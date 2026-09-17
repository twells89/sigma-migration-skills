# Domo live validation — first real-instance contact (2026-07-30)

This file records the **first live Tier-A validation** of `domo-to-sigma` against a
real Domo instance. It resolves all three "Open questions — resolve on first
instance access" from `SKILL.md`, and it **corrects several claims** in
`refs/connection.md` that were doc-inferred rather than observed.

Instance shape: 48 cards / 2 pages / 10 sample DataSets, Admin OAuth client +
developer access token. Everything below was executed, not inferred. Where a
result is instance-specific (may differ elsewhere), it says so.

---

## Verdict on the three open questions

| # | Question | Answer |
|---|---|---|
| 1 | Does the dev token reach `/api/content/v1/cards`? | **YES.** `X-DOMO-Developer-Token` returns 200 on `/api/content/v1/cards`, `/api/content/v2/users/me`, `/api/data/v3/datasources`, `/api/content/v1/pages`, `/api/data/v1/accounts`. Tier A is reachable. OAuth bearer tokens are **401** on every private path — the two credentials are not interchangeable. |
| 2 | Exact card-def JSON shape | **Resolved — three distinct shapes, see below.** The previously-documented "Shape A" is the *create/update request body*, **not** what the private read returns. |
| 3 | Page-layout geometry units | **There are no x/y/w/h units on classic pages.** Layout = ordered `collections[]` (titled sections with `cardIndices[]`) + a per-card **T-shirt `size` token**. See "Layout" below. |

---

## The three card shapes (do not conflate)

### 1. Private read — card metadata
```
GET /api/content/v1/cards?urns={id}&parts=<parts>
```
Returns a **JSON array** — index `[0]`. Confirmed `parts` vocabulary (9 values):
`certification, datasources, domoapp, drillPath, masonData, metadata, owners,
problems, properties`.

What it actually contains: `id, urn, type, title, description, metadata,
datasources, owners, certification, drillPath, domoapp, active, allowTableDrill,
badgeUpdated, created, creatorId, locked, ownerId, isCurrentUserOwner`.

⚠️ It does **NOT** contain `chartBody`, `summaryNumber`, `calculatedFields`, or
`conditionalFormats`. Those are create-body fields (shape 3), not read fields.

- **`chartType` lives at `metadata.chartType`**, not at the card root.
- `metadata.SummaryNumberFormat`, `metadata.columnAliases`, `metadata.columnFormats`
  are **JSON-encoded strings** — they need a *second* `JSON.parse`.
- `masonData` is only present for mason/app cards; absent on classic `kpi` cards.

### 2. Private read — analyzer definition (the bindings)
```
PUT /api/content/v3/cards/kpi/definition     body: {"urn":"<cardId>"}
```
`{dynamicText, variables}` in the body are **optional** — `{"urn":...}` alone works.

Top level: `{columns, dataSourceWrite, definition, drillpath, embedded, id, urn}`
(note **`drillpath`** lowercase here vs `drillPath` in `parts`).

`definition` keys: `allowTableDrill, annotations, charts, chartVersion,
conditionalFormats, description, formulas, inputTable, modified, segments,
slicers, subscriptions, title`.

**`definition.subscriptions` is a dict keyed by subscription name**, not a single
object:
- **`big_number`** — ⭐ **THE SUMMARY NUMBER.** `columns[0] = {column, aggregation,
  distinct, alias, format:{type,format}}`, `limit: 1`. Present on **31 of 36** kpi
  cards in this instance.
- `main` — the chart body. `columns[]` carry a **`mapping`** that binds the column
  to a visual role.

Observed `mapping` vocabulary (10 values): `ITEM` (category/x), `VALUE` (measure),
`SERIES` (split), `XTIME`, `BUBBLESIZE`, `CATEGORY`, `CURRENT`, `TARGET`, `DATE`,
`EVENT`.

Also on a subscription: `filters[]`, `orderBy[]`, `groupBy[]`, `limit`, `distinct`,
`fiscal`, `projection`, plus
- `dateRangeFilter` = `{column:{column,exprType}, dateTimeRange:{dateTimeRangeType,
  interval, offset, count}}` (e.g. `ROLLING_PERIOD`/`MONTH`/`count:6`)
- `dateGrain` = `{column, dateTimeElement}`

**Beast Modes are INLINE** at `definition.formulas[]` — a standalone template
fetch is *not* required to get the SQL:
```
{templateId, id:"calculation_<uuid>", name, formula, variable, status,
 persistedOnDataSource, columnPositions[], cacheWindow, locked, owner,
 usedByOtherCards, isAnalytic, isAggregatable, dataType, bignumber}
```
`isAnalytic` / `isAggregatable` classify window vs aggregate **without SQL
parsing**. Columns inside `formula` are **backtick-quoted** (MySQL dialect), e.g.
`` (sum(`Visits`) - SUM(`New Visits`)) ``.

### 3. Public create/update body
```
POST https://api.domo.com/v1/cards/chart?pageId={pageId}     # scope: data dashboard
PUT  https://api.domo.com/v1/cards/{id}/definition
```
Body fields: `calculatedFields[]{formula,id,name,saveToDataSet}`, `chartBody{…}`,
`chartType`, `chartVersion`, `conditionalFormats[]`, `dataSetId`, `description`,
`goal`, `metadataOverrides`, **`preferredFullWidth`/`preferredFullHeight`**,
`quickFilters[]{column,name,operator,type,values}`, **`summaryNumber{…}`**,
`title`, `urn`.

