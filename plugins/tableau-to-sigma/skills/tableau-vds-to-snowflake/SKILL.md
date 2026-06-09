---
name: tableau-vds-to-snowflake
description: >-
  Extract data from a published Tableau datasource via the VizQL Data Service
  (VDS) API and land it in a Snowflake table using a stored procedure + External
  Access Integration. Use when the user wants to pull a Tableau-managed dataset
  into Snowflake (one-shot or scheduled refresh) without exporting CSV by hand.
  Optionally schedule for ongoing refresh with a Snowflake Task.
user-invocable: true
---

# Tableau VDS → Snowflake

Extract data from a published Tableau datasource via the VizQL Data Service (VDS) API
and land it in a Snowflake table using a stored procedure + External Access Integration.
Optionally schedule for ongoing refresh with a Snowflake Task.

---

## When this skill applies (and when it doesn't)

> **VDS only works against *published* Tableau datasources.** If the workbook you
> care about uses an *embedded* extract (the common case for Tableau community
> samples and one-off "extract from CSV, dashboard on top" workbooks), VDS will
> not see it. `mcp__tableau__list-datasources` and `search-content` with
> `contentTypes=["datasource"]` only return published datasources — if the
> source you want isn't there, it's embedded.
>
> **To VDS an embedded extract**, the workbook owner must first **publish the
> datasource separately** in Tableau Cloud (right-click datasource → Publish
> Data Source). That's a one-time UI step per datasource. After publishing,
> the datasource shows up via the MCP and VDS can read it.
>
> Always check this **before** running the skill — surface the gap to the user
> rather than burning turns on a query that can't succeed.

---

## How it works

```
Tableau Published Datasource
        │
        │  POST /api/v1/vizql-data-service/query-datasource
        │  (auth via PAT + x-tableau-auth header)
        ▼
Snowflake Stored Procedure (Python)
  - signs in to Tableau REST API
  - calls VDS query endpoint
  - creates/replaces target table
  - loads rows via Snowpark
        │
        ▼
Snowflake Table  ──▶  Sigma Workbook
```

The stored procedure runs inside Snowflake via External Access Integration (EAI).
No data touches Claude or the local machine — Snowflake fetches directly from Tableau.

---

## Prerequisites

### Tableau
- A **published** datasource (not workbook-embedded — see callout above)
- A Personal Access Token (PAT) — name and secret
  - Create at: Tableau Cloud → Account settings → Personal Access Tokens
- The datasource LUID (a UUID) — retrieved via MCP or REST API
- The site's `contentUrl` (e.g. `"dataflow"`)

### Snowflake
- A database and schema to write to (e.g. `TJ.PUBLIC`)
- A role with `CREATE NETWORK RULE`, `CREATE SECRET`, `CREATE INTEGRATION`, `CREATE PROCEDURE`, `CREATE TABLE` privileges
  - In the TSE sandbox: `SNOWFLAKE_SANDBOX_TSE_PUSH_GROUP`
- A running warehouse (e.g. `SIGMA_WH`)
- Snowflake CLI (`snow`) configured with key-pair JWT auth:
  - Config: `~/.snowflake/config.toml`
  - Test: `snow sql -q "SELECT CURRENT_USER()" --connection <conn>`

---

## Phase 1 — Discover the datasource LUID

### Option A: Tableau MCP tool
```
mcp__tableau__list-datasources
```
Returns a list with `id` (the LUID) and `name`. Use the `id` value.

If the datasource you expect isn't in the list, it's almost certainly
embedded in a workbook rather than published. See the callout at the top of
this skill before continuing.

### Option B: Tableau REST API
```bash
bash -c '
AUTH=$(curl -s -X POST "https://{server}/api/3.21/auth/signin" \
  -H "Content-Type: application/json" \
  -d "{\"credentials\": {
    \"personalAccessTokenName\": \"{pat_name}\",
    \"personalAccessTokenSecret\": \"{pat_secret}\",
    \"site\": {\"contentUrl\": \"{site_name}\"}}}")

TOKEN=$(echo "$AUTH" | python3 -c "import sys,re; print(re.search(r\"token=\\\"([^\\\"]+)\\\"\", sys.stdin.read()).group(1))")
SITE_ID=$(echo "$AUTH" | python3 -c "import sys,re; print(re.search(r\"site id=\\\"([^\\\"]+)\\\"\", sys.stdin.read()).group(1))")

curl -s -H "x-tableau-auth: $TOKEN" \
  "https://{server}/api/3.21/sites/$SITE_ID/datasources?pageSize=100" \
  | python3 -c "import sys,re; [print(m[0], m[1]) for m in re.findall(r\"datasource id=\\\"([^\\\"]+)\\\" name=\\\"([^\\\"]+)\\\"\", sys.stdin.read())]"
'
```

