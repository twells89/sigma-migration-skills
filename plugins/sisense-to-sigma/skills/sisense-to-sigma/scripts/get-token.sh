#!/usr/bin/env bash
# Exchange Sigma client credentials for a bearer token.
# Usage:  eval "$(scripts/get-token.sh)"
# Sets SIGMA_API_TOKEN in the calling shell.

set -euo pipefail

# Agent-neutral credential bootstrap. Claude Code auto-loads creds from
# ~/.claude/settings.json into the env; other agents (Cursor, plain shell)
# don't. If the creds aren't already present, source the neutral cred file.
if [ -z "${SIGMA_CLIENT_ID:-}" ] && [ -f "$HOME/.sigma-migration/env" ]; then
  . "$HOME/.sigma-migration/env"
fi

: "${SIGMA_BASE_URL:?Set SIGMA_BASE_URL (e.g. https://api.sigmacomputing.com)}"
: "${SIGMA_CLIENT_ID:?Set SIGMA_CLIENT_ID}"
: "${SIGMA_CLIENT_SECRET:?Set SIGMA_CLIENT_SECRET}"

CREDENTIALS=$(printf '%s:%s' "$SIGMA_CLIENT_ID" "$SIGMA_CLIENT_SECRET" | base64)

RESPONSE=$(curl -sf -X POST \
  -H "Authorization: Basic ${CREDENTIALS}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  "$SIGMA_BASE_URL/v2/auth/token") || {
    echo "Token exchange failed — check SIGMA_BASE_URL, SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET" >&2
    exit 1
  }

TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Token exchange failed — response did not contain access_token" >&2
  exit 1
fi

echo "export SIGMA_API_TOKEN=${TOKEN}"
