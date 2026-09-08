#!/usr/bin/env bash
# get-metabase-session.sh — set up Metabase REST auth for discovery/extraction.
#
#   AUTH (two options — far friendlier than most BI tools):
#   • API key (PREFERRED, Metabase v49+): Admin → Settings → Authentication →
#     API keys → create a key in a group with read access to the content you're
#     migrating (Administrators = read-everything). Durable; use for engagements.
#   • Session token: POST /api/session with username/password. Sessions expire
#     (max ~14 days, sooner under SSO); on HTTP 401 just re-run this script.
#     SSO-only logins (no password) must use an API key.
#
# USAGE:
#   export MB_BASE="https://metabase.example.com"     # no trailing slash, no /api
#   # EITHER:
#   export MB_KEY="mb_…"                               # the API key
#   # OR:
#   export MB_USER="you@example.com" MB_PASS="…"       # exchanged for a session
#   eval "$(scripts/get-metabase-session.sh)"
#   mb_get "/api/session/properties" | head            # smoke test (prints version)
#
# Emits a shell function `mb_get` on stdout (eval it). Read-only helper — only GETs.
set -euo pipefail
: "${MB_BASE:?set MB_BASE=https://<your-metabase-host>}"
MB_BASE="${MB_BASE%/}"

if [ -n "${MB_KEY:-}" ]; then
  AUTH_HDR="x-api-key: $MB_KEY"
elif [ -n "${MB_USER:-}" ] && [ -n "${MB_PASS:-}" ]; then
  tok=$(curl -s "$MB_BASE/api/session" -H 'Content-Type: application/json' \
    -d "{\"username\": \"$MB_USER\", \"password\": \"$MB_PASS\"}" |
    python3 -c 'import sys,json;print(json.load(sys.stdin).get("id") or "")')
  if [ -z "$tok" ]; then
    echo "echo 'Metabase login failed — check MB_USER/MB_PASS (SSO-only users need an API key, MB_KEY).' >&2; false"
    exit 0
  fi
  AUTH_HDR="X-Metabase-Session: $tok"
else
  echo "echo 'Set MB_KEY (preferred, v49+) or MB_USER+MB_PASS.' >&2; false"
  exit 0
fi

cat <<EOF
export MB_BASE='$MB_BASE'
export MB_AUTH_HDR='$AUTH_HDR'
mb_get() {
  # mb_get "/api/…" → prints body; nonzero on HTTP>=400 (401 = key revoked / session expired)
  local p="\$1" code
  code=\$(curl -s -o /tmp/mb_last.json -w '%{http_code}' "\$MB_BASE\$p" \\
    -H 'Accept: application/json' -H "\$MB_AUTH_HDR")
  if [ "\$code" -ge 400 ]; then
    echo "Metabase GET \$p -> HTTP \$code (401 = re-auth; 403 = key's group lacks access)" >&2
    cat /tmp/mb_last.json >&2; echo >&2; return 1
  fi
  cat /tmp/mb_last.json
}
EOF
