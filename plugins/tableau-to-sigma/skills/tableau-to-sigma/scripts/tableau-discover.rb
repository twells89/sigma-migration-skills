#!/usr/bin/env ruby
# Phase-1 discovery via the Tableau REST API. Use this when you have a PAT —
# it is the FAST path (measured on "Orders Conversion Test": 61.8s serial →
# 13.7–18.9s with the unified pool). The Tableau MCP is the no-PAT fallback.
#
# Output layout (matches what the MCP-driven Phase 1 produces):
#   /tmp/<name>/get-workbook.json     — workbook metadata + view list
#   /tmp/<name>/ds-metadata.json      — VDS read-metadata response (field list + formulas)
#   /tmp/<name>/graphql-fields.json   — metadata API field list (cleaner formulas)
#   /tmp/<name>/views/<viewId>.csv    — every view's data CSV
#   /tmp/<name>/views/<viewId>.png    — dashboard view image only (skip other views by default)
#   /tmp/<name>/workbook-content.twb  — raw .twb XML (or .twbx zip bytes)
#   /tmp/<name>/timings.json          — per-task start/duration/attempts (ALWAYS
#                                       written — the evidence trail for any
#                                       future "discovery is slow" report)
#
# How it fetches: ONE shared thread pool (default 5, --pool N) covers EVERY
# network task — .twb download, VDS read-metadata, GraphQL fields, all view
# CSVs, and the dashboard PNG. Tasks are enqueued longest-job-first (PNG →
# CSVs → twb/VDS/GraphQL) so the slow PNG render hides behind the CSV batch.
# Only the initial workbook GET is serial (everything else needs its view
# list). 5 is the measured sweet spot; 8+ risks long-tail stragglers (a
# contended VizQL session can park one fetch for 40s+).
#
# Resilience (insurance — none of it fired in validation, keep it anyway):
#   * 429 / 408 / 5xx / timeouts retry with exponential backoff + jitter
#     (max 4 attempts).
#   * 401s are re-minted single-flight by lib/tableau_rest.rb (refresh_token!);
#     if a 401 still escapes that retry, the task wrapper re-mints once more.
#
# Usage:
#   eval "$(scripts/get-tableau-token.sh)"
#   ruby scripts/tableau-discover.rb \
#     --workbook-name "Orders Conversion Test" \
#     --datasource-name "ORDER_FACT (CSA.ORDER_FACT)+ (New Virtual Connection)" \
#     --out /tmp/orders [--pool 5]
#
# At least one of --workbook-id / --workbook-name is required.
# --datasource-luid / --datasource-name are optional (auto-detected from the
# .twb when omitted). --datasource-luid must be the FULL UUID — the REST
# filter has no prefix matching.

require 'json'
require 'fileutils'
require 'optparse'
require 'thread'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'tableau_rest'

opts = { fetch_view_images: 'dashboard-only', pool: 5 }
OptionParser.new do |o|
  o.on('--workbook-name NAME')    { |v| opts[:workbook_name] = v }
  o.on('--workbook-id ID')        { |v| opts[:workbook_id] = v }
  o.on('--datasource-name NAME')  { |v| opts[:datasource_name] = v }
  o.on('--datasource-luid LUID', 'FULL datasource UUID (no prefix matching)') { |v| opts[:datasource_luid] = v }
  o.on('--no-auto-ds', 'Disable .twb-based datasource auto-detect') { opts[:no_auto_ds] = true }
  o.on('--out DIR', 'Output directory (required)') { |v| opts[:out] = v }
  o.on('--skip-images')           { opts[:fetch_view_images] = 'none' }
  o.on('--all-view-images')       { opts[:fetch_view_images] = 'all' }
  o.on('--skip-content')          { opts[:skip_content] = true }
  o.on('--pool N', Integer, 'Fetch-pool size (default 5 — measured sweet spot)') { |v| opts[:pool] = v }
end.parse!

abort 'Missing --out' unless opts[:out]
abort 'Need --workbook-id or --workbook-name' unless opts[:workbook_id] || opts[:workbook_name]

