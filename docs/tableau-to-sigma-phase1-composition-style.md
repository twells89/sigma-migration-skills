# Design Doc — Tableau→Sigma Skill, Phase 1: The Composition/Style Layer

**Status:** Proposed · **Date:** 2026-07-01 · **Owner:** tableau-to-sigma (parser + builder)
**Root-cause reference:** `TABLEAU_TO_SIGMA_SKILL_GAPS.md` → *"the skill has a data-correctness layer but no composition/style layer."*
**Benchmark:** hand-built Sigma replica of *"Estimated U.S. Job Loss from Mass Deportations"* — https://app.sigmacomputing.com/dataflow/workbook/5RkbujfxygREnBLCd8d89C

---

## 1. Goal & Scope

The skill already produces **correct data** (right numbers, right chart kind, parity gate at Phase 6). It produces **generic composition**: a flat band of charts with a dark header, Sigma-default palette, `segmented`-everything controls, and no container tints. Every one of the ~30 design attributes that make the benchmark look designed is (a) already in the `.twb` and (b) expressible via the verified Sigma spec fields in `styling.md` — the skill neither **extracts** nor **emits** them.

Phase 1 turns the root cause into a **two-part build**:

- **Part 1 (parser):** `parse-twb-layout.rb` learns to extract **style** (fill colors, canvas color, text formatting, color palette, control display type, KPI-with-caption composites) alongside the structure it already emits (zone `x/y/w/h`, `chart_kind`, shelves, filters).
- **Part 2 (builder):** `build-charts-from-signals.rb` gains a **composition emitter** that turns those signals into the verified Sigma spec fields (`container.style.backgroundColor` + `borderRadius`, `themeOverrides.categoricalScheme`, `kpi-chart value.fontSize` + transparent `style`, `controlType: list` vs `segmented`, `color.scheme`, styled `text` spans).

### In scope (Phase 1)

| Gap | Short name |
|---|---|
| **B2** | Container background tints + colored header bars |
| **B3** | KPI-card composites (label + big value + side annotation) |
| **B4** | Rich styled static text (subtitle, annotations, pills, credit) |
| **B5** | Section headers between element groups |
| **C2** | Threshold / second-layer highlight fallback (>100K → computed-boolean + 2-color scheme) |
| **C5** | Auto-enable `dataLabel` when the source shows mark values *(already implemented — lines 3373–3380)* |
| **D1** | Custom categorical palette (region teal/pink/purple/orange) |
| **D2** | Consistent per-category color across all charts (pin category order) |
| **E1** | Dropdown (`list`) vs segmented control style |
| **Pass-7** | Grey canvas (`colorOverrides.backgroundCanvas`), transparent chart `style` over tints, decorative dots/legend-bars, side-annotation layout, compact label format |

### Out of scope (later phases — named here as dependents/followers)

- **B1 — repeated per-category container cards (card-trellis).** The 4 region columns as a *repeated* composite. Phase 1 builds the **styling primitives** each region card needs (tint, header bar, KPI composite, color scheme); B1 is the *repetition engine* that stamps them per region. B1 depends on Phase 1 shipping first.
- **C1 (strip/jitter plots), C3 (lollipop), C4 (normalized single-row proportion bar).** Chart-mark fidelity; independent of the style layer.
- **E2 (parameter-driven measure switch `Switch()`), E3 (set/filter actions).** Interactivity wiring; E1 (this phase) emits the *control widget* with the right display type, E2 wires the *behavior*.
- **A2 (embedded excel-extract land path), A3 (missing `.hyper`).** Discovery/transport.
- **Phase-5 visual-diff-and-refine loop.** The automated render-diff that self-corrects residuals. Phase 1 makes the residuals small; the loop makes one-shot parity a guarantee (see §6).

---

## 2. Current architecture (grounded in the code)

