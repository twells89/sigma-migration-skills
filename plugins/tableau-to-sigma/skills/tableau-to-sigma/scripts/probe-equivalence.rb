#!/usr/bin/env ruby
# frozen_string_literal: true
# probe-equivalence.rb — PROVE (or refute) that a structural edit to source
# semantics is a no-op, BEFORE the edit ships (PLAN-v3 PR-8). Companion to
# scripts/lib/equivalence_probe.rb (SQL builders + judging + ledger) and
# assert-phase6-ran.rb gate 20 (exit 27), which refuses GREEN while any
# declared edit lacks a proof or its proof says match:false.
#
# WHY: in a field migration an agent deleted a LEFT JOIN as "provably no-op"
# with zero verification — the key was a non-unique flag column, so the join
# was fanning out rows and eliding it CHANGED the numbers (corpus twin:
# corpus/tableau/join-elision-fanout). "Provably no-op" is only provable by
# measuring BOTH sides; this script is the measurement. Any join drop, table
# collapse, or filter rewrite must be declared + proven here before it ships.
#
# Per side it runs ONE probe statement through the established warehouse seam
# (the one-shot probe-workbook Custom SQL path probe-join-keys.rb /
# run-ground-truth.rb use — no new credential path):
#   SELECT COUNT(*) AS TOTAL_ROWS,
#          COUNT(DISTINCT <grain concat>) AS DISTINCT_GRAIN
#          [, SUM(<measure>) AS SUM_<MEASURE> ...]
#   FROM (<side's whole SQL>) EQ_PROBE
# and records both sides + the verdict in <workdir>/semantic-edits.json.
# A mismatch is FATAL (both sides' numbers printed): the edit is NOT a no-op
# — revert it or redesign it until the probes agree. There is NO waive path:
# an intentionally-different rewrite is not an equivalence claim and belongs
# in the user-initiated scope-change record, never in this ledger.
#
# WITHDRAW (the only sanctioned way to clear a refuted entry — never hand-edit
# the ledger): a REFUTED edit that was consequently NOT APPLIED is withdrawn
# with --withdraw "<edit_description>" --reason "<why>". The entry moves to
# the ledger's `withdrawn` array VERBATIM (its refuted proof stays as
# evidence) plus withdrawn_reason + withdrawn_at; gate 20 (assert-phase6-
# ran.rb) ignores withdrawn entries but reports them informationally. Only a
# refuted entry is withdrawable — an unproven one must be re-probed first (a
# claim is measured before it is withdrawn). HONESTY NOTE: withdrawal ATTESTS
# the edit was not applied; whether its SQL nonetheless shipped is not
# detectable mechanically — gates 16/18 remain the numeric net for an edit
# that rode along anyway.
#
# Usage:
#   ruby scripts/probe-equivalence.rb --workdir <WORK> \
#     --edit "<what the edit is>" --claim "<the no-op claim being proven>" \
#     --grain COL[,COL...] \
#     ( --before-sql <SQL or @file> --after-sql <SQL or @file>
#     | --before-element <NAME> --after-element <NAME>
#       [--before-dm-spec PATH] [--after-dm-spec PATH]   # default <WORK>/dm-spec.json;
#                              # point --before-dm-spec at the pre-edit spec snapshot )
#     [--measures COL[,COL...]]  # SUM-checksum columns; element mode derives
#                                # them from Sum([X]) columns when omitted
#     ( --connection-id <id> [--folder-id <id>]   # live probe via Sigma
#     | --fixture DIR )          # offline: DIR/before.json + DIR/after.json:
#                                #   {"total": N, "distinct": M,
#                                #    "sums": {"AMOUNT": 123.4, ...}}
#                                #   or {"error": "<message>"}
#     [--timeout S]              # TOTAL deadline for both sides (default 600;
#                                #   bounded-exports convention — never hangs)
#     [--ledger PATH]            # default <WORK>/semantic-edits.json
#
# Withdraw mode (no probe runs; nothing else may be probed in the same call):
#   ruby scripts/probe-equivalence.rb --workdir <WORK> \
#     --withdraw "<edit_description>" --reason "<why the refuted edit was not applied>"
#
# Exit codes: 0 = every declared edit proven equivalent (match:true), or a
#                 successful --withdraw;
#             1 = bad invocation, or --withdraw refused (entry not found /
#                 proven / unproven);
#             2 = mismatch — the sides are NOT equivalent (FATAL block printed;
#                 gate 20 will refuse GREEN, exit 27);
#             3 = probe error / deadline — entry left without a proof (still
#                 blocks GREEN until re-probed).

