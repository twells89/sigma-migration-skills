#!/usr/bin/env ruby
# Compose a migration-plan.json that the assessment hands to downstream
# migration skills (tableau-to-sigma, tableau-vds-to-cdw) for direct
# invocation.
#
# Inputs (all from /tmp/assessment-<site>/):
#   shortlist.json     — per-workbook score/tag (migrate-first / easy-win /
#                        moderate / retire / needs-gap-scout)
#   data-sources.json  — per-datasource Sigma-readiness verdict
#                        (drop-in / verify-network / verify-db / verify-modeling /
#                         land-in-warehouse / red-flag)
#   complexity.json    — per-workbook gap-scan summary (auto/hint/manual/unhandled)
#   twbs/              — downloaded .twb files (for warehouse-table extraction)
#
# Output: migration-plan.json with:
#   - workbooks[]: { workbookId, name, recommended_path, priority_tier, blockers,
#                    warehouse_tables, cluster_id }
#   - datasources[]: { id, name, recommended_path, verdict, reason }
#   - dm_clusters[]: { id, workbookIds, shared_warehouse_tables }
#   - summary: counts + suggested batch
#
# `recommended_path` values:
#   "tableau-to-sigma"          → workbook ready for conversion
#   "tableau-to-sigma-with-scout" → conversion needs gap-scout iterations first
#   "vds-to-snowflake"          → datasource should land in a warehouse before workbook conversion.
#                                  (Token kept for backwards-compat with downstream consumers;
#                                   the recommendation generalises to BigQuery / Databricks /
#                                   Postgres / etc. — the readout names the target_warehouse.)
#   "retire"                    → unused (accesses==0); recommend not migrating
#   "blocked"                   → known unsupported features; needs manual rework
#
# Usage: ruby scripts/migration-plan.rb --out /tmp/assessment-<site>
#
# Multi-warehouse note: this script's optional reconciliation against an
# "already-landed" warehouse table uses Snowflake's `snow sql` CLI by default
# via --snowflake-conn. For BigQuery / Databricks / Postgres / etc., the same
# pattern works — see "Multi-warehouse considerations" in SKILL.md for the
# `--warehouse-cli {snow|bq|databricks|psql}` extension shape. Only Snowflake
# is wired in this script; other warehouses are documented but unimplemented.

require 'json'
require 'optparse'
require 'set'
require 'rexml/document'

opts = { similarity: 0.5, target_schema: 'TJ.PUBLIC', warehouse_cli: 'snow' }
OptionParser.new do |p|
  p.on('--out DIR')                 { |v| opts[:out] = v }
  p.on('--similarity F', Float,
       'Jaccard threshold for DM clustering (default 0.5)') { |v| opts[:similarity] = v }
  p.on('--snowflake-conn NAME',
       'Snow CLI connection name. When set, query INFORMATION_SCHEMA for ' \
       'tables already landed in --target-schema and downgrade matching ' \
       'datasources from vds-to-snowflake to vds-already-landed. ' \
       'Equivalent flags for other warehouses are documented but unimplemented ' \
       '(see --warehouse-cli).') { |v| opts[:snow_conn] = v }
  p.on('--target-schema SCHEMA',
       'CATALOG.SCHEMA (Snowflake) / project.dataset (BigQuery) / ' \
       'catalog.schema (Databricks) / database.schema (Postgres) to check ' \
       'for already-landed tables (default TJ.PUBLIC). Used together with ' \
       '--snowflake-conn or --warehouse-cli.') { |v| opts[:target_schema] = v }
  p.on('--warehouse-cli MODE',
       %w[snow bq databricks psql],
       'Warehouse CLI driver for the already-landed reconciliation: ' \
       'snow (Snowflake; default and only currently implemented), ' \
       'bq (BigQuery), databricks (Databricks SQL), psql (Postgres / ' \
       'Redshift). Non-snow modes warn and skip the check — see SKILL.md ' \
       '"Multi-warehouse considerations" for the function signature ' \
       'to drop in.') { |v| opts[:warehouse_cli] = v }