**Parser — `parse-twb-layout.rb` (1189 lines).** Emits per-dashboard `zones[]` (`build_zone_tree`, L805; flat loop L836-901) with `x_pct/y_pct/w_pct/h_pct`, `kind` (via `zone_kind`, L781), `chart_kind` (via `chart_kind_for`, L731), plus per-worksheet signals: `sort`, `filters`, `aggregations`, `channels` (L492-500 — **already reads `<encoding class='color'>` into `channels['color']`, but only the bound column, not the palette**), `formats`, `calculations`, `dual_axis`, `measures`, `ref_marks`, `axis_formats`, `mark_labels_show`, `rows_shelf`/`cols_shelf`, `is_crosstab`, `is_kpi`. A sister `-meta.json` carries `worksheets`, `shared_filters`, `parameters` (L1022-1056), `column_aliases`, `columns_by_guid`. **It reads geometry and semantics — it never reads a single fill color, canvas color, font color, or control display type.**

**Builder — `build-charts-from-signals.rb` (3837 lines).** Main loop L1778 iterates `layout → dash['zones']`, routes each chart zone to `build_pivot_element` / `build_kpi_element` (L1625) / the general chart path, appends to `elements`. Extras: a **title text element** (L3044-3067) and **controls**: param controls (L3172, `controlType` hardcoded `segmented` at **L3206**) and shared-view filter controls (L3266, `list`/`date-range`/`range-slider`). `dataLabel` already wired (L3373-3380). Output (L3460): flat array, `--page-per-worksheet`, or `--page-per-dashboard`.

**Layout — `build-dashboard-layout.rb` + `lib/layout.rb`.** A *separate* stage (run after the chart specs) that assigns `<GridContainer>`/`<LayoutElement>` positions. `lib/layout.rb` is the **only** place that emits `style` today: `HEADER_STYLE = {backgroundColor:"#0F172A", borderRadius:"round"}` (L12) applied via `container_el(id, style)` (L55). Band containers (`band_container_xml`, `container_el(cid)` with **no style**) are plain. This is the natural home for **container tints** and **canvas theme**.

**Key architectural fact for Phase 1:** style is split across two stages. **Element-level style** (KPI `value.fontSize`, chart `color.scheme`, text spans, `dataLabel`) belongs in **`build-charts-from-signals.rb`** because it lives on the element spec. **Container/band-level style** (tint `backgroundColor`, header bar, canvas `themeOverrides`) belongs in the **layout stage (`lib/layout.rb` / `build-dashboard-layout.rb`)** because that's where containers are born. The composition emitter therefore has **two touch-points**, both fed by new parser sidecar fields.

---

## 3. Part 1 — Parser style extraction

New fields added to the sidecar. All are **additive** — every existing consumer is untouched. Sources cited to the `.twb` XML shapes the parser already walks.

### 3.1 Per-zone / per-container fill (B2, Pass-7 canvas)

Tableau dashboard zones and worksheet panes carry fill formatting as `<style><style-rule element='...'><format attr='...' value='#hex'/>`. New fields on each **zone** node (and `zone_tree` container node, `build_zone_tree` L805):

| New field | Source in `.twb` | Notes |
|---|---|---|
| `fill_color` | Zone's `<style-rule element='dash-zone'…><format attr='background-color' value='#...'/>` (or `element='pane'` for worksheet fills) | 6-digit hex; the region-column tint |
| `title_fill_color` | Zone-title `<style-rule element='caption'><format attr='background-color'>` | the colored **header bar** band (South = teal) |
| `title_text_color` | `<style-rule element='caption'><format attr='color'>` | the "South"/"West" header text hue |
| `border_color` / `border_radius` | zone `<format attr='border-color'>`; rounding not in Tableau → default `round` | radius comes from a heuristic, not the .twb |

New **dashboard-level** field:

| `canvas_color` | Dashboard `<style><style-rule element='dashboard'><format attr='background-color'>` | the grey page canvas → `themeOverrides.colorOverrides.backgroundCanvas` |

### 3.2 Discrete color palette (D1, D2)