require 'json'
require 'csv'
require 'optparse'
require 'securerandom'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'equivalence_probe'
require_relative 'lib/workbook_code'

$stdout.sync = true # progress lines interleave correctly with the FATAL block

opts = { timeout: 600 }
OptionParser.new do |p|
  p.on('--workdir DIR')          { |v| opts[:dir] = v }
  p.on('--edit DESC', 'what the edit IS (the ledger key; re-probing the same edit replaces its entry)') { |v| opts[:edit] = v }
  p.on('--claim TEXT', 'the equivalence claim being proven (e.g. "join contributes no shelf column; elision is a no-op")') { |v| opts[:claim] = v }
  p.on('--grain COLS', 'comma-separated declared-grain columns for COUNT(DISTINCT ...)') { |v| opts[:grain] = v.split(',').map(&:strip).reject(&:empty?) }
  p.on('--before-sql SQL', 'pre-edit statement (or @path to read it from a file)')  { |v| opts[:before_sql] = v }
  p.on('--after-sql SQL', 'post-edit statement (or @path to read it from a file)')  { |v| opts[:after_sql] = v }
  p.on('--before-element NAME', 'pre-edit DM element (SQL extracted from --before-dm-spec)') { |v| opts[:before_el] = v }
  p.on('--after-element NAME', 'post-edit DM element (SQL extracted from --after-dm-spec)')  { |v| opts[:after_el] = v }
  p.on('--before-dm-spec PATH', 'spec for --before-element (default <WORK>/dm-spec.json — point at the PRE-EDIT snapshot)') { |v| opts[:before_dm] = v }
  p.on('--after-dm-spec PATH', 'spec for --after-element (default <WORK>/dm-spec.json)') { |v| opts[:after_dm] = v }
  p.on('--measures COLS', 'comma-separated numeric columns for SUM checksums (element mode derives Sum([X]) columns when omitted)') { |v| opts[:measures] = v.split(',').map(&:strip).reject(&:empty?) }
  p.on('--connection-id ID')     { |v| opts[:conn] = v }
  p.on('--folder-id ID')         { |v| opts[:folder] = v }
  p.on('--fixture DIR', 'offline: canned results, DIR/before.json + DIR/after.json') { |v| opts[:fixture] = v }
  p.on('--timeout S', Integer, 'TOTAL deadline for both sides (default 600)') { |v| opts[:timeout] = v }
  p.on('--ledger PATH', 'default <WORK>/semantic-edits.json') { |v| opts[:ledger] = v }
  p.on('--withdraw DESC', 'withdraw a REFUTED edit that was NOT applied: moves its entry (refuted proof preserved verbatim as evidence) to the ledger\'s withdrawn array; requires --reason') { |v| opts[:withdraw] = v }
  p.on('--reason TEXT', 'WHY the refuted edit was not applied (required with --withdraw)') { |v| opts[:reason] = v }
end.parse!

USAGE = 'usage: probe-equivalence.rb --workdir <WORK> --edit "<desc>" --claim "<claim>" --grain COL[,COL] ' \
        '(--before-sql S --after-sql S | --before-element N --after-element N) ' \
        '(--connection-id <id> | --fixture DIR) [--measures COL,COL] [--timeout S]' \
        "\n       probe-equivalence.rb --workdir <WORK> --withdraw \"<edit_description>\" --reason \"<why not applied>\""
