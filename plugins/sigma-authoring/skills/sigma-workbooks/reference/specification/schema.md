# Workbook Spec — Top-Level Schema

The live compiled OpenAPI is authoritative:

```bash
jq '.components.schemas.CreateWorkbookSpec' /tmp/sigma-api.json
```

## Canonical wrapped shape

```yaml
name: My Workbook
folderId: <folder-uuid>
description: Optional description
document:
  schemaVersion: 1
  kind: workbook
  elements: [...]  # required flat array
  pages: [...]     # required metadata only
  overlays: [...]  # optional modal/drawer metadata
  panels: [...]    # optional workbook panel metadata
  layout: |        # required by this skill whenever elements is non-empty
    <?xml version="1.0" encoding="utf-8"?>
    ...
  settings:
    theme: { ... }
    navigation: { ... }
  agents: [...]
```

POST requires outer `name`, `folderId`, and `document`. The live document
schema requires `schemaVersion`, `kind`, `elements`, and `pages`. PUT accepts
exactly `{document: {...}}`; never send `name`, `folderId`, or response metadata
beside it.

> Elements are not nested in pages, overlays, or panels. `document.elements` is
> the single literal element array. Placement in `document.layout` is the source
> of truth for page, overlay, panel, container, repeated-container, and tab
> membership. The API rejects `pages[].elements` and rejects an unplaced element.

### Settings

`document.settings.theme` replaces the removed `themeName` /
`themeOverrides` pair:

```yaml
settings:
  theme:
    name: Dark
    overrides:
      categoricalScheme: ["#2563EB", "#F97316", "#10B981"]
  navigation:
    pageHeader: enabled          # enabled | disabled
    pageSidebar: enabled         # enabled | disabled
    primary: sidebar             # sidebar (default) | header
    pageTabsInViewMode: shown    # shown (default) | hidden
```

> The `navigation` shape above (`pageHeader`/`pageSidebar`/`primary`/
> `pageTabsInViewMode`, all enabled/disabled or shown/hidden enums) replaces a
> stale `{position, pageHeader: {visibility}}` example this doc previously
> showed — that shape does not exist in the live OpenAPI. See `layout.md`
> §"Panels, headers, sidebars, and navigation" for the full field reference,
> the matching `document.panels[]` shapes, and an important workspace-gating
> caveat before you rely on any of it.

Theme and navigation sub-fields evolve; inspect `CreateWorkbookSpec` before
using an unfamiliar option. See `styling.md` for the richer theme recipes and
`layout.md` for navigation/header/sidebar guidance.

## Pages

Pages are metadata only:

```yaml
- id: overview
  name: Overview
  type: page              # optional; defaults to page
  visibility: hidden      # optional, or the allowlist object below
  pageWidth: full
  backgroundColor: "#F8FAFC"
  backgroundImage:
    source:
      kind: url
      url: https://cdn.example.com/background.png
    style:
      fit: cover
      horizontalAlign: center
      verticalAlign: center
      tiling: none
```

The live page schema exposes `id`, `name`, `type`, `visibility`, `pageWidth`,
`backgroundColor`, and `backgroundImage`; it does not expose `elements`.
`backgroundImage.source` is either `{kind: url, url}` or an uploaded-image
reference from a readback. **Live API change (2026-08-08): container
background images now require this same `source` wrapper too** —
`backgroundImage: {url: ...}` (the old flat container shape) hard-400s
(`"backgroundImage.source: Invalid value: undefined"`); use
`backgroundImage: {source: {kind: url, url: ...}, style: ...}` on containers,
same as the page shape above. Chart-element `backgroundImage` (the plot-area
background) was not re-verified in this pass — confirm its current shape
before assuming it matches.

Restricted visibility:

```yaml
visibility:
  kind: specific-users-and-teams
  assignments:
    users: [<user-id>]
    teams: [<team-id>]
```

## Overlays

Modal and drawer definitions live in `document.overlays`, not in `pages`.
Their content still lives in flat `document.elements`; a layout `<Page>` block
whose `id` equals the overlay id assigns content to it.

```yaml
overlays:
  - id: detail-modal
    type: modal
    name: Detail
    modal:
      width: medium
      header: { title: Details }
      footer: { primaryCta: { text: Done } }
  - id: filter-drawer
    type: drawer
    name: Filters
    drawer:
      width: medium
      showShadow: shown
      header: { title: Filters }
```

