#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline contract test for lib/sigma_rest.rb — the Ruby twin of
# test_sigma_rest.py. Creds-free, network-free: the token exchange is stubbed
# (no live mint) and requests go through the `http:` injection seam.
#
# Covers the token-FRESHNESS semantics added for the stale-token field failure
# (401s at ~+25min-past-expiry because auth_token kept returning the stale env
# token):
#   - fresh/stale/age-unknown token handling in auth_token
#   - refresh_token! stamping minted-at (in-memory + SIGMA_TOKEN_MINTED_AT)
#   - auth.json mtime as the mint stamp
#   - request(): 401 → re-mint once → retry, then fail loudly
#
# Usage: ruby scripts/test-sigma-rest.rb

require 'json'
require 'time'
require 'tmpdir'
require 'net/http'
require_relative 'lib/sigma_rest'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# --- test harness ----------------------------------------------------------

ENV_KEYS = %w[SIGMA_BASE_URL SIGMA_CLIENT_ID SIGMA_CLIENT_SECRET
              SIGMA_API_TOKEN SIGMA_TOKEN_MINTED_AT SIGMA_WORKDIR
              SIGMA_ALLOW_INSECURE_BASE_URL].freeze

# The library's load-time bootstrap may have pulled real creds from
# ~/.sigma-migration/env or ./auth.json — scrub them so every case starts clean
# and nothing here can reach a live API.
def reset_state!
  ENV_KEYS.each { |k| ENV.delete(k) }
  Sigma.instance_variable_set(:@token_override, nil)
  Sigma.instance_variable_set(:@minted_at, nil)
  Sigma.instance_variable_set(:@refresh_inflight, false)
  Sigma.instance_variable_set(:@validated_bases, nil)
  # Fake host (https://sigma.example): bypass the A2 host allowlist so these
  # cases exercise the auth/HTTP seam; A2 itself is covered by case 14.
  ENV['SIGMA_ALLOW_INSECURE_BASE_URL'] = '1'
end

# Stub the mint: no network, deterministic tokens, same state effects as the
# real exchange (override + minted_at + env surfacing).
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

puts 'test-sigma-rest.rb — token freshness + 401 re-mint contract'

# 1. No token anywhere → auth_token mints.
reset_state!
ENV['SIGMA_CLIENT_ID'] = 'id'
before = $mints
tok = Sigma.auth_token
check(tok == "minted-#{before + 1}" && $mints == before + 1,
      'no token anywhere → auth_token mints one', fails)

# 2. Age-unknown env token → honored as-is (no proactive mint).
reset_state!
ENV['SIGMA_CLIENT_ID'] = 'id'
ENV['SIGMA_API_TOKEN'] = 'unknownage'
before = $mints
check(Sigma.auth_token == 'unknownage' && $mints == before,
      'age-unknown env token honored as-is', fails)

# 3. Fresh stamped token → returned, no mint.
reset_state!
ENV['SIGMA_CLIENT_ID'] = 'id'
ENV['SIGMA_API_TOKEN'] = 'youngtok'
ENV['SIGMA_TOKEN_MINTED_AT'] = (Time.now - 300).utc.iso8601
before = $mints
check(Sigma.auth_token == 'youngtok' && $mints == before,
      'fresh stamped token returned without mint', fails)

# 4. Stale stamped token + creds → re-minted proactively.
reset_state!
ENV['SIGMA_CLIENT_ID'] = 'id'
ENV['SIGMA_API_TOKEN'] = 'oldtok'
ENV['SIGMA_TOKEN_MINTED_AT'] = (Time.now - (Sigma::TOKEN_TTL_SECONDS + 60)).utc.iso8601
before = $mints
tok = Sigma.auth_token
check(tok == "minted-#{before + 1}" && $mints == before + 1,
      'stale stamped token + creds → proactive re-mint', fails)

# 5. Stale stamp but NO creds → stale token returned (401 path handles it).
reset_state!
ENV['SIGMA_API_TOKEN'] = 'oldtok'
ENV['SIGMA_TOKEN_MINTED_AT'] = (Time.now - (Sigma::TOKEN_TTL_SECONDS + 60)).utc.iso8601
before = $mints
check(Sigma.auth_token == 'oldtok' && $mints == before,
      'stale stamp without creds → token returned as-is (no mint attempt)', fails)

# 6. Garbage stamp → treated as age-unknown.
reset_state!
ENV['SIGMA_CLIENT_ID'] = 'id'
ENV['SIGMA_API_TOKEN'] = 'tok'
ENV['SIGMA_TOKEN_MINTED_AT'] = 'not-a-timestamp'
before = $mints
check(Sigma.auth_token == 'tok' && $mints == before,
      'unparseable stamp treated as age-unknown', fails)

# 7. Stale IN-MEMORY mint → re-minted.
reset_state!
ENV['SIGMA_CLIENT_ID'] = 'id'
Sigma.instance_variable_set(:@token_override, 'mintedlongago')
Sigma.instance_variable_set(:@minted_at, Time.now - (Sigma::TOKEN_TTL_SECONDS + 60))
before = $mints
tok = Sigma.auth_token
check(tok == "minted-#{before + 1}",
      'stale in-memory mint → proactive re-mint', fails)

