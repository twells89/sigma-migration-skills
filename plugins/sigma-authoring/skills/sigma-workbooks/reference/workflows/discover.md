# Source Discovery

Recipe for finding connections, tables, and column names — *and probing actual column values before writing predicates against them*.

```bash
jq '.paths."/v2/connections", .paths."/v2/connection/{connectionId}/lookup", .paths."/v2/connections/tables/{tableId}/columns"' /tmp/sigma-api.json
```

Assumes `$SIGMA_BASE_URL` and `$SIGMA_API_TOKEN` are set in the shell. Use the `sigma-api` skill's `scripts/get-token.sh` to populate `$SIGMA_API_TOKEN` — see SKILL.md for details.

## Verify values before writing predicates

If your task involves a predicate that filters on a categorical column — `CountIf([Transaction Type] = "sale")`, `If([Status] = "active", ...)`, `If([Tier] = "Gold", ...)` — you need to verify the actual distinct values *before* writing the formula. Guessing literals leads to predicates that match zero rows, dashboards that render all zeros, and `verify-workbook.sh` reporting success because the SQL compiled fine.

A column named `TRANSACTION_TYPE` rarely contains exactly `"sale"` and `"return"` — it might be `"Purchase"` and `"Return"`, or `1`/`0`, or something else entirely. A single `SELECT DISTINCT` resolves the question. Verify by whatever means you have at hand:

- An MCP server connected to the warehouse (Snowflake, BigQuery, Databricks, Sigma, etc.) — call its query tool with `SELECT DISTINCT "<col>" FROM <table>` and read the values back.
- A SQL CLI or warehouse client the user can run — paste the results into the conversation.
- Just ask the user. *"Before I write the formula, what values does the `Transaction Type` column contain?"* costs nothing and often saves a broken dashboard.

The principle is verification, not any specific tool. Pick the cheapest path your environment supports.

**Raw warehouse column names work directly in Sigma spec formulas.**
`[F_SALES/TRANSACTION_TYPE]` is accepted authoring input. Use the exact form
discovery returns—no pre-write transformation is required. After POST, GET the
saved spec: Sigma may canonicalize the reference to a friendly form such as
`[F_SALES/Transaction Type]`, or may preserve the raw spelling. Either readback
is valid; use the returned form for later edits and still compile-check it.

## Verify the composed source grain before drafting

Declare what one row is supposed to represent, and name the key that proves it.
Run the check against the source **as the workbook will read it**—after any
warehouse view, SQL, data-model relationship, join, union, or other composition
that will feed the elements. A clean spec cannot detect a plausible-looking
fanout.

For a single-column grain:

```sql
SELECT
  COUNT(*) AS row_count,
  COUNT(DISTINCT <grain_key>) AS distinct_grain_count
FROM <composed_source>;
```

Require equality only when the declared contract is one row per key. For a
composite grain, avoid warehouse-specific tuple syntax and look for duplicate
groups:

```sql
SELECT <key_a>, <key_b>, COUNT(*) AS rows_at_grain
FROM <composed_source>
GROUP BY <key_a>, <key_b>
HAVING COUNT(*) > 1;
```

That query must return zero rows. Add every grain column to both clauses.

For a 1:1 or many:1 join intended to preserve the left-side grain, capture both
`COUNT(*)` and the distinct left-grain count before and after the join. Require
both counts to remain unchanged. If rows increase, the right key is not unique
at the join key or the predicate is incomplete.

Do not apply “row count unchanged” mechanically:

- an inner join may intentionally remove unmatched left rows—write the expected
  shrinkage and account for every missing key;
- an intentional 1:many join changes the grain—declare the new composite grain
  and prove uniqueness there;
- a union normally expects the sum of its input row counts, followed by a
  uniqueness check at the union's declared grain.

