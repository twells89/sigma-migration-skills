#!/usr/bin/env bash
# Headless access-token refresh for the browser-login flow.
#
# After browser-login.sh has run once (storing the refresh token, client_id, and
# token endpoint in the OS keychain), this mints a valid access token with NO
# browser round-trip:
#   1. If a cached access token is still valid, emit it (no network call).
#   2. Otherwise redeem the stored refresh token, cache the new access token and
#      its expiry, rotate the stored refresh token if the server returns a new
#      one, and emit it.
#
# Prints (stdout, meant to be eval'd):
#   export SIGMA_API_TOKEN=<token>
#   export SIGMA_TOKEN_MINTED_AT=<UTC ISO-8601 timestamp>
#   export SIGMA_AUTH_METHOD=browser
# Progress/errors go to stderr, so `eval "$(refresh-token.sh)"` works.
#
# Usage:
#   eval "$(./refresh-token.sh)"

set -euo pipefail

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Error: $bin is required" >&2; exit 1; }
done

log() { printf '%s\n' "$*" >&2; }

# --- Keychain access (macOS `security` / Linux `secret-tool`). Names match
# --- what browser-login.sh writes: macOS service "sigma-api:<name>",
# --- libsecret attributes service=sigma-api key=<name>. ---
if command -v security >/dev/null 2>&1; then
  KC=macos
elif command -v secret-tool >/dev/null 2>&1; then
  KC=libsecret
else
  echo "Error: no OS keychain tool (security/secret-tool) found; cannot read saved credentials. Run browser-login.sh on a supported system." >&2
  exit 1
fi

kc_get() { # kc_get <name>
  case "$KC" in
    macos)     security find-generic-password -a "$USER" -s "sigma-api:$1" -w 2>/dev/null || true ;;
    libsecret) secret-tool lookup service sigma-api key "$1" 2>/dev/null || true ;;
  esac
}
kc_set() { # kc_set <name> <value>
  case "$KC" in
    macos)     security add-generic-password -U -a "$USER" -s "sigma-api:$1" -w "$2" >/dev/null 2>&1 ;;
    libsecret) printf '%s' "$2" | secret-tool store --label="sigma-api $1" service sigma-api key "$1" >/dev/null 2>&1 ;;
  esac
}

emit() { # validate every keychain-derived value before stdout is eval'd
  local t="$1" minted="$2"
  if ! [[ "$t" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "Error: token contains unexpected characters; refusing to emit." >&2
    exit 1
  fi
  if ! [[ "$minted" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "Error: token mint timestamp contains unexpected characters; refusing to emit." >&2
    exit 1
  fi
  printf 'export SIGMA_API_TOKEN=%q\n' "$t"
  printf 'export SIGMA_TOKEN_MINTED_AT=%q\n' "$minted"
  printf 'export SIGMA_AUTH_METHOD=%q\n' "browser"
}

NOW=$(date +%s)
minted_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# --- 1. Serve a still-valid cached access token without touching the network. ---
CACHED=$(kc_get access-token)
EXPIRY=$(kc_get access-expiry)
if [ -n "$CACHED" ] && [ -n "$EXPIRY" ] && [ "$EXPIRY" -gt "$NOW" ] 2>/dev/null; then
  MINTED_AT=$(kc_get access-minted-at)
  if ! [[ "$MINTED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    # Backward compatibility for caches written before mint metadata existed.
    MINTED_AT=$(minted_now)
    kc_set access-minted-at "$MINTED_AT" || true
  fi
  log "Using cached access token ($(( EXPIRY - NOW ))s remaining)."
  emit "$CACHED" "$MINTED_AT"
  exit 0
fi

# --- 2. Cache miss/expired → redeem the stored refresh token. ---
REFRESH=$(kc_get refresh-token)
CLIENT_ID=$(kc_get client-id)
TOKEN_URL=$(kc_get token-url)
if [ -z "$REFRESH" ] || [ -z "$CLIENT_ID" ] || [ -z "$TOKEN_URL" ]; then
  echo "Error: no saved browser-login credentials in the keychain. Run browser-login.sh first." >&2
  exit 1
fi

# Never POST the refresh token anywhere but a Sigma host, even if the keychain
# value was tampered with. Parse the authority exactly as curl would (stop at the
# first '/', '?', or '#'; drop userinfo and port) so a fragment cannot spoof
# the trusted suffix.
SIGMA_DOMAIN="sigma""computing.com"
case "$TOKEN_URL" in
  https://*) ;;
  *) echo "Error: stored token-url is not HTTPS; refusing to use it." >&2; exit 1 ;;
esac
TU_HOST=$(printf '%s' "$TOKEN_URL" | sed -E 's#^https?://##; s#[/?#].*##; s#^[^@]*@##; s#:[0-9]+$##')
case "$TU_HOST" in
  *."${SIGMA_DOMAIN}"|"${SIGMA_DOMAIN}") ;;
  *) echo "Error: stored token-url points at a non-Sigma host ($TU_HOST); refusing to use it." >&2; exit 1 ;;
esac

RESP=$(curl -sS -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=refresh_token" \
  --data-urlencode "refresh_token=$REFRESH" \
  --data-urlencode "client_id=$CLIENT_ID")

ACCESS=$(printf '%s' "$RESP" | jq -r '.access_token // empty')
if [ -z "$ACCESS" ]; then
  echo "Error: refresh failed (the saved refresh token may be revoked or expired — re-run browser-login.sh):" >&2
  printf '%s\n' "$RESP" | jq . >&2 2>/dev/null || printf '%s\n' "$RESP" >&2
  exit 1
fi
if ! [[ "$ACCESS" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
  echo "Error: token contains unexpected characters; refusing to cache or emit." >&2
  exit 1
fi

EXPIRES_IN=$(printf '%s' "$RESP" | jq -r '.expires_in // 3600')
case "$EXPIRES_IN" in ''|*[!0-9]*) EXPIRES_IN=3600 ;; esac
MINTED_AT=$(minted_now)

# Refresh tokens may be single-use and rotate. Persist the replacement before
# returning the access token; silently retaining a spent token is not safe.
NEW_REFRESH=$(printf '%s' "$RESP" | jq -r '.refresh_token // empty')
if [ -n "$NEW_REFRESH" ] && [ "$NEW_REFRESH" != "$REFRESH" ]; then
  if ! kc_set refresh-token "$NEW_REFRESH"; then
    echo "Error: refresh token rotated but its replacement could not be stored; re-run browser-login.sh." >&2
    exit 1
  fi
  log "Rotated the stored refresh token."
fi

# Cache commit: write the token and mint metadata first, then expiry last. A
# partial keychain write can therefore never mark stale cache data as valid.
if kc_set access-token "$ACCESS" && kc_set access-minted-at "$MINTED_AT"; then
  kc_set access-expiry "$(( NOW + EXPIRES_IN - 60 ))" ||
    log "Warning: could not cache access-token expiry; the next call will refresh again."
else
  log "Warning: could not cache the access token; the next call will refresh again."
fi

log "Minted a fresh access token via refresh (valid ~${EXPIRES_IN}s)."
emit "$ACCESS" "$MINTED_AT"
