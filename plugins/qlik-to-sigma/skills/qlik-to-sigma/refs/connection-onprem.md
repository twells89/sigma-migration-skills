# Qlik connection — CLIENT-MANAGED (on-prem Qlik Sense Enterprise on Windows)

qlik-cli only speaks Qlik **Cloud**. For client-managed Sense, the skill ships
`scripts/qlik-onprem-shim.py` — a qlik-cli-compatible shim backed by the on-prem
APIs (QRS REST + Engine/QIX JSON-RPC over WebSocket). It accepts the exact
command subset discovery uses and emits the **same output shapes**, so the whole
pipeline runs unchanged:

```bash
pip3 install websocket-client            # the Engine transport (PEP 668 machines:
                                         #   pip3 install --user websocket-client, or use a venv)
source ~/.sigma-migration/qlik-onprem.env
export QLIK_BIN="$PWD/scripts/qlik-onprem-shim.py"   # qlik-discover.py honors QLIK_BIN
python3 scripts/qlik-discover.py --app <appId> --out extract/
```

Everything downstream (converter, DM/workbook build, parity) is identical to Cloud.

> **Validation status:** the shim's Engine/QIX layer is **live-verified** — a full
> discovery run through the shim produced output **identical (order-insensitive)**
> to a qlik-cli run on the same app (script, charts, master items, layout, KPI/
> bucket snapshot values). The QIX protocol is the same on-prem and Cloud. The
> **QRS layer and on-prem auth bootstrap are code-complete but not yet live-run**
> (Cloud has no QRS) — on your first on-prem engagement, expect to debug there
> first, not in discovery/conversion. Without QRS, only `appName`/`lastReloadTime`
> metadata degrade — discovery still completes.

> **QlikView is NOT covered.** It's a different product (.qvw + the old QMS API,
> no QIX engine surface in this form). If the customer says "Qlik on-prem",
> confirm Sense Enterprise on Windows vs QlikView before scoping.

## First: which product / what to ask the customer

- Product + version: **Qlik Sense Enterprise on Windows** (this doc) vs QlikView (out of scope).
- Server hostname; which ports are reachable (443 always; 4242/4747 for the certs path).
- Auth path: can they export certificates from the QMC, or would they rather add a
  JWT virtual proxy? (Ranked below.)
- A **service account in their user directory** with read access to the streams
  being migrated.
- Are app data sources warehouse-backed, or QVD/file-fed? (See "Data reality" below.)

## Auth path 1 — certificates (best for automation, zero proxy config)

1. QMC → **Certificates** → export for the machine running the skill (PEM format)
   → you get `client.pem`, `client_key.pem`, `root.pem`.
2. Firewall: the skill machine must reach **4242** (QRS) and **4747** (Engine).
3. Env (`~/.sigma-migration/qlik-onprem.env`):

```bash
export QLIK_ONPREM_SERVER=qlik.example.com
export QLIK_ONPREM_AUTH=certs
export QLIK_ONPREM_CERTS=/path/to/exported/certs     # client.pem, client_key.pem, root.pem
export QLIK_ONPREM_USER_DIRECTORY=ACME               # the service account
export QLIK_ONPREM_USER_ID=svc_migration
# optional: QLIK_ONPREM_QRS_PORT (4242), QLIK_ONPREM_ENGINE_PORT (4747)
```

Certificate auth sends `X-Qlik-User: UserDirectory=<dir>; UserId=<user>` — the
calls run **as that user**, so stream/Section Access visibility applies. Use a
service account with read access to everything in scope (not sa_repository).

## Auth path 2 — JWT virtual proxy (everything over 443)

1. Admin: QMC → Virtual proxies → add one with **JWT** authentication, upload the
   JWT-signing cert, set a prefix (e.g. `jwt`), attribute mappings for
   userId/userDirectory. Mint a JWT signed with the matching key.
2. Env:

```bash
export QLIK_ONPREM_SERVER=qlik.example.com
export QLIK_ONPREM_AUTH=jwt
export QLIK_ONPREM_VPROXY=jwt          # the virtual proxy prefix ('' if mounted at root)
export QLIK_ONPREM_JWT=<token>
```

(Header-auth virtual proxies also work mechanically — same env shape with the
proxy trusting a header — but they're impersonation-by-header; only on locked-down
networks. NTLM/Windows auth is not supported by the shim: fine for curl, miserable
for WebSockets.)

`QLIK_ONPREM_INSECURE=1` skips TLS verification — common with self-signed
QRS/proxy certs; prefer pointing at `root.pem` when you have it.

## What the shim supports (and deliberately doesn't)

Supported (the discovery surface): `item ls` (QRS `/qrs/app/full`, mapped to the
Cloud item shape — `stream` ≈ `space`), `app script get`, `app object ls`,
`app object properties` (resolves generic objects AND master measures/dimensions),
`app measure|dimension ls/properties`, `app eval`.

Not supported, loudly:
- `raw get` — Cloud REST only; `qlik-screenshot.py` is a Cloud nicety, skip it
  on-prem (grab screenshots from the Hub manually for the visual gate).
- `app object set/rm` — the **assessment** skill's temp-object trick would require
  `DoSave` WRITES to the customer app. The assessment inventory is Cloud-only for
  now; converter-side discovery gets master items via `measure|dimension ls`,
  which doesn't need it.

## Data reality on-prem (read before promising parity)

On-prem apps are far more often **QVD/file-fed** than Cloud apps. Sigma reads a
warehouse live, so the repoint step (load script `LIB CONNECT` → warehouse, or
landing the QVD data into the warehouse) is usually the bigger share of on-prem
work — the API plumbing above is the easy part. Same principle as Cloud: feed the
converter the **Qlik model** (the load script is extracted either way), then make
sure the data exists in the warehouse Sigma queries. Reloads on-prem are triggered
via QMC tasks (no impersonated-reload gotcha like Cloud M2M, but reload rights on
the service account are still needed if you repoint the app itself).
