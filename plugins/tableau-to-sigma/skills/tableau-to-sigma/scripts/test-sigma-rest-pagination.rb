#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline contract test for the repo-speed pass over the Sigma REST surface
# (PR-507): Sigma.list_entries pagination + the orchestrator's mint-once-per-
# TTL child-spawn wiring. Conventions of test-sigma-rest.rb: creds-free,
# network-free — the token exchange is stubbed and requests go through the
# `http:` injection seam.
#
# Covers:
#   - list_entries: a multi-page list is FULLY consumed (limit=1000 + nextPage
#     loop). Unpaginated single-page responses reached END OF SUPPORT
#     2026-06-02, so a bare first-page GET silently truncates at the server
#     default (50) — the field case is a 599-column workbook.
#   - list_entries: query-string composition + defensive termination.
#   - migrate-tableau.rb wiring pins: sigma_token! reuses a fresh-stamped
#     token instead of minting per child; both Sigma spawn wrappers forward
#     the mint stamp; tableau_env reuses its signin within a TTL; all five
#     orchestrator list reads paginate via Sigma.list_entries.
#
# Usage: ruby scripts/test-sigma-rest-pagination.rb

require 'json'
require 'net/http'
require_relative 'lib/sigma_rest'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# --- test harness (test-sigma-rest.rb conventions) --------------------------

ENV_KEYS = %w[SIGMA_BASE_URL SIGMA_CLIENT_ID SIGMA_CLIENT_SECRET
              SIGMA_API_TOKEN SIGMA_TOKEN_MINTED_AT SIGMA_WORKDIR].freeze

# The library's load-time bootstrap may have pulled real creds from
# ~/.sigma-migration/env or ./auth.json — scrub them so every case starts clean
# and nothing here can reach a live API.
def reset_state!
  ENV_KEYS.each { |k| ENV.delete(k) }
  Sigma.instance_variable_set(:@token_override, nil)
  Sigma.instance_variable_set(:@minted_at, nil)
  Sigma.instance_variable_set(:@refresh_inflight, false)
end

# Stub the mint: no network, deterministic tokens.
$mints = 0
module Sigma
  def self.refresh_token!
    $mints += 1
    tok = "minted-#{$mints}"
    now = Time.now
    @token_mutex.synchronize do
      @token_override = tok
      @minted_at = now
    end
    ENV['SIGMA_API_TOKEN'] = tok
    ENV['SIGMA_TOKEN_MINTED_AT'] = now.utc.iso8601
    tok
  end
end

def http_res(klass, code, body)
  res = klass.new('1.1', code.to_s, 'msg')
  res.instance_variable_set(:@body, body)
  res.instance_variable_set(:@read, true)
  res
end

# Injectable fake for Sigma.request(..., http:) — records requests, replays a
# queued response per call.
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

puts 'test-sigma-rest-pagination.rb — list_entries pagination + mint-once-per-TTL wiring'

# 1. A 2-page stubbed response is FULLY consumed, with limit=1000 on every
#    request and the opaque nextPage token echoed back URL-encoded.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
http = FakeHttp.new([
  http_res(Net::HTTPOK, 200, JSON.generate('entries' => [{ 'label' => 'A' }, { 'label' => 'B' }],
                                           'nextPage' => 'tok 2/x')),
  http_res(Net::HTTPOK, 200, JSON.generate('entries' => [{ 'label' => 'C' }]))
])
out = Sigma.list_entries('/v2/workbooks/wb-1/columns', http: http)
check(out.map { |e| e['label'] } == %w[A B C],
      'list_entries consumes BOTH pages of a 2-page response (no silent truncation)', fails)
check(http.reqs.length == 2 &&
        http.reqs[0].path == '/v2/workbooks/wb-1/columns?limit=1000' &&
        http.reqs[1].path == '/v2/workbooks/wb-1/columns?limit=1000&page=tok+2%2Fx',
      'every page request carries limit=1000; the nextPage token rides back URL-encoded', fails)

# 2. A path that already has a query string gets & (not a second ?).
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
http = FakeHttp.new([http_res(Net::HTTPOK, 200, JSON.generate('entries' => []))])
Sigma.list_entries('/v2/files?typeFilters=folder', http: http)
check(http.reqs.first.path == '/v2/files?typeFilters=folder&limit=1000',
      'an existing query string is extended with &limit=1000', fails)

# 3. A server that repeats the same nextPage token cannot loop us forever.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
http = FakeHttp.new([
  http_res(Net::HTTPOK, 200, JSON.generate('entries' => [{ 'id' => 1 }], 'nextPage' => 'same')),
  http_res(Net::HTTPOK, 200, JSON.generate('entries' => [{ 'id' => 2 }], 'nextPage' => 'same'))
])
out = Sigma.list_entries('/v2/teams', http: http)
check(out.length == 2 && http.reqs.length == 2,
      'a repeated nextPage token ends the loop defensively (no spin)', fails)

# 4. An empty-string nextPage (some endpoints) ends the loop like nil.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
http = FakeHttp.new([
  http_res(Net::HTTPOK, 200, JSON.generate('entries' => [{ 'id' => 1 }], 'nextPage' => ''))
])
out = Sigma.list_entries('/v2/teams', http: http)
check(out.length == 1 && http.reqs.length == 1,
      'an empty nextPage ends the loop (single page)', fails)

# --- orchestrator wiring pins (migrate-tableau.rb): mint-once-per-TTL +
#     paginated list reads through the shared lib ----------------------------
src = File.read(File.expand_path('migrate-tableau.rb', __dir__), encoding: 'UTF-8')
destination_src = File.read(
  File.expand_path('lib/destination_resolver.rb', __dir__), encoding: 'UTF-8'
)
check(src =~ /def sigma_token!.*?Sigma\.token_minted_at\.nil\? \|\| Sigma\.token_stale\?.*?Sigma\.refresh_token!/m,
      'sigma_token! reuses a fresh-stamped token and mints only when stale/unknown (once per TTL, not per child)', fails)
check(src.scan("'SIGMA_TOKEN_MINTED_AT' => ENV['SIGMA_TOKEN_MINTED_AT']").size == 2,
      'both Sigma child-spawn wrappers pass the mint stamp so children age the token correctly', fails)
check(src.include?('TABLEAU_ENV_TTL_SECONDS') && src.include?('$tableau_env_cache'),
      'tableau_env reuses the signin within a TTL window instead of re-signing per child', fails)
check(src.scan('Sigma.list_entries(').size +
        destination_src.scan('api.list_entries(').size == 5 &&
        !src.match?(%r{Sigma\.request\(:get, "/v2/(?:workbooks|dataModels)/[^"]*/columns"\)}),
      'all five orchestrator list reads (including My Documents fallbacks) paginate via list_entries', fails)

puts
if fails.empty?
  puts 'ALL PASS — list_entries pagination + mint-once-per-TTL wiring behave correctly'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
