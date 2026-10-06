# Styling — designed-looking dashboards from spec alone

> **These are options to draw from, not a house style.** Reach for them when the user asks for
> design polish or you're composing from scratch with no brand direction. Never impose them on
> a migration (fidelity to the source dashboard wins) or over a user's stated branding.

Recipe library for moving a workbook from "default auto-arrange" to "looks designed." Every pattern below is built from fields that already exist in the workbook spec — no external CSS, no theme JSON, no UI editing required. **Compose from this file; do not stamp it.** The five-pattern stack under *What "designed" looks like* is one exec-dashboard composition — not a house style, and not the generate-app look. An exception command center, a planning grid, and an approval queue should not all open with the same navy hero and three white KPI cards. The **anti-pattern list** is the bar (no focal point, equal-width everything, flat type). Pick the recipes that serve this page's job, the org's theme, and any branding the user stated.

For operational apps, choose hierarchy first in
`reference/workflows/app-compositions.md`: `workbench`, `queue-rail`, or
`builder-preview`. Styling supplies paint and local grouping after the primary
work surface, supporting context, and action path have fixed positions.
Use `Styling.app_shell` for compact light identity/navigation/utility chrome;
do not reuse `Styling.header` / `gradient_header` as an app shell.

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
- [ ] **Same chrome on every operational app** — navy hero + three white KPI cards + `##` headers on a
      planning grid, an approval queue, *and* an exception command center. That stack is the
      exec-dashboard example later in this file, not a house style. Compose from the type's job in
      `generate-apps.md` Step D.4.
- [ ] **Recognizable skill chrome** — dark slate/navy band, Tailwind `#3B82F6`, a 3-up KPI strip
      (even *inside* the hero), quiet uppercase QUEUE/LOG labels. Moving KPIs into the hero is still
      this file's command-center example, not a custom app. If a screenshot would identify the skill
      before the domain, fail the pass.
- [ ] **Invisible entry controls** — text / text-area / list controls that vanish in the PNG (white
      field on a white band, or Dark theme with no field chrome). If the page takes typed input, the
      export must show where to type. A light canvas + a slightly tinted well behind the control row
      is one verified fix; do not treat that well as a template. Full Dark is not the default for a
      data-entry app unless the user asked for it. See `generate-apps.md` Step D.4.
- [ ] **Status as a 3-KPI strip on an operational app** — three equal tiles for counts that belong in
      the title line or one chip. Recipe 2 is for dashboards where the KPIs *are* the page.
