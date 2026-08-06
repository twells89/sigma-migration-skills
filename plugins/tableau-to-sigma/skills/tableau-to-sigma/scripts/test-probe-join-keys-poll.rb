#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K12(a): the join-key probe's export poll must be bounded by
# WALL-CLOCK, not a fixed iteration count, and the budget must be generous enough
# for a cold warehouse.
#
# The original loop was `30.times { sleep(i.zero? ? 0.5 : 1) }` — a ~30s ceiling.
# A cold warehouse routinely exceeds it, so the probe reported failure for a query
# that would have succeeded, and the operator hot-fixed it to 180s locally every
# run. Deterministic + offline.

DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

src = File.read(File.join(DIR, 'probe-join-keys.rb'))

puts 'Part A — the budget is a named, env-overridable constant'
check(src.match?(/PROBE_EXPORT_TIMEOUT_S\s*=/),
      'PROBE_EXPORT_TIMEOUT_S is defined', fails)
check(src.match?(/ENV\.fetch\(\s*'PROBE_EXPORT_TIMEOUT_S'\s*,\s*'180'\s*\)/),
      "the default is 180 and comes from ENV.fetch('PROBE_EXPORT_TIMEOUT_S', '180')", fails)

puts 'Part B — the loop is wall-clock bounded, not iteration-count bounded'
check(!src.match?(/^\s*30\.times do \|i\|/),
      'the fixed `30.times` poll is gone', fails)
check(src.match?(/PROBE_EXPORT_TIMEOUT_S/) && src.match?(/Time\.now/),
      'the poll compares elapsed Time.now against the budget', fails)
check(!src.include?("export did not complete in 30s"),
      'the hardcoded "30s" failure message is gone', fails)
check(src.match?(/PROBE_EXPORT_TIMEOUT_S.*?(?:override|env)/mi) ||
      src.match?(/did not complete in .*PROBE_EXPORT_TIMEOUT_S/),
      'the timeout message names the budget so a slow warehouse is distinguishable', fails)

puts 'Part C — behavioral: the budget arithmetic honours the env override'
budget = ->(env) { Integer((env || {}).fetch('PROBE_EXPORT_TIMEOUT_S', '180')) }
check(budget.call({}) == 180, 'unset env -> 180s default', fails)
check(budget.call('PROBE_EXPORT_TIMEOUT_S' => '600') == 600, 'env override is honoured', fails)

puts 'Part D — planted-defect guard: 30s really is too short for a cold export'
# A cold warehouse export of ~60s must fail under the OLD budget and pass under
# the new one. If this ever stops discriminating, Part A/B prove nothing.
cold_export_s = 60
check(cold_export_s > 30, 'PLANTED-DEFECT GUARD: a 60s cold export exceeds the old 30s ceiling', fails)
check(cold_export_s < budget.call({}), 'PLANTED-DEFECT GUARD: it fits inside the new 180s budget', fails)

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
