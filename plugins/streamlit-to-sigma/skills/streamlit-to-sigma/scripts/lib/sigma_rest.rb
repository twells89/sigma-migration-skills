# Sigma REST API wrapper with automatic 401 retry + token refresh.
#
# Sigma OAuth bearer tokens expire after ~1 hour. Long-running scripts (a
# 30-min conversion, an hour+ batch orchestration, an assessment readout)
# routinely outlive a single token and would otherwise fail mid-run.
#
# This module mirrors the shape of `tableau_rest.rb`. It provides:
#   - `Sigma.refresh_token!`         — re-do client_credentials exchange,
#                                       update in-memory token under a mutex
#   - `Sigma.auth_token`             — age-aware: re-mints automatically when
#                                       the token is older than TOKEN_TTL_SECONDS
#   - `Sigma.request(method, path)`  — catches 401, refreshes once, retries
#
# Token-freshness semantics (field lesson: sessions repeatedly hit 401s at
# ~+25min-past-expiry because `auth_token` kept returning the stale env token):
#   - A token minted by THIS process carries an in-memory minted_at stamp; when
#     it ages past TOKEN_TTL_SECONDS (50 min), auth_token re-mints proactively.
#   - The mint time is also surfaced as SIGMA_TOKEN_MINTED_AT (iso8601) so
#     child processes inherit the token's AGE along with the token itself.
#   - A token loaded from <WORK>/auth.json is aged by the file's mtime
#     (get_token.py writes it at mint time, so mtime == mint time).
#   - A bare env SIGMA_API_TOKEN with no known age is honored as-is
#     (age-unknown) — the request helper's 401 handler re-mints ONCE and
#     retries, then fails loudly.
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
require 'time'

# Agent-neutral credential bootstrap. Claude Code injects creds from
# ~/.claude/settings.json into the env automatically; other agents (Cursor,
# Cortex Code, plain shell) don't. If the Sigma creds aren't in ENV yet, load
# them from the neutral cred file written by setup.rb. Existing env always wins.
_neutral_env = File.expand_path('~/.sigma-migration/env')
if ENV['SIGMA_CLIENT_ID'].nil? && File.exist?(_neutral_env)
  File.foreach(_neutral_env, encoding: 'UTF-8') do |line|
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
      if _auth['SIGMA_API_TOKEN']
        ENV['SIGMA_API_TOKEN'] ||= _auth['SIGMA_API_TOKEN']
        # get_token.py writes auth.json at mint time, so the file's mtime IS
        # the token's mint time — record it so auth_token can age the token
        # out proactively instead of discovering staleness via a mid-phase 401.
        ENV['SIGMA_TOKEN_MINTED_AT'] ||= File.mtime(_auth_path).utc.iso8601
      end
      ENV['SIGMA_BASE_URL'] ||= _auth['SIGMA_BASE_URL'] if _auth['SIGMA_BASE_URL']
    rescue JSON::ParserError
      # A corrupt auth.json must not wedge the run — fall through to self-mint.
    end
  end
end

