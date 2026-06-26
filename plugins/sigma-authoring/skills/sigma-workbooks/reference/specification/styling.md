# Styling — designed-looking dashboards from spec alone

> **These are options to draw from, not a house style.** Reach for them when the user asks for
> design polish or you're composing from scratch with no brand direction. Never impose them on
> a migration (fidelity to the source dashboard wins) or over a user's stated branding.

Recipe library for moving a workbook from "default auto-arrange" to "looks designed." Every pattern below is built from fields that already exist in the workbook spec — no external CSS, no theme JSON, no UI editing required.

The recipes were extracted from a 2026-05-29 design experiment that built 6 versions of the same dashboard (default → polished) and compared screenshots via the `/v2/workbooks/{id}/export` PNG endpoint. The findings caught two silent-failure bugs (see `charts.md` donut section) and 4 undocumented container `style` knobs (see `layout.md`).

---

## Anti-patterns — the generic-AI tells (and the recipe that fixes each)

The recipes below are the *positive* moves. This is the *negative* checklist: the visual tropes that
mark a dashboard as generic AI output. They're easiest to catch on a render — after you POST, export
each page to PNG (`/v2/workbooks/{id}/export`) and read it against this list. Each tell links to the
fix already in this file. **Same caveat as the recipes: these are defaults for a from-scratch build,
never an override of a user's stated branding or a migration's source fidelity.**

- [ ] **No focal point** — every tile the same size and weight; the page reads as a uniform grid with
      no "most important thing." Fix: give the signature element a **wider `gridColumn` span** (e.g.
      a hero trend at `1 / 17` with a supporting chart at `17 / 25`), not an automatic 50/50. Proportion
      should follow priority — see *Putting it together* and *Balance density top vs bottom*.
- [ ] **Automatic equal-width rows** — two elements split a row 50/50 regardless of priority. Equal
      spans are right for a **KPI strip** (true peers) and genuine comparisons; for a primary-vs-supporting
      pair, weight the primary. See Recipe 2 (equal KPI cards = correct) vs the hero proportion above.
- [ ] **Every page opens the same way** — each page of a multi-page workbook leads with an identical
      KPI band. Lead each page with the thing it's *for*; vary the opening. (Launcher/landing pattern and
      `visibility: hidden` data pages help — see *Interaction patterns*.)
