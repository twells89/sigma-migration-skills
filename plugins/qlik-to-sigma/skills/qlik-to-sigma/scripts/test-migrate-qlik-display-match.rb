#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline regression for display_match? (migrate-qlik.rb's Qlik-display-vs-
# warehouse-number tolerance check, used by the Phase-6 per-KPI parity
# compare: does a Qlik-rendered display string like "$529.2M" round to the
# warehouse's raw number at the precision/unit Qlik printed?).
#
# migrate-qlik.rb is the monolithic single-process orchestrator: it parses
# ARGV and `abort`s immediately when --app/--from-discovery/--unbuild/--prj
# and --connection are missing (source ~lines 122-223) — all BEFORE
# display_match? is even defined (~line 271) — so it cannot be `require`d or
# `load`ed directly the way test-migrate-qlik-coderep-unwrap.rb's source-text
# assertions sidestep running it. Instead this extracts the two self-
# contained pieces display_match? depends on (the QLIK_SCALE constant and the
# method body) straight out of the source text and `eval`s ONLY those —
# never the surrounding CLI/orchestration.
#
# Usage: ruby scripts/test-migrate-qlik-display-match.rb
#   (run under LC_ALL=en_US.UTF-8 per this skill's ruby-hook-locale convention)

src = File.read(File.join(__dir__, 'migrate-qlik.rb'))

scale_src  = src[/^QLIK_SCALE\s*=.*$/]
method_src = src[/^def display_match\?.*?^end$/m]

abort 'FATAL: QLIK_SCALE not found in migrate-qlik.rb (source shape changed)' unless scale_src
abort 'FATAL: display_match? not found in migrate-qlik.rb (source shape changed)' unless method_src

eval(scale_src)   # rubocop:disable Security/Eval -- extracted constant, not user input
eval(method_src)  # rubocop:disable Security/Eval -- extracted method body, not user input

fails = []
def check(actual, expected, label, fails)
  ok = actual == expected
  puts "  #{ok ? 'PASS' : 'FAIL'}  #{label} => #{actual.inspect} (expected #{expected.inspect})"
  fails << label unless ok
end

CASES = [
  ['$529.2M', 529_247_958.49, true],
  ['$837.0', 837.00313, true],
  ['$529.3M', 529_247_958.49, false],
  ['632313', 632_313, true],
  ['$1.2B', 1_249_000_000, true],
  ['abc', 1, false],
  [nil, 1, false],
].freeze

CASES.each do |shown, number, expected|
  check(display_match?(shown, number), expected, "display_match?(#{shown.inspect}, #{number.inspect})", fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
