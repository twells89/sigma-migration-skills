# Interactive Browser Login (OAuth authorization-code + PKCE)

Use this for the preferred interactive setup when a human is at the keyboard.
It needs no pre-issued credentials—the client registers itself. After this
one-time login, the canonical `scripts/get_token.py` provider refreshes the
keychain session headlessly and falls back to client credentials when
available. Client credentials remain useful for unattended hosts.

> **Just want to log in?** `scripts/browser-login.sh` performs every step below
> end to end
> (`eval "$(bash <repo-root>/skills/sigma-api/scripts/browser-login.sh)"`),
> including capturing the redirect automatically (§D). Later, rerun
> `get-token.sh` (default `auto` mode) to use the cached/refreshable browser
> session first. The walkthrough here explains the underlying flow.

The flow is **discovery-driven**: you don't hardcode any endpoints — you read them from `/v2/whoami`. If `SIGMA_BASE_URL` is unset, ask the user which cloud they're on (see the Base URL table in `SKILL.md`).

## A. Discover the OAuth endpoints from `/v2/whoami`

An unauthenticated `GET /v2/whoami` answers `401` with a `WWW-Authenticate` header that points at the discovery chain. Follow it:

```sh
# 1. The 401 names the protected-resource metadata URL and the required scope.
WWW_AUTH=$(curl -sS -D - -o /dev/null "$SIGMA_BASE_URL/v2/whoami" | grep -i '^www-authenticate:')
RESOURCE_META=$(printf '%s' "$WWW_AUTH" | grep -oE 'resource_metadata="[^"]+"' | cut -d'"' -f2)
SCOPE=$(printf '%s' "$WWW_AUTH" | grep -oE 'scope="[^"]+"' | cut -d'"' -f2)   # e.g. api:access

# If /v2/whoami did NOT return a WWW-Authenticate header, this host doesn't
# offer browser login — fall back to the client-credentials flow in SKILL.md.

# 2. Protected-resource metadata → the authorization server.
AUTH_SERVER=$(curl -sS "$RESOURCE_META" | jq -r '.authorization_servers[0]')

# 3. Authorization-server metadata → the three endpoint URLs.
META=$(curl -sS "$AUTH_SERVER/.well-known/oauth-authorization-server")
AUTHORIZE_URL=$(printf '%s' "$META" | jq -r '.authorization_endpoint')
TOKEN_URL=$(printf '%s' "$META" | jq -r '.token_endpoint')
REGISTER_URL=$(printf '%s' "$META" | jq -r '.registration_endpoint')
```

**Before opening a browser, confirm every discovered endpoint host ends in `.sigmacomputing.com`** (or is `sigmacomputing.com`). A host that returned a discovery doc pointing anywhere else should abort the flow — don't launch the browser at an unknown authorization server. <!-- pragma: allowlist secret -->

## B. Register a public client (RFC 7591)

Pick a loopback port that **nothing is currently listening on** — the browser will try to deliver the authorization code there, and you don't want it handed to some unrelated local process that happens to hold a well-known port. A random high port keeps collisions vanishingly unlikely:

```sh
for _ in $(seq 1 50); do
  PORT=$(( 20000 + (RANDOM % 20000) ))
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || break   # break on a free port
done
REDIRECT_URI="http://127.0.0.1:${PORT}/oauth/callback"

CLIENT_ID=$(curl -sS -X POST "$REGISTER_URL" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg r "$REDIRECT_URI" --arg s "$SCOPE" '{
    redirect_uris: [$r], client_name: "sigma-api skill", scope: $s,
    token_endpoint_auth_method: "none"
  }')" | jq -r '.client_id')
```

`token_endpoint_auth_method: "none"` declares a public client — there is no client secret, only `client_id` + PKCE.

## C. Generate PKCE + a CSRF state

```sh
VERIFIER=$(openssl rand -base64 96 | tr -d '\r\n=+/' | cut -c1-64)                 # 43–128 unreserved chars
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -binary -sha256 | openssl base64 | tr '+/' '-_' | tr -d '=\r\n')
STATE=$(openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\r\n')                    # ≥22 chars
```

Strip both CR and LF. Windows-native OpenSSL emits CRLF; leaving the CR in
`state` or `code_challenge` URL-encodes it as `%0D` and breaks authorization.
The bundled script validates every generated component before opening the
browser.

