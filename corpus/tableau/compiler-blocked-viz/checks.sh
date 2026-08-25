#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
COMPILER="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/compile-workbook-ir.rb"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tableau-blocked-viz.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

set +e
ruby "$COMPILER" --ir "$CASE_DIR/workbook-ir.json" --out "$TMP/plan.json" --strict \
  >"$TMP/out.log" 2>&1
code=$?
set -e

test "$code" -eq 2
python3 - "$TMP/plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
assert plan["summary"]["blocking"] == 1
assert plan["blocking"][0]["rule"] == "viz.unknown.v1"
PY
echo "PASS: unsupported viz fails before writes"
