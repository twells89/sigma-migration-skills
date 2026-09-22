#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for scripts/probe-equivalence.rb + scripts/lib/equivalence_probe.rb
# (PLAN-v3 PR-8): the semantic-edit equivalence probe. Offline (fixture mode
# only — the live path shares the probe-workbook seam probe-join-keys.rb /
# run-ground-truth.rb already exercise).
#
# Pins:
#   1. an EQUIVALENT edit (identical counts + grain cardinality + sums on both
#      sides) → proof match:true, exit 0, ledger written with the probe SQL
#      (COUNT(*) + COUNT(DISTINCT grain) + SUM checksums) recorded per side;
#   2. a FAN-OUT edit (the corpus join-elision shape: after-side row count
#      inflated) → match:false, exit 2, FATAL naming BOTH sides' numbers;
#   3. a missing fixture side → exit 3, entry recorded WITHOUT a proof block
#      (probe_error) — still blocks GREEN;
#   4. re-probing the same edit_description REPLACES the entry (stale proofs
#      never accumulate);
#   5. DM-element mode: SQL + measures extracted from the spec (Custom SQL
#      statement verbatim; warehouse-table path → SELECT *; Sum([X]) columns
#      → derived SUM checksums), composite grain concat in the probe SQL;
#   6. bad invocations (no --grain / no side / no mode) → exit 1;
#   7. --withdraw: a REFUTED entry moves to the ledger's withdrawn[] verbatim
#      (refuted proof preserved as evidence + reason + withdrawn_at), unknown
#      top-level ledger keys round-trip through every rewrite, and withdraw
#      refuses proven / unproven / unknown entries and a missing --reason.
#
# Usage:  ruby scripts/test-probe-equivalence.rb
require 'json'
require 'open3'
require 'tmpdir'
require 'rbconfig'

SCRIPT = File.join(__dir__, 'probe-equivalence.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def run_probe(*args)
  Open3.capture3(RbConfig.ruby, SCRIPT, *args)
end

def write_fixture(dir, side, doc)
  File.write(File.join(dir, "#{side}.json"), JSON.pretty_generate(doc))
end

BASE_ARGS = ['--edit', 'drop LEFT JOIN SALES_FACT->SEGMENT_DIM',
             '--claim', 'joined table contributes no shelf column; elision is a no-op',
             '--grain', 'ORDER_ID', '--measures', 'AMOUNT',
             '--before-sql', 'SELECT f.*, d.SEGMENT_NAME FROM SALES_FACT f LEFT JOIN SEGMENT_DIM d ON f.ACTIVE_FLAG = d.CURRENT_FLAG',
             '--after-sql', 'SELECT f.* FROM SALES_FACT f'].freeze

# ---- 1. equivalent edit → match:true, exit 0 ---------------------------------
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx, 'after',  'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  out, _err, st = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx)
  check(st.success?, "equivalent edit → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('all proven equivalent'), 'success summary states the proof', fails)
  doc = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))
  e = doc['entries'].first
  check(doc['entries'].size == 1 && e['proof']['match'] == true, 'ledger entry carries proof match:true', fails)
  check(e['proof']['before'] == { 'total' => 8, 'distinct_grain' => 8, 'sums' => { 'AMOUNT' => 2950.0 } },
        'proof records the before side verbatim', fails)
  check(e['proof']['probed_at'].to_s =~ /\A\d{4}-\d{2}-\d{2}T/, 'proof carries probed_at', fails)
  check(e['before']['probe_sql'].include?('COUNT(*) AS TOTAL_ROWS') &&
        e['before']['probe_sql'].include?('COUNT(DISTINCT ORDER_ID) AS DISTINCT_GRAIN') &&
        e['before']['probe_sql'].include?('SUM(AMOUNT) AS SUM_AMOUNT'),
        'recorded probe SQL carries all three probes (count / distinct-grain / sum checksum)', fails)
  check(e['after']['sql'] == 'SELECT f.* FROM SALES_FACT f', 'entry records the after-side statement', fails)
end

# ---- 2. fan-out edit → match:false, exit 2, FATAL names both numbers ---------
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 8,  'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx, 'after',  'total' => 26, 'distinct' => 8, 'sums' => { 'AMOUNT' => 9575.0 })
  _out, err, st = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx)
  check(st.exitstatus == 2, "fan-out edit → exit 2 (got #{st.exitstatus})", fails)
  check(err.include?('SEMANTIC-EDIT EQUIVALENCE FATAL'), 'FATAL block printed', fails)
  check(err.include?('TOTAL_ROWS      before 8  vs  after 26'), 'FATAL names both row counts', fails)
  check(err.include?('SUM_AMOUNT  before 2950.0  vs  after 9575.0'), 'FATAL names both sum checksums', fails)
  check(err.include?('REVERT') && err.include?('no') && err.include?('waive'),
        'FATAL states the no-waive doctrine (revert or redesign)', fails)
  e = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))['entries'].first
  check(e['proof']['match'] == false, 'ledger entry carries proof match:false (gate 20 blocks)', fails)
  check(e['proof']['mismatches'].any? { |m| m['metric'] == 'TOTAL_ROWS' && m['before'] == 8 && m['after'] == 26 },
        'mismatches record the row-count delta', fails)
