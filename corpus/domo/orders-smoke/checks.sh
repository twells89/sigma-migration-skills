#!/usr/bin/env bash
set -euo pipefail

CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SKILL="$REPO_ROOT/plugins/domo-to-sigma/skills/domo-to-sigma"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$CASE_DIR"/fixtures/{datasets,cards,formulas,beast-modes,dataset-map}.json "$TMP/"

DOMO_DISCOVERY_DIR="$TMP" \
SIGMA_SKIP_DOCTOR_GATE="corpus: environment not under test" \
SIGMA_SKIP_COLUMN_PREFLIGHT="corpus: warehouse not live" \
SIGMA_FOLDER_ID="00000000-0000-0000-0000-000000000000" \
  ruby "$SKILL/scripts/build-dm.rb" >/dev/null

DOMO_DISCOVERY_DIR="$TMP" \
  ruby "$SKILL/scripts/assert-beast-modes-accounted.rb" --discovery "$TMP" \
    --stage data-model >/dev/null

DOMO_DISCOVERY_DIR="$TMP" ruby "$SKILL/scripts/build-workbook.rb" >/dev/null
DOMO_DISCOVERY_DIR="$TMP" \
  ruby "$SKILL/scripts/assert-beast-modes-accounted.rb" --discovery "$TMP" \
    --stage workbook >/dev/null

ruby -rjson -e '
  dir = ARGV[0]
  dm = JSON.parse(File.read(File.join(dir, "dm-spec.json")))
  elements = dm.fetch("pages").flat_map { |page| page.fetch("elements") }
  order_fact = elements.find { |element| element["_datasetId"] == "ds-order-fact" }
  abort "projection Beast Mode missing" unless
    order_fact.fetch("columns").any? { |column| column["name"] == "Order Year" }
  metric = order_fact.fetch("metrics").find { |item| item["name"] == "Total Sales Beast Mode" }
  abort "aggregate Beast Mode metric missing" unless
    metric && metric["formula"] == "Sum([Sales Amount])"

  accounting = JSON.parse(File.read(File.join(dir, "beast-mode-accounting.json")))
  abort "accounting counts wrong: #{accounting.inspect}" unless
    accounting["sourceBeastModes"] == 6 &&
    accounting["sourceDatasetBeastModes"] == 4 &&
    accounting["sourceCardBeastModes"] == 2 &&
    accounting["emitted"] == 3 && accounting["deferred"] == 2 &&
    accounting["notUsed"] == 1 && accounting["blocked"] == 0

  chart_specs = JSON.parse(File.read(File.join(dir, "chart-specs.json")))
  elements = chart_specs.fetch("pages").flat_map { |page| page.fetch("elements") }
  kpi = elements.find { |element| element["id"] == "el-card-total-sales" }
  filter = Array(kpi && kpi["filters"]).find { |item| item["mode"] == "exclude" }
  abort "numeric exclude filter missing" unless filter
  abort "numeric exclude stayed a string: #{filter.inspect}" unless filter["values"] == [-3]
  regional = elements.find { |element| element["id"] == "el-card-region-label" }
  label = Array(regional && regional["columns"]).find { |column| column["name"] == "Region Label" }
  abort "card-local projection not inlined" unless
    label && label["formula"] == "[Master/Region] & \" Region\""

  audit = JSON.parse(File.read(File.join(dir, "filter-type-audit.json")))
  typed = audit.fetch("filters").find { |entry| entry["column"] == "technical_error_type" }
  abort "filter audit missing LONG evidence: #{audit.inspect}" unless
    typed && typed["sourceType"] == "LONG" && typed["outputTypes"] == ["Integer"]
' "$TMP"

echo "Domo Beast Mode promotion and numeric-filter typing: PASS"
