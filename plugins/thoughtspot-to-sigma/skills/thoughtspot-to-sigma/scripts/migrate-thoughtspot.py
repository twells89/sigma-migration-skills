#!/usr/bin/env python3
"""migrate-thoughtspot.py — ONE-COMMAND orchestrator for the thoughtspot-to-sigma
pipeline: discover → DM-reuse check → convert → data model → workbooks → layout
→ source-freshness preflight → scripted parity + HARD GATE. Mirrors
qlik-to-sigma's migrate-qlik.rb: every phase prints a visible header + concise
result, decision points are flags with safe defaults (never silent), and the
parity gate is NEVER bypassed — the command FAILS if a gate fails.

This script does NOT re-implement any phase — it chains the per-phase scripts:
  ts_discover.py / ts_lib.py        (Phase 1 — TML export + freshness metadata)
  ts-dm-signature.py + find-or-pick-dm.rb
                                    (Phase 2 — DM-reuse check: candidates+scores
                                     PRINTED, default = build new; reuse only on
                                     an explicit --reuse-dm <id>)
  migrate.py                        (Phase 3 — convert [CONVERTER_PATH one-shot,
                                     or the exit-3 MCP-request/--converted resume]
                                     → DM POST + denorm readback → Liveboard →
                                     workbook build → TML-geometry layout)
  Phase 4 — post-and-readback gate: live /columns scan (no type=error)
  Phase 5 — SOURCE-FRESHNESS preflight (fmte): TS model/Liveboard modified time
            + a cheap searchdata row/aggregate probe (when TS is reachable, else
            noted unavailable) vs a live warehouse snapshot via the master
            element — printed BEFORE any side-by-side so staleness never
            masquerades as a conversion bug.
  phase6-parity-thoughtspot.rb      (Phase 6 — two-pass parity, fully scripted:
                                     ACTUAL = Sigma CSV export per chart;
                                     EXPECTED = ts_lib.searchdata ground truth
                                     when live, or a source-TML-derived
                                     re-aggregation of the master's warehouse
                                     rows when offline) + verify-parity.rb
  assert-phase6-ran.rb              (HARD GATE — must exit 0 to declare GREEN)

Usage (live):
  python3 scripts/migrate-thoughtspot.py --model <TS_MODEL_ID> \
      [--liveboard <ID> ...] [--name PREFIX] [--workdir DIR]
Usage (offline — fixtures/, no TS instance):
  python3 scripts/migrate-thoughtspot.py --model-tml fixtures/retail-analytics-model.tml \
      --liveboard-tml fixtures/retail-analytics-liveboard.tml [--name PREFIX] [--workdir DIR]
Resume after the MCP converter fallback (exit 3):
  ... same command ... --converted <workdir>/converted.json
Other flags:
  --reuse-dm <dataModelId>   reuse an existing DM (skip convert+POST) — the
                             Phase-2 check prints candidates; reuse is NEVER
                             chosen silently, only via this flag
  --skip-dm-reuse-check      skip the Phase-2 scan entirely
  --dry-run                  no Sigma POSTs: discovery + DM-reuse scan + local
                             convert (or the MCP convert-request) only

Env: TS_HOST/TS_TOKEN (live mode), SIGMA_BASE_URL + SIGMA_API_TOKEN (or
SIGMA_CLIENT_ID/SECRET via ~/.sigma-migration/env — the script mints a token),
SIGMA_CONNECTION_ID, TS_DB, TS_SCHEMA, optional SIGMA_FOLDER_ID (auto-resolved
and PRINTED when unset), optional CONVERTER_PATH (auto-located).

Exit codes: 0 = done, all gates GREEN; 3 = MCP convert request emitted (resume
with --converted); 2 = built but a parity/hard gate FAILED; other = error.
"""
import argparse, csv, io, json, os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yaml, ts_common
import migrate  # the per-phase pipeline (sigma() REST helper reused)

