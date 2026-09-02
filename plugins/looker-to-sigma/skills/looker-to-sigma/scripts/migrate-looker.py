#!/usr/bin/env python3
"""migrate-looker.py — ONE-COMMAND orchestrator for the looker-to-sigma
pipeline: parse → RLS gate → convert → DM-reuse check → DM POST + readback →
workbook build (+ layout, inline) → source-freshness preflight → scripted
parity + HARD GATE. Mirrors qlik-to-sigma's migrate-qlik.rb: every phase prints
a visible header + concise result, decision points are flags with safe defaults
(never silent), and the parity gate is NEVER bypassed — the command FAILS if a
gate fails.

This script does NOT re-implement any phase — it chains the per-phase scripts:
  parse_lookml_dashboard.py / fetch_looker_dashboard.py
                          (Phase 1 — the normalized dashboard contract, offline
                           .dashboard.lookml or live GET /dashboards/{id})
  detect_rls.py           (Phase 2 — RLS gate: zero overhead when clean; when
                           RLS IS found the command STOPS (exit 10) unless
                           --yes — security is never silently dropped. Port it
                           via apply_sigma_rls.py (SKILL.md Phase 1.5), then
                           re-run.)
  convert_dm.mjs / a local converter build / the MCP-request pattern
                          (Phase 3 — LookML → Sigma DM spec. No shellable
                           converter? The command writes convert-request.json —
                           the exact mcp__sigma-data-model__convert_lookml_to_sigma
                           arguments — and exits 3; call the tool, save its JSON,
                           and re-run with --converted <file>. Mirrors
                           thoughtspot's exit-3 design.)
  lookml-dm-signature.py + find-or-pick-dm.rb
                          (Phase 3.5 — DM-reuse check: candidates+scores
                           PRINTED, default = build new; reuse only on an
                           explicit --reuse-dm <id>)
  post_dm.py              (Phase 3 — POST /v2/dataModels/spec, join-key guard
                           included) + denorm-element readback
  build_workbook.py       (Phase 4 — contract + view .lkml → workbook spec with
                           the newspaper→24-col layout XML inline; POST once)
  Phase 5 — SOURCE-FRESHNESS preflight: source mtime/live note + a warehouse
            snapshot (master row count + max date) printed BEFORE any
            side-by-side.
  phase6-parity-looker.rb (Phase 6 — two-pass parity, fully scripted: ACTUAL =
                           Sigma CSV export per chart; EXPECTED = a Looker
                           inline query when live, or a SOURCE-LookML-derived
                           re-aggregation of the master's warehouse rows when
                           offline) + verify-parity.rb
  assert-phase6-ran.rb    (HARD GATE — vendored byte-identical from
                           quicksight-to-sigma; must exit 0 to declare GREEN)

Usage (offline — fixtures, no live Looker):
  python3 scripts/migrate-looker.py --lookml-dir fixtures/skilltest-orders \
      --dashboard fixtures/skilltest-orders/skilltest_orders.dashboard.lookml \
      [--name PREFIX] [--workdir DIR]
Usage (live — ~/.looker/looker.ini configured):
  python3 scripts/migrate-looker.py --lookml-dir /path/to/lookml \
      --dashboard-id <id> [--explore <name>] [--name PREFIX] [--workdir DIR]
Resume after the MCP converter fallback (exit 3):
  ... same command ... --converted <workdir>/converted.json
Other flags:
  --reuse-dm <dataModelId>   reuse an existing DM (skip convert+POST) — the
                             Phase-3.5 check prints candidates; reuse is NEVER
                             chosen silently, only via this flag
  --skip-dm-reuse-check      skip the Phase-3.5 scan entirely
  --folder <folderId>        Sigma folder (auto-resolved and PRINTED when unset)
  --yes                      accept safe defaults at the RLS gate (proceed
                             WITHOUT porting RLS — loud, recorded, never silent)
  --dry-run                  no Sigma POSTs: contract + RLS scan + DM spec (or
                             MCP request) + workbook spec with placeholder ids

Env: SIGMA_BASE_URL + SIGMA_API_TOKEN (or SIGMA_CLIENT_ID/SECRET via
~/.sigma-migration/env — the script mints a token), SIGMA_CONNECTION_ID,
optional CONVERTER_SRC (src/lookml.ts, run via tsx) or CONVERTER_PATH
(build/lookml.js) — both auto-located.

Exit codes: 0 = done, all gates GREEN; 3 = MCP convert request emitted (resume
with --converted); 10 = RLS found, decision needed (nothing posted);
12 = LookML readiness blocked (nothing posted); 2 = built but a parity,
accounting, report, or hard gate FAILED; other = error.
"""
import argparse, csv, glob, io, json, os, re, statistics, subprocess, sys, time
import urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import scout_gate
import code_rep  # workbook code-rep document-wrapper adapter (nested POST shape)
from build_workbook import build_field_index, parse_join_aliases, disp, leaf
from looker_filter_expr import matches_filter_expr
from safe_workbook_io import (
    fingerprint,
    list_entries,
    remote_drifted,
    validate_workbook_refs,
)

HERE = os.path.dirname(os.path.abspath(__file__))
T0 = time.time()
MCP_TOOL = "mcp__sigma-data-model__convert_lookml_to_sigma"
VENDORED_CONVERTER = os.path.join(HERE, "..", "converter", "lookml.mjs")
READINESS_BLOCKED_EXIT = 12
SIGMA_POSTS_ALLOWED = False


def resolve_converter():
    """Converter resolution (issue #227). The pinned VENDORED bundle is the
    DEFAULT so a developer machine and a customer machine produce identical
    output for the same input. A local sigma-data-model-mcp checkout/build is
    used ONLY when EXPLICITLY opted in via CONVERTER_SRC (src/lookml.ts, run via
    tsx) or CONVERTER_PATH (build/lookml.js) — there is NO silent auto-discovery
    of ~/sigma-data-model-mcp or ~/Desktop/sigma-data-model-mcp checkouts (that
    was the "works in my demo, differs for the customer" footgun).

    Returns (kind, path, desc) where kind is one of "src", "build", "vendored",
    or None (no converter resolvable — the MCP-request fallback applies)."""
    src = os.environ.get("CONVERTER_SRC")
    build = os.environ.get("CONVERTER_PATH")
    if not src and not build and os.path.exists(VENDORED_CONVERTER):
        build = VENDORED_CONVERTER
    if src:
        return "src", src, f"DEV SRC {src} (explicit opt-in via CONVERTER_SRC)"
    if build:
        if build == VENDORED_CONVERTER:
            prov_path = os.path.join(os.path.dirname(VENDORED_CONVERTER), "PROVENANCE.json")
            commit = None
            try:
                commit = json.load(open(prov_path)).get("source_commit")
            except Exception:
                pass
            return ("vendored", build,
                    f"VENDORED {os.path.basename(VENDORED_CONVERTER)}"
                    f"{f' (pinned {commit})' if commit else ''} — no data egress")
        return "build", build, f"DEV BUILD {build} (explicit opt-in via CONVERTER_PATH)"
    return None, None, ("NONE — vendored bundle missing; convert_lookml_to_sigma "
                        "MCP / --converted fallback applies")


def warn_converter_skew(resolved_path):
    """Version-skew footgun (bead 8nq5): the resolved converter checkout may be
    behind origin/main (e.g. a stale ~/Desktop clone). Compare HEAD vs
    origin/main and warn LOUDLY — never silently convert with old rules."""
    repo = resolved_path
    while repo and repo != os.path.dirname(repo) and not os.path.isdir(os.path.join(repo, ".git")):
        repo = os.path.dirname(repo)
    if not repo or not os.path.isdir(os.path.join(repo, ".git")):
        return
    def _git(*args, timeout=None):
        try:
            p = subprocess.run(["git", "-C", repo, *args], capture_output=True,
                               text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return None
        return p.stdout.strip() if p.returncode == 0 else None
    # A stale clone's LOCAL origin/main ref is stale too — refresh it (bounded;
    # offline/slow networks fall back to the local ref, never block the run).
    _git("fetch", "--quiet", "origin", "main", timeout=8)
    head = _git("rev-parse", "HEAD")
    main = _git("rev-parse", "origin/main")
    if head and main and head != main:
        print(f"\n   ════════ ⚠ CONVERTER VERSION SKEW ════════")
        print(f"   converter checkout : {repo}")
        print(f"   git HEAD           : {head[:12]}  ≠  origin/main {main[:12]}")
        print(f"   This checkout does NOT match origin/main — converter fixes may be")
        print(f"   missing (or unmerged local edits may be in play). Run:")
        print(f"     git -C {repo} fetch && git -C {repo} log --oneline HEAD..origin/main")
        print(f"   or set CONVERTER_SRC/CONVERTER_PATH at the checkout you intend to use.")
        print("   " + "═" * 42)


def hdr(n, total, title):
    print(f"\n── Phase {n}/{total} · {title} ──")


def run(cmd, env=None, cwd=None, check=True):
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd,
                       env={**os.environ, **(env or {})})
    out = (p.stdout or "") + (p.stderr or "")
    for line in out.splitlines():
        print("   " + line)
    if check and p.returncode != 0:
        sys.exit(f"FATAL: command failed ({p.returncode}): {' '.join(cmd)}")
    return p.returncode, out


def derive_render_health(workdir, render_png):
    """Persist the canonical render-health.json consumed by the final report.

    Prefer the measured render_health nested in visual-similarity.json. When
    visual similarity was not applicable but Phase 4c produced a Sigma PNG,
    analyze that PNG directly. Absence/error is recorded explicitly so the
    report fails closed instead of treating missing render evidence as healthy.
    """
    out = os.path.join(workdir, "render-health.json")
    vs_path = os.path.join(workdir, "visual-similarity.json")
    health = None
    if os.path.isfile(vs_path):
        try:
            similarity = json.load(open(vs_path))
            candidate = similarity.get("render_health")
            if isinstance(candidate, dict):
                health = candidate
                health = {**health, "source": "visual-similarity.json#render_health"}
        except Exception as ex:
            health = {"status": "ERROR", "reasons": [f"invalid visual-similarity.json: {ex}"]}
    if health is None and render_png and os.path.isfile(render_png):
        rc, _ = run([sys.executable, os.path.join(HERE, "png_health.py"),
                     "--image", render_png, "--json-out", out], check=False)
        try:
            health = json.load(open(out))
        except Exception:
            health = {"status": "ERROR",
                      "reasons": [f"png_health.py exited {rc} without readable output"],
                      "path": render_png}
    if health is None:
        health = {"status": "ERROR", "reasons": ["no Sigma render PNG was produced"]}
    with open(out, "w") as handle:
        json.dump(health, handle, indent=2)
        handle.write("\n")
    print(f"   render health: {health.get('status', 'ERROR')} → {out}")
    return health


