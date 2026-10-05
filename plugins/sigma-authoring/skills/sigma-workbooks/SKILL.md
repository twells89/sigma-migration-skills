---
name: sigma-workbooks
description: >-
  Build, edit, and iterate on Sigma workbook specs — the JSON definition you
  POST to /v2/workbooks/spec, covering pages, layout, controls, charts, KPIs,
  tables, formulas, and sources. The Sigma OpenAPI is the source of truth for
  every shape and field; this skill adds navigation, style guidance, and
  proven recipes for effective dashboards and operational apps. Use when the
  user wants to construct a dashboard from a spec, generate a Sigma app
  (planning, approval, allocation, or exception), reproduce a
  screenshot/mockup/Claude design artifact as a native Sigma app, add or
  modify pages / elements / controls / formulas, validate a spec before
  submission, or work through the workbook spec lifecycle programmatically.
  Requires an SIGMA_API_TOKEN — obtain via the sigma-api skill first.
---

# Sigma Workbooks (Spec via REST API)

This skill helps you build effective Sigma workbooks by **navigating the Sigma OpenAPI** and applying **style guidance + proven recipes** beyond what the OpenAPI alone teaches.

## Scope

The workbook **spec** — the JSON you POST to `/v2/workbooks/spec` defining pages, elements, sources, formulas, and layout. Lifecycle around the workbook (embeds, grants, materialization schedules, bookmarks, sharing) is a separate API surface and out of scope here.

## Sources of truth

Sigma's public API docs are an index at `https://help.sigmacomputing.com/openapi.json` that lists two **canonical split specs** (split from one large spec to fix compilation / out-of-memory errors — so the structure changed subtly). **That index now serves an HTML page, not JSON** (verified 2026-08-05) — it renders links to the two specs rather than returning a machine-readable list, so treat it as a human landing page and go straight to the two URLs below:

1. **`https://help.sigmacomputing.com/openapi/openapi/sigma-rest-api.json`** — the REST API: endpoint request/response shapes (workbooks, data models, members, connections, exports, materialization, …). Use for API *calls*.
2. **`https://help.sigmacomputing.com/openapi/openapi/code-representation.json`** — the "code representation" (as-code) spec. Today it documents the **data-model** spec (`/v2/dataModels/spec`); use it for data-model element shapes.

**Workbook element/control/format shapes** (the `bar-chart` / `kpi-chart` / `control` / format `kind`s that go under `/v2/workbooks/spec`) are **not inlined in either split spec** — get them from one of, roughly in this order.

> **The split specs don't document the workbook spec endpoint at all** (verified 2026-08-05): `sigma-rest-api.json` has **zero** paths matching `spec` — no `/v2/workbooks/spec`, no `/v2/workbooks/spec/verify`, no `/v2/workbooks/{id}/spec` — and `code-representation.json` carries only the two `/v2/dataModels/spec*` paths. So for workbook authoring the split specs are not merely missing the inlined element shapes; the endpoint itself is absent. Use a per-endpoint reference page, the compiled asset, or a live readback (all below).

- **A live workbook readback** — `GET /v2/workbooks/{id}/spec` on the user's org. Read literal elements from flat `document.elements[]`; pages, overlays, and panels are metadata and layout determines placement.
- **A single endpoint's stable reference page** — `https://help.sigmacomputing.com/reference/<endpoint-slug>`. Use it to confirm one endpoint's current request/response envelope. Create and verify use `{name, folderId, document: {...}}`; update accepts exactly `{document: {...}}`. <!-- pragma: allowlist secret -->
- **The full compiled OpenAPI** — one document covering every workbook `kind`, and the **only** source that documents `/v2/workbooks/spec` at all. Use it for bulk discovery ("list every kind the API accepts") that no single per-endpoint page can do. **This is the canonical, stable, unauthenticated URL — use it directly:**

  ```
  https://assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json
  ```

### Fetching the compiled asset

```bash
curl -sfL https://assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json \
  -o /tmp/sigma-api.json
```

Plain `GET`, no auth, no signature, no content hash — safe to hardcode. Title "Sigma Computing Public REST API", `version: 2.0.0`, ~6.8 MB (it uses `$ref`s into `components.schemas`, so **deref as you walk** — element kinds are behind `#/components/schemas/WorkbookElement`).