- [ ] **No grid breaks** — the same 2–3-column chart row repeats down the whole page ("spreadsheet of
      cards"). Change the layout when the section's purpose changes: hero row → section header → paired
      charts → full-width detail. See Recipe 3 (section headers) and the composition pattern.
- [ ] **The same thing said or charted twice** — lockup, eyebrow, element title, and card label repeat
      the same words, or two charts encode the same measure at the same grain. Give each text layer one
      job and remove the duplicate chart; a different color or chart kind is not new information.
- [ ] **Wide-table squeeze** — more than roughly ten visible columns force the identifier column to
      truncate. Keep the name/key plus decision-critical fields and move the rest to a selected-record
      detail surface; do not widen the whole page to preserve every field.
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

## Workbook theme (2026-06-18 release; `settings.theme.overrides` schema documented 2026-06-25)

A workbook carries a theme under `document.settings`, alongside `pages` and `layout`:

```yaml
name: My Workbook
document:
  schemaVersion: 1
  pages: [ ... ]
  layout: ...
  settings:
    theme:
      name: Dark           # built-in: Light | Dark | Surface — OR an org theme UUID
      overrides:           # optional — colors / fonts / layout style / table defaults
        colors:
          text: "#FFFFFF"
          highlight: "#1E88E5"
          surface: "#101826"
```

> **The theme moved.** It was once a top-level `themeName` + `themeOverrides` pair; both
> were **removed from the API** and are now `settings.theme.name` and
> `settings.theme.overrides` — inside `document`, alongside `pages`/`layout`. The individual
> override keys below are unchanged; only the container moved. A spec that still writes the
> old pair loses its whole theme **silently** (no error, just an unthemed workbook).

The **full overrides schema is in the public OpenAPI** (`.../spec` POST/PUT request body and GET response). The OpenAPI is the source of truth for every field; the list below is the verified summary.

### `settings.theme.name`

- Accepts a **built-in** name (`Light` / `Dark` / `Surface`) or an **org theme id** (a UUID). All round-trip. Only the **format** is checked, not existence: a malformed value 400s, but a well-formed but nonexistent UUID is accepted as-is and renders broken (like a bad `pluginId`) — so a clean POST is not proof the theme exists.
- **There is no API to discover theme names.** Built-ins are the three above; an org theme id can only be learned by reading a workbook spec that already uses it (admin Branding Settings shows names, not ids). So the theme id has to come from somewhere external — an agent cannot enumerate them from a single call.
- **Use the per-org theme registry instead of asking blind.** `harvest-theme-registry.py` (in `sigma-migration-skills/shared/scripts/`) scans an org's workbook specs once and writes `~/.sigma-migration/theme-registry.yaml`, keyed by API host, with each `settings.theme.name` and how many workbooks use it. Read it to suggest the org's themes ranked by frequency — **the most-used org-UUID is almost always the org default.** If the registry is missing or stale, run the harvester (a full scan is ~20–40s and persists), then fall back to asking the user only if no org themes are found. Singletons are often test/transient junk — prefer the high-count entries.

### `settings.theme.overrides` — one-off tweaks stacked on the base theme

Every field below **round-trips and renders** — verified live 2026-06-26 (POST → GET round-trip with 0 dropped fields, + PNG export showing the override applied; a 14-key override on a `Light` base produced a dark canvas, pill cards, cyan headers, row banding, and a monospace data font).

| Field | Type / values | Notes |
|---|---|---|
| `colors` | `{ text, highlight, surface, success, warning, danger, darkMode }` | hex; `highlight` maps to theme `$primary`. `darkMode: shown\|hidden`. |
| `colorOverrides` | `[{ name, color }]` | per-token layout colors as a **list** (not a map). `name` matches the theme color inspector (`backgroundCanvas`, `elementBackground`, …). Duplicate `name`s are rejected. A map `{ backgroundCanvas: "#hex" }` is a 400 (`Invalid ColorOverrides: object`). |
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
- `settings.theme.overrides` is the spec path to **donut/pie slice colors** — set `categoricalScheme` here (the per-element `color.scheme` is still silently dropped on donut/pie — see Recipe 5). This supersedes the old "set the theme in the UI" workaround.
- `titleFont` sets every element's title **by default**, but a per-element `name:{fontSize,color}` (live-verified 2026-07-28 — see *Things that are NOT designable via spec* below, now corrected) **wins over** `titleFont` for that one element when both are set. Use `titleFont` for a workbook-wide title style and per-element `name` only where one title needs to stand out.
- Theme vs. the recipes below: a theme is the global skin (selected, org-managed). The recipes here style individual elements from spec fields and **stack on top of** whatever theme is set. For a migration, prefer the source dashboard's look; reach for a theme only when the user asks to apply one.

---

## What "designed" looks like via spec

There is no single designed page. A page looks designed when it has a **focal
point**, a **type scale**, and **one accent system** — and when it does not
match the anti-pattern list above.

For an **exec dashboard**, stacking these five patterns is a proven composition
(the original experiment). Use it when the page *is* a dashboard. Do not clone
it onto a planning grid, approval queue, or exception command center:

1. **Branded hero header strip** — full-width container with a dark background and a colored Markdown title sitting inside.
2. **KPI cards** — each KPI inside its own white container with rounded corners + a thin border + a colored Markdown category label.
3. **Section headers** — Markdown `##` text elements between groups of elements.
4. **Categorical chart colors** — `color.scheme` on bar/line/area/combo (not donut/pie — those use the workbook theme).
5. **Number formatting on everything** — `$,.2s` for KPI values (yields `$103k`), `$,.0f` for table cells, never raw numbers.

Other compositions that also read as designed, using recipes later in this file:

- **Command center** — one option, not the exception-app default. KPIs *inside* a dark opening band is a demo idiom (`KPI strip inside a dark hero` below). A triage app should usually open on the queue; putting status in the title line avoids this file's chrome. Reserve red/amber for genuinely critical values.
- **Working grid** — the editable table is the hero (wide `gridColumn`, tall `gridRow`). One impact/variance KPI. Controls first. No decorative chrome competing with the cells.
- **Review queue** — the queue opens the page. Quiet surfaces. The audit log is a trail, not a second dashboard.

Prefer the org's existing `settings.theme` (GET a live workbook, or the theme
registry) over the sample Tailwind palette below. The palette is a fallback
when there is no brand and no org theme. For generate-app workbooks with
entry controls, prefer Light or that org theme — do not default to Dark.

