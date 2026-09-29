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
#   card-header-overrides.json   operator-authored only; never auto-emitted here
#   chart-axis-overrides.json    compact currency axis display
#   category-order-overrides.json source category order from Domo rows
#   chart-color-overrides.json   suppress unsafe high-cardinality SERIES colors
#
# The existing builders consume these files. Raw-value parity twins remain the
# builder's responsibility, so display scaling never changes the measured value.
# Every sidecar is intentionally a sparse map keyed by card id: a missing id
# means no source-grounded presentation override exists and the builder must use
# its normal defaults. It is never an error and must never abort the migration.
# KPI headers are emitted only when layout-observed.json proves source geometry.
# Chart/table Summary Numbers stay companion KPIs; replacing one with a bespoke
# text header remains an explicit operator opt-in.
#
# Usage:
#   ruby scripts/derive-presentation-overrides.rb --workdir /tmp/run
#   ruby scripts/derive-presentation-overrides.rb --discovery fixture --expected fixture/parity-expected.json

require 'fileutils'
require 'json'
require 'optparse'
require_relative 'lib/domo_sigma_util'
include DomoSigma

def atomic_write_json(path, payload)
  raise ArgumentError, "#{File.basename(path)} payload must be a JSON object" unless payload.is_a?(Hash)
  temporary = "#{path}.tmp-#{Process.pid}-#{payload.object_id}"
  File.open(temporary, 'wb') do |file|
    file.write(JSON.pretty_generate(payload) + "\n")
    file.flush
    begin
      file.fsync
    rescue SystemCallError, IOError
      # Some Windows/network filesystems do not expose fsync. The temp-file +
      # rename boundary still prevents readers from seeing a partial document.
    end
  end
  File.rename(temporary, path)
rescue Errno::EEXIST, Errno::EPERM
  # Windows cannot atomically replace an existing destination. `--force` is
  # explicit, so use the narrow replace fallback there rather than leaving a
  # partially-written destination.
  FileUtils.rm_f(path)
  File.rename(temporary, path)
ensure
  FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
end

def validate_sparse_map!(basename, payload, expected)
  raise ArgumentError, "#{basename} must be a JSON object" unless payload.is_a?(Hash)
  invalid = payload.find { |card_id, rule| card_id.to_s.empty? || !rule.is_a?(expected) }
  return payload unless invalid
  card_id, rule = invalid
  raise ArgumentError, "#{basename}[#{card_id.inspect}] must be #{expected}, got #{rule.class}"
end

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

def full_summary(expression, format)
  type = format_type(format)
  precision = format.to_h.fetch('precision', 1).to_i.clamp(0, 4)
  return "{{#{expression} | $,.#{precision}f}}" if type.match?(/currency|money/)
  return "{{#{expression} | .#{precision}%}}" if type.include?('percent')
  "{{#{expression} | ,.#{precision}f}}"
end

def dateish?(value)
  value.to_s.match?(/\A(?:\d{4}[-\/]\d{1,2}|[A-Z][a-z]{2}\s+\d{2}|Week-\d+\s+\d{4})/)
end

kpi_formats = {}
kpi_headers = {}
card_headers = {}
axis_formats = {}
category_orders = {}
color_guards = {}
warnings = []
observed_layout = File.exist?(File.join(discovery, 'layout-observed.json'))
max_category_colors = Integer(ENV.fetch('DOMO_MAX_CATEGORY_COLORS', '100'), 10) rescue 100

cards.each do |card|
  next if card['_error'] || card['_tierB']
  id = card['id'].to_s
  expected = expected_by_id[id] || {}
  summary = summary_config(card)
  summary_value = expected['summary_value'] || expected['summaryValue']

  if kpi_card?(card)
    rule = { 'fontSize' => observed_layout ? 48 : 64 }
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
      kpi_headers[id] = {
        'body' => "**#{card['title']}**\n\n<p class=\"p-small\">#{full_summary(expression, summary['format'])}\n#{summary['label']}</p>"
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

  # A SERIES mapping becomes Sigma `color.by: category`. Domo can return a
  # numeric aggregate in that slot, or a genuinely high-cardinality dimension;
  # either shape creates one browser-heavy color series per distinct value.
  # The live orchestrator already captured these rows from Domo, so make the
  # performance decision from source facts rather than guessing from names.
  mappings = Array(expected['mappings'])
  series_index = mappings.index { |mapping| mapping.to_s.upcase == 'SERIES' }
  if series_index
    source_columns = Array(expected['columns'])
    source_name = source_columns[series_index].to_s
    source_series = Array(card['columns']).find do |column|
      column['mapping'].to_s.upcase == 'SERIES' &&
        [column['column'], column['alias']].compact.map(&:to_s).include?(source_name)
    end
    # Aggregated SERIES entries are separate measures, not category colors.
    if source_series && source_series['aggregation'].to_s.empty?
      series_values = rows.map { |row| Array(row)[series_index] }.compact.uniq
    end
    if series_values && series_values.size > max_category_colors
      color_guards[id] = {
        'mode' => 'omit',
        'column' => source_name,
        'distinctValuesObserved' => series_values.size,
        'threshold' => max_category_colors,
        'source' => 'domo-card-data',
      }.compact
      warnings << "#{card['title']}: omitted SERIES category color after observing " \
                  "#{series_values.size} distinct values (limit #{max_category_colors})"
    end
  end
end

files = {
  'kpi-format-overrides.json' => [kpi_formats, Hash],
  'chart-axis-overrides.json' => [axis_formats, Hash],
  'category-order-overrides.json' => [category_orders, Array],
  'chart-color-overrides.json' => [color_guards, Hash],
}
files['kpi-card-header-overrides.json'] = [kpi_headers, Hash] if observed_layout

written = []
skipped = []
files.each do |basename, (payload, expected_rule_type)|
  path = File.join(discovery, basename)
  if File.exist?(path) && !opts[:force]
    skipped << basename
    next
  end
  validate_sparse_map!(basename, payload, expected_rule_type)
  atomic_write_json(path, payload)
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
    'card_headers' => card_headers.size,
    'axis_formats' => axis_formats.size,
    'category_orders' => category_orders.size,
    'color_guards' => color_guards.size
  },
  'written' => written,
  'preserved_existing' => skipped,
  'warnings' => warnings
}
atomic_write_json(File.join(discovery, 'presentation-overrides.json'), manifest)

warn "derive-presentation-overrides: #{cards.size} cards; wrote #{written.join(', ')}"
warn "  preserved existing: #{skipped.join(', ')}" unless skipped.empty?
warn "  expected values: #{expected_path || '(not available — metadata-only defaults)'}"
