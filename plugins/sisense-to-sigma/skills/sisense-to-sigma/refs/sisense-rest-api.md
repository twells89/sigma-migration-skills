# Sisense REST API — extraction map

Validated live against a Sisense Cloud trial (`signup-jnzavd0c.sisense.com`),
2026-06-17. Sisense Linux/Cloud. Paths differ on older Windows builds — note
the version when something 404s.

## Auth

```
POST /api/v1/authentication/login
  Content-Type: application/x-www-form-urlencoded
  username=<email>&password=<pw>
  -> { success, access_token (JWT), profile, tenantId, roleName, userId }
```

Send `Authorization: Bearer <access_token>` on every subsequent call. Tokens are
long-lived per user. `scripts/sisense-auth.sh` wraps this; it also accepts a
pre-minted `SISENSE_API_TOKEN` and skips login.

> **Access keys ≠ API tokens.** The "Access Keys" / "Web Access Token" feature
> on `/app/settings/rest` produces a **Key ID + public key** for **JWT SSO /
> embedding** — you sign requests with the *private* half. That is the wrong
> mechanism for REST content extraction. Use the bearer token above.

> **TLS.** Trial/self-signed instances can present a cert chain Python's
> verifier rejects (`CA cert does not include key usage extension`) even though
> curl accepts it. `discover.py` retries with an unverified context and warns.

## Data models (ElastiCube / Live)

```
GET /api/v1/elasticubes/getElasticubes
  -> [ { _id, title, datasets[ids], buildDestination.destination, server, type } ]

GET /api/v2/datamodels/schema?title=<title>      # the full export — USE THIS
  -> {
       oid, title, server, relationType,
       datasets: [ {
         oid, type ("extract"|"live"), connection, database, schemaName,
         name, fullname, modelingTransformations[],
         schema: { tables: [ {
           oid, id, name, displayName, type, hidden,
           expression,            # table-level custom SQL (null for plain tables)
           columns: [ {
             id, name, displayName, oid,
             type,                # Sisense numeric type code (see below)
             size, precision, scale, hidden, indexed
           } ]
         } ] }
       } ],
       relations: [ {              # joins — each links two {dataset,table,column}
         oid,
         columns: [ {dataset, table, column, isDropped}, {…} ]
       } ],
       relationsTables: [...]
     }
```

`/api/v2/datamodels` (list, no `?title`) and the legacy
`/api/datasources/{ds}/jaql/metadata` were **not** available on this build
(`Cannot GET` / 404). The `schema?title=` export is the reliable path.

### Column type codes (Sisense `type` int → Sigma)
Observed: `18` = text/string. Full map is TODO — confirm against a numeric and a
date column when populating the converter (see `design-notes.md`).

## Dashboards + widgets

```
GET /api/v1/dashboards                 -> [ { oid, title, datasource, ... } ]
GET /api/v1/dashboards/{oid}           -> dashboard (may inline widgets)
GET /api/v1/dashboards/{oid}/widgets   -> [ widget ]
```

A **widget** carries `type` (e.g. `pivot2`, `indicator`, `chart/column`,
`chart/line`, `chart/pie`, `tablewidget`), `datasource`, and
`metadata.panels[]`. Each panel (`rows`/`columns`/`values`/`filters`) holds
**JAQL** items — `{ jaql: { dim, agg, formula, context, title }, format }`.
JAQL `formula` + `context` is where Sisense measure logic lives → this is the
workbook-side translation surface (see `jaql-mapping.md`).

> The trial currently has **0 dashboards**. Build a sample dashboard on
> `Sample ECommerce` before exercising the widget→workbook path or any parity
> gate.

## Parity (run later)

```
POST /api/datasources/{datasource}/jaql
  body: a JAQL query (the same metadata a widget runs)
  -> aggregated result rows  ->  compare to the Sigma element's query
```

`POST /api/datasources/{ds}/fields/search {offset,count}` lists fields but
returned 400/empty here — prefer the model schema export for field metadata.
