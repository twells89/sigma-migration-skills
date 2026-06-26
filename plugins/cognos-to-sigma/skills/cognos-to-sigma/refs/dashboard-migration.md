# Migrating Cognos **Dashboards** (exploration JSON)

The converter (`converter/`) handles two artifacts: Data Module JSON → Sigma DM, and
report-spec **XML** → Sigma workbook. A Cognos **dashboard** is a *third, different*
artifact — `application/vnd.ibm.bi.exploration+json` — and is **not** covered by the
converter. This doc is the hand-authoring recipe, proven end-to-end on the IBM sample
**"Nebraska school board dashboard"** (5 tabs, 6 KPIs + 15 viz, exact parity).

> **The #1 rule: a Cognos dashboard's TABS become separate Sigma PAGES.** Do not flatten
> every widget onto one page. Read the tab list first (below), map each widget to its tab,
> and emit one Sigma page per tab. (Learned the hard way — first build flattened 43 widgets
> onto one page and had to be re-paged.)

## 1. Pull the dashboard spec

```
GET /bi/v1/objects/{dashboardId}?fields=specification
```
The `specification` field is a JSON **string** — parse it. (Same envelope as a report spec,
but the payload is dashboard JSON, not report XML.) The `id`/`boardId` is in the dashboard
URL: `.../bi/?perspective=dashboard&id=<ID>&objRef=<ID>`.

Cognos content lives behind **Akamai bot-protection + CAF**, so plain `curl` of `/bi/v1`
returns **441/403** even with a valid session cookie or API key — it fingerprints TLS/JA3.
The working path is a **headed-Chrome bridge** (Puppeteer with the browser session cookies
injected); see "Extraction bridge" below.

## 2. Read the structure — tabs, then widgets per tab

```
spec.name                       # dashboard title
spec.dataSources.sources[]      # {name, assetId(=module id), type:module}
spec.layout.selectedTabId       # the active tab
spec.layout.items[]             # ONE ENTRY PER TAB  ← these are your Sigma pages
  item.id
  item.title.translationTable.Default   # tab name (e.g. "Educational Outcomes")
  item.type == "container"
  ...nested... widgets
```

Widgets are nested inside each tab container. Walk each `item` collecting widget nodes:

```python
def collect(node, acc):
    if isinstance(node, dict):
        data = node.get('data', {})
        if node.get('type') == 'widget' or (isinstance(data, dict) and data.get('dataViews')):
            vt = node.get('visId') or data.get('vizId') or '?'          # viz type
            nm = node.get('name') or data.get('name') or data           # title
            title = nm.get('translationTable', {}).get('Default') if isinstance(nm, dict) else None
            acc.append((vt, title))
        for v in node.values(): collect(v, acc)
    elif isinstance(node, list):
        for v in node: collect(v, acc)
    return acc
```

KPI "summary" tiles carry their label in `data.translationTable.Default`; charts carry it in
`name.translationTable.Default`.

### Cognos viz type → Sigma element kind

| Cognos `visId` | Sigma kind |
|---|---|
| `summary` | `kpi-chart` |
| `com.ibm.vis.rave2bundlebar` / `rave2bundlecolumn` | `bar-chart` |
| `com.ibm.vis.rave2line` | `line-chart` |
| `com.ibm.vis.rave2bundlecomposite` | `combo-chart` (set per-series `type` on `yAxis.columnIds`) |
| `com.ibm.vis.rave2bundlepackedbubble` / bubble | `scatter-chart` (Sigma has no packed-bubble) |
| `com.ibm.vis.rave2bundletiledmap` | `point-map` (lat/long) or `region-map` |
| `JQGrid` / `list` (data) | `table` |
| `list` (filter) | `control` (controlType `list`) |

## 3. Get the data into the warehouse

Dashboard modules are often **file-backed** (uploaded CSV/XLSX) — the module `metadata`
endpoint returns only the *subset* the dashboard touches, and raw rows don't download. Pull
the actual rows by replaying the dashboard's own **dataset query API** through the bridge,
then land them in the warehouse (e.g. Snowflake `PUT`+`COPY`). The query the dashboard fires:

