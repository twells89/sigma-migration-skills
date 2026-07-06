#!/usr/bin/env ruby
# Discover the Custom SQL behind a Tableau workbook (or every workbook on the site)
# via the Metadata GraphQL API. Falls back to .twb XML parsing for embedded SQL on
# workbooks the GraphQL crawler hasn't indexed yet.
#
# Output: /tmp/<name>/custom-sql.json
# Shape:
#   [{
#     "name": "Orders Custom SQL",
#     "query": "SELECT ... FROM ...",
#     "connectionType": "snowflake",
#     "downstreamWorkbooks": [{"name": "Foo", "luid": "..."}],
#     "downstreamDatasources": [{"name": "Foo DS", "luid": "..."}]
#   }, ...]
#
# Usage:
#   eval "$(scripts/get-tableau-token.sh)"
#   ruby scripts/extract-custom-sql.rb --out /tmp/<name>/custom-sql.json
#   ruby scripts/extract-custom-sql.rb --workbook-luid <LUID> --out /tmp/<name>/custom-sql.json
#   ruby scripts/extract-custom-sql.rb --twb /tmp/<name>/workbook-content.twb --out /tmp/<name>/custom-sql.json

require 'json'
require 'optparse'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'tableau_rest'
# Nokogiri-backed REXML drop-in — REXML is O(n^2) on large .twb files. See lib/twb_xml.rb.
require 'twb_xml'

opts = {}
OptionParser.new do |o|
  o.on('--workbook-luid LUID') { |v| opts[:wb_luid] = v }
  o.on('--twb PATH')           { |v| opts[:twb] = v }
  o.on('--out PATH')           { |v| opts[:out] = v }
end.parse!
abort 'usage: --out PATH (optional: --workbook-luid LUID  OR  --twb PATH)' unless opts[:out]

results = []

# --- GraphQL path ---
# NB: do NOT add `isUnique` (or other newer CustomSQLTable fields) to these
# queries. `isUnique` is undefined on `CustomSQLTable` in some Tableau Metadata
# API versions (verified 2026-07-06 on 10ay.online.tableau.com): its presence
# fails the ENTIRE query with a FieldUndefined ValidationError, `Tableau.graphql`
# rescues it, and the extractor silently returns 0 custom-SQL blocks — which
# then breaks published-datasource (sqlproxy) hydration downstream. Keep the
# field set to the widely-supported minimum (name/query/connectionType + downstream).
gql_scope = if opts[:wb_luid]
              <<~GQL
                {
                  workbooks(filter:{luid:"#{opts[:wb_luid]}"}) {
                    name luid
                    upstreamTables {
                      __typename name
                      ... on CustomSQLTable {
                        query connectionType
                      }
                    }
                  }
                }
              GQL
            else
              <<~GQL
                {
                  customSQLTablesConnection(first: 500) {
                    nodes {
                      name query connectionType
                      downstreamWorkbooks { name luid }
                      downstreamDatasources { name luid }
                    }
                  }
                }
              GQL
            end

begin
  resp = Tableau.graphql(gql_scope)
  if opts[:wb_luid]
    wbs = resp.dig('data', 'workbooks') || []
    wbs.each do |wb|
      (wb['upstreamTables'] || []).each do |t|
        next unless t['__typename'] == 'CustomSQLTable'
        results << {
          'name'                  => t['name'],
          'query'                 => t['query'],
          'connectionType'        => t['connectionType'],
          'isUnique'              => t['isUnique'],
          'downstreamWorkbooks'   => [{ 'name' => wb['name'], 'luid' => wb['luid'] }],
          'downstreamDatasources' => []
        }
      end
    end
  else
    nodes = resp.dig('data', 'customSQLTablesConnection', 'nodes') || []
    nodes.each do |t|
      results << {
        'name'                  => t['name'],
        'query'                 => t['query'],
        'connectionType'        => t['connectionType'],
        'isUnique'              => t['isUnique'],
        'downstreamWorkbooks'   => t['downstreamWorkbooks']   || [],
        'downstreamDatasources' => t['downstreamDatasources'] || []
      }
    end
  end
rescue Tableau::Error => e
  warn "GraphQL fetch failed: #{e.message.lines.first&.chomp}"
end

# --- .twb fallback (embedded Custom SQL) ---
if opts[:twb] && File.exist?(opts[:twb])
  twb = TwbXml.parse(File.read(opts[:twb], encoding: 'UTF-8'))
  # Top-level datasource definitions only — `//datasource` also matches the
  # `<datasource>` REFERENCE blocks inside every worksheet, and walking those
  # repeats the same custom-SQL `<relation>` once per worksheet that uses it.
  # Customer report: a workbook with 28 real datasources got 482 hits. Scope
  # the XPath to the canonical top-level location.
  twb.elements.each('/workbook/datasources/datasource/connection') do |conn|
    conn.elements.each(".//relation[@type='text']") do |rel|
      sql = rel.text.to_s.strip
      next if sql.empty?
      next if results.any? { |r| r['query']&.strip == sql }
      results << {
        'name'                  => rel.attributes['name'],
        'query'                 => sql,
        'connectionType'        => conn.attributes['class'],
        'isUnique'              => nil,
        'downstreamWorkbooks'   => [],
        'downstreamDatasources' => [],
        'source'                => 'twb-fallback'
      }
    end
  end
end

File.write(opts[:out], JSON.pretty_generate(results))
puts "wrote #{opts[:out]} (#{results.size} custom SQL blocks)"

results.each_with_index do |r, i|
  qlen = r['query'].to_s.length
  dn = (r['downstreamWorkbooks'].map { |w| w['name'] } + r['downstreamDatasources'].map { |w| w['name'] }).first(3).join(', ')
  warn "  [#{i+1}] name=#{r['name'].inspect} conn=#{r['connectionType']} sql=#{qlen}B  downstream: #{dn}"
  warn "      sql preview: #{r['query'].to_s.lines.first(2).map(&:chomp).join(' | ')[0..160]}"
end
