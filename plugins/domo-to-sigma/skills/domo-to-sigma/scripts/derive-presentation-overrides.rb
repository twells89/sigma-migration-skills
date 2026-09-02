#!/usr/bin/env ruby
# derive-presentation-overrides.rb — source facts -> optional workbook styling
#
# The live gold run proved that Domo's source intent is recoverable, but the
# first pass reached it through hand-authored sidecars. This script makes those
# decisions reproducible for every run. It reads only discovery metadata and,
# when available, an EARLY Domo card-data snapshot (`parity-expected.json`):
#
#   kpi-format-overrides.json    Domo-style compact KPI display + font size
#   kpi-card-header-overrides.json screenshot-backed KPI title/subtitle blocks
#   chart-axis-overrides.json    compact currency axis display
#   category-order-overrides.json source category order from Domo rows
#
# The existing builders consume these files. Raw-value parity twins remain the
# builder's responsibility, so display scaling never changes the measured value.
# Chart card-header overrides remain hand-authored. KPI card headers are emitted
# only when layout-observed.json proves the source card geometry; the observed
# layout path nests each header with its KPI so no element is left unplaced.
#
# Usage:
#   ruby scripts/derive-presentation-overrides.rb --workdir /tmp/run
#   ruby scripts/derive-presentation-overrides.rb --discovery fixture --expected fixture/parity-expected.json

require 'fileutils'
require 'json'
require 'optparse'
require_relative 'lib/domo_sigma_util'
include DomoSigma

opts = {}
OptionParser.new do |o|
  o.on('--workdir DIR', 'run dir (default source for discovery/ and parity-expected.json)') { |v| opts[:workdir] = v }
  o.on('--discovery DIR', 'discovery directory (default <workdir>/discovery or DOMO_DISCOVERY_DIR)') { |v| opts[:discovery] = v }
  o.on('--expected PATH', 'Domo expected-value snapshot (optional)') { |v| opts[:expected] = v }
  o.on('--force', 'overwrite existing generated sidecars') { opts[:force] = true }
end.parse!(ARGV)

workdir = File.expand_path(opts[:workdir] || File.dirname(ENV['DOMO_DISCOVERY_DIR'].to_s))
discovery = File.expand_path(opts[:discovery] || ENV['DOMO_DISCOVERY_DIR'].to_s)
discovery = File.join(workdir, 'discovery') if discovery.empty?
cards_path = File.join(discovery, 'cards.json')
abort("missing #{cards_path}") unless File.exist?(cards_path)
FileUtils.mkdir_p(discovery)

expected_candidates = [
  opts[:expected],
  File.join(workdir, 'parity-expected.json'),
  File.join(discovery, 'parity-expected.json')
].compact
expected_path = expected_candidates.find { |path| File.exist?(path) }

cards = JSON.parse(File.read(cards_path))
expected_doc = expected_path ? (JSON.parse(File.read(expected_path)) rescue {}) : {}
raw_expected = expected_doc['cards'] || {}
expected_by_id =
  if raw_expected.is_a?(Hash)
    raw_expected.transform_keys(&:to_s)
  else
    Array(raw_expected).each_with_object({}) do |entry, out|
      out[(entry['card_id'] || entry['cardId'] || entry['id']).to_s] = entry
    end
  end

AGGREGATIONS = {
  'SUM' => 'Sum', 'AVG' => 'Avg', 'AVERAGE' => 'Avg',
  'COUNT' => 'Count', 'COUNT_DISTINCT' => 'CountDistinct',
  'COUNTDISTINCT' => 'CountDistinct', 'MIN' => 'Min', 'MAX' => 'Max'
}.freeze

# Human-friendly label for a header subtitle. Prefers the Domo-authored
# summary label or column alias (what the source tile actually printed); falls
# back to the canonical display_name so the text still reads cleanly.
def friendly_label(summary_label, alias_name, column)
  return summary_label if summary_label.to_s.strip != ''
  return alias_name if alias_name.to_s.strip != ''
  display_name(column)
end

def kpi_card?(card)
  card['sigmaKindHint'].to_s == 'kpi-chart' ||
    (card['summaryNumber'] && Array(card['groupBy']).empty? && Array(card['columns']).size <= 1)
end

