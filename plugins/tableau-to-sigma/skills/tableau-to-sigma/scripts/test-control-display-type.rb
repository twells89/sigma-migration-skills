#!/usr/bin/env ruby
# Regression test for E1 (gap beads-sigma-ubr5.17): dropdown vs segmented control
# style. Tableau surfaces a quick-filter/parameter display mode on the zone `mode`
# attr, which parse-twb-layout emits as `control_display` ('compact' → dropdown,
# 'type_in' → text, absent → default button/radio). Before this fix the builder
# hardcoded every list-domain parameter control to `segmented`.
#
# Exercises the two pure build-layer helpers directly (no live POST, no --tab):
#   - control_display_for(layout, cap, norm): finds a control's display mode by
#     caption across the dashboards' flat zones (filter/parameter kinds only)
#   - sigma_control_type(disp): maps a Tableau display mode → Sigma controlType
#
# Usage:  ruby scripts/test-control-display-type.rb
require 'json'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb'))

# Pull the pure helpers out of the script (which otherwise runs main).
%w[control_display_for sigma_control_type].each do |fn|
  m = SRC.match(/^def #{fn}\b.*?\n^end$/m) or abort("could not extract #{fn} from build-charts-from-signals.rb")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

# Mirrors norm_cap in build-charts-from-signals.rb (L3757).
NORM = ->(s) { s.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '') }

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- 1. sigma_control_type mapping -----------------------------------------
check(sigma_control_type('compact') == 'list',      "compact → list (dropdown)", fails)
check(sigma_control_type('type_in') == 'text',      "type_in → text", fails)
check(sigma_control_type(nil)       == 'segmented', "no explicit mode → segmented (default preserved)", fails)
check(sigma_control_type('radio')   == 'segmented', "unknown/radio → segmented", fails)

# ---- 2. control_display_for lookup (mirrors the benchmark's controls) -------
LAYOUT = [{
  'dashboard' => 'Job Losses',
  'zones' => [
    { 'kind' => 'parameter', 'filter_column_caption' => 'Job Loss Metric', 'control_display' => 'compact' },
    { 'kind' => 'parameter', 'filter_column_caption' => 'Immigrant / U.S.-born' }, # no mode → nil → segmented
    { 'kind' => 'filter',    'filter_column_caption' => 'Highlight State', 'control_display' => 'type_in' },
    { 'kind' => 'chart',     'filter_column_caption' => 'Region Chart', 'control_display' => 'compact' } # wrong kind: ignored
  ]
}]

check(control_display_for(LAYOUT, 'Job Loss Metric', NORM) == 'compact',
      "finds 'compact' for the Metric dropdown", fails)
check(control_display_for(LAYOUT, 'Immigrant / U.S.-born', NORM).nil?,
      "returns nil when a control has no explicit mode (→ segmented)", fails)
check(control_display_for(LAYOUT, 'Highlight State', NORM) == 'type_in',
      "finds 'type_in' on a filter zone", fails)
check(control_display_for(LAYOUT, 'JOB   loss  metric!', NORM) == 'compact',
      "caption match is normalized (case/space/punct-insensitive)", fails)
check(control_display_for(LAYOUT, 'Region Chart', NORM).nil?,
      "ignores non-filter/parameter zones (a chart zone's stray mode)", fails)
check(control_display_for(LAYOUT, 'Nonexistent', NORM).nil?,
      "returns nil for an unknown caption", fails)

# ---- 3. end-to-end mapping for the benchmark's 5 controls ------------------
# Metric/Labels/Median are compact dropdowns → list; share/rank have no mode → segmented.
mapped = {
  'Job Loss Metric'       => sigma_control_type(control_display_for(LAYOUT, 'Job Loss Metric', NORM)),
  'Immigrant / U.S.-born' => sigma_control_type(control_display_for(LAYOUT, 'Immigrant / U.S.-born', NORM))
}
check(mapped['Job Loss Metric'] == 'list',       "Metric picker → list (matches oracle)", fails)
check(mapped['Immigrant / U.S.-born'] == 'segmented', "share toggle → segmented (matches oracle)", fails)

puts
if fails.empty?
  puts 'ALL PASS — E1 control display type (dropdown vs segmented)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
