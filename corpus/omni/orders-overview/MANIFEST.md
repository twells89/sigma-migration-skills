# omni / orders-overview

Synthetic Omni shared model (orders + users) and a two-tile dashboard export.
Exercises warehouse columns, a CONCAT dimension, sum / count / ratio measures,
a many-to-one relationship, a skipped query view, Mustache RLS, access grants,
line + KPI tiles, and a date control. No tokens.

## Artifacts

Plugin fixtures under `plugins/omni-to-sigma/skills/omni-to-sigma/fixtures/orders-overview/`.

## Converter

```bash
ruby scripts/convert-dm.rb --model-dir fixtures/orders-overview --topic orders --out dm.json
ruby scripts/build-workbook.rb --export fixtures/orders-overview/dashboard-export.json \
  --model-dir fixtures/orders-overview --folder-id fixture-folder --out wb.json
```

Run from the `omni-to-sigma` skill directory. `checks.sh` byte-diffs both
goldens after id normalization.

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/omni-to-sigma/skills/omni-to-sigma/fixtures/orders-overview/public/orders.view", "format": "yaml"},
    {"path": "../../../plugins/omni-to-sigma/skills/omni-to-sigma/fixtures/orders-overview/public/users.view", "format": "yaml"},
    {"path": "../../../plugins/omni-to-sigma/skills/omni-to-sigma/fixtures/orders-overview/public/scratch.query.view", "format": "text"},
    {"path": "../../../plugins/omni-to-sigma/skills/omni-to-sigma/fixtures/orders-overview/orders.topic", "format": "yaml"},
    {"path": "../../../plugins/omni-to-sigma/skills/omni-to-sigma/fixtures/orders-overview/relationships.yaml", "format": "yaml"},
    {"path": "../../../plugins/omni-to-sigma/skills/omni-to-sigma/fixtures/orders-overview/model.yaml", "format": "yaml"},
    {"path": "../../../plugins/omni-to-sigma/skills/omni-to-sigma/fixtures/orders-overview/dashboard-export.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 3,
      "columns": 20,
      "metrics": 3,
      "relationships": 1,
      "warnings": 5,
      "element_names": ["ORDERS", "USERS", "Orders"],
      "metric_names": ["Order Count", "Total Revenue", "Revenue per Order"],
      "relationship_names": ["users"]
    },
    "workbook.json": {
      "pages": 2,
      "elements": 4,
      "columns": 6,
      "metrics": 0,
      "relationships": 0,
      "warnings": 0,
      "element_names": ["Orders Data", "Created", "Revenue by month", "Total revenue"]
    }
  }
}
```
