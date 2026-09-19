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
#       an unbounded `number-range` (control OR element filter) whose `min` AND
#       `max` are BOTH present-and-null — the {min:null,max:null} shape an
#       UNRESTRICTED Tableau quantitative quick-filter used to emit, which 400s
#       the whole POST (issue #422 — recurred across workbooks). A
#       number-range with the keys OMITTED is a valid unbounded control
#       (refs/workbook-layout.md); only null-VALUED bounds are the trap.
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
#   A1  a control carrying a DROPPED_BY_API field — the Workbook Spec API
#       ACCEPTS it (200 on POST/PUT) and SILENTLY DROPS it on readback, so it
#       never takes effect (Sigma product gap — issues #415/#417). Unlike the
#       C-class violations, these do NOT 400: they are silently ignored.
#       DROPPED_BY_API members flagged `conditional` (e.g. `filters`, #456) are
#       NOT warned here — they persist in the normal case and drop only under a
#       specific condition, so A1 (a presence check) would false-fire on every
#       control. Their drop is caught EMPIRICALLY post-POST by the control-field
#       census (lib/control_field_census.rb).
#   A2  a date-range control whose startDate/endDate default is a BARE date
#       ("2026-01-01") or a zoneless timestamp — accepted then silently
#       dropped (#415); only full ISO-8601 UTC timestamps
#       ("2026-01-01T00:00:00Z") round-trip.
require 'json'
require_relative 'code_rep'

AGG = /\A\s*(Sum|Avg|Count|CountDistinct|CountIf|SumIf|Min|Max|Median|Percentile|StdDev|Variance|VariancePop|GrandTotal)\s*\(/i
PLAIN_REF = /\A\s*\[[^\]]+\]\s*\z/   # a bare column reference, e.g. [Table/Region]
LISTY = %w[list segmented hierarchy].freeze
# C6/C7/C8: controlType shape rules — mirror Sigma's server-side spec/verify
# OFFLINE, so the control-grammar 400s (each of which otherwise costs a full
# orchestrator round-trip to discover) are caught pre-POST. Canary-verified
# server-side 2026-07-11 (see refs/composition-recipe.md).
CONTROL_TYPES = %w[checkbox switch text text-area number number-range date date-range
                   list segmented hierarchy slider range-slider legend drill].freeze
