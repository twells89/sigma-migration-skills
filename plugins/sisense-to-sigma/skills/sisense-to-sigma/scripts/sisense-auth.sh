#!/usr/bin/env bash
# Exchange Sisense email+password for a bearer token.
# Usage:  eval "$(scripts/sisense-auth.sh)"
# Sets SISENSE_API_TOKEN (and SISENSE_BASE_URL) in the calling shell.
#
# Credentials resolve in this order:
#   1. SISENSE_BASE_URL / SISENSE_EMAIL / SISENSE_PASSWORD already in the env
#   2. the neutral cred file ~/.sigma-migration/sisense.env
# If only SISENSE_API_TOKEN is present (no email/password), it is echoed back
# as-is — login is skipped (tokens are long-lived per user).

set -euo pipefail

if [ -z "${SISENSE_BASE_URL:-}" ] && [ -f "$HOME/.sigma-migration/sisense.env" ]; then
  . "$HOME/.sigma-migration/sisense.env"
fi

: "${SISENSE_BASE_URL:?Set SISENSE_BASE_URL (e.g. https://acme.sisense.com)}"

# If a token is already present and no password is supplied, reuse it.
if [ -n "${SISENSE_API_TOKEN:-}" ] && [ -z "${SISENSE_PASSWORD:-}" ]; then
  echo "export SISENSE_BASE_URL=${SISENSE_BASE_URL}"
  echo "export SISENSE_API_TOKEN=${SISENSE_API_TOKEN}"
  exit 0
fi

: "${SISENSE_EMAIL:?Set SISENSE_EMAIL}"
: "${SISENSE_PASSWORD:?Set SISENSE_PASSWORD}"

RESPONSE=$(curl -sf -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "username=${SISENSE_EMAIL}" \
  --data-urlencode "password=${SISENSE_PASSWORD}" \
  "${SISENSE_BASE_URL}/api/v1/authentication/login") || {
    echo "Sisense login failed — check SISENSE_BASE_URL / SISENSE_EMAIL / SISENSE_PASSWORD" >&2
    exit 1
  }

TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Sisense login failed — response did not contain access_token" >&2
  exit 1
fi

echo "export SISENSE_BASE_URL=${SISENSE_BASE_URL}"
echo "export SISENSE_API_TOKEN=${TOKEN}"
