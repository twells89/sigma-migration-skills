<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. Phase 2 — LookML -> Sigma data model: convert, coverage, DM reuse, POST, verify. -->

# Phase 2 — Convert the LookML semantic model

LookML views + model → Sigma data model. Resolve the explore's join graph, convert, POST,
**register the model**, and verify.

### 2a. Convert — local by default, MCP only as a manual fallback

Feed it the **LookML model**, NOT the warehouse tables — the converter walks the explore's
`join`s to resolve `view.field` prefixes (alias vs `from:` view) and emits one element per
resolved view plus a denormalized explore element.

**Default: the converter runs locally, in-process, no MCP, no data egress.** The skill ships a
self-contained vendored bundle at `converter/lookml.mjs`; `migrate-looker.py` (and
`scripts/convert_dm.mjs` directly) run it via a `node` shim — no clone, no `npm install`, no
network call, and your LookML never leaves the machine:

```bash
LOOKML_DIR=/path/to/lookml \
  node --import tsx/esm scripts/convert_dm.mjs <exploreName> /tmp/<name>/dm-spec.json
```

`convert_dm.mjs` reads `<model>.model.lkml` + every `views/*.view.lkml`, converts the explore
with `joinStrategy: 'relationships'`, and writes `res.model` (the return property is `.model`,
**not** `.sigmaDataModel`). It prints stats + warnings — **read every warning.**

A dev's own checkout wins automatically when present: `migrate-looker.py` first checks
`CONVERTER_SRC` (a `src/lookml.ts` + `tsx`, for fixed output against a patched source tree —
see the build gotcha below) or `CONVERTER_PATH` (a built `build/lookml.js`), resolved from
`~/sigma-data-model-mcp` or `~/Desktop/sigma-data-model-mcp` (`CONVERTER_HOMES`) if set. The
vendored `converter/lookml.mjs` bundle is the guaranteed floor underneath both — it is what runs
out of the box with nothing configured.

**Fallback only — no local converter and no `node`:** `migrate-looker.py` writes
`convert-request.json` (the exact `mcp__sigma-data-model__convert_lookml_to_sigma(files,
connectionId, exploreName, joinStrategy)` arguments) and **exits 3**. Call the MCP tool by hand
with those arguments, save its JSON output to `<workdir>/converted.json`, and resume with
`--converted <workdir>/converted.json`. Reach for this only when the vendored bundle is missing —
routing through the hosted MCP by default means your LookML leaves the machine and you're at the
mercy of whatever converter version the MCP happens to be running (version drift vs the vendored
bundle / a patched source tree).

> **Converter-build gotcha (only relevant when using `CONVERTER_SRC`).** The long-running MCP
> server serves the **deployed** build. After editing `src/lookml.ts` + `npm run build`, the
> running MCP tool still serves the OLD code until it restarts — another reason the local
> `CONVERTER_SRC`/vendored-bundle path is preferred over calling the MCP tool.

### 2b. Converter coverage (all live-validated 2026-06-10) — and what's still lossy

The converter handles, end-to-end and clean:
- **Dimensions** — `tier`, sql `CASE`, legacy `case:` (→ nested `If()`), `html`/`link`, custom
  `value_format`.
- **Time + duration `dimension_group`** — one column per timeframe (`DateTrunc`); duration groups
  emit `sql_start`/`sql_end` physical columns.
