# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'tableau_workbook_compiler'

# Hard reconciliation between what the semantic plan promised and what the
# shared emitters actually built.
module CompilePlanReconcile
  module_function

  def reconcile(plan:, chart_specs:, provenance:, coverage: nil)
    elements = flatten_elements(chart_specs)
    chart_elements = elements.select { |element| TableauWorkbookCompiler.chart_target?(element['kind']) }
    control_elements = elements.select { |element| element['kind'] == 'control' }
    planned = Array(plan['visuals']).select do |entry|
      entry['status'] == 'lowered' && TableauWorkbookCompiler.chart_target?(entry['target_kind'])
    end
    planned_keys = planned.filter_map { |entry| entry['key'] }.to_set
    provenance_records = provenance.is_a?(Hash) && provenance['elements'].is_a?(Hash) ?
      provenance['elements'] : (provenance || {})
    matched_keys = chart_elements.filter_map do |element|
      provenance_records.dig(element['id'], 'compile_plan_key')
    end.to_set
    built_without_plan = chart_elements.reject do |element|
      provenance_records.dig(element['id'], 'compile_plan_key')
    end.map { |element| element['id'] }
    planned_control_names = Array(plan['controls']).select { |entry| entry['status'] == 'lowered' }
                                                       .filter_map { |entry| entry['name'] }.map(&:to_s).uniq
    built_control_names = control_elements.filter_map { |element| element['name'] }.map(&:to_s).uniq
    missing_controls = planned_control_names.reject do |name|
      built_control_names.any? { |built| built.casecmp?(name) }
    end
    dropped = coverage&.dig('summary', 'dropped').to_i
    result = {
      'schema_version' => 1,
      'planned_chart_keys' => planned_keys.to_a.sort,
      'matched_chart_keys' => matched_keys.to_a.sort,
      'unmatched_plan_keys' => (planned_keys - matched_keys).to_a.sort,
      'unexplained_builds' => built_without_plan.sort,
      'planned_control_names' => planned_control_names.sort,
      'built_control_names' => built_control_names.sort,
      'missing_controls' => missing_controls.sort,
      'coverage_dropped' => dropped
    }
    result['status'] =
      if result['unmatched_plan_keys'].empty? && result['unexplained_builds'].empty? &&
         result['missing_controls'].empty? && dropped.zero?
        'PASS'
      else
        'FAIL'
      end
    result
  end

  def flatten_elements(chart_specs)
    return chart_specs if chart_specs.is_a?(Array)
    return [] unless chart_specs.is_a?(Hash)
    # Hidden helper/data elements support planned visuals but are not themselves
    # source dashboard visuals and therefore do not require plan keys.
    Array(chart_specs['pages']).flat_map { |page| Array(page['elements']) }
  end
end
