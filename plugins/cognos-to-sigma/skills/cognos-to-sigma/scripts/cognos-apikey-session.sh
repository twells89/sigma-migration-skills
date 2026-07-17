#!/usr/bin/env bash
# cognos-apikey-session.sh — establish a Cognos Analytics REST session with a
# CA API key (login key) against the DURABLE /api/v1 surface — fully headless,
# no browser cookie paste. Emits a `cog_get` function (same contract as
# get-cognos-session.sh) so it drops into Phase 0b discovery.
#
#   WHEN TO USE THIS vs get-cognos-session.sh (session replay):
#   • Try THIS FIRST for any tenant where you have a CA API key. On instances
#     whose /api/v1 surface is NOT behind an Akamai/bot-protection WAF, the API
#     key authenticates AND content reads/writes work headlessly over /api/v1.
#     Verified 2026 on a PAID CAoC instance: /api/v1 read+write worked with
#     plain curl (list datasources, create a Snowflake data server, register +
#     import a schema, POST /modules, POST an exploration) WHILE /bi/v1 returned
#     HTTP 441 from the WAF — the inverse of the trial-tenant assumption.
#   • If /api/v1 content calls return 441/403 (Akamai-walled tenant — common on
#     IBMid-SSO trials), FALL BACK to get-cognos-session.sh (browser session
#     replay) + the headed-Chrome/Puppeteer bridge in refs/dashboard-migration.md.
#   Document which path the engagement is using.
#
#   ENDPOINT NOTE — /api/v1 paths differ from the /bi/v1 "glass" paths:
#     folder items   /api/v1/content/{id}/items                 (vs /bi/v1/objects/{id}/items)
#     data module    /api/v1/modules/{id}/metadata              (vs /bi/v1/metadata/modules/{id})
#     report / dash  /api/v1/content/{id}?fields=specification  (report XML / exploration JSON)
#     datasources    /api/v1/datasources ... /connections ... /signons/{id}/schemas
#     OpenAPI (this instance) /api/api-docs/swagger.json
#
# USAGE:
#   export COG_INSTANCE=https://<your-instance>.ca.analytics.ibm.com   # no trailing /api/v1
#   export COG_APIKEY=<CA API key>                         # or COG_APIKEY_FILE=~/.cognos/apikey.txt
#   eval "$(scripts/cognos-apikey-session.sh)"
#   cog_get "/content/.public_folders/items?fields=defaultName,type,id"   # smoke test
#
# Env it expects:
#   COG_INSTANCE     https://<instance>            (base host, no /api/v1)
#   COG_APIKEY       the CA API login key value    (or COG_APIKEY_FILE=<path>)
#   COG_COOKIE_JAR   cookie jar path (default ~/.cognos/apikey_cookies.txt)

: "${COG_INSTANCE:?set COG_INSTANCE=https://<instance> (no trailing /api/v1)}"
KEY="${COG_APIKEY:-}"
if [ -z "$KEY" ] && [ -n "${COG_APIKEY_FILE:-}" ] && [ -s "${COG_APIKEY_FILE}" ]; then
  KEY="$(tr -d '\r\n' < "$COG_APIKEY_FILE")"
fi
if [ -z "$KEY" ]; then
  echo "echo 'Set COG_APIKEY=<CA API key> or COG_APIKEY_FILE=<path>' >&2; false"; exit 0
fi
JAR="${COG_COOKIE_JAR:-$HOME/.cognos/apikey_cookies.txt}"
mkdir -p "$(dirname "$JAR")"; : > "$JAR"
BASE="${COG_INSTANCE%/}/api/v1"

# 1) create the session with the API login key (PUT /api/v1/session).
_body=$(printf '{"parameters":[{"name":"CAMAPILoginKey","value":"%s"}]}' "$KEY")
_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/session" \
  -H 'Content-Type: application/json' -c "$JAR" -d "$_body")
if [ "$_code" != "201" ] && [ "$_code" != "200" ]; then
  echo "echo 'CA API-key auth failed: PUT /api/v1/session -> HTTP $_code (401=bad key, 403=existing session/blocked, 000=host unreachable)' >&2; false"; exit 0
fi
# 2) obtain the XSRF-TOKEN cookie (GET /api/v1/session), required on every later call.
curl -s -o /dev/null -b "$JAR" -c "$JAR" "$BASE/session" >/dev/null 2>&1 || true
_xsrf=$(awk '$0 !~ /^#/ && $6=="XSRF-TOKEN"{print $7}' "$JAR" | tail -1)

# Emit the session env + a `cog_get` (eval this script's stdout).
cat <<EOF
export COG_BASE='$BASE'
export COG_COOKIE_JAR='$JAR'
export COG_XSRF='$_xsrf'
# cog_get "<path under /api/v1>" -> prints body; nonzero on HTTP>=400.
#   441/403 here = /api/v1 is WAF-walled on this tenant; fall back to get-cognos-session.sh.
cog_get() {
  local p="\$1" code
  code=\$(curl -s -o /tmp/cog_last.json -w '%{http_code}' "\$COG_BASE\$p" \\
    -H 'Accept: application/json' -H "X-XSRF-Token: \$COG_XSRF" \\
    -H 'X-Requested-With: XMLHttpRequest' -b "\$COG_COOKIE_JAR" -c "\$COG_COOKIE_JAR")
  if [ "\$code" -ge 400 ]; then
    echo "Cognos GET \$p -> HTTP \$code (441/403 => /api/v1 WAF-walled here; use get-cognos-session.sh)" >&2
    cat /tmp/cog_last.json >&2; echo >&2; return 1
  fi
  cat /tmp/cog_last.json
}
EOF
