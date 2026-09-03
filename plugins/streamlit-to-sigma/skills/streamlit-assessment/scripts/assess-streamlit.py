#!/usr/bin/env python3
"""Read-only Streamlit project inventory and migration-readiness scoring."""

from __future__ import annotations

import argparse
import html
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


RECOMMENDATION_ORDER = {
    "migrate-now": 0,
    "redesign-then-migrate": 1,
    "architecture-review": 2,
    "defer-until-unblocked": 3,
}


def migration_recommendation(project: dict) -> dict:
    """Turn technical evidence into an explicit migration decision."""
    readiness = project["readiness"]
    complexity = project["complexity"]["class"]
    dispositions = project["migrationDispositions"]
    unresolved = [
        gap for gap in project["gaps"] if not gap.get("resolved", False)
    ]
    blockers = [
        gap["code"]
        for gap in unresolved
        if gap["severity"] == "blocking"
    ]
    blockers.extend(finding["code"] for finding in project["security"])
    blockers = list(dict.fromkeys(blockers))

    if readiness == "direct":
        decision = "migrate-now"
        label = "Migrate now"
        wave = "Wave 1"
        fit_score = 95 if complexity == "lite" else 85
        reason = (
            f"{complexity.title()} complexity with no unresolved restructuring "
            "or blocking findings."
        )
        next_action = (
            "Run the converter, complete reuse/readback gates, then validate "
            "data, interactions, security, and rendered parity."
        )
    elif readiness == "redesign" and complexity != "complex":
        decision = "redesign-then-migrate"
        label = "Redesign, then migrate"
        wave = "Wave 2"
        fit_score = 65
        reason = (
            "Sigma can cover the app, but unresolved behavior requires a "
            "bounded native or warehouse-backed redesign."
        )
        next_action = (
            "Approve the listed migration disposition and redesign, then run "
            "conversion with explicit manual-finish gates."
        )
    elif readiness == "redesign":
        decision = "architecture-review"
        label = "Architecture review"
        wave = "Wave 3"
        fit_score = 40
        reason = (
            "Complex state, Python, AI, plugin, or writeback behavior prevents "
            "a responsible converter-first recommendation."
        )
        next_action = (
            "Choose the target architecture and validate capability hosts "
            "before committing this app to a migration wave."
        )
    else:
        decision = "defer-until-unblocked"
        label = "Defer until unblocked"
        wave = "Hold"
        fit_score = max(5, 25 - min(len(blockers), 5) * 3)
        blocker_text = ", ".join(blockers) if blockers else "blocking findings"
        reason = f"Migration cannot proceed reliably while {blocker_text} remains."
        next_action = (
            "Resolve source ambiguity, access, security, or writeback blockers "
            "and rerun the assessment."
        )

    if "workbook-agent-candidate" in dispositions:
        next_action = (
            "Map the observed AI runtime to a governed workbook agent, attach "
            "proven grounding sources, and validate representative answers."
        )
    elif "warehouse-backed" in dispositions and readiness != "blocked":
        next_action = (
            "Approve the warehouse/input-table writeback design and security "
            "model before conversion."
        )

    return {
        "decision": decision,
        "label": label,
        "recommended": decision
        in {"migrate-now", "redesign-then-migrate"},
        "wave": wave,
        "technicalFitScore": fit_score,
        "reason": reason,
        "nextAction": next_action,
        "blockers": blockers,
        "basis": "technical-feasibility-from-source",
    }