> **Auth response is XML**, not JSON. Parse with `re.search(r'token="([^"]+)"', ...)`.
> Do NOT pipe to `jq` — it will fail silently or error.

### Validate a datasource is VDS-queryable
```bash
# Quick test — should return {"data": [...]}
bash -c '
AUTH=$(curl -s -X POST "https://{server}/api/3.21/auth/signin" \
  -H "Content-Type: application/json" \
  -d "{\"credentials\": {\"personalAccessTokenName\": \"{pat_name}\", \"personalAccessTokenSecret\": \"{pat_secret}\", \"site\": {\"contentUrl\": \"{site_name}\"}}}")
TOKEN=$(echo "$AUTH" | python3 -c "import sys,re; print(re.search(r\"token=\\\"([^\\\"]+)\\\"\", sys.stdin.read()).group(1))")
curl -s -X POST "https://{server}/api/v1/vizql-data-service/query-datasource" \
  -H "x-tableau-auth: $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"datasource\": {\"datasourceLuid\": \"{luid}\"}, \"query\": {\"fields\": [{\"fieldCaption\": \"{any_field}\"}]}, \"options\": {\"returnFormat\": \"OBJECTS\"}}" \
  | python3 -m json.tool
'
```

---

## Phase 2 — Set up Snowflake objects (one-time per account + schema)

> **Skip this phase if the setup already exists.** Network rule + secret + EAI
> + procedure are created once per Snowflake account/schema and reused for
> every subsequent VDS load. Check first:

```bash
snow sql --connection <conn> -q "
SHOW EXTERNAL ACCESS INTEGRATIONS LIKE 'tableau%';
SHOW SECRETS LIKE 'tableau%' IN SCHEMA <db>.<schema>;
SHOW NETWORK RULES LIKE 'tableau%' IN SCHEMA <db>.<schema>;
"

snow sql --connection <conn> --format json -q \
  "SHOW PROCEDURES LIKE 'QUERY_TABLEAU%' IN SCHEMA <db>.<schema>" \
  | python3 -c "import sys,json; print('procs:', [p['name'] for p in json.load(sys.stdin)])"
```

If all four exist (and you trust the PAT secret is current), jump to Phase 3.

The rest of this phase covers first-time setup. Replace `TJ.PUBLIC` throughout.

### 2a. Network rule + secret + EAI

Write to `/tmp/vds_setup.sql`:

```sql
USE ROLE <your_role>;
USE DATABASE <db>;
USE SCHEMA <schema>;

CREATE OR REPLACE NETWORK RULE tableau_api_rule
  MODE = EGRESS
  TYPE = HOST_PORT
  VALUE_LIST = ('<tableau_server_host>');   -- e.g. '10ay.online.tableau.com'

CREATE OR REPLACE SECRET tableau_pat_secret
  TYPE = GENERIC_STRING
  SECRET_STRING = '{"pat_name": "<pat_name>", "pat_secret": "<pat_secret>"}';

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION tableau_vds_eai
  ALLOWED_NETWORK_RULES = (<db>.<schema>.tableau_api_rule)
  ALLOWED_AUTHENTICATION_SECRETS = (<db>.<schema>.tableau_pat_secret)
  ENABLED = TRUE;
```

```bash
snow sql --connection <conn> -f /tmp/vds_setup.sql
```

### 2b. Stored procedure

Write to `/tmp/vds_proc.sql`:

