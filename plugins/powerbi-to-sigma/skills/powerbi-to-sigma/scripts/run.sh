#!/usr/bin/env bash
# run.sh — orchestrate the Power BI → Sigma conversion pipeline end to end.
#
# Mirrors tableau-to-sigma's script-driven pipeline. Stages:
#   1. EXTRACT      fetch + normalize the report PBIR        -> signals.json
#   2. CONVERT      model.bim -> Sigma DM (MCP step is agent-driven; this prints
#                   the instruction, then applies fixups to the converter output)
#   3. POST DM      post-and-readback.rb --type datamodel
#   4. BUILD WB     signals.json + master-map -> workbook spec + layout
#   5. POST WB      post-and-readback.rb --type workbook
#   6. LAYOUT       put-layout.rb
#   7. PARITY       phase6-parity-pbi.rb (DAX vs Sigma)
#
# Two MCP steps cannot run from a shell (they are agent/MCP calls): the
# convert_powerbi_to_sigma conversion (stage 2) and the sigma-mcp-v2 actuals
# collection (stage 7). run.sh runs everything deterministic and STOPS with a
# clear instruction at each MCP gate, so it is safe to re-run: pass the stage to
# resume from with --from.
#
# Usage:
#   # Sigma auth resolves from a caller token, stored browser session, or
#   # unattended client credentials.
#   scripts/run.sh \
#     --work-dir /tmp/pbir \
#     --workspace <wsId> --report <reportId> --dataset <datasetId> \
#     --bim /tmp/pbix/model.bim \
#     --connection <connUUID> --database <DB> --schema <SCHEMA> \
#     --ref-dm <referenceDataModelId> \
#     --master-map /tmp/pbir/master-map.json \
#     --name "My Report (from Power BI)" \
#     [--from extract|convert|post-dm|build|post-wb|layout|parity]
#
# All artifacts land in --work-dir; each stage is idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

WORK=/tmp/pbir; FROM=extract
WS=""; REPORT=""; DATASET=""; BIM=""; CONN=""; DB=""; SCHEMA=""
REF_DM=""; MMAP=""; NAME=""; CVT_OUT=""; FOLDER=""
while [[ $# -gt 0 ]]; do case "$1" in
  --work-dir) WORK="$2"; shift 2;;
  --workspace) WS="$2"; shift 2;;
  --report) REPORT="$2"; shift 2;;
  --dataset) DATASET="$2"; shift 2;;
  --bim) BIM="$2"; shift 2;;
  --connection) CONN="$2"; shift 2;;
  --database) DB="$2"; shift 2;;
  --schema) SCHEMA="$2"; shift 2;;
  --ref-dm) REF_DM="$2"; shift 2;;
  --master-map) MMAP="$2"; shift 2;;
  --name) NAME="$2"; shift 2;;
  --folder-id) FOLDER="$2"; shift 2;;
  --converter-out) CVT_OUT="$2"; shift 2;;
  --from) FROM="$2"; shift 2;;
  *) echo "unknown arg $1" >&2; exit 1;;
esac; done
mkdir -p "$WORK"
CVT_OUT="${CVT_OUT:-$WORK/dm-raw.json}"

# ---- Python resolution + venv bootstrap (bead 7o01) -------------------------
# The extract/auth scripts need msal + requests + truststore (scripts/
# requirements.txt). Resolution order: $PBI_PY (explicit) -> <work-dir>/.venv
# (bootstrapped here) -> the legacy /tmp/pbiauth venv -> system python3 IF it
# already imports msal -> bootstrap a fresh venv at $WORK/.venv.
PY="${PBI_PY:-}"
if [[ -z "$PY" ]]; then
  if [[ -x "$WORK/.venv/bin/python" ]]; then PY="$WORK/.venv/bin/python"
  elif [[ -x /tmp/pbiauth/bin/python ]]; then PY=/tmp/pbiauth/bin/python
  elif python3 -c 'import msal, requests, truststore' 2>/dev/null; then PY=python3
  else
    echo "== bootstrap: creating Python venv at $WORK/.venv (msal/requests/truststore) =="
    python3 -m venv "$WORK/.venv"
    "$WORK/.venv/bin/pip" install --quiet -r "$HERE/requirements.txt"
    PY="$WORK/.venv/bin/python"
  fi
fi

stage_idx() { case "$1" in
  extract) echo 1;; convert) echo 2;; post-dm) echo 3;; build) echo 4;;
  post-wb) echo 5;; layout) echo 6;; parity) echo 7;; *) echo 0;; esac; }
START=$(stage_idx "$FROM")