The parser already captures `channels['color']` (L492-500) but only the bound **column**. Extend the color-channel read to also capture the **discrete member→color map** from the encoding's color rule:

```
<encoding class='color' column='[…Region…]'>
  <map to='#8dd3c7'><bucket>&quot;South&quot;</bucket></map>
  <map to='#fb6a94'><bucket>&quot;West&quot;</bucket></map>
  <map to='#8f80c9'><bucket>&quot;Northeast&quot;</bucket></map>
  <map to='#f4a24e'><bucket>&quot;Midwest&quot;</bucket></map>
</encoding>
```

New field on `channels['color']`:

| `palette` | `<encoding class='color'>/<map to='#hex'><bucket>member` (member unquoted via existing `unquote_member`, L115) | `[{member:"South", color:"#8dd3c7"}, …]` — a **named** map, so the builder can pin color to category *by name* (D2) and derive a *positional* scheme in a fixed category order |

For an explicit **automatic palette** (`<encoding class='color' palette='…'>` with no per-member map), capture `palette_name` so the builder can pass a Sigma named scheme instead of a hex array.

### 3.3 Text-zone formatting (B4, B5)

Text/title/caption zones (`kind` in `text`/`title`) carry run-level formatting. Parser today emits only `caption`. Add a structured `text_runs` from the zone's `<formatted-text><run …>`:

| `text_runs` | `<formatted-text><run fontcolor='#...' fontsize='N' bold='true'>text</run>` under the text zone | array of `{text, color, font_size, bold, italic}` → becomes `<span style>` + `**bold**` |
| `text_align` | `<run>`/`<paragraph>` `alignment` attr | `left`/`center` → `<p style="text-align:…">` (heed styling.md: left is default) |
| `is_pill` | heuristic: single-run zone with a `background-color` fill + short text ("Learn More") | flags the button/pill chips (B4) |

### 3.4 Control display type (E1)

Tableau parameter/filter zones (`type-v2='paramctrl'`, `zone_kind` L788) carry a **display mode** on the zone: `<zone … param-mode='radio' | 'compact' | 'slider' | 'type-in-slider'>` (the "Show As" quick-filter mode). Add to filter/parameter zones (both flat loop L861 and `build_zone_tree` L823):

| `control_display` | zone `param-mode` / `mode` attr | `radio`/`button` → Sigma `segmented`; `compact`/`dropdown` → Sigma `list`; `slider` → `range-slider` |

This is the missing signal that fixes E1 (builder currently hardcodes `segmented` at L3206). In the benchmark: Immigrant|U.S.-born and Rank are `radio` → `segmented`; Job Loss Metric / Labels / Median are `compact` → `list`.

### 3.5 KPI-with-caption composite (B3)

No new .twb parse needed — the composite is **derived** from signals the parser already emits. Add a per-zone boolean the builder keys on:

| `kpi_composite` | true when a `chart_kind=kpi` zone (`is_kpi`, L606) is a **child** of a container zone that also holds a text/caption sibling ("Total Job Losses" label) and an annotation ("40% of U.S. total") | tells the builder to emit the label-text + big-value + side-annotation triple rather than a bare `kpi-chart` |

### 3.6 Enriched sidecar — ONE region container (South), for this benchmark