HERE = os.path.dirname(os.path.abspath(__file__))
# Zero-config converter: a self-contained ESM bundle ships in the skill at
# converter/thoughtspot.mjs (no clone, no npm, no network, no MCP). Default
# CONVERTER_PATH to it so local conversion is the out-of-the-box path; an explicit
# CONVERTER_PATH (a dev's fresher build) still wins. Inherited by migrate.py +
# convert_model.mjs, which gate local-vs-MCP on this var.
_VENDORED_CONV = os.path.join(HERE, "..", "converter", "thoughtspot.mjs")
if not os.environ.get("CONVERTER_PATH") and os.path.exists(_VENDORED_CONV):
    os.environ["CONVERTER_PATH"] = _VENDORED_CONV
T0 = time.time()


def hdr(n, total, title):
    print(f"\n── Phase {n}/{total} · {title} ──")


def elapsed():
    return f"{time.time() - T0:.1f}s"


def run(cmd, env=None, check=True):
    """Run a child script, streaming output indented. Returns (rc, captured)."""
    p = subprocess.run(cmd, capture_output=True, text=True,
                       env={**os.environ, **(env or {})})
    out = (p.stdout or "") + (p.stderr or "")
    for line in out.splitlines():
        print("   " + line)
    if check and p.returncode != 0:
        sys.exit(f"FATAL: command failed ({p.returncode}): {' '.join(cmd)}")
    return p.returncode, out


