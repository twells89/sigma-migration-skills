#!/usr/bin/env python3
"""One-command Sisense -> Sigma migration orchestrator.

Live: --cube TITLE [--dashboard TITLE]
Existing export: --from-discovery DIR [--cube TITLE] [--dashboard TITLE]
Offline fixture exercise: --dry-run (optionally with --from-discovery)
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
sys.path.insert(0, str(HERE / "lib"))
import sigma_rest  # noqa: E402


class MigrationError(Exception):
    pass


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp.%d" % os.getpid())
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def run(command, cwd=None, check=True, env=None):
    print("  $ " + " ".join(str(part) for part in command))
    process = subprocess.run(
        [str(part) for part in command],
        cwd=cwd, capture_output=True, text=True,
        env={**os.environ, **(env or {})},
    )
    output = (process.stdout or "") + (process.stderr or "")
    for line in output.splitlines():
        print("    " + line)
    if check and process.returncode:
        raise MigrationError("command failed (%d): %s" %
                             (process.returncode, " ".join(map(str, command))))
    return process.returncode, output


def phase(number, title):
    print("\n-- Phase %s: %s --" % (number, title))


def load_local_env():
    env_file = Path("~/.sigma-migration/env").expanduser()
    if env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            match = re.match(r"\s*export\s+(\w+)=['\"]?([^'\"]+)", line)
            if match and not os.environ.get(match.group(1)):
                os.environ[match.group(1)] = match.group(2)


def load_sigma_env(workdir):
    """Resolve Sigma auth through the browser-first shared provider.

    A valid bearer is reused. Known-old tokens refresh proactively, and a
    browser keychain session is tried before the unattended client fallback.
    The resolved values stay in the environment for Ruby and child-Python
    phases, including their one-refresh-on-401 transports.
    """
    load_local_env()
    resolved = Path(workdir).expanduser().resolve()
    os.environ.setdefault("SIGMA_WORKDIR", str(resolved))
    sigma_rest.bootstrap_credentials(cwd=str(resolved))
    try:
        sigma_rest.base_url()
        os.environ["SIGMA_API_TOKEN"] = sigma_rest.auth_token()
    except (sigma_rest.SigmaError, SystemExit) as exc:
        raise MigrationError(
            "Sigma authentication failed: %s. Run scripts/browser-login.sh "
            "once, or configure SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET for "
            "unattended auth." % exc
        ) from exc


def prepare_discovery(args, workdir):
    destination = workdir / "discovery"
    destination.mkdir(parents=True, exist_ok=True)
    if args.from_discovery:
        source = Path(args.from_discovery).expanduser().resolve()
        if (source / "discovery").is_dir():
            source = source / "discovery"
        if not source.is_dir():
            raise MigrationError("--from-discovery is not a directory: %s" % source)
        for candidate in source.iterdir():
            if candidate.is_file() and (
                candidate.suffix.lower() in (".json", ".png") or
                candidate.name.endswith(".jsonl")
            ):
                target = destination / candidate.name
                if candidate.resolve() != target.resolve():
                    shutil.copy2(candidate, target)
        provenance = "rest-export"
    elif args.dry_run:
        shutil.copy2(SKILL / "fixtures" / "model_ecommerce.json",
                     destination / "model_ecommerce.json")
        shutil.copy2(SKILL / "fixtures" / "dashboards.json",
                     destination / "dashboards.json")
        provenance = "inferred"
    else:
        if not args.cube:
            raise MigrationError("--cube is required for live discovery")
        run([sys.executable, HERE / "discover.py", "--out", workdir,
             "--cube", args.cube])
        provenance = "live"

    dashboards_path = destination / "dashboards.json"
    if not dashboards_path.is_file():
        raise MigrationError("discovery has no dashboards.json")
    dashboards = read_json(dashboards_path)
    dashboards = dashboards if isinstance(dashboards, list) else [dashboards]
    if args.dashboard:
        wanted = {value.casefold() for value in args.dashboard}
        dashboards = [
            row for row in dashboards
            if str(row.get("title") or row.get("_id") or row.get("oid")).casefold() in wanted
        ]
        if not dashboards:
            raise MigrationError("none of --dashboard matched the discovery export")
        dashboards_path = destination / "dashboards-selected.json"
        write_json(dashboards_path, dashboards)

    model_candidates = sorted(destination.glob("model_*.json"))
    if not model_candidates:
        model_candidates = sorted(destination.glob("*model*.json"))
    if not model_candidates:
        raise MigrationError("discovery has no model_*.json")
    model_path = None
    for candidate in model_candidates:
        model = read_json(candidate)
        title = str(model.get("title") or model.get("name") or "")
        if not args.cube or title.casefold() == args.cube.casefold() or \
                args.cube.casefold() in candidate.stem.casefold():
            model_path = candidate
            break
    model_path = model_path or model_candidates[0]
    return model_path, dashboards_path, provenance


def select_fact(readback, preferred=None):
    root = readback.get("document", readback)
    elements = list(root.get("elements") or [])
    for page in root.get("pages") or []:
        if isinstance(page, dict):
            elements.extend(page.get("elements") or [])
    elements = [row for row in elements if isinstance(row, dict) and row.get("id")]
    if not elements:
        raise MigrationError("data-model readback contains no authoritative elements")
    if preferred:
        chosen = next((row for row in elements
                       if str(row.get("name") or "").casefold() == preferred.casefold()), None)
        if not chosen:
            raise MigrationError("--fact-element-name %r is absent from DM readback" % preferred)
    else:
        chosen = max(
            elements,
            key=lambda row: (
                len(row.get("relationships") or []),
                len(row.get("columns") or []),
                str(row.get("name") or ""),
            ),
        )
    source = chosen.get("source") or {}
    name = chosen.get("name") or ((source.get("path") or [None])[-1]) or chosen["id"]
    return {"id": chosen["id"], "name": name,
            "columns": len(chosen.get("columns") or []),
            "relationships": len(chosen.get("relationships") or [])}


def selected_cube(args, model):
    return args.cube or model.get("title") or model.get("name") or "Sisense Model"


def run_accounting(workdir, gap, model, dashboards, provenance, parity=None):
    command = [
        sys.executable, HERE / "build-sisense-accounting.py",
        "--workdir", workdir, "--gap-report", gap,
        "--model", model, "--dashboards", dashboards,
        "--dm-spec", workdir / "sigma_dm_spec.json",
        "--wb-spec", workdir / "sigma_workbook_spec.json",
        "--provenance", provenance,
    ]
    if (workdir / "dm-readback.json").is_file():
        command += ["--dm-readback", workdir / "dm-readback.json"]
    if (workdir / "wb-readback.json").is_file():
        command += ["--wb-readback", workdir / "wb-readback.json"]
    if parity and Path(parity).is_file():
        command += ["--parity-final", parity]
    if (workdir / "parity-plan.json").is_file():
        command += ["--jaql-mapping", workdir / "parity-plan.json"]
    return run(command, check=False)[0]


def tile_boxes(workbook, page_id, output):
    """Derive render-side tile boxes from the authoritative inline layout."""
    root = workbook.get("document", workbook)
    elements = {
        str(row.get("id")): row
        for row in root.get("elements") or []
        if isinstance(row, dict) and row.get("id")
    }
    layout = str(root.get("layout") or "")
    page_match = re.search(
        r'<Page\b[^>]*\bid="%s"[^>]*>(.*?)</Page>' % re.escape(str(page_id)),
        layout,
        flags=re.DOTALL,
    )
    if not page_match:
        raise MigrationError("inline layout has no page %s" % page_id)
    entries = []
    for raw_attrs in re.findall(r"<Element\b([^>]*)/?>", page_match.group(1)):
        attrs = dict(re.findall(r'(\w+)="([^"]*)"', raw_attrs))
        column = re.fullmatch(r"\s*(\d+)\s*/\s*(\d+)\s*", attrs.get("gridColumn", ""))
        row = re.fullmatch(r"\s*(\d+)\s*/\s*(\d+)\s*", attrs.get("gridRow", ""))
        element_id = attrs.get("elementId")
        if not element_id or not column or not row:
            continue
        entries.append({
            "id": element_id,
            "column_start": int(column.group(1)),
            "column_end": int(column.group(2)),
            "row_start": int(row.group(1)),
            "row_end": int(row.group(2)),
        })
    if not entries:
        raise MigrationError("inline layout page %s contains no positioned elements" % page_id)
    total_rows = max(row["row_end"] for row in entries) - 1
    tiles = []
    for row in entries:
        element = elements.get(row["id"]) or {}
        if element.get("controlType") or element.get("kind") == "control":
            continue
        tiles.append({
            "name": element.get("name") or row["id"],
            "kind": "chart",
            "x_pct": 100.0 * (row["column_start"] - 1) / 24.0,
            "y_pct": 100.0 * (row["row_start"] - 1) / max(1, total_rows),
            "w_pct": 100.0 * (row["column_end"] - row["column_start"]) / 24.0,
            "h_pct": 100.0 * (row["row_end"] - row["row_start"]) / max(1, total_rows),
        })
    write_json(output, tiles)
    positioned = set(re.findall(r'\belementId="([^"]+)"', layout))
    unplaced = sorted(
        element_id for element_id, element in elements.items()
        if not (element.get("controlType") or element.get("kind") == "control")
        and element_id not in positioned
    )
    used_area = sum(
        (row["column_end"] - row["column_start"]) *
        (row["row_end"] - row["row_start"])
        for row in entries
    )
    return tiles, unplaced, min(1.0, used_area / float(24 * max(1, total_rows)))


def state_writer(workdir, args):
    state = {
        "schema_version": 1, "run_id": str(uuid.uuid4()),
        "mode": "dry-run" if args.dry_run else "live",
        "complete": False, "post_complete": False,
        "parity_complete": False, "render_complete": False,
        "success_stamped": False, "phases": [],
    }

    def record(name, status="complete", **extra):
        state["phases"].append({"name": name, "status": status})
        state.update(extra)
        write_json(workdir / "run-state.json", state)
    record("start")
    return state, record


def parse_named(values):
    result = []
    for raw in values or []:
        if "=" in raw:
            result.append(raw)
        else:
            result.append("%s=%s" % (Path(raw).stem, raw))
    return result


def visual_gate_options(args):
    if args.skip_visual_comparison:
        return ["--skip-visual-comparison", args.skip_visual_comparison]
    if args.waive_source_page:
        reason = "named Sisense source-page waiver(s): " + "; ".join(
            args.waive_source_page
        )
        return [
            "--skip-visual-comparison", reason,
            "--skip-visual-similarity", reason,
        ]
    return []


def main(argv=None):
    # Resolve neutral-file environment overrides before argparse captures its
    # defaults. This is read-only and occurs before any live API operation.
    load_local_env()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cube", help="Sisense cube title (required for live discovery)")
    parser.add_argument("--dashboard", action="append",
                        help="limit migration to this dashboard title (repeatable)")
    parser.add_argument("--from-discovery",
                        help="use an existing Sisense REST discovery export")
    parser.add_argument("--dry-run", action="store_true",
                        help="offline only; permits fixture DEMO_DB/SISENSE_ECOMMERCE defaults")
    parser.add_argument("--workdir", default="./sisense-migration",
                        help="artifact directory (default: ./sisense-migration)")
    parser.add_argument(
        "--connection-id", default=os.environ.get("SIGMA_CONNECTION_ID"),
        help="target Sigma connection ID; required live (env: SIGMA_CONNECTION_ID)",
    )
    parser.add_argument(
        "--database", default=os.environ.get("SISENSE_TARGET_DATABASE"),
        help="target warehouse database; required live (env: SISENSE_TARGET_DATABASE)",
    )
    parser.add_argument(
        "--schema", default=os.environ.get("SISENSE_TARGET_SCHEMA"),
        help="target warehouse schema; required live (env: SISENSE_TARGET_SCHEMA)",
    )
    parser.add_argument(
        "--folder-id", default=os.environ.get("SIGMA_FOLDER_ID"),
        help="target Sigma folder ID; required live (env: SIGMA_FOLDER_ID)",
    )
    parser.add_argument("--reuse-dm")
    parser.add_argument("--skip-dm-reuse-check", action="store_true")
    parser.add_argument("--fact-element-name")
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--rls-answer", choices=("port", "omit"))
    parser.add_argument("--parity-checks")
    parser.add_argument("--snow-conn", default="tj")
    parser.add_argument("--source-png", action="append", default=[], metavar="PAGE=PATH")
    parser.add_argument("--waive-source-page", action="append", default=[],
                        metavar="PAGE=REASON")
    parser.add_argument("--skip-visual-comparison", metavar="REASON")
    parser.add_argument("--blind-grade", metavar="PATH")
    args = parser.parse_args(argv)
    if args.dry_run and args.reuse_dm:
        parser.error("--dry-run cannot use a live --reuse-dm")
    if args.skip_visual_comparison is not None and not args.skip_visual_comparison.strip():
        parser.error("--skip-visual-comparison requires a non-empty reason")
    if args.blind_grade and args.skip_visual_comparison:
        parser.error("--blind-grade and --skip-visual-comparison are mutually exclusive")
    if not args.dry_run and args.from_discovery is None and not args.cube:
        parser.error("live discovery requires --cube")
    if args.dry_run:
        args.database = args.database or "DEMO_DB"
        args.schema = args.schema or "SISENSE_ECOMMERCE"
    else:
        required_live = {
            "--connection-id/SIGMA_CONNECTION_ID": args.connection_id,
            "--database/SISENSE_TARGET_DATABASE": args.database,
            "--schema/SISENSE_TARGET_SCHEMA": args.schema,
            "--folder-id/SIGMA_FOLDER_ID": args.folder_id,
        }
        missing_live = [
            label for label, value in required_live.items()
            if not str(value or "").strip()
        ]
        if missing_live:
            parser.error(
                "live migration requires explicit/resolved target configuration "
                "before any Sigma write: " + ", ".join(missing_live)
            )

    workdir = Path(args.workdir).expanduser().resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    state, record = state_writer(workdir, args)
    started = time.time()

    phase("1", "discover/read source artifacts")
    model_path, dashboards_path, provenance = prepare_discovery(args, workdir)
    model = read_json(model_path)
    cube = selected_cube(args, model)
    record("discovery")

    phase("1b", "structured gap preflight (non-strict)")
    gap_path = workdir / "gap-report.json"
    run([
        sys.executable, HERE / "scan_gaps.py", dashboards_path,
        "--model", model_path, "--out", gap_path,
        "--rules", workdir / "learned-rules.json",
    ], cwd=workdir)
    record("gap-preflight")

    phase("2", "RLS detection and explicit decision")
    security_path = workdir / "security.json"
    if not args.dry_run and provenance == "live":
        run([sys.executable, HERE / "detect_rls.py", cube,
             "--json", "--out", security_path], cwd=workdir)
    elif not security_path.is_file():
        discovered_security = next(iter((workdir / "discovery").glob("*security*.json")), None)
        if discovered_security:
            shutil.copy2(discovered_security, security_path)
        else:
            write_json(security_path, [])
    security = read_json(security_path)
    findings = security if isinstance(security, list) else security.get("security", [])
    if findings and not (args.yes or args.rls_answer):
        record("rls-decision", "blocked")
        print("RLS findings require --rls-answer port|omit or --yes; nothing was POSTed",
              file=sys.stderr)
        return 10
    write_json(workdir / "rls-decision.json", {
        "findings": len(findings),
        "decision": args.rls_answer or ("omit" if args.yes and findings else "not-applicable"),
        "explicit": bool(args.rls_answer or args.yes),
    })
    record("rls-decision")

    phase("3", "convert data model")
    connection = args.connection_id or "00000000-0000-0000-0000-000000000000"
    run([
        sys.executable, HERE / "convert.py", "model", model_path, connection,
        args.schema, args.database, "--dashboards", dashboards_path,
    ], cwd=workdir)
    dm_spec = workdir / "sigma_dm_spec.json"
    record("convert-model")

    phase("3b", "non-destructive DM reuse scan")
    signature_path = workdir / "dm-signature.json"
    match_path = workdir / "dm-match.json"
    run([
        sys.executable, HERE / "sisense-dm-signature.py",
        "--model", model_path, "--dm-spec", dm_spec,
        "--database", args.database, "--schema", args.schema,
        "--out", signature_path,
    ])
    if args.reuse_dm:
        print("  explicit --reuse-dm %s; scanner bypassed and build POST will be skipped" %
              args.reuse_dm)
        match = {
            "scan_status": "not-run-explicit-reuse",
            "recommended_dm_id": args.reuse_dm,
            "rationale": "operator explicitly selected --reuse-dm",
            "candidates": [],
        }
        write_json(match_path, match)
        write_json(workdir / "dm-reuse.json", {
            "status": "explicit-reuse", "decision": "reuse",
            "dataModelId": args.reuse_dm,
            "signature": str(signature_path),
            "match": str(match_path),
        })
    elif args.skip_dm_reuse_check:
        print("  --skip-dm-reuse-check explicitly bypassed the live scan; BUILD NEW")
        match = {
            "scan_status": "explicitly-skipped",
            "recommended_dm_id": None,
            "rationale": "--skip-dm-reuse-check",
            "candidates": [],
        }
        write_json(match_path, match)
        write_json(workdir / "dm-reuse.json", {
            "status": "explicitly-skipped", "decision": "build-new",
            "reason": "--skip-dm-reuse-check",
            "signature": str(signature_path),
            "match": str(match_path),
        })
    elif args.dry_run:
        print("  offline dry-run: signature generated, live reuse scan skipped; BUILD NEW")
        match = {
            "scan_status": "skipped-offline",
            "recommended_dm_id": None,
            "rationale": "dry-run does not query the Sigma organization",
            "candidates": [],
        }
        write_json(match_path, match)
        write_json(workdir / "dm-reuse.json", {
            "status": "skipped-offline", "decision": "build-new",
            "reason": "dry-run",
            "signature": str(signature_path),
            "match": str(match_path),
        })
    else:
        load_sigma_env(workdir)
        missing_reuse = [
            name for name in ("SIGMA_BASE_URL", "SIGMA_API_TOKEN")
            if not os.environ.get(name)
        ]
        if missing_reuse:
            raise MigrationError(
                "DM reuse scan requires live Sigma configuration: " +
                ", ".join(missing_reuse)
            )
        scan_rc, _ = run([
            "ruby", HERE / "find-or-pick-dm.rb",
            "--workbook-signature", signature_path,
            "--out", match_path,
        ], check=False)
        if scan_rc not in (0, 1) or not match_path.is_file():
            raise MigrationError("DM reuse scan failed without a usable dm-match.json")
        match = read_json(match_path)
        for candidate in (match.get("candidates") or [])[:5]:
            print("  candidate: %s (%s), score=%s" % (
                candidate.get("dm_name"), candidate.get("dm_id"),
                candidate.get("score"),
            ))
        recommendation = match.get("recommended_dm_id")
        if recommendation:
            print("  recommendation: reusable DM %s (%s)" % (
                recommendation, match.get("rationale") or "threshold met",
            ))
            print("  decision: BUILD NEW (safe default); rerun with --reuse-dm %s to reuse" %
                  recommendation)
        else:
            print("  recommendation: BUILD NEW (%s)" %
                  (match.get("rationale") or "no reusable candidate"))
        write_json(workdir / "dm-reuse.json", {
            "status": "scanned",
            "decision": "build-new",
            "recommendedDataModelId": recommendation,
            "reason": "reuse requires explicit --reuse-dm",
            "signature": str(signature_path),
            "match": str(match_path),
        })
    record("dm-reuse")

    if args.dry_run:
        dm_readback = read_json(dm_spec)
        fact = select_fact(dm_readback, args.fact_element_name)
        dm_id = "DRY_RUN_DATA_MODEL"
    else:
        load_sigma_env(workdir)
        missing = [name for name in ("SIGMA_BASE_URL", "SIGMA_API_TOKEN")
                   if not os.environ.get(name)]
        if not args.reuse_dm and not args.connection_id:
            missing.append("--connection-id/SIGMA_CONNECTION_ID")
        if missing:
            raise MigrationError("missing live configuration: " + ", ".join(missing))
        post_dm = [
            sys.executable, HERE / "post-sisense-spec.py", "dm",
            "--spec", dm_spec, "--workdir", workdir,
        ]
        if args.reuse_dm:
            post_dm += ["--id", args.reuse_dm]
        if args.folder_id:
            post_dm += ["--folder-id", args.folder_id]
        run(post_dm)
        dm_ids = read_json(workdir / "dm-ids.json")
        dm_id = dm_ids["dataModelId"]
        dm_readback = read_json(workdir / "dm-readback.json")
        fact = select_fact(dm_readback, args.fact_element_name)
    write_json(workdir / "fact-element.json", fact)
    record("dm-readback" if not args.dry_run else "dm-readback-skipped",
           post_complete=False)

    phase("5", "convert workbook with readback ids and inline layout")
    dm_for_metrics = workdir / "dm-readback.json"
    if not dm_for_metrics.is_file():
        dm_for_metrics = dm_spec
    dashboard_command = [
        sys.executable, HERE / "convert.py", "dashboard",
        dashboards_path, model_path, dm_id, fact["id"], fact["name"],
        "--dm-spec", dm_for_metrics,
    ]
    run(dashboard_command, cwd=workdir)
    wb_spec = workdir / "sigma_workbook_spec.json"

    phase("5b", "pre-POST blank-risk and layout integrity")
    lint_rc, _ = run([
        "ruby", HERE / "lint-render-integrity.rb", "--spec", wb_spec,
        "--out", workdir / "blank-risk-elements.json",
    ], check=False)
    layout_rc, _ = run([
        sys.executable, HERE / "verify_layout.py", dashboards_path, wb_spec,
    ], check=False)
    if lint_rc or layout_rc:
        raise MigrationError("pre-POST workbook integrity failed (blank-risk=%d layout=%d)" %
                             (lint_rc, layout_rc))
    record("workbook-convert-layout")

    parity_plan = workdir / "parity-plan.json"
    parity_checks = workdir / "parity-checks.json"
    parity_build = [
        sys.executable, HERE / "build-sisense-parity.py", "build",
        "--dashboards", dashboards_path, "--model", model_path,
        "--cube", cube, "--database", args.database, "--schema", args.schema,
        "--checks-out", parity_checks, "--plan-out", parity_plan,
    ]
    if args.parity_checks:
        parity_build += ["--parity-checks", args.parity_checks]
    parity_plan_rc, _ = run(parity_build, check=False)

    if args.dry_run:
        phase("6", "offline dry-run accounting (no POST/parity/render)")
        strict_rc, _ = run([
            sys.executable, HERE / "scan_gaps.py", dashboards_path,
            "--model", model_path, "--out", gap_path,
            "--rules", workdir / "learned-rules.json", "--strict",
        ], cwd=workdir, check=False)
        accounting_rc = run_accounting(
            workdir, gap_path, model_path, dashboards_path, provenance
        )
        record(
            "dry-run-finished", "incomplete",
            complete=False, post_complete=False, parity_complete=False,
            render_complete=False, success_stamped=False,
            strict_gap_complete=(strict_rc == 0),
            parity_plan_complete=(parity_plan_rc == 0),
            accounting_complete=(accounting_rc == 0),
        )
        print("\nDRY RUN COMPLETE: discovery, scans, model/workbook conversion, "
              "blank-risk lint, layout, parity planning, and accounting exercised.")
        print("POST/parity/render are explicitly NOT complete; no success marker was stamped.")
        print("artifacts: %s" % workdir)
        return 0

    if parity_plan_rc:
        raise MigrationError("parity planning produced zero executable checks")

    phase("5c", "POST/readback workbook")
    post_wb = [
        sys.executable, HERE / "post-sisense-spec.py", "workbook",
        "--spec", wb_spec, "--workdir", workdir,
    ]
    if args.folder_id:
        post_wb += ["--folder-id", args.folder_id]
    run(post_wb)
    wb_id = read_json(workdir / "wb-ids.json")["workbookId"]
    record("workbook-post-readback", post_complete=True)

    phase("6", "JAQL parity and normalized final contract")
    verify_rc, _ = run([
        sys.executable, HERE / "verify_parity.py", parity_checks,
        "--snow-conn", args.snow_conn,
    ], cwd=workdir, check=False)
    normalize_rc, _ = run([
        sys.executable, HERE / "build-sisense-parity.py", "normalize",
        "--plan", parity_plan, "--results", workdir / "parity_keys.json",
        "--out", workdir / "parity-final.json",
    ], check=False)
    if verify_rc or normalize_rc:
        record("parity", "failed")
        return 2
    record("parity", parity_complete=True)

    phase("7", "render health and tile-aware visual comparison")
    visual_dir = workdir / "visual-qa"
    visual_dir.mkdir(exist_ok=True)
    wb_root = read_json(workdir / "wb-readback.json").get("document",
                                                          read_json(wb_spec).get("document", {}))
    pages = [row for row in wb_root.get("pages") or []
             if row.get("visibility") != "hidden" and "data" not in str(row.get("id")).lower()]
    targets = []
    for page in pages:
        output = visual_dir / ("%s.png" % page["id"])
        run([
            sys.executable, HERE / "sigma-export-png.py",
            "--workbook", wb_id, "--page", page["id"], "--out", output,
            "--w", "1800", "--h", "1000",
        ])
        targets.append("%s=%s" % (page["id"], output))
    source_values = parse_named(args.source_png)
    if not source_values:
        discovered_pngs = sorted((workdir / "discovery").glob("*.png"))
        target_names = [value.split("=", 1)[0] for value in targets]
        if len(discovered_pngs) == 1 and len(target_names) == 1:
            source_values = ["%s=%s" % (target_names[0], discovered_pngs[0])]
        else:
            by_stem = {path.stem: path for path in discovered_pngs}
            source_values = [
                "%s=%s" % (name, by_stem[name])
                for name in target_names if name in by_stem
            ]
    source_dashboards = read_json(dashboards_path)
    source_dashboards = source_dashboards if isinstance(source_dashboards, list) else [source_dashboards]
    source_widget_count = sum(len(row.get("widgets") or []) for row in source_dashboards)
    tiles = []
    layout_pages = []
    for page in pages:
        tile_path = workdir / ("sisense-tile-boxes-%s.json" % page["id"])
        page_tiles, unplaced, grid_fill = tile_boxes(wb_root, page["id"], tile_path)
        tiles.append("%s=%s" % (page["id"], tile_path))
        layout_pages.append({
            "page": page.get("name") or page["id"],
            "zones": source_widget_count if len(pages) == 1 else len(page_tiles),
            "placed": len(page_tiles),
            "grid_fill_pct": round(grid_fill, 6),
            "unplaced_elements": unplaced,
        })
    write_json(workdir / "layout-census.json", {"pages": layout_pages})
    visual_command = [
        sys.executable, HERE / "finalize-sisense-report.py",
        "--workdir", workdir, "--visual-only",
    ]
    for value in tiles:
        visual_command += ["--tiles", value]
    for value in source_values:
        visual_command += ["--source-png", value]
    for value in targets:
        visual_command += ["--target-png", value]
    for value in args.waive_source_page:
        visual_command += ["--waive-source-page", value]
    run(visual_command)
    record("visual", render_complete=True)

    phase("8", "control probe, orphan cleanup, strict gap gate")
    controls = [row for row in (read_json(wb_spec).get("document") or {}).get("elements") or []
                if row.get("kind") == "control" or row.get("controlType")]
    if controls:
        run([
            "ruby", HERE / "probe-controls.rb", "--workbook-id", wb_id,
            "--out", workdir / "probe-controls",
        ])
    else:
        probe_dir = workdir / "probe-controls"
        probe_dir.mkdir(exist_ok=True)
        write_json(probe_dir / "probe-results.json", {
            "status": "not-applicable", "controls": [], "reason": "workbook has no controls",
        })
    run([
        "ruby", HERE / "cleanup-orphan-workbooks.rb",
        "--workdir", workdir, "--keep", wb_id,
    ])
    strict_rc, _ = run([
        sys.executable, HERE / "scan_gaps.py", dashboards_path,
        "--model", model_path, "--out", gap_path,
        "--rules", workdir / "learned-rules.json", "--strict",
    ], cwd=workdir, check=False)
    if strict_rc:
        record("strict-gap", "failed")
        return 2

    # The shared gate consumes source-vs-built control scope. Build a
    # preliminary census now, then refresh the same accounting after the gate
    # so the final report is post-gate evidence.
    preliminary_accounting_rc = run_accounting(
        workdir, gap_path, model_path, dashboards_path, provenance,
        workdir / "parity-final.json",
    )
    if preliminary_accounting_rc:
        record("preliminary-accounting", "failed")
        return 2
    record("preliminary-accounting")

    control_scope = workdir / "control-scope.json"
    control_scope_rc, _ = run([
        sys.executable, HERE / "build-sisense-control-scope.py",
        "--dashboards", dashboards_path,
        "--workbook", workdir / "wb-readback.json",
        "--out", control_scope,
    ], check=False)
    if control_scope_rc:
        record("control-scope", "failed")
        return 2
    record("control-scope")

    if args.blind_grade:
        blind_grade = Path(args.blind_grade).expanduser().resolve()
        if not blind_grade.is_file():
            raise MigrationError("--blind-grade does not exist: %s" % blind_grade)
        grade = read_json(blind_grade)
        dimensions = grade.get("dimensions") if isinstance(grade, dict) else None
        if not isinstance(dimensions, dict):
            raise MigrationError("--blind-grade has no dimensions object")
        checklist = ",".join(
            "%s=%s" % (key, (dimensions.get(key) or {}).get("verdict"))
            for key in (
                "element_titles_hidden", "palette_match", "composition_match",
                "chart_shapes_match", "labels_legible", "numbers_formatted",
            )
        )
        run([
            "ruby", HERE / "record-visual-check.rb",
            "--workdir", workdir, "--verdict", "pass",
            "--notes", "VERIFIER: context-free blind grade supplied to Sisense orchestrator",
            "--screenshot", targets[0].split("=", 1)[1],
            "--agent-vision", "true", "--checklist", checklist,
            "--blind-grade", blind_grade,
        ])
        record("blind-grade")

    phase("9", "shared assert-phase6 hard gate")
    gate = [
        "ruby", HERE / "assert-phase6-ran.rb",
        "--workdir", workdir, "--workbook-id", wb_id,
        "--control-scope", control_scope,
        "--require-control-flip",
    ]
    if targets:
        gate += ["--sigma-render", targets[0].split("=", 1)[1]]
    gate += visual_gate_options(args)
    gate_rc, _ = run(gate, check=False)
    if gate_rc:
        record("shared-assert", "failed")
        return 2

    phase("10", "post-gate accounting and final report")
    accounting_rc = run_accounting(
        workdir, gap_path, model_path, dashboards_path, provenance,
        workdir / "parity-final.json",
    )
    if accounting_rc:
        record("accounting", "failed")
        return 2
    final_command = [
        sys.executable, HERE / "finalize-sisense-report.py",
        "--workdir", workdir,
    ]
    for value in tiles:
        final_command += ["--tiles", value]
    for value in source_values:
        final_command += ["--source-png", value]
    for value in targets:
        final_command += ["--target-png", value]
    for value in args.waive_source_page:
        final_command += ["--waive-source-page", value]
    if run(final_command, check=False)[0]:
        record("report", "failed")
        return 2
    record("report")

    phase("11", "verify complete")
    verify_complete_rc, _ = run([
        "ruby", HERE / "verify-complete.rb",
        "--workdir", workdir, "--workbook-id", wb_id,
    ], check=False)
    if verify_complete_rc:
        record("verify-complete", "failed", complete=False)
        return 2
    record("verify-complete", complete=True, success_stamped=True)
    print("\nSisense migration COMPLETE: DM %s, workbook %s, %.1fs" %
          (dm_id, wb_id, time.time() - started))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except MigrationError as error:
        print("migrate-sisense: %s" % error, file=sys.stderr)
        sys.exit(2)