```json
{
  "id": "region-south",
  "kind": "container",
  "caption": "South",
  "x_pct": 24.5, "y_pct": 15.0, "w_pct": 18.0, "h_pct": 82.0,
  "direction": "vert",
  "fill_color": "#e6f6f3",
  "title_fill_color": "#8dd3c7",
  "title_text_color": "#1f8a70",
  "border_color": "#8dd3c7",
  "border_radius": "round",
  "children": [
    {
      "id": "z-south-kpi", "kind": "chart", "chart_kind": "kpi",
      "caption": "South Total Job Losses",
      "is_kpi": true, "kpi_composite": true,
      "measures": [{ "column": "[federated.x].[sum:JOB_LOSSES:qk]", "derivation": "Sum" }],
      "formats": { "[federated.x].[sum:JOB_LOSSES:qk]": "$,.2s" },
      "text_runs": [{ "text": "Total Job Losses", "color": "#334155", "font_size": 13, "bold": false }],
      "annotation_runs": [{ "text": "40% of U.S. total", "color": "#1f8a70", "font_size": 12, "bold": true }]
    },
    {
      "id": "z-south-impacted", "kind": "chart", "chart_kind": "bar",
      "caption": "The Most Impacted States",
      "mark_labels_show": true,
      "sort": { "direction": "descending", "column": "[…:JOB_LOSSES:qk]" },
      "channels": {
        "color": {
          "column": "[…Region…]",
          "palette": [
            { "member": "South", "color": "#8dd3c7" },
            { "member": "West", "color": "#fb6a94" },
            { "member": "Northeast", "color": "#8f80c9" },
            { "member": "Midwest", "color": "#f4a24e" }
          ]
        }
      }
    },
    {
      "id": "z-south-strip", "kind": "chart", "chart_kind": "scatter",
      "caption": "Total Job Losses by State",
      "channels": {
        "color": {
          "column": "[Above 100K]",
          "palette": [
            { "member": "false", "color": "#8dd3c7" },
            { "member": "true",  "color": "#f4c430" }
          ]
        }
      }
    }
  ]
}
```

And at the dashboard root: `"canvas_color": "#f4f5f7"`.

---

## 4. Part 2 — Builder composition emitter

### 4.1 New emit stage

Add a stage that runs **after** `elements`/`data_elements`/controls are assembled and **before** the output-mode branch (L3460). Two products, matching the two-stage style split (§2):

1. **Element-level style** — mutate the already-built element specs in place (KPI, chart, text) with `value.fontSize`, `color.scheme`, `dataLabel`, styled `body`.
2. **Composition sidecar** — a new `composition.json` (a sibling of the existing `<out>-data-elements.json` and `control-scope.json` sidecars) carrying **container styles + workbook `themeOverrides`** keyed by container id / dashboard, which the layout stage (`build-dashboard-layout.rb`) reads and applies via `container_el(id, style)` (`lib/layout.rb` L55) and a new top-level `themeOverrides` on the assembled workbook.

Concretely, add a function `emit_composition(layout, elements, data_elements, controls, meta)` in `build-charts-from-signals.rb` and a `--composition-out PATH` option (mirror of `--coverage-out`). `build-dashboard-layout.rb` gets a `--composition PATH` option; where it does `container_el(cid)` for a band with no style (bands loop ~L374 and `emit_node` L182-203), it looks up the zone's style from the sidecar and passes it through.

### 4.2 Gap → exact Sigma spec output

