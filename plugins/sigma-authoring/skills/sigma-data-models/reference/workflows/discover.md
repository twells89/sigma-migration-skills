# Discover — Find Connections, Tables, Columns

The first step before authoring any data model is figuring out **what data exists**: which connections the user has, which schemas / tables live inside them, and which columns each table exposes. **Never invent column names** — only use names you confirmed via the API or the user gave you.

Auth via the `sigma-api` skill first. All commands assume `$SIGMA_BASE_URL` and `$SIGMA_API_TOKEN` are set.

## 1. List connections

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections?limit=200" | jq '.entries[] | {connectionId, name, type}'
```

Pick the connection by `name` or `type` (Snowflake, BigQuery, Databricks, Redshift, Postgres, MySQL, etc.). Save its `connectionId` — you'll need it for every warehouse-table source in the spec.

## 2. Resolve a table path → inodeId

You need the table's `inodeId` (not just its dotted path) for the columns endpoint and for warehouse-table sources. Resolve it with `lookup`:

```bash
curl -s -X POST -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": ["DATABASE", "SCHEMA", "TABLE_NAME"]}' \
  "$SIGMA_BASE_URL/v2/connection/<connectionId>/lookup" | jq .
```

The response includes the table's `inodeId` (looks like `inode-<22-char>`). The `path` array segments depend on the warehouse — Snowflake is typically `[DATABASE, SCHEMA, TABLE]`, BigQuery is `[PROJECT, DATASET, TABLE]`, etc.

## 3. List columns for a table

The columns endpoint is keyed by **table inodeId**, not connectionId:

```bash
bash <sigma-api-skill-dir>/scripts/list-table-columns.sh "<tableInodeId>" |
  jq '.entries[] | {name, type, visibility}'
```

> **Pagination is mandatory.** The endpoint defaults to 50 results and returns
> `nextPageToken`; pass that opaque value as `pageToken` until it is absent.
> The shared helper requests `pageSize=1000` and follows every page. Never
> conclude a column is missing from a single response.
>
Capture the column `name` exactly as returned — case, special characters, and underscores all matter for downstream formula references.

> **Wrong shape:** `/v2/connections/<connectionId>/tables/<inodeId>/columns` is **not** the endpoint. The connection ID does not appear in the path. Using the wrong shape returns 404.

## 4. Browse schemas (optional)

If the user doesn't know the table path yet, walk the connection's path tree:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/paths?connectionId=<connectionId>&parentPath=DATABASE" | jq .
```

Each level (database → schema → table) is a separate call. Most authoring sessions start from a path the user already knows; this is the fallback for "what schemas can I see in this connection?"

## 5. Sanity-check before drafting

Before writing the model spec:

- [ ] Connection `connectionId` confirmed.
- [ ] Every table you plan to include has a real `inodeId` (lookup result, not guessed).
- [ ] Column pagination completed (`nextPageToken` absent), and every column
      you plan to reference appears in the combined response **verbatim** (or
      the user provided it from a warehouse query they ran themselves).
- [ ] The expected row grain and its single or composite key are written down.
- [ ] The source at that grain has no duplicates: for a single key,
      `COUNT(*) = COUNT(DISTINCT <grain-key>)`; for a composite key,
      `GROUP BY` every key column with `HAVING COUNT(*) > 1` returns zero rows.
- [ ] If joining elements, you know the join keys and whether they're 1:1,
      1:many, or many:many. For a 1:1 or many:1 join intended to preserve the
      left grain, row count and distinct left-grain count are unchanged before
      vs. after the join. For an inner or intentional 1:many join, record the
      expected shrink/expansion and prove uniqueness at the resulting grain.
      Ask the user if the intended cardinality is uncertain.

Cross-link: the `sources.md` file documents the warehouse-table source shape that consumes these IDs. The `columns.md` file covers the column ID format (`inode-<22>/COLUMN_NAME`) and the `[TABLE/Display Name]` formula reference rule.
