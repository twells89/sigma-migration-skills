---
name: streamlit-assessment
description: >-
  Read-only inventory and migration-readiness scoring for Streamlit source
  projects. Counts pages, SQL loaders, controls, elements, static-analysis gaps,
  and security-sensitive patterns, then produces a direct/redesign/blocked
  shortlist for streamlit-to-sigma.
user-invocable: true
---

# Streamlit migration assessment (read-only)

This skill never executes application code, writes to the source, or posts to
Sigma. It assesses exported/local source projects and hands selected targets to
`streamlit-to-sigma`.

Read [`refs/migration-readout.md`](refs/migration-readout.md) before presenting
complexity, delivery, calendar, or Sigma-benefit claims.

## Phase 0 — Intake

Accept one or more project directories or main Python files:

```bash
python3 scripts/assess-streamlit.py \
  /exports/app-one /exports/app-two \
  --out /tmp/streamlit-assessment.json \
  --markdown-out /tmp/streamlit-assessment.md \
  --html-out /tmp/streamlit-assessment.html
```

For Snowflake-hosted apps, export the source first. Do not request or inspect
secret values.

## Phase 1 — Inventory

The assessment reuses the converter's static analyzer and records:

- source files and project metadata
- pages and navigation shape
- SQL query loaders and inferred output columns
- controls and visible elements
- wrapper/config/loop expansion
- Pandas operations
- session state, forms, callbacks, data editors, and custom components
- security-sensitive patterns

No Streamlit process is started.

`SHOW STREAMLITS`, ownership, warehouse usage, and creation dates are inventory
evidence only. They cannot establish code complexity or migration fit. If source
has not been exported, label the app `source-required` and recommend source
collection—not migration. Never present a metadata-only inventory as the
migration assessment.

## Phase 2 — Score and shortlist

Each project receives:

- `direct` — supported surface with no restructuring/blocking gaps
- `redesign` — plugin/state/layout redesign required
- `blocked` — dynamic SQL, writeback, or another blocking gap
- `complexity.class` — `lite`, `medium`, or `complex`
- `complexity.deliveryClass` — `Fast / easy`, `Engineer-led`, or
  `Multi-specialist`
- `migrationDisposition` plus `migrationDispositions` — `spec-native`,
  `warehouse-backed`, `python-element-candidate`,
  `workbook-agent-candidate`, `manual-ui-finish`, `plugin`, `redesign`, and/or
  `blocked`
- `resolvedPatterns` and `unresolvedGapCount` — preserve source findings while
  keeping successfully lowered patterns out of readiness/complexity penalties
- `recommendation` — explicit `Migrate now`, `Migrate with redesign`,
  `Validate design, then migrate`, or `Resolve blockers, then migrate` path
- `recommendation.technicalFitScore`, `wave`, `reason`, `nextAction`, and
  `blockers` — explain rank and make the shortlist actionable

The score combines pages, queries, controls, elements, and weighted gaps. The
technical-fit score reverses that evidence into an intuitive recommendation
where higher means easier to migrate. Use the ranked recommendation to sequence
migrations, not as a calendar estimate. Markdown and HTML must both show the
recommendation, reason, blockers, and next action. Calendar ranges must come from
observed organization telemetry rather than hardcoded source-count promises.

Recommended order:

1. Direct SQL-backed dashboards.
2. Redesign candidates with native Sigma alternatives.
3. Plugin candidates.
4. Blocked apps after an explicit architecture/security decision.

## Output contract

```json
{
  "kind": "streamlit-assessment",
  "readOnly": true,
  "migrationGuide": {
    "classes": [],
    "calendarEstimatePolicy": "..."
  },
  "sigmaBenefits": [],
  "recommendationSummary": {},
  "projects": [],
  "shortlist": []
}
```

The assessment never creates issues automatically. Gap escalation remains
opt-in during the converter workflow.
