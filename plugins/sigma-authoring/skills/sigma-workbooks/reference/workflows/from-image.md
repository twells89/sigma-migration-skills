# Building from a target image or design artifact

Use this workflow when the user has provided a screenshot, mockup, PDF, or
Claude-generated design artifact they want reproduced in Sigma — including
migrations from Tableau, Looker, PowerBI, or any other BI tool.

The general spec workflow ([the rest of SKILL.md](../../SKILL.md)) still applies. This document covers **only the additional steps** that come *before* and *alongside* normal data discovery and spec drafting.

## Why this workflow exists

When the user supplies an image, the agent's first job isn't to call the API —
it's to *interpret*. A workbook spec is a precise object; an image is not.
Going straight from "I see a picture" to "POST this YAML" almost always
produces a workbook that has the right vibe but wrong shape, wrong axes, wrong
groupings, or none of the product shell and behavior visible in the artifact.
The common bad first pass recreates the charts and ignores the header, rail,
tabs, buttons, input semantics, agent panel, spacing, and visual hierarchy.

The workflow below makes the interpretation step explicit and auditable.

## Workflow

### Step 0a — Read the target image first

Before any API calls, before any data discovery, **read the image with the Read tool**. Don't read it as a confirmation step at the end; read it as the first thing you do.

If the user provided a target image, treat the workbook-creation task as a two-input problem: the prose request *and* the image. The image usually carries more information than the prose, but ambiguities in the image are why the prose is also there.

### Step 0b — Describe what you see, in Sigma terms

After reading the image, **write out an inventory** of what you saw. Do this as
part of your reply / planning, before drafting any spec. The inventory has five
sections:

1. **Workbook boundaries.** Decide whether each screen is a page or a separate
   workbook. Respect the user's explicit split. When artifacts show distinct
   apps (for example, an analytics assistant and a writeback planner), do not
   collapse them into one workbook merely because they share branding.
2. **App shell and chrome.** Inventory the logo/wordmark, left rail, breadcrumb,
   title/subtitle, header actions, tabs, cards, dividers, canvas background,
   and any footer/status strip. Record alignment, grouping, spacing, radii,
   borders, and active states. These are deliverable elements, not decoration
   to add after the data visuals.
3. **Data elements and kinds.** For each visible element, name the Sigma `kind`
   it most closely maps to (`kpi-chart`, `bar-chart`, `line-chart`,
   `donut-chart`, `table`, `input-table`, `chat`, `control`, etc.). If unsure,
   describe the marks and state the best guess. **A grid with editable cells,
   Save/Cancel state, pencil icons, or unsaved-edit text is an `input-table`,
   not a read-only `table`. A conversation rail is `document.agents[]` plus a
   `chat` element, not a text box.**
4. **Per-element details.** For each data element: what's on the x-axis, y-axis,
   color/series channel? Is it grouped or stacked? Which columns are editable,
   computed, or key/context columns? Which controls are visible and what are
   their defaults?
5. **Behavior.** For every button, tab, control, editable cell, and agent, write
   what the user expects it to do. Classify the implementation as
   `native-spec`, `ui-only`, `plugin`, or `unavailable`. Never silently turn an
   interactive-looking surface into a decorative no-op. Ask for approval before
   shipping a decorative stand-in.

The goal is to produce an explicit, debuggable interpretation. If you build a workbook and the visual judge says "this looks different," you can point at the inventory and see exactly where you went wrong.

### Step 0c — Validate the interpretation

Before drafting, read your own inventory and check it against the image again. Two questions:

- **Are there elements you didn't list?** Look at the corners and edges; logos,
  breadcrumbs, small KPIs, action buttons, status text, and editable-column
  affordances get missed.
- **Is anything ambiguous?** "I see a bar chart with bars of different colors — that could be `color.by: category` on a single grouping, or it could be a stacked bar with one stack." When in doubt, prefer the simpler interpretation and note that you're guessing — don't quietly commit.
- **Did you classify behavior, not just appearance?** A screenshot cannot prove
  whether a button publishes, navigates, opens settings, or is decorative.
  Resolve this before implementing it.

### Step 0c.1 — Record a design manifest

For a multi-screen artifact or any app-like surface, create a local JSON
manifest before drafting:

```bash
ruby scripts/design-artifact.rb init /tmp/design-manifest.json
# fill the manifest from the artifact inventory
ruby scripts/design-artifact.rb check /tmp/design-manifest.json
```

The manifest forces each visible surface to have a Sigma implementation,
acceptance criterion, and behavior classification. Use `--strict` only at the
end; it fails while obvious visual mismatches, unverified interactions, or
unaccepted tradeoffs remain:

```bash
ruby scripts/design-artifact.rb check --strict /tmp/design-manifest.json
```

The manifest is local run state. Do not commit customer screenshots, logos,
organization identifiers, workbook IDs, or warehouse paths into this skill.

