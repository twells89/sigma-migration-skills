# Migrate a CSV-backed data model between Sigma organizations

Use this workflow when a source data model contains an uploaded CSV and the
destination organization must reuse data already landed in the warehouse,
without uploading the CSV again.

## Why a direct copy does not work

A CSV source in a data-model representation is document-scoped:

```json
{
  "kind": "csv-table",
  "connectionId": "<source-connection-id>",
  "inodeId": "<csv-inode-id>"
}
```

The CSV inode cannot be resolved in a different data model or organization.
The data-model spec endpoints also cannot upload a CSV. Sigma writes uploaded
data through the connection's write-back configuration, but intentionally
hides the backing object from the connection catalog.

The physical object can still be discovered without Databricks credentials.
For each CSV element, call:

```text
GET /v2/dataModels/{dataModelId}/elements/{elementId}/query
```

The generated SQL contains the fully qualified Databricks relation. Remove the
preview `LIMIT` and Sigma request comment, then use the remaining projection as
a custom SQL source in the destination organization. A custom SQL source is
required because `POST /v2/connection/{connectionId}/lookup` returns 404 for
the hidden upload table even when given its exact physical path.

```json
{
  "kind": "sql",
  "connectionId": "<destination-connection-id>",
  "statement": "select ... from <catalog>.<write-schema>.<upload-table> Q1"
}
```

The destination connection must point to the same Databricks workspace and its
principal must have `SELECT` access to the source write-back schema.

> **Lifecycle warning:** The generated upload table is owned by the source
> Sigma document. Do not delete the source model or assume the table is a
> permanent customer-managed contract. For a durable cutover, create a
> customer-owned table or view over the data and repoint the generated plan
> before retiring the source organization.

## Authentication

Install the Sigma CLI and create one OAuth profile for each organization:

```bash
sigma auth login
# Create OAuth profile: source-org

sigma auth login
# Create OAuth profile: target-org

sigma -p source-org auth status
sigma -p target-org auth status
```

The CLI owns browser login, token storage, and refresh. The migration tool does
not read API keys, client secrets, bearer tokens, or credential files.

## 1. Inspect the source model

Run from the `sigma-data-models` skill directory:

```bash
python3 scripts/migrate_csv_data_model.py inspect \
  --source-profile source-org \
  --model 'https://app.sigmacomputing.com/<org>/data-model/<model-slug>' \
  --export-spec /secure/source-model.json
```

This is read-only. The output lists each `sourceElementId`, CSV inode, filename,
connection, source-column names, and discovered `physicalRelation`. Use the
element IDs in the mapping file.

## 2. Map every CSV element

Create a mapping file:

```json
{
  "csvSources": [
    {
      "sourceElementId": "<element-id-from-inspect>",
      "targetConnectionId": "<destination-connection-id>"
    }
  ]
}
```

Every CSV element requires exactly one destination connection mapping. The
tool verifies that both connections are Databricks connections on the same
host. If the same catalog is deliberately exposed through a different host,
set `"allowDifferentHost": true` only after confirming access.

## 3. Build and validate a migration plan

```bash
python3 scripts/migrate_csv_data_model.py plan \
  --source-profile source-org \
  --target-profile target-org \
  --model '<source-model-id-or-url>' \
  --mapping /secure/source-map.json \
  --target-folder '<destination-folder-id>' \
  --target-name 'Migrated model name' \
  --output /secure/create-spec.json
```

Planning is read-only against both organizations. It:

1. retrieves the source representation;
2. calls the element-query endpoint for every CSV element;
3. extracts the physical Databricks relation and removes the preview limit and
   request comment;
4. verifies that source and target connections use the same Databricks host;
5. changes `csv-table` sources to direct `sql` sources;
6. replaces source-column IDs, formulas, order entries, and exact
   cross-references to the old CSV column IDs;
7. replaces the source folder with the destination folder; and
8. removes source-organization server fields such as owner and document
   version.

The generated spec is mode `0600`. Review it before creating anything.

## 4. Create and read back the destination model

Add both mutation gates to the reviewed planning command:

```bash
python3 scripts/migrate_csv_data_model.py plan \
  --source-profile source-org \
  --target-profile target-org \
  --model '<source-model-id-or-url>' \
  --mapping /secure/source-map.json \
  --target-folder '<destination-folder-id>' \
  --output /secure/create-spec.json \
  --readback /secure/created-model.json \
  --apply --yes
```

The command creates through `POST /v2/dataModels/spec`, retrieves the created
model, and fails if the readback still contains a CSV source.

Creation remaps page, element, and column IDs. The readback is the source of
truth for any later update or for repointing downstream workbooks.

## 5. Verify data parity

Readback verifies structure, not data equivalence. Before handoff, compare the
source and destination for:

- row count;
- null count for keys and required fields;
- min/max dates;
- distinct key count; and
- sums of important numeric columns.

Do not retire the source data model or its uploaded CSV until parity and
downstream workbook testing are complete.
