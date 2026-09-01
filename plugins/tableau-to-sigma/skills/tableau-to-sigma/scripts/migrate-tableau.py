#!/usr/bin/env python3
"""Ruby-free Tableau migration orchestrator (Python + vendored Node converter).

The orchestrator is fail-closed and re-entrant. It never substitutes a reduced
fidelity path: unsupported conversion gaps stop at exit 4, parity input stops
at exit 12, and incomplete visual evidence stops at exit 16.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


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


def find_element_id(readback: dict, element_name: str) -> str | None:
    for page in readback.get("pages") or []:
        for element in page.get("elements") or []:
            if element.get("name") == element_name:
                return element.get("id")
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
    parser.add_argument("--expected")
    parser.add_argument("--actuals")
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

    if not (workdir / "dm-raw.json").is_file():
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

    raw_model = load(workdir / "dm-raw.json", {}) or {}
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
    dm_spec = Path(args.dm_spec).resolve() if args.dm_spec else workdir / "dm-raw.json"
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

    data_model_id = args.data_model_id or state.get("data_model_id")
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

    element_id = args.data_model_element_id or state.get("data_model_element_id")
    if not element_id:
        readback = load(workdir / "datamodel-readback.json", {}) or {}
        element_id = find_element_id(readback, args.fact_element)
    if not element_id:
        return stop(
            4,
            "DATA MODEL ELEMENT REQUIRED",
            [
                f"Could not resolve fact element {args.fact_element!r} from readback.",
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
                args.fact_element,
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

    workbook_id = args.sigma_workbook_id or state.get("workbook_id")
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

    if not args.expected or not args.actuals:
        return stop(
            12,
            "PARITY ACTUALS REQUIRED",
            [
                "Collect every KPI/chart result from the live Sigma workbook.",
                "Re-run with --expected <source.json> --actuals <sigma.json>.",
            ],
        )
    run(
        "Phase 6 numeric parity",
        "verify-parity.py",
        [
            "--expected",
            args.expected,
            "--actual",
            args.actuals,
            "--out",
            str(workdir / "parity-final.json"),
        ],
    )
    copy_artifact(args.actuals, workdir / "parity-actuals.json")
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
            args.source_anchors,
            "--actuals",
            args.actuals,
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
    return hard_gate.returncode or completed.returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        raise SystemExit(1)