end.parse!
abort('--out required') unless opts[:out]

# Sanitize a Tableau datasource name to its conventional landed table name:
# UPPER_SNAKE_CASE, alnum + underscores only, leading digits underscored.
def landed_table_name(ds_name)
  s = ds_name.to_s.upcase.gsub(/[^A-Z0-9]+/, '_').gsub(/^_+|_+$/, '')
  s = "_#{s}" if s =~ /^[0-9]/
  s
end

# One-shot list of already-landed tables in the target schema. Returns a Set
# of bare table names (no catalog/schema prefix). Empty Set on any failure
# so the script remains best-effort. Only the `snow` (Snowflake) branch is
# implemented; non-snow modes return an empty set with a stderr warning so
# the rest of the plan still composes.
def fetch_landed_tables(snow_conn, target_schema, warehouse_cli = 'snow')
  return Set.new unless snow_conn
  unless warehouse_cli == 'snow'
    warn "--warehouse-cli=#{warehouse_cli} is documented but not implemented; " \
         "see SKILL.md 'Multi-warehouse considerations' for the function shape. " \
         "Skipping already-landed reconciliation."
    return Set.new
  end
  catalog, schema = target_schema.to_s.split('.', 2)
  return Set.new unless catalog && schema
  # Fully-qualify INFORMATION_SCHEMA — snow CLI sessions often have no
  # default database, so a bare INFORMATION_SCHEMA.TABLES errors with 090105.
  q = "SELECT TABLE_NAME FROM #{catalog.upcase}.INFORMATION_SCHEMA.TABLES " \
      "WHERE TABLE_SCHEMA='#{schema.upcase}' AND TABLE_CATALOG='#{catalog.upcase}'"
  out = `snow sql --connection #{snow_conn.shellescape} -q #{q.shellescape} --format json 2>/dev/null`
  return Set.new unless $?.success? && !out.strip.empty?
  begin
    rows = JSON.parse(out)
    rows = rows['data'] if rows.is_a?(Hash) && rows['data']
    rows.is_a?(Array) ? rows.map { |r| (r['TABLE_NAME'] || r['table_name']).to_s.upcase }.to_set : Set.new
  rescue StandardError
    Set.new
  end
end

require 'shellwords'

shortlist_path  = File.join(opts[:out], 'shortlist.json')
ds_path         = File.join(opts[:out], 'data-sources.json')
complexity_path = File.join(opts[:out], 'complexity.json')
twb_dir         = File.join(opts[:out], 'twbs')

shortlist  = File.exist?(shortlist_path)  ? JSON.parse(File.read(shortlist_path))  : []
data_srcs  = File.exist?(ds_path)         ? JSON.parse(File.read(ds_path))         : { 'sources' => [] }
complexity = File.exist?(complexity_path) ? JSON.parse(File.read(complexity_path)) : { 'workbooks' => {} }

# Per-workbook warehouse-table extraction from .twb. Same logic as
# tableau-to-sigma/scripts/build-real-sig.rb but inlined.
def extract_warehouse_tables(twb_path)
  return [] unless File.exist?(twb_path)
  begin
    doc = REXML::Document.new(File.read(twb_path, encoding: 'utf-8', invalid: :replace))
  rescue StandardError
    return []
  end
  out = []
  doc.elements.each('//relation[@type="table"]') do |r|
    raw = r.attributes['table'].to_s.gsub(/[\[\]]/, '')
    table =
      if (m = raw.match(/\(([^)]+)\)$/));               m[1]
      elsif (m = raw.match(/[0-9a-f-]{30,}\.(.+)$/i));  m[1]
      else;                                              raw
      end
    out << table.to_s.upcase.strip if table && !table.empty?
  end
  out.uniq
end

