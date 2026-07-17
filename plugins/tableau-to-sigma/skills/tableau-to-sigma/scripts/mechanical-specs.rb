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
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)
require_relative 'lib/theme_derive' # shared theme derivation/emission (v5.0)

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

  # #7a — derive the REAL [db, schema] from a .twb's first LIVE-warehouse
  # datasource table relation, so the DM/converter/land steps stop defaulting to
  # the CSA.TJ placeholder (which 404s on catalog sync — field-caught on 2 live
  # runs; the real db.schema was only recoverable by hand-reading the .twb).
  # Returns [db, schema] or [nil, nil]. NEVER derives for embedded-file extracts
  # (those legitimately land at CSA.TJ) or published/sqlproxy stubs. Self-
  # contained REXML parse — does not require the un-guarded scan-workbook-gaps.rb.
  EMBEDDED_CONN_CLASSES = %w[excel-direct textscan hyper ogrdirect csv msexcel].freeze
  NONDATA_CONN_CLASSES  = %w[mapbox tableau-map wms wms-server].freeze
  def derive_db_schema_from_twb(twb_path)
    return [nil, nil] unless twb_path && File.exist?(twb_path)
    require 'rexml/document'
    xml = REXML::Document.new(File.read(twb_path, encoding: 'UTF-8'))
    xml.elements.each('/workbook/datasources/datasource') do |ds|
      name = ds.attributes['name'].to_s
      next if name.empty? || name.start_with?('Parameters')
      # the real (non-wrapper) connection for this datasource
      conn = nil
      ds.elements.each('.//connection') do |c|
        cls = c.attributes['class'].to_s.downcase
        next if cls.empty? || cls == 'federated'
        conn ||= c
      end
      next unless conn
      cls = conn.attributes['class'].to_s.downcase
      # live warehouse only — skip embedded extracts, basemaps, and published stubs
      next if EMBEDDED_CONN_CLASSES.include?(cls) || NONDATA_CONN_CLASSES.include?(cls) || cls == 'sqlproxy'
      # first physical table relation (skip the [sqlproxy] published-source stub)
      rel = nil
      ds.elements.each('.//relation') do |r|
        next unless r.attributes['type'].to_s == 'table' && r.attributes['table']
        next if r.attributes['table'].to_s == '[sqlproxy]'
        rel ||= r
      end
      next unless rel
      parts = rel.attributes['table'].to_s.scan(/\[([^\]]+)\]/).flatten
      parts = [rel.attributes['table'].to_s.gsub(/[\[\]]/, '')] if parts.empty?
      conn_db  = conn.attributes['dbname']
      conn_sch = conn.attributes['schema']
      db, sch = case parts.length
                when 3 then [parts[0], parts[1]]        # [DB].[SCHEMA].[TABLE]
                when 2 then [conn_db, parts[0]]         # [SCHEMA].[TABLE] + conn dbname
                else        [conn_db, conn_sch]         # [TABLE] + conn dbname/schema
                end
      db = nil if db.to_s.strip.empty?
      sch = nil if sch.to_s.strip.empty?
      return [db, sch] if db && sch
    end
    [nil, nil]
  rescue StandardError
    [nil, nil]
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
  def pick_fact(model, prefer_table: nil)
    els = all_elements(model)
    return nil if els.empty?
    # A dimension element's name is "<X> Dim" (trailing) OR "Dim <X>" (leading,
    # e.g. "Dim Time") — exclude BOTH so a narrow date/time dim can never be
    # chosen as the fact (the date-crosstab regression: "Dim Time" slipped past a
    # trailing-only / Dim$/ and won max_by, making the workbook master source the
    # wrong element).
    dim_re = /(^Dim\b| Dim$)/i
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
    # The warehouse table an element resolves to (its own path, or its source
    # element's path for a derived view). Used to honor `prefer_table`.
    el_table = lambda do |e|
      last = (e.dig('source', 'path') || []).last
      if last.nil? && (sid = e.dig('source', 'elementId'))
        last = (by_id[sid]&.dig('source', 'path') || []).last
      end
      last.to_s.upcase
    end
    derived = els.select { |e| e.dig('source', 'kind') == 'table' && e.dig('source', 'elementId') }
                 .reject { |e| elem_name(e) =~ dim_re }
    # Base candidates are warehouse-table elements OR custom-SQL ('sql') elements —
    # the modern Tableau object/relationship model emits one kind:'sql' element per
    # logical object (often the only kind present in a multi-custom-SQL workbook).
    base = els.select { |e| %w[warehouse-table sql].include?(e.dig('source', 'kind')) }
    # `prefer_table` = the landed table the DASHBOARD worksheets actually use
    # (dominant_fact_table). In a MULTI-embedded-extract workbook the converter
    # projects more columns for an UNUSED secondary datasource than for the one
    # the charts plot, so the max_by(columns.size) default below picks the wrong
    # fact (the Global Macro regression: 14-col unused Table B beat the 9-col used
    # Table A). When a preferred table is named, restrict the pick to elements
    # tied to it; only fall through to the count heuristic if nothing matches.
    if prefer_table
      pt = prefer_table.to_s.upcase
      dpt = derived.select { |e| el_table.call(e) == pt }
      return dpt.max_by { |e| (e['columns'] || []).size } if dpt.any?
      bpt = base.select { |e| el_table.call(e) == pt }
      unless bpt.empty?
        f = bpt.reject { |e| elem_name(e) =~ dim_re }
        return (f.empty? ? bpt : f).max_by { |e| (e['columns'] || []).size }
      end
    end
    return derived.max_by { |e| (e['columns'] || []).size } if derived.any?
    # Without 'sql' here, pick_fact returned nil and the whole mechanical path
    # FATAL-aborted on object-model workbooks (the DDMX empty-DM dead-end).
    return nil if base.empty?
    facts = base.reject { |e| elem_name(e) =~ dim_re }
    (facts.empty? ? base : facts).max_by { |e| (e['columns'] || []).size }
  end

  # The landed table (UPPER last path segment) of the datasource the DASHBOARD
  # worksheets actually use — the correct fact for a multi-embedded-extract
  # workbook. Counts each worksheet's <datasource-dependencies> (excluding
  # Parameters), maps the dominant datasource → its caption → the landing-manifest
  # entry → sf_table. Regex-based (no full XML parse) so it's fast on large .twb.
  # Returns nil when there's no manifest, a single datasource, or no clear winner.
  def dominant_fact_table(twb_text, manifest_path)
    return nil unless twb_text && manifest_path && File.exist?(manifest_path.to_s)
    entries = (JSON.parse(File.read(manifest_path.to_s)) rescue nil)
    return nil unless entries.is_a?(Array) && entries.size > 1 # single-source: no ambiguity

    # Per-datasource: its caption AND its embedded .hyper basename. Split on the
    # datasource OPEN tag (`<datasource ` — a trailing space, so it never matches
    # `<datasource-dependencies`) so each chunk is one datasource's body, and pull
    # the first `dbname='….hyper'` inside it.
    name2cap = {}
    name2hyper = {}
    name2remote = Hash.new { |h, k| h[k] = Set.new }
    sanitize = ->(s) { s.to_s.gsub(/[^0-9A-Za-z]+/, '_').gsub(/\A_+|_+\z/, '').upcase }
    twb_text.split(/<datasource\s/).drop(1).each do |chunk|
      attrs = chunk[/\A([^>]*)>/, 1].to_s
      nm = attrs[/\bname='([^']*)'/, 1]
      next unless nm
      c = attrs[/\bcaption='([^']*)'/, 1]
      name2cap[nm] ||= c if c
      db = chunk[/<connection\b[^>]*\bdbname='([^']*\.hyper)'/i, 1]
      name2hyper[nm] ||= File.basename(db) if db
      # Physical extract column names (metadata-records) — the tie-breaker below.
      chunk.scan(%r{<remote-name>([^<]+)</remote-name>}) { |r| name2remote[nm] << sanitize.call(r[0]) }
    end
    usage = Hash.new(0)
    twb_text.scan(/<datasource-dependencies\b[^>]*\bdatasource='([^']+)'/) do |m|
      n = m[0]
      next if n.nil? || n =~ /\AParameters\b/i
      usage[n] += 1
    end
    return nil if usage.empty?
    dominant = usage.max_by { |_n, c| c }&.first
    # Match the manifest by .hyper FIRST (robust: land-extracts always records the
    # hyper basename, but may LABEL the caption by the GUID filename when it can't
    # resolve the datasource caption — which would defeat a caption-only match and
    # send pick_fact to the wrong, unused table). Fall back to caption, then name.
    hyp = name2hyper[dominant]
    cap = name2cap[dominant].to_s.strip
    entry = (hyp && entries.find { |e| e['hyper'].to_s == hyp }) ||
            (!cap.empty? && entries.find { |e| e['caption'].to_s.strip == cap }) ||
            entries.find { |e| e['datasource'].to_s == dominant }
    # Server-downloaded .twb reference their extracts by GUID dbname (no .hyper
    # basename), and land-extracts GUID-labels the caption when the datasource
    # caption can't be resolved — so all three matches above can fail on exactly
    # the workbooks that need the hint most (the count heuristic then picks the
    # wrong, unused table). Tie-break by PHYSICAL column overlap: the dominant
    # datasource's <metadata-records> remote names ARE the landed column set
    # (near-total overlap on the right table, incidental on the wrong one).
    # Require a strict winner so an ambiguous match never masquerades as a hint.
    if entry.nil? && name2remote[dominant].any?
      remote = name2remote[dominant]
      scored = entries.map do |e|
        phys = (e['columns'] || {}).values.map { |v| v.to_s.upcase }
        [e, phys.count { |p| remote.include?(p) }]
      end.sort_by { |_e, n| -n }
      best_e, best_n = scored[0]
      runner_n = scored[1] ? scored[1][1] : 0
      entry = best_e if best_n.positive? && best_n > runner_n
    end
    return nil unless entry && entry['sf_table']
    entry['sf_table'].to_s.split('.').last&.upcase
  end

  # Synthesize DM columns for per-year FIXED LODs the converter left unmaterialized
  # — `{FIXED DATEPART('year',[Date]): SUM([metric])}` "World"-style global totals.
  # The converter emits NOTHING for these worksheet/datasource LOD calcs, so a
  # chart referencing e.g. "GDP World" dangles and blocks the POST. We build the
  # helper the converter SHOULD have: a nameless grouped Custom SQL element
  # (SUM per year over the landed fact table) + a `FIXED Year` relationship on the
  # fact; derive_master's existing FIXED-helper surfacing (below) then exposes each
  # World measure onto the master as [<fact>/FIXED Year/<Name>]. Scope: single
  # year dimension keyed on a physical Year column on the fact (the common case).
  # Returns the count of LOD measures synthesized. Mutates `model`/`fact`.
  FIXED_YEAR_LOD_RE = /\{\s*FIXED\s+([^:]+?)\s*:\s*(SUM|AVG|MIN|MAX|COUNT|COUNTD)\s*\(\s*\[([^\]]+)\]\s*\)\s*\}/i

  # real_map (optional): the landing manifest's caption→physical map for the
  # fact's landed table. The custom SQL references PHYSICAL warehouse columns,
  # so with a manifest the metric/discriminator checks resolve against the
  # table's REAL columns — the DM element projects only PLOTTED columns, and a
  # World LOD's base metric is typically never plotted directly (it only
  # appears inside the LOD), so a projection-only check silently drops the LOD
  # and the chart ref dangles at the POST.
  def synthesize_fixed_lods!(model, fact, twb_text, colmap = {}, discriminator: nil, real_map: nil)
    return {} unless model && fact && twb_text
    # Must return the SAME type ({}) as every other exit — the caller does
    # world_lod_map.any?, and `0.any?` is a NoMethodError that crashes the run.
    # This fires whenever the plotted fact is a DERIVED VIEW (source kind 'sql'/
    # 'table', e.g. a Virtual-Connection-backed workbook), not a raw table.
    return {} unless fact.dig('source', 'kind') == 'warehouse-table'
    path = fact.dig('source', 'path') || []
    conn = fact.dig('source', 'connectionId')
    return {} if path.size < 3 || conn.to_s.empty?

    # Key on col_display (formula-derived) — the converter leaves column['name']
    # null on extract-backed models (the display name lives in the [EXTRACT/<cap>]
    # formula, resolved by col_display). Reading c['name'] here returned an empty
    # map → no 'year' key → this whole synthesis silently no-op'd on every
    # extract-landed workbook (the World-total dual-axis line then dangled).
    fact_caps = (fact['columns'] || []).each_with_object({}) do |c, h|
      disp = col_display(c)
      h[disp.to_s.downcase] = c if disp && !disp.to_s.empty?
    end
    year_col = fact_caps['year']
    return {} unless year_col # need a physical Year key on the fact
    # Decode XML entities PER captured formula — NOT on the whole text, which would
    # turn &apos; into literal ' inside formula='…' and break attribute scanning.
    decode = ->(s) { s.to_s.gsub('&apos;', "'").gsub('&quot;', '"').gsub('&amp;', '&') }

    phys = lambda do |cap|
      dest = (real_map && (real_map[cap] || real_map[cap.to_s.strip])) ||
             colmap[cap] || colmap[cap.to_s.strip.upcase]
      (dest || cap).to_s.gsub(/[^0-9A-Za-z]+/, '_').gsub(/\A_+|_+\z/, '').upcase
    end

    # A caption is SQL-usable iff its physical column exists on the landed
    # table (manifest truth). Without a manifest, fall back to the projected
    # DM columns OR an explicit colmap entry — a threaded caption→physical
    # rename is itself evidence the column exists on the landed table.
    real_set = real_map && real_map.values.map { |v| v.to_s.upcase }.to_set
    sql_usable = lambda do |cap|
      if real_set
        real_set.include?(phys.call(cap))
      else
        fact_caps.key?(cap.to_s.downcase) || colmap.key?(cap) || colmap.key?(cap.to_s.strip.upcase)
      end
    end

    lods = {}
    twb_text.scan(/<column\b[^>]*\bcaption='([^']*)'[^>]*>\s*<calculation\b[^>]*\bformula='([^']*)'/m) do |cap_raw, f_raw|
      cap = decode.call(cap_raw)
      m = decode.call(f_raw).match(FIXED_YEAR_LOD_RE)
      next unless m
      dim, agg, metric = m[1], m[2], m[3]
      next unless dim =~ /DATEPART\(\s*'year'|\bYEAR\s*\(|\[Year\]/i     # year-grain only
      # The metric must resolve to a REAL column on THIS fact's table. A caption
      # can be defined per-datasource with different base metrics (e.g. "GDP World"
      # = SUM([GDP Value]) on one datasource, SUM([GDP (current US$)]) on another)
      # — keep the first definition whose metric this table actually carries.
      next unless sql_usable.call(metric)
      lods[cap] ||= { 'name' => cap, 'agg' => agg.upcase, 'metric' => metric }
    end
    return {} if lods.empty?

    year_phys = phys.call(col_display(year_col))
    fqn = %(#{path[0]}.#{path[1]}."#{path[2]}")
    sel = [%("#{year_phys}" AS "Year")]
    cols = [{ 'id' => 'wby-year', 'name' => 'Year', 'formula' => '[Custom SQL/Year]' }]
    lods.values.each do |l|
      sel << %(#{l['agg']}("#{phys.call(l['metric'])}") AS "#{l['name']}")
      cols << { 'id' => "wby-#{slug(l['name'])}", 'name' => l['name'], 'formula' => "[Custom SQL/#{l['name']}]" }
    end
    # Exclude aggregate/rollup rows from the per-year WORLD total. Global Macro–style
    # extracts carry region / income-group / "World" rollup rows ALONGSIDE the real
    # countries, so an unfiltered SUM(...) OVER year double-counts them (the World
    # trend line came out ~6-10x too high). The point-in-time discriminator (a
    # column NULL on rollup rows, e.g. IncomeGroup) selects real entities only.
    #
    # SCOPE GUARD (live-caught): the discriminator lives on the COUNTRY-grain fact.
    # When the FIXED-Year metrics resolve to a DIFFERENT table (e.g. an already
    # world-grain companion extract), that table may not carry the column at all —
    # emitting the WHERE anyway makes the whole DM POST fail with
    # `invalid identifier`. Only filter when the discriminator's caption resolves
    # to a column ON THIS fact; a single-entity/world-grain table needs no
    # rollup exclusion in the first place.
    where = ''
    if discriminator && !discriminator.to_s.strip.empty?
      if sql_usable.call(discriminator)
        where = %( WHERE "#{phys.call(discriminator)}" IS NOT NULL)
      else
        warn "NOTE world-by-year: discriminator #{discriminator.inspect} is not a column on " \
             "#{path[2]} — rollup-exclusion WHERE omitted (verify the world totals against " \
             'the source render in Phase 6; a table without the discriminator usually has no rollup rows).'
      end
    end
    statement = %(SELECT #{sel.join(', ')} FROM #{fqn}#{where} GROUP BY "#{year_phys}")

    sql_el = {
      'id' => 'el-world-by-year', 'kind' => 'table',
      'source' => { 'connectionId' => conn, 'kind' => 'sql', 'statement' => statement },
      'columns' => cols, 'order' => cols.map { |c| c['id'] }
    }
    page = (model['pages'] || []).find { |p| (p['elements'] || []).any? { |e| e.equal?(fact) } } ||
           (model['pages'] || []).first
    (page['elements'] ||= []) << sql_el if page
    (fact['relationships'] ||= []) << {
      'id' => 'rel-world-by-year', 'name' => 'FIXED Year', 'targetElementId' => 'el-world-by-year',
      'keys' => [{ 'sourceColumnId' => year_col['id'], 'targetColumnId' => 'wby-year' }]
    }
    # Return the world-column -> source-metric map (recipe uses it to add the
    # region-filtered Country line opposite each synthesized World line).
    lods.each_with_object({}) { |(cap, l), h| h[cap.to_s.downcase] = l['metric'] }
  end

  # Synthesize the "<Metric> YoY" helper for a multi-metric YoY panel: the
  # source prints a signed % beside each category bar. That change is
  # PAIRWISE-COMPLETE year-over-year — only entities carrying BOTH years count
  # (one-sided entities distort the group total: live-calibrated, a naive
  # region sum gave -22% where the source prints -11%). Emits ONE grouped
  # Custom SQL element over the fact table (dim + one "<metric> YoY" column
  # per metric, each at ITS OWN latest year vs the prior year, real entities
  # only) + a `FIXED YoY` relationship on the fact keyed by the dim —
  # derive_master's FIXED-helper surfacing then exposes each YoY column onto
  # the master; the multimetric recipe adds it to the bar tiles (and the
  # anchors gate can verify the printed percentages).
  # metrics: {caption => latest_year}. Returns {metric_caption.downcase =>
  # "<caption> YoY"} (empty when not applicable). Mutates model/fact.
  def synthesize_yoy_by_dim!(model, fact, dim:, entity:, metrics:, year: 'Year',
                             discriminator: nil, real_map: nil, colmap: {})
    return {} unless model && fact && metrics.is_a?(Hash) && !metrics.empty?
    return {} if dim.to_s.strip.empty? || entity.to_s.strip.empty?
    return {} unless fact.dig('source', 'kind') == 'warehouse-table'
    path = fact.dig('source', 'path') || []
    conn = fact.dig('source', 'connectionId')
    return {} if path.size < 3 || conn.to_s.empty?

    phys = lambda do |cap|
      dest = (real_map && (real_map[cap] || real_map[cap.to_s.strip])) ||
             colmap[cap] || colmap[cap.to_s.strip.upcase]
      (dest || cap).to_s.gsub(/[^0-9A-Za-z]+/, '_').gsub(/\A_+|_+\z/, '').upcase
    end
    real_set = real_map && real_map.values.map { |v| v.to_s.upcase }.to_set
    usable = ->(cap) { real_set.nil? || real_set.include?(phys.call(cap)) }
    return {} unless usable.call(dim) && usable.call(entity) && usable.call(year)

    fact_caps = (fact['columns'] || []).each_with_object({}) do |c, h|
      disp = col_display(c)
      h[disp.to_s.downcase] = c if disp && !disp.to_s.empty?
    end
    dim_col = fact_caps[dim.to_s.downcase]
    return {} unless dim_col # the relationship key must be projected on the fact

    yp = phys.call(year)
    agg = []
    out = []
    cols = [{ 'id' => 'yoy-dim', 'name' => dim, 'formula' => "[Custom SQL/#{dim}]" }]
    ymap = {}
    metrics.each_with_index do |(cap, yr), i|
      next unless usable.call(cap) && yr.to_s =~ /\A\d{4}\z/
      mp = phys.call(cap)
      y = yr.to_i
      agg << %(SUM(CASE WHEN "#{yp}" = #{y} THEN "#{mp}" END) AS m#{i}a)
      agg << %(SUM(CASE WHEN "#{yp}" = #{y - 1} THEN "#{mp}" END) AS m#{i}b)
      name = "#{cap} YoY"
      out << %(SUM(CASE WHEN m#{i}a IS NOT NULL AND m#{i}b IS NOT NULL THEN m#{i}a END) / ) +
             %(NULLIF(SUM(CASE WHEN m#{i}a IS NOT NULL AND m#{i}b IS NOT NULL THEN m#{i}b END), 0) - 1 AS "#{name}")
      cols << { 'id' => "yoy-#{slug(name)}", 'name' => name, 'formula' => "[Custom SQL/#{name}]" }
      ymap[cap.to_s.downcase] = name
    end
    return {} if ymap.empty?

    where = ''
    if discriminator && !discriminator.to_s.strip.empty? && usable.call(discriminator)
      where = %( WHERE "#{phys.call(discriminator)}" IS NOT NULL)
    end
    fqn = %(#{path[0]}.#{path[1]}."#{path[2]}")
    statement = <<~SQL.gsub(/\s+/, ' ').strip
      SELECT "#{phys.call(dim)}" AS "#{dim}", #{out.join(', ')}
      FROM (
        SELECT "#{phys.call(dim)}", "#{phys.call(entity)}", #{agg.join(', ')}
        FROM #{fqn}#{where}
        GROUP BY "#{phys.call(dim)}", "#{phys.call(entity)}"
      ) t
      GROUP BY "#{phys.call(dim)}"
    SQL

    sql_el = {
      'id' => 'el-yoy-by-dim', 'kind' => 'table',
      'source' => { 'connectionId' => conn, 'kind' => 'sql', 'statement' => statement },
      'columns' => cols, 'order' => cols.map { |c| c['id'] }
    }
    page = (model['pages'] || []).find { |p| (p['elements'] || []).any? { |e| e.equal?(fact) } } ||
           (model['pages'] || []).first
    (page['elements'] ||= []) << sql_el if page
    (fact['relationships'] ||= []) << {
      'id' => 'rel-yoy-by-dim', 'name' => 'FIXED YoY', 'targetElementId' => 'el-yoy-by-dim',
      'keys' => [{ 'sourceColumnId' => dim_col['id'], 'targetColumnId' => 'yoy-dim' }]
    }
    ymap
  end

  # Retain extra base columns on the fact that the recipe needs but the converter
  # dropped (it projects only PLOTTED columns). The multi-metric point-in-time
  # filter references [Master/<discriminator>] + [Master/<year>]; if the source
  # never plotted the discriminator (e.g. Global-Macro "IncomeGroup"), it's absent
  # from the DM → the recipe guard skips the real-entity filter. Add each wanted
  # name as a base column [<table>/<Name>] when it's a REAL warehouse column
  # (present in real_cols for the fact's table) and not already exposed. Returns
  # the count added. Runs on the DM fact BEFORE POST so it flows into the master
  # via derive_master.
  def retain_columns!(fact, names, real_cols)
    return 0 unless fact && fact.dig('source', 'kind') == 'warehouse-table'
    tbl = (fact.dig('source', 'path') || []).last.to_s
    return 0 if tbl.empty?
    rc = (real_cols[tbl] || real_cols[tbl.upcase] || []).map { |c| c.to_s.upcase }.to_set
    return 0 if rc.empty?
    have = (fact['columns'] || []).map { |c| col_display(c).to_s.downcase }
    added = 0
    Array(names).compact.each do |nm|
      s = nm.to_s.strip
      next if s.empty? || have.include?(s.downcase)
      phys = s.gsub(/[^0-9A-Za-z]+/, '_').gsub(/\A_+|_+\z/, '').upcase
      next unless rc.include?(phys) || rc.include?(s.upcase)
      id = "pit-#{slug(s)}"
      (fact['columns'] ||= []) << { 'id' => id, 'name' => s, 'formula' => "[#{tbl}/#{s}]" }
      fact['order'] << id if fact['order'].is_a?(Array)
      have << s.downcase
      added += 1
    end
    added
  end

  # The base element a derived view sources (for harvesting its metrics, which
  # don't propagate to derived elements). Returns nil for a base fact.
  def base_of(model, fact_el)
    src_eid = fact_el.dig('source', 'elementId')
    return nil unless src_eid
    all_elements(model).find { |e| e['id'] == src_eid }
  end

  # Remap a converter DM built from EMBEDDED extracts onto the landed Snowflake
  # tables, using the landing-manifest.json produced by land-extracts.py. The
  # converter only sees the generic in-.twbx table name ("Extract") for every
  # embedded datasource, so N datasources collapse onto an IDENTICAL source.path
  # + element name (TJ.PUBLIC.EXTRACT / "Extract") and their base-column formula
  # prefixes point at a table Sigma cannot resolve. This is the step
  # refs/extract-landing.md promised ("Phase 3 consumes the manifest to remap DM
  # source paths and column refs") but nothing performed — everything the
  # operator hand-fixed (colliding paths, wrong "Master" element, unresolvable
  # [EXTRACT/...] formulas) cascades from its absence.
  #
  # Matching is by COLUMN-CAPTION OVERLAP (never element name — that collides):
  # each element is scored against every manifest entry's ORIG column captions,
  # then assigned greedily 1:1 by descending overlap, so distinct column sets
  # (e.g. 36-col vs 19-col) separate two identically-named "Extract" elements.
  # For each matched element it:
  #   * repaths source.path        -> the entry's landed sf_table (split on '.')
  #   * rewrites every column/metric formula prefix  [<oldlast>/x] -> [<sf_last>/x]
  #   * sets a clean element name   (display_name of the landed table)
  # and RETURNS { colmap:, elements:, tables: }. `colmap` is a merged
  # {orig_caption => landed_column} map the caller threads into
  # fixup_dm_spec(column_mapping:) so long/sanitized indicator names
  # ("GDP (current US$)" -> GDP_CURRENT_US) fold to their real warehouse column
  # instead of phantom-dropping. No manifest / no match => a no-op {elements:0}.
  def remap_from_manifest!(model, manifest_path)
    empty = { colmap: {}, elements: 0, tables: [] }
    return empty unless manifest_path && File.exist?(manifest_path.to_s)
    entries = (JSON.parse(File.read(manifest_path.to_s)) rescue nil)
    return empty unless entries.is_a?(Array) && entries.any?

    norm = ->(s) { s.to_s.gsub(/[^0-9a-z]/i, '').upcase }
    entry_caps = entries.map { |e| [(e['columns'] || {}).keys.map { |k| norm.call(k) }.to_set, e] }
    els = all_elements(model).select { |e| e.dig('source', 'kind') == 'warehouse-table' }

    # Score every (element, entry) pair by orig-caption overlap; assign greedily
    # 1:1 by descending score so the larger column set claims its entry first.
    scored = []
    els.each_with_index do |el, ei|
      caps = (el['columns'] || []).map { |c| norm.call(col_display(c)) }.reject(&:empty?).to_set
      entry_caps.each_with_index do |(ekeys, entry), si|
        overlap = (caps & ekeys).size
        scored << [overlap, ei, si, el, entry] if overlap.positive?
      end
    end
    scored.sort_by! { |s| -s[0] }

    colmap = {}
    tables = []
    claimed_el = {}
    used_entry = {}
    rename_pairs = [] # [old_last, old_name, new_last, new_name, element]
    scored.each do |_overlap, ei, si, el, entry|
      next if claimed_el[ei] || used_entry[si]
      sf = entry['sf_table'].to_s.split('.')
      new_last = sf.last.to_s
      next if new_last.empty?
      claimed_el[ei] = true
      used_entry[si] = true
      old_last = (el.dig('source', 'path') || []).last.to_s
      old_name = el['name'].to_s
      el['source']['path'] = sf
      el['name'] = display_name(new_last)
      unless old_last.empty? || old_last == new_last
        pfx = /\[#{Regexp.escape(old_last)}\//
        (el['columns'] || []).each { |c| c['formula'] = c['formula'].to_s.gsub(pfx, "[#{new_last}/") }
        (el['metrics'] || []).each { |m| m['formula'] = m['formula'].to_s.gsub(pfx, "[#{new_last}/") }
      end
      rename_pairs << [old_last, old_name, new_last, el['name'].to_s, el]
      (entry['columns'] || {}).each { |orig, landed| colmap[orig] = landed }
      tables << new_last
    end

    # v5.4: repair DERIVED elements' refs. A converter "View"/calc-table
    # element references its base by the base's OLD identifier; the per-claim
    # rewrite above only fixes the claimed element itself, leaving the derived
    # element broken — the union-collapse orphan class. Rewrite refs on
    # UNCLAIMED elements only, and only when the old identifier maps to
    # EXACTLY ONE landed table — shared generic identifiers ("Extract" on
    # every embedded datasource) are unattributable and stay as NAMED residue,
    # never a guess.
    claimed_ids = rename_pairs.map { |r| r[4].object_id }
    { 0 => 2, 1 => 3 }.each do |old_idx, new_idx|
      rename_pairs.group_by { |r| r[old_idx] }.each do |old, rs|
        next if old.to_s.empty?
        news = rs.map { |r| r[new_idx] }.uniq
        next if news == [old]
        if news.size > 1
          warn "manifest remap: original identifier '#{old}' landed on #{news.size} tables — derived-element " \
               'refs to it are unattributable and left as-is (repoint by hand / --table-mapping)'
          next
        end
        pfx_old = /\[#{Regexp.escape(old)}\//
        repl = "[#{news.first}/"
        all_elements(model).each do |other|
          next if claimed_ids.include?(other.object_id)
          (Array(other['columns']) + Array(other['metrics'])).each do |c|
            c['formula'] = c['formula'].gsub(pfx_old, repl) if c['formula'].is_a?(String)
          end
        end
      end
    end

    # v5.4 (item: kind:'sql' FROM identifiers): Custom-SQL / FIXED-LOD helper
    # elements embed the ORIGINAL workbook table identifier in their
    # source.statement ("FROM ...'UDEMY COURSE$'") — repointing only
    # warehouse-table elements left them querying a table that does not exist
    # in the warehouse (field-confirmed twice; sanctioned recovery was a
    # manual --table-mapping). Attribute each statement to a manifest entry by
    # column-identifier overlap, then rewrite SINGLE-TABLE statements:
    #   FROM <orig identifier>  → FROM <landed sf_table>
    #   "orig col" / [orig col] → landed column name (manifest colmap)
    # Multi-table SQL (JOINs / several FROMs) is named residue — never guessed.
    sql_remapped = 0
    all_elements(model).each do |el|
      next unless el.dig('source', 'kind') == 'sql' && el.dig('source', 'statement').is_a?(String)
      stmt = el['source']['statement']
      # Attribution scan: double-quoted and bracketed tokens only (v5.4.9
      # review fix). Single-quoted tokens are DATA LITERALS in SQL (WHERE
      # region = 'West') — counting them toward column overlap could tip the
      # attribution to a wrong manifest entry and rewrite FROM to the wrong
      # landed table with no warning. Single-quoted TABLE identifiers
      # (FROM 'Sheet1$') don't contribute to column overlap anyway, and the
      # FROM rewrite below still handles them via ident_pat.
      idents = stmt.scan(/"([^"]+)"|\[([^\]]+)\]/).flatten.compact
                   .map { |x| norm.call(x) }.reject(&:empty?).to_set
      best = nil
      entries.each do |entry|
        keys = (entry['columns'] || {}).keys.map { |k| norm.call(k) }.to_set
        ov = (idents & keys).size
        best = [ov, entry] if ov.positive? && (best.nil? || ov > best[0])
      end
      next unless best
      entry = best[1]
      # Multi-table guard: >1 FROM/JOIN, or a COMMA JOIN (`FROM a, b` — one
      # FROM, zero JOINs; v5.4.9 review fix: previously scored single-table and
      # got a half-rewritten `FROM <landed>, b`). Top-level comma test: take
      # the FROM clause up to the next clause keyword, drop parenthesized
      # groups (column lists of an inline subquery — itself caught by the
      # 2-FROM count), then look for a remaining comma.
      from_clause = stmt[/\bFROM\b(.*?)(?=\b(?:WHERE|GROUP\s+BY|ORDER\s+BY|HAVING|QUALIFY|LIMIT|UNION)\b|;|\z)/im, 1].to_s
      comma_join = from_clause.gsub(/\([^()]*\)/, '').include?(',')
      if stmt.scan(/\bFROM\b/i).size + stmt.scan(/\bJOIN\b/i).size > 1 || comma_join
        warn "custom-SQL element '#{el['name']}' references multiple tables#{comma_join ? ' (comma join)' : ''} — " \
             "NOT auto-remapped; repoint it with --table-mapping (landed table: #{entry['sf_table']})"
        next
      end
      ident_pat = %q{(?:"[^"]+"|\[[^\]]+\]|'[^']+'|[A-Za-z0-9_$#]+)}
      new_stmt = stmt.sub(/\bFROM\s+#{ident_pat}(?:\s*\.\s*#{ident_pat})*/i) { "FROM #{entry['sf_table']}" }
      (entry['columns'] || {}).each do |orig, landed|
        next if orig == landed
        new_stmt = new_stmt.gsub(/"#{Regexp.escape(orig)}"/, landed.to_s)
                           .gsub(/\[#{Regexp.escape(orig)}\]/, landed.to_s)
      end
      next if new_stmt == stmt
      el['source']['statement'] = new_stmt
      sql_remapped += 1
    end

    { colmap: colmap, elements: claimed_el.size, tables: tables, sql_elements: sql_remapped }
  end

  # v5.4: prune ORPHANED BROKEN elements from the converter model (the
  # union-collapse leftover class). The union-of-one collapse and other
  # relation rewrites can leave the converter emitting an element whose
  # cross-refs name elements that no longer exist, with nothing referencing
  # it — it compiles to type=error / 400s the POST while contributing
  # nothing. Prune ONLY when BOTH hold:
  #   (a) BROKEN: ≥1 formula ref [X/…] where X is neither an existing element
  #       name nor one of the element's own SOURCE identities (its name, its
  #       source path last segment, the sql-source 'Custom SQL' alias, or its
  #       source element's name) — source-relative refs are valid;
  #   (b) UNREFERENCED: no other element's formulas and no model relationship
  #       name it (by name or id), and it is not the kept fact.
  # Loud per-element log; returns the pruned names.
  def prune_broken_orphans!(model, keep: nil)
    els = all_elements(model)
    names = els.map { |e| e['name'].to_s }.reject(&:empty?)
    by_id = els.each_with_object({}) { |e, h| h[e['id'].to_s] = e }
    pruned = []
    els.each do |el|
      el_name = el['name'].to_s
      next if keep && el_name == keep.to_s
      own = [el_name,
             (el.dig('source', 'path') || []).last.to_s,
             'Custom SQL',
             by_id[el.dig('source', 'elementId').to_s] && by_id[el.dig('source', 'elementId').to_s]['name'].to_s]
            .compact.reject(&:empty?)
      refs = (Array(el['columns']) + Array(el['metrics']))
             .flat_map { |c| c['formula'].to_s.scan(/\[([^\[\]\/]+)\/[^\[\]]*\]/).flatten }.uniq
      broken = refs.reject { |r| names.include?(r) || own.include?(r) }
      next if broken.empty?
      referenced = els.any? do |other|
        next false if other.equal?(el)
        (Array(other['columns']) + Array(other['metrics'])).any? { |c| c['formula'].to_s.include?("[#{el_name}/") } ||
          other.dig('source', 'elementId').to_s == el['id'].to_s
      end
      referenced ||= Array(model['relationships']).any? do |r|
        blob = JSON.generate(r)
        blob.include?(el['id'].to_s) || (!el_name.empty? && blob.include?(el_name))
      end
      next if referenced
      pruned << el
    end
    pruned.each do |el|
      (model['pages'] || []).each { |p| (p['elements'] || []).delete(el) }
      warn "pruned ORPHANED BROKEN element '#{el['name']}' (#{el['id']}) from the DM spec — " \
           'unreferenced, with cross-refs to non-existent elements (union-collapse leftover class)'
    end
    pruned.map { |e| e['name'].to_s }
  end

  # Run the Tableau→Sigma converter. Two backends, same output contract
  # ({ model, warnings, stats, security }):
  #   - mcp_build present → node shim importing a LOCAL build/tableau.(m)js
  #     (fast/offline, no data egress). By default this is the VENDORED
  #     converter/tableau.mjs shipped in the skill (zero config — no clone, no
  #     npm install, no network); the orchestrator also auto-discovers a dev's
  #     fresher build when present. This is the normal path.
  #   - mcp_build nil     → the HOSTED converter MCP over HTTP
  #     (https://sigma-data-model-mcp.onrender.com/mcp via lib/mcp_convert.py),
  #     used ONLY on explicit --converter hosted opt-in (uploads the .twb).
  def run_converter(twb_path:, conn:, db:, schema:, mcp_build:, workdir:, datasource_index: 0, table_mapping: nil)
    return run_converter_hosted(twb_path: twb_path, conn: conn, db: db, schema: schema,
                                workdir: workdir, datasource_index: datasource_index,
                                table_mapping: table_mapping) if mcp_build.nil?
    shim = File.join(workdir, '_convert_tableau.mjs')
    raw_out = File.join(workdir, 'dm-raw.json')
    meta_out = File.join(workdir, 'conv-meta.json')
    # Node ESM on Windows rejects a bare drive-letter specifier
    # (`import ... from "C:/path/tableau.mjs"` → ERR_UNSUPPORTED_ESM_URL_SCHEME,
    # protocol 'c:'). Absolute paths must be file:// URLs there. POSIX absolute
    # paths import fine as-is, so we only rewrite on Windows and leave the
    # (working) macOS/Linux path byte-identical.
    import_specifier =
      if Gem.win_platform? && mcp_build.to_s.match?(/\A[A-Za-z]:/)
        'file:///' + mcp_build.gsub('\\', '/')
      else
        mcp_build
      end
    File.write(shim, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { convertTableauToSigma } from #{import_specifier.to_json};
      const xml = readFileSync(#{twb_path.to_json}, 'utf8');
      const out = convertTableauToSigma(xml, {
        connectionId: #{conn.to_json},
        database: #{db.to_json},
        schema: #{schema.to_json},
        tableMapping: #{(table_mapping || {}).to_json},
      });
      const bare = out.model || out.sigmaDataModel || out;
      writeFileSync(#{raw_out.to_json}, JSON.stringify(bare, null, 2));
      // Capture out.security too — detected RLS/CLS rules (architecture B:
      // reported, not injected). Dropping it here is how RLS silently
      // vanished from the orchestrated path; the orchestrator now gates on it.
      // workbookPatterns (param measure-pickers → control-driven Switch,
      // param-filters, window/LOD calcs) + parameters (control values/defaults)
      // are needed by the build layer to materialise controls/Switch tiles and by
      // the "Not Migrated (and why)" report — pass them through (was dropped).
      writeFileSync(#{meta_out.to_json}, JSON.stringify({ model: bare, warnings: out.warnings || [], stats: out.stats || {}, security: out.security || [], workbookPatterns: out.workbookPatterns || [], parameters: out.parameters || [] }, null, 2));
    JS
    o, e, st = Open3.capture3('node', shim)
    raise "converter failed: #{e}#{o}" unless st.success?
    JSON.parse(File.read(meta_out))
  end

  # Hosted backend: POST the .twb to the convert_tableau_to_sigma tool on the
  # sigma-data-model MCP over streamable HTTP, via the vendored stdlib client
  # (scripts/lib/mcp_convert.py). Maps the tool result onto the same shape the
  # node shim returns. RLS is reported, never injected — so if the hosted result
  # carries a model but no warnings/stats keys (an unexpected wrapper), we WARN
  # loudly rather than silently shipping an empty security[] (the RLS-never-
  # silently-dropped invariant).
  def run_converter_hosted(twb_path:, conn:, db:, schema:, workdir:, datasource_index: 0, table_mapping: nil)
    client = File.join(__dir__, 'lib', 'mcp_convert.py')
    raise "hosted converter client missing: #{client}" unless File.exist?(client)
    args = {
      'xml_content'      => { '@file' => twb_path },
      'connection_id'    => conn.to_s,
      'database'         => db.to_s,
      'schema'           => schema.to_s,
      'datasource_index' => datasource_index
    }
    args['table_mapping'] = table_mapping if table_mapping && !table_mapping.empty?
    args_file = File.join(workdir, 'conv-args.json')
    raw_text  = File.join(workdir, 'conv-hosted-out.json')
    meta_out  = File.join(workdir, 'conv-meta.json')
    File.write(args_file, JSON.pretty_generate(args))
    o, e, st = Open3.capture3(*PyResolve.argv, PyResolve.winpath(client), 'convert_tableau_to_sigma', PyResolve.winpath(args_file), PyResolve.winpath(raw_text))
    raise "hosted converter failed (sigma-data-model-mcp.onrender.com): #{e}#{o}" unless st.success?
    out = JSON.parse(File.read(raw_text))
    bare = out['model'] || out['sigmaDataModel'] || out
    has_wrapper = out.is_a?(Hash) && (out.key?('warnings') || out.key?('stats') || out.key?('security'))
    unless has_wrapper
      warn "WARN: hosted converter returned a bare model with no warnings/stats/security wrapper — " \
           'detected RLS/CLS may not have been surfaced. Verify security manually (RLS is never silently dropped).'
    end
    result = { 'model' => bare, 'warnings' => out['warnings'] || [],
               'stats' => out['stats'] || {}, 'security' => out['security'] || [],
               'workbookPatterns' => out['workbookPatterns'] || [], 'parameters' => out['parameters'] || [] }
    File.write(meta_out, JSON.pretty_generate(result))
    result
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
      # Columns on the base element, by their referenceable name — used to tell a
      # 3-segment relationship path apart from a 2-segment [Element/Column] ref
      # whose COLUMN NAME contains a literal '/' (e.g. a Snowflake column named
      # "Margin Pct H/L").
      src_cols = (src_el['columns'] || []).map { |cc| col_display(cc) }.compact
      (el['columns'] || []).each do |c|
        f = c['formula'].to_s
        m = f.match(/\A\[([^\/\]]+)\/([^\/\]]+)\/([^\]]+)\]\z/)
        next unless m
        next unless base_names.include?(m[1])
        next if rel_names.include?(m[2])
        # The '/'-split assumed [Base/REL/Field], but the middle isn't a known
        # relationship. If the whole tail after the base names a real column on
        # the base element, this is [Element/Column] with a slash in the column
        # name — a column ref, NOT an unreachable relationship. Don't flag it.
        next if src_cols.include?("#{m[2]}/#{m[3]}")
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
    # Binary / mixed-encoding .twb content (some exports embed non-UTF-8 bytes)
    # makes the raw caption regex .scan below throw "invalid byte sequence in
    # UTF-8", aborting the whole mechanical pass. Scrub to valid UTF-8 first.
    twb_xml = twb_xml.to_s.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
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
  def fixup_dm_spec(model, real_columns = nil, column_mapping: nil)
    begin
      require 'set'
      $LOAD_PATH.unshift File.expand_path('lib', __dir__)
      require 'sigma_functions'
    rescue LoadError, StandardError
      # fall back to the mini-blocklist in unknown_functions
    end
    real = {}
    # Index each real warehouse column under BOTH its space-preserved upper form
    # ("SALES REGION") and its underscore-folded upper form ("SALES_REGION"). The
    # phantom check derives `phys` by folding spaces→underscores, but the catalog
    # column may genuinely contain spaces (a quoted mixed-case Snowflake column
    # like "Sales Region"), so a single form would false-drop it. Additive only —
    # never drops a column that either form matches.
    (real_columns || {}).each do |t, cols|
      real[t.to_s.upcase] = cols.flat_map { |c| [c.to_s.upcase, c.to_s.gsub(/\s+/, '_').upcase] }.to_set
    end
    # Column-rename map (--column-mapping): a genuine extract-caption → warehouse
    # rename ("State" → STATE_PROVINCE) that separator-folding can't recover.
    # Keyed by the UPPER extract caption; value = the real warehouse column.
    colmap = {}
    (column_mapping || {}).each { |src, dest| colmap[src.to_s.strip.upcase] = dest.to_s.strip }
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
    remapped = 0
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
            # Before dropping a base column absent from the real table, try the
            # column-rename map: if the caption maps to a REAL warehouse column,
            # rewrite the ref to it and KEEP the original caption as the display
            # name (so downstream master/chart refs by caption still resolve).
            disp = tail.split('/').last
            dest = colmap[disp.to_s.strip.upcase] || colmap[phys]
            if dest && rc.include?(dest.upcase)
              tblname = (el.dig('source', 'path') || []).last.to_s
              c['name'] = disp if c['name'].to_s.empty?
              c['formula'] = "[#{tblname}/#{display_name(dest.upcase)}]"
              remapped += 1
              keep << c
            else
              drop[c['id']] = true
              dn = col_display(c)
              dropped_disp_by_el[el['id']] << dn if dn
              phantom += 1
            end
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
    { fixed: fixed, dropped: dropped.uniq, phantom: phantom, remapped: remapped }
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
    # A Custom SQL fact element is NAMELESS in the DM spec (rule 3), but Sigma
    # assigns it the name "Custom SQL" server-side. An empty fact_name makes every
    # master column formula an INVALID `[/Col]` (empty element segment) → the
    # workbook POSTs but renders EMPTY (all published-DS / Custom-SQL-sourced
    # workbooks). Fall back to the server-assigned name so refs are `[Custom SQL/Col]`.
    fact_name = 'Custom SQL' if fact_name.to_s.strip.empty?
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
    # Reuse-path completeness (bead: master-map omits reused-DM columns / finding #5).
    # The columns above come from the .twb-derived CONVERTER fact element. When a
    # DM is REUSED, its live fact element (real_labels = readback columnLabels) can
    # carry columns the converter never enumerated — e.g. a raw "Order Date" the
    # source only used via a "Month of Order Date" calc. Those were silently absent
    # from the master-map, forcing a manual --master-col override. UNION every
    # readback column not already covered so the master-map spans ALL fact columns.
    # Dedup on the suffix-stripped bare name so a converter "Region" already isn't
    # re-added as "Region (Store Dim)".
    (real_labels || []).each do |lbl|
      next if lbl.to_s.strip.empty?
      bare = lbl.sub(/\s*\([^)]*\)\s*\z/, '').strip
      next if bare.empty? || seen[bare.downcase]
      add.call(lbl, nil, lbl)
    end
    # FIXED-LOD helper surfacing (y9rd.10): a FIXED/INCLUDE/EXCLUDE LOD becomes a
    # separate grouped helper element related to the fact (rel named "FIXED <dims>"),
    # so its output measure (e.g. "Region Revenue LOD") is NOT a fact column and a
    # KPI/tile referencing it would be viz-pruned. The LOD value is a partition
    # broadcast (one value per link key, repeated per row) — exactly a many-to-one
    # relationship lookup — so surface each non-key helper column onto the master as
    # a 3-part cross-element ref [fact/REL/Field]. (Window helpers — rel "Window …" —
    # are ORDERED and context-dependent; they are deliberately NOT surfaced this way.)
    if model
      els_by_id ||= all_elements(model).each_with_object({}) { |e, h| h[e['id']] = e }
      (fact_el['relationships'] || []).each do |rel|
        next unless rel['name'].to_s =~ /\A(FIXED|INCLUDE|EXCLUDE)\b/i
        tgt = els_by_id[rel['targetElementId']]
        next unless tgt && tgt.dig('source', 'kind') == 'sql'
        key_ids = (rel['keys'] || []).map { |k| k['targetColumnId'] }
        (tgt['columns'] || []).each do |hc|
          next if key_ids.include?(hc['id'])
          dn = col_display(hc)
          next if dn.nil? || dn.to_s.empty? || dn =~ GUID_RE
          key = dn.downcase
          next if seen[key]
          seen[key] = true
          id = "m-#{slug(dn)}"
          master_columns << { 'id' => id, 'name' => dn, 'formula' => "[#{fact_name}/#{rel['name']}/#{dn}]" }
          entry = { 'id' => id, 'name' => dn }
          entry['format'] = hc['format'] if hc['format']
          rx = header_regex(dn)
          unless used_regex[rx]
            mmap[rx] = entry
            used_regex[rx] = true
          end
        end
      end
    end
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
  # theme: ThemeDerive.derive output (build-charts 'theme' key) — the
  # orchestrated path previously dropped it, so every mechanical run shipped
  # themeless even when the source declared fonts/canvas/palette (v5.0 fix).
  def build_wb_spec(name:, dm_id:, fact_eid:, master_columns:, chart_elements:, folder_id: nil,
                    data_elements: [], theme: nil)
    master = {
      'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'visibleAsSource' => false,
      'source' => { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => fact_eid },
      'columns' => master_columns, 'order' => master_columns.map { |c| c['id'] }
    }
    # v5.4: document-order the data page SOURCE-BEFORE-CONSUMER. The API
    # resolves element refs in document order at POST, so a helper emitted
    # before the sub-master it sources 400s (round-6 field: TopN Source before
    # its sub-master). Kahn-style passes: an element is placeable once its
    # source elementId is not among the still-unplaced data elements (already
    # placed, the master, or external — data-model refs, placeholders). A
    # cycle (impossible for generated helpers, but never trust input) falls
    # back to insertion order for the stuck remainder.
    remaining = (data_elements || []).dup
    ordered = []
    until remaining.empty?
      batch = remaining.select do |e|
        src = e.is_a?(Hash) ? e.dig('source', 'elementId').to_s : ''
        remaining.none? { |o| !o.equal?(e) && o.is_a?(Hash) && o['id'] == src }
      end
      batch = [remaining.first] if batch.empty?
      ordered.concat(batch)
      remaining -= batch
    end
    chart_pages =
      if chart_elements.is_a?(Array) && chart_elements.all? { |e| e.is_a?(Hash) && e.key?('elements') && e.key?('name') }
        chart_elements.each_with_index.map do |pg, i|
          page = { 'id' => "page-dash-#{i + 1}", 'name' => pg['name'], 'elements' => pg['elements'] }
          # v5.0: designed-background passthrough — build-charts attaches
          # backgroundImage to its page hashes; dropping it here silently
          # strips the art.
          page['backgroundImage'] = pg['backgroundImage'] if pg['backgroundImage']
          page
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
          'elements' => [master] + ordered },
        *chart_pages
      ]
    }
    spec['folderId'] = folder_id if folder_id
    ThemeDerive.apply!(spec, theme) if defined?(ThemeDerive)
    spec
  end

  # Bind an agent-authored (--wb-spec) workbook spec to the LIVE data model. The
  # agent authors the JSON before the DM is posted, so it can't know the real ids;
  # it uses two placeholders, substituted here against the readback:
  #   "__DM_ID__"               → the posted dataModelId (anywhere a string value)
  #   "__DM_ELEMENT__:<Name>"   → the readback element id whose name == <Name>
  #                               (case-insensitive); the fact element is also
  #                               reachable as "__DM_ELEMENT__:__FACT__".
  # An unresolved "__DM_ELEMENT__:<Name>" aborts loudly (same no-silent-misbind
  # contract as the mechanical grain-helper resolver in migrate-tableau.rb) — a
  # chart bound to a non-existent element would otherwise render blank.
  def bind_manual_wb_spec(node, dm_id:, fact_eid:, dm_els: [])
    by_name = {}
    (dm_els || []).each { |e| by_name[e['name'].to_s.strip.downcase] = e['id'] }
    walk = lambda do |n|
      case n
      when Hash  then n.transform_values { |v| walk.call(v) }
      when Array then n.map { |v| walk.call(v) }
      when String
        if n == '__DM_ID__'
          dm_id
        elsif n.start_with?('__DM_ELEMENT__:')
          want = n.split(':', 2).last.to_s.strip
          if want == '__FACT__'
            fact_eid
          else
            by_name[want.downcase] ||
              raise("--wb-spec references DM element '#{want}' but the posted data model has no element by that name " \
                    "(have: #{by_name.keys.join(', ')})")
          end
        else
          n
        end
      else n
      end
    end
    walk.call(node)
  end
end
