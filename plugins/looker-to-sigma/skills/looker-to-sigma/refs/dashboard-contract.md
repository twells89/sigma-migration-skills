# Looker Dashboard → normalized JSON contract

The dashboard converter consumes ONE normalized shape, produced by either source:
- **Live (canonical):** Looker REST `GET /dashboards/{id}` + `GET /dashboards/{id}/dashboard_layouts`
  (+ `dashboard_filters`). Covers user-defined (UDD) **and** LookML dashboards identically.
- **Offline (dev only):** parse a `.dashboard.lookml` file and normalize into this shape.

Keep the converter source-agnostic: it only sees this contract.

## Shape

```jsonc
{
  "id": "business_pulse",
  "title": "Business Pulse",
  "layoutMode": "newspaper",          // newspaper | tile | static | grid (research note §2c)
  "source": "lookml" | "api",
  "lookmlLinkId": null,                // set on API dashboards linked to a .dashboard.lookml
  "filters": [
    { "name": "Date", "title": "Date", "type": "date_filter",
      "model": "training_ecommerce", "explore": "order_items",
      "dimension": "order_items.created_date",   // field this filter binds to
      "defaultValue": "30 days", "allowMultiple": false }
  ],
  "elements": [
    {
      "name": "Average Order Sale Price",
      "tileType": "single_value",      // Looker vis type → Sigma kind via research note §5e
      "model": "training_ecommerce",
      "explore": "order_items",
      "fields": ["order_items.average_sale_price"],   // view.field refs (resolve via explore joins)
      "pivots": [],
      "filters": { "order_items.status": "Complete" },// tile-level hard filters
      "sorts": ["order_items.average_sale_price desc"],
      "limit": 500,
      "listen": {},                    // filterName → field (which dashboard filters this tile obeys)
      "dynamicFields": [],             // table calcs / custom measures (client-side) → workbook formulas
      "noteText": "…", "subtitleText": "…",
      "cellVisualizations": {},        // grid in-cell data bars: {field: {scheme:[hex]|null}} from vis_config.series_cell_visualizations → conditionalFormats dataBars (often absent from the API even when the render shows bars — see SKILL.md Phase 3b)
      "layout": { "row": 0, "col": 0, "width": 8, "height": 6 }  // newspaper units
    }
  ]
}
```

## Field provenance (API vs LookML)

| Contract field | Looker API | LookML `.dashboard.lookml` |
|---|---|---|
| `elements[]` | `dashboard_elements[]` | `elements:` |
| `tileType` | `dashboard_element.type` | element `type:` |
| `fields` | `query.fields[]` (or `result_maker`) | `fields:` |
| `filters` (tile) | `query.filters{}` | element `filters:` |
| `listen` | `dashboard_element.listen` / `result_maker.filterables` | element `listen:` |
| `layout` | `dashboard_layout_components[]` (active layout only) — `row/column/width/height` | inline `row/col/width/height` |
| `filters[]` (dashboard) | `dashboard_filters[]` | top-level `filters:` |
| `dynamicFields` | `query.dynamic_fields` (JSON) | element `dynamic_fields:` |

Notes:
- API uses `column`; LookML uses `col`. Normalize to `col`.
- Only the **active** layout (`dashboard_layout.active == true`) matters; ignore mobile variants.
- `lookmlLinkId` set ⇒ dashboard is LookML-linked but may have UI edits; the API returns the
  edited (live) state — prefer it.

## Tile types in the thelook fixture (business_pulse.dashboard.lookml)

Observed: `single_value` ×2, `looker_column`, `looker_area`, `looker_donut_multiples`,
`table`; filters `date_filter` ×1, `field_filter` ×3; **`advanced` ×4** (advanced/custom
filter expressions — flag for manual review). Maps:
- `single_value` → Sigma `kpi-chart`; `looker_column` → `bar-chart`;
  `looker_area` → `area-chart`; `table` → `table`;
  `looker_donut_multiples` → single `donut-chart` + warn (Looker shows N donuts).
- Full tile-type, filter-type, and layout maps live in this skill's
  `refs/looker-dashboard-layout.md` §5e/§5f/§3 — do not duplicate; defer there.

## Layout → Sigma 24-col grid (newspaper)
`gridColumn = (col+1) / (col+1+width)`, `gridRow = (row+1) / (row+1+height)`.
tile/static/grid modes need a snap heuristic — see `refs/looker-dashboard-layout.md` §3 (lossy; warn + stack).

## Translation hazards to enforce (refs/looker-dashboard-layout.md §5)
Liquid (`{%`/`{{`) → warn/partial; `merged_results` → DM join or custom SQL; table calcs
(`pct_of_total`/`running_total`/`offset`) → workbook `Sum/GrandTotal`/`RunningSum`/`Lag`;
field prefix resolution must walk explore `join`s (alias vs `from:` view); cross-filtering
+ trellis + tooltip are Sigma UI-only (ship without, document post-publish step).
