# ── VENDORED (do not edit here) ──────────────────────────────────────────────
# Source: twells89/sigma-migration-skills @ a73f833
#   plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/dm_quarantine.rb
# Fix upstream and re-vendor; do not diverge this copy. Vendored for the
# standalone domo-sigma-migration repo (clone-safety) per the domo-build-pipeline plan.
# ─────────────────────────────────────────────────────────────────────────────
# frozen_string_literal: true
#
# dm_quarantine — pure element-quarantine logic for a failed / partially-broken
# DM POST (hackathon Rec5: ONE broken element must not lose the other N-1).
#
# The field regression: a DM spec with 5 elements where one view element carried
# 300 dependency-not-found column refs. The whole POST failed, and the tester
# hand-stripped elements to get a partial DM up. This module mechanizes that:
# identify the offending element(s) from (a) the API error text or (b) the
# post-POST /columns type=error census, remove them from the spec, and hand the
# caller a deferred-elements record to persist. The DM that results is PARTIAL
# by definition — post-and-readback.rb exits with a DISTINCT code and
# assert-phase6-ran.rb refuses GREEN while deferred-elements.json is non-empty.
#
# Pure Ruby, stdlib only, NO network — every function takes plain Hashes so the
# offline tests (scripts/test-dm-quarantine.rb) can drive it without an API.
module DmQuarantine
  module_function

  # Distinct exit code for "quarantined + partial DM posted" — chosen unused:
  # post-and-readback.rb already uses 1 (abort), 2 (type=error columns),
  # 3 (layout lint), 4 (control lint). Documented in that script's header.
  EXIT_QUARANTINED = 6

  # All elements of a DM spec → [{page_id:, el:}].
  def spec_elements(spec)
    (spec['pages'] || []).flat_map do |pg|
      (pg['elements'] || []).map { |el| { page_id: pg['id'], el: el } }
    end
  end

  # (a) Attribute a failed-POST API error to specific spec element(s).
  # Returns { ids: [element-id...], reasons: { id => "why" } } — empty ids when
  # the error names nothing attributable (caller must then fail loudly and
  # quarantine NOTHING; a blind guess would hide real breakage).
  #
  # Heuristics tuned to how Sigma DM POST errors surface today (message text in
  # the JSON/YAML body — post-and-readback parses it and aborts with .inspect):
  #   1. "[Element/...]" / "[Element/Rel/Col]" refs (dependency-not-found class)
  #      → blame the element(s) whose column formulas CONTAIN that reference,
  #        falling back to formulas referencing the same "[Element/" prefix.
  #   2. an element NAME or spec element ID mentioned verbatim → that element.
  #   3. "invalid identifier 'X'" (SQL compile class) → the kind:"sql"
  #      element(s) whose statement contains X.
  def offending_from_error(spec, error_payload)
    text = error_payload.is_a?(String) ? error_payload : JSON.generate(error_payload)
    els = spec_elements(spec)
    ids = []
    reasons = {}
    blame = lambda do |el, why|
      id = el['id']
      next if id.nil?
      ids << id unless ids.include?(id)
      reasons[id] ||= why
    end

    # 1. bracketed refs like [Name/Col] (or deeper) in the error text.
    text.scan(/\[([^\[\]\/]+)\/([^\[\]]+)\]/).each do |el_name, rest|
      ref = "[#{el_name}/#{rest}]"
      holders = els.select do |h|
        (h[:el]['columns'] || []).any? { |c| c['formula'].to_s.include?(ref) }
      end
      holders = els.select do |h|
        (h[:el]['columns'] || []).any? { |c| c['formula'].to_s.include?("[#{el_name}/") }
      end if holders.empty?
      # A base warehouse-table element's [TABLE/Col] formulas are SELF-refs
      # (normal); the same text in a view/sql element is a cross-element
      # dependency. When both match, blame the dependents, never the base —
      # quarantining the base would gut every surviving element.
      if holders.size > 1
        dependents = holders.reject { |h| h[:el].dig('source', 'kind') == 'warehouse-table' }
        holders = dependents if dependents.any?
      end
      holders = holders.reject { |h| (h[:el]['name'] || '') == el_name } if holders.size > 1
      holders.each { |h| blame.call(h[:el], "column formula references unresolved #{ref}") }
    end

    # 2. element names / ids mentioned verbatim. Bracket refs are rule 1's
    #    territory — strip them first so "[Deal Facts/…]" doesn't read as a
    #    mention of the base element. Longest names first, and each match is
    #    CONSUMED so "Deal Facts" can't re-match inside "Deal Facts View".
    mention_text = text.gsub(/\[([^\[\]\/]+)\/([^\[\]]+)\]/, ' ')
    els.sort_by { |h| -(h[:el]['name'].to_s.length) }.each do |h|
      nm = h[:el]['name'].to_s
      id = h[:el]['id'].to_s
      if !id.empty? && mention_text.include?(id)
        mention_text = mention_text.gsub(id, ' ')
        blame.call(h[:el], 'element id named in the API error')
      elsif nm.length >= 4 && mention_text.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(nm)}(?![A-Za-z0-9_])/)
        mention_text = mention_text.gsub(/(?<![A-Za-z0-9_])#{Regexp.escape(nm)}(?![A-Za-z0-9_])/, ' ')
        blame.call(h[:el], 'element name named in the API error')
      end
    end

    # 3. SQL compile errors naming an identifier → the sql element carrying it.
    text.scan(/invalid identifier\s+'?"?([A-Za-z0-9_ ]+)"?'?/i).flatten.uniq.each do |ident|
      els.each do |h|
        stmt = h[:el].dig('source', 'statement').to_s
        next if stmt.empty?
        blame.call(h[:el], "SQL compile error: invalid identifier '#{ident}'") if stmt.include?(ident)
      end
    end

    { ids: ids, reasons: reasons }
  end

  # (b) Attribute post-POST /columns type=error entries (live census) to SPEC
  # element ids. Live element ids can differ from spec ids, so the caller maps
  # live id → element NAME via the readback spec and passes those names here.
  # Entries whose elementId matches a spec id directly are also honored.
  def offending_from_error_columns(spec, error_columns, live_names_by_id = {})
    els = spec_elements(spec)
    ids = []
    reasons = {}
    Array(error_columns).each do |c|
      live_id = c['elementId'].to_s
      target = els.find { |h| h[:el]['id'] == live_id }
      if target.nil? && (nm = live_names_by_id[live_id])
        target = els.find { |h| h[:el]['name'] == nm }
      end
      next unless target
      id = target[:el]['id']
      ids << id unless ids.include?(id)
      reasons[id] ||= "live column #{(c['label'] || c['columnId']).inspect} resolved to type=error"
    end
    { ids: ids, reasons: reasons }
  end

  # Remove the named elements from a DEEP COPY of the spec. Also drops
  # relationships (on surviving elements) that target a removed element — a
  # dangling relationship would just re-fail the re-POST. Returns
  #   { spec: <cleaned>, deferred: [{pageId:, reason:, element:, removedRelationships: []}] }
  # deferred[] is what post-and-readback persists to deferred-elements.json.
  def quarantine(spec, ids, reasons = {})
    cleaned = JSON.parse(JSON.generate(spec)) # deep copy
    removed = []
    (cleaned['pages'] || []).each do |pg|
      keep = []
      (pg['elements'] || []).each do |el|
        if ids.include?(el['id'])
          removed << { 'pageId' => pg['id'], 'reason' => reasons[el['id']] || 'quarantined',
                       'element' => el, 'removedRelationships' => [] }
        else
          keep << el
        end
      end
      pg['elements'] = keep
    end
    (cleaned['pages'] || []).each do |pg|
      (pg['elements'] || []).each do |el|
        next unless el['relationships'].is_a?(Array)
        dangling, kept = el['relationships'].partition { |r| ids.include?(r['targetElementId']) }
        next if dangling.empty?
        el['relationships'] = kept
        el.delete('relationships') if kept.empty?
        holder = removed.find { |d| d['element']['id'] == dangling.first['targetElementId'] } || removed.first
        holder['removedRelationships'].concat(dangling.map { |r| r.merge('sourceElementId' => el['id']) }) if holder
      end
    end
    { spec: cleaned, deferred: removed }
  end

  # The persisted deferred-elements.json document.
  def deferred_doc(deferred, data_model_id: nil, spec_path: nil)
    { 'dataModelId' => data_model_id, 'spec' => spec_path,
      'note' => 'PARTIAL DM — these elements were quarantined at POST time. Fix them, restore into the spec, re-POST, then delete this file. assert-phase6-ran.rb blocks GREEN while it is non-empty.',
      'deferred' => deferred }.compact
  end
end
