#!/usr/bin/env bash
# End-to-end offline pin for converter-backed formula audit and complete
# Tableau source-object reporting on a real corpus workbook.
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma"
S="$SKILL/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$CASE_DIR/workbook-content.twb" "$TMP/workbook-content.twb"
cp "$CASE_DIR/golden/chart-specs.json" "$TMP/wb-spec.json"

ruby "$S/parse-twb-layout.rb" "$TMP/workbook-content.twb" "$TMP/dashboard-layout.json"
ruby "$S/extract-calc-fields.rb" --workbook-luid winprobe-fixture --source twb \
  --twb "$TMP/workbook-content.twb" --out "$TMP/calc-fields.json" --no-cache
ruby "$S/scan-workbook-gaps.rb" "$TMP/workbook-content.twb" "$TMP/workbook-content-gaps-report.md"

python3 - "$TMP/workbook-content-gaps-report.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
a = d["formula_audit"]
assert a["formulas"], "fixture calculations were not audited"
assert sum(a["counts"].values()) == len(a["formulas"])
assert all(ds["total"] == sum(ds["counts"].values()) for ds in a["datasources"])
assert a["counts"]["not_converted"] > 0, a["counts"]
assert any(row["name"] == "Converter-refused or unmapped calculated fields"
           and row["status"] == "unhandled" for row in d["detected_features"])
PY

cat >"$TMP/parity-final.json" <<'JSON'
{"status":"PASS","charts_total":8,"charts_pass":8,"visual_checked":true,"visual_verdict":"pass"}
JSON
cat >"$TMP/render-health.json" <<'JSON'
{"status":"PASS","width":1200,"height":800,"ink_ratio":0.2,"entropy":4.0,"reasons":[]}
JSON

ruby "$S/lint-render-integrity.rb" --spec "$TMP/wb-spec.json" \
  --out "$TMP/blank-risk-elements.json"
ruby "$S/build-source-object-census.rb" --workdir "$TMP"
ruby "$S/build-migration-report.rb" --workdir "$TMP"

python3 - "$TMP/source-object-census.json" "$TMP/migration-result.json" <<'PY'
import json, sys
census, result = (json.load(open(p)) for p in sys.argv[1:])
required = {"dashboard", "worksheet", "dashboard-zone", "calculation"}
types = {row["type"] for row in census["objects"]}
assert required <= types, (required, types)
assert census["summary"]["complete"] is True
assert census["summary"]["accounted"] == census["summary"]["total"] == len(census["objects"])
assert result["verdict"] != "RED"
assert result["summary"]["complete"] is True
assert result["summary"]["accounted"] == result["summary"]["total"] == len(result["source_objects"])
assert {(r["type"], r["id"], r["status"]) for r in census["objects"]} == {
    (r["type"], r["id"], r["status"]) for r in result["source_objects"]
}
PY

ruby "$S/compile-tableau-offline.rb" \
  --case-dir "$CASE_DIR" \
  --workdir "$TMP/compiler" \
  --out "$TMP/compiler-workbook.json" \
  --compare "$CASE_DIR/golden/workbook.json"
python3 - "$TMP/compiler/compile-plan-reconcile.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert result["status"] == "PASS"
assert len(result["matched_chart_keys"]) == 8
assert not result["missing_controls"]
PY

echo "     OK converter formula audit + complete source-object migration report"
