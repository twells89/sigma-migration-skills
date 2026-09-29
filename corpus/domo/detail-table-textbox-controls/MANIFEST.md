# domo / detail-table-textbox-controls

Sanitized synthetic regression extracted from a field-shaped AI call dashboard.
It pins three independent migration contracts:

- `badge_basic_table` with ungrouped VALUE-mapped text/timestamp fields remains
  a row-level detail table (no invalid `Sum(text/date)` formulas).
- data-backed `badge_textbox` becomes a latest-value KPI.
- an Analyzer Quick Filter on a combo chart uses a hidden table source and
  remains scoped to that chart.

The fixture also carries an explicit `kpi-overrides.json` entry confirming that
the source intentionally authored `COUNT(ContactId)`; QA accepts this operator
evidence instead of repeatedly raising the default-count suspicion.

## Expectations

```json
{
  "artifacts": [
    {"path": "fixtures/datasets.json", "format": "json"},
    {"path": "fixtures/cards.json", "format": "json"},
    {"path": "fixtures/beast-modes.json", "format": "json"},
    {"path": "fixtures/kpi-overrides.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
