#!/usr/bin/env bash
set -euo pipefail
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$CASE_DIR/evidence.json" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
assert e["pipeline_reuse"]["pipeline_elements_copied"] >= 1
assert e["pipeline_reuse"]["page_masters_patched"] == 3
assert e["pipeline_reuse"]["hidden_pages_preserved"] is True
assert e["coverage"]["source_visuals"] == e["coverage"]["built_visuals"] == 13
assert e["coverage"]["clean_columns"] == 139
assert e["coverage"]["dropped"] == 0
assert e["release"]["promotion_ready"] is False
assert e["release"]["contains_no_data_tiles"] is True
assert "no-data-displayed-tile" in e["release"]["blocking_classes"]
PY
echo "PASS: FP&A pipeline reuse evidence remains explicitly WIP"
