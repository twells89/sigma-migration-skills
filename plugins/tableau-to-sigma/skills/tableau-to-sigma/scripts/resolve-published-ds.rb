#!/usr/bin/env ruby
# Resolve the PUBLISHED data sources (PDS) behind a workbook's sqlproxy connections
# and emit a descriptor per PDS that hydrate-custom-sql.rb can splice into the .twb.
#
# WHY (see PUBLISHED_DS_FINDINGS): a workbook on a published DS carries only a
# <connection class='sqlproxy'> placeholder — the real relation (a warehouse table
# OR a Custom SQL <relation type='text'>) lives in the PDS object on Tableau Server.
# The RELIABLE way to get it is the REST content download, NOT the Metadata GraphQL
# lineage (which lags for hours on fresh PDSes and whose downstream links are often
# empty). We resolve the PDS by contentUrl (== the sqlproxy `dbname` /
# <repository-location id>), GET /datasources/{id}/content, and read the inner .tds.
#
# Output: JSON array of
#   { "caption":, "contentUrl":, "relationType": "text"|"table",
#     "sql":, "table":, "db":, "schema":, "columns": [...] }
#
# Usage:
#   eval "$(scripts/get-tableau-token.sh)"
#   ruby scripts/resolve-published-ds.rb --twb /tmp/<name>/workbook-content.twb --out /tmp/<name>/pds.json

require 'json'
require 'optparse'
require 'rexml/document'
require 'tempfile'
require 'open3'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'tableau_rest'
require_relative 'hydrate-custom-sql'

opts = {}
OptionParser.new do |o|
  o.on('--twb PATH') { |v| opts[:twb] = v }
  o.on('--out PATH') { |v| opts[:out] = v }
end.parse!
abort 'usage: --twb PATH --out PATH' unless opts[:twb] && opts[:out]

# Extract the inner .tds text from a datasource content download (a .tdsx zip, or
# a bare .tds when there's no extract).
def tds_text_from(bytes)
  if bytes[0, 2] == 'PK' # zip
    Tempfile.create(['pds', '.tdsx']) do |f|
      f.binmode; f.write(bytes); f.flush
      names, _ = Open3.capture2('unzip', '-Z1', f.path)
      tds = names.lines.map(&:chomp).find { |n| n.end_with?('.tds') }
      return nil unless tds
      out, st = Open3.capture2('unzip', '-p', f.path, tds)
      return st.success? ? out : nil
    end
  else
    bytes
  end
end

# Read {relationType, sql|table, db, schema} out of a PDS .tds.
def descriptor_from_tds(tds_text)
  doc = REXML::Document.new(tds_text)
  # Prefer a Custom SQL relation; else the first real table relation.
  text_rel = nil; table_rel = nil
  doc.each_element('//relation') do |r|
    type = (r.attributes['type'] || 'table').to_s
    if type == 'text' && !r.text.to_s.strip.empty?
      text_rel ||= r
    elsif type == 'table'
      tbl = r.attributes['table'].to_s
      table_rel ||= r unless tbl.empty? || tbl == '[sqlproxy]' || tbl == '[Extract].[Extract]'
    end
  end
  rel = text_rel || table_rel
  return nil unless rel
  # The connection carrying db/schema (skip the federated wrapper).
  conn = nil
  doc.each_element('//connection') do |c|
    cls = c.attributes['class'].to_s
    next if cls == 'federated' || cls.empty?
    conn = c; break
  end
  conn ||= doc.elements['//connection']
  db = conn && conn.attributes['dbname'].to_s
  schema = conn && conn.attributes['schema'].to_s
  if text_rel
    { 'relationType' => 'text', 'sql' => rel.text.to_s.strip, 'db' => db, 'schema' => schema,
      'columns' => HydrateCustomSql.parse_sql_columns(rel.text.to_s) }
  else
    { 'relationType' => 'table', 'table' => rel.attributes['table'].to_s, 'db' => db, 'schema' => schema, 'columns' => [] }
  end
end

doc = REXML::Document.new(File.read(opts[:twb], encoding: 'UTF-8'))
descriptors = []
seen = {}
doc.each_element('/workbook/datasources/datasource') do |ds|
  conn = ds.elements['connection']
  next unless conn && HydrateCustomSql.sqlproxy_connection?(conn) && !HydrateCustomSql.has_real_relation?(conn)
  content_url = HydrateCustomSql.pds_content_url(ds)
  caption = (ds.attributes['caption'] || '').to_s
  next if content_url.to_s.empty? || seen[content_url]
  seen[content_url] = true

  rec = begin
    Tableau.find_datasource_by_content_url(content_url)
  rescue Tableau::Error => e
    warn "  ⚠ PDS lookup failed for contentUrl=#{content_url.inspect}: #{e.message.lines.first&.chomp}"
    nil
  end
  unless rec && rec['id']
    warn "  ⚠ could not resolve published DS for contentUrl=#{content_url.inspect} (not found on site / no permission)"
    next
  end

  begin
    bytes = Tableau.download_datasource_content(rec['id'])
    tds = tds_text_from(bytes)
    d = tds && descriptor_from_tds(tds)
    unless d
      warn "  ⚠ downloaded PDS #{content_url.inspect} but found no usable relation in its .tds"
      next
    end
    d['caption'] = caption
    d['contentUrl'] = content_url
    d['pdsName'] = rec['name']
    d['pdsLuid'] = rec['id']
    descriptors << d
    detail = d['relationType'] == 'text' ? "Custom SQL, #{d['columns'].size} col(s)" : "table #{d['table']}"
    warn "  resolved PDS #{rec['name'].inspect} (#{content_url}) → #{detail}"
  rescue Tableau::Error => e
    warn "  ⚠ content download failed for PDS #{content_url.inspect}: #{e.message.lines.first&.chomp}"
  end
end

File.write(opts[:out], JSON.pretty_generate(descriptors))
puts "wrote #{opts[:out]} (#{descriptors.size} published data source(s) resolved)"