# Coarse kind for deciding which styling a card can carry. A numeric-axis
# (cartesian) chart can take a compact value axis; only a categorical-axis
# chart (bar/pie/donut) can carry a fixed category order. Tables and KPIs have
# neither, so neither override applies to them.
def coarse_kind(card)
  hint = card['sigmaKindHint'].to_s
  return hint unless hint.empty?
  type = card['chartType'].to_s.downcase
  return 'table' if type.include?('table') || type.include?('datagrid')
  return 'kpi-chart' if type.include?('singlevalue') || type.include?('summary')
  return 'donut-chart' if type.include?('donut') || type.include?('pie')
  return 'line-chart' if type.include?('line')
  return 'scatter-chart' if type.include?('scatter') || type.include?('bubble')
  'bar-chart'
end

VALUE_AXIS_KINDS = %w[bar-chart line-chart area-chart combo-chart scatter-chart].freeze
CATEGORY_AXIS_KINDS = %w[bar-chart pie-chart donut-chart combo-chart].freeze

def summary_config(card)
  summary = card['summaryNumber']
  return nil unless summary.is_a?(Hash)
  column = summary['column'].to_s
  return nil if column.empty? || summary['_isCalc']
  aggregation = summary['aggregation'].to_s.upcase
  return nil unless AGGREGATIONS[aggregation]
  source_column = Array(card['columns']).find { |item| item['column'].to_s == column }
  {
    'column' => column,
    # The [Master/<ref>] name build-workbook.rb emits (case-insensitive in
    # Sigma, but exact here for clarity/regression stability).
    'ref' => display_name(column),
    # The human label the source tile printed.
    'label' => friendly_label(summary['label'], source_column && source_column['alias'], column),
    'aggregation' => aggregation,
    'format' => summary['format'].is_a?(Hash) ? summary['format'] :
      (source_column && source_column['format'].is_a?(Hash) ? source_column['format'] : {})
  }
end

def compact_parts(value)
  return nil unless value.is_a?(Numeric)
  magnitude = value.abs
  return [1_000_000_000.0, 'B'] if magnitude >= 1_000_000_000
  return [1_000_000.0, 'M'] if magnitude >= 1_000_000
  return [1_000.0, 'K'] if magnitude >= 1_000
  nil
end

def format_type(format)
  format.to_h['type'].to_s.downcase
end

def dynamic_summary(expression, format, value)
  type = format_type(format)
  precision = format.to_h.fetch('precision', 1).to_i.clamp(0, 4)
  compact = compact_parts(value)
  if type.match?(/currency|money/)
    return "{{#{expression} / #{compact[0].to_i} | $,.#{precision}f}}#{compact[1]}" if compact
    return "{{#{expression} | $,.#{precision}f}}"
  end
  return "{{#{expression} | .#{precision}%}}" if type.include?('percent')
  "{{#{expression} | ,.#{precision}f}}"
end

def dateish?(value)
  value.to_s.match?(/\A(?:\d{4}[-\/]\d{1,2}|[A-Z][a-z]{2}\s+\d{2}|Week-\d+\s+\d{4})/)
end

kpi_formats = {}
kpi_headers = {}
axis_formats = {}
category_orders = {}
warnings = []
observed_layout = File.exist?(File.join(discovery, 'layout-observed.json'))

