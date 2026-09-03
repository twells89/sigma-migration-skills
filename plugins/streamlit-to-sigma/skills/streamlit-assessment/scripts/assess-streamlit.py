#!/usr/bin/env python3
"""Read-only Streamlit project inventory and migration-readiness scoring."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PLUGIN = Path(__file__).resolve().parents[3]
CONVERTER_SKILL = PLUGIN / "skills" / "streamlit-to-sigma"
sys.path.insert(0, str(CONVERTER_SKILL))

from converter import analyze_project  # noqa: E402


WEIGHTS = {
    "blocking": 20,
    "plugin-candidate": 10,
    "restructure": 6,
    "review": 3,
    "info": 0,
}

COMPLEXITY_GUIDE = [
    {
        "class": "lite",
        "typicalApp": "SQL-backed dashboard with standard charts, tables, and filters",
        "migrationPath": "Mostly automated conversion plus parity review",
        "deliveryClass": "Fast / easy",
    },
    {
        "class": "medium",
        "typicalApp": "Multipage app with forms, moderate transforms, or simple writeback",
        "migrationPath": "Assisted conversion with targeted Sigma redesign",
        "deliveryClass": "Engineer-led",
    },
    {
        "class": "complex",
        "typicalApp": "Session state, callbacks, auth, custom Python, or transactional CRUD",
        "migrationPath": "Architecture-led redesign with explicit manual finish gates",
        "deliveryClass": "Multi-specialist",
    },
]

SIGMA_BENEFITS = [
    {
        "name": "Governance",
        "value": "Centralized permissions, row/column security, lineage, and auditability",
    },
    {
        "name": "Production deployment path",
        "value": "Managed sharing and warehouse-backed execution after security and parity gates pass",
    },
    {
        "name": "Warehouse-native operations",
        "value": "Durable input, writeback, and procedure patterns without a custom app server",
    },
    {
        "name": "Reusable semantic layer",
        "value": "Governed data models, metrics, and relationships shared across workbooks",
    },
    {
        "name": "Operational simplicity",
        "value": "Managed scheduling, exports, collaboration, and API-versioned workbook delivery",
    },
]

STATEFUL_GAPS = {
    "session-state",
    "deferred-form-state",
    "data-editor",
    "streamlit-rerun",
    "python-transform",
}
RESTRUCTURE_GAPS = {
    "agent-runtime-mismatch",
    "dataframe-column-mutation",
    "dataframe-restructure-required",
    "unsupported-dataframe-operation",
    "conditional-status",
    "llm-complete-not-agent",
}


def migration_dispositions(ir, readiness: str) -> list[str]:
    gaps = [gap for gap in ir.gaps if not gap.resolved]
    gap_codes = {gap.code for gap in gaps}
    security_codes = {finding.code for finding in ir.security}
    dispositions: list[str] = []
    if "warehouse-write" in security_codes or "data-editor" in gap_codes:
        dispositions.append("warehouse-backed")
    if "python-transform" in gap_codes:
        dispositions.append("python-element-candidate")
    if "workbook-agent-candidate" in gap_codes:
        dispositions.append("workbook-agent-candidate")
    if any(gap.severity == "plugin-candidate" for gap in gaps):
        dispositions.append("plugin")
    if any(element.kind == "button" for element in ir.elements) and (
        gap_codes & STATEFUL_GAPS or "warehouse-write" in security_codes
    ):
        dispositions.append("manual-ui-finish")
    if gap_codes & (STATEFUL_GAPS | RESTRUCTURE_GAPS):
        dispositions.append("redesign")
    if readiness == "blocked":
        dispositions.append("blocked")
    if not dispositions:
        dispositions.append("spec-native")
    return dispositions


def complexity_profile(ir, score: int, readiness: str) -> dict:
    gaps = [gap for gap in ir.gaps if not gap.resolved]
    gap_codes = {gap.code for gap in gaps}
    drivers: list[str] = []
    if len(ir.pages) > 2:
        drivers.append(f"{len(ir.pages)} pages")
    if len(ir.queries) > 3:
        drivers.append(f"{len(ir.queries)} data queries")
    if gap_codes & STATEFUL_GAPS:
        drivers.append("stateful forms, callbacks, or Python transforms")
    if "workbook-agent-candidate" in gap_codes:
        drivers.append("AI/chat workflow and workbook-agent architecture")
    if any(gap.severity == "plugin-candidate" for gap in gaps):
        drivers.append("custom component or plugin work")
    if any(gap.severity == "blocking" for gap in gaps):
        drivers.append("blocking source ambiguity or dynamic SQL")
    if ir.security:
        drivers.append("security, identity, or warehouse-write review")
    if len(ir.elements) > 12:
        drivers.append(f"{len(ir.elements)} visible elements")

    complex_app = (
        readiness == "blocked"
        or bool(gap_codes & STATEFUL_GAPS)
        or bool(ir.security)
        or "workbook-agent-candidate" in gap_codes
        or any(gap.severity == "plugin-candidate" for gap in gaps)
        or (score >= 90 and readiness != "direct")
    )
    medium_app = (
        readiness == "redesign"
        or score >= 25
        or len(ir.pages) >= 3
        or len(ir.controls) >= 5
    )
    complexity = "complex" if complex_app else "medium" if medium_app else "lite"
    delivery = {
        "lite": "Fast / easy",
        "medium": "Engineer-led",
        "complex": "Multi-specialist",
    }[complexity]
    if not drivers:
        drivers.append("standard SQL-backed dashboard surface")
    return {
        "class": complexity,
        "deliveryClass": delivery,
        "drivers": drivers,
        "calendarEstimate": None,
    }


def assess(path: Path) -> dict:
    ir = analyze_project(path)
    unresolved_gaps = [gap for gap in ir.gaps if not gap.resolved]
    score = (
        len(ir.pages) * 2
        + len(ir.queries) * 2
        + len(ir.controls)
        + len(ir.elements)
        + sum(WEIGHTS.get(gap.severity, 3) for gap in unresolved_gaps)
        + len(ir.security) * 8
    )
    security_blocking = any(
        finding.code == "warehouse-write" for finding in ir.security
    )
    readiness = (
        "blocked"
        if security_blocking
        or any(gap.severity == "blocking" for gap in unresolved_gaps)
        else "redesign"
        if ir.security
        or any(
            gap.severity in {"plugin-candidate", "restructure"}
            for gap in unresolved_gaps
        )
        else "direct"
    )
    dispositions = migration_dispositions(ir, readiness)
    complexity = complexity_profile(ir, score, readiness)
    return {
        "project": ir.project_name,
        "path": str(path.resolve()),
        "mainFile": ir.main_file,
        "pages": len(ir.pages),
        "queries": len(ir.queries),
        "controls": len(ir.controls),
        "elements": len(ir.elements),
        "gaps": [gap.__dict__ | {"provenance": gap.provenance.__dict__} for gap in ir.gaps],
        "security": [
            finding.__dict__ | {"provenance": finding.provenance.__dict__}
            for finding in ir.security
        ],
        "resolvedPatterns": ir.metadata.get("loweredPatterns", []),
        "unresolvedGapCount": len(unresolved_gaps),
        "complexityScore": score,
        "complexity": complexity,
        "readiness": readiness,
        "migrationDisposition": dispositions[0],
        "migrationDispositions": dispositions,
    }


def markdown_report(report: dict) -> str:
    lines = [
        "# Streamlit → Sigma migration assessment",
        "",
        "## Ease of migration",
        "",
        "| Complexity | Typical app | Migration path | Delivery class |",
        "|---|---|---|---|",
    ]
    for row in report["migrationGuide"]["classes"]:
        lines.append(
            f"| {row['class'].title()} | {row['typicalApp']} | "
            f"{row['migrationPath']} | {row['deliveryClass']} |"
        )
    lines.extend(
        [
            "",
            "> Calendar duration is not inferred from source-code counts. "
            "Configure local estimates from observed migration telemetry, staffing, "
            "security review, source access, and parity requirements.",
            "",
            "## Project readout",
            "",
            "| Project | Readiness | Complexity | Delivery | Primary disposition |",
            "|---|---|---|---|---|",
        ]
    )
    for project in report["projects"]:
        lines.append(
            f"| {project['project']} | {project['readiness']} | "
            f"{project['complexity']['class']} | "
            f"{project['complexity']['deliveryClass']} | "
            f"{project['migrationDisposition']} |"
        )
    lines.extend(["", "### Complexity drivers", ""])
    for project in report["projects"]:
        lines.append(
            f"- **{project['project']}:** "
            + "; ".join(project["complexity"]["drivers"])
            + "."
        )
    lines.extend(["", "## Benefits of Sigma", ""])
    for benefit in report["sigmaBenefits"]:
        lines.append(f"- **{benefit['name']}:** {benefit['value']}.")
    lines.extend(
        [
            "",
            "Production-ready is a gated outcome, not an automatic claim: security, "
            "warehouse parity, interaction parity, and visual QA must pass first.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", nargs="+", help="Project directories/main files")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    args = parser.parse_args()
    projects = [assess(Path(source)) for source in args.sources]
    projects.sort(
        key=lambda item: (
            {"direct": 0, "redesign": 1, "blocked": 2}[item["readiness"]],
            item["complexityScore"],
        )
    )
    report = {
        "kind": "streamlit-assessment",
        "readOnly": True,
        "migrationGuide": {
            "classes": COMPLEXITY_GUIDE,
            "calendarEstimatePolicy": (
                "Not inferred automatically; calibrate with observed organization telemetry."
            ),
        },
        "sigmaBenefits": SIGMA_BENEFITS,
        "projects": projects,
        "shortlist": [
            {
                "project": item["project"],
                "readiness": item["readiness"],
                "complexityScore": item["complexityScore"],
                "complexity": item["complexity"]["class"],
                "deliveryClass": item["complexity"]["deliveryClass"],
                "migrationDisposition": item["migrationDisposition"],
            }
            for item in projects
        ],
    }
    body = json.dumps(report, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(body, encoding="utf-8")
    else:
        print(body, end="")
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(markdown_report(report), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