Use a warehouse-native query tool, the Sigma MCP query surface, or a SQL client.
If none is available, ask for the counts instead of drafting from an unverified
source. Record the expected counts for the post-build recheck in
[`runtime-verification.md`](runtime-verification.md#4-cardinality-and-uniqueness).

### If you're using the Sigma MCP server

The Sigma MCP server adds workspace-level discovery on top of plain value probing: `search` across workbooks / data models / tables by topic, `describe` of existing Sigma elements, awareness of pre-built metrics on data models. See [Use the Sigma MCP server](https://help.sigmacomputing.com/docs/use-sigma-mcp-server) for setup.

One footgun specific to the Sigma MCP's `query` tool: the SQL `FROM` clause uses a fixed identifier pattern based on `query.type`:

| `query.type` | FROM clause shape |
|---|---|
| `"connection"` | `FROM "connection"."<inodeId>"` |
| `"datamodel"` | `FROM "datamodel"."<elementId>"` |
| `"workbook"` | `FROM "workbook"."<elementId>"` |

The first identifier is a **literal string** — `"connection"`, `"datamodel"`, or `"workbook"` — not the human-readable connection name. Don't write `FROM "Sigma Sample Database"."<inode>"`; the server rejects it. The DDL that `describe` returns shows the correct shape verbatim.

## Warehouse Table Sources

For elements with `source.kind: "warehouse-table"`, you need three things:
1. **connectionId** — the UUID of the warehouse connection
2. **path** — the fully-qualified path as an array (e.g., `["DATABASE", "SCHEMA", "TABLE"]`)
3. **Column names** — exact names from the warehouse, used in formulas

**Prefer a pre-existing MCP tool when you have one.** If an MCP is connected, discover through it: the **Sigma MCP** (`search` / `describe` across connections, tables, and data models) or a **warehouse-native MCP** (Snowflake, BigQuery, Databricks, …) querying `INFORMATION_SCHEMA`. The REST endpoints below are the universal fallback when no MCP is available — they cover all three and need no extra setup.

Use this decision order for an open-ended business prompt:

1. Search with an already-connected Sigma or warehouse MCP.
2. Without MCP, list connections and browse every needed page from
   `/v2/connections/paths`; rank candidate paths by the user's business terms.
3. Resolve the best candidates and inspect their columns. Do not treat the
   first name match as sufficient when many paths match.
4. If several candidates remain semantically plausible—or browsing is blocked
   by permissions—show a short candidate list and ask one focused source
   question.

REST path browsing is name matching, not semantic catalog search. A vague
request such as “sales performance” can match dozens of tables. Stop after a
bounded candidate pass instead of repeatedly opening tables or workbooks.

### Step 1: Find the Connection

List available connections:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections"
```

This returns connections with their `connectionId`, `name`, and `type`.

### Step 2: Resolve the Table Path and Capture the `inodeId`

Ask the user for the fully-qualified table path, **or browse the connection tree yourself** (below). Path depth varies by database:

- **Snowflake**: `["DATABASE", "SCHEMA", "TABLE"]`
- **BigQuery**: `["PROJECT", "DATASET", "TABLE"]`
- **Databricks**: `["CATALOG", "SCHEMA", "TABLE"]`
- **Redshift**: `["SCHEMA", "TABLE"]`
- **PostgreSQL / MySQL**: `["SCHEMA", "TABLE"]`

**Browse instead of guessing.** If an MCP is connected, browse through it first — the **Sigma MCP** (`search`) or a **warehouse-native MCP** (Snowflake, BigQuery, …) is the easiest way to find a table. As a no-MCP fallback, `GET /v2/connections/paths` lists every database / schema / table across the org's connections. Each entry is `{ connectionId, path, urlId }` — the endpoint takes only `page`/`limit` (no connection filter), so filter by `connectionId` client-side:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/paths?limit=1000" \
  | jq -r --arg c "<connection-id>" \
      '.entries[] | select(.connectionId == $c) | select(.path | length == 3) | .path | join(".")'
```

(Adjust the `length` filter to your path depth — `3` for Snowflake/BigQuery/Databricks, `2` for Redshift/Postgres/MySQL. The service may cap a requested `limit`; continue through `nextPage` while `hasMore` is true. A first page is not a complete search. The response carries no `inodeId` — capture that from `lookup` next.)

Verify the path resolves and capture the `inodeId` — Step 3 needs it:

```bash
INODE_ID=$(curl -sf -X POST -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": ["SALES_DB", "PUBLIC", "ORDERS"]}' \
  "$SIGMA_BASE_URL/v2/connection/<connection-id>/lookup" \
  | jq -r '.inodeId')
```

Use the verified path in the source definition.

### Step 3: Discover Column Names via the API

Use the `inodeId` from Step 2 to list the table's columns directly — no need to ask the user or have them query the warehouse:

```bash
bash <sigma-api-skill-dir>/scripts/list-table-columns.sh "$INODE_ID" \
  | jq '.entries[] | {name, type}'
```

The raw endpoint defaults to 50 columns. It returns an opaque
`nextPageToken`, which must be sent as `pageToken` until absent. The helper
requests `pageSize=1000`, follows every page, and returns combined entries.
Never infer that a column is missing from the first response.

Each entry has `name`, `type`, `description`, and `visibility`. Use the `name` value verbatim in formulas — do not invent or transform it.

Public docs: <https://help.sigmacomputing.com/reference/listconnectiontablecolumns>.

If the call fails (rare — connector quirks, permissions), fall back to asking the user for column names or having them run `DESCRIBE TABLE` / `INFORMATION_SCHEMA.COLUMNS` against the warehouse.

For a warehouse-table source with path `["SALES_DB", "PUBLIC", "ORDERS"]`, the formula for a column is `[ORDERS/order_id]` (last path segment + column name).

## Data Model Sources

For elements with `source.kind: "data-model"`, you need:
- **dataModelId** — the UUID of the data model
- **elementId** — the UUID of the specific element within the data model

Ask the user to supply the `dataModelId` (visible in the Sigma UI URL when viewing a data model), then list the model's elements:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/elements" \
  | jq '.entries[] | {elementId, name, columns}'
```

Each entry carries the `elementId` you need plus a `columns` array of **exposed column-name strings** — the names a consuming workbook element must reference.

> **Use the elements endpoint, not the model's spec, to resolve column names.** `GET /v2/dataModels/{id}/spec` reports each column's internal id and its source formula (e.g. `[Order Fact/CUSTOMER_DIM/Region]`) and leaves `name` unset for passthrough columns. Those internal formulas are not what a consuming element references, so authoring formulas from the spec fails with `Dependency not found` on the first attempt.

**Relationship-derived columns carry a join-leg suffix.** Columns the model element pulls through a relationship are exposed as `Column Name (SOURCE)`; the base table's own columns stay bare. The suffix exists to disambiguate — on one 104-column element, `Region`, `City`, `State`, and `Is Active` each appeared twice, once under `(CUSTOMER_DIM)` and once under `(STORE_DIM)`. Reference the suffixed form verbatim, parentheses included: `[Order Fact View/Region (CUSTOMER_DIM)]`, not `[Order Fact View/Region]`.

## Cross-Element Sources

For elements sourced from another element in the same workbook:

```yaml
kind: table
elementId: other-element-id
```

Use the `id` of the source element. Column references use the source element's `name` field: `[Source Element Name/column_name]`.
