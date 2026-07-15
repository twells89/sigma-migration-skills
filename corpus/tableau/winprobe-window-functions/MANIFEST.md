# tableau / winprobe-window-functions

The WINPROBE regression pair for **Tableau window/table calcs → Sigma-native
window math** (bead beads-sigma-427, validated 2026-06-12 with **930/930 cells
exact** vs warehouse ground truth on ONE DM base element, zero Custom SQL).
Source: live Tableau workbook **"WINPROBE Window Functions"**
(`aa126c36-608a-402c-9733-2c83797bc65c`, 10ay/dataflow site) over the
`CSA.TJ.ORDER_FACT` demo warehouse (demo data only). Eight worksheets, one
window family each:

| Worksheet | Tableau calc | Validated Sigma form |
|---|---|---|
| WIN Running Revenue | `RUNNING_SUM(SUM(x))` by week | `CumulativeSum(Sum(x))` |
| WIN Moving Avg | `WINDOW_AVG(SUM(x), -3, 0)` | `MovingAvg(Sum(x), 3)` |
| WIN Pct Of Total Region | `SUM(x)/WINDOW_SUM(SUM(x))` | `PercentOfTotal(Sum(x), "grand_total")` |
| WIN Rank Category | `RANK(SUM(x))` | `Rank(Sum(x), "desc")` + computed-sort carry |
| WIN Window MaxMin | unbounded `WINDOW_MAX/MIN(SUM(x))`, Region × Quarter pivot | two-level grouped helper; consumer `Max`/`Min` |
| WIN WoW Delta | `ZN(SUM(x) - LOOKUP(SUM(x), -1))` | `Coalesce(Sum(x) - Lag(Sum(x), 1), 0)` |
| WIN Weekly Funnel | Measure Names (CountD + Sum + ratio calc) | dissolved to one multi-measure line chart |
| WIN Pareto Category | `RUNNING_SUM(SUM(x))/TOTAL(SUM(x))` | `CumulativeSum(PercentOfTotal(Sum(x), "grand_total"))` + sort carry |

Full mapping + gotchas: the skill's `refs/window-functions.md`.

## Placement re-probe (2026-07-15)

A customer reported that `MovingSum` worked in a **table** calc column, which
contradicted the old "chart yAxis is the ONLY verified context" rule. Re-probed
live with `scripts/probe-window-contexts.rb` against the `WINPROBE Base` DM
(`01d5deb8-de64-485d-a428-e368afc6963b`): the Sigma-native window family
(CumulativeSum/MovingSum/MovingAvg/Rank/RankDense/RowNumber/Lag/Lead/
PercentOfTotal) resolves to real `OVER(...)` in **all three** calc-column
contexts — grouped workbook table, ungrouped workbook "master" table, and
DM-element calc column. Only the `*Over` family (SumOver/CountOver/…) errors:
`Unknown function` at query in workbook contexts, and a hard 400 on a DM-spec
POST. The old rule confused *function family* with *placement*; `refs/window-
functions.md` and the two `scripts/*.rb` notes were corrected accordingly.
Re-run the probe to re-verify on any org — it is the gate for that claim.

## Artifacts

| File | What it is |
|---|---|
| `workbook-content.twb` | The live WINPROBE workbook XML (8 worksheets; published virtual-connection datasource over CSA.TJ) |
| `get-workbook.json` | View name → view id map (REST get-workbook shape) so `build-charts-from-signals.rb` runs offline |
| `views/<viewId>.csv` | Tableau view exports = the parity ground truth (incl. the Measure-Names LONG-format funnel CSV and the quarter-label pivot CSV) |
| `master-columns.json` | Master-map regexes for the 6 ORDER_FACT columns (Order Id / Order Date / Net Revenue / Is Returned / Region / Category) |
| `golden/chart-specs.json` | PINNED `build-charts-from-signals.rb` output: all 8 windowed views auto-emitted (4 line + 3 bar + 1 pivot + the hidden two-level window helper in `data_elements`), zero Custom SQL |

## Converter

No MCP converter — this case pins the SKILL-script contract. Regenerate with
(`$S` = `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts`):

