# metabase / orders-overview

Synthetic Metabase model and dashboard fixtures from the plugin. The case
exercises MBQL joins, expressions, metrics, FK relationships, dashboard tabs,
controls, exact 24-column layout, KPI/cartesian/pie/pivot/funnel elements, and
the released wrapped/flat workbook code representation.

## Converter

```bash
cd plugins/metabase-to-sigma/skills/metabase-to-sigma/converter
npm ci
node --import tsx/esm cli.ts ../fixtures/orders-model.card.json \
  --metadata ../fixtures/metadata.json \
  --connection PLACEHOLDER-CONNECTION-ID --database DEMO_DB --schema DEMO \
  --envelope > /tmp/metabase-dm.json
node --import tsx/esm cli.ts ../fixtures/exec-overview.dashboard.json \
  --metadata ../fixtures/metadata.json --dm PLACEHOLDER-DM-ID \
  --envelope > /tmp/metabase-workbook.json
cd ../../../../..
python3 corpus/lib/corpus_check.py normalize /tmp/metabase-dm.json \
  corpus/metabase/orders-overview/golden/data-model.json
python3 corpus/lib/corpus_check.py normalize /tmp/metabase-workbook.json \
  corpus/metabase/orders-overview/golden/workbook.json
```

## Features exercised

- A curated model with a warehouse-table join, calculated columns, metric, FK
  relationship, and derived relationship view.
- A wrapped workbook with metadata-only pages, flat elements, hidden Data
  page, and authoritative canonical `<Page>`/`<Element>` layout.
- Current `columnId` pointers for KPI, pie, pivot shelves, and funnel channels.
- Two controls wired through hidden base tables, ordered after their targets.
- Unsupported behavior remains explicit: click behavior and a relative
  date-range default warn instead of being guessed.

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/metabase-to-sigma/skills/metabase-to-sigma/fixtures/orders-model.card.json", "format": "json"},
    {"path": "../../../plugins/metabase-to-sigma/skills/metabase-to-sigma/fixtures/exec-overview.dashboard.json", "format": "json"},
    {"path": "../../../plugins/metabase-to-sigma/skills/metabase-to-sigma/fixtures/metadata.json", "format": "json"},
    {"path": "checks.sh", "format": "text"},
    {"path": "check_workbook.py", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 4,
      "columns": 36,
      "metrics": 1,
      "relationships": 1,
      "warnings": 0,
      "element_names": ["Order Fact", "Customer Dim", "Orders Model", "Order Fact View"],
      "metric_names": ["Total Revenue"],
      "relationship_names": ["CUSTOMER_DIM"]
    },
    "workbook.json": {
      "pages": 3,
      "elements": 13,
      "columns": 22,
      "metrics": 0,
      "relationships": 0,
      "warnings": 3
    }
  }
}
```
