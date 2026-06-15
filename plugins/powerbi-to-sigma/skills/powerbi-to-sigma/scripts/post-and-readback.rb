#!/usr/bin/env ruby
# POST a DM or workbook spec, parse the YAML response, then GET the spec back
# and emit a clean JSON map of pages → elements with server-assigned IDs.
#
# Usage:
#   ruby post-and-readback.rb --type datamodel|workbook --spec <spec.json> --out <id-map.json>

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'date'
require 'time'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--type T', %w[datamodel workbook]) { |v| opts[:type] = v }
  p.on('--spec P')                         { |v| opts[:spec] = v }
  p.on('--out P')                          { |v| opts[:out]  = v }
  p.on('--workdir P', 'Per-conversion working dir (default: dir of --spec). Used to track posted workbook IDs across retries.') { |v| opts[:workdir] = v }
  p.on('--skip-layout-lint') { opts[:skip_lint] = true }
  p.on('--skip-control-lint') { opts[:skip_control_lint] = true }
  p.on('--control-scope P', 'control-scope.json sidecar (default: <workdir>/control-scope.json if present)') { |v| opts[:control_scope] = v }
end.parse!
%i[type spec out].each { |k| abort("missing --#{k}") unless opts[k] }
opts[:workdir] ||= File.dirname(File.expand_path(opts[:spec]))
require 'fileutils'
FileUtils.mkdir_p(opts[:workdir])

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'

BASE = ENV.fetch('SIGMA_BASE_URL')

POST_PATH = opts[:type] == 'datamodel' ? '/v2/dataModels/spec'              : '/v2/workbooks/spec'
GET_PATH  = opts[:type] == 'datamodel' ? '/v2/dataModels/%s/spec'           : '/v2/workbooks/%s/spec'
ID_FIELD  = opts[:type] == 'datamodel' ? 'dataModelId'                      : 'workbookId'

# Wraps a single Sigma REST call with automatic 401-retry-after-refresh
# (tokens last ~1 hour; long conversions outlive a single token). Returns
# the raw Net::HTTPResponse so existing .body / .is_a?(Net::HTTPSuccess)
# checks below keep working unchanged.
def http(method, path, body = nil, accept_json: false)
  attempts = 0
  loop do
    attempts += 1
    uri = URI("#{BASE}#{path}")
    req = case method
          when :post then r = Net::HTTP::Post.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
          when :get  then Net::HTTP::Get.new(uri)
          end
    req['Authorization'] = "Bearer #{Sigma.auth_token}"
    req['Accept']        = 'application/json' if accept_json
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) { |h| h.request(req) }
    if res.code.to_i == 401 && attempts == 1 && ENV['SIGMA_CLIENT_ID']
      warn '  [auth] Sigma token expired mid-run, refreshing and retrying...'
      Sigma.refresh_token!
      next
    end
    return res
  end
end

# Orphan-prevention pre-check: workbook POSTs are create-only. If this is a
# second invocation in the same conversion, the previous workbook is being
# orphaned in the customer's My Documents. WARN loudly and emit the PUT
# alternative. Tracked at beads-sigma-38a (3-workbook customer regression).
posted_log = File.join(opts[:workdir], 'posted-workbooks.jsonl') if opts[:type] == 'workbook'
prior_ids = []
if posted_log && File.exist?(posted_log)
  prior_ids = File.readlines(posted_log).map { |l| JSON.parse(l)['id'] rescue nil }.compact
end
if prior_ids.any?
  warn ''
  warn '============================================================'
  warn "WARN — orphan workbook risk (beads-sigma-38a)"
  warn '============================================================'
  warn "This is invocation ##{prior_ids.size + 1} of post-and-readback for this"
  warn "conversion. Each POST creates a NEW workbook. Already created:"
  prior_ids.each { |id| warn "  - #{id}" }
  warn ''
  warn 'If you are RETRYING after a spec error, you should be using PUT,'
  warn 'not POST:'
  warn ''
  warn "  curl -X PUT -H \"Authorization: Bearer $SIGMA_API_TOKEN\" \\"
  warn "    -H 'Content-Type: application/json' \\"
  warn "    -d @#{opts[:spec]} \\"
  warn "    \"$SIGMA_BASE_URL/v2/workbooks/#{prior_ids.last}/spec\""
  warn ''
  warn "If you genuinely meant to create a parallel workbook, ignore this."
  warn "Otherwise, run scripts/cleanup-orphan-workbooks.rb --workdir #{opts[:workdir]}"
  warn "to delete the orphans before declaring done — assert-phase6-ran.rb"
  warn "will FAIL the gate if uncleaned orphans remain."
  warn '============================================================'
  warn ''
