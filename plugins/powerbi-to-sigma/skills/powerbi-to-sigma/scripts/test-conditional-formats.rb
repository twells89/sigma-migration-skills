#!/usr/bin/env ruby
# frozen_string_literal: true
# test-conditional-formats.rb — regression test for table/matrix conditional
# formatting: the Python extractor (_conditional_formats in extract-pbir.py) and
# the Ruby emitter (lib/pbi_conditional_formats.rb). Offline: no API, no creds.
# Run: ruby scripts/test-conditional-formats.rb
#
# Ground truth: fixtures/conditional_formats/*.visual.json are REAL Power BI PBIR
# bytes — a server-canonical tableEx round-tripped through Fabric (gradient bg +
# gradient font + data bars) and a Microsoft BCApps matrix (columnFormatting
# data bars). See the PR that added conditional-formatting support.

require 'json'
require_relative 'lib/pbi_conditional_formats'

$fail = 0
def ok(name, cond)
  puts((cond ? "  ok  " : 'FAIL  ') + name)
  $fail += 1 unless cond
end

HERE = __dir__
FIX  = File.expand_path('../fixtures/conditional_formats', HERE)

# --- 1. Ruby emitter: modes map to the right Sigma conditionalFormats ---------
qr_cids = {
  'ORDER_FACT.Net Revenue $'   => 'e-c1',
  'ORDER_FACT.Gross Profit $'  => 'e-c2',
  'ORDER_FACT.Profit Margin'   => 'e-c3',
  'ORDER_FACT.Return Rate'     => 'e-c4',
  'ORDER_FACT.Days'            => 'e-c5',
}
cfs = [
  { 'target' => 'ORDER_FACT.Net Revenue $',  'property' => 'background', 'mode' => 'gradient', 'scheme' => %w[#FFFFFF #118DFF] },
  { 'target' => 'ORDER_FACT.Profit Margin',  'property' => 'font',       'mode' => 'gradient', 'scheme' => %w[#D64550 #63BE7B] },
  { 'target' => 'ORDER_FACT.Gross Profit $', 'property' => 'background', 'mode' => 'dataBars', 'positive' => '#118DFF', 'negative' => '#D64550' },
  { 'target' => 'ORDER_FACT.Return Rate',    'property' => 'background', 'mode' => 'fieldValue', 'measure' => 'ORDER_FACT.Return Color' },
  { 'target' => 'ORDER_FACT.Days',           'property' => 'background', 'mode' => 'rules', 'unresolved' => true },
  { 'target' => 'ORDER_FACT.Not In Table',   'property' => 'background', 'mode' => 'gradient', 'scheme' => %w[#fff #000] },
]
res = PbiConditionalFormats.build(cfs, qr_cids, 'Scorecard', 'table')
fmts = res['formats']
cov  = res['coverage']

ok('gradient background -> backgroundScale', fmts.any? { |f| f['type'] == 'backgroundScale' && f['columnIds'] == ['e-c1'] && f['scheme'] == %w[#FFFFFF #118DFF] })
ok('gradient font -> fontScale',             fmts.any? { |f| f['type'] == 'fontScale' && f['columnIds'] == ['e-c3'] })
ok('dataBars -> dataBars [neg,pos]',         fmts.any? { |f| f['type'] == 'dataBars' && f['columnIds'] == ['e-c2'] && f['scheme'] == %w[#D64550 #118DFF] })
ok('only the 3 mappable modes emitted',      fmts.size == 3)
ok('field-value -> coverage approximated/recoverable', cov.any? { |c| c[:severity] == 'approximated' && c[:recoverable] && c[:detail] =~ /Return Rate/ })
ok('rules -> coverage degraded/recoverable', cov.any? { |c| c[:severity] == 'degraded' && c[:recoverable] && c[:detail] =~ /rules-based/ })
ok('CF on absent column -> coverage degraded/not-recoverable', cov.any? { |c| c[:recoverable] == false && c[:detail] =~ /not in the migrated/ })

# --- 1b. Rules mode -> type:single ------------------------------------------
rule_cfs = [
  # numeric bands on Profit Margin: <0.15 red, [0.15,0.30) yellow, >=0.30 green
  { 'target' => 'ORDER_FACT.Profit Margin', 'property' => 'background', 'mode' => 'rules',
    'rules' => [
      { 'comparisons' => [{ 'op' => '<', 'value' => '0.15', 'driver' => 'ORDER_FACT.Profit Margin' }], 'color' => '#F8696B' },
      { 'comparisons' => [{ 'op' => '>=', 'value' => '0.15', 'driver' => 'ORDER_FACT.Profit Margin' },
                          { 'op' => '<', 'value' => '0.30', 'driver' => 'ORDER_FACT.Profit Margin' }], 'color' => '#FFEB84' },
      { 'comparisons' => [{ 'op' => '>=', 'value' => '0.30', 'driver' => 'ORDER_FACT.Profit Margin' }], 'color' => '#63BE7B' },
    ] },
  # font-color text-equality rule
  { 'target' => 'ORDER_FACT.Order Channel', 'property' => 'font', 'mode' => 'rules',
    'rules' => [{ 'comparisons' => [{ 'op' => '=', 'value' => 'App', 'driver' => 'ORDER_FACT.Order Channel' }], 'color' => '#118DFF' }] },
  # cross-column rule -> coverage (single can't color A by B)
  { 'target' => 'ORDER_FACT.Net Revenue $', 'property' => 'background', 'mode' => 'rules',
    'rules' => [{ 'comparisons' => [{ 'op' => '<', 'value' => '0', 'driver' => 'ORDER_FACT.Gross Profit $' }], 'color' => '#F8696B' }] },
]
rq = { 'ORDER_FACT.Profit Margin' => 'e-c3', 'ORDER_FACT.Order Channel' => 'e-c0', 'ORDER_FACT.Net Revenue $' => 'e-c1' }
rr = PbiConditionalFormats.build(rule_cfs, rq, 'Scorecard', 'table')
rf = rr['formats']
ok('rules: one-sided threshold -> single with op',   rf.any? { |f| f['type'] == 'single' && f['columnIds'] == ['e-c3'] && f['condition'] == '<' && f['value'] == 0.15 && f['style'] == { 'backgroundColor' => '#F8696B' } })
ok('rules: And range -> single formula "[Col] >= lo and [Col] < hi"', rf.any? { |f| f['condition'] == 'formula' && f['formula'] == '[Profit Margin] >= 0.15 and [Profit Margin] < 0.3' && f['style'] == { 'backgroundColor' => '#FFEB84' } })
ok('rules: >= band -> single >=',                    rf.any? { |f| f['condition'] == '>=' && f['value'] == 0.30 && f['style'] == { 'backgroundColor' => '#63BE7B' } })
ok('rules: font text-equality -> single = with color style', rf.any? { |f| f['columnIds'] == ['e-c0'] && f['condition'] == '=' && f['value'] == 'App' && f['style'] == { 'color' => '#118DFF' } })
ok('rules: 3 numeric bands + 1 text = 4 singles',    rf.size == 4)
ok('rules: cross-column rule -> coverage, not a single', rr['coverage'].any? { |c| c[:detail] =~ /cross-column/ })

# leaf-name fallback: entity-qualified target still resolves to a leaf-matched col
res2 = PbiConditionalFormats.build(
  [{ 'target' => 'SOME_OTHER.Net Revenue $', 'property' => 'background', 'mode' => 'gradient', 'scheme' => %w[#fff #000] }],
  qr_cids, 'Scorecard', 'table'
)
ok('leaf-name fallback resolves entity-mismatched target', res2['formats'].size == 1 && res2['formats'][0]['columnIds'] == ['e-c1'])

# --- 2. Python extractor: real PBIR bytes -> normalized CF records -------------
require 'tempfile'
py = ENV['PBI_PY'] || 'python3'
EXTRACTOR = File.join(__dir__, 'extract-pbir.py')
def extract_cf(py, visual_json_path)
  Tempfile.create(['cf_extract', '.py']) do |f|
    f.write(<<~PY)
      import json, importlib.util, sys
      spec = importlib.util.spec_from_file_location("ep", sys.argv[1])
      ep = importlib.util.module_from_spec(spec); spec.loader.exec_module(ep)
      v = json.load(open(sys.argv[2]))["visual"]
      print(json.dumps(ep._conditional_formats(v, v.get("visualType"))))
    PY
    f.flush
    out = `#{py} #{f.path.inspect} #{EXTRACTOR.inspect} #{visual_json_path.inspect} 2>/dev/null`
    return (JSON.parse(out) rescue nil)
  end
end

tbl = extract_cf(py, File.join(FIX, 'tableEx_gradient_databars.visual.json'))
if tbl.nil?
  puts 'SKIP  python extractor checks (no usable python / import failed)'
else
  modes = tbl.map { |c| c['mode'] }
  ok('extract: gradient background present', tbl.any? { |c| c['mode'] == 'gradient' && c['property'] == 'background' && c['scheme'].first =~ /\A#/ })
  ok('extract: gradient font present',       tbl.any? { |c| c['mode'] == 'gradient' && c['property'] == 'font' })
  ok('extract: dataBars present w/ pos+neg', tbl.any? { |c| c['mode'] == 'dataBars' && c['positive'] =~ /\A#/ && c['negative'] =~ /\A#/ })
  ok('extract: every record carries a target', tbl.all? { |c| c['target'].to_s != '' })

  bc = extract_cf(py, File.join(FIX, 'matrix_databars_bcapps.visual.json'))
  ok('extract: BCApps matrix data bars', bc && bc.any? { |c| c['mode'] == 'dataBars' })

  # end-to-end: extracted records feed the emitter, targets resolve by leaf
  cids = {}
  tbl.each { |c| cids[c['target']] = "col-#{PbiConditionalFormats.leaf(c['target'])}" }
  e2e = PbiConditionalFormats.build(tbl, cids, 'Region Performance', 'table')
  ok('e2e: extractor output -> >=2 Sigma formats', e2e['formats'].size >= 2)
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILURE(S)")
exit($fail.zero? ? 0 : 1)
