#!/usr/bin/env ruby
# encoding: utf-8
# Converter formula-translation fixture suite (tflex ExpressionToSql set,
# re-targeted Tableau → Sigma). Offline + deterministic.
#
# WHY: these fixtures port tflex's ExpressionToSql verification discipline to
# this skill's two formula-translation surfaces. Every tflex quirk — the
# DATEDIFF arg swap, the /if/gi-inside-"Pacific" IF→CASE substring mangling,
# SPLIT→chained-SUBSTRING/CHARINDEX chains, the CONTAINS single-quote
# malformation, the removeExtraBrackets PARTITION drop — was verified ABSENT
# from this skill's converter (measured 2026-07-11, spec P2 §1.4). The
# fixtures therefore flip from "regression traps for bugs" to "locks proving
# the bugs never enter": every expected string below is the MEASURED current
# output of the real code, asserted exactly (including cosmetic double-space
# quirks — intentional tripwires; do not normalize).
#
#   Part A: vendored converter/tableau.mjs internal tableauFormulaToSigma
#           (export-appended tmp copy — the bundle only exports
#           convertTableauToSigma) — 44 asserted fixtures, 0 PENDING (N-X2 was
#           promoted 2026-07-25 when the vendored ZN → native Zn fix landed;
#           the N-Z*/N-D*/N-W* rows lock the same calc-hotfix batch).
#           Needs `node` on PATH; when node itself is absent Part A is
#           SKIPPED with a warning (CI runners may lack node) — but a
#           re-vendor that renames/splits tableauFormulaToSigma still
#           HARD-ABORTS (a silent skip must never hide 29 dead fixtures).
#   Part B: Ruby worksheet-calc translators from build-charts-from-signals.rb
#           (regex-extraction + instance_eval, minimal inline mmap — same
#           idiom as test-table-calc-translation.rb) — 25 rows.
#
# PENDING convention: known-wrong outputs are documented with the expected-
# correct Sigma formula and NEVER asserted either way; the suite prints
# current-vs-expected and nags to promote when they start matching.
#
# Usage:  ruby scripts/test-converter-fixtures.rb
require 'json'
require 'open3'
require 'tmpdir'
require_relative 'lib/formula_normalize'