def run_looker_accounting(workdir, contract_path, workbook_spec_path, stage):
    """Build/refresh source-object-census.json using the sibling accountant.

    The accountant owns object identity and terminal-status derivation. This
    adapter supplies the stable CLI contract, allowing the preliminary
    (post-build) and final (post-gate) passes to share one call without
    duplicating accounting logic in the orchestrator.
    """
    script = os.path.join(HERE, "build-looker-accounting.py")
    if not os.path.isfile(script):
        print(f"   FATAL: required accounting script missing: {script}")
        return 127
    cmd = [
        sys.executable, script,
        "--workdir", workdir,
        "--readiness", os.path.join(workdir, "lookml-readiness.json"),
        "--field-census", os.path.join(workdir, "lookml-field-census.json"),
        "--formula-mapping", os.path.join(workdir, "formula-mapping.json"),
        "--contract", contract_path,
        "--wb-spec", workbook_spec_path,
    ]
    optional = [
        ("--dm-spec", os.path.join(workdir, "dm-readback.json")),
        ("--dm-warnings", os.path.join(workdir, "dm-spec-warnings.json")),
        ("--control-scope", os.path.join(workdir, "control-scope.json")),
    ]
    if stage == "final":
        optional.append(("--parity-final", os.path.join(workdir, "parity-final.json")))
    for option, path in optional:
        if os.path.isfile(path):
            cmd += [option, path]
    if stage == "preliminary":
        cmd += [
            "--census-out", "preliminary-source-object-census.json",
            "--coverage-out", "preliminary-coverage.json",
            "--controls-out", "preliminary-controls.json",
        ]
    rc, _ = run(cmd, check=False)
    census_path = os.path.join(
        workdir,
        "preliminary-source-object-census.json"
        if stage == "preliminary" else "source-object-census.json",
    )
    if rc == 0 and os.path.isfile(census_path):
        try:
            census = json.load(open(census_path))
            objects = census.get("objects") or census.get("source_objects") or []
            count = len(objects) if isinstance(objects, list) else sum(
                len(v) for v in objects.values() if isinstance(v, list)
            ) if isinstance(objects, dict) else 0
            print(f"   {stage} accounting: {count} source object(s) → {census_path}")
        except Exception:
            print(f"   {stage} accounting wrote unreadable {census_path}")
            return 2
    return rc


def refresh_degradation_ledger(workdir):
    """Re-derive the canonical ledger after final accounting rewrites coverage."""
    ruby = (
        "entries = DegradationLedger.derive(ARGV.fetch(0)); "
        "exit(DegradationLedger.write(ARGV.fetch(0), entries) ? 0 : 1)"
    )
    rc, _ = run([
        "ruby", "-I", os.path.join(HERE, "lib"),
        "-rdegradation_ledger", "-e", ruby, workdir,
    ], check=False)
    return rc


def ensure_sigma_env(workdir=None):
    """Load ~/.sigma-migration/env and mint a bearer when SIGMA_API_TOKEN isn't
    already exported.

    Shell-neutral (no bash, no `eval`): shells out to the co-located
    get_token.py with the SAME interpreter already running this script
    (sys.executable — no PATH/py-launcher guessing needed), which writes
    <workdir>/auth.json; read the token back from there. Works identically on
    macOS/Linux/Windows."""
    env_file = os.path.expanduser("~/.sigma-migration/env")
    if os.path.exists(env_file):
        for line in open(env_file):
            m = re.match(r"\s*export\s+(\w+)=['\"]?([^'\"\n]+)", line)
            if m and not os.environ.get(m.group(1)):
                os.environ[m.group(1)] = m.group(2)
    if not os.environ.get("SIGMA_API_TOKEN") and os.environ.get("SIGMA_CLIENT_ID"):
        wd = workdir or os.getcwd()
        os.makedirs(wd, exist_ok=True)
        p = subprocess.run([sys.executable, os.path.join(HERE, "get_token.py"),
                            "--workdir", wd], capture_output=True, text=True)
        if p.returncode != 0:
            print(p.stderr or p.stdout, file=sys.stderr)
        auth_path = os.path.join(wd, "auth.json")
        if os.path.exists(auth_path):
            auth = json.load(open(auth_path))
            if auth.get("SIGMA_API_TOKEN"):
                os.environ["SIGMA_API_TOKEN"] = auth["SIGMA_API_TOKEN"]
            if auth.get("SIGMA_BASE_URL") and not os.environ.get("SIGMA_BASE_URL"):
                os.environ["SIGMA_BASE_URL"] = auth["SIGMA_BASE_URL"]


def sigma(method, path, body=None):
    if method.upper() == "POST" and not SIGMA_POSTS_ALLOWED:
        raise RuntimeError(
            f"Sigma POST {path} refused before the LookML readiness gate passed"
        )
    base = os.environ["SIGMA_BASE_URL"]; tok = os.environ["SIGMA_API_TOKEN"]
    req = urllib.request.Request(base + path,
        data=(json.dumps(body).encode() if body is not None else None), method=method,
        headers={"Authorization": "Bearer " + tok, "Accept": "application/json",
                 **({"Content-Type": "application/json"} if body is not None else {})})
    try:
        return urllib.request.urlopen(req).read().decode()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Sigma {method} {path} -> {e.code}: {e.read().decode()[:300]}")


def my_documents_id():
    """Return the caller's documented My Documents inode ID."""
    uid = json.loads(sigma("GET", "/v2/whoami"))["userId"]
    member = json.loads(sigma("GET", f"/v2/members/{uid}")) or {}
    if member.get("homeFolderId"):
        return member["homeFolderId"]
    # Legacy fallback: use the folder's id, never its parentId.
    entries = (json.loads(sigma("GET", f"/v2/members/{uid}/files")) or {}).get("entries") or []
    entry = next((e for e in entries if e.get("path") == "My Documents"), None)
    if entry and entry.get("id"):
        return entry["id"]
    entries = (json.loads(sigma("GET", "/v2/files?typeFilters=folder&limit=500")) or {}).get("entries") or []
    entry = next((e for e in entries
                  if e.get("path") == "My Documents" and e.get("ownerId") == uid), None)
    return entry.get("id") if entry else None


def resolve_folder(arg):
    """--folder / SIGMA_FOLDER_ID, else an EXACT 'Looker Migrations' folder,
    else create one under My Documents, else My Documents itself. The old
    substring heuristic (LOOKER/MIGRATION/TEST) is gone — it happily dropped
    Looker output into 'ThoughtSpot Migrations' (bead eqom)."""
    if arg:
        return arg
    if os.environ.get("SIGMA_FOLDER_ID"):
        return os.environ["SIGMA_FOLDER_ID"]
    files = json.loads(sigma("GET", "/v2/files?typeFilters=folder&limit=500"))
    entries = files.get("entries") or []
    pick = next((f for f in entries
                 if (f.get("name") or "").strip().lower() == "looker migrations"), None)
    if pick:
        print(f"   no --folder supplied — using existing folder '{pick.get('name')}' ({pick['id']})")
        return pick["id"]
    mydocs = my_documents_id()
    try:
        body = {"name": "Looker Migrations", "type": "folder"}
        if mydocs:
            body["parentId"] = mydocs
        created = json.loads(sigma("POST", "/v2/files", body))
        fid = created.get("id") or created.get("fileId")
        if fid:
            print(f"   no --folder supplied — created folder 'Looker Migrations' ({fid})")
            return fid
    except Exception as ex:
        print(f"   could not create 'Looker Migrations' folder ({str(ex)[:120]})")
    if mydocs:
        print(f"   no --folder supplied — using My Documents ({mydocs})")
        return mydocs
    sys.exit("FATAL: no writable folder found — pass --folder")


def surface_converter_warnings(wd, warns):
    """Print converter warnings PROMINENTLY after Phase 3 — layered/derived
    LookML (cross-view ${view.SQL_TABLE_NAME} refs, incremental PDTs, CTE
    fragments) produces 🔶 action-required warnings that must never scroll by
    unnoticed. Pattern guide: refs/layered-lookml.md."""
    if not warns:
        return
    loud = [w for w in warns if w.startswith("🔶")]
    review = [w for w in warns if w.startswith("⚠")]
    other = [w for w in warns if w not in loud and w not in review]
    if loud:
        print(f"\n   ════════ 🔶 ACTION REQUIRED — {len(loud)} converter warning(s) ════════")
        for w in loud:
            print("   " + w)
        if any("UNRESOLVED VIEW" in w for w in loud):
            print("   ► UNRESOLVED VIEW: the emitted SQL contains LOOKER_SCRATCH.* placeholder")
            print("     tables and will NOT run. Add the named .view.lkml file(s) to --lookml-dir")
            print("     and re-run (cross-view refs resolve across the whole directory), or")
            print("     repoint the placeholder at the real warehouse table.")
        if any("materialization" in w.lower() for w in loud):
            print("   ► MATERIALIZATION HANDOFF: this view was a persisted/incremental PDT in")
            print("     Looker. After the DM posts, enable a materialization schedule on the")
            print("     flagged element (Sigma UI → Materialization tab, or the API).")
        print("   " + "═" * 64)
    if review:
        print(f"\n   ⚠ review — {len(review)} warning(s):")
        for w in review:
            print("   " + w)
    if other:
        print(f"   ℹ {len(other)} informational warning(s) — full list: {os.path.join(wd, 'dm-spec-warnings.json')}")
    print("   layered/derived LookML pattern guide: refs/layered-lookml.md")


def export_csv(wb_id, element_id, timeout=240):
    res = json.loads(sigma("POST", f"/v2/workbooks/{wb_id}/export",
                           {"elementId": element_id, "format": {"type": "csv"}}))
    qid = res["queryId"]
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            body = sigma("GET", f"/v2/query/{qid}/download")
            if body and body.strip():
                return body
        except RuntimeError:
            pass
        time.sleep(2)
    raise RuntimeError(f"CSV export of element {element_id} timed out")


def parse_csv(body):
    rows = list(csv.reader(io.StringIO(body)))
    return (rows[0], rows[1:]) if rows else ([], [])


def numify(v):
    s = str(v).strip().replace("$", "").replace(",", "").replace("%", "")
    try:
        return float(s)
    except ValueError:
        # date-at-midnight (Sigma CSV) vs plain date (Looker JSON): same instant
        m = re.match(r"^(\d{4}-\d{2}-\d{2})[T ]00:00:00(?:\.0+)?$", s)
        if m:
            return m.group(1)
        return v


