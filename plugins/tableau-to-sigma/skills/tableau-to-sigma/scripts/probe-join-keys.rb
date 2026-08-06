#!/usr/bin/env ruby
# frozen_string_literal: true
# probe-join-keys.rb — PROVE (or refute) every join-plan.json grain assumption
# against the warehouse. Companion to scripts/lib/join_plan.rb (which derives
# the ledger at DM-build time) and assert-phase6-ran.rb gate 16 (exit 23),
# which refuses GREEN while any entry is unproven or unresolved non-unique.
#
# WHY: Sigma's Lookup() returns ONE ARBITRARY match per key. A Lookup (or
# federated-join right side) that is NOT unique at the key grain makes every
# aggregate over the looked-up column silently undercount — no error anywhere
# (field failure: target at user×date×line-item grain, key at user×date).
# "The join looks like a no-op" is likewise only provable by measuring the
# right side's key cardinality — never delete a LEFT JOIN without this proof.
#
# Per unprobed entry it runs, against the entry's right_table:
#   SELECT <keys>, COUNT(*) AS C FROM <right_table>
#     GROUP BY <keys> HAVING COUNT(*) > 1 ORDER BY C DESC LIMIT 5   -- sample dups
#   SELECT COUNT(*) AS TOTAL_ROWS, COUNT(DISTINCT <keys concat>) AS DISTINCT_KEYS
#     FROM <right_table>                                            -- totals
# A lookup-synthesis entry whose target is a Custom SQL element carries no
# right_table (null) but a right_sql statement — both queries then run against
# the statement wrapped as a subquery: FROM (<right_sql>) t.
#
# Execution reuses the established warehouse-SQL path (probe-custom-sql-columns.rb):
# a one-shot probe workbook with a Custom SQL element on the Sigma connection,
# CSV-exported then deleted — no new warehouse credential path. Offline tests
# use --fixture DIR (canned per-entry JSON results), the same offline seam
# convention as test-verify-warehouse.rb / vds-oracle.rb --vds-fixtures.
#
# Usage:
#   ruby scripts/probe-join-keys.rb --workdir <WORK> [--plan PATH]
#     --connection-id <id> [--folder-id <id>]     # live probe via Sigma;
#                            # no --folder-id → folderId omitted from the POST
#                            # (probe lands in My Documents, the API default)
#     [--fixture DIR]        # offline: DIR/entry-<index>.json per ledger entry:
#                            #   {"total": N, "distinct": M,
#                            #    "duplicates": [{"keys": {"COL": "v", ...}, "count": 3}, ...]}
#                            #   or {"error": "<message>"}
#   ruby scripts/probe-join-keys.rb --workdir <WORK> --resolve <INDEX> \
#     --how <preaggregated|waived> --reason "<evidence>"
#
# IDENTIFIER LEGALITY (W2.9): every identifier interpolated into the probe SQL
# passes through the single oracle, lib/sql_ident_check.rb — a legal bare name
# (ORDER_KEY) emits byte-identically to before, a spaced/mixed-case physical
# name emits double-quoted ("Order Key"), and a name the oracle REFUSES (the
# Tableau role-parenthetical residue PRODUCT_KEY_(PRODUCT_DIM), a GUID field
# id, quotes/control chars) is recorded as a clean status "error" and routed
# to the --resolve path below — it is NEVER guessed into live SQL.
#
# Results are written back into the ledger: status "unique" | "non-unique"
# (with counts + sample duplicate keys) | "error". A non-unique entry BLOCKS
# (FATAL block + nonzero exit) until resolved via --resolve, which records the
# evidence {how, reason, recorded_at} on the entry:
#   preaggregated — you added a grouped helper element at the key grain and
#                   repointed the Lookup at it (re-derive/re-probe if the spec
#                   changed materially);
#   waived        — operator escalation: a named human accepted the arbitrary-
#                   match risk; the reason must say who and why.
#
# Exit codes: 0 = every entry unique or resolved; 1 = bad invocation;
#             2 = unresolved non-unique entr(y/ies) remain (FATAL block printed);
#             3 = probe error(s) — entries left status "error" (gate still blocks).

require 'json'
require 'csv'
require 'optparse'
require 'securerandom'

