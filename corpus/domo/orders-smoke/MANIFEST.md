# domo / orders-smoke

Synthetic Domo discovery fixture (no live Domo instance, no customer data): two
DataSets — `Order Fact` (5 columns) and `Customer Dim` (3 columns) — three
cards that reference both DataSets, four dataset-scoped Beast Modes
(projection, aggregate, window, LOD), two card-local projections (one used,
one unused), a numeric
`NOT_IN ["-3"]` card filter, and a hand-filled
`dataset-map.json` pointing both DataSets at a synthetic `DEMO_DB.DEMO`
warehouse schema. Exercises `build-dm.rb`'s only path: Domo DataSets are flat/
materialized tables (no relational model), so each used DataSet becomes one
Sigma warehouse-table element with row-level (PROJECTION) Beast Modes folded
in as DM calc columns while aggregate formulas become metrics.

## Artifacts

| File | What it is |
|---|---|
| `fixtures/datasets.json` | 2 DataSets: `Order Fact` (order_id, order_date, region, sales_amount, customer_id) + `Customer Dim` (customer_id, customer_name, segment) |
| `fixtures/cards.json` | 3 cards (KPI `badge_singlevalue`, bar `badge_vert_bar`, table `badge_table`) — determine which DataSets are "used" |
| `fixtures/beast-modes.json` | Source inventory covering dataset classes plus used/unused card-local formulas |
| `fixtures/formulas.json` | Translated formulas: projection → calc column, aggregate → metric, window/LOD → named deferrals, card-local → workbook/not-used |
| `fixtures/dataset-map.json` | FLAT per-dataset warehouse map: `{connectionId, database, schema, table, name}` (no `path` array) |
| `checks.sh` | Executes build/accounting/workbook paths and asserts numeric `-3` filter typing |

## Features exercised

- DataSet → warehouse-table element, one per USED DataSet (cards' `datasetId`
  determines usage)
- raw snake_case column names → clean Sigma display names in `[TABLE/Col]`
  base-column formulas
- `DATE` column → `format: {kind: datetime, formatString}` (Sigma keys on
  **kind**; `{type: date}` is REJECTED — live-validated 2026-07-30)
- dataset-scoped PROJECTION Beast Mode → DM calc column (`Order Year`)
- dataset-scoped aggregate Beast Mode → DM metric (`Total Sales Beast Mode`)
- window/LOD formulas receive named accounting deferrals
- referenced card-local projection → inline workbook formula; unused card-local formula → explicit `not-used`
- numeric Domo `NOT_IN ["-3"]` → Sigma list filter `values: [-3]`
- unmapped-dataset placeholder path is NOT exercised here — both DataSets are
  present in `dataset-map.json`
- no `dm-match.json` → fresh DM build (not the reuse short-circuit); no
  `permission`/`pdp` blocks on the DataSets → no `rls-todo.json` noise

## Converter

The **in-repo converter** (not MCP), from the plugin's scripts/ dir. Runs
offline — `SIGMA_SKIP_DOCTOR_GATE` waives the Step-0 environment gate since
this corpus case is not exercising the doctor:

```
cd corpus/domo/orders-smoke
DOMO_DISCOVERY_DIR="$PWD/fixtures" SIGMA_SKIP_DOCTOR_GATE="corpus: offline" \
  ruby ../../../plugins/domo-to-sigma/skills/domo-to-sigma/scripts/build-dm.rb
python3 ../../lib/corpus_check.py normalize fixtures/dm-spec.json golden/data-model.json
```

`build-dm.rb` writes `fixtures/dm-spec.json` directly (no
`{sigmaDataModel, ...}` envelope — that wrapping is an MCP-converter
convention); the golden is that spec after `corpus_check.py normalize`
rewrites the random client-side ids to stable positional tokens.

## Expectations

```json
{
  "artifacts": [
    {"path": "fixtures/datasets.json", "format": "json"},
    {"path": "fixtures/cards.json", "format": "json"},
    {"path": "fixtures/beast-modes.json", "format": "json"},
    {"path": "fixtures/formulas.json", "format": "json"},
    {"path": "fixtures/dataset-map.json", "format": "json"},
    {"path": "checks.sh", "format": "text"}
  ],
  "goldens": {
    "data-model.json": {
      "pages": 1,
      "elements": 2,
      "columns": 10,
      "metrics": 1,
      "relationships": 0,
      "warnings": 0,
      "element_names": ["ORDER_FACT", "CUSTOMER_DIM"]
    }
  }
}
```