---

## Vetted color palette

Use this Tailwind-derived modern palette unless the customer has specified branding.
**Author against semantic roles** (`Styling::DEFAULT_ROLES` / `Styling.resolve`); emit only
resolved hex or `{kind: theme, ref: …}` in a concrete color field. Theme/chart
helpers may assemble those resolved colors into a supported categorical array.
Never write role names into Sigma color fields.

| Role | Resolves to | Use |
|---|---|---|
| `canvas` | `#FFFFFF` | Page / app-shell surface |
| `ink` | `#0F172A` | Hero band + primary dark |
| `body` | `#1E293B` | Dark slate body / card-gradient start |
| `muted` | `#64748B` | Secondary text + quiet labels |
| `hairline` | `#E2E8F0` | Card / shell borders |
| `fill` | `#FFFFFF` | Card fill |
| `series` | `#2563EB` | Categorical slot 0 / single-series marks |
| `series-mid` | `#0EA5E9` | Categorical slot 1 |
| `series-grey` | `#64748B` | Categorical slot 7 |
| `primary` | `#2563EB` | Accent / KPI title |
| `tint` | `#1E3A8A` | Navy mid-stop (header gradient) |
| `edge` | `#FFFFFF` | On-dark title / high-contrast edge |

Additional verified categorical hues (slots 2–6, no dedicated role): `#14B8A6`, `#F59E0B`, `#8B5CF6`, `#EF4444`, `#10B981`.
On-dark subtitle mute `#94A3B8` remains a one-off recipe hex (not a role).

Apply consistently: `primary` / `series` for the "primary metric" KPI label and primary bar;
growth green / warning amber / negative red from the categorical mid slots only where earned.

---

## Recipe 1 — Hero header strip

A dark, full-width strip at the top. Background = role `ink`; title = role `edge`;
subtitle on dark uses the one-off mute `#94A3B8` (prefer role `muted` on a light `canvas`).

Resolved spec (roles already resolved — safe to POST):

```yaml
elements:
  - id: hero
    kind: container
    style:
      backgroundColor: "#0F172A"   # ink
      borderRadius: round
  - id: title
    kind: text
    body: |
      # <span style="color: #FFFFFF">Orders Overview</span>   <!-- edge -->
      <span style="color: #94A3B8">Net revenue, order mix, and channel performance — last full period</span>
```

```xml
<Container elementId="hero" type="grid"
               gridColumn="1 / 25" gridRow="1 / 5"
               gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <Element elementId="title" gridColumn="1 / 25" gridRow="1 / 5"/>
</Container>
```

Notes:
- Title color via Markdown `<span style="color: #...">` after resolving `edge` (or any role) to hex. For size control beyond `#`/`##`, use Sigma's typography classes (`<p class="h-med">` etc.) and `font-family` spans — see **Field-observed idioms** below.
- For an edge-to-edge image background instead of a solid color, swap `backgroundColor` for `backgroundImage` and add `padding: none` (`backgroundColor` + `padding: none` is also valid — it just blocks `border*`).

---

## Recipe 2 — KPI card row

Three (or four) KPIs in styled white cards. Card surface = roles `fill` + `hairline`;
category label = role `primary` (or another categorical hue for growth / trailing metrics).

Resolved spec:

