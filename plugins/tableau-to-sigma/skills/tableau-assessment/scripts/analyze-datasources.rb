#!/usr/bin/env ruby
# Phase 2: Sigma-readiness + similarity analysis for every data source on the site.
#
# Reads: <out>/metadata-graph.json (from fetch-metadata-graph.rb)
# Writes: <out>/data-sources.json — per-source Sigma verdict + similarity clusters
#                                   + red-flag/drop-in/land-in-warehouse/verify buckets
#                                   + custom-SQL inventory + flow-data inventory
#
# Usage: ruby scripts/analyze-datasources.rb --out /tmp/assessment-<site>

require 'json'
require 'optparse'
require 'set'

opts = { similarity_threshold: 0.75 }
OptionParser.new do |p|
  p.on('--out DIR') { |v| opts[:out] = v }
  p.on('--similarity F', Float, 'Jaccard threshold for clustering (default 0.75)') { |v| opts[:similarity_threshold] = v }
end.parse!
abort('--out required') unless opts[:out]

graph = JSON.parse(File.read(File.join(opts[:out], 'metadata-graph.json')))

# ----- Connection-type classification ----------------------------------------
CLOUD_WAREHOUSE = %w[
  snowflake redshift bigquery databricks postgres mysql sqlserver oracle synapse
  azure_data_warehouse azure_dwh fabric azure_sql_db
].freeze

FILE_BASED = %w[
  excel-direct excel googledrive textscan hyper csv json parquet
].freeze

VERIFY_DBS = %w[presto athena denodo dremio vertica teradata exasol sap hana].freeze

CLOUD_HOST_PATTERNS = [
  /\.snowflakecomputing\.com$/i,
  /\.amazonaws\.com$/i,
  /\.googleapis\.com$/i,
  /\.azure\.com$/i,
  /\.azuredatabricks\.net$/i,
  /\.databricks\.com$/i,
  /\.cloud\.databricks\.com$/i,
  /\.bigquery\.cloud\.google\.com$/i,
  /\.windows\.net$/i,
  /\.gcp\.cloud\.databricks\.com$/i,
  /\.redshift\.amazonaws\.com$/i
].freeze

ON_PREM_PATTERNS = [
  /\.corp$/i, /\.local$/i, /\.internal$/i, /\.lan$/i, /\.intranet$/i,
  /^10\./, /^172\.(1[6-9]|2[0-9]|3[01])\./, /^192\.168\./
].freeze

def host_class(host)
  return nil if host.nil? || host.empty?
  return :cloud if CLOUD_HOST_PATTERNS.any? { |p| host.match?(p) }
  return :on_prem if ON_PREM_PATTERNS.any? { |p| host.match?(p) }
  :uncertain
end

def conn_type_class(ct)
  return :unknown if ct.nil?
  ct = ct.downcase
  return :cloud_warehouse if CLOUD_WAREHOUSE.include?(ct)
  return :file            if FILE_BASED.include?(ct)
  return :verify_db       if VERIFY_DBS.include?(ct)
  return :tableau_internal if %w[publishedConnection federated].include?(ct)
  :other
end

# ----- Per-source verdict logic ----------------------------------------------
def verdict_for(connection_types, host_classes)
  types = connection_types.map { |t| conn_type_class(t) }.compact.uniq
  hosts = host_classes.compact

  if types.empty?
    return ['unknown', 'No connection metadata available', 'Inspect manually']
  end

  if types == [:file] || types.all? { |t| t == :file }
    return [
      'land-in-warehouse',
      'File-based data source (Excel / CSV / Google Drive / hyper extract)',
      'Land this content in your cloud warehouse before migration. For .tds files, the tableau-vds-to-cdw skill auto-generates warehouse DDL (Snowflake or Databricks) + a matching Sigma data model.'
    ]
  end

  if types.include?(:tableau_internal) && types.include?(:cloud_warehouse).!
    return [
      'resolve-published',
      'Sources another published datasource (publishedConnection) or uses a federated join',
      'Recursively resolve to the underlying connection class; treat that per its own verdict.'
    ]
  end

  if hosts.include?(:on_prem)
    return [
      'verify-network',
      'On-prem or private network host detected',
      'Confirm with your IT team that Sigma has network access to this host. Sigma supports the database; this is a network/connectivity question.'
    ]
  end

  if types.all? { |t| t == :cloud_warehouse } && hosts.all? { |h| h == :cloud }
    return [
      'drop-in',
      'Cloud warehouse natively supported by Sigma',
      'Connect Sigma directly to this source. No migration prep required.'
    ]
  end

  if types.all? { |t| t == :cloud_warehouse } && hosts.include?(:uncertain)
    return [
      'verify-network',
      'Cloud-warehouse type but unrecognized host — could be self-managed or on a private endpoint',
      'Confirm the host is reachable from Sigma and that the connection profile (port, auth, SSL) matches a supported config.'
    ]
  end

  if types.include?(:verify_db)
    return [
      'verify-db',
      'Database type supported via custom connection; check Sigma connector matrix',
      'Verify Sigma supports this database (Presto/Athena/Vertica/etc.); plan additional setup time.'
    ]
  end

  if types.include?(:tableau_internal)
    return [
      'verify-modeling',
      'Federated cross-source join detected',
      'Review whether Sigma data model relationships can replicate the join logic; may require re-modeling.'
    ]
  end

  ['other', "Mixed or unrecognized connection types: #{connection_types.uniq.join(', ')}", 'Inspect manually.']