## D. Authorize in the browser and capture the code

```sh
OPEN_URL="$AUTHORIZE_URL?response_type=code&client_id=$CLIENT_ID&redirect_uri=$REDIRECT_URI&state=$STATE&code_challenge=$CHALLENGE&code_challenge_method=S256&scope=$SCOPE"
open "$OPEN_URL"   # macOS
# Linux: xdg-open "$OPEN_URL"
# Windows/Git Bash: powershell.exe Start-Process, cmd.exe //c start, or explorer.exe
```

After signing in, the browser is redirected to `http://127.0.0.1:<port>/oauth/callback?code=…&state=…`.

**Preferred: capture it automatically.** Start a one-shot loopback listener on the port _before_ opening the browser, and read `code`/`state` straight from the single request it receives — no callback URL ever has to be typed, pasted, or shown to anyone. `scripts/browser-login.sh` does exactly this with a short Python HTTP handler (bind → accept once matching `/oauth/callback`, ignoring stray requests like a browser's speculative `/favicon.ico` → respond with a plain "you can close this tab" page → exit), bounded by a 2-minute timeout.

**Fallback: manual copy.** If `python3` isn't available, the listener can't bind, or nothing arrives before the timeout, fall back to the zero-dependency path: with no local server listening the redirect page just fails to load — that's expected. Have the user copy the full address-bar URL back to you.

For a noninteractive coding agent, set an absolute temporary callback path
before launching:

```sh
export SIGMA_OAUTH_CALLBACK_FILE=/tmp/sigma-oauth-callback
export SIGMA_OAUTH_CALLBACK_TIMEOUT=300  # optional
eval "$(bash scripts/browser-login.sh)"
```

The script skips the loopback listener, opens/logs the authorization URL, and
waits for another process to write the full callback URL as one line. It
applies mode `0600` where supported (Windows NTFS access is governed by its
ACLs) and removes the file immediately after reading or timeout. Treat the
callback as a one-time credential and keep this path outside the workspace.

Either way, verify the returned `state` equals the `$STATE` you sent (mismatch ⇒ abort, possible CSRF) before exchanging `code`.

## E. Exchange the code for tokens

```sh
TOKENS=$(curl -sS -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" \
  --data-urlencode "code_verifier=$VERIFIER" \
  --data-urlencode "client_id=$CLIENT_ID")

export SIGMA_API_TOKEN=$(printf '%s' "$TOKENS" | jq -r '.access_token')
REFRESH_TOKEN=$(printf '%s' "$TOKENS" | jq -r '.refresh_token')   # long-lived — persist this
```

Because `browser-login.sh` emits this one-time exchange directly, verify it
with the `GET /v2/whoami` check in `SKILL.md` ("Verify the Token"). Subsequent
cached/refresh flows through `get_token.py` perform the same check
automatically and refuse redirects.

## F. Persist the refresh token (encrypted) and refresh on demand

> `scripts/get_token.py` is the canonical implementation of cached-token reuse,
> refresh-token redemption, and rotation; `scripts/get-token.sh` invokes it
> automatically. `scripts/refresh-token.sh` remains a browser-only shell
> compatibility helper. Reach for the manual steps below only to understand or
> customize the flow. **Refresh tokens are single-use and rotate:** each
> redemption may return a new one, so the replacement must be persisted before
> returning success.

The access token still expires in ~1 hour, but the **refresh token** lets you
mint a new one without another browser login. Store it—plus the `client_id` and
`token_endpoint` needed to redeem it—in the OS keychain, never `auth.json` or
another workspace file:

```sh
# macOS
security add-generic-password -U -a "$USER" -s "sigma-api:refresh-token" -w "$REFRESH_TOKEN"
# Linux (libsecret): secret-tool store --label="sigma-api refresh token" service sigma-api key refresh-token
```

To refresh (access token 401s), read the stored refresh token back and redeem it:

```sh
REFRESH_TOKEN=$(security find-generic-password -a "$USER" -s "sigma-api:refresh-token" -w)  # macOS

REFRESHED=$(curl -sS -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "refresh_token=$REFRESH_TOKEN" \
  --data-urlencode "client_id=$CLIENT_ID")

export SIGMA_API_TOKEN=$(printf '%s' "$REFRESHED" | jq -r '.access_token')
# If the response carries a new refresh_token, overwrite the stored one — refresh tokens may rotate.
```