```sql
USE ROLE <your_role>;
USE DATABASE <db>;
USE SCHEMA <schema>;

CREATE OR REPLACE PROCEDURE query_tableau_vds(
  server_url      STRING,
  site_name       STRING,
  datasource_luid STRING,
  target_table    STRING,
  fields_json     STRING
)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
EXTERNAL_ACCESS_INTEGRATIONS = (tableau_vds_eai)
SECRETS = ('pat_creds' = <db>.<schema>.tableau_pat_secret)
HANDLER = 'run'
AS $$
import _snowflake
import requests
import json
import re

def run(session, server_url, site_name, datasource_luid, target_table, fields_json):
    creds = json.loads(_snowflake.get_generic_secret_string('pat_creds'))

    # Sign in — Tableau returns XML
    signin = requests.post(
        f'{server_url}/api/3.21/auth/signin',
        headers={'Content-Type': 'application/json'},
        json={'credentials': {
            'personalAccessTokenName': creds['pat_name'],
            'personalAccessTokenSecret': creds['pat_secret'],
            'site': {'contentUrl': site_name}
        }},
        timeout=30
    )
    signin.raise_for_status()
    token = re.search(r'token="([^"]+)"', signin.text).group(1)

    # Query VDS
    resp = requests.post(
        f'{server_url}/api/v1/vizql-data-service/query-datasource',
        headers={'x-tableau-auth': token, 'Content-Type': 'application/json'},
        json={
            'datasource': {'datasourceLuid': datasource_luid},
            'query': {'fields': json.loads(fields_json)},
            'options': {'returnFormat': 'OBJECTS'}
        },
        timeout=60
    )
    resp.raise_for_status()
    rows = resp.json()['data']

    if not rows:
        return 'No rows returned'

    # Sanitize column names to UPPER_SNAKE_CASE
    orig_cols = list(rows[0].keys())
    safe_cols = [re.sub(r'[^A-Z0-9_]', '_', c.upper()) for c in orig_cols]
    col_defs  = ', '.join(f'{c} VARIANT' for c in safe_cols)

    session.sql(f'CREATE OR REPLACE TABLE {target_table} ({col_defs})').collect()

    from snowflake.snowpark import Row
    sf_rows = [Row(**dict(zip(safe_cols, [row[c] for c in orig_cols]))) for row in rows]
    df = session.create_dataframe(sf_rows)
    df.write.mode('overwrite').save_as_table(target_table)

    return f'Loaded {len(rows)} rows into {target_table}'
$$;
```

```bash
snow sql --connection <conn> -f /tmp/vds_proc.sql
```

---

## Phase 3 — Run the load

Build the `fields_json` array from the datasource's fields. Each field is one of:
- `{"fieldCaption": "Category"}` — dimension (no aggregation)
- `{"fieldCaption": "Sales", "function": "SUM", "fieldAlias": "Total Sales"}` — measure

Supported `function` values: `SUM`, `AVG`, `MEDIAN`, `COUNT`, `COUNTD`, `MIN`, `MAX`.
Use `mcp__tableau__get-datasource-metadata` to list available field captions.

> **To land row-level facts (most common for downstream Sigma DM authoring), omit
> `function` from every field.** With `function`, VDS aggregates server-side
> and returns a much smaller result set — fine for a pre-rolled-up extract,
> usually not what you want for a flexible Sigma workbook.

```bash
snow sql --connection <conn> -q "
USE ROLE <your_role>;
USE DATABASE <db>;
USE SCHEMA <schema>;
USE WAREHOUSE <wh>;

CALL query_tableau_vds(
  'https://<server>',
  '<site_name>',
  '<datasource_luid>',
  '<db>.<schema>.<TABLE_NAME>',
  '[
    {\"fieldCaption\": \"Category\"},
    {\"fieldCaption\": \"Sales\", \"function\": \"SUM\", \"fieldAlias\": \"Total Sales\"}
  ]'
);
"
```

### Verify the load

```bash
# Row count + a sample row
snow sql --connection <conn> --format json -q "
SELECT COUNT(*) AS n FROM <db>.<schema>.<TABLE_NAME>;
SELECT * FROM <db>.<schema>.<TABLE_NAME> LIMIT 3;
" | python3 -m json.tool
```

> **Expect small row-count drift versus the Tableau-side total** (~0.02% in
> measured Superstore Orders load: 10,192 rows landed vs. ~10,194 canonical).
> Likely cause: VDS drops rows where a required key field is null. Investigate
> only if exact parity is required.

---

## Phase 4 — Schedule with a Snowflake Task (optional)

```sql
CREATE OR REPLACE TASK refresh_tableau_data
  WAREHOUSE = <wh>
  SCHEDULE = 'USING CRON 0 6 * * * America/Los_Angeles'   -- daily at 6am PT
AS
  CALL query_tableau_vds(
    'https://<server>',
    '<site_name>',
    '<datasource_luid>',
    '<db>.<schema>.<TABLE_NAME>',
    '[{"fieldCaption": "Category"}, {"fieldCaption": "Sales", "function": "SUM", "fieldAlias": "Total Sales"}]'
  );

-- Tasks start suspended; resume to activate
ALTER TASK refresh_tableau_data RESUME;
```