```
GET /bi/v1/datasets/{datasetId}/data?type=module&refreshmd=false&qfb=none&moduleUrl=&querySpec={urlencoded JSON}
# MUST send header  X-XSRF-TOKEN: <live XSRF-TOKEN cookie value>  or CAF 403s.
```
- `datasetId` = the **runtime** module id seen in the dashboard's network traffic — NOT the
  `assetId` declared in `spec.dataSources`.
- For a `SELECT *` per table, build a `querySpec` listing every column at `attr:aggregate: none`,
  grouped on one edge; full column expr = `{querySubject.identifier}.{queryItem.expression}`.
- Module schema (column names/types/relationships): `GET /bi/v1/metadata/modules/{id}/metadata`
  (note the **trailing `/metadata`** — the bare `/metadata/modules/{id}` can 404).
- Result parse: `edges[0].itemClasses[0].h[]` = ordered columns (`di`), `edges[0].items[].t[]`
  = row cells in header order; cell value = `cell.v` (numeric) else `cell.d` (display).

## 4. Build the Sigma data model — prefer **all-custom-SQL** elements

For a dashboard built on file-backed/landed tables, make **every DM element a `kind: sql`
source** with explicit double-quoted aliases. This is the path of least resistance:

- **No inode lookups, no warehouse-name normalization guesswork** — you control aliases.
- **Bypasses the new-table catalog-sync requirement** — Sigma runs the SQL directly, so newly
  landed tables don't need a connection re-sync to be referenced (cf. `format-shapes.md` /
  the warehouse-table "Source not found" gotcha).
- **Cross-table charts become joins *inside* the SQL** (e.g. avg-grade-by-grade-level =
  course-grades ⋈ enrollment; school map w/ counts = schools ⋈ person-role) — avoids DM
  relationships entirely and the "Rollup cannot reference more than one" grouping error.

Column formula in a SQL element = `[Custom SQL/<alias>]` (regardless of the element's display
name). Put the 6 dashboard KPIs in **one single-row "KPI Summary" SQL element** (each KPI a
scalar subquery column); each KPI tile is then `Sum([KPI Summary/<col>])` over that 1 row.

Use a **headless service-account connection** (key-pair `SIGMA_SERVICE_USER`), not an OAuth
connection (OAuth can't run server-to-server). Grant the connection's role `SELECT` on the
new schema.

## 5. Build the workbook — one page per tab

`source: { kind: data-model, dataModelId, elementId }`; chart column formulas reference the
**DM element name**: `[Enrollment/School Year]`. Dimension columns un-aggregated; measures
`Sum(...)`/`Avg(...)`. Emit one `pages[]` entry per Cognos tab, and **one `<Page id>` block
per page** inside the single top-level `layout` XML string.

### Workbook gotchas hit on this build (all live-verified 2026-06-26)

- **`text` element** uses `body:` (Markdown). No `name`, no `content`.
- **`color` channel can't reuse a column already on `yAxis`/`size`** — scatter/map POST fails
  with *"a column can only be on one channel"*. Use a different column or drop `color`.
- **A `control` can't bind to a `point-map`** (*"Dependency not found"*). Back the list control
  with a real `table` element (a schools directory) and filter that.
- **Format object** = `{ kind: number, formatString: ",.0f" }` (DM) — not `{type, format}`.
- **Top-N rank with ties returns >N rows** (a "Top 5" can show 6 when values tie) — expected.

## Extraction bridge (defeats Akamai/CAF for any `/bi/v1` call)

Launch real Chrome via Puppeteer, inject the **full** browser Cookie header (incl. Akamai
`_abck`/`bm_sz`/`ak_bmsc`/`bm_sv`), warm the sensor with one `goto('/bi/')`, then issue every
`/bi/v1` call from inside the page with `fetch(..., {credentials:'include', headers:{'X-XSRF-TOKEN':<live cookie>,'X-Requested-With':'XMLHttpRequest'}})`.
Real-Chrome TLS + in-page JS passes the WAF; `curl` never will. Grab the cookie via DevTools →
Network → any `/bi/v1` request → Copy as cURL.
