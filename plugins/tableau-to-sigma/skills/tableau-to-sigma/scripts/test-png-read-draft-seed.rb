#!/usr/bin/env ruby
# Regression test for finding #8: the orchestrator can't read images, so it now
# SEEDS a draft png-read.json from the .twb zone tree (removing the write-from-
# scratch friction) — but the draft is verified:false, so the gate STILL requires
# the agent to Read the dashboard PNG and set verified:true (the .twb can't tell
# bar-vs-pie, text annotations, or the filter shelf). This preserves the vision
# gate while addressing the friction.
#
# Usage: ruby scripts/test-png-read-draft-seed.rb

require 'json'
require 'tmpdir'
require_relative 'lib/dashboard_read'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

LAYOUT = [{
  'dashboard' => 'Exec',
  'zones' => [
    { 'id' => 'k1', 'kind' => 'chart', 'caption' => 'KPI Revenue', 'is_kpi' => true, 'chart_kind' => 'kpi' },
    { 'id' => 'b1', 'kind' => 'chart', 'caption' => 'Rev by Region', 'chart_kind' => 'bar' },
    { 'id' => 'a1', 'kind' => 'chart', 'caption' => 'Auto Tile', 'chart_kind' => 'automatic' },
    { 'id' => 't1', 'kind' => 'text', 'text_runs' => [{ 'text' => 'Executive Overview' }] }
  ]
}]
META = { 'shared_filters' => [{ 'caption' => 'Order Date' }] }

Dir.mktmpdir do |d|
  File.write("#{d}/dashboard-layout.json", JSON.dump(LAYOUT))
  File.write("#{d}/dashboard-layout-meta.json", JSON.dump(META))

  p = DashboardRead.seed_from_layout(d)
  check(!p.nil? && File.exist?(p), 'seed_from_layout wrote a draft png-read.json', fails)
  doc = JSON.parse(File.read(p))

  check(doc['verified'] == false, 'draft is verified:false', fails)
  check(doc['tiles'].size == 3, "3 chart tiles seeded (got #{doc['tiles'].size})", fails)
  check(doc['tiles'].any? { |t| t['title'] == 'KPI Revenue' && t['kind'] == 'kpi-chart' }, 'KPI → kpi-chart', fails)
  check(doc['tiles'].any? { |t| t['title'] == 'Rev by Region' && t['kind'] == 'bar-chart' }, 'bar → bar-chart', fails)
  check(doc['tiles'].any? { |t| t['title'] == 'Auto Tile' && t['kind'] == 'bar-chart' }, "automatic → bar-chart (verify vs PNG)", fails)
  check(doc['text_elements'].include?('Executive Overview'), 'text zone → text_elements', fails)
  check(doc['filter_shelf'].any? { |f| f['label'] == 'Order Date' }, 'shared_filter → filter_shelf', fails)

  ok, errs = DashboardRead.validate(d)
  check(!ok && errs.first.to_s =~ /DRAFT|verified/, 'gate REJECTS the unverified draft', fails)

  doc['verified'] = true
  File.write(p, JSON.pretty_generate(doc))
  ok2, = DashboardRead.validate(d)
  check(ok2, 'gate PASSES once verified:true', fails)
end

# A hand-written png-read.json WITHOUT a `verified` field stays valid (back-compat).
Dir.mktmpdir do |d|
  File.write(DashboardRead.path(d), JSON.dump(
    'tiles' => [{ 'title' => 'X', 'kind' => 'bar-chart' }], 'text_elements' => [], 'filter_shelf' => []
  ))
  ok, = DashboardRead.validate(d)
  check(ok, 'hand-written file without a verified field is still accepted (back-compat)', fails)
end

puts
if fails.empty?
  puts 'ALL PASS — .twb draft seeded; gate still requires visual verification'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }
  exit 1
end
