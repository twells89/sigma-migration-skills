#!/usr/bin/env ruby
# frozen_string_literal: true
# test-ground-truth-run.rb — offline tests for scripts/run-ground-truth.rb
# (PR-5 part A execution), --fixture mode (canned per-entry results, the
# probe-join-keys DIR/entry-<index>.json convention).
#
# Covers: per-entry results recorded (ok rows + columns; non-warehouse-sql
# entries carried as skipped-<classification> so the actuals mirror the
# ledger); missing-fixture entry → error + exit 2; row-explosion guard fires
# LOUD (missing-GROUP-BY class, exit 2); total --timeout deadline expiry →
# loud PARTIAL (exit 3, summary.complete=false); happy path exit 0 with the
# PR-6 freshness stamp (plan_generated_at).
#
# Run: ruby scripts/test-ground-truth-run.rb

require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'run-ground-truth.rb')

$fails = []
def ok(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def write_plan(dir, entries)
  path = File.join(dir, 'ground-truth-plan.json')
  File.write(path, JSON.pretty_generate(
               'version' => 1, 'generated_at' => '2026-07-18T00:00:00Z', 'entries' => entries
             ))
  path
end

def entry(chart, cls, sql = nil)
  e = { 'chart' => chart, 'sigma_element_id' => "el-#{chart.downcase.tr(' ', '-')}",
        'classification' => cls, 'reason' => cls == 'warehouse-sql' ? nil : 'test reason' }
  if sql
    e['sql'] = sql
    e['columns'] = [{ 'alias' => 'Region', 'role' => 'dim' }, { 'alias' => 'Sales (sum)', 'role' => 'measure' }]
  end
  e
end

SQL = "SELECT REGION_NAME AS \"Region\", SUM(SALES) AS \"Sales (sum)\"\nFROM ANALYTICS.PUBLIC.SALES_FACT T1\nGROUP BY 1"

puts '-- fixture-mode execution: per-entry results + ledger mirroring --'
Dir.mktmpdir do |dir|
  plan = write_plan(dir, [
    entry('Tile A', 'warehouse-sql', SQL),
    entry('Tile Vds', 'vds'),
    entry('Tile Anchor', 'anchor-only'),
    entry('Tile B', 'warehouse-sql', SQL) # no fixture file → error
  ])
  fdir = File.join(dir, 'fx')
  Dir.mkdir(fdir)
  File.write(File.join(fdir, 'entry-0.json'),
             JSON.pretty_generate('columns' => ['Region', 'Sales (sum)'],
                                  'rows' => [['East', 100.5], ['West', 200.25]]))
  out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--fixture', fdir)
  ok(st.exitstatus == 2, "error entry present → exit 2 (got #{st.exitstatus})")
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  ok(doc['version'] == 1 && doc['mode'] == 'fixture', 'actuals carry version + mode')
  ok(doc['plan_generated_at'] == '2026-07-18T00:00:00Z',
     'actuals stamped with plan_generated_at (PR-6 freshness binding)')
  by_chart = doc['results'].each_with_object({}) { |r, h| h[r['chart']] = r }
  a = by_chart['Tile A']
  ok(a['status'] == 'ok' && a['rows'] == [['East', 100.5], ['West', 200.25]] && a['n_rows'] == 2,
     'ok entry records its rows + row count')
  ok(a['columns'] == ['Region', 'Sales (sum)'], 'ok entry records its columns')
  ok(by_chart['Tile Vds']['status'] == 'skipped-vds' && by_chart['Tile Anchor']['status'] == 'skipped-anchor-only',
     'non-warehouse-sql entries mirror their ledger classification (nothing silently drops out)')
  ok(by_chart['Tile B']['status'] == 'error' && by_chart['Tile B']['error'].to_s.include?('entry-3'),
     'missing fixture → error naming the fixture file')
  ok(doc['summary']['ok'] == 1 && doc['summary']['error'] == 1 && doc['summary']['complete'] == false,
     'summary counts ok/error and complete=false')
  ok(out.include?('[1/2]') && out.include?('[2/2]'), 'per-entry progress lines printed')
  ok(err.include?('[FAIL]'), 'stderr announces the failure')
  ok(JSON.parse(File.read(plan))['entries'].size == 4, 'plan untouched by execution')
end

puts '-- happy path: all warehouse-sql entries ok → exit 0 --'
Dir.mktmpdir do |dir|
  write_plan(dir, [entry('Tile A', 'warehouse-sql', SQL), entry('Tile Vds', 'vds')])
  fdir = File.join(dir, 'fx')
  Dir.mkdir(fdir)
  File.write(File.join(fdir, 'entry-0.json'),
             JSON.pretty_generate('columns' => ['Region', 'Sales (sum)'], 'rows' => [['East', 1]]))
  _out, _err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--fixture', fdir)
  ok(st.exitstatus.zero?, "all ok → exit 0 (got #{st.exitstatus})")
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  ok(doc['summary']['complete'] == true, 'summary.complete=true when every warehouse-sql entry returned rows')
end

puts '-- row-explosion guard (missing GROUP BY must fail LOUD, not hang) --'
Dir.mktmpdir do |dir|
  write_plan(dir, [entry('Tile Explode', 'warehouse-sql', SQL)])
  fdir = File.join(dir, 'fx')
  Dir.mkdir(fdir)
  File.write(File.join(fdir, 'entry-0.json'),
             JSON.pretty_generate('columns' => ['Region', 'Sales (sum)'],
                                  'rows' => [['a', 1], ['b', 2], ['c', 3]]))
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--fixture', fdir, '--row-limit', '2')
  ok(st.exitstatus == 2, "row explosion → exit 2 (got #{st.exitstatus})")
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  r = doc['results'][0]
  ok(r['status'] == 'row-explosion' && r['error'].to_s.include?('GROUP BY'),
     'entry recorded row-explosion naming the missing-GROUP-BY cause')
  ok(doc['summary']['row_explosion'] == 1 && doc['summary']['complete'] == false,
     'summary counts the explosion; complete=false')
  ok(err.include?('ROW-EXPLOSION'), 'stderr shouts ROW-EXPLOSION')
  ok(r['rows'].nil?, 'exploded rows are NOT dumped into the actuals file')
end

puts '-- total deadline expiry → loud PARTIAL --'
Dir.mktmpdir do |dir|
  write_plan(dir, [entry('Tile A', 'warehouse-sql', SQL), entry('Tile B', 'warehouse-sql', SQL)])
  fdir = File.join(dir, 'fx')
  Dir.mkdir(fdir)
  File.write(File.join(fdir, 'entry-0.json'), JSON.pretty_generate('columns' => %w[Region S], 'rows' => [['x', 1]]))
  File.write(File.join(fdir, 'entry-1.json'), JSON.pretty_generate('columns' => %w[Region S], 'rows' => [['x', 1]]))
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--fixture', fdir, '--timeout', '0')
  ok(st.exitstatus == 3, "deadline expired → exit 3 (got #{st.exitstatus})")
  doc = JSON.parse(File.read(File.join(dir, 'ground-truth-actuals.json')))
  ok(doc['results'].all? { |r| r['status'] == 'deadline-skipped' },
     'entries past the deadline recorded deadline-skipped (never a hang)')
  ok(doc['summary']['deadline_skipped'] == 2 && doc['summary']['complete'] == false,
     'summary counts deadline skips; complete=false (honest partial)')
  ok(err.include?('[PARTIAL]') && err.include?('INCOMPLETE'), 'stderr announces the loud partial')
end

puts '-- invocation guards --'
Dir.mktmpdir do |dir|
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir)
  ok(st.exitstatus == 1 && err.include?('usage'), 'no --connection-id/--fixture → usage exit 1')
  _out, err, st = Open3.capture3(RbConfig.ruby, SCRIPT, '--workdir', dir, '--fixture', dir)
  ok(st.exitstatus == 1 && err.include?('derive-ground-truth'),
     'missing plan → exit 1 pointing at derive-ground-truth.rb')