# K12(a): how long to wait for a probe's CSV export before giving up. Bounded by
# wall-clock, not iteration count. The previous ~30s ceiling was routinely
# exceeded by a cold warehouse, which made the probe report a failure for a query
# that would have succeeded. Raise it for a very cold warehouse:
#   PROBE_EXPORT_TIMEOUT_S=600 ruby scripts/probe-join-keys.rb ...
PROBE_EXPORT_TIMEOUT_S = Integer(ENV.fetch('PROBE_EXPORT_TIMEOUT_S', '180'))
require_relative 'lib/sql_ident_check' # single identifier-legality oracle (W2.9)

opts = { dialect: 'snowflake' }
OptionParser.new do |p|
  p.on('--workdir DIR')        { |v| opts[:workdir] = v }
  p.on('--plan PATH')          { |v| opts[:plan] = v }
  p.on('--connection-id ID')   { |v| opts[:conn] = v }
  p.on('--folder-id ID')       { |v| opts[:folder] = v }
  p.on('--dialect D')          { |v| opts[:dialect] = v }
  p.on('--fixture DIR', 'offline: canned results, DIR/entry-<index>.json') { |v| opts[:fixture] = v }
  p.on('--resolve INDEX', Integer) { |v| opts[:resolve] = v }
  p.on('--how HOW', 'preaggregated|waived') { |v| opts[:how] = v }
  p.on('--reason R')           { |v| opts[:reason] = v }
end.parse!

plan_path = opts[:plan] || (opts[:workdir] && File.join(opts[:workdir], 'join-plan.json'))
abort 'usage: probe-join-keys.rb --workdir <WORK> [--plan PATH] (--connection-id <id> | --fixture DIR | --resolve N --how H --reason R)' unless plan_path
abort "FATAL: #{plan_path} not found — run the DM build first (migrate-tableau.rb derives the ledger)" unless File.exist?(plan_path)

doc = JSON.parse(File.read(plan_path))
entries = doc.is_a?(Hash) ? (doc['entries'] || []) : doc
abort "FATAL: #{plan_path} is malformed (expected {\"entries\":[...]} or a bare array)" unless entries.is_a?(Array)

save = lambda do
  if doc.is_a?(Hash)
    doc['entries'] = entries
    File.write(plan_path, JSON.pretty_generate(doc))
  else
    File.write(plan_path, JSON.pretty_generate(entries))
  end
end

now_utc = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

# ---------------------------------------------------------------------------
# --resolve: record evidence on a blocking entry, then fall through to the
# summary so the exit code reflects what (if anything) still blocks.
# ---------------------------------------------------------------------------
if opts[:resolve]
  abort '--resolve requires --how <preaggregated|waived>' unless %w[preaggregated waived].include?(opts[:how].to_s)
  abort '--resolve requires a non-empty --reason (the evidence recorded in the ledger)' if opts[:reason].to_s.strip.empty?
  e = entries[opts[:resolve]]
  abort "FATAL: no ledger entry at index #{opts[:resolve]} (#{entries.size} entr(y/ies))" unless e.is_a?(Hash)
  unless %w[non-unique error].include?(e['status'].to_s)
    abort "FATAL: entry #{opts[:resolve]} has status #{e['status'].inspect} — only non-unique/error entries take a resolution"
  end
  e['resolution'] = { 'how' => opts[:how], 'reason' => opts[:reason].strip, 'recorded_at' => now_utc }
  save.call
  puts "entry #{opts[:resolve]} (#{e['kind']}: #{e['left']} -> #{e['right']}) resolved: #{opts[:how]} — #{opts[:reason].strip}"
end

# ---------------------------------------------------------------------------
# SQL builders (also recorded on the entry, so the ledger is auditable).
# The `table`/`keys` arguments arrive PRE-EMITTED through emit_idents below —
# these builders never see a raw ledger name.
# ---------------------------------------------------------------------------
def dup_sql(table, keys)
  cols = keys.join(', ')
  "SELECT #{cols}, COUNT(*) AS C FROM #{table} GROUP BY #{cols} HAVING COUNT(*) > 1 ORDER BY C DESC LIMIT 5"
end

def totals_sql(table, keys)
  concat = keys.size == 1 ? keys.first : keys.map { |k| "COALESCE(TO_VARCHAR(#{k}), '')" }.join(" || '|' || ")
  "SELECT COUNT(*) AS TOTAL_ROWS, COUNT(DISTINCT #{concat}) AS DISTINCT_KEYS FROM #{table}"
end

