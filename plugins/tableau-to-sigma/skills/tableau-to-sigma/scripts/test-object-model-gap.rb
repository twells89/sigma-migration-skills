#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for detect_object_model in scan-workbook-gaps.rb — the
# SINGLE-datasource multi-table relationship model ("noodle", 2020.2+
# <object-graph>). The 2026-07-28 field failure: a one-datasource 6-table
# relationship workbook printed a reassuring "Datasources: 1" (no detector
# existed), sailed past Phase 0, and the converter mis-elected a dimension as
# the fact. The detector must:
#   TRIP  (❌ :unhandled → the migrate-tableau exit-11 stop) when ANY
#         relationship lacks a wire-able serialized equality key (none /
#         computed-only / range-only / unresolved endpoint) or any logical
#         table is untouched — the DISCONNECTED-TABLES outcome — with the
#         per-pair punch list in the blurb;
#   NOT TRIP (✅ :auto row, still announcing the election-verify duty) on a
#         fully-wired noodle — the ≤5% false-stop budget case;
#   STAY SILENT on: single logical object (legacy-migrated join model),
#         workbooks with no <object-graph>, and the Parameters datasource.
# Both plain and _.fcp.-wrapped spellings must parse.
#
# Usage:  ruby scripts/test-object-model-gap.rb

require 'json'
require_relative 'scan-workbook-gaps'

FAILS = []
def check(cond, msg)
  puts((cond ? '  ok  ' : '  FAIL ') + msg)
  FAILS << msg unless cond
end

def om(content)
  feats, detail, plan = detect_object_model(content)
  [feats, detail, plan]
end

def rel_xml(first, second, expr)
  <<~XML
    <relationship>
      #{expr}
      <first-end-point object-id='#{first}' />
      <second-end-point object-id='#{second}' />
    </relationship>
  XML
end

EQ = "<expression op='='><expression op='[DATE_KEY]'/><expression op='[DATE_KEY]'/></expression>"
EQ2 = "<expression op='='><expression op='[SITE_KEY]'/><expression op='[SITE_KEY]'/></expression>"

def noodle(rels:, objects: %w[FACT_VISITS_AA11BB22CC33DD44 DIM_DATES_1122334455667788 DIM_SITES_99887766554433AA],
           graph_tag: 'object-graph', ds_name: 'federated.1noodle')
  <<~XML
    <?xml version='1.0'?>
    <workbook><datasources><datasource name='#{ds_name}' caption='Visits Model'>
      <connection class='federated'>
        <relation type='collection'>
          <relation connection='c1' name='FACT_VISITS' table='[PUBLIC].[FACT_VISITS]' type='table' />
          <relation connection='c1' name='DIM_DATES' table='[PUBLIC].[DIM_DATES]' type='table' />
          <relation connection='c1' name='DIM_SITES' table='[PUBLIC].[DIM_SITES]' type='table' />
        </relation>
      </connection>
      <#{graph_tag}>
        <objects>
          #{objects.map { |o| "<object caption='#{o.split('_').first(2).join(' ')}' id='#{o}' />" }.join("\n        ")}
        </objects>
        <relationships>
          #{rels.join("\n        ")}
        </relationships>
      </#{graph_tag}>
    </datasource></datasources></workbook>
  XML
end

puts 'Part A — fully-wired noodle must NOT trip (false-stop budget)'
feats, detail, plan = om(noodle(rels: [
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_DATES_1122334455667788', EQ),
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_SITES_99887766554433AA', EQ2)
]))
check(feats.size == 1, "fully-wired: exactly one feature row (got #{feats.size})")
check(feats.none? { |f| f[:status] == :unhandled }, 'fully-wired: NO ❌-unhandled row (must not stop)')
check(feats.any? { |f| f[:status] == :auto && f[:blurb] =~ /fact election|--fact-table/i },
      'fully-wired: ✅ row still tells the operator to VERIFY the announced election')
check(plan && plan['datasources'][0]['fact_candidate'] == 'FACT_VISITS',
      "plan sidecar carries the degree-based fact candidate (got #{plan && plan['datasources'][0]['fact_candidate']})")
check(plan['datasources'][0]['relationships'].all? { |r| r['status'] == 'wired' },
      'plan sidecar: every relationship status wired')
check(detail.is_a?(Array) && detail[0]['unwired'].zero?, 'detail row reports 0 unwired')

puts 'Part B — missing serialized keys must TRIP with the per-pair punch list'
feats, _d, plan = om(noodle(rels: [
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_DATES_1122334455667788', ''),
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_SITES_99887766554433AA', EQ2)
]))
bad = feats.find { |f| f[:status] == :unhandled }
check(bad, 'no-key relationship: ❌-unhandled row present (drives exit-11 stop)')
check(bad && bad[:blurb] =~ /FACT_VISITS↔DIM_DATES: no-serialized-key/,
      'punch list names the exact pair + reason')