# controlTypes that REQUIRE a `mode` operator — absent/empty → Sigma 400s the spec.
MODE_REQUIRED = %w[switch checkbox text number date slider].freeze
MODE_HINT = {
  'switch' => "'True/False' | 'True/All'", 'checkbox' => "'True/False' | 'True/All'",
  'text' => "an operator, e.g. 'equals'", 'number' => "'=' | '>=' | '<='",
  'date' => "'=' | '>=' | '<='", 'slider' => "'=' | '>=' | '<='"
}.freeze
# `includeNulls` is schema-valid ONLY on these types (stray elsewhere = off-schema).
INCLUDE_NULLS_OK = %w[text number number-range date date-range slider range-slider].freeze
# A1: the DROPPED_BY_API contract table — control fields the Workbook Spec API
# accepts with 200 on POST/PUT but SILENTLY DROPS on readback (GET returns the
# control without them; they never take effect on the live control). This is a
# Sigma product gap, NOT a spec-grammar error: the C-class checks above catch
# shapes that 400, this family is silently ignored. Human-readable contract
# table: sigma-workbooks reference/specification/controls.md ("Dropped-by-API
# fields"). Sources: issues #415 (date-range startDate/endDate — see A2), #417
# (list-control editor toggles), and #456 (list-control filter TARGET binding),
# all round-trip-confirmed in the field.
# field => { 'types' => affected controlTypes (informational — the drop is
# observed regardless of type), 'workaround' => the sanctioned alternative,
# 'conditional' => (optional) true when the field PERSISTS in the normal case
# and drops only under a specific condition — such members are documented here
# for the contract but are NOT A1-warned on mere presence (A1 is a presence
# check; it would false-fire on every control). Their drop is caught
# empirically post-POST by the control-field census instead. }.
DROPPED_BY_API = {
  'showNullOption' => {
    'types' => %w[list segmented hierarchy],
    'workaround' => "filter nulls at the control's OPTION-SOURCE instead: point the control's " \
                    'value-list `source` at a hidden helper element that carries an IsNotNull(<col>) ' \
                    'filter (build-charts-from-signals emits this automatically for null-excluding ' \
                    'Tableau filters — field-validated)'
  },
  'allowMultipleSelection' => {
    'types' => %w[list],
    'workaround' => 'use `selectionMode: "single"|"multiple"` — that field DOES persist'
  },
  'excludeValues' => {
    'types' => %w[list segmented hierarchy],
    'workaround' => 'use `mode: "exclude"` with `values` = the excluded members — that shape DOES persist'
  },
  'showClearButton' => {
    'types' => %w[list segmented hierarchy],
    'workaround' => 'no spec equivalent — configure in the Sigma UI control editor post-publish (record it in POSTPUBLISH_GUIDE.md)'
  },
  'showSearchBox' => {
    'types' => %w[list],
    'workaround' => 'no spec equivalent — configure in the Sigma UI control editor post-publish (record it in POSTPUBLISH_GUIDE.md)'
  },
  'showHistogram' => {
    'types' => %w[list slider range-slider],
    'workaround' => 'no spec equivalent — configure in the Sigma UI control editor post-publish (record it in POSTPUBLISH_GUIDE.md)'
  },
  'showExpandedList' => {
    'types' => %w[list],
    'workaround' => 'no spec equivalent — configure in the Sigma UI control editor post-publish (record it in POSTPUBLISH_GUIDE.md)'
  },
  'required' => {
    'types' => %w[list text number date date-range],
    'workaround' => 'no spec equivalent — configure in the Sigma UI control editor post-publish (record it in POSTPUBLISH_GUIDE.md)'
  },
  # #456: the list-control filter TARGET binding itself (which column(s) the
  # control filters). UNLIKE the always-drop editor toggles above, `filters`
  # USUALLY round-trips — it is silently dropped only in a specific condition
  # (the target column is numeric/datetime, or the target can't resolve), where
  # the readback keeps the `filters` KEY but strips its columnId/source so the
  # control filters NOTHING. Hence `conditional: true` — A1 must NOT warn on its
  # mere presence (every valid control carries filters). Detection is EMPIRICAL:
  # the post-POST control-field census (lib/control_field_census.rb) flags a
  # posted target that binds nothing on readback. A raw NUMERIC list target is
  # already routed through a Text() decode by build-charts-from-signals (see A3
  # below); a target that still can't bind goes to POSTPUBLISH_GUIDE.md.
  'filters' => {
    'types' => %w[list segmented hierarchy],
    'conditional' => true,
    'workaround' => 'the target DOES persist when it points at a TABLE element on a STRING column ' \
                    '(filters:[{source:{kind:table,elementId:<table>}, columnId:<col>}]); a NUMERIC/DATETIME ' \
                    'target is silently stripped (reads back filters:null) — cast it with a hidden Text([<col>]) ' \
                    'decode column and bind BOTH the filter target and the value-source to the decode ' \
                    '(build-charts-from-signals routes integer dims automatically; see A3). If it still ' \
                    "can't bind, route to POSTPUBLISH_GUIDE.md — never ship a control that filters nothing"
  }
}.freeze
# A2: the ONLY startDate/endDate string form observed to round-trip on a
# date-range control is a full ISO-8601 timestamp WITH timezone (UTC `Z` is
# what Sigma echoes back). Bare dates ("2026-01-01") are accepted then
# silently dropped (#415). Relative {op,unit,value} hashes (custom mode) are
# fine and not checked here.
ISO_UTC_DATETIME = /\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/.freeze
# I1: If( whose first argument is a bare [ref] immediately followed by `,` or
# `)` — i.e. no comparison operator. `If([x] = 1, ...)` does NOT match.
# v5.4: If( ONLY — Sigma's Switch(expr, case1, val1, …, default) is MATCH-form,
# so a bare [col] first argument is the matched SUBJECT, fully legitimate (the
# builder's own SORT_ORD ordering columns are exactly this shape and I1
# flagged them as false positives twice in the field).
BARE_PREDICATE = /\b(If)\s*\(\s*(\[[^\]]+\])\s*[,)]/i

