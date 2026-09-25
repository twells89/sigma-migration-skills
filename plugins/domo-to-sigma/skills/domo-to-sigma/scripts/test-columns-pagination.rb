#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Shared contract test: every Sigma COLUMNS-endpoint read in the shared scripts is
# exhaustively paginated. Sigma's server default page size is 50, so a bare
# first-page GET silently truncates a wide workbook — unpaginated single-page
# reads reached END OF SUPPORT 2026-06-02 (see shared/lib/sigma_rest.rb).
#
# Why this is a SHARED test: all three scripts below are canonical shared infra
# synced into 7-10 converters, so the defect and its fix are fleet-wide. The worst
# case is assert-phase6-ran.rb's gate 3/7 audit, which selects columns whose
# type == "error" and fails the run if any exist: reading one page makes it blind
# past column 50, so a wide workbook whose error columns sit past the cut passes
# as GREEN — a false GREEN in the one place built to prevent exactly that.
#
# Creds-free and network-free: behavior is proven through the `http:` injection
# seam, and per-script wiring is proven by reading the source.
#
# Usage: ruby shared/scripts/test-columns-pagination.rb

require 'json'
require 'net/http'

HERE = File.expand_path(__dir__)
# Works from BOTH layouts this file lives in: canonical shared/scripts (sigma_rest.rb
# is a sibling under shared/lib) and every fanned-out plugin copy (sigma_rest.rb lives
# under scripts/lib there instead, same as verify-warehouse.rb/probe-controls.rb load
# it). A nonexistent candidate is silently skipped by require, so unshifting both is
# safe in either location.
$LOAD_PATH.unshift File.expand_path('lib', HERE)
$LOAD_PATH.unshift File.expand_path('../lib', HERE)
require 'sigma_rest'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def http_res(klass, code, body)
  res = klass.new('1.1', code.to_s, 'msg')
  res.instance_variable_set(:@body, body)
  res.instance_variable_set(:@read, true)
  res
end

class FakeHttp
  attr_reader :reqs
  def initialize(responses)
    @queue = responses
    @reqs = []
  end

  def request(req)
    @reqs << req
    @queue.shift
  end
end

puts 'test-columns-pagination.rb — shared columns readers must paginate'

# 1. BEHAVIORAL: a wide workbook spread over three pages is fully consumed, and
#    an error column sitting past the default page size is still seen. This is the
#    gate 3/7 false-GREEN scenario in miniature.
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
page1 = (1..50).map  { |i| { 'label' => "COL_#{i}", 'type' => { 'type' => 'text' } } }
page2 = (51..100).map { |i| { 'label' => "COL_#{i}", 'type' => { 'type' => 'text' } } }
page3 = [{ 'label' => 'BROKEN_COL', 'type' => { 'type' => 'error' } }]
http = FakeHttp.new([
  http_res(Net::HTTPOK, 200, JSON.generate('entries' => page1, 'nextPage' => 'p2')),
  http_res(Net::HTTPOK, 200, JSON.generate('entries' => page2, 'nextPage' => 'p3')),
  http_res(Net::HTTPOK, 200, JSON.generate('entries' => page3))
])
entries = Sigma.list_entries('/v2/workbooks/wb-1/columns', http: http)
check(entries.size == 101, "all 101 columns across 3 pages are returned (got #{entries.size})", fails)
check(entries.any? { |c| c.dig('type', 'type') == 'error' },
      'an error column at ordinal 101 is SEEN — the gate 3/7 false-GREEN case', fails)
check(http.reqs.size == 3 && http.reqs.all? { |r| r.path.include?('limit=1000') },
      'every page request carries limit=1000', fails)

# 2. WIRING — the two library-using scripts read columns via Sigma.list_entries.
{
  'verify-warehouse.rb' => 'warehouse parity verifier',
  'probe-controls.rb'   => 'control label map'
}.each do |file, why|
  src = File.read(File.join(HERE, file))
  check(src.include?('Sigma.list_entries'), "#{file} paginates its columns read (#{why})", fails)
  check(!src.match?(/Sigma\.request\(:get,[^)]*\/columns"\)/),
        "#{file} no longer reads columns via a single Sigma.request", fails)
end

# 3. WIRING — the final gate paginates with a LOCAL loop and stays dependency-free.
#    Not every converter ships this gate under this name (qlik-to-sigma's phase-6
#    equivalent is verify-complete.rb) — skip rather than fail where the file is
#    simply absent; presence is proven everywhere it IS deployed (canonical +
#    every plugin target on assert-phase6-ran.rb's manifest entry).
phase6_path = File.join(HERE, 'assert-phase6-ran.rb')
if File.exist?(phase6_path)
  src = File.read(phase6_path)
  check(src.include?('nextPage'), 'assert-phase6-ran.rb follows nextPage on its gate 3/7 audit', fails)
  check(src.include?('limit=1000'), 'assert-phase6-ran.rb requests limit=1000 on its gate 3/7 audit', fails)
  check(!src.match?(/require 'sigma_rest'/),
        'assert-phase6-ran.rb stays free of a sigma_rest dependency (it is the final gate)', fails)
else
  puts '  SKIP  assert-phase6-ran.rb not present in this directory (converter uses a different phase-6 gate)'
end

puts ''
if fails.empty?
  puts 'test-columns-pagination.rb: ALL PASS'
  exit 0
else
  puts "test-columns-pagination.rb: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
