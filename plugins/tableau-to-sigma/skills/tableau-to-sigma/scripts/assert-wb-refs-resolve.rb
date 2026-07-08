#!/usr/bin/env ruby
# frozen_string_literal: true
# 🚧 GATE — every workbook-spec column reference must resolve against the LIVE
# data model BEFORE the workbook is POSTed.
#
# The failure this prevents (MSP-Dashboard, 2026-07-08): the local converter
# collapsed a multi-datasource workbook onto its primary datasource, so the DM
# ended up with ~49 columns while the workbook spec still referenced ~599 —
# every `[Master/<dropped column>]` formula then POSTed and Sigma rejected it
# with "Dependency not found", one opaque error at a time, after the DM was
# already created. This gate turns that into a single, clear, pre-POST report:
# exactly which refs don't resolve and (usually) why (dropped datasource).
#
# It complements the multi-datasource gap (scan-workbook-gaps.rb) — that one
# stops at gap-scan; this one is the safety net for anything that slips past it
# (a collapse the gap scan didn't catch, a hand-edited spec, a stale cache).
#
# Column matching is GLOBAL + normalized (case/space-insensitive, trailing
# "(suffix)" stripped) so Sigma's disambiguating label suffixes and element
# renames don't cause false positives: a ref resolves if its column exists in
# ANY element of the DM.
#
# Usage:
#   ruby assert-wb-refs-resolve.rb --wb-spec <spec.json> \
#     ( --dm-ids <dm-ids.json> | --dm-id <dataModelId> ) \
#     [--skip-ref-check REASON]   # waive — REQUIRED reason; name it in your report
#
# Exit codes:
#   0  all refs resolve (or waived)
#   1  one or more refs do not resolve against the live DM
#   2  usage error
require 'json'
require 'optparse'
require 'set'

opts = {}
OptionParser.new do |p|
  p.on('--wb-spec PATH')  { |v| opts[:spec] = v }
  p.on('--dm-ids PATH')   { |v| opts[:dm_ids] = v }
  p.on('--dm-id ID')      { |v| opts[:dm_id] = v }
  p.on('--skip-ref-check REASON',
       'waive the ref-resolution gate — REQUIRED reason; name it in your report') { |v| opts[:skip] = v }
end.parse!

if opts[:skip]
  puts "[SKIP] workbook ref-resolution gate WAIVED (#{opts[:skip]}) — name this in your report."
  exit 0
end
abort 'usage: --wb-spec PATH and (--dm-ids PATH | --dm-id ID)' unless opts[:spec] && (opts[:dm_ids] || opts[:dm_id])

def norm(col)
  s = col.to_s.strip.downcase
  s = s.sub(/\s*\([^)]*\)\s*\z/, '') # drop a trailing "(disambiguating suffix)"
  s.gsub(/\s+/, ' ')
end

# --- collect the DM's available column labels (normalized) -----------------
available = Set.new
if opts[:dm_ids]
  idmap = JSON.parse(File.read(opts[:dm_ids], encoding: 'bom|utf-8'))
  (idmap['pages'] || []).each do |pg|
    (pg['elements'] || []).each do |el|
      (el['columnLabels'] || []).each { |l| available << norm(l) }
    end
  end
else
  # Live fetch via the shared REST lib (self-mints a token).
  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'
  cols = (Sigma.request(:get, "/v2/dataModels/#{opts[:dm_id]}/columns") rescue { 'entries' => [] })
  (cols['entries'] || []).each { |c| available << norm(c['label']) if c['label'] }
end

if available.empty?
  warn '[FAIL] workbook ref-resolution gate — the live DM reports ZERO columns.'
  warn '       The data model is empty/broken; do not POST the workbook against it.'
  warn '       (This is the multi-datasource-collapse signature — see the gap report.)'
  exit 1
end

# --- extract every [Element/Column] ref from the workbook spec --------------
REF = /\[([^\]\/]+)\/([^\]]+)\]/.freeze
refs = {} # normalized column -> {display, elements:Set}
walk = lambda do |obj|
  case obj
  when Hash  then obj.each_value { |v| walk.call(v) }
  when Array then obj.each { |v| walk.call(v) }
  when String
    obj.scan(REF) do |el, col|
      k = norm(col)
      (refs[k] ||= { display: col.strip, elements: Set.new })[:elements] << el.strip
    end
  end
end
walk.call(JSON.parse(File.read(opts[:spec], encoding: 'bom|utf-8')))

unresolved = refs.reject { |k, _| available.include?(k) }

if unresolved.empty?
  puts "[PASS] workbook ref-resolution gate: all #{refs.size} referenced column(s) resolve " \
       "against the live DM (#{available.size} columns)."
  exit 0
end

warn "[FAIL] workbook ref-resolution gate — #{unresolved.size} of #{refs.size} referenced " \
     "column(s) do NOT exist in the live DM (#{available.size} columns):"
unresolved.values.first(40).each do |r|
  warn "         ✗ #{r[:display]}   (referenced via #{r[:elements].to_a.map { |e| "[#{e}/…]" }.join(', ')})"
end
warn "         … and #{unresolved.size - 40} more." if unresolved.size > 40
warn ''
warn '       These refs would fail the workbook POST with "Dependency not found". The usual'
warn '       cause is a MULTI-DATASOURCE workbook the local converter collapsed onto one'
warn '       datasource (dropping the others\' columns) — see the multi_datasource gap report,'
warn '       and build a multi-element DM (or land + repoint the missing sources) before POSTing.'
warn '       Escape hatch (name it in your report): --skip-ref-check "<reason>".'
exit 1