def lint(spec)
  spec = Sigma::CodeRep.document(spec)
  errs = []
  cols_by_id = {}
  elements = Sigma::CodeRep.workbook_elements(spec)
  elements.each do |el|
    (el['columns'] || []).each { |c| cols_by_id[c['id']] = c }
  end
  elements.each do |el|
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

      # C7 (element filters): a number-range ELEMENT filter with min AND max
      # BOTH present-and-null is the same {min:null,max:null} 400 shape as the
      # control case — the exact defect an UNRESTRICTED Tableau quantitative
      # quick-filter produced (issue #422). The builder now skips
      # emitting it, but hard-block any that slip through from any code path so
      # it can never reach POST again. Keys OMITTED = valid unbounded; only
      # null-VALUED bounds are flagged.
      (el['filters'] || []).each_with_index do |flt, i|
        next unless flt.is_a?(Hash) && flt['kind'] == 'number-range'
        next unless flt['min'].nil? && flt['max'].nil? && (flt.key?('min') || flt.key?('max'))
        errs << "C7 element '#{name}': number-range filter[#{i}] has min:null and max:null — an unbounded range Sigma 400s at POST (#422). An UNRESTRICTED quantitative filter is 'all values': drop the filter (it hides nothing) instead of shipping null bounds."
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
          # C7: a number-range control whose min AND max are BOTH present-and-null
          # is the unbounded {min:null,max:null} shape Sigma 400s at POST (#422 —
          # an UNRESTRICTED Tableau quantitative quick-filter). Keys OMITTED is a
          # valid unbounded number-range (refs/workbook-layout.md); only
          # null-VALUED bounds are the trap, so require at least one bound key be
          # present-and-null before flagging (never flag the valid keys-omitted form).
          if ct == 'number-range' && el['min'].nil? && el['max'].nil? && (el.key?('min') || el.key?('max'))
            errs << "C7 control '#{name}': controlType \"number-range\" with min:null and max:null is an unbounded range Sigma 400s at POST (#422) — an UNRESTRICTED quantitative filter is 'all values': emit NO min/max keys (valid unbounded number-range) or concrete bounds, never null bounds."
          end
          # C8: includeNulls only valid on a specific subset.
          if el.key?('includeNulls') && !INCLUDE_NULLS_OK.include?(ct)
            errs << "C8 control '#{name}': `includeNulls` is off-schema for controlType \"#{ct}\" (valid only on: #{INCLUDE_NULLS_OK.join(', ')})."
          end
        end
      end
  end
  errs
end

# A3 (PR-18): a `Text([ref])` decode of a single column reference — the shape
# the integer-dim decode routing emits and this lint verifies. Deliberately does
# NOT match `ToText(` (not a Sigma function).
A3_TEXT_DECODE = /\AText\s*\(\s*\[[^\]]+\]\s*\)\s*\z/i
A3_LISTY = %w[list segmented hierarchy].freeze

