#!/usr/bin/env ruby
# frozen_string_literal: true
#
# mechanical-specs.rb — the DETERMINISTIC Tableau→Sigma spec generator.
#
# Makes Tableau→Sigma spec generation MECHANICAL (no agent hand-authoring in the
# happy path). It chains the EXISTING building blocks:
#   convert_tableau_to_sigma (build/tableau.js)  → the Sigma DATA MODEL spec
#   parse-twb-layout.rb                          → per-dashboard zone signals
#   build-charts-from-signals.rb                 → Sigma chart-element specs
# and supplies the glue that previously forced an agent to step in:
#
#   * DM spec — the converter output IS the DM spec (schemaVersion:1 already set).
#     fixup_dm_spec() resolves the references the converter leaves unresolved
#     (raw-table-name prefixes on derived elements + Tableau internal-GUID sibling
#     refs) and DROPS calc columns that still can't resolve (unknown functions /
#     unresolved refs) so the live POST doesn't error-type. Dropped calcs are
#     returned for the orchestrator to surface as OPEN QUESTIONS.
#
#   * master-map — build-charts needs a regex→{id,name,format} map from CSV-
#     header / shelf-caption text to workbook-master column ids. derive_master()
#     DERIVES it from the converter fact element (its columns + metrics), exactly
#     mirroring how migrate-powerbi.rb derives master-map.json. Each fact column
#     display name D → master column {id:"m-<slug D>", name:D, formula:"[<Fact>/D]"}
#     and a header regex (agg-prefix tolerant). Aggregate calc metrics (Return
#     Rate, Gross Margin Pct) → a master-map entry carrying a verbatim `formula`
#     that build-charts emits straight onto the chart measure.
#
#   * workbook — build_wb_spec() wraps a hidden master table (sourcing the DM
#     fact element) + the build-charts elements into a POST-ready workbook spec.
require 'set'
require 'json'
require 'open3'

