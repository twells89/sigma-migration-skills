#!/usr/bin/env ruby
# Phase 1 discovery for domo-assessment.
#
#   ruby scripts/discover-domo.rb --from-fixtures fixtures/tier-b --out <dir>  (offline)
#   ruby scripts/discover-domo.rb --out <dir>                                  (live)
#
# Turns the governance/DomoStats system datasets (Task 3's probe target) into
# two artifacts the scorer (Task 5) consumes:
#
#   inventory.json = { instance, datasets, pages, cards, users, warnings }
#   usage.json     = { by_card: { card_id => { views, distinct_viewers } } }
#                     (written only when an activity-log table is present)
#
# IMPORTANT: this script resolves each governance table ITSELF — by fixture
# filename offline, by name-matching a live DataSet — rather than reading
# probe.json's `governance_datasets` value. Offline that value is a fixture
# PATH; live it's a DataSet ID; either way discover doesn't need it and
# depending on it would couple this stage to probe's exact output shape for
# no benefit (see refs/governance-datasets.md).
#
# TOLERANT COLUMN ACCESS: every governance table's schema is best-effort
# (schemas are reconstructed from docs/community — CONFIRM on first live
# contact). `col(row, colnames_hash, name)` below NEVER raises on a missing
# column: it returns nil and records ONE `_shapeSuspect` warning per
# (table, column) into inventory.json["warnings"], so a degraded read is
# visible to the scorer/render stages instead of silently wrong or crashing.
#
# Live prereqs (see ../domo-to-sigma/refs/connection.md):
#   export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=... DOMO_INSTANCE=<instance>
#   export DOMO_DEV_TOKEN=...        # omit for Tier B
#   eval "$(../domo-to-sigma/scripts/get-domo-token.sh)"
#
# This assessment never posts to Sigma — no Sigma credentials, no sigma_rest.rb.

require 'json'
require 'optparse'
require 'fileutils'
require 'set'

# Logical table name -> live DataSet name regex (mirrors probe-governance.rb's
# WANTED; kept independent on purpose — see header note above).
WANTED = {
  'datasets'     => /data\s*sets?/i,
  'dataflows'    => /data\s*flows?/i,
  'pages'        => /pages/i,
  'cards'        => /cards/i,
  'users'        => /users/i,
  'pdp'          => /pdp|personalized/i,
  'activity-log' => /activity\s*log/i
}.freeze

options = {}
OptionParser.new do |o|
  o.on('--from-fixtures DIR', 'Offline: read governance tables from DIR instead of a live Domo instance') { |v| options[:fixtures] = v }
  o.on('--out DIR', 'Write inventory.json / usage.json here (required)') { |v| options[:out] = v }
end.parse!

abort('--out DIR is required') unless options[:out]
abort("--from-fixtures dir not found: #{options[:fixtures]}") if options[:fixtures] && !File.directory?(options[:fixtures])
FileUtils.mkdir_p(options[:out])

WARNINGS = []
WARNED_COLUMNS = {} # (table,column) already recorded -> avoid one warning per row

# Build a `col` closure scoped to one table name, so every call site keeps the
# 3-arg shape `col(row, colnames_hash, name)` while warnings still carry which
# table was being read.
def make_col(table_name)
  lambda do |row, colnames_hash, name|
    next row[name] if colnames_hash.key?(name)
    wkey = [table_name, name]
    unless WARNED_COLUMNS[wkey]
      WARNED_COLUMNS[wkey] = true
      WARNINGS << { '_shapeSuspect' => true, 'table' => table_name, 'column' => name,
                    'reason' => "column '#{name}' not present in this table's schema" }
    end
    nil
  end
end

# { "columns" => [...], "rows" => [[...], ...] } -> { colname => index }
def build_colidx(table)
  idx = {}
  Array(table && table['columns']).each_with_index { |c, i| idx[c] = i }
  idx
end

# { "columns" => [...], "rows" => [[...], ...] } -> [ { colname => value }, ... ]
def build_rows(table, colidx)
  Array(table && table['rows']).map do |arr|
    h = {}
    colidx.each { |name, i| h[name] = arr[i] }
    h
  end
