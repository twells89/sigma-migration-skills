<!--
Auto-generated from SKILL.md by tools/gen-agent-variants.rb.
Do not edit by hand — edit SKILL.md and re-run: ruby tools/gen-agent-variants.rb --all
-->

> Build, edit, and iterate on Sigma workbook specs — the JSON definition you POST to /v2/workbooks/spec, covering pages, layout, controls, charts, KPIs, tables, formulas, and sources. The Sigma OpenAPI is the source of truth for every shape and field; this skill adds navigation, style guidance, and proven recipes for effective dashboards. Use when the user wants to construct a dashboard from a spec, add or modify pages / elements / controls / formulas, validate a spec before submission, or work through the workbook spec lifecycle programmatically. Requires an SIGMA_API_TOKEN — obtain via the sigma-api skill first.

# Sigma Workbooks (Spec via REST API)

This skill helps you build effective Sigma workbooks by **navigating the Sigma OpenAPI** and applying **style guidance + proven recipes** beyond what the OpenAPI alone teaches.

## Scope

The workbook **spec** — the JSON you POST to `/v2/workbooks/spec` defining pages, elements, sources, formulas, and layout. Lifecycle around the workbook (embeds, grants, materialization schedules, bookmarks, sharing) is a separate API surface and out of scope here.

## Sources of truth

Sigma's public API docs are an index at `https://help.sigmacomputing.com/openapi.json` that lists two **canonical split specs** (split from one large spec to fix compilation / out-of-memory errors — so the structure changed subtly):

1. **`https://help.sigmacomputing.com/openapi/openapi/sigma-rest-api.json`** — the REST API: endpoint request/response shapes (workbooks, data models, members, connections, exports, materialization, …). Use for API *calls*.
2. **`https://help.sigmacomputing.com/openapi/openapi/code-representation.json`** — the "code representation" (as-code) spec. Today it documents the **data-model** spec (`/v2/dataModels/spec`); use it for data-model element shapes.

**Workbook element/control/format shapes** (the `bar-chart` / `kpi-chart` / `control` / format `kind`s that go under `/v2/workbooks/spec`) are **not inlined in either split spec** — get them from one of:

