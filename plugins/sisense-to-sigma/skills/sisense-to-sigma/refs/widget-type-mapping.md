# Sisense widget → Sigma element mapping

Coverage table. Drives both the converter (Phase 3) and the assessment
coverage scoring. **Confirm enum strings against live widget `type` values** —
the trial has 0 dashboards, so these are from Sisense docs/field knowledge and
must be verified when a sample dashboard exists.

| Sisense widget `type`        | Sigma element            | Tag      | Notes |
|------------------------------|--------------------------|----------|-------|
| `indicator`                  | KPI chart                | AUTO     | single value; gauge variants → KPI + flag |
| `pivot2` / `pivot`           | pivot-table              | AUTO     | rows/columns/values panels → pivot axes |
| `tablewidget` / `table`      | table                    | AUTO     | |
| `chart/column`, `chart/bar`  | bar chart                | AUTO     | orientation from sub-type |
| `chart/line`                 | line chart               | AUTO     | |
| `chart/area`                 | area chart               | AUTO     | |
| `chart/pie`                  | pie chart                | AUTO     | |
| `chart/scatter`              | scatter                  | HINT     | verify axis/size mapping |
| `chart/polar`, `chart/funnel`| closest chart            | HINT     | |
| `map/*` (scatter/area maps)  | region/point map         | HINT     | geo level mapping |
| `treemap`, `sunburst`        | table (+flag)            | MANUAL   | no native equivalent |
| BloX / `plugin/*` / scripted | flag                     | UNHANDLED| no Sigma equivalent — surface, don't fake |

Tags: **AUTO** converts cleanly · **HINT** converts, verify · **MANUAL** needs a
human decision · **UNHANDLED** flagged, not converted.