# WARN-level findings (P1/I1/A3): printed by the CLI but never fail the lint —
# P1 is a live-verified silent no-op, I1 a heuristic with known false positives
# (a string-matching Switch([Region], "East", ...) is legitimate), A3 flags an
# integer-coded dimension control shipped WITHOUT a Text() decode helper.
#
# `scope` (optional) is the parsed control-scope.json sidecar. When a control is
# marked `integer_dim:true` there (build-charts stamps it from the .twb datatype
# + shelf role), A3 KNOWS the bound column is integer-coded and can warn even
# when the raw column's type is invisible in the spec. Without a scope, A3 still
# catches the precise "decode column exists but the control targets the raw
# column instead" mis-wire from the spec alone.
def lint_warnings(spec, scope: nil)
  spec = Sigma::CodeRep.document(spec)
  warns = []
  Sigma::CodeRep.workbook_elements(spec).each do |el|
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

      # N2: a column display name containing '/' is ambiguous against the
      # [Element/Column] path syntax every cross-element formula ref uses —
      # downstream refs to it split on the slash and resolve a fragment
      # (Sigma-side 'dependency not found', false PASS/FAIL in ref checks),
      # and converters DROP such columns from derived elements. WARN, not a
      # violation: a slash-named column nothing references cross-element is
      # harmless, so failing the POST for it would be a false stop.
      ((el['columns'] || []) + (el['metrics'] || [])).each do |c|
        next unless c.is_a?(Hash) && c['name'].to_s.include?('/')
        warns << "N2 column '#{c['name']}' on element '#{name}': display name contains '/' — ambiguous against " \
                 "the [Element/Column] reference path syntax; cross-element refs to it mis-resolve and derived " \
                 'elements drop it. Rename the column (remove the slash) before wiring anything to it.'
      end

      next unless kind == 'control'
      ct = el['controlType'].to_s

      # A1: fields the Workbook Spec API accepts then silently drops (#415/#417).
      DROPPED_BY_API.each do |field, info|
        # `conditional` members (e.g. `filters`, #456) persist in the normal case
        # and drop only under a specific condition — a presence check would
        # false-fire on every control; the post-POST census catches their drop.
        next if info['conditional']
        next unless el.key?(field)
        warns << "A1 control '#{name}': `#{field}` (controlType \"#{ct}\") is accepted by POST/PUT (200) " \
                 'but SILENTLY DROPPED on readback — it will never take effect (silently ignored, NOT a 400 ' \
                 'like the C-class violations; Sigma product gap, issue #417). ' \
                 "Workaround: #{info['workaround']}."
      end

      # A2: date-range default in a non-persisting string form (#415).
      if ct == 'date-range'
        %w[startDate endDate].each do |f|
          v = el[f]
          next unless v.is_a?(String) && !v.strip.empty? && v !~ ISO_UTC_DATETIME
          warns << "A2 control '#{name}': date-range `#{f}` #{v.inspect} is a bare/zoneless date — accepted " \
                   'by POST/PUT (200) but SILENTLY DROPPED on readback; the control ships with NO default ' \
                   '(silently ignored, not a 400 — Sigma product gap, issue #415). Workaround: emit a full ' \
                   "ISO-8601 UTC timestamp (e.g. \"#{v[0, 10]}T00:00:00Z\"), the only string form observed to " \
                   'round-trip; then confirm via the post-POST control-field audit, and if it still drops, set ' \
                   'the default in the Sigma UI (record it in POSTPUBLISH_GUIDE.md).'
        end
      end
  end

  # A3 (PR-18): integer-coded dimension control without a Text() decode helper.
  # A Sigma list/segmented/hierarchy control sources STRING option values, so a
  # filter target on a raw INTEGER column is accepted (200) then SILENTLY
  # stripped — the readback carries filters:null and the control filters nothing
  # (control-parity.md "list-control targets on NUMERIC columns are silently
  # stripped"). The fix is a `Text([<col>])` decode column the control binds to.
  # This catches a REGRESSION of the auto-decode routing. Advisory only.
  all_els = Sigma::CodeRep.workbook_elements(spec)
  els_by_id = all_els.each_with_object({}) { |e, h| (id = e['id'] || e['elementId']) && (h[id] = e) }
  # controlId -> scope record (integer_dim / decode annotations).
  scope_by_cid = {}
  if scope.is_a?(Hash)
    Array(scope['controls']).each { |c| scope_by_cid[c['controlId']] = c if c.is_a?(Hash) && c['controlId'] }
  end
  resolve_target = lambda do |t|
    return nil unless t.is_a?(Hash)
    eid = t.dig('source', 'elementId')
    tgt_el = els_by_id[eid]
    return nil unless tgt_el
    (tgt_el['columns'] || []).find { |c| c['id'] == t['columnId'] }
  end
  all_els.each do |el|
    next unless (el['kind'] || el['type']).to_s.include?('control')
    next unless A3_LISTY.include?(el['controlType'].to_s)
    name = el['name'] || el['id'] || '(unnamed)'
    cid  = el['controlId']
    targets = Array(el['filters'])
    target_cols = targets.map { |t| resolve_target.call(t) }.compact
    has_decode = target_cols.any? { |c| c['formula'].to_s =~ A3_TEXT_DECODE }
    sc = scope_by_cid[cid] || {}
    decode_status = sc.dig('decode', 'status').to_s

    # Signal 1 — scope marks this control integer_dim but the spec ships no
    # decode target. manual-required is an ACCOUNTED gap (routed to the
    # POSTPUBLISH guide) — surface it, but as the softer "add it by hand" note.
    if sc['integer_dim'] && !has_decode
      if %w[manual-required partial-manual].include?(decode_status)
        warns << "A3 control '#{name}': integer-coded dimension control whose decode could NOT be auto-built " \
                 "(#{decode_status}) — Sigma silently strips a raw numeric list-filter target. Add a `Text([<col>])` " \
                 'decode column on the target element by hand and bind the control to it (routed to POSTPUBLISH_GUIDE.md).'
      else
        warns << "A3 control '#{name}': integer-coded dimension control (control-scope integer_dim:true) with NO " \
                 '`Text([<col>])` decode helper among its filter targets — Sigma accepts the raw numeric target (200) ' \
                 'then SILENTLY strips it (readback filters:null); the control filters nothing. Add a Text() decode ' \
                 'column and repoint the control to it (build-charts-from-signals routes this automatically — a miss ' \
                 'here is a regression).'
      end
      next
    end

    # Signal 2 — spec-only mis-wire: a decode column EXISTS on the target element
    # but the control still targets the RAW column. Precise, no false positives:
    # only fires when a sibling `Text([<target col name>])` is present.
    next if has_decode
    targets.each do |t|
      raw = resolve_target.call(t)
      next unless raw
      sibs = (els_by_id[t.dig('source', 'elementId')]['columns'] || [])
      decode_sib = sibs.find { |c| c['formula'].to_s.strip.casecmp?("Text([#{raw['name']}])") }
      next unless decode_sib
      warns << "A3 control '#{name}': a `Text()` decode column (#{decode_sib['name'].inspect}) exists on the target " \
               "element but the control targets the RAW column #{raw['name'].inspect} — a raw numeric list-filter " \
               "target is silently stripped by Sigma. Repoint this filter target (and the control's value-source) " \
               "at #{decode_sib['id'].inspect}."
    end
  end

  warns
end

if __FILE__ == $PROGRAM_NAME
  path = ARGV[0] or abort('usage: preflight_lint.rb <workbook-spec.json> [control-scope.json]')
  spec = JSON.parse(File.read(path))
  # A control-scope.json next to the spec (or passed as ARGV[1]) lets A3 use the
  # .twb-derived integer_dim signal; without it A3 still catches decode mis-wires.
  scope_path = ARGV[1] || File.join(File.dirname(path), 'control-scope.json')
  scope = (JSON.parse(File.read(scope_path)) if File.exist?(scope_path.to_s)) rescue nil
  errs = lint(spec)
  warns = lint_warnings(spec, scope: scope)
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
