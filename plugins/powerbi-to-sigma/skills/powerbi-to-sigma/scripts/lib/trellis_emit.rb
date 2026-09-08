# frozen_string_literal: true
#
# TrellisEmit — the converter-agnostic emitter for Sigma's NATIVE element
# `trellis` property (small multiples / faceting). ONE source of truth for
#   (a) which chart kinds actually support a spec-authored trellis, and
#   (b) what to do on the kinds that DON'T (the documented fallbacks).
#
# Empirical basis: docs/sigma-trellis-chart-support.md. Sigma accepts a POST with
# an element `trellis` key (200 OK) but SILENTLY STRIPS it on unsupported kinds —
# the key is simply gone on readback and the tile renders flat, no error. So the
# supported set below is a hard gate, and every caller that emits a native trellis
# MUST re-read the spec and assert the key survived (see verify-trellis-survived).
#
# The correct Sigma shape is ONE viz element with the facet dimension as a column
# and `trellis: { rowsBy | columnsBy: [{ columnId }] }` (a 2-D grid points rowsBy
# and columnsBy at two DIFFERENT columns). This is distinct from the pivot-table's
# own `rowsBy`/`columnsBy` cross-tab shelves (keyed on `columnId`, a separate mechanism).
#
# Interface (converter-agnostic; mutates the element hash in place):
#   TrellisEmit.apply(element, facet_column_id:, orientation:)
#     element          — the Sigma element spec Hash (needs 'kind'; 'trellis' set here)
#     facet_column_id  — a columns[] id String, OR a 2-element [rowId, colId] Array
#                        for a true 2-D grid
#     orientation      — :rows | :cols | :grid   (Strings 'rows'/'cols'/'grid' ok)
#   → returns one of RESULTS:
#     :trellised             — supported kind; element['trellis'] set
#     :fallback_donut        — kind was pie-chart → converted to donut + trellis set
#     :needs_sibling_fanout  — kpi-chart → caller should fan out to N sibling KPIs
#     :needs_pivot_shelves   — pivot-table → caller should use its own rowsBy/columnsBy
#     :flat                  — table / anything else → leave flat (no-op)
#   On the three no-op results the element is left UNTOUCHED (no trellis key, no
#   kind change), so a caller can branch on the result and take the fallback path.
#
# Pure + stdlib-only + unit-tested (test-trellis-emit.rb). Canonical lives in
# shared/lib; edit there, run tools/sync-shared.rb.

module TrellisEmit
  module_function

  # Kinds whose native `trellis` key round-trips (survives readback). Emit ONLY
  # for these; the rest silently strip it. (docs/sigma-trellis-chart-support.md)
  SUPPORTED_KINDS = %w[
    bar-chart line-chart area-chart combo-chart scatter-chart donut-chart
  ].freeze

  # Fallback rule per unsupported kind → the action the emitter takes / signals.
  #   :convert_to_donut  pie has no native trellis but donut does → convert, then trellis
  #   :sibling_fanout    kpi has no native trellis → fan out to N per-member KPI elements
  #   :pivot_shelves     pivot-table faceting is its OWN rowsBy/columnsBy shelves
  #   :flat              table (and any other kind) → keep flat
  FALLBACKS = {
    'pie-chart'   => :convert_to_donut,
    'kpi-chart'   => :sibling_fanout,
    'pivot-table' => :pivot_shelves,
    'table'       => :flat
  }.freeze

  RESULTS = %i[trellised fallback_donut needs_sibling_fanout needs_pivot_shelves flat].freeze

  # Non-mutating: what WILL apply do for this kind? Lets a caller gate the
  # element-specific work (adding the facet column, emptying member filters,
  # dropping siblings) to only the kinds that actually trellis.
  def disposition(kind)
    k = kind.to_s
    return :trellised if SUPPORTED_KINDS.include?(k)

    case FALLBACKS[k]
    when :convert_to_donut then :fallback_donut
    when :sibling_fanout   then :needs_sibling_fanout
    when :pivot_shelves    then :needs_pivot_shelves
    else :flat
    end
  end

  # True when apply will set a native trellis (supported kind, or pie→donut).
  def trellises?(kind)
    d = disposition(kind)
    d == :trellised || d == :fallback_donut
  end

  # Mutating. On a supported kind (or pie→donut) sets element['trellis'] and
  # returns :trellised / :fallback_donut. On kpi/pivot/table leaves the element
  # untouched and returns the signal so the caller runs the documented fallback.
  def apply(element, facet_column_id:, orientation:)
    kind = element['kind'].to_s
    result =
      if kind == 'pie-chart'
        element['kind'] = 'donut-chart' # donut trellises natively; pie strips the key
        :fallback_donut
      elsif SUPPORTED_KINDS.include?(kind)
        :trellised
      else
        return disposition(kind) # no-op: needs_sibling_fanout / needs_pivot_shelves / flat
      end
    element['trellis'] = trellis_object(facet_column_id, orientation)
    result
  end

  # Build the `trellis` value for the given facet(s) + orientation.
  #   :rows → { rowsBy: [ref] }                     vertical small-multiples
  #   :cols → { columnsBy: [ref] }                  horizontal small-multiples
  #   :grid → two facet ids  → { rowsBy:[a], columnsBy:[b] }  a true 2-D grid
  #           one facet id   → { columnsBy: [ref] }  single field wraps into a tile grid
  # A single facet always faces ONE axis (rowsBy XOR columnsBy — emitting both on
  # the SAME column is degenerate).
  def trellis_object(facet_column_id, orientation)
    ids = Array(facet_column_id)
    case orientation.to_s
    when 'rows'
      { 'rowsBy' => [ref(ids.first)] }
    when 'grid'
      if ids.length >= 2
        { 'rowsBy' => [ref(ids[0])], 'columnsBy' => [ref(ids[1])] }
      else
        { 'columnsBy' => [ref(ids.first)] }
      end
    else # 'cols' and any other single-axis default
      { 'columnsBy' => [ref(ids.first)] }
    end
  end

  def ref(column_id)
    { 'columnId' => column_id }
  end
end
