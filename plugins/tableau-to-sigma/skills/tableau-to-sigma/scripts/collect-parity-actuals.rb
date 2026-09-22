#!/usr/bin/env ruby
# frozen_string_literal: true
# collect-parity-actuals.rb — POOLED Sigma-side actuals collection for Phase 6.
#
# The actuals fetch used to be fully agent-mediated (one mcp-v2 query per chart,
# serially) — ~6 minutes of wall clock on a 40-chart fat workbook. Sigma's
# element CSV export (POST /v2/workbooks/{wb}/export → poll
# GET /v2/query/{q}/download — the same verified flow export-chart-png.rb uses)
# returns exactly the plotted channels of a chart element with column display
# names as headers, so it can fill the parity plan's actuals for every chart
# kind EXCEPT pivot-tables (their CSV export is the WIDE pivot grid, not the
# long row/col/value tuples the plan compares — verified on a wide field
# crosstab element 2026-06-12). Grouped "level" tables export in
# long form and ARE poolable (verified on el-fat-status-table).
#
# Pooled N-wide (default 5 — the discovery pool's measured sweet spot) with the
# same backoff-retry pattern tableau-discover.rb uses. Runs through
# lib/sigma_rest so the auto-refresh-on-401 applies mid-run.
#
# BOUNDED EXPORTS (issue #416). Every export POST carries Sigma's `rowLimit`
# (default 100k, --row-limit overrides, 0 = uncapped) and --timeout is the
# TOTAL wall-clock budget for the run — one deadline computed at start,
# checked by every poll loop, download, and retry backoff
# (lib/export_pool.rb). Previously --timeout bounded only each chart's poll
# wait (and each of up to 4 retries got a fresh window), so a multi-million-
# row unaggregated detail table hung the pool at 100% CPU with no output.
# A TRUNCATED export is a FAIL-LOUD condition here — parity over partial data
# is meaningless — so the chart is marked "too-large-for-export" and routed
# to the agent-mediated/warehouse path (never silently compared). The pool
# prints one progress line per chart start/finish.
#
# Usage (normally invoked by phase6-parity.rb pass 1):
#   ruby scripts/collect-parity-actuals.rb \
#     --plan <dir>/parity-plan.json --workbook-id <wb> \
#     --workbook-spec <dir>/wb-readback.json \
#     --out <dir>/parity-actuals.json [--pool 5] [--timeout 600] [--row-limit N]
#
# Output: --out gets { "<chart name>": [[v, v, ...], ...], ... } for every
# chart it could collect (MERGED into an existing file, never clobbering keys
# it didn't collect). Charts it cannot serve (pivot grids, export errors,
# unmappable columns) are listed on stdout — the agent supplies those via
# mcp-v2 (phase6-parity prints the exact queries).
#
# PIVOT-TOTALS JSON FALLBACK (SPEED — issue #422). Sigma's element CSV export
# 500s server-side for ANY pivot carrying a `totals` key (probe-isolated live;
# verify-anchors works around it by PUT-stripping the totals for the export
# window and restoring after). Here we take the cheaper, non-mutating route: the
# element's JSON export is UNAFFECTED by the totals key and returns the same
# long-form rows, so we simply read that instead — no PUT, no restore. Two entry
# points, both automatic (no agent mediation, no retry loop against the doomed
# CSV):
#   * PROACTIVE — the workbook spec shows the element carries a non-empty
#     `totals` key: skip the CSV round-trip entirely and read JSON straight away.
#     This is the recurring-time-sink fix: prior runs paid a failed CSV export +
#     agent-mediated re-collection on every totals pivot.
#   * REACTIVE — a CSV export that nonetheless 5xx's (a totals key we couldn't
#     see, control-driven pivots) falls back to the JSON export before giving up.
# When JSON returns real rows the chart is collected as :ok exactly like any
# other; only if JSON ALSO fails does the render-verify marker below apply.
#
# KNOWN-PLATFORM-BUG FALLBACK (SKILL_IMPROVEMENT_PLAN_V3 §D4): the element CSV
# export returns an EMPTY/HTML body (large pivots) — or BOTH the CSV and its JSON
# fallback 500 — while the rendered values are CORRECT. That must not fail the
# run and must not push agents into ad-hoc --min-pass-rate waivers: such charts
# are marked in --out as
#   { "status": "render-verify-required",
#     "reason": "pivot CSV export 500/empty (known Sigma limitation)" }
# and listed in ONE summary line — the agent verifies them via render-read or
# direct SQL, then sets "render_verified": true on the chart in parity-plan.json
# (or replaces the marker with real rows). verify-parity reports the marker as
# PENDING (never DIVERGE) until resolved.
#
# Exit codes: 0 = ran (collected what it could — uncollected charts are the
# AGENT's list, not a failure); 1 = bad invocation / no plan; 3 = --timeout
# total deadline expired mid-run (partial actuals written, timed-out charts
# marked {"status":"timeout"} and named on stdout).

