# Metabase source-format shapes (card + dashboard JSON, MBQL)

What the converter parses. Written from the public MBQL reference and API docs,
then **verified against a live production estate (Metabase Cloud v1.61.4,
7,023 cards / 1,548 dashboards)**; shapes marked ⚠ have version variants. The
biggest production finding: modern instances return **pMBQL** ("lib/" MBQL) —
see the section at the bottom; everything below it is the LEGACY shape the
converter operates on after `pmbql-normalize.mjs` runs at intake.

## Card JSON (`GET /api/card/{id}`)

```jsonc
{
  "id": 123, "name": "Revenue by Month", "description": null,
  "collection_id": 5, "database_id": 2, "table_id": 45,
  "type": "question",            // "question" | "model" | "metric"  (⚠ v46–49: models use "dataset": true)
  "display": "line",             // table|bar|row|line|area|combo|scatter|pie|scalar|smartscalar|gauge|progress|funnel|waterfall|map|pivot|trend
  "dataset_query": {
    "type": "query",             // "query" = MBQL | "native" = SQL
    "database": 2,
    "query": { ... MBQL, below ... },
    "native": {                  // only when type = "native"
      "query": "SELECT ... WHERE category = {{cat}} AND {{date_range}}",
      "template-tags": {
        "cat":        { "name": "cat", "display-name": "Category", "type": "text", "default": "Widget" },
        "date_range": { "name": "date_range", "type": "dimension", "widget-type": "date/range",
                        "dimension": ["field", 80, null] }   // "field filter" — expands to a WHERE clause
      }
    }
  },
  "result_metadata": [           // per-result column — the id→name fallback when db metadata is absent
    { "name": "CREATED_AT", "display_name": "Created At", "base_type": "type/DateTime", "field_ref": ["field", 80, {"temporal-unit": "month"}] }
  ],
  "visualization_settings": { ... display config, below ... }
}
```

## MBQL query (`dataset_query.query`)

```jsonc
{
  "source-table": 45,                  // integer table id — OR "card__123" (a nested question/model)
  "joins": [{
    "source-table": 50,
    "alias": "Products",               // join alias — field refs carry {"join-alias": "Products"}
    "strategy": "left-join",           // left-join | right-join | inner-join | full-join (default left)
    "condition": ["=", ["field", 90, null], ["field", 91, {"join-alias": "Products"}]],
    "fields": "all"                    // "all" | "none" | explicit field refs
  }],
  "expressions": {                     // custom columns — see expression-dsl.md
    "Profit": ["-", ["field", 72, null], ["field", 73, null]]
  },
  "aggregation": [
    ["sum", ["field", 72, null]],
    ["count"],
    ["aggregation-options", ["sum-where", ["field",72,null], ["=", ["field",81,null], "Widget"]],
      { "name": "widget_rev", "display-name": "Widget Revenue" }]   // named aggregation wrapper
  ],
  "breakout": [ ["field", 80, { "temporal-unit": "month" }] ],     // group-bys
  "filter": ["and",
    ["=", ["field", 81, null], "Widget", "Gadget"],                 // = with >1 value ⇒ IN
    ["time-interval", ["field", 80, null], -30, "day"],
    ["segment", 7]                                                  // saved segment ref (flag)
  ],
  "order-by": [ ["desc", ["aggregation", 0]] ],
  "limit": 100,
  "fields": [ ["field", 72, null], ... ]                            // explicit column list (no aggregation)
}
```

**Field refs** — the core shape: `["field", <id-int | "name-string">, opts|null]`.
Opts: `"temporal-unit"` (`day|week|month|quarter|year|hour|…` — bucketing),
`"join-alias"`, `"base-type"` (set when the id is a literal name, e.g. columns of
a nested card), `"binning"` (`{"strategy":"num-bins","num-bins":10}` — numeric
histogram). Integer ids resolve via `GET /api/database/{id}/metadata`
(`fieldIndex`); string names resolve directly. `["expression", "Profit"]` refs a
custom column; `["aggregation", 0]` refs an aggregation by position (order-by only).

**Aggregations**: `count`, `sum`, `avg`, `distinct`, `min`, `max`, `median`,
`stddev`, `var`, `percentile` (`["percentile", field, 0.95]`), `share` (ratio of
rows matching a condition), `count-where`, `sum-where`, `cum-sum`, `cum-count`,
legacy `["metric", id]`. Named via the `aggregation-options` wrapper.

## Dashboard JSON (`GET /api/dashboard/{id}`)

