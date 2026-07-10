#!/usr/bin/env ruby
# Fetch the .twb (or .twbx, auto-unzipped) for every workbook on the current
# Tableau site, in parallel.
#
# Requires PAT-mode auth (TABLEAU_AUTH_TOKEN, TABLEAU_SITE_ID, TABLEAU_SERVER_URL).
# Run `eval "$(scripts/get-tableau-token.sh)"` in the same shell first.
#
# Designed for large sites (1000+ workbooks):
#   - Skips already-downloaded files (resumable across runs / restarts).
#   - Persistent HTTPS connection per worker thread (avoids per-request TLS handshake).
#   - Proactive token refresh every --refresh-min minutes + 401 retry inside
#     Tableau.request (long runs survive session timeout without manual re-auth).
#   - Adaptive backoff on 429 / 503.
#   - Per-minute progress + ETA so the user sees throughput live.
#
# Usage:
#   ruby scripts/fetch-all-twbs.rb --out /tmp/assessment-<site>
#   ruby scripts/fetch-all-twbs.rb --out /tmp/assessment-<site> --threads 16 --limit 50
#
# Output:
#   <out>/twbs/<luid>.twb   — raw XML, ready for scan-workbook-gaps.rb
#   <out>/twbs/<luid>.twbx  — only present when server returned a .twbx (unzipped to .twb alongside)
#   <out>/workbook-list.json
#   <out>/twb-fetch-results.json

require 'json'
require 'fileutils'
require 'optparse'
require 'thread'
require 'net/http'
require 'uri'
$LOAD_PATH.unshift File.expand_path('../../tableau-to-sigma/scripts/lib', __dir__)
require 'tableau_rest'
require 'py_resolve'

# Cross-platform replacement for shelling `unzip` (not present on stock
# Windows): Ruby has no stdlib zip reader, so this delegates to Python's
# stdlib `zipfile` via a Store-stub-safe interpreter (see lib/py_resolve.rb,
# shared across the tableau-to-sigma plugin's skills).
def unzip_extract(zip_path, dest_dir)
  require 'open3'
  code = 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])'
  _out, err, status = Open3.capture3(*PyResolve.argv, '-c', code, zip_path, dest_dir)
  warn "  unzip failed for #{zip_path}: #{err.strip[0, 300]}" if !status.success? && !err.to_s.strip.empty?
  status.success?
end

opts = { threads: 12, refresh_min: 60, limit: nil, force: false, exclude_projects: ['Personal Space'] }
OptionParser.new do |p|
  p.on('--out DIR')                { |v| opts[:out] = v }
  p.on('--threads N', Integer)     { |v| opts[:threads] = v }
  p.on('--limit N',   Integer)     { |v| opts[:limit] = v }
  p.on('--refresh-min N', Integer) { |v| opts[:refresh_min] = v }
  p.on('--force')                  { opts[:force] = true }
  # Comma-separated. Use --exclude-projects '' to include Personal Space.
  p.on('--exclude-projects LIST')  { |v| opts[:exclude_projects] = v.split(',').map(&:strip).reject(&:empty?) }
end.parse!
abort('--out required') unless opts[:out]

twb_dir = File.join(opts[:out], 'twbs')
FileUtils.mkdir_p(twb_dir)

warn "Listing workbooks via REST..."
all_wbs = []
page = 1
loop do
  resp = Tableau.request(:get, "#{Tableau.base_path}/workbooks?pageSize=100&pageNumber=#{page}")
  batch = resp.dig('workbooks', 'workbook') || []
  all_wbs.concat(batch)
  pag = resp['pagination'] || {}
  break if batch.empty? || all_wbs.size >= pag['totalAvailable'].to_i
  page += 1
end
warn "got #{all_wbs.size} workbooks"
File.write(File.join(opts[:out], 'workbook-list.json'), JSON.pretty_generate(all_wbs))

# Drop workbooks in excluded projects (default: "Personal Space").
# This matches the Phase 2 Admin Insights query filters — keeps the .twb corpus
# aligned with the workbook_inventory the readout will reference.
if opts[:exclude_projects].any?
  before = all_wbs.size
  all_wbs = all_wbs.reject { |w| opts[:exclude_projects].include?(w.dig('project', 'name')) }
  skipped = before - all_wbs.size
  warn "excluding projects #{opts[:exclude_projects].inspect}: dropped #{skipped} workbooks" if skipped.positive?
end

all_wbs = all_wbs.first(opts[:limit]) if opts[:limit]

# Resume: skip workbooks we already have a .twb or .twbx for.
existing = {}
unless opts[:force]
  Dir.glob(File.join(twb_dir, '*.{twb,twbx}')).each do |path|
    luid = File.basename(path).sub(/\.(twb|twbx)$/, '')
    existing[luid] = path
  end
end

todo = all_wbs.reject { |w| existing[w['id']] }
warn "resume: #{existing.size} already on disk, #{todo.size} to fetch" if existing.any?

queue = Queue.new
todo.each { |w| queue << w }
results = {}
mutex = Mutex.new
start_t = Time.now
done_count = 0
total = todo.size