### Step 0d — Now proceed with normal discovery

Once you have a validated inventory, run the normal data-discovery flow (see Step 3 of the main workflow). For each element in the inventory, decide which available column maps to the axis or grouping field. If the source data doesn't have a column that matches the image's exactly, **substitute the closest equivalent and note the substitution** — structural fidelity matters more than data fidelity for image-driven cases.

Example: image shows "Gross Margin by Customer Value Tier (Bronze / Silver / Gold / Platinum)" but the available data has no customer tiers. Substitute by a comparable categorical dimension that does exist (e.g., a `customer_segment` column with whatever buckets it has, or a derived bucket from order count). Document this in your final summary.

### Step 0d.1 — Verify each dimension picked is the *right shape*

A common failure: the agent sees "Delivery Speed Tier" in the target image (four bars labeled Economy / Express / Slow / Standard), grabs the first categorical-looking column in the available data (e.g. `product_brand` with hundreds of values), and ends up with a bar chart that has 200 unreadable rotated labels.

Before drafting, for each dimension you picked, sanity-check two things:

1. **Cardinality.** Count distinct values in the column. If the target image shows 4 bars and your column has 200 distinct values, that's the wrong column — keep looking, or derive a coarser bucketing.
2. **Semantics.** The column's contents should make sense for what the target's label implies. "Ship speed" should be values like Express/Standard/Slow, not product names or SKUs.

A two-line probe in your data-discovery step:

```sql
-- check cardinality
SELECT COUNT(DISTINCT <candidate_column>) FROM <table>;
-- check semantics (sample values)
SELECT DISTINCT <candidate_column> FROM <table> LIMIT 10;
```

If the candidate fails either check, document the gap in your final summary and either (a) substitute a different column that fits better, (b) derive a coarser bucketing via a formula like `If([order_count] >= 10, "Frequent", [order_count] >= 3, "Regular", "Occasional")`, or (c) drop that element from your reproduction if no good substitute exists.