```jsonc
{
  "id": 9, "name": "Exec Overview",
  "parameters": [                          // dashboard-level filters → Sigma controls
    { "id": "abc123", "name": "Date", "slug": "date", "type": "date/range", "default": "past30days" },
    { "id": "def456", "name": "Category", "slug": "cat", "type": "string/=" }
  ],
  "tabs": [ { "id": 1, "name": "Overview" } ],   // ⚠ v49+; dashcards carry dashboard_tab_id
  "dashcards": [                                 // ⚠ pre-v48: "ordered_cards" with sizeX/sizeY
    {
      "id": 1, "card_id": 123,
      "row": 0, "col": 0, "size_x": 8, "size_y": 6,   // 24-col grid → maps 1:1 to Sigma's 24-col layout
      "dashboard_tab_id": 1,
      "card": { ...full card JSON embedded... },
      "parameter_mappings": [
        { "parameter_id": "abc123", "card_id": 123,
          "target": ["dimension", ["field", 80, null]] }   // which column this control filters on this card
      ],
      "visualization_settings": {
        "virtual_card": { "display": "text" }, "text": "## Section header"   // text/heading cards have card_id: null
      }
    }
  ]
}
```

## `visualization_settings` keys the converter reads

| Key | Display | Meaning |
|---|---|---|
| `graph.dimensions` / `graph.metrics` | bar/line/area/combo/row/scatter/waterfall | x-axis column names / series column names (match `result_metadata.name`) |
| `stackable.stack_type` | bar/area | `"stacked"` \| `"normalized"` (100%) |
| `series_settings` | combo | per-series `{"display": "line"\|"bar"}` overrides |
| `pie.dimension` / `pie.metric` | pie | slice dim + value |
| `pivot_table.column_split` | pivot | `{"rows": [field refs], "columns": [...], "values": [...]}` → rowsBy/columnsBy/values |
| `scalar.field` | scalar | which column is THE number |
| `map.type` | map | `"region"` → region-map; `"pin"` → point-map |
| `column_settings` | any | per-column `{"number_style": "currency", "decimals": 2, "suffix": …}` → Sigma format |
| `table.columns` | table | column order + `enabled` (hidden cols) |

## Things that look like data but aren't

- **Text/heading dashcards** — `card_id: null` + `visualization_settings.virtual_card`
  → Sigma `text` elements (markdown passes through).
- **Click behavior** (`click_behavior` in viz settings — cross-filter / link) →
  flagged, not converted (Sigma actions are a manual follow-up).
- **`trend` / `smartscalar`** — the KPI value converts; the auto "vs previous
  period" comparison line is flagged (rebuild with a Sigma KPI comparison).

## pMBQL ("lib/" MBQL) — what modern instances ACTUALLY return

**Production finding (2026-06, Metabase Cloud v1.61.4): 100% of a 7,023-card
estate returned `dataset_query` in pMBQL form**, not the legacy shape above. A
single card-list response may contain EITHER format depending on instance
version — sniff the `lib/type` key, never the version string.

```jsonc
{
  "lib/type": "mbql/query",
  "database": 134,
  "stages": [                                   // legacy nests source-query; pMBQL chains stages
    {
      "lib/type": "mbql.stage/mbql",            // or "mbql.stage/native"
      "source-table": 8391,                     // or "source-card": N  (legacy: "card__N")
      "aggregation": [["count", {"lib/uuid": "…"}]],
      "breakout":    [["field", {"lib/uuid": "…", "base-type": "type/DateTime", "temporal-unit": "week"}, 124164]],
      "filters": [                              // ARRAY (implicit AND) — legacy has a single "filter"
        ["=", {"lib/uuid": "…"}, ["field", {…}, 124158], "AU"],
        ["in", {"lib/uuid": "…"}, ["field", {…}, 124161], "A", "B"]   // pMBQL multi-value op
      ],
      "expressions": [                          // LIST of clauses — legacy is a {name: clause} map
        ["datetime-diff", {"lib/uuid": "…", "lib/expression-name": "Cohort Age"}, …]
      ],
      "joins": [{ "lib/type": "mbql/join", "alias": "…", "strategy": "left-join",
                  "stages": [{"source-table": 46}], "conditions": [ … ], "fields": "all" }]
    }
  ]
}
```

Key invariant: **every pMBQL clause is `[op, {opts}, …args]` — the options map
is ALWAYS the second element** (legacy puts it last, or third for `field`).
Native stages carry the SQL directly: `{"lib/type": "mbql.stage/native",
"native": "<sql>", "template-tags": {…}}` (template-tag `dimension` refs are
pMBQL field clauses too).

`converter/pmbql-normalize.mjs` (byte-identical copy in
`metabase-assessment/scripts/`) converts all of this to the legacy shape at
intake in BOTH skills. It prefers the card's **`legacy_query`** field when
present — a JSON *string* containing the server's own down-conversion (~70% of
cards on the reference estate carry it) — and falls back to the local
normalizer. Multi-stage queries (stages > 1; 14 of 7,023 observed) normalize to
legacy `source-query` nesting, which the converter FLAGS (rebuild as chained
Sigma elements), never mistranslates.
