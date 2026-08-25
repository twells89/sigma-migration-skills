# frozen_string_literal: true

require_relative 'workbook_rule_registry'

# Applies semantic compile-plan decisions to the existing shared chart emitters.
# It changes inference inputs (kind/filter bindings) but never duplicates the
# emitters themselves.
module CompilePlanApply
  module_function

  def index(plan)
    by_zone = {}
    by_name = {}
    Array(plan && plan['visuals']).each do |entry|
      by_zone[[entry['dashboard'].to_s, entry['zone_id'].to_s]] = entry if entry['zone_id']
      by_name[[entry['dashboard'].to_s, entry['source_name'].to_s]] = entry if entry['source_name']
    end
    { by_zone: by_zone, by_name: by_name }
  end

  def find(index, dashboard, zone)
    index[:by_zone][[dashboard.to_s, zone['id'].to_s]] ||
      index[:by_name][[dashboard.to_s, zone['caption'].to_s]]
  end

  def apply_zone!(zone, dashboard, index)
    entry = find(index, dashboard, zone)
    return nil unless entry
    raise ArgumentError, "compile plan entry #{entry['key']} is not lowered" unless entry['status'] == 'lowered'

    source_kind = WorkbookRuleRegistry.chart_key_for_target(entry['target_kind'])
    zone['chart_kind'] = source_kind if source_kind
    zone['is_crosstab'] = true if entry['target_kind'] == 'pivot-table'
    zone['_compile_plan_key'] = entry['key']

    planned_filters = Array(entry.dig('bindings', 'filters')).map do |filter|
      {
        'column_caption' => filter['column'],
        'kind' => filter['kind'],
        'exclude' => filter['mode'] == 'exclude',
        'members' => filter['values'],
        '_compile_plan' => true
      }.compact
    end
    if planned_filters.any?
      existing = Array(zone['filters'])
      planned_filters.each do |filter|
        next if existing.any? do |candidate|
          candidate['column_caption'].to_s.casecmp?(filter['column_caption'].to_s) &&
            Array(candidate['members']) == Array(filter['members'])
        end
        existing << filter
      end
      zone['filters'] = existing
    end
    entry
  end
end