def bad(msg)
  warn "FATAL: #{msg}"
  warn USAGE
  exit 1
end

bad('--workdir required') unless opts[:dir]

ledger_path = opts[:ledger] || File.join(opts[:dir], 'semantic-edits.json')

# ---------------------------------------------------------------------------
# Withdraw mode — the ONLY sanctioned way to clear a REFUTED-and-not-applied
# entry (hand-editing the ledger is forbidden; that was previously the only
# way out, which is exactly why this path exists). The entry moves VERBATIM
# (refuted proof preserved as evidence) to the doc's `withdrawn` array with
# withdrawn_reason + withdrawn_at; gate 20 ignores withdrawn entries but
# reports them informationally.
# ---------------------------------------------------------------------------
if opts[:withdraw]
  bad('--withdraw takes no probe flags (--edit/--claim/--grain/sides) — it only moves an existing refuted entry') if
    opts[:edit] || opts[:claim] || opts[:grain] || opts[:before_sql] || opts[:after_sql] || opts[:before_el] || opts[:after_el]
  bad('--reason required with --withdraw (WHY was the refuted edit not applied?)') if opts[:reason].to_s.strip.empty?
  bad("no ledger at #{ledger_path} — nothing to withdraw") unless File.exist?(ledger_path)
  doc = begin
    EquivalenceProbe.load(ledger_path)
  rescue JSON::ParserError => e
    bad("#{ledger_path} unparseable: #{e.message[0, 80]} — fix or remove it (do not hand-edit proofs)")
  end
  status, moved = EquivalenceProbe.withdraw(doc, opts[:withdraw], opts[:reason].strip)
  case status
  when :not_found
    warn "FATAL: no declared entry matches --withdraw #{opts[:withdraw].inspect} in #{ledger_path}."
    known = doc['entries'].select { |e| e.is_a?(Hash) }.map { |e| e['edit_description'] }
    warn "       Declared edits: #{known.empty? ? '(none)' : known.map(&:inspect).join(', ')}"
    exit 1
  when :proven
    warn "FATAL: #{opts[:withdraw].inspect} is PROVEN equivalent (match:true) — it does not block and there is"
    warn '       nothing to withdraw. If the edit was later reverted, re-probe the current before/after pair.'
    exit 1
  when :unproven
    warn "FATAL: #{opts[:withdraw].inspect} has no refuted proof — withdrawal requires the measurement as evidence."
    warn "       #{moved['probe_error'] ? "Last probe errored: #{moved['probe_error'].to_s[0, 120]}" : 'The entry was declared but never probed.'}"
    warn '       Re-probe first (a claim is measured before it is withdrawn): if the probe REFUTES it and the'
    warn '       edit is therefore not applied, withdraw then; if it PROVES it, nothing blocks.'
    exit 1
  end
  EquivalenceProbe.write(ledger_path, doc)
  puts "probe-equivalence: WITHDREW #{moved['edit_description'].inspect} — refuted and not applied " \
       "(reason: #{moved['withdrawn_reason']})."
  puts "  The refuted proof is preserved verbatim in the ledger's withdrawn[] as evidence; gate 20 no longer"
  puts '  blocks on this entry but will report it informationally.'
  puts '  HONESTY NOTE: withdrawal attests the edit was NOT applied. Whether its SQL nonetheless shipped is'
  puts '  not detectable mechanically — gates 16/18 remain the numeric net for an edit that rode along anyway.'
  puts "  Ledger: #{ledger_path}"
  exit 0
end

bad('--reason only applies to --withdraw') if opts[:reason]
bad('--edit required (the ledger key describing the structural edit)') if opts[:edit].to_s.strip.empty?
bad('--claim required (the equivalence claim the probe is testing)') if opts[:claim].to_s.strip.empty?
bad('--grain required (the declared grain to COUNT DISTINCT)') if Array(opts[:grain]).empty?
bad('provide --fixture DIR (offline) or --connection-id <id> (live probe)') unless opts[:fixture] || opts[:conn]