# Emission gate (W2.9): map an entry's interpolable identifiers through the
# SINGLE legality oracle (SqlIdentCheck.sql_ident — no second regex anywhere).
#   keys    — each probe key's emission form (bare byte-identical, or quoted)
#   table   — the FROM target: the right_table FQN emitted part-by-part; or,
#             for a Custom-SQL Lookup target (right_table null, right_sql
#             recorded), the statement wrapped as a subquery "(<sql>) t"
#             (interpolated verbatim — it is a statement, not an identifier);
#             nil when the entry carries neither (pre-existing error path).
#   refused — [[name, reason], ...] every identifier the oracle refuses; any
#             refusal means NO SQL may be built or sent for this entry.
def emit_idents(entry)
  refused = []
  emit = lambda do |name|
    form = SqlIdentCheck.sql_ident(name)
    refused << [name, SqlIdentCheck.illegal_reason(name)] unless form
    form
  end
  keys = (entry['probe_keys'] || entry['keys'] || []).map(&emit)
  fqn = entry['right_table'].to_s
  table =
    if !fqn.empty?
      parts = fqn.split('.').map(&emit)
      parts.join('.') unless parts.include?(nil)
    else
      sql = entry['right_sql'].to_s
      sql.empty? ? nil : "(#{sql}) t"
    end
  { keys: keys, table: table, refused: refused }
end

# ---------------------------------------------------------------------------
# Result acquisition: fixture (offline) or the probe-workbook Custom SQL path.
# Returns {'total'=>N,'distinct'=>M,'duplicates'=>[{'keys'=>{},'count'=>n}]}
# or {'error'=>msg}.
# ---------------------------------------------------------------------------
def fixture_result(dir, idx)
  f = File.join(dir, "entry-#{idx}.json")
  return { 'error' => "no fixture #{File.basename(f)} in #{dir}" } unless File.exist?(f)
  JSON.parse(File.read(f))
rescue JSON::ParserError => e
  { 'error' => "fixture unparseable: #{e.message[0, 80]}" }
end

# Run one SQL statement through a one-shot probe workbook (the established
# warehouse-SQL seam — see probe-custom-sql-columns.rb) and return CSV rows.
# The created id is registered in the local probe registry BEFORE the first
# export (E7.1) and the ensure-DELETE appends the matching cleaned record, so
# a kill mid-export leaves a sweepable trace instead of silent litter.
def sigma_sql_rows(conn_id, folder_id, sql, columns, workdir: nil)
  spec = {
    'name' => "_probe_joinkeys_#{SecureRandom.hex(4)}",
    'schemaVersion' => 1,
    'pages' => [{ 'id' => 'p1', 'name' => 'p1', 'elements' => [{
      'id' => 'probe', 'kind' => 'table', 'name' => 'Probe',
      'source' => { 'kind' => 'sql', 'connectionId' => conn_id, 'statement' => sql },
      'columns' => columns.map { |c| { 'id' => "c-#{c.downcase.gsub(/[^a-z0-9]+/, '-')}", 'name' => c, 'formula' => "[Custom SQL/#{c}]" } }
    }] }]
  }
  # folderId only when the caller supplied one. An explicit `folderId: null`
  # is a live 400 (Twin B e2e); an OMITTED key lands the probe in My Documents
  # — the API default validate-spec.rb documents, stamped conditionally the
  # same way mechanical-specs.rb does.
  spec['folderId'] = folder_id if folder_id
  begin
    r = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec))
  rescue Sigma::Error => e
    # Keep the HTTP status AND the response-body excerpt on one line so the
    # recorded probe_error names the real cause, not a bare "400 Bad Request".
    raise "probe workbook POST failed: #{e.message.to_s.gsub(/\s+/, ' ').strip[0, 240]}"
  end
  wb_id = r.is_a?(Hash) ? r['workbookId'] : nil
  raise "probe workbook POST failed: #{r.inspect[0, 160]}" unless wb_id
  ProbeRegistry.created(wb_id, name: spec['name'], workdir: workdir,
                        script: 'probe-join-keys.rb')
  begin
    exp = Sigma.request(:post, "/v2/workbooks/#{wb_id}/export",
                        body: JSON.generate('elementId' => 'probe', 'format' => { 'type' => 'csv' }))
    qid = exp && exp['queryId']
    raise "export POST returned no queryId: #{exp.inspect[0, 160]}" unless qid
    csv = nil
    # K12(a): bound by WALL-CLOCK, not iteration count. The old `30.times` loop
    # gave a ~30s ceiling; a cold warehouse routinely exceeds it, so the probe
    # reported failure for a query that would have succeeded. Operators were
    # hand-patching this to 180s every run.
    started = Time.now
    i = 0
    while Time.now - started < PROBE_EXPORT_TIMEOUT_S
      sleep(i.zero? ? 0.5 : 1)
      i += 1
      begin
        b = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
        (csv = b) && break if b && !b.to_s.empty?
      rescue Sigma::Error => e
        raise unless e.message.lines.first.to_s =~ /\b404\b/
      end
    end
    unless csv
      raise "export did not complete in #{PROBE_EXPORT_TIMEOUT_S}s " \
            "(PROBE_EXPORT_TIMEOUT_S env var raises this; a cold warehouse can " \
            'legitimately need longer — this is not necessarily a probe failure)'
    end
    CSV.parse(csv, headers: true)
  ensure
    begin
      Sigma.request(:delete, "/v2/files/#{wb_id}")
      ProbeRegistry.cleaned(wb_id, workdir: workdir, via: 'ensure')
    rescue StandardError => e
      ProbeRegistry.cleaned(wb_id, workdir: workdir, via: 'ensure',
                            outcome: e.message.lines.first.to_s =~ /\b404\b/ ? '404' : 'failed')
    end
  end
