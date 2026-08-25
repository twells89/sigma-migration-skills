#!/usr/bin/env ruby
# frozen_string_literal: true
# 🚧 GATE — every workbook-spec column reference must resolve against the LIVE
# data model BEFORE the workbook is POSTed.
#
# The failure this prevents (a real multi-datasource workbook): the local converter
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
# Merged capabilities (from the branch resolver assert-refs-resolve.rb, now
# deleted — scripts/test-wb-refs-resolve.rb covers them):
#   * INTERNAL workbook refs: when a ref's PREFIX names an element of the
#     wb-spec itself, Sigma binds the ref to that element — so a master-level
#     calc column (absent from the DM by design) resolves against the element's
#     own columns/metrics instead of false-failing the DM check, and a ref to a
#     workbook element defined LATER in the document fails loudly (spec
#     dependency resolution is strictly forward-in-document-order —
#     refs/troubleshooting.md).
#   * SOURCE dependency checks: an element's source.elementId must exist in the
#     spec (and precede it, for table sources); a data-model source's elementId
#     must exist in the dm-ids readback (stale readback / wrong DM otherwise).
#   * --dm-id live mode PAGINATES /columns and fails refs that resolve ONLY to
#     columns whose type compiled to "error" (present but permanently broken).
#   * --dm-ids accepts both {pages:[{elements:[...]}]} (post-and-readback.rb
#     output) and a flat {elements:[...]} shape.
#
# Usage:
#   ruby assert-wb-refs-resolve.rb --wb-spec <spec.json> \
#     ( --dm-ids <dm-ids.json> | --dm-id <dataModelId> ) \
#     [--metrics <metrics.json>]  # optional explicit DM metrics census;
#                                 # auto-loads beside --dm-ids when present
#     [--workdir DIR]             # workdir for the off-ramp trail (the
#                                 # orchestrator passes it; a waived run
#                                 # records itself to offramps.jsonl)
#     [--skip-ref-check REASON]   # waive — REQUIRED reason; name it in your report
#
# Exit codes:
#   0  all refs resolve (or waived — a waiver with --workdir writes a
#      skip-flag-waived record to offramps.jsonl: PR-14 closed the escape that
#      let a --skip-ref-check run report "GREEN, 0 waivers")
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
  p.on('--metrics PATH', 'DM metrics census for [Metrics/<name>] references') { |v| opts[:metrics] = v }
  p.on('--workdir DIR', 'workdir for the off-ramp trail (a waiver is recorded there)') { |v| opts[:workdir] = v }
  p.on('--skip-ref-check REASON',
       'waive the ref-resolution gate — REQUIRED reason; name it in your report') { |v| opts[:skip] = v }
end.parse!

if opts[:skip]
  puts "[SKIP] workbook ref-resolution gate WAIVED (#{opts[:skip]}) — name this in your report."
  # PR-14: a skipped verification must leave a record — this exact flag once
  # produced a false "GREEN, 0 waivers" final because nothing wrote one.
  if opts[:workdir]
    begin
      $LOAD_PATH.unshift File.expand_path('lib', __dir__)
      require 'offramp'
      Offramp.log(opts[:workdir], kind: 'skip-flag-waived', reason: opts[:skip],
                  detail: '--skip-ref-check')
    rescue LoadError
      warn '       WARN: lib/offramp.rb not vendored — the waiver could not be recorded to offramps.jsonl.'
    end
  else
    warn '       WARN: no --workdir given — the waiver was NOT recorded to offramps.jsonl (pass --workdir).'
  end
  exit 0
end
abort 'usage: --wb-spec PATH and (--dm-ids PATH | --dm-id ID)' unless opts[:spec] && (opts[:dm_ids] || opts[:dm_id])

def norm(col)
  s = col.to_s.strip.downcase
  s = s.sub(/\s*\([^)]*\)\s*\z/, '') # drop a trailing "(disambiguating suffix)"
  s.gsub(/\s+/, ' ')
end

# --- collect the DM's available column labels (normalized) -----------------
available  = Set.new
error_cols = Set.new # normalized labels whose type compiled to "error" (live mode)
dm_el_ids  = Set.new # DM element ids (offline mode; for source.elementId checks)
metrics_census = nil # nil means no census was available; an empty Set is a valid empty census
add_metrics = lambda do |records|
  next unless records.is_a?(Array)
  metrics_census ||= Set.new
  records.each do |metric|
    name = metric.is_a?(Hash) ? metric['name'] : metric
    metrics_census << name.to_s.strip unless name.to_s.strip.empty?
  end
