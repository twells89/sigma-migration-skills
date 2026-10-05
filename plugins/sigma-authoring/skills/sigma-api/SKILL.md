---
name: sigma-api
description: >-
  Authenticate against the Sigma Computing REST API and obtain a bearer token.
  Use whenever the user wants to call the Sigma API directly with curl/HTTP,
  exchange OAuth client credentials for an access token, sign in interactively
  via a browser OAuth login (authorization-code + PKCE), configure
  SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET, troubleshoot 401/403
  responses, or pick the right Sigma API hostname for their cloud. Use as a
  prerequisite when another Sigma skill needs an
  SIGMA_API_TOKEN.
---

# Sigma REST API Authentication

Authenticate against the Sigma Computing REST API and obtain a bearer token. This skill is a prerequisite for any skill that calls the Sigma API directly with `curl`.

The preferred `get-token.sh` path uses the stdlib-only Python 3 provider.
Interactive browser setup additionally requires `curl`, `jq`, and `openssl`;
automatic refresh-token reuse requires macOS `security` or Linux
`secret-tool`. Without a keychain, the initial browser access token still
works but cannot be refreshed. If Python is unavailable, `get-token.sh`
retains a safe client-credentials fallback using `curl`, `jq`, and `base64`.
Browser launch supports macOS, Linux, and Windows/Git Bash, although Windows
does not currently have a keychain persistence backend. Run
`scripts/check-prerequisites.sh sigma-api` from the repository root for a
read-only check.

## Reference Index

| File                                                                 | When to load                                                                                                                                                                                   |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [reference/browser-oauth-login.md](reference/browser-oauth-login.md) | The user wants an interactive browser sign-in (OAuth authorization-code + PKCE) instead of a client ID/secret — the discovery-driven flow, code exchange, and encrypted refresh-token storage. |

## Base URL Selection

The host depends on the user's Sigma cloud and region. Confirm with the user before exporting. The user can also look up their base URL in **Administration → Developer Access** in the Sigma app.