# ── EXPECTED side (offline): re-aggregate the master's warehouse rows per the
#    SOURCE LookML measure definitions — independent of the formulas the
#    builder generated, so a builder bug DIVERGES instead of self-confirming. ──
class SourceEval:
    def __init__(self, measures, view_pk, explore, headers):
        self.measures, self.view_pk, self.explore = measures, view_pk, explore
        self.idx = {h: i for i, h in enumerate(headers)}

    def display(self, field):
        view = field.split(".")[0]
        suf = "" if view == self.explore else f" ({view})"
        if field in self.measures:
            base = self.measures[field][1]
            return (base + suf) if base else None
        return disp(leaf(field)) + suf

    def col_vals(self, field_display, rows, raw=False):
        i = self.idx.get(field_display)
        if i is None:
            return None
        vals = [r[i] for r in rows if str(r[i]).strip() != ""]
        return vals if raw else [numify(v) for v in vals]

    def measure_value(self, field, rows, depth=0):
        if depth > 4 or field not in self.measures:
            return None
        # build_field_index emits 4-tuples (mtype, base, sql, filters) — take the
        # first three (the filters slot was added for filtered-measure tiles).
        mtype, base, sql = self.measures[field][:3]
        view = field.split(".")[0]
        if mtype in ("number",) or re.search(r"\$\{(\w+)\}", sql or ""):
            # ratio / composite: substitute each ${measure} component recursively
            refs = {m for m in re.findall(r"\$\{(\w+)\}", sql or "")
                    if f"{view}.{m}" in self.measures}
            if refs:
                expr = sql
                for m in refs:
                    v = self.measure_value(f"{view}.{m}", rows, depth + 1)
                    if v is None:
                        return None
                    expr = expr.replace("${%s}" % m, f"({v!r})")
                expr = re.sub(r"\$\{TABLE\}\.", "", expr)
                expr = re.sub(r"\bNULLIF\s*\(", "NullIf(", expr, flags=re.I)
                try:
                    return eval(expr, {"__builtins__": {}},          # noqa: S307 — arithmetic only
                                {"NullIf": lambda x, y: None if x == y else x})
                except Exception:
                    return None
        d = self.display(field)
        if mtype == "count":
            if view != self.explore and self.view_pk.get(view):
                pk = disp(self.view_pk[view]) + f" ({view})"
                vals = self.col_vals(pk, rows, raw=True)
                return len(set(vals)) if vals is not None else len(rows)
            return len(rows)
        vals = self.col_vals(d, rows, raw=(mtype == "count_distinct"))
        if vals is None:
            return None
        if mtype == "count_distinct":
            return len(set(vals))
        nums = [v for v in vals if isinstance(v, float)]
        return {"sum": sum, "average": statistics.fmean, "avg": statistics.fmean,
                "min": min, "max": max,
                "median": statistics.median}.get(mtype, sum)(nums) if nums else None


def expected_offline(el, ev, rows):
    """Contract element + SourceEval + master rows → [[dim, val], ...]."""
    fields = el.get("fields") or []
    ms = [f for f in fields if f in ev.measures]
    ds = [f for f in fields if f not in ev.measures]
    data = rows
    for fld, val in (el.get("filters") or {}).items():
        d = ev.display(fld)
        i = ev.idx.get(d)
        if i is None:
            continue
        verdicts = [matches_filter_expr(r[i], val) for r in data]
        if all(verdict is not None for verdict in verdicts):
            data = [row for row, keep in zip(data, verdicts) if keep]
    if el.get("tileType") == "looker_scatter" and len(ms) >= 2:
        groups = {None: data}
        if ds:
            groups = {}
            di = ev.idx.get(ev.display(ds[0]))
            for r in data:
                groups.setdefault(r[di], []).append(r)
        return [[ev.measure_value(ms[0], rs), ev.measure_value(ms[1], rs)]
                for rs in groups.values()]
    if not ms:
        return None
    # dim field mirrors the builder/plan: pie slices come from pivots[0] or the
    # first dimension; axis charts use the first dimension; KPI has none.
    if el.get("tileType") in ("looker_pie", "looker_donut_multiples"):
        catf = (el.get("pivots") or ds or [None])[0]
    else:
        catf = ds[0] if ds else None
    if el.get("tileType") == "single_value" or not catf:
        return [[None, ev.measure_value(ms[0], data)]]
    di = ev.idx.get(ev.display(catf))
    if di is None:
        return None
    groups = {}
    for r in data:
        groups.setdefault(r[di], []).append(r)
    return [[d, ev.measure_value(ms[0], rs)] for d, rs in groups.items()]


def expected_live(el, measures=None, want_label=None):
    """Ground truth from Looker itself: run the tile's inline query.

    want_label: for measure-only grids split into KPI tiles named
    "<tile> · <Measure Label>", select the field whose display matches the
    label (and return a single [[None, value]] row)."""
    import looker_api
    fields = el.get("fields") or []
    body = {"model": el.get("model"), "view": el.get("explore"), "fields": fields,
            "filters": el.get("filters") or {}, "limit": "5000"}
    code, res = looker_api.call("POST", "/queries/run/json", body)
    if code != 200 or not isinstance(res, list):
        raise RuntimeError(f"Looker inline query -> {code}: {str(res)[:200]}")
    keys = list(res[0].keys()) if res else fields
    val_key = None
    if want_label:
        val_key = next((f for f in fields
                        if disp(leaf(f)) == want_label and f in keys), None)
        if val_key is None:
            raise RuntimeError(f"no field matching KPI label {want_label!r}")
        return [[None, numify(res[0][val_key])]] if res else None
    # The Sigma chart's value axis is the tile's FIRST measure (build_workbook
    # ms[0] — same convention as expected_offline). Compare the SAME measure:
    # first field that is a LookML measure; fallback = last field.
    if measures:
        val_key = next((f for f in fields if f in measures and f in keys), None)
    if val_key is None:
        val_key = next((f for f in reversed(fields) if f in keys), keys[-1])
    dim_key = next((f for f in fields if f != val_key and f in keys), None)
    if dim_key is None:
        return [[None, numify(res[0][val_key])]] if res else None
    # Sigma CSV export renders NULL dims as "" — normalize Looker's null the
    # same way so a null-dim row doesn't strict-DIVERGE on representation.
    return [["" if r[dim_key] is None else r[dim_key], numify(r[val_key])] for r in res]


