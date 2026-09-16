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
- `periods.type: COMBINED` with `OFFSET` entries defines each comparison.
- One hidden, filtered table is emitted per period.
- Helpers align dates by the source graph grain, then a union preserves overlap
  rows that belong to more than one comparison.
- The visible `combo-chart` exposes one explicit measure per period: selected
  period as bars and comparison periods as lines.

Workbook union sources do not accept a custom `name`; formulas use Sigma's
server-derived `Union of N Sources` namespace.

This covers month-over-month, year-over-year, and multiple comparison periods
such as current year plus two prior years. If the compare metadata is absent or
uses an unrecognized shape, the card is skipped with a named warning rather
than silently emitted as a one-series chart.