| Gap | Parser field consumed | Sigma spec output (field + example, per `styling.md`) |
|---|---|---|
| **B2** tint | zone `fill_color` | container `style.backgroundColor: "#e6f6f3"`, `style.borderRadius: "round"`, `style.borderColor: "#8dd3c7"`, `style.borderWidth: 1` |
| **B2** header bar | zone `title_fill_color` + `title_text_color` | a child **container** `style.backgroundColor:"#8dd3c7"` wrapping a `text` element `body: "### <span style=\"color:#1f8a70\">**South**</span>"` |
| **B3** KPI composite | `kpi_composite`, `text_runs`, `annotation_runs` | container + label `text` + `kpi-chart` with `name: ' '` (single space — the duplicate-title fix, styling.md Recipe 2), `value: {columnId, fontSize: 32}`, `style: {backgroundColor: "#00000000", padding: none}` (transparent hero, Pass-7), + a side `text` annotation |
| **B4** styled text | `text_runs`, `text_align`, `is_pill` | `text` element `body` with `<span style="color:#…;font-size:13px">`, `**bold**` lead words; pill → `<span style="background-color:#fde68a">**Learn More**</span>` in a `borderRadius: pill` container |
| **B5** section headers | child text zone captions ("The Most Impacted States") | `text` element `body: "### The Most Impacted States"` (styling.md Recipe 3) |
| **C2** threshold highlight | `channels.color.palette` with 2 members (bool) + a `> N` calc | a **computed boolean column** `formula: "[Master/Total Job Losses] > 100000"` + chart `color: {by: category, column: <bool>, scheme: ["#8dd3c7", "#f4c430"]}`; WARN "halo approximated as 2-color threshold" |
| **C5** data labels | `mark_labels_show: true` | chart `dataLabel: { labels: "shown" }` — **already implemented** (L3373-3380); no work needed |
| **D1** palette | `channels.color.palette` (named) | workbook-level `themeOverrides.categoricalScheme: ["#8dd3c7","#fb6a94","#8f80c9","#f4a24e"]` (fixed category order) **and** per-chart `color: {by: category, column: …, scheme: […same order]}` |
| **D2** consistent color | `palette` member→color map + pinned category order | build a single **category→color dict**; sort every chart's category axis to the same fixed order so `scheme` is positional-consistent dashboard-wide |
| **E1** control style | zone `control_display` | control `controlType: "list"` (dropdown) vs `"segmented"` — **replaces the hardcoded `segmented` at L3206** with `control_display == 'compact' ? 'list' : 'segmented'` |
| **Pass-7** canvas | dashboard `canvas_color` | workbook `themeOverrides.colorOverrides: { backgroundCanvas: "#f4f5f7" }` |
| **Pass-7** transparent chart | (default when chart sits inside a tinted container) | chart `style: { backgroundColor: "#00000000" }` so the tint shows through instead of a white card over the tint |

### 4.3 Worked example — the "South" region container emitted spec

Tied to the benchmark: teal-tinted column, teal header bar with "South", the `2.4M` / `40% of U.S. total` KPI composite, the proportion split bar, the up/down state pill row, "The Most Impacted States" labeled bar, and "Total Job Losses by State" strip.

**Element specs (from `build-charts-from-signals.rb`):**

```json
[
  { "id": "south-header-text", "kind": "text",
    "body": "### <span style=\"color: #1f8a70\">**● South**</span>" },

  { "id": "south-kpi-label", "kind": "text",
    "body": "<span style=\"color: #334155\">Total Job Losses</span>" },

  { "id": "el-kpi-south", "kind": "kpi-chart",
    "name": " ",
    "source": { "kind": "table", "elementId": "master" },
    "columns": [
      { "id": "k-south", "name": "Total Job Losses",
        "formula": "Sum([Master/Job Losses])",
        "format": { "kind": "number", "formatString": "$,.2s" } }
    ],
    "value": { "columnId": "k-south", "fontSize": 32 },
    "style": { "backgroundColor": "#00000000", "padding": "none" } },

  { "id": "south-kpi-annotation", "kind": "text",
    "body": "<span style=\"color: #1f8a70\">**40%** <span style=\"color:#64748b\">of U.S. total</span></span>" },

  { "id": "south-impacted", "kind": "bar-chart",
    "name": " ",
    "source": { "kind": "table", "elementId": "master" },
    "columns": [
      { "id": "x-south-impacted", "formula": "[Master/State]" },
      { "id": "y-south-impacted", "formula": "Sum([Master/Job Losses])",
        "format": { "kind": "number", "formatString": ",.2s" } }
    ],
    "xAxis": { "columnId": "x-south-impacted", "sort": { "by": "y-south-impacted", "direction": "descending" } },
    "yAxis": { "columnIds": ["y-south-impacted"] },
    "color": { "by": "single", "value": "#8dd3c7" },
    "dataLabel": { "labels": "shown" },
    "style": { "backgroundColor": "#00000000" } },

  { "id": "south-strip", "kind": "scatter-chart",
    "name": " ",
    "source": { "kind": "table", "elementId": "master" },
    "columns": [
      { "id": "sx-south", "formula": "[Master/Total Job Loss %]" },
      { "id": "sy-south", "formula": "Sum([Master/Job Losses])" },
      { "id": "sc-south", "name": "Above 100K", "formula": "[Master/Job Losses] > 100000" }
    ],
    "xAxis": { "columnId": "sx-south" },
    "yAxis": { "columnIds": ["sy-south"] },
    "color": { "by": "category", "column": "sc-south", "scheme": ["#8dd3c7", "#f4c430"] },
    "style": { "backgroundColor": "#00000000" } }
]
```

