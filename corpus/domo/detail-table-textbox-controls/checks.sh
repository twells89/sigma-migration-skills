#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/domo-to-sigma/skills/domo-to-sigma"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$CASE_DIR"/fixtures/{datasets,cards,beast-modes,kpi-overrides}.json "$TMP/"

DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" >/dev/null
DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" --convert >/dev/null
DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" --lint >/dev/null
DOMO_DISCOVERY_DIR="$TMP" DOMO_RUN_DIR="$TMP" ruby "$SKILL/scripts/build-workbook.rb" >/dev/null
DOMO_DISCOVERY_DIR="$TMP" DOMO_RUN_DIR="$TMP" \
  ruby "$SKILL/scripts/qa-check.rb" --in "$TMP/chart-specs.json" >/dev/null

ruby -rjson -e '
  dir = ARGV[0]
  specs = JSON.parse(File.read(File.join(dir, "chart-specs.json")))
  elements = specs.fetch("pages").flat_map { |page| page.fetch("elements") }

  detail = elements.find { |element| element["id"] == "el-detail-card" }
  abort "detail table missing" unless detail && detail["kind"] == "table"
  abort "detail table unexpectedly grouped" if detail.key?("groupings")
  invalid = detail.fetch("columns").select do |column|
    column["name"].to_s.match?(/During Business Hours|Call Start Time|Call Intent|ANI/) &&
      column["formula"].to_s.start_with?("Sum(")
  end
  abort "detail text/date columns aggregated: #{invalid.inspect}" unless invalid.empty?

  refresh = elements.find { |element| element["id"] == "el-refresh-card" }
  abort "Last Refresh textbox did not become KPI" unless
    refresh && refresh["kind"] == "kpi-chart" &&
    refresh.dig("columns", 0, "formula") == "Max([Master/Call Date])"

  chart = elements.find { |element| element["id"] == "el-quick-chart" }
  helper = specs.fetch("data_elements").find {
    |element| element["id"] == "src-el-quick-chart-filters"
  }
  abort "chart Quick Filter helper missing" unless
    chart && helper && chart.dig("source", "elementId") == helper["id"]

  coverage = JSON.parse(File.read(File.join(dir, "domo-controls-coverage.json")))
  abort "chart Quick Filter not emitted: #{coverage.inspect}" unless
    coverage["expected"] == 1 && coverage["emitted"] == 1
  warnings = JSON.parse(File.read(File.join(dir, "warnings.json")))
  fatal = warnings.select {
    |warning| warning["warning"].to_s.match?(/SKIPPED|unknown chartType|Quick Filter.*deferred/)
  }
  abort "unexpected card loss: #{fatal.inspect}" unless fatal.empty?
' "$TMP"

echo "Domo detail table, textbox, and chart Quick Filter: PASS"
