#!/usr/bin/env ruby
# Phase 3 — Data model builder.
#
# Domo DataSets are flat, materialized tables (no relational model), so the Sigma
# DM is ~1 table element per DataSet. This emits a /v2/dataModels/spec-shaped JSON
# (schemaVersion 1) with:
#   - one warehouse-table element per USED DataSet (clean display names — fixes
#     the raw snake_case-labels complaint at the source)
#   - PROJECTION (row-level) Beast Modes as DM calc columns
#   - AGGREGATE dataset Beast Modes as first-class Sigma metrics
#   - WINDOW/LOD formulas as explicit deferred accounting outcomes
#
# Domo data lands in a warehouse Sigma reads; that mapping is customer-specific and
# CANNOT be guessed IN GENERAL. Supply discovery/dataset-map.json:
#   { "<datasetId>": { "connectionId": "...", "database": "DB", "schema": "SCH",
#                      "table": "TABLE", "name": "Nice Element Name" }, ... }
# Run without it once and this writes discovery/dataset-map.template.json to fill.
#
# ── Auto-fill (2026-07-30 live validation) ──────────────────────────────────
# For CONNECTOR-BACKED DataSets, database/schema/table is NOT actually a
# guess: Domo's own stream configuration carries it 1:1 (see
# refs/live-validation-2026-07-30.md "Snowflake connector — dataset→warehouse
# mapping is discoverable"). Every missing/blank entry in dataset-map.json is
# now auto-filled from `GET /api/data/v1/streams/{streamId}` where possible —
# see derive_map_entry below for exactly what is and isn't derivable.
# `connectionId` is a SIGMA-side id with no Domo analog and is NEVER derived —
# it always needs a human, same as before. (If you're setting up a NEW
# connector account to backfill a stream, prefer the live-validated keypair
# Snowflake connector `com.domo.connector.snowflakekeypairauthentication` —
# the plain `com.domo.connector.snowflake[.v2]` versions are rejected as
# DEPRECATED for new streams.)
#
#   ruby scripts/build-dm.rb            # → discovery/dm-spec.json
#
# Then POST via the reused post-and-readback.rb (Phase 4), which returns server IDs.

require 'json'
require 'fileutils'
require_relative 'lib/domo_sigma_util'
require_relative 'lib/domo_rest'   # auto-fill's thin network seam — see fetch_stream_config
require_relative 'lib/column_preflight' # shared SENTINEL_SOURCES — see the "needs review" warning below
include DomoSigma   # display_name, rand_id, inode_id — shared with build-workbook.rb

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

# C3 reuse-check: consume find-or-pick-dm.rb's real --out file (dm-match.json),
# shaped {recommended_dm_id, auto_picked, ...} — the same shape the sibling
# cognos/looker converters key off of.
def reuse_decision(dir)
  path = File.join(dir, 'dm-match.json')
  return nil unless File.exist?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError
  nil
end

# ---------------------------------------------------------------------------
# Auto-fill dataset-map.json from Domo's stream configuration (2026-07-30 live
# validation). Split into small pure pieces + one thin network seam so the
# derivation logic is unit-testable with NO credentials and NO network
# (test/test-build-dm.rb stubs `fetcher:`), while build-dm.rb's real run uses
# the live Domo.private_get calls below.

# Flatten a Domo stream's `configuration` array
# ({streamId, category:"STREAM", name, type, value}) into a plain name=>value
# Hash. Pure — no network. Observed names: databaseName, schemaName,
# tableName, warehouseName, query, reportType.
def stream_config_hash(configuration)
  Array(configuration).each_with_object({}) do |c, h|
    h[c['name']] = c['value'] if c.is_a?(Hash) && c['name']
  end
end

