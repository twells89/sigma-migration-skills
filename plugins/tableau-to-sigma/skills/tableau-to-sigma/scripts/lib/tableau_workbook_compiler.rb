# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'workbook_rule_registry'

# Deterministic lowering planner for Tableau workbook semantics. It converts the
# canonical workbook IR into an explicit rule-by-rule plan consumed by the
# existing chart/layout builders. Unsupported constructs are blocking records,
# never silent fallbacks.
module TableauWorkbookCompiler
  SCHEMA_VERSION = 2
  CHART_RULES = WorkbookRuleRegistry::CHART_RULES
  MARK_FALLBACKS = WorkbookRuleRegistry::MARK_FALLBACKS
  TABLE_CALC_RECIPES = WorkbookRuleRegistry::TABLE_CALC_RECIPES

  module_function

  def compile(ir)
    pages = Array(ir.dig('workbook', 'pages'))
    visuals = pages.flat_map do |page|
      Array(page['zones']).map { |zone| compile_zone(page['name'], zone) }
    end
    controls = compile_controls(ir, pages)
    formulas = compile_formulas(pages)
    actions = compile_actions(pages)
    source_gaps = Array(ir['unsupported']).map { |entry| source_gap(entry) }
    blocking = (
      visuals.select { |entry| entry['status'] == 'unsupported' } +
      controls.select { |entry| entry['status'] == 'unsupported' } +
      formulas.select { |entry| entry['status'] == 'unsupported' } +
      actions.select { |entry| entry['status'] == 'unsupported' } +
      source_gaps.select { |entry| entry['status'] == 'unsupported' }
    )

    plan = {
      'schemaVersion' => SCHEMA_VERSION,
      'kind' => 'tableau-workbook-compile-plan',
      'source_ir_sha256' => Digest::SHA256.hexdigest(JSON.generate(deep_sort(ir))),
      'pages' => pages.map { |page| compile_page(page) },
      'visuals' => visuals,
      'controls' => controls,
      'formulas' => formulas,
      'actions' => actions,
      'source_gaps' => source_gaps,
      'blocking' => blocking,
      'summary' => {
        'pages' => pages.length,
        'source_zones' => visuals.length,
        'visuals_lowered' => visuals.count { |entry| entry['status'] == 'lowered' },
        'planned_chart_visuals' => visuals.count do |entry|
          entry['status'] == 'lowered' && chart_target?(entry['target_kind'])
        end,
        'controls_lowered' => controls.count { |entry| entry['status'] == 'lowered' },
        'formulas_lowered' => formulas.count { |entry| entry['status'] == 'lowered' },
        'actions_lowered' => actions.count { |entry| entry['status'] == 'lowered' },
        'blocking' => blocking.length
      }
    }
    errors = validate(plan)
    raise ArgumentError, errors.join('; ') unless errors.empty?
    plan
  end

  def compile_page(page)
    {
      'name' => page['name'],
      'layout_index' => page['layout_index'],
      'emit_page' => page['emit_page'],
      'rule' => page['is_story'] ? 'page.story-point.v1' : 'page.dashboard.v1',
      'canvas_px' => page['canvas_px'],
      'style_rules' => page['style_rules'],
      'brand_palette' => page['brand_palette']
    }.compact
  end

  def compile_zone(dashboard, zone)
    base = {
      'key' => stable_key('zone', dashboard, zone['id'], zone['caption']),
      'dashboard' => dashboard,
      'zone_id' => zone['id'],
      'source_kind' => zone['kind'],
      'source_name' => zone['caption'],
      'geometry' => zone['geometry'],
      'style' => zone['style']
    }.compact

    case zone['kind'].to_s
    when 'chart', 'worksheet'
      unless chart_bindings_present?(zone)
        return unsupported(
          base,
          'viz.binding-missing.v1',
          'chart has no shelves, measures, channels, or calculations to materialize'
        )
      end
      chart_key = normalized_chart_key(zone)
      if zone['dual_axis']
        return base.merge(
          'status' => 'lowered',
          'target_kind' => 'combo-chart',
          'rule' => 'viz.dual-axis-combo.v1',
          'synchronized_axis' => !!zone['synchronized_axis'],
          'bindings' => compile_bindings(dashboard, zone)
        )
      end
      target, rule = WorkbookRuleRegistry.target_for(chart_key)
      return unsupported(base, 'viz.unknown.v1', "unknown chart family #{chart_key.inspect}") unless target

      base.merge(
        'status' => 'lowered',
        'target_kind' => target,
        'rule' => rule,
        'bindings' => compile_bindings(dashboard, zone)
      )
    when 'filter', 'parameter'
      base.merge('status' => 'lowered', 'target_kind' => 'control', 'rule' => 'control.zone.v1')
    when 'text', 'title', 'dash-title'
      base.merge('status' => 'lowered', 'target_kind' => 'text', 'rule' => 'viz.text.v1')
    when 'image'
      base.merge('status' => 'lowered', 'target_kind' => 'image', 'rule' => 'viz.image.v1')
    when 'container', 'layout', 'spacer', 'blank'
      base.merge('status' => 'layout-only', 'rule' => 'layout.zone.v1')
    when 'dashboard-object'
      compile_dashboard_object(base, zone)
    else
      unsupported(base, 'zone.unknown.v1', "unsupported dashboard zone kind #{zone['kind'].inspect}")
    end
  end

  def compile_dashboard_object(base, zone)
    case zone['button_intent'].to_s
    when 'navigate'
      if zone['button_nav_target'].to_s.empty?
        unsupported(base, 'action.navigation.v1', 'navigation target is unresolved')
      else
        base.merge(
          'status' => 'lowered',
          'target_kind' => 'button',
          'rule' => 'action.navigation.v1',
          'target_page' => zone['button_nav_target']
        )
      end
    when /\Aexport/
      base.merge('status' => 'native-equivalent', 'rule' => 'action.native-export.v1')
    when 'toggle'
      unsupported(base, 'action.container-toggle.v1', 'Sigma has no spec-authored container visibility toggle')
    else
      unsupported(base, 'dashboard-object.unknown.v1', 'dashboard object has no deterministic lowering rule')
    end
  end

  def compile_bindings(dashboard, zone)
    rows = axis_bindings(zone['rows_shelf'])
    cols = axis_bindings(zone['cols_shelf'])
    values = Array(zone['measures']).map do |measure|
      {
        'column' => WorkbookRuleRegistry.field_name(measure),
        'formula' => WorkbookRuleRegistry.aggregate_formula(measure),
        'derivation' => measure.is_a?(Hash) ? measure['derivation'] : nil
      }.compact
    end
    if values.empty?
      values = Array(zone['calculations']).select { |calc| calc.is_a?(Hash) }.map do |calc|
        name = calc['caption'] || calc['name']
        { 'column' => name, 'formula' => WorkbookRuleRegistry.aggregate_formula('name' => name) }
      end
    end
    filters = Array(zone['filters']).reject { |filter| filter['is_action'] }.map do |filter|
      {
        'column' => filter['column_caption'] || filter['caption'] ||
          filter['column'] || filter['field'] || filter['raw_param'],
        'kind' => filter['kind'] || 'list',
        'mode' => filter['exclude'] ? 'exclude' : 'include',
        'values' => filter['members'] || filter['values']
      }.compact
    end
    {
      'source' => {
        'master_id' => "master-#{slug(dashboard)}",
        'pipeline_root' => nil
      },
      'rows' => rows,
      'columns' => cols,
      'values' => values,
      'filters' => filters,
      'channels' => zone['channels'] || {},
      'metric_eligible' => filters.empty?
    }
  end

  def axis_bindings(shelf)
    fields = shelf.is_a?(Hash) ? Array(shelf['fields']) : []
    fields.map do |field|
      {
        'column' => WorkbookRuleRegistry.field_name(field),
        'formula' => WorkbookRuleRegistry.master_formula(field),
        'role' => field.is_a?(Hash) ? field['role'] : nil,
        'derivation' => field.is_a?(Hash) ? field['derivation'] : nil
      }.compact
    end
  end

  def compile_controls(ir, pages)
    parameters = Array(ir.dig('workbook', 'parameters')).map do |parameter|
      name = parameter['caption'] || parameter['name'] || parameter['id']
      {
        'key' => stable_key('parameter', name),
        'source' => 'parameter',
        'name' => name,
        'status' => 'lowered',
        'target_kind' => control_kind(parameter),
        'rule' => 'control.parameter.v1',
        'current_value' => parameter['current_value'] || parameter['currentValue'],
        'domain' => parameter['values'] || parameter['domain']
      }.compact
    end

    filters = pages.flat_map do |page|
      Array(page['zones']).flat_map do |zone|
        nested = if %w[filter parameter].include?(zone['kind'].to_s)
          Array(zone['filters']).reject { |filter| filter['is_action'] }.map do |filter|
          name = filter['column_caption'] || filter['caption'] ||
            filter['column'] || filter['field'] || filter['raw_param']
          if name.to_s.empty?
            {
              'key' => stable_key('filter', page['name'], zone['id']),
              'source' => 'quick-filter',
              'status' => 'unsupported',
              'rule' => 'control.filter.v1',
              'reason' => 'filter column could not be resolved'
            }
          else
            {
              'key' => stable_key('filter', page['name'], zone['id'], name),
              'source' => 'quick-filter',
              'dashboard' => page['name'],
              'name' => name,
              'status' => 'lowered',
              'target_kind' => filter_control_kind(filter),
              'rule' => 'control.filter.v1',
              'members' => filter['members'] || filter['values'],
              'target_master_id' => "master-#{slug(page['name'])}"
            }
          end
          end
        else
          []
        end
        zone_control =
          if %w[filter parameter].include?(zone['kind'].to_s)
            name = zone['filter_column_caption'] || zone['caption']
            if name.to_s.empty?
              [{
                'key' => stable_key('zone-control', page['name'], zone['id']),
                'source' => zone['kind'] == 'parameter' ? 'parameter' : 'quick-filter',
                'dashboard' => page['name'],
                'status' => 'unsupported',
                'rule' => 'control.zone.v1',
                'reason' => 'control column could not be resolved'
              }]
            else
              [{
                'key' => stable_key('zone-control', page['name'], zone['id'], name),
                'source' => zone['kind'] == 'parameter' ? 'parameter' : 'quick-filter',
                'dashboard' => page['name'],
                'name' => name,
                'status' => 'lowered',
                'target_kind' => control_kind(
                  'datatype' => zone['filter_column_datatype'],
                  'display' => zone['control_display']
                ),
                'rule' => 'control.zone.v1',
                'column_caption' => name,
                'target_master_id' => "master-#{slug(page['name'])}"
              }]
            end
          else
            []
          end
        nested + zone_control
      end
    end
    (parameters + filters)
      .uniq { |entry| [entry['source'], entry['name'], entry['dashboard']] }
      .sort_by { |entry| entry['key'] }
  end

  def compile_formulas(pages)
    records = pages.flat_map do |page|
      Array(page['zones']).flat_map do |zone|
        Array(zone['calculations']).map do |calculation|
          formula = calculation.is_a?(Hash) ? calculation['formula'].to_s : calculation.to_s
          name = calculation.is_a?(Hash) ? (calculation['caption'] || calculation['name']) : nil
          compile_formula(page['name'], zone['id'], name, formula)
        end
      end
    end
    records.uniq { |entry| [entry['name'], entry['formula']] }
           .sort_by { |entry| [entry['name'].to_s, entry['formula'].to_s] }
  end

  def compile_formula(dashboard, zone_id, name, formula)
    base = {
      'key' => stable_key('formula', name, formula),
      'dashboard' => dashboard,
      'zone_id' => zone_id,
      'name' => name,
      'formula' => formula
    }.compact
    return unsupported(base, 'formula.empty.v1', 'calculation has no formula') if formula.strip.empty?
    if formula.match?(/\bIN\s+\[[^\]]+\]/i)
      return unsupported(base, 'formula.set-membership.v1', 'set membership requires a resolved member domain')
    end
    if formula.match?(/\b(?:SCRIPT_|RAWSQL_|MODEL_EXTENSION_)/i)
      return unsupported(base, 'formula.external-runtime.v1', 'external analytics/runtime function cannot be lowered')
    end

    table_functions = TABLE_CALC_RECIPES.keys.select { |function| formula.match?(/\b#{Regexp.escape(function)}\s*\(/i) }
    unless table_functions.empty?
      recipes = table_functions.map { |function| TABLE_CALC_RECIPES.fetch(function).first }.uniq
      return base.merge(
        'status' => 'lowered',
        'rule' => 'formula.table-calc.v1',
        'recipes' => recipes,
        'sigma_formula' => lower_formula(formula)
      )
    end
    if formula.match?(/\{(?:FIXED|INCLUDE|EXCLUDE)\b/i)
      return base.merge(
        'status' => 'verify-required',
        'rule' => 'formula.lod.v1',
        'reason' => 'LOD lowering requires the data-model grain compiler'
      )
    end

    base.merge('status' => 'lowered', 'rule' => 'formula.scalar.v1', 'sigma_formula' => lower_formula(formula))
  end

  def compile_actions(pages)
    actions = pages.flat_map do |page|
      Array(page['zones']).flat_map do |zone|
        filter_actions = Array(zone['filters']).select { |filter| filter['is_action'] }.map do |filter|
          name = filter['caption'] || filter['column'] || filter['raw_param']
          {
            'key' => stable_key('action-filter', page['name'], zone['id'], name),
            'dashboard' => page['name'],
            'zone_id' => zone['id'],
            'source' => name,
            'status' => 'lowered',
            'target_kind' => 'filter-action',
            'rule' => 'action.cross-filter.v1'
          }.compact
        end
        button_action = if zone['kind'] == 'dashboard-object' && zone['button_intent']
                          [compile_dashboard_object(
                            {
                              'key' => stable_key('button-action', page['name'], zone['id']),
                              'dashboard' => page['name'],
                              'zone_id' => zone['id'],
                              'source' => zone['caption']
                            },
                            zone
                          )]
                        else
                          []
                        end
        filter_actions + button_action
      end
    end
    actions.sort_by { |entry| entry['key'] }
  end

  def source_gap(entry)
    severity = entry['severity'].to_s
    {
      'key' => stable_key('source-gap', entry['visual'], entry['detail']),
      'status' => severity == 'approximated' ? 'verify-required' : 'unsupported',
      'rule' => 'source.coverage-gap.v1',
      'source' => entry
    }
  end

  def validate(plan)
    errors = []
    errors << "schemaVersion must be #{SCHEMA_VERSION}" unless plan['schemaVersion'] == SCHEMA_VERSION
    errors << 'kind must be tableau-workbook-compile-plan' unless plan['kind'] == 'tableau-workbook-compile-plan'
    %w[pages visuals controls formulas actions source_gaps blocking].each do |key|
      errors << "#{key} must be an array" unless plan[key].is_a?(Array)
    end
    keys = %w[visuals controls formulas actions].flat_map { |section| Array(plan[section]).map { |entry| entry['key'] } }
    duplicates = keys.compact.tally.select { |_key, count| count > 1 }.keys
    errors << "duplicate compile keys: #{duplicates.join(', ')}" unless duplicates.empty?
    Array(plan['visuals']).each_with_index do |visual, index|
      next unless visual['status'] == 'lowered' && chart_target?(visual['target_kind'])
      bindings = visual['bindings']
      errors << "visuals[#{index}] lowered chart is missing bindings" unless bindings.is_a?(Hash)
      if bindings.is_a?(Hash) &&
         (Array(bindings['rows']) + Array(bindings['columns']) + Array(bindings['values'])).empty?
        errors << "visuals[#{index}] lowered chart has no semantic field bindings"
      end
    end
    errors
  end

  def blocking?(plan)
    Array(plan['blocking']).any?
  end

  def normalized_chart_key(zone)
    key = zone['is_kpi'] ? 'kpi' : (zone['is_crosstab'] ? 'crosstab' : zone['chart_kind'])
    if key.to_s.downcase == 'table' && shelf_has_dimension?(zone['rows_shelf']) &&
       shelf_has_dimension?(zone['cols_shelf']) && Array(zone['measures']).any?
      key = 'crosstab'
    end
    key = MARK_FALLBACKS[zone['mark_class'].to_s.downcase] if key.to_s.empty?
    key.to_s.downcase.tr('_', '-').strip
  end

  def shelf_has_dimension?(shelf)
    Array(shelf.is_a?(Hash) ? shelf['fields'] : nil).any? do |field|
      !field.is_a?(Hash) || %w[dim dimension].include?(field['role'].to_s.downcase)
    end
  end

  def chart_bindings_present?(zone)
    shelves = [zone['rows_shelf'], zone['cols_shelf']].compact.any? do |shelf|
      shelf.is_a?(Hash) ? Array(shelf['fields']).any? : !shelf.to_s.strip.empty?
    end
    shelves ||
      Array(zone['measures']).any? ||
      (zone['channels'].is_a?(Hash) && zone['channels'].any?) ||
      Array(zone['calculations']).any?
  end

  def control_kind(parameter)
    type = (parameter['datatype'] || parameter['dataType'] || parameter['type']).to_s.downcase
    values = parameter['values'] || parameter['domain']
    return 'date-control' if type.match?(/date|time/)
    return 'list-control' if values.is_a?(Array) && !values.empty?
    return 'number-control' if type.match?(/int|real|float|decimal|number/)
    'text-control'
  end

  def filter_control_kind(filter)
    kind = (filter['kind'] || filter['filter_type']).to_s.downcase
    return 'date-range-control' if kind.include?('date')
    return 'number-range-control' if kind.include?('number') || kind.include?('range')
    'list-control'
  end

  def lower_formula(formula)
    result = formula.to_s.dup
    {
      'COUNTD' => 'CountDistinct', 'COUNT' => 'Count', 'SUM' => 'Sum',
      'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max', 'MEDIAN' => 'Median',
      'IIF' => 'If', 'ZN' => 'Zn'
    }.each { |tableau, sigma| result.gsub!(/\b#{tableau}\s*\(/i, "#{sigma}(") }
    TABLE_CALC_RECIPES.each do |tableau, (_rule, sigma)|
      result.gsub!(/\b#{Regexp.escape(tableau)}\s*\(/i, "#{sigma}(")
    end
    result
  end

  def chart_target?(kind)
    %w[
      bar-chart line-chart area-chart pie-chart scatter-chart combo-chart
      waterfall-chart point-map region-map pivot-table table kpi-chart
      box-plot
    ].include?(kind.to_s)
  end

  def slug(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, '-').sub(/\A-/, '').sub(/-\z/, '')[0, 40]
  end

  def unsupported(base, rule, reason)
    base.merge('status' => 'unsupported', 'rule' => rule, 'reason' => reason)
  end

  def stable_key(*parts)
    Digest::SHA256.hexdigest(parts.compact.map(&:to_s).join("\0"))[0, 20]
  end

  def deep_sort(value)
    case value
    when Hash
      value.keys.sort.each_with_object({}) { |key, output| output[key] = deep_sort(value[key]) }
    when Array
      value.map { |item| deep_sort(item) }
    else
      value
    end
  end
end