end
if opts[:dm_ids]
  idmap = JSON.parse(File.read(opts[:dm_ids], encoding: 'bom|utf-8'))
  dm_elements = if idmap['pages'].is_a?(Array)
                  idmap['pages'].flat_map { |pg| pg['elements'] || [] }
                else
                  idmap['elements'] || [] # flat readback shape
                end
  dm_elements.each do |el|
    dm_el_ids << el['id'] if el['id']
    (el['columnLabels'] || []).each { |l| available << norm(l) }
    add_metrics.call(el['metrics']) if el.key?('metrics')
  end
  add_metrics.call(idmap['metrics']) if idmap.key?('metrics')
else
  # Live fetch via the shared REST lib (self-mints a token). Paginated — big
  # DMs (the collapse case declared 599 columns) overflow a single page.
  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'
  clean = Set.new
  page = nil
  loop do
    qs = 'limit=500'
    qs += "&page=#{page}" if page
    data = (Sigma.request(:get, "/v2/dataModels/#{opts[:dm_id]}/columns?#{qs}") rescue nil)
    break unless data.is_a?(Hash)
    (data['entries'] || []).each do |c|
      next unless c['label']
      k = norm(c['label'])
      available << k
      c.dig('type', 'type') == 'error' ? error_cols << k : clean << k
    end
    page = data['nextPage']
    break if page.nil? || page.to_s.empty?
  end
  # A column that resolves cleanly in ANY element is usable even if a same-
  # named column errored elsewhere — only fail labels that ONLY error.
  error_cols.subtract(clean)

  # Metrics do not appear in /columns. Read the full data-model spec and build
  # a separate census from element metrics[]; never infer metrics from labels.
  dm_spec = (Sigma.request(:get, "/v2/dataModels/#{opts[:dm_id]}/spec") rescue nil)
  dm_doc = dm_spec.is_a?(Hash) && dm_spec['document'].is_a?(Hash) ? dm_spec['document'] : dm_spec
  if dm_doc.is_a?(Hash)
    add_metrics.call(dm_doc['metrics']) if dm_doc.key?('metrics')
    Array(dm_doc['pages']).each do |page_record|
      next unless page_record.is_a?(Hash)
      Array(page_record['elements']).each do |element|
        add_metrics.call(element['metrics']) if element.is_a?(Hash) && element.key?('metrics')
      end
    end
  end
end

metrics_file = opts[:metrics]
if metrics_file.nil? && opts[:dm_ids]
  sidecar = File.join(File.dirname(File.expand_path(opts[:dm_ids])), 'metrics.json')
  metrics_file = sidecar if File.exist?(sidecar)
end
if metrics_file
  begin
    metrics_doc = JSON.parse(File.read(metrics_file, encoding: 'bom|utf-8'))
    metrics_records = metrics_doc.is_a?(Hash) ? metrics_doc['metrics'] : metrics_doc
    abort "metrics census #{metrics_file} carries no metrics array" unless metrics_records.is_a?(Array)
    add_metrics.call(metrics_records)
  rescue JSON::ParserError, Errno::ENOENT => e
    abort "metrics census #{metrics_file} unreadable: #{e.message}"
  end
end

if available.empty?
  warn '[FAIL] workbook ref-resolution gate — the live DM reports ZERO columns.'
  warn '       The data model is empty/broken; do not POST the workbook against it.'
  warn '       (This is the multi-datasource-collapse signature — see the gap report.)'
  exit 1
end

wb = JSON.parse(File.read(opts[:spec], encoding: 'bom|utf-8'))
require_relative 'lib/workbook_code'

# --- workbook-internal element index (name → own columns, id → doc order) ---
wb_elements = WorkbookCode.elements(wb)
wb_order_by_id = {}
wb_internal = {} # element name -> { names: Set(normalized own column names), order: min doc index }
wb_elements.each_with_index do |el, i|
  wb_order_by_id[el['id']] = i if el['id']
  nm = el['name'].to_s.strip
  next if nm.empty?
  own = ((el['columns'] || []) + (el['metrics'] || [])).map { |c| norm(c['name']) if c['name'] }.compact
  rec = (wb_internal[nm] ||= { names: Set.new, order: i })
  rec[:names].merge(own)
  rec[:order] = [rec[:order], i].min