end

resp = http(:post, POST_PATH, File.read(opts[:spec]))
parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
oid = parsed[ID_FIELD] or abort("POST failed: #{parsed.inspect}")
warn "POST ok: #{ID_FIELD}=#{oid}"

# Append the new ID to the per-conversion log. Newline-delimited JSON so
# multiple processes can append safely (atomic append on POSIX).
if posted_log
  File.open(posted_log, 'a') do |f|
    f.puts(JSON.generate({ 'id' => oid, 'ran_at' => Time.now.utc.iso8601 }))
  end
end

# Read back
spec = JSON.parse(http(:get, format(GET_PATH, oid), accept_json: true).body)

# Fetch the resolved /columns BEFORE writing the id-map so we can attach the
# AUTHORITATIVE per-element column labels (the suffixed display names Sigma
# assigns to disambiguate joined-dim columns — e.g. "Customer Id (CUSTOMER_DIM)").
# derive_master needs these to emit master-column formulas that actually resolve.
# (Same response is reused below for the error-type guard — one round trip.)
columns_path = opts[:type] == 'datamodel' ?
  "/v2/dataModels/#{oid}/columns" :
  "/v2/workbooks/#{oid}/columns"
cols_res = http(:get, columns_path, accept_json: true)
cols_json = cols_res.is_a?(Net::HTTPSuccess) ? (JSON.parse(cols_res.body) rescue { 'entries' => [] }) : nil
labels_by_el = Hash.new { |h, k| h[k] = [] }
(cols_json && cols_json['entries'] || []).each do |c|
  labels_by_el[c['elementId']] << c['label'] if c['elementId'] && c['label']
end

