#!/usr/bin/env bash
# orders-presentation — executable expectations (offline, creds-free).
# Run by corpus/run-corpus.sh --check after corpus_check.py passes.
#
# Proves the presentation-override AUTOMATION reproduces the styling decisions
# the gold acceptance run first reached through hand-authored sidecars — the
# gap that made gold non-transferable to other customers. derive-presentation-
# overrides.rb reads only discovery metadata + a Domo card-data snapshot and
# emits the four sidecars build-workbook.rb consumes. This asserts:
#   1. currency KPI  -> compact scale/suffix/prefix + font size
#   2. percent  KPI  -> font size only (never a bogus $ scale)
#   3. chart w/ summary -> source-value header + compact currency axis
#   4. categorical order -> Domo row order, preserved
#   5. KPI cards get NO chart-header override (their value IS the tile)
set -uo pipefail
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$CASE_DIR/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/domo-to-sigma/skills/domo-to-sigma/scripts"

command -v ruby >/dev/null || { echo "checks: ruby not found (required for the derivation check)"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
note() { printf '     %s\n' "$*"; }

mkdir -p "$TMP/discovery"
cp "$CASE_DIR/fixtures/cards.json" "$TMP/discovery/cards.json"
cp "$CASE_DIR/fixtures/parity-expected.json" "$TMP/parity-expected.json"
printf '{}\n' > "$TMP/discovery/layout-observed.json"

ruby "$SCRIPTS/derive-presentation-overrides.rb" --workdir "$TMP" --discovery "$TMP/discovery" --force \
  >"$TMP/derive.out" 2>&1 || { note "FAIL: derive-presentation-overrides.rb exited nonzero"; sed -n '1,20p' "$TMP/derive.out"; exit 1; }

ruby -rjson -e '
  dir = ARGV[0]
  kpi   = JSON.parse(File.read(File.join(dir, "kpi-format-overrides.json")))
  axis  = JSON.parse(File.read(File.join(dir, "chart-axis-overrides.json")))
  order = JSON.parse(File.read(File.join(dir, "category-order-overrides.json")))
  headers = JSON.parse(File.read(File.join(dir, "kpi-card-header-overrides.json")))
  errs = []

  rev = kpi["kpi_rev"] || {}
  errs << "currency KPI missing compact scale" unless rev["scale"] == 1000 && rev["suffix"] == "K" && rev["prefix"] == "$"
  errs << "currency KPI missing font size" unless rev["fontSize"].to_i > 0

  ret = kpi["kpi_ret"] || {}
  errs << "percent KPI must NOT get a currency scale" if ret.key?("scale")
  errs << "percent KPI missing font size" unless ret["fontSize"].to_i > 0

  companion = kpi["bar_channel"] || {}
  errs << "currency companion KPI must preserve the full source value" unless
    companion["scale"] == 1 && companion["suffix"] == "" && companion["prefix"] == "$" &&
    companion["decimals"] == 1

  ax = axis["bar_channel"] || {}
  errs << "currency chart axis not compacted" unless ax["scale"] == 1000 && ax["suffix"] == "K" && ax["prefix"] == "$"
  errs << "percent/count chart wrongly given a currency axis" if axis.key?("kpi_ret") || axis.key?("table_detail")

  errs << "categorical order not preserved from Domo rows" unless order["bar_channel"] == ["In-Store", "Online", "App"]
  errs << "date axis wrongly treated as a category" if order.key?("line_month")
  errs << "table wrongly given a categorical order" if order.key?("table_detail")
  errs << "screenshot-backed KPI header missing dynamic full value" unless
    headers.dig("kpi_rev", "body").to_s.include?("{{Sum([Master/Net Revenue]) | $,.1f}}")

  # Chart card-header sidecars remain operator-authored. Screenshot-backed KPI
  # headers are safe because observed layout nests them with their KPI.
  errs << "card-header-overrides.json must NOT be auto-emitted" if File.exist?(File.join(dir, "card-header-overrides.json"))

  if errs.empty?
    puts "OK"
  else
    errs.each { |e| warn "  - #{e}" }
    exit 1
  end
' "$TMP/discovery" && note "ok: presentation overrides derived correctly (currency/percent KPI, compact axis, category order; layout-safe only)" \
  || { note "FAIL: derived presentation overrides did not match expectations"; fail=1; }

# The manifest records provenance + counts, never silently absent.
ruby -rjson -e '
  m = JSON.parse(File.read(ARGV[0]))
  abort "manifest schema wrong" unless m["schema"] == "domo-presentation-overrides/v1"
  c = m["counts"] || {}
  abort "manifest counts wrong: #{c.inspect}" unless c["cards"] == 5 && c["kpi_formats"] == 5 &&
    c["kpi_headers"] == 2 &&
    c["axis_formats"] == 2 && c["category_orders"] == 1
' "$TMP/discovery/presentation-overrides.json" && note "ok: presentation-overrides.json manifest records provenance + counts" \
  || { note "FAIL: presentation-overrides.json manifest missing/wrong"; fail=1; }

exit "$fail"