# Pre-populate results for skipped files so output JSON is complete.
existing.each do |luid, path|
  results[luid] = {
    'name' => (all_wbs.find { |w| w['id'] == luid } || {})['name'],
    'path' => path,
    'size' => File.size(path),
    'kind' => path.end_with?('.twbx') ? 'twbx' : 'twb',
    'cached' => true
  }
end

# Background token refresher: re-signs in every refresh_min minutes so the
# session never goes stale mid-batch. The 401-retry inside Tableau.request is
# the belt; this is the suspenders. Skipped if no PAT env (will then surface a
# clear error on the first 401 instead).
refresh_stop = false
refresher = if ENV['TABLEAU_PAT_NAME'] && opts[:refresh_min].positive?
  Thread.new do
    interval = opts[:refresh_min] * 60
    loop do
      slept = 0
      while slept < interval
        break if refresh_stop
        sleep 5
        slept += 5
      end
      break if refresh_stop
      begin
        Tableau.refresh_token!
        warn "  [auth] proactive token refresh OK (#{Time.now.strftime('%H:%M:%S')})"
      rescue => e
        warn "  [auth] proactive refresh failed: #{e.message}"
      end
    end
  end
end

# Per-worker persistent connection. Net::HTTP keeps the TCP+TLS socket open
# across requests when reused, which on small workbooks shaves ~30% off latency
# (measured against 10ay.online.tableau.com).
def make_http
  uri = URI(Tableau.server_url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 300
  http.open_timeout = 30
  http.keep_alive_timeout = 30
  http.start
  http
end

# Adaptive backoff: 429 / 503 -> exponential sleep, up to 4 retries.
def fetch_with_backoff(http, luid)
  attempts = 0
  loop do
    begin
      return Tableau.request(:get, "#{Tableau.base_path}/workbooks/#{luid}/content?includeExtract=false",
                             accept: '*/*', binary: true, http: http)
    rescue Tableau::Error => e
      code = e.message[/-> (\d+)/, 1].to_i
      if [429, 503, 502, 504].include?(code) && attempts < 4
        attempts += 1
        wait = [2 ** attempts, 30].min
        warn "  backoff #{wait}s on #{code} for #{luid} (attempt #{attempts})"
        sleep wait
        next
      end
      raise
    end
  end
end

threads = opts[:threads].times.map do
  Thread.new do
    http = make_http
    while !queue.empty?
      w = queue.pop(true) rescue nil
      break unless w
      luid = w['id']
      name = w['name']
      begin
        bytes = fetch_with_backoff(http, luid)
        path =
          if bytes[0, 2] == 'PK'
            File.join(twb_dir, "#{luid}.twbx")
          else
            File.join(twb_dir, "#{luid}.twb")
          end
        File.binwrite(path, bytes)
        mutex.synchronize do
          results[luid] = {
            'name' => name,
            'path' => path,
            'size' => bytes.bytesize,
            'kind' => path.end_with?('.twbx') ? 'twbx' : 'twb'
          }
          done_count += 1
          if done_count % 10 == 0 || done_count == total
            elapsed = Time.now - start_t
            rate = done_count / elapsed
            eta = (total - done_count) / [rate, 0.01].max
            warn "  [#{done_count}/#{total}] #{rate.round(1)} wb/s  eta #{(eta/60).round(1)}m  last: #{name[0,50]}"
          end
        end
      rescue => e
        mutex.synchronize do
          results[luid] = { 'name' => name, 'error' => e.message }
          done_count += 1
          warn "  ERROR #{luid}  #{name}: #{e.message[0,200]}"
        end
      end
    end
    http.finish rescue nil
  end
end
threads.each(&:join)
refresh_stop = true
refresher&.kill

# Unzip .twbx → inner .twb (gap-scanner reads .twb XML directly)
unzip_queue = results.select { |_, r| !r['error'] && r['kind'] == 'twbx' && !r['cached'] }
warn "unzipping #{unzip_queue.size} .twbx files..."
unzip_queue.each do |luid, r|
  twb_path = File.join(twb_dir, "#{luid}.twb")
  next if File.exist?(twb_path) && File.size(twb_path) > 0
  tmp = File.join(twb_dir, "_unpack_#{luid}")
  FileUtils.mkdir_p(tmp)
  unless unzip_extract(r['path'], tmp)
    FileUtils.rm_rf(tmp)
    next
  end
  inner = Dir.glob(File.join(tmp, '**', '*.twb')).first
  if inner
    FileUtils.cp(inner, twb_path)
    r['twb_path'] = twb_path
    r['twb_size'] = File.size(twb_path)
  end
  FileUtils.rm_rf(tmp)
end

File.write(File.join(opts[:out], 'twb-fetch-results.json'), JSON.pretty_generate(results))
n_err = results.count { |_, r| r['error'] }
elapsed = Time.now - start_t
warn "done in #{elapsed.round(1)}s. wrote twb-fetch-results.json (#{results.size} workbooks, #{n_err} errors, #{existing.size} cached)"
exit(n_err.positive? && results.size == n_err ? 1 : 0)
