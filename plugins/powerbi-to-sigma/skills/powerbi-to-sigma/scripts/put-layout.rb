#!/usr/bin/env ruby
# GET a workbook spec, replace per-page layouts with a single top-level layout
# XML (provided), strip read-only fields, PUT back.
#
# Container layouts: a <Container> in the layout XML must be paired with a
# `kind: container` placeholder element in the spec (else it is silently
# dropped — layout-playbook.md). Layout builders that emit Containers
# write a sidecar `<layout>.elements.json` ({pageId: [element, ...]}) next to
# the layout XML; this script injects those elements into the document-global
# `elements` collection. Page ids in the sidecar are validation hints only:
# page membership comes from layout XML. Injection is idempotent.
#
# Usage:
#   ruby put-layout.rb --workbook <wbId> --layout <layout.xml> \
#     [--elements <elements.json>]

require 'json'
require 'yaml'
require 'date'
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'code_rep'
require 'sigma_rest'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

opts = {}
OptionParser.new do |p|
  p.on('--workbook ID') { |v| opts[:wb] = v }
  p.on('--layout PATH') { |v| opts[:layout] = v }
  p.on('--elements PATH', 'spec elements to inject (default: <layout>.elements.json if present)') { |v| opts[:elements] = v }
end.parse!
%i[wb layout].each { |k| abort("missing --#{k}") unless opts[k] }

HttpResponse = Struct.new(:body)

def http(method, path, body = nil)
  raw = Sigma.request(method, path, body: body, accept: '*/*')
  HttpResponse.new(raw.is_a?(String) ? raw : JSON.generate(raw))
end

# encoding: 'UTF-8' is NOT optional — this layout XML is regexp-matched below and
# carries element titles straight from the source dashboard, so em-dashes and
# curly quotes are the norm. A raw read inherits the locale's default external
# encoding and raises `invalid byte sequence in US-ASCII`. F5 crash class, #752.
xml = File.read(opts[:layout], encoding: 'UTF-8')
abort "FATAL: empty elementId in layout XML" if xml.match?(/elementId=""/)

raw_spec = JSON.parse(http(:get, "/v2/workbooks/#{opts[:wb]}/spec").body)
# Workbook code-rep nests pages/layout/schemaVersion/kind under a top-level
# `document` key (live since 2026-08) and REJECTS the old flat body on PUT
# with a 400 — unwrap the GET before any spec['pages'] access below; this
# endpoint is workbook-only (data-model code-rep is confirmed unchanged).
spec = Sigma::CodeRep.wrap(Sigma::CodeRep.document(raw_spec))['document']
spec['layout'] = xml
spec['pages'] ||= []
spec['elements'] ||= []

# Inject container/header-text spec elements (see header comment).
elements_path = opts[:elements] || "#{opts[:layout]}.elements.json"
if File.exist?(elements_path)
  inject = JSON.parse(File.read(elements_path))
  injected = 0
  page_ids = spec['pages'].filter_map { |p| p['id'] }
  existing = spec['elements'].filter_map { |e| e['id'] }
  inject.each do |page_id, els|
    unless page_ids.include?(page_id)
      warn "WARN: elements sidecar references unknown page #{page_id.inspect} — skipped"
      next
    end
    els.each do |el|
      next if existing.include?(el['id'])
      spec['elements'] << el
      existing << el['id']
      injected += 1
    end
  end
  puts "injected #{injected} container/header element(s) from #{elements_path}"
end

# The released representation makes layout authoritative: every flat element
# must be placed once, and layout must never reference an unknown element.
placed = xml.scan(/\belementId="([^"]+)"/).flatten
element_ids = spec['elements'].filter_map { |e| e['id'] }
duplicates = placed.group_by(&:itself).select { |_id, rows| rows.length > 1 }.keys
missing = element_ids - placed
unknown = placed - element_ids
abort "FATAL: invalid authoritative layout: duplicate=#{duplicates.inspect}; " \
      "unplaced=#{missing.inspect}; unknown=#{unknown.inspect}" \
  unless duplicates.empty? && missing.empty? && unknown.empty?
# Read-only metadata (workbookId, url, ownerId, createdBy, updatedBy,
# createdAt, updatedAt, latestDocumentVersion) never reaches `spec` in the
# first place now — Sigma::CodeRep.document() above already unwraps to just
# the document fields (schemaVersion/pages/kind/layout), so there is nothing
# left here to strip before the PUT.
put_body = JSON.pretty_generate(Sigma::CodeRep.wrap(spec))
resp = http(:put, "/v2/workbooks/#{opts[:wb]}/spec", put_body)
parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
puts parsed['workbookId'] ? "PUT ok: workbookId=#{parsed['workbookId']}" : "ERROR: #{parsed.inspect}"
exit(parsed['workbookId'] ? 0 : 1)
