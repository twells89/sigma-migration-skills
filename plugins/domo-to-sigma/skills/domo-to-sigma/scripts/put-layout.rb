#!/usr/bin/env ruby
# ── VENDORED (do not edit here) ──────────────────────────────────────────────
# Source: twells89/sigma-migration-skills @ a73f833
#   plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/put-layout.rb
# Fix upstream and re-vendor; do not diverge this copy. Vendored for the
# standalone domo-sigma-migration repo (clone-safety) per the domo-build-pipeline plan.
# ─────────────────────────────────────────────────────────────────────────────
# GET a workbook spec, replace per-page layouts with a single top-level layout
# XML (provided), strip read-only fields, PUT back.
#
# Container layouts: a <GridContainer> in the layout XML must be paired with a
# `kind: container` placeholder element in the spec (else it is silently
# dropped — layout-playbook.md). Layout builders that emit GridContainers
# write a sidecar `<layout>.elements.json` ({pageId: [element, ...]}) next to
# the layout XML; this script injects those elements (containers + header
# text) into the matching pages before the PUT. Pass --elements to override
# the sidecar path. Injection is idempotent (existing element ids are kept).
#
# Usage:
#   ruby put-layout.rb --workbook <wbId> --layout <layout.xml> \
#     [--elements <elements.json>]

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'date'
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'code_rep'
# Ruby 2.6 floor (macOS system ruby): this file uses Enumerable#tally (2.7+).
# Polyfilled rather than rewritten -- see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

opts = {}
OptionParser.new do |p|
  p.on('--workbook ID') { |v| opts[:wb] = v }
  p.on('--layout PATH') { |v| opts[:layout] = v }
  p.on('--elements PATH', 'spec elements to inject (default: <layout>.elements.json if present)') { |v| opts[:elements] = v }
end.parse!
%i[wb layout].each { |k| abort("missing --#{k}") unless opts[k] }

BASE = ENV.fetch('SIGMA_BASE_URL')
TOK  = ENV.fetch('SIGMA_API_TOKEN')

def http(method, path, body = nil)
  uri = URI("#{BASE}#{path}")
  req = case method
        when :get then Net::HTTP::Get.new(uri)
        when :put then r = Net::HTTP::Put.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
        end
  req['Authorization'] = "Bearer #{TOK}"
  req['Accept']        = 'application/json'
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |h| h.request(req) }
end

xml = File.read(opts[:layout], encoding: 'UTF-8')
abort "FATAL: empty elementId in layout XML" if xml.match?(/elementId=""/)

raw_spec = JSON.parse(http(:get, "/v2/workbooks/#{opts[:wb]}/spec").body)
# Workbook code-rep nests pages/layout/schemaVersion/kind under a top-level
# `document` key (live since 2026-08) and REJECTS the old flat body on PUT
# with a 400 — unwrap the GET before any spec['pages'] access below; this
# endpoint is workbook-only (data-model code-rep is confirmed unchanged).
spec = Sigma::CodeRep.document(raw_spec)
spec['pages'].each { |p| p.delete('layout') }
spec['layout'] = xml

# Inject container/header-text spec elements (see header comment). Workbook
# elements are document-global in the released representation; sidecar page
# keys describe layout ownership and must never recreate pages[].elements.
elements_path = opts[:elements] || "#{opts[:layout]}.elements.json"
if File.exist?(elements_path)
  inject = JSON.parse(File.read(elements_path))
  injected = 0
  inject.each do |page_id, els|
    page = spec['pages'].find { |p| p['id'] == page_id }
    unless page
      warn "WARN: elements sidecar references unknown page #{page_id.inspect} — skipped"
      next
    end
    spec['elements'] ||= []
    existing = spec['elements'].map { |e| e['id'] }
    els.each do |el|
      next if existing.include?(el['id'])
      spec['elements'] << el
      existing << el['id']
      injected += 1
    end
  end
  puts "injected #{injected} container/header element(s) from #{elements_path}"
end
# Read-only metadata (workbookId, url, ownerId, createdBy, updatedBy,
# createdAt, updatedAt, latestDocumentVersion) never reaches `spec` in the
# first place now — Sigma::CodeRep.document() above already unwraps to just
# the document fields (schemaVersion/pages/kind/layout), so there is nothing
# left here to strip before the PUT.

element_ids = Array(spec['elements']).map { |element| element['id'] }
placed_ids = xml.scan(/\belementId="([^"]+)"/).flatten
duplicate_elements = element_ids.tally.select { |_id, count| count > 1 }.keys
duplicate_placements = placed_ids.tally.select { |_id, count| count > 1 }.keys
unplaced = element_ids - placed_ids
unknown = placed_ids - element_ids
unless duplicate_elements.empty? && duplicate_placements.empty? && unplaced.empty? && unknown.empty?
  abort "FATAL: layout must place every flat workbook element exactly once: " \
        "duplicate element ids=#{duplicate_elements.inspect}; duplicate placements=#{duplicate_placements.inspect}; " \
        "unplaced=#{unplaced.inspect}; unknown=#{unknown.inspect}"
end

resp = http(:put, "/v2/workbooks/#{opts[:wb]}/spec", JSON.pretty_generate(Sigma::CodeRep.wrap(spec)))
parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
puts parsed['workbookId'] ? "PUT ok: workbookId=#{parsed['workbookId']}" : "ERROR: #{parsed.inspect}"
exit(parsed['workbookId'] ? 0 : 1)