Overlay actions and open/close effects are in `reference/workflows/actions.md`.

## Panels

`document.panels` is the metadata collection for workbook panels such as
header/sidebar surfaces (live-confirmed 2026-08-10 on a navigation-enabled
workspace). Each entry is discriminated by `type` (`"header"` | `"sidebar"`).
Panel content is selected by layout placement — a dedicated `<Panel id="...">`
block in the `layout` XML (its own tag, not `<Page>`), not a nested element
list. See `layout.md` §"Panels, headers, sidebars, and navigation" for the
full field reference, the `<Panel>` layout shape, the
`document.settings.navigation` on/off switch, and the workspace-entitlement
gate. Preserve unknown panel metadata on round trip.

## Response-only fields

GET can return these outer server-managed fields:

- `workbookId`, `url`
- `documentVersion`, `latestDocumentVersion`
- `ownerId`, `createdBy`, `updatedBy`, `createdAt`, `updatedAt`

They are not part of a PUT body.

## ID and layout rules

- Page, overlay, panel, element, action, and column IDs must be unique in their
  documented scopes.
- IDs submitted on POST are preserved.
- Every layout `elementId` must match a flat `document.elements[].id`.
- Every element must be placed exactly where intended in layout. Do not infer
  ownership from array adjacency.

## Related: `kind: "report"` documents are a separate resource, not a workbook variant

The compiled OpenAPI also defines a `report` document (`document.kind:
"report"`), but it is **not** something you set on a `/v2/workbooks/spec`
payload — it's a sibling top-level resource with its own endpoint family:
`POST /v2/reports/spec`, `POST /v2/reports/spec/verify`, `GET`/`PUT
/v2/reports/{reportId}/spec`, plus a full set of `/v2/reports/{reportId}/...`
routes (`elements`, `pages`, `schedules`, `send`, `export`, …). A workbook
becomes a report via `POST /v2/workbooks/{workbookId}/convertToReport`, not
by changing `document.kind` in place.

Reports use **pixel** layout, not grid layout. The OpenAPI's `layout`
description for a report document reads:

> Pixel layout as XML. Top-level Page and Panel roots; Element children use
> absolute x/y/width/height in pixels. Panel roots require type="header" or
> type="footer".

Key differences from the workbook shapes documented in this skill:

- **Absolute pixel placement** (`x`/`y`/`width`/`height`) instead of
  `gridColumn`/`gridRow` grid-line syntax.
- **Report panels are `header`/`footer`** (top/bottom of a printed page),
  each with `config: {height, backgroundColor}` (height in pixels) and a
  `pages[]` assignment list — not `header`/`sidebar` like workbook panels
  (see `layout.md`). Same vocabulary (`panels`, `type`, `config`), different
  enum values, different resource — don't conflate the two.
- `document.config` on a report carries `margin`, `pageHeight`, and
  `pageWidth`, all in pixels — a report-level print/page-size block with no
  workbook equivalent.

This skill targets `/v2/workbooks/spec`; report authoring is out of scope
here. Load the sibling `sigma-reports` skill for the report lifecycle, pixel
layout, support matrix, offline validator, and safe full-replacement workflow.
Do not reuse workbook layout recipes for reports.

## Minimal working example

```yaml
name: Sales Dashboard
folderId: <folder-uuid>
document:
  schemaVersion: 1
  kind: workbook
  elements:
    - id: sales-table
      kind: table
      name: Sales Data
      source:
        kind: warehouse-table
        connectionId: <connection-uuid>
        path: [SALES_DB, PUBLIC, ORDERS]
      columns:
        - id: col-order-id
          name: Order ID
          formula: "[ORDERS/ORDER_ID]"
        - id: col-amount
          name: Amount
          formula: "[ORDERS/AMOUNT]"
  pages:
    - id: overview
      name: Overview
  layout: |
    <?xml version="1.0" encoding="utf-8"?>
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="overview">
      <Element elementId="sales-table" gridColumn="1 / 25" gridRow="1 / 20"/>
    </Page>
```

Raw warehouse names are accepted in warehouse-table formulas. Sigma may
canonicalize them on POST or preserve the raw spelling. Always GET the saved
spec and use the returned form for later edits; Custom SQL aliases and join
keys follow special rules documented in `formulas.md` and `sources.md`.