`chartBody` and `summaryNumber` share one Component shape: `columns[]{column,
aggregation, alias, calendar, format{…}, mapping}`, `dateGrain`, `dateRangeFilter`,
`distinct`, `filters[]{column,operand,values[]}`, `fiscal`, `groupBy[]`, `limit`,
`offset`, `orderBy[]`, `projection`.

⚠️ **`summaryNumber` (create) ≡ `subscriptions.big_number` (read).** An extractor
must read the latter; only a *writer* sees the former.

✅ **`POST /v1/cards/chart` WORKS — verified by creating real cards.** But it is
brutally intolerant of partial bodies:

> **A partial body returns bare `500 Internal Server Error` with no field
> diagnostics.** Minimal bodies (`dataSetId` + `title` + `chartType` +
> `chartBody.columns`) all 500, with and without `pageId`. The **same request
> succeeds** once every Component field is present. Do not interpret a 500 here as
> "the API is unavailable" — it almost always means a missing field.

A body that succeeds populates, on **both** `chartBody` and `summaryNumber`:
`columns[]`, `groupBy[]`, `orderBy[]`, `filters[]`, `distinct`, `fiscal`,
`projection`, `limit`, `offset` — plus top-level `calculatedFields[]`,
`conditionalFormats[]`, `quickFilters[]`, `chartVersion`, `goal`,
`metadataOverrides`, `preferredFullWidth`, `preferredFullHeight`. Empty arrays are
fine; **absent** keys are not. Omit `urn` on create (it is the update key).

Required scope is **`data dashboard`** — a token lacking `dashboard` returns
**403**, which is easy to misread as an auth failure rather than a scope gap.

`?pageId=` is optional but strongly recommended: without it the card is created
**orphaned** (no page), and Domo's UI gives you no easy way to find it.

Response echoes the created card including a server-assigned `urn` and
server-assigned `calculatedFields[].id` (`calculation_<uuid>`) — your supplied
calc id is **replaced**, so re-read the response rather than assuming your id
survived.

⚠️ **`GET /v1/cards/{id}/definition` returns 500 for every card on this instance**
even though creation works and `GET /v1/cards` / `GET /v1/cards/{id}` return 200.
Don't depend on the public definition read — use the private shape-2 read, which
works reliably.

#### Write-path enums (probed exhaustively — these are STRICT enums)

⚠️ **`chartType` is a strict enum, NOT a free-form string.** `refs/card-to-element.md`
says *"chartType is a free-form string … match on substring"* — that is wrong for
the write path, and **4 of the 9 tokens that file documents are not valid Domo
values at all**:

| Documented in `card-to-element.md` | Reality |
|---|---|
| `badge_datagrid` | ❌ invalid — the table type is **`badge_table`** |
| `badge_pivottable` | ❌ invalid |
| `badge_stackedarea` | ❌ invalid |
| `badge_line` | ❌ invalid — use `badge_symbolline` / `badge_curved_symbolline` |
| `badge_vert_bar`, `badge_horiz_bar`, `badge_pie`, `badge_singlevalue`, `badge_xyscatterplot` | ✅ valid |

Additional **valid** values confirmed by creating cards: `badge_table`,
`badge_donut`, `badge_symbolline`, `badge_curved_symbolline`, `badge_trendline`,
`badge_treemap`, `badge_word_cloud`, `badge_filledgauge`, `badge_map`,
`badge_line_bar`, `badge_vert_stackedbar`, `badge_vert_multibar`.

**`Aggregation` enum — valid: `SUM`, `COUNT`, `AVG`, `MIN`, `MAX`.** There is **no
distinct-count aggregation**; `COUNT DISTINCT`, `COUNT_DISTINCT`, `DISTINCT_COUNT`,
`UNIQUE`, `UNIQUE_COUNT`, `CARDINALITY` all 400. A distinct count is
`{"aggregation":"COUNT","distinct":true}` on the column.

**`ConditionalFormat.TextStyle` — valid: `BOLD`, `ITALIC`, `BOLD_ITALIC`.**
`NORMAL` and lowercase forms 400.

**`preferredFullWidth` / `preferredFullHeight` must be 1–6.** Domo's card grid is
**6 columns wide**, not 24 — a 12 is rejected with *"height and width must have
values between 1 and 6"*. Relevant when mapping Domo width → Sigma's 24-col grid:
the scale factor is 4, not 1.

**`calculatedFields` are referenced by `name`, not by `id`.** Putting the calc's id
in `columns[].column` fails with *"The following column(s) are missing from the
datasource schema: &lt;id&gt;"*. Use the `name`; the server assigns its own
`calculation_<uuid>` id and returns it. `saveToDataSet` does not change this.

**Filters:** the write field is **`operand`** (not `operator`); `quickFilters` use
`operator`. On read-back the server adds `filterType: "LEGACY"`.

#### Card-authoring traps that produce SILENTLY BROKEN cards

These four cost real debugging time. Each yields a card that Domo accepts with
**HTTP 200** but that is wrong or unusable — so a build script cannot trust the
create status code alone. **Verify every authored card by rendering it.**