# ---------------------------------------------------------------------------
# Resolve each side's SQL (+ derivable measures) — literal, @file, or DM
# element extraction. Element mode reads the element's Custom SQL statement
# verbatim or SELECT *s its physical table path.
# ---------------------------------------------------------------------------
read_json = lambda do |path|
  return nil unless path && File.exist?(path)
  JSON.parse(File.read(path, encoding: 'UTF-8'))
rescue JSON::ParserError => e
  bad("#{path} unparseable: #{e.message[0, 80]}")
end

derived_measures = []
resolve_side = lambda do |label, sql_opt, el_opt, dm_opt|
  if sql_opt
    sql = sql_opt.start_with?('@') ? (File.exist?(sql_opt[1..-1]) ? File.read(sql_opt[1..-1], encoding: 'UTF-8') : bad("--#{label}-sql file #{sql_opt[1..-1]} not found")) : sql_opt
    bad("--#{label}-sql is empty") if sql.to_s.strip.empty?
    sql.strip
  elsif el_opt
    dm_path = dm_opt || File.join(opts[:dir], 'dm-spec.json')
    dm = read_json.call(dm_path)
    bad("--#{label}-element needs #{dm_path} (or --#{label}-dm-spec PATH)") unless dm
    el = EquivalenceProbe.find_element(dm, el_opt)
    bad("element #{el_opt.inspect} not found in #{dm_path}") unless el
    sql = EquivalenceProbe.element_sql(el)
    bad("element #{el_opt.inspect} carries neither a Custom SQL statement nor a table path") unless sql
    EquivalenceProbe.element_measures(el).each { |m| derived_measures << m unless derived_measures.include?(m) }
    sql
  else
    bad("side #{label.inspect} unspecified — pass --#{label}-sql or --#{label}-element")
  end
end

before_sql = resolve_side.call('before', opts[:before_sql], opts[:before_el], opts[:before_dm])
after_sql  = resolve_side.call('after',  opts[:after_sql],  opts[:after_el],  opts[:after_dm])

measures = Array(opts[:measures]).empty? ? derived_measures : opts[:measures]
if measures.empty?
  warn 'WARN: no SUM checksums — no --measures given and none derivable from the spec.'
  warn '      Counts alone can miss a value-only drift; pass --measures <numeric cols> when any exist.'
end

grain = opts[:grain]
probe = { 'before' => EquivalenceProbe.probe_sql(before_sql, grain, measures),
          'after'  => EquivalenceProbe.probe_sql(after_sql, grain, measures) }

# ---------------------------------------------------------------------------
# Result acquisition: fixture (offline) or the probe-workbook Custom SQL seam.
# Returns {'total'=>N,'distinct'=>M,'sums'=>{...}} or {'error'=>msg}.
# ---------------------------------------------------------------------------
def fixture_result(dir, side)
  f = File.join(dir, "#{side}.json")
  return { 'error' => "no fixture #{File.basename(f)} in #{dir}" } unless File.exist?(f)
  JSON.parse(File.read(f))
rescue JSON::ParserError => e
  { 'error' => "fixture unparseable: #{e.message[0, 80]}" }
end

