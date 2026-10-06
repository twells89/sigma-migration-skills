# microstrategy-to-sigma

Claude Code plugin for migrating **MicroStrategy (Strategy One)** to
**Sigma**, in the same format and phase structure as the
[sigma-migration-skills](https://github.com/twells89/sigma-migration-skills)
converters (Tableau, Power BI, Qlik, ThoughtSpot, QuickSight, Cognos,
Metabase). Built standalone so it can graduate into that marketplace's
`plugins/`.

## Status: live-validated (classic-schema grid path)

Validated end-to-end on a live Strategy One trial against Snowflake:
dossier + classic semantic model (star schema with heterogeneous key columns,
facts, metrics incl. `Count<Distinct=True>` and a compound margin) →
Sigma data model + workbook with **exact parity — 19/19 + 30/30 + 3/3 rows**
(money/counts exact, ratios rel 1e-6), including one report whose
Analytical-Engine row-collapse quirk is reproduced deterministically
(`resolve_ae_winners.py`).

**Roadmap** (deliberately not in the validated path — see
`skills/microstrategy-to-sigma/refs/design-notes.md`):
chart-visualization emission (the dossier viz-type lookup is
extraction-validated; only `grid` builds are parity-proven) and filters /
selectors / page-by / prompts.

Strategy One's newer **"Data Model" object** (Mosaic, `/api/model/dataModels`)
IS covered: extraction + authoring + parity-validated live querying
(`connect_live`, exact 19/19 vs the classic fixture) — see
`skills/microstrategy-to-sigma/refs/datamodels.md` and
`scripts/{build,extract}_datamodel.py`. Its `securityFilters` (RLS) remain
the future RLS-port surface; browser OAuth does not make that unsupported
translation automatic, so a security-filter finding still requires an explicit
port/skip decision.

## What's in the box

| Skill | What it does |
|---|---|
| [`skills/microstrategy-to-sigma`](skills/microstrategy-to-sigma/SKILL.md) | The converter: REST discovery → `extract.py` (dossier + semantic model → `bundle.json`) → `convert.py` (→ Sigma DM + workbook specs) → POST + readback gate → `verify_parity.py` (hard parity gate). Plus `resolve_ae_winners.py` for the Analytical-Engine row-collapse trap. |
| [`skills/microstrategy-assessment`](skills/microstrategy-assessment/SKILL.md) | Read-only estate inventory + readout: project/report/dossier counts, viz-type histogram (walking panel stacks recursively), datasource types, per-dossier complexity flags + migrate-first/moderate/needs-review tags scored against the converter's actual viz coverage. |

The hard-won knowledge lives in `skills/microstrategy-to-sigma/refs/`:
`mstr-rest-api.md` (every verified REST gotcha — changeset locks, lowercase
response headers, session-bound dossier flows, the datasource trio),
`ae-row-collapse.md`, `viz-type-mapping.md`, `design-notes.md`.

## Quick start

```bash
# MicroStrategy creds (session auth — no API-key concept exists)
export MSTR_BASE_URL="https://<host>/MicroStrategyLibrary"
export MSTR_USERNAME="..." MSTR_PASSWORD="..."   # or ~/.sigma-migration/env

# Sigma (preferred one-time interactive setup; later runs reuse the keychain)
export SIGMA_BASE_URL="https://<your-published-sigma-api-host>"
eval "$(bash skills/microstrategy-to-sigma/scripts/browser-login.sh)"
# SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET remain the unattended fallback.

# Assess the estate (read-only)
python3 skills/microstrategy-assessment/scripts/assess.py --out /tmp/mstr-assessment

# Migrate (see skills/microstrategy-to-sigma/SKILL.md for the full phase walkthrough)
python3 skills/microstrategy-to-sigma/scripts/extract.py <dossierId> bundle.json
python3 skills/microstrategy-to-sigma/scripts/convert.py --bundle bundle.json \
  --connection-id <SIGMA_CONN> --database <DB> --folder-id <FOLDER>
# ... POST DM spec -> readback ids -> re-emit workbook -> POST -> verify_parity.py
```

All Sigma-side Python live paths use the co-located shared client: they reuse a
valid bearer, proactively refresh known-old tokens, prefer the browser keychain,
fall back to client credentials, and retry once after HTTP 401.

Or install as a Claude Code plugin and just ask: *"migrate my MicroStrategy
dossier to Sigma"* / *"assess my MicroStrategy estate."*

`fixtures/` contains the real validated artifacts: `bundle.json` (the
converter contract, extracted live), `expected_parity.json` (the MSTR ground
truth), `dossier_definition.json`, plus the fixture builders
(`build_schema.py`, `BUILD_SPEC.md`) for rehearsing the loop on a fresh trial.

## Design contract

Core principle (shared with every sibling converter): **flag, never fake.**
Anything without a clean Sigma analog (unmapped viz types, panel-stack
content) is surfaced as a loud warning with a readable table fallback — never
silently wrong numbers. Parity is a hard gate: a migration is green only when
`verify_parity.py` passes against numbers taken from MicroStrategy itself.

## Graduating into sigma-migration-skills

This repo is already in the marketplace plugin layout
(`.claude-plugin/plugin.json` + `skills/<name>/SKILL.md|scripts|refs|fixtures`).
To graduate: drop the repo content into
`sigma-migration-skills/plugins/microstrategy-to-sigma/` — no path changes
needed (all script cross-references are relative).

## License

MIT
