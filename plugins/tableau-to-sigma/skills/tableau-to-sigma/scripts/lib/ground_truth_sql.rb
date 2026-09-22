# frozen_string_literal: true
#
# ground_truth_sql.rb — derive per-tile GROUND-TRUTH WAREHOUSE SQL from the
# .twb signals (PR-5 part A, the PLAN-v3 centerpiece).
#
# INDEPENDENCE CONTRACT: everything here derives from the SOURCE workbook's
# own signals — parse-twb-layout zones (shelves, aggregations, filters),
# the .twb datasource join/table/filter specs, and the already-extracted calc
# formulas (calc-fields.json / the layout meta sidecar). NOTHING is imported
# from build-charts-from-signals.rb or read from the built wb-spec, so the
# oracle cannot share the builder's misreadings. The one documented common-mode
# residue is the calc-formula channel: a calc measure's SQL depends on the same
# extracted formula text the DM build translated — every such dependency is
# recorded per tile in provenance.calc_dependencies (name + formula_hash) so a
# translation bug is traceable; anchors remain the fully independent channel.
#
# PER-TILE CLASSIFICATION — the coverage ledger. Every parity-plan chart gets
# EXACTLY ONE entry with EXACTLY ONE classification; nothing silently drops out:
#   warehouse-sql        entry carries executable SQL:
#                          SELECT <dims>, <AGG(measure)> FROM <source tables
#                          joined per the .twb join spec> WHERE <worksheet +
#                          datasource/extract filters> GROUP BY <dims>
#   vds                  the tile's value is a window/table calc — Tableau must
#                          compute it (route to scripts/vds-oracle.rb, the
#                          existing window-calc oracle path)
#   anchor-only          blends / LOD / unsupported filter or calc constructs —
#                          rendered-source anchors are the only value oracle
#   unverifiable(reason) no source zone / no measures / no resolvable warehouse
#                          table — nothing numeric to verify against
#
# Ruby 2.6-compatible, offline (no network). Parsing via lib/twb_xml.rb;
# join/table FQN helpers reused from lib/join_plan.rb (the probe-side ledger
# lib — NOT the builder).

require 'json'
require 'digest'
require_relative 'twb_xml'
require_relative 'join_plan'