1. ⚠️ **`orderBy` MUST be empty.** Any non-empty `chartBody.orderBy` creates a card
   that saves with 200 and then **fails to render forever** (render endpoint 500).
   Controlled test: identical cards differing only in `orderBy` — `[]` renders;
   a bare dimension, an aggregated measure, a `mapping`-bearing entry, and an
   `ascending:false` entry **all 500**. (`order:"DESC"` is rejected at create with
   400 — unknown field.) There is no working form. Omit `orderBy` and apply sort
   in the Domo UI or downstream in Sigma. This silently broke 7 of 15 cards.
2. ⚠️ **`dateGrain` is inert unless the date column carries `calendar: true`.**
   With `calendar:false` (or absent) Domo ignores `dateGrain` and groups by raw
   **day** — a 31-month series rendered as ~500 daily points. Setting
   `calendar: true` on the date column in BOTH `columns[]` and `groupBy[]` makes
   `dateTimeElement: "MONTH"` take effect. Measure columns should **omit**
   `calendar` entirely (live cards have it absent, not `false`).
3. ⚠️ **`dateGrain` needs a real `DATE` column.** A `YYYYMMDD` integer surrogate
   date key — very common in warehouse fact tables, and the shape of the fact
   table used for this validation — is a `LONG`
   to Domo and cannot drive a date grain. Migrations in the other direction must
   synthesize a real date; note Sigma can derive one from the integer key with
   `MakeDate` (see `refs/beast-mode-to-sigma.md`).
4. ⚠️ **The `mapping` vocabulary is CHART-TYPE DEPENDENT.** For `badge_line_bar`
   (and the other combo/two-axis types) the measures bind via **`SERIES`**, not
   `VALUE` — verified against 3 real combo cards on the instance, all of which use
   `ITEM` + `calendar:true` for the date and `SERIES` for every measure. Using
   `VALUE` on a combo produces a card that renders **"No data in filtered range"**.
   A categorical `ITEM` axis on a combo also renders empty: these types apply an
   implicit date range and need a time axis.

Minor: `goal: 0` draws a literal "Goal 0.0%" reference marker on the card — omit
`goal` unless you want one.

#### Render endpoint: charts vs tables take DIFFERENT parts AND different payload keys

| Card kind | `parts` | Payload location | Format |
|---|---|---|---|
| chart / KPI | `image` | `image.data` | base64 **PNG** |
| **table** (`badge_table`) | **`imagePDF`** | **`html`** | HTML-wrapped base64 **PDF** |

`parts=image` on a table card returns **400**; `imageGrid` / `grid` also 400. And
the `imagePDF` payload is NOT under `image.data` — it arrives under **`html`** as
`<div class="kpi_chart">JVBERi0xLjQ…</div>`, i.e. strip the HTML tags, then
base64-decode to get a `%PDF-1.4` document. So `lib/domo_rest.rb#decode_render`
needs a **third** branch (HTML-wrapped base64 PDF) beyond the JSON-base64-PNG and
raw-bytes cases, and Phase-1b visual capture must branch `parts` on card type or
it will silently fail to capture every table.

---

## Card enumeration — the P0 fix

**`GET /v1/pages/{pageId}` returns `cardIds: []` even for a page with 36 cards.**
`domo-discover.rb` derived its card list from `page['cardIds'] || page['cards']`,
so on a live instance discovery yields **zero cards** and the migration silently
produces an empty workbook. Three working routes, in preference order:

1. ⭐ **`GET /api/content/v3/stacks/{pageId}/cards?parts=metadata,datasources`**
   (private) — the richest: returns `cards[]` (full card objects), **`sizes[]`**,
   **`collections[]`**, and `pageAnalyzerSettings`. One call per page gives cards
   *and* layout. A `cards_for_page` helper for this already existed in
   `lib/domo_rest.rb` but nothing called it.
2. **`POST /api/content/v2/cards/adminsummary?parts=<parts>&skip=N&limit=100`**
   (private) — body `{"ascending":true,"orderBy":"cardTitle","pageIds":[…]}` →
   `{"cardAdminSummaries":[…]}` with `pageHierarchy`. Instance-wide sweep;
   paginates via **query** params, not body.
3. **`GET /v1/cards?limit=100&offset=0`** (PUBLIC) — returns
   `{totalCardCount, cards:[{cardUrn, cardTitle, type, pages[], lastModified}]}`.
   Filter on `pages[]` containing the target pageId. **This works on Tier B**, so
   Tier B no longer means "no card inventory".

⚠️ **Card `type` vocabulary differs by surface**: the public API reports
`type: "chart"` where the private API reports `type: "kpi"` for the same card.
Don't key element-kind decisions on `type` alone — use `metadata.chartType`.

---

## Layout — classic pages have no x/y/w/h

`/api/content/v3/stacks/{pageId}/cards` returns:
- **`sizes[]`** = `{id, size}` where `size` is a **token** (`"medium"` for all 36
  here) — **not** width/height. There are no x/y/w/h fields anywhere.
- **`collections[]`** = `{id, title, description, minimized, cardIndices[]}` —
  titled sections that group cards **by index** into the `cards[]` array.