FileUtils.mkdir_p(opts[:out])
FileUtils.mkdir_p(File.join(opts[:out], 'views'))

T0 = Time.now.to_f
TIMINGS = []
TIMINGS_MUTEX = Mutex.new
LOG_MUTEX = Mutex.new

def log(msg)
  LOG_MUTEX.synchronize { warn format('[%7.3f] %s', Time.now.to_f - T0, msg) }
end

# Atomic write: downstream interleaved callers (migrate-tableau.rb) poll for
# these artifacts while this script is still running — never let them observe
# a half-written file.
def atomic_write(path, bytes)
  tmp = "#{path}.tmp.#{Process.pid}"
  File.binwrite(tmp, bytes)
  File.rename(tmp, path)
end

# 400 is included: Tableau Cloud's VizQL layer intermittently 400s view/data
# exports under concurrent load (observed on the FATSCALE 44-view fat workbook:
# 5/44 CSVs 400'd on one run, all succeeded on the next) — a retry with backoff
# recovers them. A genuinely-bad request just burns the 4 attempts.
RETRYABLE = /\b(429|408|400|50[234])\b|Too Many Requests|timed? ?out|Timeout/i

# Run one named fetch task with timing + backoff-retry. Returns task result or nil.
def run_task(name)
  t0 = Time.now.to_f
  attempts = 0
  begin
    attempts += 1
    result = yield
    TIMINGS_MUTEX.synchronize do
      TIMINGS << { 'task' => name, 'start' => (t0 - T0).round(3),
                   'seconds' => (Time.now.to_f - t0).round(3), 'attempts' => attempts, 'ok' => true }
    end
    result
  rescue Tableau::Error, Timeout::Error, Errno::ETIMEDOUT, Net::ReadTimeout, Net::OpenTimeout => e
    msg = e.message.lines.first&.chomp || e.class.name
    if attempts < 4 && msg =~ RETRYABLE
      delay = (1.5 * (2**(attempts - 1))) + rand * 0.5
      log "#{name}: retryable (#{msg[0, 80]}) — backoff #{delay.round(1)}s (attempt #{attempts})"
      sleep delay
      retry
    elsif attempts < 3 && msg =~ /\b401\b/
      # lib already retried 401 once with a refreshed token; one more explicit
      # re-mint covers session invalidation racing across threads.
      log "#{name}: 401 escaped lib retry — re-minting token (attempt #{attempts})"
      (Tableau.refresh_token! rescue nil)
      sleep 1.0 + rand * 0.5
      retry
    end
    TIMINGS_MUTEX.synchronize do
      TIMINGS << { 'task' => name, 'start' => (t0 - T0).round(3),
                   'seconds' => (Time.now.to_f - t0).round(3), 'attempts' => attempts,
                   'ok' => false, 'error' => msg[0, 200] }
    end
    log "#{name}: FAILED after #{attempts} attempt(s): #{msg[0, 120]}"
    nil
  end
end

# --- 1. Workbook (serial — everything else depends on the view list) --------
wb = run_task('get-workbook') do
  w = if opts[:workbook_id]
        Tableau.get_workbook(opts[:workbook_id])
      else
        hit = Tableau.find_workbook_by_name(opts[:workbook_name])
        abort "No workbook found with name=#{opts[:workbook_name]}" unless hit
        Tableau.get_workbook(hit['id'])
      end
  atomic_write(File.join(opts[:out], 'get-workbook.json'), JSON.pretty_generate(w))
  w
end
abort 'workbook fetch failed' unless wb
views = wb.dig('views', 'view') || []
views = [views] unless views.is_a?(Array)
log "wrote get-workbook.json  (id=#{wb['id']} views=#{views.size})"

# --- 1b. Capability banner ---------------------------------------------------
# Tableau Server can lack VDS and the Metadata API that Cloud always exposes.
# Announce the mode up front so an operator isn't left debugging why
# ds-metadata.json / graphql-fields.json never appeared — the .twb XML path
# covers both calc-formula sources when those services are off.
caps = (Tableau.capabilities rescue {})
if caps.any?
  meta_state = caps['metadata_api'] ? 'available' : 'OFF → calc formulas from .twb XML'
  log "capabilities: product=#{caps['product_version'] || '?'} " \
      "REST API=#{caps['rest_api_version'] || '?'}  Metadata API: #{meta_state}"
  log 'note: VDS is probed per-datasource below; on failure discovery falls back to the .twb XML.' unless caps['metadata_api']