require 'json'
require 'csv'
require 'optparse'
require 'thread'

DEFAULT_DRIFT_WARN_MIN = (ENV['PARITY_DRIFT_WARN_MINUTES'] || '30').to_f
opts = { pool: 5, timeout: 600, drift_warn_min: DEFAULT_DRIFT_WARN_MIN }
OptionParser.new do |p|
  p.on('--plan PATH')          { |v| opts[:plan] = v }
  p.on('--workbook-id ID')     { |v| opts[:wb] = v }
  p.on('--workbook-spec PATH') { |v| opts[:spec] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
  p.on('--pool N', Integer)    { |v| opts[:pool] = v }
  p.on('--timeout S', Integer, 'TOTAL wall-clock budget for the whole run (default 600). One deadline computed at start; every poll, download, and retry checks it. On expiry: per-chart "timeout" markers, partial actuals written, exit 3.') { |v| opts[:timeout] = v }
  p.on('--row-limit N', Integer, 'row cap per element CSV export (Sigma export rowLimit; default 100000, 0 = uncapped). A chart whose export is TRUNCATED at the cap is marked "too-large-for-export" and routed to the agent-mediated/warehouse path — parity over partial data is meaningless.') { |v| opts[:row_limit] = v }
  p.on('--drift-warn-minutes N', Float, 'ADVISORY live-drift threshold (default 30, or $PARITY_DRIFT_WARN_MINUTES; 0 = off). If the source captures the parity `expected` was built from are older than N minutes when these Sigma actuals are collected, emit a loud WARN — against a LIVE warehouse the data may have moved, so an expected/=actual gap can be drift, not a translation bug. Never a gate.') { |v| opts[:drift_warn_min] = v }
end.parse!
%i[plan wb spec out].each { |k| abort "missing --#{k.to_s.tr('_', '-')}" unless opts[k] }

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'export_pool'
require 'code_rep'

# Default = ExportPool::DEFAULT_EXPORT_ROW_LIMIT, the ONE shared default with
# verify-anchors.rb (A3, wave-1 review: rowLimit is part of the raw-export
# cache key; a divergent default defeated every cross-script cache hit).
# Resolved here — after the require — because the opts literal cannot see the
# constant; --row-limit still overrides (0 = uncapped).
_rl = opts.key?(:row_limit) ? opts[:row_limit].to_i : ExportPool::DEFAULT_EXPORT_ROW_LIMIT
ROW_LIMIT = _rl.positive? ? [_rl, ExportPool::SIGMA_EXPORT_HARD_CAP].min : nil

plan = JSON.parse(File.read(opts[:plan]))
charts = plan.is_a?(Hash) ? (plan['charts'] || []) : plan

# LIVE-DRIFT ADVISORY (issue #422). The parity `expected` values come from source
# view CSVs captured earlier (auto-parity-plan stamps the plan with
# `source_csv_max_mtime` = the newest source-capture time). We are collecting the
# Sigma actuals NOW. Against a LIVE warehouse the underlying data can move between
# those two reads, so an expected/=actual gap may be DRIFT, not a translation bug
# — a class phase-6 keeps rediscovering as if it were one. Warn LOUDLY (advisory,
# never a gate) when the gap exceeds the threshold, and name the remedy.
def source_capture_epoch(plan, plan_path)
  stamped = (plan['source_csv_max_mtime'] if plan.is_a?(Hash))
  return stamped.to_i if stamped
  # Fallback: newest source view CSV mtime under the workdir (the plan's dir).
  csvs = Dir.glob(File.join(File.dirname(plan_path), 'views', '*.csv'))
  csvs.map { |f| File.mtime(f).to_i }.max
end

if opts[:drift_warn_min].to_f.positive?
  src_epoch = source_capture_epoch(plan, opts[:plan])
  gap_min = src_epoch ? (Time.now.to_i - src_epoch) / 60.0 : nil
  if gap_min && gap_min > opts[:drift_warn_min]
    warn ''
    warn '=' * 70
    warn format('⚠️  LIVE-DRIFT RISK — source captured %.0f min ago (> %g min threshold)',
                gap_min, opts[:drift_warn_min])
    warn '=' * 70
    warn format('The parity `expected` values were built from source captures at %s,',
                Time.at(src_epoch).strftime('%Y-%m-%dT%H:%M:%S%z'))
    warn 'but the Sigma actuals are being collected NOW. If the warehouse is LIVE, its'
    warn 'data may have changed in between — a resulting expected/=actual gap is DRIFT,'
    warn 'NOT a translation bug. Do not rabbit-hole on it as one.'
    warn 'REMEDY (synchronized recapture): re-export the source view CSVs immediately'
    warn 'before this collection (or snapshot/freeze the warehouse), rebuild the plan'
    warn 'with phase6-parity --regen-plan so `expected` reflects the same data window,'
    warn 'then re-collect these actuals.'
    warn '(advisory only — tune with --drift-warn-minutes / $PARITY_DRIFT_WARN_MINUTES; 0 disables)'
    warn '=' * 70
    warn ''
  end
end

spec = JSON.parse(File.read(opts[:spec]))
# The --workbook-spec readback may be a flat artifact or a live response with
# the released top-level `document` envelope. Preserve response metadata for
# cache/version checks, while reading workbook-global elements through CodeRep.
spec = Sigma::CodeRep.metadata(spec).merge(Sigma::CodeRep.document(spec))
elements = Sigma::CodeRep.workbook_elements(spec)
el_by_id = elements.each_with_object({}) { |e, h| h[e['id']] = e }

# ── RAW export cache (#7a/#7d) + readback version check (#7b) ────────────────
# The post-POST readback (--workbook-spec, normally <WORK>/wb-readback.json) is
# THE spec source for this run — but only while its latestDocumentVersion still
# matches the live workbook (any new POST/PUT bumps it). When the readback
# carries a version, ONE live version probe validates it; on a match, the
# version-keyed raw export cache activates, shared with verify-anchors.rb:
# same (workbookId, latestDocumentVersion, elementId, format, rowLimit) keys,
# RAW wire bodies only, every mapping/truncation verdict recomputed below
# (the reconciled #7 red line — never a recorded verdict). A stale readback is
# named LOUDLY (spec source invalid → element ids may be wrong) and disables
# the cache; a version-less readback just keeps the old uncached behavior.
# (A def, not an inline begin/end: begin blocks leak their locals into the
# top-level scope, where the pool's per-thread `c = queue.pop` would silently
# become a SHARED variable — a live race, caught by test-parity-export-
# robustness.rb. Method scope contains them.)
def build_export_cache(spec, plan_path, wb, spec_path)
  rb_ver = ExportPool.resolve_doc_version(spec)
  return nil if rb_ver.nil? # hand-built / legacy readback without a version — nothing to key on
  live_ver = begin
    live = Sigma.request(:get, "/v2/workbooks/#{wb}/spec")
    live = JSON.parse(live) if live.is_a?(String)
    ExportPool.resolve_doc_version(live)
  rescue StandardError
    nil
  end
  if live_ver.nil?
    warn '[cache] raw export cache OFF — live version probe failed (payloads cannot be version-keyed)'
    nil
  elsif live_ver != rb_ver
    warn '=' * 70
    warn "⚠️  STALE READBACK — #{File.basename(spec_path)} is doc v#{rb_ver} but the live workbook is v#{live_ver}."
    warn '    The workbook changed since the readback was captured (a later POST/PUT). Element ids and'
    warn '    columns in the plan may no longer match the live spec. Re-run phase6-parity.rb PASS 1 to'
    warn '    refresh wb-readback.json. Raw export cache OFF for this run.'
    warn '=' * 70
    nil
  else
    warn "[cache] raw export cache active (wb #{wb} @ doc v#{live_ver}; " \
         'strict version keys, verdicts always recomputed)'
    ExportPool::Cache.new(File.dirname(plan_path), workbook_id: wb.to_s, doc_version: live_ver)
  end
end
CACHE = build_export_cache(spec, opts[:plan], opts[:wb], opts[:spec])

# Tableau-CSV-compatible cell parse — same rules as auto-parity-plan's
# parse_cell so expected/actual compare on identical representations.
def parse_cell(v, format = nil)
  return nil if v.nil? || v.to_s.strip.empty?
  s = v.to_s.strip
  pct = s.end_with?('%')
  if format.is_a?(Hash)
    grouping = format['digitGroupingSymbol'].to_s
    decimal = format['decimalSymbol'].to_s
    s = s.delete(grouping) unless grouping.empty? || grouping == decimal
    s = s.tr(decimal, '.') unless decimal.empty? || decimal == '.'
    currency = format['currencySymbol'].to_s
    s = s.delete(currency) unless currency.empty?
  end
  f = (Float(s.gsub(/[,$%]/, '')) rescue nil)
  return v if f.nil?
  pct ? f / 100.0 : f
end

RETRYABLE = /\b(429|408|50[234])\b|Too Many Requests|timed? ?out|Timeout/i
# 5xx after retries (or a non-retryable 500) = the known pivot-export platform
# bug → render-verify fallback, not a run failure.
SERVER_ERR = /\b5\d\d\b|Internal Server Error/i
RENDER_VERIFY_REASON = 'pivot CSV export 500/empty (known Sigma limitation)'

# Map a set of long-form export rows (already split into a header row + body
# rows of cells) onto the plan's wanted columns by DISPLAY NAME, consuming
# indices so duplicate names (x + color both "Region") bind in order. Shared by
# the CSV and JSON paths so both produce identical actuals tuples.
# Returns [:ok, rows] or [:fail, reason].
def map_columns(headers, body_rows, want_names, formats = nil)
  used = []
  idxs = want_names.map do |n|
    i = headers.each_index.find { |j| !used.include?(j) && headers[j].casecmp?(n) }
    used << i if i
    i
  end
  return [:fail, "export headers #{headers.inspect[0, 120]} missing column(s) #{want_names.zip(idxs).select { |_, i| i.nil? }.map(&:first).join(', ')}"] if idxs.any?(&:nil?)
  [:ok, body_rows.map { |r| idxs.each_with_index.map { |i, j| parse_cell(r[i], formats && formats[j]) } }]
end

# Pivot JSON-export fallback (issue #422). Reads the element's JSON export (long-
# form row objects, unaffected by the totals key that 500s the CSV export) and
# reshapes to the same actuals tuples the CSV path produces. Same return
# contract as collect_chart. NEVER retries — a JSON 5xx degrades straight to the
# render-verify marker (the CSV path already exhausted / skipped its retries).
def collect_chart_json(element_id, want_names, formats, wb, deadline)
  return [:timeout, "total --timeout (#{deadline.budget.round}s) deadline reached before JSON export"] if deadline.expired?
  # Version-keyed raw-cache hit (#7a): reuse the recorded wire body; the
  # reshape/mapping below is recomputed either way (never a recorded verdict).
  body = CACHE && CACHE.fetch(element_id, 'json', ROW_LIMIT)
  if body.nil?
    qid = ExportPool.start_json_export(wb, element_id, ROW_LIMIT)
    return [:fail, 'JSON export POST returned no queryId'] unless qid
    status, body = ExportPool.poll_json_download(qid, deadline)
    return [:timeout, "JSON export poll hit the total --timeout (#{deadline.budget.round}s) deadline"] if status == :timeout
    return [:manual, RENDER_VERIFY_REASON] if status == :html
    CACHE.store(element_id, 'json', ROW_LIMIT, body) if CACHE
  end
  objs = ExportPool.parse_json_rows(body)
  return [:manual, RENDER_VERIFY_REASON] if objs.empty?
  # Truncated at the row cap → a huge flat grid, not a comparable aggregate.
  if ROW_LIMIT && objs.length >= ROW_LIMIT
    return [:toolarge, "element JSON export truncated at rowLimit #{ROW_LIMIT} — parity over partial data is meaningless"]
  end
  headers = objs.first.keys.map { |h| h.to_s.strip }
  # Objects are uniform (one shape per export); align each row's values to the
  # first object's key order so map_columns' by-name index matching applies.
  body_rows = objs.map { |o| headers.map { |h| o[o.keys.find { |k| k.to_s.strip == h }] } }
  map_columns(headers, body_rows, want_names, formats)
rescue Sigma::Error, Timeout::Error, Errno::ETIMEDOUT => e
  msg = e.message.lines.first.to_s
  return [:manual, RENDER_VERIFY_REASON] if msg =~ SERVER_ERR
  [:fail, msg[0, 160]]
end

# One chart: export → poll → download → map plan columns by display name.
# Returns [:ok, rows] / [:skip, reason] / [:fail, reason] /
# [:manual, reason] (export empty/HTML, or CSV+JSON both 5xx → render-verify) /
# [:toolarge, reason] (export truncated at ROW_LIMIT — parity over partial
# data is meaningless; agent-mediated/warehouse path) /
# [:timeout, reason] (the shared total deadline expired).
def collect_chart(c, el_by_id, wb, deadline)
  return [:skip, 'pivot-table — CSV export is the wide grid; agent-mediated (mcp-v2)'] if c['sigma_kind'] == 'pivot-table'
  el = el_by_id[c['sigma_element_id']]
  return [:fail, 'element not in workbook spec'] unless el
  name_for = (el['columns'] || []).each_with_object({}) { |col, h| h[col['id']] = col['name'].to_s.strip }
  format_for = (el['columns'] || []).each_with_object({}) { |col, h| h[col['id']] = col['format'] }
  want_names = (c['sigma_columns'] || []).map { |id| name_for[id] }
  want_formats = (c['sigma_columns'] || []).map { |id| format_for[id] }
  return [:fail, "plan column id(s) missing from element: #{(c['sigma_columns'] || []).zip(want_names).select { |_, n| n.nil? }.map(&:first).join(', ')}"] if want_names.any?(&:nil?)

  # PROACTIVE pivot-totals fallback (SPEED — issue #422): a `totals` key 500s
  # this element's CSV export every time, so skip the doomed round-trip + retry
  # and read the JSON export straight away.
  if el.is_a?(Hash) && el.key?('totals') && !el['totals'].nil? &&
     !(el['totals'].respond_to?(:empty?) && el['totals'].empty?)
    return collect_chart_json(c['sigma_element_id'], want_names, want_formats, wb, deadline)
  end

  attempts = 0
  begin
    attempts += 1
    return [:timeout, "total --timeout (#{deadline.budget.round}s) deadline reached before export started"] if deadline.expired?
    # Version-keyed raw-cache hit (#7a): reuse the recorded wire body — the
    # truncation check and column mapping below are recomputed either way
    # (never a recorded verdict).
    body = CACHE && CACHE.fetch(c['sigma_element_id'], 'csv', ROW_LIMIT)
    if body.nil?
      qid = ExportPool.start_csv_export(wb, c['sigma_element_id'], ROW_LIMIT)
      return [:fail, 'export POST returned no queryId'] unless qid
      status, body = ExportPool.poll_csv_download(qid, deadline)
      return [:timeout, "export poll hit the total --timeout (#{deadline.budget.round}s) deadline"] if status == :timeout
      # HTML instead of CSV = the export renderer errored behind a 200 — same
      # class as the 500 (seen live on control-driven pivots).
      return [:manual, RENDER_VERIFY_REASON] if status == :html
      CACHE.store(c['sigma_element_id'], 'csv', ROW_LIMIT, body) if CACHE
    end
    rows = CSV.parse(body)
    # Truncated at the row cap: this "chart" is a huge flat detail grid, not a
    # comparable plotted aggregate. Parity over a partial export would be
    # meaningless — fail LOUD and route to the agent-mediated/warehouse path.
    if ExportPool.truncated?(rows, ROW_LIMIT)
      return [:toolarge, "element CSV export truncated at rowLimit #{ROW_LIMIT} — " \
                         'parity over partial data is meaningless']
    end
    # Empty / header-only exports (large pivots return a bodyless grid while the
    # rendered values are correct) → render-verify fallback, not a failure.
    return [:manual, RENDER_VERIFY_REASON] if rows.empty?
    headers = rows.shift.map { |h| h.to_s.strip }
    return [:manual, RENDER_VERIFY_REASON] if rows.empty?
    # Map each plan column to a CSV index by display name (shared with the JSON
    # path so both emit identical actuals tuples).
    map_columns(headers, rows, want_names, want_formats)
  rescue Sigma::Error, Timeout::Error, Errno::ETIMEDOUT, CSV::MalformedCSVError => e
    msg = e.message.lines.first.to_s
    if attempts < 4 && msg =~ RETRYABLE && !deadline.expired?
      # Backoff never sleeps past the shared deadline (each retry used to get
      # a fresh timeout window — one source of the unbounded total runtime).
      sleep([(1.5 * (2**(attempts - 1))) + rand * 0.5, [deadline.remaining, 0].max].min)
      retry
    end
    # A persistent 5xx (500 immediately; 502/503/504 after retries) is the known
    # pivot-export platform bug — try the JSON export (issue #422) before giving
    # up; only if THAT also fails does the render-verify marker apply.
    return collect_chart_json(c['sigma_element_id'], want_names, want_formats, wb, deadline) if msg =~ SERVER_ERR
    [:fail, msg[0, 160]]
  end
end

t_start = Time.now
# ONE deadline for the entire run (issue #416) — created before any export
# starts and shared by every worker, poll loop, download, and retry.
deadline = ExportPool::Deadline.new(opts[:timeout])
warn format('collect-parity-actuals: %d chart(s), pool=%d, row limit %s, total budget %ds',
            charts.size, [opts[:pool], charts.size].min.clamp(1, 16),
            ROW_LIMIT ? ROW_LIMIT.to_s : 'UNCAPPED', opts[:timeout])
queue = Queue.new
charts.each { |c| queue << c }
results = {}
mutex = Mutex.new
threads = Array.new([opts[:pool], charts.size].min.clamp(1, 16)) do
  Thread.new do
    loop do
      c = begin
        queue.pop(true)
      rescue ThreadError
        break
      end
      name = c['chart']
      if deadline.expired?
        # Deadline blown: record a clean per-chart timeout without starting.
        ExportPool.progress(deadline, "TIMEOUT #{name.inspect} — not started " \
                                      "(total --timeout #{opts[:timeout]}s reached)")
        mutex.synchronize { results[name] = [:timeout, "total --timeout (#{opts[:timeout]}s) deadline reached before export started"] }
        next
      end
      ExportPool.progress(deadline, "START   #{name.inspect} (#{c['sigma_element_id']})")
      t_el = Time.now
      status, payload = collect_chart(c, el_by_id, opts[:wb], deadline)
      note = case status
             when :ok      then "#{payload.length} row(s)"
             when :toolarge then 'TOO LARGE (truncated at row limit)'
             when :timeout then 'TIMEOUT'
             else status.to_s.upcase
             end
      ExportPool.progress(deadline, format('DONE    %s — %s in %.1fs', name.inspect, note, Time.now - t_el))
      mutex.synchronize { results[name] = [status, payload] }
    end
  end
end
threads.each(&:join)

ok       = results.select { |_, (s, _)| s == :ok }
skipped  = results.select { |_, (s, _)| s == :skip }
manual   = results.select { |_, (s, _)| s == :manual }
failed   = results.select { |_, (s, _)| s == :fail }
toolarge = results.select { |_, (s, _)| s == :toolarge }
timedout = results.select { |_, (s, _)| s == :timeout }

# Merge into --out (preserve any agent-collected keys already present).
existing = (JSON.parse(File.read(opts[:out])) rescue {}) if File.exist?(opts[:out])
existing ||= {}
ok.each { |name, (_, rows)| existing[name] = rows }
# Render-verify markers: never clobber real rows (agent-collected or from an
# earlier successful export) — only fill gaps / refresh stale markers. Charts
# already backed by rows need no verification and stay off the summary line.
marked = []
manual.each do |name, (_, reason)|
  next if existing[name].is_a?(Array)
  existing[name] = { 'status' => 'render-verify-required', 'reason' => reason }
  marked << name
end
# Too-large / timed-out charts: same never-clobber rule. Both markers keep the
# chart PENDING in verify-parity and routed to the agent-mediated/warehouse
# path (phase6-parity re-lists any non-Array, non-render-verify actual).
marked_toolarge = []
toolarge.each do |name, (_, reason)|
  next if existing[name].is_a?(Array)
  existing[name] = { 'status' => 'too-large-for-export', 'reason' => reason }
  marked_toolarge << name
end
marked_timeout = []
timedout.each do |name, (_, reason)|
  next if existing[name].is_a?(Array)
  existing[name] = { 'status' => 'timeout', 'reason' => reason }
  marked_timeout << name
end
File.write(opts[:out], JSON.pretty_generate(existing))

wall = (Time.now - t_start).round(1)
puts "collect-parity-actuals: #{ok.size}/#{charts.size} chart(s) collected via pooled CSV export " \
     "in #{wall}s (pool=#{opts[:pool]}) → #{opts[:out]}"
skipped.each { |name, (_, why)| puts "  AGENT-MEDIATED  #{name}: #{why}" }
if marked.any?
  puts "  RENDER-VERIFY REQUIRED (#{marked.size}): #{marked.join(', ')} — " \
       "#{RENDER_VERIFY_REASON}; marked in #{opts[:out]}; verify each via render-read or direct SQL, " \
       'then set "render_verified": true on the chart in parity-plan.json (or replace the marker with rows).'
end
if marked_toolarge.any?
  puts "  TOO LARGE FOR EXPORT (#{marked_toolarge.size}): #{marked_toolarge.join(', ')} — " \
       "export truncated at rowLimit #{ROW_LIMIT}; parity over partial data is meaningless. " \
       "Marked \"too-large-for-export\" in #{opts[:out]}; supply these via an agent-mediated (mcp-v2) " \
       'AGGREGATE query or the warehouse SQL oracle — or add an element filter so the tile exports fewer rows.'
end
failed.each  { |name, (_, why)| puts "  NOT COLLECTED   #{name}: #{why} — agent must supply via mcp-v2" }
if timedout.any?
  puts "  TIMEOUT (#{timedout.size}): #{timedout.keys.join(', ')} — total --timeout #{opts[:timeout]}s " \
       "deadline reached; partial actuals written to #{opts[:out]} (timed-out charts marked " \
       '"timeout"). Re-run with a higher --timeout, or supply these charts via mcp-v2/warehouse SQL.'
  exit 3
end
exit 0
