# domo / live-shapes

**Regression fixture for the shapes only a LIVE Domo instance produces.** Derived
from a real Tier-A run (2026-07-30) and then fully anonymised — neutral dataset
ids (`ds-fact` / `ds-dim`), neutral column names (`amount`, `margin`, `channel`,
`event_date`, …), neutral card titles. No customer or warehouse identifiers.

The sibling `orders-smoke` case is a hand-written synthetic that exercises
`build-dm.rb`'s happy path. This case exists for a different reason: **every bug it
guards against passed the offline suite before it was caught live.** The shapes
here are the ones the docs got wrong, so they are the ones most likely to regress.

Evidence and the full story:
`plugins/domo-to-sigma/skills/domo-to-sigma/refs/live-validation-2026-07-30.md`.

## Artifacts

| File | What it is |
|---|---|
| `fixtures/datasets.json` | 2 DataSets carrying a real `schema.columns` array — the PUBLIC LIST endpoint returns `columns` as an Integer COUNT with no schema, which crashed `build-dm` (`29.each`) and would otherwise have posted a column-less DM |
| `fixtures/cards.json` | 15 cards from the live run: 7 element kinds, `subscriptions.big_number` summary numbers, `datasources[].dataSourceId` bindings, `mapping` roles, `calendar` pseudo-columns + `dateGrain`, a combo whose measures bind via SERIES, a second-dataset card, and a table whose summary number is a COUNT |
| `fixtures/formulas.json` | 5 Beast Modes, all class `aggregate`, with hand-authored `sigmaFormula`s. Historical reason: the shared converter could not translate `CASE WHEN` / `COUNT(DISTINCT)` (beads jva2/sqp1), and a separate double-bracketing collision (bead qorq) corrupted real ALL-CAPS Domo column refs (`[[Net Revenue]]` instead of `[Net Revenue]`) even after that fix. **All three fixed 2026-07-30** (sigma-data-model-mcp PR #115 then PR #116) — re-verified live: all four of this corpus's Beast Modes that needed a hand-authored override now convert correctly with the shared converter alone (two match byte-for-byte; two differ only by a semantically-inert wrapping paren). This fixture's entries are frozen as a regression pin of the shapes that USED to require an override, not because they still do |
| `fixtures/dataset-map.json` | warehouse map incl. a **`columnOverrides`** entry deriving a Domo-only DATE column from a `YYYYMMDD` integer key via `MakeDate` |

## Live-only shapes this case pins

- **`schema.columns` present** — build-dm hard-fails without it rather than
  emitting an empty data model
- **`format: {kind: datetime, formatString}`** — Sigma keys on `kind`; `{type: date}`
  is rejected and failed the whole DM POST
- **table `groupings`** — a Sigma `table` with a dimension + `Sum(...)` and NO
  `groupings` renders RAW DETAIL rows. Both tables here carry one. This is the
  single defect the anchors oracle caught numerically (source 58,494.90 vs a
  row-level 487.96)
- **aggregate Beast Modes are INLINED** as the element's measure formula, un-wrapped
  (`If(Sum(...)=0, 0, ...)`), never `Sum([Master/<BM name>])` — an aggregate Beast
  Mode is not a data-model column
- **calendar pseudo-columns → `DateTrunc`** — `CalendarMonth`/`CalendarWeek` do NOT
  exist in the DataSet; the real column + grain live on `dateGrain`
- **SERIES-mapped combo measures** — a combo binds measures via `SERIES`, not
  `VALUE`; treating SERIES as a dimension yields a chart with ZERO measures
- **`columnOverrides`** — a Domo-only column derived from one that does exist,
  rather than emitting a reference the warehouse cannot resolve
- **multi-dataset page** — the `ds-dim` card now routes to its own hidden
  sub-master (`master-ds-dim`, one master per DataSet — bead ziht landed) rather
  than being SKIPPED, **provided** a live `dm-ids.json`/`dm-spec.json` pair is
  available to resolve `ds-dim` to its data-model element; absent that pair, the
  card still falls back to today's named-warning SKIP rather than a silent
  mis-bind. `corpus/run-corpus.sh --check` for this case only validates
  `golden/data-model.json` (build-dm.rb's output) — no golden `chart-specs.json`
  exists here, so this case does not exercise the sub-master routing itself;
  that is pinned by `test/test-migrate-domo.rb`'s full-chain fixture instead

## Converter

In-repo converter (not MCP), offline:

```
cd corpus/domo/live-shapes
DOMO_DISCOVERY_DIR="$PWD/fixtures" SIGMA_SKIP_DOCTOR_GATE="corpus: offline" \
  ruby ../../../plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-dm.rb
python3 ../../lib/corpus_check.py normalize fixtures/dm-spec.json golden/data-model.json
```

`build-workbook.rb` can be run against the same `DOMO_DISCOVERY_DIR` to regenerate
`fixtures/chart-specs.json` — that is where the workbook-layer shapes above
(groupings, inlined Beast Modes, DateTrunc) are observable.

## Expectations

```json
{
  "artifacts": [
    {"path": "fixtures/datasets.json", "format": "json"},
    {"path": "fixtures/cards.json", "format": "json"},
    {"path": "fixtures/formulas.json", "format": "json"},
    {"path": "fixtures/dataset-map.json", "format": "json"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 2,
      "columns": 12,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0,
      "element_names": ["FACT", "DIM"]
    }
  }
}
```
