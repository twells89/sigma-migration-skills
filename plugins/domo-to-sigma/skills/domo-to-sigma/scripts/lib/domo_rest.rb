# Domo REST wrapper for domo-to-sigma. Covers BOTH API surfaces:
#   - PUBLIC  api.domo.com           (OAuth bearer, DOMO_ACCESS_TOKEN)   — documented, stable
#   - PRIVATE {instance}.domo.com    (X-DOMO-Developer-Token header)     — undocumented, best-effort
#
# Requires in ENV:
#   DOMO_ACCESS_TOKEN  (public; set by scripts/get-domo-token.sh)
#   DOMO_CLIENT_ID / DOMO_CLIENT_SECRET  (for auto-refresh on 401)
#   DOMO_INSTANCE      (private host: {DOMO_INSTANCE}.domo.com)
#   DOMO_DEV_TOKEN     (private; optional — omit for Tier B / public-only)
#
# All methods return parsed Hash/Array (or raw String for csv export). HTTP errors
# raise Domo::Error with the response body included.
#
# STATUS: auth + public endpoints follow Domo's documented API. Private endpoint
# shapes are now confirmed against Domo's OpenAPI ("Get Chart Card Definition") and
# three production reference impls (jsade/domo-query-cli, brycewc/domo-toolkit,
# newli5737/domo-chousa). Field paths still want a final check on first contact
# with a live instance (see refs/connection.md).

require 'net/http'
require 'uri'
require 'json'