- **Measures** — `sum`/`count`/`count_distinct`/`avg`/`median`/`percentile`/filtered/**ratio**.
  Measure `${dimension}` refs and measure-references-measure `${measure}` (ratio) refs resolve to
  the right Sigma formula; `1.0` literals preserved; `NULLIF` → `NullIf`.
- **Joins** — snowflake (multi-hop) joins wire the FK to the correct intermediate element (not
  always the base); `full_outer` + field-limited joins; `sql_always_where` / `always_filter`.
- **Composite join keys** — a `sql_on` that ANDs several `${a.b} = ${c.d}` pairs becomes ONE
  relationship carrying every key pair; Liquid `{% condition %}` is stripped first; literal
  predicates (`${view.col} = 5`) are reported, not dropped.
- **Unique keys / table grain** — `primary_key: yes` → element `uniqueKeys` (what semantic
  aggregates uses to track grain; inert without the beta, so always safe to emit). A view with
  no `primary_key` warns. `sql_distinct_key` is deliberately NOT mapped there — see
  `refs/lookml-remodeling.md`, "Diagnosing where fan-out actually lives".
- **Other** — `derived_table`, `parameter` + Liquid, `drill_fields`, `set`, view/group labels,
  multiple explores per model.

These 8 converter bugs were found and **FIXED in source** (branch
`tj/lookml-robustness-ratio-percentile-html-fixes`); treat them as **handled**, but know the
shapes so you recognize a regression:

| # | Bug (now fixed) | What it produced before the fix |
|---|---|---|
| BUG1 | measure `${dimension}` refs unresolved | literal `Sum([${sale price}])` + phantom `${...}` columns |
| BUG2 | multi-hop (snowflake) joins mis-wired | FK hung off the base element instead of the intermediate |
| BUG3 | ratio measures (`${measure}`, `1.0`→`0`) | phantom column + `0 * ${...}` formula |
| BUG4 | `html:`/Liquid `%}` desynced the block parser | silently dropped ALL view fields after the html dimension |
| BUG5 | `percentile` → bogus `CountIf` | wrong aggregation |
| BUG6 | filtered `type:count` with no sql | bogus phantom value column |
| BUG7 | `type:duration` dimension_group | dangling `DateDiff` (no sql_start/sql_end) |
| BUG8 | legacy `case:{when/else}` dim | passthrough to a nonexistent column |

> If the running MCP build predates these fixes, use the `convert_dm.mjs` direct path (2a)
> against a patched source tree, OR repair the spec post-hoc — but the source fixes mean **raw
> converter output now POSTs clean with no in-spec workarounds**.

**Still lossy / unsupported (documented, warned — never silent):**
- **Liquid parameters** — deterministic finite-enum dimension branches convert
  to workbook-local controls; nested/multi-parameter branches, parameterized
  measures, and manifest constants remain a gated static-default/manual review.
- **`link:` / `html:` styling** — dropped (data is fine; the styling/hyperlink is lost).
- **Pivot cross-tab** → flattened to columns + warn (rebuild as a Sigma `pivot-table` in the UI).
- **Table-calc grain/sort** for window functions (rank / offset / percentile) → review.
- **`merged_results`** → a DM join or a Custom SQL element (follow `merge_result_id` to the
  source queries; >2 sources or non-equi joins → manual + warn).
- **`many_to_many`** → mapped to the closest Sigma type (`N:1`) with a warning to verify
  cardinality and introduce a bridge/junction table where the join can fan out on both
  sides. Sigma has no native M:N relationship.
- **RLS (`access_filter` / `sql_always_where` / `access_grant`)** — detected at discovery
  (Phase 1d) and decided ONCE at the Phase 1.5 gate, then ported via the scripted, API-driven
  `apply_sigma_rls.py` (reuse-first user-attribute lookup → create/assign → PATCH the
  `CurrentUserAttributeText("<attr>") = [<Field>]` row filter). The converter also emits an
  `access_filter` RLS note + `CurrentUserAttributeText()` stub. Never silently dropped — the
  outcome is recorded.

> **`metric()` returns "Missing Metric" in MCP SQL** — a known Sigma quirk, not a conversion
> bug. Verify metric values via the **raw aggregate** (`Sum(...)`, `CountDistinct(...)`), not via
> `metric()`.

### Phase 2.5 — Reuse an existing DM? (run BEFORE 2c — avoid sprawl; the reuse-first DM gate every converter runs before building)

Before POSTing a NEW data model, check whether an existing Sigma DM already covers the
same warehouse tables (don't add a 4th near-identical "Orders" DM):

```bash
python3 scripts/lookml-dm-signature.py --lookml-dir /path/to/lookml \
  --label "<explore label>" --out /tmp/<name>/dm-signature.json
bash -c 'eval "$(scripts/get-token.sh)" && \
  ruby scripts/find-or-pick-dm.rb --workbook-signature /tmp/<name>/dm-signature.json \
    --out /tmp/<name>/dm-match.json --auto-pick'     # exit 0 = candidate ≥ min-score
```

`lookml-dm-signature.py` derives `{warehouse_tables (sql_table_name FQNs),
referenced_columns (dimension/measure names), measures}` straight from the LookML view
files — the same files you fed `convert_dm.mjs`. Decision:
- **Score ≥ 0.6** → **ASK the user** reuse-vs-new: surface the candidate name, matched
  cols (N/M), and the inherited-extras warning from `dm-match.json`. If they reuse, run the
  **shape preflight** first — `ruby scripts/shape-preflight.rb --dm-id <id> --element "<element
  you'll wire to>" --needed-columns "<dashboard cols>" --out /tmp/<name>/shape-preflight.json`
  (exit 2 = unsafe). It mechanically confirms:
  1. every column the dashboards reference resolves on the element you'll wire to (no
     `type=error` columns; fact vs separate-dim location);
  2. **the element is usable as a source** — i.e. it is NOT `visibleAsSource: false`. The
     flag **defaults to `true` and is omitted from the spec when true**, so absence = visible
     and you only act when you literally see `"visibleAsSource": false`. A hidden element
     builds fine via the API but **users can't pick it as a source in the workbook UI** —
     wire to a visible sibling, or `PUT` the DM spec setting `visibleAsSource: true`, before
     proceeding (verified live 2026-06-29);
  3. **how related columns are exposed** — if the columns you need live on a *separate*
     element reached by a `relationships[]` entry (a reused relational DM, NOT a flat denorm
     element), note the relationship's exact `name`; Phase 3 will reference them as
     `[<element>/<RelationshipName>/<col>]` (see 3b). Confirm the join is 1:1 on its key — a
     non-unique target key silently fans out (see the fan-out troubleshooting row).

  Then **skip 2c/2d** and point Phase 3's workbook masters at the matched
  `recommended_dm_id` + its element ids. With `--auto-pick` a clear winner (no tie within
  0.05) skips the prompt — still WARN about inherited columns/RLS/metrics.
- **Score < 0.6** → POST new (2c) and TELL the user no reusable DM was found.

### 2c. POST the data model

```bash
bash -c 'eval "$(scripts/get-token.sh)" && \
  SIGMA_CONNECTION_ID=<full-connection-uuid> \
  python3 scripts/post_dm.py /tmp/<name>/dm-spec.json'
```

- Endpoint is `POST /v2/dataModels/spec` (NOT `/v2/workbooks/spec`).
- **Use the FULL connection UUID** (e.g. `ab12cd34-5678-40ab-8def-1234567890ab`), not a short
  prefix — `convert_dm.mjs` writes a placeholder `connectionId`; `post_dm.py` swaps in
  `$SIGMA_CONNECTION_ID`.
- **`folderId` is required** — `post_dm.py` auto-picks a writable folder (preferring one whose
  name mentions LOOKER/MIGRATION/TEST).
- **The spec endpoints return YAML** (`success: true\nworkbookId: …`), not JSON — never
  `json.load` the response or pipe it to `jq`.

Record the returned `dataModelId` and (after a read-back) the element IDs.

### 2d. Register the model + verify

> A freshly POSTed/deployed LookML model **404s on query until you register it** (Looker side
> for the Looker model; this is the deploy flow for standing up a test instance):
>
> ```
> PATCH /session {workspace_id: dev}
> PUT  /projects/{id}/git_branch {name: <dev-branch>, ref: origin/main}   # pull pushed commits into dev
> POST /projects/{id}/validate                                            # expect 0 errors
> POST /projects/{id}/deploy_to_production                                # 204
> POST /lookml_models {name, project_name, allowed_db_connection_names:[<conn>]}
> ```
>
> LookML param gotcha: params are **not** semicolon-separated — compact
> `{ primary_key: yes; hidden: yes; sql: ... ;; }` fails ("Invalid lookml syntax") and cascades
> into bogus join/field errors. Use multi-line blocks (only `;;` terminates a `sql`).
> A refinement `view: +x` in a glob-included file fails ("Could not find a view to extend") —
> fold the param/measure into the base view.

**Verify the Sigma DM:** `mcp__sigma-mcp-v2__describe` the element (no `type=error` columns;
metric formulas resolve clean), then `mcp__sigma-mcp-v2__query` a raw aggregate and confirm it
matches the warehouse.
