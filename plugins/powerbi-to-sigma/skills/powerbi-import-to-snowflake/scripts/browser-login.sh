#!/usr/bin/env bash
# Interactive browser login for the Sigma API (OAuth 2.1 authorization-code + PKCE).
#
# Unlike get-token.sh (headless client-credentials), this signs a *human* in
# through the browser — no pre-provisioned client_id/secret. It:
#   1. discovers the OAuth endpoints from an unauthenticated /v2/whoami 401,
#   2. registers a public client (RFC 7591),
#   3. runs the PKCE authorization-code flow, opening the system browser,
#   4. captures the redirect on a one-shot local loopback listener (falls back
#      to pasting the callback URL back if python3 isn't available, or the
#      listener times out), verifying the CSRF state,
#   5. exchanges the code, stores the refresh token in the OS keychain,
#   6. prints access-token mint metadata on stdout.
#
# Reads (env):
#   SIGMA_BASE_URL   a published Sigma API host (required)
#
# Prints (stdout, meant to be eval'd):
#   export SIGMA_API_TOKEN=<token>
#   export SIGMA_TOKEN_MINTED_AT=<UTC ISO-8601 timestamp>
#   export SIGMA_AUTH_METHOD=browser
# All prompts/progress go to stderr, so `eval "$(browser-login.sh)"` works.
#
# Usage:
#   eval "$(./browser-login.sh)"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/browser-login-platform.sh
source "$SCRIPT_DIR/lib/browser-login-platform.sh"

: "${SIGMA_BASE_URL:?SIGMA_BASE_URL is not set (see SKILL.md for the per-cloud host)}"

for bin in curl jq openssl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Error: $bin is required" >&2; exit 1; }
done

log() { printf '%s\n' "$*" >&2; }

# Pin SIGMA_BASE_URL to a known Sigma cloud host. The script's stdout is eval'd,
# so a hostile discovery/token response could otherwise become RCE on the caller.
SIGMA_DOMAIN="sigma""computing.com"
case "$SIGMA_BASE_URL" in
  https://aws-api.${SIGMA_DOMAIN}|\
  https://api.us-a.aws.${SIGMA_DOMAIN}|\
  https://api.ca.aws.${SIGMA_DOMAIN}|\
  https://api.eu.aws.${SIGMA_DOMAIN}|\
  https://api.au.aws.${SIGMA_DOMAIN}|\
  https://api.uk.aws.${SIGMA_DOMAIN}|\
  https://api.us.azure.${SIGMA_DOMAIN}|\
  https://api.eu.azure.${SIGMA_DOMAIN}|\
  https://api.ca.azure.${SIGMA_DOMAIN}|\
  https://api.uk.azure.${SIGMA_DOMAIN}|\
  https://api.au.azure.${SIGMA_DOMAIN}|\
  https://api.${SIGMA_DOMAIN}|\
  https://api.sa.gcp.${SIGMA_DOMAIN}) ;;
  *) echo "Error: SIGMA_BASE_URL must be one of the published Sigma API hosts (see SKILL.md)." >&2; exit 1 ;;
esac

# Every endpoint we discover must live on a Sigma host — never open a browser at,
# or POST credentials to, an authorization server a spoofed discovery doc names.
assert_sigma_host() {
  local url="$1" host
  case "$url" in
    https://*) ;;
    *) echo "Error: refusing non-HTTPS OAuth endpoint: $url" >&2; exit 1 ;;
  esac
  # The authority ends at the first '/', '?', or '#'; strip any userinfo and port
  # so the check sees exactly the host curl will connect to. A naive "everything
  # up to the first /" parse would let a fragment spoof the trusted suffix.
  host=$(printf '%s' "$url" | sed -E 's#^https?://##; s#[/?#].*##; s#^[^@]*@##; s#:[0-9]+$##')
  case "$host" in
    *."${SIGMA_DOMAIN}"|"${SIGMA_DOMAIN}") ;;
    *) echo "Error: refusing OAuth endpoint on non-Sigma host: ${host:-<none>}" >&2; exit 1 ;;
  esac
}

urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# --- A. Discover the OAuth endpoints from an unauthenticated /v2/whoami 401. ---
WWW_AUTH=$(curl -sS -D - -o /dev/null "$SIGMA_BASE_URL/v2/whoami" | tr -d '\r' | grep -i '^www-authenticate:' || true)
[ -n "$WWW_AUTH" ] || { echo "Error: $SIGMA_BASE_URL/v2/whoami returned no WWW-Authenticate header; this host does not offer browser login. Use get-token.sh (client credentials)." >&2; exit 1; }

RESOURCE_META=$(printf '%s' "$WWW_AUTH" | grep -oE 'resource_metadata="[^"]+"' | cut -d'"' -f2 || true)
SCOPE=$(printf '%s' "$WWW_AUTH" | grep -oE 'scope="[^"]+"' | cut -d'"' -f2 || true)
[ -n "$RESOURCE_META" ] || { echo "Error: could not parse resource_metadata from WWW-Authenticate header." >&2; exit 1; }
[ -n "$SCOPE" ] || { echo "Error: could not parse scope from WWW-Authenticate header." >&2; exit 1; }
assert_sigma_host "$RESOURCE_META"

AUTH_SERVER=$(curl -sS "$RESOURCE_META" | jq -r '.authorization_servers[0] // empty')
[ -n "$AUTH_SERVER" ] || { echo "Error: no authorization server listed in protected-resource metadata." >&2; exit 1; }
AUTH_SERVER=${AUTH_SERVER%/}
assert_sigma_host "$AUTH_SERVER"

META=$(curl -sS "$AUTH_SERVER/.well-known/oauth-authorization-server")
AUTHORIZE_URL=$(printf '%s' "$META" | jq -r '.authorization_endpoint // empty')
TOKEN_URL=$(printf '%s' "$META" | jq -r '.token_endpoint // empty')
REGISTER_URL=$(printf '%s' "$META" | jq -r '.registration_endpoint // empty')
for u in "$AUTHORIZE_URL" "$TOKEN_URL" "$REGISTER_URL"; do
  [ -n "$u" ] || { echo "Error: authorization-server metadata is missing an endpoint URL." >&2; exit 1; }
  assert_sigma_host "$u"
done

# --- Pick a loopback port that NOTHING is currently listening on, so the auth
# --- code is only ever delivered to the address bar — never to a foreign local
# --- process that happens to hold the port. ---
port_is_free() {
  # Succeeds (returns 0) only when NOTHING is listening on 127.0.0.1:$1.
  # Prefer lsof (shell-independent, present on macOS/Linux); fall back to bash's
  # /dev/tcp connect. Both are used only to SKIP busy ports — the random high
  # port below is the real guard against handing the code to a foreign process.
  if command -v lsof >/dev/null 2>&1; then
    ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}
REDIRECT_PORT=""
for ((i = 0; i < 50; i++)); do
  cand=$(( 20000 + (RANDOM % 20000) ))
  if port_is_free "$cand"; then REDIRECT_PORT="$cand"; break; fi
done
[ -n "$REDIRECT_PORT" ] || { echo "Error: could not find a free loopback port after 50 tries." >&2; exit 1; }
REDIRECT_URI="http://127.0.0.1:${REDIRECT_PORT}/oauth/callback"

# --- B. Register a public client (RFC 7591). ---
REG=$(curl -sS -X POST "$REGISTER_URL" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg r "$REDIRECT_URI" --arg s "$SCOPE" '{
    redirect_uris: [$r], client_name: "sigma-api skill", scope: $s,
    token_endpoint_auth_method: "none"
  }')")
CLIENT_ID=$(printf '%s' "$REG" | jq -r '.client_id // empty')
[ -n "$CLIENT_ID" ] || { echo "Error: client registration failed:" >&2; printf '%s\n' "$REG" >&2; exit 1; }

