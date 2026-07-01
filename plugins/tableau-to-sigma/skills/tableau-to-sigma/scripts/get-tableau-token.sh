#!/usr/bin/env bash
# Sign in to Tableau via Personal Access Token.
# Usage:  eval "$(scripts/get-tableau-token.sh)"
# Sets TABLEAU_AUTH_TOKEN and TABLEAU_SITE_ID in the calling shell.
#
# IMPORTANT: this makes ONE signin attempt. Tableau invalidates a PAT after
# four consecutive failed signins, so do not wrap this in a retry loop with
# different name/secret combos — fix the credentials and call once.
# Works against both Tableau Cloud and self-hosted Tableau Server (the REST
# signin + serverinfo endpoints are identical; the API version is negotiated).

set -euo pipefail

# Agent-neutral credential bootstrap. Claude Code auto-loads creds from
# ~/.claude/settings.json into the env; other agents don't. If the creds aren't
# already present, source the neutral cred file written by setup-tableau.rb.
if [ -z "${TABLEAU_PAT_SECRET:-}" ] && [ -f "$HOME/.sigma-migration/env" ]; then
  . "$HOME/.sigma-migration/env"
fi

: "${TABLEAU_SERVER_URL:?Run scripts/setup-tableau.rb to configure credentials}"
: "${TABLEAU_PAT_NAME:?Run scripts/setup-tableau.rb to configure credentials}"
: "${TABLEAU_PAT_SECRET:?Run scripts/setup-tableau.rb to configure credentials}"
# contentUrl may legitimately be EMPTY — that's the Tableau Server "Default" site.
# Require it to be SET (so we know setup ran) but allow an empty value; a bare
# `:?` guard would reject the Default site.
if [ -z "${TABLEAU_SITE_CONTENT_URL+x}" ]; then
  echo "TABLEAU_SITE_CONTENT_URL not set — run scripts/setup-tableau.rb to configure credentials" >&2
  exit 1
fi

# --- REST API version negotiation -------------------------------------------
# Tableau Cloud always speaks the latest REST API version, but a self-hosted
# Tableau Server is pinned to whatever its installed release supports. Signing
# in against a version the server doesn't know returns a 400 that looks like a
# credential failure. Ask the server which version it speaks — serverinfo needs
# NO auth, so the probe never counts against the 4-strike PAT lockout — and use
# that. An explicit TABLEAU_API_VERSION always wins.
if [ -n "${TABLEAU_API_VERSION:-}" ]; then
  API_VER="$TABLEAU_API_VERSION"
else
  # 2.4 is supported by every Tableau Server release still in the field and by Cloud.
  API_VER=$(curl -sS -H "Accept: application/json" \
    "${TABLEAU_SERVER_URL}/api/2.4/serverinfo" 2>/dev/null | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin)['serverInfo']['restApiVersion'])
except Exception:
    print('')
" 2>/dev/null)
  if [ -z "$API_VER" ]; then
    API_VER="3.22"
    echo "serverinfo probe failed; defaulting to REST API ${API_VER} (override with TABLEAU_API_VERSION)." >&2
  fi
fi

RESPONSE=$(curl -sS -X POST \
  -H "Content-Type: application/xml" \
  -H "Accept: application/json" \
  --data "<tsRequest><credentials personalAccessTokenName=\"${TABLEAU_PAT_NAME}\" personalAccessTokenSecret=\"${TABLEAU_PAT_SECRET}\"><site contentUrl=\"${TABLEAU_SITE_CONTENT_URL}\"/></credentials></tsRequest>" \
  "${TABLEAU_SERVER_URL}/api/${API_VER}/auth/signin")

# Parse the response. On success we expect {"credentials":{"token":"...","site":{"id":"..."}, ...}}.
# On failure we get {"error":{"code":"401001",...}}.
TOKEN=$(printf '%s' "$RESPONSE" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if 'error' in d:
    sys.exit(3)
print(d['credentials']['token'])
" 2>/dev/null) || {
  CODE=$?
  if [ "$CODE" = "3" ]; then
    ERR_CODE=$(printf '%s' "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',{}).get('code','?'))" 2>/dev/null || echo '?')
    echo "Tableau signin failed (error code: $ERR_CODE)." >&2
    echo "Response: $RESPONSE" >&2
    if [ "$ERR_CODE" = "401001" ]; then
      echo >&2
      echo "401001 means the PAT name or secret is wrong — OR the token has been invalidated by 4+" >&2
      echo "consecutive failed signins. Create a fresh PAT (Account Settings → Personal Access" >&2
      echo "Tokens, on Tableau Server or Cloud) and re-run setup-tableau.rb." >&2
    fi
    exit 1
  fi
  echo "Tableau signin failed — could not parse response: $RESPONSE" >&2
  exit 1
}

SITE_ID=$(printf '%s' "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['credentials']['site']['id'])")

echo "export TABLEAU_AUTH_TOKEN='${TOKEN}'"
echo "export TABLEAU_SITE_ID='${SITE_ID}'"
echo "export TABLEAU_API_VERSION='${API_VER}'"
