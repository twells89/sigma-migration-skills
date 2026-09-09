# metabase-assessment

Read-only migration-readiness assessment for a Metabase instance → Sigma.
Mirrors the `tableau-assessment` pattern: inventory the collection tree, score
each model / question / dashboard against the **exact** coverage of the
`metabase-to-sigma` converter, roll up an estate auto-migration %, name every
gap, and render a branded HTML readout.

```
SKILL.md                      phased workflow (Connect → Discover → Score → Effort → Render)
PRIVACY.md                    customer-facing data-handling disclosure
scripts/
  discover-metabase.sh        bulk fast path: GET /api/card (one response) + parallel dashboard GETs + db metadata → inventory.json (read-only; --walk = legacy per-collection walk)
  mb-bulk-split.py            local splitter for the bulk card payload (stdlib-only, never networks)
  pmbql-normalize.mjs         pMBQL ("lib/" MBQL) → legacy normalizer (synced copy of the converter's)
  score-coverage.mjs          classify auto/hint/manual/unhandled vs. converter gaps; per-artifact + roll-up (zero-dep)
  render-report.mjs           branded standalone readout.html (zero-dep)
refs/
  mb-rest.md                  endpoints + the two auth shapes used + the fast path
  scoring-rubric.md           every gap signal → bucket → remediation + production calibration (7k-card estate)
  usage-telemetry.md          honest take on Metabase usage stats (view_count v50+ is thin; rich audit is Pro/EE)
fixtures/
  101.card.json               all-auto MBQL question
  102.card.json               cum-sum question (unhandled)
  103.card.json               native-SQL model with a field-filter tag (hint)
  104.card.json               pMBQL (modern "lib/" format) native question with every tag kind
  201.dashboard.json          native funnel dashcard + click behavior (manual) + view_count
  202.dashboard.json          pMBQL dashboard: tag-targeting parameters + object detail card
```

Discovery + scoring are **production-validated**: a 7,023-card / 1,548-dashboard
Metabase Cloud estate (v1.61.4, 100% pMBQL) discovered in ~1 minute and scored
97% auto-migratable. See `refs/scoring-rubric.md` § Production calibration.

## Quick start (offline, against the bundled fixtures)

```bash
node scripts/score-coverage.mjs --in fixtures --out /tmp/metabase-assessment-sample
node scripts/render-report.mjs  --out /tmp/metabase-assessment-sample
open /tmp/metabase-assessment-sample/readout.html
```

## Live

```bash
export MB_BASE="https://<host>"        # no trailing /api
export MB_KEY="mb_..."                 # or: export MB_SESSION="<token>"
bash scripts/discover-metabase.sh --probe
bash scripts/discover-metabase.sh --out /tmp/metabase-assessment-<env>
node scripts/score-coverage.mjs --in /tmp/metabase-assessment-<env>/specs --out /tmp/metabase-assessment-<env>
node scripts/render-report.mjs  --out /tmp/metabase-assessment-<env>
```

Read-only and all-free. Tableau is the reference point. Not a replacement for
a deeper hands-on engagement.