# --- workbook side ---
# Field-name compatibility: shortlist.json uses `luid` for the workbook id.
# Older formats may have used `workbookId` or `id`. Accept all three.
# `fetch-all-twbs.rb` writes .twb files at `twbs/<luid>.twb` — match by LUID,
# NOT by sanitized name (name-matching was the bug that produced 0 DM clusters
# in the 2026-05-22 e2e validation run).
workbook_entries = shortlist.map do |w|
  name = w['name']
  workbookId = w['luid'] || w['workbookId'] || w['id']
  tag = w['tag']
  twb_path = workbookId ? File.join(twb_dir, "#{workbookId}.twb") : nil
  twb_path = nil unless twb_path && File.exist?(twb_path)
  whouse_tables = twb_path ? extract_warehouse_tables(twb_path) : []
  cx = (complexity['workbooks'] || {})[name] || {}

  recommended_path =
    case tag
    when 'retire'           then 'retire'
    when 'needs-gap-scout'  then 'tableau-to-sigma-with-scout'
    when 'migrate-first', 'easy-win', 'moderate'
      # Block if too many manual/unhandled features
      if (cx['manual'].to_i + cx['unhandled'].to_i) > 5
        'blocked'
      else
        'tableau-to-sigma'
      end
    else
      'tableau-to-sigma'
    end

  blockers = []
  blockers << "#{cx['unhandled']} unhandled feature(s)"  if cx['unhandled'].to_i > 0
  blockers << "#{cx['manual']} manual-setup feature(s)"  if cx['manual'].to_i > 0
  blockers << 'no usage (accesses=0)'                    if tag == 'retire'

  {
    'workbookId'        => workbookId,
    'name'              => name,
    'recommended_path'  => recommended_path,
    'priority_tier'     => tag,
    'score'             => w['score'],
    'accesses'          => w['accesses'],
    'actors'            => w['actors'],
    'warehouse_tables'  => whouse_tables,
    'blockers'          => blockers
  }
end

# --- datasource side ---
# When --snowflake-conn is provided, enumerate already-landed tables ONCE and
# downgrade any vds-to-snowflake row whose derived table name is already
# present. Backwards-compatible: empty Set means no reconciliation runs.
landed_tables = fetch_landed_tables(opts[:snow_conn], opts[:target_schema], opts[:warehouse_cli])
already_landed_count = 0

datasource_entries = (data_srcs['sources'] || []).map do |s|
  v = s['verdict']
  recommended_path =
    case v
    when 'land-in-warehouse', 'red-flag' then 'vds-to-snowflake'
    when 'drop-in'                        then 'drop-in'
    when 'verify-network', 'verify-db', 'verify-modeling' then 'verify-then-migrate'
    else 'verify-then-migrate'
    end

  entry = {
    'id'                => s['datasourceId'] || s['id'],
    'name'              => s['name'],
    'verdict'           => v,
    'recommended_path'  => recommended_path,
    'reason'            => s['reason'] || s['action']
  }

  if recommended_path == 'vds-to-snowflake' && !landed_tables.empty?
    derived = landed_table_name(s['name'])
    if landed_tables.include?(derived)
      already_landed_count += 1
      entry['recommended_path'] = 'vds-already-landed'
      entry['landed_table']     = "#{opts[:target_schema]}.#{derived}"
      entry['reason']           = "Found #{derived} in #{opts[:target_schema]}; skipping VDS re-run"
    end
  end

  entry
end

# --- DM clustering ---
# Cluster workbooks whose warehouse-table sets are Jaccard-similar ≥ threshold
# AND share at least one "fact-shaped" table (ends in _FACT or contains FACT).
def jaccard(a, b)
  a = a.to_set; b = b.to_set
  return 0.0 if (a | b).empty?
  (a & b).size.to_f / (a | b).size
end

def has_fact_overlap?(a, b)
  shared = (a.to_set & b.to_set).to_a
  shared.any? { |t| t.upcase.include?('FACT') } || shared.any? { |t| t.upcase.end_with?('_FACT') }
end

clusterable = workbook_entries.select do |w|
  %w[tableau-to-sigma tableau-to-sigma-with-scout].include?(w['recommended_path']) &&
    !w['warehouse_tables'].empty?