**Composition sidecar (consumed by the layout stage):**

```json
{
  "workbook": {
    "themeOverrides": {
      "categoricalScheme": ["#8dd3c7", "#fb6a94", "#8f80c9", "#f4a24e"],
      "colorOverrides": { "backgroundCanvas": "#f4f5f7" }
    }
  },
  "containers": {
    "region-south": {
      "style": { "backgroundColor": "#e6f6f3", "borderRadius": "round",
                 "borderColor": "#8dd3c7", "borderWidth": 1 },
      "children_order": ["south-header-bar", "south-kpi-composite", "south-impacted", "south-strip"]
    },
    "south-header-bar": {
      "style": { "backgroundColor": "#8dd3c7", "borderRadius": "round" },
      "wraps": "south-header-text"
    }
  }
}
```

The layout stage places `region-south` as a `<GridContainer>` (via existing `gc`/`container_el`), applies its `style`, nests `south-header-bar` (teal) at the top, then the KPI composite, the bar, and the strip — reproducing the teal column. The single teal `color.scheme[0]` on the South bar and the `#00000000` chart backgrounds are what make Pass-4 (header bars, labels) and Pass-7 (transparent-over-tint) unnecessary as manual passes.

> **Note on B1:** the above is *one* region emitted explicitly. Phase 1 ships the primitives; the B1 card-trellis (later) is the loop that stamps this same triple for West/Northeast/Midwest with each region's palette entry and an element-level `[Region] = "West"` filter.

---

## 5. Data flow

| Parser sidecar field (new) | .twb source | Builder / layout consumer | Sigma spec output |
|---|---|---|---|
| zone `fill_color` | `<style-rule element='dash-zone'><format attr='background-color'>` | `emit_composition` → composition.json → `container_el(id, style)` (lib/layout.rb L55) | `container.style.backgroundColor` |
| zone `title_fill_color` / `title_text_color` | `<style-rule element='caption'>` fills | header-bar sub-container + text | child container `style.backgroundColor` + `text` `<span style="color:…">` |
| dashboard `canvas_color` | `<style-rule element='dashboard'><format attr='background-color'>` | `emit_composition` → workbook themeOverrides | `themeOverrides.colorOverrides.backgroundCanvas` |
| `channels.color.palette` (named) | `<encoding class='color'>/<map to>` | palette→scheme in chart path + workbook theme | `themeOverrides.categoricalScheme` + per-chart `color.scheme` |
| `text_runs` / `text_align` / `is_pill` | `<formatted-text><run>` | text-element `body` builder | `text.body` with `<span style>`, `**bold**`, pill container |
| `control_display` | zone `param-mode` | param-control emitter (replaces L3206) | `controlType: list` vs `segmented` |
| `kpi_composite` / `annotation_runs` | derived (is_kpi child of captioned container) | `build_kpi_element` (L1625) extension | container + label text + `kpi-chart {name:' ', value.fontSize, style transparent}` + annotation text |
| `mark_labels_show` (existing) | `<format attr='mark-labels-show'>` | chart path (L3373) | `dataLabel.labels: shown` |
| `channels.color.palette` (2-member bool) | color rule on a `>N` calc | threshold-fallback in chart path | computed bool column + `color.scheme:[base, highlight]` |

---

## 6. Testing / gate

