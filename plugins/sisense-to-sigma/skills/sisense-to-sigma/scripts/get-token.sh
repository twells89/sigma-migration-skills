#!/usr/bin/env bash
# Exchange Sigma client credentials for a bearer token.
# Usage:  eval "$(scripts/get-token.sh)"
# Sets SIGMA_API_TOKEN in the calling shell.

set -euo pipefail

# Agent-neutral credential bootstrap. Claude Code auto-loads creds from
# ~/.claude/settings.json into the env; other agents (Cursor, Cortex Code, plain
# shell) don't. If the creds aren't already present, source the neutral cred
# file written by setup.rb so this works under any agent.
if [ -z "${SIGMA_CLIENT_ID:-}" ] && [ -f "$HOME/.sigma-migration/env" ]; then
  . "$HOME/.sigma-migration/env"
fi

: "${SIGMA_BASE_URL:?Run scripts/setup.rb to configure credentials}"
: "${SIGMA_CLIENT_ID:?Run scripts/setup.rb to configure credentials}"
: "${SIGMA_CLIENT_SECRET:?Run scripts/setup.rb to configure credentials}"

# Pre-flight credential sanity (POSTMORTEM 2026-06-18): the #1 hard blocker was a
# settings.json where SIGMA_CLIENT_SECRET had been pasted with a COPY of
# SIGMA_CLIENT_ID. Sigma then returns the opaque "client secret provided is
# invalid" and nothing else runs. Catch the obvious paste-errors here with a
# specific, actionable message before the round-trip.
if [ "$SIGMA_CLIENT_SECRET" = "$SIGMA_CLIENT_ID" ]; then
  echo "FATAL: SIGMA_CLIENT_SECRET is identical to SIGMA_CLIENT_ID — you pasted the" >&2
  echo "client ID into both fields. The secret is a SEPARATE, longer value shown only" >&2
  echo "once when the API key was created. Fix it in ~/.sigma-migration/env (and in" >&2
  echo "~/.claude/settings.json if it lives there too), then re-run." >&2
  exit 1
fi

CREDENTIALS=$(printf '%s:%s' "$SIGMA_CLIENT_ID" "$SIGMA_CLIENT_SECRET" | base64)

RESPONSE=$(curl -sf -X POST \
  -H "Authorization: Basic ${CREDENTIALS}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  "$SIGMA_BASE_URL/v2/auth/token") || {
    echo "Token exchange failed — check SIGMA_BASE_URL, SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET" >&2
    echo "  base : $SIGMA_BASE_URL" >&2
    echo "  id   : ${#SIGMA_CLIENT_ID} chars   secret: ${#SIGMA_CLIENT_SECRET} chars" >&2
    echo "  (a valid Sigma secret is ~128 chars — if the secret is the same length as" >&2
    echo "   the id, you likely pasted the id into both fields.)" >&2
    exit 1
  }

TOKEN=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null \
  || echo "$RESPONSE" | ruby -r json -e "print JSON.parse(STDIN.read)['access_token']")

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "Token exchange failed — response did not contain access_token" >&2
  exit 1
fi

echo "export SIGMA_API_TOKEN=${TOKEN}"
