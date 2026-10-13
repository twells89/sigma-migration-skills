# Spotfire Library REST API v2 transport

> **LIVE-UNVALIDATED.** This transport is implemented from official public
> Spotfire documentation and unit-tested for URL/method construction, but has
> not been exercised against a real Spotfire tenant. Treat response
> completeness, ACL visibility, and Spotfire Cloud availability as unknown
> until proven on the target deployment.

## Version boundary and official sources

Library REST API v2 was introduced in Spotfire Server 14.0. The assessment uses
the v2 contract documented at:

- [Spotfire Server Library REST API v2 (latest)](https://docs.tibco.com/pub/spotfire_server/latest/doc/api/TIB_sfire_server_REST_API_Reference/library-v2.html)
- [Spotfire Server 14.0.8 Library REST API v2](https://docs.tibco.com/pub/spotfire_server/14.0.8/doc/api/TIB_sfire_server_REST_API_Reference/library-v2.html)
- [Spotfire item types](https://docs.tibco.com/pub/spotfire_server/14.6.3/doc/html/TIB_sfire_server_tsas_admin_help/server/topics/spotfire_item_types.html)

The endpoint base in the official reference is:

```text
https://<server>/spotfire/api/rest/library/v2
```

The script performs exactly:

```text
GET /info
GET /items?maxResults=0&attributes=all
```

`maxResults=0` asks for all matching items under the documented contract.
Only items visible to the OAuth principal are returned. An incomplete
principal therefore yields an incomplete inventory without proving the rest
of the estate is empty.

The official item type for an analysis file is `spotfire.dxp`. The assessment
also counts folders, data functions, scripts, data connections, information
links, and visualization mods by their documented item type. It does not call
`GET /items/{id}/contents`: the same API documentation says downloaded
content should be treated as opaque unless it uses a publicly documented
format.

## OAuth

Required scope: **`api.library.read`** only. Do not register or request
`api.library.write` for this assessment.

The official authorization-server paths are:

```text
metadata: https://<server>/spotfire/.well-known/oauth-authorization-server
token:    https://<server>/spotfire/oauth2/token
```

A headless confidential client is normally registered for the
`client_credentials` grant and `api.library.read`. The script accepts either:

- `SPOTFIRE_ACCESS_TOKEN` (preferred; no token request by the script), or
- `SPOTFIRE_CLIENT_ID` + `SPOTFIRE_CLIENT_SECRET`.

The default token authentication method is `client_secret_basic`.
Set `SPOTFIRE_TOKEN_AUTH_METHOD=post` only if the client was registered for
`client_secret_post`. Token minting is an OAuth authentication exchange and
does not mutate Library content. Tokens and secrets are never written to
assessment output.

## Pre-14 fallback

When `--server-version` has a major version below 14, live mode stops before
authentication or Library calls. Use:

```bash
python3 scripts/assess.py --manifest exported.json --out <dir>
# or
python3 scripts/assess.py --inventory normalized-dxp-inventory.json --out <dir>
```

The export must be obtained through an authorized local/admin process suitable
for that deployment. This skill does not ship a legacy endpoint scraper,
database reader, or DXP binary parser.

## Spotfire Cloud uncertainty

Spotfire Cloud topology, OAuth client registration, URL routing, and scope
availability can differ by tenant/plan and are not established by the public
Server reference alone. Before a Cloud run, confirm with the tenant
administrator that:

1. Library REST API v2 is enabled and routable;
2. an API client can be registered with `api.library.read`;
3. the principal can see the intended folders; and
4. data-processing/privacy terms allow metadata export.

If any point is uncertain, use an approved offline manifest and preserve the
evidence-tier disclosure.

## Read-only audit

The source contains no generic request method for live Library access:
`LibraryClient` exposes `get`, `info`, and `items`. Unit tests assert the item
request uses HTTP GET and the documented `/spotfire/api/rest/library/v2`
prefix. The assessment imports no Sigma client and has no Sigma endpoint.