# Run one SQL statement through a one-shot probe workbook (the established
# warehouse-SQL seam — see probe-join-keys.rb / run-ground-truth.rb) and
# return parsed CSV rows. `deadline` bounds the export poll so a stuck query
# cannot outlive the run's total budget (bounded-exports convention).
def sigma_sql_rows(conn_id, folder_id, sql, columns, deadline, workdir: nil)
  spec = {
    'name' => "_probe_equivalence_#{SecureRandom.hex(4)}",
    'schemaVersion' => 1,
    'pages' => [{ 'id' => 'p1', 'name' => 'p1', 'elements' => [{
      'id' => 'probe', 'kind' => 'table', 'name' => 'Probe',
      'source' => { 'kind' => 'sql', 'connectionId' => conn_id, 'statement' => sql },
      'columns' => columns.each_with_index.map { |c, i| { 'id' => "c#{i}", 'name' => c, 'formula' => "[Custom SQL/#{c}]" } }
    }] }]
  }
  spec['folderId'] = folder_id if folder_id
  begin
    # The current workbook API accepts the released nested `document` shape
    # with document-global elements and layout-owned page membership. The
    # legacy flat pages[].elements body is rejected before either SQL probe can
    # run, leaving every declared semantic edit permanently unproven.
    post_body = WorkbookCode.canonicalize(spec)
    r = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(post_body))
  rescue Sigma::Error => e
    raise "probe workbook POST failed: #{e.message.to_s.gsub(/\s+/, ' ').strip[0, 240]}"
  end
  wb_id = r.is_a?(Hash) ? r['workbookId'] : nil
  raise "probe workbook POST failed: #{r.inspect[0, 160]}" unless wb_id
  ProbeRegistry.created(wb_id, name: spec['name'], workdir: workdir,
                        script: 'probe-equivalence.rb')
  begin
    exp = Sigma.request(:post, "/v2/workbooks/#{wb_id}/export",
                        body: JSON.generate('elementId' => 'probe', 'format' => { 'type' => 'csv' }))
    qid = exp && exp['queryId']
    raise "export POST returned no queryId: #{exp.inspect[0, 160]}" unless qid
    csv = nil
    loop do
      raise 'export poll hit the total --timeout deadline' if Time.now > deadline
      sleep 1
      begin
        b = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
        (csv = b) && break if b && !b.to_s.empty?
      rescue Sigma::Error => e
        raise unless e.message.lines.first.to_s =~ /\b404\b/
      end
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

def live_result(conn_id, folder_id, sql, measures, deadline, workdir: nil)
  cols = EquivalenceProbe.probe_columns(measures)
  rows = sigma_sql_rows(conn_id, folder_id, sql, cols, deadline, workdir: workdir)
  row = rows.first
  raise 'probe returned no rows' unless row
  sums = {}
  measures.each { |m| sums[m] = row[EquivalenceProbe.sum_alias(m)] }
  { 'total' => row['TOTAL_ROWS'].to_s.strip, 'distinct' => row['DISTINCT_GRAIN'].to_s.strip, 'sums' => sums }
rescue StandardError => e
  { 'error' => e.message.to_s.gsub(/\s+/, ' ').strip[0, 300] }
end

if opts[:conn]
  $LOAD_PATH.unshift File.expand_path('lib', __dir__)
  require 'sigma_rest'
  require 'probe_registry'
end

t0 = Time.now
deadline = t0 + opts[:timeout]
now_utc = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')

sides = {}
errors = {}
%w[before after].each_with_index do |side, i|
  ts = Time.now
  raw = if opts[:fixture]
          fixture_result(opts[:fixture], side)
        elsif Time.now > deadline
          { 'error' => "total --timeout #{opts[:timeout]}s expired before the #{side} side ran" }
        else
          live_result(opts[:conn], opts[:folder], probe[side], measures, deadline, workdir: opts[:dir])
        end
  elapsed = (Time.now - ts).round(1)
  if raw['error']
    errors[side] = raw['error']
    puts "  [#{i + 1}/2] ERROR  #{side} — #{raw['error'][0, 160]} (#{elapsed}s)"
  else
    sides[side] = EquivalenceProbe.side_metrics(raw, measures)
    m = sides[side]
    puts "  [#{i + 1}/2] ok     #{side} — #{m['total']} row(s), #{m['distinct_grain']} distinct grain key(s)" \
         "#{measures.empty? ? '' : ', sums: ' + m['sums'].map { |k, v| "#{k}=#{v.inspect}" }.join(' ')} (#{elapsed}s)"
  end
end

