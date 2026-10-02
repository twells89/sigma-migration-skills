# Omni chartType → Sigma kind

`scripts/lib/omni_chart_map.rb`. A missing kind skips the tile into
`chart-gaps.json` (never guessed).

| Omni `chartType` | Sigma `kind` |
|---|---|
| `line`, `lineColor` | `line-chart` |
| `area` | `area-chart` |
| `bar`, `column`, `columnStacked`, `columnPercent`, `barStacked`, `barPercent` | `bar-chart` |
| `barLine` | `combo-chart` |
| `scatter`, `point`, `pointSize`, `pointSizeColor` | `scatter-chart` |
| `pie` | `pie-chart` |
| `kpi` | `kpi-chart` |
| `table` | `table` |
| `heatmap` | `heatmap-chart` |
| `funnel` | `funnel-chart` |
| `sankey` | `sankey-chart` |
| `map` | `point-map` |
| `regionMap` | `region-map` |
| `boxplot` | `box-chart` |
| `markdown`, `omni-ai-summary-markdown`, `singleRecord` | skip |

Date frames in `query.fields` (`orders.created_at[month]`) become
`DateTrunc("month", [Orders/Created At])` on the hidden data element.
Custom Vega specs are not read; only `chartType` is.