if [[ $START -le 1 ]]; then
  echo "== [1/7] EXTRACT PBIR =="
  # bead anlb: a fetched definition may be the CLASSIC single report.json
  # (top-level sections[], no definition/ dir) instead of exploded PBIR.
  # extract-pbir.py exits non-zero on that shape — auto-branch to
  # extract-report-classic.py instead of dying.
  EXTRACT_OK=0
  if [[ -n "$WS" && -n "$REPORT" ]]; then
    # the fetch half still runs (parts land in $WORK) even when the extract half fails
    "$PY" "$HERE/extract-pbir.py" --workspace "$WS" --report "$REPORT" --pbir-dir "$WORK" --out "$WORK/signals.json" && EXTRACT_OK=1 || true
  elif [[ -d "$WORK/definition" ]]; then
    "$PY" "$HERE/extract-pbir.py" --pbir-dir "$WORK" --out "$WORK/signals.json" && EXTRACT_OK=1 || true
  fi
  if [[ $EXTRACT_OK -eq 0 ]]; then
    RJ=""
    for cand in "$WORK/report.json" "$WORK"/*/report.json; do
      [[ -f "$cand" ]] && { RJ="$cand"; break; }
    done
    if [[ -n "$RJ" && ! -d "$WORK/definition" ]]; then
      echo "  classic single report.json detected ($RJ) — branching to extract-report-classic.py"
      "$PY" "$HERE/extract-report-classic.py" --report-json "$RJ" --out "$WORK/signals.json"
    else
      echo "  EXTRACT FAILED: no definition/ dir and no classic report.json under $WORK" >&2
      exit 1
    fi
  fi

  # ---- stage 1.5: SOURCE-FRESHNESS PREFLIGHT (bead fmte) — NON-BLOCKING ----
  # Import-mode models are frozen snapshots; Sigma reads the live warehouse.
  # The preflight is only CONSUMED at stage 7 parity, so it runs as a
  # BACKGROUND LANE concurrent with convert/post/build (3-8s of PBI round-trips
  # off the critical path); its log is replayed before stage 7. Best-effort:
  # never fatal. If freshness.json already exists (resume), it is reused.
  if [[ -n "$WS" && -n "$DATASET" && ! -f "$WORK/freshness.json" ]]; then
    echo "== [1.5/7] SOURCE-FRESHNESS PREFLIGHT (non-blocking) =="
    "$PY" "$HERE/pbi-freshness.py" --workspace "$WS" --dataset "$DATASET" \
      ${BIM:+--tmsl "$BIM"} --out "$WORK/freshness.json" \
      >"$WORK/freshness.log" 2>&1 &
    FRESH_PID=$!
    echo "  launched in background (pid $FRESH_PID) — consumed at stage 7 parity"
  elif [[ -f "$WORK/freshness.json" ]]; then
    echo "== [1.5/7] SOURCE-FRESHNESS PREFLIGHT: reusing existing freshness.json =="
  fi
fi

if [[ $START -le 2 ]]; then
  echo "== [2/7] CONVERT model.bim (MCP gate) =="
  if [[ -f "$CVT_OUT" ]]; then
    echo "  converter output present ($CVT_OUT) — applying fixups"
    ruby "$HERE/convert-model.rb" --converter-out "$CVT_OUT" \
      ${REF_DM:+--ref-dm "$REF_DM"} ${NAME:+--name "$NAME"} --out "$WORK/dm-spec.json"
  else
    [[ -n "$BIM" ]] && ruby "$HERE/convert-model.rb" --bim "$BIM" \
      ${CONN:+--connection "$CONN"} ${DB:+--database "$DB"} ${SCHEMA:+--schema "$SCHEMA"}
    echo ""
    echo "  >>> GATE: run the convert_powerbi_to_sigma MCP call above, save its"
    echo "      sigmaDataModel JSON to $CVT_OUT, then re-run: --from convert"
    exit 0
  fi
fi

if [[ $START -le 3 ]]; then
  echo "== [3/7] POST DATA MODEL =="
  # bead 7o01(d): post-and-readback prints its verdict on STDERR — merge it into
  # the tee'd log (a bare `| tee` swallows the verdict from the saved log).
  ruby "$HERE/post-and-readback.rb" --type datamodel --spec "$WORK/dm-spec.json" \
    --out "$WORK/dm-idmap.json" --workdir "$WORK" 2>&1 | tee "$WORK/dm-post.txt"
  echo "  NOTE: PUT reassigns element IDs — use the readback IDs in master-map.json"
fi

if [[ $START -le 4 ]]; then
  echo "== [4/7] BUILD WORKBOOK SPEC + LAYOUT =="
  [[ -n "$MMAP" ]] || { echo "  --master-map required for build stage" >&2; exit 1; }
  # The workbook POST requires a folderId. Use --folder-id if given, else inherit
  # the DM's folderId (harvested at convert) from $WORK/dm-spec.json.
  FOLDER_USE="$FOLDER"
  if [[ -z "$FOLDER_USE" && -f "$WORK/dm-spec.json" ]]; then
    FOLDER_USE=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("folderId",""))' "$WORK/dm-spec.json" 2>/dev/null || true)
  fi
  ruby "$HERE/build-workbook-from-pbir.rb" --signals "$WORK/signals.json" \
    --master-map "$MMAP" ${NAME:+--name "$NAME"} ${FOLDER_USE:+--folder-id "$FOLDER_USE"} \
    --out "$WORK/workbook-spec.json" --layout-out "$WORK/layout.xml"
fi

if [[ $START -le 5 ]]; then
  echo "== [5/7] POST WORKBOOK =="
  # bead 7o01(d): keep STDERR (the post-and-readback verdict) in the tee'd log.
  ruby "$HERE/post-and-readback.rb" --type workbook --spec "$WORK/workbook-spec.json" \
    --out "$WORK/wb-idmap.json" --workdir "$WORK" 2>&1 | tee "$WORK/wb-post.txt"
fi

if [[ $START -le 6 ]]; then
  echo "== [6/7] LAYOUT (MUST be the FINAL write — bead 16i) =="
  # bead 16i: layout is hard-ordered as the last spec write. The workbook spec
  # already EMBEDS the layout (build step) so the stage-5 POST never triggers
  # Sigma's single-column auto-layout; this PUT is the authoritative final write.
  # NOTHING may bare-PUT /workbooks/spec after this point (parity is read-only).
  WB_ID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$WORK/wb-post.txt" | head -1 || true)
  if [[ -n "$WB_ID" && -f "$WORK/layout.xml" ]]; then
    ruby "$HERE/put-layout.rb" --workbook "$WB_ID" --layout "$WORK/layout.xml"
    # Re-assert the layout actually stuck (catches a silent wipe).
    if ruby "$HERE/assert-phase6-ran.rb" --tableau "$WORK" --workbook-id "$WB_ID" \
         --skip-orphan-check --skip-column-check 2>/dev/null \
       | grep -q 'gate 4/4: layout XML applied'; then
      echo "  layout-survives check: OK"
    else
      echo "  layout-survives check: (deferred — full gate runs after parity)"
    fi
  else
    echo "  (skipped — need wb id in wb-post.txt and layout.xml)"
  fi
fi

if [[ $START -le 7 ]]; then
  # join the non-blocking stage-1.5 freshness lane before parity consumes it
  if [[ -n "${FRESH_PID:-}" ]]; then
    wait "$FRESH_PID" 2>/dev/null || true
    [[ -f "$WORK/freshness.log" ]] && sed 's/^/  /' "$WORK/freshness.log"
    [[ -f "$WORK/freshness.json" ]] || echo "  (freshness preflight produced no freshness.json — continuing without it)"
  fi
  echo "== [7/7] PARITY (DAX vs Sigma — MCP gate) =="
  if [[ -n "$WS" && -n "$DATASET" && -f "$WORK/chart-dax.json" ]]; then
    WB_ID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$WORK/wb-post.txt" | head -1 || true)
    # bead fmte: the staleness banner LEADS the parity output, and finalize
    # classifies deltas MATCH / STALE-EXPLAINED / DIVERGENT (only DIVERGENT blocks).
    FRESH_ARG=""
    [[ -f "$WORK/freshness.json" ]] && FRESH_ARG="--freshness $WORK/freshness.json"
    ruby "$HERE/phase6-parity-pbi.rb" --emit-dax --workspace "$WS" --dataset "$DATASET" \
      --chart-dax "$WORK/chart-dax.json" --workbook-id "$WB_ID" --out "$WORK/parity-plan.json" \
      $FRESH_ARG
    echo "  >>> GATE: collect Sigma actuals via sigma-mcp-v2 query (per chart above),"
    echo "      save to $WORK/parity-actuals.json, then:"
    echo "      ruby $HERE/phase6-parity-pbi.rb --finalize --plan $WORK/parity-plan.json \\"
    echo "        --actuals $WORK/parity-actuals.json --out-dir $WORK $FRESH_ARG"
  else
    echo "  (skipped — need --workspace, --dataset, and $WORK/chart-dax.json)"
  fi
fi

# ---- FINAL GATE: assert-phase6-ran (bead 148 flags: --tableau + --workbook-id) ----
# The shared hard gate proves Phase 6 ran, no orphan workbooks, no type=error
# columns, AND the layout survived (gate 4/4 — bead 16i). It needs the
# per-conversion dir via --tableau (NOT --workdir) and --workbook-id.
WB_ID=$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$WORK/wb-post.txt" 2>/dev/null | head -1 || true)
if [[ -f "$WORK/parity-final.json" && -n "$WB_ID" ]]; then
  echo "== FINAL GATE: assert-phase6-ran =="
  ruby "$HERE/assert-phase6-ran.rb" --tableau "$WORK" --workbook-id "$WB_ID" || {
    echo "  >>> GATE FAILED — fix the reported issue before declaring done."; exit 1;
  }
elif [[ -n "$WB_ID" ]]; then
  echo "== FINAL GATE (layout + columns only; parity-final.json not yet present) =="
  ruby "$HERE/assert-phase6-ran.rb" --tableau "$WORK" --workbook-id "$WB_ID" \
    --skip-orphan-check 2>&1 | grep -E 'gate [34]/4' || true
  echo "  (run the parity --finalize MCP gate to complete gate 1/4)"
fi
echo "== run.sh done (resume any stage with --from <stage>) =="