def prioritize_projects(projects: list[dict]) -> list[dict]:
    for project in projects:
        project["recommendation"] = migration_recommendation(project)
    projects.sort(
        key=lambda item: (
            RECOMMENDATION_ORDER[item["recommendation"]["decision"]],
            -item["recommendation"]["technicalFitScore"],
            item["complexityScore"],
            item["project"].casefold(),
        )
    )
    for rank, project in enumerate(projects, start=1):
        project["priorityRank"] = rank
    return projects


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
            "## Migration recommendations",
            "",
            "> Recommendations rank technical migration fit from inspected source. "
            "Business value, usage, ownership, and decommissioning decisions require "
            "separate evidence.",
            "",
            "| Rank | Project | Recommendation | Wave | Fit | Why | Next action |",
            "|---:|---|---|---|---:|---|---|",
        ]
    )
    for project in report["projects"]:
        recommendation = project["recommendation"]
        lines.append(
            f"| {project['priorityRank']} | {project['project']} | "
            f"**{recommendation['label']}** | {recommendation['wave']} | "
            f"{recommendation['technicalFitScore']}/100 | "
            f"{recommendation['reason']} | {recommendation['nextAction']} |"
        )
    lines.extend(
        [
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


def html_report(report: dict) -> str:
    """Render the same ranked recommendation contract as standalone HTML."""

    def esc(value: object) -> str:
        return html.escape(str(value), quote=True)

    counts = report["recommendationSummary"]
    rows = []
    for project in report["projects"]:
        recommendation = project["recommendation"]
        blockers = ", ".join(recommendation["blockers"]) or "None"
        rows.append(
            "<tr>"
            f"<td>{project['priorityRank']}</td>"
            f"<td><strong>{esc(project['project'])}</strong></td>"
            f"<td><span class=\"decision {esc(recommendation['decision'])}\">"
            f"{esc(recommendation['label'])}</span></td>"
            f"<td>{esc(recommendation['wave'])}</td>"
            f"<td>{recommendation['technicalFitScore']}/100</td>"
            f"<td>{esc(project['readiness'])}</td>"
            f"<td>{esc(project['complexity']['class'])}</td>"
            f"<td>{esc(recommendation['reason'])}</td>"
            f"<td>{esc(recommendation['nextAction'])}</td>"
            f"<td>{esc(blockers)}</td>"
            "</tr>"
        )
    guide_rows = [
        "<tr>"
        f"<td>{esc(row['class'].title())}</td>"
        f"<td>{esc(row['typicalApp'])}</td>"
        f"<td>{esc(row['migrationPath'])}</td>"
        f"<td>{esc(row['deliveryClass'])}</td>"
        "</tr>"
        for row in report["migrationGuide"]["classes"]
    ]
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Streamlit → Sigma migration assessment</title>
  <style>
    body {{ font-family: system-ui, sans-serif; margin: 0 auto; max-width: 1500px;
      padding: 28px; color: #172033; line-height: 1.4; }}
    h1, h2 {{ margin-bottom: 8px; }}
    .note {{ background: #eff6ff; border-left: 4px solid #2563eb;
      padding: 12px 16px; margin: 16px 0; }}
    .summary {{ display: grid; grid-template-columns: repeat(4, minmax(150px, 1fr));
      gap: 12px; margin: 20px 0; }}
    .card {{ border: 1px solid #dbe3ef; border-radius: 10px; padding: 16px; }}
    .value {{ font-size: 28px; font-weight: 700; color: #1d4ed8; }}
    .table-wrap {{ overflow-x: auto; }}
    table {{ border-collapse: collapse; width: 100%; font-size: 13px; }}
    th, td {{ border: 1px solid #dbe3ef; padding: 8px; text-align: left;
      vertical-align: top; }}
    th {{ background: #f5f7fa; }}
    .decision {{ border-radius: 999px; padding: 3px 8px; white-space: nowrap;
      font-weight: 650; }}
    .migrate-now {{ background: #dcfce7; color: #166534; }}
    .redesign-then-migrate {{ background: #dbeafe; color: #1e40af; }}
    .architecture-review {{ background: #fef3c7; color: #92400e; }}
    .defer-until-unblocked {{ background: #fee2e2; color: #991b1b; }}
  </style>
</head>
<body>
  <h1>Streamlit → Sigma migration assessment</h1>
  <p>Ranked technical shortlist from static source inspection.</p>
  <div class="note"><strong>Recommendation basis:</strong> inspected source,
    readiness, unresolved gaps, security findings, migration disposition, and
    complexity. Usage and business value are not inferred.</div>
  <div class="summary">
    <div class="card"><div class="value">{counts['total']}</div>Total apps</div>
    <div class="card"><div class="value">{counts['migrateNow']}</div>Migrate now</div>
    <div class="card"><div class="value">{counts['redesignThenMigrate']}</div>Redesign then migrate</div>
    <div class="card"><div class="value">{counts['deferOrReview']}</div>Review / defer</div>
  </div>
  <h2>Recommended migration order</h2>
  <div class="table-wrap"><table>
    <thead><tr><th>Rank</th><th>Project</th><th>Recommendation</th><th>Wave</th>
      <th>Technical fit</th><th>Readiness</th><th>Complexity</th><th>Why</th>
      <th>Next action</th><th>Blockers</th></tr></thead>
    <tbody>{''.join(rows)}</tbody>
  </table></div>
  <h2>Complexity guide</h2>
  <div class="table-wrap"><table>
    <thead><tr><th>Class</th><th>Typical app</th><th>Path</th><th>Delivery</th></tr></thead>
    <tbody>{''.join(guide_rows)}</tbody>
  </table></div>
  <p class="note">Metadata-only inventory such as <code>SHOW STREAMLITS</code>
    cannot establish migration complexity. Export and inspect each app's source
    before assigning a migration recommendation.</p>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("sources", nargs="+", help="Project directories/main files")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    parser.add_argument("--html-out", type=Path)
    args = parser.parse_args()
    projects = prioritize_projects(
        [assess(Path(source)) for source in args.sources]
    )
    recommendation_counts = {
        decision: sum(
            project["recommendation"]["decision"] == decision
            for project in projects
        )
        for decision in RECOMMENDATION_ORDER
    }
    report = {
        "kind": "streamlit-assessment",
        "readOnly": True,
        "recommendationBasis": {
            "scope": "technical-feasibility-from-inspected-source",
            "doesNotInclude": [
                "business value",
                "usage",
                "stakeholder priority",
                "decommissioning approval",
            ],
            "metadataOnlyInventoryIsInsufficient": True,
        },
        "migrationGuide": {
            "classes": COMPLEXITY_GUIDE,
            "calendarEstimatePolicy": (
                "Not inferred automatically; calibrate with observed organization telemetry."
            ),
        },
        "sigmaBenefits": SIGMA_BENEFITS,
        "recommendationSummary": {
            "total": len(projects),
            "migrateNow": recommendation_counts["migrate-now"],
            "redesignThenMigrate": recommendation_counts[
                "redesign-then-migrate"
            ],
            "deferOrReview": (
                recommendation_counts["architecture-review"]
                + recommendation_counts["defer-until-unblocked"]
            ),
        },
        "projects": projects,
        "shortlist": [
            {
                "rank": item["priorityRank"],
                "project": item["project"],
                "readiness": item["readiness"],
                "complexityScore": item["complexityScore"],
                "complexity": item["complexity"]["class"],
                "deliveryClass": item["complexity"]["deliveryClass"],
                "migrationDisposition": item["migrationDisposition"],
                "recommendation": item["recommendation"],
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
    if args.html_out:
        args.html_out.parent.mkdir(parents=True, exist_ok=True)
        args.html_out.write_text(html_report(report), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