module MechanicalSpecs
  module_function

  LOWER = %w[a an and as at but by for in nor of on or so the to up yet via vs].freeze

  # Sigma's display-name derivation for a SNAKE_CASE / camelCase identifier.
  def display_name(s)
    norm = (s || '').gsub(/([a-z])([A-Z])/, '\\1_\\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
    words = norm.downcase.split('_').reject(&:empty?)
    words.each_with_index.map { |w, i| (i.zero? || !LOWER.include?(w)) ? w.capitalize : w }.join(' ')
  end

  # Display name of a converter column: explicit `name`, else the LAST path
  # segment of the formula. "[A/B/Category]" -> "Category".
  def col_display(col)
    return col['name'] if col['name'] && !col['name'].to_s.empty?
    f = col['formula'].to_s
    m = f.match(/\[([^\]]+)\]\s*$/)
    return nil unless m
    m[1].split('/').last
  end

  def slug(s)
    s.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')
  end

  # A header-matching regex for a display name that ALSO tolerates a Tableau CSV
  # aggregation prefix ("Sum of X", "Distinct count of X", ...), the dotted
  # short-agg form ("Avg. Days To Ship" — bead z1d0/320u), and a date-part
  # prefix ("Month of Order Date" / "Week of Order Date" — bead ovud: date-axis
  # headers must resolve to the underlying date master column). build-charts
  # passes the raw CSV header to map_column, so every prefix must be optional.
  def header_regex(dname)
    '(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of ' \
      '|(?:avg|sum|min|max|med|cnt|ctd)\.\s*' \
      '|(?:second|minute|hour|day|week|month|quarter|year) of ' \
      ")?#{Regexp.escape(dname)}$"
  end

  # A pure-GUID display name is an internal converter artifact, never a CSV header.
  GUID_RE = /\A[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\z/i

  # Strip a cross-element calc col's disambiguating suffix:
  #   "Region (STORE_DIM (CSA.STORE_DIM))" -> "Region".
  def base_caption(dname)
    b = dname.to_s.sub(/\s*\([A-Z0-9_]+ \([^)]*\)\)\s*\z/, '').strip
    b.empty? ? nil : b
  end

  def formula_has_guid_ref?(formula)
    formula.to_s =~ /\[[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\]/i
  end

  # Map each Tableau internal field GUID -> its master display name. The
  # converter encodes the raw warehouse column name (a UUID-shaped Tableau field
  # id) as the suffix of the column's sigma inode id ("inode-<hash>/<RAW_UUID>"),
  # so GUID 7b7dc9c3-... in a formula == the column whose inode tail is 7B7DC9C3-.
  def guid_display_index(*elements)
    idx = {}
    elements.compact.each do |el|
      (el['columns'] || []).each do |c|
        tail = c['id'].to_s.split('/').last
        next unless tail =~ /\A[0-9A-F-]{20,}\z/i
        dn = col_display(c)
        idx[tail.downcase] = dn if dn
      end
    end
    idx
  end

  # Rewrite a metric formula: GUID refs -> [Master/<display>], remaining bare
  # [Col] refs -> [Master/Col]. Returns nil if any GUID stays unresolved.
  def rewrite_metric_formula(formula, guid_idx)
    f = formula.to_s.dup
    f = f.gsub(/\[([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/i) do
      dn = guid_idx[Regexp.last_match(1).downcase]
      dn ? "[Master/#{dn}]" : Regexp.last_match(0)
    end
    return nil if formula_has_guid_ref?(f)
    f.gsub(/\[([^\/\]]+)\]/) { "[Master/#{Regexp.last_match(1)}]" }
  end

  def all_elements(model)
    (model['pages'] || []).flat_map { |p| p['elements'] || [] }
  end

  def elem_name(e)
    e['name'] || display_name((e.dig('source', 'path') || []).last.to_s)
  end

  # Pick the CHART-READY fact element. The converter builds a derived "<Fact>
  # View" element (kind:table sourcing the base fact) that DENORMALIZES every
  # cross-element + calc column the dashboards plot — base warehouse-table
  # elements carry only their own physical columns. So prefer the largest derived
  # view that is NOT a *Dim; fall back to a base warehouse-table fact otherwise.
  def pick_fact(model)
    els = all_elements(model)
    return nil if els.empty?
    # A dimension element's name is "<X> Dim" (trailing) OR "Dim <X>" (leading,
    # e.g. "Dim Time") — exclude BOTH so a narrow date/time dim can never be
    # chosen as the fact (the date-crosstab regression: "Dim Time" slipped past a
    # trailing-only / Dim$/ and won max_by, making the workbook master source the
    # wrong element).
    dim_re = /(^Dim\b| Dim$)/i
    derived = els.select { |e| e.dig('source', 'kind') == 'table' && e.dig('source', 'elementId') }
                 .reject { |e| elem_name(e) =~ dim_re }
    return derived.max_by { |e| (e['columns'] || []).size } if derived.any?
    base = els.select { |e| e.dig('source', 'kind') == 'warehouse-table' }
    return nil if base.empty?
    facts = base.reject { |e| elem_name(e) =~ dim_re }
    (facts.empty? ? base : facts).max_by { |e| (e['columns'] || []).size }
  end

  # The base element a derived view sources (for harvesting its metrics, which
  # don't propagate to derived elements). Returns nil for a base fact.
  def base_of(model, fact_el)
    src_eid = fact_el.dig('source', 'elementId')
    return nil unless src_eid
    all_elements(model).find { |e| e['id'] == src_eid }
  end

  # Run the Tableau→Sigma converter via a node shim importing build/tableau.js.
  def run_converter(twb_path:, conn:, db:, schema:, mcp_build:, workdir:)
    shim = File.join(workdir, '_convert_tableau.mjs')
    raw_out = File.join(workdir, 'dm-raw.json')
    meta_out = File.join(workdir, 'conv-meta.json')
    File.write(shim, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { convertTableauToSigma } from #{mcp_build.to_json};
      const xml = readFileSync(#{twb_path.to_json}, 'utf8');
      const out = convertTableauToSigma(xml, {
        connectionId: #{conn.to_json},
        database: #{db.to_json},
        schema: #{schema.to_json},
      });
      const bare = out.model || out.sigmaDataModel || out;
      writeFileSync(#{raw_out.to_json}, JSON.stringify(bare, null, 2));
      // Capture out.security too — detected RLS/CLS rules (architecture B:
      // reported, not injected). Dropping it here is how RLS silently
      // vanished from the orchestrated path; the orchestrator now gates on it.
      writeFileSync(#{meta_out.to_json}, JSON.stringify({ model: bare, warnings: out.warnings || [], stats: out.stats || {}, security: out.security || [] }, null, 2));
    JS
    o, e, st = Open3.capture3('node', shim)
    raise "converter failed: #{e}#{o}" unless st.success?
    JSON.parse(File.read(meta_out))
  end

  # Tableau functions that cannot survive as a DM CALC COLUMN (fallback when
  # the SigmaFunctions lib isn't loadable). NB: the window/table-calc family
  # (WINDOW_* / RUNNING_* / RANK / INDEX / LOOKUP / TOTAL) IS auto-translated —
  # but only as CHART-element viz formulas by build-charts-from-signals.rb
  # (refs/window-functions.md, WINPROBE-validated). A converter-emitted DM calc
  # column still carrying one of these names is untranslated leakage and must
  # be dropped here (window functions silently error in DM calc columns).
  def unknown_functions(formula)
    if defined?(SigmaFunctions) && SigmaFunctions.respond_to?(:unknown_functions)
      return SigmaFunctions.unknown_functions(formula)
    end
    %w[DATEPARSE MAKEDATE MAKEDATETIME WINDOW_SUM WINDOW_AVG WINDOW_MIN WINDOW_MAX
       WINDOW_COUNT WINDOW_MEDIAN WINDOW_PERCENTILE WINDOW_STDEV WINDOW_CORR
       RUNNING_SUM RUNNING_AVG RUNNING_COUNT RUNNING_MIN RUNNING_MAX
       RANK RANK_DENSE RANK_PERCENTILE INDEX LOOKUP PREVIOUS_VALUE SIZE TOTAL
       SCRIPT_REAL SCRIPT_STR MODEL_QUANTILE MODEL_PERCENTILE].select { |fn| formula.to_s =~ /\b#{fn}\s*\(/i }
  end

  # ---- caption hygiene (bead 320u) ------------------------------------------
  # Tableau captions can carry trailing/leading whitespace ("Order Date ").
  # Sigma TRIMS display names server-side, so an untrimmed ref
  # `[Order Fact View/Order Date ]` errors "Dependency not found" against the
  # trimmed readback label. Trim every element/column/metric name AND every
  # bracketed-ref segment in every formula, model-wide, before anything else
  # consumes the names.
  def trim_ref_segments(formula)
    formula.to_s.gsub(/\[([^\]]+)\]/) do
      "[#{Regexp.last_match(1).split('/', -1).map(&:strip).join('/')}]"
    end
  end

  def trim_spec_whitespace!(model)
    n = 0
    all_elements(model).each do |el|
      if el['name'].is_a?(String) && el['name'] != el['name'].strip
        el['name'] = el['name'].strip
        n += 1
      end
      ((el['columns'] || []) + (el['metrics'] || [])).each do |c|
        if c['name'].is_a?(String) && c['name'] != c['name'].strip
          c['name'] = c['name'].strip
          n += 1
        end
        next unless c['formula']
        t = trim_ref_segments(c['formula'])
        if t != c['formula']
          c['formula'] = t
          n += 1
        end
      end
      (el['relationships'] || []).each do |r|
        if r['name'].is_a?(String) && r['name'] != r['name'].strip
          r['name'] = r['name'].strip
          n += 1
        end
      end
    end
    n
  end

  # ---- relationship-name dedupe (bead ovud) ----------------------------------
  # A fact with 2+ FKs to ONE dim (ship/return/order date → DATE_DIM) gets 2+
  # relationships ALL NAMED after the dim table. Cross-element refs resolve via
  # the relationship NAME ([Base/REL_NAME/Field]), so duplicate names make every
  # join after the first unreachable — the derived view's dim columns silently
  # bind to one arbitrary join (date axes NULL-bucket). Fix: role-based unique
  # names ("DATE_DIM (Ship Date)") derived from the source FK column, and
  # rewrite the derived-element refs round-robin (the converter emits one
  # column block per join instance, in relationship order).
  def dedupe_relationship_names!(model)
    els = all_elements(model)
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
    renamed = []
    els.each do |el|
      rels = el['relationships'] || []
      next if rels.empty?
      cols_by_id = (el['columns'] || []).each_with_object({}) { |c, h| h[c['id']] = c }
      rels.group_by { |r| r['name'] }.each do |name, group|
        next if name.to_s.empty? || group.size < 2
        old_name = name
        group.each do |r|
          src_col = cols_by_id[r.dig('keys', 0, 'sourceColumnId')]
          role = src_col && col_display(src_col)
          role = role.to_s.sub(/\s+Key\z/i, '').strip
          r['name'] = role.empty? ? "#{old_name} (#{r['id']})" : "#{old_name} (#{role})"
        end
        # Disambiguate any residual collisions (two FKs with the same display).
        seen = Hash.new(0)
        group.each do |r|
          seen[r['name']] += 1
          r['name'] = "#{r['name']} #{seen[r['name']]}" if seen[r['name']] > 1
        end
        renamed << { element: el, old: old_name, rels: group }
      end
    end
    # Rewrite cross-element refs that used a now-renamed relationship name.
    # The converter denormalizes one column block PER JOIN INSTANCE in
    # relationship order, so the k-th duplicate of a given [BASE/OLD/Field]
    # formula belongs to the k-th renamed relationship.
    renamed.each do |rn|
      base_el = rn[:element]
      base_names = [base_el['name'],
                    display_name((base_el.dig('source', 'path') || []).last.to_s),
                    (base_el.dig('source', 'path') || []).last].compact.uniq.reject(&:empty?)
      els.each do |el|
        next if el['id'] == base_el['id']
        seen_per_formula = Hash.new(0)
        (el['columns'] || []).each do |c|
          f = c['formula'].to_s
          base = base_names.find { |b| f.start_with?("[#{b}/#{rn[:old]}/") }
          next unless base
          k = seen_per_formula[f]
          seen_per_formula[f] += 1
          rel = rn[:rels][k] || rn[:rels].last
          c['formula'] = f.sub("[#{base}/#{rn[:old]}/", "[#{base}/#{rel['name']}/")
        end
      end
    end
    renamed.size
  end

  # ---- relationship reachability assert (bead ovud, post-fixup guard) --------
  # Every cross-element ref middle segment ([Base/REL/Field]) must name a
  # relationship that exists on the base element, and relationship names must be
  # unique per element. Returns an array of violation strings (empty = clean).
  # Run BEFORE the DM POST so an unreachable join fails loudly instead of
  # NULL-bucketing every chart grouped through it.
  def relationship_reachability_violations(model)
    els = all_elements(model)
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
    out = []
    els.each do |el|
      names = (el['relationships'] || []).map { |r| r['name'] }
      counts = names.each_with_object(Hash.new(0)) { |n, h| h[n] += 1 }
      dupes = counts.select { |_, v| v > 1 }.keys
      dupes.each { |d| out << "element '#{elem_name(el)}': #{names.count(d)} relationships share the name #{d.inspect} — joins after the first are unreachable" }
    end
    els.each do |el|
      src_el = el.dig('source', 'elementId') && by_id[el.dig('source', 'elementId')]
      next unless src_el
      rel_names = (src_el['relationships'] || []).map { |r| r['name'] }.compact
      base_names = [src_el['name'], display_name((src_el.dig('source', 'path') || []).last.to_s),
                    (src_el.dig('source', 'path') || []).last].compact.uniq.reject(&:empty?)
      (el['columns'] || []).each do |c|
        f = c['formula'].to_s
        m = f.match(/\A\[([^\/\]]+)\/([^\/\]]+)\/([^\]]+)\]\z/)
        next unless m
        next unless base_names.include?(m[1])
        next if rel_names.include?(m[2])
        out << "derived column #{(col_display(c) || c['id']).inspect} refs relationship #{m[2].inspect} which does not exist on '#{elem_name(src_el)}' (have: #{rel_names.join(', ')})"
      end
    end
    out
  end

  # ---- computed-key join recovery (bead ovud) ---------------------------------
  # The converter SKIPS Tableau joins whose key is a computed expression
  # (`DATE([Order Date]) = [Date Key]`) — Sigma relationships join on columns.
  # Two mechanical recoveries:
  #   (a) the fact element CARRIES the wrapped column → add a calc key column
  #       (`Date([Order Date])`) and a relationship keyed on it.
  #   (b) the wrapped column is VDS-only (not in the converter output / real
  #       warehouse table) but the warehouse fact has "<CAPTION>_KEY"
  #       (ORDER_DATE → ORDER_DATE_KEY) and the model already joins another
  #       "* Date Key" FK to a date dim → add the missing base FK column, a
  #       role-named relationship to that same dim element, AND a derived-view
  #       date column named after the original caption ("Order Date" =
  #       [FACT/DATE_DIM (Order Date)/Full Date]) so date-axis headers
  #       ("Month of Order Date") resolve. Without this every date axis
  #       NULL-buckets (the FATSCALE rehearsal failure).
  # real_cols: { "TABLE" => [physical names] } from Phase 2. dim_catalogs:
  # { "TABLE" => [{'name','type'}] } for picking the dim's date payload column.
  # Returns an array of human-readable action messages.
  def recover_computed_key_joins!(model, twb_xml, real_cols, dim_catalogs = {})
    msgs = []
    els = all_elements(model)
    fact = els.select { |e| e.dig('source', 'kind') == 'warehouse-table' }
              .reject { |e| elem_name(e) =~ / Dim$/i }
              .max_by { |e| (e['columns'] || []).size }
    return msgs unless fact
    fact_table = (fact.dig('source', 'path') || []).last.to_s
    derived = els.find { |e| e.dig('source', 'elementId') == fact['id'] }

    # guid -> caption from the .twb column metadata.
    cap_by_guid = {}
    twb_xml.scan(/<column[^>]*caption='([^']*)'[^>]*name='\[([0-9a-f-]{36})[^']*\]'/i) do |cap, guid|
      cap_by_guid[guid.downcase] ||= cap.gsub('&quot;', '"').strip
    end
    twb_xml.scan(/<column[^>]*name='\[([0-9a-f-]{36})[^']*\]'[^>]*caption='([^']*)'/i) do |guid, cap|
      cap_by_guid[guid.downcase] ||= cap.gsub('&quot;', '"').strip
    end

    # Computed-key join expressions: one side FUNC([guid]), other side [guid].
    joins = twb_xml.scan(%r{<expression op='='>\s*<expression op='([A-Z_]+)\(\[([0-9a-f-]{36})\][^']*'\s*/>\s*<expression op='\[([0-9a-f-]{36})[^']*\]'\s*/>\s*</expression>}i)
    joins += twb_xml.scan(%r{<expression op='='>\s*<expression op='\[([0-9a-f-]{36})[^']*\]'\s*/>\s*<expression op='([A-Z_]+)\(\[([0-9a-f-]{36})\][^']*'\s*/>\s*</expression>}i)
                    .map { |a, fn, b| [fn, b, a] }
    fn_map = { 'DATE' => 'Date', 'DATETIME' => 'Date' }

    joins.each do |fn, src_guid, _tgt_guid|
      sigma_fn = fn_map[fn.to_s.upcase]
      next unless sigma_fn
      caption = cap_by_guid[src_guid.downcase]
      next if caption.nil? || caption.empty?
      slug_cap = slug(caption)
      fact_cols = fact['columns'] || []
      has_caption_col = fact_cols.any? { |c| col_display(c).to_s.casecmp?(caption) }

      # Pick the date-dim join to mirror: an existing fact relationship whose
      # source FK display ends in "Date Key" (ship/return date FKs).
      cols_by_id = fact_cols.each_with_object({}) { |c, h| h[c['id']] = c }
      mirror = (fact['relationships'] || []).find do |r|
        sc = cols_by_id[r.dig('keys', 0, 'sourceColumnId')]
        sc && col_display(sc).to_s =~ /Date Key\z/i
      end

      if has_caption_col && mirror
        # (a) calc key column + relationship.
        key_id = "c-#{slug_cap}-join-key"
        unless fact_cols.any? { |c| c['id'] == key_id }
          fact['columns'] << { 'id' => key_id, 'name' => "#{caption} Join Key",
                               'formula' => "#{sigma_fn}([#{caption}])" }
          fact['order'] << key_id if fact['order']
        end
        mirror_tgt = els.find { |e| e['id'] == mirror['targetElementId'] }
        rel_name = "#{(mirror_tgt&.dig('source', 'path') || []).last.to_s.upcase} (#{caption})"
        fact['relationships'] << { 'id' => "rel-#{slug_cap}", 'name' => rel_name,
                                   'targetElementId' => mirror['targetElementId'],
                                   'keys' => [{ 'sourceColumnId' => key_id,
                                                'targetColumnId' => mirror.dig('keys', 0, 'targetColumnId') }] }
        msgs << "computed-key join recovered (calc key): #{fact_table} → rel '#{rel_name}' on #{sigma_fn}([#{caption}])"
        next
      end

      # (b) VDS-only column: recover via the physical "<CAPTION>_KEY" FK.
      phys_key = "#{caption.gsub(/\s+/, '_').upcase}_KEY"
      real_fact = (real_cols || {})[fact_table.upcase] || []
      next unless real_fact.map { |c| c.to_s.upcase }.include?(phys_key) && mirror
      key_disp = display_name(phys_key) # "Order Date Key"
      key_col = fact_cols.find { |c| col_display(c).to_s.casecmp?(key_disp) }
      unless key_col
        key_col = { 'id' => "c-#{slug(key_disp)}", 'name' => key_disp,
                    'formula' => "[#{fact_table}/#{key_disp}]" }
        fact['columns'] << key_col
        fact['order'] << key_col['id'] if fact['order']
      end
      tgt_el = els.find { |e| e['id'] == mirror['targetElementId'] }
      dim_table = (tgt_el&.dig('source', 'path') || []).last.to_s
      rel_name = "#{dim_table.upcase} (#{caption})"
      unless (fact['relationships'] || []).any? { |r| r['name'] == rel_name }
        fact['relationships'] << { 'id' => "rel-#{slug_cap}", 'name' => rel_name,
                                   'targetElementId' => mirror['targetElementId'],
                                   'keys' => [{ 'sourceColumnId' => key_col['id'],
                                                'targetColumnId' => mirror.dig('keys', 0, 'targetColumnId') }] }
      end
      # Date payload column for the derived view, named after the ORIGINAL
      # caption so chart headers ("Month of Order Date") resolve to it.
      payload = ((dim_catalogs[dim_table.upcase] || []).find { |c| c['type'].to_s =~ /date/i } || {})['name']
      payload_disp = payload ? display_name(payload) : 'Full Date'
      base_seg = (fact['name'] && !fact['name'].to_s.empty?) ? fact['name'] : fact_table
      if derived && !(derived['columns'] || []).any? { |c| col_display(c).to_s.casecmp?(caption) }
        dcol = { 'id' => "c-#{slug_cap}", 'name' => caption,
                 'formula' => "[#{base_seg}/#{rel_name}/#{payload_disp}]" }
        derived['columns'] << dcol
        derived['order'] << dcol['id'] if derived['order']
      end
      msgs << "computed-key join recovered (physical FK): #{fact_table}.#{key_disp} → rel '#{rel_name}'; derived date column '#{caption}' = [#{base_seg}/#{rel_name}/#{payload_disp}]"
    end
    msgs
  end

  # ---- base-calc exposure (bead ovud/3w4d follow-through) ---------------------
  # The converter keeps single-table calc columns (Ship Speed Category =
  # If([Days To Ship] <= 2, ...)) on the BASE fact element, but the workbook
  # master sources the DERIVED "<Fact> View" — a column not re-exposed there is
  # unreachable and its chart dim falls back to an unresolvable raw header.
  # Append a passthrough ref on the derived view for every base calc column
  # that isn't already exposed. Idempotent.
  def expose_base_calcs_on_derived!(model)
    els = all_elements(model)
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
    added = 0
    els.each do |el|
      src = el.dig('source', 'elementId') && by_id[el.dig('source', 'elementId')]
      next unless src && src.dig('source', 'kind') == 'warehouse-table'
      src_name = src['name'] && !src['name'].to_s.empty? ? src['name'] : display_name((src.dig('source', 'path') || []).last.to_s)
      have = (el['columns'] || []).map { |c| col_display(c).to_s.downcase }
      (src['columns'] || []).each do |c|
        f = c['formula'].to_s
        next if f.empty? || f =~ /\A\[[^\]]+\]\z/ # bare base refs are already exposed
        lbl = (c['name'] || col_display(c)).to_s.strip
        next if lbl.empty? || have.include?(lbl.downcase)
        nid = "c-#{slug(lbl)}-dv"
        el['columns'] << { 'id' => nid, 'name' => lbl, 'formula' => "[#{src_name}/#{lbl}]" }
        el['order'] << nid if el['order']
        have << lbl.downcase
        added += 1
      end
    end
    added
  end

  # DM-spec fixup (mechanical). See module doc. Returns
  #   { fixed: <n formulas rewritten>, dropped: [<dropped calc display names>] }.
  # real_columns: optional { "TABLE" => Set/Array of UPPER physical column names }
  # discovered live from the warehouse (Phase 2). When supplied, base
  # warehouse-table columns whose physical name is NOT in the real table are
  # DROPPED as phantom (Tableau virtual-connection flattening invents columns
  # like "REGION (STORE_DIM (CSA.STORE_DIM))" that don't exist in ORDER_FACT).
  def fixup_dm_spec(model, real_columns = nil)
    begin
      require 'set'
      $LOAD_PATH.unshift File.expand_path('lib', __dir__)
      require 'sigma_functions'
    rescue LoadError, StandardError
      # fall back to the mini-blocklist in unknown_functions
    end
    real = {}
    (real_columns || {}).each { |t, cols| real[t.to_s.upcase] = cols.map { |c| c.to_s.upcase }.to_set }
    # Caption hygiene FIRST (bead 320u): Sigma trims display names server-side,
    # so trailing-space captions must be trimmed everywhere refs are built.
    trim_spec_whitespace!(model)
    # Role-based unique relationship names (bead ovud): multi-FK-to-one-dim
    # duplicate names make joins unreachable and date axes NULL-bucket.
    dedupe_relationship_names!(model)
    # Re-expose base-fact calc columns on the derived view so chart dims like
    # "Ship Speed Category" resolve through the master.
    expose_base_calcs_on_derived!(model)
    els = all_elements(model)
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
    guid_idx = guid_display_index(*els)
    fixed = 0
    dropped = []
    # Stamp a display name on every base warehouse-table element that lacks one,
    # so the DM readback returns a concrete element name (master-column formulas
    # and validate-spec --dm-context both key on element name). kind:sql elements
    # MUST stay nameless (spec rule 3) — skip those.
    els.each do |e|
      next if e['name'] && !e['name'].to_s.empty?
      next unless e.dig('source', 'kind') == 'warehouse-table'
      tbl = (e.dig('source', 'path') || []).last.to_s
      e['name'] = display_name(tbl) unless tbl.empty?
    end
    phantom = 0
    dropped_col_ids = Set.new
    dropped_disp_by_el = Hash.new { |h, k| h[k] = Set.new } # element id -> dropped display names
    unless real.empty?
      els.each do |el|
        next unless el.dig('source', 'kind') == 'warehouse-table'
        tbl = (el.dig('source', 'path') || []).last.to_s.upcase
        rc = real[tbl]
        next unless rc
        keep = []
        drop = {}
        (el['columns'] || []).each do |c|
          # Physical warehouse name = the formula tail mapped to UPPER_SNAKE, OR
          # the inode-id tail. A base col formula is "[TABLE/Display Name]".
          tail = c['formula'].to_s[/\[([^\]]+)\]\s*$/, 1]
          phys = tail ? tail.split('/').last.gsub(/\s+/, '_').upcase : nil
          # Only drop pure base-column refs (formula is exactly [TABLE/x]); never
          # drop a calc column (it has functions / multiple refs).
          is_base_ref = c['formula'].to_s =~ /\A\[#{Regexp.escape((el.dig('source','path')||[]).last.to_s)}\/[^\]]+\]\z/
          if is_base_ref && phys && !rc.include?(phys)
            drop[c['id']] = true
            dn = col_display(c)
            dropped_disp_by_el[el['id']] << dn if dn
            phantom += 1
          else
            keep << c
          end
        end
        if drop.any?
          el['columns'] = keep
          el['order'] = (el['order'] || []).reject { |id| drop[id] } if el['order']
          dropped_col_ids.merge(drop.keys)
        end
      end
      # Drop relationships whose key columns were filtered out as phantom (a
      # virtual-connection relationship keyed on a flattened column that does
      # not exist in the real table) — Sigma rejects dangling relationship keys.
      els.each do |el|
        next unless el['relationships']
        el['relationships'] = el['relationships'].reject do |r|
          (r['keys'] || []).any? do |k|
            dropped_col_ids.include?(k['sourceColumnId']) || dropped_col_ids.include?(k['targetColumnId'])
          end
        end
      end
      # Cascade: a derived element column that is a bare single ref to a dropped
      # base column ("[Src/<droppedName>]") can no longer resolve — drop it too.
      els.each do |el|
        src_eid = el.dig('source', 'elementId')
        next unless src_eid && dropped_disp_by_el.key?(src_eid)
        src_el = by_id[src_eid]
        src_name = src_el && (src_el['name'] || display_name((src_el.dig('source', 'path') || []).last.to_s))
        next unless src_name
        dropped_names = dropped_disp_by_el[src_eid]
        keep = []
        drop = {}
        (el['columns'] || []).each do |c|
          tail = c['formula'].to_s[/\A\[#{Regexp.escape(src_name)}\/([^\]]+)\]\z/, 1]
          if tail && dropped_names.include?(tail.split('/').last)
            drop[c['id']] = true
            phantom += 1
          else
            keep << c
          end
        end
        if drop.any?
          el['columns'] = keep
          el['order'] = (el['order'] || []).reject { |id| drop[id] } if el['order']
        end
      end
    end
    els.each do |el|
      src_eid = el.dig('source', 'elementId')
      src_el = src_eid && by_id[src_eid]
      src_name = src_el && (src_el['name'] || display_name((src_el.dig('source', 'path') || []).last.to_s))
      src_table = src_el && (src_el.dig('source', 'path') || []).last
      keep_cols = []
      drop_ids = {}
      (el['columns'] || []).each do |c|
        unless c['formula']
          keep_cols << c
          next
        end
        before = c['formula']
        f = before.dup
        # (1) prefix rewrite for derived elements: [<SRC_TABLE>/ -> [<SrcName>/
        f = f.gsub("[#{src_table}/", "[#{src_name}/") if src_name && src_table && src_name != src_table
        # (2) GUID sibling refs -> bare display name
        f = f.gsub(/\[([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/i) do
          dn = guid_idx[Regexp.last_match(1).downcase]
          dn ? "[#{dn}]" : Regexp.last_match(0)
        end
        fixed += 1 if f != before
        c['formula'] = f
        # Drop if it still can't resolve (unresolved GUID or unknown function).
        bad_fn = unknown_functions(f).reject { |n| %w[IF THEN ELSE ELSEIF END WHEN CASE AND OR NOT].include?(n.to_s.upcase) }
        if formula_has_guid_ref?(f) || !bad_fn.empty?
          dn = col_display(c) || c['name']
          dropped << dn if dn
          drop_ids[c['id']] = true
          next
        end
        keep_cols << c
      end
      if drop_ids.any?
        el['columns'] = keep_cols
        el['order'] = (el['order'] || []).reject { |id| drop_ids[id] } if el['order']
      end
      # Metrics get the same treatment: resolve GUID refs, then DROP any metric
      # whose formula still can't resolve (unresolved GUID, or a ref to a
      # parenthesized cross-element column name validate-spec misreads as a
      # function call). Plotted-but-dropped metrics surface via the master-map's
      # untranslated list; here we just keep the DM POST-able.
      if el['metrics']
        kept_metrics = []
        (el['metrics'] || []).each do |m|
          f = (m['formula'] || '').dup
          f = f.gsub(/\[([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/i) do
            dn = guid_idx[Regexp.last_match(1).downcase]
            dn ? "[#{dn}]" : Regexp.last_match(0)
          end
          m['formula'] = f
          # A ref whose name contains "(" (e.g. "[Unit Cost (PRODUCT_DIM (...))]")
          # is a cross-element physical column the validator/parsing can't handle
          # in an aggregate metric — drop it.
          paren_ref = f =~ /\[[^\]]*\([^\]]*\][^\]]*\]/ || f =~ /\([A-Z0-9_]+ \(/
          if formula_has_guid_ref?(f) || paren_ref
            dropped << (m['name'] || 'metric')
            next
          end
          kept_metrics << m
        end
        el['metrics'] = kept_metrics
      end
    end
    { fixed: fixed, dropped: dropped.uniq, phantom: phantom }
  end

  # The display-name suffix Sigma stamps on a derived-view column when its bare
  # name collides with a sibling (a joined-dim column or a second join of the
  # same table). The converter column carries the dim in its formula PATH:
  #   "[Order Fact/CUSTOMER_DIM/Region]" -> base label "Region (CUSTOMER_DIM)".
  # A base-fact column ("[Order Fact/Order Id]") and calc columns have no dim
  # path -> bare label. Sigma further appends " (n)" when even the (DIM) form
  # collides (e.g. DATE_DIM joined twice); that ordinal is resolved by matching
  # against the LIVE readback labels in resolve_real_labels, not guessed here.
  def expected_label(col)
    f = col['formula'].to_s
    # An explicitly-named column keeps its name — Sigma honors the spec `name`
    # as the display label (calc columns, fact base columns, AND recovered
    # passthrough columns like the ovud order-date payload column).
    return col['name'] if col['name'] && !col['name'].to_s.empty?
    tail = f[/\[([^\]]+)\]\s*\z/, 1]
    return (col['name'] && !col['name'].to_s.empty? ? col['name'] : nil) unless tail
    parts = tail.split('/')
    name = parts.last
    parts.size >= 3 ? "#{name} (#{parts[-2]})" : name
  end

  # Match each converter derived-view column to the AUTHORITATIVE display label
  # Sigma assigned on POST/readback. Returns { col_object_id => real_label }.
  # We walk the columns in order (Sigma assigns disambiguating suffixes in column
  # order) and consume from a pool of the real labels: exact (DIM) form first,
  # then the " (n)" disambiguated forms. Columns we cannot match keep their bare
  # expected label as a best-effort fallback.
  def resolve_real_labels(cols, real_labels)
    pool = Hash.new(0)
    (real_labels || []).each { |l| pool[l] += 1 }
    out = {}
    cols.each do |c|
      exp = expected_label(c)
      next if exp.nil? || exp.to_s.empty?
      chosen =
        if pool[exp].positive?
          exp
        else
          # The (DIM) form already consumed (or absent): take the next " (n)" form.
          ((1..20).map { |n| "#{exp} (#{n})" }.find { |t| pool[t].positive? }) || exp
        end
      pool[chosen] -= 1 if pool[chosen].positive?
      out[c['id']] = chosen
    end
    out
  end

  # Derive { 'master_columns' => [...], 'mmap' => {...}, 'untranslated_metrics' => [...] }.
  # fact_name is the AUTHORITATIVE Sigma element name (from the DM readback) used
  # in master-column formulas [fact_name/Col]. base_el (optional) is the element a
  # derived view sources, whose metrics are also harvested.
  #
  # model (optional): the full converter model. When supplied, every mmap entry
  # whose converter column resolves through a relationship to a DIM element
  # ([FACT/REL_NAME/Col]) is annotated with its native grain:
  #   'grain' => { 'element' => '<Dim element display name>', 'relationship' => REL,
  #                'key' => '<fact FK display name>' }
  # Tableau evaluates aggregates of a dim-table measure at the DIM table's
  # native grain (relationship semantics) — Avg([Lifetime Revenue]) averages
  # over CUSTOMER_DIM rows, NOT over fact rows. build-charts uses the
  # annotation to emit a dim-grain helper element so two-stage averages match
  # (the FAT KPI AvgLTR class of divergence).
  #
  # real_labels (optional): the ACTUAL column display labels of the derived fact
  # element, read back from the live DM (`/v2/dataModels/<id>/columns`). The
  # converter exposes a joined-dim column under its bare last-path-segment name
  # ("Customer Id"), but on POST Sigma disambiguates it with a relationship
  # SUFFIX ("Customer Id (CUSTOMER_DIM)"). The master-column FORMULA must use the
  # real (suffixed) label or it errors as "Dependency not found". When supplied,
  # each master column's formula is [fact_name/<real label>] while its NAME (and
  # every mmap regex) stays the BARE caption — so build-charts' [Master/<bare>]
  # refs and the bare Tableau chart captions still resolve. Without real_labels
  # we fall back to the bare-name formula (correct only for non-virtual conns).
  def derive_master(fact_el, fact_name, base_el = nil, real_labels = nil, model = nil)
    master_columns = []
    mmap = {}
    seen = {}
    used_regex = {}
    untranslated = []
    guid_idx = guid_display_index(fact_el, base_el)
    # Native-grain index: converter column formula -> dim element name + FK key
    # (see the doc comment above). Keyed by the column's bare display name.
    grain_for = {}
    if model && base_el
      els_by_id = all_elements(model).each_with_object({}) { |e, h| h[e['id']] = e }
      key_cols = (base_el['columns'] || []).each_with_object({}) { |c, h| h[c['id']] = c }
      (fact_el['columns'] || []).each do |c|
        m = c['formula'].to_s.match(%r{\A\[([^/\]]+)/([^/\]]+)/([^\]]+)\]\z})
        next unless m
        rel = (base_el['relationships'] || []).find { |r| r['name'] == m[2] }
        next unless rel
        tgt = els_by_id[rel['targetElementId']]
        next unless tgt
        tgt_name = (tgt['name'] && !tgt['name'].to_s.empty?) ? tgt['name'] : display_name((tgt.dig('source', 'path') || []).last.to_s)
        fk = key_cols[rel.dig('keys', 0, 'sourceColumnId')]
        dn = col_display(c)
        next unless dn
        grain_for[dn.downcase] = { 'element' => tgt_name, 'relationship' => m[2],
                                   'key' => fk && col_display(fk) }.compact
      end
    end
    # dname (BARE caption, used for name+mmap) -> real readback label (used for formula).
    real_for = lambda do |dname, real_label|
      lbl = (real_label && !real_label.to_s.empty?) ? real_label : dname
      "[#{fact_name}/#{lbl}]"
    end
    add = lambda do |dname, format, real_label = nil|
      return if dname.nil? || dname.to_s.empty?
      return if dname =~ GUID_RE
      key = dname.downcase
      return if seen[key]
      seen[key] = true
      id = "m-#{slug(dname)}"
      master_columns << { 'id' => id, 'name' => dname, 'formula' => real_for.call(dname, real_label) }
      entry = { 'id' => id, 'name' => dname }
      entry['format'] = format if format
      entry['grain'] = grain_for[key] if grain_for[key]
      rx = header_regex(dname)
      unless used_regex[rx]
        mmap[rx] = entry
        used_regex[rx] = true
      end
      bc = base_caption(dname)
      if bc && bc != dname
        brx = header_regex(bc)
        unless used_regex[brx]
          mmap[brx] = entry
          used_regex[brx] = true
        end
      end
    end
    raw_cols = (fact_el['columns'] || [])
    # Real readback label per converter column (suffixed form). Empty hash when
    # no readback labels supplied -> formulas fall back to the bare name.
    label_for = real_labels ? resolve_real_labels(raw_cols, real_labels) : {}
    # Bare-named columns claim their regex before suffixed cross-element dupes.
    cols = raw_cols.map { |c| [col_display(c), c['format'], label_for[c['id']]] }
    cols.sort_by! { |(dn, _, _)| (dn.to_s.include?('(') ? 1 : 0) }
    cols.each { |(dn, fmt, real_label)| add.call(dn, fmt, real_label) }
    # Aggregate calc metrics are NOT master columns — they are workbook-level
    # aggregate formulas registered as master-map entries with a verbatim
    # `formula` (base-col refs rewritten to [Master/Col]); build-charts emits the
    # formula straight onto the chart measure. The raw base cols are master cols.
    metric_srcs = [fact_el, base_el].compact
    metric_srcs.each do |mel|
      (mel['metrics'] || []).each do |m|
        nm = m['name']
        next if nm.nil? || nm.to_s.empty?
        rx = header_regex(nm)
        next if used_regex[rx]
        formula = rewrite_metric_formula(m['formula'], guid_idx)
        if formula.nil?
          untranslated << nm
          next
        end
        entry = { 'id' => "m-#{slug(nm)}", 'name' => nm, 'formula' => formula }
        entry['format'] = m['format'] if m['format']
        mmap[rx] = entry
        used_regex[rx] = true
      end
    end
    { 'master_columns' => master_columns, 'mmap' => mmap, 'untranslated_metrics' => untranslated }
  end

  # Assemble the full workbook spec: a hidden master table on page-data sourcing
  # the DM fact element, plus dashboard page(s) of the build-charts elements.
  #
  # chart_elements: either a flat array (single dashboard page named after the
  # workbook — legacy) OR an array of { 'name' =>, 'elements' => } page hashes
  # (one Sigma page per Tableau dashboard — bead ptrt).
  # data_elements: extra HIDDEN elements for the data page (e.g. the scatter
  # grouped-source tables — bead z1d0).
  def build_wb_spec(name:, dm_id:, fact_eid:, master_columns:, chart_elements:, folder_id: nil,
                    data_elements: [])
    master = {
      'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'visibleAsSource' => false,
      'source' => { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => fact_eid },
      'columns' => master_columns, 'order' => master_columns.map { |c| c['id'] }
    }
    chart_pages =
      if chart_elements.is_a?(Array) && chart_elements.all? { |e| e.is_a?(Hash) && e.key?('elements') && e.key?('name') }
        chart_elements.each_with_index.map do |pg, i|
          { 'id' => "page-dash-#{i + 1}", 'name' => pg['name'], 'elements' => pg['elements'] }
        end
      else
        [{ 'id' => 'page-dash', 'name' => name, 'elements' => chart_elements }]
      end
    spec = {
      'name' => name,
      'description' => 'Generated mechanically from Tableau via tableau-to-sigma (convert_tableau_to_sigma + build-charts-from-signals).',
      'schemaVersion' => 1,
      'pages' => [
        { 'id' => 'page-data', 'name' => 'Data',
          'elements' => [master] + (data_elements || []) },
        *chart_pages
      ]
    }
    spec['folderId'] = folder_id if folder_id
    spec
  end
end
