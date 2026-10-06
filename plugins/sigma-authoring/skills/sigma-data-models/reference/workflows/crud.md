# Data Model CRUD

POST / GET / PUT against the data-model spec endpoints. Load this for any create, retrieve, or update operation.

The three workflows share auth, ID conventions, and the feature reference files in `reference/`. They differ in HTTP verb, full-replacement semantics, and ID handling. Read the **ID semantics across CRUD** table first — many bugs come from mixing up which IDs the server respects vs. remaps.

Every call includes `-H "Authorization: Bearer $SIGMA_API_TOKEN"`. Auth comes from the `sigma-api` skill.

## ID Semantics Across CRUD

| Phase | What happens to IDs |
|-------|---------------------|
| **CREATE (POST)** | All submitted IDs (pages, elements, columns) are remapped by the server to short alphanumeric IDs. Cross-references (`dateColumnId`, relationship keys) are resolved against the submitted IDs *before* remapping, so they end up correct. Nothing you sent comes back verbatim. |
| **GET** | Server-assigned IDs only. This is the source of truth for any subsequent UPDATE. |
| **UPDATE (PUT) — existing elements** | Keep the server-assigned IDs verbatim. Changing them on unchanged elements can break workbooks that depend on this data model. |
| **UPDATE (PUT) — new elements added in the same PUT** | Server remaps them just like CREATE. Use placeholder IDs (`inode-<tableId>/<COL>` for warehouse columns, short alphanumeric otherwise) — they will not come back verbatim. |
| **UPDATE — mixed cross-references** (e.g., a relationship between an existing column and a new one) | Existing side uses the live server ID. New side uses the placeholder. Server resolves on submit. |

> **Rule of thumb:** GET is the only step that returns IDs you can rely on. Use GET as the entry point for every UPDATE.

## CREATE — Author a New Model

### 1. Gather required IDs

You need a `folderId`, a `connectionId`, and (usually) a warehouse `path` + inode prefix.

**Destination folder:**

```sh
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/files" \
  | jq '.entries[] | {inodeId, name, type}'
```

The `inodeId` of the target folder becomes `folderId`.

**Connection:**

```sh
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections" \
  | jq '.entries[] | {connectionId, name}'
```

**Connection paths and tables:**

```sh
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections/paths?limit=1000"
```

Search the `entries` array for depth-3 `path` values (e.g., `["EXAMPLES", "PLUGS_ELECTRONICS", "TABLE_NAME"]`). If `hasMore` is `true`, paginate with `&page=<nextPage>`.

Once you have the path, look up the table for its inode prefix:

```sh
curl -s -X POST \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path": ["<DATABASE>", "<SCHEMA>", "<TABLE>"]}' \
  "$SIGMA_BASE_URL/v2/connection/<connectionId>/lookup"
```

The last segment of the `url` field (e.g., `.../t/5FCsrDpnzcdw5YYJRBbY6l`) becomes the inode prefix for warehouse column IDs: `inode-5FCsrDpnzcdw5YYJRBbY6l/<COLUMN_NAME>`.

**Connection table columns** (use to discover real column names + types before composing — never invent column names):

```sh
bash <sigma-api-skill-dir>/scripts/list-table-columns.sh "<inodeId>"
```

Returns all pages of `name`, `type`, and `visibility`. The raw endpoint
defaults to 50 and uses `nextPageToken`/`pageToken`; do not declare a column
missing until pagination is exhausted. Normalize special characters per the
**Special characters** section in `reference/columns.md`.

**Existing data-model elements / columns** (only when the user explicitly names an existing model as a relationship target or template):

```sh
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/elements"

curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/columns"
```

Use `columnId` values when referencing columns in relationship keys.

> Do **not** read other data models to infer column names, discover table structure, or borrow patterns unless the user explicitly named one as a template or source.

### 2. Identify features

Map the user's request to feature reference files via the SKILL.md **Reference Index**. Tell the user which features you identified and why, then read the relevant files before composing.

If the user explicitly names an existing model to base the new one on, retrieve its spec via the GET workflow below and use it — modified per the description — as the basis instead of the minimal structure.

### 3. Compose the JSON

Start from the minimal structure, then layer in patterns from the reference files.

```json
{
  "name": "<YOUR_DATA_MODEL_NAME>",
  "folderId": "<YOUR_FOLDER_ID>",
  "schemaVersion": 1,
  "pages": [
    {
      "id": "page-1",
      "name": "Main",
      "elements": [
        {
          "id": "table-1",
          "kind": "table",
          "source": {
            "kind": "warehouse-table",
            "connectionId": "<YOUR_CONNECTION_ID>",
            "path": ["<YOUR_DATABASE>", "<YOUR_SCHEMA>", "<YOUR_TABLE_NAME>"]
          },
          "columns": [
            {
              "id": "<YOUR_TABLE_INODE>/<COLUMN_NAME>",
              "formula": "[<YOUR_TABLE_NAME>/Column Name]",
              "name": "Column Name"
            }
          ]
        }
      ]
    }
  ]
}
```

