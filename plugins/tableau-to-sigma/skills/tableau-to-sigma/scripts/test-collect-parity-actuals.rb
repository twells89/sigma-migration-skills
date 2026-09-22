#!/usr/bin/env ruby
# frozen_string_literal: true
# test-collect-parity-actuals.rb — regression test for the workbook code-rep
# `document` unwrap in scripts/collect-parity-actuals.rb.
#
# Unlike the other one-offs, the fix here operates on the `--workbook-spec`
# FILE (a saved readback JSON, not a live GET): `spec = JSON.parse(File.read
# (opts[:spec]))` may now be a live-shaped nested `document` readback rather
# than the legacy flat artifact. A bare `spec['pages']` read there was always
# empty, so `el_by_id` came back empty and every chart in the plan was
# (wrongly) reported "element not in workbook spec" instead of being
# collected.
#
# No live version-probe GET is exercised here: the fixture spec carries no
# `latestDocumentVersion`/`latestVersion`, so `ExportPool.resolve_doc_version`
# returns nil and `build_export_cache` short-circuits before any network call
# (see collect-parity-actuals.rb's own comment on that path) — the ONLY
# network this test needs to stub is the pooled CSV export
# (POST .../export, GET /v2/query/:id/download), via the same `sigma_rest.rb`
# load-path-shadow convention as test-probe-control-formula.rb /
# test-probe-window-contexts.rb.
#
# Run: ruby scripts/test-collect-parity-actuals.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'collect-parity-actuals.rb')
REAL_SIGMA_REST = File.expand_path('lib/sigma_rest.rb', __dir__)

# A --workbook-spec readback shaped like the LIVE response: metadata
# (workbookId) sits alongside `document`, which carries flat elements,
# metadata-only pages, and their required layout.
# No latestDocumentVersion/latestVersion anywhere — the raw-export cache
# build must short-circuit on that (nil rb_ver) rather than attempt a live
# version-probe GET.
NESTED_WB_SPEC = {
  'workbookId' => 'wb-test',
  'document' => {
    'schemaVersion' => 4,
    'kind' => 'workbook',
    'pages' => [{ 'id' => 'p1', 'name' => 'Overview' }],
    'elements' => [
      { 'id' => 'c1', 'kind' => 'bar-chart', 'name' => 'Revenue by Region',
        'columns' => [
          { 'id' => 'col-region', 'name' => 'Region' },
          { 'id' => 'col-profit', 'name' => 'Profit',
            'format' => { 'kind' => 'number', 'formatString' => '$,.0f',
                          'currencySymbol' => '$', 'digitGroupingSymbol' => '.' } }
        ] }
    ],
    'layout' => '<Page id="p1"><Element elementId="c1"/></Page>'
  }
}.freeze

PLAN = { 'charts' => [
  { 'chart' => 'Revenue by Region', 'sigma_element_id' => 'c1', 'sigma_kind' => 'bar-chart',
    'sigma_columns' => %w[col-region col-profit] }
] }.freeze

SIGMA_STUB = <<~RUBY
  require 'json'
  module Sigma
    class Error < StandardError; end
    def self.request(method, path, body: nil, accept: nil, binary: false, content_type: nil, http: nil)
      if ENV['SIGMA_STUB_LOG']
        File.open(ENV['SIGMA_STUB_LOG'], 'a') { |f| f.puts JSON.generate('method' => method.to_s, 'path' => path, 'body' => body) }
      end
      case
      when method == :post && path == '/v2/workbooks/wb-test/export'
        { 'queryId' => 'q1' }
      when method == :get && path == '/v2/query/q1/download'
        "Region,Profit\\nWest,$106.801\\n"
      else
        raise Error, "stub: unexpected \#{method} \#{path}"
      end
    end
    def self.base_url; 'https://stub.invalid'; end
    def self.auth_token; 'stub-token'; end
  end
  real = ENV['REAL_SIGMA_REST']
  $LOADED_FEATURES << real if real && !$LOADED_FEATURES.include?(real)
RUBY

def run_collect(dir, extra_env = {})
  stub_dir = File.join(dir, 'stub')
  Dir.mkdir(stub_dir) unless Dir.exist?(stub_dir)
  File.write(File.join(stub_dir, 'sigma_rest.rb'), SIGMA_STUB)

  spec_path = File.join(dir, 'wb-readback.json')
  plan_path = File.join(dir, 'parity-plan.json')
  out_path  = File.join(dir, 'parity-actuals.json')
  File.write(spec_path, JSON.generate(NESTED_WB_SPEC))
  File.write(plan_path, JSON.generate(PLAN))

  out, err, st = Open3.capture3(
    { 'REAL_SIGMA_REST' => REAL_SIGMA_REST, 'SIGMA_BASE_URL' => 'https://stub.invalid',
      'SIGMA_API_TOKEN' => 'stub-token' }.merge(extra_env),
    RbConfig.ruby, '-I', stub_dir, '-r', 'sigma_rest', SCRIPT,
    '--plan', plan_path, '--workbook-id', 'wb-test', '--workbook-spec', spec_path,
    '--out', out_path, '--pool', '1', '--timeout', '30', '--drift-warn-minutes', '0'
  )
  [out, err, st, out_path]
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts '== collect-parity-actuals: wrapped --workbook-spec file must resolve the chart element =='
Dir.mktmpdir do |dir|
  log = File.join(dir, 'stub.log')
  out, err, st, out_path = run_collect(dir, { 'SIGMA_STUB_LOG' => log })

  check(st.exitstatus.zero?, "exits 0 (got #{st.exitstatus}; out=#{out.inspect} err=#{err.inspect})", fails)
  check(out.include?('1/1 chart(s) collected'),
        "reports 1/1 charts collected, not 0/1 (got: #{out.inspect})", fails)
  check(!out.include?('NOT COLLECTED'),
        "does NOT report 'element not in workbook spec' (flat elements must resolve) (got: #{out.inspect})", fails)

  check(File.exist?(out_path), 'parity-actuals.json written', fails)
  if File.exist?(out_path)
    actuals = JSON.parse(File.read(out_path))
    check(actuals['Revenue by Region'] == [['West', 106_801.0]],
          "actuals strip the column's custom dot grouping separator (got #{actuals.inspect})", fails)
  end

  reqs = File.exist?(log) ? File.readlines(log).map { |l| JSON.parse(l) } : []
  check(reqs.any? { |r| r['method'] == 'post' && r['path'] == '/v2/workbooks/wb-test/export' },
        'export POST issued for the resolved element (proves el_by_id found c1)', fails)
end

puts
if fails.empty?
  puts 'test-collect-parity-actuals: ALL PASS'
else
  puts "test-collect-parity-actuals: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
