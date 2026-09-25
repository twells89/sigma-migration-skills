#!/usr/bin/env ruby
# Accuracy fixture suite for the vendored converter/sql.mjs (Track E). Offline +
# deterministic. Pattern copied from tableau-to-sigma's test-converter-fixtures.rb
# (the exemplar this skill's own design doc cites): a symbol-count guard runs
# UNCONDITIONALLY so a re-vendor that drops/renames a needed export hard-aborts
# rather than silently skipping every fixture; if `node` is present, fixtures run
# for real against the bundle; if absent, SKIPPED loudly, never a silent pass.
#
#   ruby test/test-convert-beast-modes-fixtures.rb
require 'json'
require 'open3'
require 'tmpdir'

VENDORED = File.expand_path('../converter/sql.mjs', __dir__)

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---------------------------------------------------------------------------
# Representative Beast Mode SQL snippets (post-normalize_bm — backticks already
# rewritten to [brackets], matching what --convert actually feeds the bundle).
# Deliberately NOT the mcp's own 74-item corpus — that stays upstream-only; a
# domo-side dependency on it would reintroduce exactly the coupling Track E
# removes. :expect_converted false marks a formula this converter is KNOWN not
# to fully translate (still an honest, present sigmaFormula) — never asserted
# as a bug, just locked so a future upstream fix is noticed via NOTE below.
# ---------------------------------------------------------------------------
FIXTURES = [
  { id: 'D-1', sql: 'SUM([Net Revenue])',                        expect: 'Sum([Net Revenue])' },
  { id: 'D-2', sql: 'COUNT(DISTINCT [Order Id])',                 expect: 'CountDistinct([Order Id])' },
  { id: 'D-3', sql: 'AVG([Order Total])',                         expect: 'Avg([Order Total])' },
  { id: 'D-4', sql: 'SUM([Gross Profit]) / SUM([Net Revenue])',   expect: 'Sum([Gross Profit]) / Sum([Net Revenue])' },
  { id: 'D-5', sql: "CASE WHEN [Status] = 'Active' THEN 1 ELSE 0 END",
    expect: 'If([Status] = "Active", 1, 0)' },
  { id: 'D-6', sql: 'MAX([Order Date])',                          expect: 'Max([Order Date])' },
  { id: 'D-7', sql: 'MIN([Order Date])',                          expect: 'Min([Order Date])' },
  { id: 'D-8', sql: 'ROUND([Margin Pct], 2)',                     expect: 'Round([Margin Pct], 2)' },
  { id: 'D-9', sql: "DATEDIFF('day', [Order Date], [Ship Date])", expect: 'DateDiff("day", [Order Date], [Ship Date])' },
  { id: 'D-10', sql: 'COALESCE([Discount], 0)',                   expect: 'Coalesce([Discount], 0)' },
  # D-11..D-14 — MySQL 2-arg DATEDIFF/TIMEDIFF (bead beads-sigma-znvg, upstream
  # PR #122, vendored at source 0641a62). D-9 above only ever covered the 3-arg
  # form; the 2-arg form is what Domo Beast Modes actually emit, and it produced
  # `DateDiff(Today(),[Date])` — wrong arity AND wrong operand order — which is
  # not valid Sigma and caused 9 of the 15 type=error columns on the live
  # 36-card cold run. These fixtures fail on the PRE-#122 bundle (measured:
  # `DateDiff(Today(),[Date])`), so they are what makes a re-vendor regression
  # loud on the domo side rather than only upstream.
  #
  # D-12 is the important one: both operands are columns, so a half-fix that adds
  # the unit WITHOUT swapping still compiles and silently returns the negation —
  # no error anywhere. Pinning the exact operand order is the only thing that
  # catches it.
  { id: 'D-11', sql: 'datediff(current_date(),[Date])',
    expect: 'DateDiff("day", [Date], Today())' },
  { id: 'D-12', sql: 'DATEDIFF([CloseDate],[CreatedDate])',
    expect: 'DateDiff("day", [CreatedDate], [CloseDate])' },
  { id: 'D-13', sql: 'TIMEDIFF([ended_at],[started_at])',
    expect: 'DateDiff("second", [started_at], [ended_at])' },
  { id: 'D-14', sql: 'SUM(CASE WHEN DATEDIFF(current_date(),[Date]) < 7 THEN 1 ELSE 0 END)',
    expect: 'Sum(If(DateDiff("day", [Date], Today()) < 7, 1, 0))' },
]
# NOTE (converted:false expected): the vendored converter has no Sigma mapping
# for LIKE/BETWEEN — this is intentional, not a bug (see design doc's Error
# Handling section). Locks the honesty signal itself, not a translation.
RESIDUAL_FIXTURES = [
  { id: 'D-R1', sql: "LOWER([Country]) LIKE 'usa'" },
  { id: 'D-R2', sql: '[Order Total] BETWEEN 100 AND 500' },
]