def ensure_sigma_env(workdir=None):
    """Make the command truly one-command: load ~/.sigma-migration/env and mint a
    bearer when SIGMA_API_TOKEN isn't already exported.

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


def resolve_folder():
    """SIGMA_FOLDER_ID is a decision point — auto-resolve with a PRINTED default
    (prefers a THOUGHTSPOT/MIGRATION/TEST folder) rather than silently failing."""
    if os.environ.get("SIGMA_FOLDER_ID"):
        return os.environ["SIGMA_FOLDER_ID"]
    files = json.loads(migrate.sigma("GET", "/v2/files?typeFilters=folder&limit=200"))
    entries = files.get("entries") or []
    pick = next((f for f in entries
                 if any(k in (f.get("name") or "").upper()
                        for k in ("THOUGHTSPOT", "MIGRATION", "TEST"))),
                entries[0] if entries else None)
    if not pick:
        sys.exit("FATAL: no writable folder found — set SIGMA_FOLDER_ID")
    os.environ["SIGMA_FOLDER_ID"] = pick["id"]
    print(f"   no SIGMA_FOLDER_ID supplied — using folder '{pick.get('name')}' ({pick['id']})")
    return pick["id"]


# ── Sigma CSV export (ACTUAL side of parity + the warehouse freshness probe) ──
def export_csv(wb_id, element_id, timeout=240, retries=1):
    """One slow export usually means warehouse/org saturation, not a broken
    element — pause once and retry before failing the whole run (never hammer:
    a single retry, with a cool-down, then a hard error)."""
    for attempt in range(retries + 1):
        res = json.loads(migrate.sigma("POST", f"/v2/workbooks/{wb_id}/export",
                                       {"elementId": element_id, "format": {"type": "csv"}}))
        qid = res["queryId"]
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                body = migrate.sigma("GET", f"/v2/query/{qid}/download")
                if body and body.strip():
                    return body
            except RuntimeError:
                pass
            time.sleep(2)
        if attempt < retries:
            print(f"   WARN: CSV export of {element_id} timed out after {timeout}s — "
                  f"cooling down 60s, then retrying once (saturation guard)")
            time.sleep(60)
    raise RuntimeError(f"CSV export of element {element_id} timed out")


def parse_csv(body):
    rows = list(csv.reader(io.StringIO(body)))
    return (rows[0], rows[1:]) if rows else ([], [])


def numify(v):
    s = str(v).strip().replace("$", "").replace(",", "").replace("%", "")
    try:
        return float(s)
    except ValueError:
        return v


# ── EXPECTED side, derived from the SOURCE TML (independent of the builder) ──
TS_AGG = {"SUM": lambda vs: sum(vs),
          "AVERAGE": lambda vs: (sum(vs) / len(vs)) if vs else None,
          "MIN": lambda vs: min(vs) if vs else None,
          "MAX": lambda vs: max(vs) if vs else None,
          "COUNT": lambda vs: len(vs),
          "COUNT_DISTINCT": lambda vs: len(set(vs))}


def viz_specs_with_aggs(lb_tml_path, resolver=None):
    """Parse a Liveboard TML → ({viz name: {spec, aggs}}, liveboard_guid). The
    per-measure agg comes from the TML's own table_columns[].headline_aggregation
    (default SUM) — the SOURCE definition, not the built Sigma formula, so a
    builder bug diverges."""
    doc = yaml.safe_load(open(lb_tml_path).read())
    lb_guid = doc.get("guid")
    lb = doc["liveboard"]
    out = {}
    for v in lb["visualizations"]:
        spec = ts_common.parse_ts_viz(v, resolver)
        if not spec:
            continue
        aggs = {}
        for tc in ((v.get("answer") or {}).get("table") or {}).get("table_columns") or []:
            base = ts_common._strip_total(tc.get("column_id", ""))
            if tc.get("headline_aggregation"):
                aggs[base] = tc["headline_aggregation"].upper()
        out[spec["name"]] = {"spec": spec, "aggs": aggs}
    return out, lb_guid


def expected_offline(spec, aggs, resolver, headers, rows):
    """Re-aggregate the master element's warehouse rows per the SOURCE viz spec."""
    fr = lambda base: ts_common._resolve(resolver, base)["friendly"]
    idx = {h: i for i, h in enumerate(headers)}
    data = rows
    for f in spec.get("filters", []):
        col = idx.get(fr(f["col"]))
        if col is None:
            continue
        vals = {str(x).casefold() for x in f["values"]}
        keep = (lambda r: str(r[col]).casefold() in vals) if f["mode"] == "include" \
            else (lambda r: str(r[col]).casefold() not in vals)
        data = [r for r in data if keep(r)]
    meas = spec["measures"][0]
    mcol = idx.get(fr(meas))
    if mcol is None:
        return None
    agg = TS_AGG.get(aggs.get(meas, "SUM"), TS_AGG["SUM"])
    mvals = lambda rs: [numify(r[mcol]) for r in rs if str(r[mcol]).strip() != ""]
    if not spec["dims"]:
        return [[None, agg(mvals(data))]]
    dcol = idx.get(fr(spec["dims"][0]))
    if dcol is None:
        return None
    groups = {}
    for r in data:
        groups.setdefault(r[dcol], []).append(r)
    return [[d, agg(mvals(rs))] for d, rs in groups.items()]


def expected_live(spec, model_id):
    """Ground truth from ThoughtSpot itself: run the viz's search tokens through
    searchdata against the model. Only the x dim is queried (a color/series dim
    would change the grain — parity compares per-x totals); `top N` tokens ride
    along so top-N tiles compare the same row set."""
    import ts_lib
    q = " ".join(f"[{c}]" for c in spec["dims"][:1] + spec["measures"])
    if spec.get("topn"):
        q += f" top {spec['topn']}"
    for f in spec.get("filters", []):
        q += f" [{f['col']}] {'=' if f['mode'] == 'include' else '!='} " + \
             " ".join(f"'{v}'" for v in f["values"])
    res = ts_lib.searchdata(q, model_id)
    names = res["column_names"]
    drows = res["data_rows"]
    if not spec["dims"]:
        return [[None, numify(drows[0][0])]] if drows else None
    didx = names.index(spec["dims"][0]) if spec["dims"][0] in names else 0
    meas = spec["measures"][0]
    vidx = next((names.index(n) for n in (f"Total {meas}", f"Average {meas}", meas) if n in names),
                len(names) - 1)
    return [[r[didx], numify(r[vidx])] for r in drows]


