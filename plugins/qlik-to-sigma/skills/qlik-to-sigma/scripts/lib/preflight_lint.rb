#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Preflight lint for a workbook spec — catches the two enterprise-class failure modes
# BEFORE POST, with a precise message instead of the opaque "Invalid kind: control"
# or a silently-detail-rendered table.
#
#   ruby preflight_lint.rb <workbook-spec.json>
#     exit 0  = clean
#     exit 1  = violations (printed, one per line)
#
# Checks:
#   T1  a `table` with aggregate column(s) + dimension(s) but NO `groupings`
#       → renders raw detail rows (the 9.6M-row / $0 / duplicate-dim enterprise bug).
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
#   K1  a kpi-chart whose `value.columnId` column's formula is a BARE reference
#       to a sibling column ([X] with no function call) — compiles clean but
#       renders NULL (live: the call-center WoW badges). Inline the aggregate.
#   S1  `style.backgroundColor` on a kpi-chart or bar-chart — blanks the tile in
#       PNG export and garbles thousands separators (live: call-center KPIs,
#       supermart mini bars). Use container styling instead.
#   C5  a control with selectionMode:"single" carrying `values` (array) instead
#       of scalar `value` — the filter AND the default silently drop.
#   C6  a control with an unknown controlType, or the docs-only `top-n` type that
#       the live tenant 400s — mirrors Sigma spec/verify offline (canary 2026-07-11).
#   C7  a control missing a REQUIRED field for its type: `mode` on
#       switch/checkbox/text/number/date/slider; `low`/`high` on range-slider;
#       flat `min`/`max` on number-range (unbounded → 400).
#   C8  `includeNulls` on a controlType where it is off-schema.
#   N1  an element or column whose `name` is empty/whitespace-only — breaks
#       parity header matching and blank-renders axes (title hiding belongs on
#       the element, not the name).
#
# WARN-level (printed, never fail the lint — `lint_warnings(spec)`):
#   P1  a `conditionalFormats` entry with includeValues:false — silently
#       disables the format (live-verified: visual-vocabulary waffle).
#   I1  heuristic: If() whose FIRST argument is a bare column ref with no
#       comparison operator — integer/bit predicates fail at render with
#       "Invalid Query"; suggest an explicit `= 1` comparison.
require 'json'

AGG = /\A\s*(Sum|Avg|Count|CountDistinct|CountIf|SumIf|Min|Max|Median|Percentile|StdDev|Variance|VariancePop|GrandTotal)\s*\(/i
PLAIN_REF = /\A\s*\[[^\]]+\]\s*\z/   # a bare column reference, e.g. [Table/Region]
LISTY = %w[list segmented hierarchy].freeze
# C6/C7/C8: controlType shape rules — mirror Sigma's server-side spec/verify
# OFFLINE, so the control-grammar 400s (each of which otherwise costs a full
# orchestrator round-trip to discover) are caught pre-POST. Canary-verified
# server-side 2026-07-11 (see refs/composition-recipe.md).
CONTROL_TYPES = %w[checkbox switch text text-area number number-range date date-range
                   list segmented hierarchy slider range-slider].freeze