```yaml
elements:
  - id: kpi-net-box
    kind: container
    style:
      backgroundColor: "#FFFFFF"   # fill
      borderRadius: round
      borderColor: "#E2E8F0"       # hairline
      borderWidth: 1
  - id: kpi-net-label
    kind: text
    body: |
      <span style="color: #2563EB">**NET REVENUE**</span>   <!-- primary -->
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
<Container elementId="kpi-net-box" type="grid"
               gridColumn="1 / 9" gridRow="5 / 12"
               gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
  <Element elementId="kpi-net-label" gridColumn="1 / 25" gridRow="1 / 3"/>
  <Element elementId="kpi-net"       gridColumn="1 / 25" gridRow="3 / 8"/>
</Container>
```

Repeat the container + label + KPI triple for each metric, switching the label color via roles /
categorical mid hues (green for growth, purple for averages, amber for trailing-indicator metrics).
Three across at columns `1/9`, `9/17`, `17/25` is the usual **dashboard** KPI-row split — not a
requirement for operational apps.

> **Set the value column's `name: ' '` (a single space)** when a colored Markdown label sits above the KPI — otherwise you get a **duplicate title**: the card label (`NET REVENUE`) *and* the KPI's own title (`Net Revenue`) stacked in the same card. The title comes from the element `name` **and, when that's absent, the bound value column's `name`** — so with no element name (the usual case here) the *column* name is what leaks through. There's no `showTitle: false` field, and **omitting the name does NOT work** — an empty/absent name is stripped and the title re-derives. Only a single space persists. (Verified live + rendered; this is the #1 KPI-card mistake.)

---

## Recipe 3 — Section header

A heading row between groups of elements. Tighter than a hero, looser than a chart.
Default text color follows the workbook theme; for an explicit quiet label use role `muted`
(`#64748B`) after resolve — never serialize the role name.

```yaml
- id: section-charts
  kind: text
  body: |
    ## Revenue breakdown
```

```xml
<Element elementId="section-charts" gridColumn="1 / 25" gridRow="12 / 14"/>
```

Use these between (a) KPI row and chart row, (b) chart row and detail table, (c) any two thematically distinct chunks. Two per dashboard is usually enough — more than that and the page reads as fragmented.

---

## Recipe 4 — Divider before the detail table

Between the high-level charts and the "drill down to raw rows" table, a horizontal rule sets the visual separation cleanly. The rule inherits theme chrome; if you color a companion rule/label, resolve `hairline` (`#E2E8F0`) or `muted` first.

```yaml
- id: divider-1
  kind: divider
```

```xml
<Element elementId="divider-1" gridColumn="1 / 25" gridRow="26 / 27"/>
```

A 1-row span. The `divider` element is a first-class kind, not a hack — see `content-elements.md`.

---

## Recipe 5 — Categorical chart colors

For bar / line / area / combo charts, pin slice colors via roles (then resolve to hex).
Default single-series mark = role `series` / `primary` (`#2563EB`). Positional schemes start
with `series`, then warning/negative categorical mids:

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
    scheme: ["#2563EB", "#F59E0B", "#EF4444"]   # series + amber + red (resolved)
```

`scheme` is positional — pin colors to category sort order, not to category names. Sort by the value descending to get "biggest bar = `series` blue, smaller = warning amber/red."
For a single-series chart emit `color: { by: single, value: "#2563EB" }` (`Styling.chart_color` / role `series`).

> **Donut and pie do NOT accept `scheme`.** The field is silently stripped on those chart kinds. To customize donut/pie slice colors from spec, set `settings.theme.overrides.categoricalScheme` at the workbook level (see *Workbook theme* above) — that path is now spec-authorable and verified (`Styling.chart_color(theme, categorical: true)`). See `charts.md` donut section for the verified gotchas.

---

## Recipe 6 — Number formatting

Every value gets a `format` block (no color roles here). When a KPI **title** is accented,
merge `Styling.kpi_accent(theme)` / role `primary` (`#2563EB`) into `name.color` — resolved
hex only. The four most useful formats:

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
## Putting it together — example exec-dashboard composition

