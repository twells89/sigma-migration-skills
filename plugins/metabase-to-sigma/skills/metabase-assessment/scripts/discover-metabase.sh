#!/usr/bin/env bash
# Metabase estate discovery — read-only inventory walk for the
# metabase-assessment skill.
#
# Auth (one of):
#   export MB_BASE="https://<host>"        # no trailing /api — added here
#   export MB_KEY="mb_..."                 # API key (v49+)  → x-api-key header
#   export MB_SESSION="<token>"            # session token   → X-Metabase-Session header
#
# Usage:
#   discover-metabase.sh --probe
#       Cheap check — GET /api/session/properties, prints the instance version.
#   discover-metabase.sh --out <dir> [--include-personal] [--concurrency N]
#                        [--max-dashboards N] [--skip-cards] [--walk] [--page N]
#       FAST PATH (default — production-validated on a 7k-card / 1.5k-dashboard
#       estate, ~1 minute vs >1 hour for the old per-item walk):
#         1. GET /api/card        — ALL card definitions in ONE response
#                                   (~110MB for 7k cards; streamed to disk, then
#                                   split locally by mb-bulk-split.py)
#         2. GET /api/dashboard   — the dashboard list, then PARALLEL
#                                   per-dashboard GETs (default 16 concurrent,
#                                   resumable: on-disk specs are skipped)
#         3. GET /api/database/{id}/metadata once per referenced database
#            (403 on scoped keys is recorded, not fatal — the converter falls
#             back to card result_metadata, then GET /api/field/{id})
#       --walk forces the legacy per-collection item walk (also the automatic
#       fallback when the bulk card endpoint is unavailable).
#
# READ-ONLY: only ever issues GETs. Never POSTs / modifies / runs anything.
# Resumable (already-downloaded specs are skipped), 401-aware (writes
# token_expired:true into inventory.json and exits gracefully).
# Personal collections are skipped by default (--include-personal to override).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

OUT=""
PROBE=0
PAGE=100
INCLUDE_PERSONAL=0
CONC=16
MAX_DASH=""
SKIP_CARDS=0
WALK=0
while [ $# -gt 0 ]; do
  case "$1" in
    --probe) PROBE=1; shift ;;
    --out)   OUT="$2"; shift 2 ;;
    --page)  PAGE="$2"; shift 2 ;;
    --concurrency) CONC="$2"; shift 2 ;;
    --max-dashboards) MAX_DASH="$2"; shift 2 ;;
    --skip-cards) SKIP_CARDS=1; shift ;;
    --walk) WALK=1; shift ;;
    --include-personal) INCLUDE_PERSONAL=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

: "${MB_BASE:?set MB_BASE (e.g. https://metabase.example.com — no trailing /api)}"
MB_BASE="${MB_BASE%/}"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

# Pick the auth header: MB_KEY (x-api-key) wins, else MB_SESSION.
AUTH_NAME=""; AUTH_VALUE=""
if [ -n "${MB_KEY:-}" ]; then
  AUTH_NAME="x-api-key"; AUTH_VALUE="$MB_KEY"
elif [ -n "${MB_SESSION:-}" ]; then
  AUTH_NAME="X-Metabase-Session"; AUTH_VALUE="$MB_SESSION"
elif [ "$PROBE" = "0" ]; then
  echo "set MB_KEY (API key) or MB_SESSION (session token)" >&2; exit 2
fi

