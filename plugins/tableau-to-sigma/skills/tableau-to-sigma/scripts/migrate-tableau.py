#!/usr/bin/env python3
"""Ruby-free Tableau migration orchestrator (Python + vendored Node converter).

The orchestrator is fail-closed and re-entrant. It never substitutes a reduced
fidelity path: unsupported conversion gaps stop at exit 4, parity input stops
at exit 12, incomplete visual evidence stops at exit 16, and unattributed
embedded extracts stop at exit 17. Reuse discovery is GET-only and automatic
reuse requires one unique, fully compatible candidate.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "lib"))
import sigma_rest  # noqa: E402
import tableau_source  # noqa: E402


class ExtractLandingRequired(RuntimeError):
    pass


class ReuseRequired(RuntimeError):
    pass


class ParityPreparationError(RuntimeError):
    pass


def load(path: Path, default=None):
    if not path.is_file():
        return default
    with path.open(encoding="utf-8-sig") as handle:
        return json.load(handle)


def write(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def copy_artifact(source: str, destination: Path) -> None:
    source_path = Path(source).expanduser().resolve()
    if source_path != destination.resolve():
        shutil.copyfile(source_path, destination)


def parity_plan_chart_names(plan: dict) -> list[str]:
    charts = plan.get("charts") if isinstance(plan, dict) else None
    if not isinstance(charts, list) or not charts:
        raise ParityPreparationError("parity-plan.json contains no charts")
    if plan.get("plan_status") != "green":
        raise ParityPreparationError(
            f"parity-plan.json status is {plan.get('plan_status')!r}, not 'green'"
        )
    unresolved = [
        item
        for item in plan.get("hidden_filters") or []
        if not isinstance(item, dict)
        or item.get("status") not in {"translated", "waived"}
    ]
    if unresolved:
        raise ParityPreparationError(
            f"{len(unresolved)} hidden source filter(s) remain unresolved"
        )
    names = []
    for index, chart in enumerate(charts):
        if not isinstance(chart, dict):
            raise ParityPreparationError(f"parity chart at index {index} is malformed")
        name = str(chart.get("chart") or chart.get("name") or "").strip()
        required = (
            chart.get("tableau_view"),
            chart.get("sigma_element_id"),
            chart.get("sigma_columns"),
            chart.get("expected"),
        )
        if not name or any(value in (None, "", []) for value in required):
            raise ParityPreparationError(
                f"parity chart {name or index!r} lacks source/target coverage"
            )
        names.append(name)
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise ParityPreparationError(
            "parity chart names are duplicated: " + ", ".join(duplicates)
        )
    return names


def validate_parity_rows(path: Path, chart_names: list[str], label: str) -> dict:
    try:
        artifact = load(path, None)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise ParityPreparationError(
            f"{label} artifact is unreadable: {path}: {exc}"
        ) from exc
    if not isinstance(artifact, dict):
        raise ParityPreparationError(f"{label} artifact must be a JSON object: {path}")
    expected = set(chart_names)
    present = set(artifact)
    if present != expected:
        missing = sorted(expected - present)
        extra = sorted(present - expected)
        detail = []
        if missing:
            detail.append("missing " + ", ".join(repr(name) for name in missing))
        if extra:
            detail.append("unexpected " + ", ".join(repr(name) for name in extra))
        raise ParityPreparationError(
            f"{label} coverage does not match parity plan ({'; '.join(detail)})"
        )
    for name in chart_names:
        rows = artifact[name]
        if not isinstance(rows, list) or not rows:
            raise ParityPreparationError(
                f"{label} for displayed tile {name!r} is failed, empty, or truncated"
            )
        if any(not isinstance(row, list) or not row for row in rows):
            raise ParityPreparationError(
                f"{label} for displayed tile {name!r} contains malformed rows"
            )
    return artifact


def validate_workbook_readback_fresh(
    readback_path: Path, workbook_id: str, *, api=sigma_rest
) -> str:
    try:
        readback = load(readback_path, None)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise ParityPreparationError(
            f"workbook readback is unreadable: {readback_path}: {exc}"
        ) from exc
    if not isinstance(readback, dict):
        raise ParityPreparationError(f"workbook readback is unreadable: {readback_path}")
    artifact_id = readback.get("workbookId")
    if artifact_id is not None and str(artifact_id) != str(workbook_id):
        raise ParityPreparationError(
            f"workbook readback belongs to {artifact_id!r}, not {workbook_id!r}"
        )
    artifact_version = readback.get("latestDocumentVersion") or readback.get(
        "latestVersion"
    )
    if artifact_version is None or str(artifact_version) == "":
        raise ParityPreparationError(
            "workbook readback lacks latestDocumentVersion/latestVersion"
        )
    try:
        live = api.request("get", f"/v2/workbooks/{workbook_id}/spec")
    except Exception as exc:
        raise ParityPreparationError(
            f"live workbook document-version check failed: {exc}"
        ) from exc
    if not isinstance(live, dict):
        raise ParityPreparationError("live workbook spec returned no JSON object")
    live_version = live.get("latestDocumentVersion") or live.get("latestVersion")
    if live_version is None or str(live_version) == "":
        raise ParityPreparationError("live workbook spec lacks a document version")
    if str(live_version) != str(artifact_version):
        raise ParityPreparationError(
            f"stale workbook readback: artifact is document version "
            f"{artifact_version}, live workbook is {live_version}"
        )
    return str(live_version)


def prepare_numeric_parity(
    args,
    workdir: Path,
    workbook_id: str,
    *,
    runner=subprocess.run,
    api=sigma_rest,
) -> tuple[Path, Path, Path]:
    """Build/validate the plan, expected projection, and Sigma actuals."""
    readback_path = workdir / "workbook-readback.json"
    plan_path = workdir / "parity-plan.json"
    expected_path = workdir / "parity-expected.json"
    actuals_path = workdir / "parity-actuals.json"
    if not readback_path.is_file():
        raise ParityPreparationError(f"missing workbook readback: {readback_path}")
    validate_workbook_readback_fresh(readback_path, workbook_id, api=api)

    plan_command = [
        sys.executable,
        str(HERE / "auto-parity-plan.py"),
        "--tableau",
        str(workdir),
        "--workbook-spec",
        str(readback_path),
        "--workbook-id",
        workbook_id,
        "--out",
        str(plan_path),
    ]
    for dashboard in args.dashboard:
        plan_command += ["--dashboard", dashboard]
    completed = runner(plan_command, check=False)
    if completed.returncode:
        raise ParityPreparationError(
            f"automatic parity plan failed with exit {completed.returncode}"
        )
    try:
        plan = load(plan_path, None)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise ParityPreparationError(
            f"automatic parity plan is unreadable: {exc}"
        ) from exc
    if not isinstance(plan, dict):
        raise ParityPreparationError("automatic parity plan was not written")
    chart_names = parity_plan_chart_names(plan)

    if args.expected:
        explicit_expected = Path(args.expected).expanduser().resolve()
        validate_parity_rows(explicit_expected, chart_names, "explicit expected")
        try:
            copy_artifact(str(explicit_expected), expected_path)
        except OSError as exc:
            raise ParityPreparationError(
                f"could not stage explicit expected artifact: {exc}"
            ) from exc
    else:
        completed = runner(
            [
                sys.executable,
                str(HERE / "parity-plan-to-expected.py"),
                "--plan",
                str(plan_path),
                "--out",
                str(expected_path),
            ],
            check=False,
        )
        if completed.returncode:
            raise ParityPreparationError(
                f"parity expected transform failed with exit {completed.returncode}"
            )
    validate_parity_rows(expected_path, chart_names, "expected")

    if args.actuals:
        explicit_actuals = Path(args.actuals).expanduser().resolve()
        validate_parity_rows(explicit_actuals, chart_names, "explicit actuals")
        try:
            copy_artifact(str(explicit_actuals), actuals_path)
        except OSError as exc:
            raise ParityPreparationError(
                f"could not stage explicit actuals artifact: {exc}"
            ) from exc
    else:
        completed = runner(
            [
                sys.executable,
                str(HERE / "collect-parity-actuals.py"),
                "--plan",
                str(plan_path),
                "--workbook-id",
                workbook_id,
                "--workbook-spec",
                str(readback_path),
                "--out",
                str(actuals_path),
            ],
            check=False,
        )
        if completed.returncode:
            raise ParityPreparationError(
                f"automatic Sigma actuals collection failed with exit "
                f"{completed.returncode}; see {actuals_path}"
            )
    validate_parity_rows(actuals_path, chart_names, "actuals")
    return plan_path, expected_path, actuals_path


def run(phase: str, script: str, arguments: list[str]) -> None:
    print(f"── {phase}: {script}")
    completed = subprocess.run(
        [sys.executable, str(HERE / script), *arguments],
        check=False,
    )
    if completed.returncode:
        raise RuntimeError(
            f"{phase} failed: {script} exited {completed.returncode}"
        )


def stop(code: int, title: str, lines: list[str]) -> int:
    print(f"\n==================== {title} (exit {code}) ====================")
    for line in lines:
        print(line)
    return code


def source_arguments(source: str) -> list[str]:
    if source.startswith(("http://", "https://")) or "/views/" in source:
        return ["--workbook-url", source]
    return ["--workbook-name", source]


def find_element_id(
    readback: dict,
    element_name: str,
    required_columns: list[str] | None = None,
) -> str | None:
    elements = []
    for page in readback.get("pages") or []:
        for element in page.get("elements") or []:
            elements.append(element)
            if element.get("name") == element_name:
                return element.get("id")
    required = {
        re.sub(r"[^A-Za-z0-9]", "", str(value)).upper()
        for value in required_columns or []
        if value
    }
    if required:
        compatible = []
        for element in elements:
            present = {
                re.sub(
                    r"[^A-Za-z0-9]",
                    "",
                    str(column.get("name") or column.get("label") or ""),
                ).upper()
                for column in element.get("columns") or []
                if isinstance(column, dict)
            }
            if required <= present and element.get("id"):
                compatible.append(element["id"])
        if len(compatible) == 1:
            return compatible[0]
    return None


def warehouse_paths(model: dict) -> list[list[str]]:
    found = {}
    for page in model.get("pages") or []:
        for element in page.get("elements") or []:
            source = element.get("source") or {}
            path = source.get("path")
            if source.get("kind") == "warehouse-table" and isinstance(path, list):
                found[tuple(str(part) for part in path)] = path
    return [found[key] for key in sorted(found)]


def unresolved_gaps(gaps: dict, resolutions: dict | None) -> list[dict]:
    rows = [
        row
        for row in gaps.get("detected_features") or []
        if row.get("status") == "unhandled"
    ]
    accepted = (resolutions or {}).get("resolutions") or {}
    return [
        row
        for row in rows
        if (
            (accepted.get(row.get("name")) or {}).get("status") != "validated"
            or not (accepted.get(row.get("name")) or {}).get("evidence")
        )
    ]


def neutral_environment(path: Path | None = None) -> dict[str, str]:
    path = path or Path("~/.sigma-migration/env").expanduser()
    if not path.is_file():
        return {}
    result = {}
    pattern = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = pattern.match(line)
        if not match:
            continue
        value = match.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        result[match.group(1)] = value
    return result


def twbx_has_hyper(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        with zipfile.ZipFile(path) as archive:
            return any(name.lower().endswith(".hyper") for name in archive.namelist())
    except (OSError, zipfile.BadZipFile):
        return False


def read_manifest(path: Path) -> list[dict]:
    value = load(path, None)
    return (
        [item for item in value if isinstance(item, dict)]
        if isinstance(value, list)
        else []
    )


def extract_landing_gate(
    args,
    workdir: Path,
    classification: dict,
    *,
    runner=subprocess.run,
    environment: dict[str, str] | None = None,
    neutral_path: Path | None = None,
) -> dict:
    """Require, or deterministically create, attributed extract landing evidence."""
    embedded = tableau_source.embedded_datasources(classification)
    if not embedded:
        result = {
            "status": "not-required",
            "exact_parity_eligible": True,
            "embedded_datasources": [],
        }
        write(workdir / "extract-landing-status.json", result)
        return result

    names = [item["name"] for item in embedded]
    manifest_path = workdir / "landing-manifest.json"
    manifest = read_manifest(manifest_path)
    coverage = tableau_source.validate_manifest_coverage(classification, manifest)
    if coverage["valid"]:
        result = {
            "status": "landed",
            "exact_parity_eligible": True,
            "manifest_path": str(manifest_path),
            "coverage": coverage,
            "embedded_datasources": names,
        }
        write(workdir / "extract-landing-status.json", result)
        return result

    if args.skip_extract_landing:
        result = {
            "status": "skipped",
            "kind": "extract-landing-offramp",
            "reason": args.skip_extract_landing,
            "exact_parity_eligible": False,
            "exact_parity_claim": "prohibited",
            "impact": (
                "Frozen Tableau extract bytes were not attributed to landed tables; "
                "source-data parity is unverified."
            ),
            "embedded_datasources": names,
            "manifest_coverage": coverage,
        }
        write(workdir / "extract-landing-offramp.json", result)
        write(workdir / "extract-landing-status.json", result)
        return result

    twbx = workdir / "workbook-content.twbx"
    process_env = dict(os.environ if environment is None else environment)
    neutral = neutral_environment(neutral_path)

    def resolved(key: str) -> str | None:
        return process_env.get(key) or neutral.get(key)

    identity_ok = all(resolved(key) for key in ("SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER"))
    auto_ready = (
        not args.no_auto_land
        and twbx_has_hyper(twbx)
        and bool(args.db)
        and bool(args.schema)
        and bool(args.connection)
        and identity_ok
    )
    landing_returncode = None
    if auto_ready:
        prefix = re.sub(r"[^A-Za-z0-9]+", "_", args.name or workdir.name)
        prefix = prefix.strip("_").upper()[:24] or "TABLEAU"
        completed = runner(
            [
                sys.executable,
                str(HERE / "land-extracts.py"),
                "--twbx",
                str(twbx),
                "--twb",
                str(workdir / "workbook-content.twb"),
                "--db",
                args.db,
                "--schema",
                args.schema,
                "--prefix",
                prefix,
                "--sigma-connection-id",
                args.connection,
                "--manifest-out",
                str(manifest_path),
            ],
            check=False,
        )
        landing_returncode = completed.returncode
        # The landing can finish tables+manifest and fail during catalog sync.
        # Always trust the populated artifact independently of process status.
        manifest = read_manifest(manifest_path)
        coverage = tableau_source.validate_manifest_coverage(classification, manifest)
        if coverage["valid"]:
            result = {
                "status": "landed",
                "exact_parity_eligible": True,
                "manifest_path": str(manifest_path),
                "coverage": coverage,
                "embedded_datasources": names,
                "auto_landed": True,
                "landing_returncode": landing_returncode,
                "catalog_sync_warning": landing_returncode != 0,
            }
            write(workdir / "extract-landing-status.json", result)
            return result

    blockers = []
    if args.no_auto_land:
        blockers.append("--no-auto-land disabled automatic landing")
    if not twbx_has_hyper(twbx):
        blockers.append(f"{twbx} is missing or contains no .hyper payload")
    if not args.db or not args.schema:
        blockers.append("explicit --db and --schema landing target required")
    if not args.connection:
        blockers.append("explicit --connection required for Sigma catalog sync")
    if not identity_ok:
        blockers.append(
            "SNOWFLAKE_ACCOUNT and SNOWFLAKE_USER are unresolved in process/"
            "~/.sigma-migration/env"
        )
    if manifest:
        blockers.append(
            "landing-manifest.json is populated but does not cover: "
            + ", ".join(coverage["missing_datasources"])
        )
    if landing_returncode is not None:
        blockers.append(
            f"land-extracts.py exited {landing_returncode} without complete manifest coverage"
        )
    raise ExtractLandingRequired(
        "; ".join(blockers)
        + ". Land the frozen extract with scripts/land-extracts.py and place an "
        "attributed, non-empty landing-manifest.json in the workdir, or explicitly "
        "use --skip-extract-landing REASON (source-data exact parity will be prohibited)."
    )


def reuse_decision(
    result: dict,
    mode: str,
    *,
    explicit_data_model: bool = False,
    explicit_workbook: bool = False,
) -> tuple[str | None, str | None]:
    dm = (result.get("data_model") or {}).get("selected_id")
    workbook = (result.get("workbook") or {}).get("selected_id")
    if explicit_data_model and not dm:
        raise ReuseRequired("explicit data model ID failed compatibility verification")
    if explicit_workbook and not workbook:
        raise ReuseRequired("explicit workbook ID failed compatibility verification")
    if mode == "require":
        missing = [
            label
            for label, value in (("data model", dm), ("workbook", workbook))
            if not value
        ]
        if missing:
            raise ReuseRequired(
                "strict reuse required but no unique compatible "
                + " / ".join(missing)
                + " was selected"
            )
    return dm, workbook


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbook", required=True, help="name or Tableau share URL")
    parser.add_argument("--connection", required=True)
    parser.add_argument("--folder", required=True)
    parser.add_argument("--db", required=True)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--landing", required=True, help="DB.SCHEMA or n/a")
    parser.add_argument("--out", required=True)
    parser.add_argument("--dashboard", action="append", default=[])
    parser.add_argument("--name")
    parser.add_argument("--fact-element", default="ORDER_FACT")
    parser.add_argument("--dm-spec")
    parser.add_argument("--gap-resolutions")
    parser.add_argument("--data-model-id")
    parser.add_argument("--data-model-element-id")
    parser.add_argument("--workbook-template")
    parser.add_argument("--sigma-workbook-id")
    parser.add_argument(
        "--reuse-mode",
        choices=("auto", "new", "require"),
        default="auto",
        help="strict discovery policy; auto reuses unique compatible matches",
    )
    parser.add_argument(
        "--no-auto-land",
        action="store_true",
        help="require manual extract landing even when all automatic inputs exist",
    )
    parser.add_argument(
        "--skip-extract-landing",
        metavar="REASON",
        help="explicitly proceed without frozen-extract attribution; prohibits exact-parity claims",
    )
    parser.add_argument(
        "--expected",
        help="explicit/backcompat expected JSON override; default derives from parity-plan.json",
    )
    parser.add_argument(
        "--actuals",
        help="explicit/backcompat Sigma actuals JSON override; default collects via REST export",
    )
    parser.add_argument("--source-anchors")
    parser.add_argument("--source-png")
    parser.add_argument("--page-id")
    parser.add_argument("--blind-grade")
    parser.add_argument(
        "--security-decision",
        choices=("port", "customize", "skip"),
        help="required when source security rules are detected",
    )
    parser.add_argument("--security-reason")
    parser.add_argument("--skip-doctor-gate", help="named reason; recorded by gate")
    parser.add_argument("--discover-only", action="store_true")
    args = parser.parse_args()

    workdir = Path(args.out).expanduser().resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    state_path = workdir / "migrate-state-python.json"
    state = load(state_path, {}) or {}
    name = args.name or "Tableau Migration — Python"

    mission = {
        "source": {"value": args.workbook, "provenance": "stated"},
        "sigma_connection": {
            "value": args.connection,
            "provenance": "stated",
        },
        "destination": {"value": args.folder, "provenance": "stated"},
        "landing": {"value": args.landing, "provenance": "stated"},
        "scope": {
            "value": args.dashboard or [args.workbook],
            "provenance": "stated",
        },
    }
    write(workdir / "mission.json", mission)

    gate_args = [
        "--workdir",
        str(workdir),
        "--runtime-profile",
        "python",
    ]
    if args.skip_doctor_gate:
        gate_args += ["--skip-doctor-gate", args.skip_doctor_gate]
    run("Step 0", "assert-doctor-ran.py", gate_args)

    if not (workdir / "workbook-content.twb").is_file():
        discover_args = [
            *source_arguments(args.workbook),
            "--out",
            str(workdir),
        ]
        for dashboard in args.dashboard:
            discover_args += ["--dashboard", dashboard]
        run("Phase 1", "tableau-discover.py", discover_args)
    if args.discover_only:
        print(f"DISCOVERY COMPLETE: {workdir}")
        return 0

    if not (workdir / "dashboard-layout.json").is_file():
        layout_args = [
            str(workdir / "workbook-content.twb"),
            str(workdir / "dashboard-layout.json"),
        ]
        for dashboard in args.dashboard:
            layout_args += ["--dashboard", dashboard]
        run("Phase 1 layout signals", "parse-twb-layout.py", layout_args)
    if not (workdir / "gaps.json").is_file():
        run(
            "Phase 1 gap scan",
            "scan-workbook-gaps.py",
            [
                str(workdir / "workbook-content.twb"),
                str(workdir / "gaps-report.md"),
            ],
        )
    gaps = load(workdir / "gaps.json", {}) or {}
    resolutions = (
        load(Path(args.gap_resolutions).resolve(), {})
        if args.gap_resolutions
        else None
    )
    if args.gap_resolutions:
        copy_artifact(args.gap_resolutions, workdir / "gap-resolutions.json")
    open_gaps = unresolved_gaps(gaps, resolutions)
    if open_gaps:
        write(workdir / "unresolved-gaps.json", open_gaps)
        return stop(
            11,
            "GAP REVIEW REQUIRED",
            [
                f"{len(open_gaps)} unhandled source feature(s) remain.",
                f"See {workdir / 'unresolved-gaps.json'}.",
                "Validate full-fidelity resolutions and re-run with",
                "--gap-resolutions <resolutions.json>. Accepted degradation is not validation.",
            ],
        )

    classification = tableau_source.classify_workbook(
        workdir / "workbook-content.twb"
    )
    write(workdir / "source-classification.json", classification)
    try:
        landing = extract_landing_gate(args, workdir, classification)
    except ExtractLandingRequired as exc:
        return stop(
            17,
            "EXTRACT LANDING REQUIRED",
            [
                str(exc),
                f"Classifier evidence: {workdir / 'source-classification.json'}",
            ],
        )
    state["extract_landing_status"] = landing["status"]
    state["exact_parity_eligible"] = landing["exact_parity_eligible"]
    write(state_path, state)

    if not (workdir / "dm-raw.json").is_file() and not args.dm_spec:
        run(
            "Phase 2",
            "convert-tableau.py",
            [
                "--twb",
                str(workdir / "workbook-content.twb"),
                "--connection",
                args.connection,
                "--database",
                args.db,
                "--schema",
                args.schema,
                "--out",
                str(workdir),
            ],
        )

    source_model_path = (
        Path(args.dm_spec).expanduser().resolve()
        if args.dm_spec
        else workdir / "dm-raw.json"
    )
    raw_model = load(source_model_path, {}) or {}
    effective_dm_spec = source_model_path
    fact_element_name = args.fact_element
    manifest = (
        read_manifest(Path(landing["manifest_path"]))
        if landing.get("manifest_path")
        else []
    )
    if manifest:
        remap = tableau_source.remap_from_manifest(raw_model, manifest)
        used_manifest = remap.get("used_manifest_entries") or []
        remapped_coverage = tableau_source.validate_manifest_coverage(
            classification, used_manifest
        )
        remap["coverage"] = remapped_coverage
        write(workdir / "extract-manifest-remap.json", remap)
        if not remap["elements"] or not remapped_coverage["valid"]:
            return stop(
                17,
                "EXTRACT MANIFEST REMAP INCOMPLETE",
                [
                    "The manifest exists, but converted DM elements could not be "
                    "attributed to every embedded datasource.",
                    f"See {workdir / 'extract-manifest-remap.json'}.",
                    "Repair datasource/table/column attribution before any Sigma POST.",
                ],
            )
        matching_fact = [
            mapping
            for mapping in remap["mappings"]
            if re.sub(r"[^A-Za-z0-9]", "", mapping.get("old_name") or "").upper()
            == re.sub(r"[^A-Za-z0-9]", "", args.fact_element).upper()
            or re.sub(r"[^A-Za-z0-9]", "", mapping.get("old_table") or "").upper()
            == re.sub(r"[^A-Za-z0-9]", "", args.fact_element).upper()
        ]
        if len(matching_fact) == 1:
            fact_element_name = matching_fact[0]["new_name"]
        elif len(remap["mappings"]) == 1:
            fact_element_name = remap["mappings"][0]["new_name"]
        effective_dm_spec = workdir / "dm-remapped.json"
        write(effective_dm_spec, raw_model)
    elif landing["status"] == "skipped":
        write(
            workdir / "extract-manifest-remap.json",
            {
                "status": "skipped",
                "reason": args.skip_extract_landing,
                "exact_parity_eligible": False,
                "elements": 0,
            },
        )

    for path in warehouse_paths(raw_model):
        table_path = ".".join(path)
        slug = re.sub(r"[^A-Za-z0-9_-]+", "-", path[-1]).strip("-")
        columns_path = workdir / f"cols-{slug}.json"
        if columns_path.is_file():
            continue
        run(
            "Phase 2 warehouse columns",
            "discover-columns.py",
            [
                "--connection-id",
                args.connection,
                "--table-path",
                table_path,
                "--out",
                str(columns_path),
            ],
        )

    metadata = load(workdir / "conv-meta.json", {}) or {}
    security = metadata.get("security") or []
    if security and not args.security_decision:
        return stop(
            15,
            "SECURITY DECISION REQUIRED",
            [
                f"{len(security)} Tableau security rule(s) were detected.",
                "Re-run with --security-decision port|customize|skip.",
                "Skip is loud: all rows become visible and completion records the decision.",
            ],
        )
    if security and args.security_decision != "skip":
        return stop(
            15,
            "SECURITY IMPLEMENTATION REQUIRED",
            [
                f"Decision={args.security_decision}; apply the rules with apply_sigma_rls.py.",
                "Then re-run this command. Security is never silently dropped.",
            ],
        )
    if security and args.security_decision == "skip" and not args.security_reason:
        return stop(
            15,
            "SECURITY SKIP REASON REQUIRED",
            ["Re-run with --security-reason <explicit user-approved reason>."],
        )
    write(
        workdir / "security-decision.json",
        (
            {
                "decision": "skip",
                "rules_detected": len(security),
                "reason": args.security_reason,
                "acknowledges_all_rows_visible": True,
            }
            if security
            else {"decision": "not-required", "rules_detected": 0}
        ),
    )

    unsupported = [
        pattern
        for pattern in metadata.get("workbookPatterns") or []
        if pattern.get("kind") == "unsupported"
    ]
    dm_spec = effective_dm_spec
    if unsupported and not args.dm_spec:
        write(workdir / "unsupported-patterns.json", unsupported)
        return stop(
            4,
            "CONVERTER STOP — REPAIR REQUIRED",
            [
                f"{len(unsupported)} unsupported pattern(s) require full-fidelity repair.",
                f"See {workdir / 'unsupported-patterns.json'}.",
                "Write a repaired DM spec plus measured semantic-edits.json, then re-run",
                f"with --dm-spec <path>. Do not delete or waive the affected objects.",
            ],
        )
    if not (workdir / "semantic-edits.json").is_file():
        write(
            workdir / "semantic-edits.json",
            {"kind": "semantic-edits", "edits": [], "match": True},
        )

    if args.reuse_mode == "new" and (
        args.data_model_id or args.sigma_workbook_id
    ):
        return stop(
            3,
            "INVALID REUSE POLICY",
            [
                "--reuse-mode new conflicts with an explicit existing object ID.",
                "Use --reuse-mode auto/require, or remove the explicit ID.",
            ],
        )

    existing_dm = args.data_model_id or state.get("data_model_id")
    existing_workbook = args.sigma_workbook_id or state.get("workbook_id")
    reuse_result_path = workdir / "reuse-discovery.json"
    should_discover = args.reuse_mode != "new" or bool(
        existing_dm or existing_workbook
    )
    if should_discover:
        reuse_args = [
            "--workdir",
            str(workdir),
            "--dm-spec",
            str(dm_spec),
            "--out",
            str(reuse_result_path),
            "--mode",
            "both",
        ]
        if existing_dm:
            reuse_args += ["--data-model-id", existing_dm]
        if existing_workbook:
            reuse_args += ["--workbook-id", existing_workbook]
        print("── Reuse discovery: discover-tableau-reuse.py")
        reuse_completed = subprocess.run(
            [sys.executable, str(HERE / "discover-tableau-reuse.py"), *reuse_args],
            check=False,
        )
        reuse_result = load(reuse_result_path, {}) or {}
        if reuse_completed.returncode not in (0, 3):
            raise RuntimeError(
                "reuse discovery failed before posting; see "
                f"{reuse_result_path}"
            )
        try:
            discovered_dm, discovered_workbook = reuse_decision(
                reuse_result,
                args.reuse_mode,
                explicit_data_model=bool(existing_dm),
                explicit_workbook=bool(existing_workbook),
            )
        except ReuseRequired as exc:
            return stop(
                3,
                "STRICT REUSE NOT RESOLVED",
                [str(exc), f"Review candidates in {reuse_result_path}."],
            )
    else:
        discovered_dm = discovered_workbook = None
        write(
            reuse_result_path,
            {
                "contract_version": 1,
                "read_only": True,
                "status": "skipped",
                "rationale": "--reuse-mode new",
            },
        )

    data_model_id = discovered_dm
    workbook_id = discovered_workbook
    if data_model_id:
        state["data_model_id"] = data_model_id
    if workbook_id:
        state["workbook_id"] = workbook_id
    write(state_path, state)

    if not data_model_id:
        run(
            "Phases 3–4",
            "post-and-readback.py",
            [
                "--type",
                "datamodel",
                "--spec",
                str(dm_spec),
                "--out",
                str(workdir / "dm-ids.json"),
                "--workdir",
                str(workdir),
                "--name",
                f"{name} — Data Model",
                "--folder-id",
                args.folder,
            ],
        )
        data_model_id = load(workdir / "dm-ids.json")["dataModelId"]
        state["data_model_id"] = data_model_id
        write(state_path, state)
    else:
        write(workdir / "dm-ids.json", {"dataModelId": data_model_id})
        try:
            dm_readback = sigma_rest.request(
                "get", f"/v2/dataModels/{data_model_id}/spec"
            )
        except sigma_rest.SigmaError as exc:
            raise RuntimeError(
                f"selected data model {data_model_id} readback failed: {exc}"
            ) from exc
        if not isinstance(dm_readback, dict):
            raise RuntimeError(
                f"selected data model {data_model_id} returned no JSON spec"
            )
        write(workdir / "datamodel-readback.json", dm_readback)

    element_id = args.data_model_element_id or state.get("data_model_element_id")
    if not element_id:
        readback = load(workdir / "datamodel-readback.json", {}) or {}
        signature = load(workdir / "workbook-signature-python.json", {}) or {}
        element_id = find_element_id(
            readback,
            fact_element_name,
            signature.get("referenced_columns") or [],
        )
    if not element_id:
        return stop(
            4,
            "DATA MODEL ELEMENT REQUIRED",
            [
                f"Could not resolve fact element {fact_element_name!r} from readback.",
                "Re-run with --data-model-element-id <server element id>.",
            ],
        )
    state["data_model_element_id"] = element_id
    write(state_path, state)

    if args.workbook_template:
        run(
            "Phase 5 template binding",
            "build-workbook-template.py",
            [
                "--template",
                args.workbook_template,
                "--data-model-id",
                data_model_id,
                "--element-id",
                element_id,
                "--folder-id",
                args.folder,
                "--out",
                str(workdir / "wb-spec-python.json"),
            ],
        )
    else:
        print("── Phase 5 automatic build: build-workbook-from-signals.py")
        automatic = subprocess.run(
            [
                sys.executable,
                str(HERE / "build-workbook-from-signals.py"),
                "--layout",
                str(workdir / "dashboard-layout.json"),
                "--meta",
                str(workdir / "dashboard-layout-meta.json"),
                "--data-model-id",
                data_model_id,
                "--element-id",
                element_id,
                "--data-model-element-name",
                fact_element_name,
                "--folder-id",
                args.folder,
                "--title",
                name,
                "--formula-audit",
                str(workdir / "formula-audit.json"),
                "--dm-spec",
                str(dm_spec),
                "--out",
                str(workdir / "wb-spec-python.json"),
                "--residues-out",
                str(workdir / "workbook-residues.json"),
            ],
            check=False,
        )
        if automatic.returncode == 2:
            return stop(
                4,
                "WORKBOOK BUILD RESIDUES",
                [
                    "Automatic source-signal binding found unsupported or ambiguous zones.",
                    f"See {workdir / 'workbook-residues.json'}.",
                    "Repair every residue in a complete customer-local template and re-run",
                    "with --workbook-template <template.json>.",
                ],
            )
        if automatic.returncode:
            raise RuntimeError(
                f"automatic workbook builder exited {automatic.returncode}"
            )

    post_args = [
        "--type",
        "workbook",
        "--spec",
        str(workdir / "wb-spec-python.json"),
        "--out",
        str(workdir / "wb-ids.json"),
        "--workdir",
        str(workdir),
    ]
    if workbook_id:
        post_args += ["--update-id", workbook_id]
    run("Phase 5 readback", "post-and-readback.py", post_args)
    workbook_id = load(workdir / "wb-ids.json")["workbookId"]
    state["workbook_id"] = workbook_id
    write(state_path, state)

    print("── Accounting: build-source-object-census.py")
    accounting = subprocess.run(
        [
            sys.executable,
            str(HERE / "build-source-object-census.py"),
            "--workdir",
            str(workdir),
        ],
        check=False,
    )
    if accounting.returncode:
        return stop(
            4,
            "SOURCE OBJECT ACCOUNTING REQUIRED",
            [
                f"See {workdir / 'source-object-census.json'}.",
                "Every source formula and dashboard zone needs one terminal disposition.",
            ],
        )

    try:
        _, expected_path, actuals_path = prepare_numeric_parity(
            args, workdir, workbook_id
        )
    except ParityPreparationError as exc:
        return stop(
            12,
            "PARITY PREPARATION REQUIRED",
            [
                str(exc),
                f"Review {workdir / 'parity-plan.json'} and "
                f"{workdir / 'parity-actuals.json'}.",
                "Resolve every source filter/tile/export failure, then re-run. "
                "--expected/--actuals remain explicit override inputs.",
            ],
        )
    run(
        "Phase 6 numeric parity",
        "verify-parity.py",
        [
            "--expected",
            str(expected_path),
            "--actual",
            str(actuals_path),
            "--out",
            str(workdir / "parity-final.json"),
        ],
    )
    if not args.source_anchors:
        return stop(
            16,
            "SOURCE ANCHORS REQUIRED",
            [
                "Transcribe source-render values into source-anchors.json.",
                "Re-run with --source-anchors <source-anchors.json>.",
            ],
        )
    copy_artifact(args.source_anchors, workdir / "source-anchors.json")
    run(
        "Phase 6 source anchors",
        "verify-anchors.py",
        [
            "--workdir",
            str(workdir),
            "--anchors",
            str(workdir / "source-anchors.json"),
            "--actuals",
            str(actuals_path),
        ],
    )

    source_png = (
        Path(args.source_png).resolve()
        if args.source_png
        else next(iter((workdir / "dashboards").glob("*.png")), None)
    )
    if not source_png or not source_png.is_file() or not args.page_id:
        return stop(
            16,
            "VISUAL INPUT REQUIRED",
            [
                "Provide --source-png <source dashboard PNG> and --page-id <Sigma page id>.",
            ],
        )
    render_png = workdir / "sigma-render-final.png"
    run(
        "Phase 6 render",
        "sigma-export-png.py",
        [
            "--workbook",
            workbook_id,
            "--page",
            args.page_id,
            "--out",
            str(render_png),
        ],
    )
    run(
        "Phase 6 visual floor",
        "visual-similarity.py",
        [
            "--source",
            str(source_png),
            "--render",
            str(render_png),
            "--json-out",
            str(workdir / "visual-similarity-final.json"),
        ],
    )
    if not args.blind_grade:
        return stop(
            16,
            "BLIND VISUAL GRADE REQUIRED",
            [
                "Run a fresh context-free grader against the source and final render.",
                "Re-run with --blind-grade <blind-grade.json>.",
            ],
        )
    print("── Final gate: verify-complete.py")
    completed = subprocess.run(
        [
            sys.executable,
            str(HERE / "verify-complete.py"),
            "--workdir",
            str(workdir),
            "--blind-grade",
            args.blind_grade,
        ],
        check=False,
    )
    run(
        "Final report",
        "build-migration-report.py",
        ["--workdir", str(workdir)],
    )
    print("── Consolidated hard gate: assert-phase6-ran.py")
    hard_gate = subprocess.run(
        [
            sys.executable,
            str(HERE / "assert-phase6-ran.py"),
            "--workdir",
            str(workdir),
            "--blind-grade",
            args.blind_grade,
        ],
        check=False,
    )
    if not state.get("exact_parity_eligible", True):
        print(
            "OFF-RAMP: extract landing was explicitly skipped; this run does NOT "
            "claim exact parity with the frozen Tableau extract. See "
            f"{workdir / 'extract-landing-offramp.json'}."
        )
    return hard_gate.returncode or completed.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        raise SystemExit(1)