end

# `em` is emit_idents(entry) — the SQL interpolates only oracle-emitted forms;
# the RAW key names still name the probe workbook's CSV columns (a quoted
# "Order Key" SELECT yields a CSV header of Order Key, the raw name).
def live_result(conn_id, folder_id, entry, em, workdir: nil)
  keys = entry['probe_keys'] || entry['keys']
  return { 'error' => 'no right_table FQN (or right_sql) on the entry — resolve the warehouse table and re-derive' } unless em[:table]
  dup_rows = sigma_sql_rows(conn_id, folder_id, dup_sql(em[:table], em[:keys]), keys + ['C'], workdir: workdir)
  tot_rows = sigma_sql_rows(conn_id, folder_id, totals_sql(em[:table], em[:keys]), %w[TOTAL_ROWS DISTINCT_KEYS], workdir: workdir)
  tot = tot_rows.first
  {
    'total'      => tot && tot['TOTAL_ROWS'].to_i,
    'distinct'   => tot && tot['DISTINCT_KEYS'].to_i,
    'duplicates' => dup_rows.map { |r|
      { 'keys' => keys.each_with_object({}) { |k, h| h[k] = r[k] }, 'count' => r['C'].to_i }
    }
  }
rescue StandardError => e
  # Flatten to one line but KEEP the whole message — the old lines.first
  # truncation dropped the HTTP response body (line 2 of Sigma::Error),
  # leaving a bare "400 Bad Request" with no hint at the real cause.
  { 'error' => e.message.to_s.gsub(/\s+/, ' ').strip[0, 300] }
end

# ---------------------------------------------------------------------------
# Probe every unprobed (or previously errored) entry.
# ---------------------------------------------------------------------------
unless opts[:resolve]
  abort 'provide --fixture DIR (offline) or --connection-id <id> (live probe)' unless opts[:fixture] || opts[:conn]
  if opts[:conn]
    $LOAD_PATH.unshift File.expand_path('lib', __dir__)
    require 'sigma_rest'
    require 'probe_registry'
  end
  entries.each_with_index do |e, i|
    next unless %w[unprobed error].include?(e['status'].to_s)
    keys = e['probe_keys'] || e['keys'] || []
    if keys.empty?
      e['status'] = 'error'
      e['probe_error'] = 'entry carries no key columns — re-derive the ledger'
      puts "  ERROR  ##{i} #{e['kind']}: #{e['left']} -> #{e['right']} — no key columns"
      next
    end
    # W2.9 legality gate: a refused identifier never reaches SQL — no probe_sql
    # is recorded, no fixture/live acquisition runs; the entry takes a clean
    # 'error' routed to the SAME --resolve path as any other blocked entry.
    em = emit_idents(e)
    unless em[:refused].empty?
      detail = em[:refused].map { |n, r| "#{n.inspect}: #{r}" }.join('; ')
      e['status'] = 'error'
      e['probe_error'] = "identifier(s) not legal to send to the warehouse — #{detail}. " \
                         'Re-derive the ledger (join_plan strips Tableau role parentheticals from probe keys), ' \
                         "or record an operator decision: --resolve #{i} --how waived --reason \"<operator>: <why>\""
      puts "  ERROR  ##{i} #{e['kind']}: #{e['left']} -> #{e['right']} — refused by the identifier legality oracle (no SQL sent): #{detail}"
      next
    end
    tgt = em[:table] || '<right_table>'
    e['probe_sql'] = { 'duplicates' => dup_sql(tgt, em[:keys]),
                       'totals'     => totals_sql(tgt, em[:keys]) }
    res = opts[:fixture] ? fixture_result(opts[:fixture], i) : live_result(opts[:conn], opts[:folder], e, em, workdir: opts[:workdir])
    e['probed_at'] = now_utc
    if res['error']
      e['status'] = 'error'
      e['probe_error'] = res['error']
      puts "  ERROR  ##{i} #{e['kind']}: #{e['left']} -> #{e['right']} — #{res['error']}"
      if res['error'] =~ /folder/i
        puts '         hint: the API rejected the folder placement — re-run with --folder-id <id> (a folder the token can edit; pick-destination.rb lists candidates)'
      end
      next
    end
    dups = res['duplicates'] || []
    total = res['total']
    distinct = res['distinct']
    e['counts'] = { 'total' => total, 'distinct' => distinct }
    if dups.empty? && total == distinct
      e['status'] = 'unique'
      e.delete('duplicates')
      puts "  UNIQUE  ##{i} #{e['kind']}: #{e['right']} unique on (#{keys.join(', ')}) — #{total} row(s), #{distinct} key(s)"
    else
      e['status'] = 'non-unique'
      e['duplicates'] = dups.first(5)
      puts "  NON-UNIQUE  ##{i} #{e['kind']}: #{e['right']} on (#{keys.join(', ')}) — #{total} row(s) over #{distinct} key(s)"
    end
  end
  save.call
