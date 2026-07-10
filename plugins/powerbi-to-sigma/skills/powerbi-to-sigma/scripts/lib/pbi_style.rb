# frozen_string_literal: true

# pbi_style.rb — style-fidelity transforms shared by build-workbook-from-pbir.rb
# and its tests. Pure functions over the Sigma element hash + the PBI `rec`
# signals; NO API, NO creds. Tested by scripts/test-pbi-style.rb.
#
# Three transforms live here (see refs/style-fidelity.md §5-7):
#   1. Number abbreviation — PBI cards/charts default to display-units "Auto"
#      (compact "$126K"); Sigma defaults to full ("$125,916"). We emit d3
#      compact `s` notation on KPI/chart MEASURE columns so the migrated look
#      matches. Tables keep full precision (PBI tables do too).
#   2. KPI card alignment — PBI stat cards center their callout; we center by
#      default via layout.anchor (overridable from a PBI alignment signal).
#   3. Table presentation preset — PBI matrices/tableEx read as roomy
#      "presentation" tables, not the dense spreadsheet grid Sigma defaults to.
module PbiStyle
  # A roomier, lighter table look that matches how source BI tools render
  # dashboard tables (verified round-trips + renders live 2026-06-24).
  PRESENTATION_TABLE_STYLE = {
    'preset'      => 'presentation',
    'cellSpacing' => 'medium',
    'gridLines'   => 'horizontal',
    'banding'     => 'shown'
  }.freeze

  KPI_KIND    = 'kpi-chart'
  CHART_KINDS = %w[kpi-chart bar-chart line-chart area-chart combo-chart donut-chart pie-chart].freeze
  TABLE_KINDS = %w[table pivot-table].freeze

  # d3 `s` precision: KPIs carry one big value → 3 sig figs keeps 6-digit values
  # honest ($125,916 → $126k, not $130k); chart data labels are denser → 2.
  KPI_PRECISION   = 3
  CHART_PRECISION = 2

  module_function

  # PBI serializes labelDisplayUnits only when NON-default. Absent (nil) = the
  # PBI default "Auto", which abbreviates. Explicit "none" = full precision.
  # Everything else (auto/thousands/millions/…) abbreviates.
  def abbreviates?(display_units)
    display_units.to_s.strip.downcase != 'none'
  end

  # PBI card callout alignment → Sigma kpi-chart layout.anchor.
  # Default (no signal) = 'middle': stat cards read best centered, and it's the
  # requested house default for PBI migrations. An explicit PBI alignment wins.
  def kpi_anchor(value_align = nil)
    case value_align.to_s.strip.downcase
    when 'left'  then 'start'
    when 'right' then 'end'
    when 'center', 'middle' then 'middle'
    else 'middle'
    end
  end

  # The measure (value) column ids of a built element, by binding — the columns
  # whose numbers should abbreviate. Dimensions are never abbreviated.
  def measure_col_ids(el)
    ids = []
    ids << el.dig('value', 'columnId') if el.dig('value', 'columnId') # kpi-chart
    ids << el.dig('value', 'id')       if el.dig('value', 'id')       # pie/donut
    Array(el.dig('yAxis', 'columnIds')).each do |y|                   # bar/line/area/combo
      ids << (y.is_a?(Hash) ? y['columnId'] : y)
    end
    ids.compact.uniq
  end

  # Rewrite a measure column's format to compact `s` notation, preserving a `$`
  # currency prefix. Skips percents (never abbreviate a ratio). Returns the new
  # format hash, or nil to leave the column untouched.
  #   existing "$,.0f"  + currency → "$,.<p>s"
  #   existing ",.0f"   (plain)    → ",.<p>s"
  #   no format, currency sibling  → "$,.<p>s"
  #   no format, no currency clue  → nil  (can't classify — e.g. a bare ratio)
  def compact_format(existing, precision, currency_sibling)
    fs = existing.is_a?(Hash) ? existing['formatString'].to_s : ''
    return nil if fs.include?('%')                       # percent — leave alone
    if fs.start_with?('$')
      { 'kind' => 'number', 'formatString' => "$,.#{precision}s" }
    elsif !fs.empty?
      { 'kind' => 'number', 'formatString' => ",.#{precision}s" }
    elsif currency_sibling
      { 'kind' => 'number', 'formatString' => "$,.#{precision}s" }
    end
  end

  # Abbreviate every measure column of a KPI/chart element in place.
  # No-op unless the element is a KPI/chart and PBI's display units abbreviate.
  def abbreviate_measures!(el, display_units, kind = nil)
    kind ||= el['kind']
    return el unless CHART_KINDS.include?(kind)
    return el unless abbreviates?(display_units)

    precision = kind == KPI_KIND ? KPI_PRECISION : CHART_PRECISION
    ids  = measure_col_ids(el)
    cols = el['columns'] || []
    # If any measure column is currency, treat the whole element as currency so
    # an unformatted sibling (e.g. a "Prior Year" column) picks up the `$` too.
    currency_sibling = ids.any? do |cid|
      c = cols.find { |x| x['id'] == cid }
      c && c['format'].is_a?(Hash) && c.dig('format', 'formatString').to_s.start_with?('$')
    end
    ids.each do |cid|
      col = cols.find { |x| x['id'] == cid }
      next unless col
      f = compact_format(col['format'], precision, currency_sibling)
      col['format'] = f if f
    end
    el
  end

  # Add the presentation table style to a table/pivot-table (does not clobber an
  # already-set tableStyle).
  def presentation_table!(el, kind = nil)
    kind ||= el['kind']
    return el unless TABLE_KINDS.include?(kind)
    el['tableStyle'] ||= PRESENTATION_TABLE_STYLE.dup
    el
  end
end
