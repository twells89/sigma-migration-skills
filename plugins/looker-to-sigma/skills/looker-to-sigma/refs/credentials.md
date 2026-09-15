<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. Looker + Sigma credentials, and the Looker-side warehouse connection. -->

# Prerequisites — credentials and connections

### Looker credentials (`~/.looker/looker.ini`)

```ini
[Looker]
base_url=https://<your-instance>.cloud.looker.com
client_id=<API3 client_id>
client_secret=<API3 client_secret>
verify_ssl=True
```

- **API 4.0**, key-pair-free `client_credentials`. Modern Google-hosted Looker serves the API on
  the standard **443** at `https://<instance>.cloud.looker.com/api/4.0` — no port needed. Older
  self-hosted instances used the legacy `:19999`; if your `base_url` still carries it and that
  port is unreachable, the client **self-heals**: it retries on 443 and warns you to update the
  ini. You can also override the base without editing the ini via `LOOKER_BASE_URL`
  (or `LOOKERSDK_BASE_URL`).
- **TLS:** requests use the OS trust store via `truststore` (installed by `bash scripts/bootstrap.sh`),
  so Python's stricter OpenSSL 3.x accepts the same certs curl/Ruby do; it falls back to certifi
  then the stock bundle. Leave `verify_ssl=True` (setting it false disables verification and warns).
- The credential's user needs **Admin** (or at least: see models, dashboards, run queries, and
  — for the test-fixture builders or Git-deploy flow — develop + deploy).
- Generate an API3 key in Looker: **Admin → Users → (your user) → Edit Keys → New API3 Key**.
- Test: `python3 scripts/looker_api.py whoami` → prints HTTP 200, your display name + roles.

### Sigma credentials

`eval "$(scripts/get-token.sh)"` exchanges `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` (from
`~/.sigma-migration/env`, written by the `sigma-api` skill's `setup.rb`) for a `SIGMA_API_TOKEN`.
Also note your **full connection UUID** (`SIGMA_CONNECTION_ID`) and a writable **folderId**.

> Tokens live ~1 hour. Re-fetch when a curl returns 401. Never use
> `TOKEN=$(eval "$(scripts/get-token.sh)")` — `$()` is a subshell where the exported var dies.
> Keep `eval` + `curl` in the same `bash -c '...'` invocation.

> **Inline Python/Node inside bash — DON'T.** Triple-nested escapes silently break. Always
> write a `.py`/`.mjs` file with `Write` and call it via `python3 file.py` / `node file.mjs`.
> The scripts here already follow that rule.

### The Looker-side warehouse connection (one-time, for live parity)

Looker needs its **own** direct warehouse auth — Sigma's connection UUID is Sigma-side and
unusable for Looker. To stand up an end-to-end test pointed at the same warehouse as Sigma
(so 3-way parity is meaningful):

- **Snowflake service identity:** create a `SERVICE`-type user with **key-pair** auth (Snowflake
  blocks single-factor passwords for service users) + a role granting USAGE on the warehouse +
  the db/schema and SELECT on the tables/views.
- **Looker connection** (`POST /connections`): `uses_key_pair_auth: true`, `certificate` =
  base64 of the `.p8` private key, `file_type: ".p8"`, warehouse via
  `jdbc_additional_params=warehouse=<WH>`, host `<account>.snowflakecomputing.com`. Test via
  `PUT /connections/{name}/test`.
- **Git-backed project + model:** create a project in the **dev** workspace, add a deploy key to
  the Git repo, set the git remote via **`PATCH /projects/{id}`** (PUT 404s). All dev-workspace
  mutations need **ONE persistent session** (`PATCH /session {workspace_id: dev}`).

> This setup is only needed to build a *live* test instance. For a customer migration the Looker
> instance + connection already exist — you just read from them.
