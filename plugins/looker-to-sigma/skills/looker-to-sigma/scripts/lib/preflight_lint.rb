#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Preflight lint for a workbook spec — catches the two EDNA-class failure modes
# BEFORE POST, with a precise message instead of the opaque "Invalid kind: control"
# or a silently-detail-rendered table.
#
#   ruby preflight_lint.rb <workbook-spec.json>
#     exit 0  = clean
#     exit 1  = violations (printed, one per line)
#
# Checks:
#   T1  a `table` with aggregate column(s) + dimension(s) but NO `groupings`
#       → renders raw detail rows (the 9.6M-row / $0 / duplicate-dim EDNA bug).
#   T2  a `groupings.calculations` column that is a PASSTHROUGH of an aggregate
#       (re-aggregates to "multiple values"); calc cols must be Sum(...)/etc.
#   C1  a `control` missing id / controlId / controlType.
#   C2  any control nesting its value fields under a bogus `value` OBJECT
#       (control fields are FLAT top-level) → the opaque `Invalid kind: control`.
#       NOTE: a scalar `value:` is legitimate (slider handle position); only an
#       OBJECT value is the trap. Also: a `source`, if present, must be double-nested.
#   C3  a list/segmented/hierarchy control wired to NOTHING — neither a `source`
#       (value-list) nor `filters` (target columns). A filters-only list control
#       is VALID (live-verified), so source is NOT independently required.
require 'json'

AGG = /\A\s*(Sum|Avg|Count|CountDistinct|CountIf|SumIf|Min|Max|Median|Percentile|StdDev|Variance|VariancePop|GrandTotal)\s*\(/i
PLAIN_REF = /\A\s*\[[^\]]+\]\s*\z/   # a bare column reference, e.g. [Table/Region]
LISTY = %w[list segmented hierarchy].freeze

def lint(spec)
  errs = []
  cols_by_id = {}
  pages = spec['pages'] || []
  pages.each do |pg|
    (pg['elements'] || []).each do |el|
      (el['columns'] || []).each { |c| cols_by_id[c['id']] = c }
    end
  end
  pages.each do |pg|
    (pg['elements'] || []).each do |el|
      kind = el['kind']
      name = el['name'] || el['id'] || '(unnamed)'
      cols = el['columns'] || []

      if kind == 'table'
        agg = cols.select { |c| c['formula'].to_s =~ AGG }
        dim = cols.select { |c| c['formula'].to_s =~ PLAIN_REF }
        grouped = el['groupings'].is_a?(Array) && !el['groupings'].empty?
        if agg.any? && dim.any? && !grouped
          errs << "T1 table '#{name}': has aggregate column(s) #{agg.map { |c| c['name'] }.inspect} + dimension(s) but NO `groupings` → will render raw detail rows, not an aggregated summary. Add groupings:[{groupBy:[<dim id>], calculations:[<agg id>...]}]."
        end
        # T2: a grouping calculation that points at a passthrough-of-aggregate column
        (el['groupings'] || []).each do |g|
          (g['calculations'] || []).each do |cid|
            f = (cols_by_id[cid] || {})['formula'].to_s
            # a calc that is a plain ref to another column whose own formula is an aggregate
            if f =~ PLAIN_REF
              # can't always resolve cross-element; flag bare passthroughs that look like measures
              errs << "T2 table '#{name}': grouping calculation '#{cid}' is a passthrough (`#{f}`) — a grouped calculation must be an aggregate expression (Sum([...]) etc.), not a passthrough of an already-aggregated column (renders 'multiple values')." if cols_by_id[cid] && (cols_by_id[cid]['name'].to_s =~ /total|sum|count|avg|revenue|profit|tcv|amount/i)
            end
          end
        end
      end

      if kind == 'control'
        %w[id controlId controlType].each do |f|
          errs << "C1 control '#{name}': missing required field `#{f}`." if el[f].to_s.empty?
        end
        errs << "C1 control '#{name}': `id` and `controlId` must be DISTINCT." if !el['id'].to_s.empty? && el['id'] == el['controlId']

        # C2: control value fields are FLAT top-level — never nested under a `value` OBJECT.
        # (Live-verified: a nested value:{...} yields the opaque "Invalid kind: control" for
        #  list / date-range / number-range / slider alike.) A SCALAR value: is legitimate
        #  (the slider handle position), so only flag `value` when it is a Hash.
        errs << "C2 control '#{name}': value fields nested under a `value` object — control fields must be FLAT top-level (list: mode/selectionMode/values; ranges: low/high; slider: low/high/mode/<scalar value>)." if el['value'].is_a?(Hash)

        # `source`, if present, must be double-nested ({kind:source, source:{kind:table,elementId}, columnId}).
        if el['source'].is_a?(Hash) && !el['source']['source'].is_a?(Hash)
          errs << "C2 control '#{name}': `source` present but not double-nested — needs {kind:source, source:{kind:table,elementId}, columnId}."
        end

        # C3: a list-type control must be wired to SOMETHING — a `source` (value-list) and/or
        # `filters` (target columns). A filters-only list control is VALID (live-verified), so we
        # require source OR filters, never both, and never the bare mode/selectionMode/values.
        if LISTY.include?(el['controlType'])
          has_source  = el['source'].is_a?(Hash)
          has_filters = el['filters'].is_a?(Array) && !el['filters'].empty?
          unless has_source || has_filters
            errs << "C3 control '#{name}': list-type control has neither `source` (value-list) nor `filters` (target columns) — it controls nothing. Add filters:[{source:{kind:table,elementId}, columnId}] and/or a double-nested source."
          end
        end
      end
    end
  end
  errs
end

if __FILE__ == $PROGRAM_NAME
  path = ARGV[0] or abort('usage: preflight_lint.rb <workbook-spec.json>')
  spec = JSON.parse(File.read(path))
  errs = lint(spec)
  if errs.empty?
    puts 'preflight lint: clean'
    exit 0
  end
  warn "preflight lint: #{errs.size} violation(s)"
  errs.each { |e| warn "  ✗ #{e}" }
  exit 1
end