Check task history:
```sql
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(task_name => 'refresh_tableau_data'))
ORDER BY scheduled_time DESC LIMIT 10;
```

---

## Column types (what actually lands)

The procedure declares the target table with all-`VARIANT` columns, then
`df.write.mode('overwrite').save_as_table(...)` **overrides** that schema —
Snowpark infers types from the data:

| Tableau field type | Snowflake column type after load |
|---|---|
| `REAL` / `INTEGER` measures | `FLOAT` / `NUMBER(38, 0)` |
| `STRING` dimensions | `VARCHAR(134217728)` |
| `DATE` / `DATETIME` | `VARCHAR(134217728)` — VDS returns ISO strings like `2022-11-07T00:00:00` |

**Dates land as strings.** Sigma will introspect those VARCHAR columns and
auto-type them as `datetime` based on the value shape. Downstream Sigma DM
column formulas should use `Date([SOURCE/Col Name])` directly:

```json
{ "id": "so-order-date", "name": "Order Date",
  "formula": "Date([SUPERSTORE_ORDERS/Order Date])" }
```

> **Do NOT use the `Date(Left(Text([col]), 10))` pattern here.** That works
> for integer YYYYMMDD date keys (see `../tableau-to-sigma/refs/column-gotchas.md`)
> but fails on VARCHAR-stored ISO datetimes because Sigma's auto-typing makes
> them `datetime` at the DM column level, and `Left()` doesn't compile against
> datetime. Use `Date([col])` for VDS-landed date columns.

Optional: create a typed view to lock down explicit casts:

```sql
CREATE OR REPLACE VIEW <db>.<schema>.<TABLE_NAME>_TYPED AS
SELECT
  CATEGORY::VARCHAR        AS CATEGORY,
  ORDER_DATE::DATE         AS ORDER_DATE,
  TOTAL_SALES::FLOAT       AS TOTAL_SALES
FROM <db>.<schema>.<TABLE_NAME>;
```

---

## Sigma column-metadata cache lag

After a `CREATE OR REPLACE TABLE` (which is what the proc does on every run),
Sigma's cached column metadata for that table may be stale until Sigma re-syncs:

- Sigma's `mcp__sigma-mcp-v2__search` and `/v2/connections/tables/<inodeId>/columns`
  endpoints can briefly return the *old* column list after a VDS re-load that
  changed the column set (e.g. you added or removed a field in the `fields_json`).
- The data is correct; the metadata is what's stale.