module GroundTruthSql
  VERSION = 1
  CLASSIFICATIONS = %w[warehouse-sql vds anchor-only unverifiable].freeze

  # Window/table-calc constructs → the vds classification (the existing
  # vds-oracle path executes the ORIGINAL formula server-side).
  WINDOW_RE = /\b(?:RUNNING_(?:SUM|AVG|COUNT|MIN|MAX)|WINDOW_[A-Z]+|RANK(?:_DENSE|_UNIQUE|_MODIFIED|_COMPETITION|_PERCENTILE)?|INDEX|FIRST|LAST|SIZE|TOTAL|LOOKUP|PREVIOUS_VALUE)\s*\(/i
  LOD_RE = /\{\s*(?:FIXED|INCLUDE|EXCLUDE)\b/i
  # Row-level constructs with no warehouse equivalent (or session-dependent).
  UNSUPPORTED_FN_RE = /\b(?:RAWSQL\w*|SCRIPT_\w+|USERNAME|USERDOMAIN|ISMEMBEROF|FULLNAME)\s*\(/i

  # Aggregate + row-level function whitelist for the mechanical SQL rewrite.
  # Anything OUTSIDE this set (IF/CASE/DATE fns/string fns/…) is refused —
  # the tile classifies anchor-only rather than shipping guessed SQL.
  AGG_FNS = %w[SUM AVG MIN MAX COUNT COUNTD MEDIAN].freeze
  ROW_FNS = %w[ZN ABS ROUND].freeze
  ALLOWED_WORDS = (AGG_FNS + ROW_FNS + %w[DISTINCT]).freeze

  # Shelf derivation prefix → SQL aggregate (parse-twb-layout MEASURE_PREFIXES).
  AGG_BY_DERIV = {
    'sum' => 'SUM', 'avg' => 'AVG', 'min' => 'MIN', 'max' => 'MAX',
    'count' => 'COUNT', 'cnt' => 'COUNT', 'countd' => 'COUNT(DISTINCT',
    'ctd' => 'COUNT(DISTINCT', 'median' => 'MEDIAN'
  }.freeze
  # column-instance derivation attr (KPI marks-card measures) → same mapping.
  AGG_BY_DERIVATION_ATTR = {
    'sum' => 'SUM', 'avg' => 'AVG', 'average' => 'AVG', 'min' => 'MIN',
    'max' => 'MAX', 'count' => 'COUNT', 'countd' => 'COUNT(DISTINCT',
    'median' => 'MEDIAN'
  }.freeze
  # Window-calc quick-calc shelf prefixes (pcto/rtot) → vds.
  VDS_DERIVS = %w[pcto rtot].freeze

  # Date-TRUNC shelf prefixes → DATE_TRUNC part. Date-PART prefixes → extract
  # function. Anything else date-shaped (mdy/md/qd/ymd …) is refused (honest).
  TRUNC_PARTS = { 'tyr' => 'YEAR', 'tqr' => 'QUARTER', 'tmn' => 'MONTH',
                  'twk' => 'WEEK', 'tdy' => 'DAY', 'thr' => 'HOUR',
                  'yr' => 'YEAR', 'qr' => 'QUARTER', 'mn' => 'MONTH',
                  'wk' => 'WEEK', 'dy' => 'DAY' }.freeze
  # yr/qr/mn/wk/dy on a DISCRETE pill is Tableau's date-PART; on shelves the
  # trunc form (tyr/tmn/…) is the continuous axis. Both map above: the trunc
  # translation (DATE_TRUNC) also GROUPs identically for the part case within
  # one year — close enough is NOT the bar here, so discrete date parts use
  # the extract function instead:
  PART_FNS = { 'yr' => 'YEAR', 'qr' => 'QUARTER', 'mn' => 'MONTH',
               'wk' => 'WEEK', 'dy' => 'DAY' }.freeze

  module_function

  # ---------------------------------------------------------------------------
  # .twb datasource graph: tables (name → FQN + columns), joins, worksheet →
  # datasource dependencies. db/schema complete published-VC paren labels the
  # same way join_plan.rb does.
  # ---------------------------------------------------------------------------
  def parse_twb(twb_xml, db: nil, schema: nil)
    xml = twb_xml.to_s.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '')
    doc = TwbXml.parse(xml)
    out = { 'datasources' => {}, 'worksheet_datasources' => {} }
    doc.elements.each('/workbook/datasources/datasource') do |ds|
      name = ds.attributes['name'].to_s
      caption = (ds.attributes['caption'] || name).to_s
      next if name == 'Parameters' || caption.start_with?('Parameter')

      # 2020.2+ RELATIONSHIP model (object-graph): one <object> per logical
      # table, <relationship> edges with key expressions. Parsed FIRST — its
      # <relation type='table'> nodes must not masquerade as a physical join.
      objects = []
      ds.elements.each('.//object-graph/objects/object') do |obj|
        rel = obj.elements[".//relation[@type='table']"]
        next unless rel
        tname = rel.attributes['name'].to_s
        cols = []
        rel.elements.each('columns/column') { |c| cols << c.attributes['name'].to_s }
        objects << {
          'id' => obj.attributes['id'].to_s,
          'caption' => (obj.attributes['caption'] || tname).to_s,
          'table_name' => tname,
          'fqn' => JoinPlan.vc_physical_fqn(tname, db, schema) || JoinPlan.twb_table_fqn(doc, rel),
          'columns' => cols
        }
      end
      field_owners = {}
      ds.elements.each('.//cols/map') do |map|
        key = map.attributes['key'].to_s.sub(/\A\[/, '').sub(/\]\z/, '')
        value = map.attributes['value'].to_s
        match = value.match(/\A\[([^\]]+)\]\.\[([^\]]+)\]\z/)
        next unless match
        owner = objects.find do |object|
          object['table_name'] == match[1] || object['caption'] == match[1]
        end
        field_owners[key] = owner['caption'] if owner
      end
      transformed_fields = []
      ds.elements.each(".//object-graph/objects/object//relation/columns/column") do |column|
        next if column.attributes['date-parse-format'].to_s.empty?
        transformed_fields << column.attributes['name'].to_s
      end
      relationships = []
      ds.elements.each('.//object-graph/relationships/relationship') do |r|
        eq = r.elements["expression[@op='=']"]
        sides = eq ? eq.elements.to_a('expression').map { |e| e.attributes['op'].to_s } : []
        first = r.elements['first-end-point']
        second = r.elements['second-end-point']
        next unless first && second && sides.size == 2
        relationships << { 'first' => first.attributes['object-id'].to_s,
                           'second' => second.attributes['object-id'].to_s,
                           'second_unique' => second.attributes['unique-key'].to_s == 'true',
                           'lexpr' => sides[0], 'rexpr' => sides[1] }
      end

      tables = []
      joins = []
      custom_sql = nil
      if objects.empty?
        ds.elements.each(".//relation[@type='table']") do |rel|
          tname = rel.attributes['name'].to_s
          next if tables.any? { |t| t['name'] == tname }
          cols = []
          rel.elements.each('columns/column') { |c| cols << c.attributes['name'].to_s }
          tables << {
            'name' => tname,
            'fqn'  => JoinPlan.vc_physical_fqn(tname, db, schema) || JoinPlan.twb_table_fqn(doc, rel),
            'columns' => cols
          }
        end
        ds.elements.each(".//relation[@type='text']") do |rel|
          custom_sql ||= rel.texts.map(&:value).join.strip if rel.respond_to?(:texts)
          custom_sql ||= rel.text.to_s.strip
        end
        ds.elements.each(".//relation[@type='join']") do |rel|
          pairs = []
          rel.elements.each("clause[@type='join']//expression[@op='=']") do |eq|
            sides = eq.elements.to_a('expression').map { |e| JoinPlan.parse_side(e.attributes['op']) }.compact
            pairs << { 'ltable' => sides[0][:table], 'lcol' => sides[0][:column],
                       'rtable' => sides[1][:table], 'rcol' => sides[1][:column] } if sides.size == 2
          end
          next if pairs.empty?
          joins << { 'join_type' => (rel.attributes['join'] || 'inner').to_s, 'pairs' => pairs }
        end
      end
      out['datasources'][name] = { 'name' => name, 'caption' => caption,
                                   'tables' => tables, 'joins' => joins,
                                   'objects' => objects, 'relationships' => relationships,
                                   'field_owners' => field_owners,
                                   'transformed_fields' => transformed_fields,
                                   'custom_sql' => custom_sql }
    end
    doc.elements.each('//worksheet') do |ws|
      wname = ws.attributes['name'].to_s
      next if wname.empty?
      deps = []
      ws.elements.each('.//datasource-dependencies') do |dd|
        deps << dd.attributes['datasource'].to_s
      end
      ws.elements.each('.//view/datasources/datasource') do |d|
        deps << d.attributes['name'].to_s
      end
      deps = deps.reject { |d| d.empty? || d == 'Parameters' }.uniq
      out['worksheet_datasources'][wname] = deps
    end
    out
  end

  # ---------------------------------------------------------------------------
  # Calc index: caption/internal-name → {name, formula, formula_hash, source}.
  # calc-fields.json (the DM-build translation input) wins; the layout meta's
  # columns_by_guid formulas fill gaps for calcs the scoped extraction dropped.
  # ---------------------------------------------------------------------------
  def calc_index(calc_fields, meta)
    idx = {}
    reg = lambda do |key, name, formula, source|
      k = key.to_s.sub(/\A\[/, '').sub(/\]\z/, '')
      return if k.empty? || formula.to_s.empty?
      idx[k] ||= { 'name' => name.to_s, 'formula' => formula.to_s,
                   'formula_hash' => Digest::SHA1.hexdigest(formula.to_s),
                   'source' => source }
    end
    Array(calc_fields.is_a?(Hash) ? calc_fields['calcs'] : nil).each do |c|
      next unless c.is_a?(Hash)
      f = c['formula']
      reg.call(c['name'], c['name'], f, 'calc-fields')
      reg.call(c['internal_name'], c['name'] || c['internal_name'], f, 'calc-fields')
    end
    cbg = meta.is_a?(Hash) ? meta['columns_by_guid'] : nil
    (cbg || {}).each do |guid, info|
      next unless info.is_a?(Hash) && info['formula']
      reg.call(guid, info['caption'] || guid, info['formula'], 'twb-meta')
      reg.call(info['caption'], info['caption'], info['formula'], 'twb-meta')
    end
    idx
  end

  # Parameter defaults: caption AND internal name → {value, datatype}.
  def param_index(meta)
    idx = {}
    Array(meta.is_a?(Hash) ? meta['parameters'] : nil).each do |p|
      next unless p.is_a?(Hash)
      rec = { 'value' => p['default_value'], 'datatype' => p['datatype'].to_s }
      cap = p['caption'].to_s
      nm  = p['name'].to_s.sub(/\A\[/, '').sub(/\]\z/, '')
      idx[cap] = rec unless cap.empty?
      idx[nm] ||= rec unless nm.empty?
    end
    idx
  end

  # ---------------------------------------------------------------------------
  # SQL text helpers
  # ---------------------------------------------------------------------------
  def sql_string(v)
    "'#{v.to_s.gsub("'", "''")}'"
  end

  def sql_literal(v, datatype)
    case datatype.to_s
    when 'integer', 'real' then v.to_s.strip
    else sql_string(v)
    end
  end

  def quote_alias(s)
    %("#{s.to_s.gsub('"', '""')}")
  end

  # Find the matching close paren for the '(' at src[open]. Returns its index
  # or nil (unbalanced). Quotes-aware enough for our whitelisted grammar.
  def match_paren(src, open)
    depth = 0
    i = open
    while i < src.length
      case src[i]
      when '(' then depth += 1
      when ')'
        depth -= 1
        return i if depth.zero?
      when "'"
        j = src.index("'", i + 1)
        return nil if j.nil?
        i = j
      end
      i += 1
    end
    nil
  end

  # Rewrite every `FN(inner)` call via the block: `yield(inner) → replacement`.
  def rewrite_calls(src, fn)
    out = src.dup
    loop do
      m = out.match(/\b#{fn}\s*\(/i)
      break unless m
      open = m.end(0) - 1
      close = match_paren(out, open)
      return nil if close.nil?
      inner = out[(open + 1)...close]
      out = out[0...m.begin(0)] + yield(inner) + out[(close + 1)..-1]
    end
    out
  end

  # Wrap aggregate denominators in NULLIF(x, 0): Tableau division by zero
  # yields NULL; unwrapped SQL would error the whole ground-truth query.
  def nullif_denominators(sql)
    out = sql.dup
    i = 0
    while (slash = out.index('/', i))
      rest = out[(slash + 1)..-1]
      m = rest.match(/\A\s*(SUM|AVG|MIN|MAX|COUNT|MEDIAN|COALESCE)\s*\(/i)
      unless m
        i = slash + 1
        next
      end
      open = slash + 1 + m.end(0) - 1
      close = match_paren(out, open)
      return sql if close.nil?
      call = out[(slash + 1)...(close + 1)]
      lead = call[/\A\s*/]
      repl = "#{lead}NULLIF(#{call.strip}, 0)"
      out = out[0...(slash + 1)] + repl + out[(close + 1)..-1]
      i = slash + 1 + repl.length
    end
    out
  end

  # ---------------------------------------------------------------------------
  # Formula → SQL expression translation (mechanical, whitelisted — refuses
  # anything it cannot rewrite verbatim instead of guessing).
  # Returns { 'status' => 'ok', 'sql' =>, 'deps' =>, 'params_used' => }
  #      or { 'status' => 'vds' | 'lod' | 'unsupported', 'reason' => }.
  # ctx: { 'calcs' =>, 'params' =>, 'resolve_col' => lambda(name)→sql|nil }
  def translate_formula(formula, ctx, depth = 0)
    f = formula.to_s.gsub(%r{//[^\n]*}, ' ').strip
    return { 'status' => 'unsupported', 'reason' => 'empty formula' } if f.empty?
    return { 'status' => 'vds', 'reason' => 'window/table-calc function' } if f =~ WINDOW_RE
    return { 'status' => 'lod', 'reason' => 'LOD expression ({FIXED/INCLUDE/EXCLUDE})' } if f =~ LOD_RE
    if (m = f.match(UNSUPPORTED_FN_RE))
      return { 'status' => 'unsupported', 'reason' => "#{m[0].sub(/\($/, '').strip}() has no warehouse equivalent" }
    end
    return { 'status' => 'unsupported', 'reason' => 'calc references nest too deep (>3 levels)' } if depth > 3

    deps = []
    params_used = {}

    # [Parameters].[X] → the parameter's CURRENT DEFAULT value (recorded).
    f = f.gsub(/\[Parameters?(?:\s*\([^)]*\))?\]\s*\.\s*\[([^\]]+)\]/i) do
      pname = Regexp.last_match(1)
      p = ctx['params'][pname]
      return { 'status' => 'unsupported', 'reason' => "parameter #{pname.inspect} has no recorded default value" } if p.nil?
      params_used[pname] = p['value']
      sql_literal(p['value'], p['datatype'])
    end

    # Whitelist check on every bare identifier OUTSIDE brackets/strings.
    masked = f.gsub(/\[[^\]]*\]/, ' ').gsub(/'[^']*'/, ' ')
    masked.scan(/[A-Za-z_][A-Za-z0-9_]*/).each do |word|
      next if ALLOWED_WORDS.include?(word.upcase)
      return { 'status' => 'unsupported',
               'reason' => "function/keyword #{word.inspect} is outside the mechanical SQL subset" }
    end

    # Bracket refs: parameter (bare caption) → literal; calc → recurse
    # (dependency recorded); else physical column via the resolver.
    sql = f.gsub(/\[([^\]]+)\]/) do
      name = Regexp.last_match(1)
      if (p = ctx['params'][name])
        params_used[name] = p['value']
        next sql_literal(p['value'], p['datatype'])
      end
      if (calc = ctx['calcs'][name])
        inner = translate_formula(calc['formula'], ctx, depth + 1)
        return inner unless inner['status'] == 'ok'
        deps << calc
        deps.concat(inner['deps'])
        params_used.merge!(inner['params_used'])
        next "(#{inner['sql']})"
      end
      col = ctx['resolve_col'].call(name)
      return { 'status' => 'unsupported', 'reason' => "field #{name.inspect} does not resolve to a warehouse column" } if col.nil?
      col
    end

    sql = rewrite_calls(sql, 'COUNTD') { |inner| "COUNT(DISTINCT #{inner.strip})" }
    return { 'status' => 'unsupported', 'reason' => 'unbalanced parentheses (COUNTD)' } if sql.nil?
    sql = rewrite_calls(sql, 'ZN') { |inner| "COALESCE(#{inner.strip}, 0)" }
    return { 'status' => 'unsupported', 'reason' => 'unbalanced parentheses (ZN)' } if sql.nil?
    sql = nullif_denominators(sql)

    { 'status' => 'ok', 'sql' => sql.strip, 'deps' => deps, 'params_used' => params_used }
  end

  def contains_aggregate?(sql)
    !!(sql =~ /\b(?:SUM|AVG|MIN|MAX|COUNT|MEDIAN)\s*\(/i)
  end

  # ---------------------------------------------------------------------------
  # FROM clause per the .twb join spec. Tables get positional aliases (T1…Tn);
  # returns { 'sql' =>, 'aliases' => {table name → alias}, 'joined' => [...] }
  # or { 'error' => reason [, 'anchor_only' => true] }.
  # meta supplies columns_by_guid for relationship-model key resolution.
  # ---------------------------------------------------------------------------
  def build_from(ds, meta = {})
    return build_from_relationships(ds, meta) unless Array(ds['objects']).empty?
    tables = ds['tables'] || []
    if tables.empty?
      sql = ds['custom_sql'].to_s
      return { 'error' => 'no warehouse table (or Custom SQL statement) resolvable from the .twb datasource' } if sql.empty?
      return { 'sql' => "FROM (#{sql}) T1", 'aliases' => {}, 'joined' => ['(custom sql)'] }
    end
    missing = tables.select { |t| t['fqn'].to_s.empty? }
    unless missing.empty?
      return { 'error' => "table(s) without a resolvable warehouse FQN: #{missing.map { |t| t['name'] }.join(', ')}" }
    end
    aliases = {}
    tables.each_with_index { |t, i| aliases[t['name']] = "T#{i + 1}" }
    joins = ds['joins'] || []
    if joins.empty? && tables.size > 1
      return { 'error' => "#{tables.size} tables but no parseable join clause in the .twb" }
    end
    first = tables.first
    lines = ["FROM #{first['fqn']} #{aliases[first['name']]}"]
    joined = [first['name']]
    joins.each do |j|
      pairs = j['pairs'].select { |p| aliases[p['ltable']] && aliases[p['rtable']] }
      return { 'error' => 'join clause references an unknown table' } if pairs.empty?
      # The table not yet in the FROM chain is the one this join introduces.
      new_side = pairs.first['rtable']
      new_side = pairs.first['ltable'] unless joined.include?(pairs.first['ltable'])
      next if joined.include?(new_side)
      t = tables.find { |x| x['name'] == new_side }
      kw = case j['join_type']
           when 'left' then 'LEFT JOIN'
           when 'right' then 'RIGHT JOIN'
           when 'full' then 'FULL OUTER JOIN'
           else 'JOIN'
           end
      on = pairs.map do |p|
        "#{aliases[p['ltable']]}.#{p['lcol']} = #{aliases[p['rtable']]}.#{p['rcol']}"
      end.join(' AND ')
      lines << "  #{kw} #{t['fqn']} #{aliases[new_side]} ON #{on}"
      joined << new_side
    end
    { 'sql' => lines.join("\n"), 'aliases' => aliases, 'joined' => joined }
  end

  # RELATIONSHIP (object-graph) model: FROM the first end-point of the first
  # relationship, LEFT JOIN each related object — but ONLY when every second
  # end-point is unique-keyed. A LEFT JOIN on equality to a UNIQUE key cannot
  # change the fact grain, so joining all related tables is fan-out-safe
  # without replicating Tableau's per-viz join culling. Any non-unique related
  # table → refuse (anchor_only): a fanned-out ground truth would be silently
  # wrong — the exact failure class this oracle exists to catch.
  def build_from_relationships(ds, meta)
    objects = ds['objects']
    rels = ds['relationships'] || []
    return { 'error' => 'relationship model with no relationship edges parseable', 'anchor_only' => true } if rels.empty?
    nonuniq = rels.reject { |r| r['second_unique'] }
    unless nonuniq.empty?
      return { 'error' => "relationship (object-graph) model: #{nonuniq.size} related table(s) not " \
                          'unique-keyed — per-viz join culling not derivable in part A (fan-out risk)',
               'anchor_only' => true }
    end
    missing = objects.select { |o| o['fqn'].to_s.empty? }
    unless missing.empty?
      return { 'error' => "object(s) without a resolvable warehouse FQN: #{missing.map { |o| o['caption'] }.join(', ')}" }
    end
    by_id = {}
    aliases = {}
    objects.each_with_index do |o, i|
      by_id[o['id']] = o
      a = "T#{i + 1}"
      aliases[o['id']] = a
      aliases[o['caption']] ||= a
    end
    cbg = meta.is_a?(Hash) ? (meta['columns_by_guid'] || {}) : {}
    key_sql = lambda do |expr, al, object_caption|
      s = expr.to_s
      resolved = true
      sql = s.gsub(/\[([^\]]+)\]/) do
        ref = Regexp.last_match(1).sub(/\s+\([^\]]*\)\z/, '') # '<guid> (DUP TABLE)' → guid
        info = cbg[ref]
        if info && info['caption']
          caption = info['caption'].to_s
          # parse-twb-layout disambiguates duplicate relationship fields by
          # appending " (<logical table caption>)". That suffix is display-only,
          # not part of the warehouse identifier (Product Key, not
          # PRODUCT_KEY_(PRODUCT_DIM_(WAREHOUSE.PRODUCT_DIM))).
          suffix = " (#{object_caption})"
          caption = caption[0...-suffix.length] if caption.end_with?(suffix)
          "#{al}.#{JoinPlan.physical_name(caption)}"
        elsif ref =~ /\A[0-9A-Fa-f-]{20,}\z/
          resolved = false
          ref
        else
          "#{al}.#{JoinPlan.physical_name(ref)}"
        end
      end
      resolved ? sql : nil
    end
    root_id = rels.first['first']
    root = by_id[root_id]
    return { 'error' => 'relationship root object unresolvable' } if root.nil?
    lines = ["FROM #{root['fqn']} #{aliases[root_id]}"]
    joined = [root_id]
    rels.each do |r|
      next if joined.include?(r['second'])
      unless joined.include?(r['first'])
        return { 'error' => "relationship chain does not start at #{by_id[r['first']] ? by_id[r['first']]['caption'] : r['first']}" }
      end
      o = by_id[r['second']]
      return { 'error' => 'relationship references an unknown object' } if o.nil?
      l = key_sql.call(r['lexpr'], aliases[r['first']], by_id[r['first']]['caption'])
      rr = key_sql.call(r['rexpr'], aliases[r['second']], by_id[r['second']]['caption'])
      if l.nil? || rr.nil?
        return { 'error' => "relationship key column unresolvable (no caption for the field GUID in the .twb)",
                 'anchor_only' => true }
      end
      lines << "  LEFT JOIN #{o['fqn']} #{aliases[r['second']]} ON #{l} = #{rr}"
      joined << r['second']
    end
    { 'sql' => lines.join("\n"), 'aliases' => aliases, 'joined' => joined.map { |id| by_id[id]['caption'] } }
  end

  # Column resolver for one datasource: physical name (or renamed
  # 'COL (TABLE)' cross-table form) → alias-qualified SQL identifier.
  def column_resolver(ds, aliases, meta = {})
    named = (ds['tables'] || []).map { |t| { 'key' => t['name'], 'columns' => t['columns'] } } +
            Array(ds['objects']).map { |o| { 'key' => o['caption'], 'columns' => o['columns'] } }
    owners = {}
    named.each do |t|
      (t['columns'] || []).each { |c| (owners[c] ||= []) << t['key'] }
    end
    field_owners = ds['field_owners'] || {}
    columns_by_guid = meta.is_a?(Hash) ? (meta['columns_by_guid'] || {}) : {}
    columns_by_guid.each do |guid, info|
      next unless info.is_a?(Hash) && field_owners[guid]
      caption = info['caption'].to_s.strip
      next if caption.empty?
      owner = field_owners[guid]
      caption_owners = (owners[caption] ||= [])
      caption_owners << owner unless caption_owners.include?(owner)
      physical = JoinPlan.physical_name(caption)
      physical_owners = (owners[physical] ||= [])
      physical_owners << owner unless physical_owners.include?(owner)
    end
    transformed_fields = Array(ds['transformed_fields'])
    lambda do |name, guid = nil|
      n = name.to_s.strip
      field_guid = guid.to_s.sub(/\A\[/, '').sub(/\]\z/, '')
      return nil if !field_guid.empty? && transformed_fields.include?(field_guid)
      table_hint = nil
      table_hint = field_owners[field_guid] unless field_guid.empty?
      if (m = n.match(/\A(.+?)\s+\(([^()]+)\)\z/))
        # Tableau's cross-table rename: 'REGION (REGION_DIM)'.
        cand_t = named.find { |t| t['key'] == m[2] || t['key'].start_with?("#{m[2]} (") }
        if cand_t
          table_hint = cand_t['key']
          n = m[1]
        end
      end
      col = JoinPlan.physical_name(n)
      own = owners[col] || owners[n]
      tbl = table_hint || (own && own.size == 1 ? own.first : nil)
      tbl ||= own.first if own && own.include?((named.first || {})['key'])
      if tbl && aliases[tbl]
        "#{aliases[tbl]}.#{col}"
      elsif own && own.first && aliases[own.first]
        "#{aliases[own.first]}.#{col}"
      else
        col # no (or ambiguous) column metadata — emit unqualified; the
        #     warehouse errors loudly on a genuinely ambiguous name
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Filters → WHERE clauses.
  # Returns { 'sql' =>, 'skip' => reason } (one of), or { 'error' => reason }
  # when the filter kind cannot be expressed (→ anchor-only).
  # ---------------------------------------------------------------------------
  def filter_clause(fi, ctx)
    return { 'skip' => 'action filter (dashboard interaction; default state applies no filter)' } if fi['kind'] == 'action' || fi['is_action']
    target = fi['column_caption'].to_s
    target = fi['column_guid'].to_s if target.empty?
    return { 'error' => 'filter target column unresolvable' } if target.empty?
    col =
      if (calc = ctx['calcs'][target])
        t = translate_formula(calc['formula'], ctx)
        return { 'error' => "filter on calc #{target.inspect}: #{t['reason'] || t['status']}" } unless t['status'] == 'ok'
        return { 'error' => "filter on aggregate calc #{target.inspect} (HAVING semantics not derivable)" } if contains_aggregate?(t['sql'])
        (ctx['filter_deps'] ||= []).concat([calc] + t['deps'])
        "(#{t['sql']})"
      else
        ctx['resolve_col'].call(target)
      end
    return { 'error' => "filter column #{target.inspect} does not resolve to a warehouse column" } if col.nil?

    case fi['kind']
    when 'list'
      return { 'error' => "native top-N filter on #{target.inspect} (rank semantics not derivable in v1)" } if fi['topn']
      unless Array(fi['condition_expressions']).empty?
        return { 'error' => "condition-expression filter on #{target.inspect} (not derivable in v1)" }
      end
      members = Array(fi['members'])
      if members.empty?
        return { 'skip' => "categorical filter on #{target.inspect} enumerates no members (Tableau 'All')" } unless fi['exclude']
        return { 'skip' => "exclude filter on #{target.inspect} excludes nothing" } if !fi['excludes_null']
        return { 'sql' => "#{col} IS NOT NULL" }
      end
      lits = members.map { |v| sql_literal(v, fi['datatype']) }.join(', ')
      if fi['exclude']
        sql = "#{col} NOT IN (#{lits})"
        sql += " AND #{col} IS NOT NULL" if fi['excludes_null']
        { 'sql' => sql }
      else
        { 'sql' => "#{col} IN (#{lits})" }
      end
    when 'wildcard'
      wc = fi['wildcard']
      return { 'error' => "unparseable wildcard filter on #{target.inspect}" } unless wc.is_a?(Hash)
      pat = wc['pattern'].to_s.gsub("'", "''")
      like = { 'contains' => "%#{pat}%", 'starts-with' => "#{pat}%", 'ends-with' => "%#{pat}" }
      mode = wc['mode'].to_s
      base = mode.sub(/\Adoes-not-(?:start-with|end-with|contain)\z/) do |x|
        x.sub('does-not-', '').sub('contain', 'contains')
      end
      p = like[base]
      return { 'error' => "wildcard mode #{mode.inspect} not derivable" } if p.nil?
      neg = mode.start_with?('does-not-')
      { 'sql' => "#{col} #{neg ? 'NOT ' : ''}LIKE '#{p}'" }
    when 'number-range'
      parts = []
      parts << "#{col} >= #{fi['min']}" if fi['min']
      parts << "#{col} <= #{fi['max']}" if fi['max']
      return { 'skip' => "quantitative filter on #{target.inspect} carries no bounds" } if parts.empty?
      { 'sql' => parts.join(' AND ') }
    when 'relative-date'
      { 'error' => "relative-date filter on #{target.inspect} (anchor 'today' not reproducible in v1)" }
    else
      { 'error' => "filter kind #{fi['kind'].inspect} on #{target.inspect} not derivable" }
    end
  end

  # ---------------------------------------------------------------------------
  # Shelf → dims / measures.
  # ---------------------------------------------------------------------------
  def shelf_fields(zone)
    rows = (zone['rows_shelf'] || {})['fields'] || []
    cols = (zone['cols_shelf'] || {})['fields'] || []
    # color channel: a dim on the color shelf adds a grouping level.
    chans = []
    ch = (zone['channels'] || {})['color']
    if ch.is_a?(Hash)
      raw = ch['column'] || ch[:column]
      chans << { 'raw' => raw.to_s, 'role' => 'dim', 'derivation' => nil,
                 'guid' => shelf_guid(raw.to_s) } unless raw.to_s.empty?
    end
    cols + rows + chans
  end

  # `[federated.X].[none:NAME:nk]` / `[NAME]` → NAME (same shapes
  # parse-twb-layout's guid_from_param resolves; local copy keeps this module
  # layout-parser-independent at runtime).
  def shelf_guid(raw)
    m = raw.to_s.match(%r{\.\[(?:[a-z\-]+:)?([0-9a-f\-]{36}|Calculation_\d+|[A-Za-z_][\w. ()/&-]*)(?::[a-z]+\d*)?\]\z}i)
    return m[1] if m
    m = raw.to_s.match(%r{\A\[(?:[a-z\-]+:)?([0-9a-f\-]{36}|Calculation_\d+|[A-Za-z_][\w. ()/&-]*)(?::[a-z]+\d*)?\]\z}i)
    m && m[1]
  end

  def caption_for(guid, meta)
    info = meta.is_a?(Hash) ? (meta['columns_by_guid'] || {})[guid] : nil
    (info && info['caption']) || guid
  end

  # Tableau relationship culling evaluates a chart that uses only one related
  # dimension table at that table's own grain (for example Avg(Customer
  # Lifetime Revenue) over CUSTOMER_DIM rows, not fact-weighted joined rows).
  # The v1 warehouse oracle cannot reproduce that culling/null-bucket contract
  # from the object graph alone, so route such tiles to valued anchors instead
  # of emitting a confidently wrong fact-rooted query.
  def related_object_grain(ds, fields)
    objects = Array(ds['objects'])
    relationships = Array(ds['relationships'])
    return nil if objects.empty? || relationships.empty?
    root = objects.find { |object| object['id'] == relationships.first['first'] }
    return nil unless root
    owners_by_guid = ds['field_owners'] || {}
    relevant = Array(fields).reject { |field| field['role'] == 'measure-names' }
    return nil if relevant.empty?
    owners = relevant.map do |field|
      guid = field['guid'] || shelf_guid(field['raw'])
      owners_by_guid[guid]
    end
    return nil if owners.any? { |owner| owner.to_s.empty? }
    unique = owners.uniq
    return nil unless unique.size == 1 && unique.first != root['caption']
    unique.first
  end

  # ---------------------------------------------------------------------------
  # Per-tile derivation. Returns the ledger entry.
  # ---------------------------------------------------------------------------
  def derive_tile(chart, zone, twb, meta, calcs, params, dash_name)
    entry = {
      'chart' => chart['chart'] || chart['name'],
      'tableau_view' => chart['tableau_view'] || zone && zone['caption'],
      'sigma_element_id' => chart['sigma_element_id'],
      'classification' => nil, 'reason' => nil, 'sql' => nil, 'columns' => nil,
      'provenance' => { 'dashboard' => dash_name, 'zone_id' => zone && zone['id'],
                        'worksheet' => zone && zone['caption'], 'datasource' => nil,
                        'dims' => [], 'measures' => [], 'filters' => [],
                        'filters_skipped' => [], 'calc_dependencies' => [],
                        'parameters' => {} }
    }
    classify = lambda do |cls, reason = nil|
      entry['classification'] = cls
      entry['reason'] = reason
      entry
    end
    return classify.call('unverifiable', 'no source dashboard zone/worksheet matched this tile') if zone.nil?

    ws = zone['caption'].to_s
    ds_names = (twb['worksheet_datasources'] || {})[ws] || []
    return classify.call('anchor-only', "data blend: worksheet depends on #{ds_names.size} datasources (#{ds_names.join(', ')})") if ds_names.size > 1
    ds = twb['datasources'][ds_names.first] || twb['datasources'].values.first
    return classify.call('unverifiable', 'no datasource resolvable for the worksheet') if ds.nil?
    entry['provenance']['datasource'] = ds['caption']

    # FROM derives up front (the resolver wants its aliases), but a FROM error
    # is only classified AFTER the shelf walk — a window-calc tile on an
    # underivable datasource is still `vds` (Tableau computes it), not
    # anchor-only/unverifiable.
    from = build_from(ds, meta)
    resolve_col = column_resolver(ds, from['aliases'] || {}, meta)
    ctx = { 'calcs' => calcs, 'params' => params, 'resolve_col' => resolve_col }
    from_fail = lambda do
      classify.call(from['anchor_only'] ? 'anchor-only' : 'unverifiable', from['error'])
    end

    # vds short-circuit: quick-calc window pills (pcto/rtot) on the tile.
    if Array(zone['quick_calc_pcto']).any?
      return classify.call('vds', 'percent-of-total quick calc on the marks card — Tableau computes it (vds-oracle path)')
    end

    fields = shelf_fields(zone)
    ownership_fields = fields.dup
    Array(zone['measures']).each do |measure|
      raw = measure.is_a?(Hash) ? measure['column'] : measure
      guid = shelf_guid(raw.to_s)
      ownership_fields << { 'role' => 'measure', 'guid' => guid, 'raw' => raw } if guid
    end
    if (grain_owner = related_object_grain(ds, ownership_fields))
      return classify.call(
        'anchor-only',
        "tile aggregates only #{grain_owner} fields; per-viz relationship culling/null semantics " \
        'require rendered-source anchors'
      )
    end
    dims = []
    measures = []
    calc_deps = []
    params_used = {}

    add_dep = lambda do |dep_list|
      dep_list.each do |d|
        calc_deps << { 'name' => d['name'], 'formula_hash' => d['formula_hash'], 'source' => d['source'] } \
          unless calc_deps.any? { |x| x['formula_hash'] == d['formula_hash'] }
      end
    end

    fields.each do |fld|
      guid = fld['guid'] || shelf_guid(fld['raw'])
      next if fld['role'] == 'measure-names'
      next if guid.nil? && fld['role'] != 'measure-names'
      cap = caption_for(guid, meta)
      # A dim already grouped (e.g. the color-channel copy of a shelf dim) adds nothing.
      next if fld['role'] == 'dim' && dims.any? { |d| d['alias'] == cap || d['alias'].to_s.start_with?("#{cap} (") }
      if fld['role'] == 'dim'
        deriv = fld['derivation'].to_s
        if (calc = calcs[guid.to_s] || calcs[cap.to_s])
          t = translate_formula(calc['formula'], ctx)
          return classify.call('vds', "dimension calc #{cap.inspect} is a window/table calc") if t['status'] == 'vds'
          unless t['status'] == 'ok'
            return classify.call('anchor-only', "dimension #{cap.inspect}: #{t['reason'] || t['status']}")
          end
          return classify.call('anchor-only', "dimension calc #{cap.inspect} aggregates (not a row-level grouping)") if contains_aggregate?(t['sql'])
          add_dep.call([calc] + t['deps'])
          params_used.merge!(t['params_used'])
          dims << { 'raw' => fld['raw'], 'sql' => "(#{t['sql']})", 'alias' => cap }
        elsif deriv.empty? || deriv == 'none'
          col = resolve_col.call(cap, fld['guid'])
          return classify.call('anchor-only', "dimension #{cap.inspect} does not resolve to a warehouse column") if col.nil?
          dims << { 'raw' => fld['raw'], 'sql' => col, 'alias' => cap }
        elsif TRUNC_PARTS[deriv]
          col = resolve_col.call(cap, fld['guid'])
          return classify.call('anchor-only', "date dimension #{cap.inspect} does not resolve to a warehouse column") if col.nil?
          if deriv.start_with?('t')
            dims << { 'raw' => fld['raw'], 'sql' => "DATE_TRUNC('#{TRUNC_PARTS[deriv]}', #{col})",
                      'alias' => "#{cap} (#{TRUNC_PARTS[deriv].downcase})" }
          else
            dims << { 'raw' => fld['raw'], 'sql' => "#{PART_FNS[deriv]}(#{col})",
                      'alias' => "#{cap} (#{PART_FNS[deriv].downcase} part)" }
          end
        else
          return classify.call('anchor-only', "dimension derivation #{deriv.inspect} on #{cap.inspect} not derivable")
        end
      elsif fld['role'] == 'measure'
        deriv = fld['derivation'].to_s.downcase
        return classify.call('vds', "shelf quick-calc #{deriv.inspect} on #{cap.inspect} — Tableau computes it (vds-oracle path)") if VDS_DERIVS.include?(deriv)
        if %w[usr user].include?(deriv)
          calc = calcs[guid.to_s] || calcs[cap.to_s]
          return classify.call('anchor-only', "user-aggregated measure #{cap.inspect} has no recorded formula") if calc.nil?
          t = translate_formula(calc['formula'], ctx)
          return classify.call('vds', "measure #{cap.inspect} is a window/table calc — Tableau computes it (vds-oracle path)") if t['status'] == 'vds'
          return classify.call('anchor-only', "measure #{cap.inspect}: #{t['reason'] || t['status']}") unless t['status'] == 'ok'
          sql = t['sql']
          sql = "SUM(#{sql})" unless contains_aggregate?(sql) # row-level calc summed by Tableau's default
          add_dep.call([calc] + t['deps'])
          params_used.merge!(t['params_used'])
          measures << { 'raw' => fld['raw'], 'agg' => 'usr', 'sql' => sql, 'alias' => cap }
        elsif AGG_BY_DERIV[deriv]
          if (calc = calcs[guid.to_s] || calcs[cap.to_s])
            t = translate_formula(calc['formula'], ctx)
            return classify.call('vds', "measure calc #{cap.inspect} is a window/table calc") if t['status'] == 'vds'
            return classify.call('anchor-only', "measure #{cap.inspect}: #{t['reason'] || t['status']}") unless t['status'] == 'ok'
            return classify.call('anchor-only', "aggregate-of-aggregate on #{cap.inspect} not derivable") if contains_aggregate?(t['sql'])
            add_dep.call([calc] + t['deps'])
            params_used.merge!(t['params_used'])
            inner = "(#{t['sql']})"
          else
            inner = resolve_col.call(cap, fld['guid'])
            return classify.call('anchor-only', "measure #{cap.inspect} does not resolve to a warehouse column") if inner.nil?
          end
          agg = AGG_BY_DERIV[deriv]
          sql = agg.end_with?('(DISTINCT') ? "#{agg} #{inner})" : "#{agg}(#{inner})"
          measures << { 'raw' => fld['raw'], 'agg' => deriv, 'sql' => sql, 'alias' => "#{cap} (#{deriv})" }
        else
          return classify.call('anchor-only', "aggregation #{deriv.inspect} on #{cap.inspect} not derivable (ATTR/stdev/var family)")
        end
      end
    end

    # KPI / marks-card measures (empty shelves): the worksheet's
    # column-instance measures list.
    if measures.empty?
      Array(zone['measures']).each do |mz|
        guid = shelf_guid(mz['column'])
        next if guid.nil?
        cap = caption_for(guid, meta)
        d = mz['derivation'].to_s.downcase
        if %w[user usr].include?(d)
          calc = calcs[guid.to_s] || calcs[cap.to_s]
          return classify.call('anchor-only', "user-aggregated measure #{cap.inspect} has no recorded formula") if calc.nil?
          t = translate_formula(calc['formula'], ctx)
          return classify.call('vds', "measure #{cap.inspect} is a window/table calc — Tableau computes it (vds-oracle path)") if t['status'] == 'vds'
          return classify.call('anchor-only', "measure #{cap.inspect}: #{t['reason'] || t['status']}") unless t['status'] == 'ok'
          sql = t['sql']
          sql = "SUM(#{sql})" unless contains_aggregate?(sql)
          add_dep.call([calc] + t['deps'])
          params_used.merge!(t['params_used'])
          measures << { 'raw' => mz['column'], 'agg' => 'usr', 'sql' => sql, 'alias' => cap }
        elsif AGG_BY_DERIVATION_ATTR[d]
          measure_guid = mz['column'].to_s.sub(/\A\[/, '').sub(/\]\z/, '')
          inner = resolve_col.call(cap, measure_guid)
          return classify.call('anchor-only', "measure #{cap.inspect} does not resolve to a warehouse column") if inner.nil?
          agg = AGG_BY_DERIVATION_ATTR[d]
          sql = agg.end_with?('(DISTINCT') ? "#{agg} #{inner})" : "#{agg}(#{inner})"
          measures << { 'raw' => mz['column'], 'agg' => d, 'sql' => sql, 'alias' => "#{cap} (#{d})" }
        else
          return classify.call('anchor-only', "measure derivation #{mz['derivation'].inspect} on #{cap.inspect} not derivable")
        end
      end
    end

    return from_fail.call if from['error']
    return classify.call('unverifiable', 'no measures derivable from the worksheet shelves/marks card') if measures.empty?

    # Filters: worksheet-level, then datasource/extract-level (post-#414 parse).
    where = []
    ctx['filter_deps'] = []
    Array(zone['filters']).each do |fi|
      r = filter_clause(fi, ctx)
      return classify.call('anchor-only', r['error']) if r['error']
      if r['skip']
        entry['provenance']['filters_skipped'] << { 'column' => fi['column_caption'] || fi['column_guid'],
                                                    'source' => 'worksheet', 'reason' => r['skip'] }
      else
        where << r['sql']
        entry['provenance']['filters'] << { 'column' => fi['column_caption'] || fi['column_guid'],
                                            'source' => 'worksheet', 'kind' => fi['kind'], 'sql' => r['sql'] }
      end
    end
    ds_label = ds['caption'].to_s
    ds_name = ds['name'].to_s
    Array(meta.is_a?(Hash) ? meta['datasource_filters'] : nil).each do |fi|
      next unless [fi['datasource'].to_s, fi['datasource_name'].to_s].include?(ds_label) ||
                  [fi['datasource'].to_s, fi['datasource_name'].to_s].include?(ds_name)
      r = filter_clause(fi, ctx)
      return classify.call('anchor-only', "datasource filter: #{r['error']}") if r['error']
      if r['skip']
        entry['provenance']['filters_skipped'] << { 'column' => fi['column_caption'] || fi['column_guid'],
                                                    'source' => fi['filter_scope'] || 'datasource', 'reason' => r['skip'] }
      else
        where << r['sql']
        entry['provenance']['filters'] << { 'column' => fi['column_caption'] || fi['column_guid'],
                                            'source' => fi['filter_scope'] || 'datasource',
                                            'kind' => fi['kind'], 'sql' => r['sql'] }
      end
    end
    add_dep.call(ctx['filter_deps'])

    # Assemble.
    select_parts = dims.map { |d| "#{d['sql']} AS #{quote_alias(d['alias'])}" } +
                   measures.map { |m| "#{m['sql']} AS #{quote_alias(m['alias'])}" }
    sql_lines = ["SELECT #{select_parts.join(",\n       ")}", from['sql']]
    sql_lines << "WHERE #{where.join("\n  AND ")}" unless where.empty?
    unless dims.empty?
      pos = (1..dims.size).to_a.join(', ')
      sql_lines << "GROUP BY #{pos}"
      sql_lines << "ORDER BY #{pos}"
    end
    entry['sql'] = sql_lines.join("\n")
    entry['columns'] = dims.map { |d| { 'alias' => d['alias'], 'role' => 'dim' } } +
                       measures.map { |m| { 'alias' => m['alias'], 'role' => 'measure' } }
    entry['provenance']['dims'] = dims
    entry['provenance']['measures'] = measures
    entry['provenance']['calc_dependencies'] = calc_deps
    entry['provenance']['parameters'] = params_used
    classify.call('warehouse-sql')
  end

  # ---------------------------------------------------------------------------
  # Whole-plan derivation. charts = parity-plan charts array; dashboards =
  # dashboard-layout.json array; meta = *-meta.json Hash; twb_xml = raw .twb
  # text; calc_fields = calc-fields.json Hash (or nil).
  # ---------------------------------------------------------------------------
  # ---------------------------------------------------------------------------
  # VDS-oracle fan-out hazard (Twin-B e2e 2026-07-19). VDS queries the
  # datasource through Tableau's LOGICAL layer: relationship joins are CULLED
  # per-viz, so VDS returns UN-FANNED data. A tile whose rendered value is fed
  # by a fan-out join (a .twb join whose right side is NOT proven unique on
  # the keys) therefore gets a VDS answer that can AGREE with a Sigma build
  # that silently dropped the join — a false-green oracle for the exact defect
  # gate 16 exists to catch. When the join-plan ledger carries an entry for
  # one of the tile's datasource tables that is not status "unique", the vds
  # classification is demoted to anchor-only with the hazard named; rendered-
  # source anchors (which DO see the fan-out) carry the value bar instead.
  # No ledger (nil) → no demotion: old workdirs/tests keep their behavior, and
  # in a gated run the ledger always exists by the time this derivation runs.
  def demote_vds_fanout!(entry, twb, join_ledger)
    return entry unless entry['classification'] == 'vds' && join_ledger.is_a?(Array)
    unproven = join_ledger.select do |j|
      j.is_a?(Hash) && j['kind'] == 'federated-join' && j['status'].to_s != 'unique'
    end
    return entry if unproven.empty?
    ds = (twb['datasources'] || {}).values
                                   .find { |d| d['caption'] == entry.dig('provenance', 'datasource') }
    return entry unless ds
    names = Array(ds['tables']).map { |t| t['name'] } +
            Array(ds['objects']).flat_map { |o| [o['caption'], o['id']] }
    fqns = (Array(ds['tables']) + Array(ds['objects'])).map { |t| t['fqn'] }.compact
    hit = unproven.find do |j|
      names.include?(j['left']) || names.include?(j['right']) ||
        (j['right_table'] && fqns.include?(j['right_table']))
    end
    return entry unless hit
    entry['classification'] = 'anchor-only'
    entry['reason'] = "vds-oracle unsafe: tile datasource carries join #{hit['left']} -> #{hit['right']} " \
                      "(ledger status #{(hit['status'] || 'unprobed').inspect}, not proven unique) — VDS reads " \
                      'relationship-culled (un-fanned) data and would false-green a dropped/fanned join; ' \
                      "was vds: #{entry['reason']}"
    entry
  end

  # join_ledger: the workdir's join-plan.json entries (lib/join_plan.rb), when
  # available — used to demote the vds classification on fan-out-fed tiles
  # (see demote_vds_fanout! above). nil → no demotion (back-compat).
  def derive(charts, dashboards, meta, twb_xml, calc_fields, db: nil, schema: nil, join_ledger: nil)
    twb = parse_twb(twb_xml, db: db, schema: schema)
    calcs = calc_index(calc_fields, meta)
    params = param_index(meta)

    zones_by_caption = {}
    Array(dashboards).each do |d|
      Array(d['zones']).each do |z|
        next unless z['kind'] == 'chart' && z['caption']
        zones_by_caption[z['caption'].to_s] ||= [d['dashboard'], z]
        zones_by_caption[z['caption'].to_s.downcase] ||= [d['dashboard'], z]
      end
    end

    entries = Array(charts).map do |c|
      view = (c['tableau_view'] || c['chart'] || c['name']).to_s
      dash, zone = zones_by_caption[view] || zones_by_caption[view.downcase]
      e = derive_tile(c, zone, twb, meta, calcs, params, dash)
      demote_vds_fanout!(e, twb, join_ledger)
      e
    end

    counts = Hash.new(0)
    entries.each { |e| counts[e['classification']] += 1 }
    {
      'version' => VERSION,
      'entries' => entries,
      'summary' => {
        'tiles' => entries.size,
        'warehouse_sql' => counts['warehouse-sql'],
        'vds' => counts['vds'],
        'anchor_only' => counts['anchor-only'],
        'unverifiable' => counts['unverifiable'],
        'coverage_complete' => entries.size == Array(charts).size
      }
    }
  end
end
