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
# Non-mappable modes (returned as coverage entries, NEVER silently dropped):
#   fieldValue (a DAX measure returns the hex) — the measure lives in the model,
#              not the report; recoverable once the measure is translated.
#   rules      (ruleDefinition) — thresholds aren't carried in the report def we
#              parse; recoverable by re-authoring in the Sigma UI (type:single).
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
        coverage << { visual: name, pbi_type: 'conditional-format', sigma_kind: kind,
                      severity: 'degraded', recoverable: true,
                      detail: "rules-based conditional format on '#{cf['target']}'",
                      action: 'Re-create the threshold rules in the Sigma UI (conditionalFormats type:single) — PBI rule thresholds are not carried in the report definition we parse.' }
      end
    end
    { 'formats' => formats, 'coverage' => coverage }
  end
end
