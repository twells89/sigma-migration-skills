#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-per-page-masters.rb — PLAN-v3 PR-17.
#
# Proves the per-page master transform:
#   (1) is a NO-OP for 0 or 1 master-using content page (single-page builds stay
#       byte-identical to the shared-master build — the flag-OFF regression guard
#       in module form);
#   (2) on a two-page (hidden Data page + two dashboard pages) workbook gives each
#       page its OWN master instance with a distinct id;
#   (3) rewrites each page's chart source, control value-source, and control
#       filter TARGET to that page's master — no cross-page (ghost) targets;
#   (4) preserves master COLUMN ids (so control filters[].columnId still resolves)
#       and clones the hidden helper closure per page (helper -> page master);
#   (5) leaves the built spec control-lint CLEAN (shared control_lint.rb).
require 'json'
require 'set'
require_relative 'lib/per_page_masters'
require_relative 'lib/control_lint'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Master column (id preserved across clones) + a hidden top-N helper sourcing it.
def master_el
  { 'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'visibleAsSource' => false,
    'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm-1', 'elementId' => 'fact-1' },
    'columns' => [
      { 'id' => 'm-region', 'name' => 'Region', 'formula' => '[Order Fact/Region]' },
      { 'id' => 'm-unused', 'name' => 'Unused Payload', 'formula' => '[Order Fact/Unused Payload]' }
    ],
    'order' => %w[m-region m-unused] }
end

def helper_el
  { 'id' => 'topn-src', 'kind' => 'table', 'name' => 'TopN Source', 'visibleAsSource' => false,
    'source' => { 'kind' => 'table', 'elementId' => 'master' },
    'columns' => [{ 'id' => 'h-region', 'name' => 'Region', 'formula' => '[Master/Region]' }] }
end

# A content page: a chart sourcing `chart_src`, plus a Region list control whose
# value list AND filter target both point at the master.
def content_page(id, name, chart_src)
  { 'id' => id, 'name' => name, 'elements' => [
    { 'id' => "chart-#{id}", 'kind' => 'bar-chart', 'name' => "Rev #{name}",
      'source' => { 'kind' => 'table', 'elementId' => chart_src } },
    { 'id' => "el-ctl-region-#{id}", 'kind' => 'control', 'controlId' => "ctl-region-#{id}",
      'name' => 'Region', 'controlType' => 'list', 'mode' => 'include', 'selectionMode' => 'multiple',
      'source' => { 'kind' => 'source', 'source' => { 'kind' => 'table', 'elementId' => 'master' },
                    'columnId' => 'm-region' },
      'filters' => [{ 'id' => 'flt-1', 'source' => { 'kind' => 'table', 'elementId' => 'master' },
                      'columnId' => 'm-region' }] }
  ] }
end

def two_page_spec
  spec = { 'name' => 'WB', 'schemaVersion' => 1, 'pages' => [
    { 'id' => 'page-data', 'name' => 'Data', 'elements' => [master_el, helper_el] },
    content_page('dash-1', 'Overview', 'topn-src'), # chart sources the helper (which sources master)
    content_page('dash-2', 'Detail',   'master')    # chart sources the master directly
  ] }
  # Simulate the pre-split builder's workbook-wide fan-out: both page copies
  # still carry a target for topn-src, even though only Overview uses it.
  spec['pages'].drop(1).each do |page|
    page['elements'].find { |element| element['kind'] == 'control' }['filters'] << {
      'id' => 'flt-global-helper',
      'source' => { 'kind' => 'table', 'elementId' => 'topn-src' },
      'columnId' => 'h-region'
    }
  end
  spec
end

puts 'test-per-page-masters:'

# --- (1) no-op guards -------------------------------------------------------
single = { 'pages' => [
  { 'id' => 'page-data', 'name' => 'Data', 'elements' => [master_el] },
  content_page('dash-1', 'Overview', 'master')
] }
before = JSON.generate(single)
r0 = PerPageMasters.split!(single)
check(!r0[:applied] && JSON.generate(single) == before,
      'single master-using page → NO-OP, spec byte-identical (flag-OFF equivalence)', fails)

none = { 'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'elements' => [master_el] },
                     { 'id' => 'p-text', 'name' => 'Notes', 'elements' => [{ 'id' => 't', 'kind' => 'text', 'body' => 'hi' }] }] }
b2 = JSON.generate(none)
r_none = PerPageMasters.split!(none)
check(!r_none[:applied] && JSON.generate(none) == b2,
      'text-only extra page (0 pages use the master) → NO-OP', fails)