end

# --- 2. Build the task queue -------------------------------------------------
queue = Queue.new
twb_done = Queue.new # signals twb completion (for auto-ds fallback)

# 2a. twb download task (.twbx auto-extract preserved from the serial version)
unless opts[:skip_content]
  queue << lambda do
    bytes = run_task('twb-download') { Tableau.download_workbook_content(wb['id']) }
    twb_xml = nil
    if bytes
      if bytes.start_with?("PK\x03\x04")
        twbx_path = File.join(opts[:out], 'workbook-content.twbx')
        atomic_write(twbx_path, bytes)
        log "wrote workbook-content.twbx  (#{bytes.bytesize} bytes)"
        require 'tmpdir'
        Dir.mktmpdir do |tmp|
          unless system('unzip', '-o', '-q', twbx_path, '-d', tmp)
            log '.twbx auto-unzip failed (unzip command not available?); leaving .twbx in place'
          else
            inner = Dir.glob(File.join(tmp, '**', '*.twb')).first
            if inner
              twb_path = File.join(opts[:out], 'workbook-content.twb')
              atomic_write(twb_path, File.binread(inner))
              log "extracted workbook-content.twb  (#{File.size(twb_path)} bytes) from .twbx"
              # Force UTF-8: a bare File.read uses the locale default (US-ASCII on
              # many systems) and raises "invalid byte sequence in US-ASCII" on the
              # first non-ASCII byte (em-dash, @handles, curly quotes). The direct-
              # download branch below already force_encodes; the .twbx path must too.
              twb_xml = File.read(twb_path, encoding: 'UTF-8')
            else
              log '.twbx contained no inner .twb — odd'
            end
          end
        end
      else
        twb_path = File.join(opts[:out], 'workbook-content.twb')
        atomic_write(twb_path, bytes)
        log "wrote workbook-content.twb  (#{bytes.bytesize} bytes)"
        twb_xml = bytes.force_encoding('UTF-8')
      end
    end
    twb_done << twb_xml
  end
end

# 2b. datasource metadata tasks (VDS + GraphQL) — enqueued immediately when a
#     luid or name is supplied; otherwise chained after the twb task (the
#     .twb-caption auto-detect needs the downloaded XML).
ds_metadata_tasks = lambda do |ds_luid|
  queue << lambda do
    vds = run_task('vds-read-metadata') { Tableau.read_metadata(ds_luid) }
    if vds
      atomic_write(File.join(opts[:out], 'ds-metadata.json'), JSON.pretty_generate(vds))
      log "wrote ds-metadata.json  (#{vds.dig('data')&.size || 0} fields)"
    end
  end
  queue << lambda do
    gql = run_task('graphql-fields') { Tableau.graphql_datasource_fields(ds_luid) }
    if gql
      atomic_write(File.join(opts[:out], 'graphql-fields.json'), JSON.pretty_generate(gql))
      log 'wrote graphql-fields.json'
    end
  end
end

ds_luid = opts[:datasource_luid]
if ds_luid.nil? && opts[:datasource_name]
  hit = run_task('find-datasource') { Tableau.find_datasource_by_name(opts[:datasource_name]) }
  ds_luid = hit && hit['id']
end

auto_ds_pending = ds_luid.nil? && !opts[:no_auto_ds] && !opts[:skip_content]
ds_metadata_tasks.call(ds_luid) if ds_luid
if ds_luid.nil? && !auto_ds_pending
  warn 'no --datasource-luid/--datasource-name supplied (and auto-detect is unavailable); skipping VDS + GraphQL fetches'
end