# Network seam: DataSet id -> flattened stream-config Hash (or {} when there's
# nothing to find). Deliberately tolerant of EVERY failure mode — no dev token
# (Tier B), the dataset has no streamId, the stream fetch 404s/errors — because
# a miss here must degrade to "couldn't auto-derive," never abort the build:
# connectionId already requires a human regardless of what this finds.
# `Domo.private_get` returns nil outright when DOMO_DEV_TOKEN is unset, so this
# is also safe to call with zero Domo credentials configured.
def fetch_stream_config(ds_id)
  return {} if Domo.dev_token.nil?
  detail = (Domo.private_get("/api/data/v3/datasources/#{ds_id}") rescue nil)
  stream_id = detail.is_a?(Hash) ? detail['streamId'] : nil
  return {} unless stream_id
  stream = (Domo.private_get("/api/data/v1/streams/#{stream_id}") rescue nil)
  stream.is_a?(Hash) ? stream_config_hash(stream['configuration']) : {}
end

# Derive one dataset-map.json entry from a DataSet + its flattened stream
# config (`conf` — possibly {}, see fetch_stream_config). NEVER invents
# `connectionId` (Sigma-side; has no Domo analog) and NEVER invents a table
# name when one isn't actually derivable — those cases are FLAGGED via
# `_source`/`_note`, not guessed, so nothing silently looks confirmed:
#
#   "domo-stream-config"              tableName present on the stream ->
#                                      real warehouse-table mapping.
#   "domo-stream-config-query-only"   a custom-SQL report stream (`query`
#                                      present, no tableName) -> `table` stays
#                                      nil; the SQL is recorded under `_query`
#                                      for a human to turn into a table/view
#                                      or a Sigma custom-SQL source.
#   "domo-landed-data"                 no connector stream config at all (api /
#                                      webform / excel-upload / sample-data
#                                      DataSets) -> there is no warehouse
#                                      location; land-vs-repoint applies.
def derive_map_entry(dataset, conf)
  conf = conf || {}
  base = { 'connectionId' => '', 'name' => dataset['name'] }
  if conf['tableName']
    base.merge('database' => conf['databaseName'], 'schema' => conf['schemaName'],
               'table' => conf['tableName'], '_source' => 'domo-stream-config')
  elsif conf['query']
    base.merge('database' => conf['databaseName'], 'schema' => conf['schemaName'],
               'table' => nil, '_source' => 'domo-stream-config-query-only',
               '_query' => conf['query'],
               '_note' => 'custom-SQL report stream: no single table to derive — turn `_query` ' \
                          'into a warehouse table/view, or a Sigma custom-SQL source, by hand')
  else
    base.merge('database' => nil, 'schema' => nil, 'table' => nil,
               '_source' => 'domo-landed-data',
               '_note' => 'no connector stream config found (api/webform/excel-upload/sample data) — ' \
                          'this DataSet has no warehouse location; land it or repoint by hand')
  end
end

# Fill in every id in `ids` whose dataset-map.json entry is missing a real
# `table` — a completely absent id, an entry with a blank/empty table, or one
# a PRIOR auto-fill pass already flagged (still nil). Never touches an entry
# that already has a real table, hand-authored or previously derived, so a
# human's work is never clobbered. The one field a human may already have
# supplied that must never be overwritten either way is `connectionId` — it
# can never be derived from Domo, so it always survives untouched.
#
# `fetcher` is the network seam (ds_id -> stream-config Hash via
# fetch_stream_config); tests inject a stub here to stay fully offline.
# Returns [merged_map, count_of_entries_touched_this_pass].
def autofill_dataset_map(ds_map, ds_by_id, ids, fetcher: method(:fetch_stream_config))
  merged = ds_map.dup
  touched = 0
  ids.each do |id|
    entry = merged[id]
    next if entry && !entry['table'].to_s.strip.empty?

    dataset = ds_by_id[id] || { 'id' => id, 'name' => id }
    derived = derive_map_entry(dataset, fetcher.call(id))
    derived['connectionId'] = entry['connectionId'] if entry && !entry['connectionId'].to_s.strip.empty?
    derived['name'] = entry['name'] if entry && !entry['name'].to_s.strip.empty?
    merged[id] = derived
    touched += 1
  end
  [merged, touched]
end