1. **Unit — parser:** fixture `.twb` (the benchmark workbook) → assert the new sidecar fields are populated: `fill_color` for the 4 region zones, `canvas_color`, `channels.color.palette` with the 4 named region colors, `control_display: compact` for Job Loss Metric and `radio` for Immigrant|U.S.-born. Add alongside the parser's existing spec fixtures (`test-container-layout.rb` / `test-layout-lint.rb`).
2. **Unit — builder:** feed the enriched sidecar → assert `themeOverrides.categoricalScheme` is emitted in fixed order, KPI has `value.fontSize` + `name:' '` + transparent `style`, `controlType:list` where `control_display=compact`, and the threshold chart carries a 2-color `scheme`. Round-trip the emitted style fields through POST→GET (all §4.2 fields are verified round-trippable per `styling.md`).
3. **Fleet PNG gate (existing).** The composition emitter must keep the fleet parity gate green. Run the workbook through the existing Phase-6/`verify-dashboard-visual.rb` render and confirm no regressions and that the render now shows tints/palette/labels. Test path is **CSA.TJ** (the standard Tableau→Sigma warehouse path); land the benchmark's fact table there and run the full converter against it as the E2E case.
4. **Phase-5 visual diff (follow-on, out of Phase 1).** Once the loop exists, it diffs the emitted render against the benchmark image; Phase 1's job is to shrink that diff to near-zero on the style axis so the loop converges in 0–1 passes instead of 7.

Respect the existing `assert-phase6-ran.rb` hard gate — the composition emitter runs before layout, so Phase 6 still gates the final render.

---

## 7. Risks & unknowns