# ---------------------------------------------------------------------------
# Record the entry (upsert by edit_description) — an errored probe leaves the
# entry WITHOUT a proof block, which blocks GREEN exactly like an unproven
# declaration.
# ---------------------------------------------------------------------------
entry = {
  'edit_description' => opts[:edit].strip,
  'claim'            => opts[:claim].strip,
  'grain'            => grain,
  'measures'         => measures,
  'before'           => { 'sql' => before_sql, 'probe_sql' => probe['before'] },
  'after'            => { 'sql' => after_sql,  'probe_sql' => probe['after'] }
}
if errors.any?
  entry['probe_error'] = errors.map { |s, e| "#{s}: #{e}" }.join(' | ')
else
  mm = EquivalenceProbe.mismatches(sides['before'], sides['after'])
  entry['proof'] = {
    'mode'       => opts[:fixture] ? 'fixture' : 'live',
    'before'     => sides['before'],
    'after'      => sides['after'],
    'match'      => mm.empty?,
    'mismatches' => mm,
    'probed_at'  => now_utc
  }
end

doc = begin
  EquivalenceProbe.load(ledger_path)
rescue JSON::ParserError => e
  bad("#{ledger_path} unparseable: #{e.message[0, 80]} — fix or remove it (do not hand-edit proofs)")
end
entries = doc['entries']
EquivalenceProbe.upsert(entries, entry)
# Write the WHOLE doc back — unknown top-level keys (an operator's
# withdrawal_note, the withdrawn array, future fields) round-trip verbatim.
EquivalenceProbe.write(ledger_path, doc)

# ---------------------------------------------------------------------------
# FATAL block on mismatch + whole-ledger summary (the gate reads the same
# file; this exit mirrors what gate 20 / exit 27 will decide).
# ---------------------------------------------------------------------------
if entry['proof'] && !entry['proof']['match']
  b = entry['proof']['before']
  a = entry['proof']['after']
  warn ''
  warn '================== SEMANTIC-EDIT EQUIVALENCE FATAL =================='
  warn "edit:  #{entry['edit_description']}"
  warn "claim: #{entry['claim']}"
  warn '  the claim is REFUTED — the two sides are NOT equivalent:'
  warn "    TOTAL_ROWS      before #{b['total']}  vs  after #{a['total']}"
  warn "    DISTINCT_GRAIN  before #{b['distinct_grain']}  vs  after #{a['distinct_grain']}  (grain: #{grain.join(', ')})"
  entry['proof']['mismatches'].each do |x|
    next unless x['metric'].to_s.start_with?('SUM_')
    warn "    #{x['metric']}  before #{x['before'].inspect}  vs  after #{x['after'].inspect}"
  end
  warn '  A row-count difference at an unchanged grain means the edit fans out or drops'
  warn '  rows (the deleted-LEFT-JOIN field case); a sum difference means the values'
  warn '  drifted. The edit does NOT ship: REVERT it, then withdraw this refuted entry'
  warn "  (--withdraw #{entry['edit_description'].inspect} --reason \"<why>\" — the refuted"
  warn '  proof is preserved as evidence; never hand-edit the ledger), or redesign the'
  warn '  edit until the probes agree, then re-probe. There is no waive path — an'
  warn '  intentionally-different rewrite is not an equivalence claim and belongs in'
  warn '  the user-initiated scope-change record, not this ledger.'
  warn '====================================================================='
end

blocking = entries.reject { |e| EquivalenceProbe.proven?(e) }
mismatched = blocking.select { |e| e['proof'].is_a?(Hash) }
errored = blocking.reject { |e| e['proof'].is_a?(Hash) }
if mismatched.any?
  warn "probe-equivalence: #{mismatched.size} declared edit(s) REFUTED (match:false) — the final gate (exit 27) will refuse GREEN. Ledger: #{ledger_path}"
  exit 2
end
if errored.any?
  warn "probe-equivalence: #{errored.size} declared edit(s) without a proof (probe error / never probed) — re-probe; the final gate (exit 27) blocks until proven. Ledger: #{ledger_path}"
  exit 3
end
puts "probe-equivalence: #{entries.size} declared edit(s) all proven equivalent (match:true). Ledger: #{ledger_path}"
exit 0