# When a dataset-map entry has no derivable table (query-only stream, or a
# non-connector "landed data" DataSet — see derive_map_entry), build_element
# must NEVER fall back to guessing a table from the DataSet's display name —
# that would silently look like a confirmed warehouse mapping. Emit an
# unmistakable sentinel instead, mirroring the existing '<CONNECTION_ID>'
# placeholder convention, so a human catches it before this DM spec is posted.
def placeholder_table(map_entry)
  case map_entry['_source']
  when 'domo-stream-config-query-only' then '<TABLE:QUERY_ONLY_NEEDS_HUMAN>'
  when 'domo-landed-data'               then '<TABLE:LANDED_DATA_NO_WAREHOUSE_SOURCE>'
  end
end

# Domo type → optional Sigma column format hint.
# Domo column type → Sigma column `format` object.
#
# LIVE-VALIDATED FIX (2026-07-30): this used to emit { 'type' => 'date' } /
# { 'type' => 'datetime' }. Sigma rejects that outright —
#   POST /v2/dataModels/spec →
#   "pages[0].elements[0].columns[8].format: Missing \"kind\" field"
# The format object keys on **kind**, never `type`, and there is no `date` kind:
# `datetime` covers both, with formatString controlling display. See
# plugins/sigma-authoring/skills/sigma-data-models/reference/formatting.md.
# Any DATE column in the source made the whole DM POST fail.
def type_format(domo_type)
  case domo_type.to_s.upcase
  when 'DATE'     then { 'kind' => 'datetime', 'formatString' => '%Y-%m-%d' }
  when 'DATETIME' then { 'kind' => 'datetime', 'formatString' => '%Y-%m-%d %H:%M:%S' }
  when 'LONG', 'DECIMAL', 'DOUBLE' then nil # numbers: leave default; number-format applied at workbook layer
  end
end

def beast_mode_spec_id(prefix, bm)
  token = (bm['id'] || bm['name'] || 'calc').to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
  "#{prefix}-#{token}"
end

def unique_semantic_name(raw_name, used_names)
  base = display_name(raw_name.to_s.empty? ? 'Calc' : raw_name)
  candidate = base
  if used_names.include?(candidate.downcase)
    candidate = "#{base} (Beast Mode)"
    n = 2
    while used_names.include?(candidate.downcase)
      candidate = "#{base} (Beast Mode #{n})"
      n += 1
    end
  end
  used_names << candidate.downcase
  candidate
end

def beast_mode_block_reason(bm)
  return "source extraction failed: #{bm['extractionError']}" if bm['extractionError']
  return 'no translated Sigma formula' if bm['sigmaFormula'].to_s.strip.empty?
  return 'automated translation was flagged converted:false; add formula-overrides.json' if bm['converted'] == false
  return "formula lint errors: #{Array(bm['lintErrors']).join('; ')}" unless Array(bm['lintErrors']).empty?
  return 'dataset/card definitions for this id contain divergent SQL' if bm['definitionConflict']
  nil
end

# Sigma resolves same-element references case-insensitively and treats
# underscores like spaces, but it does not camel-split a reference at compile
# time. Validate every calculated column/metric against the exact namespace this
# builder emits so a dangling [Call DateTime] cannot survive until REST POST when
# the actual column is named "Call Date Time".
def sigma_reference_key(name)
  name.to_s.tr('_', ' ').downcase.gsub(/\s+/, ' ').strip
end

def emitted_column_name(column)
  return column['name'] unless column['name'].to_s.strip.empty?

  match = column['formula'].to_s.match(/\A\[[^\/\]]+\/([^\]]+)\]\z/)
  match && match[1]
end

