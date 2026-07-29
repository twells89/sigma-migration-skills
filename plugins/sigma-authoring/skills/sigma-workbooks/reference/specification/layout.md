# Layout

Recipe book for the `layout` XML — when to write it, the two-tag grammar, and the silent-failure traps to watch for. `layout` is a **single workbook-top-level property** (one XML string holding one `<Page>` block per page — see the grammar below), **not** a per-page field: setting `pages[].layout` silently no-ops and Sigma falls back to auto-arrange (a common, hard-to-spot trap). Its value is the XML string described below. **Default to writing explicit `layout` XML for multi-element workbooks.**

Container *elements* (the `kind: "container"` JSON placeholders that pair with `<GridContainer>` in this XML) are covered in **Container elements** below.

## When to write layout vs. let Sigma auto-arrange

Write explicit `layout` when **any** of these apply:

- The page has **mixed element kinds** (charts + KPIs, controls + charts, text/image/divider polish). Auto-arrange treats them as a vertical stack and gives every element the same height — KPIs end up the size of charts, dividers get huge gutters around them.
- The user asked for specific positioning ("logo on left, title on right", "KPIs across the top", side-by-side charts).
- There's a `kind: "container"` element on the page. Containers without a matching `<GridContainer>` are functionally no-ops.
- The workbook has more than ~4 elements on a page. Auto-arrange becomes a long scroll.

Auto-arrange (omit `layout`) is fine when:

- The page has a single element.
- The page is a uniform stack of tables — auto-arrange produces a reasonable list view.
- The user explicitly says default layout is fine.

If unsure, write the layout. Writing one is cheap (the patterns below are copy-paste); a visually broken dashboard is expensive.

## Two-tag grammar

```xml
<?xml version="1.0" encoding="utf-8"?>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="<pageId>">
  <GridContainer elementId="<containerId>" type="grid" gridColumn="1 / 25" gridRow="1 / 4"
                 gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <LayoutElement elementId="<childId>" gridColumn="1 / 13" gridRow="1 / 4"/>
  </GridContainer>
  <LayoutElement elementId="<elementId>" gridColumn="1 / 25" gridRow="4 / 16"/>
</Page>
```

Each `<Page id>` matches a `pages[].id`. Each `elementId` matches an element on that page. `gridColumn` / `gridRow` use standard CSS grid line syntax (`start / end`); the default grid is 24 columns wide. One `<Page>` block per workbook page.

## `<GridContainer>` vs `<LayoutElement>`

- `<LayoutElement elementId="X" .../>` — **leaf**. Positions a single element; no children.
- `<GridContainer elementId="X" ...>...</GridContainer>` — **container**. Wraps child `<LayoutElement>`s in its own inner grid.

Use `<GridContainer>` for any tag with nested children — a `<LayoutElement>` only renders as a leaf.

## Container elements

A `kind: "container"` element in `pages[].elements[]` is a grouping placeholder — a labeled section, a branded header strip, a KPI row treated as a unit. It renders **only** when a matching `<GridContainer elementId="…">` positions it; declared without one, it's a no-op. Containers carry optional `style` (background color, border, corner radius, padding) and `backgroundImage` — pull the current shape from the spec rather than hardcoding it (the set of container/layout options is growing):

```bash
jq --arg k container 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

```yaml
- id: header
  kind: container
  style: { backgroundColor: "#0B3D91" }
```

- **Element on a background image:** to place an element *on top of* a container's `backgroundImage`, make it a **child** of that container in the layout XML — the background spans the container and the child sits on top.
- **When to skip:** with no shared background or logical grouping, position elements directly with `<LayoutElement>`. A container around a single element is usually overkill.

## `gridTemplateRows`: always `"auto"`

Row tracks are always `"auto"` — write `gridTemplateRows="auto"`. Height comes from the children, not from the row track.

### Stacking children inside a container

Because row tracks collapse to `"auto"`, height comes from children, not from the container's `gridTemplateRows`. Two patterns work:

**Side-by-side** — children share the container's row range, differ by `gridColumn`:

```xml
<GridContainer elementId="kpi-row" type="grid"
               gridColumn="1 / 25" gridRow="1 / 4"
               gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <LayoutElement elementId="kpi-1" gridColumn="1 / 9"  gridRow="1 / 4"/>
  <LayoutElement elementId="kpi-2" gridColumn="9 / 17" gridRow="1 / 4"/>
  <LayoutElement elementId="kpi-3" gridColumn="17 / 25" gridRow="1 / 4"/>
</GridContainer>
```

**Stacked rows** — children have disjoint `gridRow` spans within the container's row range:

```xml
<GridContainer elementId="header-row" type="grid"
               gridColumn="1 / 25" gridRow="1 / 12"
               gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <LayoutElement elementId="title"  gridColumn="1 / 25" gridRow="1 / 4"/>
  <LayoutElement elementId="kpi-1"  gridColumn="1 / 9"  gridRow="4 / 12"/>
  <LayoutElement elementId="kpi-2"  gridColumn="9 / 17" gridRow="4 / 12"/>
  <LayoutElement elementId="kpi-3"  gridColumn="17 / 25" gridRow="4 / 12"/>
</GridContainer>
```

Use stacked rows when you want a section header above a row of charts inside the same container, instead of moving those elements out to the page level.

## Page-level fields: `visibility` and `backgroundImage`

Besides `id`, `name`, and `elements` — and the workbook-top-level `layout` XML whose `<Page id>` block references this page's elements (see the top of this doc; `layout` is NOT a page field) — a page supports two optional fields:

- **`visibility`** — set to `hidden` to hide the page from end users. Omit for a visible page.
- **`backgroundImage`** — a page-wide background image, same shape as a container's `backgroundImage`: a required `url` plus an optional `style` block (`fit`, `horizontalAlign`, `verticalAlign`, `tiling`). `url` supports `{{formula}}` references.

```yaml
pages:
  - id: overview
    name: Overview
    visibility: hidden
    backgroundImage:
      url: https://cdn.example.com/bg.jpg
      style:
        fit: cover
        tiling: none
    elements: [ ... ]
```

## Layout `elementId` references

Each layout `elementId` must match an element `id` on that page exactly (case-sensitive). IDs are preserved verbatim on create, so the IDs in your saved spec stay valid for follow-up `PUT`s.

To study real grid-container idioms, fetch an existing multi-page workbook's spec (`GET /v2/workbooks/{id}/spec`, see SKILL.md Steps 1–2). The OpenAPI doesn't model the `layout` XML string, so a live spec is the way to see production layout.