end

# ----- Build per-source records ---------------------------------------------
sources = []

# Published datasources
(graph['publishedDatasources'] || []).each do |pd|
  dbs = pd['upstreamDatabases'] || []
  conn_types = dbs.map { |d| d['connectionType'] }.compact
  hosts      = dbs.map { |d| d['hostName'] }.compact
  host_clss  = hosts.map { |h| host_class(h) }
  verdict, reason, action = verdict_for(conn_types, host_clss)

  fields = (pd['fields'] || []).map { |f| f['name'].to_s.downcase }.sort.uniq

  sources << {
    'kind'                 => 'published',
    'luid'                 => pd['luid'],
    'id'                   => pd['id'],
    'name'                 => pd['name'],
    'is_certified'         => pd['isCertified'],
    'has_extract'          => pd['hasExtracts'],
    'extract_last_update'  => pd['extractLastUpdateTime'],
    'upstream_connections' => dbs.map { |d| { 'name' => d['name'], 'connection_type' => d['connectionType'], 'host' => d['hostName'], 'host_class' => host_class(d['hostName'])&.to_s } },
    'upstream_tables'      => (pd['upstreamTables'] || []).map { |t| t['fullName'] || t['name'] }.compact.uniq,
    'downstream_workbooks' => (pd['downstreamWorkbooks'] || []).map { |w| w['name'] },
    'verdict'              => verdict,
    'verdict_reason'       => reason,
    'recommended_action'   => action,
    'field_count'          => fields.size,
    'field_set'            => fields,
    'parent_workbook'      => nil
  }
end

# Embedded datasources (per workbook)
(graph['workbooks'] || []).each do |wb|
  (wb['embeddedDatasources'] || []).each do |ed|
    dbs = ed['upstreamDatabases'] || []
    conn_types = dbs.map { |d| d['connectionType'] }.compact
    hosts      = dbs.map { |d| d['hostName'] }.compact
    host_clss  = hosts.map { |h| host_class(h) }
    verdict, reason, action = verdict_for(conn_types, host_clss)

    fields = (ed['fields'] || []).map { |f| f['name'].to_s.downcase }.sort.uniq

    sources << {
      'kind'                 => 'embedded',
      'luid'                 => nil,
      'id'                   => ed['id'],
      'name'                 => ed['name'],
      'is_certified'         => false,
      'has_extract'          => ed['hasExtracts'],
      'extract_last_update'  => nil,
      'upstream_connections' => dbs.map { |d| { 'name' => d['name'], 'connection_type' => d['connectionType'], 'host' => d['hostName'], 'host_class' => host_class(d['hostName'])&.to_s } },
      'upstream_tables'      => (ed['upstreamTables'] || []).map { |t| t['fullName'] || t['name'] }.compact.uniq,
      'downstream_workbooks' => [wb['name']],
      'verdict'              => verdict,
      'verdict_reason'       => reason,
      'recommended_action'   => action,
      'field_count'          => fields.size,
      'field_set'            => fields,
      'parent_workbook'      => wb['name']
    }
  end
end

# ----- Similarity analysis (embedded only) ----------------------------------
def jaccard(a, b)
  a_set = a.is_a?(Set) ? a : Set.new(a)
  b_set = b.is_a?(Set) ? b : Set.new(b)
  return 0.0 if a_set.empty? && b_set.empty?
  inter = (a_set & b_set).size
  union = (a_set | b_set).size
  union.zero? ? 0.0 : inter.to_f / union
end

embedded = sources.select { |s| s['kind'] == 'embedded' && s['field_count'] >= 3 }
field_sets = embedded.map { |s| Set.new(s['field_set']) }

