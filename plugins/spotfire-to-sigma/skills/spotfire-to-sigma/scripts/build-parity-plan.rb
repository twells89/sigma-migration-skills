#!/usr/bin/env ruby
# frozen_string_literal: true
# build-parity-plan.rb — emit a parity-plan.json (and a normalized wb-readback.json)
# straight from a built Sigma workbook spec, with NO source-tool views required.
#
# Normal Phase 6 (auto-parity-plan.rb) matches each chart to a SOURCE view to get
# expected values. In raw-mode (only a .twb/.pbix/.qvf, no live source) there are
# no source views — but verify-warehouse.rb only needs the LIST of visible chart
# elements + their plotted columns to confirm each evaluates against the warehouse.
# This helper produces exactly that, so an agent in file-mode does not hand-roll
# the plan (handoff FIX 1).
#
# Usage:
#   ruby scripts/build-parity-plan.rb --workbook-id <wb> --out <wd>/parity-plan.json \
#     [--workbook-spec <wd>/wb-readback.json]   # use this spec instead of GET /spec
#     [--emit-spec <wd>/wb-readback.json]        # also write the spec here (unwrapped
#                                                 # document: {schemaVersion, pages, elements, kind, layout})
#
# Output parity-plan.json: { "charts": [ { chart, sigma_element_id, sigma_kind,
#   sigma_columns:[<plotted column ids>] }, ... ] } — one entry per VISIBLE chart
# element (hidden data-page masters, controls, text/image/containers excluded).
#
# Exit codes: 0 = plan written (>=1 chart); 2 = zero chartable elements; 1 = bad invocation.

require 'json'
require 'optparse'
require 'set'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'code_rep'

opts = {}
OptionParser.new do |p|
  p.on('--workbook-id ID')     { |v| opts[:wb] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
  p.on('--workbook-spec PATH') { |v| opts[:spec] = v }
  p.on('--emit-spec PATH')     { |v| opts[:emit] = v }
end.parse!
abort 'missing --out' unless opts[:out]
abort 'missing --workbook-id (or --workbook-spec)' unless opts[:wb] || opts[:spec]

# Load the spec: from a file if given, else from the live workbook. Either
# source may be the live nested shape (POST/GET /v2/workbooks/.../spec nests
# pages/layout/schemaVersion/kind under a top-level `document` key, verified
# live 2026-08-03/04) or a legacy flat artifact (committed fixtures, older
# wb-readback.json snapshots) — Sigma::CodeRep.document() accepts both and
# always hands back the plain workbook document.
if opts[:spec] && File.exist?(opts[:spec])
  spec = Sigma::CodeRep.document(JSON.parse(File.read(opts[:spec])))
else
  require 'sigma_rest'
  resp = Sigma.request(:get, "/v2/workbooks/#{opts[:wb]}/spec")
  # /spec may wrap the spec under a key; accept either shape.
  raw = resp.is_a?(Hash) && resp['spec'] ? resp['spec'] : resp
  spec = Sigma::CodeRep.document(raw)
end

# Non-data element kinds we never verify (controls, text, images, containers).
SKIP_KIND = /control|^text$|^image$|^button|container|^iframe|^embed|^divider/i

def chartable?(el)
  k = el['kind'].to_s
  return false if k.empty? || k =~ SKIP_KIND
  return false if el['visibleAsSource'] == false        # hidden data-page master
  (el['columns'] || []).any?
end

# Plotted channel columns = every columnId the element's channels reference that
# the element actually owns. Best-effort: if none resolve, leave empty (verify-
# warehouse then just asserts the element returns non-empty, non-error data).
def plotted_column_ids(el)
  own = (el['columns'] || []).map { |c| c['id'] }.compact.to_set
  ids = []
  walk = lambda do |v|
    case v
    when Hash
      v.each do |k, val|
        next if k == 'columns'                          # skip the column definitions
        if k == 'columnId' && val.is_a?(String)
          ids << val
        elsif k == 'columnIds' && val.is_a?(Array)
          val.each { |x| ids << (x.is_a?(Hash) ? (x['columnId'] || x['id']) : x) }
        else
          walk.call(val)
        end
      end
    when Array then v.each { |x| walk.call(x) }
    end
  end
  walk.call(el)
  ids.compact.uniq.select { |i| own.include?(i) }
end

charts = []
Sigma::CodeRep.workbook_elements(spec).each do |el|
  next unless chartable?(el)
  # `name` can be a visibility hash on hidden-title elements (put-layout) —
  # recover the text, else fall through to title/id.
  ename = el['name'].is_a?(Hash) ? el['name']['text'] : el['name']
  ename = nil if ename.to_s.empty?
  charts << {
    'chart'            => (ename || el['title'] || el['id']).to_s,
    'sigma_element_id' => el['id'],
    'sigma_kind'       => el['kind'],
    'sigma_columns'    => plotted_column_ids(el),
  }
end

if charts.empty?
  warn '[FAIL] build-parity-plan: found zero visible chart elements in the workbook spec.'
  warn '       (All elements were controls/text/images/containers or hidden masters.)'
  exit 2
end

File.write(opts[:out], JSON.pretty_generate('charts' => charts))
# Write the UNWRAPPED document (not just {pages:[...]}) — blind_grade.rb,
# verify-anchors.rb's offline mode, and record-visual-check.rb all read
# wb-readback.json expecting a plain pages/elements/layout document at the top level;
# CodeRep.document() has already stripped the transport envelope above.
File.write(opts[:emit], JSON.pretty_generate(spec)) if opts[:emit]

puts "build-parity-plan: #{charts.size} visible chart element(s) → #{opts[:out]}"
puts "  (wb-readback spec → #{opts[:emit]})" if opts[:emit]
charts.first(12).each { |c| puts "    - #{c['chart']} [#{c['sigma_kind']}] #{c['sigma_columns'].size} col(s)" }
exit 0
