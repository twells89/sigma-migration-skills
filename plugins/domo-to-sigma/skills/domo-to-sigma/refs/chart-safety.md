# Domo chart safety

Load this reference in Phase 5 when a card uses a categorical color split or
period-over-period comparison.

## Category-color cardinality

`color.by: category` is only valid for a bounded categorical split. Never bind
an aggregate Beast Mode to that channel: each numeric result becomes a distinct
series. A field-found Auto-Pay migration produced 2,013 categories and made the
page unresponsive.

Aggregate/window Beast Modes mapped as Domo `SERIES` are measures, even when
their card-column record omits `aggregation`. The live orchestrator also counts
distinct `SERIES` values in Domo card-data. Above 100 observed values it emits
`chart-color-overrides.json`; the workbook builder omits the color channel and
records the measured cardinality in `warnings.json`.

`qa-check.rb` hard-fails any aggregate formula that still escapes onto a
category-color channel.

## Period-over-period reconstruction

Domo authors a POP card with only a date and one value. Its result adds
`POP_PERIOD` and `POP_INDEX`, but those are synthetic query channels—not
warehouse columns. The converter reconstructs them from the source
`dateRangeFilter`:

- `dateTimeRange.dateTimeRangeType: INTERVAL_OFFSET` defines the selected period.
- `periods.type: COMBINED` with `OFFSET` entries defines each comparison. When
  the private analyzer definition omits this block, discovery retries the
  official public `GET /v1/cards/chart/{urn}` CardDefinition. If it is still
  absent, the early Domo card-data snapshot reconstructs offsets from its
  `POP_PERIOD`/`POP_INDEX` channels and records a warning.
- One hidden, filtered table is emitted per period.
- Helpers align dates by the source graph grain, then a union preserves overlap
  rows that belong to more than one comparison.
- The visible `combo-chart` exposes one explicit measure per period: selected
  period as bars and comparison periods as lines.
- Parity pivots Domo's synthetic transport (`ITEM`, `VALUE`, `POP_PERIOD`,
  `POP_INDEX`, including null date-density rows) to that same visible
  grain-by-period table before strict comparison; raw card-data and a rendered
  Sigma combo have intentionally different row/column shapes.

Workbook union sources do not accept a custom `name`; formulas use Sigma's
server-derived `Union of N Sources` namespace.

This covers month-over-month, year-over-year, and multiple comparison periods
such as current year plus three prior years.

`badge_pop_bar_line` does not prove that a comparison exists. A live 2026-09-18
probe created and then deleted five disposable cards through Domo's API:

- One and three declared offsets returned `ITEM`, `VALUE`, `POP_PERIOD`, and
  `POP_INDEX`; these take the reconstruction path above.
- With `periods` omitted, a one-measure card returned only `ITEM` and `VALUE`.
- With `periods` omitted, two- and four-measure cards returned `ITEM`, `VALUE`,
  and one `SERIES` channel per extra authored measure—still no synthetic POP
  channels.

Those latter shapes are ordinary selected-period Domo queries despite the POP
chart-type token. When a successful public probe or captured card-data proves
that shape, preserve one authored measure as a single-series bar, or multiple
authored measures as a combo (first bar, remaining lines), and apply the source
`INTERVAL_OFFSET` window. Record that no source comparison was present; do not
drop the card and do not claim that a comparison was rebuilt.

Do not confuse one authored Y-axis field with one rendered series. A customer
Analyzer screenshot showed exactly one `SUM of 1-30` binding while the card
visibly rendered current-period bars plus a prior-period line. If a one-measure
card has neither comparison metadata nor a completed no-periods probe, skip it
with a named unresolved-metadata warning rather than flattening away a
comparison that Analyzer may still derive.
