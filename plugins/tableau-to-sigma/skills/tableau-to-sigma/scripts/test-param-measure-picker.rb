#!/usr/bin/env ruby
# Regression test for the parameter measure-picker wiring (n4pi.10): a Tableau
# parameter that selects WHICH measure a tile shows → a Sigma control-driven
# Switch tile measure. Exercises the build-layer helpers directly (no live POST):
#   - load_param_switches: indexes a converter `param-switch` workbookPattern by
#     the calc caption AND its Calculation_<id> (the Calculation_NNN→caption bridge)
#   - param_switch_for:    looks a picker up by either key
#   - param_switch_inline: builds the SIBLING-form Switch, INLINES aggregate-metric
#     branch refs to their formula (not a passthrough column), gracefully NULLs an
#     unresolvable branch (and surfaces it), and SKIPS window-function pickers
#
# Usage:  ruby scripts/test-param-measure-picker.rb
require 'json'
require 'set'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb'))

# Pull the pure helper methods out of the script (which otherwise runs main) and
# define them here. Order doesn't matter — they're resolved at call time.
%w[map_column coerce_case_literal remap_param_branch
   load_param_switches param_switch_for param_switch_inline
   norm_param_caption picker_param_caps_index].each do |fn|
  m = SRC.match(/^def #{fn}\b.*?\n^end$/m) or abort("could not extract #{fn} from build-charts-from-signals.rb")
  eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# master-map: real COLUMNS (no formula) + an aggregate METRIC ("Signs" -> a
# CountDistinct formula) so we can assert metric inlining vs column passthrough.
MMAP = {
  '(?i)^Region$'          => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^Net Revenue$'     => { 'id' => 'm-nr', 'name' => 'NET_REVENUE' },
  '(?i)^Account$'         => { 'id' => 'm-acct', 'name' => 'ACCOUNT_ID' },
  '(?i)^Signs$'           => { 'id' => 'm-signs', 'name' => 'Signs', 'formula' => 'CountDistinct([Master/ACCOUNT_ID])' }
}
CBG = {
  'Calculation_777' => { 'caption' => 'Metric Picker', 'datatype' => 'real' },
  'Parameter 3'     => { 'caption' => 'Metric Param', 'datatype' => 'string' }
}

# ---- 1. clean measure-picker: metric branch inlined, column branch passthrough -
$param_switches = []; $param_switch_by_key = {}; $param_switch_used = []
meta = { 'columns_by_guid' => CBG }
patterns = { 'workbookPatterns' => [
  { 'kind' => 'param-switch', 'name' => 'Metric Picker', 'controlId' => 'ctl-parameter-3',
    'paramName' => 'Parameter 3',
    'cases' => [{ 'when' => 'Revenue', 'then' => 'Sum([Net Revenue])' },
                { 'when' => 'Signs',   'then' => '[Signs]' }],
    'elseExpr' => nil }
] }
require 'tmpdir'
Dir.mktmpdir do |d|
  File.write(File.join(d, 'wp.json'), JSON.dump(patterns))
  load_param_switches(File.join(d, 'wp.json'), meta)
end

check($param_switches.size == 1, 'loaded 1 param-switch', fails)
# Calculation_NNN→caption bridge: found by caption AND by the internal id.
check(!param_switch_for('Metric Picker').nil?, 'param_switch_for resolves by caption', fails)
check(!param_switch_for('Calculation_777').nil?, 'param_switch_for resolves by Calculation_<id> (caption bridge)', fails)
check(param_switch_for('Nope').nil?, 'param_switch_for returns nil for a non-picker', fails)

plan = param_switch_inline($param_switches.first, MMAP, CBG)
f = plan && plan['sibling_form']
check(!plan.nil?, 'param_switch_inline builds a plan', fails)
check(f.to_s.start_with?('Switch([ctl-parameter-3],'), "Switch references the converter controlId (got #{f.inspect})", fails)
check(f.to_s.include?('Sum([NET_REVENUE])'), 'column branch → passthrough sibling form Sum([NET_REVENUE])', fails)
check(f.to_s.include?('CountDistinct([ACCOUNT_ID])'), 'metric branch INLINED to its formula (CountDistinct([ACCOUNT_ID])), not a [Signs] passthrough', fails)
check(!f.to_s.include?('[Signs]'), 'no dangling [Signs] metric passthrough (would not resolve on the master)', fails)
check((plan['branch_refs'] & %w[NET_REVENUE ACCOUNT_ID]).sort == %w[ACCOUNT_ID NET_REVENUE],
      "branch_refs are the real columns to materialise (got #{plan['branch_refs'].inspect})", fails)
check(plan['unresolved'].empty?, 'no unresolved options when every branch resolves', fails)

# ---- 2. graceful NULL for an unresolvable branch (surfaced, not silent) --------
sw2 = { 'name' => 'P2', 'control_id' => 'ctl-parameter-9', 'param_name' => 'Parameter 9',
        'cases' => [{ 'when' => 'Good', 'then' => 'Sum([Net Revenue])' },
                    { 'when' => 'Bad',  'then' => '[Nonexistent Calc]' }], 'else' => nil }
plan2 = param_switch_inline(sw2, MMAP, CBG)
check(plan2 && plan2['sibling_form'].include?('"Bad", Null'), 'unresolvable branch → Null (other options keep working)', fails)
check(plan2 && plan2['unresolved'] == ['Bad'], "unresolved option surfaced (got #{plan2 && plan2['unresolved'].inspect})", fails)

# ---- 3. window-function picker is SKIPPED (can't inline in a Switch) -----------
sw3 = { 'name' => 'P3', 'control_id' => 'ctl-parameter-4', 'param_name' => 'Parameter 4',
        'cases' => [{ 'when' => 'Total', 'then' => '[Signs]' },
                    { 'when' => 'Pct',   'then' => '[Signs]/window_sum([Signs])' }], 'else' => nil }
check(param_switch_inline(sw3, MMAP, CBG).nil?, 'window-function picker → nil (surfaced as a note, never emitted broken)', fails)

# ---- 4. all-branches-unresolvable → nil (nothing to plot) ----------------------
sw4 = { 'name' => 'P4', 'control_id' => 'ctl-parameter-5', 'param_name' => 'Parameter 5',
        'cases' => [{ 'when' => 'X', 'then' => '[Ghost A]' }, { 'when' => 'Y', 'then' => '[Ghost B]' }], 'else' => nil }
check(param_switch_inline(sw4, MMAP, CBG).nil?, 'all branches unresolvable → nil (no empty Switch)', fails)

# ---- 5. picker-param dedup index (jwsf) ----------------------------------------
# The auto-control loop must skip the redundant ctl-param-<caption> control for a
# parameter that already drives a WIRED picker — else the orphan control-scope
# record trips control_lint "missing control". The jwsf failure: param_name WAS
# the caption ("Metric Picker"), so the old columns_by_guid-only lookup returned
# nil and the dedup never fired.
check(norm_param_caption('[Parameters].[Metric Picker]') == 'metric picker', 'norm_param_caption strips [Parameters].[…] wrapping', fails)
check(norm_param_caption('[Metric Picker]') == 'metric picker', 'norm_param_caption strips bare brackets', fails)
sws = [{ 'control_id' => 'ctl-metric-picker', 'param_name' => 'Metric Picker' }]
# jwsf case: param_name is already the caption, columns_by_guid has NO entry for it.
idx = picker_param_caps_index(sws, ['ctl-metric-picker'], {})
check(idx['metric picker'] == true, 'jwsf: dedup matches when param_name IS the caption (columns_by_guid miss)', fails)
# GUID-keyed param_name still resolves via columns_by_guid (legacy path).
idx2 = picker_param_caps_index([{ 'control_id' => 'ctl-x', 'param_name' => 'Parameter 7' }],
                               ['ctl-x'], { 'Parameter 7' => { 'caption' => 'Region Picker' } })
check(idx2['region picker'] == true, 'GUID-keyed param_name resolves caption via columns_by_guid', fails)
# An UN-wired picker must NOT suppress its parameter's control.
idx3 = picker_param_caps_index(sws, [], {})
check(idx3.empty?, 'un-wired picker → no dedup (control still emitted)', fails)

puts
if fails.empty?
  puts 'ALL PASS — param measure-picker: control-driven Switch, metric inlining, graceful null, window skip'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