check(bad && bad[:blurb] =~ /--reuse-dm/ && bad[:blurb] =~ /object-graph-plan\.json/,
      'punch list routes to the plan sidecar + the --reuse-dm re-entry (never hand-POST)')
check(plan['datasources'][0]['relationships'].map { |r| r['status'] }.sort == %w[no-serialized-key wired],
      'plan statuses: one wired, one no-serialized-key')

puts 'Part C — computed-only key trips as its own reason'
feats, = om(noodle(rels: [
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_DATES_1122334455667788',
          "<expression op='='><expression op='DATE([ORDER_DATE])'/><expression op='[DATE_DAY]'/></expression>")
]))
bad = feats.find { |f| f[:status] == :unhandled }
check(bad && bad[:blurb] =~ /computed-only-key/, 'computed-only key → ❌ with computed-only-key reason')

puts 'Part C2 — mixed physical + computed keys trip as partial'
mixed = "<expression op='AND'>" \
        "#{EQ}" \
        "<expression op='='><expression op='DATETRUNC([ORDER_DATE])'/><expression op='[DATE_DAY]'/></expression>" \
        '</expression>'
feats, = om(noodle(rels: [
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_DATES_1122334455667788', mixed)
]))
bad = feats.find { |f| f[:status] == :unhandled }
check(bad && bad[:blurb] =~ /partial-computed-key/,
      'mixed physical + computed relationship → ❌ instead of silently widening the join')

puts 'Part D — range/inequality-only key trips as non-equality'
feats, = om(noodle(rels: [
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_DATES_1122334455667788',
          "<expression op='&lt;='><expression op='[DATE_KEY]'/><expression op='[DATE_KEY]'/></expression>")
]))
bad = feats.find { |f| f[:status] == :unhandled }
check(bad && bad[:blurb] =~ /non-equality-key/, 'range-only key → ❌ with non-equality-key reason')

puts 'Part E — unresolved endpoint object-id trips'
feats, = om(noodle(rels: [
  rel_xml('NO_SUCH_OBJECT_DEADBEEF00112233', 'DIM_DATES_1122334455667788', EQ)
]))
bad = feats.find { |f| f[:status] == :unhandled }
check(bad && bad[:blurb] =~ /endpoint-unresolved/, 'unresolved endpoint → ❌ with endpoint-unresolved reason')

puts 'Part F — untouched logical table trips even when every serialized rel is wired'
feats, = om(noodle(rels: [
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_DATES_1122334455667788', EQ)
])) # DIM_SITES exists but no relationship touches it
bad = feats.find { |f| f[:status] == :unhandled }
check(bad && bad[:blurb] =~ /DIM_SITES: no relationship touches it/,
      'isolated table named in the punch list')

puts 'Part G — shapes that must stay SILENT'
feats, _d, plan = om(noodle(rels: [], objects: ['MIGRATED_DATA_AA11BB22CC33DD44']))
check(feats.empty? && plan.nil?, 'single logical object (legacy-migrated join model) → no rows')
feats, _d, plan = om("<?xml version='1.0'?><workbook><datasources><datasource name='flat' caption='Flat'><connection class='snowflake'/></datasource></datasources></workbook>")
check(feats.empty? && plan.nil?, 'no <object-graph> → no rows')
feats, _d, plan = om(noodle(rels: [rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_DATES_1122334455667788', '')],
                            ds_name: 'Parameters'))
check(feats.empty? && plan.nil?, 'Parameters datasource is excluded')

puts 'Part H — _.fcp.-wrapped object-graph spelling parses identically'
feats, _d, plan = om(noodle(rels: [
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_DATES_1122334455667788', EQ),
  rel_xml('FACT_VISITS_AA11BB22CC33DD44', 'DIM_SITES_99887766554433AA', EQ2)
], graph_tag: '_.fcp.ObjectModelEncapsulateLegacy.true...object-graph'))
check(feats.size == 1 && feats[0][:status] == :auto && plan,
      "FCP-wrapped graph detected, fully-wired → ✅ (got #{feats.map { |f| f[:status] }.inspect})")

puts 'Part I — orchestrator stop contract (source-level pins)'
mig = File.read(File.join(__dir__, 'migrate-tableau.rb'))
check(mig.include?("g['status'].to_s == 'unhandled'"),
      'migrate-tableau stops on status=unhandled rows (the ❌ row drives exit-11)')
gaps_src = File.read(File.join(__dir__, 'scan-workbook-gaps.rb'))
check(gaps_src.include?("status: :unhandled, count: (unwired.size + untouched.size).clamp(1, 99)"),
      'detector emits :unhandled with a per-pair count')

puts
if FAILS.empty?
  puts "all object-model gap-detector tests passed"
  exit 0
else
  puts "#{FAILS.size} FAILURE(S):"
  FAILS.each { |f| puts "  - #{f}" }
  exit 1
end