**Mitigations:**
- If you only add columns (don't remove), the agent's DM references to the
  surviving columns continue working — the stale extra columns are harmless.
- If you remove columns, either wait for Sigma to re-sync (typically minutes),
  or trigger a manual schema refresh from the Sigma connection UI.
- There's no public API to force a connection re-sync today; this is a known
  rough edge.

---

## Finding fields available on a datasource

Use the MCP metadata tool:
```
mcp__tableau__get-datasource-metadata  datasourceLuid="<luid>"
```

The response includes **all CALCULATION fields with their Tableau formulas** —
that's the right input for translating calc fields into the downstream Sigma
DM. See `../tableau-to-sigma/scripts/extract-calc-fields.rb` for a pre-built
extractor + translation-notes generator.

Or query VDS metadata endpoint directly:
```bash
curl -s -X POST "https://<server>/api/v1/vizql-data-service/read-metadata" \
  -H "x-tableau-auth: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"datasource": {"datasourceLuid": "<luid>"}}' | python3 -m json.tool
```

---

## Worked example: Superstore Datasource → TJ.PUBLIC.SUPERSTORE_ORDERS

A concrete end-to-end run from a measured conversion (May 2026):

```bash
snow sql --connection tj -q "
USE ROLE SNOWFLAKE_SANDBOX_TSE_PUSH_GROUP;
USE DATABASE TJ;
USE SCHEMA PUBLIC;
USE WAREHOUSE SIGMA_WH;

CALL QUERY_TABLEAU_VDS(
  'https://10ay.online.tableau.com',
  'dataflow',
  '1bef4413-4d4b-452a-9082-2cae8e94f28d',
  'TJ.PUBLIC.SUPERSTORE_ORDERS',
  '[
    {\"fieldCaption\": \"Order ID\"},
    {\"fieldCaption\": \"Order Date\"},
    {\"fieldCaption\": \"Ship Date\"},
    {\"fieldCaption\": \"Customer Name\"},
    {\"fieldCaption\": \"Segment\"},
    {\"fieldCaption\": \"Country/Region\"},
    {\"fieldCaption\": \"State/Province\"},
    {\"fieldCaption\": \"Category\"},
    {\"fieldCaption\": \"Sub-Category\"},
    {\"fieldCaption\": \"Sales\"},
    {\"fieldCaption\": \"Profit\"},
    {\"fieldCaption\": \"Quantity\"},
    {\"fieldCaption\": \"Discount\"}
  ]'
);
"
# → Loaded 10192 rows into TJ.PUBLIC.SUPERSTORE_ORDERS
```

Result: 19 columns landed (note `Country/Region` → `COUNTRY_REGION` from the
slash → `_` sanitizer; `Sub-Category` → `SUB_CATEGORY`). Downstream Sigma DM
built on the landed table; KPI parity with the Tableau Executive Overview
was within 0.02% on Sales/Profit/Quantity — exact on Profit Ratio and
Discount.

---

## Troubleshooting

| Error / symptom | Cause | Fix |
|---|---|---|
| Expected datasource not in `mcp__tableau__list-datasources` output | Datasource is embedded in a workbook, not published | Have the workbook owner publish the datasource separately in Tableau Cloud — VDS only sees published datasources |
| `404` on `/api/v1/sites/.../datasources/.../query` | Wrong VDS URL — the Tableau docs example uses this but the real endpoint is different | Use `/api/v1/vizql-data-service/query-datasource` with `datasource.datasourceLuid` in body |
| `401` on VDS query | Token expired (PAT tokens last ~hours) or wrong `x-tableau-auth` header name | Re-authenticate and retry; confirm header is `x-tableau-auth` not `Authorization` |
| `json.decoder.JSONDecodeError` parsing auth response | Tableau signin returns XML, not JSON | Parse with `re.search(r'token="([^"]+)"', response.text)` |
| EAI creation error: "Network rule not found" | Fully-qualified name required | Use `<db>.<schema>.tableau_api_rule` in the `ALLOWED_NETWORK_RULES` list |
| Procedure error: "secret not found" | Secret must be fully qualified in procedure DDL | Use `<db>.<schema>.tableau_pat_secret` in `SECRETS = (...)` |
| `requests.exceptions.ConnectionError` in procedure | EAI not attached to the procedure, or network rule host mismatch | Verify `EXTERNAL_ACCESS_INTEGRATIONS = (tableau_vds_eai)` is in the CREATE PROCEDURE DDL; confirm host in network rule exactly matches the Tableau server hostname |
| VDS returns `{"error": "datasource not found"}` | Datasource LUID is wrong or datasource was deleted/moved | Re-fetch LUID via `mcp__tableau__list-datasources` |
| Columns with spaces / slashes / hyphens get `_` substitution | `re.sub(r'[^A-Z0-9_]', '_', c.upper())` in the proc sanitizes anything non-alphanumeric | Expected — use a typed view or rename in the Sigma DM (column-gotchas no longer apply since slashes are gone) |
| Sigma DM column shows type `error` for a date column | Date came from VDS as VARCHAR; Sigma auto-types as datetime; `Left()`/`Text()` formula doesn't compile | Use `Date([SOURCE/Col Name])` directly in the DM column formula (see "Column types" section) |
| Sigma shows columns that no longer exist after a VDS re-load | Sigma connection metadata cache lag | Stale extra columns are harmless if you only added — for removals, wait for resync or refresh in the Sigma UI |
| Row count in Snowflake is ~0.02% lower than Tableau total | VDS drops rows with NULL key fields | Expected drift; investigate only if exact parity is required |
| Task runs but table is empty | PAT expired (PATs have a max TTL) | Rotate PAT in Tableau Cloud → update secret: `ALTER SECRET tableau_pat_secret SET SECRET_STRING = '...'` |
| Setup commands re-run on every conversion | Phase 2 was treated as per-conversion | Phase 2 is one-time per Snowflake account + schema; check existing infra first (see Phase 2 callout) |
