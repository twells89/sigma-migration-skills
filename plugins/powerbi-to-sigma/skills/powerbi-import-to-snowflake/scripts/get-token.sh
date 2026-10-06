#!/usr/bin/env bash
# Mint a Sigma bearer token. Browser-keychain auth is preferred; OAuth client
# credentials are the fallback. Existing valid caller tokens are intentionally
# handled by callers rather than re-emitted here.
#
# Usage:
#   eval "$(./get-token.sh)"
#   eval "$(./get-token.sh --auth-mode browser)"
#
# Auth mode: --auth-mode or SIGMA_AUTH_MODE = auto (default), browser, or
# client-credentials. With Python, the canonical get_token.py provider handles
# every mode. Without Python, this retains a safe client-credentials fallback.
#
# Prints SIGMA_API_TOKEN, SIGMA_TOKEN_MINTED_AT, and SIGMA_AUTH_METHOD exports.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_MODE="${SIGMA_AUTH_MODE:-auto}"
if [ "$#" -gt 0 ]; then
  if [ "$#" -eq 2 ] && [ "$1" = "--auth-mode" ]; then
    AUTH_MODE="$2"
  elif [ "$#" -eq 1 ] && [[ "$1" == --auth-mode=* ]]; then
    AUTH_MODE="${1#--auth-mode=}"
  else
    echo "Usage: get-token.sh [--auth-mode auto|browser|client-credentials]" >&2
    exit 64
  fi
fi
case "$AUTH_MODE" in
  auto|browser|client-credentials) ;;
  *) echo "Error: auth mode must be auto, browser, or client-credentials" >&2; exit 64 ;;
esac

# Prefer the canonical dual-mode provider whenever any common Python launcher
# is available (python3 on POSIX, python/py on Windows Git Bash).
PYTHON=()
if command -v python3 >/dev/null 2>&1; then
  PYTHON=(python3)
elif command -v python >/dev/null 2>&1; then
  PYTHON=(python)
elif command -v py >/dev/null 2>&1; then
  PYTHON=(py -3)
fi
if [ "${#PYTHON[@]}" -gt 0 ]; then
  exec "${PYTHON[@]}" "$SCRIPT_DIR/get_token.py" \
    --print-export --auth-mode "$AUTH_MODE"
fi

# Browser refresh requires the Python provider. In auto mode, client
# credentials still work on a Python-free host.
if [ "$AUTH_MODE" = "browser" ]; then
  echo "Error: browser auth requires Python 3 for the canonical token provider." >&2
  exit 1
fi

: "${SIGMA_BASE_URL:?SIGMA_BASE_URL is not set}"
: "${SIGMA_CLIENT_ID:?SIGMA_CLIENT_ID is not set (Python is unavailable, so browser auth cannot be used)}"
: "${SIGMA_CLIENT_SECRET:?SIGMA_CLIENT_SECRET is not set (Python is unavailable, so browser auth cannot be used)}"

for bin in curl jq base64; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Error: $bin is required for the Python-free client-credentials fallback" >&2
    exit 1
  }
done

# Pin to known Sigma cloud hosts. The script's stdout is intended to be eval'd,
# so a hostile token-endpoint response could otherwise become RCE on the caller.
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

# `printf` (not `echo`) so no trailing newline is encoded into the credentials.
# `tr -d '\n'` strips the wrap base64 inserts at 76 columns by default on both
# BSD and GNU — without it, long id:secret pairs would inject a newline into
# the Authorization header.
CREDENTIALS=$(printf '%s:%s' "$SIGMA_CLIENT_ID" "$SIGMA_CLIENT_SECRET" | base64 | tr -d '\n')

RESPONSE=$(curl -sf -X POST "${SIGMA_BASE_URL}/v2/auth/token" \
  -H "Authorization: Basic ${CREDENTIALS}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials")

TOKEN=$(echo "$RESPONSE" | jq -r '.access_token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "Error: failed to extract access_token from response:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi

# The token will be eval'd by the caller. Reject any character outside the
# OAuth-2 bearer-token alphabet (RFC 6750 §2.1) so a compromised or spoofed
# token endpoint cannot smuggle shell metacharacters into `eval`.
if ! [[ "$TOKEN" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
  echo "Error: token contains unexpected characters; refusing to emit." >&2
  exit 1
fi

printf 'export SIGMA_API_TOKEN=%q\n' "$TOKEN"
printf 'export SIGMA_TOKEN_MINTED_AT=%q\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'export SIGMA_AUTH_METHOD=%q\n' "client-credentials"