- **A live workbook readback** — `GET /v2/workbooks/{id}/spec` on the user's org. The durable, always-current source: read a real workbook and navigate `pages[].elements[]` by `kind`. **Prefer this.**
- **The full compiled OpenAPI** — one spec that *does* inline every workbook `kind`, served as a content-addressed Fern docs asset (the sanctioned reference for now):
  `https://files.buildwithfern.com/sigma.docs.buildwithfern.com/006ce360082503c7b849529b4c183cc4dc63360aff76038ca64669572c662b87/assets/openapi/sigma-computing-public-rest-api.json`
  Good for offline `jq` navigation. Caveats: it may **lag** the live API slightly (it's refreshed out-of-band — manually today, moving to an automated refresh + a dedicated reliably-hosted asset that will also back the CLI), and the hash pins a build so the path can change on a docs redeploy. So treat a **live workbook readback** (above) as the always-current source, and if this asset 404s, rediscover the current link from the Sigma API reference docs. (The retired `help.sigmacomputing.com/openapi/sigma-computing-public-rest-api.json` path now 404s.)

When this skill and the spec (or a live readback) disagree, the spec wins. When a feature isn't covered here, consult the spec / a live workbook and use what it documents.

## Consulting the shapes (compiled OpenAPI or a live readback)

**The field lists and examples in this skill are illustrative, not exhaustive** — when you need the complete, current shape of anything, query the full compiled spec (the Fern asset in *Sources of truth*) or a live workbook readback. Fetch the compiled spec once per session and inspect with `jq`:

```bash
curl -sf https://files.buildwithfern.com/sigma.docs.buildwithfern.com/006ce360082503c7b849529b4c183cc4dc63360aff76038ca64669572c662b87/assets/openapi/sigma-computing-public-rest-api.json > /tmp/sigma-api.json
# ^ content-addressed docs asset (see "Sources of truth"); if it 404s, use the current link from the Sigma API reference docs, or read a live workbook spec (GET /v2/workbooks/{id}/spec) and navigate pages[].elements[] by kind.

# The entire workbook spec request body lives under one path (it is not split into named schemas):
jq '.paths."/v2/workbooks/spec".post.requestBody.content."application/json".schema' /tmp/sigma-api.json
```

Element, source, control, and format shapes are **inlined** under that path and identified by their `kind` value (e.g. `bar-chart`, `kpi-chart`, `join`, `warehouse-table`) — not by a top-level schema name. Navigate by the `kind` discriminator:

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

**Or navigate a live workbook readback** (durable, when the compiled asset is unavailable) — same `kind` discriminator, just walk the elements directly:

```bash
curl -sf -H "Authorization: Bearer $SIGMA_API_TOKEN" "$SIGMA_BASE_URL/v2/workbooks/<id>/spec" > /tmp/wb.json
# list the kinds a real workbook uses; inspect one element's full shape:
jq -r '[.. | objects | select(.kind) | .kind] | unique[]' /tmp/wb.json
jq 'first(.. | objects | select(.kind=="bar-chart"))' /tmp/wb.json
```
(`wb-rep.rb capabilities --workbook <id>` does the same enumeration in pure Ruby — no `jq` needed.)

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

Authenticate via the `sigma-api` skill first to populate `$SIGMA_BASE_URL` and `$SIGMA_API_TOKEN`.

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

If the user provided a **target image** (a screenshot, mockup, or PDF of a dashboard they want reproduced), pause here and load `reference/workflows/from-image.md` — it adds explicit observation, description, and validation steps that have to happen *before* normal data discovery. The standard workflow alone tends to produce workbooks with the right vibe but the wrong shape when the input is visual.

### Step 1 — Find a reference workbook to study

Any existing workbook on the user's org doubles as a template. List and pick one with similar content:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/workbooks?limit=50" | jq '.entries[] | {workbookId, name}'
```

If no relevant workbook exists, pick any — the goal is studying spec structure, not matching content. If the org has no workbooks at all, draft from scratch using the OpenAPI shapes + this skill's recipes.

### Step 2 — Study the reference spec

YAML is the canonical format for workbook specs in this skill — easier to read, diff, and review than JSON. Sigma's API accepts both (`Content-Type: application/yaml` or `application/json`); `Accept: application/yaml` is the default on `GET /v2/workbooks/<id>/spec`. Use `yq` to inspect spec YAML the same way you'd use `jq` on JSON.

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/workbooks/<reference-workbook-id>/spec" \
  > /tmp/reference-spec.yaml
```

Look at source structure, column ID patterns, formula syntax, element naming, layout XML idioms. The `pages` array shape is exactly what you'll POST when creating.

### Step 3 — Discover data sources

Load `reference/workflows/discover.md`. Quick summary:

1. `GET /v2/connections` — find the user's connection by name or type.
2. Ask the user for the table path; verify with `POST /v2/connection/<id>/lookup`.
3. Discover columns directly via `GET /v2/connections/tables/{inodeId}/columns` (full mechanics in `reference/workflows/discover.md`). Only fall back to asking the user when the endpoint doesn't return what's needed.

**Never invent column names** — only use names returned by the API or supplied by the user.

**Verify literal values before writing predicates.** If your task involves filtering on a categorical column (e.g., `CountIf([Status] = "active")`, `If([Type] = "sale", ...)`), you need to know what values that column *actually* contains — the `/v2/connections/tables/{inodeId}/columns` endpoint gives you names and types but not values. Run a `SELECT DISTINCT <col>` via any tool that reaches the warehouse — an MCP server (warehouse or [Sigma](https://help.sigmacomputing.com/docs/use-sigma-mcp-server)), a SQL CLI, or just ask the user. Don't guess literals. See `reference/workflows/discover.md`.

### Step 4 — Identify features and load only what you need

Map the user's request to the **Reference Index** below. State the features you identified, then read the listed reference files before drafting. **If the user asks for a feature this skill doesn't cover**, fetch the OpenAPI and inspect the relevant schema.

### Step 5 — Draft the spec to a local file

Write the spec YAML to disk (e.g., `/tmp/workbook-spec.yaml`). YAML is preferred over JSON in this skill — easier to read, diff, and comment for human review. The API accepts either; pick YAML unless something downstream specifically needs JSON. Key rules:

- Every element needs a unique `id` and a descriptive `name`.
- Every column needs a unique `id`, a `name`, and a `formula`.
- Follow the formula reference rules in `reference/specification/formulas.md` exactly — most spec errors happen here.
- **Write explicit `layout` XML for multi-element workbooks.** Auto-arrange (omitting `layout`) is acceptable only for single-element pages or a uniform stack of tables. See `reference/specification/layout.md` for the rubric.
- Start with 1–2 pages. Add more later via update.

For **create**, the file must include top-level `name`, `folderId`, `schemaVersion`, and `pages`. `description` is optional. `layout` is technically optional but expected for multi-element workbooks. `schemaVersion` is usually `1` — that's the current value; it may change in the future, so if the API rejects the spec on that field, check what your reference-workbook GET in Step 2 returned and use that instead. Full CRUD mechanics are in `reference/workflows/crud.md`.

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

If creation fails, read the error, fix the spec, re-validate, retry. See `reference/workflows/validate.md` for decoding cryptic errors.

### Step 7b — Verify the workbook actually compiles

**Do not skip.** A successful POST is necessary but not sufficient — Sigma accepts specs whose formulas don't resolve, then surfaces the failures at query time by embedding the error as a string literal in the compiled SQL (`'Unknown column "[X]"'`, `'Circular column reference to [Y]'`). Affected elements render empty in the UI. Only Sigma's compiler knows whether your formula references actually resolve.

```bash
./scripts/verify-workbook.sh "$WORKBOOK_ID"
```

If any element reports `[FAIL]`, fix the column formulas in the spec (most often a missing source prefix, a self-referencing column, or a friendly-name mismatch with the warehouse — see `reference/specification/formulas.md`), `PUT` the corrected spec, and re-verify.

### Step 8 — Iterate

After initial creation, use `PUT /v2/workbooks/<id>/spec` to add pages or refine the workbook.

**For anything beyond ~1 page / ~10 elements, switch to the element rep** (`reference/workflows/element-rep.md`): `scripts/wb-rep.rb pull <id> <dir>` explodes the spec into one file per element so each edit touches a ~½KB file instead of the whole spec, `push` handles drift-check + validation + PUT, and `render` exports page PNGs you can actually look at. The raw GET/PUT flow below remains fine for small workbooks and one-off tweaks.

> **IDs are preserved on CREATE.** The `id` values you POST (pages, elements, columns) are kept verbatim, and `layout` `elementId` references stay valid — so you can edit your saved spec and `PUT` it back directly. `GET` the current spec first only if you don't have your latest copy. See `reference/workflows/crud.md`.

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/workbooks/<workbook-id>/spec" \
  > /tmp/current-spec.yaml

# Edit /tmp/current-spec.yaml, then:
curl -s -X PUT -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/yaml" \
  -H "Accept: application/yaml" \
  --data-binary @/tmp/current-spec.yaml \
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
| `reference/specification/tables.md` | Table element, tabular data, data grid, spreadsheet-style list. Also element-level filters (top N, limit, rank), groupings (pivot, group by), the `pivot-table` and editable `input-table` element kinds, and `conditionalFormats` (threshold-based cell coloring, on pivot/input tables). |
| `reference/specification/charts.md` | Chart, graph, visualization, line / bar / column / stacked / grouped / combo / donut / pie / scatter / share-of / breakdown. Cartesian axes, color channel, trellis, trendlines, reference marks. |
| `reference/specification/maps.md` | Map visualizations — `geography-map` (GeoJSON shapes), `point-map` (lat/long bubbles), `region-map` (states / counties / countries). |
| `reference/specification/kpis.md` | KPI, stat, big number, single value, metric card — layout / value styling, and the spec limits of the trend-sparkline block (still UI-bound). Comparative KPIs (a Δ badge vs. a prior/target column) are the house default — see the dedicated row below. |
| `refs/kpi-comparison.md` + `examples/comparative-kpi-card.yaml` | Comparative KPI card, delta badge, vs.-prior / vs.-target number. The verified, readback-stable `comparisonColumn` + `comparison:{display:"delta"}` shape, its gotchas, the `KpiCard.build`/`kpi_card.build` emitter that produces it, and a clone-able spec fragment. |
| `reference/specification/controls.md` | Filter, dropdown, picker, multi-select, date range, date picker, text filter, number range, slider, segmented, hierarchy. |
| `reference/specification/content-elements.md` | The non-data elements — `text` (Markdown + inline styling), `image`, `divider`, `embed` (external URLs). Titles, callouts, logos, rules, embedded content. |
| `reference/specification/input-tables.md` | Operational supplement for `input-table` (spec shape lives in `tables.md`): write-connection requirement, the publish gate, reading data back via warehouse views, element endpoints for auditing, and migration patterns (Excel/planning models). |
| `reference/specification/styling.md` | **Load when building a dashboard from scratch.** Design recipe library — vetted color palette, hero header strip, KPI card row, section headers, divider rhythm, categorical chart colors. Turns a default-arrange workbook into a designed-looking one without UI editing. |

### Sources

| File | When to load |
|------|--------------|
| `reference/specification/sources-warehouse.md` | Always — load before drafting any spec. Warehouse-table source (Snowflake, BigQuery, Databricks, Redshift, Postgres/MySQL). |
| `reference/specification/sources.md` | Reference another chart/table/element, derive from existing element, join, combine tables, data model / semantic-layer source, custom SQL, union, transpose, unpivot. |

### Cross-cutting

| File | When to load |
|------|--------------|
| `reference/specification/schema.md` | Always — load before drafting any spec. Top-level shape, required fields, response-only fields to strip. |
| `reference/specification/formulas.md` | Always — load before drafting any spec. Formula syntax, qualification, special characters, the #1 mistake. |
| `reference/specification/formatting.md` | Format, currency, percentage, date format, decimals — column formatting. |
| `reference/specification/layout.md` | **Always load for multi-element workbooks.** Layout XML, GridContainer/LayoutElement, container elements, page visibility / background, auto-arrange fallback rules, when to write explicit layout vs. omit. |
| `reference/specification/example-full.yaml` | A real multi-page reference spec (KPIs, charts, joins, controls, layout) — copy shapes from when in doubt. |

### Workflows

| File | When to load |
|------|--------------|
| `reference/workflows/discover.md` | Finding connections, tables, and column names. Load before composing a new spec. |
| `reference/workflows/composition.md` | Open-ended design decisions — calibrating workbook complexity to the request, when to ask the user, what to ask, surfacing structural choices in the final summary, and three opinionated layout patterns (`exec` KPI-strip dashboards, `master-detail` pick-one-see-its-detail, optional `overview` KPI/trend/pivot stack) backed by `shared/lib/composition.rb` — plus an optional, independently-selectable richness menu (comparative KPI cards, AI-insight callout, grain/filter controls, wide pivot) backed by `shared/lib/kpi_card.rb` and `shared/lib/richness.rb`. Load before drafting anything when the prompt leaves significant design choices unmade. |
| `reference/workflows/crud.md` | POST / GET / PUT against the workbook spec endpoints. Load when creating, retrieving, or updating a workbook. |
| `reference/workflows/validate.md` | Pre-submit + post-create validation. Load before any POST or PUT. |
| `reference/workflows/from-image.md` | The user supplied a target image (screenshot, mockup, BI-tool export) to reproduce. Load *before* discovery — it adds explicit observation and validation steps. |
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

## Troubleshooting

### "I don't see this field in the skill"

Fetch the OpenAPI. The skill documents stable, common surface area; the API has more. See **Consulting the OpenAPI** above.

### API schema mismatch (skill is stale)

A 400 about request *shape* — `invalid argument`, `unknown field`, `unexpected property`, `missing required field` — usually means the API moved past the skill. Fetch the OpenAPI (see **Consulting the OpenAPI**), diff the live shape for that `kind`, and retry **once** with the correction. Tell the user it looks like the skill is out of date and worth updating through whatever channel they installed it from; don't loop on retries.

### 401 Unauthorized

Sigma OAuth tokens expire after ~1 hour. Long workbook-building sessions (orchestrated batch conversions, multi-step iterations, anything that runs >50 minutes) will hit this mid-flight.

**Ruby callers** (any of the `tableau-to-sigma/scripts/*.rb` Sigma-touching scripts): use the `Sigma` REST wrapper at `tableau-to-sigma/scripts/lib/sigma_rest.rb` — it does automatic 401-with-refresh-and-retry. Concretely:

```ruby
require_relative 'lib/sigma_rest'
spec = Sigma.request(:get, "/v2/workbooks/#{id}/spec")   # auto-refreshes on 401
```

**Bash / curl callers**: re-run `eval "$(scripts/get-token.sh)"` to refresh manually. For long shell loops, wrap the curl in a small helper that retries once on 401:

```bash
sigma_curl() {
  local resp code
  resp=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $SIGMA_API_TOKEN" "$@")
  code=$(echo "$resp" | tail -1)
  if [ "$code" = "401" ]; then
    eval "$(scripts/get-token.sh)"
    resp=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $SIGMA_API_TOKEN" "$@")
  fi
  echo "$resp" | sed '$d'  # strip trailing status code
}
```

If 401 persists after refresh, re-authenticate via `sigma-api` and verify `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, `SIGMA_CLIENT_SECRET`.

### 403 Forbidden on workbook create

The credentials authenticated but aren't permitted to create workbooks here. Ask the user's Sigma admin to confirm the credential's permissions and folder access.

### "Invalid column reference" or formula errors on creation

The most common spec issue. A bare `[column_name]` was used where `[TABLE/column_name]` is needed. See `reference/specification/formulas.md` for the full rules and `reference/workflows/validate.md` for the manual checklist.

### "Unknown column" errors

The column name in the formula doesn't match what the warehouse actually has. Re-confirm the column names via `GET /v2/connections/tables/{inodeId}/columns` (raw warehouse names) and the readback (`GET /v2/workbooks/<id>/spec`, which shows Sigma's normalized friendly names). Use those names verbatim.

### `jq` or `yq` not installed

`jq` is used for OpenAPI inspection (the OpenAPI is JSON). `yq` is used for workbook-spec inspection (specs are YAML).

- `jq`: `brew install jq` (macOS) or `apt install jq` (Debian/Ubuntu).
- `yq`: **two different tools share this name** — the Go **mikefarah/yq** (`brew install yq`) and the Python **`pip install yq`** wrapper around jq. *Reading* works the same in both (`yq -r '.workbookId' f.yaml`), but *in-place editing differs*: mikefarah uses `yq -i '…' f.yaml`, while the Python wrapper needs `yq -y -i '…' f.yaml`. Run `yq --help` to see which you have and adapt.

### Cryptic validation errors / silent bad data

See `reference/workflows/validate.md` for the full triage table (mapping `Invalid kind: pages[0].elements[N]...` style errors to the right spec file).