module Sigma
  class Error < StandardError; end
  class AuthError < Error; end

  # Sigma bearer tokens live ~60 minutes. Any token older than this is treated
  # as stale and re-minted proactively (50 min leaves a safety margin), so long
  # phases stop tripping over mid-run 401s from a token that quietly expired.
  TOKEN_TTL_SECONDS = 50 * 60

  @token_mutex = Mutex.new
  @token_override = nil
  @minted_at = nil
  @refresh_inflight = false

  module_function

  def base_url
    ENV.fetch('SIGMA_BASE_URL') { raise Error, 'SIGMA_BASE_URL not set' }
  end

  # Security (A2): only transmit Sigma credentials to an https://
  # sigmacomputing.com host. A poisoned SIGMA_BASE_URL would otherwise
  # exfiltrate the client id/secret. Opt out (self-hosted/dev) with
  # SIGMA_ALLOW_INSECURE_BASE_URL=1 (loud warning).
  def self.validate_base_url!(base)
    if ENV['SIGMA_ALLOW_INSECURE_BASE_URL'] == '1'
      warn "WARNING: SIGMA_ALLOW_INSECURE_BASE_URL=1 — skipping SIGMA_BASE_URL validation (#{base})"; return
    end
    u = (URI.parse(base) rescue nil); host = u&.host&.downcase
    abort "FATAL: SIGMA_BASE_URL must use https:// (got '#{base}') — refusing to send Sigma credentials." unless u&.scheme == 'https'
    abort "FATAL: SIGMA_BASE_URL host '#{host}' is not a sigmacomputing.com host — refusing to send Sigma credentials. Set SIGMA_ALLOW_INSECURE_BASE_URL=1 to override." unless host == 'sigmacomputing.com' || host&.end_with?('.sigmacomputing.com')
  end

  # Return a token that is safe to use RIGHT NOW.
  #   - No token anywhere → mint one.
  #   - Known mint time (this process minted it, a parent surfaced
  #     SIGMA_TOKEN_MINTED_AT, or auth.json's mtime) and age > TTL → re-mint
  #     (requires SIGMA_CLIENT_ID; without creds the stale token is returned
  #     and the 401 path surfaces the failure loudly).
  #   - Age unknown (bare env SIGMA_API_TOKEN) → honored as-is; the request
  #     helper's 401 handler re-mints once and retries.
  def auth_token
    tok = @token_mutex.synchronize { @token_override } || ENV['SIGMA_API_TOKEN']
    return refresh_token! if tok.nil? || tok.empty?
    return refresh_token! if token_stale? && ENV['SIGMA_CLIENT_ID']
    tok
  end

  # When the current token was minted, if known. The in-memory stamp (set by
  # refresh_token! in this process) wins; else SIGMA_TOKEN_MINTED_AT (iso8601,
  # set by a parent process's mint or by the auth.json bootstrap from mtime).
  # nil = age unknown.
  def token_minted_at
    m = @token_mutex.synchronize { @minted_at }
    return m if m
    ts = ENV['SIGMA_TOKEN_MINTED_AT'].to_s
    return nil if ts.empty?
    begin
      Time.parse(ts)
    rescue ArgumentError
      nil
    end
  end

  def token_stale?
    minted = token_minted_at
    !minted.nil? && (Time.now - minted) > TOKEN_TTL_SECONDS
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
      Sigma.validate_base_url!(base_url)
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
      now = Time.now
      @token_mutex.synchronize do
        @token_override = tok
        @minted_at = now
      end
      # Surface the refreshed token — and its mint time, so child processes
      # inherit the token's AGE and re-mint on schedule too — to child
      # processes / shell evals.
      ENV['SIGMA_API_TOKEN'] = tok
      ENV['SIGMA_TOKEN_MINTED_AT'] = now.utc.iso8601
      tok
    ensure
      @token_mutex.synchronize { @refresh_inflight = false }
    end
  end

  # Exhaustively read a paginated LIST endpoint: GET `path` with limit=1000
  # (the documented API maximum; the server default is 50) and follow
  # `nextPage` tokens until exhausted, returning the concatenated `entries`.
  # Unpaginated single-page responses reached END OF SUPPORT on 2026-06-02 —
  # a bare first-page GET now silently truncates at the default page size
  # (field case: a 599-column workbook whose error-column audit saw only the
  # first page). `path` may already carry a query string. The nextPage token
  # is opaque (URL-encoded on reuse); a repeated token or a non-Hash body ends
  # the loop defensively rather than spinning — and the repeated-token stop
  # names itself on stderr, because a silent defensive stop is invisible
  # truncation, the exact bug class this helper exists to remove.
  #
  # An optional block receives each page's parsed body as it arrives; callers
  # use it for page-level observability (e.g. announcing a multi-page fetch on
  # stderr) without re-implementing the loop.
  # Sigma's list endpoints use TWO different pagination conventions, and the
  # cursor field name and the query-param name must be matched as a PAIR:
  #   `nextPage`      -> send back as `page=`        (most /v2 list endpoints)
  #   `nextPageToken` -> send back as `pageToken=`   (e.g. the columns endpoint,
  #                                                   /v2/connections/tables/{inodeId}/columns)
  # Handling only the first convention is a SILENT TRUNCATION, not an error: the
  # second-convention endpoints simply never expose `nextPage`, so the loop ends
  # after page 1 and returns exactly the server's default page size (50) with no
  # warning. Measured live on a real 149-column table: 50 of 149 columns
  # returned, which surfaced downstream as 99 phantom "missing" columns in the
  # domo column pre-flight — and, far worse, would let assert-phase6-ran.rb's
  # error-column audit inspect only the first 50 columns of a wide table and
  # still report clean (bead 0h11; same class as bf1f, different endpoint).
  # Mixing the pair is its own trap: feeding a `nextPageToken` back as `page=`
  # makes the server re-serve page 1 forever, so the repeated-cursor guard below
  # is what keeps a half-fix from becoming an infinite loop.
  def list_entries(path, limit: 1000, http: nil)
    entries = []
    cursor = nil
    cursor_param = nil
    seen = {}
    pages = 0
    loop do
      qs = "limit=#{limit.to_i}"
      qs += "&#{cursor_param}=#{URI.encode_www_form_component(cursor)}" if cursor
      data = request(:get, "#{path}#{path.include?('?') ? '&' : '?'}#{qs}", http: http)
      break unless data.is_a?(Hash)
      pages += 1
      yield data if block_given?
      entries.concat(data['entries'] || [])

      # Read whichever cursor this endpoint actually returned, and remember the
      # param it must be sent back as.
      if !data['nextPage'].nil? && !data['nextPage'].to_s.empty?
        cursor = data['nextPage']
        cursor_param = 'page'
      elsif !data['nextPageToken'].nil? && !data['nextPageToken'].to_s.empty?
        cursor = data['nextPageToken']
        cursor_param = 'pageToken'
      else
        break
      end

      if seen[cursor]
        warn "#{path}: server repeated #{cursor_param} cursor #{cursor.inspect} — " \
             "stopping after #{pages} page(s) to avoid an infinite loop (list may be incomplete)"
        break
      end
      seen[cursor] = true
    end
    entries
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
