#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/domo-to-sigma/skills/domo-to-sigma"
TMP="$(mktemp -d)"
BLOCKED="$(mktemp -d)"
trap 'rm -rf "$TMP" "$BLOCKED"' EXIT

cp "$CASE_DIR"/fixtures/{datasets,cards,beast-modes}.json "$TMP/"

DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" >/dev/null
DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" --convert >/dev/null
DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" --lint >/dev/null
DOMO_DISCOVERY_DIR="$TMP" DOMO_RUN_DIR="$TMP" ruby "$SKILL/scripts/build-workbook.rb" >/dev/null

ruby -rjson -e '
  dir = ARGV[0]
  formulas = JSON.parse(File.read(File.join(dir, "formulas.json")))
  abort "expected 35 source-valid formulas, got #{formulas.length}" unless formulas.length == 35
  blocked = formulas.reject { |formula| formula["converted"] != false }
  abort "source-valid formula blocked: #{blocked.map { |formula| formula["name"] }.inspect}" unless blocked.empty?
  by_name = formulas.to_h { |formula| [formula["name"], formula] }
  expected = {
    "Window Running Sum" => "CumulativeSum(Sum([Sales]))",
    "Window Rank" => "Rank(Sum([Sales]), \"desc\")",
    "Window Lag" => "Lag(Sum([Sales]), 1)",
    "Window Lead" => "Lead(Sum([Sales]), 1)",
    "Window Ntile" => "Ntile(4, Sum([Sales]), \"asc\")",
    "Logic Like Contains" => "If(Contains([Text_Value], \"alpha\"), \"Match\", \"Other\")",
    "Logic Between" => "If(([Value] >= 10 and [Value] <= 20), \"Mid\", \"Other\")",
    "Date Format" => "DateFormat([Date], \"%Y-%m\")",
    "Date Str To Date" => "DateParse([Date_Text], \"%m/%d/%Y\")",
    "Date Last Day" => "LastDay([Date], \"month\")",
    "Date Monthname" => "MonthName([Date])",
    "Date Weekday Legacy" => "Weekday([Date])",
    "Aggregate Approx Count Distinct" => "CountDistinct([Employee_ID])",
    "Unsupported Sqrt" => "Power([Value], 0.5)",
    "Unsupported Convert Tz" => "ConvertTimezone([Date], \"America/Denver\", \"UTC\")",
  }
  expected.each do |name, formula|
    actual = by_name.dig(name, "sigmaFormula")
    abort "#{name}: expected #{formula.inspect}, got #{actual.inspect}" unless actual == formula
  end
  abort "SUM DISTINCT helper placement missing" unless
    by_name.dig("Aggregate Sum Distinct", "semanticPlacement", "kind") == "sum-distinct"

  specs = JSON.parse(File.read(File.join(dir, "chart-specs.json")))
  visible = specs.fetch("pages").flat_map { |page| page.fetch("elements") }
  helpers = specs.fetch("data_elements")
  abort "expected all 35 source cards, got #{visible.length}" unless visible.length == 35
  abort "expected 7 grouped helpers, got #{helpers.length}" unless helpers.length == 7
  distinct = visible.find { |element| element["name"].to_s.include?("Aggregate Sum Distinct") }
  abort "SUM DISTINCT visible formula wrong" unless
    distinct && distinct.fetch("columns").last["formula"].include?("Distinct values for")
  %w[
    Fixed\ Total
    Fixed\ By\ Region
    Fixed\ Multi\ By
    Fixed\ Add\ City
    Fixed\ Remove\ Category
    Fixed\ Filter\ None
    Fixed\ Filter\ Allow
    Fixed\ Filter\ Deny
    Fixed\ Percent\ Total
  ].each do |name|
    abort "missing FIXED card #{name}" unless visible.any? { |element| element["name"].to_s.end_with?(name) }
  end
  warnings = JSON.parse(File.read(File.join(dir, "warnings.json")))
  fatal = warnings.select { |warning| warning["warning"].to_s.match?(/dropped column|SKIPPED/) }
  abort "unexpected dropped Beast Mode cards: #{fatal.inspect}" unless fatal.empty?
' "$TMP"

cp "$CASE_DIR/fixtures/blocked-beast-modes.json" "$BLOCKED/beast-modes.json"
DOMO_DISCOVERY_DIR="$BLOCKED" ruby "$SKILL/scripts/convert-beast-modes.rb" >/dev/null
DOMO_DISCOVERY_DIR="$BLOCKED" ruby "$SKILL/scripts/convert-beast-modes.rb" --convert >/dev/null
DOMO_DISCOVERY_DIR="$BLOCKED" ruby "$SKILL/scripts/convert-beast-modes.rb" --lint >/dev/null
ruby -rjson -e '
  formulas = JSON.parse(File.read(File.join(ARGV[0], "formulas.json")))
  abort "expected two source-invalid formulas" unless formulas.length == 2
  abort "source-invalid formula did not fail closed" unless formulas.all? {
    |formula| formula["converted"] == false && formula["_source"] == "domo-semantic-block"
  }
' "$BLOCKED"

echo "Domo Beast Mode acceptance matrix: PASS"
