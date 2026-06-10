---
name: tableau-vds-to-cdw
description: >-
  Extract data from a published Tableau datasource via the VizQL Data Service
  (VDS) API and land it in a cloud data warehouse — Snowflake or Databricks — so
  Sigma can read it. Use when a user wants to pull a Tableau-managed dataset into
  the warehouse (one-shot or scheduled refresh) without exporting CSV by hand.
  Optionally schedule ongoing refresh (Snowflake Task / Databricks Workflow).
user-invocable: true
---

# Tableau VDS → Cloud Data Warehouse (CDW)

Extract data from a published Tableau datasource via the VizQL Data Service (VDS) API
and land it in a cloud data warehouse so Sigma can build on it. The **Tableau/VDS
extraction half is warehouse-agnostic** — only the *landing* step changes per target.

**Supported targets:**

| Target | Landing mechanism | Section |
|---|---|---|
| **Snowflake** | Stored procedure + External Access Integration, scheduled with a Task | [Part A](#part-a--land-in-snowflake) |
| **Databricks** | Notebook on **serverless** compute + secret scope, scheduled with a Workflow | [Part B](#part-b--land-in-databricks) |
| BigQuery | Not built yet — the extraction half ports directly; landing = a Cloud Function / scheduled query. File an issue if needed. | — |

Both Snowflake and Databricks paths are validated end-to-end with **parity verified in
Sigma** against the landed table (Superstore: 10,192 rows, exact on Technology/Office
Supplies, expected null-key row-level drift on the total — see Column types).

---

## When this skill applies (and when it doesn't) — shared

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
   Server-side compute in the warehouse
   (Snowflake stored proc  |  Databricks notebook)
   - signs in to Tableau REST API
   - calls VDS query endpoint
   - creates/replaces target table
   - loads rows
        │
        ▼
   Warehouse table  ──▶  Sigma Workbook
```

The extraction + load runs **server-side** (Snowflake proc / Databricks job), so
**no data touches Claude or the local machine** — the warehouse fetches directly
from Tableau. The local CLI only orchestrates (deploys the proc/notebook, kicks
off the run, polls status).

---

## Phase 1 — Discover the datasource LUID (shared)

### Option A: Tableau MCP tool
```
mcp__tableau__list-datasources
```
Returns a list with `id` (the LUID) and `name`. Use the `id` value.

If the datasource you expect isn't in the list, it's almost certainly
embedded in a workbook rather than published. See the callout above.

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

### Finding fields available on a datasource
Use the MCP metadata tool:
```
mcp__tableau__get-datasource-metadata  datasourceLuid="<luid>"
```
The response includes **all CALCULATION fields with their Tableau formulas** —
that's the right input for translating calc fields into the downstream Sigma
DM. See `../tableau-to-sigma/scripts/extract-calc-fields.rb` for a pre-built
extractor + translation-notes generator.

Or query the VDS metadata endpoint directly:
```bash
curl -s -X POST "https://<server>/api/v1/vizql-data-service/read-metadata" \
  -H "x-tableau-auth: $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"datasource": {"datasourceLuid": "<luid>"}}' | python3 -m json.tool
```

### Building the `fields` array (used by both targets)
Each field is one of:
- `{"fieldCaption": "Category"}` — dimension (no aggregation)
- `{"fieldCaption": "Sales", "function": "SUM", "fieldAlias": "Total Sales"}` — measure

Supported `function` values: `SUM`, `AVG`, `MEDIAN`, `COUNT`, `COUNTD`, `MIN`, `MAX`.

> **To land row-level facts (most common for downstream Sigma DM authoring), omit
> `function` from every field.** With `function`, VDS aggregates server-side
> and returns a much smaller result set — fine for a pre-rolled-up extract,
> usually not what you want for a flexible Sigma workbook.

---
---

# Part A — Land in Snowflake

## Prerequisites (Snowflake)

### Tableau
- A **published** datasource, a PAT (name + secret), the datasource LUID, and the
  site `contentUrl` — all from Phase 1.

### Snowflake
- A database and schema to write to (e.g. `TJ.PUBLIC`)
- A role with `CREATE NETWORK RULE`, `CREATE SECRET`, `CREATE INTEGRATION`, `CREATE PROCEDURE`, `CREATE TABLE` privileges
  - In the TSE sandbox: `SNOWFLAKE_SANDBOX_TSE_PUSH_GROUP`
- A running warehouse (e.g. `SIGMA_WH`)
- Snowflake CLI (`snow`) configured with key-pair JWT auth:
  - Config: `~/.snowflake/config.toml`
  - Test: `snow sql -q "SELECT CURRENT_USER()" --connection <conn>`

## Phase A2 — Set up Snowflake objects (one-time per account + schema)

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

If all four exist (and you trust the PAT secret is current), jump to Phase A3.

The rest of this phase covers first-time setup. Replace `TJ.PUBLIC` throughout.

### A2a. Network rule + secret + EAI

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

### A2b. Stored procedure

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

## Phase A3 — Run the load

Build the `fields_json` array per the shared "Building the `fields` array" section.
Use `mcp__tableau__get-datasource-metadata` to list available field captions.

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
snow sql --connection <conn> --format json -q "
SELECT COUNT(*) AS n FROM <db>.<schema>.<TABLE_NAME>;
SELECT * FROM <db>.<schema>.<TABLE_NAME> LIMIT 3;
" | python3 -m json.tool
```

## Phase A4 — Schedule with a Snowflake Task (optional)

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

### Worked example: Superstore Datasource → TJ.PUBLIC.SUPERSTORE_ORDERS

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
    {\"fieldCaption\": \"Order ID\"}, {\"fieldCaption\": \"Order Date\"},
    {\"fieldCaption\": \"Ship Date\"}, {\"fieldCaption\": \"Customer Name\"},
    {\"fieldCaption\": \"Segment\"}, {\"fieldCaption\": \"Country/Region\"},
    {\"fieldCaption\": \"State/Province\"}, {\"fieldCaption\": \"Category\"},
    {\"fieldCaption\": \"Sub-Category\"}, {\"fieldCaption\": \"Sales\"},
    {\"fieldCaption\": \"Profit\"}, {\"fieldCaption\": \"Quantity\"},
    {\"fieldCaption\": \"Discount\"}
  ]'
);
"
# → Loaded 10192 rows into TJ.PUBLIC.SUPERSTORE_ORDERS
```

19 columns landed (`Country/Region` → `COUNTRY_REGION`, `Sub-Category` → `SUB_CATEGORY`
from the slash/hyphen → `_` sanitizer). KPI parity with the Tableau Executive Overview
was within 0.02% on Sales/Profit/Quantity — exact on Profit Ratio and Discount.

---
---

# Part B — Land in Databricks

The Databricks path is **simpler than Snowflake** — the entire EAI + network-rule
egress phase disappears, because cluster/serverless compute has outbound internet
by default. The mapping:

| Snowflake | Databricks |
|---|---|
| Stored proc (Snowpark) | A **notebook** on **serverless** compute |
| EAI + network rule + secret | **Just a secret scope** — no network plumbing |
| `df.write.save_as_table` | `df.write.saveAsTable` → Delta table in Unity Catalog |
| Snowflake Task | Databricks **Workflow** schedule |

## Prerequisites (Databricks)

- A **published** Tableau datasource + PAT + LUID + site (Phase 1).
- A **Databricks workspace** URL (e.g. `https://dbc-xxxx.cloud.databricks.com`) and a
  workspace **PAT** (User Settings → Developer → Access tokens).
- The **Databricks CLI** (v0.205+, the unified Go CLI):
  ```bash
  brew install databricks/tap/databricks
  ```
  Configure a profile (host + token) — either `~/.databrickscfg`:
  ```ini
  [myprofile]
  host  = https://dbc-xxxx.cloud.databricks.com
  token = dapi...
  ```
  or via env: `export DATABRICKS_HOST=... DATABRICKS_TOKEN=...`. Verify:
  ```bash
  databricks current-user me -p myprofile
  ```
  > **zsh gotcha:** do NOT pass the profile via an unquoted shell var
  > (`P="-p myprofile"; databricks ... $P`). zsh does **not** word-split unquoted
  > expansions, so the CLI receives one arg `" myprofile"` and errors
  > `has no  myprofile profile configured`. Use the literal flag `-p myprofile`
  > or `export DATABRICKS_CONFIG_PROFILE=myprofile`.
- **Compute:** a notebook Job on **serverless** (recommended — see below). No
  all-purpose cluster required.
- **A Unity Catalog target you can write to** — `catalog.schema.table`. Confirm your
  principal has `CREATE SCHEMA` / `CREATE TABLE` **before** running (see Phase B0).

## Phase B0 — Confirm write privileges (do this first)

> **Unity Catalog privilege ≠ workspace admin.** Being a workspace/account admin does
> NOT grant UC table-create rights. A run that extracts fine from Tableau will still
> fail at `CREATE SCHEMA` with `PERMISSION_DENIED` if your principal lacks the grant.
> Check the target catalog's grants up front:

```bash
databricks grants get catalog <catalog> -p myprofile -o json \
  | python3 -c "import sys,json; [print(a['principal'], a['privileges']) for a in json.load(sys.stdin).get('privilege_assignments',[])]"
```

Look for `ALL_PRIVILEGES` or `CREATE_SCHEMA`+`CREATE_TABLE` on one of *your* groups.
Pick a catalog where you have it (or ask the workspace owner to grant it).

## Phase B1 — Store the Tableau PAT in a secret scope

```bash
databricks secrets create-scope <scope> -p myprofile      # e.g. tableau_vds
databricks secrets put-secret <scope> tableau_pat_name   --string-value "<pat_name>"   -p myprofile
databricks secrets put-secret <scope> tableau_pat_secret --string-value "<pat_secret>" -p myprofile
databricks secrets list-secrets <scope> -p myprofile      # confirm both keys
```

## Phase B2 — Author the notebook

Write to `/tmp/vds_to_delta.py` (Databricks `SOURCE` notebook — the `# Databricks
notebook source` first line and `# COMMAND ----------` cell separators matter):

```python
# Databricks notebook source
import requests, re, json
from datetime import datetime, timezone

server      = dbutils.widgets.get("server")        # https://10ay.online.tableau.com
site        = dbutils.widgets.get("site")          # contentUrl, e.g. dataflow
luid        = dbutils.widgets.get("luid")          # datasource LUID
target      = dbutils.widgets.get("target")        # catalog.schema.table
fields_json = dbutils.widgets.get("fields")        # VDS fields array (JSON string)

pat_name   = dbutils.secrets.get("<scope>", "tableau_pat_name")
pat_secret = dbutils.secrets.get("<scope>", "tableau_pat_secret")

# Sign in — Tableau returns XML; parse with regex (NOT jq/json)
signin = requests.post(
    f"{server}/api/3.21/auth/signin",
    headers={"Content-Type": "application/json"},
    json={"credentials": {
        "personalAccessTokenName": pat_name,
        "personalAccessTokenSecret": pat_secret,
        "site": {"contentUrl": site},
    }},
    timeout=30,
)
signin.raise_for_status()
tok = re.search(r'token="([^"]+)"', signin.text).group(1)

# Query VDS
resp = requests.post(
    f"{server}/api/v1/vizql-data-service/query-datasource",
    headers={"x-tableau-auth": tok, "Content-Type": "application/json"},
    json={
        "datasource": {"datasourceLuid": luid},
        "query": {"fields": json.loads(fields_json)},
        "options": {"returnFormat": "OBJECTS"},
    },
    timeout=300,
)
resp.raise_for_status()
rows = resp.json()["data"]
if not rows:
    dbutils.notebook.exit("No rows returned")

# Sanitize column names to UPPER_SNAKE_CASE (mirror the Snowflake proc)
orig_cols = list(rows[0].keys())
safe_cols = [re.sub(r"[^A-Z0-9_]", "_", c.upper()) for c in orig_cols]
data = [tuple(r.get(c) for c in orig_cols) for r in rows]

df = spark.createDataFrame(data, schema=safe_cols)
cat, sch, tbl = target.split(".")
spark.sql(f"CREATE SCHEMA IF NOT EXISTS `{cat}`.`{sch}`")
df.write.mode("overwrite").saveAsTable(target)

n = spark.table(target).count()
dbutils.notebook.exit(json.dumps({"rows": n, "target": target,
                                  "loaded_at": datetime.now(timezone.utc).isoformat()}))
```

Import it into the workspace:
```bash
databricks workspace import "/Users/<you>@<org>/vds_to_delta" \
  --file /tmp/vds_to_delta.py --language PYTHON --format SOURCE --overwrite -p myprofile
```

## Phase B3 — Run the load (serverless Job)

> **Why serverless:** SQL warehouses can't run the Python `requests` call, and
> workspaces often have no all-purpose cluster. A Job **notebook task with no
> cluster spec runs on serverless automatically** (in workspaces with serverless
> enabled) — no cluster to create or pay to keep warm.

Write the run request to `/tmp/vds_run.json` (the `fields` value is a JSON **string**):

```json
{
  "run_name": "vds_to_delta",
  "tasks": [{
    "task_key": "vds_to_delta",
    "notebook_task": {
      "notebook_path": "/Users/<you>@<org>/vds_to_delta",
      "base_parameters": {
        "server": "https://<server>",
        "site": "<site_name>",
        "luid": "<datasource_luid>",
        "target": "<catalog>.<schema>.<TABLE_NAME>",
        "fields": "[{\"fieldCaption\": \"Category\"}, {\"fieldCaption\": \"Sales\"}]"
      }
    }
  }]
}
```

Submit and poll:
```bash
RID=$(databricks jobs submit --json @/tmp/vds_run.json --no-wait -p myprofile \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['run_id'])")
# poll until life_cycle_state == TERMINATED
databricks jobs get-run $RID -p myprofile -o json \
  | python3 -c "import sys,json; s=json.load(sys.stdin)['state']; print(s.get('life_cycle_state'), s.get('result_state'))"
# read the notebook exit value (row count) / error
TR=$(databricks jobs get-run $RID -p myprofile -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['tasks'][0]['run_id'])")
databricks jobs get-run-output $TR -p myprofile -o json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('EXIT:', d.get('notebook_output',{}).get('result')); print('ERR:', d.get('error'))"
```

### Verify the load (no warehouse needed)
```bash
databricks tables get <catalog>.<schema>.<TABLE_NAME> -p myprofile -o json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data_source_format'], d['table_type']); [print(' ',c['name'],c['type_text']) for c in d['columns']]"
```

## Phase B4 — Schedule with a Workflow (optional)

Persist a Job with a `schedule` (instead of one-shot `submit`):
```bash
databricks jobs create --json '{
  "name": "refresh_tableau_data",
  "schedule": {"quartz_cron_expression": "0 0 6 * * ?", "timezone_id": "America/Los_Angeles"},
  "tasks": [{"task_key": "vds_to_delta",
             "notebook_task": {"notebook_path": "/Users/<you>@<org>/vds_to_delta",
                               "base_parameters": { "...": "same as B3" }}}]
}' -p myprofile
```

### Worked example (validated 2026-06-10)
Superstore (LUID `1bef4413-…`, Tableau `10ay`/`dataflow`) → serverless notebook →
`customer_success.tj_vds_spike.superstore_orders` (managed **Delta**): **10,192 rows**,
13 columns, same sanitization as Snowflake (`Country/Region`→`COUNTRY_REGION`,
`Sub-Category`→`SUB_CATEGORY`). Sigma read it back via a Databricks connection on the
same workspace — Technology/Office Supplies SUM(Sales) exact, total within 0.02%
(null-key row-level drift, see below).

---
---

## Column types — what actually lands (shared)

Both targets infer types from the data:

| Tableau field type | Snowflake | Databricks |
|---|---|---|
| `REAL` / `INTEGER` measures | `FLOAT` / `NUMBER(38,0)` | `double` / `bigint` |
| `STRING` dimensions | `VARCHAR` | `string` |
| `DATE` / `DATETIME` | `VARCHAR` (ISO string) | `string` (ISO string) |

**Dates land as strings** on both — VDS returns ISO strings like `2022-11-07T00:00:00`.
Sigma introspects and auto-types them as `datetime`. Downstream Sigma DM column
formulas should use `Date([SOURCE/Col Name])` directly:

```json
{ "id": "so-order-date", "name": "Order Date",
  "formula": "Date([SUPERSTORE_ORDERS/Order Date])" }
```

> **Do NOT use the `Date(Left(Text([col]), 10))` pattern here.** That works for integer
> YYYYMMDD date keys (see `../tableau-to-sigma/refs/column-gotchas.md`) but fails on the
> VARCHAR/string ISO datetimes VDS produces, because Sigma auto-types them as `datetime`
> at the DM column level and `Left()` doesn't compile against datetime.

> **Row-level drift (both targets):** when landing row-level facts (no `function`),
> expect the table's row count and re-aggregated measures to differ slightly from a
> *server-side aggregated* VDS query — VDS drops rows with NULL key fields (~0.02%;
> measured Superstore 10,192 landed vs ~10,194 canonical). This is expected, not a bug.

Optional: create a typed view to lock down explicit casts (Snowflake shown; Databricks
is the same with `CREATE OR REPLACE VIEW <cat>.<sch>.<tbl>_TYPED AS ...`):

```sql
CREATE OR REPLACE VIEW <db>.<schema>.<TABLE_NAME>_TYPED AS
SELECT
  CATEGORY::VARCHAR        AS CATEGORY,
  ORDER_DATE::DATE         AS ORDER_DATE,
  TOTAL_SALES::FLOAT       AS TOTAL_SALES
FROM <db>.<schema>.<TABLE_NAME>;
```

## Sigma column-metadata cache lag (shared)

After a `CREATE OR REPLACE TABLE` / `saveAsTable` (which is what the load does every
run), Sigma's cached **catalog** metadata for that table may be stale until Sigma
re-syncs:
- The data is correct; the column *index* is what's stale.
- Adding columns is harmless (surviving column refs keep working). Removing columns:
  wait for re-sync (minutes) or refresh in the Sigma connection UI.
- There's no public API to force a connection re-sync today.
- **Workaround for verification:** source via **raw Custom SQL** (`source.kind: sql`)
  rather than the catalog table — raw SQL executes directly and bypasses the stale
  catalog index. (This is exactly how the parity check reads a just-landed table.)

---

## Troubleshooting

### Tableau / VDS (shared)
| Error / symptom | Cause | Fix |
|---|---|---|
| Expected datasource not in `list-datasources` | Embedded in a workbook, not published | Publish the datasource separately in Tableau Cloud — VDS only sees published datasources |
| `404` on `/api/v1/sites/.../datasources/.../query` | Wrong VDS URL | Use `/api/v1/vizql-data-service/query-datasource` with `datasource.datasourceLuid` in body |
| `401` on VDS query | PAT token expired (~hours) or wrong header name | Re-authenticate; confirm header is `x-tableau-auth` not `Authorization` |
| `json.decoder.JSONDecodeError` on auth | Tableau signin returns XML, not JSON | Parse with `re.search(r'token="([^"]+)"', resp.text)` |
| VDS returns `{"error": "datasource not found"}` | LUID wrong or datasource moved/deleted | Re-fetch LUID via `list-datasources` |
| Row count ~0.02% below Tableau total | VDS drops rows with NULL key fields | Expected drift; investigate only if exact parity required |
| Columns with spaces/slashes/hyphens get `_` substitution | `re.sub(r'[^A-Z0-9_]','_',c.upper())` sanitizer | Expected — use a typed view or rename in the Sigma DM |
| Sigma DM column type `error` for a date | Date landed as VARCHAR/string; Sigma auto-types datetime; `Left()`/`Text()` won't compile | Use `Date([SOURCE/Col Name])` directly |

### Snowflake landing
| Error / symptom | Cause | Fix |
|---|---|---|
| EAI creation: "Network rule not found" | FQN required | Use `<db>.<schema>.tableau_api_rule` in `ALLOWED_NETWORK_RULES` |
| Procedure: "secret not found" | Secret must be fully qualified | Use `<db>.<schema>.tableau_pat_secret` in `SECRETS = (...)` |
| `requests.exceptions.ConnectionError` in proc | EAI not attached, or host mismatch | Confirm `EXTERNAL_ACCESS_INTEGRATIONS = (tableau_vds_eai)` in the DDL; host in network rule matches exactly |
| Setup re-runs every conversion | Phase A2 treated as per-conversion | A2 is one-time per account + schema; check existing infra first |
| Task runs but table empty | PAT expired (max TTL) | Rotate PAT → `ALTER SECRET tableau_pat_secret SET SECRET_STRING = '...'` |

### Databricks landing
| Error / symptom | Cause | Fix |
|---|---|---|
| `PERMISSION_DENIED: no CREATE SCHEMA on <catalog>` | UC privilege ≠ workspace admin | Run Phase B0 grant check; pick a catalog where your group has `CREATE_SCHEMA`/`ALL_PRIVILEGES`, or ask the owner |
| `has no  <profile> profile configured` (double space) | zsh didn't word-split an unquoted `$VAR` holding `-p <profile>` | Use literal `-p <profile>` or `export DATABRICKS_CONFIG_PROFILE=<profile>` |
| Job needs a cluster / no all-purpose cluster exists | Notebook task given no compute and serverless disabled | Enable serverless for notebooks/jobs, or add a `job_clusters` spec; SQL warehouses can't run the `requests` call |
| `INTERNAL_ERROR` with no detail in `get-run` | Real error is in the task run output | `get-run-output <task_run_id>` → read `error` / `error_trace` |
| Sigma can't see the just-landed table | Connection catalog metadata cache lag | Verify via raw Custom SQL (`source.kind: sql`), or refresh the connection in the Sigma UI |