end

# ---------------------------------------------------------------------------
# LIVE path (stubbed REST, no network) — E7.1/A11 (wave-1 review): every probe
# workbook REGISTERS in <workdir>/probe-artifacts.jsonl at POST time and marks
# its outcome at DELETE, so a crash between POST and DELETE can no longer
# strand an orphan the sweep's registry-first mode cannot see.
# ---------------------------------------------------------------------------
GT_STUB = <<~'RUBY'
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      File.open(ENV['GT_STUB_LOG'], 'a') { |f| f.puts(JSON.generate('m' => method.to_s, 'p' => path)) }
      return { 'workbookId' => 'wb-gt-probe' } if method == :post && path == '/v2/workbooks/spec'
      return { 'queryId' => 'q-gt' } if method == :post && path.include?('/export')
      return "Region,Sales (sum)\nEast,100.5\n" if method == :get && path.start_with?('/v2/query/')
      return {} if method == :delete
      raise Error, "stub: unexpected #{method} #{path}"
    end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

puts '-- live path: probe workbook registered at POST, marked cleaned at DELETE (E7.1/A11) --'
Dir.mktmpdir do |dir|
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), GT_STUB)
  write_plan(dir, [entry('Tile A', 'warehouse-sql', SQL)])
  log = File.join(dir, 'gt-stub-log.jsonl')
  _out, err, st = Open3.capture3(
    { 'GT_STUB_LOG' => log, 'REAL_SIGMA_REST' => File.join(__dir__, 'lib', 'sigma_rest.rb'),
      'SIGMA_BASE_URL' => 'https://stub.invalid', 'SIGMA_API_TOKEN' => 'stub' },
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest',
    SCRIPT, '--workdir', dir, '--connection-id', 'conn-1'
  )
  ok(st.exitstatus.zero?, "live stub run exits 0 (got #{st.exitstatus}: #{err.lines.first(2).join(' ').strip[0, 140]})")
  calls = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  ok(calls.count { |c| c['m'] == 'delete' } == 1, 'probe workbook deleted exactly once')
  reg_path = File.join(dir, 'probe-artifacts.jsonl')
  ok(File.exist?(reg_path), 'probe-artifacts.jsonl written into the workdir (E7.1 registry)')
  reg = File.exist?(reg_path) ? File.readlines(reg_path).map { |l| JSON.parse(l) } : []
  created = reg.find { |r| r['created_at'] }
  cleaned = reg.find { |r| r['deleted_at'] }
  ok(created && created['id'] == 'wb-gt-probe' && created['script'] == 'run-ground-truth.rb' &&
     created['name'].to_s.start_with?('_probe_groundtruth_'),
     'created record: id + script + probe name registered AT POST time')
  ok(cleaned && cleaned['id'] == 'wb-gt-probe' && cleaned['via'] == 'ensure' &&
     cleaned['outcome'] == 'deleted',
     'cleaned record: DELETE outcome marked via ensure')
  # Registration order is the crash-safety contract: created BEFORE the export
  # ever starts (a kill between POST and DELETE leaves a findable record).
  ok(reg.index(created) < reg.index(cleaned), 'created line precedes cleaned line (register-at-creation)')
end

# Current live workbook POST contract: the serial fallback must canonicalize
# the throwaway probe exactly like the pooled and join-key probe seams.
script_source = File.read(SCRIPT)
canonicalize_at = script_source.index('WorkbookCode.canonicalize(spec)')
post_at = script_source.index("Sigma.request(:post, '/v2/workbooks/spec'")
ok(script_source.include?("require_relative 'lib/workbook_code'"),
   'serial live seam loads the workbook code-representation adapter')
ok(canonicalize_at && post_at && canonicalize_at < post_at,
   'serial live seam canonicalizes the probe workbook before POST')

puts
if $fails.empty?
  puts 'ALL PASS — run-ground-truth fixture-mode execution'
  exit 0
else
  puts "FAILURES (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
