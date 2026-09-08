# Content Elements (text, image, divider, embed, form, progress, navigation)

The non-data-bound elements — prose, images, rules, and embedded URLs. None take a `source`. Pull any kind's exact shape from the spec:

```bash
jq --arg k text 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
# swap k for image / divider / embed / form / progress / navigation
```

These are flat `document.elements[]` entries and are assigned by layout.

## text

A Markdown block — titles, descriptions, section headers, callouts. Required `id`, `kind`, `body`; optional `verticalAlign` (`start` / `middle` / `end`) and `overflow` (`clip` / `scroll`). No `name`, no `source`.

```yaml
id: text-header
kind: text
body: |
  # Sales Overview

  A weekly view of revenue, with the regions driving the most growth.
```

(YAML's `|` block scalar keeps the body readable.)

### `body`: Markdown + inline styling

`body` is Markdown plus a small set of inline HTML for styling. Standard Markdown: paragraphs, `**bold**`, `*italic*`, headings (`#`, `##`, `###`), bullet / ordered lists, `[links](https://example.com)`, and `{{formula}}` / `{{ast | fmt}}` segments (same syntax as element titles, e.g. `{{Count() | ,.0f}}`).

A control value uses its `controlId`: `{{[RegionFilter]}}`. The element `id`
is not the formula handle. Dynamic-text references can serialize without
resolving, so GET the spec back and render the element; readback normalization
and visible output are the binding checks.

Inline styling via HTML — all round-trip through the spec and render:

- **Color / background:** `<span style="color: #8B0000">` and/or `background-color` — **hex values** (`#rgb` / `#rrggbb`).
- **Font size:** `<span style="font-size: 24px">`.
- **Font family:** `<span style="font-family: Georgia">` — a single family name that starts with a letter and contains only letters, numbers, spaces, underscores, or dashes. **No comma-separated fallback lists** — `"Georgia, serif"` is rejected.
- **Paragraph block styles:** `<p class="p-large">…</p>` and `<p class="p-small">…</p>`.
- **Alignment:** `<p style="text-align: center">…</p>` (also `left` / `right`).

A single `<span>` can combine properties (e.g. color + font-size). If a value violates its rule, the API rejects the whole `body` with a specific message naming the field — read it and fix the value.

Common pattern — bold + color (both supported):

```markdown
# **<span style="color: #8B0000">Deployments Dashboard</span>**
```

## image

Embeds an external image by URL (hosted only — no uploads). Required `id`, `kind`, `url`; `url` supports `{{formula}}` references for dynamic selection. `alt`, `link`, and a `style` block exist too — pull the shape from the recipe. Sizing comes from the layout grid, not the element.

```yaml
id: logo
kind: image
url: https://cdn.example.com/logo.png
```

## divider

A rule for separating sections. Required `id`, `kind`; optional `direction` (`horizontal` / `vertical`), `align`, and `style` (`color` / `width` / `strokeStyle`).

```yaml
id: section-rule
kind: divider
```

## page-break

Forces a page break for PDF export / print pagination. The **entire** element is `id` + `kind` — it takes no other fields at all (confirmed via `capabilities --kind page-break`), and nothing renders on screen beyond a thin spacer band.

```yaml
id: pb-before-detail
kind: page-break
```

**Live-verified 2026-08-05** (create + readback round-trip; present and intact in the GET-back).

> **Height is fixed at 1 grid row.** A multi-row `gridRow` in the layout XML is rejected: `page-break 'pb' must span exactly one grid row (got height 2). Page breaks are fixed at height 1; set gridRow to a one-row span (e.g. "1 / 2")`. So `<Element elementId="pb" gridColumn="1 / 25" gridRow="24 / 25"/>` — always a one-row span.

## embed

Renders an external URL inline — a hosted report, form, video, etc. Required `id`, `kind`, `url`; `url` supports `{{formula}}` references.

```yaml
id: embed-report
kind: embed
url: https://example.com/report
```

## form

An input form. Required `id`, `kind`, `fields` (array); optional `style`. Each field requires `type` (`text` / `text-area` / `number` / `date` / `checkbox`); optional `label`, `placeholder`, `required` (`required` / `optional`, default `optional` — a **string enum, not a boolean**), and `readOnly` (`readonly` / `editable`, default `editable`).

```yaml
id: intake-form
kind: form
fields:
  - type: text
    label: Name
    required: required
  - type: number
    label: Quantity
  - type: date
    label: Start date
  - type: checkbox
    label: Subscribe
```

Verified live: `form` elements can be gated behind a per-workspace feature flag — a correctly-shaped spec can still fail `/v2/workbooks/spec/verify` with `` `form` elements are not enabled for this workspace``. That's an entitlement error, not a shape error; the field shape above round-tripped past validation to reach that gate. **Unlike `progress`/`navigation` below, this means `form`'s actual create/render/behavior is unverified in the available test org/workspace** — the entitlement gate blocks even a real `POST /v2/workbooks/spec` create, so there's no readback or screenshot to check against. Re-run this verification (real create, not just `/verify`) if a workspace with `form` enabled becomes available.

## progress

A native progress-bar/gauge element — a single value rendered against a min/max range. Required `id`, `kind`; optional `min`, `max`, `value` (each a **formula string**, e.g. `"Sum([Sales])"` or a literal like `"72"` — not a raw number), `mode` (`percent` / `value`, default `percent`), `shape` (`bar` / `ring`, default `bar`), and a plugin-style `config` object (fill/track color, size, alignment, label/value/description text styling, conditional `colorRules`).

```yaml
id: capacity-gauge
kind: progress
mode: value
min: "0"
max: "100"
value: "72"
shape: ring
```

**Live-verified 2026-08-03** (real `POST /v2/workbooks/spec` create + `GET` readback + PNG export screenshot — not just `/verify`): `min`/`max`/`value`/`mode`/`shape` all round-tripped verbatim as strings. Visually, `bar` draws a horizontal fill bar and `ring` a circular gauge with a text label centered inside — both match what the field names imply.

**`mode` gotcha, confirmed by screenshot pixel-measurement — `/v2/workbooks/spec/verify` cannot catch this, it's a rendering behavior, not a schema error:** the fill and the on-element label are computed from `value`/`min`/`max` *differently* depending on `mode`:
- `mode: value` — the label shows the raw `value` string; the fill fraction is `(value − min) / (max − min)`. Confirmed exactly: `min:"0", max:"10", value:"5"` measured (via pixel sampling of the rendered ring) as precisely a 50%-filled ring labeled "5"; `value:"10"` measured as a fully-filled ring labeled "10". This is the intuitive "N out of a range" gauge — use it for anything like "72 out of 100" (the example above).
- `mode: percent` (the **default**) — the fill fraction is *still* `(value − min) / (max − min)` (min/max default to `0`/`1` if omitted), **but the label is always `value × 100` formatted with a `%` suffix, unconditionally, ignoring `min`/`max` entirely.** Measured proof: `min:"0", max:"72", value:"72"` (fill should be 100% either way) rendered a fully-filled bar labeled **"7200%"**, not "100%" or "72%". A bare `value:"0.72"` with no `min`/`max` rendered a 72%-filled bar labeled correctly as **"72%"**. So for `mode: percent`, `value` must already be the 0–1 fraction you want displayed — passing a 0–100-scaled number (the intuitive reading of "percent") silently produces a nonsense label while the fill still looks fine, which is easy to ship unnoticed:

```yaml
# Correct mode:percent recipe — value is a 0-1 fraction, min/max omitted (default 0/1):
id: capacity-gauge-percent
kind: progress
mode: percent
shape: ring
value: "0.72"    # renders a 72%-filled ring labeled "72%"
```

Overlaps the `gauge` plugin's territory (`plugins/sigma-authoring/skills/sigma-plugin-authoring/plugins/gauge/README.md`) — that plugin exists to draw a radial semicircle sweep with red/amber/green banding by closeness-to-target, which native `progress` (even `shape: ring`) doesn't reproduce. For a plain value- or percent-of-range indicator, reach for `progress` first; keep the plugin for the semicircle RAG-gauge look specifically.

## navigation

An in-canvas page-navigation element — two variants sharing `kind: navigation`, discriminated by `mode`. Required on both: `id`, `kind`, `mode`. Optional on both: `style`, `optionStyle` (style/orientation/alignment/size/colors of the option buttons).

**Manual** (`mode: manual`) additionally requires `options` — an array of menu items (`label`, `icon`, `destination`) or one-level submenus; `destination` is one of `{type: page, pageId}`, `{type: element, elementId}`, `{type: link, url, openTarget}` (`openTarget` defaults to `"_blank"` if omitted — confirmed by readback, not stated in the request), or `{type: none}`. Optional `showIcons`.

```yaml
id: page-nav
kind: navigation
mode: manual
options:
  - label: Overview
    destination: { type: page, pageId: page-1 }
  - label: Docs
    destination: { type: link, url: https://example.com }
```

**Auto** (`mode: auto`) has no other required fields; optional `pageLabels` — a **list** of `{ pageId, label }` overrides (not a map keyed by page id). Duplicate `pageId`s are rejected.

```yaml
id: page-nav-auto
kind: navigation
mode: auto
pageLabels:
  - pageId: page-1
    label: Overview
  - pageId: page-2
    label: Details
```

**Live-verified 2026-08-03** (real create + readback + screenshot): both variants round-tripped verbatim. Visually, `navigation` renders as a horizontal **tab bar** (underlined label per option, not a sidebar or breadcrumb — expect tabs if you pictured otherwise from the name). `manual` mode showed exactly the `options[].label` strings as tabs, in the given order. `auto` mode showed one tab per workbook page, using `pageLabels` to override the tab text where provided — and, confirmed by adding two more pages after the fact and re-screenshotting, a page with **no** `pageLabels` entry falls back to that page's own `name` as its tab text, and once there are more pages than fit the element's width, the overflow collapses into a trailing **"More ▾"** dropdown rather than wrapping or truncating.

**Caveat:** none of the above can confirm actual click-through — whether a `destination` really navigates (manual) or clicking an auto-generated tab really switches the active page — since that requires driving a live browser session, not just the REST API/screenshot. The structural and label rendering is confirmed; click behavior is not.

## plugin (2026-06-18 release)

Embeds a **custom Sigma plugin** as a page element. Required `id`, `kind`, `pluginId`; optional `displayName`, `style`, and a plugin-defined `config`.

```yaml
id: my-histogram
kind: plugin
pluginId: 6cdf51c1-dda0-4f99-aa08-5c72804020bb   # the plugin's registered UUID
displayName: Histogram                            # optional label
style: { backgroundColor: "#101826" }             # optional element background (see notes)
config:                                            # plugin-defined bindings + settings
  source: { kind: element, elementId: master }     # bind an element as the data source
  valueColumn: { kind: column, columnId: m-netprof, source: source }
  chartType: Frequency
  binMethod: "Auto (Sturges)"
  binCount: "10"
```

- **Data bindings** inside `config`: `{ kind: element, elementId }` selects a source element; `{ kind: column, columnId, source }` selects one of its columns (`{ kind: column, columnIds: [...], source }` for several); `source: source` points at the `config.source` element. A plugin can also read a control's value — bind the control the same way the plugin's input expects.
- **`config` is half-opaque** — bare **literals** (strings/booleans/string-arrays) pass through unvalidated and are handed to the plugin at render time (a literal round-tripping does **not** mean Sigma supports it). But **`kind`-tagged references are resolved and validated**: a `{kind: element, ...}` / `{kind: column, ...}` / `{kind: control, ...}` pointing at something that doesn't exist is a hard 400 (`Dependency not found`). The literal keys are per-plugin — harvest them from a working spec.
- **Element background:** use element-level `style.backgroundColor` (same shape as a container `style`) — a plugin renders on its own white canvas otherwise, which looks wrong inside a dark theme. A bare top-level `background` key is stripped.
- **Discover available plugins with `GET /v2/plugins`** ("List custom plugins", paginated `pageSize`/`pageToken`; needs `Accept: application/json`). Each entry is `{ pluginId, name, description, url, devUrl, type }` — list them to pick the right `pluginId` instead of guessing. A **bogus `pluginId` is not validated at POST** (200, then renders as a broken "missing plugin"), so always source it from `/v2/plugins`. The endpoint returns id + name only — the per-plugin **`config` shape** still has to come from a workbook spec that uses the plugin (or the plugin's source). See `twells89/sigma-workbook-spec-findings` finding #27 + Plugin-ID catalog.