# controlTypes that REQUIRE a `mode` operator — absent/empty → Sigma 400s the spec.
MODE_REQUIRED = %w[switch checkbox text number date slider].freeze
MODE_HINT = {
  'switch' => "'True/False' | 'True/All'", 'checkbox' => "'True/False' | 'True/All'",
  'text' => "an operator, e.g. 'equals'", 'number' => "'=' | '>=' | '<='",
  'date' => "'=' | '>=' | '<='", 'slider' => "'=' | '>=' | '<='"
}.freeze
# `includeNulls` is schema-valid ONLY on these types (stray elsewhere = off-schema).
INCLUDE_NULLS_OK = %w[text number number-range date date-range slider range-slider].freeze
# I1: If( whose first argument is a bare [ref] immediately followed by `,` or
# `)` — i.e. no comparison operator. `If([x] = 1, ...)` does NOT match.
# v5.4: If( ONLY — Sigma's Switch(expr, case1, val1, …, default) is MATCH-form,
# so a bare [col] first argument is the matched SUBJECT, fully legitimate (the
# builder's own SORT_ORD ordering columns are exactly this shape and I1
# flagged them as false positives twice in the field).
BARE_PREDICATE = /\b(If)\s*\(\s*(\[[^\]]+\])\s*[,)]/i

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

      # N1: whitespace-only names (element + columns). A " " name "hides" the
      # title but breaks verify-warehouse/parity header matching, blank-renders
      # axes, and collapses parity keys. Hide titles on the ELEMENT instead.
      if el.key?('name') && el['name'].to_s.strip.empty?
        errs << "N1 element '#{el['id'] || '(no id)'}' (#{kind}): `name` is empty/whitespace-only — whitespace names break parity header matching and blank axis renders — use a real name (title hiding belongs on the element, not the name)."
      end
      cols.each do |c|
        next unless c.key?('name') && c['name'].to_s.strip.empty?
        errs << "N1 column '#{c['id'] || '(no id)'}' on element '#{name}': `name` is empty/whitespace-only — whitespace names break parity header matching and blank axis renders — use a real name (title hiding belongs on the element, not the name)."
      end

      # K1: a kpi-chart's value column must inline the FULL aggregate expression.
      # A bare sibling ref ([Total Calls]) compiles clean and renders NULL.
      if kind == 'kpi-chart'
        vcid = el.dig('value', 'columnId')
        vcol = cols.find { |c| c['id'] == vcid }
        if vcol && vcol['formula'].to_s =~ PLAIN_REF
          errs << "K1 kpi-chart '#{name}': value column '#{vcid}' formula is a bare sibling ref (`#{vcol['formula']}`) — kpi-chart value columns must inline the full aggregate expression — bare sibling refs compile clean but render null."
        end
      end

      # S1: element-level backgroundColor on kpi/bar tiles breaks the export
      # renderer (live UI fine, PNG export blank + garbled separators).
      if %w[kpi-chart bar-chart].include?(kind) && el.dig('style', 'backgroundColor')
        errs << "S1 #{kind} '#{name}': style.backgroundColor (#{el.dig('style', 'backgroundColor').inspect}) — backgroundColor on kpi/bar blanks the tile in PNG export and garbles number separators — use container styling instead."
      end

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

        # A COLUMN-BOUND source ({kind:source}) must be double-nested
        # ({kind:source, source:{kind:table,elementId}, columnId}). A MANUAL
        # value-list source ({kind:manual, valueType, values, labels}) — emitted
        # for segmented parameter controls (e.g. an enterprise measure-switcher) — is a
        # self-contained list and is correct as-is; Sigma accepts it (live-verified
        # 2026-06-25). Only flag the column-bound form when it isn't double-nested.
        if el['source'].is_a?(Hash) && el['source']['kind'] == 'source' && !el['source']['source'].is_a?(Hash)
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

        # C5: single-select controls take a SCALAR `value`, never a `values`
        # array — with values:[...] both the filter and the default silently
        # drop on PUT (probe-isolated live, twice).
        if el['selectionMode'].to_s == 'single' && el['values'].is_a?(Array)
          scalar = el['values'].first
          errs << "C5 control '#{name}': selectionMode \"single\" carries `values` (array) — the filter and the default silently drop. Use a scalar instead: replace `values: #{el['values'].inspect}` with `value: #{scalar.inspect}`."
        end

        # C6/C7/C8: controlType grammar — mirrors Sigma spec/verify offline.
        ct = el['controlType'].to_s
        unless ct.empty?
          if ct == 'top-n'
            errs << "C6 control '#{name}': controlType \"top-n\" is docs-only — the live tenant 400s it (probed 2026-07-11). Use a top-N rank-filter on the ELEMENT, not a control."
          elsif !CONTROL_TYPES.include?(ct)
            errs << "C6 control '#{name}': unknown controlType \"#{ct}\". Valid: #{CONTROL_TYPES.join(', ')}."
          end
          # C7: operator-bearing controls require a `mode`.
          if MODE_REQUIRED.include?(ct) && el['mode'].to_s.empty?
            errs << "C7 control '#{name}': controlType \"#{ct}\" requires a `mode` (#{MODE_HINT[ct]}) — absent, Sigma 400s the spec."
          end
          # C7: a range-slider without track bounds silently filters every row out.
          if ct == 'range-slider' && (el['low'].nil? || el['high'].nil?)
            errs << "C7 control '#{name}': controlType \"range-slider\" needs flat `low`/`high` track bounds — bare emits a 0..0 slider that filters all rows out."
          end
          # C7: an unbounded number-range (both min AND max null/absent) 400s the
          # spec — the builder null-fills mode:between bounds instead of omitting
          # them (field-caught: an opaque union-type 400 mislabeled "modal"). Set
          # flat min/max, or drop the control if the range is genuinely open.
          if ct == 'number-range' && el['min'].nil? && el['max'].nil?
            errs << "C7 control '#{name}': controlType \"number-range\" has neither `min` nor `max` — an unbounded number-range 400s (null-filled between-bounds). Set flat min/max, or drop the control."
          end
          # C8: includeNulls only valid on a specific subset.
          if el.key?('includeNulls') && !INCLUDE_NULLS_OK.include?(ct)
            errs << "C8 control '#{name}': `includeNulls` is off-schema for controlType \"#{ct}\" (valid only on: #{INCLUDE_NULLS_OK.join(', ')})."
          end
        end
      end
    end
  end
  errs
