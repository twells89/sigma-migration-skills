#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-render-once.rb — W2.7 render-once per latestDocumentVersion. The reuse
# decision is a PURE function (render_reuse_plan, extracted from the
# orchestrator) over the 5b render-versions sidecar + on-disk discovery
# artifacts; the matrix pins the red line: a version bump ALWAYS forces a
# fresh render, and reuse copies RAW PNGs only — never a verdict.
#
#   T1 reuse trip: same doc version + all pairs on disk → full staging plan
#      (source from views/<viewId>.png; sigma from the 5b render).
#   T2 RED LINE: changed/unknown doc version → nil (fresh render), always.
#   T3 fail-open gaps: missing sigma PNG / missing source (no fallback) /
#      empty layout / unreadable sidecar → nil.
#   T4 fallback order: views/<viewId>.png absent → dashboards/<name>.png.
#   T5 wiring pins: 6f call-site is reuse-else-child; reuse block copies PNGs
#      and writes the manifest with visual_match:false (never a judgment);
#      5b writes the version-keyed sidecar; RCF banner points pass 1 at the
#      staged 6f render only under an unchanged version.
#
# Usage: ruby scripts/test-render-once.rb   (<5s, no spawns, no network)

require 'json'
require 'tmpdir'
require 'fileutils'
require_relative 'lib/workbook_code'

DIR = __dir__
SRC = File.read(File.join(DIR, 'migrate-tableau.rb'), encoding: 'UTF-8')
m = SRC.match(/^def render_reuse_plan.*?\n^end$/m) or abort('could not extract render_reuse_plan')
eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code
dim_method = SRC.match(/^def visual_render_dimensions.*?\n^end$/m) or
  abort('could not extract visual_render_dimensions')
eval(dim_method[0]) # rubocop:disable Security/Eval

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

PNG = "\x89PNG-fixture-bytes"
def seed(d, doc_version: 'v7', view_png: true, dash_png: false, sigma_png: true, layout: true)
  FileUtils.mkdir_p(File.join(d, 'visual-qa'))
  FileUtils.mkdir_p(File.join(d, 'views'))
  FileUtils.mkdir_p(File.join(d, 'dashboards'))
  p1 = File.join(d, 'visual-qa', 'p1.png')
  File.binwrite(p1, PNG) if sigma_png
  File.write(File.join(d, 'visual-qa', 'render-versions.json'), JSON.pretty_generate(
               'doc_version' => doc_version, 'pages' => { 'p1' => p1 },
               'rendered_at' => '2026-01-01T00:00:00Z'))
  File.write(File.join(d, 'dashboard-layout.json'), JSON.pretty_generate(
               layout ? [{ 'dashboard' => 'Alpha Overview', 'zones' => [] }] : []))
  File.write(File.join(d, 'wb-ids.json'), JSON.pretty_generate(
               'document' => {
                 'schemaVersion' => 4,
                 'kind' => 'workbook',
                 'pages' => [{ 'name' => 'Alpha Overview', 'id' => 'p1' }],
                 'elements' => [],
                 'layout' => '<Page id="p1"></Page>'
               }))
  File.write(File.join(d, 'get-workbook.json'), JSON.pretty_generate(
               'workbook' => { 'views' => { 'view' => [{ 'name' => 'Alpha Overview', 'id' => 'view-1' }] } }))
  File.binwrite(File.join(d, 'views', 'view-1.png'), PNG) if view_png
  File.binwrite(File.join(d, 'dashboards', 'Alpha_Overview.png'), PNG) if dash_png
  d
end

puts 'T1 — reuse trip: unchanged doc version + all artifacts on disk'
Dir.mktmpdir do |d|
  seed(d)
  plan = render_reuse_plan(d, 'v7')
  check(plan.is_a?(Array) && plan.size == 1, 'full staging plan returned', fails)
  if plan.is_a?(Array) && plan.first
    r = plan.first
    check(r['slug'] == 'alpha-overview' && r['source_from'].end_with?('views/view-1.png') &&
          r['sigma_from'].end_with?('visual-qa/p1.png'),
          'source from the discovery view PNG, sigma from the version-keyed 5b render', fails)
  end