end

# Load one governance table, offline (fixture file, keyed by logical filename)
# or live (query the matching DataSet). Returns the raw {columns,rows} Hash,
# or nil if absent — an uninstalled connector / missing fixture degrades
# gracefully rather than raising.
def load_table(name, options)
  if options[:fixtures]
    path = File.join(options[:fixtures], "#{name}.json")
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  else
    require_relative '../../domo-to-sigma/scripts/lib/domo_rest'
    rx = WANTED[name]
    return nil unless rx
    hit = begin
      Domo.list_datasets(limit: 200).find { |d| d['name'].to_s =~ rx }
    rescue => e
      warn "  live lookup for #{name} failed: #{e.message}"
      nil
    end
    return nil unless hit
    begin
      Domo.query_dataset(hit['id'], 'SELECT * FROM table')
    rescue => e
      warn "  live query for #{name} failed: #{e.message}"
      nil
    end
  end
end

# Parse the Tier-A-only "Beast Mode Refs" cards.json column: one or more
# ';'-separated "id:name:sql" triplets (colon-limited to 3 so SQL text
# containing ':' isn't mangled). Empty/nil -> [] (Tier-B has no such column,
# and col() already recorded the _shapeSuspect warning for that).
def parse_beast_mode_refs(raw)
  return [] if raw.nil? || raw.to_s.strip.empty?
  raw.to_s.split(';').map(&:strip).reject(&:empty?).map do |entry|
    id, name, sql = entry.split(':', 3)
    { 'id' => id, 'name' => name, 'sql' => sql }.compact
  end
end

# ---------------------------------------------------------------------------

tables = {}
%w[datasets pages cards users pdp dataflows activity-log].each do |name|
  tables[name] = load_table(name, options)
end

tables.each do |name, tbl|
  next if tbl
  WARNINGS << { '_shapeSuspect' => true, 'table' => name, 'column' => nil,
                'reason' => "#{name}.json not present -- this governance dataset appears absent/uninstalled" }
end

# ---- datasets ---------------------------------------------------------------
ds_colidx = build_colidx(tables['datasets'])
ds_col = make_col('datasets')
datasets_out = build_rows(tables['datasets'], ds_colidx).map do |row|
  {
    'id'              => ds_col.call(row, ds_colidx, 'DataSet ID'),
    'name'            => ds_col.call(row, ds_colidx, 'DataSet Name'),
    'owner'           => ds_col.call(row, ds_colidx, 'Owner Name'),
    'connector_type'  => ds_col.call(row, ds_colidx, 'Connector Type'),
    'row_count'       => ds_col.call(row, ds_colidx, 'Row Count'),
    'last_updated'    => ds_col.call(row, ds_colidx, 'Last Updated'),
    'update_schedule' => ds_col.call(row, ds_colidx, 'Update Schedule')
  }
end

# ---- pages -------------------------------------------------------------------
pg_colidx = build_colidx(tables['pages'])
pg_col = make_col('pages')
pages_out = build_rows(tables['pages'], pg_colidx).map do |row|
  {
    'id'             => pg_col.call(row, pg_colidx, 'Page ID'),
    'title'          => pg_col.call(row, pg_colidx, 'Page Title'),
    'owner'          => pg_col.call(row, pg_colidx, 'Owner Name'),
    'parent_page_id' => pg_col.call(row, pg_colidx, 'Parent Page ID'),
    'card_count'     => pg_col.call(row, pg_colidx, 'Card Count')
  }
end

# ---- users -------------------------------------------------------------------
us_colidx = build_colidx(tables['users'])
us_col = make_col('users')
users_out = build_rows(tables['users'], us_colidx).map do |row|
  {
    'id'         => us_col.call(row, us_colidx, 'User ID'),
    'name'       => us_col.call(row, us_colidx, 'User Name'),
    'email'      => us_col.call(row, us_colidx, 'Email'),
    'role'       => us_col.call(row, us_colidx, 'Role'),
    'last_login' => us_col.call(row, us_colidx, 'Last Login'),
    'created'    => us_col.call(row, us_colidx, 'Created Date')
  }
