# frozen_string_literal: true

# pbi_conditional_formats.rb — map extract-pbir's normalized table/matrix
# conditional-formatting records (rec['conditional_formats']) to Sigma
# element-level `conditionalFormats`. Pure + offline (no globals, no API) so it
# is unit-testable; build-workbook-from-pbir.rb requires it and feeds the
# returned coverage entries to record_unresolved.
#
# Mappable modes (emitted as Sigma conditionalFormats):
#   gradient  -> backgroundScale / fontScale (a low->high color scale)
#   dataBars  -> dataBars (sign-colored bars; see feedback_sigma_table_databars_spec)
#   rules     -> one `single` per band (native op+value; a two-sided And range ->
#              condition:formula "[Col] >= lo and [Col] < hi"). Cross-column /
#              compound / else-default cases -> coverage.
# Non-mappable (returned as coverage entries, NEVER silently dropped):
#   fieldValue (a DAX measure returns the hex) — the measure lives in the model,
#              not the report; recoverable once the measure is translated.
module PbiConditionalFormats
  module_function

  # Leaf of a PBI queryRef / Sigma ref: strip aggregation wrappers + take the
  # segment after the last '.', matching build-workbook-from-pbir.rb's qr_leaf so
  # an entity-qualified selector.metadata ("ORDER_FACT.Net Revenue $") matches a
  # bound queryRef that differs only by entity prefix.
  def leaf(qr)
    s = qr.to_s.strip
    s = Regexp.last_match(1).strip while s =~ /\A[A-Za-z_][A-Za-z0-9_ ]*\(\s*(.*)\s*\)\z/
    s.split('.').last.to_s.tr('[]', '').tr('/', '-')
  end

  # Resolve a CF target (selector.metadata) to a built column id in qr_cids
  # ({queryRef => columnId}). Exact match first, then a leaf-name fallback.
  def resolve(target, qr_cids)
    return qr_cids[target] if qr_cids[target]
    tl = leaf(target)
    return nil if tl.empty?
    hit = qr_cids.find { |qr, _| leaf(qr).casecmp(tl).zero? }
    hit && hit[1]
  end

  # "0.15" -> 0.15, "3" -> 3, "East" -> "East" (a threshold value for a single rule).
  def coerce_val(v)
    return v unless v.is_a?(String)
    return Integer(v) if v =~ /\A-?\d+\z/
    return Float(v) if v =~ /\A-?\d+\.\d+\z/
    v
  end

  # A threshold as a Sigma formula literal: numbers bare, strings double-quoted.
  def fmt_literal(v)
    cv = coerce_val(v)
    cv.is_a?(Numeric) ? cv.to_s : %("#{cv}")
  end

  # A rule's comparison list -> one Sigma `single` conditionalFormat, or nil when
  # the shape isn't a plain op / two-sided range (caller routes nil to coverage).
  # A single comparison uses a native operator condition; a two-sided And range
  # uses `condition: formula` (Sigma `single` has no Between) referencing the
  # column by display name.
  def single_from_comparisons(comps, cid, col_name, color, style_key)
    style = { style_key => color }
    if comps.size == 1
      c = comps[0]
      { 'type' => 'single', 'columnIds' => [cid], 'condition' => c['op'],
        'value' => coerce_val(c['value']), 'style' => style }
    elsif comps.size == 2
      lo = comps.select { |c| ['>', '>='].include?(c['op']) }
      hi = comps.select { |c| ['<', '<='].include?(c['op']) }
      return nil unless lo.size == 1 && hi.size == 1
      formula = "[#{col_name}] #{lo[0]['op']} #{fmt_literal(lo[0]['value'])} and " \
                "[#{col_name}] #{hi[0]['op']} #{fmt_literal(hi[0]['value'])}"
      { 'type' => 'single', 'columnIds' => [cid], 'condition' => 'formula',
        'formula' => formula, 'style' => style }
    end
  end

  # Returns { 'formats' => [Sigma conditionalFormats...], 'coverage' => [entries] }.
  # Each coverage entry is a hash of record_unresolved keyword args.
  def build(cfs, qr_cids, name, kind)
    formats = []
    coverage = []
    Array(cfs).each do |cf|
      cid = resolve(cf['target'], qr_cids)
      unless cid
        coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                      severity: 'degraded', recoverable: false,
                      detail: "conditional format on '#{cf['target']}' — that column is not in the migrated #{kind}" }
        next
      end
      case cf['mode']
      when 'gradient'
        scheme = Array(cf['scheme']).select { |c| c.to_s =~ /\A#/ }
        scheme = %w[#ffffcc #bd0026] if scheme.size < 2
        type = cf['property'] == 'font' ? 'fontScale' : 'backgroundScale'
        formats << { 'type' => type, 'columnIds' => [cid], 'scheme' => scheme }
      when 'dataBars'
        # low->high = negative,positive (Sigma bars are sign-colored, not a value gradient)
        scheme = [cf['negative'], cf['positive']].compact.select { |c| c.to_s =~ /\A#/ }
        scheme = ['#4caf7d'] if scheme.empty?
        formats << { 'type' => 'dataBars', 'columnIds' => [cid], 'scheme' => scheme }
      when 'fieldValue'
        coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                      severity: 'approximated', recoverable: true,
                      detail: "field-value conditional format on '#{cf['target']}' (color driven by measure #{cf['measure']})",
                      action: 'The cell color is computed by a DAX measure; re-create it in Sigma as a conditionalFormat with a `formula` condition once that measure is translated.' }
      when 'rules'
        rules = Array(cf['rules'])
        if rules.empty?
          # a Conditional/FillRule we couldn't model into discrete bands
          coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                        severity: 'degraded', recoverable: true,
                        detail: "rules-based conditional format on '#{cf['target']}' (unmodeled shape)",
                        action: 'Re-create the threshold rules in the Sigma UI (conditionalFormats type:single).' }
        else
          style_key = cf['property'] == 'font' ? 'color' : 'backgroundColor'
          tl = leaf(cf['target'])
          rules.each do |r|
            comps = Array(r['comparisons'])
            color = r['color']
            next if !color || comps.empty?
            # Sigma `single` colors the target column by its OWN value. If a rule
            # tests a DIFFERENT column, it needs a formula condition -> coverage.
            if comps.any? { |c| !c['driver'].to_s.empty? && leaf(c['driver']).casecmp(tl) != 0 }
              coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                            severity: 'degraded', recoverable: true,
                            detail: "cross-column rule on '#{cf['target']}' (driven by #{comps.map { |c| c['driver'] }.compact.uniq.join(', ')})",
                            action: 'Re-create as a conditionalFormat with a `formula` condition referencing the driving column.' }
              next
            end
            sf = single_from_comparisons(comps, cid, leaf(cf['target']), color, style_key)
            if sf
              formats << sf
            else
              coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                            severity: 'degraded', recoverable: true,
                            detail: "compound rule on '#{cf['target']}' (#{comps.size} conditions) not expressible as a single threshold",
                            action: 'Re-create as a conditionalFormat with a `formula` condition in the Sigma UI.' }
            end
          end
          # PBI "else" color has no single-rule form in Sigma.
          if cf['default']
            coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                          severity: 'approximated', recoverable: true,
                          detail: "default/else color on '#{cf['target']}' not carried (Sigma has no else-rule)",
                          action: 'Set the column background/default in the Sigma UI if the else color matters.' }
          end
        end
      end
    end
    { 'formats' => formats, 'coverage' => coverage }
  end
end
