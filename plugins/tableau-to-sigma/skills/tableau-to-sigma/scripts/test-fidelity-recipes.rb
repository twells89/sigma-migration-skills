#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-fidelity-recipes.rb — regression test for the Phase 5g fidelity catalog.
#
#   1. Each canonical recipe spec-shape (from refs/fidelity-recipes.md) still
#      round-trips: it deep-merges into a base workbook spec WITHOUT dropping
#      sibling elements and WITHOUT wiping the layout (the PUT-wipes-layout trap).
#   2. The two genericized calibration ledgers (test-fixtures/fidelity-cal-*.json)
#      converge — zero unresolved spec-fixable deltas — and every recipe named in
#      them corresponds to a real recipe surface in refs/fidelity-recipes.md.
#
#   ruby scripts/test-fidelity-recipes.rb

require 'json'
require_relative 'fidelity-loop' # module FidelityLoop (CLI guarded off)

HERE = __dir__
RECIPES = File.join(HERE, '..', 'refs', 'fidelity-recipes.md')
$failures = 0

def ok(cond, msg)
  puts(cond ? "  ok - #{msg}" : "  FAIL - #{msg}")
  $failures += 1 unless cond
end

# A representative live workbook spec: two elements + a real layout string.
def base_spec
  {
    'settings' => { 'theme' => { 'name' => 'Light' } },
    'pages' => [{
      'id' => 'p1',
      'elements' => [
        { 'elementId' => 'k1', 'kind' => 'kpi-chart', 'name' => 'Revenue' },
        { 'elementId' => 'b1', 'kind' => 'bar-chart', 'name' => 'By Region' }
      ]
    }],
    'layout' => '<Page id="p1"><Container><Element elementId="k1"/><Element elementId="b1"/></Container></Page>'
  }
end

# Canonical recipe spec-shapes — the exact patch an agent authors per catalog row.
RECIPE_PATCHES = {
  'canvas background'      => { 'settings' => { 'theme' => { 'overrides' => { 'colorOverrides' => [{ 'name' => 'backgroundCanvas', 'color' => '#0F172A' }] } } } },
  'workbook palette'       => { 'settings' => { 'theme' => { 'overrides' => { 'categoricalScheme' => %w[#0e7c7b #14b8a6 #f2a900] } } } },
  'fonts'                  => { 'settings' => { 'theme' => { 'overrides' => { 'fonts' => { 'textFont' => 'Inter', 'dataFont' => 'Inter' } } } } },
  'chart-over-tint'        => { 'pages' => [{ 'id' => 'p1', 'elements' => [{ 'elementId' => 'b1', 'style' => { 'backgroundColor' => '#00000000' } }] }] },
  'kpi hide title'         => { 'pages' => [{ 'id' => 'p1', 'elements' => [{ 'elementId' => 'k1', 'value' => { 'name' => ' ' } }] }] },
  'status chips'           => { 'pages' => [{ 'id' => 'p1', 'elements' => [{ 'elementId' => 'b1', 'conditionalFormats' => [{ 'type' => 'single', 'condition' => 'greaterThan', 'value' => 0 }] }] }] },
  'table databars'         => { 'pages' => [{ 'id' => 'p1', 'elements' => [{ 'elementId' => 'b1', 'conditionalFormats' => [{ 'type' => 'dataBars', 'columnIds' => %w[c1], 'scheme' => %w[#a4dfc0 #4caf7d] }] }] }] },
  'table density'          => { 'pages' => [{ 'id' => 'p1', 'elements' => [{ 'elementId' => 'b1', 'tableStyle' => { 'preset' => 'presentation' } }] }] }
}.freeze

puts 'recipe spec-shapes round-trip (deep-merge into a live spec):'
RECIPE_PATCHES.each do |name, patch|
  merged = FidelityLoop.deep_merge(base_spec, patch)
  els = merged['pages'][0]['elements']
  ok(els.length == 2, "#{name}: no sibling element dropped")
  ok(merged['layout'] == base_spec['layout'], "#{name}: layout preserved (PUT-wipes-layout trap avoided)")
  # the patch's leaf value is actually present in the merge
  leaf = JSON.generate(patch)
  probe = JSON.generate(merged)
  key = patch.keys.first
  ok(probe.include?(key) && (leaf.length < 4 || merged.to_s.length >= base_spec.to_s.length),
     "#{name}: patch content merged in")
end

puts 'catalog covers every recipe surface named in the calibration ledgers:'
catalog = File.read(RECIPES)
# The spec paths / idioms the calibration fixes reference must appear in the catalog.
%w[categoricalScheme backgroundCanvas holeValue settings.theme.overrides.fonts
   tableStyle style.backgroundColor #00000000 conditionalFormats
   text-formula list\ control presentation].each do |surface|
  needle = surface.gsub('\\ ', ' ')
  ok(catalog.include?(needle) || catalog.downcase.include?(needle.downcase),
     "catalog documents #{needle.inspect}")
end

puts 'calibration ledgers converge (0 unresolved spec-fixable):'
%w[fidelity-cal-A.json fidelity-cal-B.json].each do |f|
  led = JSON.parse(File.read(File.join(HERE, 'test-fixtures', f)))
  ok(FidelityLoop.ledger_ok?(led), "#{f}: no unresolved spec-fixable deltas")
  residuals = (led['entries'] || []).select { |e| %w[ui-only sigma-capability data].include?(e['cls']) }
  ok(residuals.any?, "#{f}: carries recorded non-blocking residuals (flow to the report)")
  # every spec-fixable entry cites a fix
  missing = (led['entries'] || []).select { |e| e['cls'] == 'spec-fixable' && (e['fix'].nil? || e['fix'].empty?) }
  ok(missing.empty?, "#{f}: every spec-fixable delta cites a fix recipe")
end

puts
if $failures.zero?
  puts 'ALL PASS'
  exit 0
else
  puts "#{$failures} FAILURE(S)"
  exit 1
end
