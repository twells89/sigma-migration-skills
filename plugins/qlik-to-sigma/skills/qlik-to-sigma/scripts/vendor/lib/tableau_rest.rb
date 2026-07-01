# Tableau REST API wrapper for tableau-to-sigma when the MCP isn't available.
# Requires TABLEAU_SERVER_URL, TABLEAU_SITE_ID, TABLEAU_AUTH_TOKEN, TABLEAU_API_VERSION in ENV
# (set by scripts/get-tableau-token.sh).
#
# All methods return parsed Hash/Array (or raw bytes for view_image). Network/HTTP errors raise
# Tableau::Error with the response body included.

require 'net/http'
require 'uri'
require 'json'
require 'cgi'

# Agent-neutral credential bootstrap. Claude Code injects creds from
# ~/.claude/settings.json into the env automatically; other agents (Cursor,
# Cortex Code, plain shell) don't. If the Tableau PAT creds aren't in ENV yet,
# load them from the neutral cred file written by setup-tableau.rb. Existing
# env always wins.
_neutral_env = File.expand_path('~/.sigma-migration/env')
if ENV['TABLEAU_PAT_SECRET'].nil? && File.exist?(_neutral_env)
  File.foreach(_neutral_env) do |line|
    next unless (m = line.chomp.match(/\A\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)\z/))
    key, raw = m[1], m[2].strip
    raw = raw[1..-2] if raw.length >= 2 &&
      ((raw.start_with?("'") && raw.end_with?("'")) || (raw.start_with?('"') && raw.end_with?('"')))
    ENV[key] ||= raw
  end
end