end

# ---- 3. missing fixture side → exit 3, no proof block (still blocks) ---------
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  _out, err, st = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx)
  check(st.exitstatus == 3, "missing after fixture → exit 3 (got #{st.exitstatus})", fails)
  check(err.include?('without a proof'), 'error summary states the entry is unproven', fails)
  e = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))['entries'].first
  check(!e.key?('proof') && e['probe_error'].to_s.include?('after'),
        'errored entry has NO proof block and names the failing side', fails)
end

# ---- 4. re-probe replaces the entry (fix-then-reprobe flow) ------------------
Dir.mktmpdir do |dir|
  fx_bad = File.join(dir, 'fx-bad')
  fx_ok = File.join(dir, 'fx-ok')
  Dir.mkdir(fx_bad)
  Dir.mkdir(fx_ok)
  write_fixture(fx_bad, 'before', 'total' => 8,  'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx_bad, 'after',  'total' => 26, 'distinct' => 8, 'sums' => { 'AMOUNT' => 9575.0 })
  write_fixture(fx_ok, 'before', 'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx_ok, 'after',  'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  _o, _e, st1 = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx_bad)
  _o, _e, st2 = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx_ok)
  doc = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))
  check(st1.exitstatus == 2 && st2.exitstatus.zero?, 'refuted then re-probed clean → exit 2 then 0', fails)
  check(doc['entries'].size == 1 && doc['entries'].first['proof']['match'] == true,
        're-probe REPLACES the entry (one entry, now match:true — stale proofs never accumulate)', fails)
end

# ---- 5. DM-element mode: SQL + measures extracted from the spec --------------
DM_SPEC = {
  'pages' => [{ 'elements' => [
    { 'id' => 'el-joined', 'name' => 'Fact Joined',
      'source' => { 'kind' => 'sql', 'connectionId' => 'c1',
                    'statement' => 'SELECT f.*, d.SEGMENT_NAME FROM DB.SCH.FACT f LEFT JOIN DB.SCH.DIM d ON f.K = d.K' },
      'columns' => [{ 'id' => 'c1', 'name' => 'Amount', 'formula' => 'Sum([Amount])' },
                    { 'id' => 'c2', 'name' => 'Net Value', 'formula' => 'Sum([Fact Joined/Net Value])' },
                    { 'id' => 'c3', 'name' => 'Region', 'formula' => '[Region]' }] },
    { 'id' => 'el-flat', 'name' => 'Fact Flat',
      'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB SCH FACT] },
      'columns' => [{ 'id' => 'c1', 'name' => 'Amount', 'formula' => 'Sum([Amount])' }] }
  ] }]
}.freeze

Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_SPEC))
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 5, 'distinct' => 5, 'sums' => { 'AMOUNT' => 10.0, 'NET_VALUE' => 4.0 })
  write_fixture(fx, 'after',  'total' => 5, 'distinct' => 5, 'sums' => { 'AMOUNT' => 10.0, 'NET_VALUE' => 4.0 })
  out, _err, st = run_probe('--workdir', dir,
                            '--edit', 'collapse Fact Joined to the bare table',
                            '--claim', 'the joined dim column is unused; collapsing is a no-op',
                            '--grain', 'ORDER_ID,LINE_NO',
                            '--before-element', 'Fact Joined', '--after-element', 'Fact Flat',
                            '--fixture', fx)
  check(st.success?, "element mode, equivalent → exit 0 (got #{st.exitstatus})", fails)
  e = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))['entries'].first
  check(e['before']['sql'].include?('LEFT JOIN DB.SCH.DIM'), 'before SQL extracted verbatim from the Custom SQL element', fails)
  check(e['after']['sql'] == 'SELECT * FROM DB.SCH.FACT', 'after SQL derived from the warehouse-table path', fails)
  check(e['measures'].sort == %w[AMOUNT NET_VALUE].sort,
        'measures derived from the Sum([X]) columns (display -> physical folding)', fails)
  check(e['before']['probe_sql'].include?("COUNT(DISTINCT COALESCE(TO_VARCHAR(ORDER_ID), '') || '|' || COALESCE(TO_VARCHAR(LINE_NO), '')) AS DISTINCT_GRAIN"),
        'composite grain concats with the probe-join-keys folding', fails)
  check(out.include?('sums: AMOUNT=10.0'), 'progress line surfaces the sum checksums', fails)
