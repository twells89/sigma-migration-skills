#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/domo-to-sigma/skills/domo-to-sigma"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$CASE_DIR"/fixtures/{datasets,cards,beast-modes}.json "$TMP/"
DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" >/dev/null
DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" --convert >/dev/null
DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" --lint >/dev/null
DOMO_DISCOVERY_DIR="$TMP" DOMO_RUN_DIR="$TMP" ruby "$SKILL/scripts/build-workbook.rb" >/dev/null

ruby -rjson -e '
  specs = JSON.parse(File.read(File.join(ARGV[0], "chart-specs.json")))
  table = specs.fetch("pages").flat_map { |page| page.fetch("elements") }
    .find { |element| element["id"] == "el-rent-now-performance" }
  abort "summary table missing" unless table && table["kind"] == "table"
  by_name = table.fetch("columns").to_h { |column| [column["name"], column] }
  abort "Button Click was aggregated" unless by_name.dig("Button Click", "formula") == "[Master/Button Click]"
  abort "Waiting Discount was aggregated" unless
    by_name.dig("Waiting Discount", "formula") == "[Master/Waiting Discount]"
  abort "explicit SUM was lost" unless
    by_name.dig("Total Web Inquiries", "formula") == "Sum([Master/Total Web Inquiries])"
  abort "aggregate Beast Mode was not preserved" unless
    by_name.dig("Rental Rate", "formula") ==
      "(1.0 * Sum([Master/Completed Rentals])) / Sum([Master/Total Web Inquiries])"
  grouping = table.fetch("groupings").first
  abort "implicit dimensions missing from groupBy" unless
    grouping.fetch("groupBy").sort == %w[d-button-click d-waiting-discount]
  abort "measures missing from calculations" unless
    grouping.fetch("calculations").sort == %w[m-rental-rate m-total-web-inquiries]
' "$TMP"

echo "Domo mixed summary table: PASS"