cards.each do |card|
  next if card['_error'] || card['_tierB']
  id = card['id'].to_s
  expected = expected_by_id[id] || {}
  summary = summary_config(card)
  summary_value = expected['summary_value'] || expected['summaryValue']

  if kpi_card?(card)
    rule = { 'fontSize' => 64 }
    if summary && format_type(summary['format']).match?(/currency|money/) && (compact = compact_parts(summary_value))
      rule.merge!(
        'scale' => compact[0].to_i, 'suffix' => compact[1],
        'decimals' => summary['format'].fetch('precision', 1).to_i.clamp(0, 4),
        'prefix' => '$'
      )
    end
    kpi_formats[id] = rule
    if observed_layout && summary
      aggregate = AGGREGATIONS.fetch(summary['aggregation'])
      expression = "#{aggregate}([Master/#{summary['ref']}])"
      precision = summary['format'].to_h.fetch('precision', 1).to_i.clamp(0, 4)
      formatted =
        case format_type(summary['format'])
        when /currency|money/ then "{{#{expression} | $,.#{precision}f}}"
        when /percent/ then "{{#{expression} | .#{precision}%}}"
        else "{{#{expression} | ,.#{precision}f}}"
        end
      kpi_headers[id] = {
        'body' => "**#{card['title']}**\n\n<p class=\"p-small\">#{formatted}\n#{summary['label']}</p>"
      }
    end
    next
  end

  # A chart/table Summary Number becomes a companion KPI in Sigma. Keep that
  # value at full source precision inside the card header instead of allowing
  # Sigma's narrow-KPI default to abbreviate it with a lowercase "k".
  if summary && format_type(summary['format']).match?(/currency|money/)
    kpi_formats[id] = {
      'scale' => 1,
      'suffix' => '',
      'decimals' => summary['format'].fetch('precision', 1).to_i.clamp(0, 4),
      'prefix' => '$'
    }
  end

  # NOTE: a card's source Summary Number is surfaced automatically by the
  # EXISTING companion-KPI mechanism (build-workbook.rb emits an `-summary`
  # kpi-chart beside the chart, and build-domo-layout.rb already synthesizes a
  # zone for it). We deliberately do NOT auto-emit card-header-overrides.json
  # here: that override swaps the companion for a bespoke text header, which
  # adds `header-*` elements the automated layout builder has no zone for
  # (it would leave them unplaced and fail put-layout's exhaustiveness check).
  # The companion already delivers the "number above the chart"; the combined
  # header line stays an operator opt-in, authored by hand when desired.

  kind = coarse_kind(card)
  rows = Array(expected['rows'])
  numeric_values = rows.flat_map { |row| Array(row).drop(1) }.select { |value| value.is_a?(Numeric) }
  currency_measure = Array(card['columns']).find do |column|
    column['aggregation'] && format_type(column['format']).match?(/currency|money/)
  end
  if VALUE_AXIS_KINDS.include?(kind) && currency_measure && numeric_values.any? &&
     (compact = compact_parts(numeric_values.map(&:abs).max))
    axis_formats[id] = {
      'scale' => compact[0].to_i, 'prefix' => '$', 'suffix' => compact[1], 'decimals' => 0
    }
  end

  first_column = Array(card['columns']).find { |column| column['aggregation'].to_s.empty? }
  first_values = rows.map { |row| Array(row).first }.compact
  unique_values = first_values.each_with_object([]) { |value, out| out << value unless out.include?(value) }
  time_axis = first_column && (first_column['calendar'] || card['dateGrain'].is_a?(Hash))
  if CATEGORY_AXIS_KINDS.include?(kind) && first_column && !time_axis &&
     unique_values.size.between?(2, 20) && unique_values.none? { |value| dateish?(value) }
    category_orders[id] = unique_values
  end
end

files = {
  'kpi-format-overrides.json' => kpi_formats,
  'chart-axis-overrides.json' => axis_formats,
  'category-order-overrides.json' => category_orders
}
files['kpi-card-header-overrides.json'] = kpi_headers if observed_layout

written = []
skipped = []
files.each do |basename, payload|
  path = File.join(discovery, basename)
  if File.exist?(path) && !opts[:force]
    skipped << basename
    next
  end
  File.write(path, JSON.pretty_generate(payload) + "\n")
  written << basename
end

manifest = {
  'schema' => 'domo-presentation-overrides/v1',
  'source' => {
    'cards' => File.basename(cards_path),
    'expected' => expected_path && File.expand_path(expected_path)
  },
  'counts' => {
    'cards' => cards.size,
    'kpi_formats' => kpi_formats.size,
    'kpi_headers' => kpi_headers.size,
    'axis_formats' => axis_formats.size,
    'category_orders' => category_orders.size
  },
  'written' => written,
  'preserved_existing' => skipped,
  'warnings' => warnings
}
File.write(File.join(discovery, 'presentation-overrides.json'), JSON.pretty_generate(manifest) + "\n")

warn "derive-presentation-overrides: #{cards.size} cards; wrote #{written.join(', ')}"
warn "  preserved existing: #{skipped.join(', ')}" unless skipped.empty?
warn "  expected values: #{expected_path || '(not available — metadata-only defaults)'}"
