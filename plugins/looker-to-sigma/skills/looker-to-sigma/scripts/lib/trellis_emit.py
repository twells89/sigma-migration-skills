"""TrellisEmit — the converter-agnostic emitter for Sigma's NATIVE element
`trellis` property (small multiples / faceting). ONE source of truth for
  (a) which chart kinds actually support a spec-authored trellis, and
  (b) what to do on the kinds that DON'T (the documented fallbacks).

BYTE-COMPATIBLE PYTHON MIRROR of shared/lib/trellis_emit.rb — same supported set,
same fallbacks, same disposition semantics, same results. The Ruby copy is used
by the Ruby builders (tableau); the Qlik / Power-BI builders are Python, so they
call this. The scout_gate.rb / scout_gate.py pair is the precedent for a shared
cross-language lib: the two sides must agree exactly on the contract. Ruby's
result SYMBOLS (:trellised, :fallback_donut, :needs_sibling_fanout,
:needs_pivot_shelves, :flat) are mirrored here as the identical STRINGS.

Empirical basis: docs/sigma-trellis-chart-support.md. Sigma accepts a POST with
an element `trellis` key (200 OK) but SILENTLY STRIPS it on unsupported kinds —
the key is simply gone on readback and the tile renders flat, no error. So the
supported set below is a hard gate, and every caller that emits a native trellis
MUST re-read the spec and assert the key survived (see verify-trellis-survived).

The correct Sigma shape is ONE viz element with the facet dimension as a column
and `trellis: { rowsBy | columnsBy: [{ columnId }] }` (a 2-D grid points rowsBy
and columnsBy at two DIFFERENT columns). This is distinct from the pivot-table's
own `rowsBy`/`columnsBy` cross-tab shelves (keyed on `columnId`, a separate mechanism).

Interface (converter-agnostic; mutates the element dict in place):
  apply(element, facet_column_id, orientation)
    element          — the Sigma element spec dict (needs 'kind'; 'trellis' set here)
    facet_column_id  — a columns[] id str, OR a 2-element [rowId, colId] list for
                       a true 2-D grid
    orientation      — 'rows' | 'cols' | 'grid'
  -> returns one of RESULTS:
    "trellised"             — supported kind; element['trellis'] set
    "fallback_donut"        — kind was pie-chart -> converted to donut + trellis set
    "needs_sibling_fanout"  — kpi-chart -> caller should fan out to N sibling KPIs
    "needs_pivot_shelves"   — pivot-table -> caller should use its own rowsBy/columnsBy
    "flat"                  — table / anything else -> leave flat (no-op)
  On the three no-op results the element is left UNTOUCHED (no trellis key, no
  kind change), so a caller can branch on the result and take the fallback path.

Pure + stdlib-only + unit-tested (test_trellis_emit.py). Canonical lives in
shared/lib; edit there, run tools/sync-shared.rb.
"""

# Kinds whose native `trellis` key round-trips (survives readback). Emit ONLY
# for these; the rest silently strip it. (docs/sigma-trellis-chart-support.md)
SUPPORTED_KINDS = (
    "bar-chart", "line-chart", "area-chart", "combo-chart", "scatter-chart", "donut-chart",
)

# Fallback rule per unsupported kind -> the action the emitter takes / signals.
#   convert_to_donut  pie has no native trellis but donut does -> convert, then trellis
#   sibling_fanout    kpi has no native trellis -> fan out to N per-member KPI elements
#   pivot_shelves     pivot-table faceting is its OWN rowsBy/columnsBy shelves
#   flat              table (and any other kind) -> keep flat
FALLBACKS = {
    "pie-chart": "convert_to_donut",
    "kpi-chart": "sibling_fanout",
    "pivot-table": "pivot_shelves",
    "table": "flat",
}

RESULTS = ("trellised", "fallback_donut", "needs_sibling_fanout", "needs_pivot_shelves", "flat")


def disposition(kind):
    """Non-mutating: what WILL apply do for this kind? Lets a caller gate the
    element-specific work (adding the facet column, emptying member filters,
    dropping siblings) to only the kinds that actually trellis."""
    k = str(kind)
    if k in SUPPORTED_KINDS:
        return "trellised"
    fb = FALLBACKS.get(k)
    if fb == "convert_to_donut":
        return "fallback_donut"
    if fb == "sibling_fanout":
        return "needs_sibling_fanout"
    if fb == "pivot_shelves":
        return "needs_pivot_shelves"
    return "flat"


def trellises(kind):
    """True when apply will set a native trellis (supported kind, or pie->donut).
    (Ruby: TrellisEmit.trellises?)"""
    d = disposition(kind)
    return d == "trellised" or d == "fallback_donut"


def apply(element, facet_column_id, orientation):
    """Mutating. On a supported kind (or pie->donut) sets element['trellis'] and
    returns "trellised" / "fallback_donut". On kpi/pivot/table leaves the element
    untouched and returns the signal so the caller runs the documented fallback."""
    kind = str(element.get("kind"))
    if kind == "pie-chart":
        element["kind"] = "donut-chart"  # donut trellises natively; pie strips the key
        result = "fallback_donut"
    elif kind in SUPPORTED_KINDS:
        result = "trellised"
    else:
        return disposition(kind)  # no-op: needs_sibling_fanout / needs_pivot_shelves / flat
    element["trellis"] = trellis_object(facet_column_id, orientation)
    return result


def trellis_object(facet_column_id, orientation):
    """Build the `trellis` value for the given facet(s) + orientation.
      'rows' -> { rowsBy: [ref] }                     vertical small-multiples
      'cols' -> { columnsBy: [ref] }                  horizontal small-multiples
      'grid' -> two facet ids  -> { rowsBy:[a], columnsBy:[b] }  a true 2-D grid
                one facet id   -> { columnsBy: [ref] }  single field wraps into a tile grid
    A single facet always faces ONE axis (rowsBy XOR columnsBy — emitting both on
    the SAME column is degenerate)."""
    ids = facet_column_id if isinstance(facet_column_id, (list, tuple)) else [facet_column_id]
    o = str(orientation)
    if o == "rows":
        return {"rowsBy": [ref(ids[0])]}
    if o == "grid":
        if len(ids) >= 2:
            return {"rowsBy": [ref(ids[0])], "columnsBy": [ref(ids[1])]}
        return {"columnsBy": [ref(ids[0])]}
    # 'cols' and any other single-axis default
    return {"columnsBy": [ref(ids[0])]}


def ref(column_id):
    return {"columnId": column_id}
