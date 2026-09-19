# frozen_string_literal: true
# Omni visConfig.chartType → Sigma element kind.
# Grounded in exploreomni/omni-agent-skills omni-content-builder visConfig.md.
# Unknown / custom Vega / markdown tiles return nil so the workbook builder
# can skip them and record a gap instead of guessing a chart.

module OmniChartMap
  KIND = {
    'line' => 'line-chart',
    'lineColor' => 'line-chart',
    'area' => 'area-chart',
    'bar' => 'bar-chart',
    'column' => 'bar-chart',
    'columnStacked' => 'bar-chart',
    'columnPercent' => 'bar-chart',
    'barStacked' => 'bar-chart',
    'barPercent' => 'bar-chart',
    'barLine' => 'combo-chart',
    'scatter' => 'scatter-chart',
    'point' => 'scatter-chart',
    'pointSize' => 'scatter-chart',
    'pointSizeColor' => 'scatter-chart',
    'pie' => 'pie-chart',
    'kpi' => 'kpi-chart',
    'table' => 'table',
    'heatmap' => 'heatmap-chart',
    'funnel' => 'funnel-chart',
    'sankey' => 'sankey-chart',
    'map' => 'point-map',
    'regionMap' => 'region-map',
    'boxplot' => 'box-chart'
  }.freeze

  SKIP = %w[markdown omni-ai-summary-markdown singleRecord].freeze

  module_function

  def kind_for(chart_type)
    return nil if chart_type.nil? || chart_type.to_s.empty?
    return nil if SKIP.include?(chart_type.to_s)
    KIND[chart_type.to_s]
  end

  def known?(chart_type)
    !kind_for(chart_type).nil?
  end
end