One 24-column layout that stacks the five dashboard patterns. **Example only** —
for a sales/exec overview. Do not ship this page as the generate-app default.

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

  <Container elementId="hero" type="grid"
                 gridColumn="1 / 25" gridRow="1 / 5"
                 gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="title" gridColumn="1 / 25" gridRow="1 / 5"/>
  </Container>

  <Container elementId="kpi-net-box" type="grid"
                 gridColumn="1 / 9" gridRow="5 / 12"
                 gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
    <Element elementId="kpi-net-label" gridColumn="1 / 25" gridRow="1 / 3"/>
    <Element elementId="kpi-net"       gridColumn="1 / 25" gridRow="3 / 8"/>
  </Container>
  <!-- two more KPI containers at 9/17 and 17/25 -->

  <Element elementId="section-charts"   gridColumn="1 / 25"  gridRow="12 / 14"/>
  <Element elementId="chart-by-channel" gridColumn="1 / 13"  gridRow="14 / 26"/>
  <Element elementId="chart-by-status"  gridColumn="13 / 25" gridRow="14 / 26"/>

  <Element elementId="divider-1"      gridColumn="1 / 25" gridRow="26 / 27"/>
  <Element elementId="section-detail" gridColumn="1 / 25" gridRow="27 / 29"/>
  <Element elementId="master"         gridColumn="1 / 25" gridRow="29 / 37"/>
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
- Text elements take a top-level `verticalAlign: center` ✓ (sibling of `body`, not in `style`).

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
layout: { anchor: center }            # also: verticalAnchor: top|center|bottom, titleOrient: bottom, comparisonValueOrient: right
```

**KPI strip inside a dark hero** ✓ — the strongest "designed" move observed (KPIs live in the
hero band, not below it): one dark container spans the full band; the title text, accent-colored
labels, and the KPIs all lay out inside its `Container`; each KPI pops with
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
- ✓ **The working recipe (re-verified 2026-08-08): `backgroundImage` is a TOP-LEVEL field on the
  container element — a SIBLING of `style`, NOT nested inside `style`.** Nesting it under `style`
  silently drops it (posts `200`, GET readback shows only `backgroundColor`, renders flat) — that was
  a real mistake caught this session. **Breaking change (live, 2026-08-08):** the url itself now
  nests under `source: {kind: url, url: ...}` — the old flat `backgroundImage: {url: ...}` hard-400s
  (`"backgroundImage.source: Invalid value: undefined"`). The correct shape:
  ```yaml
  - id: hero
    kind: container
    style: { backgroundColor: "#0B1120", borderRadius: round }   # solid fallback / load color
    backgroundImage:
      source: { kind: url, url: "https://…/gradient.png" }       # <-- sibling of style, not inside it
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

## Composition styling — the `Styling` module

The recipes above are written to hand-author; the same moves are also available as a small
shared helper library — `scripts/lib/styling.rb` — for applying a professional look on top of
a layout built with the `Composition` engine (`reference/workflows/composition.md`) instead of
re-transcribing hex codes and container shapes into every **dashboard**. `Styling.header`,
`section_card`, and `gradient_header` emit the exec-dashboard composition. On the generate-app
path, do **not** call them as the default look — compose from `generate-apps.md` Step D.4.
Every field these helpers emit is one of the live-verified GO surfaces above; each helper is
gated behind an internal `SURFACES` map so a future regression can flip a surface off in one
place instead of emitting an unverified (or now-rejected) shape at every call site.

### Theme

Semantic roles (`canvas`, `ink`, `body`, `muted`, `hairline`, `fill`, `series`, `series-mid`,
`series-grey`, `primary`, `tint`, `edge`) sit behind the palette. `Styling.resolve(role)` and
`Styling.theme(roles: …)` map them onto the verified hexes above; `DEFAULT_THEME` is **derived**
from `DEFAULT_ROLES` so no-arg `theme`, `chart_color`, and `kpi_accent` stay byte-compatible with
prior output. Pass a partial `roles:` map to retarget surfaces without mutating `DEFAULT_ROLES` /
the caller hash. `accent:` still tints categorical slot 0 + `theme[:accent]`.

Role names are authoring-only—`Styling.resolve` returns hex or
`{kind: theme, ref: …}`; theme/chart helpers assemble custom categorical
arrays from resolved roles. Never serialize a role name as a Sigma color field.