end

# WARN-level findings (P1/I1): printed by the CLI but never fail the lint —
# P1 is a live-verified silent no-op, I1 a heuristic with known false positives
# (a string-matching Switch([Region], "East", ...) is legitimate).
def lint_warnings(spec)
  warns = []
  (spec['pages'] || []).each do |pg|
    (pg['elements'] || []).each do |el|
      kind = el['kind']
      name = el['name'] || el['id'] || '(unnamed)'

      # P1: conditionalFormats with includeValues:false is a silent no-op.
      (el['conditionalFormats'] || []).each_with_index do |cf, i|
        next unless cf.is_a?(Hash) && cf['includeValues'] == false
        warns << "P1 #{kind} '#{name}': conditionalFormats[#{i}] has includeValues:false — includeValues:false silently disables the format — verified live. Keep includeValues:true."
      end

      # I1: If()/Switch() over a bare column ref (no comparison) — integer/bit
      # predicates fail at render ("Invalid Query"). Suggest an explicit = 1.
      (el['columns'] || []).each do |c|
        c['formula'].to_s.scan(BARE_PREDICATE) do |fn, ref|
          warns << "I1 column '#{c['name'] || c['id']}' on element '#{name}': #{fn}(#{ref}, ...) uses a bare column ref as the predicate — integer predicates fail at render ('Invalid Query'). Use an explicit comparison, e.g. #{fn}(#{ref} = 1, ...)."
        end
      end
    end
  end
  warns
end

if __FILE__ == $PROGRAM_NAME
  path = ARGV[0] or abort('usage: preflight_lint.rb <workbook-spec.json>')
  spec = JSON.parse(File.read(path))
  errs = lint(spec)
  warns = lint_warnings(spec)
  if errs.empty?
    puts "preflight lint: clean#{warns.any? ? " (#{warns.size} warning(s))" : ''}"
    warns.each { |w| warn "  ⚠ #{w}" }
    exit 0
  end
  warn "preflight lint: #{errs.size} violation(s)#{warns.any? ? ", #{warns.size} warning(s)" : ''}"
  errs.each { |e| warn "  ✗ #{e}" }
  warns.each { |w| warn "  ⚠ #{w}" }
  exit 1
end
