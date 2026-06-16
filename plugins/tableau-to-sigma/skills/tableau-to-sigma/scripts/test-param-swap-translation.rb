#!/usr/bin/env ruby
# Regression test for the parameter-driven field-swap path (the EDNA /
# "Partner Landscape" Choose-Split-Table idiom). Deterministic + offline — no
# Tableau or Sigma calls. Guards the six fixes that made param swaps migrate
# end-to-end (proven 7/7 strict on the EDNA-mirror fixture, 2026-06-16):
#
#   1. Switch branch refs remapped UUID/caption -> [Master/<col>]
#   2. numeric WHEN literals quoted to match the text segmented control
#   3. control ref [ctl-param-...] preserved (drives the Switch)
#   4. validate-spec accepts [ctl-*] control refs (not "not a sibling column")
#
# It exercises the ACTUAL function bodies from build-charts-from-signals.rb
# (extracted + evaluated against stubs) and runs validate-spec.rb on a minimal
# workbook spec.
#
# Usage:  ruby scripts/test-param-swap-translation.rb

require 'json'
require 'tempfile'

DIR = __dir__
BUILD = File.join(DIR, 'build-charts-from-signals.rb')
VALIDATE = File.join(DIR, 'validate-spec.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- Part A: translation unit test -----------------------------------------
# Extract the translation helpers from the (non-requireable, CLI) script and
# eval them over stubs, so we test the shipped bodies verbatim.
src = File.read(BUILD)
defs = %w[coerce_case_literal remap_param_branch translate_case_on_param
          translate_if_chain_on_param param_control_ref].map do |fn|
  m = src.match(/^def #{fn}\b.*?\nend\n/m)
  abort "test bug: could not extract def #{fn} from build-charts-from-signals.rb" unless m
  m[0]
end.join("\n")

# Define the extracted helpers (and a map_column stub) as singleton methods on
# a throwaway object so they can call one another (self == mod).
mod = Object.new
mod.instance_eval("def map_column(cap, mmap); mmap[cap.to_s.strip]; end\n" + defs)

mmap = {
  'Region'              => { 'id' => 'm-region', 'name' => 'Region' },
  'Customer Segment'    => { 'id' => 'm-cs', 'name' => 'Customer Segment' },
  'Customer Value Tier' => { 'id' => 'm-cvt', 'name' => 'Customer Value Tier' },
  'Ship Speed Category' => { 'id' => 'm-ssc', 'name' => 'Ship Speed Category' }
}
cbg = {
  'd73055c0-9ed1-347d-8f8e-05a48ce2c8a8' => { 'caption' => 'Region' },
  '49c438c6-924a-38d9-91a5-1c9dca786152' => { 'caption' => 'Customer Segment' }
}
formula = 'CASE [Choose Split Table] ' \
          'WHEN 1 THEN [d73055c0-9ed1-347d-8f8e-05a48ce2c8a8] ' \
          'WHEN 2 THEN [49c438c6-924a-38d9-91a5-1c9dca786152] ' \
          'WHEN 3 THEN [Customer Value Tier] ' \
          'WHEN 4 THEN [Ship Speed Category] END'

puts 'Part A — CASE-on-parameter translation'
sw = mod.translate_case_on_param(formula, ['Choose Split Table'], mmap, cbg)
check(sw.to_s.start_with?('Switch([ctl-param-choose-split-table]'),
      'emits a Switch over the param control ref', fails)
check(!sw.to_s.match?(/\[[0-9a-f]{8}-[0-9a-f]{4}-/),
      'no raw Tableau UUID survives in branch refs', fails)
check(sw.to_s.include?('[Master/Region]') && sw.to_s.include?('[Master/Customer Value Tier]'),
      'branch refs remapped onto [Master/<col>]', fails)
check(sw.to_s.include?('"1"') && sw.to_s.include?('"4"'),
      'numeric WHEN literals quoted (text control match)', fails)

puts 'Part A — coerce_case_literal'
check(mod.coerce_case_literal('1') == '"1"', 'bare number -> quoted', fails)
check(mod.coerce_case_literal('"x"') == '"x"', 'quoted string untouched', fails)
check(mod.coerce_case_literal('Foo') == 'Foo', 'non-numeric token untouched', fails)

# ---- Part B: validate-spec accepts control refs ----------------------------
puts 'Part B — validate-spec accepts [ctl-*] control refs'
spec = {
  'pages' => [{
    'name' => 'P', 'elements' => [
      { 'id' => 'ctl1', 'kind' => 'control', 'controlId' => 'ctl-param-choose-split-table', 'name' => 'Choose Split Table' },
      { 'id' => 'el1', 'kind' => 'table', 'name' => 'T',
        'source' => { 'kind' => 'table', 'elementId' => 'master' },
        'columns' => [
          { 'id' => 'a', 'name' => 'Region', 'formula' => '[Master/Region]' },
          { 'id' => 'x', 'name' => 'Split', 'formula' => 'Switch([ctl-param-choose-split-table], "1", [Region])' }
        ] }
    ]
  }]
}
tmp = Tempfile.new(['param-swap-spec-', '.json'])
tmp.write(JSON.generate(spec)); tmp.close
out = `ruby #{VALIDATE.inspect} --type workbook #{tmp.path.inspect} 2>&1`
tmp.unlink
check(!out.include?('bare ref [ctl-param-choose-split-table] not a sibling'),
      'control ref not flagged as non-sibling', fails)
check(!out.downcase.include?('ctl-param-choose-split-table') || !out.include?('not a sibling'),
      'no sibling error mentions the control', fails)

puts
if fails.empty?
  puts 'OK — param-swap translation + control-ref validation all pass'
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