end

# element mode: --measures overrides derivation
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'dm-spec.json'), JSON.pretty_generate(DM_SPEC))
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 5, 'distinct' => 5, 'sums' => { 'QTY' => 7.0 })
  write_fixture(fx, 'after',  'total' => 5, 'distinct' => 5, 'sums' => { 'QTY' => 7.0 })
  _out, _err, st = run_probe('--workdir', dir, '--edit', 'x', '--claim', 'y', '--grain', 'ORDER_ID',
                             '--before-element', 'Fact Joined', '--after-element', 'Fact Flat',
                             '--measures', 'QTY', '--fixture', fx)
  e = JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))['entries'].first
  check(st.success? && e['measures'] == ['QTY'], '--measures overrides spec-derived checksum columns', fails)
end

# no measures anywhere → loud WARN, counts still compared
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 5, 'distinct' => 5)
  write_fixture(fx, 'after',  'total' => 5, 'distinct' => 5)
  _out, err, st = run_probe('--workdir', dir, '--edit', 'x', '--claim', 'y', '--grain', 'K',
                            '--before-sql', 'SELECT 1', '--after-sql', 'SELECT 1', '--fixture', fx)
  check(st.success? && err.include?('no SUM checksums'), 'measure-less probe passes on counts but WARNs loudly', fails)
end

# ---- 6. bad invocations → exit 1 ---------------------------------------------
[
  ['--workdir', '.', '--edit', 'x', '--claim', 'y', '--before-sql', 'a', '--after-sql', 'b', '--fixture', '.'],  # no grain
  ['--workdir', '.', '--edit', 'x', '--claim', 'y', '--grain', 'K', '--before-sql', 'a', '--fixture', '.'],      # no after side
  ['--workdir', '.', '--edit', 'x', '--claim', 'y', '--grain', 'K', '--before-sql', 'a', '--after-sql', 'b']     # no mode
].each_with_index do |args, i|
  _out, _err, st = run_probe(*args)
  check(st.exitstatus == 1, "bad invocation ##{i + 1} → exit 1 (got #{st.exitstatus})", fails)
end

# ---- 7. withdraw: refuted-and-not-applied entry moves to withdrawn[] ---------
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 8,  'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx, 'after',  'total' => 26, 'distinct' => 8, 'sums' => { 'AMOUNT' => 9575.0 })
  _out, err, st = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx)
  check(st.exitstatus == 2, "withdraw setup: refuted probe → exit 2 (got #{st.exitstatus})", fails)
  check(err.include?('--withdraw'), 'FATAL block names the withdraw path for a not-applied edit', fails)
  ledger = File.join(dir, 'semantic-edits.json')
  refuted_proof = JSON.parse(File.read(ledger))['entries'].first['proof']

  # D2 setup: an operator adds an unknown top-level key by hand — it must
  # survive every subsequent ledger rewrite.
  doc = JSON.parse(File.read(ledger))
  doc['withdrawal_note'] = 'operator context: edit was reverted in commit abc123'
  File.write(ledger, JSON.pretty_generate(doc))

  # withdraw without --reason → exit 1, nothing moved
  _out, err, st = run_probe('--workdir', dir, '--withdraw', BASE_ARGS[1])
  check(st.exitstatus == 1 && err.include?('--reason'), 'withdraw without --reason → exit 1 naming the requirement', fails)
  check(JSON.parse(File.read(ledger))['entries'].size == 1, 'refused withdraw moves nothing', fails)

  # withdraw an unknown edit → exit 1 listing the declared edits
  _out, err, st = run_probe('--workdir', dir, '--withdraw', 'no such edit', '--reason', 'x')
  check(st.exitstatus == 1 && err.include?('no declared entry') && err.include?(BASE_ARGS[1]),
        'withdrawing an unknown edit → exit 1 listing the declared edits', fails)

  # the real withdraw → exit 0, entry moved with proof preserved verbatim
  out, _err, st = run_probe('--workdir', dir, '--withdraw', BASE_ARGS[1],
                            '--reason', 'refuted — the join stays; edit was never applied')
  check(st.success?, "withdraw of a refuted entry → exit 0 (got #{st.exitstatus})", fails)
  check(out.include?('WITHDREW') && out.include?('refuted and not applied'),
        'withdraw output states the semantics', fails)
  check(out.include?('not detectable mechanically') || out.include?('gates 16/18'),
        'withdraw output keeps the honesty note (attestation, not measurement)', fails)
  doc = JSON.parse(File.read(ledger))
  check(doc['entries'].empty?, 'withdrawn entry left the blocking entries[]', fails)
  w = Array(doc['withdrawn']).first
  check(Array(doc['withdrawn']).size == 1 && w['edit_description'] == BASE_ARGS[1],
        'entry landed in withdrawn[] keyed by edit_description', fails)
  check(w['proof'] == refuted_proof, 'the REFUTED proof is preserved VERBATIM as evidence', fails)
  check(w['withdrawn_reason'] == 'refuted — the join stays; edit was never applied' &&
        w['withdrawn_at'].to_s =~ /\A\d{4}-\d{2}-\d{2}T/,
        'withdrawn entry carries the reason + withdrawn_at stamp', fails)
  check(doc['withdrawal_note'] == 'operator context: edit was reverted in commit abc123',
        'unknown top-level ledger key survives the withdraw rewrite (D2)', fails)

  # withdrawing the same edit again → not found
  _out, _err, st = run_probe('--workdir', dir, '--withdraw', BASE_ARGS[1], '--reason', 'x')
  check(st.exitstatus == 1, 'a withdrawn edit cannot be withdrawn twice (not found)', fails)

  # a fresh probe of a NEW edit rewrites the ledger and keeps withdrawn[] +
  # the operator key (D2 through the probe path, not just the withdraw path)
  fx_ok = File.join(dir, 'fx-ok')
  Dir.mkdir(fx_ok)
  write_fixture(fx_ok, 'before', 'total' => 3, 'distinct' => 3, 'sums' => { 'AMOUNT' => 5.0 })
  write_fixture(fx_ok, 'after',  'total' => 3, 'distinct' => 3, 'sums' => { 'AMOUNT' => 5.0 })
  _out, _err, st = run_probe('--workdir', dir, '--edit', 'rewrite region filter', '--claim', 'same set',
                             '--grain', 'ORDER_ID', '--measures', 'AMOUNT',
                             '--before-sql', 'SELECT 1', '--after-sql', 'SELECT 1', '--fixture', fx_ok)
  doc = JSON.parse(File.read(ledger))
  check(st.success? && Array(doc['withdrawn']).size == 1 &&
        doc['withdrawal_note'] == 'operator context: edit was reverted in commit abc123',
        'probe rewrite preserves withdrawn[] and unknown top-level keys (D2 round-trip)', fails)
