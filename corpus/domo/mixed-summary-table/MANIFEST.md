# domo / mixed-summary-table

Synthetic regression for Domo `badge_table` cards that mix unaggregated and
aggregated `VALUE` roles. Domo treats unaggregated VALUE fields as implicit
group-by dimensions when the same summary table contains explicit aggregates.

The fixture proves text categories remain bare dimension references, explicit
aggregates remain measures, and aggregate Beast Modes stay calculations.

## Expectations

```json
{
  "artifacts": [
    {"path": "fixtures/datasets.json", "format": "json"},
    {"path": "fixtures/cards.json", "format": "json"},
    {"path": "fixtures/beast-modes.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ]
}
```