# req <path-with-leading-slash> — body lands in $RESP, status in $HTTP_CODE.
# NOT command-substituted (a subshell would lose HTTP_CODE); curl -o keeps the
# body and the status code separate, so no fragile tail-line parsing either.
RESP=$(mktemp); trap 'rm -f "$RESP"' EXIT
HTTP_CODE=""
TOKEN_EXPIRED=0
req() {
  : > "$RESP"
  if [ -n "$AUTH_NAME" ]; then
    HTTP_CODE=$(curl -s -o "$RESP" -w '%{http_code}' "$MB_BASE$1" \
      -H 'Accept: application/json' -H "$AUTH_NAME: $AUTH_VALUE" || echo "000")
  else
    HTTP_CODE=$(curl -s -o "$RESP" -w '%{http_code}' "$MB_BASE$1" \
      -H 'Accept: application/json' || echo "000")
  fi
  if [ "$HTTP_CODE" = "401" ]; then TOKEN_EXPIRED=1; fi
}
ok() { [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" -ge 200 ] 2>/dev/null && [ "$HTTP_CODE" -lt 400 ] 2>/dev/null; }

# ---- probe ----
if [ "$PROBE" = "1" ]; then
  req "/api/session/properties"
  if ! ok; then
    echo "PROBE FAILED (HTTP ${HTTP_CODE:-?}) — check MB_BASE (no trailing /api) and that the instance is reachable." >&2
    exit 1
  fi
  version=$(jq -r '.version.tag // "unknown"' "$RESP" 2>/dev/null || echo "unknown")
  echo "PROBE OK (HTTP $HTTP_CODE). Metabase version: $version"
  case "$version" in
    v0.4[0-9].*|v1.4[0-9].*|v0.3*|v1.3*) echo "NOTE: pre-v50 — view_count is not exposed; usage ranking falls back to feature counts." ;;
  esac
  exit 0
fi

[ -n "$OUT" ] || { echo "--out <dir> required (unless --probe)" >&2; exit 2; }
mkdir -p "$OUT/specs" "$OUT/metadata"
ART="$OUT/.artifacts.jsonl"; : > "$ART"
PFLAG=""
[ "$INCLUDE_PERSONAL" = "1" ] && PFLAG="--include-personal"

# instance version (best effort, for the inventory header)
req "/api/session/properties"
VERSION=$(jq -r '.version.tag // "unknown"' "$RESP" 2>/dev/null || echo "unknown")

# ---- collection list (flat — needed by both paths for names + personal flags) ----
req "/api/collection?archived=false"
if ! ok; then
  jq -n --arg base "$MB_BASE" --arg code "${HTTP_CODE:-?}" \
    '{environment:{base:$base,error:("collection list failed (HTTP " + $code + ")")},artifacts:[],token_expired:true}' \
    > "$OUT/inventory.json"
  echo "AUTH FAILED (HTTP ${HTTP_CODE:-?}) listing collections — wrote token_expired flag; re-auth (MB_SESSION expired? MB_KEY group lacks perms?) and re-run." >&2
  exit 0
fi
cp "$RESP" "$OUT/collections.json"
N_COLLECTIONS=$(jq 'length' "$OUT/collections.json" 2>/dev/null || echo 0)

# id + name per collection (legacy walk); skip personal collections unless asked.
COLL_TSV=$(jq -r --argjson p "$INCLUDE_PERSONAL" '
  [ .[] | select($p == 1 or ((.personal_owner_id // null) == null and ((.is_personal // false) | not))) ]
  | .[] | "\(.id)\t\(.name)"' "$OUT/collections.json" 2>/dev/null || true)
if ! printf '%s\n' "$COLL_TSV" | cut -f1 | grep -qx 'root'; then
  COLL_TSV=$(printf 'root\tOur analytics\n%s' "$COLL_TSV")
fi

fetched_dbs=""  # space-separated db ids already fetched

fetch_metadata() { # $1 = database id
  local db="$1" f
  [ -n "$db" ] && [ "$db" != "null" ] || return 0
  case " $fetched_dbs " in *" $db "*) return 0 ;; esac
  fetched_dbs="$fetched_dbs $db"
  f="$OUT/metadata/$db.metadata.json"
  [ -s "$f" ] && return 0
  req "/api/database/$db/metadata"
  if ok && [ -s "$RESP" ]; then
    cp "$RESP" "$f"
  elif [ "$HTTP_CODE" = "403" ]; then
    # Scoped keys often can't read whole-database metadata. NOT fatal: the
    # converter resolves field ids via card result_metadata, then
    # GET /api/field/{id} (which works even for restricted DBs), then SQL names.
    echo "database $db: metadata HTTP 403 — use the field-id fallback chain (result_metadata → GET /api/field/{id})" >> "$OUT/metadata/unavailable.txt"
  fi
}

record_failed() { # $1=id $2=type $3=name $4=collection — definition fetch failed
  jq -n --arg id "$1" --arg type "$2" --arg name "$3" --arg coll "$4" \
    '{id:($id|tonumber? // $id),type:$type,name:$name,collection:$coll,specFile:null}' >> "$ART"
}

fetch_card() { # $1=id $2=name $3=collection — appends an artifact record (legacy walk)
  local id="$1" name="$2" coll="$3" f="$OUT/specs/$1.card.json" db
  if [ ! -s "$f" ]; then
    req "/api/card/$id"
    [ "$TOKEN_EXPIRED" = "1" ] && return 0
    if ! ok || [ ! -s "$RESP" ]; then record_failed "$id" "card" "$name" "$coll"; return 0; fi
    cp "$RESP" "$f"
  fi
  db=$(jq -r '.database_id // .dataset_query.database // empty' "$f" 2>/dev/null || true)
  fetch_metadata "$db"
  jq -c --arg coll "$coll" --arg sf "specs/$id.card.json" '
    {id:.id, type:(if (.type=="model") or (.dataset==true) then "model" elif .type=="metric" then "metric" else "card" end),
     name:.name, collection:$coll, view_count:(.view_count // null), specFile:$sf}' "$f" >> "$ART" 2>/dev/null || \
    record_failed "$id" "card" "$name" "$coll"
}

fetch_dashboard() { # $1=id $2=name $3=collection (legacy walk)
  local id="$1" name="$2" coll="$3" f="$OUT/specs/$1.dashboard.json"
  if [ ! -s "$f" ]; then
    req "/api/dashboard/$id"
    [ "$TOKEN_EXPIRED" = "1" ] && return 0
    if ! ok || [ ! -s "$RESP" ]; then record_failed "$id" "dashboard" "$name" "$coll"; return 0; fi
    cp "$RESP" "$f"
  fi
  jq -c --arg coll "$coll" --arg sf "specs/$id.dashboard.json" \
    '{id:.id, type:"dashboard", name:.name, collection:$coll, view_count:(.view_count // null), specFile:$sf}' \
    "$f" >> "$ART" 2>/dev/null || record_failed "$id" "dashboard" "$name" "$coll"
}

# ============================================================================
# FAST PATH (default): bulk card endpoint + parallel dashboard GETs
# ============================================================================
if [ "$WALK" = "0" ]; then
  # ---- cards: one bulk GET, split locally ----
  if [ "$SKIP_CARDS" = "0" ]; then
    if ls "$OUT/specs/"*.card.json >/dev/null 2>&1 && [ -s "$OUT/databases.txt" ]; then
      echo "cards already split on disk — rebuilding artifact records (re-delete specs/ to force a re-fetch)"
      python3 "$SCRIPT_DIR/mb-bulk-split.py" collect-cards --collections "$OUT/collections.json" --out "$OUT" $PFLAG
    else
      echo "bulk-fetching ALL card definitions (GET /api/card — ~15MB per 1k cards, streamed to disk) …"
      BULK="$OUT/cards.bulk.json"
      CODE=$(curl -s -o "$BULK" -w '%{http_code}' "$MB_BASE/api/card" \
        -H 'Accept: application/json' -H "$AUTH_NAME: $AUTH_VALUE" || echo "000")
      if [ "$CODE" = "200" ] && [ -s "$BULK" ]; then
        python3 "$SCRIPT_DIR/mb-bulk-split.py" split-cards --bulk "$BULK" --collections "$OUT/collections.json" --out "$OUT" $PFLAG
        rm -f "$BULK"
      elif [ "$CODE" = "401" ]; then
        TOKEN_EXPIRED=1
      else
        echo "bulk GET /api/card failed (HTTP $CODE) — falling back to the legacy per-collection walk." >&2
        WALK=1
      fi
    fi
  fi

  # ---- dashboards: list once, fetch in parallel (resumable) ----
  if [ "$WALK" = "0" ] && [ "$TOKEN_EXPIRED" = "0" ]; then
    req "/api/dashboard"
    if ok; then
      cp "$RESP" "$OUT/dashboards.list.json"
      DIDS="$OUT/.dash_ids"
      python3 "$SCRIPT_DIR/mb-bulk-split.py" list-dashboards --list "$OUT/dashboards.list.json" \
        --collections "$OUT/collections.json" --out "$OUT" $PFLAG ${MAX_DASH:+--max "$MAX_DASH"} > "$DIDS"
      N_TO_FETCH=$(grep -c . "$DIDS" || true)
      if [ "${N_TO_FETCH:-0}" -gt 0 ]; then
        echo "fetching $N_TO_FETCH dashboards ($CONC parallel, resumable) …"
        export MB_BASE AUTH_NAME AUTH_VALUE OUT
        xargs -P "$CONC" -n 1 sh -c '
          id="$0"; f="$OUT/specs/$id.dashboard.json"
          [ -s "$f" ] && exit 0
          tmp="$f.tmp.$$"
          code=$(curl -s -o "$tmp" -w "%{http_code}" "$MB_BASE/api/dashboard/$id" \
            -H "Accept: application/json" -H "$AUTH_NAME: $AUTH_VALUE" || echo 000)
          if [ "$code" = "200" ] && [ -s "$tmp" ]; then mv "$tmp" "$f"
          else rm -f "$tmp"; echo "dashboard $id: HTTP $code" >&2; fi
        ' < "$DIDS" || true
      fi
      python3 "$SCRIPT_DIR/mb-bulk-split.py" collect-dashboards --collections "$OUT/collections.json" --out "$OUT"
      rm -f "$DIDS"
    elif [ "$HTTP_CODE" = "401" ]; then
      TOKEN_EXPIRED=1
    else
      echo "GET /api/dashboard failed (HTTP $HTTP_CODE) — dashboards via the legacy walk." >&2
      WALK=1
    fi
  fi

  # ---- database metadata (once per referenced database; 403 = fallback chain) ----
  if [ "$TOKEN_EXPIRED" = "0" ] && [ -s "$OUT/databases.txt" ]; then
    while IFS= read -r db; do
      [ -n "$db" ] && fetch_metadata "$db"
    done < "$OUT/databases.txt"
  fi
fi

# ============================================================================
# LEGACY WALK (--walk, or automatic fallback): per-collection item pages
# ============================================================================
if [ "$WALK" = "1" ]; then
  while IFS=$'\t' read -r cid cname; do
    [ -n "$cid" ] || continue
    [ "$TOKEN_EXPIRED" = "1" ] && break
    offset=0
    while :; do
      [ "$TOKEN_EXPIRED" = "1" ] && break
      req "/api/collection/$cid/items?models=card&models=dashboard&models=dataset&limit=$PAGE&offset=$offset"
      [ "$TOKEN_EXPIRED" = "1" ] && break
      ok || break
      n=$(jq '.data | length' "$RESP" 2>/dev/null || echo 0)
      [ "$n" -gt 0 ] 2>/dev/null || break
      # snapshot the page before inner reqs reuse $RESP
      items=$(jq -r '.data[] | "\(.model)\t\(.id)\t\(.name)"' "$RESP")
      while IFS=$'\t' read -r model iid iname; do
        [ -n "$iid" ] || continue
        [ "$TOKEN_EXPIRED" = "1" ] && break
        case "$model" in
          card|dataset) fetch_card "$iid" "$iname" "$cname" ;;
          dashboard)    fetch_dashboard "$iid" "$iname" "$cname" ;;
        esac
      done <<< "$items"
      [ "$n" -lt "$PAGE" ] && break
      offset=$((offset + PAGE))
    done
  done <<< "$COLL_TSV"
fi

# ---- sandboxing probe (Pro/EE only; 404 on OSS is fine) ----
if [ "$TOKEN_EXPIRED" = "0" ]; then
  req "/api/mt/gtap" || true
  if ok && jq -e 'type=="array" and length>0' "$RESP" >/dev/null 2>&1; then
    cp "$RESP" "$OUT/sandboxes.json"
    echo "NOTE: $(jq 'length' "$OUT/sandboxes.json") sandboxing policies found (EE) -> $OUT/sandboxes.json"
  fi
fi

# ---- assemble inventory.json ----
jq -s --arg base "$MB_BASE" --arg version "$VERSION" --argjson ncoll "${N_COLLECTIONS:-0}" \
   --argjson expired "$TOKEN_EXPIRED" '
  . as $arts |
  {environment:{
     generated_at: (now | strftime("%Y-%m-%d")),
     base: $base, version: $version,
     n_collections: $ncoll,
     by_type: (reduce $arts[] as $a ({}; .[$a.type] = ((.[$a.type] // 0) + 1))),
     n_artifacts: ($arts | length),
     n_cards: ([$arts[] | select(.type=="card" or .type=="metric")] | length),
     n_models: ([$arts[] | select(.type=="model")] | length),
     n_dashboards: ([$arts[] | select(.type=="dashboard")] | length)
   },
   artifacts: $arts}
  + (if $expired == 1 then {token_expired:true} else {} end)
' "$ART" > "$OUT/inventory.json"
rm -f "$ART"

n_total=$(jq '.environment.n_artifacts' "$OUT/inventory.json")
n_models=$(jq '.environment.n_models' "$OUT/inventory.json")
n_cards=$(jq '.environment.n_cards' "$OUT/inventory.json")
n_dash=$(jq '.environment.n_dashboards' "$OUT/inventory.json")
msg="discovered $n_total artifacts ($n_models models, $n_cards questions, $n_dash dashboards) -> $OUT/inventory.json"
if [ "$TOKEN_EXPIRED" = "1" ]; then
  msg="$msg  [WARNING: auth expired mid-walk (401) — re-auth and re-run to complete; on-disk specs are kept]"
fi
echo "$msg"
