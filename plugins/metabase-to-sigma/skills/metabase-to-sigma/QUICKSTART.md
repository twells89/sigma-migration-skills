author: Sigma Computing
summary: Migrating from Metabase made easy — convert Metabase models and dashboards to Sigma with Claude Code
id: developers_migrating_from_metabase_made_easy
categories: Developers, Migration, AI
environments: Web
status: Draft
feedback link: https://github.com/twells89/metabase-to-sigma/issues

# Migrating from Metabase to Sigma made easy

## Introduction & why it matters
Duration: 2

Rebuilding Metabase content in a new BI tool by hand means re-deriving every model,
re-typing every custom expression, and hoping the numbers still tie out.

This quickstart automates the path with **your coding agent** (Claude Code, Cursor,
Cortex Code, …) + the Metabase→Sigma skills: discover content over the Metabase REST
API, translate MBQL to Sigma formulas, build a Sigma data model and matching workbook,
and **verify data parity** against the same warehouse.

positive
: **Validation status:** discovery, extraction, scoring, and the conversion
semantics were live-validated end to end. The released wrapped/flat workbook
payload is covered offline; use the POST/readback, parity, and PNG gates on
every migration before calling it complete.

positive
: Metabase is open source — you can rehearse the entire migration on a local
`docker run metabase/metabase` pointed at the same warehouse Sigma reads.

## Who this is for
Duration: 1

- Sigma SEs and technical CSMs
- Migration partners
- Metabase admins evaluating a move to Sigma

## Prerequisites
Duration: 2

- **A coding agent that runs skills** — Claude Code (CLI or desktop), Cursor, etc.
- **Metabase REST access** — an API key (v49+: Admin → Settings → Authentication →
  API keys) or username/password. Open-source Metabase is fully sufficient.
- **Sigma API credentials** (`SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`).
- **The same warehouse on both sides** — Sigma's connection must reach the database
  Metabase queries (the bundled H2 Sample Database is not reachable from Sigma).

## Assess the estate (optional, ~minutes)
Duration: 5

```bash
export MB_BASE="https://<your-metabase>" MB_KEY="mb_…"
eval "$(skills/metabase-to-sigma/scripts/get-metabase-session.sh)"
bash skills/metabase-assessment/scripts/discover-metabase.sh --out /tmp/mb-assess
node skills/metabase-assessment/scripts/score-coverage.mjs --in /tmp/mb-assess/specs --out /tmp/mb-assess
node skills/metabase-assessment/scripts/render-report.mjs --out /tmp/mb-assess
open /tmp/mb-assess/readout.html
```

The readout scores every card/dashboard against the converter's exact coverage and
hands you a wave plan: migrate-first, moderate, needs-review.

## Migrate a dashboard
Duration: 15

Ask your agent:

> Migrate my Metabase dashboard "Exec Overview" to Sigma.

The `metabase-to-sigma` skill walks Phases 0–4: discover (cards + **database
metadata** — MBQL refs columns by integer id), convert models → data model, check
for a reusable existing DM, POST + read back (hard-fails on any error-typed column),
convert the dashboard → workbook wired to the DM, apply the 24-col layout, then run
the parity plan and compare totals to the Metabase cards.

Every construct without a clean Sigma analog (cum-sum, segment refs, progress
viz, click behaviors) is **flagged with a warning, never faked**.

## Verify & wrap up
Duration: 3

- Parity gate: `assert-parity --check` green against the Metabase numbers (mind
  Metabase's result cache — Sigma reads live).
- Layout gate: `apply-layout.mjs` reported `layoutOnReadback: true`.
- Row security (Pro/EE sandboxing): the skill detects, asks, and ports to Sigma
  user attributes — skipping is loud and explicit.