- [ ] **No grid breaks** — the same 2–3-column chart row repeats down the whole page ("spreadsheet of
      cards"). Change the layout when the section's purpose changes: hero row → section header → paired
      charts → full-width detail. See Recipe 3 (section headers) and the composition pattern.
- [ ] **Decorative accent overuse** — the accent color is sprayed onto every card, tint, and surface, so
      nothing stands out. Reserve it: tint the hero band and the primary KPI label, default the rest to the
      neutral card surface (`#FBFBFB`/`#FAFBFC`, not pure white). **Carry *one* accent system through the
      page** — repeat the KPI label colors in the charts below, in order. See *Composition principles*.
- [ ] **Oversaturated status colors** — raw default red/green badges. Use the vetted palette
      (`#10B981` growth, `#F59E0B`/`#EF4444` warning/negative only) and reserve red/amber for genuinely
      negative values. See *Vetted color palette* and Recipe 5.
- [ ] **Flat typography** — every heading, KPI, and label at the same size/weight; "feels like a form."
      Build a scale: hero `#`/`##` title → quiet uppercase `p-small` section labels → KPI `value.fontSize`
      (28–32) → table cells. See *Typography* and *Quiet section labels*.
- [ ] **Centered text everywhere** — every block centered, so every section reads like a landing page.
      Default to left for text and titles (note: left-aligned `h-*` heading classes are rejected — use
      markdown `#` + a `<span>`); reserve centering for a single hero moment. See *Typography*.
- [ ] **Nested cards** — a card inside a card inside a card (e.g. a chart wrapped in its own styled
      container that already sits in a band container). Flattens hierarchy and adds noise. Use containers
      for **bands and KPI cards**, not to re-wrap every element; separate with spacing, type, and
      dividers (Recipe 4) before adding another container.

---

## Workbook theme (2026-06-18 release; `themeOverrides` schema documented 2026-06-25)

A workbook carries a **top-level theme**, alongside `pages` and `layout`:

```yaml
name: My Workbook
schemaVersion: 1
pages: [ ... ]
layout: ...
themeName: Dark          # built-in: Light | Dark | Surface  — OR an org theme UUID
themeOverrides:          # optional — colors / fonts / layout style / table defaults
  colors:
    text: "#FFFFFF"
    highlight: "#1E88E5"
    surface: "#101826"
```

The **full `themeOverrides` schema is now in the public OpenAPI** (`.../spec` POST/PUT request body and GET response — added 2026-06-25; earlier release notes shipped the feature before the spec documented it). The OpenAPI is the source of truth for every field; the list below is the verified summary.

### `themeName`

- Accepts a **built-in** name (`Light` / `Dark` / `Surface`) or an **org theme id** (a UUID). All round-trip. Only the **format** is checked, not existence: a malformed value 400s, but a well-formed but nonexistent UUID is accepted as-is and renders broken (like a bad `pluginId`) — so a clean POST is not proof the theme exists.
- **There is no API to discover theme names.** Built-ins are the three above; an org theme id can only be learned by reading a workbook spec that already uses it (admin Branding Settings shows names, not ids). So the theme id has to come from somewhere external — an agent cannot enumerate them from a single call.
- **Use the per-org theme registry instead of asking blind.** `harvest-theme-registry.py` (in `sigma-migration-skills/shared/scripts/`) scans an org's workbook specs once and writes `~/.sigma-migration/theme-registry.yaml`, keyed by API host, with each `themeName` and how many workbooks use it. Read it to suggest the org's themes ranked by frequency — **the most-used org-UUID is almost always the org default.** If the registry is missing or stale, run the harvester (a full scan is ~20–40s and persists), then fall back to asking the user only if no org themes are found. Singletons are often test/transient junk — prefer the high-count entries.

### `themeOverrides` — one-off tweaks stacked on the base theme

Every field below **round-trips and renders** — verified live 2026-06-26 (POST → GET round-trip with 0 dropped fields, + PNG export showing the override applied; a 14-key override on a `Light` base produced a dark canvas, pill cards, cyan headers, row banding, and a monospace data font).

| Field | Type / values | Notes |
|---|---|---|
| `colors` | `{ text, highlight, surface, success, warning, danger, darkMode }` | hex; `highlight` maps to theme `$primary`. `darkMode: shown\|hidden`. |
| `colorOverrides` | `{ <token>: "#hex" }` | per-token layout colors; keys match the theme color inspector (`backgroundCanvas`, `elementBackground`, …). |
| `fonts` | `{ textFont, dataFont }` | **font family names.** `textFont` = format-panel "Text font"; `dataFont` = "Data font" (values/numbers). |
| `titleFont` | `{ color, fontSize (6–96), fontWeight: bold\|normal }` | element **title** font. |
| `borderRadius` | `square \| round \| pill` | corner rounding. |
| `elementBorder` | `{ color, width (0–3) }` | `color` = hex **or** `{ kind: theme, ref: "colors-xxx" }`. |
| `categoricalScheme` | palette name **or** `["#hex", …]` | custom categorical palette (incl. donut/pie — see below). |
| `sequentialScheme` / `divergingScheme` | named scheme (string) | continuous palettes. |
| `pageWidth` / `maxPageWidth` | `full\|large\|medium\|custom` / number (≥600) | `maxPageWidth` applies when `pageWidth: custom`. |
| `space` | `{ unit: small\|medium\|large, showElementPadding: shown\|hidden }` | element spacing / padding. |
| `hasCards` | `shown \| hidden` | card-style element chrome. |
| `layoutColors` | `{ useElementForeground: shown\|hidden }` | render elements above the canvas. |
| `invertTooltipColors` | `shown \| hidden` | |
| `tableStyles` | see below | full table-default block. |

`tableStyles`: `preset` (`spreadsheet`\|`presentation`), `cellSpacing` (`extra-small`\|`small`\|`medium`\|`large`), `gridLines` (`none`\|`vertical`\|`horizontal`\|`all`), `banding` + `bandingColor`, `outerBorder`, `autofitColumns`, `headerDividerColor`, `heavyVerticalDividers`/`heavyHorizontalDividers` (pivot only), and `textStyles.{header,cell,columnHeader,rowHeader}` — each `{ font, fontSize, fontWeight, color, backgroundColor, align, verticalAlign, textWrap }`. Color fields take hex or a `{ kind: theme, ref }` reference.

**Gotchas:**
- The server **lowercases hex** on save (`#0F172A` → `#0f172a`) — cosmetic, not a drop; don't treat it as a failed round-trip.
- `themeOverrides` is the spec path to **donut/pie slice colors** — set `categoricalScheme` here (the per-element `color.scheme` is still silently dropped on donut/pie — see Recipe 5). This supersedes the old "set the theme in the UI" workaround.
- Theme vs. the recipes below: a theme is the global skin (selected, org-managed). The recipes here style individual elements from spec fields and **stack on top of** whatever theme is set. For a migration, prefer the source dashboard's look; reach for a theme only when the user asks to apply one.

---

## What "designed" looks like via spec

You can ship a dashboard that looks legitimately professional from the spec by stacking five patterns:

1. **Branded hero header strip** — full-width container with a dark background and a colored Markdown title sitting inside.
2. **KPI cards** — each KPI inside its own white container with rounded corners + a thin border + a colored Markdown category label.
3. **Section headers** — Markdown `##` text elements between groups of elements.
4. **Categorical chart colors** — `color.scheme` on bar/line/area/combo (not donut/pie — those use the workbook theme).
5. **Number formatting on everything** — `$,.2s` for KPI values (yields `$103k`), `$,.0f` for table cells, never raw numbers.

If you do all five, the dashboard reads as designed. Skip any one and it reads as "the LLM didn't try."

---

## Vetted color palette

Use this Tailwind-derived modern palette unless the customer has specified branding:

```
Primary blue:   #3B82F6
Green:          #10B981
Amber:          #F59E0B
Red:            #EF4444
Purple:         #8B5CF6
Cyan:           #06B6D4

Dark surface:   #0F172A   (slate-900 — hero header bg)
Muted text:     #94A3B8   (slate-400 — subtitle text on dark bg)
Card border:    #E2E8F0   (slate-200 — subtle 1px on white cards)
Card bg:        #FFFFFF
Page bg:        (Sigma default — don't override)
```

Apply consistently: the same blue (`#3B82F6`) for the "primary metric" KPI label and the primary bar chart; green for "growth" metrics; amber/red for "warning" / "negative" only.

---

## Recipe 1 — Hero header strip

A dark, full-width strip at the top with a bold white title and a muted subtitle.

```yaml
elements:
  - id: hero
    kind: container
    style:
      backgroundColor: "#0F172A"
      borderRadius: round
  - id: title
    kind: text
    body: |
      # <span style="color: #FFFFFF">Orders Overview</span>
      <span style="color: #94A3B8">Net revenue, order mix, and channel performance — last full period</span>
```

```xml
<GridContainer elementId="hero" type="grid"
               gridColumn="1 / 25" gridRow="1 / 5"
               gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <LayoutElement elementId="title" gridColumn="1 / 25" gridRow="1 / 5"/>
</GridContainer>
```

Notes:
- Title color via Markdown `<span style="color: #...">`. For size control beyond `#`/`##`, use Sigma's typography classes (`<p class="h-med">` etc.) and `font-family` spans — see **Field-observed idioms** below.
- For an edge-to-edge image background instead of a solid color, swap `backgroundColor` for `backgroundImage` and add `padding: none` (`backgroundColor` + `padding: none` is also valid — it just blocks `border*`).

---

## Recipe 2 — KPI card row

Three (or four) KPIs in styled white cards, each with a colored category label above the value.

```yaml
elements:
  - id: kpi-net-box
    kind: container
    style:
      backgroundColor: "#FFFFFF"
      borderRadius: round
      borderColor: "#E2E8F0"
      borderWidth: 1
  - id: kpi-net-label
    kind: text
    body: |
      <span style="color: #3B82F6">**NET REVENUE**</span>
  - id: kpi-net
    kind: kpi-chart
    name: ' '   # single space — suppresses the KPI's own title (see note below)
    source:
      elementId: master
      kind: table
    columns:
      - id: kpi-nr-val
        formula: Sum([Master/Net Revenue])
        format:
          kind: number
          formatString: "$,.2s"    # renders as "$103k"
    value:
      columnId: kpi-nr-val
```

```xml
<GridContainer elementId="kpi-net-box" type="grid"
               gridColumn="1 / 9" gridRow="5 / 12"
               gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <LayoutElement elementId="kpi-net-label" gridColumn="1 / 25" gridRow="1 / 3"/>
  <LayoutElement elementId="kpi-net"       gridColumn="1 / 25" gridRow="3 / 8"/>
</GridContainer>
```

Repeat the container + label + KPI triple for each metric, switching the label color (green for growth, purple for averages, amber for trailing-indicator metrics). Three across at columns `1/9`, `9/17`, `17/25` is the standard layout.

> **Set the value column's `name: ' '` (a single space)** when a colored Markdown label sits above the KPI — otherwise you get a **duplicate title**: the card label (`NET REVENUE`) *and* the KPI's own title (`Net Revenue`) stacked in the same card. The title comes from the element `name` **and, when that's absent, the bound value column's `name`** — so with no element name (the usual case here) the *column* name is what leaks through. There's no `showTitle: false` field, and **omitting the name does NOT work** — an empty/absent name is stripped and the title re-derives. Only a single space persists. (Verified live + rendered; this is the #1 KPI-card mistake.)

---

## Recipe 3 — Section header

A heading row between groups of elements. Tighter than a hero, looser than a chart.

```yaml
- id: section-charts
  kind: text
  body: |
    ## Revenue breakdown
```

```xml
<LayoutElement elementId="section-charts" gridColumn="1 / 25" gridRow="12 / 14"/>
```

Use these between (a) KPI row and chart row, (b) chart row and detail table, (c) any two thematically distinct chunks. Two per dashboard is usually enough — more than that and the page reads as fragmented.

---

## Recipe 4 — Divider before the detail table

Between the high-level charts and the "drill down to raw rows" table, a horizontal rule sets the visual separation cleanly.

```yaml
- id: divider-1
  kind: divider
```

```xml
<LayoutElement elementId="divider-1" gridColumn="1 / 25" gridRow="26 / 27"/>
```

A 1-row span. The `divider` element is a first-class kind, not a hack — see `content-elements.md`.

---

## Recipe 5 — Categorical chart colors

For bar / line / area / combo charts, pin slice colors to the vetted palette:

```yaml
- id: chart-by-status
  kind: bar-chart
  source:
    elementId: master
    kind: table
  columns:
    - id: bs-status
      formula: '[Master/Order Status]'
    - id: bs-rev
      formula: Sum([Master/Net Revenue])
      format:
        kind: number
        formatString: "$,.0f"
  xAxis:
    columnId: bs-status
    sort:
      by: bs-rev
      direction: descending
  yAxis:
    columnIds: [bs-rev]
  color:
    by: category
    column: bs-status
    scheme: ["#3B82F6", "#F59E0B", "#EF4444"]
```

`scheme` is positional — pin colors to category sort order, not to category names. Sort by the value descending to get "biggest bar = primary blue, smaller = warning amber/red."

> **Donut and pie do NOT accept `scheme`.** The field is silently stripped on those chart kinds. To customize donut/pie slice colors from spec, set `themeOverrides.categoricalScheme` at the workbook level (see *Workbook theme* above) — that path is now spec-authorable and verified. See `charts.md` donut section for the verified gotchas.

---

## Recipe 6 — Number formatting

Every value gets a `format` block. The four most useful:

| Format string | Output |
|---|---|
| `"$,.2s"` | `$103k` — compact, perfect for KPI tiles |
| `"$,.0f"` | `$103,247` — full precision, table cells |
| `",.0f"` | `1,234` — count with thousands separator |
| `",.2%"` | `12.34%` — percentage |

```yaml
columns:
  - id: kpi-val
    formula: Sum([Master/Revenue])
    format:
      kind: number
      formatString: "$,.2s"
```

See `formatting.md` for the full d3-format / strftime reference.

---

## Putting it together — page composition pattern

The 24-column grid layout that pulls all six recipes into one dashboard:

```
Row 1-5      Hero header (full width)
Row 5-12     KPI tile 1 | KPI tile 2 | KPI tile 3   (each 8 cols wide)
Row 12-14    Section header — "Revenue breakdown"
Row 14-26    Donut / pie  | Bar chart                (each 12 cols wide)
Row 26-27    Divider
Row 27-29    Section header — "Order details"
Row 29-37    Detail table (full width)
```

XML:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-1">

  <GridContainer elementId="hero" type="grid"
                 gridColumn="1 / 25" gridRow="1 / 5"
                 gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <LayoutElement elementId="title" gridColumn="1 / 25" gridRow="1 / 5"/>
  </GridContainer>

  <GridContainer elementId="kpi-net-box" type="grid"
                 gridColumn="1 / 9" gridRow="5 / 12"
                 gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <LayoutElement elementId="kpi-net-label" gridColumn="1 / 25" gridRow="1 / 3"/>
    <LayoutElement elementId="kpi-net"       gridColumn="1 / 25" gridRow="3 / 8"/>
  </GridContainer>
  <!-- two more KPI containers at 9/17 and 17/25 -->

  <LayoutElement elementId="section-charts"   gridColumn="1 / 25"  gridRow="12 / 14"/>
  <LayoutElement elementId="chart-by-channel" gridColumn="1 / 13"  gridRow="14 / 26"/>
  <LayoutElement elementId="chart-by-status"  gridColumn="13 / 25" gridRow="14 / 26"/>

  <LayoutElement elementId="divider-1"      gridColumn="1 / 25" gridRow="26 / 27"/>
  <LayoutElement elementId="section-detail" gridColumn="1 / 25" gridRow="27 / 29"/>
  <LayoutElement elementId="master"         gridColumn="1 / 25" gridRow="29 / 37"/>
</Page>
```

---

## Field-observed idioms (Sigma SE demo org, 2026-06-12)

Mined from the specs of Sigma's flagship demo workbooks (Cold Provisions, Marketing
Control Center, Actuarial Insights Portal, Power Grid Operations, Trade Surveillance,
Headcount Forecasting — ~1.6MB of designed spec), then **live-verified by POST/PUT on a
standard production org on 2026-06-12** (a redesigned 4-page workbook). Items marked
✓ round-tripped through the spec API; items marked ✗ exist in demo specs (UI-authored)
but were REJECTED when pushed via the API — with the workaround noted. The API
validates HTML bodies strictly; the verified rules are below.

**The headline lesson:** in the polished demos, *text (285), container (221), image (56)
and control (161) elements outnumber charts ~10:1*. The designed look is composition —
typography, cards, icons, density — not chart configuration.

### Typography — far beyond bare Markdown

Text bodies accept HTML `<p>` with **Sigma typography classes** and inline style — but
the spec API validates them. Verified rules (the UI is more permissive than the API):

```yaml
body: '# <span style="color: #FFFFFF">Repo Health</span>'                                              # ✓ markdown heading + span color
body: '<p class="p-small"><span style="color: #94A3B8">subtitle text</span></p>'                       # ✓ p-small / p-large stand alone
body: '<p class="h-med" style="text-align: center"><span style="color: #0e2e52">Title</span></p>'     # ✓ h-* classes need a non-default alignment
body: '<p class="h-med"><span style="color: #FFF">Title</span></p>'                                    # ✗ 400: "<p> carries no non-default block style or alignment"
body: '<p class="h-med" style="text-align: left">…'                                                    # ✗ left = default, same 400
body: '<span style="color: var(--colors-textNeutral)">…</span>'                                        # ✗ 400: "color value must be hex" — theme CSS vars are UI-only; use hex
```

- Classes: `h-med`, `h-small` (only with `text-align: center|right`), `p-large`, `p-small` (standalone OK). For **left-aligned headings use markdown `#`/`##` + a `<span>`** for color.
- Markdown (`**bold**`, `*italic*`) works inside spans; `font-family` spans work (observed `font-family: Inter`).
- Colors in spans must be **hex** via the API (`var(--colors-*)` appears in UI-authored demo specs but the API rejects it).
- Text elements take a top-level `verticalAlign: middle` ✓ (sibling of `body`, not in `style`).

### Dynamic text — `{{…}}` formula templating ✓

Text bodies interpolate live formulas, including cross-element aggregates — verified:

```yaml
body: '<p class="p-small"><span style="color: #E2E8F0">**{{Sum([Clones/Clones])}}** clones · **{{CountDistinct([Clones/Repo Name])}}** repos</span></p>'
```

- The server normalizes markdown that crosses `{{…}}` boundaries into per-segment spans (harmless).
- `Text()` is **single-argument** — `Text(Sum(...), "#,##0")` renders as `Invalid Query: Text expected 1 argument` *in the rendered text only*: the spec POSTs fine and the SQL compile check passes, so **only a visual render catches templating errors**.
- Demo orgs also use `{{CallText("ai_query", …)}}` for AI narrative summaries and template image `url` fields (`url: '{{[Stores/Store Image Url]}}'`) — not yet round-tripped here.

### Cards and chips ✓

- `borderRadius` has a third value: **`pill`** ✓ (heavily used — softer than `round`).
- **Tinted chip cards** ✓: pastel fill + same-hue border, verified set — blue `#f0f7ff`/`#bad9f8`, cyan `#e6f6fa`/`#a5dded`, green `#e4f7ec`/`#a4dfc0`, purple `#f0ebfa`/`#cfc0ee`. Soft neutrals `#FBFBFB`/`#FAFBFC` with `#e6e6e6` borders are the default card surface (not pure white).
- `style.borderColor` accepts **theme refs** in demo specs: `borderColor: {kind: theme, ref: colors-border}` — not yet round-tripped via API (hex always works).
- `padding: none` ✓ for dense, app-like layouts.
- `backgroundColor: "auto"` lets a container adapt to the theme.

### KPIs — style them directly, no wrapper needed ✓

`kpi-chart` takes its own `style` (so a KPI can be its own card), `value.fontSize`, `value.color`, and a `layout` block — all verified:

```yaml
style: { backgroundColor: "#f0f7ff", padding: none }      # match the chip tint so the KPI blends in
value: { columnId: k1-v, fontSize: 28 }
layout: { anchor: middle }            # also: verticalAnchor: start|middle, titleOrient: bottom, comparisonValueOrient: right
```

**KPI strip inside a dark hero** ✓ — the strongest "designed" move observed (KPIs live in the
hero band, not below it): one dark container spans the full band; the title text, accent-colored
labels, and the KPIs all lay out inside its `GridContainer`; each KPI pops with
`value: {columnId: …, fontSize: 32, color: "#FFFFFF"}`. Use light accent tints for the labels on
dark (`#93C5FD` blue, `#67E8F9` cyan, `#6EE7B7` green, `#C4B5FD` purple).

Make the KPI background **transparent** with 8-digit alpha hex —
`style: {backgroundColor: "#00000000", padding: none}` ✓ — so the numbers sit directly on the
band. Matching the band's solid color instead breaks the moment the band is a gradient: each KPI
renders as an opaque panel hugging its numeral, which reads as "cut off" at real viewport widths.
Alpha hex `#rrggbbaa` is accepted and rendered (the OpenAPI only documents `#rrggbb`).

### Single-color chart marks ✓

The top-level `color` channel on bar/line/area charts takes a discriminated object — `by: single`
for one hue, `by: category` for the positional `scheme` (Recipe 5):

```yaml
color: { by: single, value: "#3B82F6" }     # ✓ one hue for all marks
color: "#3B82F6"                            # ✗ 400 "Invalid value: string"
color: { value: "#3B82F6" }                 # ✗ 400 "Invalid value: object" (missing by)
```

`name` can also be an object `{text: "Revenue for {{[Store/Name]}}", fontSize: 16}` (templated titles — observed, not yet round-tripped).
41 of 109 demo KPIs carry a `comparison`, 21 a `trend` sparkline — but per `kpis.md`
the comparison/trend *column binding* is UI-only; the spec styles what the UI bound.
For spec-only PoP figures use the formula-column recipe in `kpis.md`.

### Gradient hero bands — hosted image only

Neil-style gradient banners are NOT directly authorable:

- `style.backgroundColor` with a CSS `linear-gradient(...)` string is **accepted by POST/PUT but
  silently dropped** — the container renders with *no* background at all (worse than a 400; only
  a render catches it). Hex only.
- ✓ **The working recipe (re-verified 2026-06-26): `backgroundImage` is a TOP-LEVEL field on the
  container element — a SIBLING of `style`, NOT nested inside `style`.** Nesting it under `style`
  silently drops it (posts `200`, GET readback shows only `backgroundColor`, renders flat) — that was
  a real mistake caught this session. The correct shape:
  ```yaml
  - id: hero
    kind: container
    style: { backgroundColor: "#0B1120", borderRadius: round }   # solid fallback / load color
    backgroundImage: { url: "https://…/gradient.png" }           # <-- sibling of style, not inside it
  ```
  Lay the title **text element inside the hero container** and it overlays the gradient (text-over-image
  works for a container background — unlike a separate `image` element, which does NOT z-stack under
  text and instead stacks vertically). Generate a small gradient PNG (512×96 scales fine); external
  https images **do render in PNG export** (raw.githubusercontent.com and GitHub Pages both work;
  data-URIs are still WAF-blocked — below). `url` supports `{{formula}}` templating.
  - A pure-Ruby/zlib PNG encoder is ~20 lines; host via `gh api PUT .../contents/...` to a long-lived
    branch and reference the `raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>` URL
    (`Content-Type: image/png`), or GitHub Pages (mind build pipelines — a Vite/Actions site only ships
    what its build emits, so static assets go in `public/`).
  - Separately, chart elements (bar/line/area/…) also accept a `backgroundImage: {url}` for the
    **plot area** — a different field on a different element, documented in the OpenAPI.

### Icons — inline SVG data-URIs ✗ (WAF-blocked via API)

Demo workbooks are full of `image` elements with base64 [Lucide](https://lucide.dev) SVG data-URIs
(`url: "data:image/svg+xml;base64,…"`) — those specs were authored in the UI. **Pushing the same
shape through the public API gets the request 403'd by Cloudflare's WAF** (an HTML "Just a moment…"
challenge page, not a Sigma error — the base64-SVG payload trips an XSS signature). Workarounds:
host icons at an https URL, or skip icons (tinted chips + typography carry the design). Data-driven
`url: '{{[El/Image Url]}}'` templating and circular photos
(`style: {fit: cover, borderRadius: pill, borderColor: "#ffffff", borderWidth: 3}`) are unaffected shapes.

### Composition principles for a "sleek" page ✓

Options, not a template — these are the moves that fixed a page that read as two
disconnected halves (a dark hero floating over a sparse light body):

- **Compact the hero band.** Size the container to its content: if the inner grid ends at
  row N, end the band at N+1. Dead dark rows under the KPI values are the #1 "looks off" signal.
- **Quiet section labels.** Between a strong hero and the content, a small uppercase
  `<p class="p-small"><span style="color: #64748B">**LABEL**</span></p>` reads sleeker than a big
  `##` heading — the heading competes with the hero, the label connects to it.
- **Carry one accent system through the page.** Whatever colors the KPI labels use, repeat them
  in the charts below (`color: {by: single, value: …}`) in the same order. The eye links each
  trend to its KPI.
- **Prefer single-series trend charts.** Multi-measure lines get default series colors you cannot
  set via spec (no per-series scheme); one measure per chart, hue-matched, is cleaner and authorable.
- **Balance density top vs bottom.** A 4-KPI strip over 2 charts reads bottom-light; match the
  rhythm (4-over-3 or 3-over-3) or add a detail row.

### Interaction patterns

- **Segmented control as date-grain switcher** — the single most common interactive idiom:

```yaml
kind: control
controlType: segmented
controlId: cDateGrain
source: { kind: manual, valueType: text, values: [Quarter, Month, Week, Day], labels: [Quarter, Month, Week, Day] }
value: Week
```

- **Launcher/landing pages**: a Homepage of nav cards (container + `**BOLD TITLE**` text + one-line description per card) makes a workbook feel like an app. Pair with `visibility: hidden` data pages.

---

## Things that are NOT designable via spec (as of 2026-05-29)

Don't waste a round-trip trying to set these — the spec API silently drops them.

- **Chart tooltip customization** (spec-findings #10)
- **Trellis / small-multiples layout** (spec-findings #11)
- **Donut / pie slice colors** (spec-findings #22)
- **KPI title color or "hide title" toggle** — `name` always renders as a black title
- **Element title font size / font family** — the `name` field has no `style` sibling. (Text *elements* CAN set fonts via `<span style="font-family: …">` — see field-observed idioms above; it's only the title `name` that can't.)
- ~~**Workbook-level palette / theme** via spec~~ — **RESOLVED**: now spec-authorable via top-level `themeName` + `themeOverrides` (see *Workbook theme* above).
- **Chart `tooltip` / `trellis*` fields** (UI-only)

If a customer needs slice color branding on donut/pie, set the workbook theme in the UI after the spec is posted.