> **Do not use the old Fern docs asset** (`fdr-prod-docs-files-public.s3.amazonaws.com/sigma.docs.buildwithfern.com/<hash>/…`). It is content-addressed, now requires AWS presigned query params (a bare fetch 403s), and — the reason that actually matters — **it lags the live API**. As of 2026-08-05 it was missing `/v2/reports/spec*` entirely, still documented the pre-`document`-wrapper request body, and **did not contain the `repeated-container` element kind**, which caused this skill to previously assert that repeated containers were not spec-authorable. They are. Working from a stale asset produces confidently wrong documentation; prefer the `assets.sigmacomputing.com` URL above, and treat a live workbook readback as the tiebreaker.

The old `help.sigmacomputing.com/openapi.json` index is now an HTML landing page and does not link the compiled asset at all.

When this skill and the spec (or a live readback) disagree, the spec wins. When a feature isn't covered here, consult the spec / a live workbook and use what it documents.

## Consulting the shapes (per-endpoint pages, compiled OpenAPI, or a live readback)

**The field lists and examples in this skill are illustrative, not exhaustive** — when you need the complete, current shape of anything, pick the right tool for the question:

- **One endpoint, one doubt** (does this field still exist, is the body wrapped or flat, what's required) — go straight to that endpoint's stable reference page, `https://help.sigmacomputing.com/reference/<endpoint-slug>` (see *Sources of truth*). No caching, no `jq`, just read the page.
- **Every `kind` the API accepts, or every field on a `kind`** (bulk discovery — e.g. building out `reference/specification/*.md`) — the per-endpoint pages don't help here (one endpoint each); use the compiled OpenAPI or a live workbook readback instead. Fetch the compiled spec once per session and inspect with `jq`:

```bash
# Assumes /tmp/sigma-api.json from "Fetching the compiled asset" above.
# If a field looks wrong, check that field's per-endpoint page, or read a live workbook spec
# (GET /v2/workbooks/{id}/spec) and navigate document.elements[] by kind.

# The workbook spec request body. NOTE: the outer object is {name, folderId, description?, document},
# so elements/pages/overlays/panels/layout/settings/agents are under .document:
jq '.paths."/v2/workbooks/spec".post.requestBody.content."application/json".schema' /tmp/sigma-api.json
```

Element, source, control, and format shapes are identified by their `kind` value (e.g. `bar-chart`, `kpi-chart`, `join`, `warehouse-table`) rather than by a top-level schema name. They live in `components.schemas` and are reached by `$ref` (element kinds hang off `#/components/schemas/WorkbookElement`) — so **deref as you walk** if you're writing your own traversal. The `jq` recipes below scan the whole document, so they work regardless:

```bash
# List every kind the spec accepts (elements, sources, controls, formats, …):
jq -r '[.. | objects | select(.properties.kind.enum) | .properties.kind.enum[0]] | unique[]' /tmp/sigma-api.json

# Full field list (required + optional) for one kind — swap bar-chart for any kind above:
jq --arg k bar-chart 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))
  | {required: ([.allOf[]?.required // .required] | add | unique), properties: ([(.allOf[]?.properties // .properties) | keys[]] | unique)}' /tmp/sigma-api.json

# The full nested shape for that kind (to inspect sub-objects like source, yAxis, format, comparison):
jq --arg k bar-chart 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

`WebFetch` works for the JSON too. Either path is fine.

No `curl`/`jq` on the machine (e.g. Windows without WSL)? `scripts/wb-rep.rb`
ships a `capabilities` subcommand that does the same three queries with
pure-Ruby `Net::HTTP` + `JSON.parse` — no external tools required:

```bash
ruby scripts/wb-rep.rb capabilities                          # list every kind
ruby scripts/wb-rep.rb capabilities --kind bar-chart          # field list for one kind
ruby scripts/wb-rep.rb capabilities --kind bar-chart --field source  # one field's shape
```

**Why bother:** the API ships new fields and viz configurations regularly, and this skill covers the common surface, not every field. If you want a capability and don't see it documented here, **assume it may exist and check the spec before concluding it doesn't** — the `kind` query above answers in seconds.

## Auth

Authenticate via the `sigma-api` skill first to populate `$SIGMA_BASE_URL` and
`$SIGMA_API_TOKEN`. Its common `get-token.sh` path prefers a saved interactive
browser session and falls back to `SIGMA_CLIENT_ID` /
`SIGMA_CLIENT_SECRET` for unattended use. Either method yields the same token;
the rest of this skill is identical.

## Recommended Workflow

These are guidelines, not mandates — but they prevent the failure modes that show up most often when drafting from scratch.

> **Schema drift signal:** an error about request *shape* (`invalid argument`, `unknown field`, `missing required field`, `unexpected property`) usually means this skill is stale on that detail. Fetch the OpenAPI and compare; the canonical shape is there.

### Step 0 — Authenticate, capture user identity

```bash
USER_ID=$(curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/whoami" | jq -r '.userId')

HOME_FOLDER_ID=$(curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/members/$USER_ID" | jq -r '.homeFolderId')
```

If the user provided a **target image or design artifact** (a screenshot,
mockup, PDF, or Claude-generated app design they want reproduced), pause here
and load `reference/workflows/from-image.md` — it adds mandatory whole-screen
inventory, behavior classification, design-manifest, native-first routing,
render-diff, and iteration gates that happen *before and alongside* normal data
discovery. The standard workflow alone tends to reproduce the data visuals
while missing the app shell and behavior.

If the user asked to generate / build / scaffold a Sigma **app** (planning,
approval, allocation, exception, or an unspecified “app”) and did **not**
supply a target image, pause here and load
`reference/workflows/generate-apps.md` — it classifies the app type,
**interviews** before it builds (which fields users may edit, whether the
workflow needs approvals, whether to add a Sigma Agent and what it is
for), records an intake manifest, states a build plan, and clones a
best-practice **architecture** fixture.
Design is a separate pass: load `styling.md` as a library and compose for
this type (do not stamp the five-recipe dashboard *or* the navy-hero
command-center example). A
target image still wins: load `from-image.md` instead.

### Step 1 — Optional: choose one relevant reference workbook

Use a live reference only when the OpenAPI and this skill do not answer a
specific shape question, or when the user explicitly wants to match an
existing workbook. Do not browse unrelated workbooks speculatively. If a
reference is needed, list once and choose one relevant workbook:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/workbooks?limit=50" | jq '.entries[] | {workbookId, name}'
```

Save the chosen workbook ID for the session. If no relevant workbook exists,
draft from the compiled OpenAPI and this skill's fixtures—do not pick a random
workbook. Read only the one reference needed for the unresolved shape.

### Step 2 — Cache the reference spec, if Step 1 selected one

YAML is the canonical format for workbook specs in this skill — easier to read, diff, and review than JSON. Sigma's API accepts both (`Content-Type: application/yaml` or `application/json`); `Accept: application/yaml` is the default on `GET /v2/workbooks/<id>/spec`. Use `yq` to inspect spec YAML the same way you'd use `jq` on JSON.

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/workbooks/<reference-workbook-id>/spec" \
  > /tmp/reference-spec.yaml
```

Look at source structure, column IDs, formulas, flat `document.elements`, page
metadata, and layout XML. Reuse this cached file for the session instead of
re-listing or re-fetching workbooks. Do not copy an obsolete
`pages[].elements` shape.

### Step 3 — Discover data sources

Load `reference/workflows/discover.md`. Quick summary:

1. Prefer Sigma MCP `search` / `describe` (or a warehouse-native MCP) when it is already connected.
2. Otherwise list connections and browse `/v2/connections/paths`, including pagination, before asking for an exact table path.
3. Verify the selected path with `POST /v2/connection/<id>/lookup`, then use the `sigma-api` paginated column helper to exhaust `GET /v2/connections/tables/{inodeId}/columns`; its default raw response contains only 50 columns.
4. Ask one focused question only when semantic search/browse leaves multiple plausible sources or the endpoint cannot return what is needed.

**Never invent column names** — only use names returned by the API or supplied by the user.

**Verify literal values before writing predicates.** If your task involves filtering on a categorical column (e.g., `CountIf([Status] = "active")`, `If([Type] = "sale", ...)`), you need to know what values that column *actually* contains — the `/v2/connections/tables/{inodeId}/columns` endpoint gives you names and types but not values. Run a `SELECT DISTINCT <col>` via any tool that reaches the warehouse — an MCP server (warehouse or [Sigma](https://help.sigmacomputing.com/docs/use-sigma-mcp-server)), a SQL CLI, or just ask the user. Don't guess literals. See `reference/workflows/discover.md`.

**Verify the composed source grain before drafting.** Name the expected grain
key (or composite key), then prove that the source as the workbook will read it
has one row per key. For a single key, assert
`COUNT(*) = COUNT(DISTINCT <grain-key>)`; for a composite key, group by all key
columns and require zero duplicate groups. For a 1:1 or many:1 join intended to
preserve the left grain, compare row count and distinct left-grain count before
and after the join and require both to stay unchanged. Inner joins and
intentional 1:many joins need a written expected shrink/expansion instead.
Do not draft plausible-looking counts over an unproven fanout. See
`reference/workflows/discover.md`.

### Step 4 — Identify features and load only what you need

Map the user's request to the **Reference Index** below. State the features you identified, then read the listed reference files before drafting. **If the user asks for a feature this skill doesn't cover**, fetch the OpenAPI and inspect the relevant schema.

When choosing a visualization, use the data-shape selector at the top of
`reference/specification/charts.md` before copying a chart recipe. A ranked
categorical comparison defaults to a horizontal bar, not a sorted table used
as the primary visualization.

If the user asked to generate an app, run `generate-apps.md` first (Step 0)
before choosing an input-table architecture here. That interview already
recorded which fields users may edit, whether the workflow needs
approvals, and whether to include a workbook agent. Load
`reference/specification/styling.md` as a library and compose for this
app's job — do not stamp the five-pattern exec-dashboard stack or the
navy-hero command-center example.

If the request includes an input table, writeback, “populate,” “seed,” planning,
approval, allocation, or exception workflow, load
`reference/specification/input-tables.md` before choosing an architecture.
Creating an input-table element, loading initial rows, composing a downstream
read path, and submitting a runtime action are four different operations. Do
not substitute actions, unions, or joins for one another when the first
approach leaves the table empty.

### Step 5 — Draft the spec to a local file

Write the spec YAML to disk (e.g., `/tmp/workbook-spec.yaml`). YAML is preferred over JSON in this skill — easier to read, diff, and comment for human review. The API accepts either; pick YAML unless something downstream specifically needs JSON. Key rules:

For a build expected to exceed one page or roughly ten elements, start with
the element rep now (`reference/workflows/element-rep.md`): scaffold/import the
local spec, split it, and work in per-element files before the first POST.
Do not wait until the first large whole-spec iteration has already consumed
the context budget.

- Every element needs a unique `id` and a descriptive `name`.
- Every column needs a unique `id`, a `name`, and a `formula`.
- Follow the formula reference rules in `reference/specification/formulas.md` exactly — most spec errors happen here.
- **Write explicit `document.layout` XML whenever elements are non-empty.** It
  is the source of truth for page/container/tab organization.
- Emit `<Element>` for layout leaves and `<Container>` for nested grids,
  including repeated-container elements. `<TabbedContainer>` / `<Tab>` remain
  valid. Never emit the legacy `<LayoutElement>` / `<GridContainer>` aliases;
  live verification rejects `<LayoutElement>` (`valid:false`; some API
  versions returned HTTP 400 instead).
- Start with 1–2 pages. Add more later via update.

For **create**, include outer `name`/`folderId` and `document` with required
`schemaVersion`, `kind: workbook`, flat `elements`, and metadata-only `pages`.
Optional document fields include `overlays`, `panels`, `settings`, and `agents`.
This skill requires `layout` whenever `elements` is non-empty. See
`reference/specification/schema.md`.

### Step 6 — Validate the spec

**Run the bundled validator first — do not skip.**

```bash
./scripts/validate-spec.sh /tmp/workbook-spec.yaml
```

Then do the manual formula pass and final shape checks per `reference/workflows/validate.md`. Fix everything reported before continuing.

### Step 7 — Create the workbook

```bash
curl -s -X POST -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/yaml" \
  -H "Accept: application/yaml" \
  --data-binary @/tmp/workbook-spec.yaml \
  "$SIGMA_BASE_URL/v2/workbooks/spec" > /tmp/create-response.yaml

WORKBOOK_ID=$(yq -r '.workbookId' /tmp/create-response.yaml)
cp /tmp/workbook-spec.yaml "/tmp/workbook-spec-${WORKBOOK_ID}.yaml"
```

Persist the spec after a successful create so subsequent `PUT` updates can start from it. Report **both** the workbook URL **and** the saved spec path.

If creation fails, classify the error before changing anything. Correct the
local spec, rerun all offline checks, and make at most one corrected write for
the same error class. For a shape/schema error, inspect the live schema rather
than submitting alternative guesses. If the same error persists after the
corrected write, stop and report the unresolved contract mismatch. See
`reference/workflows/validate.md` for error classification.

### Step 7b — Verify the workbook actually compiles

**Do not skip.** A successful POST is necessary but not sufficient — Sigma accepts specs whose formulas don't resolve, then surfaces the failures at query time by embedding the error as a string literal in the compiled SQL (`'Unknown column "[X]"'`, `'Circular column reference to [Y]'`). Affected elements render empty in the UI. Only Sigma's compiler knows whether your formula references actually resolve.

```bash
./scripts/verify-workbook.sh "$WORKBOOK_ID"
```

If any element reports `[FAIL]`, fix the column formulas in the spec (most often a missing source prefix, a self-referencing column, or a friendly-name mismatch with the warehouse — see `reference/specification/formulas.md`), `PUT` the corrected spec, and re-verify.

### Step 8 — Iterate

After initial creation, use `PUT /v2/workbooks/<id>/spec` to add pages or refine the workbook.

**Continue with the element rep for anything beyond ~1 page / ~10 elements**
(`reference/workflows/element-rep.md`): `scripts/wb-rep.rb pull <id> <dir>`
explodes an existing spec into one file per element, `push` handles drift-check
+ validation + PUT, and `render` exports page PNGs. The raw GET/PUT flow below
remains fine for small workbooks and one-off tweaks.

> **IDs are preserved on CREATE.** The `id` values you POST (pages, elements, columns) are kept verbatim, and `layout` `elementId` references stay valid — so you can edit your saved spec and `PUT` it back, re-wrapped as just `{document: {...}}` (see below — PUT does not take the outer `name`/`folderId`). `GET` the current spec first only if you don't have your latest copy. See `reference/workflows/crud.md`.

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/workbooks/<workbook-id>/spec" \
  > /tmp/current-spec.yaml

# Edit /tmp/current-spec.yaml inside .document; preserve elements, pages,
# overlays, panels, layout, settings, and agents.
# then PUT only the document object — see reference/workflows/crud.md for why
# sending the outer name/folderId/response-only fields alongside it 400s:
yq '{"document": .document}' /tmp/current-spec.yaml > /tmp/current-spec-put.yaml
curl -s -X PUT -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/yaml" \
  -H "Accept: application/yaml" \
  --data-binary @/tmp/current-spec-put.yaml \
  "$SIGMA_BASE_URL/v2/workbooks/<workbook-id>/spec" | yq .

cp /tmp/current-spec.yaml "/tmp/workbook-spec-<workbook-id>.yaml"
./scripts/verify-workbook.sh "<workbook-id>"
```

### Step 9 — Report back

Report the workbook URL and the saved spec path. **Do not tack on generic "improvement ideas" or "next steps."** Match the response to what was asked.

Surface follow-up items only when they're load-bearing, and name them concretely:

- **Tradeoffs you made during the build** — dropped a chart, simplified a formula, skipped a control because the shape wasn't in your reference.
- **Obvious gaps revealed by the column list** — e.g., the user asked for "sales by region" and the table has a `region_tier` column that would make the breakdown richer. One sentence, named.

If none apply, just report the URL + spec path and stop.

## Reference Index

The reference is feature-sliced — don't read every file up-front. The index has three sections: **elements** (the visual / interactive pieces), **sources** (where each element gets its data), and **cross-cutting** (formulas, layout, formatting, validation, CRUD).

### Elements

| File | When to load |
|------|--------------|
| `reference/specification/tables.md` | Table element, tabular data, data grid, spreadsheet-style list. Also **element-level filters** (`list`, `top-n`, `number-range`, `date-range`, `text-match`, `hierarchy`), groupings (pivot, group by), the `pivot-table` and editable `input-table` element kinds, and `conditionalFormats` (threshold-based cell coloring, on pivot/input tables). |
| `reference/specification/charts.md` | **Load before choosing a visualization.** Data-shape → chart selection, then chart/graph recipes for line / bar / column / stacked / grouped / combo / donut / pie / scatter / waterfall / share-of / breakdown. Cartesian axes, color, trellis, legend, trendlines, reference marks. |
| `reference/specification/maps.md` | Map visualizations — `geography-map` (GeoJSON shapes), `point-map` (lat/long bubbles), `region-map` (states / counties / countries). |
| `reference/specification/kpis.md` | KPI, stat, big number, single value, metric card — including layout / value styling, the comparison Δ badge (`comparisonColumn` + `comparison:{display:"delta"}` — spec-authorable and readback-stable; the house default), and the trend/sparkline block (still UI-bound). |
| `reference/specification/controls.md` | Filter, dropdown, picker, multi-select, date range, date picker, text filter, number range, slider, segmented, hierarchy, legend, and drill controls. Also entry controls and formula handles. |
| `reference/specification/content-elements.md` | The non-data elements — `text` (Markdown + inline styling), `image`, `divider`, `embed` (external URLs), `page-break` (PDF/print pagination), `form`, `progress`, `navigation`, `plugin`. Titles, callouts, logos, rules, embedded content. |
| `reference/specification/input-tables.md` | **Load for every input-table or “populate/seed” request.** Operational supplement for `input-table`: supported row-arrival decision tree, write connection, UI-only published permission, publish gate, linked-key correlation, warehouse views, and why actions/unions/joins are not bulk seeding mechanisms. |
| `reference/specification/styling.md` | **Load when composing a look from spec.** A library of options (hero bands, KPI cards, gradients, section headers, chart color, formats) plus an anti-pattern checklist. Not a house style — do not stamp the five-pattern exec dashboard onto every app. PNG fail: skill chrome, invisible entry controls, Dark-by-default on data-entry, 3-KPI status on operational apps. |
| `reference/specification/agents.md` | Workbook AI agent, chat with your data, agent, chatbot, AI assistant. The workbook-top-level `agents:[]` array + page-level `chat` element; Analyze / Configure / Navigate / Act capability profiles; direct control/navigation/write action tools; read-only analyst vs. operator; the four `tools[]` kinds (`action`, `mcp-connector`, `warehouse-agent`, `search-service`), `greeting`, `requiresApproval`, why action sequences are referenceable but not authorable; org-feature gate + graceful degrade. |

### Sources

| File | When to load |
|------|--------------|
| `reference/specification/sources-warehouse.md` | Always — load before drafting any spec. Warehouse-table source (Snowflake, BigQuery, Databricks, Redshift, Postgres/MySQL). |
| `reference/specification/sources.md` | Reference another chart/table/element, derive from existing element, join, combine tables, data model / semantic-layer source, custom SQL, union, transpose, unpivot. |

### Cross-cutting

| File | When to load |
|------|--------------|
| `reference/specification/schema.md` | Always — wrapped shape, required flat `document.elements`, metadata-only pages, overlays, panels, settings, backgrounds, and the PUT-only-document rule. |
| `reference/specification/formulas.md` | Always — load before drafting any spec. Formula syntax, qualification, special characters, the #1 mistake. |
| `reference/specification/formatting.md` | Format, currency, percentage, date format, decimals — column formatting. |
| `reference/specification/layout.md` | **Always load.** Required layout policy; page/container organization; backgrounds/spacing; panels, headers, sidebars, navigation; repeated and tabbed containers. |
| `reference/specification/example-full.yaml` | A real multi-page reference spec (KPIs, charts, joins, controls, layout) — copy shapes from when in doubt. |
| `reference/specification/comparative-kpi-card.yaml` | Minimal clone-able comparative KPI card — `value` + `comparisonColumn` + `comparison:{display:"delta"}`, the house-default comparative shape (see `kpis.md`). |

### Workflows

| File | When to load |
|------|--------------|
| `reference/workflows/discover.md` | Finding connections, tables, and column names. Load before composing a new spec. |
| `reference/workflows/composition.md` | Open-ended design decisions, named asymmetric splits/mosaic, and the content-prescriptive `ledger` record-lookup archetype. Covers when to ask, chart-vs-table defaults, editorial sizing, and hidden source pages. Load before drafting when the prompt leaves design choices unmade or asks users to find/browse records. |
| `reference/workflows/app-compositions.md` | **Operational app visual composition.** Load with `generate-apps.md`: keeps semantic architecture separate from appearance, selects `workbench` / `queue-rail` / `builder-preview`, requires a local design manifest, emits asymmetric work-surface-first layout via `Composition.compose`, and adds a two-render PNG polish gate. |
| `reference/workflows/actions.md` | Buttons, write-back, and **all twelve** action effects — insert/update/delete-rows, clear-control, set-control-value, open/close-overlay (modal **and** drawer), open-url, open-document (incl. passing `targetControls` into another workbook), navigate, select-tab, refresh-element — plus the append-only-log pattern and the masked-error catalog. Load when the user wants a button, a "log/save/submit" action, tab/page navigation, a deep link, or a write-back workflow. |
| `reference/workflows/generate-apps.md` | **Generate a Sigma app.** Load first when the user asks to build a planning, approval, allocation, or exception app (and did not supply a target image). Classifies the type, **interviews** for editable fields / approvals / an Analyze–Configure–Navigate–Act workbook-agent contract, clones an architecture fixture (planning is a multi-page studio shell), then **composes** an app shell + `workbench` / `queue-rail` / `builder-preview` look. Fail the PNG pass on skill chrome, invisible entry controls, Dark-by-default on data-entry, a 3-KPI status strip, an empty work surface, or `Unknown column` / `Invalid Query` on a page measure. |
| `reference/workflows/planning-apps.md` | **Scenario planning, budgeting, and forecasting apps.** Scenario × Period × Planning Line grain, governed baseline, scenario matrix, linked override grid, financial sign, filter-propagation choices, approval/audit, and runtime gates. |
| `reference/workflows/allocation-apps.md` | **Allocation and capacity apps.** Budget/target vs. baseline at Period × Allocation Dimension grain, linked editable units/uplifts, working allocation, request queue, and exact variance gates. |
| `reference/workflows/approval-apps.md` | **Approval and decision apps.** Stable entity-key queues, counter-values, immutable audit logs, one-row status updates, agent boundaries, and runtime tests. |
| `reference/workflows/exception-apps.md` | **Exception command centers.** Stable operational-key queues, deterministic recommendations, overrides, ownership, resolution logs, and exact KPI-delta tests. |
| `reference/workflows/crud.md` | POST / GET / PUT against the workbook spec endpoints. Load when creating, retrieving, or updating a workbook. |
| `reference/workflows/validate.md` | Pre-submit + post-create structural validation. Load before any POST or PUT; for joins, controls, writeback, agents, or numeric claims continue to `runtime-verification.md`. |
| `reference/workflows/runtime-verification.md` | **Runtime evidence loop:** compile, render, export, cardinality, numeric oracle, published writeback, linked-row correlation, control scope, approval scope, and agent tests. |
| `reference/workflows/from-image.md` | The user supplied a target image or Claude design artifact to reproduce. Load *before* discovery — it inventories the entire app shell and behavior, routes native Sigma vs plugin/UI-only surfaces, requires a local design manifest, and enforces first-render → diff → final-render acceptance. |
| `reference/workflows/element-rep.md` | **Large or multi-page workbooks, parallel element work, or iterative refinement.** `scripts/wb-rep.rb` explodes the spec into one small file per element (pull/status/push/render) so edits never drag the whole spec through context — element-level semantics over the whole-spec API, plus PNG renders to inspect what you built. |

## Quick Formula Rules

The single most common spec error is bare `[column_name]` references to warehouse columns. Full rules in `reference/specification/formulas.md`. Skeleton:

**Outside the element** — use `[SourceName/column_name]`:
- Warehouse-table source: `SourceName` = last segment of the `path` array (e.g., `[ORDERS/Revenue]`)
- Another element: `SourceName` = that element's `name`
- Join legs: prefix by the leg's `name`, or by the join's top-level `name` for `primarySource` columns

**Inside the same element** — use `[column_name]` (no prefix):
- References a column defined in this element by its `name` field.
- A column cannot reference itself (circular reference error).

**Data-model metrics** — use `[Metrics/<metric name>]`:
- `Metrics` is a reserved namespace; use the metric's `name`, not its ID.
- `[<element name>/<metric>]` is a column reference and can fail with
  `Dependency not found` even though the metric exists.
- Confirm the metric survives the data-model GET readback before binding it.

## Troubleshooting

### "I don't see this field in the skill"

Fetch the OpenAPI. The skill documents stable, common surface area; the API has more. See **Consulting the shapes** above.

### API schema mismatch (skill is stale)

A 400 about request *shape* — `invalid argument`, `unknown field`, `unexpected property`, `missing required field` — usually means the API moved past the skill. Fetch the OpenAPI (see **Consulting the shapes**), diff the live shape for that `kind`, and retry **once** with the correction. Tell the user it looks like the skill is out of date and worth updating through whatever channel they installed it from; don't loop on retries.

`columnId` is case-sensitive camelCase. `columnID`, `columnid`, and
`{id: <column>}` are not aliases for chart channels or pivot shelves. Run
`validate-spec.sh` / `wb-rep.rb lint` before POST; both reject these forms and
unknown local column pointers.

### 401 Unauthorized

Sigma OAuth tokens expire after ~1 hour. Long workbook-building sessions (orchestrated batch conversions, multi-step iterations, anything that runs >50 minutes) will hit this mid-flight.

**Ruby callers** (any of the `tableau-to-sigma/scripts/*.rb` Sigma-touching scripts): use the `Sigma` REST wrapper at `tableau-to-sigma/scripts/lib/sigma_rest.rb` — it does automatic 401-with-refresh-and-retry. Concretely:

```ruby
require_relative 'lib/sigma_rest'
spec = Sigma.request(:get, "/v2/workbooks/#{id}/spec")   # auto-refreshes on 401
```

**Bash / curl callers**: re-run the `sigma-api` skill's browser-first
`get-token.sh` to refresh manually. For long shell loops, wrap the curl in a
small helper that retries once on 401:

```bash
sigma_curl() {
  local resp code
  resp=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $SIGMA_API_TOKEN" "$@")
  code=$(echo "$resp" | tail -1)
  if [ "$code" = "401" ]; then
    eval "$(bash ../sigma-api/scripts/get-token.sh)"
    resp=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $SIGMA_API_TOKEN" "$@")
  fi
  echo "$resp" | sed '$d'  # strip trailing status code
}
```

If 401 persists after refresh, re-authenticate via `sigma-api`: rerun
`browser-login.sh` if the keychain refresh token was revoked, or verify
`SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, and `SIGMA_CLIENT_SECRET` for the
client-credentials fallback.

### 403 Forbidden on workbook create

The credentials authenticated but aren't permitted to create workbooks here. Ask the user's Sigma admin to confirm the credential's permissions and folder access.

### "Invalid column reference" or formula errors on creation

The most common spec issue. A bare `[column_name]` was used where `[TABLE/column_name]` is needed. See `reference/specification/formulas.md` for the full rules and `reference/workflows/validate.md` for the manual checklist.

### "Unknown column" errors

The column name in the formula doesn't match what the warehouse actually has. Re-confirm the column names via `GET /v2/connections/tables/{inodeId}/columns` (raw warehouse names) and the readback (`GET /v2/workbooks/<id>/spec`, which may preserve the raw spelling or show Sigma's canonicalized friendly form). Raw names are accepted authoring input; use the returned readback form for later edits.

### `jq` or `yq` not installed

`jq` is used for OpenAPI inspection (the OpenAPI is JSON). `yq` is used for workbook-spec inspection (specs are YAML).

- `jq`: `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu).
- `yq`: **two different tools share this name** — the Go **mikefarah/yq** (`brew install yq`) and the Python **`pip install yq`** wrapper around jq. *Reading* works the same in both (`yq -r '.workbookId' f.yaml`), but *in-place editing differs*: mikefarah uses `yq -i '…' f.yaml`, while the Python wrapper needs `yq -y -i '…' f.yaml`. Run `yq --help` to see which you have and adapt.

### Cryptic validation errors / silent bad data

See `reference/workflows/validate.md` for `document.elements[N]` and layout error triage.
