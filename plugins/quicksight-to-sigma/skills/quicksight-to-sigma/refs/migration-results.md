# QuickSight → Sigma: 20-dashboard validation RESULTS

> Run date: 2026-06-06 · Source account: AWS QuickSight **Enterprise**, acct `<aws-account-id>`,
> us-east-1, profile `pivot` (20 graduated analyses D1–D20, all `CREATION_SUCCESSFUL`).
> Sigma target: "QuickSight Migrations" folder (`59804d8b-fe7b-4de5-8f78-8d0cce07caa9`).
> Companion: `refs/migration-test-slate.md` (the slate + 24-visual build catalog).

## Summary
The `quicksight-to-sigma` capability (converter MCP `convert_quicksight_to_sigma` + browser
mirror, plus the skill's fixup/build/layout/parity scripts) was validated end-to-end against a
graduated 20-dashboard slate on a **live QuickSight Enterprise account**. Every buildable
dashboard reached **exact warehouse parity** (Sigma MCP query vs the same Snowflake source the
QuickSight analysis reads): single-KPI, bar/line/pie, 2-way and 3-way joins, CustomSql,
parameters/what-if, combo+scatter, gauge/funnel/treemap (approximated), data-prep transforms
(incl. an applied 347-headcount row filter), multi-level pivots, and **maps** (region-map, exact
parity). Hard cases degrade **gracefully and explicitly** — window/table-calc → `Null` + the
original expression preserved in the column description; un-migratable visual kinds emit a per-visual
`warnings.json` manifest — never a silent failure and never a broken POST. Five converter/skill
gaps surfaced during the run were fixed at source (4 bugs) and the skill fixup was reconciled
against the converter (1 task), with zero parity regression.

## D1–D20 results

URL form: `https://app.sigmacomputing.com/workbook/<urlId>`. **Every buildable dashboard
(D1–D17, D19, D20) has a retained workbook in the "QuickSight Migrations" folder** — 19 workbooks
in all. **D18 is the only entry with no workbook**: it is a reasoned (c)-tail (exotic chart gallery
— 6 visuals with no Sigma chart kind, 0 chart elements), so the DM posts clean but no workbook is
built. Where a D-number had more than one workbook from re-runs, the most-recent (`updatedAt`)
copy is linked below. All URLs were verified against the live
`GET /v2/files?typeFilters=workbook` list — none are invented.

| # | QuickSight analysis | datasets | visual types | outcome | migrated vs dropped | Sigma workbook |
|---|---|---|---|---|---|---|
| D1 | D1-Single-KPI-Total-Revenue | 1 RelationalTable | KPI | ✅ exact-parity | KPI total 109116.5 ✓ | [2QQHnE2K6Uz3quHMY0i7dn](https://app.sigmacomputing.com/workbook/2QQHnE2K6Uz3quHMY0i7dn) |
| D2 | D2-Bar-By-Region | 1 | bar | ✅ exact-parity | bar-by-region ✓ | [rXGEgUa3fKboJpYqFFg4V](https://app.sigmacomputing.com/workbook/rXGEgUa3fKboJpYqFFg4V) |
| D3 | D3-Line-And-Pie | 1 | line, pie | ✅ exact-parity | line trend + pie mix ✓ | [uclsjO43ZtarimhRbGwfY](https://app.sigmacomputing.com/workbook/uclsjO43ZtarimhRbGwfY) |
| D4 | D4-Exec-Summary | 3-way join | 4 KPI, bar, line, filter | ✅ exact-parity | all elements; West 38408.6 ✓ | [3UaM6oxiCV7bCcGRHrRhoD](https://app.sigmacomputing.com/workbook/3UaM6oxiCV7bCcGRHrRhoD) |
| D5 | D5-CustomSql-Table | 1 CustomSql | bar, table | ✅ exact-parity | CustomSql element named; West 38408.6 ✓ | [c1huwfY97IBLi9vICJC4A](https://app.sigmacomputing.com/workbook/c1huwfY97IBLi9vICJC4A) |
| D6 | D6-OrdersCustomers-Join | 2-way join | bar, KPI | ✅ exact-parity | join collapsed to 1 element; West 38408.6 ✓ | [63nDXy5wkxRYFOAT9xyzXp](https://app.sigmacomputing.com/workbook/63nDXy5wkxRYFOAT9xyzXp) |
| D7 | D7-Orders-WhatIf | 1 + params | what-if + param controls | ✅ exact-parity | params→controls; slider→segmented control | [4HK9XIC3ani3j144K6Xa8g](https://app.sigmacomputing.com/workbook/4HK9XIC3ani3j144K6Xa8g) |
| D8 | D8-Orders-Combo | 1 | combo (dual-axis), scatter | ✅ exact-parity | combo + scatter (size+color) ✓ | [ccnnkylCYSXO6pmTh2v30](https://app.sigmacomputing.com/workbook/ccnnkylCYSXO6pmTh2v30) |
| D9 | D9-Orders-GaugeFunnelTree | 1 | gauge, funnel, treemap | ✅ exact-parity | gauge→kpi, funnel/treemap→bar (approximated) | [6hwkpX7v7L1Cnx8R3eHZu](https://app.sigmacomputing.com/workbook/6hwkpX7v7L1Cnx8R3eHZu) |
| D10 | D10-Employees-Transforms | 1 + transforms | bar, KPI | ✅ exact-parity | Cast/Create/Rename + **row filter applied → 347 headcount** ✓ | [2hj8kEA4Uu8Xnv1Ksfq8FQ](https://app.sigmacomputing.com/workbook/2hj8kEA4Uu8Xnv1Ksfq8FQ) |
| D11 | D11 Multi-Level Pivot | 1 | pivot (2 row, 1 col, 2 measures, subtotals) | ✅ exact-parity | pivot via rowsBy/columnsBy `{id}` arrays ✓ | [7KSVLawrB3JU3fM1xKqThH](https://app.sigmacomputing.com/workbook/7KSVLawrB3JU3fM1xKqThH) |
| D12 | D12 Window Table-Calc | 1 | bar/line w/ window calcs | ⚠️ graceful | non-window exact (Online 60895.18 ✓); 4 window cols → `Null` + expr in description | [4yik4mvsIdKu5MLH1vAHY5](https://app.sigmacomputing.com/workbook/4yik4mvsIdKu5MLH1vAHY5) |
| D13 | D13 Cascading Cross-Sheet Filters | 1 | filters across sheets | ⚠️ partial | data exact; FilterGroups dropped; multi-sheet → 1 page | [29L0Pyprn1tUxHEq8Q5Bpx](https://app.sigmacomputing.com/workbook/29L0Pyprn1tUxHEq8Q5Bpx) |
| D14 | D14 Visual Actions | 1 | charts + actions | ⚠️ partial | data exact; visual actions (filter/nav/URL) dropped + warned | [dL4KSC5DEQM6TDOlkUGp7](https://app.sigmacomputing.com/workbook/dL4KSC5DEQM6TDOlkUGp7) |
| D15 | D15 Free-Form Overlap | 1 | free-form + text + image | ✅ exact-parity | data exact; pixel overlap collision-resolved to stacked grid | [3AuNiEy2WWoOBxPW3L76sT](https://app.sigmacomputing.com/workbook/3AuNiEy2WWoOBxPW3L76sT) |
| D16 | D16 Paginated Ticket Report | 1 | section-paginated + table | ⚠️ partial | table exact; sections (header/footer/page-break) flattened | [6vH3tPLylq8HPnMdU22OxD](https://app.sigmacomputing.com/workbook/6vH3tPLylq8HPnMdU22OxD) |
| D17 | D17 Workforce Maps | 1 | filled choropleth + geo points | ✅ exact-parity | both → region-map; avg-salary-by-state matches Snowflake ✓ | [51HiaeigGh29ORZJbRIrR8](https://app.sigmacomputing.com/workbook/51HiaeigGh29ORZJbRIrR8) |
| D18 | D18 Exotic Chart Gallery | 1 | waterfall/sankey/boxplot/histogram/wordcloud/radar | (c)-tail | DM posts clean (6 cols); 6 visuals have no Sigma kind → 6 explicit warnings | (c)-tail — no chart elements, no workbook |
| D19 | D19 Secured Conditional Table | 1 | table + RLS/CLS + conditional fmt | ⚠️ partial | data exact; RLS/CLS + color rules/data bars dropped (live on dataset, not analysis) | [6yfSJ8sIMWI0Q6d1ac8ESZ](https://app.sigmacomputing.com/workbook/6yfSJ8sIMWI0Q6d1ac8ESZ) |
| D20 | D20 Kitchen Sink | multi-join + params | bar/line/window + Insight/CustomContent/Plugin | ⚠️ partial | bar/line exact; window → `Null`; Insight/CustomContent/Plugin dropped + warned | [662gb4RxpVNfYQgsPo3GAz](https://app.sigmacomputing.com/workbook/662gb4RxpVNfYQgsPo3GAz) |

Live cross-check: all 19 buildable D-series workbooks (D1–D17, D19, D20) confirmed present in the
folder via `GET /v2/files?typeFilters=workbook&limit=500`; the `urlId`s above are the most-recent
verified copy per D-number. **D18 is the only D-number with no workbook** — a reasoned (c)-tail
(0 chart elements), not a missing or cleaned dashboard. URLs are not invented.

## Gaps found & fixed (during the run)

| Bead | Where fixed | One-line |
|---|---|---|
| `beads-sigma-vy4k` (P1 bug) | **converter** `src/quicksight.ts` + browser mirror | CustomSql/RelationalTable single-table elements were nameless → now named via `sigmaDisplayName`, cols emitted as `[Custom SQL/RAW_ALIAS]`; `dedupeElementNames` guarantees unique names. |
| `beads-sigma-nc6g` (P0 bug) | **converter** + skill fixup/builder | Multi-table `JoinInstruction` (2-way + chained 3-way) — element naming/dedupe, transitive 2nd-hop resolution, paren sanitization, builder picks the element covering the charted cols (not `elements[0]`). |
| `beads-sigma-woaa` (P0 bug) | **converter** (DM side) + skill builder | Window/table-calc was a comment-only `/* TODO */` → failed the all-or-nothing POST; now degrades to `formula:'Null'` + original expr in column description, on both DM and workbook sides. |
| `beads-sigma-23xu` (P1 bug) | **converter** (cast) + skill (filter) | `CastColumnType` self-referenced its own display name → `error` col; now wraps resolved `[Custom SQL/RAW]`. `FilterOperation` surfaced to `dm-filters.json` and applied as a real element-level list filter (D10 → 347, was 369). |
| `beads-sigma-dqyv` (P1 task) | **skill** `convert-model.rb --fixup` | Reconciled: slimmed fixup 397→303 lines, removed work the converter now does at source; kept only `synth_join_sql` collapse + `FilterOperation` surfacing + folderId/schemaVersion. Join strategy = keep `synth_join_sql` (uniform for both RelationalTable and CustomSql joins). Re-tested D1/D4/D5/D6/D10/D12 → zero regression. |

## Known (c)-tail (NOT bugs — reasoned, warned, never "failed")

Confirmed against the public Sigma OpenAPI element union (no matching Sigma element kind exists):
- **histogram, heat-map, treemap*, waterfall, box-plot, radar, sankey, word-cloud** — no Sigma
  chart kind. (*treemap is *approximated* to bar where charted as a TreeMapVisual; the bare kind
  has no native equivalent.) Emitted as per-visual `warnings.json` entries.
- **LayerMap** (multi-layer geospatial) — no Sigma kind. (Single-layer FilledMap / name- or
  lat-long GeospatialMap DO build natively as region-map/point-map — no longer (c)-tail.)
- **Insight (ML)** — forecast/anomaly/narrative ML; no equivalent.
- **CustomContent** — arbitrary iframe/HTML; no equivalent.
- **Plugin** — third-party visual (Highcharts etc.); no equivalent.
- **Section-based pagination + free-form pixel overlap** — Sigma uses a 24-col responsive grid;
  sections flatten, overlapping free-form elements collision-resolve to a stacked grid.
- **RLS / CLS** (row/column security) — analysis-level constructs; in QuickSight these live on the
  **dataset**, not the analysis definition, so they aren't in the migrated artifact.
- **Window / table-calc functions** (~28: sumOver, runningSum, rank, periodOverPeriod, percentOfTotal,
  percentile*Over, …) — degrade to `Null` + original expr in column description (graceful, not exact).
- **FilterOperation row-filter on a warehouse-table DM element** — a true row filter cannot move
  into a warehouse-table element; surfaced as a workbook/element filter or pushed to SQL WHERE
  (handled for D10) — warned where it can't.
- **Dataset-of-datasets** recursion — explicitly out of scope (negative test).

## How to reproduce

See `SKILL.md` — the proven 7-phase happy path:
1. **AUTH** AWS CLI → QuickSight (Enterprise required, unchanged); Sigma via the browser-first shared provider (`scripts/browser-login.sh` once, client credentials as the unattended fallback).
2. **DISCOVER** `describe-analysis-definition` + `describe-data-set(s)` + `describe-data-source(s)` → `quicksight-discover.py`.
3. **CONVERT** `convert_quicksight_to_sigma` MCP (MCP gate) → Sigma DM JSON.
4. **POST DM** `convert-model.rb --fixup` → validate → `POST /v2/dataModels/spec`.
5. **WORKBOOK** master tables per DM element + chart elements mirroring the QS visuals → `POST /v2/workbooks/spec`.
6. **LAYOUT** QS grid x,y,w,h → 24-col layout → `put-layout.rb` (do NOT skip).
7. **VERIFY** sigma-mcp-v2 query each element + Phase 6 parity vs the QuickSight aggregation (hard gate).
