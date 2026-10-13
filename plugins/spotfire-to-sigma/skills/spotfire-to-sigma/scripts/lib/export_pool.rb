# frozen_string_literal: true
#
# export_pool.rb — BOUNDED element CSV export collection (issue #416).
#
# WHY. verify-anchors.rb and collect-parity-actuals.rb share the same element
# CSV export flow (POST /v2/workbooks/{wb}/export → poll
# GET /v2/query/{q}/download). Before this lib, --timeout bounded only the
# per-element POLL WAIT: the download of the CSV body, CSV.parse over it, and
# the per-cell scans were all unbounded, and the export itself carried no row
# cap — so a multi-million-row unaggregated detail grid (the shape a faithful
# 1:1 Tableau-table migration produces) hung the pool for 15+ minutes at 100%
# CPU with zero output (field-reported, 2026-07-17: 3 flat detail tables up to
# ~5.1M rows). Two fixes, both here so the scripts cannot drift apart:
#
#   1. Deadline — ONE wall-clock budget computed at process start. Every poll
#      loop and download checks it, so --timeout bounds TOTAL runtime.
#   2. rowLimit — Sigma's export API accepts a rowLimit (docs: "Export
#      workbook"; CSV/JSON/XLSX are truncated at 1M rows regardless), so the
#      export, the download, the CSV.parse, and every downstream scan are all
#      bounded by the caller's row cap. A bounded export can be TRUNCATED —
#      truncated?() detects it and callers MUST treat a miss/compare over a
#      truncated export as inconclusive, never as a hard verdict.
#
# The caller must `require 'sigma_rest'` first (this lib calls Sigma.request,
# which is exactly what the offline test stubs replace).

require 'json'
require 'timeout'
require 'digest'
require 'time'
require 'fileutils'