end

# --- extract every [Element/Column] ref, element by element (doc order) -----
REF = /\[([^\]\/]+)\/([^\]]+)\]/.freeze
refs = {}       # normalized column -> {display, elements:Set}  (unresolved-vs-DM report)
metric_refs = Set.new
metric_fails = {}
extra_fails = [] # forward-order / dangling-source / type=error findings
walk = lambda do |obj, &blk|
  case obj
  when Hash  then obj.each_value { |v| walk.call(v, &blk) }
  when Array then obj.each { |v| walk.call(v, &blk) }
  when String then obj.scan(REF) { |el, col| blk.call(el, col) }
  end
end

unresolved = {}
wb_elements.each_with_index do |el, i|
  el_desc = "\"#{el['name'] || el['id'] || '?'}\" (kind=#{el['kind'] || '?'})"

  # source-level dependency: the element the formulas' prefixes lean on
  src = el['source'] || {}
  own_names = Set.new(((el['columns'] || []) + (el['metrics'] || [])).filter_map do |column|
    norm(column['name']) if column['name']
  end)
  operator_prefixes = Set.new
  if src['kind'] == 'join'
    operator_prefixes << src['name'].to_s unless src['name'].to_s.empty?
    Array(src['joins']).each { |join| operator_prefixes << join['name'].to_s unless join['name'].to_s.empty? }
  elsif src['kind'] == 'union'
    operator_prefixes << src['name'].to_s unless src['name'].to_s.empty?
    count = Array(src['sources']).length
    operator_prefixes << "Union of #{count} Sources" if count.positive?
  end
  if src['kind'] == 'table' && src['elementId']
    tgt = wb_order_by_id[src['elementId']]
    if tgt.nil?
      extra_fails << "element #{el_desc}: source elementId \"#{src['elementId']}\" not found in the spec — POST fails with Dependency not found"
    elsif tgt > i
      extra_fails << "element #{el_desc}: source element \"#{src['elementId']}\" is defined LATER in the document (spec dependency resolution is strictly forward-in-document-order — refs/troubleshooting.md); move it before this element"
    end
  elsif src['kind'] == 'data-model' && src['elementId'] && opts[:dm_ids] && !dm_el_ids.empty? && !dm_el_ids.include?(src['elementId'])
    extra_fails << "element #{el_desc}: source data-model elementId \"#{src['elementId']}\" not in #{File.basename(opts[:dm_ids])} — stale readback or wrong DM"
  end

  walk.call(el) do |prefix, col_raw|
    if prefix.strip == 'Metrics'
      metric_name = col_raw.to_s.strip
      metric_refs << metric_name
      if metrics_census.nil?
        metric_fails[metric_name] =
          "no DM metrics census is available for [Metrics/#{metric_name}] — pass --metrics <workdir>/metrics.json, " \
          'keep metrics.json beside --dm-ids, or use a full DM spec/readback carrying metrics[]'
      elsif !metrics_census.include?(metric_name)
        known = metrics_census.to_a.sort
        metric_fails[metric_name] =
          "metric #{metric_name.inspect} is not in the DM metrics census " \
          "(#{known.empty? ? 'the census is EMPTY' : "known metrics: #{known.join(', ')}"})"
      end
      next
    end

    # A 3-part relationship ref [Element/RelName/Field] resolves THROUGH the DM
    # relationship — the actual column to check is the FINAL segment (Field); the
    # middle segment is a relationship name (existence validated DM-side by the
    # reachability guard), NOT a column. Resolving the whole "RelName/Field" string
    # as a column name was a false-negative on surfaced FIXED-LOD columns
    # (e.g. [Metric Series/FIXED Year/Revenue World]).
    #
    # TWO-SEGMENT ESCAPE (ported from mechanical-specs.rb's derived-rel checker,
    # the wave-2 slash fix): a COLUMN NAME may itself contain '/' (e.g.
    # "Date (Month /Year)", "Margin Pct H/L") — an unconditional split resolved
    # such a ref as its final fragment ("Year)"), a false FAIL, or a false PASS
    # when a real same-named column existed. If the WHOLE slashed tail names a
    # real column (in the DM or on the ref's own internal element), it is a
    # 2-segment [Element/Column] ref — check it as-is; only otherwise is the
    # tail a relationship path whose final segment is the column.
    col =
      if col_raw.include?('/')
        whole = norm(col_raw)
        internal_names = (wb_internal[prefix.strip] || {})[:names]
        if available.include?(whole) || internal_names&.include?(whole)
          col_raw
        else
          col_raw.split('/').last
        end
      else
        col_raw
      end
    k = norm(col)
    rec = (refs[k] ||= { display: col.strip, elements: Set.new })
    rec[:elements] << prefix.strip

    # Join and union sources expose local operator namespaces which are not DM
    # element names (ForecastJoin / Rates / Manual / Union of N Sources). A
    # matching output column is resolved by this element's own source operator,
    # not by the global DM column census.
    if operator_prefixes.include?(prefix.strip)
      if own_names.include?(k)
        next
      end
      extra_fails << "element #{el_desc}: [#{prefix.strip}/#{col.strip}] names a workbook-local " \
                     'join/union operator column that this element does not emit'
      next
    end

    if (internal = wb_internal[prefix.strip])
      # The prefix names an element of THIS spec — Sigma binds the ref to it.
      if internal[:names].include?(k)
        if internal[:order] > i
          extra_fails << "element #{el_desc}: [#{prefix.strip}/#{col.strip}] targets a workbook element defined LATER in the document — spec dependency resolution is strictly forward-in-document-order (refs/troubleshooting.md)"
        end
        next # resolves internally (order violations reported above)
      end
      # fall through: the element may have been renamed — give the global DM
      # check (upstream behavior) the final say before failing the ref.
    end

    if available.include?(k)
      if error_cols.include?(k)
        extra_fails << "element #{el_desc}: [#{prefix.strip}/#{col.strip}] resolves only to a DM column whose type compiled to \"error\" — the ref would never produce data"
      end
      next
    end
    unresolved[k] ||= { display: col.strip, elements: Set.new }
    unresolved[k][:elements] << prefix.strip
  end