This picks a visual dimension; it does **not** prove the composed source's row
grain. Run the pre-draft source check in
[`discover.md`](discover.md#verify-the-composed-source-grain-before-drafting)
before authoring any element.

### Step 0d.2 — Verify each metric is the *right calculation*

The other common failure: agent sees "Return Rate by Ship Speed" in the target and builds a bar chart showing 0-100% values for every category because they used `Sum([is_return])` instead of a rate calculation.

Before drafting, for each measure (the y-axis aggregate) you picked:

- **If the target label says "rate" or "%":** the measure is a *ratio*, not a sum. Use `Sum([numerator])/Count(*)` or `Sum([numerator])/Sum([denominator])` — not a raw sum.
- **If the target label says "average":** use `Avg(...)`, not `Sum(...)`.
- **If the target label is a money amount:** confirm the column is the right kind (revenue / margin / cost / price), and format the column with a currency format string.

After creation, the produced chart's y-axis range should look approximately like the target's. A "0-100%" axis when the target shows "0-4%" is a calculation error, not a formatting one.

### Step 0d.3 — Extract a small design system

Do this before writing layout XML:

- **Palette:** canvas, card, border, primary ink, muted text, accent, semantic
  colors. Sample or estimate hex values from the artifact; do not substitute
  the default dark hero recipe when the target is a light app shell.
- **Typography:** wordmark, page title, subtitle, section title, control label,
  and data-cell scale.
- **Geometry:** rail width, header height, number of grid columns, card gaps,
  radii, borders, and content density.
- **Alignment groups:** which items visually belong together. Header action
  buttons that sit shoulder-to-shoulder must occupy adjacent tight cells; two
  right-aligned buttons in wide independent cells will drift apart.

Apply these consistently across every workbook generated from the artifact.

### Step 0d.4 — Route to native Sigma first

Use native workbook elements for the whole screen whenever possible:

- app chrome → `container`, `text`, `image`, `divider`, `button`, `navigation`;
- editable grid → `input-table`;
- assistant rail → `document.agents[]` + `chat`;
- cross-workbook tabs → button actions with `open-document`;
- data visuals → native chart/table/KPI kinds.

Load `sigma-plugin-authoring` only for a **bespoke data visualization with no
native Sigma equivalent**. A screenshot that merely looks polished is not a
reason to build a custom plugin.

If the inventory calls for `kind: form`, verify a minimal form spec before
building the full screen. `Invalid kind: "form"` and “form elements are not
enabled” both mean the workspace cannot author that element. Stop after the
preflight and ask whether an `input-table` + controls workflow is an acceptable
behavioral substitute; do not spend writes or tokens varying the form syntax.

### Step 0d.5 — Treat assets honestly

For a visible logo, prefer an existing public HTTPS asset or a user-provided
asset URL. If none is available:

1. ask whether a close primitive/icon approximation is acceptable;
2. label the approximation as a tradeoff in the manifest;
3. do not claim a monogram is the source logo.

Inline SVG data URIs may pass `/v2/workbooks/spec/verify` but still trigger a
Cloudflare WAF challenge on the actual `POST`/`PUT`. Only a successful write,
readback, and render proves the asset path works.

### Step 0e — Draft the native structure first

The first draft must include every structural surface from the inventory:
workbook split, shell, header, navigation/tabs, controls, data elements, input
tables, agents, and explicit layout. Do not defer the app shell to a later
"polish" pass; that produces a valid but visibly wrong first result and makes
the user push for the design they already supplied.

For input-table artifacts:

- use a real `input-table` on the first draft;
- establish deterministic linked keys before creation (keys are immutable);
- include the write connection/writeback schema as required by the live schema;
- preserve editable vs computed columns;
- verify defaults and row cardinality by export;
- record the UI-only published-data-entry and publish gates explicitly.

For agent artifacts, use a real agent/chat when the org feature is available.
Do not substitute static explanatory text and call it an agent.

### Step 0f — Render, compare, and iterate

From here, follow the standard workflow (Steps 5–8). A successful spec verify,
POST, readback, or compile check is **not visual acceptance**.

1. Render every visible page to PNG at approximately the target artifact's
   viewport/aspect ratio. PDF is useful for print artifacts; use PNG for app
   screenshots because responsive layout is the thing being judged.
2. Read the rendered PNG itself and compare it side-by-side with the target.
3. Diff at four levels:
   - **structure:** workbook/page split, shell, header, rail, cards, agent rail;
   - **geometry:** width ratios, heights, alignment, gaps, density;
   - **semantics:** chart kinds, axes, input/edit behavior, agent capability;
   - **finish:** colors, borders, typography, active states, clipping.
4. Put every visible mismatch into `visual.mismatches` in the manifest.
5. Iterate with `PUT`, re-render, and remove mismatches only when the new render
   proves they are fixed.

**Do not stop at the first render.** Artifact-driven work requires at least a
first render and a final render. The final render must have no unresolved
`high`-severity mismatch. An accepted limitation (for example, formula columns
always rendering last) belongs in `acceptedTradeoffs`, not silently ignored.

### Step 0g — Exercise behavior

For each control and interactive surface:

- confirm stored defaults on readback (single-select controls may store a
  scalar `value`, while multi-select controls use `values`);
- export with at least two control states and prove both what changes and what
  must not change;
- for input tables, edit a real row, save, re-query, and verify computed values;
- for agents, ask a question with a known answer and verify the response;
- for buttons/tabs, exercise navigation/action behavior where authentication
  permits it.

Client-credential REST auth does not create an authenticated browser session.
If UI-only data-entry permission, first-save provisioning, or publish remains,
report that gate precisely; do not claim completion from API evidence.

### Step 0h — Completion gate

Before declaring done:

```bash
ruby scripts/design-artifact.rb check --strict /tmp/design-manifest.json
./scripts/verify-workbook.sh "$WORKBOOK_ID"
```

Also re-render every visible page. Report the workbook URLs, spec paths,
accepted tradeoffs, and any UI-only gates. Do not make the user rediscover
obvious visual differences that are already visible in the render.

## Things to watch out for

- **The toolbar text in BI tool screenshots is misleading.** A Tableau "marks card" labeled "automatic" or a Looker "visualization type: bar" can ship as anything visually — read the actual visual, not the metadata text.
- **Don't carry source-tool concepts directly.** Tableau "sheets," Looker "looks," PowerBI "visuals" all map onto Sigma's flat `elements[]` list, but they don't translate 1:1. A Tableau dashboard tab is a Sigma `page`; a Tableau sheet is one or more Sigma elements.
- **Title text isn't the data.** A chart titled "Gross Revenue by Ship Speed" tells you what the user wants the chart *labeled*; the data fields are inferred from the visual marks, axes, and the user's other instructions — not from the title.
- **When the data is empty.** If your produced workbook renders "No data" for a panel, the structural interpretation may be right but the data substitution wrong. Re-check: did you pick a column that actually has rows in the selected time range? Did the default filter exclude everything? Fix and re-verify rather than calling it done.
- **Don't decorate fake behavior.** A button styled "Publish" is not a publish
  feature unless it actually publishes. Remove it, wire a real action, or mark
  it as an explicitly accepted decorative surface.
- **Don't conflate writeback rows with spec state.** Input-table rows live in
  managed warehouse state and can survive spec `PUT`s. Verify both the document
  and the rows after structural changes.

## What this workflow does NOT cover

This page is about *interpreting* an image into spec intent. It does not redefine:

- How to discover data (see `reference/workflows/discover.md`)
- How to write formulas, layouts, or spec shapes (see `reference/specification/*.md`)
- How to validate a spec before submitting (see `reference/workflows/validate.md`)
- How to verify after creating (see `scripts/verify-workbook.sh`)

You still need those — this workflow just sits in front of them.