module ExportPool
  # Sigma truncates CSV/JSON/XLSX exports at 1M rows no matter what — a
  # rowLimit above this is meaningless (batch with `offset` if you truly need
  # more; none of these verification flows do).
  SIGMA_EXPORT_HARD_CAP = 1_000_000

  # ONE default export row bound shared by every caller (A3, wave-1 review):
  # verify-anchors.rb and collect-parity-actuals.rb used to default to
  # different rowLimits (anchors×10k min-50k vs a flat 100k) — and rowLimit is
  # part of the cache key, so their "shared" cache produced zero cross-script
  # hits on the typical 5–8-anchor run. Both scripts now floor at this value;
  # explicit --row-limit still overrides.
  DEFAULT_EXPORT_ROW_LIMIT = 100_000

  # ---------------------------------------------------------------------------
  # RAW export cache (#7a/#7d — speed review, reconciled program).
  #
  # verify-anchors.rb and collect-parity-actuals.rb run the SAME element export
  # wire flow, often against the SAME unchanged workbook (builder pass →
  # finalize → verifier re-run) — the most expensive live operation in a gate
  # run, paid 2–3x. This cache shares ONE export per element between them and
  # across re-runs, under the reconciled #7 RED LINE:
  #
  #   * RAW ONLY — the cache stores the untouched wire BODY (CSV/JSON bytes).
  #     Verdicts (truncation, anchor match, parity compare) are ALWAYS
  #     recomputed by the caller from those bytes. Nothing verdict-shaped is
  #     ever written here, so nothing verdict-shaped can ever be reused.
  #   * STRICT VERSION KEYS — every entry is bound to
  #     (workbookId, latestDocumentVersion, elementId, format, rowLimit).
  #     Any POST/PUT bumps latestDocumentVersion, so a stale payload can never
  #     match live state. An UNKNOWN doc version disables the cache entirely
  #     (fail-closed: no attribution, no reuse, no store).
  #   * AGE-BOUNDED — entries older than max_age_s (default 30 min, the
  #     repo-speed B4 acceptance rule) are ignored; live data can move under a
  #     live warehouse even when the workbook version does not.
  #   * BYTE-BOUND — each payload's sha256 is recorded at store time and
  #     re-verified at fetch; a swapped/corrupted payload is a MISS.
  #
  # Storage: <workdir>/export-cache/<elementId>.<fmt>[.r<rowLimit>] payload +
  # a .meta.json sidecar per entry. The workdir is machine-local run state
  # (never committed) — same hygiene class as the view CSVs beside it.
  # ---------------------------------------------------------------------------
  class Cache
    DIR = 'export-cache'
    DEFAULT_MAX_AGE_S = 30 * 60

    attr_reader :dir, :workbook_id, :doc_version

    def initialize(workdir, workbook_id:, doc_version:, max_age_s: DEFAULT_MAX_AGE_S)
      @dir = File.join(workdir, DIR)
      @workbook_id = workbook_id.to_s
      @doc_version = doc_version.nil? || doc_version.to_s.empty? ? nil : doc_version.to_s
      @max_age_s = max_age_s
      @hits = 0
      @stores = 0
    end

    # Enabled only when the payloads can be strictly attributed: a known
    # workbook AND a known live document version.
    def enabled?
      !@workbook_id.empty? && !@doc_version.nil?
    end

    def stats
      { 'hits' => @hits, 'stores' => @stores }
    end

    # → raw body String on a strict hit, else nil. A hit means: same workbook,
    # same latestDocumentVersion, same element, same format, young enough,
    # byte-identical to the recorded sha — and a rowLimit that SATISFIES the
    # request: the exact same limit, or (A3, wave-1 review) a cached entry
    # whose rowLimit ≥ the requested one AND whose body is UN-truncated w.r.t.
    # its own limit. An un-truncated bounded export is the element's COMPLETE
    # result set, so it is exactly what the smaller-bounded request would have
    # returned (callers re-run their own truncated?() over it — verdicts are
    # unchanged-or-better, never laundered). A cached body that FILLED its
    # limit stays a MISS for any other limit (it may differ from what the
    # request would fetch). NEVER returns verdicts — callers re-parse and
    # re-decide every time.
    def fetch(element_id, fmt, row_limit, now: Time.now)
      return nil unless enabled?
      # Exact-key fast path.
      body = fetch_entry(element_id, fmt, row_limit, row_limit, now)
      return body if body
      return nil if row_limit.nil? # an uncapped request accepts only an uncapped entry
      # ≥-acceptance path: any recorded entry for this element+format whose
      # limit covers the request (nil = uncapped ≥ everything). Largest first
      # so the most complete candidate wins.
      candidate_limits(element_id, fmt)
        .select { |cl| cl.nil? || cl >= row_limit.to_i }
        .reject { |cl| cl.to_s == row_limit.to_s }
        .sort_by { |cl| cl.nil? ? -Float::INFINITY : -cl }
        .each do |cl|
          body = fetch_entry(element_id, fmt, cl, row_limit, now)
          return body if body
        end
      nil
    rescue StandardError
      nil # a broken cache entry is a MISS, never an error
    end

    # Record one raw payload under the strict key. Best-effort: a failed write
    # only forfeits the future hit.
    def store(element_id, fmt, row_limit, body, now: Time.now)
      return nil unless enabled? && body.is_a?(String) && !body.empty?
      FileUtils.mkdir_p(@dir)
      File.binwrite(payload_path(element_id, fmt, row_limit), body)
      File.write(meta_path(element_id, fmt, row_limit), JSON.pretty_generate(
                   'workbook_id' => @workbook_id,
                   'doc_version' => @doc_version,
                   'element_id' => element_id.to_s,
                   'format' => fmt.to_s,
                   'row_limit' => row_limit.to_s,
                   'sha256' => Digest::SHA256.hexdigest(body),
                   'at' => now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')))
      @stores += 1
      true
    rescue StandardError
      nil
    end

    private

    # One entry's full strict check, shared by the exact and ≥ paths.
    # entry_limit names the stored entry; requested_limit the caller's bound —
    # they differ only on the ≥ path, where the body must additionally be
    # UN-truncated w.r.t. its OWN limit (complete result set) to stand in.
    def fetch_entry(element_id, fmt, entry_limit, requested_limit, now)
      meta = read_meta(element_id, fmt, entry_limit)
      return nil unless meta
      return nil unless meta['workbook_id'] == @workbook_id &&
                        meta['doc_version'] == @doc_version &&
                        # element_id equality (A7): the on-disk name is the
                        # SCRUBBED id, so two ids differing only in scrubbed
                        # chars would otherwise cross-serve.
                        meta['element_id'] == element_id.to_s &&
                        meta['format'] == fmt.to_s &&
                        meta['row_limit'].to_s == entry_limit.to_s
      at = (Time.parse(meta['at'].to_s) rescue nil)
      return nil if at.nil? || (now - at) > @max_age_s || (now - at) < 0
      body_path = payload_path(element_id, fmt, entry_limit)
      return nil unless File.exist?(body_path)
      body = File.binread(body_path)
      return nil unless Digest::SHA256.hexdigest(body) == meta['sha256']
      if entry_limit.to_s != requested_limit.to_s
        return nil unless complete_body?(body, fmt, entry_limit)
      end
      @hits += 1
      body
    rescue StandardError
      nil
    end

    # Data-row count strictly below the entry's own bound (the API hard cap
    # for an uncapped entry) = the export was NOT cut off = complete result
    # set. Counting parses the body (CSV rows can embed newlines) — paid only
    # on the rare cross-limit path, and still far cheaper than a wire export.
    def complete_body?(body, fmt, entry_limit)
      bound = entry_limit.nil? ? SIGMA_EXPORT_HARD_CAP : entry_limit.to_i
      n_rows =
        if fmt.to_s == 'json'
          ExportPool.parse_json_rows(body).length
        else
          require 'csv'
          [CSV.parse(body).length - 1, 0].max # minus the header row
        end
      n_rows < bound
    rescue StandardError
      false # unparseable body can never prove completeness
    end

    # Every stored rowLimit for one element+format (nil = the uncapped entry),
    # read from the meta sidecars.
    def candidate_limits(element_id, fmt)
      safe = element_id.to_s.gsub(/[^A-Za-z0-9._-]/, '_')
      Dir[File.join(@dir, "#{safe}.#{fmt}*.meta.json")].map do |p|
        m = File.basename(p)[/\.r(\d+)\.meta\.json\z/, 1]
        m && m.to_i
      end.uniq
    end

    def entry_base(element_id, fmt, row_limit)
      # elementId charset is [A-Za-z0-9_-] in practice; scrub defensively so a
      # hostile id can never escape the cache dir.
      safe = element_id.to_s.gsub(/[^A-Za-z0-9._-]/, '_')
      File.join(@dir, "#{safe}.#{fmt}#{row_limit ? ".r#{row_limit}" : ''}")
    end

    def payload_path(element_id, fmt, row_limit)
      entry_base(element_id, fmt, row_limit)
    end

    def meta_path(element_id, fmt, row_limit)
      "#{entry_base(element_id, fmt, row_limit)}.meta.json"
    end

    def read_meta(element_id, fmt, row_limit)
      p = meta_path(element_id, fmt, row_limit)
      return nil unless File.exist?(p)
      m = JSON.parse(File.read(p))
      m.is_a?(Hash) ? m : nil
    rescue StandardError
      nil
    end
  end

  # Whole-run wall-clock budget, created ONCE at the start of a run and shared
  # by every worker: when it expires, everything stops — poll loops, retries,
  # downloads, and elements not yet started.
  class Deadline
    attr_reader :budget

    def initialize(seconds)
      @t0 = Time.now
      @budget = seconds.to_f
    end

    def elapsed
      Time.now - @t0
    end

    def remaining
      @budget - elapsed
    end

    def expired?
      remaining <= 0
    end
  end

  module_function

  # POST the export, bounded to row_limit rows (nil = unbounded, discouraged).
  # Returns the queryId or nil.
  def start_csv_export(wb, element_id, row_limit)
    start_export(wb, element_id, 'csv', row_limit)
  end

  # JSON twin of start_csv_export. Sigma's element JSON export returns the
  # element's LONG-FORM rows (one object per row keyed by column display name),
  # and — unlike the CSV export — it does NOT 500 on a pivot carrying a `totals`
  # key. That makes it the automatic fallback for the pivot CSV-export platform
  # bug (see collect-parity-actuals.rb). Same POST shape, format.type = json.
  def start_json_export(wb, element_id, row_limit)
    start_export(wb, element_id, 'json', row_limit)
  end

  # POST /v2/workbooks/{wb}/export for one element in the given format
  # ('csv' | 'json'), bounded to row_limit rows (nil = unbounded). `params:`
  # (optional) carries control values ({controlId => value}) — the REST
  # export's `parameters` key, the only programmatic way to exercise a
  # non-default control value (see probe-controls.rb). Returns the queryId or
  # nil.
  def start_export(wb, element_id, fmt, row_limit, params: nil)
    body = { elementId: element_id, format: { type: fmt } }
    body[:rowLimit] = row_limit if row_limit
    body[:parameters] = params if params && !params.empty?
    r = Sigma.request(:post, "/v2/workbooks/#{wb}/export", body: JSON.generate(body))
    r && r['queryId']
  end

  # Poll for the rendered CSV and download it, bounded by the shared deadline.
  # Returns [:ok, body] | [:timeout, nil] | [:html, nil] (HTML behind a 200 =
  # renderer error). Raises Sigma::Error for non-404 HTTP failures (callers
  # keep their own retry/fallback policies).
  def poll_csv_download(qid, deadline, poll_interval: 1.0)
    poll_download(qid, deadline, accept: 'text/csv', poll_interval: poll_interval)
  end

  # JSON twin of poll_csv_download — same bounded-poll/download contract, same
  # return shape, only the Accept header differs.
  def poll_json_download(qid, deadline, poll_interval: 1.0)
    poll_download(qid, deadline, accept: 'application/json', poll_interval: poll_interval)
  end

  # Poll for the rendered export body and download it, bounded by the shared
  # deadline. `accept` selects the wire format ('text/csv' | 'application/json'
  # — both stream identically). Returns [:ok, body] | [:timeout, nil] |
  # [:html, nil] (HTML behind a 200 = renderer error). Raises Sigma::Error for
  # non-404 HTTP failures (callers keep their own retry/fallback policies).
  def poll_download(qid, deadline, accept:, poll_interval: 1.0)
    loop do
      return [:timeout, nil] if deadline.expired?
      sleep([poll_interval, [deadline.remaining, 0.05].max].min)
      return [:timeout, nil] if deadline.expired?
      begin
        # The download itself is bounded too: rowLimit keeps the body small,
        # and Timeout hard-caps a stalled or endlessly-streaming read at the
        # remaining budget (previously an unbounded multi-hundred-MB body read
        # was the first half of the silent hang).
        b = Timeout.timeout([deadline.remaining, 1.0].max) do
          Sigma.request(:get, "/v2/query/#{qid}/download", accept: accept, binary: true)
        end
        next if b.to_s.empty? # still rendering
        return [:html, nil] if b.to_s.lstrip.start_with?('<')
        return [:ok, b]
      rescue Timeout::Error
        return [:timeout, nil]
      rescue Sigma::Error => e
        raise unless e.message.lines.first.to_s =~ /\b404\b/ # not materialized yet — keep polling
      end
    end
  end

  # Parse a Sigma JSON-export body into an array of row hashes (each keyed by
  # column display name). Handles both `format.type:"json"` (one JSON array of
  # objects) and `"jsonl"`/NDJSON (one object per line), plus a defensive
  # {"rows"|"data": [...]} wrapper. Returns [] for a blank/empty body.
  def parse_json_rows(body)
    s = body.to_s.strip
    return [] if s.empty?
    parsed = (JSON.parse(s) rescue nil)
    case parsed
    when Array then parsed.select { |r| r.is_a?(Hash) }
    when Hash
      rows = parsed['rows'] || parsed['data']
      rows.is_a?(Array) ? rows.select { |r| r.is_a?(Hash) } : [parsed]
    else
      # NDJSON: one JSON object per line.
      s.each_line.map { |ln| JSON.parse(ln) rescue nil }.select { |r| r.is_a?(Hash) }
    end
  end

  # rows INCLUDE the header row. A bounded export that came back full is
  # conservatively truncated (the element may hold exactly row_limit rows, but
  # the caller cannot tell the difference — treat verdicts over it as
  # inconclusive either way).
  def truncated?(rows, row_limit)
    !row_limit.nil? && rows.is_a?(Array) && (rows.length - 1) >= row_limit
  end

  # The workbook document version off a spec GET / readback hash — the strict
  # cache-key half that changes on every POST/PUT. Accepts the documented
  # spec-level spelling and the workbook-metadata spelling; nil when absent
  # (callers treat nil as cache-disabling, never as "match anything").
  def resolve_doc_version(spec)
    return nil unless spec.is_a?(Hash)
    v = spec['latestDocumentVersion'] || spec['latestVersion']
    v.nil? || v.to_s.empty? ? nil : v.to_s
  end

  # ---------------------------------------------------------------------------
  # Pooled ground-truth SQL probes (#7c). The established warehouse-SQL seam
  # (probe-join-keys.rb / run-ground-truth.rb) pays FOUR REST calls per entry —
  # POST probe workbook, POST export, poll download, DELETE — fully serially.
  # This helper runs the same seam as ONE workbook: one spec POST carrying one
  # Custom SQL 'table' element per entry, exports pooled `pool`-wide against
  # the shared deadline, then ONE DELETE in ensure — ~4T calls become T+2 and
  # the wall clock divides by the pool width. Wire flow per element is
  # UNCHANGED (same export → poll → download the singleton path uses), so
  # per-entry verdicts (row counts, row-explosion, comparisons) stay the
  # caller's to compute — this is transport, not judgment.
  #
  # entries: [{ 'sql' => <statement>, 'columns' => [<alias>, ...] }, ...]
  # Returns: per-entry [ [:ok, rows] | [:timeout, nil] | [:error, msg] ]
  # (rows = CSV rows INCLUDING the header row, exactly like poll_csv_download
  # consumers expect). Raises only when the single probe-workbook POST itself
  # fails — nothing was created, nothing needs cleanup.
  #
  # REGISTRY-IN-POOL (E7.1 litter red line, wave-1 review): the pooled probe
  # workbook is REGISTERED in the ProbeRegistry immediately after the POST
  # parses — BEFORE the first export starts — and its DELETE outcome is marked
  # in the same ensure that deletes it, so a crash/SIGKILL anywhere between
  # POST and DELETE can never orphan the workbook untraceably
  # (sweep-run-artifacts.rb deletes leftovers from the registry). The lib is
  # soft-required so plugins that don't vendor probe_registry.rb still load;
  # where probe_registry.rb IS vendored alongside, registration is automatic —
  # callers cannot forget it. Where it is NOT (most export_pool twins ship
  # without it today), pooled probes run UNREGISTERED and the sweep cannot see
  # them — registration is automatic only where BOTH libs are vendored, not
  # wherever export_pool.rb alone is.
  # `workdir:`/`script:` only feed the registry record (signature extension by
  # options only — the positional/existing-kwarg contract is FROZEN; lane C's
  # batched probes are the second consumer).
  # ---------------------------------------------------------------------------
  def pooled_sql_probe(conn_id, entries, deadline, folder_id: nil, pool: 5,
                       row_limit: nil, name: nil, workdir: nil, script: nil)
    require 'csv'
    require 'securerandom'
    require 'code_rep' # vendored alongside export_pool.rb wherever this lib ships
    begin
      require 'probe_registry' # soft: present in plugins that vendor it
    rescue LoadError
      nil
    end
    return [] if entries.empty?
    elements = entries.each_with_index.map do |e, i|
      { 'id' => "probe#{i}", 'kind' => 'table', 'name' => "Probe #{i}",
        'source' => { 'kind' => 'sql', 'connectionId' => conn_id, 'statement' => e['sql'].to_s },
        'columns' => Array(e['columns']).each_with_index.map do |c, j|
          { 'id' => "c#{i}_#{j}", 'name' => c.to_s, 'formula' => "[Custom SQL/#{c}]" }
        end }
    end
    probe_name = name || "_probe_pooled_#{SecureRandom.hex(4)}"
    layout_elements = elements.each_with_index.map do |el, i|
      r0 = 1 + (i * 12)
      "  <Element elementId=\"#{el['id']}\" gridColumn=\"1 / 25\" gridRow=\"#{r0} / #{r0 + 12}\"/>"
    end
    layout = [
      '<?xml version="1.0" encoding="utf-8"?>',
      '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1">',
      *layout_elements,
      '</Page>'
    ].join("\n")
    doc = { 'schemaVersion' => 1,
            'pages' => [{ 'id' => 'p1', 'name' => 'p1' }],
            'elements' => elements,
            'layout' => layout }
    meta = { 'name' => probe_name }
    meta['folderId'] = folder_id if folder_id # omitted key = My Documents (API default)
    # The workbook code-rep surface nests non-metadata fields under a
    # top-level `document` key and rejects the old flat body with HTTP 400
    # (see code_rep.rb) — this pooled-probe POST is a second, independent
    # call site for that same surface (Task 3.2).
    body = JSON.generate(Sigma::CodeRep.wrap(doc, extra: meta))
    begin
      r = Sigma.request(:post, '/v2/workbooks/spec', body: body)
    rescue Sigma::Error => e
      raise "pooled probe workbook POST failed: #{e.message.to_s.gsub(/\s+/, ' ').strip[0, 240]}"
    end
    wb_id = r.is_a?(Hash) ? r['workbookId'] : nil
    raise "pooled probe workbook POST failed: #{r.inspect[0, 160]}" unless wb_id
    # Register FIRST — before any export can run (or raise). NEVER FATAL by
    # the registry's own contract, so bookkeeping cannot break the probe.
    if defined?(ProbeRegistry)
      ProbeRegistry.created(wb_id, name: probe_name, workdir: workdir,
                            script: script || 'pooled_sql_probe')
    end
    results = Array.new(entries.length)
    begin
      queue = Queue.new
      entries.each_index { |i| queue << i }
      mutex = Mutex.new
      Array.new([pool, entries.length].min.clamp(1, 16)) do
        Thread.new do
          loop do
            i = begin
              queue.pop(true)
            rescue ThreadError
              break
            end
            res =
              begin
                if deadline.expired?
                  [:timeout, nil]
                else
                  qid = start_csv_export(wb_id, "probe#{i}", row_limit)
                  if qid.nil?
                    [:error, 'export POST returned no queryId']
                  else
                    status, body = poll_csv_download(qid, deadline)
                    case status
                    when :timeout then [:timeout, nil]
                    when :html    then [:error, 'export returned HTML behind a 200 (renderer error)']
                    else               [:ok, CSV.parse(body)]
                    end
                  end
                end
              rescue StandardError => e
                [:error, e.message.to_s.gsub(/\s+/, ' ').strip[0, 240]]
              end
            mutex.synchronize { results[i] = res }
          end
        end
      end.each(&:join)
    ensure
      # ONE delete for the whole batch — the probe workbook never outlives the
      # call, even on timeout/error. The outcome is marked in the registry
      # (deleted | 404 | failed) so the sweep can tell cleaned from
      # outstanding; a failed delete leaves the entry outstanding for retry.
      begin
        Sigma.request(:delete, "/v2/files/#{wb_id}")
        ProbeRegistry.cleaned(wb_id, workdir: workdir, via: 'ensure') if defined?(ProbeRegistry)
      rescue StandardError => e
        if defined?(ProbeRegistry)
          begin
            ProbeRegistry.cleaned(wb_id, workdir: workdir, via: 'ensure',
                                  outcome: e.message.lines.first.to_s =~ /\b404\b/ ? '404' : 'failed')
          rescue StandardError
            nil
          end
        end
      end
    end
    results
  end

  # ---------------------------------------------------------------------------
  # Pooled exports of EXISTING workbook elements (W2.12 — flip-export pooling).
  # probe-controls.rb pays K×2 fully-serial element exports per gate run
  # (baseline + control-flip per control, plus leak checks); this runs the
  # same export → poll → download wire flow `pool`-wide. TRANSPORT ONLY: which
  # elements to export, what a differing/identical CSV means, and every
  # PASS/FAIL verdict stay the caller's. Each job gets its OWN
  # Deadline(timeout_per_job) — the exact per-CSV --timeout semantics the
  # serial path had, parallelized.
  #
  # jobs: [{ 'element_id' => <id>, 'params' => nil | {controlId => value},
  #          'row_limit' => nil | N }, ...]
  # Returns per-job [ [:ok, body] | [:timeout, nil] | [:error, msg] ] (body =
  # raw wire CSV bytes; callers parse and judge — never this lib).
  # ---------------------------------------------------------------------------
  def pooled_element_exports(wb, jobs, pool: 5, timeout_per_job: 90, poll_interval: 1.0)
    return [] if jobs.empty?
    results = Array.new(jobs.length)
    queue = Queue.new
    jobs.each_index { |i| queue << i }
    mutex = Mutex.new
    Array.new([pool, jobs.length].min.clamp(1, 16)) do
      Thread.new do
        loop do
          i = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          job = jobs[i]
          res =
            begin
              qid = start_export(wb, job['element_id'], 'csv', job['row_limit'],
                                 params: job['params'])
              if qid.nil?
                [:error, 'export POST returned no queryId']
              else
                status, body = poll_csv_download(qid, Deadline.new(timeout_per_job),
                                                 poll_interval: poll_interval)
                case status
                when :timeout then [:timeout, nil]
                when :html    then [:error, 'export returned HTML behind a 200 (renderer error)']
                else               [:ok, body]
                end
              end
            rescue StandardError => e
              [:error, e.message.to_s.gsub(/\s+/, ' ').strip[0, 240]]
            end
          mutex.synchronize { results[i] = res }
        end
      end
    end.each(&:join)
    results
  end

  # One progress line per pool event, stamped with run-elapsed seconds — the
  # pool is never silent for minutes. Single write() so concurrent workers
  # don't interleave mid-line; stderr so stdout contracts stay clean.
  def progress(deadline, msg)
    $stderr.write(format("  [pool +%6.1fs] %s\n", deadline.elapsed, msg))
  end
end
