#!/usr/bin/env ruby
# frozen_string_literal: true

source = File.read(File.join(__dir__, 'build-charts-from-signals.rb'))
%w[
  map_column translate_row_level_calc translate_dim_calc canonical_switch_value
  coerce_case_literal param_control_ref remap_param_branch split_outer_tableau_if
  translate_nested_param_if translate_case_on_param translate_if_chain_on_param
  translate_user_agg_formula
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
  '(?i)^UPLOADED_TS_EST$' => { 'id' => 'm-uploaded', 'name' => 'UPLOADED_TS_EST' }
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

if failures.empty?
  puts 'ALL PASS — nested parameter percentile translates without truncation'
else
  warn "#{failures.length} failure(s): #{failures.join('; ')}"
  exit 1
end
