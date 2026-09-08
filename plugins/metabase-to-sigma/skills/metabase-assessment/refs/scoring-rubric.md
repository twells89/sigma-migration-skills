# Metabase→Sigma coverage scoring rubric

`score-coverage.mjs` classifies every feature into one of four buckets by
detecting the **exact** signals the `metabase-to-sigma` converter
(`converter/metabase.ts`, `translateMbqlExpr`) acts on. It does not re-run the
converter; it mirrors what the converter translates cleanly vs. flags. MBQL is
already-parsed JSON, so the scorer recurses the `dataset_query` trees and
matches op names — no regex DSL parsing. Each detected gap is recorded with a
count, the reason, and the remediation shown in the readout.

## Buckets

| Bucket | Meaning | Converter behavior |
|---|---|---|
| **auto** | Converts cleanly, zero touch | emitted directly (table source, breakout, aggregation, expression, chart, control, sql element) |
| **hint** | Converts, but review one thing (no logic rebuild) | converts; a sequencing/wiring/fan-out check (nested card, field filter, join) |
| **manual** | Brief re-creation in Sigma | converter passes through + warns; you rebuild it by hand |
| **unhandled** | No clean Sigma analog — needs a human design decision | converter emits a flagged placeholder + a loud warning (never silent, never guessed) |

## Cost / value / tag (same framework as every `*-assessment` skill)

- `cost  = 10·n_unhandled + 3·n_manual + 1·n_hint`
- `value = 10 · view_count` when the instance exposes `view_count` on cards/dashboards (**v50+**); else `10 · n_features` *(proxy — see `usage-telemetry.md`)*
- `score = value / (1 + cost)`
- complexity: `n_unhandled>0 → high`; else `n_manual>0 → medium`; else `low`
- tag: `n_unhandled≥1 → needs-review`; else `(manual+unhandled)==0 → migrate-first`; else `score≥10 → easy-win`; else `moderate`
- `pct_auto_migratable = (n_auto + n_hint) / n_features` — hint is a review, not rework, so it counts as auto-migratable.

## Card signals (from `metabase.ts` / the converter's `expression-dsl.md`)