- `pageAnalyzerSettings` = `{pageId, interactionFilters, noAddingNewFilters,
  showFilterBar, showGlobalDateFilters, showSegments, showFilterIcons}` — page
  filter-bar configuration.

So the faithful layout mapping for a classic page is:
**collection → Sigma section/container; `cardIndices` order → grid order;
`size` token → column span.** Free-form pixel geometry exists only on newer
mason/Domo-App pages.

This is why `build-domo-layout.rb` produced a vertical stack: it expects x/y/w/h
from `merge_geometry`, finds none, and degrades. Consuming `collections` + `sizes`
is the fix.

---

## ⛔ Domo layout is NOT reachable through the API — in either direction — ⚠️ NARROWED (see `refs/page-layout-v4.md`)

> ## ⚠️ NARROWED 2026-07-30 — geometry IS readable, on a v4 page
>
> This section is kept as the **measured historical record** for the classic page
> probed here — it was true for that page, and it is still true for any genuinely
> legacy page (one with no `pageLayoutV4` in its stacks response). It is not the
> whole picture, though.
>
> `refs/page-layout-v4.md` — corroborated on two independent live Domo tenants —
> found a third page style, **v4-inline**, where geometry is readable and exact:
> `pageLayoutV4.standard.template[]`, joined to `content[]` on `contentKey`, gives
> real `x`/`y`/`width`/`height` per card (grid is 60-wide, so Domo → Sigma scales
> ×0.4). (`content[]` also carries positioned `HEADER` section dividers, but
> those are not yet surfaced as section titles/dividers in the composed
> dashboard — `merge_pagelayoutv4_geometry` discards any `content[]` entry
> without a `cardId`, which is every `HEADER` entry; see `refs/page-layout-v4.md`'s
> caveat.)
>
> So the claim below in Consequence 1 — that card *size, position and order* are
> UI-only — is a **narrowing, not a reversal**: still true for a page with no
> `pageLayoutV4`, not true in general. `refs/page-layout-v4.md` also records two
> defects in our own code (`domo_rest.rb`'s `cards_for_page` never requested the
> v4 payload; `domo_sigma_util.rb`'s v4 branch dug a `pageLayoutV4.cards` key
> that didn't exist) that have since been fixed. Read it for the full page-style
> taxonomy.

Probed exhaustively on a live instance. For a **classic** Domo page there is no way
to read OR write layout geometry:

| What | Result |
|---|---|
| `preferredFullWidth` / `preferredFullHeight` on card create | accepted (and range-checked to 1..6) but **persist nowhere** — absent from every readback shape |
| `sizes[].size` from `/stacks/{pageId}/cards` | **`""`** for API-created cards. A human resizing a card in the Domo UI is what sets `small`/`medium`/`large` |
| `collections[]` (titled sections) | no reachable write endpoint — `POST`/`PUT` on `/collections`, `/pages/{id}/collections` all 404 |
| card **order** on the page | **not controllable** — cards created 1st and 4th came back at `pageOrder` 2 and 0. Order appears internal/arbitrary |
| `PUT /api/content/v3/stacks/{pageId}/cards` | 405 |
| page render (for a screenshot) | **404 on every variant PROBED** — `/api/content/v{1,2,3}/pages/{id}/render`, `/stacks/{id}/render`, `/pages/{id}/export`, `/export/v1/pages/{id}`, `/pages/{id}/image`. ⚠️ This is "not found across the paths listed", NOT proof none exists — Domo's private surface is undocumented and large. Unchecked lead: the `brycewc/domo-product-apis` Postman collection reportedly has a **Get Layout** request; its page is client-rendered so the path could not be extracted programmatically. Confirm it before relying on this row. |
| `PUT /v1/cards/{id}/definition` (documented "Update Chart Card Definition") | **500**, like `GET .../definition` — no update path at all; only CREATE works |

Consequences, and they are structural rather than cosmetic:

1. **You cannot build a nicely-arranged Domo dashboard from code — on a genuinely
   legacy page.** Card *content* is fully API-controllable (dataset, chart type,
   columns, filters, formats, conditional formats); card *size, position and
   order* are UI-only **for a page with no `pageLayoutV4`** (see the narrowing
   note above and `refs/page-layout-v4.md` — a v4-inline page's geometry, and
   `HEADER`-divider order, IS readable). If a demo or fixture page needs to look
   composed in Domo and turns out to be genuinely legacy, a human must arrange it.
2. **A migration gets no layout signal from a classic page via any endpoint probed here**, so a converter that
   expects x/y/w/h will silently degrade to a vertical stack — exactly the
   field-reported failure. The only fidelity route is a **human-supplied page
   screenshot**, read by the model into `discovery/layout-observed.json`
   (`_source: "observed-from-screenshot"` — never presented as API truth).
3. Because that is often unavailable, the DEFAULT composition matters more than for
   any other converter. House order: **controls at the top → KPIs (compact row) →
   charts 2-up → tables full width**. A `layout-2d.flag` of `"grid"` is necessary
   but NOT sufficient — `layout_lint` separately fails an under-filled band (a lone
   element spanning 12 of 24 columns leaves dead space), so bands must be filled.

Free-form pixel geometry does exist on newer **mason / Domo-App** pages; the above
is specifically about classic card pages, which is what the sample content and any
API-created page are.

### ⭐ `/api/content/v4/pages/layouts/{layoutId}` — the layout endpoint (v4!)

**Correction to the row above:** the original probe swept v1/v2/v3 and concluded
"no layout endpoint." It missed **v4**, which does exist (surfaced from the
`brycewc/domo-product-apis` Postman collection):

```
GET /api/content/v4/pages/layouts/{layoutId}
GET /api/content/v4/pages/{pageId}/layouts      # also 200
```

On this instance both return **`200` with `Content-Length: 0`** — an empty body —
for every page tried, including Domo's own sample page. Why:

- the path takes a **`layoutId`**, not a pageId, and **no `layoutId` field appears
  anywhere** in the private page surface (`/v1/pages`, `/v3/stacks/{id}/cards`,
  `?parts=layouts`) for a classic page
- every page on this instance is `type: "page"` — a **classic card page**

So the working hypothesis, **UNTESTED for lack of a suitable page**: v4 layouts
serve Domo's newer **Dashboard** page type (mason/DDX), which is exactly the type
that carries free-form pixel geometry. A classic page has no layout record, hence
the empty 200.

**If you have a Domo Dashboard-type page, test this first** — it would become
preference tier 1 in `build-domo-layout.rb` and would beat the screenshot rung
outright. Document the real payload shape here before wiring it.

Standing lesson: probing v1–v3 and declaring absence was an overclaim. Domo
versions its private endpoints independently and v4 exists for at least this
resource.

#### `includeV4PageLayouts=true` — confirmed no-op for a classic page

The stacks call accepts `includeV4PageLayouts=true`. Passing it on a classic page
adds **no layout key at all** to the response (top-level keys are unchanged:
`cards, collections, id, isFavorite, locked, page, pageAnalyzerSettings, sizes,
title, type`). That independently corroborates the empty v4 200 above: a classic
page simply has no v4 layout record. Expect this flag to matter only for a
Dashboard-type page.

### ⭐ The stacks `parts` vocabulary is MUCH larger — and includes `subscriptions`

The 9-value `parts` list documented earlier comes from the CARD endpoint. The
**stacks** endpoint accepts a wider set:

```
GET /api/content/v3/stacks/{pageId}/cards
    ?parts=metadata,datasources,library,drillPathURNs,owners,certification,
           dateInfo,subscriptions,slicers,metadataOverrides
    &includeV4PageLayouts=true
```

Verified live — each card in `cards[]` then carries `metadata, datasources,
dateInfo, drillPathURNs, owners, certification, slicers, metadataOverrides` **and
`subscriptions`**.

**This is a significant efficiency and robustness win the extractor should adopt.**
`subscriptions` here is the SAME binding data that `PUT /api/content/v3/cards/kpi/definition`
returns — including `big_number` with its `column`/`aggregation`/`alias`/`format`,
and a per-subscription `dataSourceId`:

```json
{"cardId": 390868622, "dataSourceId": "…", "dataSourceName": "…",
 "componentName": "big_number",
 "subscription": {"name": "big_number", "dataSourceId": "…",
                  "columns": [{"column": "QUANTITY_ORDERED", "aggregation": "SUM", …}]}}
```

Today `domo-discover.rb` makes **one PUT per card** to get bindings. On the 36-card
sample page that is 36 round-trips where **one** stacks call would do — and it also
removes the need to join `datasetId` separately, since each subscription carries its
own `dataSourceId`. Note the shape differs slightly (a LIST of
`{cardId, componentName, subscription}` envelopes here, vs a dict keyed by
subscription name on the PUT), so normalize both.

`slicers` is now live-confirmed on `badge_table`: entries carry
`{type,displayType,dataSourceId,name,column,columnDisplayName,operator,values,
collapsed,controlType}` and represent Analyzer Quick Filters, distinct from
`subscriptions.main.filters`. The public `/v1/cards/chart/{id}` response calls
the same list `quickFilters`. `dateInfo` is also present and summarizes the
card date grain/range. Unexplored parts worth a look: `metadataOverrides`, and
`drillPathURNs` (drill hierarchies — currently dropped entirely).

## Render endpoint — confirmed, with a correction

```
PUT /api/content/v1/cards/kpi/{cardId}/render?parts=image
body {"queryOverrides":{}, "width":800, "height":600}
```
Returns **200 with `Content-Type: application/json`** — a JSON envelope, *not* raw
image bytes:
```json
{"image": {"data": "<base64 PNG>", "notAllDataShown": false},
 "limited": false, "notAllDataShown": false}
```
Base64 PNG is under **`image.data`**. `lib/domo_rest.rb#decode_render` kept both a
JSON and a raw-bytes branch pending confirmation — the JSON branch is the live one
here. This closes the render `TODO(on-access)`.

---

## Parity — validated live

`POST /v1/datasets/query/execute/{id}` (public, stable) reconciled **exactly**
against the same aggregation run directly on the warehouse: identical row count,
distinct count, and two summed measures to the cent. Phase 6's mechanism is sound.

⚠️ **Alias-case collision.** When a requested alias matches an existing column
name case-insensitively, Domo returns **the column's casing**, not the alias:
`ROUND(SUM(GROSS_PROFIT),2) AS gross_profit` came back as `GROSS_PROFIT`, while a
non-colliding `AS net_rev` was preserved. Parity code that keys result columns on
the requested alias will silently miss those. Match case-insensitively, or alias to
a name that cannot collide.

Sample-data (`publicsampledata`) DataSets **are** queryable via `query/execute`, so
parity works on Domo's own sample cards too.

---

## Snowflake connector — dataset→warehouse mapping is discoverable

`build-dm.rb` requires a hand-authored `discovery/dataset-map.json` because the
Domo-dataset→warehouse mapping "cannot be guessed". For **connector-backed**
DataSets it can be: the stream configuration carries it.

```
GET /api/data/v1/streams/{streamId}
```
→ `configuration[]` of `{streamId, category:"STREAM", name, type, value}` with
names **`databaseName`**, **`schemaName`**, **`tableName`**, `warehouseName`,
`query`, `reportType`, plus `account{id}` and `dataSource{id}`. Those map 1:1 onto
`dataset-map.json`'s `database` / `schema` / `table`. A dataset's `streamId` is on
its private detail (`GET /api/data/v3/datasources/{id}`).

Connector metadata lives at `GET /api/data/v1/connectors/{connectorId}`, whose
`view.configWizard.steps[].sections[]` enumerates the config field names and
`discovery.commands[]` lists the credential fields.

Notes for a real engagement:
- **A keypair Snowflake connector exists**: `com.domo.connector.snowflakekeypairauthentication`
  (account type `snowflakekeypairauthentication`; fields `account, username,
  privateKey, passPhrase, role`). Prefer it over password auth. The account-type
  ids `snowflake-keypair` / `snowflake-jwt` do **not** exist — that spelling 404s.
- `com.domo.connector.snowflake` v1.225 and `com.domo.connector.snowflake.v2` v1.2
  both reject stream creation with *"connector version with state: DEPRECATED"*.
  The keypair connector (v0.149) accepts it.
- Stream creation requires `dataProvider{key}` **and** a non-deprecated
  `transport{type:"CONNECTOR", description:"<connectorId>", version:"<major>.<minor>"}`.
- `GET /v1/account-types` is **paginated at 50** and its `?key=` filter is ignored;
  fetch by id directly instead of scanning page 1.

---

## ⛔ The formula layer is NOT "nearly free" — 74% of real Beast Modes fail — ✅ RESOLVED (PR #115, #116)

> ## ✅ RESOLVED 2026-07-30 — all three bugs fixed upstream (sigma-data-model-mcp PR #115, then PR #116)
>
> This section is kept as the **measured historical baseline** — it was true, and it
> is the reason this fix work happened. It is no longer the current state.
>
> Beads `jva2` (Bug 1, `CASE WHEN`), `sqp1` (Bug 2, `COUNT(DISTINCT x)`), and `qorq`
> (Bug 3, double-bracketing — see below) are **all closed**. All three constructs
> now translate correctly end-to-end. The "81 unique Beast Modes / 52 paren-wrapped
> / 44 CASE+paren" figures below were later found to be per-card *instances*, not
> distinct formulas; deduplicated by SQL text the corpus is **74 distinct
> formulas**. Re-measured against the PR #115 fix with a single identical
> harness applied to both the `0be8116` baseline and the fixed HEAD — same
> `normalize_bm` steps both times (backticks → `[brackets]` AND `WEEKDAY` →
> `DAYOFWEEK`), so the two columns are genuinely comparable, not measured at
> different points with different inputs:
>
> | metric | before | after |
> |---|---|---|
> | matched a rule | 0 | 37 |
> | leaked `[Distinct]` | 5 | 0 |
> | `And()`/`Or()` call form | 52 | 0 |
> | `Today()()` | 21 | 0 |
> | residual raw `CASE` in output | 54 | 0 |
> | residual untranslated infix | — | 1 (honestly reported — infix `LIKE` still has no Sigma equivalent) |
>
> **Correction 2026-07-30 (review round 2):** an earlier draft of this table
> published `16` for the "before" residual-raw-`CASE` figure. That number was
> real, but it was measured at the *wrong point in time* — it's the
> post-Task-5 intermediate figure (commit `1a47959`, the commit that first
> introduced the `residualCase` check), not the pre-Track-A baseline (`0be8116`)
> every other "before" figure in this table is measured against. Re-measured
> with one identical harness against both endpoints: the real baseline is
> **54**, not 16. The correct number *understates* the win (54→0 is a bigger
> improvement than 16→0 would have been), but a measured number sitting in the
> wrong column is wrong regardless of which direction the error points — worth
> writing down as a lesson: when publishing a before/after table, measure both
> ends with the same harness at the same time, don't reuse a number that was
> measured at an intermediate commit along the way.
>
> Honest framing, not overstated: **37 of 74 (50%) now match a converter rule
> exactly.** The rest fall through to the generic expression converter, which no
> longer *corrupts* them (no leaked `[Distinct]`, no `And()`/`Or()` call-form nulls,
> no `Today()()`, no raw `CASE` residue) but also does not fully translate every
> shape — 1 formula has a residual infix `LIKE` with no Sigma equivalent and is
> correctly reported as unconverted rather than silently shipped.
>
> **This 74-formula corpus never actually exercised Bug 3** (below), because its
> sample identifiers are mostly mixed-case Salesforce-style field names
> (`IsWon`, `CloseDate`, `created_on`), and Bug 3 only triggers on an ALL-CAPS
> bracketed ref. So "0 double-bracketing defects" measured here was never evidence
> the shared converter handled a Snowflake-backed Domo instance's actual column
> naming convention (`NET_REVENUE`, `ORDER_ID`, …) — it was an artifact of this
> particular corpus's identifier casing. **The generalisable lesson: a regression
> corpus's identifier-casing convention is itself a variable that can hide a real
> defect from every measurement run against it — verify a fix against the TARGET
> system's actual naming convention, not just whatever corpus happens to be
> lying around.** Bug 3 was found and fixed exactly because this corpus's four
> `formula-overrides.json` entries were re-verified live against real
> Domo-native SQL (ALL-CAPS backtick-quoted columns) rather than assumed safe
> once Bugs 1/2 closed. See the correction at the end of this section for the
> re-verified detail.

`SKILL.md`'s "one big idea" says Beast Mode is MySQL-dialect SQL and therefore
routes straight through `convert_sql_to_sigma_formula`, so "the formula layer is
nearly free." **Live testing disproves this — as measured 2026-07-30, before the
fix above.** Measured over the **81 unique Beast Modes** on the validation
instance:

| Construct | Beast Modes using it | Converter handles it? |
|---|---|---|
| `CASE WHEN … THEN … ELSE … END` | **58 / 81 (71%)** | ❌ **no** |
| `COUNT(DISTINCT …)` | 7 / 81 (8%) | ❌ **no** |
| Date fns (`DATEDIFF`/`DATE_ADD`/…) | 23 / 81 (28%) | partly |
| `IFNULL`/`COALESCE` | 1 / 81 | yes |
| `CONCAT` | 2 / 81 | yes |
| window (`OVER`/`RANK`/…) | 0 / 81 | n/a |

**60 of 81 (74%) hit at least one of the two confirmed breakages.**

### Bug 1 — `CASE WHEN` is not translated (invalid Sigma emitted) — ✅ RESOLVED (PR #115)
Sigma has **no `CASE` syntax**; conditionals are `If(cond, then, else)` (or
`Switch`). The converter emits a mangled hybrid that is not valid Sigma:

```
in : (CASE WHEN (SUM(NET_REVENUE) = 0) THEN 0 ELSE (SUM(GROSS_PROFIT) / SUM(NET_REVENUE)) END )
out: (CASE When(Sum([Net Revenue]) = 0) THEN 0 Else(Sum([Gross Profit]) / Sum([Net Revenue])) END )
```
`When(` and `Else(` are rendered as if they were function calls, and `CASE` / `THEN`
/ `END` are passed through verbatim. Expected shape:
`If(Sum([Net Revenue]) = 0, 0, Sum([Gross Profit]) / Sum([Net Revenue]))`.

Real Beast Modes nest this heavily — e.g. a `COUNT(CASE WHEN … THEN … END)` inside
an outer `CASE WHEN … = 0 THEN … ELSE … END` guard — so a naive regex fix is not
enough; this needs real conditional-expression handling.

**Fixed 2026-07-30** (sigma-data-model-mcp PR #115 / bead `jva2`). Root cause was
narrower than it looked: `lookConvertCase` already existed and was correct — the
bug was that `lookSqlToSigmaRules`'s CASE branch anchors on `/^CASE\b/i`, and Domo
wraps every Beast Mode in outer parentheses, so `(CASE WHEN …)` always missed the
anchor and silently fell through to the corrupting fallback. Stripping balanced
outer parens before pattern matching (plus an embedded-CASE scanner for a CASE
nested inside arithmetic/an aggregate, which the anchor alone can't reach) fixed
it. Verified: the exact input above now returns
`If(Sum([Net Revenue]) = 0, 0, Sum([Gross Profit]) / Sum([Net Revenue]))`
byte-identical to the hand-authored override.

### Bug 2 — `COUNT(DISTINCT x)` treats `DISTINCT` as a column — ✅ RESOLVED (PR #115)
```
in : (SUM(NET_REVENUE) / COUNT(DISTINCT ORDER_ID))
out: (Sum([Net Revenue]) / Count([Distinct] [Order Id]))
```
`DISTINCT` becomes a bracketed **column reference**. Sigma's form is
`CountDistinct([Order Id])`.

**Fixed 2026-07-30** (sigma-data-model-mcp PR #115 / bead `sqp1`) — the converter
now scans to the matching `)`, masks the whole `COUNT(DISTINCT …)` call out (the
live corpus nests a whole CASE inside one, so a regex on the argument alone was not
enough), converts the argument recursively, and splices back
`CountDistinct(<arg>)`. Verified: the input above now returns
`Sum([Net Revenue]) / CountDistinct([Order Id])` byte-identical to the
hand-authored override (when fed Title-Case bracket refs — see Bug 3 for why the
real ALL-CAPS-identifier case needed a second fix, now also resolved).

### Bug 3 — double-bracketing at OUR interface (this repo's fault, not the converter's) — ✅ RESOLVED (PR #116)
`convert-beast-modes.rb`'s pre-normalize step rewrites Domo's backtick-quoted
columns to Sigma bracket refs *before* calling the converter, but the converter
expected **bare SNAKE_CASE** identifiers and added the brackets itself:

```
bare  NET_REVENUE    -> [Net Revenue]     ✅
ours  [NET_REVENUE]  -> [[Net Revenue]]   ❌ double-bracketed (pre-fix)
```
So either the normalizer had to stop converting backticks to brackets, or the
converter had to be made idempotent for already-bracketed refs. The fix took the
second path.

**Correction 2026-07-30, re-verified after PR #115.** Bugs 1 and 2 were fixed
(above); Bug 3 was not — it was unrelated to the CASE/COUNT(DISTINCT) fix and
reproduced exactly as measured originally. Re-ran all four
`formula-overrides.json` entries in this corpus (`Margin Pct`, `Margin Pct 2`,
`Avg Order Value`, `Return Rate`) through the PR #115 converter with their real
`normalizedSql` (ALL-CAPS brackets from backtick-quoting): all four still
double-bracketed every column ref, e.g. `If(Sum([[Net Revenue]]) = 0, 0, …)`
instead of `If(Sum([Net Revenue]) = 0, 0, …)` — still invalid Sigma. Fed the SAME
formulas with Title-Case bracket refs (`[Net Revenue]`, not `[NET_REVENUE]`)
instead, the double-bracketing did not trigger (the converter's bracket-wrapping
pass keyed off an ALL-CAPS `[A-Z_][A-Z0-9_]*` pattern, which a mixed-case ref
never matches) — and the CASE/COUNT(DISTINCT) fix was then visible cleanly,
matching the hand-authored override byte-for-byte (aside from `Avg Order Value` /
`Return Rate` retaining a harmless outer-paren wrapper on the
generic-converter fallback path). This is why the shared 74-formula regression
corpus (mostly Salesforce-style field names like `IsWon`, `CloseDate`) measured 0
double-bracketing defects while these four Domo-native, ALL-CAPS-column Beast
Modes still failed: the corpus's identifier casing convention never exercised Bug
3 in the first place — **0/74 was never evidence the fix generalized to a real,
Snowflake-backed Domo instance's actual naming convention, it was an artifact of
this corpus's own (mixed-case) sample data.**

**Fixed 2026-07-30** (sigma-data-model-mcp PR #116 / bead `qorq`) — the
bracket-wrapping pass now masks `[…]` spans before its bare-ALL-CAPS-identifier
regex runs, so an already-bracketed ref (whatever its case) passes through once,
not twice. Re-verified live against PR #116: all four Beast Modes above now
convert to the hand-authored formula — two byte-for-byte, two differing only by a
semantically-inert wrapping paren (`(a / b)` vs `a / b`, the same formula in
Sigma). All four `formula-overrides.json` entries in this corpus have been
removed. **The generalisable lesson, worth keeping even though the bug itself is
fixed: a regression corpus's identifier-casing convention is a variable that can
hide a defect from every measurement run against it. Verify a fix against the
TARGET system's actual naming convention, not just whatever corpus is on hand.**

### Consequence — Beast Modes used to silently disappear from the migration (historical; all three bugs now fixed)
`convert-beast-modes.rb --lint` **drops** entries lacking a `sigmaFormula` rather
than shipping bad output (good, honest behaviour). But combined with the above,
the live run produced:

```
wrote discovery/formulas.json (0 formulas)
⚠ 4 Beast Mode(s) still lack a sigmaFormula: …
```

i.e. **every** Beast Mode was dropped, so the data model and workbook carried **no
calc columns at all**. The warning was loud, but the fidelity loss was total. On a
real customer dashboard where 71% of Beast Modes are conditional, this was the
single largest fidelity gap in the skill — larger than the chart-type gap below.
Post-fix (PRs #115 and #116): none of Bugs 1-3 contribute to this outcome any
longer for a Beast Mode using the shapes measured here; the shared converter
handles CASE WHEN, COUNT(DISTINCT), and ALL-CAPS bracket-quoted Domo columns
without a hand-authored override.

### Where the fix belongs
All three bugs were in the **canonical shared converter**
(`convertSqlToSigmaFormula` / its `formulas.ts` bracket-wrapping pass, in the
`sigma-data-model` MCP source), which every SQL-ish converter in this repo
depends on — so fixing them there was high leverage and benefits dbt / snowflake
/ sql / cognos alike. **Fixed 2026-07-30: Bugs 1-2 in PR #115, Bug 3 in PR #116.**
The `formula-overrides.json` sidecar mechanism in `convert-beast-modes.rb` stays
as the right escape hatch for whatever the shared converter cannot yet do next —
it is simply no longer load-bearing for this defect class.

## Chart-type coverage gap

`refs/card-to-element.md` documents **9** `badge_*` tokens. This instance uses
**22** distinct ones, of which **19 have no match** in the map — including
`badge_map` (7 cards), `badge_treemap`, `badge_bubble`, `badge_filledgauge`,
`badge_donut`, `badge_word_cloud`, `badge_calendar`, `badge_curved_symbolline`,
`badge_trendline`, `badge_two_trendline`, `badge_pop_bar_line`,
`badge_symbol_bar`, `badge_symbolline`, `badge_vert_symbol_overlay`,
`badge_horiz_100pct`, and every `*_multibar` / `*_stackedbar` / `*_nestedbar`
variant. Those all fall through to the unknown-chartType branch and emit a
bar-chart. Expanding this map is the largest remaining fidelity lever.