VENDORED = File.expand_path('../converter/tableau.mjs', __dir__)
CHARTS   = File.join(__dir__, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Render fixture inputs on one line for PASS/FAIL output (N-F14 has a real
# newline in its fixture string).
def one_line(s)
  s.gsub("\n", '\n')
end

# ---------------------------------------------------------------------------
# Part A fixture table — measured 2026-07-11 against converter/tableau.mjs
# @ c33e5bd (see converter/PROVENANCE.json); ZN/date/window rows re-measured
# 2026-07-25 against the calc-hotfix local patches (PROVENANCE local_patches).
# :warn => substring that must appear in the warnings array; no :warn =>
# warnings must be EMPTY.
# ---------------------------------------------------------------------------
NODE_FIXTURES = [
  { id: 'N-F1',  input: 'IFNULL([Sales], 0)',                    expect: 'Coalesce([Sales], 0)' },
  { id: 'N-F2',  input: 'ISNULL([Discount])',                    expect: 'IsNull([Discount])' },
  # ZN → native Sigma Zn (docs/zn) — name-map, robust for any nesting; the old
  # Coalesce($1, 0) regex broke ZN(AGG(...)) (see N-X2).
  { id: 'N-F3',  input: 'ZN([Profit])',                          expect: 'Zn([Profit])' },
  # tflex F4: DATEDIFF arg swap + pass-count parity chaos. Absent here — the
  # skill preserves Tableau (part, start, end) order, which is exactly Sigma's
  # DateDiff(part, start, end); single-pass regex, no double-swap.
  { id: 'N-F4a', input: "DATEDIFF('day', [Start], [Finish])",    expect: 'DateDiff("day", [Start], [Finish])' },
  { id: 'N-F4b', input: "DATEDIFF('day', [Order Date], [Ship Date])",
    expect: 'DateDiff("day", [Order Date], [Ship Date])' },
  { id: 'N-F5',  input: "DATEADD('month', 3, [Order Date])",     expect: 'DateAdd("month", 3, [Order Date])' },
  { id: 'N-F6',  input: 'LEN([Customer Name])',                  expect: 'Len([Customer Name])' },
  { id: 'N-F7',  input: 'RIGHT([Order ID], 4)',                  expect: 'Right([Order ID], 4)' },
  { id: 'N-F8',  input: 'CONTAINS([Segment], "Corp")',           expect: 'Contains([Segment], "Corp")' },
  # tflex F8: CONTAINS single-quote → malformed LIKE '%'Corp'%'. Absent — the
  # single→double-quote pass yields a clean Sigma string literal.
  { id: 'N-F8b', input: "CONTAINS([Segment], 'Corp')",           expect: 'Contains([Segment], "Corp")' },
  { id: 'N-F9',  input: 'TRIM([City])',                          expect: 'Trim([City])' },
  { id: 'N-F10', input: 'SPLIT([Name], "-", 1)',                 expect: 'SplitPart([Name], "-", 1)' },
  # tflex F11: SPLIT → chained SUBSTRING/CHARINDEX. Absent — one SplitPart().
  { id: 'N-F11', input: 'SPLIT([Name], "-", 2)',                 expect: 'SplitPart([Name], "-", 2)' },
  # Both Tableau SPLIT and Sigma SplitPart are 1-indexed with negatives from
  # the right (vendored verification note in TABLEAU_FUNC_MAP).
  { id: 'N-F12', input: 'SPLIT([Name], "-", -1)',                expect: 'SplitPart([Name], "-", -1)' },
  { id: 'N-F13', input: 'IF [Sales] > 100 THEN "High" ELSE "Low" END',
    expect: 'If([Sales] > 100, "High", "Low")' },
  # Multiline IF/ELSEIF collapses to nested If (literal newlines in fixture).
  { id: 'N-F14', input: "IF [A] = 1 THEN \"one\"\nELSEIF [A] = 2 THEN \"two\"\nELSE \"other\"\nEND",
    expect: 'If([A] = 1, "one", If([A] = 2, "two", "other"))' },
  # THE re-target of tflex's core lesson (F15): /if/gi inside "Pacific" used
  # to mangle the literal. Dead here — tableauIfToSigma splits on \bTHEN\b /
  # \bELSEIF\b word boundaries; "Pacific" survives intact.
  { id: 'N-F15', input: 'IF [Region] = "Pacific" THEN 1 ELSE 0 END',
    expect: 'If([Region] = "Pacific", 1, 0)' },
  # Chart-only placement warning is part of the table-calc contract — assert it.
  { id: 'N-F16', input: 'RANK(SUM([Sales]))',                    expect: 'Rank(Sum([Sales]), "desc")',
    warn: 'CHART/grouped-element context ONLY' },
  { id: 'N-F17', input: 'RANK_DENSE(SUM([Sales]))',              expect: 'RankDense(Sum([Sales]), "desc")',
    warn: 'CHART/grouped-element context ONLY' },
  # Bare-ref passthrough is correct-by-design: refs resolve to sibling DM
  # columns (tflex's no-parens field-map substitution has no analog — this
  # skill never inlines formula text).
  { id: 'N-F18', input: '[Profit Ratio] * 100',                  expect: '[Profit Ratio] * 100' },
  { id: 'N-F19', input: 'UPPER([City])',                         expect: 'Upper([City])' },
  { id: 'N-F20', input: 'TRIM(SPLIT([Name], "-", 1))',           expect: 'Trim(SplitPart([Name], "-", 1))' },
  # CASE → If-chain form (semantically = Switch).
  { id: 'N-X1',  input: 'CASE [Region] WHEN "West" THEN 1 ELSE 0 END',
    expect: 'If([Region] = "West", 1, 0)' },
  # PROMOTED 2026-07-25 (was the suite's one PENDING row): the single-paren
  # Coalesce ZN rewrite emitted malformed Coalesce(Sum([Profit], 0)); the fix
  # maps ZN → native Sigma Zn() by NAME, so any nesting survives. Landed as a
  # vendored local patch (converter/PROVENANCE.json local_patches — upstream
  # clone divergent), not the re-vendor the old note asked for.
  { id: 'N-X2',  input: 'ZN(SUM([Profit]))',                     expect: 'Zn(Sum([Profit]))' },
  # Locks the _TEXT_FN_RE fix: Coalesce/Zn are NOT text-producing, so numeric
  # `+` between null-guards must stay `+` (was silently corrupted to `&`).
  { id: 'N-Z1',  input: 'ZN([Sales]) + ZN([Profit])',            expect: 'Zn([Sales]) + Zn([Profit])' },
  { id: 'N-Z2',  input: 'ZN(SUM([Sales])) - ZN(SUM([Profit]))',  expect: 'Zn(Sum([Sales])) - Zn(Sum([Profit]))' },
  # …while the OTHER side of the same fix holds: _isTextOperand recurses into
  # Coalesce's args, so a string-literal null-guard chain still converts + → &
  # (was silently left as numeric +, which errors the column at render), and a
  # ref-only Coalesce with no type info conservatively keeps +.
  { id: 'N-Z3',  input: 'IFNULL([a], "x") + IFNULL([b], "y")',
    expect: 'Coalesce([a], "x") & Coalesce([b], "y")' },
  { id: 'N-Z4',  input: 'IFNULL([c], [e]) + IFNULL([d], [f])',
    expect: 'Coalesce([c], [e]) + Coalesce([d], [f])' },
  # Start-of-week arg has no Sigma slot — dropped LOUDLY (was silent drift)…
  { id: 'N-D1',  input: "DATEDIFF('week', [Start], [Finish], 'monday')",
    expect: 'DateDiff("week", [Start], [Finish])',  warn: "start-of-week 'monday' dropped" },
  { id: 'N-D2',  input: "DATETRUNC('week', [Order Date], 'monday')",
    expect: 'DateTrunc("week", [Order Date])',      warn: "start-of-week 'monday' dropped" },
  # …and ONLY DateTrunc/DateDiff drop it — a weekday string that is a real last
  # argument elsewhere survives (the old strip ate it: Contains([D], 'monday')
  # became Contains([D])).
  { id: 'N-D3',  input: "CONTAINS([Day Name], 'monday')",        expect: 'Contains([Day Name], "monday")' },
  # Non-existent Sigma names purged from emission (function-index verified):
  { id: 'N-D4',  input: 'DATETIME([Ship Date])',                 expect: 'Date([Ship Date])' },
  { id: 'N-D5',  input: "DATEPART('weekday', [Order Date])",     expect: 'Weekday([Order Date])',
    warn: 'verify numbering' },
  { id: 'N-D6',  input: "DATENAME('week', [Order Date])",        expect: 'Text(DatePart("week", [Order Date]))' },
  # Un-staled window mappings — MovingCorr/MovingVariance/MovingCount exist:
  { id: 'N-W1',  input: 'WINDOW_CORR(SUM([Sales]), SUM([Profit]), -2, 0)',
    expect: 'MovingCorr(Sum([Sales]), Sum([Profit]), 2)', warn: 'CHART/grouped-element context ONLY' },
  { id: 'N-W2',  input: 'WINDOW_VAR(SUM([Sales]), -4, 0)',
    expect: 'MovingVariance(Sum([Sales]), 4)',            warn: 'CHART/grouped-element context ONLY' },
  { id: 'N-W3',  input: 'WINDOW_COUNT(COUNT([Sales]), -2, 0)',
    expect: 'MovingCount(Count([Sales]), 2)',             warn: 'CHART/grouped-element context ONLY' },
  # Population variant stays untranslatable (no Moving*Pop in Sigma):
  { id: 'N-W4',  input: 'WINDOW_VARP(SUM([Sales]), -2, 0)',
    expect: '/* table calc: WINDOW_VARP(SUM([Sales]), -2, 0) */',
    warn: 'has no Sigma equivalent' },
  { id: 'N-X3',  input: 'COUNTD([Customer ID])',                 expect: 'CountDistinct([Customer ID])' },
  # Fail-open WITH warning is the B1 contract for unmapped functions.
  { id: 'N-X4',  input: 'FINDNTH([Path], "-", 2)',               expect: 'FINDNTH([Path], "-", 2)',
    warn: 'Unmapped Tableau function(s) passed through unconverted: FINDNTH' },
  # LODs are unsupported-by-design at THIS function's level — they route
  # through the tableauParseLOD/SQL-helper machinery; assert comment + warning.
  { id: 'N-X5',  input: '{FIXED [Region]: SUM([Sales])}',
    expect: '/* LOD: {FIXED [Region]: SUM([Sales])} */',
    warn: 'LOD expression not converted' },
  # Grand-total special case: NO chart-only warning (assert warnings empty).
  { id: 'N-X6',  input: 'WINDOW_SUM(SUM([Sales]))',              expect: 'GrandTotal(Sum([Sales]))' },
  { id: 'N-X7',  input: 'RUNNING_SUM(SUM([Sales]))',             expect: 'CumulativeSum(Sum([Sales]))',
    warn: 'CHART/grouped-element context ONLY' },
  { id: 'N-X8',  input: 'IIF([Sales] > 0, 1, 0)',                expect: 'If([Sales] > 0, 1, 0)' }
].freeze

# ---------------------------------------------------------------------------
# Part B fixture table — measured 2026-07-11. entry => translator driven:
#   :row → translate_row_level_calc   :dim → translate_dim_calc
#   :kpi → translate_kpi_measure_formula   :agg → translate_user_agg_formula
#   :win → translate_window_calc (assert subset of its returned hash)
# expect nil = the translator's fail-closed contract (caller warns; locked by
# test-row-level-date-translation.rb). Do NOT drive translate_tableau_tc here:
# it returns inner aggs in Tableau case by design and
# test-table-calc-translation.rb owns that unit surface —
# translate_window_calc is the composed, correctly-cased entry point.
# ---------------------------------------------------------------------------
MMAP = {
  '(?i)^sales$'         => { 'name' => 'SALES' },
  '(?i)^profit$'        => { 'name' => 'PROFIT' },
  '(?i)^profit ratio$'  => { 'name' => 'PROFIT_RATIO' },
  '(?i)^customer id$'   => { 'name' => 'CUSTOMER_ID' },
  '(?i)^order date$'    => { 'name' => 'ORDER_DATE' },
  '(?i)^ship date$'     => { 'name' => 'SHIP_DATE' },
  '(?i)^start$'         => { 'name' => 'START_DATE' },
  '(?i)^finish$'        => { 'name' => 'FINISH_DATE' },
  '(?i)^region$'        => { 'name' => 'REGION' },
  '(?i)^a$'             => { 'name' => 'A' }
}.freeze

RUBY_FIXTURES = [
  { id: 'R-F1',  entry: :row, input: 'IFNULL([Sales], 0)', expect: 'Coalesce([Master/SALES], 0)' },
  # NOTE the DOUBLE space after `"day",` in the next three rows: the gsub
  # template carries a trailing space and the source comma-space survives.
  # Cosmetic (Sigma ignores it) but asserted EXACTLY as an intentional
  # tripwire — do not normalize.
  { id: 'R-F4a', entry: :row, input: "DATEDIFF('day', [Start], [Finish])",
    expect: 'DateDiff("day",  [Master/START_DATE], [Master/FINISH_DATE])' },
  { id: 'R-F4b', entry: :row, input: "DATEDIFF('day', [Order Date], [Ship Date])",
    expect: 'DateDiff("day",  [Master/ORDER_DATE], [Master/SHIP_DATE])' },
  { id: 'R-F5',  entry: :row, input: "DATEADD('month', 3, [Order Date])",
    expect: 'DateAdd("month",  3, [Master/ORDER_DATE])' },
  { id: 'R-F18', entry: :row, input: '[Profit Ratio] * 100', expect: '[Master/PROFIT_RATIO] * 100' },
  # PENDING-enhancement (not a failure): IsNull is on the Sigma whitelist — a
  # 2-line handler + residue-list entry would translate it on the row path;
  # keep asserting the fail-closed nil until that lands.
  { id: 'R-F2',  entry: :row, input: 'ISNULL([Discount])', expect: nil },
  # PENDING-enhancement (not a failure): Sigma has Zn/Coalesce and ZN is
  # already handled on the agg path (R-X2) — port to the row path; until then
  # fail-closed nil is the contract.
  { id: 'R-F3',  entry: :row, input: 'ZN([Profit])', expect: nil },
  # v5.4: 1:1 STRING functions now translate on the row path too (identical
  # name modulo case + identical signature; every spelling is in the
  # canonical sigma_functions.rb registry) — REPLACE-chain derived dims on
  # sub-masters needed them. Unmapped refs keep the raw name (repaired
  # downstream by the global ref-label repair).
  { id: 'R-F6',  entry: :row, input: 'LEN([Customer Name])', expect: 'Len([Master/Customer Name])' },
  { id: 'R-F7',  entry: :row, input: 'RIGHT([Order ID], 4)', expect: 'Right([Master/Order ID], 4)' },
  { id: 'R-F8',  entry: :row, input: 'CONTAINS([Segment], "Corp")', expect: 'Contains([Master/Segment], "Corp")' },
  { id: 'R-F9',  entry: :row, input: 'TRIM([City])', expect: 'Trim([Master/City])' },
  { id: 'R-F19', entry: :row, input: 'UPPER([City])', expect: 'Upper([Master/City])' },
  # SPLIT is deliberately NOT mapped (Sigma SplitPart negative-token semantics
  # unverified) — fail-closed nil stays the locked contract.
  { id: 'R-F10', entry: :row, input: 'SPLIT([Name], "-", 1)', expect: nil },
  { id: 'R-F20', entry: :row, input: 'TRIM(SPLIT([Name], "-", 1))', expect: nil },
  { id: 'R-F13', entry: :dim, input: 'IF [Sales] > 100 THEN "High" ELSE "Low" END',
    expect: 'If([Master/SALES] > 100, "High", "Low")' },
  { id: 'R-F14', entry: :dim,
    input: "IF [A] = 1 THEN \"one\"\nELSEIF [A] = 2 THEN \"two\"\nELSE \"other\"\nEND",
    expect: 'If([Master/A] = 1, "one", If([Master/A] = 2, "two", "other"))' },
  # tflex substring-"if" lesson locked on the Ruby side too.
  { id: 'R-F15', entry: :dim, input: 'IF [Region] = "Pacific" THEN 1 ELSE 0 END',
    expect: 'If([Master/REGION] = "Pacific", 1, 0)' },
  { id: 'R-X1',  entry: :dim, input: 'CASE [Region] WHEN "West" THEN 1 ELSE 0 END',
    expect: 'Switch([Master/REGION], "West", 1, 0)' },
  # KPI context Sum-wraps bare mapped refs.
  { id: 'R-F18k', entry: :kpi, input: '[Profit Ratio] * 100',
    expect: 'Sum([Master/PROFIT_RATIO]) * 100' },
  { id: 'R-X3',  entry: :kpi, input: 'COUNTD([Customer ID])',
    expect: 'CountDistinct([Master/CUSTOMER_ID])' },
  # Cross-path lock with node N-X2: both paths now translate ZN(AGG(...))
  # correctly but through different idioms — node emits native Zn(...), the
  # paren-aware Ruby agg loop emits Coalesce(..., 0). Semantically identical
  # (Zn(x) ≡ Coalesce(x, 0)); each path's own shape is asserted exactly.
  { id: 'R-X2',  entry: :agg, input: 'ZN(SUM([Profit]))',
    expect: 'Coalesce(Sum([Master/PROFIT]), 0)' },
  { id: 'R-F16', entry: :win, input: 'RANK(SUM([Sales]))',
    expect: { 'mode' => 'inline', 'formula' => 'Rank(Sum([Master/SALES]), "desc")',
              'follows_sort' => false } },
  { id: 'R-F17', entry: :win, input: 'RANK_DENSE(SUM([Sales]))',
    expect: { 'mode' => 'inline', 'formula' => 'RankDense(Sum([Master/SALES]), "desc")',
              'follows_sort' => false } },
  # Unbounded WINDOW_SUM → two-level grouped helper plan; assert all four keys.
  { id: 'R-X6',  entry: :win, input: 'WINDOW_SUM(SUM([Sales]))',
    expect: { 'mode' => 'two-stage', 'stage_agg' => 'Sum', 'retrieve_agg' => 'Max',
              'value_formula' => 'Sum([Master/SALES])' } },
  { id: 'R-X7',  entry: :win, input: 'RUNNING_SUM(SUM([Sales]))',
    expect: { 'mode' => 'inline', 'formula' => 'CumulativeSum(Sum([Master/SALES]))',
              'follows_sort' => true } }
].freeze

# ===========================================================================
# Part A — vendored node converter (per-formula, no .twb needed)
# ===========================================================================
puts 'Part A — vendored converter/tableau.mjs: internal tableauFormulaToSigma'
abort "FATAL: vendored converter missing at #{VENDORED} — run tools/vendor-converters.sh" unless File.exist?(VENDORED)
bundle = File.read(VENDORED, encoding: 'utf-8')

# Symbol-count guard runs UNCONDITIONALLY (before the node check): a
# re-vendor that renames/minifies/splits the symbol must hard-abort, never
# silently skip 29 fixtures.
names = bundle.scan(/^function (tableauFormulaToSigma\d*)\(/).flatten
abort 'converter fixture harness: expected exactly ONE top-level ' \
      "tableauFormulaToSigma in converter/tableau.mjs, found #{names.size} — " \
      'the re-vendor renamed it; update test-converter-fixtures.rb' \
  unless names.size == 1

node_present = begin
  _out, _err, st = Open3.capture3('node', '--version')
  st.success?
rescue Errno::ENOENT
  false
end

skipped_a = 0
node_rows = nil
if node_present
  Dir.mktmpdir('conv-fixtures') do |dir|
    # Never mutate the vendored file — copy to tmpdir and append the export
    # (esbuild keeps top-level function names, so this exposes the internal).
    exposed = File.join(dir, 'tableau-exposed.mjs')
    File.open(exposed, 'w:UTF-8') do |f|
      f.write(bundle)
      f.write("\nexport { #{names[0]} as tableauFormulaToSigma };\n")
    end

    # Fixture I/O via JSON files, not argv/heredoc — inputs contain quotes and
    # a literal newline (N-F14).
    fx_path  = File.join(dir, 'fixtures.json')
    res_path = File.join(dir, 'results.json')
    File.open(fx_path, 'w:UTF-8') do |f|
      f.write(JSON.generate(NODE_FIXTURES.map { |x| { 'id' => x[:id], 'input' => x[:input] } }))
    end

    # Node ESM on Windows rejects a bare drive-letter specifier
    # (ERR_UNSUPPORTED_ESM_URL_SCHEME, protocol 'c:') — absolute paths must be
    # file:// URLs there. POSIX absolute paths import fine as-is, so only
    # rewrite on Windows (same idiom as mechanical-specs.rb run_converter).
    import_specifier =
      if Gem.win_platform? && exposed.to_s.match?(/\A[A-Za-z]:/)
        'file:///' + exposed.gsub('\\', '/')
      else
        exposed
      end

    runner = File.join(dir, 'run.mjs')
    File.open(runner, 'w:UTF-8') do |f|
      f.write(<<~JS)
        import { readFileSync, writeFileSync } from 'node:fs';
        import { tableauFormulaToSigma } from #{import_specifier.to_json};
        const fixtures = JSON.parse(readFileSync(#{fx_path.to_json}, 'utf8'));
        const out = fixtures.map(({ id, input }) => {
          const warnings = [];
          let output = null, error = null;
          try { output = tableauFormulaToSigma(input, warnings); }
          catch (e) { error = String(e); }
          return { id, output, warnings, error };
        });
        writeFileSync(#{res_path.to_json}, JSON.stringify(out));
      JS
    end

    _o, e, st = Open3.capture3('node', runner)
    unless st.success?
      warn "FAIL — node fixture runner failed:\n#{e}"
      exit 1
    end
    node_rows = JSON.parse(File.read(res_path, encoding: 'utf-8'))
  end

  by_id = {}
  node_rows.each { |r| by_id[r['id']] = r }

  NODE_FIXTURES.each do |fx|
    r     = by_id[fx[:id]]
    got   = r && r['output']
    warns = (r && r['warnings']) || []
    err   = r && r['error']

    if fx[:pending]
      exp = fx[:pending][:expected]
      puts "  PENDING  #{fx[:id]}  current=#{got.inspect}  expected=#{exp.inspect}  (#{fx[:pending][:reason]})"
      if got == exp
        puts "  NOTE: PENDING #{fx[:id]} now produces the correct output — promote to a hard assertion"
      end
      next
    end

    ok_out  = err.nil? && got == fx[:expect]
    ok_warn = fx[:warn] ? warns.any? { |w| w.include?(fx[:warn]) } : warns.empty?
    detail  = fx[:warn] ? "  [warns: #{fx[:warn]}]" : ''
    diag    = (ok_out && ok_warn) ? '' :
              "  (got output=#{got.inspect} warnings=#{warns.inspect}#{err ? " error=#{err.inspect}" : ''})"
    check(ok_out && ok_warn,
          "#{fx[:id]}  #{one_line(fx[:input])}  →  #{fx[:expect]}#{detail}#{diag}", fails)
  end

  # Secondary lint: Sigma formula names are CASE-SENSITIVE
  # (lib/formula_normalize.rb) — every Identifier( token the converter emits
  # must be an exact known spelling. Catches a re-vendor leaking e.g. LTRIM(.
  # Excluded: PENDING rows, /* … */ comment outputs (N-X5), and the
  # intentional N-X4 unconverted passthrough.
  puts
  puts 'Part A lint — emitted function tokens are exact Sigma spellings'
  leaks = []
  NODE_FIXTURES.each do |fx|
    next if fx[:pending] || fx[:id] == 'N-X4'
    got = (by_id[fx[:id]] || {})['output'].to_s
    next if got.start_with?('/*')
    got.scan(FormulaNormalize::TOKEN_RE) do
      tok = $&
      next if tok.start_with?('[', '"', "'")
      leaks << "#{fx[:id]}:#{tok}(" unless FormulaNormalize::KNOWN_EXACT.include?(tok)
    end
  end
  check(leaks.empty?,
        "every emitted Identifier( is a known exact Sigma spelling#{leaks.empty? ? '' : " (leaks: #{leaks.uniq.join(', ')})"}",
        fails)
else
  skipped_a = NODE_FIXTURES.size
  warn '  WARN  node not found on PATH — Part A SKIPPED ' \
       "(#{skipped_a} node-converter fixtures unexercised; CI runners may lack node). " \
       'Install node (doctor.sh enforces it for the converter path) to run them.'
end

# ===========================================================================
# Part B — Ruby worksheet-calc translators
# ===========================================================================
puts
puts 'Part B — Ruby translators (build-charts-from-signals.rb)'
# encoding: system Ruby 2.6 defaults to US-ASCII under some locales and the
# extracted defs contain UTF-8 arrows — read explicitly as UTF-8.
src = File.read(CHARTS, encoding: 'utf-8')
o = Object.new
%w[USER_AGG_FN SIGMA_AGG WINDOW_SIGMA_FNS WINDOW_MANUAL_RE WINDOW_TC_RE].each do |c|
  m = src.match(/^#{c}\s*=\s*%w\[.*?\]\.freeze/m) ||
      src.match(/^#{c}\s*=\s*\{.*?\}\.freeze/m) || src.match(/^#{c}\s*=.*$/)
  o.instance_eval(m[0]) if m
end
%w[
  map_column strip_tableau_comments translate_sla_ratio split_top_level_args
  parse_tableau_function_call translated_calc_reference param_control_ref
  translate_user_agg_formula translate_row_level_calc translate_dim_calc
  translate_kpi_measure_formula translate_tableau_tc translate_window_calc
  header_base
].each do |fn|
  m = src.match(/^def #{fn}\b.*?\n^end$/m)
  abort "test bug: could not extract #{fn}" unless m
  o.instance_eval(m[0])
end

RUBY_FIXTURES.each do |fx|
  res = case fx[:entry]
        when :row then o.translate_row_level_calc(fx[:input], MMAP, {})
        when :dim then o.translate_dim_calc(fx[:input], MMAP, {})
        when :kpi then o.translate_kpi_measure_formula(fx[:input], MMAP, {})
        when :agg then o.translate_user_agg_formula(fx[:input], MMAP, {})
        when :win then o.translate_window_calc(fx[:input], MMAP, {})
        end
  exp = fx[:expect]
  if exp.nil?
    check(res.nil?,
          "#{fx[:id]} [#{fx[:entry]}]  #{one_line(fx[:input])}  →  nil (fail-closed)#{res.nil? ? '' : "  (got #{res.inspect})"}",
          fails)
  elsif exp.is_a?(Hash)
    bad = exp.reject { |k, v| res.is_a?(Hash) && res[k] == v }
    check(bad.empty?,
          "#{fx[:id]} [win]  #{one_line(fx[:input])}  →  #{exp.inspect}#{bad.empty? ? '' : "  (got #{res.inspect})"}",
          fails)
  else
    check(res == exp,
          "#{fx[:id]} [#{fx[:entry]}]  #{one_line(fx[:input])}  →  #{exp}#{res == exp ? '' : "  (got #{res.inspect})"}",
          fails)
  end
end

# ===========================================================================
puts
pending_ct = NODE_FIXTURES.count { |f| f[:pending] }
if fails.empty?
  part_a = if node_present
             "Part A #{NODE_FIXTURES.size - pending_ct} asserted + #{pending_ct} PENDING"
           else
             "Part A SKIPPED (no node on PATH; #{skipped_a} fixtures unexercised)"
           end
  puts "OK — converter formula fixtures hold (#{part_a}; Part B #{RUBY_FIXTURES.size} rows)"
  exit 0
else
  warn "FAIL — #{fails.size} check(s) failed:"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