`Styling.theme(accent: nil)` returns that derived `DEFAULT_THEME` — **one** professional,
host-agnostic palette — or a variant with `accent` / `roles` applied. There's no branding/logo
support and no second built-in palette: one palette, optionally re-tinted, matches this doc's
stance in the note at the top — reach for a theme when the user wants design polish with no
stated brand direction; a migration's source fidelity or a user's own branding always overrides
this.

### `chart_color(theme, categorical: false)`

- Single-series (default): `{ "color": { "by": "single", "value": theme[:categorical][0] } }` —
  merge onto a bar/line/area/combo element (Recipe 5's single-hue case).
- Categorical (`categorical: true`): `{ "settings": { "theme": { "overrides": { "categoricalScheme": theme[:categorical] } } } }`
  — **deep-merge** at the workbook level (inside `document`, a sibling of `pages`/`layout`), not per-element.
  Deep-merge, not shallow: a shallow merge of `settings` clobbers `navigation`.
  — merge at the **workbook** level (a sibling of `pages`/`layout`), not per-element. This is the
  verified path for donut/pie slice colors too (per-element `color.scheme` is still silently
  dropped there — see Recipe 5 / *Workbook theme* above).

### `kpi_accent(theme)`

Returns `{ "color": theme[:accent] }` — merge into a KPI element's `name` object
(`{ "name": { "text": "Revenue", "color": "#2563EB" } }`). This is the KPI **title** color,
live-verified 2026-07-28 (see the corrected claim under *Things that are NOT designable* below) —
distinct from `value.color`, which tints the number itself (already documented under
*Field-observed idioms* above); combine both for a fully accented KPI card.

### `format_for(semantic)`

Returns a `format` fragment — `{ "kind": "number", "formatString": <d3> }` — for one of four
semantics: `:currency` → `"$,.0f"`, `:integer` → `",.0f"`, `:percent` → `".1%"`, `:decimal` →
`",.2f"`. These are **d3-format** strings, not Excel-style masks: `"$#,##0"` is hard-rejected at
POST with a 400 (`Invalid number format string`), never silently dropped — never hand-write an
Excel-style format string. See Recipe 6 above and `formatting.md` for the full grammar.

### `header(id:, title:, theme:, page_cols: 24)` / `section_card(id:, band:, theme:, page_cols: 24)`

Apply the Recipe-1 hero-header and Recipe-2-style card idioms on top of `Composition.bands()`
output rather than hand-writing the container + child XML per dashboard:

- `header` emits a `kind: container` styled `theme[:header]`
  (`{backgroundColor:"#0F172A", borderRadius:"round"}`) plus a separate `kind: text` title child —
  a container has no field of its own that renders visible text, see `layout.md`'s Container
  elements section — and the wrapping `<Container>`/`<Element>` XML fragment.
- `section_card` wraps one `Composition.bands()` band (`{role:, ids:, r0:, r1:}`) in a
  `kind: container` styled `theme[:card]`
  (`{backgroundColor:"#FFFFFF", borderColor:"#E2E8F0", borderWidth:1, borderRadius:"round"}`),
  tiling the band's element ids side-by-side inside it at the same relative split
  `Composition.band` would use unwrapped.
- Both container `style` shapes use the field name **`borderRadius`** (`square|round|pill`) —
  never the guessed `cornerRadius`, which is silently dropped on readback (the *container-style*
  row of the GO/NO-GO surface map above). Container `style.padding` accepts
  only `none` or omission; values such as `small` are rejected. Also never
  combine `padding: none` with `borderColor`/`borderWidth` on the same
  container—border fields require default (omitted) padding.

### `gradient_header(id:, title:, subtitle:, gradient:, motif:, motif_side:, logo_url:, page_cols: 24)` — sleek header via a data-URI SVG

A step up from the flat `header` band above: instead of a solid `backgroundColor`,
the container's `backgroundImage` is a composed **inline SVG, base64-encoded as a
`data:image/svg+xml;base64,...` URI** — a `linearGradient` (the `gradient:` stops)
optionally layered with a decorative motif `<g>`. Same `{ element:, layout: }`
return contract as `header`, so it drops into the same composition call sites.

```yaml
- id: hdr-bg
  kind: container
  style: { borderRadius: round }
  backgroundImage:
    source:
      kind: url
      url: "data:image/svg+xml;base64,PHN2ZyB4bWxucz0i..."   # composed gradient(+motif) SVG
    style: { fit: cover }
- id: hdr-title
  kind: text
  verticalAlign: center
  body: '# <span style="color: #FFFFFF">Overview</span>'
```

(Breaking change, live 2026-08-08: the url now nests under `source: {kind: url, url:}` — the
old flat `backgroundImage: {url:}` hard-400s. Same shape applies to `gradient_card` below.)

- `gradient:` is an array of **2–3 hex stops** (default: a neutral, host-agnostic
  3-stop slate→navy→blue ramp in `DEFAULT_THEME[:header_gradient]` — not red; red,
  like `theme(accent:)` elsewhere in this file, is a caller override, never a
  built-in default).
- `motif:` picks a decorative element layered on top of the gradient, positioned by
  `motif_side:` (`:right` default, `:left`, `:center`). It's a **menu, not a fixed
  look** — six geometric, trademark-free options in `Styling::MOTIFS`:

  | Key | Look |
  |---|---|
  | `:glow` (default) | A soft radial highlight — the plainest, least busy option. |
  | `:rings` | Concentric circles + crosshair lines — a "signal/target" mark. |
  | `:grid` | A faint repeating grid pattern. |
  | `:waves` | Three nested arcs — a soft "signal wave" mark. |
  | `:dots` | A repeating dot pattern. |
  | `:none` | No motif — a plain gradient. |

  A **String** value for `motif:` starting with `http` or `data:` is treated as a
  **bring-your-own image** and used verbatim as the background instead of composing
  from the menu — useful for a caller with their own hero graphic. Every menu motif
  is geometric (circles, grids, arcs, dots) — no logos, letterforms, or third-party
  marks.
- `logo_url:` (optional) adds a left-column `image` element inside the same band.
- NO-GO on the `gradient_header` surface falls back to the plain `header` band
  above (graceful — never a broken shape); NO-GO on just `motif` (surface still GO)
  drops to a plain gradient with no decorative `<g>`.

### `gradient_card(id:, kpi_element:, gradient: DEFAULT_THEME[:card_gradient], page_cols: 24)` — gradient KPI card

Decorate-only, like `section_card`: wraps a **caller-built** `kpi-chart` element
(e.g. from `KpiCard.build`) in a gradient `backgroundImage` container. `gradient:`
is **optional** — it defaults to `DEFAULT_THEME[:card_gradient]` (a dark slate
pair, `['#1E293B', '#0F172A']`), so a caller with no brand gradient in mind still
gets a legible dark card; pass a caller-specific 2–3 hex-stop array to override it.

The composed background is **two layers**, not one — the caller's (or default)
gradient rect, THEN a dark **scrim**: a vertical `linearGradient` from black at
~0.55 opacity at the top (where the KPI name+value sit) fading to 0 opacity
toward the bottom (where a `sparkline` sits). This is what makes a white KPI
value legible on **any** gradient, bright or dark — not just a dark one — while
the brand gradient still reads through in the lower half (never fully blacked
out). It never mutates `kpi_element` or `kpi_card.rb` — it returns
`{ element:, child_layout:, patch: }`: the container element to add, the inner
`<Element>` fragment positioning the KPI inside it, and a `patch` Hash
the caller merges onto their own copy of the KPI's `value`/`name`/`style` objects:

```yaml
value: { color: "#FFFFFF" }
name:  { color: "#FFFFFF" }
style: { backgroundColor: transparent, padding: none }
```

so the title and value read white against the gradient. **Merge all three keys
— `value`, `name`, AND `style`** — not just `value`/`name`: the KPI element keeps
its own opaque background otherwise, so a live render shows white-on-white even
with the scrim in place. NO-GO returns the empty
`{ element: [], child_layout: '', patch: {} }` marker — nothing half-decorated.

### `sparkline(id:, source_element_id:, period_ref:, value_formula:, period_format:)` — the composite in-card sparkline (refines the earlier NO-GO)

`reference/workflows/composition.md` documents an **in-kpi date-column sparkline**
as NO-GO: adding a real date dimension to a `kpi-chart`'s own `columns` renders no
line — that finding **still stands**, unchanged.

What **is** live-verified GO is a different shape entirely: a **separate,
borderless `line-chart`** element stacked *below* the KPI inside the same
`gradient_card` (or any card) container — not a field on the KPI element at all.
`Styling.sparkline` builds exactly this:

```yaml
- id: k-rev-spark
  kind: line-chart
  source: { kind: table, elementId: src }
  columns:
    - id: k-rev-spark-period
      formula: '[Src/Period]'
      format: { kind: datetime, formatString: "%b %Y" }
    - id: k-rev-spark-value
      formula: Sum([Src/Revenue])
  xAxis: { columnId: k-rev-spark-period, format: { marks: none, labels: hidden } }
  yAxis:
    columnIds: [k-rev-spark-value]
    format: { labels: hidden, marks: none, scale: { type: linear, zero: false, hideZeroLine: true } }
  name: { visibility: hidden }
  legend: { visibility: hidden }
  lineAreaStyle: { interpolation: monotone }
  style: { backgroundColor: transparent, padding: none }
```

Both axes hide their labels/marks (no chart chrome competing with the KPI above
it); `scale.zero: false` so a small real trend isn't flattened against a forced
zero baseline; `name`/`legend` hidden (no title, no legend on a mini chart);
`backgroundColor: transparent` so it blends into the card around it. Place it in
the same container as a `gradient_card`-wrapped (or plain) KPI, sized as a thin
strip beneath the value.

**So:** "no sparkline field on the KPI element" is still true and always will be
(it's UI-only there) — but "no sparkline in the card" is not. The composite
pattern (KPI + a stacked borderless line-chart, same card) is the GO way to get
one.

## Things that are NOT designable via spec (as of 2026-05-29)

Don't waste a round-trip trying to set these — the spec API silently drops them.

- **Chart tooltip customization** (spec-findings #10)
- **Trellis / small-multiples layout** (spec-findings #11)
- **Donut / pie slice colors** (spec-findings #22, per-element `color.scheme`; use workbook-level `settings.theme.overrides.categoricalScheme` instead — see *Workbook theme* above)
- ~~**KPI title color or "hide title" toggle** — `name` always renders as a black title~~ — **RESOLVED, live-verified 2026-07-28**: `name` on a `kpi-chart` (or any element) *is* colorable — `{ "name": { "text": "Revenue", "color": "#2563EB" } }` survives readback and renders the title in that color. This supersedes the "`name` always renders as a black title" claim this doc carried until now — for *this exact shape only*: there is still no `showTitle: false` / "hide title" toggle, so the `name: ' '` (single-space) workaround in Recipe 2 above still stands for suppressing a duplicate title.
- ~~**Element title font size / font family** — the `name` field has no `style` sibling.~~ — **PARTIALLY RESOLVED, live-verified 2026-07-28**: a per-element `name` object also takes `fontSize` — `{ "name": { "text": "Category Detail", "fontSize": 22, "color": "#DC2626" } }` on a non-KPI element (e.g. a table) survives readback and renders both a visibly larger size and a distinct color, **overriding the workbook-wide `titleFont`** (see *Workbook theme* above) for that one element when both are set. This supersedes the "the `name` field has no `style` sibling" claim this doc carried until now. Font *family* per title remains untested — only `fontSize`/`color` were probed; `settings.theme.overrides.fonts.textFont` (*Workbook theme* above) is still the only verified lever for text font family, and it's global, not per-title.
- ~~**Workbook-level palette / theme** via spec~~ — **RESOLVED**: now spec-authorable via `settings.theme.name` + `settings.theme.overrides` (see *Workbook theme* above).
- **Chart `tooltip` / `trellis*` fields** (UI-only)

If a customer needs slice color branding on donut/pie, set the workbook theme in the UI after the spec is posted.