# 2c. dashboard PNG task — IN THE POOL, queued BEFORE the CSVs (longest-job-
#     first: the PNG render is the longest single fetch; starting it at t≈0
#     hides it entirely behind the CSV batch).
case opts[:fetch_view_images]
when 'none'
  log 'skipping view images (--skip-images)'
when 'dashboard-only'
  # Heuristic: the view whose name matches "overview"/"dashboard", else the longest name.
  dash = views.find { |v| v['name'] =~ /\boverview\b|\bdashboard\b/i } ||
         views.max_by { |v| (v['name'] || '').length }
  if dash
    queue << lambda do
      png = run_task("png:#{dash['name']}") { Tableau.view_image(dash['id']) }
      if png
        atomic_write(File.join(opts[:out], 'views', "#{dash['id']}.png"), png)
        log "wrote views/#{dash['id']}.png  (dashboard: #{dash['name']}, #{png.bytesize} bytes)"
      end
    end
  end
when 'all'
  views.each do |v|
    queue << lambda do
      png = run_task("png:#{v['name']}") { Tableau.view_image(v['id']) }
      if png
        atomic_write(File.join(opts[:out], 'views', "#{v['id']}.png"), png)
        log "wrote views/#{v['id']}.png  (#{v['name']})"
      end
    end
  end
end

# 2d. view CSV tasks
views.each do |v|
  queue << lambda do
    csv = run_task("csv:#{v['name']}") { Tableau.view_data(v['id']) }
    if csv
      atomic_write(File.join(opts[:out], 'views', "#{v['id']}.csv"), csv)
      log "wrote views/#{v['id']}.csv  (#{v['name']}, #{csv.bytesize} bytes)"
    end
  end
end

# --- 3. Run the pool ----------------------------------------------------------
n_threads = [opts[:pool], queue.size + 1].min
n_threads = 1 if n_threads < 1
log "pool: #{n_threads} threads, #{queue.size} queued tasks#{auto_ds_pending ? ' (+VDS/GraphQL after twb auto-detect)' : ''}"

# Auto-ds chain: a watcher enqueues VDS/GraphQL once the twb lands.
watcher = nil
unless opts[:skip_content]
  watcher = Thread.new do
    twb_xml = twb_done.pop
    next unless auto_ds_pending
    unless twb_xml
      log 'auto-detect skipped — no .twb content; skipping VDS/GraphQL'
      next
    end
    caption = twb_xml.scan(/<datasource\s+caption='([^']+)'/).flatten
                     .reject { |c| c == 'Parameters' }
                     .first
    if caption
      bare = caption.sub(/\s*\+?\s*\(New Virtual Connection\)\s*$/i, '').strip
      found = nil
      %W[#{caption} #{bare}].uniq.each do |cand|
        hit = run_task("find-datasource:#{cand}") { Tableau.find_datasource_by_name(cand) }
        if hit
          found = hit['id']
          log "auto-detected datasource from .twb: #{cand.inspect} (luid=#{found})"
          break
        end
      end
      ds_metadata_tasks.call(found) if found
      log "could not resolve auto-detected datasource caption #{caption.inspect}; pass --datasource-luid to override" unless found
    else
      log 'auto-detect found no datasource caption in the .twb — skipping VDS/GraphQL'
    end
  end
end

pool = Array.new(n_threads) do
  Thread.new do
    loop do
      task = begin
               queue.pop(true)
             rescue ThreadError
               # queue momentarily empty — the auto-ds watcher may still add
               # tasks; spin until it's dead AND the queue is empty.
               if watcher && watcher.alive?
                 sleep 0.1
                 next
               end
               break
             end
      task.call
    end
  end
end
watcher&.join
pool.each(&:join)

# timings.json is ALWAYS written — it's the evidence trail when someone reports
# discovery slowness later (per-task start offsets show pool occupancy; attempts
# shows whether backoff/re-mint ever fired).
total = (Time.now.to_f - T0).round(3)
atomic_write(File.join(opts[:out], 'timings.json'),
             JSON.pretty_generate('total_seconds' => total, 'pool' => opts[:pool],
                                  'tasks' => TIMINGS.sort_by { |t| t['start'] }))
log "done. total=#{total}s (timings.json written)"