After the JSON, surface a "What you need to supply" table:

| Placeholder | What it is | How to find it |
|---|---|---|
| `<YOUR_FOLDER_ID>` | Destination folder for the data model | `GET /v2/files` output or the folder URL in Sigma |
| `<YOUR_CONNECTION_ID>` | Data source connection | `GET /v2/connections` output or the Connections page |
| `<YOUR_DATABASE>` / `<YOUR_SCHEMA>` / `<YOUR_TABLE_NAME>` | Warehouse path to source table | The warehouse, or the connection browser in Sigma |
| `<YOUR_TABLE_INODE>` | Inode prefix for warehouse column IDs | Last path segment of the `url` returned by `POST /v2/connection/<id>/lookup` (e.g., `.../t/5FCsrDpnzcdw5YYJRBbY6l` → `inode-5FCsrDpnzcdw5YYJRBbY6l`) |

Reminder on IDs: anything you submit is remapped on accept (see the ID semantics table at the top). Cross-references (e.g., `dateColumnId` in metric timelines, relationship keys) are resolved correctly before remapping.

### 4. Submit

```sh
cat > spec.json <<'EOF'
{ ...the composed JSON... }
EOF

curl -s -X POST \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @spec.json \
  "$SIGMA_BASE_URL/v2/dataModels/spec"
```

The response includes the `dataModelId` of the new model. Give the user a link in the form `https://app.sigmacomputing.com/<org_name>/data-model/<dataModelId>`.

## GET — Read an Existing Model

> **This is the entry point for an UPDATE — always GET first.** The retrieved spec is the only source of IDs you can safely PUT back.

### 1. List models

```sh
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/dataModels" \
  | jq '.entries[] | {dataModelId, name}'
```

If the user wants to browse by folder first:

```sh
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/files" \
  | jq '.entries[] | {inodeId, name, type}'
```

### 2. Retrieve the spec

```sh
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/spec" \
  | jq .
```

Save to a file for review or as input to the UPDATE workflow:

```sh
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/spec" \
  > my-data-model.json
```

## UPDATE — Modify an Existing Model

The update endpoint uses **PUT** and requires the **complete** representation, not a diff. Always start from the GET so existing elements are preserved.

### 1. List + identify

Same as the GET workflow — `GET /v2/dataModels`, optionally `GET /v2/files` to browse by folder.

### 2. Retrieve the current spec

```sh
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/spec" \
  > current-spec.json
```

### 3. Identify changes and load references

For each type of change the user is asking for, read the corresponding reference file from the SKILL.md **Reference Index** to get the correct JSON pattern. Common change categories:

- Add, rename, or remove a column or metric → `reference/columns.md`, `reference/metrics.md`
- Add a calculated column or change a formula → `reference/columns.md`
- Change or swap the data source → `reference/sources.md`
- Add a relationship or join → `reference/relationships.md`, `reference/sources.md`
- Add, modify, or remove filters → `reference/filters.md`
- Add column-level security → `reference/column-level-security.md`
- Add or modify controls → `reference/controls.md`
- Reorder columns or change folder/grouping → `reference/folders-groupings.md`
- Reformat a column or metric → `reference/formatting.md`

Use the retrieved spec as structural context — match existing ID conventions and naming patterns.

### 4. Compose the updated spec

Apply the changes to `current-spec.json`. Key rules:

- Include from the GET response: `name`, `folderId`, `ownerId`, `createdAt`, `updatedAt`, `schemaVersion`, and all of `pages`. Server-managed fields (`documentVersion`, `latestDocumentVersion`, `url`, `createdBy`, `updatedBy`) can be omitted — they are silently ignored if present.
- **Preserve existing element IDs** — changing them on unchanged elements can break workbooks that depend on this data model.
- For new elements, follow the ID conventions: short alphanumeric for generated IDs, `inode-<tableId>/<COL>` for warehouse columns. They'll be remapped on submit.
- Controls live in the page `elements` array alongside table elements, not inside them.
- Mixed-ID cross-references (e.g., a relationship between an existing column and a new one): see the ID semantics table at the top of this file. Existing side uses the live server ID; new side uses the placeholder; server resolves on submit.

### 5. Submit

```sh
curl -s -X PUT \
  -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d @current-spec.json \
  "$SIGMA_BASE_URL/v2/dataModels/<dataModelId>/spec"
```