puts 'Accuracy fixtures — vendored converter/sql.mjs'
abort "FATAL: vendored converter missing at #{VENDORED} — run tools/vendor-converters.sh <mcp-clone> domo" \
  unless File.exist?(VENDORED)
bundle = File.read(VENDORED, encoding: 'utf-8')

# Symbol-count guard — UNCONDITIONAL, runs even without node. A re-vendor that
# drops or renames any of these 5 exports must hard-abort, never silently skip
# every fixture below.
NEEDED = %w[lookSqlToSigmaRules lookConvertExpression hasResidualCaseKeyword hasResidualInfixOperator lookUnknownFunctions]
missing = NEEDED.reject { |name| bundle.match?(/\b#{Regexp.escape(name)}\b/) }
abort "converter fixture harness: converter/sql.mjs is missing expected export(s): #{missing.join(', ')} " \
      '— the re-vendor dropped/renamed a needed function; update test-convert-beast-modes-fixtures.rb ' \
      'or investigate the upstream change.' unless missing.empty?

node_present = begin
  _o, _e, st = Open3.capture3('node', '--version')
  st.success?
rescue Errno::ENOENT
  false
end

if node_present
  Dir.mktmpdir('domo-conv-fixtures') do |dir|
    fx_path  = File.join(dir, 'fixtures.json')
    res_path = File.join(dir, 'results.json')
    all_fixtures = FIXTURES + RESIDUAL_FIXTURES
    File.write(fx_path, JSON.generate(all_fixtures.map { |x| { 'id' => x[:id], 'sql' => x[:sql] } }))

    import_specifier = Gem.win_platform? && VENDORED.match?(/\A[A-Za-z]:/) ? 'file:///' + VENDORED.gsub('\\', '/') : VENDORED
    runner = File.join(dir, 'run.mjs')
    File.write(runner, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { lookSqlToSigmaRules, lookConvertExpression, hasResidualCaseKeyword, hasResidualInfixOperator } from #{import_specifier.to_json};
      const fixtures = JSON.parse(readFileSync(#{fx_path.to_json}, 'utf8'));
      const out = fixtures.map(({ id, sql }) => {
        let sigmaFormula = lookSqlToSigmaRules(sql);
        if (sigmaFormula == null) sigmaFormula = lookConvertExpression(sql);
        const converted = !hasResidualCaseKeyword(sigmaFormula) && !hasResidualInfixOperator(sigmaFormula);
        return { id, sigmaFormula, converted };
      });
      writeFileSync(#{res_path.to_json}, JSON.stringify(out));
    JS

    _o, e, st = Open3.capture3('node', runner)
    if !st.success?
      warn "FAIL — node fixture runner failed:\n#{e}"
      exit 1
    end

    rows = JSON.parse(File.read(res_path, encoding: 'utf-8'))
    by_id = {}
    rows.each { |r| by_id[r['id']] = r }

    FIXTURES.each do |fx|
      r = by_id[fx[:id]]
      check(r && r['sigmaFormula'] == fx[:expect] && r['converted'] == true,
            "#{fx[:id]}  #{fx[:sql].inspect} → #{fx[:expect].inspect} (converted:true)", fails)
    end

    RESIDUAL_FIXTURES.each do |fx|
      r = by_id[fx[:id]]
      check(r && !r['sigmaFormula'].to_s.empty? && r['converted'] == false,
            "#{fx[:id]}  #{fx[:sql].inspect} → present-but-converted:false (honest residual-LIKE/BETWEEN signal)", fails)
    end
  end
else
  warn '  WARN  node not found on PATH — accuracy fixtures SKIPPED ' \
       "(#{FIXTURES.size + RESIDUAL_FIXTURES.size} fixtures unexercised). " \
       'Install node (doctor.sh enforces it for the converter path) to run them.'
end

puts
if !node_present
  # Zero fixtures ran — 'fails' is empty by construction, not because anything
  # was verified. Never print the bare "ALL PASS" string here: a CI consumer
  # that only checks the final line or exit code must not read a
  # zero-coverage run as a clean, fully-exercised pass.
  puts "SKIPPED — 0/#{FIXTURES.size + RESIDUAL_FIXTURES.size} fixtures exercised (node absent). This is NOT a verified pass."
  exit 0
elsif fails.empty?
  puts 'ALL PASS'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