```
ruby $S/parse-twb-layout.rb workbook-content.twb dashboard-layout.json
ruby $S/build-charts-from-signals.rb --tableau-dir . --layout dashboard-layout.json \
  --meta dashboard-layout-meta.json --master-map master-columns.json \
  --master-element-id master --page-per-dashboard --out chart-specs.json
```

Diff `chart-specs.json` against `golden/chart-specs.json` (deterministic ids —
they derive from worksheet captions). `dashboard-layout*.json` are regenerable
intermediates and are not pinned.

## Assertions encoded by the pin

- Every windowed measure lands as a Sigma-native viz formula ON THE CHART
  yAxis (never a DM calc column, never Custom SQL, never `*Over`).
- `LOOKUP(x, -1)` → `Lag(x, 1)` (negative offset = backward; the pre-2026-06-12
  Lag/Lead mapping was reversed).
- `RANK(...)` emits an explicit `"desc"` (Tableau default direction).
- Tableau `<computed-sort>` (sort dim by measure) is parsed and carried into
  `xAxis.sort` via a hidden companion aggregate (`srt-*` column) on the rank +
  pareto charts — cumulative/rank formulas follow that order.
- Week dims use the Sunday-anchored `DateAdd("day", 1 - Weekday(d), DateTrunc("day", d))`.
- The MaxMin pivot sources ONE hidden two-level grouped helper
  (`data_elements[0]`: outer grouping = Region, inner = quarter-trunc'd Order
  Date, `Max`/`Min` stage calcs over the shared `Sum(Net Revenue)` value) and
  the pivot values re-aggregate `Max`/`Min` — never `Sum` (broadcast-down).
- The pivot's quarter shelf resolves `tqr` → `DateTrunc("quarter", ...)`
  (the t-prefixed trunc derivations used to fall through to the raw date).
- The Weekly Funnel Measure-Names LONG CSV dissolves into one 3-measure line
  chart whose y columns are NAMED with the verbatim Tableau measure labels
  (the parity plan pivots the long CSV and matches by display name).

## Known parity reference (live run 2026-06-12)

WINPROBE probe workbook (org tj-wells-1989, conn `bc0319f8`, `CSA.TJ`):
930/930 cells exact (tol 1e-6) across all 8 families, three-way
(Tableau CSV == warehouse SQL == Sigma element export). Kept references:
Tableau wb `aa126c36-608a-402c-9733-2c83797bc65c`, Sigma DM `01d5deb8`.

## Expectations

```json
{
  "artifacts": [
    {"path": "workbook-content.twb", "format": "xml"},
    {"path": "get-workbook.json", "format": "json"},
    {"path": "master-columns.json", "format": "json"},
    {"path": "views/939579b7-3a5e-4eef-8d4e-7be678adefeb.csv", "format": "text"},
    {"path": "views/446cd366-7aba-4c64-8dd0-75633d0c4b92.csv", "format": "text"},
    {"path": "views/20340dc0-4194-4530-8317-d72a24a1bcaa.csv", "format": "text"},
    {"path": "views/57f05682-b35f-41cc-bc96-7217d06efb80.csv", "format": "text"},
    {"path": "views/30fc3fc8-1e65-4cb7-8010-6365d489fe67.csv", "format": "text"}
  ],
  "goldens": {
    "chart-specs.json": {
      "pages": 8,
      "elements": 16,
      "columns": 27,
      "element_names": [
        "title--synthetic-win-running-revenue", "WIN Running Revenue",
        "title--synthetic-win-moving-avg", "WIN Moving Avg",
        "title--synthetic-win-pct-of-total-reg", "WIN Pct Of Total Region",
        "title--synthetic-win-rank-category", "WIN Rank Category",
        "title--synthetic-win-window-maxmin", "WIN Window MaxMin",
        "title--synthetic-win-wow-delta", "WIN WoW Delta",
        "title--synthetic-win-weekly-funnel", "WIN Weekly Funnel",
        "title--synthetic-win-pareto-category", "WIN Pareto Category"
      ]
    }
  }
}
```