def expected_from_lbdata(lb_guid, spec, _cache={}):
    """Ground truth for tiles whose dim/measure is an ANSWER-level formula —
    searchdata can't express those, but metadata/liveboard/data returns the
    tile's own rows as ThoughtSpot renders them."""
    import ts_lib
    if lb_guid not in _cache:
        _cache[lb_guid] = ts_lib._req("metadata/liveboard/data", {
            "metadata_identifier": lb_guid, "data_format": "COMPACT", "record_size": 1000})
    tiles = (_cache[lb_guid] or {}).get("contents", [])
    t = next((t for t in tiles if (t.get("visualization_name") or "") == spec["name"]), None)
    if not t:
        return None
    names = [c["name"] if isinstance(c, dict) else c for c in (t.get("column_names") or [])]
    rows = t.get("data_rows") or []
    if not spec["dims"]:
        return [[None, numify(rows[0][0])]] if rows else None
    def col_idx(cands):
        return next((names.index(c) for c in cands if c in names), None)
    didx = col_idx([spec["dims"][0]])
    meas = spec["measures"][0]
    vidx = col_idx([f"Total {meas}", f"Average {meas}", meas])
    if didx is None or vidx is None:
        return None
    groups, order = {}, []
    for r in rows:
        d = r[didx]
        d = None if (d is None or str(d).strip() == "") else d
        val = numify(r[vidx])
        if d in groups and isinstance(groups[d], float) and isinstance(val, float):
            groups[d] += val
        else:
            if d not in groups:
                order.append(d)
            groups[d] = val
    return [[d, groups[d]] for d in order]