end

# ---------------------------------------------------------------------------
# Summary + FATAL block for unresolved non-unique entries.
# ---------------------------------------------------------------------------
resolved = lambda { |e| e['resolution'].is_a?(Hash) && %w[preaggregated waived].include?(e['resolution']['how'].to_s) }
blocking = []
errored  = []
entries.each_with_index do |e, i|
  case e['status'].to_s
  when 'non-unique' then blocking << [i, e] unless resolved.call(e)
  when 'error'      then errored  << [i, e] unless resolved.call(e)
  end
end

blocking.each do |i, e|
  keys = (e['probe_keys'] || e['keys'] || []).join(', ')
  warn ''
  warn '==================== JOIN-CARDINALITY FATAL ===================='
  warn "entry ##{i} (#{e['kind']}): #{e['left']} -> #{e['right']} on (#{keys})"
  warn "  right side NOT unique at the key grain: #{e.dig('counts', 'total')} row(s) over #{e.dig('counts', 'distinct')} distinct key(s)"
  warn '  sample duplicate keys:'
  (e['duplicates'] || []).each do |d|
    kv = (d['keys'] || {}).map { |k, v| "#{k}=#{v}" }.join(' | ')
    warn "    #{kv}  -> #{d['count']} rows"
  end
  warn '  Sigma Lookup() returns ONE ARBITRARY match per key — every aggregate over'
  warn '  the looked-up column silently undercounts. Sanctioned resolutions:'
  warn '    (a) PRE-AGGREGATE the target to the key grain: add a grouped helper element'
  warn '        (grouped at the key columns, aggregating the looked-up measures), repoint'
  warn '        the Lookup at it, re-probe, then record the evidence:'
  warn "          ruby scripts/probe-join-keys.rb --workdir <W> --resolve #{i} --how preaggregated --reason \"<helper element name>\""
  warn '    (b) OPERATOR ESCALATION: stop and hand this entry to the migration operator;'
  warn '        if they accept the arbitrary-match risk, record who and why:'
  warn "          ruby scripts/probe-join-keys.rb --workdir <W> --resolve #{i} --how waived --reason \"<operator>: <why>\""
  warn '================================================================'
end

if blocking.any?
  warn "probe-join-keys: #{blocking.size} unresolved non-unique entr(y/ies) — the final gate (exit 23) will refuse GREEN."
  exit 2
end
if errored.any?
  warn "probe-join-keys: #{errored.size} entr(y/ies) could not be probed (status error) — fix and re-run; the final gate blocks until proven."
  exit 3
end
res_n = entries.count { |e| resolved.call(e) }
puts "probe-join-keys: #{entries.size} entr(y/ies) — #{entries.count { |e| e['status'] == 'unique' }} unique" \
     "#{res_n.positive? ? ", #{res_n} resolved (#{entries.select { |e| resolved.call(e) }.map { |e| e['resolution']['how'] }.uniq.join('/')})" : ''}. Ledger: #{plan_path}"
exit 0
