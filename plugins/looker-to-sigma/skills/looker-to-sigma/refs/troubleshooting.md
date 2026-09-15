<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. Troubleshooting — error/symptom -> cause -> fix. -->

# Troubleshooting

| Error / symptom | Cause | Fix |
|---|---|---|
| `convert_dm.mjs` output still has the old bug shape | Edited `src/lookml.ts` but the MCP server serves the deployed build | Run `convert_dm.mjs` via `node --import tsx/esm` against the patched `src/` (or restart the MCP server) |
| Converter dropped all view fields after an `html:` dim | Stale build predating BUG4 fix | Use the patched source path; the `;;`-block pre-extraction now includes `html`/`sql_on`/etc. |
| Metric formula contains `${...}` literals or `0 *` | Stale build predating BUG1/BUG3 fixes | Patched source resolves `${dim}`/`${measure}` refs and preserves `1.0` |
| `metric()` returns "Missing Metric" in a Sigma query | Known Sigma quirk | Verify via raw aggregate (`Sum`/`CountDistinct`), not `metric()` |
| `Source not found: warehouse table …` on DM POST | (a) connection catalog hasn't indexed the schema yet, OR (b) the LookML `sql_table_name` DB.SCHEMA differs from what the connection serves, OR (c) short connectionId | `post_dm.py` now AUTO-SYNCs the named schema (`POST /v2/connections/{id}/sync`) and retries once — (a) self-heals. For (b) pass `--source-swap FROM_DB.FROM_SCHEMA=TO_DB.TO_SCHEMA`. For (c) use the FULL connection UUID. Last resort: a Custom SQL DM element (`kind: "sql"`) |
| `jq: parse error: Invalid numeric literal` | Sigma spec endpoints return YAML | Never pipe spec responses to `jq` / `json.load` |
| `Invalid kind: "control"` on workbook POST | Control element missing its own `id` (separate from `controlId`) | Add a distinct `id` |
| KPI or donut POSTs 400 with `value.id` | Channel pointers now require `columnId` | KPI and donut/pie both use `value.columnId` (and donut `color.columnId`) |
| Tile shows the wrong chart kind | Read `element.type` (always `"vis"`) instead of `query.vis_config.type` | `fetch_looker_dashboard.py` already reads `vis_config.type` — re-fetch the contract |
| Looker LookML deploy fails "Invalid lookml syntax" | Compact `{ a: yes; b: yes; }` params | Use multi-line blocks; only `;;` terminates a `sql` |
| LookML model 404s on query right after deploy | Model not registered | `POST /lookml_models {name, project_name, allowed_db_connection_names}` |
| `PUT /projects/{id}` 404 when setting git remote | Wrong verb | Use `PATCH /projects/{id}` |
| Looker dev-workspace mutation has no effect | The calls ran in separate processes/sessions (the bearer cache is per-process; a 401 re-login also starts a NEW session that resets the workspace to production) | Do the whole dev flow in ONE process — `looker_api.py`'s cached token keeps one session, so `PATCH /session {workspace_id: dev}` sticks for subsequent `call()`s; re-PATCH after any forced re-login |
| Reused DM element builds via API but users can't select it as a source in the workbook UI | The element is `visibleAsSource: false` (hidden); the API doesn't enforce visibility on build | Wire to a visible sibling, or `PUT` the DM spec setting `visibleAsSource: true`. NB the flag defaults true and is **omitted when true** — only `"visibleAsSource": false` in the spec means hidden. Catch it in the Phase 2.5 shape preflight |
| Related-element column resolves as `type=error` | Referenced the raw warehouse/staging table name, or used the wrong layer's form | **Workbook** formula → `[<element>/<RelationshipName>/<col>]` (relationship name); **DM** calc → `[<TargetElementName>/<col>]` or `Lookup(…)`. Read the exact name from `relationships[].name` — never the table name (see 3b) |
| Reused relationship returns 2+ matches per row / inflated KPI & chart totals | The relationship key is incomplete (e.g. fact related to a dim on a non-unique attribute, or missing a 2nd key like Region) so it fans out — a non-unique target key multiplies fact rows silently (e.g. relating on a 5-value Region column vs a 4,972-row dim ≈ 994× inflation) | Relate on the dim's true primary key (or add the missing key to make the join 1:1) in the DM — manual. A single-key fan-out produces **wrong** aggregates with no error; flag it, don't ship |
| Tile filtered by `NOT NULL` returns zero rows | The token was emitted as a literal list member | Rebuild with the filter-expression normalizer; the Sigma filter must exclude JSON `null`, never match the text `"NOT NULL"` |
| Grouped-element relationship returns NULL, or grouped-element join times out | Observed unsafe Sigma plan for two pre-aggregated endpoints | `detect_modeling_hazards.py` blocks it; combine the grain and window logic in one Custom SQL element or record a proved-safe resolution |
| Rolling mean/stddev is a “window of one” | The element lacks a stable date grouping/sort or intended partition | Add explicit grain+ascending sort+partition; otherwise push the window into Custom SQL |
| API-driven fix overwrote a live UI edit | PUT was based on a stale workbook snapshot | Re-run with `--update-workbook`; reconcile the version/hash conflict. Use `--force-overwrite` only when deliberately discarding the remote edit |