def validate_element_formula_references!(element, dataset_id:)
  named_columns = Array(element['columns']).each_with_object([]) do |column, names|
    name = emitted_column_name(column)
    names << name if name
  end
  named_metrics = Array(element['metrics']).map { |metric| metric['name'] }.compact
  known = (named_columns + named_metrics).each_with_object({}) do |name, index|
    index[sigma_reference_key(name)] = name
  end

  calculated = Array(element['columns']).select { |column| !column['name'].to_s.strip.empty? }
  calculated += Array(element['metrics'])
  failures = calculated.each_with_object([]) do |item, out|
    missing = formula_column_references(item['formula']).reject {
      |reference| known.key?(sigma_reference_key(reference))
    }.uniq
    next if missing.empty?

    out << "#{item['name'] || item['id']}: " \
           "#{missing.map { |reference| "[#{reference}]" }.join(', ')}"
  end
  return element if failures.empty?

  raise ArgumentError,
        "data-model formula reference preflight failed for dataset #{dataset_id}: " \
        "#{failures.join('; ')}. Emitted names: #{known.values.sort.join(', ')}"
end

# Build one warehouse-table element for a DataSet.
def build_element(ds, map_entry, dataset_bms, outcomes: [])
  table = map_entry['table'] || placeholder_table(map_entry) || map_entry['name'] || ds['name'] || 'TABLE'
  el_id = rand_id
  cols = []
  order = []

  # LIVE-VALIDATED FIX (2026-07-30): this used to fall back to `ds['columns']`,
  # but discovery's datasets.json comes from the PUBLIC LIST endpoint
  # (GET /v1/datasets), whose `columns` is an Integer COUNT — there is no
  # `schema` key on a list entry at all:
  #   {"id":"...","name":"Orders Fact","rows":877,"columns":29}
  # So the fallback both crashed (`29.each`) and, worse, would have produced a
  # data model with ZERO columns. Only the per-dataset DETAIL endpoint
  # (GET /v1/datasets/{id}) carries schema.columns[] as an array of
  # {"name","type"}; domo-discover.rb enriches datasets.json with it.
  #
  # A DM with no columns must NEVER be posted silently — fail loudly and name
  # the dataset so the operator knows exactly which discovery record is thin.
  schema_cols = ds.dig('schema', 'columns')
  unless schema_cols.is_a?(Array)
    raise ArgumentError, "dataset #{ds['id'].inspect} (#{ds['name'].inspect}) has no " \
      "schema.columns array (got #{schema_cols.class}: #{schema_cols.inspect[0, 40]}). " \
      "datasets.json was probably written from the PUBLIC LIST endpoint, whose " \
      "`columns` is a COUNT. Re-run domo-discover.rb so each dataset is enriched " \
      "from GET /v1/datasets/{id} (schema.columns), then rebuild."
  end
  # A Domo DataSet routinely carries columns the mapped WAREHOUSE table does not
  # have — Domo-side derived/computed columns, or a landed copy that drifted from
  # its source. Emitting a bare reference for those fails only at POST time, with
  # an opaque server error:
  #   "Cannot resolve columns on table 'X': dependency not found:
  #    formula reference 'order_fact/order date'"
  # (live-validated 2026-07-30; bead m655). Until build-dm can pre-flight columns
  # against the warehouse itself, let the operator resolve it explicitly in
  # dataset-map.json — the gap becomes declared and visible instead of a 400:
  #
  #   "<datasetId>": {
  #     "connectionId": "...", "database": "DB", "schema": "SCH", "table": "T",
  #     "excludeColumns": ["SOME_DOMO_ONLY_COL"],
  #     "columnOverrides": {
  #       "ORDER_DATE": { "formula": "MakeDate(Floor([Order Date Key]/10000), ...)" }
  #     }
  #   }
  #
  # `excludeColumns` drops a Domo-only column; `columnOverrides[<COL>].formula`
  # keeps it but derives it from columns that DO exist (e.g. a YYYYMMDD integer
  # surrogate key -> MakeDate). Both are reported so nothing is silent.
  excluded  = Array(map_entry['excludeColumns']).map { |s| s.to_s.upcase }
  overrides = (map_entry['columnOverrides'] || {}).each_with_object({}) do |(k, v), h|
    h[k.to_s.upcase] = v
  end
  dropped = []
  derived = []
  used_names = []

  schema_cols.each do |c|
    raw = c['name'] || c['id']
    next unless raw
    if excluded.include?(raw.to_s.upcase)
      dropped << raw
      next
    end
    id  = inode_id(raw)
    ov  = overrides[raw.to_s.upcase]
    if ov.is_a?(Hash) && !ov['formula'].to_s.empty?
      # An explicit `name` is REQUIRED on a calc column. Without it Sigma
      # auto-names the column **"Calc"**, so every downstream reference
      # ([Master/Order Date], DateTrunc("month", [Master/Order Date]), …) fails
      # with "Dependency not found" — verified live 2026-07-30. A warehouse-table
      # column doesn't need it (the name comes from the [TABLE/Display] ref); a
      # derived one does.
      col = { 'id' => id, 'name' => display_name(raw), 'formula' => ov['formula'].to_s }
      derived << raw
    else
      col = { 'id' => id, 'formula' => "[#{table}/#{column_ref_name(raw)}]" }
    end
    fmt = ov.is_a?(Hash) && ov['format'] ? ov['format'] : type_format(c['type'])
    col['format'] = fmt if fmt
    cols << col
    order << id
    used_names << display_name(raw).downcase
  end

  # Surface both resolutions — a declared gap the operator can audit, never silent.
  warn "  dataset #{ds['id']}: dropped #{dropped.size} Domo-only column(s) per " \
       "excludeColumns: #{dropped.join(', ')}" unless dropped.empty?
  warn "  dataset #{ds['id']}: derived #{derived.size} column(s) via columnOverrides " \
       "(not present in #{table}): #{derived.join(', ')}" unless derived.empty?

  metrics = []
  Array(dataset_bms).each do |bm|
    common = {
      'id' => bm['id'],
      'name' => bm['name'],
      'class' => bm['class'],
      'scope' => bm['scope'],
      'dataSourceId' => ds['id'],
    }.compact
    if (reason = beast_mode_block_reason(bm))
      outcomes << common.merge('status' => 'blocked', 'reason' => reason)
      next
    end

    case bm['class']
    when 'projection'
      name = unique_semantic_name(bm['name'], used_names)
      id = beast_mode_spec_id('bm-col', bm)
      cols << {
        'id' => id,
        'name' => name,
        'formula' => normalize_formula_column_refs(bm['sigmaFormula']),
      }
      order << id
      outcomes << common.merge('status' => 'emitted', 'target' => 'data-model-column',
                               'targetId' => id, 'sigmaName' => name)
    when 'aggregate'
      name = unique_semantic_name(bm['name'], used_names)
      id = beast_mode_spec_id('bm-metric', bm)
      metrics << {
        'id' => id,
        'name' => name,
        'formula' => normalize_formula_column_refs(bm['sigmaFormula']),
      }
      outcomes << common.merge('status' => 'emitted', 'target' => 'data-model-metric',
                               'targetId' => id, 'sigmaName' => name)
    when 'window', 'lod'
      outcomes << common.merge(
        'status' => 'deferred',
        'reason' => "#{bm['class']} Beast Modes require an explicit Sigma placement/override",
      )
    else
      outcomes << common.merge('status' => 'blocked',
                               'reason' => "unknown Beast Mode class #{bm['class'].inspect}")
    end
  end

  element = {
    'id' => el_id, 'kind' => 'table',
    'source' => {
      'connectionId' => map_entry['connectionId'] || '<CONNECTION_ID>',
      'kind' => 'warehouse-table',
      'path' => [map_entry['database'], map_entry['schema'], table].compact,
    },
    'columns' => cols, 'metrics' => metrics, 'order' => order, 'relationships' => [],
    '_datasetId' => ds['id'],
  }
  validate_element_formula_references!(element, dataset_id: ds['id'])
end

if $PROGRAM_NAME == __FILE__
  # 🚧 Environment gate (Windows / cross-user parity). Phase 3 is the first BUILD
  # step, so it refuses to start until the Step-0 doctor (scripts/doctor.sh on
  # macOS/Linux/Git-Bash, scripts/doctor.ps1 on Windows PowerShell) has written a
  # PASSING doctor.json — the same gate the other migration skills enforce, so a
  # broken environment stops here with an explicit fix instead of the run
  # improvising around a missing runtime. Waive by naming a reason:
  #   SIGMA_SKIP_DOCTOR_GATE="<reason>" ruby scripts/build-dm.rb
  gate = File.join(__dir__, 'assert-doctor-ran.rb')
  if File.exist?(gate)
    gate_cmd = ['ruby', gate]
    skip = ENV['SIGMA_SKIP_DOCTOR_GATE'].to_s.strip
    gate_cmd += ['--skip-doctor-gate', skip] unless skip.empty?
    abort '  build-dm.rb aborted at the environment gate (see the fix above).' unless system(*gate_cmd)
  end

  # C3 reuse-check: only short-circuit on a CONFIRMED auto-pick (covers all
  # source tables / column-superset — see find-or-pick-dm.rb's rationale). A
  # merely-scored-but-not-auto_picked candidate must NOT silently reuse — fall
  # through to building a fresh DM, same as the cognos/looker converters.
  m = reuse_decision(OUT)
  if m && m['auto_picked'] && m['recommended_dm_id']
    formula_catalog = JSON.parse(File.read(File.join(OUT, 'formulas.json'))) rescue []
    required_semantics = Array(formula_catalog).select { |formula| formula['scope'] == 'dataset' }
    if required_semantics.any?
      warn "  reuse-check: candidate #{m['recommended_dm_id']} covers source tables/columns but this " \
           "migration requires #{required_semantics.size} dataset Beast Mode(s). Automatic reuse is " \
           'refused until metric/calc coverage is proven; building a fresh data model instead.'
    else
      # NOTE: this short-circuits BEFORE the C9 PDP/RLS scan below — intentional,
      # not an oversight. Row-level security travels with the reused data model.
      FileUtils.mkdir_p(OUT)
      File.write(File.join(OUT, 'dm-reuse.json'), JSON.generate({ 'reused' => m['recommended_dm_id'] }))
      warn "  reuse-check: reusing existing data model #{m['recommended_dm_id']} (find-or-pick-dm auto-pick) — skipping DM creation."
      exit 0
    end
  end

  datasets = JSON.parse(File.read(File.join(OUT, 'datasets.json'))) rescue []
  cards    = JSON.parse(File.read(File.join(OUT, 'cards.json')))    rescue []
  formulas = JSON.parse(File.read(File.join(OUT, 'formulas.json'))) rescue []

  # C9: Domo PDP (row-level permission policies) — detect, never silently drop.
  # Stubbed as opt-in Sigma RLS: written to discovery/rls-todo.json for a human to
  # translate into a data-model row-level-security policy (SKILL.md Phase 6 Security).
  pdp = datasets.flat_map { |ds| detect_pdp(ds) }
  unless pdp.empty?
    FileUtils.mkdir_p(OUT)
    File.write(File.join(OUT, 'rls-todo.json'), JSON.generate({ 'policies' => pdp }))
    warn "  C9/RLS: #{pdp.length} Domo PDP policy(ies) detected — wrote discovery/rls-todo.json. " \
         'Apply as Sigma row-level security opt-in; NOT auto-applied.'
  end

  # Which datasets does the workbook actually use?
  used = cards.map { |c| c['datasetId'] }.compact.uniq
  used = datasets.map { |d| d['id'] }.compact if used.empty?
  ds_by_id = datasets.each_with_object({}) { |d, h| h[d['id']] = d }

  # Customer dataset→warehouse map. connectionId is ALWAYS a human's job
  # (Sigma-side id, no Domo analog); database/schema/table now auto-fill from
  # Domo's connector stream config where derivable — see
  # "Auto-fill (2026-07-30 live validation)" above and derive_map_entry.
  map_path = File.join(OUT, 'dataset-map.json')
  if File.exist?(map_path)
    existing = JSON.parse(File.read(map_path))
    # File already exists — hand-authored, previously auto-filled, or a mix.
    # Only fill entries still missing a real `table`; a complete entry
    # (hand-authored or already-derived) is left untouched.
    ds_map, filled = autofill_dataset_map(existing, ds_by_id, used)
    if filled > 0
      File.write(map_path, JSON.pretty_generate(ds_map))
      warn "  auto-fill: derived a warehouse location for #{filled} dataset(s) from Domo stream " \
           'config (see "_source" per entry in dataset-map.json) — connectionId still needs a human.'
    end
  else
    # No dataset-map.json at all yet: attempt auto-fill for every used
    # DataSet and write a TEMPLATE (still requires one human pass —
    # connectionId can never be derived) pre-filled with whatever Domo's
    # stream config makes derivable, instead of a blank stub to hand-author
    # from scratch.
    ds_map, _ = autofill_dataset_map({}, ds_by_id, used)
    FileUtils.mkdir_p(OUT)
    File.write(File.join(OUT, 'dataset-map.template.json'), JSON.pretty_generate(ds_map))
    warn "  No discovery/dataset-map.json. Wrote dataset-map.template.json — auto-filled what Domo's"
    warn '  stream config can tell us per DataSet (see "_source"/"_note" per entry). Fill in the'
    warn '  remaining connectionId (always a human) and resolve any flagged entries, rename to'
    warn '  dataset-map.json, re-run.'
    exit 2
  end

  # Column pre-flight gate (bead m655): refuse to build a DM spec until every
  # used dataset's Domo columns are confirmed resolvable against the mapped
  # warehouse table (or already excludeColumns/columnOverrides'd) — see
  # docs/superpowers/specs/2026-07-31-domo-dm-column-preflight-design.md and
  # scripts/preflight-columns.rb. Runs here (after dataset-map.json is
  # confirmed to exist, before elements are built) — NOT before the C3
  # reuse-shortcut above, which exits before building anything new and has
  # nothing to pre-flight. Waivable the same way the doctor-gate above is:
  # name a reason.
  preflight_path = File.join(OUT, 'column-preflight.json')
  preflight_skip = ENV['SIGMA_SKIP_COLUMN_PREFLIGHT'].to_s.strip
  if preflight_skip.empty?
    unless File.exist?(preflight_path)
      abort "  build-dm.rb aborted: discovery/column-preflight.json not found — run " \
            'scripts/preflight-columns.rb first (checks Domo dataset columns against the ' \
            'real warehouse table before this build). Waive with ' \
            'SIGMA_SKIP_COLUMN_PREFLIGHT="<reason>" ruby scripts/build-dm.rb'
    end
    if File.mtime(preflight_path) < File.mtime(map_path)
      abort "  build-dm.rb aborted: discovery/column-preflight.json predates discovery/dataset-map.json " \
            '(the mapping changed since the last pre-flight check) — re-run ' \
            'scripts/preflight-columns.rb to regenerate it, then re-run this.'
    end
    preflight_report = begin
      JSON.parse(File.read(preflight_path))
    rescue JSON::ParserError => e
      abort "  build-dm.rb aborted: discovery/column-preflight.json exists but failed to parse " \
            "(#{e.message}) — re-run scripts/preflight-columns.rb to regenerate it."
    end
    unless preflight_report.is_a?(Hash)
      abort "  build-dm.rb aborted: discovery/column-preflight.json did not parse to a Hash " \
            "(got #{preflight_report.class}) — re-run scripts/preflight-columns.rb to regenerate it."
    end
    unresolved = preflight_report.select { |_, v| !(v['missing'] || []).empty? || v['error'] }
    unless unresolved.empty?
      warn "  build-dm.rb aborted: #{unresolved.size} dataset(s) still have unresolved columns " \
           '(see discovery/column-preflight.json for names + any auto-suggested columnOverrides):'
      unresolved.each do |id, v|
        detail = v['error'] || (v['missing'] || []).join(', ')
        warn "    #{id} (#{v['table']}): #{detail}"
      end
      abort '  Resolve via excludeColumns/columnOverrides in dataset-map.json, then re-run ' \
            'scripts/preflight-columns.rb.'
    end
  else
    warn "  ⚠ column pre-flight gate WAIVED (SIGMA_SKIP_COLUMN_PREFLIGHT=#{preflight_skip.inspect}) — " \
         'unresolved columns may still 400 at DM POST time.'
  end

  # Dataset-scoped Beast Modes grouped by source. Projection formulas become
  # calculated columns; aggregate formulas become first-class Sigma metrics.
  # Window/LOD/unreliable formulas are recorded with explicit dispositions.
  bms_by_ds = Hash.new { |h, k| h[k] = [] }
  formulas.each do |f|
    next unless f['scope'] == 'dataset'
    bms_by_ds[f['dataSourceId'] || f['_dataSourceId']] << f
  end

  bm_outcomes = []
  elements = used.map do |id|
    ds = ds_by_id[id] || { 'id' => id, 'name' => id }
    entry = ds_map[id] || {}
    build_element(ds, entry, bms_by_ds[id], outcomes: bm_outcomes)
  end
  # A translated dataset formula with no source id cannot be attached to any
  # model element. Record it as blocked rather than silently losing it under
  # Hash[nil].
  Array(bms_by_ds[nil]).each do |bm|
    bm_outcomes << {
      'id' => bm['id'], 'name' => bm['name'], 'class' => bm['class'],
      'scope' => bm['scope'], 'status' => 'blocked',
      'reason' => 'dataset-scoped formula has no dataSourceId',
    }.compact
  end

  # LIVE-VALIDATED FIX (2026-07-30): the DM spec MUST carry a folderId or
  # POST /v2/dataModels/spec rejects it outright:
  #   "Expecting UUID at 0.folderId but instead got: undefined"
  # This was never emitted, and migrate-domo.rb only threaded --folder-id into
  # build-workbook-spec — so the data-model POST could not succeed in live mode
  # at all. Accept it from --folder-id or SIGMA_FOLDER_ID (env), and warn
  # explicitly when absent rather than writing a spec that is guaranteed to 400.
  folder_id = nil
  if (i = ARGV.index('--folder-id'))
    folder_id = ARGV[i + 1]
  end
  folder_id ||= ENV['SIGMA_FOLDER_ID']

  spec = {
    'name' => 'Domo Migration',
    'schemaVersion' => 1,
    'pages' => [{ 'id' => rand_id, 'name' => 'Data', 'elements' => elements }],
  }
  if folder_id.to_s.empty?
    warn '  ⚠ no folderId (pass --folder-id <uuid> or set SIGMA_FOLDER_ID) — ' \
         'POST /v2/dataModels/spec WILL fail with "Expecting UUID at 0.folderId".'
  else
    spec['folderId'] = folder_id
  end
  FileUtils.mkdir_p(OUT)
  File.write(File.join(OUT, 'dm-spec.json'), JSON.pretty_generate(spec))
  File.write(File.join(OUT, 'beast-mode-dm-outcomes.json'), JSON.pretty_generate(
    'sourceCount' => formulas.count { |formula| formula['scope'] == 'dataset' },
    'outcomes' => bm_outcomes,
  ))
  warn "  wrote #{File.join(OUT, 'dm-spec.json')} (#{elements.size} element(s))"
  emitted_metrics = bm_outcomes.count { |outcome| outcome['target'] == 'data-model-metric' }
  emitted_columns = bm_outcomes.count { |outcome| outcome['target'] == 'data-model-column' }
  blocked_bms = bm_outcomes.count { |outcome| outcome['status'] == 'blocked' }
  deferred_bms = bm_outcomes.count { |outcome| outcome['status'] == 'deferred' }
  warn "  Beast Modes: #{emitted_columns} calc column(s), #{emitted_metrics} metric(s), " \
       "#{deferred_bms} deferred, #{blocked_bms} blocked — see beast-mode-dm-outcomes.json"
  missing = ds_map.select { |_, v| v['connectionId'].to_s.empty? }.keys
  warn "  ⚠ #{missing.size} dataset(s) have no connectionId — fill dataset-map.json: #{missing.join(', ')}" unless missing.empty?
  needs_review = ds_map.select { |_, v| ColumnPreflight::SENTINEL_SOURCES.include?(v['_source']) }.keys
  unless needs_review.empty?
    warn "  ⚠ #{needs_review.size} dataset(s) need human review before this DM is posted (query-only " \
         'stream or no warehouse source at all — see "_source"/"_note" in dataset-map.json, and the ' \
         "<TABLE:...> sentinel in dm-spec.json): #{needs_review.join(', ')}"
  end
  warn "\n  Next (Phase 4): post-and-readback.rb dm-spec.json  (captures server element/column IDs)"
end
