#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
COMPILER="$REPO_ROOT/plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/compile-tableau-offline.rb"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tableau-compiler-corpus.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ruby "$COMPILER" \
  --case-dir "$CASE_DIR" \
  --workdir "$TMP/run-a" \
  --out "$TMP/workbook-a.json" \
  --compare "$CASE_DIR/golden/workbook.json"

ruby "$COMPILER" \
  --case-dir "$CASE_DIR" \
  --workdir "$TMP/run-b" \
  --out "$TMP/workbook-b.json"

cmp "$TMP/workbook-a.json" "$TMP/workbook-b.json"
cmp "$TMP/run-a/workbook-ir.json" "$TMP/run-b/workbook-ir.json"
cmp "$TMP/run-a/workbook-compile-plan.json" "$TMP/run-b/workbook-compile-plan.json"

python3 "$CASE_DIR/check_workbook.py" "$CASE_DIR" "$TMP/workbook-a.json" "$TMP/run-a"

echo "PASS: partner crosstab end-to-end compiler golden is byte deterministic"
