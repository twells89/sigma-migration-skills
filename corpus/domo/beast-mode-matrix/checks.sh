#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/domo-to-sigma/skills/domo-to-sigma"
TMP="$(mktemp -d)"
BLOCKED="$(mktemp -d)"
trap 'rm -rf "$TMP" "$BLOCKED"' EXIT

cp "$CASE_DIR"/fixtures/{datasets,cards,beast-modes,dataset-map}.json "$TMP/"

DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" >/dev/null
DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" --convert >/dev/null
DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/convert-beast-modes.rb" --lint >/dev/null
SIGMA_SKIP_DOCTOR_GATE='creds-free corpus fixture' \
  SIGMA_SKIP_COLUMN_PREFLIGHT='synthetic warehouse mapping' \
  DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/build-dm.rb" >/dev/null
DOMO_DISCOVERY_DIR="$TMP" DOMO_RUN_DIR="$TMP" ruby "$SKILL/scripts/build-workbook.rb" >/dev/null

ruby -rjson -e '
  dir = ARGV[0]
  formulas = JSON.parse(File.read(File.join(dir, "formulas.json")))
  abort "expected 40 source-valid formulas, got #{formulas.length}" unless formulas.length == 40
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
    "Date Curdate Case" => "If([Inquiry Date] > Today(), \"Yes\", \"No\")",
    "Comment Block Case" => "If([Inquiry Date] > Today(), \"Yes\", \"No\")",
    "Comment Dash Case" => "If([Inquiry Date] > Today(), \"Yes\", \"No\")",
    "Area Code Substring" => "If(Len([Phone Number]) < 10, \"\", If(Contains([Phone Number], \"@\"), \"\", If(Left([Phone Number], 1) = \"1\", Mid([Phone Number], 2, 3), Left([Phone Number], 3))))",
    "Month Split Curdate" => "If(Day([Current Date]) < Day(Today()), Concat(\"Days 1-\", Text((Day(Today()) - 1))), Concat(\"Days \", Text(Day(Today())), \"-EOM\"))",
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
  %w[Comment\ Block\ Case Comment\ Dash\ Case].each do |name|
    abort "#{name}: comment removal was not recorded" unless
      Array(by_name.dig(name, "preWarnings")).any? { |warning| warning.include?("Removed 1 MySQL comment") }
  end
  dm = JSON.parse(File.read(File.join(dir, "dm-spec.json")))
  dm_columns = dm.fetch("pages").flat_map { |page| page.fetch("elements") }
    .flat_map { |element| element.fetch("columns", []) }
    .to_h { |column| [column["name"], column["formula"]] }
  %w[Date\ Curdate\ Case Comment\ Block\ Case Comment\ Dash\ Case].each do |name|
    abort "#{name} did not become a DM calculated column using Today()" unless
      dm_columns[name] == "If([Inquiry Date] > Today(), \"Yes\", \"No\")"
  end
  abort "SUBSTRING did not become a DM calculated column using Mid()" unless
    dm_columns["Area Code Substring"] == expected["Area Code Substring"]
  abort "CURDATE/CONCAT numeric arguments did not receive valid Sigma mappings" unless
    dm_columns["Month Split Curdate"] == expected["Month Split Curdate"]

  specs = JSON.parse(File.read(File.join(dir, "chart-specs.json")))
  visible = specs.fetch("pages").flat_map { |page| page.fetch("elements") }
  helpers = specs.fetch("data_elements")
  abort "expected all 36 source cards, got #{visible.length}" unless visible.length == 36
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
