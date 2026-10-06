# KPIs

Recipe for `kpi-chart` — the single-value stat card. For the canonical schema:

```bash
jq --arg k kpi-chart 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

Typically a KPI points at a table as its source and computes one aggregated value.

## Shape

```yaml
id: total-sales
kind: kpi-chart
name: Total sales
source:
  kind: table
  elementId: sales-table
columns:
  - id: kpi-val
    formula: Sum([Master/Sales Amount])
    format:
      kind: number
      formatString: "$,.0f"
value:
  columnId: kpi-val
```

- `columns` — define exactly one column (the value you want displayed). More columns are allowed but only the bound `value.columnId` is rendered.
- `value.columnId` — REQUIRED. The column ID to show in the card.
- `format` on the column controls the displayed format. See `formatting.md`.
- **Hiding the title (avoid the duplicate-title trap):** a KPI derives its visible title from the element `name` **and, when that is absent, from the bound value column's `name`.** So *omitting the element `name` is not enough* — the value column's name still renders as a title. This is the #1 KPI mistake: pairing a colored Markdown category label above the KPI (see `styling.md` KPI-card recipe) with a KPI whose value column has a real name like `Net Revenue` → you get **two** stacked titles ("NET REVENUE" label + "Net Revenue" title + the number). To show only the label + number, set the **value column's** `name: ' '` (a single space). `name: ''` (empty) or omitting it gets stripped and the title re-derives — only a single space persists. (If you instead want the KPI's own title and no separate label, skip the Markdown label and give the value column a real `name`.)

For a period-over-period delta (e.g. "vs. prior quarter"), compute it as a **formula column** — `[This Quarter] / [Last Quarter] - 1` against the source — and show it in its own column or a second KPI.

## Value styling

`value` also accepts presentation fields — `fontSize` (number or `"auto"`) and `color` (a hex string or a theme reference `{ kind: "theme", ref: "colors-xxx" }`).

## Formula qualification

Every KPI sources another element, so the column's formula must use the source's prefix (`[<SourceName>/col]`). A bare `[col]` is only valid for referencing another column defined in this KPI's own `columns[]` array. This is the single most common mistake — see `formulas.md`.

Run `./scripts/validate-spec.sh <spec.yaml>` before publishing to catch it.

## `layout`, `comparison`, and `trend` blocks

The OpenAPI exposes three more kpi-chart objects; their spec-authoring support differs:

- `layout` — **round-trips.** `{ anchor: left|center|right, verticalAnchor: top|center|bottom, titleOrient: top|bottom, ... }` positions the card contents. Default values are omitted on readback. (live-verified 2026-06-11, re-verified 2026-06-24)
- `value` styling — **round-trips.** `fontSize` (number or `"auto"`), `color`; `fontWeight: bold` reads back omitted (it appears to be the default). (live-verified 2026-06-11, re-verified 2026-06-24)
- `comparison` (the Δ badge) via `comparisonColumn: {columnId}` + `comparison: {display: "delta", colorGood, colorBad}` — **spec-authorable and readback-stable.** Verified 2026-07-27 against live staging: POST → export the source table → GET readback, with `comparisonColumn.columnId` intact and correct and `comparison.display`/colors unmodified. **KPIs are comparative by default — this is the house pattern, not an edge case.** See `comparative-kpi-card.yaml` beside this file for a full worked example. This supersedes the "did not render from spec / UI-only / stripped on readback" claim this doc carried through 2026-06-24 — for *this exact shape only* (see below for what's still unproven).

  **Don't over-extend this finding — two adjacent things remain unverified:**
  - The UI's **period-comparison MODE** (a date-driven picker like "vs. prior quarter" that derives the comparison value from a date dimension at render time) is a **different mechanism** from `comparisonColumn`. No public-API field exposes that date/series binding, and it remains **UI-bound** here. `comparisonColumn` compares two columns *you* compute (e.g. a `Current` column and a `Prior` column produced by your own formulas/source) — it is not an automatic "vs. last N periods" toggle.
  - `trend` (sparkline) is **still UI-bound** — unchanged by the 2026-07-27 finding, which tested only `comparisonColumn`/`comparison`, not `trend`. See the reproduction notes below.
  - An earlier version of this doc claimed `comparison` itself was "best-effort — survives on some KPIs, stripped on others." That blanket claim does **not** hold for the `comparisonColumn` + `comparison:{display:"delta"}` shape (verified 2026-07-27, reproduced twice). If you hit stripping with some *other* `comparison` configuration, treat that configuration as unverified and confirm with a live readback before relying on it — don't assume the whole block is unreliable.

  Behavior on POST/readback (verified 2026-06-24 for `trend`; 2026-07-27 for `comparison`/`comparisonColumn`):
  - `comparisonColumn` + `comparison:{display:"delta"}` — **accepted and persists** on readback, populated correctly.
  - `trend` — **accepted and persists** on readback, but **inert without a UI binding** — it renders nothing on its own here.
  - A column-level `columns[].sparkline` — **stripped** on readback.

  > ⚠️ **The widely-shared sparkline recipe did not reproduce here.** `trend: {shape: line}` + a `DateTrunc("month")` column + a date-range filter on it rendered **no** sparkline — tested ~8 ways on 2026-06-24, including the full documented recipe (a pre-grouped month time-series source, the month column in the KPI, **and both `mode: between` and the relative `mode: last … unit: month`**), column-level `sparkline`, and an exact copy of a *working* UI-bound KPI's columns. Every one rendered the value alone (the **grand total** — no date column ever created the series). Notably, the documented shape that filters a KPI on a `DateTrunc` month column **living on the source** (not in the KPI's own `columns`) is **rejected outright** by this API (`Dependency not found`). A KPI render that shows a live spark in the UI returns **no** `trend`/`sparkline` in its spec — only leftover `DateTrunc`/raw-date columns the editor added.
  >
  > **Open question — likely an org/version difference.** Another environment reports these *do* build from spec and render a stable sparkline. I could not reproduce that on this org/public API across the configs above, and the schema exposes no series binding — so until a workbook **built purely from spec and never opened in the editor** is shown to render a sparkline, treat spec sparklines as unsupported here and finish them in the UI. (Our own Looker converter agrees — `build_workbook.py` warns "Sigma KPI spec has no comparison/delta slot … set it in the UI".)

### Give a trend/comparison KPI enough height (or you won't *see* the sparkline)

A KPI stacks **title → value → comparison line → sparkline**, and Sigma **drops the lower items first** when the tile is too short — the sparkline goes before the comparison, which goes before the value. A plain value KPI is fine at ~5 grid rows (below that the title hides — see `styling.md`), but **a KPI carrying a sparkline + comparison needs noticeably more — budget ~8+ grid rows (~240px+)**, taller for long titles.

This is a **render-loop trap**: if you bind a sparkline but lay the tile out short, the export PNG shows only the number, and it's easy to wrongly conclude "the spark didn't build." When a sparkline you configured doesn't appear in the render, **first grow the element's `gridRow` span and re-export** before assuming it failed. (Exporting a single element with `pixelHeight` only scales the output canvas — it does **not** reproduce this layout-height clipping; you have to actually give the element more rows in the page layout.)