# --- (2)/(3)/(4) the split --------------------------------------------------
spec = two_page_spec
res = PerPageMasters.split!(spec)
check(res[:applied], 'two master-using pages → transform APPLIES', fails)
check(res[:pages] == 2, 'reports 2 pages split', fails)
check(res[:masters] == 2, 'reports 2 distinct master instances', fails)
check(res[:master_columns_before] == 4 && res[:master_columns_after] == 2,
      "slims each clone to its referenced columns (got #{res[:master_columns_before]} -> #{res[:master_columns_after]})", fails)

dp = spec['pages'].find { |p| p['name'] == 'Data' }
master_ids = dp['elements'].select { |e| e.dig('source', 'kind') == 'data-model' }.map { |e| e['id'] }
check(master_ids.uniq.size == 2, "two distinct master ids on the Data page (got #{master_ids.inspect})", fails)
check(master_ids.include?('master-overview') && master_ids.include?('master-detail'),
      "page-scoped master ids (got #{master_ids.inspect})", fails)
check(dp['elements'].none? { |e| e['id'] == 'master' },
      'the original shared master id is gone (fully de-shared, no orphan)', fails)

# column ids preserved on every clone → control filters[].columnId still resolves
check(dp['elements'].select { |e| e.dig('source', 'kind') == 'data-model' }
        .all? { |m| m['columns'].map { |c| c['id'] } == ['m-region'] },
      'master column ids preserved across clones (m-region)', fails)

# each page's control filter TARGET + value source point at THAT page's master;
# no target names another page's master (no cross-page ghost)
def page_ctl(spec, name)
  spec['pages'].find { |p| p['name'] == name }['elements'].find { |e| e['kind'] == 'control' }
end
ov = page_ctl(spec, 'Overview')
dt = page_ctl(spec, 'Detail')
ov_tgt = ov['filters'].first.dig('source', 'elementId')
dt_tgt = dt['filters'].first.dig('source', 'elementId')
check(ov_tgt == 'master-overview', "Overview control filters master-overview (got #{ov_tgt})", fails)
check(dt_tgt == 'master-detail',   "Detail control filters master-detail (got #{dt_tgt})", fails)
check(ov['source']['source']['elementId'] == 'master-overview', 'Overview control value-list sources its own master', fails)
check(ov_tgt != dt_tgt, 'the two pages target DIFFERENT masters (leakage impossible)', fails)
check(dt['filters'].length == 1,
      "Detail drops the copied Overview-only helper target (got #{dt['filters'].map { |f| f.dig('source', 'elementId') }.inspect})", fails)

# the helper closure is cloned per page and re-sourced to that page's master
ov_chart = spec['pages'].find { |p| p['name'] == 'Overview' }['elements'].find { |e| e['kind'] == 'bar-chart' }
check(ov_chart.dig('source', 'elementId') == 'topn-src-overview',
      "Overview chart sources its cloned helper (got #{ov_chart.dig('source', 'elementId')})", fails)
ov_helper = dp['elements'].find { |e| e['id'] == 'topn-src-overview' }
check(ov_helper && ov_helper.dig('source', 'elementId') == 'master-overview',
      'cloned helper re-sourced to its page master (helper -> master-overview)', fails)
dt_chart = spec['pages'].find { |p| p['name'] == 'Detail' }['elements'].find { |e| e['kind'] == 'bar-chart' }
check(dt_chart.dig('source', 'elementId') == 'master-detail',
      'Detail chart (direct master source) repointed to master-detail', fails)

# --- (5) control-lint clean on the split spec -------------------------------
viol = ControlLint.lint(spec)
check(viol.empty?, "control-lint CLEAN after split (violations: #{viol.inspect})", fails)
# and no ghost targets specifically
rows = ControlLint.controls_report(spec)
check(rows.all? { |r| r[:ghost_targets].empty? }, 'no ghost (cross-page) filter targets in any control', fails)
check(rows.all? { |r| !r[:reach].empty? }, 'every control reaches its page master (no dead controls)', fails)

# A gated workbook handoff re-enters with this already-split spec. The
# transform must be byte-idempotent: no master-overview-overview ids and no
# stale layout/source references.
split_once = JSON.generate(spec)
res_again = PerPageMasters.split!(spec)
check(!res_again[:applied] && JSON.generate(spec) == split_once,
      'already-split handoff re-entry → NO-OP, spec byte-identical', fails)
check(dp['elements'].none? { |element| element['id'].match?(/-overview-overview|-detail-detail/) },
      're-entry creates no double-suffixed master/helper ids', fails)

puts
if fails.empty?
  puts 'ALL PASS — per-page masters de-share correctly; single-page builds unchanged'
  exit 0
else
  puts "#{fails.length} FAILED"
  exit 1
end
