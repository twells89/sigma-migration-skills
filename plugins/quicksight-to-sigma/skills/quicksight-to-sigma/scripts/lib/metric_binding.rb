# frozen_string_literal: true
#
# metric_binding.rb — bind a workbook measure to a governed DM metric.
#
# Every converter builds a Sigma data model whose elements carry reusable metrics
# (name + formula), but the workbook builder tends to re-derive each measure inline
# (Sum([Master/Net Revenue]), CountDistinct(...), ...), bypassing the governed
# metric: the aggregation logic is duplicated (and can drift) and the analyst never
# gets the metric object. This is the thin, converter-agnostic binder that lets a
# builder prefer a governed [Metrics/<name>] reference when it is provably the same
# aggregation — and fall back to the inline formula otherwise.
#
# Two pure functions:
#
# - available_metrics(element_id, elements_by_id) — the metrics REFERENCEABLE on an
#   element: its own metrics plus those inherited through the source.elementId chain
#   (a denorm "<X> View" element carries 0 own metrics but inherits its base fact's;
#   Sigma exposes them and they resolve as [Metrics/<name>] on the denorm — verified
#   live). Deduped by name, nearest element wins. Each metric is {"name","formula"};
#   entries missing either field are skipped.
#
# - metric_ref_or_inline(inline, master_name, metrics) — returns "[Metrics/<name>]"
#   when `inline` matches a metric by FORMULA EQUIVALENCE (strip the master prefix so
#   Sum([Data/Net Revenue]) equals a metric's Sum([Net Revenue]), then compare
#   ignoring whitespace), else returns `inline` unchanged. Naming-independent and
#   SAFE: ratios / filtered / custom / no-match / empty-metrics all fall through to
#   inline, so passing no metrics is byte-identical to the pre-binding behavior.
#   Whether a column is even a measure (worth binding) is the caller's decision.
#
# The reference form is the literal namespace [Metrics/<Metric Name>] — NOT
# [Element/Name] (that errors). Extracted from the looker reference implementation
# (PR #484); see beads-sigma-7bun. Mirror: shared/lib/metric_binding.py — keep the
# two in lockstep.

module MetricBinding
  module_function

  # Whitespace-insensitive canonical form of a Sigma formula (or empty).
  def canon(formula)
    (formula || '').gsub(/\s+/, '')
  end

  # Metrics referenceable on element_id = own + inherited via source.elementId,
  # deduped by name (nearest element wins). elements_by_id maps id => element hash
  # (string keys, as JSON.parse produces). Returns an array of
  # {"name"=>, "formula"=>}; metrics missing a name or formula are dropped.
  # Cycle-safe.
  def available_metrics(element_id, elements_by_id)
    seen = {}
    chain = []
    eid = element_id
    while eid && !seen[eid]
      seen[eid] = true
      el = elements_by_id[eid]
      break unless el

      (el['metrics'] || []).each do |m|
        name = m['name']
        formula = m['formula']
        chain << { 'name' => name, 'formula' => formula } if name && formula
      end
      eid = (el['source'] || {})['elementId']
    end
    dedup_by_name(chain)
  end

  def dedup_by_name(metrics)
    seen = {}
    metrics.each_with_object([]) do |m, out|
      next if seen[m['name']]

      seen[m['name']] = true
      out << m
    end
  end

  # Prefer "[Metrics/<name>]" when `inline` matches a metric by formula equivalence
  # (master prefix stripped, whitespace ignored); otherwise return `inline`
  # unchanged. Safe no-op when `metrics` is empty/nil or `inline` is not a String.
  def metric_ref_or_inline(inline, master_name, metrics)
    return inline unless inline.is_a?(String) && metrics && !metrics.empty?

    # gsub with a String pattern strips EVERY master prefix literally (matches the
    # Python mirror's str.replace); Sum([M/a])/Sum([M/b]) → Sum([a])/Sum([b]).
    want = canon(inline.gsub("[#{master_name}/", '['))
    metrics.each do |m|
      name = m['name']
      formula = m['formula']
      return "[Metrics/#{name}]" if name && formula && canon(formula) == want
    end
    inline
  end
end
