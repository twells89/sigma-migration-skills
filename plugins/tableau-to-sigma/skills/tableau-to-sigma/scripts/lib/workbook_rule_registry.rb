# frozen_string_literal: true

# Single lowering vocabulary shared by the semantic compiler and the legacy
# signal builder. A rule change can no longer make the plan promise one Sigma
# kind while the builder emits another.
module WorkbookRuleRegistry
  CHART_RULES = {
    'bar' => ['bar-chart', 'viz.bar.v1'],
    'bar-chart' => ['bar-chart', 'viz.bar.v1'],
    'line' => ['line-chart', 'viz.line.v1'],
    'line-chart' => ['line-chart', 'viz.line.v1'],
    'area' => ['area-chart', 'viz.area.v1'],
    'area-chart' => ['area-chart', 'viz.area.v1'],
    'pie' => ['pie-chart', 'viz.pie.v1'],
    'donut' => ['pie-chart', 'viz.donut.v1'],
    'scatter' => ['scatter-chart', 'viz.scatter.v1'],
    'scatter-plot' => ['scatter-chart', 'viz.scatter.v1'],
    'combo' => ['combo-chart', 'viz.combo.v1'],
    'waterfall' => ['waterfall-chart', 'viz.waterfall.v1'],
    'map' => ['point-map', 'viz.map.v1'],
    'symbol-map' => ['point-map', 'viz.map.v1'],
    'map-point' => ['point-map', 'viz.map.v1'],
    'filled-map' => ['region-map', 'viz.map-filled.v1'],
    'map-region' => ['region-map', 'viz.map-filled.v1'],
    'table' => ['table', 'viz.table.v1'],
    'table-or-text' => ['table', 'viz.table.v1'],
    'crosstab' => ['pivot-table', 'viz.pivot.v1'],
    'pivot' => ['pivot-table', 'viz.pivot.v1'],
    'pivot-table' => ['pivot-table', 'viz.pivot.v1'],
    'kpi' => ['kpi-chart', 'viz.kpi.v1'],
    'kpi-chart' => ['kpi-chart', 'viz.kpi.v1'],
    'trellis' => ['bar-chart', 'viz.trellis.v1'],
    'box-plot' => ['box-plot', 'viz.box.v1'],
    'histogram' => ['bar-chart', 'viz.histogram.v1'],
    'gantt' => ['bar-chart', 'viz.gantt.v1'],
    'automatic' => ['bar-chart', 'viz.automatic.v1'],
    'other' => ['bar-chart', 'viz.other.v1']
  }.freeze

  MARK_FALLBACKS = {
    'bar' => 'bar',
    'line' => 'line',
    'area' => 'area',
    'pie' => 'pie',
    'circle' => 'scatter',
    'square' => 'scatter',
    'polygon' => 'filled-map',
    'map' => 'map',
    'text' => 'table'
  }.freeze

  TABLE_CALC_RECIPES = {
    'RUNNING_SUM' => ['formula.running-sum.v1', 'CumulativeSum'],
    'RUNNING_AVG' => ['formula.running-avg.v1', 'CumulativeAvg'],
    'RUNNING_MIN' => ['formula.running-min.v1', 'CumulativeMin'],
    'RUNNING_MAX' => ['formula.running-max.v1', 'CumulativeMax'],
    'WINDOW_SUM' => ['formula.window-sum.v1', 'WindowSum'],
    'WINDOW_AVG' => ['formula.window-avg.v1', 'MovingAvg'],
    'WINDOW_MIN' => ['formula.window-min.v1', 'WindowMin'],
    'WINDOW_MAX' => ['formula.window-max.v1', 'WindowMax'],
    'RANK' => ['formula.rank.v1', 'Rank'],
    'RANK_DENSE' => ['formula.rank-dense.v1', 'DenseRank'],
    'RANK_UNIQUE' => ['formula.row-number.v1', 'RowNumber'],
    'LOOKUP' => ['formula.lookup.v1', 'Lag'],
    'INDEX' => ['formula.index.v1', 'RowNumber'],
    'FIRST' => ['formula.first.v1', 'FirstValue'],
    'LAST' => ['formula.last.v1', 'LastValue'],
    'TOTAL' => ['formula.partition-total.v1', 'WindowSum'],
    'SIZE' => ['formula.partition-size.v1', 'WindowCount']
  }.freeze

  module_function

  def target_for(key)
    CHART_RULES[key.to_s.downcase.tr('_', '-').strip]
  end

  def sigma_kind_map
    CHART_RULES.each_with_object({}) { |(key, (kind, _rule)), out| out[key] = kind }.freeze
  end

  def chart_key_for_target(target)
    {
      'bar-chart' => 'bar', 'line-chart' => 'line', 'area-chart' => 'area',
      'pie-chart' => 'pie', 'scatter-chart' => 'scatter',
      'combo-chart' => 'combo', 'waterfall-chart' => 'waterfall',
      'point-map' => 'map-point', 'region-map' => 'map-region',
      'pivot-table' => 'pivot-table', 'table' => 'table',
      'kpi-chart' => 'kpi', 'box-plot' => 'box-plot'
    }[target.to_s]
  end

  def field_name(field)
    return field.to_s unless field.is_a?(Hash)
    field['caption'] || field['column_caption'] || field['name'] ||
      field['guid'] || field['column'] || field['raw']
  end

  def master_formula(field)
    name = field_name(field).to_s.gsub(/\A\[|\]\z/, '')
    "[Master/#{name}]"
  end

  def aggregate_formula(field)
    name = field_name(field).to_s.gsub(/\A\[|\]\z/, '')
    derivation = field.is_a?(Hash) ? (field['derivation'] || field['aggregation']) : nil
    function = {
      'avg' => 'Avg', 'average' => 'Avg', 'count' => 'Count',
      'cnt' => 'Count', 'countd' => 'CountDistinct', 'min' => 'Min',
      'max' => 'Max', 'median' => 'Median'
    }[derivation.to_s.downcase] || 'Sum'
    "#{function}([Master/#{name}])"
  end
end