end

puts 'T2 — RED LINE: a version bump always forces a fresh render'
Dir.mktmpdir do |d|
  seed(d, doc_version: 'v7')
  check(render_reuse_plan(d, 'v8').nil?, 'changed doc version → nil (fresh render)', fails)
  check(render_reuse_plan(d, nil).nil?, 'unknown current version → nil (fail-open, never guess)', fails)
end

puts 'T3 — fail-open on ANY gap'
Dir.mktmpdir do |d|
  seed(d, sigma_png: false)
  check(render_reuse_plan(d, 'v7').nil?, 'missing 5b sigma PNG → nil', fails)
end
Dir.mktmpdir do |d|
  seed(d, view_png: false, dash_png: false)
  check(render_reuse_plan(d, 'v7').nil?, 'source PNG absent on both fallbacks → nil', fails)
end
Dir.mktmpdir do |d|
  seed(d, layout: false)
  check(render_reuse_plan(d, 'v7').nil?, 'no dashboards in the layout → nil (child renderer decides)', fails)
end
Dir.mktmpdir do |d|
  seed(d)
  File.write(File.join(d, 'visual-qa', 'render-versions.json'), '{ nope')
  check(render_reuse_plan(d, 'v7').nil?, 'unreadable sidecar → nil', fails)
end

puts 'T4 — source fallback order matches verify-dashboard-visual.rb'
Dir.mktmpdir do |d|
  seed(d, view_png: false, dash_png: true)
  plan = render_reuse_plan(d, 'v7')
  check(plan.is_a?(Array) && plan.first && plan.first['source_from'].end_with?('dashboards/Alpha_Overview.png'),
        'views/<viewId>.png absent → dashboards/<name>.png fallback', fails)
end

puts 'T5 — wiring pins'
check(SRC.include?('_reuse_plan = render_reuse_plan(WORK, _doc_v6f)') &&
      SRC =~ /if _reuse_plan\n.*REUSING the 5b renders/m,
      '6f call-site: reuse-else-child (child renderer untouched on the else leg)', fails)
check(SRC =~ /'visual_match' => false \}\n  end\n  File\.write\(File\.join\(_vqa6, 'compare-manifest\.json'\)/m,
      'reuse manifest stages visual_match:false — a COMPARISON TODO, never a judgment', fails)
check(SRC.scan(/render-versions\.json/).size >= 2 && SRC.include?("'doc_version' => sigma_doc_version(wb_id)"),
      '5b writes the version-keyed sidecar the reuse decision reads', fails)
check(SRC =~ /documentVersion .* is unchanged since 5b — START pass 1 from the/,
      'RCF banner starts pass 1 from the staged 6f render only under an unchanged version', fails)
check(m[0] !~ /parity-final|visual_verdict|blind_grade|visual_match/,
      'the pure reuse plan never touches verdict artifacts (raw evidence only)', fails)

puts 'T6 — fixed Tableau canvas drives Sigma render dimensions'
fixed = [{ 'dashboard' => 'Alpha Overview',
           'canvas_px' => { 'w' => 1600, 'h' => 1000, 'sizing_mode' => 'fixed' } }]
check(visual_render_dimensions({ 'name' => 'Alpha Overview' }, fixed) == [1600, 1000],
      'fixed source canvas replaces the old hard-coded 1800×1000 render', fails)
check(visual_render_dimensions({ 'name' => 'Other' }, fixed) == [1800, 1000],
      'unmatched/automatic dashboard keeps the safe render fallback', fails)

puts
if fails.empty?
  puts 'test-render-once: ALL PASS'
else
  puts "test-render-once: #{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
