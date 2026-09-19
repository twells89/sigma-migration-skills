# Omni source contract

v0 reads an offline model directory plus one dashboard JSON. Live Omni is
optional and read-only (`OMNI_BASE_URL`, `OMNI_API_TOKEN`).

## Model directory

Git-synced or `GET /api/v1/models/{id}/yaml?mode=combined` files:

| File | Role |
|---|---|
| `*.view` / `*.view.yaml` | Dimensions and measures. View name is the `Reference this view as` comment, else the file stem. |
| `*.topic` / `*.topic.yaml` | `base_view`, `label`, nested `joins`. |
| `relationships.yaml` | `join_from_view`, `join_to_view`, `on_sql`, `relationship_type`, `reversible`. |
| `model.yaml` | `access_grants`, `default_topic_access_filters`. |
| `*.query.view` | Recorded and skipped. Not inlined. |

`${view.field}` is the field reference. `aggregate_type` of `sum`, `count`,
`count_distinct`, `average`, `min`, `max`, `median` becomes a Sigma metric.
A measure with no `aggregate_type` whose SQL is arithmetic over other measures
becomes a ratio (`NullIf`). `omni_dimensionalize`, Mustache
`{{ omni_attributes.* }}`, and `DO NOT PARSE` are skipped with a warning.

`on_sql` must be one `${a.f} = ${b.g}` equality. `many_to_one` /
`assumed_many_to_one` → `N:1`, `one_to_one` → `1:1`. `reversible: false` stays
one-directional and is warned.

Warehouse path is `[schema, table_name]` from the view. Pass
`--connection-id` before POST. The topic becomes a table element named
`label` that sources the base view and pulls joined columns through the
relationship name (`[ORDERS/users/Region]`).

Topic `fields:` curation is not applied in v0 (warning). Workbook-model YAML
inside an export is not merged in v0.

## Dashboard export

`GET /api/unstable/documents/{id}/export` (`exportVersion` `"0.1"`) or the
v2 envelope. The normalizer (`scripts/lib/omni_export.rb`) accepts:

- `queryPresentations` as an array or `{data, order}` on `dashboard`,
  `dashboard.metadata`, `workbook`, or the top level
- `dashboard.metadata.layouts.lg` items `{i,x,y,w,h}` (12-col boards scale ×2
  onto Sigma's 24-col grid)
- `filterConfig` plus `dashboard.metadata.tileFilterMap`
- `document.name` / `document.identifier`

Each tile keeps `query` (the body `POST /api/v1/query/run` already accepts)
and `visConfig.chartType`. See `refs/chart-map.md`.

A `tileFilterMap` value of `false` means that tile does not listen. v0 will
not emit controls in that case, because every chart shares one data element
and a shared filter cannot exclude one tile. The exclusion is written to
`filter-gaps.json`.

Spreadsheet `fileUploads` are ignored.

## Query oracle

`scripts/omni-query-oracle.rb` writes one `POST /api/v1/query/run` body per
tile. With `OMNI_BASE_URL` and `OMNI_API_TOKEN` it runs them and writes
`oracle-results.json`. Offline it exits 0 after the plan.
