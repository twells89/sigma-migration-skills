#!/usr/bin/env ruby
# Hydrate a published-datasource (sqlproxy) Tableau workbook so the converter can
# build a real Sigma data model from it.
#
# THE PROBLEM (see also extract-custom-sql.rb): when a workbook connects to a
# *published data source* via <connection class='sqlproxy' dbname='<PubDS>'>, the
# actual Custom SQL lives in the published data source object on Tableau Server —
# NOT in the .twb. The .twb carries only a placeholder relation (table='[sqlproxy]')
# plus cached column metadata. Fed to the converter as-is, that yields a 0-column
# element pointing at a non-existent "sqlproxy" table → POST "Source not found".
#
# THE FIX (approach A — embed, don't post-process): splice the retrieved Custom
# SQL into the datasource as a <relation type='text'> and present the connection
# as the real warehouse connection. The existing converter then emits a normal
# kind:'sql' element — reusing all its proven Custom-SQL shaping (column formulas,
# LOD/window helpers, the mixed-case identifier quoting fix), with ZERO new
# data-model-shaping code here.
#
# To keep the emitted SQL Snowflake-safe regardless of the source column casing,
# the Custom SQL is WRAPPED and its output columns projected with upper-snake
# aliases:  SELECT "Sales Region" AS SALES_REGION, ... FROM ( <original SQL> ) t
# and the cached <metadata-records> remote-names are rewritten to those aliases
# (captions preserved for display). This means every downstream reference (fact
# columns, LOD GROUP BY / helper subqueries) resolves against a bare upper-snake
# identifier, which is exactly what the converter and Sigma expect.
#
# Usage (CLI):
#   ruby scripts/hydrate-custom-sql.rb \
#     --twb /tmp/<name>/workbook-content.twb \
#     --custom-sql /tmp/<name>/custom-sql.json \
#     [--columns /tmp/<name>/probed-columns.json]  # {"<PubDS or caption>": ["col", ...]}
#     --db CSA --schema TJ \
#     --out /tmp/<name>/workbook-hydrated.twb
#
# The module (HydrateCustomSql) is pure/offline and unit-tested by
# test-hydrate-custom-sql.rb.

require 'json'
require 'optparse'
require 'rexml/document'