end

if unresolved.empty? && metric_fails.empty? && extra_fails.empty?
  puts "[PASS] workbook ref-resolution gate: all #{refs.size} referenced column(s) and " \
       "#{metric_refs.size} referenced metric(s) resolve against the live DM " \
       "(#{available.size} columns, #{metrics_census&.size || 0} metrics) or the spec's own elements."
  exit 0
end

if unresolved.any?
  # Keep the progress count on the [FAIL] head. The retry breaker consumes
  # this exact shape to distinguish a converging repair (18 -> 17 misses)
  # from a repeating or growing failure.
  warn "[FAIL] workbook ref-resolution gate — #{unresolved.size} of #{refs.size} referenced " \
       "column(s) do NOT exist in the live DM " \
       "(#{available.size} columns):"
  unresolved.values.first(40).each do |r|
    warn "         ✗ #{r[:display]}   (referenced via #{r[:elements].to_a.map { |e| "[#{e}/…]" }.join(', ')})"
  end
  warn "         … and #{unresolved.size - 40} more." if unresolved.size > 40
elsif metric_fails.any?
  warn "[FAIL] workbook ref-resolution gate — #{metric_fails.size} of #{metric_refs.size} referenced " \
       'metric(s) failed the DM metrics census:'
else
  warn '[FAIL] workbook ref-resolution gate'
end
if metric_fails.any?
  warn "       #{metric_fails.size} of #{metric_refs.size} referenced metric(s) failed the DM metrics census:" \
    if unresolved.any?
  metric_fails.values.first(40).each { |failure| warn "         ✗ #{failure}" }
  warn "         … and #{metric_fails.size - 40} more." if metric_fails.size > 40
end
if extra_fails.any?
  warn "       plus #{extra_fails.size} structural failure(s):"
  extra_fails.first(20).each { |f| warn "         ✗ #{f}" }
  warn "         … and #{extra_fails.size - 20} more." if extra_fails.size > 20
end
warn ''
warn '       These refs would fail the workbook POST with "Dependency not found". The usual'
warn '       cause is a MULTI-DATASOURCE workbook the local converter collapsed onto one'
warn '       datasource (dropping the others\' columns) — see the multi_datasource gap report,'
warn '       and build a multi-element DM (or land + repoint the missing sources) before POSTing.'
warn '       Escape hatch (name it in your report): --skip-ref-check "<reason>".'
exit 1