end

# ---- pdp: DataSet IDs carrying at least one policy ---------------------------
pdp_colidx = build_colidx(tables['pdp'])
pdp_col = make_col('pdp')
pdp_dataset_ids = build_rows(tables['pdp'], pdp_colidx)
                  .map { |row| pdp_col.call(row, pdp_colidx, 'DataSet ID') }
                  .compact.to_set

# ---- dataflows: DataSet IDs that are a DataFlow OUTPUT -----------------------
df_colidx = build_colidx(tables['dataflows'])
df_col = make_col('dataflows')
dataflow_output_ids = build_rows(tables['dataflows'], df_colidx).flat_map do |row|
  raw = df_col.call(row, df_colidx, 'Output DataSet IDs')
  raw.to_s.split(',').map(&:strip)
end.reject(&:empty?).to_set

# ---- activity-log -> usage_by_card -------------------------------------------
usage_by_card = {}
if tables['activity-log']
  al_colidx = build_colidx(tables['activity-log'])
  al_col = make_col('activity-log')
  build_rows(tables['activity-log'], al_colidx).each do |row|
    obj_type = al_col.call(row, al_colidx, 'Object Type')
    action   = al_col.call(row, al_colidx, 'Action Type')
    next unless obj_type == 'CARD' && action == 'VIEWED'
    cid = al_col.call(row, al_colidx, 'Object ID')
    next if cid.nil?
    uid = al_col.call(row, al_colidx, 'User ID')
    entry = (usage_by_card[cid] ||= { 'views' => 0, '_viewers' => Set.new })
    entry['views'] += 1
    entry['_viewers'] << uid if uid
  end
end

# ---- cards: join pages/datasets/pdp/dataflows/usage/beast-mode-refs ---------
cd_colidx = build_colidx(tables['cards'])
cd_col = make_col('cards')
cards_out = build_rows(tables['cards'], cd_colidx).map do |row|
  id         = cd_col.call(row, cd_colidx, 'Card ID')
  dataset_id = cd_col.call(row, cd_colidx, 'DataSet ID')
  beast_raw  = cd_col.call(row, cd_colidx, 'Beast Mode Refs') # Tier-A only

  {
    'id'               => id,
    'title'            => cd_col.call(row, cd_colidx, 'Card Title'),
    'type'             => cd_col.call(row, cd_colidx, 'Card Type'),
    'page_id'          => cd_col.call(row, cd_colidx, 'Page ID'),
    'dataset_id'       => dataset_id,
    'views'            => usage_by_card.dig(id, 'views') || 0,
    'beast_modes'      => parse_beast_mode_refs(beast_raw),
    'pdp'              => pdp_dataset_ids.include?(dataset_id),
    'dataflow_sourced' => dataflow_output_ids.include?(dataset_id)
  }
end

# ---- write inventory.json -----------------------------------------------------
instance =
  if options[:fixtures]
    "fixtures:#{File.basename(File.expand_path(options[:fixtures]))}"
  else
    ENV.fetch('DOMO_INSTANCE', 'unknown')
  end

inventory = {
  'instance' => instance,
  'datasets' => datasets_out,
  'pages'    => pages_out,
  'cards'    => cards_out,
  'users'    => users_out,
  'warnings' => WARNINGS
}

inv_path = File.join(options[:out], 'inventory.json')
File.write(inv_path, JSON.pretty_generate(inventory))
warn "wrote #{inv_path} (#{cards_out.size} cards, #{WARNINGS.size} shape warnings)"

# ---- write usage.json (only when an activity-log table is present) -----------
if tables['activity-log']
  usage_out = {
    'by_card' => usage_by_card.each_with_object({}) do |(cid, v), h|
      h[cid] = { 'views' => v['views'], 'distinct_viewers' => v['_viewers'].size }
    end
  }
  usage_path = File.join(options[:out], 'usage.json')
  File.write(usage_path, JSON.pretty_generate(usage_out))
  warn "wrote #{usage_path} (#{usage_out['by_card'].size} card(s) with usage)"
else
  warn 'no activity-log table -- usage.json not written (no audit scope)'
end
