---
name: sigma-data-models
description: >-
  Author, retrieve, or modify a Sigma data model spec (the JSON/YAML
  semantic-layer definition with sources, columns, metrics, relationships,
  filters, controls, folder groupings, and column-level security) by calling
  the Sigma REST API directly. Use when the user wants to build a new data
  model from existing warehouse tables, add metrics or relationships to an
  existing model, change a model's source, edit columns, or round-trip a
  data model spec through code. **Out of scope: converting from another BI
  tool's format (dbt, LookML, Tableau, Power BI, Alteryx, etc.).** Those
  conversions are handled by the Sigma data-model converter (browser tool +
  MCP) — point users there when they paste source-format input.
  Requires an SIGMA_API_TOKEN — obtain via the sigma-api skill first.
---

# Sigma Data Models (Author / Get / Update)

Build a Sigma data model spec — the JSON definition of pages, sources, columns, metrics, relationships, filters, controls, folder groupings, and column-level security — and round-trip it through the Sigma REST API.

This skill is for **authoring from existing warehouse tables**: a user knows their warehouse, wants to expose specific tables as a Sigma data model with the right joins, metrics, and governance, and needs help composing the spec. Conversions from other BI-tool formats (dbt schema.yml, LookML views, Tableau TDS, Power BI PBIT, Alteryx YXMD, etc.) are **not in this skill** — direct users to the Sigma data-model converter MCP / browser tool, which already handles those mappings.

**Auth:** Authenticate via the `sigma-api` skill first to set `$SIGMA_BASE_URL` and `$SIGMA_API_TOKEN`. This skill assumes both are already exported.

**Requirements:** `curl`, `jq`, `base64`. Your Sigma API credentials must have permission to create or edit data models, plus "Can edit" access on the destination folder (for create) or the existing data model (for update). If a request returns 403, ask your Sigma admin to confirm the credential's permissions.

## Reference Index

Feature-specific JSON patterns live in `reference/`. Load each file when you identify the corresponding feature in the user's request — don't read every file up-front.

| File | When to load |
|------|--------------|
| `reference/columns.md` | Calculated columns, formula columns, derived columns; **renaming a column, changing a formula**, warehouse-column ID conventions, column reference rules. |
| `reference/metrics.md` | Metrics, aggregate measures, metric timelines, time-series / trend metrics; **adding a metric to an existing table or changing aggregation**. |
| `reference/relationships.md` | Relationships, foreign-key linking, related tables, cross-table lookups; **adding a relationship between an existing element and a new one** (mixed-ID rule — see `workflows/crud.md`). |
| `reference/sources.md` | Custom SQL sources, join sources, union sources, transpose sources; **swapping a model's source kind** on an existing model. |
| `reference/filters.md` | Row filters, where clauses, date range filters, top-N; **adding/removing a filter on an existing model**. |
| `reference/folders-groupings.md` | Folders, column groupings, column ordering, sort, organize columns; **reordering existing columns**. |
| `reference/column-level-security.md` | Column-level security (CLS), data masking, restrict columns by team / user attribute; **applying CLS to an existing column**. |
| `reference/controls.md` | List/dropdown, text input, text area, number input, number range, date, date range, slider, range slider, segmented, switch, checkbox, top-N controls; **adding a control to an existing page**. |
| `reference/formatting.md` | Column or metric formatting — currency, percentage, date format, decimals, datetime; **reformatting a column or metric on an existing model**. |
| `reference/calc-columns.md` | Calculated / derived / formula columns on a DM element. Covers shape, formula references, and the **window-function silent-error gotcha** (`CountOver`/`SumOver` etc. fail in DM element calc cols → workarounds). |

## Workflows Index

| File | When to load |
|------|--------------|
| `reference/workflows/discover.md` | **Read first when starting a new model.** Find the user's connection, resolve a table path → inodeId, list columns. Without this, you'll guess column names and the spec will fail. |
| `reference/workflows/authoring.md` | Composition judgment calls — one big model vs many small, SQL source vs warehouse-table, joins in the model vs in workbooks, naming conventions, where to put metrics, folder placement, when to materialize. |
| `reference/workflows/crud.md` | `POST` / `GET` / `PUT` against `/v2/dataModels` endpoints. Always load before any API call. Contains the ID-semantics contrast (CREATE remap vs GET source-of-truth vs UPDATE preserve), full step-by-step recipes, and the mixed-ID rule for relationships in updates. |
| `reference/workflows/validate.md` | Pre-submit checklist + decoding common errors (400 / 403 / 409) + the "pull a known-working model and diff" pattern when guessing isn't working. |

## ID Conventions

Cross-cutting rules. Per-workflow ID semantics (remap vs preserve vs mixed cross-references) live in `reference/workflows/crud.md`.

- Short alphanumeric IDs for generated entities: `"page-1"`, `"table-orders"`, `"col-revenue"`.
- Warehouse column IDs follow `"inode-<tableId>/<COLUMN_NAME>"` — use `"<YOUR_TABLE_INODE>/<COL_NAME>"` as a placeholder.
- Control `id` is the element ID; `controlId` is the formula reference name — keep them distinct.

## Unsupported Features

Call out any of these before presenting the final spec:

- Multiple tables with identical names in the same data model
- Input tables, Python elements, and UI elements
- Referencing Sigma elements in custom SQL
- Partial updates — the create and update endpoints both require the full representation
- The `*Over` window functions (`CountOver` / `SumOver` / `RowNumberOver` / `RankOver` / …) — invalid as a spec formula (a DM-spec POST 400s; workbook calc columns error `Unknown function`). The Sigma-**native** window family (`CumulativeSum` / `MovingAvg` / `Rank` / `RowNumber` / `Lag` / `Lead` / `PercentOfTotal`) DOES resolve in DM-element and workbook calc columns — use those. See `reference/calc-columns.md`.
- `IsIn(...)` in any formula — Sigma's formula language has no such function. Use chained `or` conditions instead. (See the `sigma-workbooks` skill's `formulas.md` for the full function reference.)

## Cross-Skill References

- **Building a workbook on top of this model** → load the `sigma-workbooks` skill. Its `sources.md` documents the `{ "kind": "data-model", "dataModelId": "...", "elementId": "..." }` source shape.
- **Repointing existing workbooks to a newly-created model** → see `sigma-workbooks/reference/workflows/crud.md` and the swap-sources endpoint.
- **Auth, base URLs, regions, token refresh** → always defer to the `sigma-api` skill rather than restating. For automatic 401-retry-with-refresh in Ruby long-running scripts (DM-build loops that outlive the 1-hour token TTL), see `sigma-workbooks/SKILL.md` "401 Unauthorized" — same pattern applies here.

## Out of Scope (use a different tool)

- **Converting from dbt / LookML / Tableau / Power BI / Alteryx / Snowflake semantic views** → the Sigma data-model converter (browser tool at `~/sigma-skills/.../sigma-data-model-manager` and the `sigma-data-model` MCP) handles these. Don't re-implement converter logic in this skill.
- **Tableau-to-Sigma full pipeline** (datasource + workbook + repoint) → use the `tableau-to-sigma` skill.