module HydrateCustomSql
  module_function

  # Upper-snake alias for a warehouse output column — mirrors the converter's
  # normalizeColumnName so the spliced metadata-record remote-names line up with
  # the SQL output identifiers the converter expects.
  def alias_for(name)
    name.to_s.gsub(/[^A-Za-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').upcase
  end

  # Quote a source column reference only when it is NOT already a safe bare
  # identifier (has spaces / mixed case / punctuation / leading digit). Matches
  # the "only quote when needed" rule in the converter's identifier fix, so
  # already-uppercase columns pass through untouched.
  def quote_ref(name)
    a = alias_for(name)
    (name.to_s == a && name.to_s !~ /\A[0-9]/) ? name.to_s : %("#{name}")
  end

  # Wrap the original Custom SQL and project its output columns with upper-snake
  # aliases. The original query is preserved verbatim inside the subquery, so
  # arbitrarily complex SQL (joins, CTEs, expressions) is untouched.
  def wrap_sql(query, columns)
    raise ArgumentError, 'no output columns' if columns.nil? || columns.empty?
    proj = columns.map { |c| "#{quote_ref(c)} AS #{alias_for(c)}" }.join(', ')
    "SELECT #{proj} FROM (\n#{query.to_s.strip}\n) t"
  end

  # Derive the OUTPUT column names of a SELECT. A published DS's Custom SQL is the
  # authoritative source of its own columns (the .tds carries no <metadata-records>
  # / <cols> map, and the sqlproxy workbook doesn't cache them), so we read them
  # off the query itself. Finds the FINAL top-level SELECT (after any WITH CTEs),
  # splits its projection on top-level commas, and takes each item's output name:
  # `expr AS alias` → alias; `"Quoted"` / `t."Quoted"` → Quoted; `t.col`/`col` → col.
  # `SELECT *` (or an unnameable expr) → returns [] so the caller falls back to a
  # column probe rather than guessing.
  def parse_sql_columns(sql)
    s = sql.to_s.gsub(/\s+/, ' ').strip
    # Locate the last top-level SELECT and its matching FROM (paren depth 0).
    depth = 0; sel_at = nil; from_at = nil
    i = 0
    while i < s.length
      ch = s[i]
      if ch == "'" || ch == '"'
        q = ch; i += 1
        i += 1 while i < s.length && s[i] != q
      elsif ch == '('
        depth += 1
      elsif ch == ')'
        depth -= 1
      elsif depth.zero? && s[i, 7] =~ /\ASELECT\b/i && (i.zero? || s[i - 1] =~ /[^A-Za-z0-9_]/)
        sel_at = i; from_at = nil
      elsif depth.zero? && sel_at && s[i, 5] =~ /\AFROM\b/i && (s[i - 1] =~ /[^A-Za-z0-9_]/)
        from_at = i; break
      end
      i += 1
    end
    return [] unless sel_at && from_at
    proj = s[(sel_at + 6)...from_at].strip
    return [] if proj == '*' || proj.start_with?('DISTINCT *')
    # Split the projection on top-level commas.
    items = []; buf = +''; d = 0; j = 0
    while j < proj.length
      c = proj[j]
      if c == "'" || c == '"'
        q = c; buf << c; j += 1
        while j < proj.length && proj[j] != q
          buf << proj[j]; j += 1
        end
        buf << (proj[j] || '')
      elsif c == '('
        d += 1; buf << c
      elsif c == ')'
        d -= 1; buf << c
      elsif c == ',' && d.zero?
        items << buf.strip; buf = +''
      else
        buf << c
      end
      j += 1
    end
    items << buf.strip unless buf.strip.empty?
    items.map { |it| output_name_of(it) }.compact
  end

  # Output name of a single SELECT-list item.
  def output_name_of(item)
    it = item.strip
    return nil if it.empty? || it == '*'
    if (m = it.match(/\s+AS\s+("?)([^"]+)\1\s*\z/i)) || (m = it.match(/\s+AS\s+(\[)([^\]]+)\]\s*\z/i))
      return m[2].strip
    end
    # trailing quoted identifier: ... "Foo"  or  t."Foo"
    if (m = it.match(/"([^"]+)"\s*\z/))
      return m[1]
    end
    # bare dotted/simple identifier with no expression chars
    if it =~ /\A[A-Za-z_][\w.]*\z/
      return it.split('.').last
    end
    nil # an unaliased expression — can't name it safely
  end

  # The published-datasource contentUrl a sqlproxy connection points at
  # (<connection dbname='...'> and the sibling <repository-location id='...'>).
  def pds_content_url(ds)
    conn = ds.elements['connection']
    dbname = conn && conn.attributes['dbname'].to_s
    return dbname unless dbname.to_s.empty?
    rl = ds.elements['repository-location'] || ds.elements['.//repository-location']
    rl && rl.attributes['id'].to_s
  end

  # Quick check (cheap, offline): does this .twb have any top-level datasource on
  # a sqlproxy connection with no real relation? Used by the migrate orchestrator
  # to decide whether to run the (Tableau-token-requiring) hydration path at all.
  def twb_has_sqlproxy?(twb_path)
    return false unless File.exist?(twb_path)
    doc = REXML::Document.new(File.read(twb_path, encoding: 'UTF-8'))
    doc.each_element('/workbook/datasources/datasource') do |ds|
      conn = ds.elements['connection']
      return true if conn && sqlproxy_connection?(conn) && !has_real_relation?(conn)
    end
    false
  rescue StandardError
    false
  end

  # A sqlproxy / published-datasource connection carries no real schema of its own.
  def sqlproxy_connection?(conn)
    return false unless conn
    (conn.attributes['class'].to_s == 'sqlproxy')
  end

  # Does this datasource already carry embedded Custom SQL or a real base table?
  # (If so we leave it alone — nothing to hydrate.)
  def has_real_relation?(conn)
    return false unless conn
    conn.each_element('.//relation') do |rel|
      type = (rel.attributes['type'] || 'table').to_s
      tbl  = rel.attributes['table'].to_s
      return true if type == 'text' && !rel.text.to_s.strip.empty?
      return true if type == 'table' && !tbl.empty? && tbl != '[sqlproxy]' && tbl != '[Extract].[Extract]'
    end
    false
  end

  # Column names cached in the datasource's own <metadata-records> (the published
  # DS's real column names, as Tableau saw them). Fallback when no probe was run.
  def cached_columns(conn)
    cols = []
    conn.each_element('.//metadata-records/metadata-record') do |mr|
      remote = (mr.get_text('remote-name')&.value || '').strip
      cols << remote unless remote.empty?
    end
    cols
  end

  # The published-datasource name this sqlproxy connection points at
  # (<connection dbname='<PubDS>'>) — the join key to a custom-sql.json block's
  # downstreamDatasources / name.
  def published_ds_name(conn)
    (conn.attributes['dbname'] || '').to_s
  end

  # Pick the Custom SQL query for a datasource from the extracted blocks.
  #   1. a block whose downstreamDatasources name matches the sqlproxy dbname
  #   2. a block whose own name matches the dbname / datasource caption
  #   3. if exactly one block exists overall, use it (unambiguous)
  # Returns [query, block] or [nil, nil].
  def query_for(conn, ds_caption, blocks)
    pub = published_ds_name(conn)
    want = [pub, ds_caption].map { |s| s.to_s.downcase }.reject(&:empty?)

    by_downstream = blocks.find do |b|
      (b['downstreamDatasources'] || []).any? { |d| want.include?(d['name'].to_s.downcase) }
    end
    return [by_downstream['query'], by_downstream] if by_downstream && by_downstream['query']

    by_name = blocks.find { |b| want.include?(b['name'].to_s.downcase) }
    return [by_name['query'], by_name] if by_name && by_name['query']

    with_sql = blocks.select { |b| !b['query'].to_s.strip.empty? }
    return [with_sql.first['query'], with_sql.first] if with_sql.size == 1

    [nil, nil]
  end

  # Splice a resolved published-datasource relation into `ds`'s connection,
  # replacing the sqlproxy placeholder so the converter builds a real element.
  # Handles BOTH published-DS shapes:
  #   relation_type 'text'  → wrapped+aliased Custom SQL (columns required)
  #   relation_type 'table' → a real <relation type='table' table='[db].[schema].[T]'>
  # `db`/`schema` present the connection as a live warehouse (for text, they scope
  # the Sigma connection; for table, they qualify the table path when it isn't
  # already 3-part). Returns true if spliced.
  def splice_pds!(ds, relation_type:, db:, schema:, sql: nil, table_path: nil,
                  columns: [], warehouse_class: 'snowflake')
    conn = ds.elements['connection']
    return false unless conn
    rel_name = conn.elements['.//relation']&.attributes&.[]('name')
    rel_name = nil if rel_name.to_s.empty? || rel_name.to_s.downcase == 'sqlproxy'
    rel_name ||= (ds.attributes['caption'] || 'PublishedDS').to_s

    # Present as the real warehouse — sqlproxy/extract placeholders carry no schema.
    conn.attributes['class'] = warehouse_class
    conn.attributes['dbname'] = db if db && !db.empty?
    conn.attributes['schema'] = schema if schema && !schema.empty?
    conn.attributes.delete('channel'); conn.attributes.delete('directory')
    conn.attributes.delete('port');    conn.attributes.delete('server')

    # Drop placeholder relation(s), splice the real one.
    conn.elements.each('.//relation') { |r| r.parent.delete_element(r) }
    rel = REXML::Element.new('relation')
    rel.add_attribute('name', rel_name)

    if relation_type == 'table'
      return false if table_path.to_s.strip.empty?
      rel.add_attribute('type', 'table')
      rel.add_attribute('table', qualify_table(table_path, db, schema))
    else
      return false if sql.to_s.strip.empty? || columns.nil? || columns.empty?
      rel.add_attribute('type', 'text')
      rel.text = wrap_sql(sql, columns)
    end
    conn.add_element(rel)
    mr = conn.elements['metadata-records']
    conn.delete_element(rel) && conn.insert_before(mr, rel) if mr

    # For Custom SQL, the converter builds the element's columns from
    # <metadata-records>. A workbook on a published DS usually has NONE cached
    # (the columns live in the PDS), so we SYNTHESIZE them from the resolved
    # output columns — remote-name = the upper-snake output alias (matches the
    # wrapped SELECT), caption = the original display name. If a block already
    # exists we realign its remote-names instead. Without this the element POSTs
    # with 0 columns and every calc/LOD referencing it fails to resolve.
    if relation_type != 'table'
      existing = conn.elements['metadata-records']
      if columns && !columns.empty?
        # The parsed Custom SQL output is the AUTHORITATIVE column set — build a
        # full metadata-records block from it (remote-name = upper-snake output
        # alias, caption = display name), so the element exposes every Custom SQL
        # column, not just the ones this workbook happened to use. PRESERVE the
        # workbook's cached type/class per column when it matches (by alias or
        # caption) — only default to string/column for columns the workbook
        # didn't cache. (Sigma still re-resolves real types from the warehouse;
        # this just keeps Desktop's measure/dimension hints intact.)
        cached = {}
        existing&.each_element('metadata-record') do |m|
          rn = (m.get_text('remote-name')&.value || '').strip
          cap = (m.get_text('caption')&.value || '').strip
          info = { 'class' => (m.attributes['class'] || 'column'),
                   'ltype' => (m.get_text('local-type')&.value || '').strip,
                   'agg'   => (m.get_text('aggregation')&.value || '').strip }
          cached[alias_for(rn)] = info unless rn.empty?
          cached[cap.downcase] = info unless cap.empty?
        end
        existing&.remove
        mrs = REXML::Element.new('metadata-records')
        columns.each do |c|
          info = cached[alias_for(c)] || cached[c.to_s.downcase] || {}
          rec = mrs.add_element('metadata-record', 'class' => (info['class'] || 'column'))
          rec.add_element('remote-name').text = alias_for(c)
          rec.add_element('local-name').text = "[#{c}]"
          rec.add_element('parent-name').text = "[#{rel_name}]"
          rec.add_element('remote-alias').text = alias_for(c)
          rec.add_element('local-type').text = (info['ltype'].to_s.empty? ? 'string' : info['ltype'])
          rec.add_element('aggregation').text = info['agg'] unless info['agg'].to_s.empty?
          rec.add_element('caption').text = c
        end
        conn.add_element(mrs) # after the <relation> (canonical order)
      elsif existing
        # No parsed columns (e.g. SELECT * we couldn't expand) — best-effort:
        # realign whatever the workbook cached to the upper-snake output aliases.
        existing.each_element('metadata-record') do |m|
          rn = m.get_text('remote-name')
          next unless rn
          m.elements['remote-name'].text = alias_for(rn.value.strip)
        end
      end
    end
    true
  end

  # Ensure a table ref is fully qualified [db].[schema].[table] using the PDS's
  # db/schema when the ref has fewer than 3 parts.
  def qualify_table(table_path, db, schema)
    parts = table_path.to_s.scan(/\[([^\]]*)\]/).flatten
    parts = table_path.to_s.split('.').map { |p| p.gsub(/\A\[|\]\z/, '') } if parts.empty?
    parts = parts.reject(&:empty?)
    case parts.length
    when 1 then parts = [db, schema, parts[0]]
    when 2 then parts = [db, parts[0], parts[1]]
    end
    parts = parts.reject { |p| p.to_s.empty? }
    '[' + parts.join('].[') + ']'
  end

  # Back-compat: the original text-only splice (GraphQL-block path).
  def hydrate_datasource!(ds, query:, columns:, db:, schema:, warehouse_class: 'snowflake')
    splice_pds!(ds, relation_type: 'text', sql: query, columns: columns,
                db: db, schema: schema, warehouse_class: warehouse_class)
  end

  # Descriptor-driven hydration (the REST-chase path). `descriptors` is an array of
  #   { 'contentUrl'=>, 'relationType'=>'text'|'table', 'sql'=>, 'table'=>,
  #     'db'=>, 'schema'=>, 'columns'=>[...] }
  # produced by resolve-published-ds.rb (which downloads GET /datasources/{id}/content
  # and reads the inner .tds). Matches each sqlproxy datasource to a descriptor by
  # contentUrl (== the connection's dbname / repository-location id). This is the
  # PRIMARY path — reliable regardless of Metadata-API lineage lag.
  def hydrate_pds!(doc, descriptors:, db:, schema:, warehouse_class: 'snowflake')
    by_url = {}
    (descriptors || []).each { |d| by_url[d['contentUrl'].to_s.downcase] = d if d['contentUrl'] }
    hydrated = []
    doc.each_element('/workbook/datasources/datasource') do |ds|
      conn = ds.elements['connection']
      next unless conn && sqlproxy_connection?(conn) && !has_real_relation?(conn)
      url = pds_content_url(ds).to_s.downcase
      d = by_url[url]
      next unless d
      rtype = d['relationType'].to_s == 'table' ? 'table' : 'text'
      cols = d['columns'] || (rtype == 'text' ? parse_sql_columns(d['sql']) : [])
      d_db = d['db'].to_s.empty? ? db : d['db']
      d_schema = d['schema'].to_s.empty? ? schema : d['schema']
      ok = splice_pds!(ds, relation_type: rtype, sql: d['sql'], table_path: d['table'],
                       columns: cols, db: d_db, schema: d_schema, warehouse_class: warehouse_class)
      next unless ok
      hydrated << { 'caption' => (ds.attributes['caption'] || '').to_s, 'contentUrl' => d['contentUrl'],
                    'relationType' => rtype, 'columns' => cols.size, 'source' => 'rest-content' }
    end
    hydrated
  end

  # Walk all top-level datasources; hydrate every sqlproxy one we can resolve.
  # columns_by_key: optional {published-ds-or-caption(downcased) => [col,...]} from a probe.
  # Returns an array of {caption, published_ds, columns, source} for reporting.
  def hydrate!(doc, blocks:, columns_by_key: {}, db:, schema:, warehouse_class: 'snowflake')
    hydrated = []
    doc.each_element('/workbook/datasources/datasource') do |ds|
      conn = ds.elements['connection']
      next unless conn
      next unless sqlproxy_connection?(conn)
      next if has_real_relation?(conn)

      caption = (ds.attributes['caption'] || '').to_s
      pub = published_ds_name(conn)
      query, _blk = query_for(conn, caption, blocks)
      next if query.to_s.strip.empty?

      key_probe = [pub.downcase, caption.downcase].find { |k| columns_by_key.key?(k) }
      columns = key_probe ? columns_by_key[key_probe] : cached_columns(conn)
      col_source = key_probe ? 'probe' : 'cached-metadata'
      next if columns.nil? || columns.empty?

      if hydrate_datasource!(ds, query: query, columns: columns, db: db, schema: schema,
                             warehouse_class: warehouse_class)
        hydrated << { 'caption' => caption, 'published_ds' => pub,
                      'columns' => columns.size, 'column_source' => col_source }
      end
    end
    hydrated
  end
