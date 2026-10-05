# Sigma REST API wrapper with automatic 401 retry + token refresh.
#
# Sigma OAuth bearer tokens expire after ~1 hour. Long-running scripts (a
# 30-min conversion, an hour+ batch orchestration, an assessment readout)
# routinely outlive a single token and would otherwise fail mid-run.
#
# This module mirrors the shape of `tableau_rest.rb`. It provides:
#   - `Sigma.refresh_token!`         — invoke sigma-api's browser-first token
#                                       provider and update the in-memory token
#   - `Sigma.request(method, path)`  — refreshes known 50-minute-old tokens,
#                                       catches 401, refreshes once, retries
#
# Required env: SIGMA_BASE_URL.
# Optional env: SIGMA_API_TOKEN (initial token), browser-login keychain state,
# SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET fallback, and SIGMA_AUTH_MODE.
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
require 'open3'
require 'time'

# File-based token handoff (shell-neutral, kills the `eval "$(get-token.sh)"`
# bash idiom that PowerShell/cmd cannot run). scripts/get_token.py writes
# <WORK>/auth.json includes SIGMA_API_TOKEN, SIGMA_BASE_URL, and mint metadata.
# Read it
# here so any shell/agent can mint once (python) and every downstream Ruby
# script picks the token up. Precedence: explicit env ALWAYS wins → auth.json →
# (below) sigma-api provider mint via refresh_token!. auth.json should be kept
# out of version control — it holds a live bearer token, never print it.
if ENV['SIGMA_API_TOKEN'].nil?
  _auth_candidates = [ENV['SIGMA_WORKDIR'], Dir.pwd].compact
                        .map { |d| File.join(d, 'auth.json') }
  _auth_path = _auth_candidates.find { |p| File.exist?(p) }
  if _auth_path
    begin
      _auth = JSON.parse(File.read(_auth_path, encoding: 'bom|utf-8'))
      ENV['SIGMA_API_TOKEN'] ||= _auth['SIGMA_API_TOKEN'] if _auth['SIGMA_API_TOKEN']
      ENV['SIGMA_BASE_URL']  ||= _auth['SIGMA_BASE_URL']  if _auth['SIGMA_BASE_URL']
      ENV['SIGMA_TOKEN_MINTED_AT'] ||= _auth['SIGMA_TOKEN_MINTED_AT'] if _auth['SIGMA_TOKEN_MINTED_AT']
      ENV['SIGMA_AUTH_METHOD'] ||= _auth['SIGMA_AUTH_METHOD'] if _auth['SIGMA_AUTH_METHOD']
    rescue JSON::ParserError
      # A corrupt auth.json must not wedge the run — fall through to self-mint.
    end
  end
end

module Sigma
  class Error < StandardError; end
  class AuthError < Error; end

  TOKEN_REFRESH_AGE_SECONDS = 50 * 60

  @token_mutex = Mutex.new
  @token_override = nil
  @refresh_inflight = false

  module_function

  def base_url
    ENV.fetch('SIGMA_BASE_URL') { raise Error, 'SIGMA_BASE_URL not set' }
  end

  def token_refresh_due?(now: Time.now)
    minted_at = ENV['SIGMA_TOKEN_MINTED_AT']
    return false if minted_at.nil? || minted_at.empty?

    now >= Time.iso8601(minted_at) + TOKEN_REFRESH_AGE_SECONDS
  rescue ArgumentError
    # Caller-provided tokens predate mint metadata and malformed metadata is
    # not trustworthy enough to discard a potentially valid token.
    false
  end

  def auth_token
    token = @token_mutex.synchronize { @token_override } || ENV['SIGMA_API_TOKEN']
    return refresh_token! if token.nil? || token.empty?
    return refresh_token! if token_refresh_due?

    token
  end

  # Invoke sigma-api's canonical dual-mode provider. It checks the browser
  # keychain first in auto mode, then falls back to client credentials, and
  # verifies the result with redirect-disabled /v2/whoami. If Python is
  # unavailable, get-token.sh retains the safe client-credential fallback.
  # Returns all emitted mint metadata without eval'ing shell output.
  def token_provider_result
    provider_paths = [
      ENV['SIGMA_TOKEN_PROVIDER'],
      File.expand_path('../get_token.py', __dir__),
      File.expand_path('../../../sigma-api/scripts/get_token.py', __dir__)
    ].compact
    provider = provider_paths.find { |path| File.file?(path) }
    raise AuthError, 'sigma-api get_token.py provider not found' unless provider

    python_commands = []
    python_commands << [ENV['SIGMA_PYTHON']] unless ENV['SIGMA_PYTHON'].to_s.empty?
    python_commands.concat([['python3'], ['python'], ['py', '-3']])
    output = error = status = nil
    python_commands.each do |command|
      begin
        output, error, status = Open3.capture3(*command, provider, '--print-export')
      rescue Errno::ENOENT
        next
      end
      break
    end

    if status.nil?
      shell_paths = [
        File.expand_path('../get-token.sh', __dir__),
        File.expand_path('../../../sigma-api/scripts/get-token.sh', __dir__)
      ]
      shell = shell_paths.find { |path| File.file?(path) }
      raise AuthError, 'Python and sigma-api get-token.sh are unavailable' unless shell
      begin
        output, error, status = Open3.capture3('bash', shell)
      rescue Errno::ENOENT
        raise AuthError, 'Python and bash are unavailable; cannot refresh the Sigma token'
      end
    end

    unless status.success?
      detail = error.to_s.strip
      raise AuthError, "Sigma token provider failed#{detail.empty? ? '' : ": #{detail}"}"
    end

    values = {}
    output.each_line do |line|
      match = line.chomp.match(/\Aexport (SIGMA_API_TOKEN|SIGMA_TOKEN_MINTED_AT|SIGMA_AUTH_METHOD)=([A-Za-z0-9._~+\/=:-]+)\z/)
      values[match[1]] = match[2] if match
    end
    required = %w[SIGMA_API_TOKEN SIGMA_TOKEN_MINTED_AT SIGMA_AUTH_METHOD]
    missing = required.reject { |key| values[key] && !values[key].empty? }
    raise AuthError, "Sigma token provider omitted #{missing.join(', ')}" unless missing.empty?

    values
  end

  # Thread-safe and single-flight: concurrent callers all wait for one provider
  # invocation and share the result. Returns the new access token.
  def refresh_token!
    @token_mutex.synchronize do
      return @token_override if @refresh_inflight
      @refresh_inflight = true
    end
    begin
      values = token_provider_result
      tok = values.fetch('SIGMA_API_TOKEN')
      @token_mutex.synchronize { @token_override = tok }
      values.each { |key, value| ENV[key] = value }
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
      if res.code.to_i == 401 && attempts == 1
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