def scan_modified(obj):
    """Best-effort: find a 'modified' epoch-ms anywhere in a metadata entry."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k.lower() in ("modified", "modified_ts", "last_modified") and isinstance(v, (int, float)) and v > 1e12:
                return time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(v / 1000))
            r = scan_modified(v)
            if r:
                return r
    elif isinstance(obj, list):
        for it in obj:
            r = scan_modified(it)
            if r:
                return r
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    ap.add_argument("--model-tml")
    ap.add_argument("--liveboard", action="append")
    ap.add_argument("--liveboard-tml", action="append")
    ap.add_argument("--name")
    ap.add_argument("--workdir")
    ap.add_argument("--converted")
    ap.add_argument("--reuse-dm")
    ap.add_argument("--skip-dm-reuse-check", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if not a.model and not a.model_tml:
        ap.error("--model or --model-tml required")
    offline = bool(a.model_tml)
    wd = migrate.resolve_workdir(a.workdir)
    ensure_sigma_env(wd)
    if not a.dry_run:
        missing = [v for v in ("SIGMA_BASE_URL", "SIGMA_API_TOKEN") if not os.environ.get(v)]
        if not a.reuse_dm and not os.environ.get("SIGMA_CONNECTION_ID"):
            missing.append("SIGMA_CONNECTION_ID (full warehouse-connection UUID)")
        if missing:
            sys.exit("FATAL: missing env: " + ", ".join(missing))
    TOTAL = 6

    # ── Phase 1 — Discover (model TML + freshness metadata) ──────────────────
    hdr(1, TOTAL, "Discover")
    if offline:
        model_tml = open(a.model_tml).read()
        print(f"   offline: model TML from {a.model_tml}")
    else:
        import ts_lib
        model_tml, err = ts_lib.export_tml(a.model, "LOGICAL_TABLE")
        if err:
            sys.exit("model export failed: " + err)
    open(os.path.join(wd, "model.tml"), "w").write(model_tml)
    root = yaml.safe_load(model_tml)
    root = root.get("model") or root.get("worksheet") or root
    model_name = root.get("name", "Migrated Model")
    resolver = ts_common.build_resolver(root)
    n_lb = len(a.liveboard or a.liveboard_tml or []) or "all referencing"
    print(f"   model '{model_name}': {len(resolver)} resolvable column(s) · {n_lb} Liveboard(s) · workdir {wd}")

    freshness = {"model_modified": None, "liveboards_modified": {}}
    if not offline:
        try:
            import ts_lib
            for e in ts_lib.search("LOGICAL_TABLE"):
                if e.get("metadata_id") == a.model:
                    freshness["model_modified"] = scan_modified(e)
            wanted = set(a.liveboard or [])
            for e in ts_lib.search("LIVEBOARD"):
                if not wanted or e.get("metadata_id") in wanted:
                    freshness["liveboards_modified"][e.get("metadata_name")] = scan_modified(e)
            print(f"   TS metadata: model modified {freshness['model_modified'] or '?'}")
        except Exception as ex:
            print(f"   TS freshness metadata unavailable: {ex}")
    json.dump(freshness, open(os.path.join(wd, "freshness.json"), "w"), indent=2)

    # ── Phase 2 — DM-reuse check (printed; default = BUILD NEW, never silent) ─
    hdr(2, TOTAL, "DM-reuse check")
    if a.reuse_dm:
        print(f"   --reuse-dm {a.reuse_dm} supplied — reusing that data model (convert + POST skipped)")
    elif a.skip_dm_reuse_check:
        print("   --skip-dm-reuse-check — building a new data model")
    else:
        sig = os.path.join(wd, "dm-signature.json")
        match_out = os.path.join(wd, "dm-match.json")
        sig_cmd = [sys.executable, os.path.join(HERE, "ts-dm-signature.py"), "--tml",
                   os.path.join(wd, "model.tml"), "--out", sig]
        if os.environ.get("TS_DB"):
            sig_cmd += ["--database", os.environ["TS_DB"]]
        if os.environ.get("TS_SCHEMA"):
            sig_cmd += ["--schema", os.environ["TS_SCHEMA"]]
        run(sig_cmd)
        rc, _ = run(["ruby", os.path.join(HERE, "find-or-pick-dm.rb"),
                     "--workbook-signature", sig, "--out", match_out], check=False)
        try:
            match = json.load(open(match_out))
            cands = match.get("candidates") or []
            for c in cands[:5]:
                print(f"     candidate: {c.get('dm_name')} ({c.get('dm_id')}) score={c.get('score')}")
            best = cands[0] if cands else None
            if rc == 0 and best:
                print("   ➤ a reusable DM scored ≥ threshold — DEFAULT IS STILL BUILD-NEW. To reuse it, re-run with:")
                print(f"       --reuse-dm {best.get('dm_id')}")
            else:
                print("   no existing DM scores above the reuse threshold — building new")
        except Exception as ex:
            print(f"   DM-reuse scan unavailable ({ex}) — building new")

    # ── Phase 3 — Convert + build (migrate.py: DM POST, workbooks, layout) ────
    hdr(3, TOTAL, "Convert + build (migrate.py)")
    if a.dry_run:
        conv_out = os.path.join(wd, "converted.json")
        if os.environ.get("CONVERTER_PATH"):
            p = subprocess.run(["node", os.path.join(HERE, "convert_model.mjs"),
                                os.path.join(wd, "model.tml")], capture_output=True, text=True)
            if p.returncode:
                sys.exit("convert failed: " + p.stderr[-300:])
            open(conv_out, "w").write(p.stdout)
            conv = json.loads(p.stdout)
            print(f"   DRY RUN: converted spec -> {conv_out} "
                  f"({(conv.get('stats') or {}).get('elements', '?')} element(s), "
                  f"{len(conv.get('warnings') or [])} warning(s))")
        else:
            req = {"tool": "mcp__sigma-data-model__convert_thoughtspot_to_sigma",
                   "arguments": {"tml_yaml": model_tml,
                                 "connection_id": os.environ.get("SIGMA_CONNECTION_ID", ""),
                                 "database": os.environ.get("TS_DB", ""),
                                 "schema": os.environ.get("TS_SCHEMA", "")}}
            json.dump(req, open(os.path.join(wd, "convert-request.json"), "w"), indent=2)
            print(f"   DRY RUN: no CONVERTER_PATH — MCP request -> {wd}/convert-request.json")
        print("\n================ RESULT (dry run) ================")
        print(f"artifacts   : {wd}  (no Sigma objects created)")
        print("==================================================")
        return 0
    resolve_folder()
    mig_cmd = [sys.executable, os.path.join(HERE, "migrate.py"), "--workdir", wd]
    if a.model:
        mig_cmd += ["--model", a.model]
    if a.model_tml:
        mig_cmd += ["--model-tml", a.model_tml]
    for lb in a.liveboard or []:
        mig_cmd += ["--liveboard", lb]
    for lb in a.liveboard_tml or []:
        mig_cmd += ["--liveboard-tml", lb]
    if a.name:
        mig_cmd += ["--name", a.name]
    if a.converted:
        mig_cmd += ["--converted", a.converted]
    if a.reuse_dm:
        mig_cmd += ["--reuse-dm", a.reuse_dm]
    rc, _ = run(mig_cmd, check=False)
    if rc == 3:
        print("\n   ⏸ MCP converter fallback: call the MCP tool per the instructions above,")
        print(f"     save its JSON to {wd}/converted.json, then RE-RUN THIS COMMAND with:")
        print(f"       --converted {wd}/converted.json")
        return 3
    if rc != 0:
        sys.exit(f"FATAL: migrate.py failed ({rc})")
    out = json.load(open(os.path.join(wd, "migrate_out.json")))
    dm = out["dataModel"]
    wbs = [(name, r) for name, r in out["results"].items() if r.get("workbook")]
    fails = [(name, r) for name, r in out["results"].items() if r.get("error")]
    if not wbs:
        sys.exit("FATAL: no workbook was built: " + json.dumps(fails))
    print(f"   DM {dm} · {len(wbs)} workbook(s)" + (f" · {len(fails)} FAILED Liveboard(s)" if fails else ""))

    # ── Phase 4 — Post-and-readback gate (live /columns: no type=error) ───────
    hdr(4, TOTAL, "Post-and-readback gate")
    col_errors = 0
    for name, r in wbs:
        cols = json.loads(migrate.sigma("GET", f"/v2/workbooks/{r['workbook']}/columns"))
        entries = cols.get("entries") or []
        errs = [c for c in entries if (c.get("type") or {}).get("type") == "error"]
        col_errors += len(errs)
        print(f"   {name[:34]:34s} {len(entries) - len(errs)}/{len(entries)} columns resolve"
              + (f" — {len(errs)} ERROR-typed" if errs else ""))
        for c in errs[:6]:
            print(f"     [{c.get('elementId')}] {c.get('label')}: {c.get('formula')}")

    # ── Phase 5 — SOURCE-FRESHNESS preflight (read BEFORE any side-by-side) ───
    hdr(5, TOTAL, "Source freshness (preflight — before parity)")
    masters = {}  # wb id -> (headers, rows)
    print("   ── SOURCE FRESHNESS (read this before any side-by-side) ──")
    if freshness.get("model_modified"):
        print(f"   TS model last modified   : {freshness['model_modified']}")
    for lname, t in (freshness.get("liveboards_modified") or {}).items():
        print(f"   TS Liveboard modified    : {lname} — {t or '?'}")
    if offline:
        print("   TS instance              : unavailable (offline run) — modified-time + searchdata probe skipped")
    probe_measure = next((c.get("name") for c in root.get("columns", [])
                          if str(((c.get("properties") or {}).get("column_type") or "")).upper() == "MEASURE"
                          and str(((c.get("properties") or {}).get("aggregation") or "SUM")).upper() == "SUM"), None)
    for name, r in wbs:
        headers, rows = parse_csv(export_csv(r["workbook"], "m-ofv"))
        masters[r["workbook"]] = (headers, rows)
        idx = {h: i for i, h in enumerate(headers)}
        datecol = next((h for h in headers if "date" in h.lower()), None)
        maxdate = max((str(row[idx[datecol]]) for row in rows if str(row[idx[datecol]]).strip()), default="?") \
            if datecol else None
        line = f"   warehouse (via Sigma)    : '{name[:30]}' master = {len(rows)} rows"
        if datecol:
            line += f", max({datecol}) = {maxdate}"
        print(line)
        if probe_measure and not offline and a.model:
            fcol = idx.get(ts_common._resolve(resolver, probe_measure)["friendly"])
            if fcol is not None:
                wh = sum(numify(row[fcol]) for row in rows
                         if isinstance(numify(row[fcol]), float))
                try:
                    import ts_lib
                    sd = ts_lib.searchdata(f"[{probe_measure}]", a.model)
                    tsv = numify(sd["data_rows"][0][0]) if sd.get("data_rows") else None
                    status = "MATCH" if isinstance(tsv, float) and abs(tsv - wh) <= max(abs(tsv), abs(wh)) * 1e-6 + 1e-9 \
                        else "DIVERGENT — investigate BEFORE reading parity as a conversion bug"
                    print(f"   probe Total {probe_measure[:20]:20s}: TS {tsv}  vs warehouse {round(wh, 2)}  {status}")
                except Exception as ex:
                    print(f"   TS searchdata probe unavailable: {ex}")
    print("   (ThoughtSpot models are usually live-query — a divergence here means the model/")
    print("    warehouse CHANGED between export and now, or a join differs; not cache staleness.)")

    # ── Phase 6 — Parity (two-pass, scripted) + HARD GATE ────────────────────
    hdr(6, TOTAL, "Parity + hard gate")
    model_id = a.model
    overall = []
    for i, (name, r) in enumerate(wbs):
        wb = r["workbook"]
        pdir = wd if len(wbs) == 1 else os.path.join(wd, f"parity-{i + 1}")
        os.makedirs(pdir, exist_ok=True)
        rc, _ = run(["ruby", os.path.join(HERE, "phase6-parity-thoughtspot.rb"),
                     "--workdir", pdir, "--workbook-id", wb], check=False)
        if rc != 0:
            sys.exit(f"FATAL: parity pass 1 failed for {wb}")
        plan = json.load(open(os.path.join(pdir, "parity-plan.json")))
        vmap, lb_guid = viz_specs_with_aggs(r["lb_tml"], resolver) if r.get("lb_tml") else ({}, None)
        expected, actuals = {}, {}
        for c in plan["charts"]:
            cname = c["chart"]
            # ACTUAL — the built Sigma chart, via CSV export
            headers, rows = parse_csv(export_csv(wb, c["sigma_element_id"]))
            if c.get("kind") == "pivot-table" and rows and "Total" in rows[0]:
                # Pivot CSV is a matrix: line 1 = measure/col-dim banner (lands in
                # `headers`), rows[0] = the real header (row dim, col-dim values,
                # 'Total'), then one row per row-dim value and a trailing grand-
                # total row. Parity compares row-dim totals — the 'Total' column.
                hdr2 = rows[0]
                tidx = hdr2.index("Total")
                actuals[cname] = [
                    [(r[0] if str(r[0]).strip() != "" else None), numify(r[tidx])]
                    for r in rows[1:] if str(r[0]).strip() != "Total"]
                v = vmap.get(cname)
                if not v:
                    print(f"   WARN: no source viz named {cname!r} in the Liveboard TML — chart will DIVERGE")
                    continue
                exp = None
                if model_id and not offline:
                    try:
                        exp = expected_live(v["spec"], model_id)
                    except Exception as ex:
                        print(f"   WARN: TS expected fetch failed for {cname!r} ({ex}); falling back to warehouse re-aggregation")
                if exp is None:
                    mh, mr = masters[wb]
                    exp = expected_offline(v["spec"], v["aggs"], resolver, mh, mr)
                if exp is not None:
                    expected[cname] = exp
                continue
            idx = {h: i for i, h in enumerate(headers)}
            want = c["sigma_columns"]
            if len(want) == 1:                      # KPI
                vi = idx.get(want[0], 0)
                actuals[cname] = [[None, numify(rows[0][vi])]] if rows else []
            else:
                di, vi = idx.get(want[0], 0), idx.get(want[1], 1 if len(headers) > 1 else 0)
                # Normalize the null bucket ('' from Sigma CSV vs None from
                # searchdata) and group-sum duplicate dims (a chart with a
                # color/series dim exports one CSV row per (x, series) pair —
                # parity compares per-x totals on both sides).
                pairs = [[row[di] if str(row[di]).strip() != "" else None, numify(row[vi])]
                         for row in rows]
                if c.get("kind") == "table":
                    # Grouped-table CSV exports drop to UNDERLYING-row grain when
                    # the element carries a non-grouped passthrough column (e.g. a
                    # filter column) — each of a group's n rows repeats the
                    # group-level calculation, so group-summing squares counts
                    # (n rows x value n = n^2). The calculation is already at
                    # group level: dedupe exact (dim, value) repeats first.
                    seen, deduped = set(), []
                    for d, val in pairs:
                        if (d, val) not in seen:
                            seen.add((d, val))
                            deduped.append([d, val])
                    pairs = deduped
                grouped, order = {}, []
                for d, val in pairs:
                    if d in grouped and isinstance(grouped[d], float) and isinstance(val, float):
                        grouped[d] += val
                    else:
                        if d not in grouped:
                            order.append(d)
                        grouped[d] = val
                actuals[cname] = [[d, round(grouped[d], 6) if isinstance(grouped[d], float) else grouped[d]]
                                  for d in order]
            # EXPECTED — searchdata ground truth (live) or source-TML re-aggregation (offline)
            v = vmap.get(cname)
            if not v:
                print(f"   WARN: no source viz named {cname!r} in the Liveboard TML — chart will DIVERGE")
                continue
            exp = None
            sp = v["spec"]
            afn = set(sp.get("af_names") or [])
            use_lb = bool(afn & set(sp.get("dims", [])[:1])) or bool(afn & set(sp.get("measures", [])[:1]))
            if model_id and not offline:
                try:
                    exp = expected_from_lbdata(lb_guid, sp) if (use_lb and lb_guid) else expected_live(sp, model_id)
                except Exception as ex:
                    print(f"   WARN: TS expected fetch failed for {cname!r} ({ex}); falling back to warehouse re-aggregation")
            if exp is None:
                mh, mr = masters[wb]
                exp = expected_offline(v["spec"], v["aggs"], resolver, mh, mr)
            if exp is not None:
                expected[cname] = exp
        json.dump(expected, open(os.path.join(pdir, "parity-expected.json"), "w"), indent=2)
        json.dump(actuals, open(os.path.join(pdir, "parity-actuals.json"), "w"), indent=2)
        rc, _ = run(["ruby", os.path.join(HERE, "phase6-parity-thoughtspot.rb"),
                     "--workdir", pdir, "--finalize"], check=False)
        grc, _ = run(["ruby", os.path.join(HERE, "assert-phase6-ran.rb"),
                      "--workdir", pdir, "--workbook-id", wb], check=False)
        summary = json.load(open(os.path.join(pdir, "parity-final.json")))
        overall.append((name, wb, summary, grc))

    # ── Summary ───────────────────────────────────────────────────────────────
    green = all(g == 0 for *_x, g in overall) and col_errors == 0
    print("\n================ RESULT ================")
    print(f"dataModelId : {dm}{'  (REUSED)' if out.get('dmReused') else ''}")
    for name, wb, s, g in overall:
        print(f"workbook    : {wb}  '{name}' — parity {s['charts_pass']}/{s['charts_total']} "
              f"{s['status']}, hard gate {'PASS' if g == 0 else f'FAIL (exit {g})'}")
    if fails:
        print(f"failed lbs  : {', '.join(n for n, _ in fails)}")
    print(f"PARITY      : {'GREEN' if green else 'RED'}  ·  wall-clock {elapsed()}")
    print("========================================")
    return 0 if green else 2


if __name__ == "__main__":
    sys.exit(main())