end

# ── CLI ──────────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  opts = {}
  OptionParser.new do |o|
    o.on('--twb PATH')         { |v| opts[:twb] = v }
    o.on('--pds PATH')         { |v| opts[:pds] = v }   # descriptors from resolve-published-ds.rb (PRIMARY)
    o.on('--custom-sql PATH')  { |v| opts[:csql] = v }  # GraphQL blocks (fallback)
    o.on('--columns PATH')     { |v| opts[:cols] = v }
    o.on('--db NAME')          { |v| opts[:db] = v }
    o.on('--schema NAME')      { |v| opts[:schema] = v }
    o.on('--warehouse-class C'){ |v| opts[:wcls] = v }
    o.on('--out PATH')         { |v| opts[:out] = v }
  end.parse!
  abort 'usage: --twb PATH --out PATH (--pds DESCRIPTORS.json  and/or  --custom-sql BLOCKS.json) [--db DB --schema SCHEMA]' \
    unless opts[:twb] && opts[:out] && (opts[:pds] || opts[:csql])

  wcls = opts[:wcls] || 'snowflake'
  doc = REXML::Document.new(File.read(opts[:twb], encoding: 'UTF-8'))
  hydrated = []

  # PRIMARY: REST-content descriptors (table + custom SQL, no lineage dependency).
  if opts[:pds] && File.exist?(opts[:pds])
    descriptors = JSON.parse(File.read(opts[:pds], encoding: 'UTF-8')) rescue []
    descriptors = [] unless descriptors.is_a?(Array)
    hydrated += HydrateCustomSql.hydrate_pds!(doc, descriptors: descriptors,
                                              db: opts[:db], schema: opts[:schema], warehouse_class: wcls)
  end

  # FALLBACK: GraphQL Custom SQL blocks (only for any sqlproxy DS still unresolved).
  if opts[:csql] && File.exist?(opts[:csql])
    blocks = JSON.parse(File.read(opts[:csql], encoding: 'UTF-8')) rescue []
    blocks = [] unless blocks.is_a?(Array)
    cols_by_key = {}
    if opts[:cols] && File.exist?(opts[:cols])
      (JSON.parse(File.read(opts[:cols], encoding: 'UTF-8')) rescue {}).each { |k, v| cols_by_key[k.to_s.downcase] = v }
    end
    hydrated += HydrateCustomSql.hydrate!(doc, blocks: blocks, columns_by_key: cols_by_key,
                                          db: opts[:db], schema: opts[:schema], warehouse_class: wcls)
  end

  if hydrated.empty?
    warn 'hydrate-custom-sql: no sqlproxy datasource could be hydrated (none found, or PDS/Custom SQL/columns unresolved). .twb copied unchanged.'
    File.write(opts[:out], File.read(opts[:twb], encoding: 'UTF-8'))
  else
    File.open(opts[:out], 'w') { |f| doc.write(f) }
    hydrated.each do |h|
      tag = h['contentUrl'] ? "PDS #{h['contentUrl'].inspect} (#{h['relationType']})" : "published DS #{h['published_ds'].inspect}"
      warn "  hydrated datasource #{h['caption'].inspect} → #{tag}, #{h['columns']} col(s) from #{h['source'] || h['column_source']}"
    end
  end
  puts "wrote #{opts[:out]} (#{hydrated.size} datasource(s) hydrated)"
end
