#!/usr/bin/env ruby
# frozen_string_literal: true

source = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
%w[
  map_column qualify_master_formula strip_tableau_comments worksheet_calculation_for
  translate_row_level_calc translate_dim_calc
  translated_calc_reference translate_sla_ratio canonical_switch_value
  split_top_level_args parse_tableau_function_call
  coerce_case_literal param_control_ref remap_param_branch split_outer_tableau_if
  translate_nested_param_if translate_case_on_param translate_if_chain_on_param
  translate_user_agg_formula decompose_nested_fixed
].each do |name|
  definition = source.match(/^def #{name}\b.*?\n^end$/m)
  abort "could not extract #{name}" unless definition
  eval(definition[0]) # rubocop:disable Security/Eval -- first-party helper test
end

master_map = {
  '(?i)^Measure Name$' => { 'id' => 'm-name', 'name' => 'Measure Name' },
  '(?i)^Tabular Flag$' => { 'id' => 'm-tab', 'name' => 'Tabular Flag' },
  '(?i)^Verification Flow Type$' => { 'id' => 'm-flow', 'name' => 'Verification Flow Type' },
  '(?i)^Measure Value$' => { 'id' => 'm-value', 'name' => 'Measure Value' },
  '(?i)^Verification Date$' => { 'id' => 'm-date', 'name' => 'Verification Date' },
  '(?i)^UPLOADED_TS_EST$' => { 'id' => 'm-uploaded', 'name' => 'UPLOADED_TS_EST' },
  '(?i)^DOC_PK$' => { 'id' => 'm-doc', 'name' => 'DOC_PK' },
  '(?i)^TAT_SETTING$' => { 'id' => 'm-setting', 'name' => 'TAT_SETTING' },
  '(?i)^VERIFIED_PAGES$' => { 'id' => 'm-verified', 'name' => 'VERIFIED_PAGES' },
  '(?i)^Instant/Complete/Requeue$' => { 'id' => 'm-disposition', 'name' => 'Instant/Complete/Requeue' },
  '(?i)^VERIFICATION_FLOW_TYPE$' => { 'id' => 'm-verification-flow', 'name' => 'VERIFICATION_FLOW_TYPE' }
}
formula = <<~TABLEAU
  PERCENTILE(
    IF [Include Bank Statement] = "Yes" THEN
      IF [Measure Name] = 'TAT' AND [Tabular Flag] = 'Non-Tabular' THEN [Measure Value] END
    ELSE
      IF [Measure Name] = 'TAT' AND [Tabular Flag] = 'Non-Tabular'
         AND [Verification Flow Type] <> 'BANK_STATEMENT' THEN [Measure Value] END
    END
  , 0.75) / 60
TABLEAU

result = translate_if_chain_on_param(
  formula, ['Include Bank Statement'], master_map, {}
)
failures = []
check = lambda do |condition, message|
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  failures << message unless condition
end
check.call(result&.start_with?('PercentileCont('),
           "outer Tableau percentile becomes PercentileCont (got #{result.inspect})")
check.call(result&.include?('Switch([ctl-param-include-bank-statement]'),
           'parameter IF becomes a control-driven Switch')
check.call(result.to_s.scan(/\bIf\(/).length == 2,
           'both nested conditional branches survive as Sigma If formulas')
check.call(result&.include?('[Master/Measure Value]') &&
           result.include?('[Master/Verification Flow Type]'),
           'nested branches bind their real master columns')
check.call(result.to_s !~ /\b(?:THEN|END|PERCENTILE)\b/,
           'no Tableau syntax leaks into the emitted formula')
check.call(!result.to_s.include?("'"),
           'Tableau single-quoted literals become Sigma double-quoted strings')

date_case = <<~TABLEAU
  CASE [Monthly/Weekly/Daily]
    WHEN "Monthly" THEN DATETRUNC('month',[Verification Date])
    WHEN "Quarterly" THEN DATETRUNC('quarter',[Verification Date])//+' '+STR(YEAR([UPLOADED_TS_EST]))
    ELSE DATETRUNC('day',[Verification Date])
  END
TABLEAU
date_result = translate_case_on_param(
  date_case, ['Monthly/Weekly/Daily'], master_map, {}
)
check.call(date_result&.include?('DateTrunc("month", [Master/Verification Date])') &&
           date_result.include?('DateTrunc("quarter", [Master/Verification Date])'),
           "date-switch branches use Sigma date functions (got #{date_result.inspect})")
check.call(date_result.to_s !~ %r{//|\bSTR\b|DATETRUNC|'month'|'quarter'},
           'Tableau comments, function casing, and single-quoted units do not leak')

conditional_sum = translate_user_agg_formula(
  "SUM(IF [Tabular Flag] = 'Tabular' THEN [Measure Value] END)",
  master_map,
  {}
)
check.call(
  conditional_sum == 'Sum(If([Master/Tabular Flag] = "Tabular", [Master/Measure Value], Null))',
  "conditional aggregate becomes a Sigma aggregate over If (got #{conditional_sum.inspect})"
)

conditional_percentile = translate_user_agg_formula(
  "PERCENTILE(IF [Measure Name] = 'TAT' THEN [Measure Value] ELSE NULL END, 0.75) / 60",
  master_map,
  {}
)
check.call(
  conditional_percentile ==
    'PercentileCont(If([Master/Measure Name] = "TAT", [Master/Measure Value], NULL), 0.75) / 60',
  "conditional percentile becomes PercentileCont over If (got #{conditional_percentile.inspect})"
)

columns_by_guid = {
  'TAT Calc (copy)_123' => {
    'caption' => 'TAT in mins',
    'formula' => <<~TABLEAU
      (IF [Measure Name] = 'TAT' THEN [Measure Value] ELSE NULL END)/60
      /* { FIXED [DOC_PK] : MAX([Measure Value]) } */
    TABLEAU
  },
  'Calc Setting' => {
    'caption' => 'TAT Setting- Calc',
    'formula' => "// retired override\n[TAT_SETTING]"
  },
  'Calc Exceeding' => {
    'caption' => 'Number of Docs exceeding TAT Setting',
    'formula' => 'COUNTD(IF [TAT Calc (copy)_123] > [Calc Setting] THEN [DOC_PK] ELSE NULL END)'
  },
  'Nth Param (copy)_456' => {
    'caption' => 'Nth Percentile - TAT Tierwise',
    'formula' => '0.95'
  },
  'Calculation_744219879042306048' => {
    'caption' => 'No. of uploaded pages',
    'formula' => <<~TABLEAU
      IF [Measure Name] = 'UPLOADED_PAGES' THEN [Measure Value] ELSE NULL END
      // retired source-specific page-count branch
    TABLEAU
  },
  'Calculation_Requeue' => {
    'caption' => 'Requeue Count',
    'formula' => "IF [Instant/Complete/Requeue] = 'Requeue' AND [VERIFICATION_FLOW_TYPE] <> 'UNKNOWN' THEN [Measure Value] END"
  },
  'Calculation_Instant' => {
    'caption' => 'Instant Count',
    'formula' => "IF [Instant/Complete/Requeue] = 'Instant' AND [VERIFICATION_FLOW_TYPE] <> 'UNKNOWN' THEN [Measure Value] END"
  }
}
nth = translate_user_agg_formula(
  "// PERCENTILE([TAT Calc (copy)_123], 0.95)\n" \
  "PERCENTILE([TAT Calc (copy)_123], [Parameters].[Nth Param (copy)_456])",
  master_map,
  columns_by_guid
)
check.call(
  nth&.include?('PercentileCont(If([Master/Measure Name] = "TAT"') &&
    nth.include?('[ctl-param-nth-percentile-tat-tierwise]'),
  "commented LOD percentile becomes an inline control-driven percentile (got #{nth.inspect})"
)
sla = translate_user_agg_formula(
  '(COUNTD([DOC_PK]) - [Calc Exceeding]) / COUNTD([DOC_PK])',
  master_map,
  columns_by_guid
)
check.call(
  sla&.include?('CountDistinct(If(If([Master/Measure Name] = "TAT"') &&
    sla.include?('[Master/TAT_SETTING]') &&
    !sla.include?('Calc Exceeding'),
  "SLA ratio recursively expands the active TAT calculation (got #{sla.inspect})"
)
check.call(
  decompose_nested_fixed(columns_by_guid['TAT Calc (copy)_123']['formula']).nil?,
  'FIXED expressions inside Tableau comments do not create false LOD helper chains'
)
caption_matched_calc = worksheet_calculation_for(
  [{ 'name' => '[Calculation_75th_TAT]', 'caption' => '75th Percentile TAT',
     'formula' => 'PERCENTILE([TAT Calc (copy)_123], 0.75)' }],
  '75th Percentile TAT'
)
check.call(
  caption_matched_calc && caption_matched_calc['name'] == '[Calculation_75th_TAT]',
  'pivot measures resolve worksheet calculations by display caption'
)
Object.const_set(:USER_AGG_FN, {
  'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
  'MEDIAN' => 'Median'
}.freeze) unless Object.const_defined?(:USER_AGG_FN)
nested_ratio = translate_user_agg_formula(
  'SUM([VERIFIED_PAGES]) / SUM([Calculation_744219879042306048])',
  master_map,
  columns_by_guid
)
check.call(
  nested_ratio ==
    'Sum([Master/VERIFIED_PAGES]) / Sum(If([Master/Measure Name] = "UPLOADED_PAGES", [Master/Measure Value], NULL))',
  "aggregates recursively expand referenced row-level calculations (got #{nested_ratio.inspect})"
)
requeue_ratio = translate_user_agg_formula(
  'SUM([Calculation_Requeue]) / (SUM([Calculation_Requeue]) + SUM([Calculation_Instant]))',
  master_map,
  columns_by_guid
)
check.call(
  requeue_ratio&.scan('If(')&.length == 3 &&
    requeue_ratio.include?('[Master/Instant/Complete/Requeue]') &&
    requeue_ratio.include?('[Master/VERIFICATION_FLOW_TYPE]'),
  "nested conditional ratio preserves boolean predicates (got #{requeue_ratio.inspect})"
)
qualified_master_formula = qualify_master_formula(
  'If([VERIFICATION_FLOW_TYPE] = "UNKNOWN", Null, [Measure Value])',
  master_map
)
check.call(
  qualified_master_formula ==
    'If([Master/VERIFICATION_FLOW_TYPE] = "UNKNOWN", Null, [Master/Measure Value])',
  "master-derived formulas are qualified for chart reuse (got #{qualified_master_formula.inspect})"
)

if failures.empty?
  puts 'ALL PASS — nested parameter percentile translates without truncation'
else
  warn "#{failures.length} failure(s): #{failures.join('; ')}"
  exit 1
end