# 8. refresh_token! stamps mint time (in-memory + env) and reads FRESH.
reset_state!
ENV['SIGMA_CLIENT_ID'] = 'id'
Sigma.refresh_token!
check(!Sigma.token_minted_at.nil? && !Sigma.token_stale? &&
        !ENV['SIGMA_TOKEN_MINTED_AT'].to_s.empty?,
      'refresh_token! stamps minted-at (memory + SIGMA_TOKEN_MINTED_AT) and reads fresh', fails)

# 9. auth.json mtime becomes the mint stamp (load-time bootstrap, subprocess —
#    the bootstrap runs at require time).
Dir.mktmpdir do |d|
  File.write(File.join(d, 'auth.json'),
             JSON.generate('SIGMA_API_TOKEN' => 'filetok', 'SIGMA_BASE_URL' => 'https://sigma.example'))
  old = Time.now - (Sigma::TOKEN_TTL_SECONDS + 300)
  File.utime(old, old, File.join(d, 'auth.json'))
  lib = File.expand_path('lib/sigma_rest', __dir__)
  script = 'puts ENV.fetch("SIGMA_TOKEN_MINTED_AT", "MISSING"); puts Sigma.token_stale?'
  env = { 'SIGMA_WORKDIR' => d, 'SIGMA_API_TOKEN' => nil, 'SIGMA_TOKEN_MINTED_AT' => nil }
  out = IO.popen(env, ['ruby', '-r', lib, '-e', script], &:read)
  st = $?.exitstatus
  lines = out.to_s.split("\n")
  check(st == 0 && lines[0] != 'MISSING' && lines[1] == 'true',
        "auth.json mtime becomes the mint stamp; 50min-old file reads STALE (got #{lines.inspect})", fails)
end

# 10. request(): 401 → re-mint ONCE → retry with the fresh bearer.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_CLIENT_ID'] = 'id'
ENV['SIGMA_API_TOKEN'] = 'staletok'
http = FakeHttp.new([
  http_res(Net::HTTPUnauthorized, 401, 'unauthorized'),
  http_res(Net::HTTPOK, 200, '{"ok":true}')
])
before = $mints
out = Sigma.request(:get, '/v2/x', http: http)
check(out == { 'ok' => true } && $mints == before + 1 &&
        http.reqs.last['Authorization'] == "Bearer minted-#{before + 1}",
      '401 → re-mint once → retry with fresh bearer', fails)

# 11. request(): second 401 after the re-mint → fail loudly.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_CLIENT_ID'] = 'id'
ENV['SIGMA_API_TOKEN'] = 'staletok'
http = FakeHttp.new([
  http_res(Net::HTTPUnauthorized, 401, 'unauthorized'),
  http_res(Net::HTTPUnauthorized, 401, 'still unauthorized')
])
raised = false
begin
  Sigma.request(:get, '/v2/x', http: http)
rescue Sigma::Error => e
  raised = e.message.include?('401')
end
check(raised, 'second 401 after re-mint raises Sigma::Error (fail loudly)', fails)

# 12. request(): 401 with NO creds → no retry, immediate loud failure.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_API_TOKEN'] = 'tok'
http = FakeHttp.new([http_res(Net::HTTPUnauthorized, 401, 'unauthorized')])
raised = false
begin
  Sigma.request(:get, '/v2/x', http: http)
rescue Sigma::Error
  raised = true
end
check(raised && http.reqs.length == 1,
      '401 without client creds → no retry, loud failure', fails)

# 13. Stale token + request() → proactive re-mint means NO 401 roundtrip.
reset_state!
ENV['SIGMA_BASE_URL'] = 'https://sigma.example'
ENV['SIGMA_CLIENT_ID'] = 'id'
ENV['SIGMA_API_TOKEN'] = 'oldtok'
ENV['SIGMA_TOKEN_MINTED_AT'] = (Time.now - (Sigma::TOKEN_TTL_SECONDS + 60)).utc.iso8601
http = FakeHttp.new([http_res(Net::HTTPOK, 200, '{"ok":1}')])
before = $mints
out = Sigma.request(:get, '/v2/x', http: http)
check(out == { 'ok' => 1 } && $mints == before + 1 && http.reqs.length == 1 &&
        http.reqs.first['Authorization'] == "Bearer minted-#{before + 1}",
      'stale token re-minted BEFORE the request (single roundtrip, fresh bearer)', fails)

# 14. A2 on the request path: a pre-minted token skips the token exchange, so
# request() itself must refuse a non-Sigma SIGMA_BASE_URL before any bearer
# token goes out.
reset_state!
ENV.delete('SIGMA_ALLOW_INSECURE_BASE_URL')
ENV['SIGMA_BASE_URL'] = 'https://evil.example'
ENV['SIGMA_API_TOKEN'] = 'pre-minted'
http = FakeHttp.new([http_res(Net::HTTPOK, 200, '{"ok":1}')])
refused = false
begin
  Sigma.request(:get, '/v2/x', http: http)
rescue SystemExit
  refused = true
end
check(refused && http.reqs.empty?,
      'request() refuses a non-Sigma SIGMA_BASE_URL with a pre-minted token (no bearer sent)', fails)

puts
if fails.empty?
  puts 'ALL PASS — sigma_rest token freshness + 401 re-mint behave correctly'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
