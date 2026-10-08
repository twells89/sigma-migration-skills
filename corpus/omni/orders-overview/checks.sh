#!/usr/bin/env bash
# Offline Omni orders-overview: DM + workbook goldens, RLS detect, query oracle.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/omni-to-sigma/skills/omni-to-sigma"
ASMT="$REPO_ROOT/plugins/omni-to-sigma/skills/omni-assessment"
FIX="$SKILL/fixtures/orders-overview"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ruby "$SKILL/scripts/convert-dm.rb" --model-dir "$FIX" --topic orders --out "$TMP/dm.json"
python3 "$REPO_ROOT/corpus/lib/corpus_check.py" diff \
  "$CASE_DIR/golden/data-model.json" "$TMP/dm.json"

ruby "$SKILL/scripts/build-workbook.rb" \
  --export "$FIX/dashboard-export.json" --model-dir "$FIX" \
  --folder-id fixture-folder --out "$TMP/wb.json"
python3 "$REPO_ROOT/corpus/lib/corpus_check.py" diff \
  "$CASE_DIR/golden/workbook.json" "$TMP/wb.json"

ruby "$SKILL/scripts/detect-rls.rb" --model-dir "$FIX" --out "$TMP/rls.json"
ruby "$SKILL/scripts/apply-sigma-rls.rb" --detect "$TMP/rls.json" --out "$TMP/rls-plan.json"
ruby "$SKILL/scripts/omni-query-oracle.rb" --export "$FIX/dashboard-export.json" --out "$TMP/oracle.json"
ruby "$ASMT/scripts/omni-inventory.rb" --model-dir "$FIX" --out "$TMP/inventory.json"

set +e
ruby "$SKILL/scripts/apply-sigma-rls.rb" --detect "$TMP/rls.json" --out "$TMP/refused.json" --apply
refuse=$?
set -e
test "$refuse" -eq 2

python3 - "$TMP/rls.json" "$TMP/oracle.json" "$TMP/inventory.json" "$TMP/rls-plan.json" <<'PY'
import json, sys
rls, oracle, inv, plan = (json.load(open(p)) for p in sys.argv[1:])
assert rls["summary"]["findings"] >= 3
assert rls["summary"]["access_filters"] >= 1
assert rls["summary"]["access_grants"] >= 1
assert oracle["mode"] == "offline"
assert len(oracle["queries"]) == 2
assert oracle["queries"][0]["endpoint"] == "POST /api/v1/query/run"
assert inv["counts"]["views"] == 2
assert inv["counts"]["query_views"] == 1
assert inv["shortlist"][0]["key"] == "orders"
assert plan["row_filters"][0]["user_attribute"] == "region"
print("     OK omni orders-overview DM, workbook, RLS, oracle, inventory")
PY