module Domo
  class Error < StandardError; end
  class AuthError < Error; end

  PUBLIC_HOST = 'api.domo.com'

  @mutex = Mutex.new
  @token_override = nil

  module_function

  def access_token
    @mutex.synchronize { @token_override } ||
      ENV.fetch('DOMO_ACCESS_TOKEN') { raise Error, 'DOMO_ACCESS_TOKEN not set — run get-domo-token.sh' }
  end

  def instance
    ENV.fetch('DOMO_INSTANCE') { raise Error, 'DOMO_INSTANCE not set (e.g. "acme" for acme.domo.com)' }
  end

  def dev_token
    ENV['DOMO_DEV_TOKEN'] # nil => Tier B (public only)
  end

  # Re-run client-credentials and update the in-memory public token. Thread-safe.
  def refresh_token!
    id     = ENV.fetch('DOMO_CLIENT_ID')     { raise AuthError, 'DOMO_CLIENT_ID not set — cannot refresh' }
    secret = ENV.fetch('DOMO_CLIENT_SECRET') { raise AuthError, 'DOMO_CLIENT_SECRET not set — cannot refresh' }
    scope  = (ENV['DOMO_SCOPE'] || 'data user account dashboard').gsub(' ', '%20')
    uri = URI("https://#{PUBLIC_HOST}/oauth/token?grant_type=client_credentials&scope=#{scope}")
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(id, secret)
    res = http(uri).request(req)
    raise AuthError, "token refresh failed: #{res.code} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
    tok = JSON.parse(res.body).fetch('access_token')
    @mutex.synchronize { @token_override = tok }
    ENV['DOMO_ACCESS_TOKEN'] = tok
    tok
  end

  # ---- PUBLIC API (api.domo.com) -------------------------------------------

  # GET against api.domo.com. Auto-refreshes once on 401. `accept` lets callers
  # request text/csv for the DataSet export endpoint.
  def public_get(path, query: nil, accept: 'application/json', _retried: false)
    uri = URI("https://#{PUBLIC_HOST}#{path}")
    uri.query = URI.encode_www_form(query) if query
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{access_token}"
    req['Accept'] = accept
    res = http(uri).request(req)
    if res.is_a?(Net::HTTPUnauthorized) && !_retried
      refresh_token!
      return public_get(path, query: query, accept: accept, _retried: true)
    end
    handle(res, accept)
  end

  def public_post(path, body:, _retried: false)
    uri = URI("https://#{PUBLIC_HOST}#{path}")
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{access_token}"
    req['Content-Type']  = 'application/json'
    req['Accept']        = 'application/json'
    req.body = body.is_a?(String) ? body : JSON.generate(body)
    res = http(uri).request(req)
    if res.is_a?(Net::HTTPUnauthorized) && !_retried
      refresh_token!
      return public_post(path, body: body, _retried: true)
    end
    handle(res, 'application/json')
  end

  # Convenience: documented public endpoints.
  def list_datasets(limit: 50, offset: 0)
    public_get('/v1/datasets', query: { limit: limit, offset: offset })
  end

  def dataset(id)
    public_get("/v1/datasets/#{id}")
  end

  def dataset_csv(id, header: true)
    public_get("/v1/datasets/#{id}/data", query: { includeHeader: header }, accept: 'text/csv')
  end

  def query_dataset(id, sql)
    public_post("/v1/datasets/query/execute/#{id}", body: { sql: sql })
  end

  def pages
    public_get('/v1/pages')
  end

  def page(id)
    public_get("/v1/pages/#{id}")
  end

  # ---- PRIVATE API ({instance}.domo.com/api/...) ---------------------------
  # Undocumented. Returns nil if DOMO_DEV_TOKEN is unset (Tier B). CONFIRM shapes.

  def private_get(path, query: nil)
    tok = dev_token or return nil
    uri = URI("https://#{instance}.domo.com#{path}")
    uri.query = URI.encode_www_form(query) if query
    req = Net::HTTP::Get.new(uri)
    req['X-DOMO-Developer-Token'] = tok
    req['Accept'] = 'application/json'
    handle(http(uri).request(req), 'application/json')
  end

  # PUT against the private API. Returns the raw Net::HTTPResponse so callers can
  # branch on Content-Type (the render endpoint returns JSON-wrapped base64 OR raw
  # image bytes depending on instance version). Returns nil on Tier B.
  def private_put_raw(path, body:, query: nil)
    tok = dev_token or return nil
    uri = URI("https://#{instance}.domo.com#{path}")
    uri.query = URI.encode_www_form(query) if query
    req = Net::HTTP::Put.new(uri)
    req['X-DOMO-Developer-Token'] = tok
    req['Content-Type'] = 'application/json'
    req['Accept']       = 'application/json'
    req.body = body.is_a?(String) ? body : JSON.generate(body)
    res = http(uri).request(req)
    raise Error, "#{res.code} #{res.message} for #{path}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
    res
  end

  # PUT against the private API that returns a parsed JSON body (vs private_put_raw,
  # which returns the raw response for binary/render calls). Returns nil on Tier B.
  def private_put(path, body:, query: nil)
    res = private_put_raw(path, body: body, query: query)
    return nil if res.nil?
    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end

  # POST against the private API, parsed JSON body. Returns nil on Tier B — same
  # convention as private_get/private_put. Used for the card-enumeration fallback
  # (adminsummary — see cards_adminsummary below), which paginates via QUERY
  # params even though it's a POST (the filter — pageIds/orderBy/ascending —
  # goes in the body).
  def private_post(path, body:, query: nil)
    tok = dev_token or return nil
    uri = URI("https://#{instance}.domo.com#{path}")
    uri.query = URI.encode_www_form(query) if query
    req = Net::HTTP::Post.new(uri)
    req['X-DOMO-Developer-Token'] = tok
    req['Content-Type'] = 'application/json'
    req['Accept']       = 'application/json'
    req.body = body.is_a?(String) ? body : JSON.generate(body)
    handle(http(uri).request(req), 'application/json')
  end

  # ---- Card definition: TWO shapes ----------------------------------------
  # Domo exposes a card's definition in two different shapes with DIFFERENT field
  # names. The extractor (domo-discover.rb) normalizes both into one record.
  #
  #  Shape A — official OpenAPI "CardDefinition" (parts form). `chartBody` and
  #    `summaryNumber` are Component objects: .columns[]{column,alias,aggregation,
  #    format,mapping,calendar,order}; calculatedFields[]{formula,id,name,
  #    saveToDataSet}; conditionalFormats[]{condition,format,savedToDataSet};
  #    chartType is a free string. groupBy/orderBy/filters/projection nest INSIDE
  #    the Component, not at top level.
  def card_definition(card_id, parts: 'metadata,properties,datasources')
    private = begin
      private_get('/api/content/v1/cards', query: { urns: card_id, parts: parts })
    rescue Error
      nil
    end
    private || public_get("/v1/cards/chart/#{card_id}")
  end

  #  Shape B — internal analyzer definition (what the app + production tools pull).
  #    Response wrapped under a top-level `definition`:
  #      definition.subscriptions.main.{columns[]{column,formulaId}, filters[],
  #        orderBy[], groupBy[]}, definition.formulas[]{id,name,columnPositions}.
  #    Beast-mode refs are ids prefixed "calculation_<uuid>" joining to a formula.
  #    Refs: brycewc/domo-toolkit, newli5737/domo-chousa, jsade/domo-query-cli.
  # CONFIRMED live: {"urn": id} alone is sufficient — dynamicText/variables are
  # optional and omitted here (refs/live-validation-2026-07-30.md Bug 3).
  def card_definition_v3(card_id)
    private_put('/api/content/v3/cards/kpi/definition', body: { urn: card_id })
  end

  # Standalone Beast Mode ("function template"). The `expression` field carries the
  # formula text; `aggregated`/`analytic` classify it WITHOUT parsing SQL:
  #   analytic:true  => window/analytic  (RANK/…​ OVER, PARTITION BY)
  #   aggregated:true => aggregate        (wrap at workbook/element level)
  #   else            => projection/row-level (Sigma DM calc column)
  # `legacyId` == the "calculation_<uuid>" id seen in card refs.
  def beast_mode_template(fn_id)
    private_get("/api/query/v1/functions/template/#{fn_id}")
  end

  # DataSet metadata WITH Beast Mode formulas. properties.formulas.formulas is a
  # MAP keyed by formula id (iterate values), each {id,name,formula,templateId,
  # persistedOnDataSource,columnPositions,...}. persistedOnDataSource:true = a
  # dataset-level Beast Mode (vs card-local).
  def dataset_formulas(ds_id)
    private_get("/api/data/v3/datasources/#{ds_id}", query: { parts: 'core,permission,formulas' })
  end

  # Enumerate cards bound to a DataSet / on a page (private API).
  def cards_for_dataset(ds_id)
    private_get("/api/content/v1/datasources/#{ds_id}/cards", query: { drill: true })
  end

  # Card enumeration — Bug 1 (P0). `GET /v1/pages/{id}` (Domo.page, PUBLIC) returns
  # cardIds: [] even on a page with dozens of cards (confirmed live). The THREE
  # routes below are the working alternatives, in preference order; see
  # domo-discover.rb's enumerate_page_cards for the fallback orchestration.

  # 1. PRIMARY (private). The richest single call: full card objects (each with
  #    `metadata.chartType`, matching the parts-read shape) PLUS `sizes[]`
  #    (T-shirt size token per card) and `collections[]` (titled sections,
  #    grouping cards BY INDEX into this response's own `cards[]`) — see Bug 5 /
  #    DomoSigma.merge_geometry. This method already existed; nothing called it
  #    until this fix.
  def cards_for_page(page_id, parts: 'metadata,datasources,dateInfo,subscriptions,slicers')
    private_get("/api/content/v3/stacks/#{page_id}/cards",
                query: { parts: parts, includeV4PageLayouts: true })
  end

  # 2. FALLBACK (private, instance-wide sweep). Paginates via QUERY params
  #    (skip/limit) — NOT the body, which instead carries the filter. Passing
  #    `pageIds: [page_id]` scopes the sweep to one page server-side. Returns
  #    lighter records ({id,type,title,badgeUpdated,locked,owners,pageHierarchy})
  #    with NO `metadata`/chartType — callers fall back to the analyzer
  #    definition's definition.charts.main.chartType for classification.
  def cards_adminsummary(page_id, parts: 'metadata,datasources', skip: 0, limit: 100)
    private_post('/api/content/v2/cards/adminsummary',
                 body: { ascending: true, orderBy: 'cardTitle', pageIds: [page_id] },
                 query: { parts: parts, skip: skip, limit: limit })
  end

  # 3. FALLBACK — the only one of the three reachable on Tier B (public, no dev
  #    token). `limit` MUST be capped at 100: a higher limit silently returns an
  #    EMPTY list rather than erroring, so callers must paginate via `offset`
  #    instead of asking for more per page. Response: {totalCardCount,
  #    cards:[{cardUrn,cardTitle,type,pages:[...],lastModified}]} — filter on
  #    `pages` client-side to scope to one page id. This list is also
  #    eventually-consistent right after bulk mutations — an empty result means
  #    "unknown right now", not "definitely no cards".
  #
  #    NOTE: `type` here uses the PUBLIC vocabulary (e.g. "chart"), which
  #    disagrees with the private API's "kpi" for the very same card — never key
  #    element-kind decisions on `type`; use metadata.chartType instead.
  def list_cards(limit: 100, offset: 0)
    public_get('/v1/cards', query: { limit: [limit, 100].min, offset: offset })
  end

  def page_layout(page_id)
    private_get("/api/content/v1/pages/#{page_id}")
  end

  # ---- Card render (visual capture) ----------------------------------------
  # Renders a card exactly as the Domo app shows it. This is the automated
  # upgrade of the Tier-B "manual PNG capture" fallback: with a dev token we pull
  # a true visual reference per card so the Sigma build + layout-visual-qa gate
  # have something to match (see refs/connection.md "Visual + layout capture"
  # and feedback_phase1d_dashboard_png / batch_converter_png_brief).
  #
  # PUT /api/content/v1/cards/kpi/{cardId}/render?parts=image      → PNG
  #                                              ?parts=imagePDF   → PDF
  # Body params (all optional): width, height, scale, queryOverrides, filters.
  # Returns binary image/PDF bytes, or nil on Tier B.
  #
  # CONFIRMED live (refs/live-validation-2026-07-30.md, "Render endpoint: charts
  # vs tables"): `parts` and the payload shape are BOTH card-kind-dependent, not
  # just a format toggle. `parts=image` is the chart/KPI path — 200, base64 PNG
  # under `image.data` (see decode_render). `parts=image` 400s outright on a
  # TABLE card (`badge_table`); tables need `parts=imagePDF` — same query param
  # this method already sends for format: :pdf — whose payload is NOT under
  # `image.data` either: it arrives HTML-wrapped base64 under `html` (BUG 3;
  # decode_render's third branch strips the tag and decodes it). Callers
  # (domo-capture-visuals.rb) must pick `format: :pdf` for a table card — this
  # method itself has no card-kind knowledge to do that automatically.
  def render_card(card_id, format: :png, width: 1000, height: 700, scale: 2,
                  query_overrides: nil, filters: nil)
    part = (format.to_sym == :pdf) ? 'imagePDF' : 'image'
    body = { width: width, height: height, scale: scale }
    body[:queryOverrides] = query_overrides if query_overrides
    body[:filters]        = filters if filters
    res = private_put_raw("/api/content/v1/cards/kpi/#{card_id}/render",
                          body: body, query: { parts: part })
    return nil if res.nil?
    decode_render(res)
  end

  def render_card_png(card_id, **kw); render_card(card_id, format: :png, **kw); end
  def render_card_pdf(card_id, **kw); render_card(card_id, format: :pdf, **kw); end

  def dataset_meta(ds_id)
    private_get("/api/data/v3/datasources/#{ds_id}", query: { parts: 'core,permission' })
  end

  # ---- internals -----------------------------------------------------------

  # Normalize a render response to raw binary bytes. CONFIRMED live shape
  # (refs/live-validation-2026-07-30.md): 200, Content-Type: application/json,
  # body = {"image": {"data": "<b64 PNG>", "notAllDataShown": false}, "limited":
  # false, "notAllDataShown": false} — a JSON ENVELOPE, not raw bytes. Tolerates
  # older/other-instance shapes too:
  #   1. raw bytes           — Content-Type image/* or application/pdf
  #   2. JSON, image is Hash — { "image": { "data": "<b64>" } }  (live/confirmed)
  #   3. JSON, image is str  — { "image": "<b64>" } / "imageData" / "data"
  # NOTE: json['image'] is a Hash in the confirmed shape, so it must be tried
  # as a nested dig BEFORE the bare-string keys, not after — `a || b` short-
  # circuits on the first truthy value, and a Hash is truthy even though it's
  # not the base64 string we want.
  def decode_render(res)
    require 'base64'
    ctype = res['content-type'].to_s
    body  = res.body.to_s
    return body if ctype.start_with?('image/', 'application/pdf', 'application/octet-stream')

    if ctype.include?('json') || body.lstrip.start_with?('{')
      json = JSON.parse(body) rescue nil
      if json.is_a?(Hash)
        b64 = json.dig('image', 'data') || json['imageData'] || json['data'] ||
              (json['image'].is_a?(String) ? json['image'] : nil)
        return Base64.decode64(b64) if b64.is_a?(String) && !b64.empty?

        # THIRD payload shape (live-validated 2026-07-30): a TABLE card rendered
        # with parts=imagePDF returns its payload under `html`, NOT image.data —
        # an HTML-wrapped base64 PDF:
        #   {"html": "<div class=\"kpi_chart\">JVBERi0xLjQ...</div>", ...}
        # Strip the tags, then base64-decode to a %PDF-1.4 document. Without this
        # branch a table card's visual silently captures as zero bytes.
        # See refs/live-validation-2026-07-30.md "charts vs tables".
        if json['html'].is_a?(String) && !json['html'].empty?
          inner = json['html'].gsub(/<[^>]+>/, '').strip
          return Base64.decode64(inner) if inner.match?(%r{\A[A-Za-z0-9+/=\s]+\z}) && inner.length > 100
        end
      end
    end
    # Fall back: treat the whole body as a base64 string (some instances do this).
    looks_b64 = body.match?(%r{\A[A-Za-z0-9+/=\s]+\z}) && body.length > 100
    looks_b64 ? Base64.decode64(body) : body
  end

  def http(uri)
    h = Net::HTTP.new(uri.host, uri.port)
    h.use_ssl = (uri.scheme == 'https')
    h.read_timeout = 120
    h
  end

  def handle(res, accept)
    unless res.is_a?(Net::HTTPSuccess)
      raise Error, "#{res.code} #{res.message} for #{res.uri rescue '?'}: #{res.body}"
    end
    return res.body if accept == 'text/csv'
    res.body.to_s.empty? ? {} : JSON.parse(res.body)
  end
end