def main():
    global SIGMA_POSTS_ALLOWED
    ap = argparse.ArgumentParser()
    ap.add_argument("--lookml-dir", help="LookML project dir (model + views). "
                    "Omit when using --project (pulled via the Looker API).")
    ap.add_argument("--project", help="Looker project id — pull its LookML over the "
                    "REST API instead of using a local --lookml-dir (needs DEVELOP "
                    "permission on the project; see looker_project.py).")
    ap.add_argument("--dashboard", help="offline: a .dashboard.lookml file")
    ap.add_argument("--dashboard-id", help="live: Looker dashboard id (needs ~/.looker/looker.ini)")
    ap.add_argument("--look-id", help="live: Looker Look id (a single saved query → a "
                    "one-tile workbook; needs ~/.looker/looker.ini)")
    ap.add_argument("--explore", help="explore to convert (default: the contract's most-used)")
    ap.add_argument("--name", help="name PREFIX applied to the DM and the workbook")
    ap.add_argument("--workdir")
    ap.add_argument("--converted", help="JSON output of the convert_lookml_to_sigma MCP tool")
    ap.add_argument("--reuse-dm")
    ap.add_argument("--skip-dm-reuse-check", action="store_true")
    ap.add_argument("--folder")
    ap.add_argument("--update-workbook",
                    help="PUT an existing workbook instead of POSTing a new one; "
                         "uses a version+hash drift guard")
    ap.add_argument("--force-overwrite", action="store_true",
                    help="override a detected concurrent workbook edit (recorded loudly)")
    ap.add_argument("--source-swap", action="append", default=[],
                    help="FROM_DB.FROM_SCHEMA=TO_DB.TO_SCHEMA — repoint warehouse "
                         "source paths when the LookML sql_table_name differs from "
                         "the Sigma connection's catalog. Repeatable.")
    ap.add_argument("--auto-source-swap-to", metavar="TO_DB.TO_SCHEMA",
                    help="Resolve the FROM_DB.FROM_SCHEMA automatically from the "
                         "Looker connection (GET /connections) and repoint it to "
                         "this target. Saves hand-writing --source-swap; needs the "
                         "Looker API (~/.looker/looker.ini).")
    ap.add_argument("--reuse-auto", action="store_true",
                    help="allow Phase 3.5 to AUTO-adopt a reusable DM (reuse-first). "
                         "Default OFF: candidates are printed and the safe default is "
                         "build-new (reuse only via explicit --reuse-dm).")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--materialize-derived", choices=["off", "auto", "all"], default="off",
                    help="Phase 2b always SCANS for expensive derived tables (informational). "
                         "'auto' also triggers a Sigma materialization for the DM elements the "
                         "scan flagged `materialize`; 'all' for every Custom-SQL (derived) element. "
                         "Default 'off' = recommend only. Creating the recurring schedule is "
                         "UI-only, so this triggers/monitors and prints the exact UI handoff.")
    ap.add_argument("--print-converter", action="store_true",
                    help="Resolve the converter (CONVERTER_SRC -> CONVERTER_PATH -> "
                         "vendored bundle), print the resolved path + a one-line "
                         "provenance description, and exit 0. No other args, Sigma "
                         "creds, or network access required.")
    a = ap.parse_args()
    if a.print_converter:
        _kind, _path, _desc = resolve_converter()
        print(_path or "none")
        print(_desc)
        return 0
    if not a.dashboard and not a.dashboard_id and not a.look_id:
        ap.error("--dashboard (offline .dashboard.lookml) / --dashboard-id / --look-id (live) required")
    if not a.lookml_dir and not a.project:
        ap.error("--lookml-dir (local checkout) or --project (pull via Looker API) required")
    offline = not a.dashboard_id and not a.look_id
    wd = os.path.abspath(os.path.expanduser(a.workdir or "./looker-migration"))
    os.makedirs(wd, exist_ok=True)

    # ── --project: pull the LookML over the Looker REST API (no local checkout).
    # Needs DEVELOP permission on the project (raw LookML is only served in the dev
    # workspace); on a permission/API failure, fail loud with the --lookml-dir hint.
    if a.project and not a.lookml_dir:
        import looker_project
        pulled = os.path.join(wd, "lookml")
        print(f"── pulling LookML for project '{a.project}' via the Looker API → {pulled} ──")
        try:
            files = looker_project.pull_project(a.project, pulled)
            print(f"   pulled {len(files)} .lkml file(s)")
        except Exception as ex:
            sys.exit(f"FATAL: --project pull failed: {ex}")
        a.lookml_dir = pulled
    lookml_dir = os.path.abspath(os.path.expanduser(a.lookml_dir))
    prefix = (a.name.strip() + " ") if a.name else ""
    TOTAL = 6

    # ── Phase 1 — Parse (the normalized dashboard contract) ──────────────────
    hdr(1, TOTAL, "Parse")
    contract_path = os.path.join(wd, "contract.json")
    if a.look_id:
        # A Look is a single saved query → the same normalized contract with one tile.
        run([sys.executable, os.path.join(HERE, "fetch_looker_look.py"),
             a.look_id, contract_path])
    elif offline:
        run([sys.executable, os.path.join(HERE, "parse_lookml_dashboard.py"),
             a.dashboard, "--out", contract_path])
    else:
        run([sys.executable, os.path.join(HERE, "fetch_looker_dashboard.py"),
             a.dashboard_id, contract_path])
    dash = json.load(open(contract_path))
    if isinstance(dash, list):
        dash = dash[0]
    explores = [e.get("explore") for e in dash["elements"] if e.get("explore")]
    explore = a.explore or (max(set(explores), key=explores.count) if explores else None)
    views_dir = os.path.join(lookml_dir, "views")
    if not os.path.isdir(views_dir):
        views_dir = lookml_dir
    view_files = sorted(glob.glob(os.path.join(views_dir, "*.view.lkml")))
    _aliases = parse_join_aliases(glob.glob(os.path.join(lookml_dir, "*.model.lkml")))
    measures, _dims, view_pk, _formats, _yesno, _dim_groups, _labels = build_field_index(view_files, _aliases)
    print(f"   '{dash['title']}': {len(dash['elements'])} tile(s), {len(dash['filters'])} filter(s), "
          f"explore '{explore}' · {len(view_files)} view file(s), {len(measures)} measure(s) · workdir {wd}")

    # ── Phase 1b — readiness audit (HARD pre-POST gate) ──────────────────────
    # This runs immediately after source parsing/LookML discovery and before
    # credentials are minted, a folder is created, or any Sigma object is
    # posted. The audit uses the same vendored converter as Phase 3 and always
    # persists the three source-accounting artifacts. A blocked audit has its
    # own exit so callers can distinguish unsupported/omitted LookML from RLS,
    # parity, and infrastructure failures.
    print("\n── Phase 1b · LookML readiness (pre-POST hard gate) ──")
    readiness_path = os.path.join(wd, "lookml-readiness.json")
    field_census_path = os.path.join(wd, "lookml-field-census.json")
    formula_mapping_path = os.path.join(wd, "formula-mapping.json")
    readiness_cmd = [
        "node", os.path.join(HERE, "audit-lookml-readiness.mjs"),
        "--lookml-dir", lookml_dir,
        "--out", readiness_path,
        "--field-census", field_census_path,
        "--formula-mapping", formula_mapping_path,
        "--dashboard-contract", contract_path,
    ]
    readiness_explores = sorted(set([e for e in explores if e] +
                                    ([explore] if explore else [])))
    for target_explore in readiness_explores:
        readiness_cmd += ["--explore", target_explore]
    readiness_rc, _ = run(readiness_cmd, check=False)
    readiness = {}
    try:
        readiness = json.load(open(readiness_path))
    except Exception:
        pass
    readiness_status = str(readiness.get("readiness") or "").lower()
    if readiness_rc == 1 or readiness_status == "blocked":
        print("   ⛔ readiness BLOCKED — unsupported, unresolved, or omitted LookML was found.")
        print(f"   Review {readiness_path}, {field_census_path}, and {formula_mapping_path}.")
        print("   Nothing was posted to Sigma.")
        return READINESS_BLOCKED_EXIT
    if readiness_rc != 0 or readiness_status not in ("clean", "caveat"):
        sys.exit(f"FATAL: LookML readiness audit failed ({readiness_rc}); nothing was posted")
    print(f"   readiness {readiness_status.upper()} · "
          f"{readiness.get('summary', {}).get('fields', 0)} field(s), "
          f"{readiness.get('summary', {}).get('omitted', 0)} omitted")
    SIGMA_POSTS_ALLOWED = True

    ensure_sigma_env(wd)
    if not a.dry_run:
        missing = [v for v in ("SIGMA_BASE_URL", "SIGMA_API_TOKEN") if not os.environ.get(v)]
        if not a.reuse_dm and not os.environ.get("SIGMA_CONNECTION_ID"):
            missing.append("SIGMA_CONNECTION_ID (full warehouse-connection UUID — NOT a short prefix)")
        if missing:
            sys.exit("FATAL: missing env: " + ", ".join(missing))

    # ── --auto-source-swap-to: ask Looker what DB.SCHEMA this explore's connection
    # targets (the FROM) and build the swap to the requested TARGET. Removes the
    # postmortem's hand-written --source-swap. Production-safe (no develop perm).
    if a.auto_source_swap_to:
        import looker_project
        model = next((el.get("model") for el in dash["elements"] if el.get("model")), None)
        conn, fdb, fsch = (looker_project.explore_connection_target(model, explore)
                           if model and explore else (None, None, None))
        if fdb and fsch:
            swap = f"{fdb}.{fsch}={a.auto_source_swap_to}"
            if swap not in a.source_swap:
                a.source_swap.append(swap)
            print(f"   auto-source-swap: Looker connection '{conn}' targets {fdb}.{fsch} "
                  f"→ repointing to {a.auto_source_swap_to}")
        else:
            print(f"   ⚠ --auto-source-swap-to: could not resolve the Looker connection "
                  f"target for model={model} explore={explore} — pass --source-swap explicitly")

    # ── Phase 2 — RLS gate (zero overhead when clean; LOUD when not) ─────────
    # Scoped to the model(s)/explore(s) THIS dashboard uses (bead 8nq5): RLS on
    # other models in the same project dir is an informational note, not a stop.
    hdr(2, TOTAL, "RLS gate (detect_rls.py)")
    dash_models = sorted({el.get("model") for el in dash["elements"] if el.get("model")})
    dash_explores = sorted({e for e in explores if e} | ({explore} if explore else set()))
    scope_args = []
    if dash_models:
        scope_args += ["--scope-models", ",".join(dash_models)]
    if dash_explores:
        scope_args += ["--scope-explores", ",".join(dash_explores)]
    p = subprocess.run([sys.executable, os.path.join(HERE, "detect_rls.py"), lookml_dir,
                        "--json"] + scope_args, capture_output=True, text=True)
    findings, info_findings = [], []
    try:
        parsed = json.loads(p.stdout) if p.stdout.strip() else []
        findings = parsed.get("findings", parsed) if isinstance(parsed, dict) else parsed
        info_findings = parsed.get("informational", []) if isinstance(parsed, dict) else []
    except ValueError:
        findings = []
    if info_findings:
        print(f"   ℹ {len(info_findings)} RLS finding(s) on OTHER model(s)/explore(s) in this "
              f"project (dashboard uses {', '.join(dash_models or dash_explores)}) — "
              "informational only, no gate:")
        for f in info_findings[:5]:
            print(f"     - [{f.get('construct')}] {f.get('source')}"
                  + (f" explore={f.get('explore')}" if f.get("explore") else ""))
        json.dump(info_findings, open(os.path.join(wd, "rls-out-of-scope.json"), "w"), indent=2)
    if not findings:
        print("   no RLS constructs found on this dashboard's model(s) — proceeding "
              "(zero-overhead happy path)")
    else:
        print(f"   ⚠ {len(findings)} RLS finding(s):")
        for f in findings[:10]:
            print(f"     - {json.dumps(f)[:160]}")
        json.dump(findings, open(os.path.join(wd, "rls-findings.json"), "w"), indent=2)
        if not a.yes:
            print("\n==================== DECISION NEEDED (RLS) ====================")
            print("This LookML enforces row-level security. It is NEVER silently dropped")
            print("and NEVER silently ported. Options:")
            print("  1. Port it: run the scripted flow in SKILL.md Phase 1.5")
            print("     (scripts/apply_sigma_rls.py — reuse-first, plan-only by default),")
            print("     then re-run this command with --yes.")
            print("  2. Re-run with --yes to migrate WITHOUT RLS (every row visible to")
            print("     everyone — the outcome is recorded in rls-findings.json).")
            print("Nothing was posted to Sigma.")
            print("===============================================================")
            return 10
        print("   --yes: proceeding WITHOUT porting RLS — the migrated model shows ALL rows")
        print("   to everyone until you run apply_sigma_rls.py (recorded in rls-findings.json)")

    # ── Phase 2b — Performance scan (detect_derived_perf.py; informational) ───
    # The converter ports every derived_table's SQL verbatim (nested derived
    # views inline as stacked CTEs into ONE Custom SQL element), so slow Looker
    # SQL stays slow in Sigma. Scan for expensive derived tables and recommend
    # materializing them. NON-BLOCKING — recommend, never stop (unlike the RLS gate).
    print("\n── Phase 2b · Performance scan (detect_derived_perf.py) ──")
    perf_findings = []
    pp = subprocess.run(
        [sys.executable, os.path.join(HERE, "detect_derived_perf.py"), lookml_dir, "--json"]
        + (["--scope-explores", ",".join(dash_explores)] if dash_explores else []),
        capture_output=True, text=True)
    try:
        pparsed = json.loads(pp.stdout) if pp.stdout.strip() else {}
        perf_findings = pparsed.get("findings", []) if isinstance(pparsed, dict) else []
    except ValueError:
        perf_findings = []
    mat_views = [f for f in perf_findings if f.get("recommendation") == "materialize"]
    if not perf_findings:
        print("   no expensive derived tables in scope — nothing to optimize")
    else:
        print(f"   {len(perf_findings)} derived table(s) in scope; "
              f"{len(mat_views)} recommended to MATERIALIZE:")
        for f in perf_findings[:12]:
            print(f"     - {f['view']} [{f['severity']}, cost={f['cost']}] → "
                  f"{f['recommendation']} ({', '.join(f['signals'])})")
        json.dump(perf_findings, open(os.path.join(wd, "derived-perf.json"), "w"), indent=2)
        if a.materialize_derived == "off" and mat_views:
            print("   ℹ pass --materialize-derived auto to materialize the flagged element(s) after "
                  "the DM is built, or open each element's ⋮ → Materialization in the Sigma UI.")

    # ── Phase 3 — Convert (local build / patched source / MCP request) ────────
    hdr(3, TOTAL, "Convert")
    dm_spec_path = os.path.join(wd, "dm-spec.json")
    dynamic_params_path = os.path.join(wd, "dm-spec-dynamic-parameters.json")
    conn = os.environ.get("SIGMA_CONNECTION_ID", "PLACEHOLDER_CONNECTION_ID")
    if a.reuse_dm:
        print(f"   --reuse-dm {a.reuse_dm} — converter skipped")
    elif a.converted:
        conv = json.load(open(a.converted))
        spec = conv.get("model") or conv.get("sigmaDataModel") or conv
        json.dump(spec, open(dm_spec_path, "w"), indent=2)
        json.dump({"version": 1, "parameters": conv.get("dynamicParameters") or []},
                  open(dynamic_params_path, "w"), indent=2)
        print(f"   using MCP converter output {a.converted} -> {dm_spec_path}")
    else:
        # Converter resolution (issue #227): the pinned VENDORED bundle is the
        # DEFAULT so a dev machine and a customer machine convert identically. A
        # local checkout/build is used ONLY via explicit CONVERTER_SRC /
        # CONVERTER_PATH — no silent auto-discovery of ~/… checkouts.
        kind, path, desc = resolve_converter()
        src = path if kind == "src" else None
        build = path if kind in ("build", "vendored") else None
        print(f"   converter: {desc}", file=sys.stderr)
        if src or build:
            warn_converter_skew(src or build)
        if src:
            repo = os.path.dirname(os.path.dirname(src))
            run(["node", "--import", "tsx/esm", os.path.join(HERE, "convert_dm.mjs"),
                 explore, dm_spec_path],
                env={"LOOKML_DIR": lookml_dir, "CONVERTER_SRC": src,
                     "SIGMA_CONNECTION_ID": conn}, cwd=repo)
            # ── secondary explores ────────────────────────────────────────────
            # A dashboard's tiles can hit several explores; the converter takes
            # ONE exploreName, so views reachable only through a secondary
            # explore would otherwise be missing from the DM (their workbook
            # refs then 400 with "Dependency not found"). Convert each extra
            # explore and merge its NEW elements (normalized-name dedupe) into
            # the primary spec.
            def _mlnorm(s):
                return re.sub(r"[^a-z0-9]", "", (s or "").lower())
            extra = [e for e in dict.fromkeys(explores) if e and e != explore]
            if extra:
                spec0 = json.load(open(dm_spec_path))
                have = {_mlnorm(el.get("name")
                                or ((el.get("source") or {}).get("path") or [""])[-1])
                        for pg in spec0.get("pages", []) for el in pg.get("elements", [])}
                merged = 0
                for ex2 in extra:
                    if _mlnorm(ex2) in have:
                        continue
                    sub_path = os.path.join(wd, f"dm-spec-{_mlnorm(ex2)}.json")
                    run(["node", "--import", "tsx/esm",
                         os.path.join(HERE, "convert_dm.mjs"), ex2, sub_path],
                        env={"LOOKML_DIR": lookml_dir, "CONVERTER_SRC": src,
                             "SIGMA_CONNECTION_ID": conn}, cwd=repo)
                    sub = json.load(open(sub_path))
                    for pg in sub.get("pages", []):
                        for el in pg.get("elements", []):
                            key = _mlnorm(el.get("name")
                                          or ((el.get("source") or {}).get("path") or [""])[-1])
                            if key in have:
                                continue
                            have.add(key)
                            spec0["pages"][0]["elements"].append(el)
                            merged += 1
                if merged:
                    json.dump(spec0, open(dm_spec_path, "w"), indent=2)
                    print(f"   merged {merged} element(s) from {len(extra)} secondary "
                          f"explore(s): {', '.join(extra)}")
        elif build:
            shim = os.path.join(wd, "_convert_lookml.mjs")
            files = [{"name": os.path.basename(f), "content": open(f).read()}
                     for f in sorted(glob.glob(os.path.join(lookml_dir, "*.model.lkml"))) + view_files]
            json.dump(files, open(os.path.join(wd, "_lookml-files.json"), "w"))
            # Node ESM rejects a bare Windows drive-letter path
            # (ERR_UNSUPPORTED_ESM_URL_SCHEME, protocol 'c:'); a file:// URL
            # imports on every OS. as_uri() needs an absolute path (build is).
            import pathlib
            build_url = pathlib.Path(build).resolve().as_uri()
            open(shim, "w").write(f"""// generated by migrate-looker.py — local converter build path
import {{ readFileSync, writeFileSync }} from 'node:fs';
import {{ convertLookMLToSigma }} from {json.dumps(build_url)};
const files = JSON.parse(readFileSync({json.dumps(os.path.join(wd, "_lookml-files.json"))}, 'utf8'));
const res = convertLookMLToSigma(files, {{ connectionId: {json.dumps(conn)},
  exploreName: {json.dumps(explore)}, joinStrategy: 'relationships' }});
writeFileSync({json.dumps(dm_spec_path)}, JSON.stringify(res.model, null, 2));
writeFileSync({json.dumps(os.path.join(wd, "dm-spec-warnings.json"))}, JSON.stringify(res.warnings || [], null, 2));
writeFileSync({json.dumps(dynamic_params_path)}, JSON.stringify({{ version: 1, parameters: res.dynamicParameters || [] }}, null, 2));
console.error('stats:', JSON.stringify(res.stats));
(res.warnings || []).forEach(w => console.error('  WARN ' + w));
""")
            run(["node", shim])
        else:
            files = [{"name": os.path.basename(f), "content": open(f).read()}
                     for f in sorted(glob.glob(os.path.join(lookml_dir, "*.model.lkml"))) + view_files]
            req = {"tool": MCP_TOOL,
                   "arguments": {"files": files, "connectionId": conn,
                                 "exploreName": explore, "joinStrategy": "relationships"}}
            req_path = os.path.join(wd, "convert-request.json")
            json.dump(req, open(req_path, "w"), indent=2)
            print(f"""
   No shellable converter (CONVERTER_SRC / CONVERTER_PATH unset) — use the MCP converter:
     1. Call the `{MCP_TOOL}` MCP tool with the arguments in
          {req_path}
     2. Save the tool's JSON output to {wd}/converted.json
     3. RE-RUN THIS COMMAND with:  --converted {wd}/converted.json""")
            return 3

    # Surface converter warnings prominently (🔶 = action required — unresolved
    # cross-view refs / materialization handoffs; ⚠ = review). Never buried.
    if not a.reuse_dm:
        conv_warns = []
        if a.converted:
            try:
                conv_warns = json.load(open(a.converted)).get("warnings") or []
            except Exception:
                conv_warns = []
            json.dump(conv_warns, open(os.path.join(wd, "dm-spec-warnings.json"), "w"), indent=2)
        else:
            wpath = os.path.join(wd, "dm-spec-warnings.json")
            if os.path.exists(wpath):
                try:
                    conv_warns = json.load(open(wpath))
                except Exception:
                    conv_warns = []
        surface_converter_warnings(wd, conv_warns)

    # ── Phase 3.5 — DM-reuse check (printed; default = BUILD NEW) ─────────────
    hdr(3, TOTAL, "DM-reuse check (3.5)")
    if a.reuse_dm:
        print(f"   --reuse-dm {a.reuse_dm} supplied — reusing that data model (POST skipped)")
    elif a.skip_dm_reuse_check or a.dry_run:
        print("   skipped (--skip-dm-reuse-check / --dry-run) — building new")
    else:
        sig = os.path.join(wd, "dm-signature.json")
        match_out = os.path.join(wd, "dm-match.json")
        run([sys.executable, os.path.join(HERE, "lookml-dm-signature.py"),
             "--lookml-dir", lookml_dir, "--label", dash["title"], "--out", sig])
        # Auto-pick is OFF by default (POSTMORTEM 2026-06-18 #4): the gate fires on
        # TABLE coverage, not COLUMN coverage, so a DM that covers the tables but
        # lacks a column the workbook needs gets adopted → the workbook POST then
        # 400s "Dependency not found". This contradicted Phase 3.5's own contract
        # ("default = BUILD NEW; reuse only on explicit --reuse-dm"). Opt back into
        # reuse-first with --reuse-auto.
        pick_args = ["--auto-pick", "--auto-pick-threshold", "0.5"] if a.reuse_auto else []
        rc, _ = run(["ruby", os.path.join(HERE, "find-or-pick-dm.rb"),
                     "--workbook-signature", sig, "--out", match_out] + pick_args,
                    check=False)
        try:
            match = json.load(open(match_out))
            cands = match.get("candidates") or []
            for c in cands[:5]:
                print(f"     candidate: {c.get('dm_name')} ({c.get('dm_id')}) score={c.get('score')}")
            if a.reuse_auto and match.get("auto_picked") and match.get("recommended_dm_id"):
                a.reuse_dm = match["recommended_dm_id"]
                print(f"   DM-REUSE (auto, --reuse-auto): {match.get('rationale')}")
                if match.get("warning"):
                    print(f"   ⚠ {match.get('warning')}")
            elif cands:
                print(f"   ➤ {len(cands)} candidate DM(s) found — DEFAULT IS BUILD-NEW "
                      "(safe: a partial-coverage reuse can break the workbook). To reuse the")
                print(f"     top match explicitly, re-run with:  --reuse-dm {cands[0].get('dm_id')}")
            else:
                print("   no existing DM scores above the reuse threshold — building new")
        except Exception as ex:
            print(f"   DM-reuse scan unavailable ({ex}) — building new")

    if a.dry_run:
        wb_spec = os.path.join(wd, "wb-spec.json")
        wb_args = [sys.executable, os.path.join(HERE, "build_workbook.py"), contract_path,
                   "--views", views_dir, "--out", wb_spec]
        if os.path.exists(dynamic_params_path):
            wb_args += ["--dynamic-parameters", dynamic_params_path]
        run(wb_args)
        hazard_rc, _ = run(
            [sys.executable, os.path.join(HERE, "detect_modeling_hazards.py"),
             "--workdir", wd, "--contract", contract_path,
             "--dm-spec", dm_spec_path, "--wb-spec", wb_spec],
            check=False,
        )
        if hazard_rc:
            sys.exit(
                "modeling-hazard gate blocked the dry run; inspect modeling-hazards.json "
                "and rebuild at an explicit grain before posting"
            )
        print("\n================ RESULT (dry run) ================")
        print(f"artifacts   : {wd}  (contract, dm-spec/convert-request, wb-spec — no Sigma objects created)")
        print("==================================================")
        return 0

    # ── Phase 4a — POST the data model + denorm readback ──────────────────────
    hdr(4, TOTAL, "Build data model (post_dm.py + readback)")
    folder = resolve_folder(a.folder)
    if a.reuse_dm:
        dm = a.reuse_dm
    else:
        spec = json.load(open(dm_spec_path))
        if prefix:
            spec["name"] = f"{prefix}{spec.get('name') or dash['title']}"
            json.dump(spec, open(dm_spec_path, "w"), indent=2)
        swap_args = []
        for s in a.source_swap:
            swap_args += ["--source-swap", s]
        rc, out = run([sys.executable, os.path.join(HERE, "post_dm.py"), dm_spec_path,
                       "--folder-id", folder] + swap_args)
        m = re.search(r'dataModelId"?\s*[:=]\s*"?([0-9a-f-]{36})', out)
        if not m:
            sys.exit("FATAL: could not parse dataModelId from post_dm.py output")
        dm = m.group(1)
    import yaml
    dmspec = yaml.safe_load(sigma("GET", f"/v2/dataModels/{dm}/spec"))
    dm_readback_path = os.path.join(wd, "dm-readback.json")
    with open(dm_readback_path, "w") as handle:
        json.dump(dmspec, handle, indent=2)
        handle.write("\n")
    els = [e for pg in dmspec.get("pages", []) for e in (pg.get("elements") or [])]
    denorm = next((e for e in els if (e.get("name") or "").endswith(" View")), None) \
        or max(els, key=lambda e: len(e.get("columns") or []))
    # Resolvable display name (mirrors sigma-ids.ts elementName fallback):
    # explicit `name`, else warehouse path tail, else "Custom SQL" for sql
    # elements — never KeyError on a nameless element.
    src = denorm.get("source") or {}
    denorm_name = denorm.get("name") \
        or ((src.get("path") or [None])[-1]) \
        or ("Custom SQL" if src.get("kind") == "sql" else denorm["id"])
    print(f"   DM {dm} · denorm '{denorm_name}' ({denorm['id']}, "
          f"{len(denorm.get('columns') or [])} cols) · {len(els)} element(s)")

    # ── Phase 4a.6 — Materialize expensive derived tables (opt-in) ────────────
    # Custom-SQL elements ARE the ported derived tables. --materialize-derived
    # triggers a Sigma materialization so runtime queries hit a stored table
    # instead of re-running the (possibly nested-CTE) SQL. The recurring SCHEDULE
    # is UI-only; the API only triggers/monitors — so a not-yet-configured element
    # degrades to a precise UI handoff, never a silent failure. (perf_findings
    # was gathered in Phase 2b, which runs before this on every path.)
    if a.materialize_derived != "off":
        sql_els = [e for e in els if (e.get("source") or {}).get("kind") == "sql"]
        if a.materialize_derived == "auto" and perf_findings:
            want = {re.sub(r"[^a-z0-9]", "", (f["view"] or "").lower())
                    for f in perf_findings if f.get("recommendation") == "materialize"}
            targets = [e for e in sql_els
                       if re.sub(r"[^a-z0-9]", "", (e.get("name") or "").lower()) in want] or sql_els
        else:  # "all"
            targets = sql_els
        if not targets:
            print("   --materialize-derived: no Custom-SQL (derived-table) elements in this DM")
        else:
            # Sigma's API only TRIGGERS an already-configured materialization; the
            # recurring schedule is created in the UI (verified: :materialize on an
            # unscheduled element returns 400 "Scheduled materialization is not
            # configured for this element"). So this triggers where a schedule
            # exists and otherwise emits a precise, per-element UI handoff.
            print(f"   --materialize-derived {a.materialize_derived}: {len(targets)} derived "
                  "element(s). Sigma triggers a materialization only where a schedule already "
                  "exists (schedule creation is UI-only):")
            actions = []
            for e in targets:
                eid = e["id"]; ename = e.get("name") or eid
                try:
                    res = json.loads(sigma("POST", f"/v2/dataModels/{dm}:materialize",
                                           {"sheetId": eid}) or "{}")
                    mid = res.get("materializationId")
                    print(f"     ✓ {ename}: triggered (materializationId={mid}) — runs async")
                    actions.append({"element": ename, "id": eid, "status": "triggered",
                                    "materializationId": mid})
                except RuntimeError as ex:
                    msg = str(ex)
                    if "not configured" in msg or "not_permitted" in msg:
                        print(f"     • {ename}: no schedule yet → in Sigma open this element's "
                              "⋮ → Materialization and set a cadence matching the old Looker "
                              "datagroup; it then materializes on that schedule.")
                        status = "needs-ui-schedule"
                    else:
                        print(f"     ⚠ {ename}: trigger failed — {msg[:140]}")
                        status = "error"
                    actions.append({"element": ename, "id": eid, "status": status, "error": msg[:200]})
            json.dump(actions, open(os.path.join(wd, "materialization-actions.json"), "w"), indent=2)
            print("   ↪ then rank which materializations pay off by warehouse credit with the "
                  "sigma-materialization-advisor skill (post-migration, credit-based).")

    # ── Phase 4a.5 — shape preflight (REUSE only) ────────────────────────────
    # Mechanical reuse gate for the failure modes a spec POST won't catch and that
    # otherwise ship silently: a hidden (visibleAsSource:false) element, missing
    # columns, and relationship FAN-OUT. Only meaningful when reusing a DM we did
    # NOT just build (a freshly-converted DM's elements are visible and 1:1 by
    # construction). The orchestrator can't run ad-hoc SQL, so fan-out relationships
    # are SURFACED with the exact Sigma-MCP query (--ack-fanout); visibility hard-fails.
    # The agent path (SKILL.md Phase 2.5) runs the emitted queries to confirm 1:1.
    if a.reuse_dm:
        pf_out = os.path.join(wd, "shape-preflight.json")
        rc_pf, _ = run(["ruby", os.path.join(HERE, "shape-preflight.rb"),
                        "--dm-id", dm, "--element", denorm_name,
                        "--ack-fanout", "--out", pf_out], check=False)
        try:
            pf = json.load(open(pf_out))
            for r in pf.get("relationships", []):
                q = (r.get("uniqueness_query") or {}).get("sql")
                print(f"   ↳ verify 1:1 (reuse): relationship '{r['name']}' → "
                      f"'{r.get('target_element')}' — run via Sigma MCP query: {q}")
        except Exception:
            pass
        if rc_pf == 2:
            sys.exit("FATAL: shape-preflight failed (hidden element / missing columns on the "
                     "reuse element) — see shape-preflight.json. Wire to a visible element or fix "
                     "coverage before reusing.")

    # ── Phase 4b — Build + POST the workbook (layout XML inline) ─────────────
    hdr(4, TOTAL, "Build workbook (4b)")
    wb_spec_path = os.path.join(wd, "wb-spec.json")
    # Full DATA-MODEL element catalog (id+name) → one master per explore for
    # multi-explore dashboards. Data-model specs intentionally retain
    # pages[].elements; the workbook-only flat-element rule does not apply here.
    # dashboards (each explore matched to its DM element by normalized name).
    dm_els_path = os.path.join(wd, "dm-elements.json")
    # Attach each element's REFERENCEABLE DM metrics (name + formula) so build_workbook can
    # emit a governed [Metrics/<name>] reference instead of re-deriving the aggregation inline
    # (matched by formula equivalence; falls back to inline when there's no match). Metrics
    # are inherited through the `source.elementId` chain: a denorm "<X> View" element carries
    # 0 own metrics but inherits its base fact's — Sigma exposes them and they resolve as
    # [Metrics/<name>] on the denorm (verified live). So resolve the chain, deduped by name.
    _by_id = {e["id"]: e for e in els}

    def _avail_metrics(eid, seen=None):
        seen = seen if seen is not None else set()
        e = _by_id.get(eid)
        if not e or eid in seen:
            return []
        seen.add(eid)
        own = [{"name": m.get("name"), "formula": m.get("formula")}
               for m in (e.get("metrics") or []) if m.get("name") and m.get("formula")]
        return own + _avail_metrics((e.get("source") or {}).get("elementId"), seen)

    def _dedup(ms):
        seen, out = set(), []
        for m in ms:
            if m["name"] not in seen:
                seen.add(m["name"])
                out.append(m)
        return out

    json.dump([{"id": e["id"], "name": e.get("name")
                or ((e.get("source") or {}).get("path") or [None])[-1],
                "metrics": _dedup(_avail_metrics(e["id"]))}
               for e in els], open(dm_els_path, "w"))
    # Use --flag=value for ids: Sigma-reassigned element ids can start with '-'
    # (e.g. "-BGy34L4Yj"), which argparse otherwise mis-reads as a flag.
    wb_args = [sys.executable, os.path.join(HERE, "build_workbook.py"), contract_path,
               "--views", views_dir, f"--dm-id={dm}", f"--element-id={denorm['id']}",
               f"--dm-element-name={denorm_name}", f"--dm-elements={dm_els_path}",
               f"--folder-id={folder}", f"--out={wb_spec_path}"]
    if os.path.exists(dynamic_params_path):
        wb_args += ["--dynamic-parameters", dynamic_params_path]
    run(wb_args)
    hazard_rc, _ = run(
        [sys.executable, os.path.join(HERE, "detect_modeling_hazards.py"),
         "--workdir", wd, "--contract", contract_path,
         "--dm-spec", dm_spec_path, "--wb-spec", wb_spec_path],
        check=False,
    )
    if hazard_rc:
        sys.exit(
            "FATAL: modeling-hazard gate blocked workbook POST. Inspect "
            f"{os.path.join(wd, 'modeling-hazards.json')}; replace unsafe aggregate "
            "relationships/windows with an explicit-grain or Custom SQL implementation, "
            "or record a justified resolution with detect_modeling_hazards.py --resolve."
        )
    wspec = json.load(open(wb_spec_path))
    wspec["name"] = f"{prefix}{dash['title']} (from Looker)"
    preflight_rc, _ = run(
        ["ruby", os.path.join(HERE, "lib", "preflight_lint.rb"), wb_spec_path],
        check=False,
    )
    if preflight_rc:
        sys.exit("FATAL: workbook preflight failed; no workbook write attempted")

    try:
        dm_columns = list_entries(
            lambda path: json.loads(sigma("GET", path)),
            f"/v2/dataModels/{dm}/columns",
        )
    except (RuntimeError, ValueError, json.JSONDecodeError) as exc:
        sys.exit(f"FATAL: could not paginate live DM columns for pre-write ref check: {exc}")
    ref_failures = validate_workbook_refs(
        wspec,
        {"pages": [{"elements": els}]},
        dm_columns,
    )
    if ref_failures:
        print("\n================ WORKBOOK REFERENCE GATE ================", file=sys.stderr)
        for failure in ref_failures[:30]:
            print(" - " + failure, file=sys.stderr)
        sys.exit(
            f"FATAL: {len(ref_failures)} workbook reference(s) are stale or unresolved; "
            "no workbook write attempted"
        )

    write_base_path = os.path.join(wd, "wb-write-base.json")
    try:
        # Builder output is already a current workbook envelope. Re-wrapping via
        # CodeRep is deliberate: it tolerates legacy local artifacts while
        # preserving outer metadata and the full current document collections.
        post_body = code_rep.wrap(code_rep.document(wspec), code_rep.metadata(wspec))
        if a.update_workbook:
            remote = json.loads(sigma("GET", f"/v2/workbooks/{a.update_workbook}/spec"))
            saved_base = (json.load(open(write_base_path))
                          if os.path.exists(write_base_path) else None)
            if remote_drifted(saved_base, remote) and not a.force_overwrite:
                sys.exit(
                    "FATAL: concurrent-edit guard: the live workbook changed since the "
                    "last readback. Pull/reconcile it or pass --force-overwrite explicitly."
                )
            if remote_drifted(saved_base, remote) and a.force_overwrite:
                with open(os.path.join(wd, "write-conflicts.jsonl"), "a") as handle:
                    handle.write(json.dumps({
                        "workbookId": a.update_workbook,
                        "saved": saved_base,
                        "remote": fingerprint(remote),
                        "resolution": "force-overwrite",
                    }) + "\n")
            json.dump(fingerprint(remote), open(write_base_path, "w"), indent=2)
            resp = sigma("PUT", f"/v2/workbooks/{a.update_workbook}/spec", post_body)
            wb = a.update_workbook
        else:
            # Keep the create payload wrapped immediately at the call site. The
            # update branch above performs extra drift checks, but both writes
            # must send the current document envelope.
            post_body = code_rep.wrap(code_rep.document(wspec), code_rep.metadata(wspec))
            resp = sigma("POST", "/v2/workbooks/spec", post_body)   # responds in YAML
            match = re.search(r"workbookId[\"'\s:]+([0-9a-f-]{36})", resp)
            if not match:
                sys.exit("FATAL: workbook POST: " + resp[:300])
            wb = match.group(1)
    except RuntimeError as e:
        msg = str(e)
        dep = re.search(r"Dependency not found: '([^']+)'", msg)
        if dep:
            sys.exit(
                f"FATAL: workbook POST rejected — missing DM column '{dep.group(1)}'. "
                f"A tile references a data-model column the converter did not emit "
                f"(e.g. an unconverted dimension/measure, or a join column not denormalized "
                f"onto the explore element). Inspect the spec at {wb_spec_path} and the DM "
                f"element columns; the offending tile field should be dropped or the converter "
                f"gap fixed — never POST past it.")
        sys.exit(f"FATAL: workbook write failed: {msg[:400]}")
    if not a.update_workbook:
        with open(os.path.join(wd, "posted-workbooks.jsonl"), "a") as f:
            f.write(json.dumps({"id": wb, "name": wspec["name"]}) + "\n")
    with open(os.path.join(wd, "workbook-writes.jsonl"), "a") as handle:
        handle.write(json.dumps({
            "id": wb,
            "name": wspec["name"],
            "method": "PUT" if a.update_workbook else "POST",
        }) + "\n")
    json.dump({"workbookId": wb}, open(os.path.join(wd, "wb-ids.json"), "w"))
    readback = json.loads(sigma("GET", f"/v2/workbooks/{wb}/spec"))
    json.dump(readback, open(os.path.join(wd, "wb-readback.json"), "w"), indent=2)
    json.dump(fingerprint(readback), open(write_base_path, "w"), indent=2)
    entries = list_entries(
        lambda path: json.loads(sigma("GET", path)),
        f"/v2/workbooks/{wb}/columns",
    )
    errs = [c for c in entries if (c.get("type") or {}).get("type") == "error"]
    post_ref_failures = validate_workbook_refs(
        readback,
        {"pages": [{"elements": els}]},
        dm_columns,
    )
    if post_ref_failures:
        for failure in post_ref_failures[:30]:
            print("     stale readback ref: " + failure)
        sys.exit(
            f"FATAL: post-write readback introduced {len(post_ref_failures)} stale "
            "reference(s); inspect wb-readback.json before any further PUT"
        )
    print(f"   workbook {wb} '{wspec['name']}' · {len(entries) - len(errs)}/{len(entries)} columns resolve"
          + (f" — {len(errs)} ERROR-typed" if errs else ""))
    for c in errs[:6]:
        print(f"     [{c.get('elementId')}] {c.get('label')}: {c.get('formula')}")

    # RUN-EACH-TIME GAP-SCOUT GATE (bead beads-sigma-5l5e). Looker's converter
    # passes calc expressions through optimistically (no convert-time degrade
    # signal); a calc that has no Sigma equivalent surfaces HERE as a type=error
    # column at readback. Each such column is scout-eligible — the gap-scout must
    # ATTEMPT a Sigma translation before we accept a broken column. --yes only
    # accepts columns the scout already tried (validated or escalated); an
    # unscouted error column always stops. Recorded to the ledger by
    # scout-validate.py via lib/scout_gate.py. A 'validated' row is honored only
    # when it carries signed live-probe evidence (ScoutGate integrity, issue #458):
    # a hand-written or forged 'validated' line is treated as unvalidated (→ the
    # :escalated bucket), so the gate still blocks / requires genuine scouting.
    if errs:
        gid = lambda c: "errcol:%s/%s" % (c.get("elementId"), c.get("label"))
        gap_ids = list(dict.fromkeys(gid(c) for c in errs))
        bk = scout_gate.classify(wd, gap_ids)
        if bk["unscouted"] and not a.yes:
            print("\n==================== GAP-SCOUT REQUIRED ====================")
            print("%d of %d ERROR-typed column(s) have NOT been scouted — the gap-scout must"
                  % (len(bk["unscouted"]), len(gap_ids)))
            print("attempt a Sigma translation before a broken column ships:")
            for i in bk["unscouted"]:
                print("  --gap-id '%s'" % i)
            print("\nSpawn one gap-scout per column (scripts/gap-scout.md) with the exact --gap-id")
            print("above plus --workdir %s, then re-run, OR re-run with --yes to ship them FLAGGED." % wd)
            print("===========================================================")
            sys.exit(11)
        elif bk["unscouted"]:
            # Regression fix (gap-scout PR #153 made this a hard exit 11 that overrode
            # --yes, stalling the unattended/demo path). Under --yes the gate is ADVISORY:
            # the ERROR-typed columns ship FLAGGED in Sigma (as they did before the gate
            # existed) and the run proceeds. Record them so re-runs don't re-surface;
            # recommend the gap-scout for anyone who wants a faithful translation.
            print("\n   gap-scout: %d ERROR-typed column(s) NOT scouted — proceeding (--yes); they ship FLAGGED/broken in Sigma."
                  % len(bk["unscouted"]))
            print("   (optional: run scripts/gap-scout.md on these to persist a faithful Sigma translation)")
            for i in bk["unscouted"]:
                scout_gate.record(wd, i, "errcol", "accepted")
        else:
            print("   gap-scout: all %d error column(s) accounted for (validated or escalated)" % len(gap_ids))

    # Preliminary object accounting runs as soon as the workbook build/readback
    # is available. It is refreshed after parity and the hard gate because
    # terminal dispositions and verification evidence can change there.
    print("\n── Phase 4d · Preliminary source-object accounting ──")
    preliminary_accounting_rc = run_looker_accounting(
        wd, contract_path, wb_spec_path, "preliminary"
    )
    if preliminary_accounting_rc != 0:
        print(f"   ⚠ preliminary accounting failed (exit {preliminary_accounting_rc}); "
              "the final refresh remains mandatory")

    # ── Phase 4c — Visual QA: render each content page to a FULL-PAGE PNG ─────
    # so the layout (applied inline by build_workbook.py and POSTed above) can be
    # reviewed against refs/layout-visual-qa.md AND the source Looker dashboard —
    # matching the other migration skills' visual-QA gate. Page ids come from the
    # LOCAL wb-spec.json (deterministic; POST preserves these ids) — the live GET
    # /spec readback proved flaky inside the pipeline. SIGMA_API_TOKEN is passed
    # explicitly in the child env. Render is NON-FATAL (a transient export
    # failure must not sink a green migration); the REVIEW is the gate.
    hdr(4, TOTAL, "Visual QA (4c)")
    vqa = os.path.join(wd, "visual-qa")
    os.makedirs(vqa, exist_ok=True)
    workbook_doc = code_rep.document(wspec)
    content_pages = [pg for pg in (workbook_doc.get("pages") or [])
                     if "data" not in str(pg.get("id")).lower()]
    rendered = 0
    render_png = None  # first successful page PNG — wired to gate 8 (--sigma-render)
    for pg in content_pages:
        out = os.path.join(vqa, f"{pg['id']}.png")
        rc, _ = run([sys.executable, os.path.join(HERE, "sigma-export-png.py"),
                     "--workbook", wb, "--page", pg["id"], "--out", out,
                     "--w", "1800", "--h", "1000"],
                    env={"SIGMA_API_TOKEN": os.environ.get("SIGMA_API_TOKEN", "")},
                    check=False)
        if rc == 0:
            rendered += 1
            if render_png is None and os.path.exists(out):
                render_png = out
        else:
            print(f"   WARN: visual-QA render failed for page {pg['id']}")
    print(f"   rendered {rendered}/{len(content_pages)} full-page PNG(s) → {vqa}")
    if rendered:
        print("   VISUAL QA (review, do not skip): open each PNG; check vs "
              "refs/layout-visual-qa.md AND the source Looker dashboard — titles, "
              "right chart kinds, colors, no overlaps/dead zones.")

    # ── Phase 5 — SOURCE-FRESHNESS preflight (read BEFORE any side-by-side) ───
    hdr(5, TOTAL, "Source freshness (preflight — before parity)")
    try:
        mh, mr = parse_csv(export_csv(wb, "m-master"))
    except RuntimeError as e:
        # A CSV-export timeout here almost always means the master ended up with 0
        # columns (every tile field was dropped/unresolved upstream). Don't crash the
        # whole run with a raw stack trace — warn and skip the freshness readout so
        # the parity gate still runs and reports the real coverage problem.
        print(f"   ⚠ source-freshness export skipped: {e}")
        print("     (the master may have no resolvable columns — check the Phase-4b "
              "field-drop warnings above; parity will still run and surface it.)")
        mh, mr = [], []
    print("   ── SOURCE FRESHNESS (read this before any side-by-side) ──")
    if offline:
        newest = max((os.path.getmtime(f) for f in view_files + [a.dashboard]), default=None)
        print(f"   source                : offline .lkml files (newest mtime "
              f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(newest)) if newest else '?'}) — "
              "live Looker freshness unavailable")
    else:
        print("   source                : live Looker — tiles query the warehouse live; EXPECTED")
        print("                           below comes from Looker inline queries run NOW")
    idx = {h: i for i, h in enumerate(mh)}
    datecol = next((h for h in mh if "date" in h.lower()), None)
    line = f"   warehouse (via Sigma) : master = {len(mr)} rows"
    if datecol:
        mx = max((str(r[idx[datecol]]) for r in mr if str(r[idx[datecol]]).strip()), default="?")
        line += f", max({datecol}) = {mx}"
    print(line)
    print("   (Looker is live-query: a parity delta is a CONVERSION issue, not cache staleness.)")

    # ── Phase 6 — Parity (two-pass, scripted) + HARD GATE ────────────────────
    hdr(6, TOTAL, "Parity + hard gate")
    rc, _ = run(["ruby", os.path.join(HERE, "phase6-parity-looker.rb"),
                 "--workdir", wd, "--workbook-id", wb], check=False)
    if rc != 0:
        sys.exit("FATAL: parity pass 1 failed")
    plan = json.load(open(os.path.join(wd, "parity-plan.json")))
    by_name = {e.get("name"): e for e in dash["elements"]}
    ev = SourceEval(measures, view_pk, explore, mh)
    expected, actuals = {}, {}

    # Both fetch sides are per-chart and independent — fan them out N-wide
    # (default 4; LOOKER_PARITY_WORKERS overrides, e.g. =1 on a loaded
    # warehouse). The Sigma CSV exports and the Looker inline queries are each
    # network-bound; 4 concurrent queries is a modest, warehouse-friendly burst.
    # looker_api's token cache is thread-safe (one shared login).
    def parity_fetch(c):
        cname = c["chart"]
        msgs = []
        headers, rows = parse_csv(export_csv(wb, c["sigma_element_id"]))
        cidx = {h: i for i, h in enumerate(headers)}
        want = c["sigma_columns"]
        if c.get("kind") == "table-total":
            # A table-only Look → grand-total check: SUM the additive column over
            # every displayed (grouped/pivot) row = the overall total (grain-
            # invariant). EXPECTED = the same grand total of the tile's first
            # measure from Looker (live) / the warehouse re-aggregation (offline).
            def _num(x):
                v = numify(x)
                return v if isinstance(v, (int, float)) else None
            if c.get("source_kind") == "pivot-table":
                # A pivot CSV is a cross-tab: line 0 is a meta row, `headers` is the
                # value/pivot-dim names, the first data row is the real column header
                # (rowDim, pivotVals…, "Total"), and Sigma appends a grand-Total row
                # (first cell "Total") whose last cell is the grand total. Prefer that;
                # else sum the body cells excluding the Total row + Total column.
                colhdr = rows[0] if rows else []
                tot_cols = {i for i, h in enumerate(colhdr) if str(h).strip().lower() == "total"}
                trow = next((r for r in rows if r and str(r[0]).strip().lower() == "total"), None)
                gt = None
                if trow:
                    tail = [_num(trow[i]) for i in sorted(tot_cols) if i < len(trow)]
                    tail = [n for n in tail if n is not None] or [n for n in map(_num, trow) if n is not None]
                    gt = tail[-1] if tail else None
                if gt is None:
                    gt = sum(n for r in rows[1:] if not (r and str(r[0]).strip().lower() == "total")
                             for i, cc in enumerate(r) if i not in tot_cols
                             for n in [_num(cc)] if n is not None)
                act = [[None, gt if gt is not None else 0]]
            else:
                # grouped table: a single named value column, no auto-total row → sum it
                vi = cidx.get(want[0], 0)
                act = [[None, sum(n for r in rows if vi < len(r)
                                  for n in [_num(r[vi])] if n is not None)]]
            el = by_name.get(cname)
            if el is None:
                msgs.append(f"   WARN: no source tile named {cname!r} in the contract — will DIVERGE")
                return cname, act, None, msgs
            exp = None
            try:
                rowsexp = None
                if not offline:
                    rowsexp = expected_live(el, measures)
                if rowsexp is None:
                    rowsexp = expected_offline(el, ev, mr)
                exp = [[None, sum(numify(v) for _d, v in rowsexp if v is not None)]]
            except Exception as ex:
                msgs.append(f"   WARN: table-total expected fetch failed for {cname!r} ({ex})")
            return cname, act, exp, msgs
        if len(want) == 1:                      # KPI
            vi = cidx.get(want[0], 0)
            act = [[None, numify(rows[0][vi])]] if rows else []
        else:
            di = cidx.get(want[0], 0)
            vi = cidx.get(want[1], 1 if len(headers) > 1 else 0)
            act = [[row[di], numify(row[vi])] for row in rows]
        el = by_name.get(cname)
        want_label = None
        if not el and " · " in cname:
            # measure-only grid split into KPI tiles "<tile> · <Measure Label>"
            base_name, want_label = cname.rsplit(" · ", 1)
            el = by_name.get(base_name)
        if not el:
            msgs.append(f"   WARN: no source tile named {cname!r} in the contract — chart will DIVERGE")
            return cname, act, None, msgs
        exp = None
        if not offline:
            try:
                exp = expected_live(el, measures, want_label)
            except Exception as ex:
                msgs.append(f"   WARN: Looker inline query failed for {cname!r} ({ex}); "
                            "falling back to warehouse re-aggregation")
        if exp is None:
            exp = expected_offline(el, ev, mr)
        return cname, act, exp, msgs

    workers = max(1, min(4, int(os.environ.get("LOOKER_PARITY_WORKERS", "4") or 4),
                         len(plan["charts"])))
    t_par = time.time()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(parity_fetch, plan["charts"]))
    for cname, act, exp, msgs in results:
        for m in msgs:
            print(m)
        actuals[cname] = act
        if exp is not None:
            expected[cname] = exp
    print(f"   fetched expected+actual for {len(plan['charts'])} chart(s) "
          f"{workers}-wide in {time.time() - t_par:.1f}s")
    json.dump(expected, open(os.path.join(wd, "parity-expected.json"), "w"), indent=2)
    json.dump(actuals, open(os.path.join(wd, "parity-actuals.json"), "w"), indent=2)
    rc, _ = run(["ruby", os.path.join(HERE, "phase6-parity-looker.rb"),
                 "--workdir", wd, "--finalize"], check=False)
    # Refresh canonical accounting after parity has supplied terminal evidence
    # and before the hard gate derives/stamps its degradation verdict.
    pre_gate_accounting_rc = run_looker_accounting(
        wd, contract_path, wb_spec_path, "final"
    )
    gate_cmd = ["ruby", os.path.join(HERE, "assert-phase6-ran.rb"),
                "--workdir", wd, "--workbook-id", wb,
                # Opt into gate 7b (runtime control flip test). Gate 7's static
                # control lint checks the spec against a builder-derived
                # control-scope.json sidecar — it cannot catch a builder-level
                # listen->column mis-mapping (spec + sidecar agree). Gate 7b
                # flips each control live (probe-controls.rb) and proves its
                # targets change. Looker is the first adopter; other converters
                # are unaffected until they pass this flag too.
                "--require-control-flip"]
    # Wire the Phase-4c render to gate 8 (visual render). We render to
    # visual-qa/<pageId>.png, but the gate defaults to looking for
    # <workdir>/sigma-render.png — without this the gate never finds the PNG and
    # every migration fails gate 8 despite a clean render.
    if render_png and os.path.exists(render_png):
        gate_cmd += ["--sigma-render", render_png]
    grc, _ = run(gate_cmd, check=False)
    summary = json.load(open(os.path.join(wd, "parity-final.json")))

    # ── Parity-RED triage (POSTMORTEM 2026-06-18 #4) ─────────────────────────
    # When the gate is RED, tell the operator WHY without hand-math: compute the
    # per-chart actual/expected ratio of total magnitude. If the ratios cluster
    # tightly around a common multiplier (≠1), the conversion is faithful and the
    # two warehouses just hold different data volumes — a SCALE mismatch, not a
    # conversion bug. Divergent ratios point at a real conversion error.
    if grc != 0:
        def total(rows):
            return sum(v for _, v in (rows or []) if isinstance(v, (int, float)))
        ratios = []
        for cname in expected:
            e, ac = total(expected.get(cname)), total(actuals.get(cname))
            if e and ac:
                ratios.append((cname, ac / e))
        if ratios:
            print("\n   ── PARITY-RED TRIAGE (ratio analysis) ──")
            for cname, r in ratios:
                print(f"     {r:6.3f}×  {cname}")
            # Two-cluster signature of a SCALE mismatch (not a conversion bug):
            # ratio-type measures (AOV, margin %) are scale-invariant → cluster at
            # ~1.0×; additive measures (revenue, counts) scale with data volume →
            # cluster at a common N×. So split, don't just measure overall spread.
            near_one = [r for _, r in ratios if abs(r - 1.0) <= 0.05]
            scaled = [r for _, r in ratios if abs(r - 1.0) > 0.05]
            scaled_spread = (max(scaled) / min(scaled)) if scaled and min(scaled) else None
            if not scaled:
                print("   ⇒ every chart matches within ±5% yet the strict gate is RED — the delta is")
                print("     row-level / ordering / formatting, not magnitude. Inspect parity-final.json.")
            elif scaled_spread is not None and scaled_spread <= 1.15:
                mult = statistics.median(scaled)
                tail = (f"; {len(near_one)} ratio-measure(s) stay ~1.0× as expected"
                        if near_one else "")
                print(f"   ⇒ additive measures cluster at ~{mult:.2f}× (spread {scaled_spread:.2f}×, ≤1.15)"
                      f"{tail}.")
                print("     This is the signature of a DATASET-SCALE mismatch — same formulas over a")
                print("     larger/smaller table — NOT a conversion bug. Confirm both sides point at the")
                print("     SAME warehouse schema (LookML sql_table_name vs the Sigma connection; see")
                print("     --source-swap).")
            else:
                print(f"   ⇒ scaled ratios DIVERGE (spread {scaled_spread:.2f}× > 1.15) — no consistent")
                print("     multiplier, so this is likely a REAL conversion error on the outlier")
                print("     chart(s), not just a data-volume difference. Investigate those tiles.")

    # ── Final accounting + completion report (all terminal paths) ─────────────
    # The report is deliberately generated after the parity/assert gate on both
    # green and non-green runs. A RED report or a failed accounting/report
    # command is itself migration failure, even when the legacy gate was green.
    print("\n── Completion accounting + migration report ──")
    final_accounting_rc = run_looker_accounting(
        wd, contract_path, wb_spec_path, "final"
    )
    ledger_rc = refresh_degradation_ledger(wd)
    render_health = derive_render_health(wd, render_png)
    report_rc, _ = run(
        ["ruby", os.path.join(HERE, "build-migration-report.rb"),
         "--workdir", wd,
         "--inventory", os.path.join(wd, "source-object-census.json")],
        check=False,
    )
    report = {}
    try:
        report = json.load(open(os.path.join(wd, "migration-result.json")))
    except Exception:
        pass
    report_verdict = str(report.get("verdict") or "MISSING").upper()
    print(f"   migration report: {report_verdict} "
          f"({report.get('summary', {}).get('accounted', 0)}/"
          f"{report.get('summary', {}).get('total', 0)} accounted)")

    # ── Summary ────────────────────────────────────────────────────────────────
    green = (grc == 0 and not errs and pre_gate_accounting_rc == 0 and
             final_accounting_rc == 0 and ledger_rc == 0 and
             report_rc == 0 and report_verdict != "RED" and
             str(render_health.get("status") or "").upper() == "PASS")
    print("\n================ RESULT ================")
    print(f"dataModelId : {dm}{'  (REUSED)' if a.reuse_dm else ''}")
    print(f"workbookId  : {wb}  '{wspec['name']}'")
    print(f"parity      : {summary['charts_pass']}/{summary['charts_total']} {summary['status']} · "
          f"hard gate {'PASS' if grc == 0 else f'FAIL (exit {grc})'}")
    print(f"accounting  : {'PASS' if final_accounting_rc == 0 else f'FAIL (exit {final_accounting_rc})'}")
    print(f"ledger      : {'PASS' if ledger_rc == 0 else f'FAIL (exit {ledger_rc})'}")
    print(f"report      : {report_verdict}"
          + ("" if report_rc == 0 else f" · FAIL (exit {report_rc})"))
    if findings:
        print(f"RLS         : {len(findings)} finding(s) NOT ported (recorded in rls-findings.json)")
    print(f"PARITY      : {'GREEN' if green else 'RED'}  ·  wall-clock {time.time() - T0:.1f}s")
    print("========================================")
    return 0 if green else 2


if __name__ == "__main__":
    sys.exit(main())
