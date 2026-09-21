# Shared helpers for the Domo→Sigma build scripts (build-dm.rb, build-workbook.rb).
# Kept in one place so display-name derivation is IDENTICAL across the DM columns
# and the workbook column references — a mismatch compiles Sigma columns to type
# "error" (case-sensitive same-element refs).

# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'ruby_compat'
module DomoSigma
  module_function

  # Clean a raw identifier to a Sigma display name (mirrors the converter's
  # sigmaDisplayName). Idempotent: display_name(display_name(x)) == display_name(x).
  def display_name(raw)
    s = raw.to_s
           .gsub(/([a-z])([A-Z])/, '\1_\2')
           .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
           .gsub(/([A-Za-z])([0-9])/, '\1_\2')
           .gsub(/([0-9])([A-Za-z])/, '\1_\2')
    s.split(%r{[_\s/.]+}).reject(&:empty?).map { |w|
      # Upcase the FIRST character only — never String#capitalize, which also
      # LOWERCASES the remainder. A dot is not a split boundary, so a dotted
      # column arrives as one token that still holds an internal capital:
      #   'Account.BillingState' -> camel-split -> ['Account.Billing', 'State']
      #   .capitalize            -> 'Account.billing State'   <- 'B' destroyed
      #   first-char-only        -> 'Account.Billing State'   <- matches Sigma
      # Sigma camel-splits the same way we do ('IsWon' -> 'Is Won' resolves
      # fine), so the dotted case was the ONLY divergence — and it 400'd the
      # data-model POST with "dependency not found: formula reference
      # 'pdp_example_dataset/account.billing state'" on a live cold run
      # (bead xo56). Column pre-flight could never catch it: it compares
      # display_name to display_name on both sides, so the two agreed with
      # each other while both disagreed with Sigma.
      (w =~ /\A[A-Z0-9]+\z/) ? w : w.sub(/\A./) { |c| c.upcase }
    }.join(' ')
  end

  # Kept as the single named seam for "the name used INSIDE a formula
  # reference", now that display_name itself can never emit a dot.
  #
  # Why the dot matters: Sigma resolves a reference case-insensitively and
  # treats underscore and space as equivalent ('created_on' == 'Created On',
  # '_BATCH_ID_' == 'BATCH ID' — both probed live), but a name carrying BOTH a
  # dot AND a space does NOT resolve:
  #   '[T/Account.Billing State]' -> 400 dependency not found
  #   '[T/Account Billing State]' -> resolves
  #   '[T/Account.BillingState]'  -> resolves
  # display_name used to produce the first form for a dotted warehouse column
  # like 'Account.BillingState', which 400'd BOTH the data-model POST (against
  # the warehouse column) and then the workbook POST (against the master
  # element's column of the same name). Splitting on '.' as well removes the
  # dot entirely and yields the second, resolving form everywhere.
  # Bead xo56, found on the 36-card cold run.
  def column_ref_name(raw)
    display_name(raw)
  end

  B62 = (('0'..'9').to_a + ('a'..'z').to_a + ('A'..'Z').to_a).freeze

  # Client-side id. Sigma preserves client IDs on CREATE (feedback_sigma_spec_id_stability).
  def rand_id(len = 10)
    Array.new(len) { B62.sample }.join
  end

  def inode_id(col)
    "inode-#{rand_id(22)}/#{col.to_s.upcase}"
  end

  # Master-column id from a display name — MUST match build-workbook-spec.rb's
  # auto-master slug (m-<slug>) so control filters can target the master column.
  def mcol_id(display)
    "m-#{display.to_s.downcase.gsub(/\W+/, '-').sub(/-$/, '')}"
  end

  # Domo number-format object → Sigma column format. Falls back to a name heuristic
  # (the same precedence the Tableau KPI emitter uses) ONLY to pick a category
  # (currency/percent/number) — never to build a format string.
  #
  # Sigma's released format schema uses d3 `formatString`; the old
  # `decimalPlaces` field is not in the schema and was silently stripped on
  # readback, leaving long raw decimals in every KPI. Preserve Domo's category,
  # precision, grouping, currency/percent multiplier, and abbreviated display.
  def sigma_format(domo_fmt, name = nil)
    raw_format = domo_fmt.is_a?(Hash) ? domo_fmt['format'].to_s : ''
    explicit_prec = domo_fmt.is_a?(Hash) && (domo_fmt['precision'] || domo_fmt['decimals'])
    inferred_prec = raw_format[/\.(0+)/, 1]&.length
    prec = (explicit_prec || inferred_prec || 0).to_i
    type = domo_fmt.is_a?(Hash) ? domo_fmt['type'].to_s.upcase : ''
    abbreviated = type == 'ABBREVIATED'
    category =
      case type
      when 'CURRENCY', 'MONEY'                            then :currency
      when 'PERCENT', 'PERCENTAGE'                        then :percent
      when 'COMMA', 'NUMBER', 'DECIMAL', 'LONG', 'DOUBLE'  then :number
      else
        n = name.to_s.downcase
        if    raw_format.include?('$') || n =~ /revenue|sales|profit|cost|amount|budget|price|\$/ then :currency
        elsif n =~ /rate|percent|pct|%|margin|ratio|share/            then :percent
        elsif abbreviated || !type.empty? || domo_fmt.is_a?(Hash)     then :number
        end
      end
    return nil unless category

    if abbreviated
      # Domo's 0.0 abbreviation keeps roughly four significant digits
      # (950.9K); d3's SI formatter is the released Sigma equivalent.
      sig = [prec + 3, 2].max
      prefix = category == :currency ? (domo_fmt['currency'] || '$').to_s : ''
      return { 'kind' => 'number', 'formatString' => "#{prefix}.#{sig}~s" }
    end

    format_string =
      case category
      when :percent then ",.#{prec}%"
      when :currency
        symbol = domo_fmt.is_a?(Hash) ? (domo_fmt['currency'] || '$').to_s : '$'
        "#{symbol},.#{prec}f"
      else ",.#{prec}f"
      end
    { 'kind' => 'number', 'formatString' => format_string }
  end

  # Does this column name look like a row-key / id (the Domo table-summary COUNT trap)?
  def id_like?(name)
    n = name.to_s.downcase
    n == 'id' || n =~ /(^|[_ ])id$/ || n =~ /\bkey$/ || n =~ /\buuid\b/
  end

  # C9: extract Domo PDP (personalized data permission) policies from a DataSet
  # metadata object (fetched with parts=core,permission). Returns [] when none —
  # the caller (build-dm.rb) must warn + stub, never silently drop row-level security.
  def detect_pdp(dataset)
    perm = dataset['permission'] || dataset['pdp'] || {}
    (perm['policies'] || []).map do |p|
      { 'id' => p['id'].to_s, 'name' => (p['name'] || p['id']).to_s,
        'predicates' => Array(p['predicates']) }
    end
  end

  # Merge Domo page-layout geometry onto each card record by id — ports
  # domo-capture-visuals.rb's normalize_layout coordinate extraction so
  # domo-discover.rb's --pages path (not just the OPTIONAL capture-visuals
  # script) hands build-domo-layout.rb real layout instead of forcing it to
  # auto-stack every card.
  #
  # Bug 5 (P0, refs/live-validation-2026-07-30.md): CLASSIC Domo pages carry NO
  # x/y/w/h pixel geometry anywhere. What a live `GET
  # /api/content/v3/stacks/{pageId}/cards` response (Domo.cards_for_page, the
  # PRIMARY card-enumeration route — see domo-discover.rb's
  # enumerate_page_cards) actually gives you for layout is:
  #
  #   sizes[]       = [{"id"=>"<cardId>", "size"=>"medium"}, ...]
  #                   — a T-SHIRT-SIZE TOKEN per card (small/medium/large/...),
  #                   NOT pixels or a column span number.
  #   collections[] = [{"id"=>.., "title"=>"Section Name", "description"=>..,
  #                      "minimized"=>false, "cardIndices"=>[0,1,2,3]}, ...]
  #                   — titled sections that group cards BY INDEX into the
  #                   stacks response's OWN `cards[]` array (NOT by card id).
  #                   An API-created page has collections: [] and just an
  #                   ordered `sizes[]` entry per card — no sections at all.
  #
  # This method merges THREE kinds of geometry onto each card record by id, and
  # keeps them independent so any can be present, absent, or combined:
  #
  #   - legacy 'x'/'y'/'w'/'h' (mason / Domo-App pages, pixel-ish grid coords)
  #     — sourced from `page_layout`, UNCHANGED behavior from before this fix.
  #   - 'x'/'y'/'w'/'h' can ALSO come from the newer pageLayoutV4 pass (Track C,
  #     refs/page-layout-v4.md), sourced from `stacks['pageLayoutV4']` via
  #     `merge_pagelayoutv4_geometry` — scaled ×0.4 from Domo's 60-wide grid.
  #     It is the more authoritative source and runs LAST among the two geometry
  #     passes, so when both are present it wins outright (all 4 keys set
  #     atomically together, never partially) over legacy `page_layout` geometry
  #     for the same card id.
  #   - '_size'        — the T-shirt token, from `stacks['sizes']`, keyed by
  #                       card id.
  #   - '_collection'  — {'id','title','index'} for the collection (if any)
  #                       this card falls in. `cardIndices` indexes the
  #                       response's visual `sizes[]` sequence; the analyzer
  #                       `cards[]`/definition-fetch order can differ wildly
  #                       (field run: 26/29 cards assigned to the wrong section
  #                       when those arrays were assumed identical). Omitted (never
  #                       defaulted) when the card's index isn't inside any
  #                       collection's `cardIndices` (e.g. collections: [] on
  #                       an API-created page).
  #   - '_pageOrder'   — that visual sizes[] index, ALWAYS attached whenever
  #                       `stacks` is given (regardless of collection
  #                       membership), so the layout builder has an explicit
  #                       ordering signal even on a page with zero collections.
  #
  # build-domo-layout.rb (owned by another agent) is the consumer of all of
  # this — this method only DEFINES and documents the shape on discovery's
  # output; it does not lay anything out itself.
  #
  # Pure/side-effect-free in all three passes: returns a NEW array; a card with
  # no matching entry in a given source is left unchanged by that source's pass
  # — 'x'/'y'/'w'/'h' are OMITTED, never defaulted to 0 (0 is a valid top-left
  # coordinate and must not be confused with "unknown").
  def merge_geometry(cards, page_layout, stacks: nil)
    out = Array(cards)
    out = merge_xywh_geometry(out, page_layout)
    out = merge_pagelayoutv4_geometry(out, stacks)
    out = merge_stacks_geometry(out, stacks)
    out
  end

  # --- pageLayoutV4 pass (v4-inline pages) — Track C, refs/page-layout-v4.md ---
  # stacks['pageLayoutV4'] (present once Domo.cards_for_page sends
  # includeV4PageLayouts=true — see domo_rest.rb) carries two arrays that must
  # be joined on contentKey: 'content' maps contentKey -> cardId (HEADER
  # entries carry a 'text' field and NO cardId — they're section dividers, not
  # cards, and are skipped here by the `next unless c['cardId']` guard).
  # 'standard.template' maps contentKey -> x/y/width/height on Domo's 60-wide
  # grid ('compact' is the 12-wide mobile grid — unused). PAGE_BREAK entries
  # appear in 'standard.template' with no 'content' counterpart at all and are
  # skipped the same way every unmatched contentKey is (`next unless card_id`).
  # Domo 60-wide -> Sigma 24-wide grid is x0.4. build_dashboard (rung 1,
  # build-domo-layout.rb) only ever consumes x/y/w/h as relative percentages
  # of their own page's max, so this scale factor doesn't change its output —
  # but storing genuinely Sigma-comparable units here keeps the record correct
  # for any other consumer, and matches what was actually verified live.
  def merge_pagelayoutv4_geometry(cards, stacks)
    v4 = stacks.is_a?(Hash) ? stacks['pageLayoutV4'] : nil
    return cards unless v4.is_a?(Hash)

    content_map = {}
    Array(v4['content']).each do |c|
      next unless c.is_a?(Hash) && c['cardId']
      content_map[c['contentKey'].to_s] = c['cardId'].to_s
    end
    return cards if content_map.empty?

    geom_by_id = {}
    Array(v4.dig('standard', 'template')).each do |t|
      next unless t.is_a?(Hash)
      card_id = content_map[t['contentKey'].to_s]
      next unless card_id
      next if [t['x'], t['y'], t['width'], t['height']].any?(&:nil?)
      geom_by_id[card_id] = {
        'x' => (t['x'].to_f     * 0.4).round(2),
        'y' => (t['y'].to_f     * 0.4).round(2),
        'w' => (t['width'].to_f  * 0.4).round(2),
        'h' => (t['height'].to_f * 0.4).round(2),
      }
    end

    cards.map do |card|
      next card unless card.is_a?(Hash)
      geom = geom_by_id[card['id'].to_s]
      geom ? card.merge(geom) : card
    end
  end

  # Preserve the non-card content PageLayoutV4 exposes. HEADER and PAGE_BREAK
  # are real authored page semantics, not phantom cards: the workbook builder
  # emits released `text` / `page-break` elements from these records and the
  # Domo layout adapter places them at this geometry. Unknown v4 template
  # types stay out until their meaning is grounded.
  def pagelayoutv4_content(stacks, page_id)
    v4 = stacks.is_a?(Hash) ? stacks['pageLayoutV4'] : nil
    return [] unless v4.is_a?(Hash)

    content_by_key = Array(v4['content']).each_with_object({}) do |content, out|
      out[content['contentKey'].to_s] = content if content.is_a?(Hash)
    end
    Array(v4.dig('standard', 'template')).filter_map do |template|
      next unless template.is_a?(Hash)
      type = template['type'].to_s.upcase
      next unless %w[HEADER PAGE_BREAK].include?(type)
      next if [template['x'], template['y'], template['width'], template['height']].any?(&:nil?)

      key = template['contentKey'].to_s
      source = content_by_key[key] || {}
      slug_type = type.downcase.tr('_', '-')
      {
        'id' => "domo-layout-#{page_id}-#{slug_type}-#{key}".gsub(/[^a-zA-Z0-9_-]/, '-')[0, 64],
        'type' => slug_type,
        'text' => source['text'],
        'x' => (template['x'].to_f * 0.4).round(2),
        'y' => (template['y'].to_f * 0.4).round(2),
        'w' => (template['width'].to_f * 0.4).round(2),
        'h' => (template['height'].to_f * 0.4).round(2)
      }.compact
    end
  end

  # --- x/y/w/h pass (mason / Domo-App pages) — unchanged from before Bug 5 --
  def merge_xywh_geometry(cards, page_layout)
    return cards unless page_layout.is_a?(Hash)

    raw_cards = page_layout['cards'] || []
    geom_by_id = {}
    Array(raw_cards).each do |c|
      next unless c.is_a?(Hash)
      id = c['id'] || c['cardId'] || c['urn']
      next unless id
      geom = c['layout'].is_a?(Hash) ? c['layout'] : c # geometry sometimes nested under "layout"
      geom_by_id[id.to_s] = {
        'x' => geom['x']     || geom['col']    || geom['gridX'],
        'y' => geom['y']     || geom['row']    || geom['gridY'],
        'w' => geom['w']     || geom['width']  || geom['colSpan'] || geom['sizeX'],
        'h' => geom['h']     || geom['height'] || geom['rowSpan'] || geom['sizeY'],
      }
    end

    cards.map do |card|
      next card unless card.is_a?(Hash)
      geom = geom_by_id[card['id'].to_s]
      next card unless geom
      coords = geom.each_with_object({}) { |(k, v), h| h[k] = v.to_i unless v.nil? }
      coords.empty? ? card : card.merge(coords)
    end
  end

  # --- sizes[] / collections[] pass (classic pages) — Bug 5 -----------------
  def merge_stacks_geometry(cards, stacks)
    return cards unless stacks.is_a?(Hash)

    size_by_id = {}
    ordered_ids = []
    Array(stacks['sizes']).each do |s|
      next unless s.is_a?(Hash) && s['id']
      id = s['id'].to_s
      ordered_ids << id
      size_by_id[id] = s['size']
    end
    if ordered_ids.empty?
      ordered_ids = Array(cards).each_with_object([]) do |card, out|
        out << card['id'].to_s if card.is_a?(Hash) && card['id']
      end
    end
    order_by_id = ordered_ids.each_with_index.to_h

    collection_by_id = {}
    Array(stacks['collections']).each do |col|
      next unless col.is_a?(Hash)
      Array(col['cardIndices']).each do |idx|
        card_id = ordered_ids[idx.to_i]
        next unless card_id
        collection_by_id[card_id] = {
          'id' => col['id'], 'title' => col['title'], 'index' => idx.to_i
        }
      end
    end

    cards.each_with_index.map do |card, idx|
      next card unless card.is_a?(Hash)
      extra = {}
      card_id = card['id'].to_s
      size = size_by_id[card_id]
      extra['_size'] = size if size
      coll = collection_by_id[card_id]
      extra['_collection'] = coll if coll
      extra['_pageOrder'] = order_by_id.fetch(card_id, idx)
      extra.empty? ? card : card.merge(extra)
    end
  end
end