The authoritative list lives in the Sigma help docs: [Supported regions, data platforms, and features](https://help.sigmacomputing.com/docs/region-warehouse-and-feature-support). Mirror below: <!-- pragma: allowlist secret -->

| Cloud | Region                | Base URL                                  |
| ----- | --------------------- | ----------------------------------------- |
| AWS   | US West (Oregon)      | `https://aws-api.sigmacomputing.com`      | <!-- pragma: allowlist secret -->
| AWS   | US East (N. Virginia) | `https://api.us-a.aws.sigmacomputing.com` | <!-- pragma: allowlist secret -->
| AWS   | Canada (Central)      | `https://api.ca.aws.sigmacomputing.com`   | <!-- pragma: allowlist secret -->
| AWS   | Europe (Frankfurt)    | `https://api.eu.aws.sigmacomputing.com`   | <!-- pragma: allowlist secret -->
| AWS   | Asia Pacific (Sydney) | `https://api.au.aws.sigmacomputing.com`   | <!-- pragma: allowlist secret -->
| AWS   | UK (London)           | `https://api.uk.aws.sigmacomputing.com`   | <!-- pragma: allowlist secret -->
| Azure | US (Virginia)         | `https://api.us.azure.sigmacomputing.com` | <!-- pragma: allowlist secret -->
| Azure | Europe (Netherlands)  | `https://api.eu.azure.sigmacomputing.com` | <!-- pragma: allowlist secret -->
| Azure | Canada (Toronto)      | `https://api.ca.azure.sigmacomputing.com` | <!-- pragma: allowlist secret -->
| Azure | UK (London)           | `https://api.uk.azure.sigmacomputing.com` | <!-- pragma: allowlist secret -->
| Azure | Australia             | `https://api.au.azure.sigmacomputing.com` | <!-- pragma: allowlist secret -->
| GCP   | US (Iowa)             | `https://api.sigmacomputing.com`          | <!-- pragma: allowlist secret -->
| GCP   | Saudi Arabia (Dammam) | `https://api.sa.gcp.sigmacomputing.com`   | <!-- pragma: allowlist secret -->

> `SIGMA_BASE_URL` is the **API host**, not the app URL — `https://aws-api.sigmacomputing.com`, not `https://app.sigmacomputing.com`. <!-- pragma: allowlist secret -->

## Step 1 — Configure Authentication

`SIGMA_BASE_URL` is always required:

```sh
export SIGMA_BASE_URL="https://aws-api.sigmacomputing.com"  # adjust per cloud; pragma: allowlist secret
```

For an interactive terminal, prefer a one-time browser sign-in:

```sh
eval "$(bash scripts/browser-login.sh)"
```

It stores the refresh token only in the OS keychain. For unattended hosts,
configure client credentials as the fallback instead:

```sh
export SIGMA_CLIENT_ID="your-client-id"
export SIGMA_CLIENT_SECRET="your-client-secret"
```

Find client credentials in Sigma Administration → APIs and Tokens (also
surfaced as Developer Access → API credentials).

## Step 2 — Get or Refresh a Bearer Token

Call the same helper for initial minting and refresh:

- **Claude Code:** `eval "$(${CLAUDE_PLUGIN_ROOT}/skills/sigma-api/scripts/get-token.sh)"`
- **Cursor / Codex / generic:** `eval "$(bash <repo-root>/skills/sigma-api/scripts/get-token.sh)"`

In the default `auto` mode, `get-token.sh` delegates to
`scripts/get_token.py`: it first serves or refreshes the browser session in the
OS keychain, then falls back to `SIGMA_CLIENT_ID` /
`SIGMA_CLIENT_SECRET`. A valid token already held by a caller should be reused
by that caller until refresh is needed.

Before returning a browser or client-credentials result, the Python provider
verifies the token with `GET /v2/whoami`. It never follows redirects for this
request, so the bearer cannot be forwarded to a redirect target. A 401, 403,
non-JSON response, or redirect fails closed without emitting the token or
writing `auth.json`.

Every successfully verified mint emits:

| Variable | Meaning |
|---|---|
| `SIGMA_API_TOKEN` | Short-lived access token |
| `SIGMA_TOKEN_MINTED_AT` | UTC ISO-8601 mint timestamp |
| `SIGMA_AUTH_METHOD` | `browser` or `client-credentials` |

Select a mode explicitly with `SIGMA_AUTH_MODE` or `--auth-mode`:

```sh
eval "$(bash scripts/get-token.sh --auth-mode browser)"
eval "$(SIGMA_AUTH_MODE=client-credentials bash scripts/get-token.sh)"
```

Allowed values are `auto`, `browser`, and `client-credentials`; the CLI flag
overrides the environment variable. `browser` never falls back to client
credentials, and `client-credentials` never reads the keychain.

### Shell-neutral provider and `auth.json`

PowerShell, cmd.exe, and agent subprocesses need no `eval`:

```sh
python3 scripts/get_token.py --workdir /tmp/sigma-run
```

After `/v2/whoami` succeeds, this writes backward-compatible
`/tmp/sigma-run/auth.json` with mode `0600`. It contains the access token, base
URL, mint timestamp, and auth method—never the refresh token. `--print-token`
prints only the bare token;
`--print-export` prints the three shell exports.

### Manual client-credentials exchange (last-resort fallback)

```sh
CREDENTIALS=$(printf '%s:%s' "$SIGMA_CLIENT_ID" "$SIGMA_CLIENT_SECRET" | base64)

export SIGMA_API_TOKEN=$(curl -sf -X POST \
  -H "Authorization: Basic ${CREDENTIALS}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  "$SIGMA_BASE_URL/v2/auth/token" \
  | jq -r '.access_token')

[ -z "$SIGMA_API_TOKEN" ] || [ "$SIGMA_API_TOKEN" = "null" ] && { echo "Token exchange failed" >&2; exit 1; }
```

### One-time interactive browser login

Sigma supports interactive **OAuth 2.1 authorization-code + PKCE** login—no
pre-issued credentials, because the client registers itself. This is the
preferred setup when a human is at the keyboard; client credentials remain
the fallback for unattended automation.

`scripts/browser-login.sh` packages the whole flow: it reads `SIGMA_BASE_URL`,
discovers the OAuth endpoints, opens your browser, captures the callback,
exchanges the code, stores the refresh token in the OS keychain, and emits the
same token/mint/auth-method exports as `get-token.sh`.

- **Claude Code:** `eval "$(${CLAUDE_PLUGIN_ROOT}/skills/sigma-api/scripts/browser-login.sh)"`
- **Cursor / Codex / generic:** `eval "$(bash <repo-root>/skills/sigma-api/scripts/browser-login.sh)"`

The script picks a random high loopback port that nothing is currently listening on for its redirect URI, so the one-time authorization code is never delivered to another local process. It strips Windows CRLF from PKCE/state values and opens the system browser on macOS, Linux, or Windows/Git Bash. Prompts go to stderr; only the `export` line reaches stdout.

Full discovery-driven walkthrough (including the refresh-token storage the script performs) in **[reference/browser-oauth-login.md](reference/browser-oauth-login.md)** — read it to understand or customize what the script does.

#### Direct browser-only refresh helper

Normally, rerun `get-token.sh`; its default mode already prefers the saved
browser session. `scripts/refresh-token.sh` remains available as a
browser-only compatibility helper. It serves a valid cache and otherwise
redeems—and safely rotates—the keychain refresh token.

- **Claude Code:** `eval "$(${CLAUDE_PLUGIN_ROOT}/skills/sigma-api/scripts/refresh-token.sh)"`
- **Cursor / Codex / generic:** `eval "$(bash <repo-root>/skills/sigma-api/scripts/refresh-token.sh)"`

Run it once per shell (or per phase) and reuse the exported token. If it
reports that the refresh token is expired or revoked, run `browser-login.sh`
again.

## Shared paginated metadata helper

API-dependent skills use `scripts/list-table-columns.sh <table-inode-id>` to
retrieve complete warehouse-table metadata. The underlying endpoint defaults
to 50 columns; the helper requests 1,000 per page and follows the opaque
`nextPageToken` as `pageToken` until it is absent.

```bash
bash scripts/list-table-columns.sh "$INODE_ID" |
  jq '.entries[] | {name, type, visibility}'
```

Never conclude that a warehouse column is missing from only the first API
response. The helper emits one object containing all `entries`, `pageCount`,
and `totalCount`.

## Step 3 — Verify the Token

`GET /v2/whoami` is the canonical sanity check that the token is valid and the
base URL is correct. `scripts/get_token.py` performs this check automatically,
without following redirects, after both browser and client-credentials auth.
Use the manual check below only for a token obtained elsewhere or when
diagnosing a later response:

```sh
curl -sf -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/whoami" | jq .
```

The response includes `userId`, `organizationId`, and `accountType`.

## Token Expiry

Tokens last about an hour. Re-`eval` the helper (or repeat the manual exchange)
to refresh. The bundled Ruby `sigma_rest` wrappers proactively refresh tokens
whose `SIGMA_TOKEN_MINTED_AT` / `auth.json` metadata is at least 50 minutes old,
then still refresh and retry once on 401. Tokens supplied by callers without
valid mint-age metadata are preserved until the server returns 401.

## Interpreting HTTP Status Codes

- **2xx.** Success.
- **401 Unauthorized.** The token is missing, expired, or otherwise not accepted. Re-run the token exchange.
- **403 Forbidden.** The credentials authenticated, but the caller isn't permitted to make this request.
- **404 Not Found.** Wrong path, wrong `SIGMA_BASE_URL` for the user's cloud, or the resource doesn't exist.
- **5xx.** Server-side error. Retry with backoff.

## Security Notes

- Never echo `$SIGMA_API_TOKEN`, `$SIGMA_CLIENT_SECRET`, or any other secret to logs the user can share.
- Don't write secrets to files inside the workspace.
- Treat the bearer token like a password — only pass it via the `Authorization` header, never on a query string.
