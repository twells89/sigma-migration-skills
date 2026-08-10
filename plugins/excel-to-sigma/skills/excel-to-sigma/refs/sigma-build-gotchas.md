# Sigma build gotchas (data model + workbook spec)

Hard-won rules from building the forecast DM + input-table workbook. These are the
difference between a 2xx that errors at query time and a working migration. Many
overlap with the other sigma-migration-skills converters — collected here for the
Excel path.

## Data model spec (`POST /v2/dataModels/spec`)

- **Envelope:** top-level `schemaVersion: 1`, real-UUID `folderId`, `pages[]` with
  `id` + `name` + `elements[]`. Each element: `kind: table` (NOT `type`), a
  `source`, and `columns[]`.
- **SQL element source:** `source: { kind: sql, connectionId, statement }`.
- **SQL-element column formulas use the literal `[Custom SQL/ALIAS]` prefix** —
  NOT `[ElementName/ALIAS]`. The DM spec-resource doc claims element-name; the API
  rejects it. `ALIAS` is the column alias in your `SELECT`.
  ```json
  { "id": "fc6", "formula": "[Custom SQL/FORECAST_AMOUNT]", "name": "Forecast Amount" }
  ```
- **Element `name` is NOT honored** — every element reads back as "Custom SQL".
  Don't rely on it; identify elements by their columns.
- **Element + column IDs are REASSIGNED on POST.** The ids you send are mapped to
  internal ids. Before querying or doing any follow-up PUT, `describe` the live
  model (Sigma MCP `describe` type `datamodel` then `datamodel-element`) and use
  the readback ids.
- **Grouping trap:** to let a chart/pivot group by a dimension from another
  element, emit a **flattened in-SQL join element** (a `WITH … SELECT … JOIN`),
  NOT cross-element relationship refs — otherwise "Rollup cannot reference more
  than one external relation."

## Workbook spec (`POST /v2/workbooks/spec`) — released document wrapper

> **Live-verified 2026-08:** the workbook code-rep surface nests non-metadata
> fields under a top-level `document` key and rejects the old flat body with
> HTTP 400 (including `/verify`). Same adapter every sibling converter uses
> (`scripts/lib/code_rep.py`, vendored from `shared/lib/code_rep.py`).
> **Data-model specs are unchanged** — do NOT wrap `/v2/dataModels/.../spec`.

- **Wire body for create:** top-level `name` + `folderId` (+ optional
  `description`) outside; inside `document`: `schemaVersion`, `kind: workbook`,
  metadata-only `pages[]`, flat `elements[]`, and required `layout` XML.
- Builders may still author the convenient nested `pages[].elements` draft.
  Call `workbook_wire.wire_workbook(spec)` (which builds a stacked layout if
  missing, then `code_rep.wrap`) **as the last write before POST**. Dry-run
  artifacts that would be POSTed must be the wrapped shape too.
- **Every page needs a string `id`** (POST fails with `each page must have a
  string "id"` otherwise). Page membership lives in `document.layout`
  (`<Page id="…"><Element elementId="…"/></Page>`), not in nested
  `pages[].elements` after wrap.
- Prefer `<Element>` / `<Container>` tags — `code_rep.wrap` rewrites legacy
  `<LayoutElement>` / `<GridContainer>` aliases.
- Theme (if any) goes in `document.settings.theme.{name,overrides}` via
  `code_rep.set_theme` — never top-level `themeName` / `themeOverrides`.
- Every element needs a unique `id`; columns need `id` + `name` + `formula`.
- Send `Content-Type: application/json` (or yaml). Specs round-trip as YAML on GET.
- On readback, unwrap with `code_rep.document(resp)` / `code_rep.workbook_elements`
  — never dig `pages[].elements` on a live GET.
- **Input-table specifics** live in `refs/input-tables.md` (write connection, empty
  source, system columns without `type`, publish gate).

## Auth

```bash
bash -c 'source ~/.sigma-migration/env; TOKEN=$(curl -s -X POST "$SIGMA_BASE_URL/v2/auth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=$SIGMA_CLIENT_ID&client_secret=$SIGMA_CLIENT_SECRET" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[\"access_token\"])"); <curl using $TOKEN>'
```
Tokens expire ~1h. Never `source` settings.json (it's JSON). Don't assign to the
shell-reserved `UID` var (use `MID` etc.).

## Verification

- Query the built DM element grouped by the rollup dimension via the Sigma MCP and
  compare to parity targets computed straight from the source data.
- A successful POST is necessary but not sufficient — Sigma accepts specs whose
  formulas don't resolve and embeds the error as a SQL string literal at query
  time. Always run a real query.