| Signal | Bucket | Reason | Remediation |
|---|---|---|---|
| table source (`source-table: <int>`) | auto | → the model/DM element for the warehouse table | — |
| breakout (no binning) | auto | → Sigma grouping / chart axis (`temporal-unit` → `DateTrunc`) | — |
| translated aggregation — `count/sum/avg/min/max/median/distinct/stddev/var/percentile/count-where/sum-where/share` (+ `aggregation-options` name wrapper) | auto | → `Sum/Avg/CountIf/SumIf/Percentile/…` via `translateMbqlExpr` | — |
| translated expression/filter op — arithmetic, `case`, `coalesce`, `concat`, string fns (`substring/trim/upper/lower/length/replace/regex-match-first/split-part`), math (`round/floor/ceil/abs/sqrt/exp/power/log`), date fns (`datetime-add/-subtract/-diff`, `get-*`, `now`, `relative-datetime`), comparisons, `between`, `is-null/not-null/is-empty/not-empty`, `starts-with/ends-with/contains/does-not-contain`, `time-interval`, `inside` | auto | maps via `translateMbqlExpr` (multi-value `=` → `Or` chain — Sigma has no `IsIn`) | — |
| native SQL card | auto | the SQL text → a Sigma Custom SQL (`sql`) element verbatim | — |
| plain template tag (`type: text/number/date`) | auto | → a Sigma `=`-parameter control | — |
| supported display — `table/bar/row/line/area/combo/scatter/pie/scalar/smartscalar/trend/pivot/map/funnel/gauge/waterfall/sankey` | auto | → native Sigma table/chart/pivot/KPI/map element | — (note: the `smartscalar`/`trend` auto "vs previous period" comparison line is a manual follow-up — the KPI value itself converts) |
| nested-card source (`source-table: "card__N"`) | hint | built on another saved card (usually a model) | converts to an element sourced from card N's element — sequence the source card first; recorded in `uses_cards` for the wave plan |
| field-filter template tag (`type: dimension`) | hint | the tag expands to a whole WHERE clause at runtime | becomes a Sigma control on the target column + an element filter — verify widget type + default |
| nested-card template tag (`{{#N}}`, `type: card`) | hint | inlines another saved question as a sub-query | sequence the referenced card first |
| explicit MBQL `joins` | hint | converts to a Sigma DM `join` source | review fan-out (row multiplication) before trusting aggregates — same risk as in Metabase |
| `binning` opts on a breakout | manual | numeric histogram buckets | recreate with `BinFixed()`/`BinCount()` in the consuming workbook element |
| `["segment", id]` ref | manual | definition lives in another object | inline the segment's MBQL filter (`GET /api/segment/{id}`) |
| `["metric", id]` ref (legacy) | manual | definition lives in another object | inline the metric's aggregation (`GET /api/legacy-metric/{id}`) |
| `click_behavior` (top-level or per-column) | manual | cross-filter / drill link | re-implement as a Sigma action |
| snippet template tag (`type: snippet`) | manual | splices a shared SQL snippet | inline the snippet text into the Custom SQL |
| optional `[[…]]` SQL block | hint | Metabase includes it only when the tag has a value; Sigma has no optional-clause syntax | field-filter/default-carrying blocks stay active; others are dropped (Metabase's empty-value behavior) with a loud warning — review each |
| conditional formatting — `single` rule | auto | threshold rule → Sigma `conditionalFormats` entry | — |
| conditional formatting — gradient/`range` scale | manual | backgroundScale spec shape not live-verified | recreate in the Sigma UI |
| `object` display (record detail) | manual | single-record detail view | flagged table; recreate detail with element filters / drill |
| multi-stage query (pMBQL `stages`>1 / `source-query`) | manual | a sub-query, not a flat card | rebuild as chained Sigma elements; converter flags + skips |
| `cum-sum` / `cum-count` / `offset` | unhandled | running-total / lag window — the window scope lives on the consuming element | rebuild with `CumulativeSum` / `Lag` in the date-grouped workbook element (proven pattern); converter emits a flagged placeholder |
| display `progress` | unhandled | no faithful native Sigma mapping is verified | data preserved as a flagged table; choose an explicitly approved replacement |
| unmapped MBQL op | unhandled | no confirmed Sigma mapping | translate by hand; converter emits `/* unmapped: <op> */` + a loud warning |
| sandboxing policy (EE, from `sandboxes.json`) | unhandled | GTAP row-level security per group | port to Sigma user attributes + DM filters via the shared RLS engine (`apply_sigma_rls.py`) — opt-in, reviewed per policy |

## Dashboard signals

| Signal | Bucket | Reason | Remediation |
|---|---|---|---|
| dashcard with a supported card display | auto | 24-col grid → Sigma's 24-col layout 1:1 | — |
| text/heading card (`card_id: null` + `virtual_card`) | auto | markdown → Sigma text element | — |
| `parameters[]` | auto | → Sigma controls (+ `parameter_mappings` → per-card filter targets) | — |
| `tabs[]` | auto | → workbook pages | — |
| `click_behavior` on a dashcard | manual | cross-filter / drill link | re-implement as a Sigma action |
| dashcard with display `progress` | unhandled | no faithful native Sigma mapping is verified | flagged table; choose an approved replacement |

Both `dashcards[]` (v48+, `size_x/size_y`) and legacy `ordered_cards[]`
(`sizeX/sizeY`) shapes are accepted.

## Production calibration (a 7k-card production estate, 2026-06)

First production run of this scorer — Metabase Cloud v1.61.4, 7,023 cards /
12 models / 1,548 dashboards (8,571 artifacts), 100% pMBQL. Results to sanity-
check your own runs against:

- The historical run reported **97% auto-migratable** under the June coverage
  catalog. Funnel, gauge, waterfall, and sankey were then counted unhandled;
  the current scorer correctly counts them as native/auto, so rescore the
  source estate before quoting an exact current percentage.
- tags: **migrate-first 8,039 · easy-win 272 · needs-review 183 · moderate 77**
- display histogram (cards): table 2999 · bar 1604 · line 1176 · combo 449 ·
  scalar 259 · pie 135 · row 130 · funnel 83 · area 67 · pivot 39 · object 37 ·
  waterfall 15 · sankey 13 · gauge 11 · scatter 3 · progress 3. Current
  coverage converts funnel/waterfall/sankey/gauge natively; progress remains
  flagged and object remains a manual detail-table route.
- 45% of cards carry template tags; 53% of dashboards carry parameters; 17%
  use tabs; `view_count` available (usage-based value path exercised)

## Calibrating against the bundled fixtures

Running against `fixtures/` (4 cards + 2 dashboards) must produce all four buckets:

- **Revenue by Month** (101) — all-auto MBQL (sum/count, month breakout, multi-value `=` filter, line) → `migrate-first`, low.
- **Cumulative Revenue** (102) — `cum-sum` → `needs-review`, high (the `-` Profit expression still scores auto).
- **Orders Cleaned (model)** (103) — native SQL model; `{{status}}` text tag auto, `{{date_range}}` dimension field filter → 1 **hint**; `migrate-first`, low.
- **Executive Overview** (201) — funnel dashcard → **auto/native**; a
  `click_behavior` → **manual**; parameter/tab/line/text → auto; `view_count:
  240` exercises the usage-based value path.
- **Filtered Revenue (pMBQL Native + Tags)** (104) — modern `lib/type` format: plain tags auto, field-filter + card tags + optional block → **hints**; `migrate-first`.
- **Regional Ops (pMBQL)** (202) — pMBQL dashboard: parameters auto, object dashcard → **manual**.

If those don't show up, the scorer regressed.
