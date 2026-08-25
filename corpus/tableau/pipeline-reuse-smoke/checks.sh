#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
APPLY="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/apply-workbook-pipeline.rb"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tableau-pipeline-reuse.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ruby "$APPLY" \
  --wb-spec "$CASE_DIR/generated.json" \
  --donor-spec "$CASE_DIR/donor.json" \
  --plan "$CASE_DIR/pipeline-map.json" \
  --out "$TMP/workbook.json"

python3 - "$TMP/workbook.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))["document"]
by_id = {e["id"]: e for e in doc["elements"]}
assert "actuals" in by_id
assert by_id["master-overview"]["source"]["elementId"] == "actuals"
assert by_id["master-overview"]["columns"][0]["formula"] == '"P&L"'
assert by_id["revenue-kpi"]["columns"][0]["formula"] == "Sum([Master/Amount])"
assert by_id["revenue-kpi"]["name"] == "Revenue"
PY
echo "PASS: reviewed pipeline map applies deterministically"
