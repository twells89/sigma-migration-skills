#!/usr/bin/env bash
set -euo pipefail
CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 - "$CASE_DIR/evidence.json" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
assert e["compiler"]["blocking"] == 0
assert e["compiler"]["reconcile"] == "PASS"
assert e["coverage"]["source_visuals"] == e["coverage"]["built_visuals"] == 9
assert e["coverage"]["dropped"] == 0
assert e["parity"]["charts_pass"] == e["parity"]["charts_total"] == 9
assert e["parity"]["value_parity_score"] == 1.0
assert e["parity"]["tiles_all_nonempty"] is True
assert e["anchors"]["checked"] == e["anchors"]["matched"] == 9
assert e["visual"]["pass"] is True and e["visual"]["score_overall"] >= 0.7349
PY
echo "PASS: Orders Executive compiler live-evidence floor"
