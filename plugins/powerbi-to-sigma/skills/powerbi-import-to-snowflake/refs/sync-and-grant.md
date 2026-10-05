# Making Sigma see the newly-landed tables

A freshly created warehouse table is invisible to Sigma until two things happen.
The tool does both when you pass `--sigma-connection <id>`; otherwise do them
manually.

## 1. GRANT (in the generated `load.sql`)

The Sigma connection queries as some Snowflake role (for an OAuth connection,
each user's own role; `PUBLIC` covers everyone). The tool appends:

```sql
GRANT USAGE  ON SCHEMA <db>.<schema>               TO ROLE <grant-role>;   -- default PUBLIC
GRANT SELECT ON ALL TABLES IN SCHEMA <db>.<schema> TO ROLE <grant-role>;
```

Override the role with `--grant-role <ROLE>`; `--grant-role ""` skips grants.

## 2. Connection sync

Even after GRANT, a DM POST fails with:

```
Source not found: warehouse table 'DB.SCHEMA.TABLE' on connection '<uuid>'.
```

…until the connection has indexed the new table. Trigger per table:

```
POST /v2/connections/<connectionId>/sync
Body: {"path": ["<DB>", "<SCHEMA>", "<TABLE>"]}
```

The tool calls this for every landed table. `sigma_sync` delegates auth to the
co-located `scripts/lib/sigma_rest.py`: it reuses a valid caller token, refreshes
a stored browser session before falling back to client credentials, proactively
refreshes tokens with known stale age, and retries one HTTP 401.

Set `SIGMA_BASE_URL` and use one of:

- a current `SIGMA_API_TOKEN`;
- a browser session saved once with `scripts/browser-login.sh`; or
- `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET` for unattended runs.

Sigma sync is optional. If no usable Sigma auth is available, the tool prints a
skip and leaves the completed Snowflake landing intact. A failed table sync is
reported while later tables continue. The endpoint is `/sync` and takes a
`path` body — there is no separate `/lookup` route (404).