end

# withdraw refuses a PROVEN entry (nothing blocks; nothing to withdraw)
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  write_fixture(fx, 'after',  'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  _out, _err, st = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx)
  check(st.success?, 'withdraw-refusal setup: proven probe → exit 0', fails)
  _out, err, st = run_probe('--workdir', dir, '--withdraw', BASE_ARGS[1], '--reason', 'x')
  check(st.exitstatus == 1 && err.include?('PROVEN'), 'withdraw of a proven entry → refused (exit 1)', fails)
  check(JSON.parse(File.read(File.join(dir, 'semantic-edits.json')))['entries'].size == 1,
        'refused withdraw of a proven entry moves nothing', fails)
end

# withdraw refuses an UNPROVEN entry (measure before you withdraw)
Dir.mktmpdir do |dir|
  fx = File.join(dir, 'fx')
  Dir.mkdir(fx)
  write_fixture(fx, 'before', 'total' => 8, 'distinct' => 8, 'sums' => { 'AMOUNT' => 2950.0 })
  _out, _err, st = run_probe('--workdir', dir, *BASE_ARGS, '--fixture', fx) # missing after side
  check(st.exitstatus == 3, 'withdraw-refusal setup: errored probe → exit 3', fails)
  _out, err, st = run_probe('--workdir', dir, '--withdraw', BASE_ARGS[1], '--reason', 'x')
  check(st.exitstatus == 1 && err.include?('no refuted proof') && err.include?('Re-probe'),
        'withdraw of an unproven entry → refused, routes to re-probe first', fails)
end

# withdraw mode rejects probe flags in the same call
_out, _err, st = run_probe('--workdir', '.', '--withdraw', 'x', '--reason', 'y', '--edit', 'z')
check(st.exitstatus == 1, '--withdraw mixed with probe flags → exit 1', fails)

# Live probe POST contract: workbook writes must use the released nested
# document shape. Fixture-only tests cannot exercise the API boundary, so pin
# the same canonicalizer used by probe-join-keys.rb.
script_source = File.read(SCRIPT)
canonicalize_at = script_source.index('WorkbookCode.canonicalize(spec)')
post_at = script_source.index("Sigma.request(:post, '/v2/workbooks/spec'")
check(script_source.include?("require_relative 'lib/workbook_code'"),
      'live seam loads the workbook code-representation adapter', fails)
check(canonicalize_at && post_at && canonicalize_at < post_at,
      'live seam canonicalizes the probe workbook before POST', fails)

puts
if fails.empty?
  puts 'ALL PASS — probe-equivalence fixture modes, fan-out FATAL, proof replacement, element extraction, invocation guards, withdraw + unknown-key round-trip'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
