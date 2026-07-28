# domo-assessment

Read-only migration-readiness assessment for a Domo instance → Sigma.
Inventories the instance via Domo's Governance/DomoStats system datasets
(and, when reachable, the private card-definition API), scores every card
against the `domo-to-sigma` converter's exact coverage, rolls up a
value/cost-ranked migration shortlist, and renders a plain-Markdown readout.

```
SKILL.md                      phased workflow (Probe → Discover → Score → Render → Hand off)
PRIVACY.md                    customer-facing data-handling disclosure
scripts/
  probe-governance.rb         detect Tier A/B + audit scope; writes probe.json (read-only)
  discover-domo.rb            enumerate datasets/pages/cards/users; writes inventory.json + usage.json
  score-coverage.rb           value/cost/score/tag every card; writes complexity.json/shortlist.json/migration-plan.json
  render-readout.rb           renders readout.md (zero-dep)
  dup-dashboards.py           tool-neutral duplicate/consolidation detector (called by score-coverage.rb)
fixtures/
  tier-a/, tier-b/            committed synthetic governance-dataset fixtures for offline runs
refs/
  governance-datasets.md      which governance dataset powers which section + SQL pattern
  complexity-scoring.md       the full scoring rubric
  output-shapes.md            exact JSON shape of every stage's output
  readout-template.md         the readout.md section layout
```

## Quick start — offline (no creds, no network)

```bash
bash run-offline.sh
```

Runs the full pipeline (probe → discover → score → render) over the
committed `fixtures/tier-a` and `fixtures/tier-b` directories and asserts on
the emitted `complexity.json`, printing `OFFLINE GREEN: <tier>` per tier.
This is how a reviewer can prove the skill green without any Domo or Sigma
credentials.

## Quick start — live

```bash
export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=... DOMO_INSTANCE=<instance>
export DOMO_DEV_TOKEN=...        # omit for Tier B (public-API-only)
eval "$(../domo-to-sigma/scripts/get-domo-token.sh)"

OUT=/tmp/domo-assessment-<instance>
ruby scripts/probe-governance.rb   --out "$OUT"
ruby scripts/discover-domo.rb      --out "$OUT"
ruby scripts/score-coverage.rb     --in  "$OUT" --out "$OUT"
ruby scripts/render-readout.rb     --in  "$OUT" --out "$OUT"
```

Every stage also accepts `--from-fixtures <dir>` in place of a live
connection (see "Quick start — offline" above). Read-only throughout: every
live call is a `GET` or a `POST .../query/execute` `SELECT` against a
Domo-owned system dataset. Never posts to Sigma.

See `SKILL.md` for the full phase-by-phase docs (Probe → Discover → Score →
Render → Hand off to `domo-to-sigma`), the Tier A/B distinction, and current
"Open work". See `PRIVACY.md` for what crosses the Anthropic API vs. stays
local-only.