module Tableau
  class Error < StandardError; end
  class AuthError < Error; end

  @token_mutex = Mutex.new
  @token_override = nil
  @site_id_override = nil

  module_function

  def server_url
    ENV.fetch('TABLEAU_SERVER_URL') { raise Error, 'TABLEAU_SERVER_URL not set — run get-tableau-token.sh' }
  end

  def site_id
    @token_mutex.synchronize { @site_id_override } || ENV.fetch('TABLEAU_SITE_ID') { raise Error, 'TABLEAU_SITE_ID not set — run get-tableau-token.sh' }
  end

  def auth_token
    @token_mutex.synchronize { @token_override } || ENV.fetch('TABLEAU_AUTH_TOKEN') { raise Error, 'TABLEAU_AUTH_TOKEN not set — run get-tableau-token.sh' }
  end

  def api_version
    ENV.fetch('TABLEAU_API_VERSION', '3.22')
  end

  # Re-sign in with the PAT env vars and update the in-memory token. Thread-safe.
  # Long-running scripts (hours) should call this before Tableau's session times
  # out (cloud default: 240 min idle, can be much shorter under strict policies).
  # Single-flight: concurrent callers all wait for one signin and share the result.
  def refresh_token!
    @token_mutex.synchronize do
      return @token_override if @refresh_inflight
      @refresh_inflight = true
    end
    begin
      name = ENV.fetch('TABLEAU_PAT_NAME')   { raise AuthError, 'TABLEAU_PAT_NAME not set — cannot refresh' }
      secret = ENV.fetch('TABLEAU_PAT_SECRET'){ raise AuthError, 'TABLEAU_PAT_SECRET not set — cannot refresh' }
      site_url = ENV.fetch('TABLEAU_SITE_CONTENT_URL') { raise AuthError, 'TABLEAU_SITE_CONTENT_URL not set' }
      uri = URI.join(server_url, "/api/#{api_version}/auth/signin")
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/xml'
      req['Accept'] = 'application/json'
      req.body = %(<tsRequest><credentials personalAccessTokenName="#{name}" personalAccessTokenSecret="#{secret}"><site contentUrl="#{site_url}"/></credentials></tsRequest>)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
      raise AuthError, "signin -> #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
      j = JSON.parse(res.body)
      @token_mutex.synchronize do
        @token_override = j.dig('credentials', 'token')
        @site_id_override = j.dig('credentials', 'site', 'id')
      end
      @token_override
    ensure
      @token_mutex.synchronize { @refresh_inflight = false }
    end
  end

  def base_path
    "/api/#{api_version}/sites/#{site_id}"
  end

  # ---- low-level transport -------------------------------------------------

  def request(method, path, body: nil, content_type: 'application/json', accept: 'application/json', binary: false, http: nil)
    uri = URI.join(server_url, path)
    attempts = 0
    loop do
      attempts += 1
      req = case method
            when :get  then Net::HTTP::Get.new(uri)
            when :post then Net::HTTP::Post.new(uri)
            when :put  then Net::HTTP::Put.new(uri)
            when :delete then Net::HTTP::Delete.new(uri)
            else raise ArgumentError, "unsupported method #{method}"
            end
      req['X-Tableau-Auth'] = auth_token
      req['Accept'] = accept
      if body
        req['Content-Type'] = content_type
        req.body = body
      end

      res = if http
              http.request(req)
            else
              Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 120) { |h| h.request(req) }
            end
      if res.code.to_i == 401 && attempts == 1 && ENV['TABLEAU_PAT_NAME']
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

  # ---- workbooks -----------------------------------------------------------

  # Returns the first workbook matching name, or nil. Use search_workbooks for full list.
  def find_workbook_by_name(name)
    encoded = CGI.escape("name:eq:#{name}")
    j = request(:get, "#{base_path}/workbooks?filter=#{encoded}")
    list = j.dig('workbooks', 'workbook') || []
    list = [list] unless list.is_a?(Array)
    list.first
  end

  def get_workbook(workbook_id)
    request(:get, "#{base_path}/workbooks/#{workbook_id}")['workbook']
  end

  # Returns the raw .twb XML (string) or .twbx bytes for workbooks with embedded extracts.
  # Embedded check: if the response starts with PK\x03\x04 it's a zip (twbx); otherwise raw XML.
  def download_workbook_content(workbook_id, include_extract: false)
    qs = include_extract ? '' : '?includeExtract=false'
    request(:get, "#{base_path}/workbooks/#{workbook_id}/content#{qs}",
            accept: '*/*', binary: true)
  end

  # ---- views ---------------------------------------------------------------

  def view_data(view_id)
    request(:get, "#{base_path}/views/#{view_id}/data", accept: '*/*')
  end

  def view_image(view_id, width: 1400, height: 900, resolution: 'high')
    qs = "?resolution=#{resolution}&maxAge=1"
    qs += "&vf_width=#{width}&vf_height=#{height}" if width && height
    request(:get, "#{base_path}/views/#{view_id}/image#{qs}", accept: '*/*', binary: true)
  end

  # ---- datasources ---------------------------------------------------------

  def list_datasources(page_size: 100, page: 1)
    request(:get, "#{base_path}/datasources?pageSize=#{page_size}&pageNumber=#{page}")
  end

  def find_datasource_by_name(name)
    encoded = CGI.escape("name:eq:#{name}")
    j = request(:get, "#{base_path}/datasources?filter=#{encoded}")
    list = j.dig('datasources', 'datasource') || []
    list = [list] unless list.is_a?(Array)
    list.first
  end

  # ---- server capabilities -------------------------------------------------
  # Tableau Cloud always exposes the latest REST API, VDS, and the Metadata API.
  # A self-hosted Tableau Server is pinned to its installed release and ships
  # with VDS (2024.2+) and the Metadata API OFF by default — so the discovery
  # path must know which capabilities are live before it leans on them.

  # Server-level info (no site scope). Returns e.g.
  #   {"productVersion"=>{"value"=>"2024.2", ...}, "restApiVersion"=>"3.23"}
  def serverinfo
    request(:get, "/api/#{api_version}/serverinfo")['serverInfo']
  end

  # Is the Metadata API (GraphQL) turned on? Always on in Cloud; DISABLED BY
  # DEFAULT on Tableau Server (admin enables via `tsm maintenance
  # metadata-services enable`). When off the endpoint 404s and calc-formula
  # extraction falls back to parsing the .twb XML.
  def metadata_api_available?
    r = graphql('{ __typename }')
    !r.nil? && (r['errors'].nil? || r['errors'].empty?)
  rescue Error
    false
  end

  # Best-effort capability summary for the discovery banner. `vds` is left nil:
  # VDS has no auth-free ping, so the discover pool detects it per datasource and
  # falls back to .twb on failure. Never raises.
  def capabilities
    info = (serverinfo rescue nil) || {}
    {
      'product_version'  => info.dig('productVersion', 'value'),
      'rest_api_version' => info['restApiVersion'] || api_version,
      'metadata_api'     => (metadata_api_available? rescue false),
    }
  end

  # VizQL Data Service — full field list with calc formulas. This is the REST equivalent
  # of mcp__tableau__get-datasource-metadata.
  def read_metadata(datasource_luid)
    body = { datasource: { datasourceLuid: datasource_luid } }.to_json
    request(:post, "/api/v1/vizql-data-service/read-metadata", body: body)
  end

  # ---- metadata GraphQL ----------------------------------------------------

  # Convenience: fetch a published datasource by luid, returning fields + calc formulas.
  # Cleaner display names than read_metadata (which uses GUIDs for fields belonging to
  # joined logical tables).
  def graphql_datasource_fields(datasource_luid)
    query = <<~GQL
      {
        publishedDatasources(filter:{luid:"#{datasource_luid}"}) {
          name luid
          fields {
            name
            fullyQualifiedName
            ... on CalculatedField { formula isHidden }
          }
        }
      }
    GQL
    body = { query: query }.to_json
    request(:post, "/api/metadata/graphql", body: body)
  end

  def graphql(query, variables: nil)
    payload = { query: query }
    payload[:variables] = variables if variables
    request(:post, "/api/metadata/graphql", body: payload.to_json)
  end
end