end

clusters = []
unassigned = clusterable.dup
while (seed = unassigned.shift)
  members = [seed]
  unassigned.reject! do |w|
    sim = jaccard(seed['warehouse_tables'], w['warehouse_tables'])
    if sim >= opts[:similarity] && has_fact_overlap?(seed['warehouse_tables'], w['warehouse_tables'])
      members << w
      true
    end
  end
  shared = members.map { |m| m['warehouse_tables'].to_set }.reduce(:&) || Set.new
  cluster_id = "cluster-#{(clusters.size + 1).to_s.rjust(2, '0')}-#{seed['warehouse_tables'].first&.downcase&.gsub(/[^a-z0-9]/, '-') || 'misc'}"
  members.each { |m| m['cluster_id'] = cluster_id }
  clusters << {
    'id'                       => cluster_id,
    'seed_workbook'            => seed['name'],
    'workbookIds'              => members.map { |m| m['workbookId'] },
    'workbook_names'           => members.map { |m| m['name'] },
    'shared_warehouse_tables'  => shared.to_a.sort,
    'cluster_size'             => members.size
  }
end

# --- summary ---
by_path = workbook_entries.group_by { |w| w['recommended_path'] }
suggested_batch = workbook_entries
  .select { |w| w['recommended_path'] == 'tableau-to-sigma' }
  .sort_by { |w| -(w['score'].to_f) }
  .first(8)
  .map { |w| { 'workbookId' => w['workbookId'], 'name' => w['name'], 'cluster_id' => w['cluster_id'] } }

result = {
  'workbooks'   => workbook_entries,
  'datasources' => datasource_entries,
  'dm_clusters' => clusters,
  'summary' => {
    'workbooks_total'              => workbook_entries.size,
    'workbooks_ready_for_conversion' => (by_path['tableau-to-sigma']            || []).size,
    'workbooks_need_scout'         => (by_path['tableau-to-sigma-with-scout']  || []).size,
    'workbooks_blocked'            => (by_path['blocked']                       || []).size,
    'workbooks_retire'             => (by_path['retire']                        || []).size,
    'datasources_vds_to_snowflake' => datasource_entries.count { |d| d['recommended_path'] == 'vds-to-snowflake' },
    'datasources_already_landed'   => already_landed_count,
    'datasources_drop_in'          => datasource_entries.count { |d| d['recommended_path'] == 'drop-in' },
    'cluster_count'                => clusters.size,
    'suggested_batch'              => suggested_batch
  }
}

File.write(File.join(opts[:out], 'migration-plan.json'), JSON.pretty_generate(result))

puts "wrote #{File.join(opts[:out], 'migration-plan.json')}"
puts "workbooks total: #{result['summary']['workbooks_total']}"
puts "  ready for tableau-to-sigma: #{result['summary']['workbooks_ready_for_conversion']}"
puts "  need gap-scout iterations:  #{result['summary']['workbooks_need_scout']}"
puts "  blocked (manual/unhandled): #{result['summary']['workbooks_blocked']}"
puts "  retire (no usage):          #{result['summary']['workbooks_retire']}"
puts "datasources: #{datasource_entries.size}"
puts "  recommend VDS→Snowflake:  #{result['summary']['datasources_vds_to_snowflake']}"
puts "  already landed (skip):    #{result['summary']['datasources_already_landed']}"
puts "  drop-in to Sigma:         #{result['summary']['datasources_drop_in']}"
puts "DM clusters: #{result['summary']['cluster_count']}"
clusters.each do |c|
  puts "  #{c['id']}: #{c['cluster_size']} workbooks, #{c['shared_warehouse_tables'].size} shared tables"
end
puts
puts "suggested first batch (top #{suggested_batch.size} ready workbooks by score):"
suggested_batch.each_with_index { |w, i| puts "  #{i + 1}. #{w['name']} (cluster: #{w['cluster_id'] || '-'})" }
