# frozen_string_literal: true

# lib/pbi_pivot_sort.rb — apply a Power BI matrix/tableEx sort to a Sigma
# pivot-table's row grouping.
#
# Two things this pins that the builder got wrong before:
#   1. A pivot-table row sort IS spec-expressible — `rowsBy[0].sort = {by, direction}`
#      is accepted, round-trips, and renders (verified 2026-07-15). The old builder
#      punted with "pivot-table sort is not spec-expressible, set it in the UI" and
#      dropped EVERY matrix/tableEx sort.
#   2. Power BI sorts a blank/null dimension member FIRST; Sigma sorts nulls LAST
#      and has no nulls-first option. So when we sort the ROW DIMENSION ITSELF
#      ascending, coalesce its nulls to "(Blank)" ("(" sorts before letters) — the
#      blank row then lands on top exactly like PBI, matching the donut/pie null
#      treatment (refs/style-fidelity.md). A MEASURE sort orders the blank by its
#      value, so we only coalesce when sorting by the dim ascending.
#
# NB: the sort's row order is the VISUAL's sort (PBIR query.sortDefinition, or the
# extractor's first-column-ascending default for null sortDefinition) — NEVER the
# parity/executeQueries row order, which is the DAX ORDER BY, not the display sort.
module PbiPivotSort
  BLANK_LABEL = '(Blank)'

  # Mutates `rows_by` (array of {"columnId"=>..}) and `cols` (array of {"id","formula"..})
  # in place. Returns true when a sort was applied, false when it couldn't be.
  #   rows_by : the pivot's rowsBy array (outer grouping is index 0)
  #   cols    : the element's built columns (for the coalesce rewrite)
  #   cid     : the resolved Sigma column id to sort by
  #   dir     : "ascending" | "descending"
  def self.apply!(rows_by:, cols:, cid:, dir:)
    return false unless rows_by.is_a?(Array) && !rows_by.empty? && cid

    rows_by[0] = (rows_by[0] || {}).merge('sort' => { 'by' => cid, 'direction' => dir })

    # blank-first reproduction: only when sorting BY THE ROW DIM ITSELF, ascending
    row_cid = rows_by[0]['columnId'] || rows_by[0]['id']
    if cols.is_a?(Array) && dir == 'ascending' && cid == row_cid
      dcol = cols.find { |c| c.is_a?(Hash) && c['id'] == cid }
      f = dcol && dcol['formula']
      if f.is_a?(String) && !f.strip.downcase.start_with?('coalesce(')
        dcol['formula'] = %(Coalesce(#{f}, "#{BLANK_LABEL}"))
      end
    end
    true
  end
end
