# Sigma REST API wrapper with automatic 401 retry + token refresh.
#
# Sigma OAuth bearer tokens expire after ~1 hour. Long-running scripts (a
# 30-min conversion, an hour+ batch orchestration, an assessment readout)
# routinely outlive a single token and would otherwise fail mid-run.
#
# This module mirrors the shape of `tableau_rest.rb`. It provides:
#   - `Sigma.refresh_token!`         — re-do client_credentials exchange,
#                                       update in-memory token under a mutex
#   - `Sigma.request(method, path)`  — catches 401, refreshes once, retries
#
# Required env: SIGMA_BASE_URL, SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET.
# Optional env: SIGMA_API_TOKEN (initial token; refreshed on demand).
#
# Usage:
#   require_relative 'lib/sigma_rest'
#   wb = Sigma.request(:get, "/v2/workbooks/#{id}")
#   Sigma.request(:post, '/v2/workbooks/spec', body: spec.to_json)
#
# All methods return parsed Hash/Array (or raw bytes for binary endpoints).

require 'net/http'
require 'uri'
require 'json'
require 'base64'

# Agent-neutral credential bootstrap. Claude Code injects creds from
# ~/.claude/settings.json into the env automatically; other agents (Cursor,
# Cortex Code, plain shell) don't. If the Sigma creds aren't in ENV yet, load
# them from the neutral cred file written by setup.rb. Existing env always wins.
_neutral_env = File.expand_path('~/.sigma-migration/env')
if ENV['SIGMA_CLIENT_ID'].nil? && File.exist?(_neutral_env)
  File.foreach(_neutral_env) do |line|
    next unless (m = line.chomp.match(/\A\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)\z/))
    key, raw = m[1], m[2].strip
    raw = raw[1..-2] if raw.length >= 2 &&
      ((raw.start_with?("'") && raw.end_with?("'")) || (raw.start_with?('"') && raw.end_with?('"')))
    ENV[key] ||= raw
  end
end

# File-based token handoff (shell-neutral, kills the `eval "$(get-token.sh)"`
# bash idiom that PowerShell/cmd cannot run). scripts/get_token.py writes
# <WORK>/auth.json = {"SIGMA_API_TOKEN": ..., "SIGMA_BASE_URL": ...}. Read it
# here so any shell/agent can mint once (python) and every downstream Ruby
# script picks the token up. Precedence: explicit env ALWAYS wins → auth.json →
# (later) client-credential self-mint via refresh_token!. auth.json is
# .gitignored and holds a live bearer token — never print it.
if ENV['SIGMA_API_TOKEN'].nil?
  _auth_candidates = [ENV['SIGMA_WORKDIR'], Dir.pwd].compact
                        .map { |d| File.join(d, 'auth.json') }
  _auth_path = _auth_candidates.find { |p| File.exist?(p) }
  if _auth_path
    begin
      _auth = JSON.parse(File.read(_auth_path, encoding: 'bom|utf-8'))
      ENV['SIGMA_API_TOKEN'] ||= _auth['SIGMA_API_TOKEN'] if _auth['SIGMA_API_TOKEN']
      ENV['SIGMA_BASE_URL']  ||= _auth['SIGMA_BASE_URL']  if _auth['SIGMA_BASE_URL']
    rescue JSON::ParserError
      # A corrupt auth.json must not wedge the run — fall through to self-mint.
    end
  end
end

module Sigma
  class Error < StandardError; end
  class AuthError < Error; end

  @token_mutex = Mutex.new
  @token_override = nil
  @refresh_inflight = false

  module_function

  def base_url
    ENV.fetch('SIGMA_BASE_URL') { raise Error, 'SIGMA_BASE_URL not set' }
  end

  def auth_token
    @token_mutex.synchronize { @token_override } || ENV['SIGMA_API_TOKEN'] || refresh_token!
  end

  # Re-do the OAuth client_credentials exchange and store the new token.
  # Thread-safe and single-flight: concurrent callers all wait for one
  # exchange and share the result. Returns the new token.
  def refresh_token!
    @token_mutex.synchronize do
      return @token_override if @refresh_inflight
      @refresh_inflight = true
    end
    begin
      cid    = ENV.fetch('SIGMA_CLIENT_ID')     { raise AuthError, 'SIGMA_CLIENT_ID not set' }
      secret = ENV.fetch('SIGMA_CLIENT_SECRET') { raise AuthError, 'SIGMA_CLIENT_SECRET not set' }
      creds = Base64.strict_encode64("#{cid}:#{secret}")
      uri = URI("#{base_url}/v2/auth/token")
      req = Net::HTTP::Post.new(uri)
      req['Authorization'] = "Basic #{creds}"
      req['Content-Type']  = 'application/x-www-form-urlencoded'
      req.body = 'grant_type=client_credentials'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
      raise AuthError, "token exchange -> #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
      tok = JSON.parse(res.body)['access_token']
      raise AuthError, "token exchange returned no access_token: #{res.body}" if tok.nil? || tok.empty?
      @token_mutex.synchronize { @token_override = tok }
      # Surface the refreshed token to child processes / shell evals.
      ENV['SIGMA_API_TOKEN'] = tok
      tok
    ensure
      @token_mutex.synchronize { @refresh_inflight = false }
    end
  end

  def request(method, path, body: nil, content_type: 'application/json', accept: 'application/json', binary: false, http: nil)
    uri = URI("#{base_url}#{path}")
    attempts = 0
    loop do
      attempts += 1
      req = case method
            when :get    then Net::HTTP::Get.new(uri)
            when :post   then Net::HTTP::Post.new(uri)
            when :put    then Net::HTTP::Put.new(uri)
            when :patch  then Net::HTTP::Patch.new(uri)
            when :delete then Net::HTTP::Delete.new(uri)
            else raise ArgumentError, "unsupported method #{method}"
            end
      req['Authorization'] = "Bearer #{auth_token}"
      req['Accept']        = accept
      if body
        req['Content-Type'] = content_type
        req.body = body
      end

      res = if http
              http.request(req)
            else
              Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) { |h| h.request(req) }
            end

      # Sigma returns 401 with code:"unauthorized" when the bearer expires.
      # Refresh once and retry; on a second 401, surface the error.
      if res.code.to_i == 401 && attempts == 1 && ENV['SIGMA_CLIENT_ID']
        refresh_token!
        next
      end
      unless res.is_a?(Net::HTTPSuccess)
        raise Error, "#{method.upcase} #{path} -> #{res.code} #{res.message}\n#{res.body}"
      end
      return res.body if binary
      return res.body unless accept == 'application/json'
      return res.body.empty? ? nil : JSON.parse(res.body)
    end
  end
end
