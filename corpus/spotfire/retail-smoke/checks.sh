#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$ROOT/plugins/spotfire-to-sigma/skills/spotfire-to-sigma"
MANIFEST="$SKILL/fixtures/spotfire-manifest.json"
SOURCE_MAP="$SKILL/fixtures/source-map.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 "$SKILL/scripts/validate_manifest.py" "$MANIFEST" --quiet
python3 "$SKILL/scripts/scan_gaps.py" "$MANIFEST" \
  --source-map "$SOURCE_MAP" --out "$TMP/gap-report.json"
python3 "$SKILL/scripts/convert.py" \
  --manifest "$MANIFEST" --source-map "$SOURCE_MAP" \
  --out-dm "$TMP/dm.json" --out-workbook "$TMP/wb.json" \
  --out-gaps "$TMP/conversion-gaps.json" \
  --out-resolved-sources "$TMP/resolved-sources.json"

ruby "$SKILL/scripts/lib/preflight_lint.rb" "$TMP/wb.json"
ruby "$SKILL/scripts/lib/layout_lint.rb" "$TMP/wb.json"
ruby "$SKILL/scripts/lib/control_lint.rb" "$TMP/wb.json"

python3 "$ROOT/corpus/lib/corpus_check.py" normalize \
  "$TMP/dm.json" "$TMP/data-model.json"
python3 "$ROOT/corpus/lib/corpus_check.py" normalize \
  "$TMP/wb.json" "$TMP/workbook.json"

python3 "$SKILL/scripts/migrate_spotfire.py" \
  --manifest "$MANIFEST" --source-map "$SOURCE_MAP" \
  --workdir "$TMP/orchestrated" --dry-run
python3 - "$TMP/orchestrated" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
state = json.loads((root / "run-state.json").read_text())
assert state["status"] == "dry-run-complete"
assert state["manifest_validated"] is True
assert state["conversion_complete"] is True
assert state["complete"] is False
for key in (
    "reuse_check_complete",
    "data_model_post_complete",
    "data_model_readback_complete",
    "workbook_post_complete",
    "workbook_readback_complete",
    "post_complete",
    "warehouse_verification_complete",
    "source_visual_comparison_complete",
    "parity_complete",
    "render_complete",
    "success_stamped",
):
    assert state[key] is False, key

gap = json.loads((root / "gap-report.json").read_text())
assert gap["summary"]["objects"] > 0
assert gap["summary"]["gaps"] > 0
assert gap["security"]["status"] == "review-required"
PY

cmp "$TMP/data-model.json" "$CASE_DIR/golden/data-model.json"
cmp "$TMP/workbook.json" "$CASE_DIR/golden/workbook.json"
cmp "$TMP/gap-report.json" "$CASE_DIR/golden/gap-report.json"
echo "Spotfire authoritative-manifest conversion, lints, dry-run gates, and goldens match"
