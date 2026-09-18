#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-g10-anchor-coverage.rb — G10 regression (run-2 postmortem): all 11
# anchors sat in 3 of 9 displayed tiles, and the anchors ORACLE (the
# charts_total<=0 substitution in assert-phase6-ran) passed while 6 tiles had
# ZERO anchor coverage. Now:
#   A — verify-anchors.rb computes per-displayed-tile anchor coverage
#       (matched_in == tile display name, or sigma_element_hint token-match),
#       writes anchor_coverage {covered, displayed, uncovered:[names]} into the
#       verdict, and WARNs on uncovered tiles (exit code unchanged — advisory).
#   B — assert-phase6-ran's charts_total<=0 ORACLE SUBSTITUTION requires
#       covered==displayed OR every uncovered tile named in source-anchors.json
#       coverage_waivers [{tile, reason}] (Phase 1d). Stale verdict without the
#       field fails closed. General gate-13 path: WARN only, no new failure.
#
# Offline + deterministic. Usage: ruby scripts/test-g10-anchor-coverage.rb

require 'json'
require 'csv'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/blind_fixture'

Encoding.default_external = Encoding::UTF_8

HERE   = __dir__
VERIFY = File.join(HERE, 'verify-anchors.rb')
GATE   = File.join(HERE, 'assert-phase6-ran.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'Part A — verify-anchors per-displayed-tile coverage'
def stage_verify_fixture(d, anchors, waivers: nil)
  elements = [
    { 'id' => 'el-a', 'kind' => 'chart', 'name' => 'Alpha Chart', 'source' => { 'elementId' => 'base' } },
    { 'id' => 'el-b', 'kind' => 'chart', 'name' => 'Beta Chart' },
    { 'id' => 'el-c', 'kind' => 'chart', 'name' => 'Gamma Chart' },
    { 'id' => 'base', 'kind' => 'table', 'name' => 'Base' }
  ]
  spec = {
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [{ 'id' => 'p', 'name' => 'Dashboard' }],
    'elements' => elements,
    'layout' => "<Page id=\"p\">#{elements.map { |el| %(<Element elementId="#{el['id']}"/>) }.join}</Page>"
  }
  File.write(File.join(d, 'wb.json'), JSON.generate(spec))
  exdir = File.join(d, 'exports')
  Dir.mkdir(exdir) unless Dir.exist?(exdir)
  File.write(File.join(exdir, 'el-a.csv'), "x,y\n1,100\n")
  File.write(File.join(exdir, 'el-b.csv'), "x,y\n1,55\n")
  File.write(File.join(exdir, 'el-c.csv'), "x,y\n1,77\n")
  File.write(File.join(exdir, 'base.csv'), "v\n100\n55\n77\n999\n")
  doc = { 'source_image' => 'v.png', 'anchors' => anchors }
  doc['coverage_waivers'] = waivers if waivers
  File.write(File.join(d, 'source-anchors.json'), JSON.generate(doc))
  [File.join(d, 'wb.json'), exdir]
end

BASE_ANCHORS = [
  { 'id' => 'a1', 'label' => 'Alpha value', 'raw' => '100', 'kind' => 'number' },
  { 'id' => 'a2', 'label' => 'Alpha pair', 'raw' => '1', 'kind' => 'number' },
  { 'id' => 'a3', 'label' => 'x', 'raw' => '999', 'kind' => 'number' },        # matches only the feeder
  { 'id' => 'a4', 'label' => 'x2', 'raw' => '999', 'kind' => 'number' },
  { 'id' => 'a5', 'label' => 'x3', 'raw' => '999', 'kind' => 'number' }
].freeze

Dir.mktmpdir do |d|
  # Beta covered by matched_in; Gamma covered ONLY via a hint (its anchor MISSES).
  anchors = BASE_ANCHORS.map(&:dup)
  anchors[1] = { 'id' => 'a2', 'label' => 'Beta value', 'raw' => '55', 'kind' => 'number' }
  anchors << { 'id' => 'a6', 'label' => 'Gamma KPI', 'raw' => '424242', 'kind' => 'number',
               'sigma_element_hint' => 'Gamma Chart' }
  spec, exdir = stage_verify_fixture(d, anchors)
  out, err, st = Open3.capture3(RbConfig.ruby, VERIFY, '--workdir', d, '--workbook-spec', spec, '--exports-dir', exdir)
  v = JSON.parse(File.read(File.join(d, 'anchors-verdict.json')))
  cov = v['anchor_coverage']
  check(cov.is_a?(Hash), 'anchor_coverage written into the verdict', fails)
  check(cov && cov['displayed'] == 3 && cov['covered'] == 3 && cov['uncovered'] == [],
        "matched_in + hint token-match both cover (got #{cov.inspect})", fails)
  check(!st.success?, 'exit still reflects the MISSING anchor (coverage is advisory, not a pass)', fails)
  check(!(out + err).include?('UNCOVERED'), 'no UNCOVERED warning when every displayed tile is covered', fails)
end

Dir.mktmpdir do |d|
  # Nothing watches Beta or Gamma: anchors match in Alpha + the feeder only.
  spec, exdir = stage_verify_fixture(d, BASE_ANCHORS.map(&:dup))
  out, err, st = Open3.capture3(RbConfig.ruby, VERIFY, '--workdir', d, '--workbook-spec', spec, '--exports-dir', exdir)
  v = JSON.parse(File.read(File.join(d, 'anchors-verdict.json')))
  cov = v['anchor_coverage']
  check(st.success?, "all anchors matched -> exit 0 (coverage never flips the exit; got #{st.exitstatus})", fails)
  check(cov && cov['covered'] == 1 && cov['displayed'] == 3 &&
        cov['uncovered'].sort == ['Beta Chart', 'Gamma Chart'],
        "uncovered displayed tiles named (got #{cov.inspect})", fails)
  check((out + err) =~ /UNCOVERED\s+"Beta Chart"/ && (out + err) =~ /UNCOVERED\s+"Gamma Chart"/,
        'WARN names each uncovered tile', fails)
  check((out + err).include?('coverage_waivers'), 'WARN points at the Phase 1d coverage_waivers escape', fails)
end

Dir.mktmpdir do |d|
  # PR-6 provenance rider: an anchor EXPLICITLY marked png-eyeball earns NO
  # coverage credit for the tile it matched in (eyeballed values are the weak
  # reading the field sessions got wrong); legacy provenance-less anchors keep
  # their credit (back-compat, exercised by the cases above).
  anchors = BASE_ANCHORS.map(&:dup)
  anchors[1] = { 'id' => 'a2', 'label' => 'Beta value', 'raw' => '55', 'kind' => 'number',
                 'provenance' => 'png-eyeball' }
  spec, exdir = stage_verify_fixture(d, anchors)
  _out, _err, st = Open3.capture3(RbConfig.ruby, VERIFY, '--workdir', d, '--workbook-spec', spec, '--exports-dir', exdir)
  v = JSON.parse(File.read(File.join(d, 'anchors-verdict.json')))
  cov = v['anchor_coverage']
  check(st.success?, 'png-eyeball anchor still MATCHES (provenance never changes matching)', fails)
  check(cov && cov['uncovered'].include?('Beta Chart'),
        "png-eyeball match earns NO coverage credit — Beta stays uncovered (got #{cov.inspect})", fails)
end

Dir.mktmpdir do |d|
  # coverage_waivers annotate the WARN (the verdict keeps the RAW measurement).
  spec, exdir = stage_verify_fixture(d, BASE_ANCHORS.map(&:dup),
                                     waivers: [{ 'tile' => 'Beta Chart', 'reason' => 'legend-only tile' },
                                               { 'tile' => 'Gamma Chart', 'reason' => 'no printed values' }])
  out, err, = Open3.capture3(RbConfig.ruby, VERIFY, '--workdir', d, '--workbook-spec', spec, '--exports-dir', exdir)
  v = JSON.parse(File.read(File.join(d, 'anchors-verdict.json')))
  check(v['anchor_coverage']['uncovered'].sort == ['Beta Chart', 'Gamma Chart'],
        'verdict keeps the raw uncovered list (waivers applied by the GATE, not the measurement)', fails)
  check((out + err).include?('[coverage_waivers: waived at Phase 1d]'),
        'WARN marks tiles already waived at Phase 1d', fails)
end

puts
puts 'Part B — assert-phase6-ran charts_total==0 ORACLE coverage floor'
def oracle_workdir(d, coverage:, waivers: nil, omit_coverage: false)
  File.write(File.join(d, 'parity-final.json'), JSON.pretty_generate(
    'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
    'charts_total' => 0, 'charts_pass' => 0,
    'visual_checked' => true, 'visual_verdict' => 'pass',
    'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass',
                           'composition_match' => 'pass', 'chart_shapes_match' => 'pass',
                           'labels_legible' => 'pass', 'numbers_formatted' => 'pass' },
    'agent_vision' => true))
  File.binwrite(File.join(d, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  BlindFixture.install(d) # PR-9: gate 8b refuses a self-attested visual pass
  Dir.mkdir(File.join(d, 'visual-verify')) unless Dir.exist?(File.join(d, 'visual-verify'))
  File.write(File.join(d, 'visual-verify', 'manifest.json'), JSON.pretty_generate(
    (0..2).map { |i| { 'worksheet' => "w#{i}", 'element_id' => "el#{i}", 'visual_verified' => true, 'shape_match' => true } }))
  sa = { 'source_image' => 'v.png',
         'anchors' => (1..5).map { |i| { 'id' => "a#{i}", 'label' => "m#{i}", 'raw' => "#{i}00", 'kind' => 'number' } } }
  sa['coverage_waivers'] = waivers if waivers
  File.write(File.join(d, 'source-anchors.json'), JSON.pretty_generate(sa))
  av = { 'checked' => 5, 'matched' => 5, 'missing' => [], 'pass' => true,
         'detail' => [], 'tiles_all_nonempty' => true, 'dashboard_tiles_empty' => [] }
  av['anchor_coverage'] = coverage unless omit_coverage
  File.write(File.join(d, 'anchors-verdict.json'), JSON.pretty_generate(av))
end

def run_gate(d, *args)
  env = { 'SIGMA_BASE_URL' => nil, 'SIGMA_API_TOKEN' => nil }
  Open3.capture3(env, RbConfig.ruby, GATE, '--workdir', d, *args)
end

Dir.mktmpdir do |d|
  oracle_workdir(d, coverage: { 'covered' => 3, 'displayed' => 3, 'uncovered' => [] })
  out, err, st = run_gate(d)
  check(st.success?, "full coverage -> oracle stands in, exit 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip})", fails)
  check(out.include?('ANCHORS ORACLE stands in') && out.include?('anchor coverage 3/3'),
        'oracle PASS line reports the coverage ratio', fails)
end

Dir.mktmpdir do |d|
  oracle_workdir(d, coverage: { 'covered' => 1, 'displayed' => 3, 'uncovered' => ['Beta Chart', 'Gamma Chart'] })
  a_out, a_err, st = run_gate(d)
  combined = a_out + a_err
  check(st.exitstatus == 2, "uncovered tiles, no waivers -> oracle REFUSED, exit 2 (got #{st.exitstatus})", fails)
  check(combined =~ /d\) every displayed tile has anchor coverage/ && combined.include?('UNCOVERED'),
        'refusal names condition (d) with the uncovered tiles', fails)
  check(combined.include?('coverage_waivers'), 'refusal points at the Phase 1d coverage_waivers path', fails)
  check(combined !~ /ANCHORS ORACLE stands in/, 'oracle does NOT stand in over uncovered tiles', fails)
end

Dir.mktmpdir do |d|
  oracle_workdir(d, coverage: { 'covered' => 1, 'displayed' => 3, 'uncovered' => ['Beta Chart', 'Gamma Chart'] },
                    waivers: [{ 'tile' => 'Beta Chart', 'reason' => 'legend-only tile, no printed values' },
                              { 'tile' => 'Gamma Chart', 'reason' => 'image tile' }])
  out, _err, st = run_gate(d)
  check(st.success?, "every uncovered tile coverage-waived at Phase 1d -> exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('2 coverage-waived at Phase 1d'), 'PASS line counts the coverage waivers', fails)
end

Dir.mktmpdir do |d|
  # PARTIAL waivers do not unlock the oracle.
  oracle_workdir(d, coverage: { 'covered' => 1, 'displayed' => 3, 'uncovered' => ['Beta Chart', 'Gamma Chart'] },
                    waivers: [{ 'tile' => 'Beta Chart', 'reason' => 'legend-only' }])
  _out, err, st = run_gate(d)
  check(st.exitstatus == 2 && (err.include?('Gamma Chart') || (_out + err).include?('Gamma Chart')),
        "partially-waived coverage still refused, naming the unwaived tile (got #{st.exitstatus})", fails)
end

Dir.mktmpdir do |d|
  # Stale verdict (no anchor_coverage field) fails CLOSED — same W1.1 doctrine.
  oracle_workdir(d, coverage: nil, omit_coverage: true)
  a_out, a_err, st = run_gate(d)
  combined = a_out + a_err
  check(st.exitstatus == 2, "verdict predating anchor_coverage -> fail closed, exit 2 (got #{st.exitstatus})", fails)
  check(combined =~ /d\) per-displayed-tile anchor coverage \(UNKNOWN/,
        'refusal says the coverage is UNKNOWN and to re-run verify-anchors', fails)
end

puts
puts 'Part C — general gate-13 path: coverage is WARN-only'
Dir.mktmpdir do |d|
  # charts_total=2 (real parity in force) + passing anchors verdict with
  # uncovered tiles -> exit 0 with a WARN, no new failure mode.
  File.write(File.join(d, 'parity-final.json'), JSON.pretty_generate(
    'workbook_id' => 'wb-test', 'mode' => 'strict', 'status' => 'PASS',
    'charts_total' => 2, 'charts_pass' => 2, 'charts_fail' => 0,
    'visual_checked' => true, 'visual_verdict' => 'pass',
    'style_checklist' => { 'element_titles_hidden' => 'pass', 'palette_match' => 'pass',
                           'composition_match' => 'pass', 'chart_shapes_match' => 'pass',
                           'labels_legible' => 'pass', 'numbers_formatted' => 'pass' },
    'agent_vision' => true))
  File.binwrite(File.join(d, 'sigma-render.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 6000))
  BlindFixture.install(d) # PR-9: gate 8b refuses a self-attested visual pass
  Dir.mkdir(File.join(d, 'views'))
  File.binwrite(File.join(d, 'views', 'dash.png'), "\x89PNG\r\n\x1a\n".b + ("\x00".b * 100))
  File.write(File.join(d, 'source-anchors.json'), JSON.pretty_generate(
    'source_image' => 'views/dash.png',
    'anchors' => (1..5).map { |i| { 'id' => "a#{i}", 'label' => "m#{i}", 'raw' => "#{i}00", 'kind' => 'number' } }))
  File.write(File.join(d, 'anchors-verdict.json'), JSON.pretty_generate(
    'checked' => 5, 'matched' => 5, 'missing' => [], 'pass' => true, 'detail' => [],
    'tiles_all_nonempty' => true, 'dashboard_tiles_empty' => [],
    'anchor_coverage' => { 'covered' => 1, 'displayed' => 3, 'uncovered' => ['Beta Chart', 'Gamma Chart'] }))
  out, err, st = run_gate(d)
  check(st.success?, "general path: uncovered tiles -> still exit 0 (got #{st.exitstatus})", fails)
  check((out + err) =~ /\[WARN\] gate 13: 2 displayed tile\(s\) have ZERO anchor coverage/,
        'general path WARNs with the uncovered count', fails)
  check((out + err).include?('Advisory on'), 'WARN says it is advisory here and hard on the oracle path', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — anchor coverage measurement + oracle coverage floor + advisory general path'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