clusters = []
seen = Set.new
embedded.each_with_index do |src, i|
  next if seen.include?(i)
  cluster_members = [i]
  ((i + 1)...embedded.size).each do |j|
    next if seen.include?(j)
    sim = jaccard(field_sets[i], field_sets[j])
    if sim >= opts[:similarity_threshold]
      cluster_members << j
    end
  end
  next if cluster_members.size < 2
  cluster_members.each { |k| seen << k }
  members = cluster_members.map do |k|
    s = embedded[k]
    { 'name' => s['name'], 'workbook' => s['parent_workbook'], 'field_count' => s['field_count'] }
  end
  base_idx = cluster_members.first
  similarity_to_base = cluster_members.map { |k| jaccard(field_sets[base_idx], field_sets[k]).round(3) }
  clusters << {
    'cluster_id'        => "cluster-#{clusters.size + 1}",
    'size'              => cluster_members.size,
    'avg_field_count'   => (members.sum { |m| m['field_count'] }.to_f / members.size).round,
    'similarity_to_base'=> similarity_to_base,
    'members'           => members
  }
end

# ----- Custom SQL inventory --------------------------------------------------
custom_sql = (graph['customSQLTables'] || []).map do |c|
  {
    'name'                 => c['name'],
    'connection_type'      => c.dig('database', 'connectionType'),
    'host'                 => c.dig('database', 'hostName'),
    'downstream_workbooks' => (c['downstreamWorkbooks'] || []).map { |w| w['name'] },
    'downstream_datasources' => (c['downstreamDatasources'] || []).map { |d| d['name'] },
    'query_preview'        => (c['query'] || '')[0, 280],
    'query_size_chars'     => (c['query'] || '').size
  }
end

# ----- Tableau Prep flows ----------------------------------------------------
flows = (graph['flows'] || []).map do |f|
  dbs = f['upstreamDatabases'] || []
  hosts = dbs.map { |d| d['hostName'] }.compact
  host_clss = hosts.map { |h| host_class(h) }
  {
    'luid'                  => f['luid'],
    'name'                  => f['name'],
    'upstream_connection_types' => dbs.map { |d| d['connectionType'] }.compact.uniq,
    'upstream_hosts'        => hosts,
    'upstream_host_classes' => host_clss.map(&:to_s),
    'downstream_workbooks'  => (f['downstreamWorkbooks'] || []).map { |w| w['name'] },
    'downstream_datasources'=> (f['downstreamDatasources'] || []).map { |d| d['name'] },
    'is_orphan'             => (f['downstreamWorkbooks'] || []).empty? && (f['downstreamDatasources'] || []).empty?
  }
end

# ----- Summary buckets ------------------------------------------------------
by_verdict = sources.group_by { |s| s['verdict'] }
summary = {
  'total'                  => sources.size,
  'published_count'        => sources.count { |s| s['kind'] == 'published' },
  'embedded_count'         => sources.count { |s| s['kind'] == 'embedded' },
  'by_verdict' => {
    'drop-in'           => (by_verdict['drop-in']           || []).size,
    'verify-network'    => (by_verdict['verify-network']    || []).size,
    'verify-db'         => (by_verdict['verify-db']         || []).size,
    'verify-modeling'   => (by_verdict['verify-modeling']   || []).size,
    'resolve-published' => (by_verdict['resolve-published'] || []).size,
    'land-in-warehouse' => (by_verdict['land-in-warehouse'] || []).size,
    'other'             => (by_verdict['other']             || []).size,
    'unknown'           => (by_verdict['unknown']           || []).size
  },
  'duplicate_clusters' => clusters.size,
  'sources_in_clusters' => clusters.sum { |c| c['size'] },
  'custom_sql_count'   => custom_sql.size,
  'flows_count'        => flows.size,
  'orphan_flows'       => flows.count { |f| f['is_orphan'] }
}

result = {
  'summary'             => summary,
  'sources'             => sources,
  'similarity_clusters' => clusters,
  'custom_sql'          => custom_sql,
  'prep_flows'          => flows
}

out_path = File.join(opts[:out], 'data-sources.json')
File.write(out_path, JSON.pretty_generate(result))
puts "wrote #{out_path}"
puts "  total sources:        #{summary['total']} (#{summary['published_count']} published, #{summary['embedded_count']} embedded)"
puts "  drop-in:              #{summary.dig('by_verdict', 'drop-in')}"
puts "  verify-network:       #{summary.dig('by_verdict', 'verify-network')}"
puts "  land-in-warehouse:    #{summary.dig('by_verdict', 'land-in-warehouse')}"
puts "  verify-modeling:      #{summary.dig('by_verdict', 'verify-modeling')}"
puts "  resolve-published:    #{summary.dig('by_verdict', 'resolve-published')}"
puts "  unknown / other:      #{(summary.dig('by_verdict', 'unknown') || 0) + (summary.dig('by_verdict', 'other') || 0)}"
puts "  duplicate clusters:   #{summary['duplicate_clusters']} (covering #{summary['sources_in_clusters']} sources)"
puts "  custom SQL queries:   #{summary['custom_sql_count']}"
puts "  Prep flows:           #{summary['flows_count']} (#{summary['orphan_flows']} orphans)"