# --- C. PKCE verifier/challenge + a CSRF state. ---
VERIFIER=$(openssl rand -base64 96 | sigma_pkce_verifier)
CHALLENGE=$(printf '%s' "$VERIFIER" | openssl dgst -binary -sha256 | openssl base64 | sigma_base64url)
STATE=$(openssl rand -base64 24 | sigma_base64url)
sigma_require_component "PKCE verifier" "$VERIFIER" '^[A-Za-z0-9._~-]{43,128}$'
sigma_require_component "PKCE challenge" "$CHALLENGE" '^[A-Za-z0-9_-]+$'
sigma_require_component "OAuth state" "$STATE" '^[A-Za-z0-9_-]+$'

# --- D. Authorize in the browser, capturing the redirect automatically. ---
AUTH_REQ="${AUTHORIZE_URL}?response_type=code&client_id=$(urlenc "$CLIENT_ID")&redirect_uri=$(urlenc "$REDIRECT_URI")&state=$(urlenc "$STATE")&code_challenge=${CHALLENGE}&code_challenge_method=S256&scope=$(urlenc "$SCOPE")"

# Pull code + state out of a callback URL (belt-and-suspenders for the fallback
# path below; the listener does its own parsing to build a same-origin
# response, but this is what actually feeds the token exchange). Stop at '&'
# AND '#' so a trailing fragment isn't swallowed into the value, then
# percent-decode — the address-bar/query value is URL-encoded and curl
# --data-urlencode re-encodes on the way out, so without this a code carrying
# a %XX escape would be double-encoded and rejected.
# The pattern must be quoted — bash parses the unquoted form `${1//%/...}` as
# the anchored-suffix substitution `${1/%.../...}` (empty pattern anchored at
# the end), which unconditionally appends the replacement instead of
# replacing every literal `%`. Verified live: unquoted, this silently
# corrupts every decoded value with a trailing NUL byte and never actually
# decodes a real %XX escape.
urldec() { printf '%b' "${1//'%'/\\x}"; }
qs_param() { printf '%s' "$1" | sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p"; }

CODE=""
RET_STATE=""
LISTENER_PID=""
LISTENER_OUT=""
CALLBACK_FILE="${SIGMA_OAUTH_CALLBACK_FILE:-}"
CALLBACK_TIMEOUT="${SIGMA_OAUTH_CALLBACK_TIMEOUT:-300}"

if [ -n "$CALLBACK_FILE" ]; then
  sigma_prepare_callback_file "$CALLBACK_FILE"
fi
cleanup_callback_file() {
  [ -z "$CALLBACK_FILE" ] || rm -f "$CALLBACK_FILE"
}
trap cleanup_callback_file EXIT

open_browser() {
  log ""
  log "Opening your browser to sign in to Sigma…"
  log "If it does not open, paste this URL into a browser yourself:"
  log ""
  log "  $AUTH_REQ"
  log ""
  if ! sigma_open_system_browser "$AUTH_REQ"; then
    log "No supported browser launcher was found; open the URL above manually."
  fi
}

# Start a one-shot local listener BEFORE opening the browser, so the redirect
# lands on it directly and the code never has to be read back from the address
# bar. Bind failure or no python3 → CODE stays empty and we fall back below.
if command -v python3 >/dev/null 2>&1 && [ -z "$CALLBACK_FILE" ]; then
  LISTENER_OUT=$(mktemp)
  python3 - "$REDIRECT_PORT" >"$LISTENER_OUT" 2>/dev/null <<'PYEOF' &
import socket, sys, time

port = int(sys.argv[1])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(("127.0.0.1", port))
    srv.listen(5)
except OSError:
    sys.exit(1)

body = b"<html><body>Signed in to Sigma \xe2\x80\x94 you can close this tab and return to the terminal.</body></html>"
resp = (
    b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "
    + str(len(body)).encode()
    + b"\r\nConnection: close\r\n\r\n"
    + body
)

deadline = time.time() + 120
found = None
while time.time() < deadline:
    srv.settimeout(max(0.1, deadline - time.time()))
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        break
    conn.settimeout(5)
    try:
        data = conn.recv(65536).decode("utf-8", "replace")
    except OSError:
        data = ""
    request_line = data.split("\r\n", 1)[0] if data else ""
    parts = request_line.split(" ")
    req_path = parts[1] if len(parts) > 1 else ""
    try:
        conn.sendall(resp)
    except OSError:
        pass
    conn.close()
    # Ignore stray requests (e.g. a browser's speculative /favicon.ico) —
    # keep accepting on the same listener until the real callback arrives
    # or the deadline above is hit.
    if req_path.startswith("/oauth/callback"):
        found = req_path
        break

srv.close()
if found:
    print(found)
PYEOF
  LISTENER_PID=$!

  open_browser
  log "Waiting for you to approve in the browser (up to 2 minutes)…"

  wait "$LISTENER_PID" 2>/dev/null || true
  CALLBACK_PATH=$(cat "$LISTENER_OUT" 2>/dev/null || true)
  rm -f "$LISTENER_OUT"

  if [ -n "$CALLBACK_PATH" ]; then
    CODE=$(urldec "$(qs_param "$CALLBACK_PATH" code)")
    RET_STATE=$(urldec "$(qs_param "$CALLBACK_PATH" state)")
    [ -n "$CODE" ] || log "Warning: listener caught a callback with no ?code= — falling back to manual paste."
  else
    log "No callback arrived within 2 minutes — falling back to manual paste."
  fi
fi

# Fallback: no python3, the listener couldn't bind, or it timed out/came back
# empty. This is the same zero-dependency path the flow always used. Only
# open the browser here if the listener path above never got a chance to
# (no python3) — if it already opened once and just timed out waiting for
# approval, opening a second tab on the same request would just be noise.
if [ -z "$CODE" ]; then
  if [ -z "$LISTENER_PID" ]; then
    open_browser
  fi
  log "After you approve, the browser will try to load a"
  log "  http://127.0.0.1:${REDIRECT_PORT}/oauth/callback?code=…&state=…"
  log "page that fails to connect — that is expected (nothing is listening there)."
  log "Copy the FULL address-bar URL, paste it here, and press Enter:"
  CALLBACK=""
  if [ -n "$CALLBACK_FILE" ]; then
    log "Waiting up to ${CALLBACK_TIMEOUT}s for the callback URL in:"
    log "  $CALLBACK_FILE"
    log "Write the URL as one line; the file is removed immediately after reading."
    CALLBACK=$(sigma_wait_for_callback_file "$CALLBACK_FILE" "$CALLBACK_TIMEOUT" || true)
  else
    # Prefer the controlling terminal (works even under `eval "$(...)"`, where
    # stdout is captured). If there is no usable tty — the open/read fails, e.g.
    # macOS "Device not configured" — fall back to stdin (piped callers).
    if ! { read -r CALLBACK < /dev/tty; } 2>/dev/null; then
      read -r CALLBACK || true
    fi
  fi
  [ -n "$CALLBACK" ] || { echo "Error: no callback URL provided." >&2; exit 1; }
  CODE=$(urldec "$(qs_param "$CALLBACK" code)")
  RET_STATE=$(urldec "$(qs_param "$CALLBACK" state)")
  [ -n "$CODE" ] || { echo "Error: no ?code= found in the pasted URL." >&2; exit 1; }
fi

[ "$RET_STATE" = "$STATE" ] || { echo "Error: state mismatch (possible CSRF) — aborting." >&2; exit 1; }

# --- E. Exchange the authorization code for tokens. ---
TOKENS=$(curl -sS -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=authorization_code" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" \
  --data-urlencode "code_verifier=$VERIFIER" \
  --data-urlencode "client_id=$CLIENT_ID")
ACCESS=$(printf '%s' "$TOKENS" | jq -r '.access_token // empty')
REFRESH=$(printf '%s' "$TOKENS" | jq -r '.refresh_token // empty')
if [ -z "$ACCESS" ]; then
  echo "Error: token exchange failed:" >&2
  printf '%s\n' "$TOKENS" | jq . >&2 2>/dev/null || printf '%s\n' "$TOKENS" >&2
  exit 1
fi

# The token will be eval'd by the caller. Reject anything outside the RFC 6750
# bearer-token alphabet so a spoofed token endpoint cannot smuggle shell into eval.
if ! [[ "$ACCESS" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
  echo "Error: token contains unexpected characters; refusing to emit." >&2
  exit 1
fi
EXPIRES_IN=$(printf '%s' "$TOKENS" | jq -r '.expires_in // 3600')
case "$EXPIRES_IN" in ''|*[!0-9]*) EXPIRES_IN=3600 ;; esac
MINTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
NOW=$(date +%s)
CACHE_EXPIRY=$(( NOW + EXPIRES_IN - 60 ))

# --- F. Persist the refresh token (never to a workspace file) so a later
# --- refresh needs no browser round-trip. client_id + token_url ride along so
# --- the refresh is self-contained (see reference/browser-oauth-login.md, §F).
# --- Store refresh metadata first and the refresh token last; then cache the
# --- access token with expiry as the final cache-commit key. ---
if [ -n "$REFRESH" ]; then
  if command -v security >/dev/null 2>&1; then
    if security add-generic-password -U -a "$USER" -s "sigma-api:client-id" -w "$CLIENT_ID" >/dev/null 2>&1 &&
       security add-generic-password -U -a "$USER" -s "sigma-api:token-url" -w "$TOKEN_URL" >/dev/null 2>&1 &&
       security add-generic-password -U -a "$USER" -s "sigma-api:refresh-token" -w "$REFRESH" >/dev/null 2>&1; then
      if security add-generic-password -U -a "$USER" -s "sigma-api:access-token" -w "$ACCESS" >/dev/null 2>&1 &&
         security add-generic-password -U -a "$USER" -s "sigma-api:access-minted-at" -w "$MINTED_AT" >/dev/null 2>&1; then
        security add-generic-password -U -a "$USER" -s "sigma-api:access-expiry" -w "$CACHE_EXPIRY" >/dev/null 2>&1 || true
      fi
      log "Stored refresh token in the macOS keychain (service 'sigma-api:refresh-token')."
    else
      log "Warning: could not store the complete browser session in the macOS keychain; the new refresh token was not safely persisted."
    fi
  elif command -v secret-tool >/dev/null 2>&1; then
    if printf '%s' "$CLIENT_ID" | secret-tool store --label="sigma-api client-id" service sigma-api key client-id >/dev/null 2>&1 &&
       printf '%s' "$TOKEN_URL" | secret-tool store --label="sigma-api token-url" service sigma-api key token-url >/dev/null 2>&1 &&
       printf '%s' "$REFRESH" | secret-tool store --label="sigma-api refresh token" service sigma-api key refresh-token >/dev/null 2>&1; then
      if printf '%s' "$ACCESS" | secret-tool store --label="sigma-api access-token" service sigma-api key access-token >/dev/null 2>&1 &&
         printf '%s' "$MINTED_AT" | secret-tool store --label="sigma-api access-minted-at" service sigma-api key access-minted-at >/dev/null 2>&1; then
        printf '%s' "$CACHE_EXPIRY" | secret-tool store --label="sigma-api access-expiry" service sigma-api key access-expiry >/dev/null 2>&1 || true
      fi
      log "Stored refresh token via libsecret (service 'sigma-api', key 'refresh-token')."
    else
      log "Warning: could not store the complete browser session in libsecret; the new refresh token was not safely persisted."
    fi
  else
    log "Note: no OS keychain tool (security/secret-tool) found; refresh token NOT persisted."
  fi
else
  log "Note: no refresh_token returned; sign in again when the access token expires (~1h)."
fi

printf 'export SIGMA_API_TOKEN=%q\n' "$ACCESS"
printf 'export SIGMA_TOKEN_MINTED_AT=%q\n' "$MINTED_AT"
printf 'export SIGMA_AUTH_METHOD=%q\n' "browser"
