#!/usr/bin/env bash
# Fetch every metadata column for one Sigma warehouse table.
#
# The API defaults to 50 columns per response. This helper requests the
# maximum page size and follows each opaque nextPageToken until exhaustion.
#
# Usage:
#   list-table-columns.sh <table-inode-id>
#
# Output:
#   {"entries":[...],"pageCount":N,"totalCount":N}

set -euo pipefail

TABLE_ID="${1:-}"
if [[ -z "$TABLE_ID" || "$#" -ne 1 ]]; then
  echo "Usage: $0 <table-inode-id>" >&2
  exit 64
fi

: "${SIGMA_BASE_URL:?SIGMA_BASE_URL is not set}"
: "${SIGMA_API_TOKEN:?SIGMA_API_TOKEN is not set}"

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "Error: $bin is required" >&2
    exit 1
  }
done

BASE_URL="${SIGMA_BASE_URL%/}"
SIGMA_DOMAIN="sigma""computing.com"
case "$BASE_URL" in
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
  *)
    echo "Error: SIGMA_BASE_URL must be one of the published Sigma API hosts." >&2
    exit 1
    ;;
esac

PAGES_FILE=$(mktemp)
TOKENS_FILE=$(mktemp)
cleanup() {
  rm -f "$PAGES_FILE" "$TOKENS_FILE"
}
trap cleanup EXIT

PAGE_TOKEN=""
PAGE_COUNT=0
while :; do
  CURL_ARGS=(
    -sfG
    -H "Authorization: Bearer $SIGMA_API_TOKEN"
    --data-urlencode "pageSize=1000"
  )
  if [[ -n "$PAGE_TOKEN" ]]; then
    CURL_ARGS+=(--data-urlencode "pageToken=$PAGE_TOKEN")
  fi

  RESPONSE=$(curl "${CURL_ARGS[@]}" \
    "$BASE_URL/v2/connections/tables/$TABLE_ID/columns") || {
      echo "Error: failed to fetch table columns page $((PAGE_COUNT + 1))." >&2
      exit 1
    }

  if ! printf '%s' "$RESPONSE" |
    jq -e '.entries | type == "array"' >/dev/null 2>&1; then
    echo "Error: table columns response did not contain an entries array." >&2
    exit 1
  fi

  printf '%s\n' "$RESPONSE" >> "$PAGES_FILE"
  PAGE_COUNT=$((PAGE_COUNT + 1))
  [[ "$PAGE_COUNT" -le 10000 ]] || {
    echo "Error: table column pagination exceeded 10,000 pages." >&2
    exit 1
  }

  NEXT_PAGE_TOKEN=$(printf '%s' "$RESPONSE" | jq -r '.nextPageToken // empty')
  [[ -n "$NEXT_PAGE_TOKEN" ]] || break
  if grep -Fqx -- "$NEXT_PAGE_TOKEN" "$TOKENS_FILE"; then
    echo "Error: table columns API repeated nextPageToken; refusing an infinite loop." >&2
    exit 1
  fi
  printf '%s\n' "$NEXT_PAGE_TOKEN" >> "$TOKENS_FILE"
  PAGE_TOKEN="$NEXT_PAGE_TOKEN"
done

jq -s '{
  entries: ([.[].entries[]]),
  pageCount: length,
  totalCount: ([.[].entries[]] | length)
}' "$PAGES_FILE"