out = {
  ID_FIELD => oid,
  'pages'  => spec.fetch('pages', []).map do |p|
    {
      'id'       => p['id'],
      'name'     => p['name'],
      'visibility' => p['visibility'],
      'elements' => (p['elements'] || []).map do |e|
        el = { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'] }
        el['columnLabels'] = labels_by_el[e['id']] if labels_by_el.key?(e['id'])
        el
      end
    }
  end
}
File.write(opts[:out], JSON.pretty_generate(out))
puts JSON.pretty_generate(out)

# Universal silent-error guard: scan every column's resolved type via the
# `/columns` endpoint and fail loudly on any column with type `error`.
#
# A column ends up "error" when the formula compiles successfully against the
# validator but fails at runtime. Typical causes:
#   - Referenced column doesn't exist (typo)
#   - Function doesn't exist in Sigma (e.g., IsIn — see memory feedback_sigma_formula_isin.md)
#   - Window aggregate used in calc-column context (validate-spec catches the known
#     function names; this catches anything else that produces an error type)
#   - Cross-element ref without a Lookup wrapper (compiles, returns NULL forever — actually
#     resolves as the column's declared type, not "error", so this guard misses it; that's
#     why refs/data-model-spec.md has its own callout)
#
# Endpoint: GET /v2/{dataModels|workbooks}/<id>/columns — returns one entry per
# column with `type.type` resolved. Scan for type == "error".

res = cols_res
if res.is_a?(Net::HTTPSuccess)
  error_columns = (cols_json['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
  if error_columns.any?
    warn "\n========================================"
    warn "FAIL — #{error_columns.size} column(s) compiled to type \"error\":"
    error_columns.each do |c|
      warn "  [element=#{c['elementId']}] #{c['label']} (#{c['columnId']}):"
      warn "    formula: #{c['formula']}"
    end
    warn 'Fix these formulas before continuing — Phase 6 parity would fail downstream.'
    warn 'Common causes: typo in a column ref, IsIn() / non-existent function, window'
    warn 'aggregate in a calc column (use a Custom SQL element instead — see Phase 3).'
    warn '========================================'
    exit(2)
  else
    total = (cols_json['entries'] || []).size
    warn "column-type guard: #{total} columns clean (no `error` types)"
  end
else
  warn "WARN: could not fetch /columns for type guard (got HTTP #{res.code}); skipping"
end

# Layout-quality lint (shared scripts/lib/layout_lint.rb — vendored byte-
# identical, md5 discipline): fails loudly on raw-id element display names,
# input controls outside the GridContainer bands of a banded page, and dead
# zones (>25% empty grid rows between a page's first and last element). The
# "PHASEE PBI Employee Dashboard" regression shipped a parity-green workbook
# that was a visual mess — every data gate passed. Escape: --skip-layout-lint
# (legacy/intentional layouts only; name the reason in your report).
if opts[:type] == 'workbook' && !opts[:skip_lint]
  require_relative 'lib/layout_lint'
  violations = LayoutLint.lint(spec)
  if violations.any?
    warn "\n========================================"
    warn "FAIL — layout lint: #{violations.size} violation(s):"
    violations.each { |v| warn "  - #{v}" }
    warn 'Fix the spec/layout and re-PUT before continuing: raw-id names -> derive human'
    warn 'titles; loose controls -> control band or the chart container; dead zones ->'
    warn 're-band the page. The workbook DID post — fix with PUT /v2/workbooks/<id>/spec'
    warn '(re-POSTing creates an orphan).'
    warn '========================================'
    exit(3)
  end
  warn 'layout lint: clean (raw-id names / orphan controls / dead zones)'
end

# Control-wiring lint (shared scripts/lib/control_lint.rb — vendored byte-
# identical, md5 discipline): fails loudly on dead controls (no resolving
# filter target AND no [controlId] formula reference — the "Orders Overview
# (from Looker)" estate escape), ghost filter targets, and controls whose
# source-closure misses same-page queryable elements (the PHASEE
# "Action(Region) -> Monthly Revenue Trend" escape). If the builder emitted a
# control-scope sidecar (<workdir>/control-scope.json — see the lib header
# CONTRACT), it also fails when the source artifact had filter signals but the
# spec shipped zero controls (the Qlik class), and honors per-control
# scope:[...] allowlists for intentional single-chart switchers (grain
# controls). Escape: --skip-control-lint (name the reason in your report).
if opts[:type] == 'workbook' && !opts[:skip_control_lint]
  require_relative 'lib/control_lint'
  scope_path = opts[:control_scope] || File.join(opts[:workdir], 'control-scope.json')
  scope = nil
  if File.exist?(scope_path)
    scope = JSON.parse(File.read(scope_path)) rescue nil
    warn "WARN: #{scope_path} is not valid JSON — control lint runs without source scope" if scope.nil?
  end
  violations = ControlLint.lint(spec, scope: scope)
  if violations.any?
    warn "\n========================================"
    warn "FAIL — control lint: #{violations.size} violation(s):"
    violations.each { |v| warn "  - #{v}" }
    warn 'Fix the control wiring and re-PUT before continuing: dead controls -> add'
    warn 'filters targets ({source:{elementId}, columnId}) or remove the control;'
    warn 'partial reach -> wire the uncovered elements or annotate controlScope in'
    warn 'control-scope.json (see scripts/lib/control_lint.rb CONTRACT). The workbook'
    warn 'DID post — fix with PUT /v2/workbooks/<id>/spec (re-POSTing creates an orphan).'
    warn '========================================'
    exit(4)
  end
  n = ControlLint.controls_report(spec).length
  warn "control lint: clean (#{n} control(s); dead / ghost-target / reach#{scope ? ' / source-scope' : ''})"
end

# Phase 6 nag — column-type guard catches formula-resolution errors but does
# NOT compare data values to Tableau. Phase 6 (mandatory per SKILL.md) is the
# ONLY thing that confirms the chart actually reproduces the source. Emit a
# clear next-step prompt so the agent (or human) doesn't silently skip it.
if opts[:type] == 'workbook'
  warn ""
  warn "================================================================"
  warn "NEXT STEP — Phase 6 (MANDATORY): verify data parity vs Tableau"
  warn "================================================================"
  warn "Column-type guard PASSES means formulas RESOLVE. It does NOT mean"
  warn "the chart values match Tableau's. Run this BEFORE declaring done:"
  warn ""
  warn "  ruby scripts/phase6-parity.rb \\"
  warn "    --tableau <dir-with-views/-and-get-workbook.json> \\"
  warn "    --workbook-id #{oid}"
  warn ""
  warn "Add --extract-mode --extract-tol 0.30 if the Tableau workbook has"
  warn "a .hyper extract (drift between live + cached data is expected)."
  warn "================================================================"
end