- **Unreliable `.twb` style attributes.** Tableau fill formatting lives in several element scopes (`dash-zone`, `pane`, `caption`, `cell`) and versions differ. **Mitigation:** read defensively (try each scope, `nil` when absent), and treat any un-extracted color as "no style" (falls back to today's plain container — never worse than current output). Emit a WARN, don't guess a color.
- **Alpha handling.** `style.backgroundColor` accepts 8-digit `#rrggbbaa` (verified) and the transparent-KPI recipe depends on `#00000000`; the server **lowercases hex on save** (`styling.md` gotcha) — do not treat the lowercased readback as a dropped field in the round-trip test.
- **Category-order pinning (D2).** Positional `color.scheme` drifts if two charts sort their category axis differently. **Mitigation:** build one canonical `category→color` dict from the palette and force every chart to the same sort order; store it once so all four region charts + the left-rail "Most Impacted" bar keep a region on one color dashboard-wide.
- **`categoricalScheme` vs per-chart `scheme` interaction.** Setting both is redundant but harmless (per-chart wins). For **donut/pie**, per-chart `scheme` is silently dropped — must use the workbook `categoricalScheme` path (styling.md Recipe 5). None of the benchmark's charts are pie, so low risk.
- **`text.body` HTML strictness.** The API validates HTML: left-aligned `<p class="h-*">` 400s, `var(--colors-*)` 400s (hex only), `Text()` templating errors only surface on render. **Mitigation:** emit markdown `#`/`###` + `<span style="color:#hex">` for headings, hex colors only, and keep the render check in the loop.
- **Two-stage style split ordering.** Element style is set in the chart builder; container/theme style flows through a sidecar to the layout stage. If the layout stage falls back to the banded path (`build_page_for_dashboard`, on tree failure), it must still read the composition sidecar for tints — otherwise a fallback silently drops all container tints. **Mitigation:** wire the sidecar lookup into *both* `emit_node` (tree path) and the bands loop (banded path).
- **Header-bar as nested container.** `styling.md` warns against over-nesting, but a colored header *band* inside a tinted column is the benchmark and is a legitimate band, not decorative re-wrapping. Keep it to one level.

---

## 8. Sequenced task list (Phase 1)

| # | Task | Files | Effort |
|---|---|---|---|
| 1 | Parser: extract `channels.color.palette` (named member→color map) from `<encoding class='color'>/<map>` | `parse-twb-layout.rb` (extend L492-500) | **M** |
| 2 | Parser: extract zone `fill_color` / `title_fill_color` / `title_text_color` / `border_color` and dashboard `canvas_color` | `parse-twb-layout.rb` (`build_zone_tree` L805, flat loop L868, dashboard loop L836) | **M** |
| 3 | Parser: extract `control_display` (`param-mode`) on filter/param zones | `parse-twb-layout.rb` (L823, L861) | **S** |
| 4 | Parser: extract `text_runs` / `text_align` / `is_pill` from text/title zone `<formatted-text>` | `parse-twb-layout.rb` (zone loop) | **M** |
| 5 | Parser: derive `kpi_composite` + `annotation_runs` from is_kpi-in-captioned-container | `parse-twb-layout.rb` | **S** |
| 6 | Builder: `emit_composition` + `--composition-out`; write `composition.json` (container styles + workbook `themeOverrides`) | `build-charts-from-signals.rb` (new stage before L3460) | **M** |
| 7 | Builder: **D1/D2** — palette → `themeOverrides.categoricalScheme` + pinned-order per-chart `color.scheme` | `build-charts-from-signals.rb` (chart path + composition) | **M** |
| 8 | Builder: **E1** — replace hardcoded `segmented` (L3206) with `control_display`-driven `list`/`segmented` | `build-charts-from-signals.rb` (L3172-3249) | **S** |
| 9 | Builder: **B3** — KPI composite (`name:' '`, `value.fontSize`, transparent `style`, label + annotation text) | `build-charts-from-signals.rb` (`build_kpi_element` L1625) | **M** |
| 10 | Builder: **B4/B5** — styled `text` elements from `text_runs`; `###` section headers; pill chips | `build-charts-from-signals.rb` (extend title/text emit L3044) | **M** |
| 11 | Builder: **C2** — threshold 2-color fallback (computed bool + `scheme:[base,hl]`) + WARN | `build-charts-from-signals.rb` (chart path) | **M** |
| 12 | ~~Builder: **C5** — auto `dataLabel`~~ — **already implemented (L3373-3380)**; verify only | — | **done** |
| 13 | Layout: **B2 + Pass-7** — read `composition.json`; apply container tints via `container_el(id, style)`; emit header-bar sub-container; set workbook `themeOverrides` + transparent chart `style` over tints | `build-dashboard-layout.rb` (L182-203, bands loop; `--composition`), `lib/layout.rb` | **L** |
| 14 | Tests: parser-fixture assertions + builder round-trip + CSA.TJ E2E fleet-PNG gate on the benchmark | `test-container-layout.rb`, `test-layout-lint.rb`, new fixtures | **L** |
| 15 | Wire the new stage into `migrate-tableau.rb` orchestration (composition sidecar path threading) | `migrate-tableau.rb` | **S** |

**Rough total:** ~7 S/M tasks + 2 L tasks. Tasks 1–5 (parser) are independent and can land as one PR; 6–11 (builder element+theme) as a second; 13–15 (layout + tests + orchestration) as a third. Land in that order so the parser sidecar exists before the builder consumes it and the layout stage consumes it last.

---

**Bottom line:** Phase 1 is two edits and a sidecar — teach `parse-twb-layout.rb` to read six style signals it currently ignores, and add an `emit_composition` stage to `build-charts-from-signals.rb` (plus a style-aware pass in the layout stage) that turns them into the exact `styling.md` fields the human set by hand. Doing this collapses render Passes 2–7 (palette, tints, header bars, KPI composites, labels, dropdowns, canvas, transparent chart backgrounds) into the one-shot output. B1 (card-trellis) and the Phase-5 visual-diff loop are the direct dependents that turn "~90% of the replica automatically" into "exact, one run."

---

## Backlog tracking

Filed in beads under epic **`beads-sigma-ubr5`** ("Tableau→Sigma fidelity: composition/style layer + gap backlog"), children `beads-sigma-ubr5.1`–`.20` (gap IDs A1–F6). Phase 0 (A1 `.twb` UTF-8 read fix + A4 scanner-vocabulary surfacing) ships separately; C5 already implemented.
