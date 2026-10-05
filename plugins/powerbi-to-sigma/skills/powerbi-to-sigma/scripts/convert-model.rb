#!/usr/bin/env ruby
# convert-model.rb — turn a Power BI model.bim into a postable Sigma DM spec.
#
# Power BI analog of the Tableau DM-build step. The actual TMSL→Sigma conversion
# is done by the `convert_powerbi_to_sigma` MCP tool (or the /tmp/conv-fix CLI
# build) — that's an agent/MCP call, not a library this script can import. So
# this script does the two deterministic halves that bracket the MCP call:
#
#   MODE A (--bim ...): print the exact MCP call the agent should make, and the
#   warehouse db/schema/connection it should pass. (Discovery + instruction.)
#
#   MODE B (--converter-out ...): take the MCP's sigmaDataModel JSON and apply
#   the 3 required spec fixups (refs/spec-fixups.md, gap beads-sigma-tkd) so it
#   is accepted by POST /v2/dataModels/spec:
#     1. schemaVersion: 1 at top level
#     2. folderId + ownerId harvested from a reference DM (find-or-pick-dm.rb)
#     3. element `name` on every base warehouse-table element (= source.path[-1]),
#        because workbook masters reference DM elements BY NAME.
#   Writes a ready-to-post spec. Does NOT post (post-and-readback.rb does that),
#   so the step is idempotent and re-runnable.
#
# Usage:
#   # A — emit the MCP instruction for a model.bim:
#   ruby scripts/convert-model.rb --bim /tmp/pbix/model.bim \
#       --connection <connUUID> --database <DB> --schema <SCHEMA>
#
#   # B — apply fixups to the converter output:
#   ruby scripts/convert-model.rb --converter-out /tmp/pbix/dm-raw.json \
#       --ref-dm <referenceDataModelId> \
#       --out /tmp/pbix/dm-spec.json
#       [--name "Workforce KitchenSink (from Power BI)"]
#       [--folder-id <uuid> --owner-id <id>]   # skip ref-dm harvest if both given
#
# Env (mode B harvest): SIGMA_BASE_URL plus a valid caller token, stored browser
# session, or SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET fallback.

require 'json'
require 'optparse'
require 'open3'
require_relative 'dax-restructure-patterns'
require_relative 'lib/warehouse_column_refs'

opts = {}
OptionParser.new do |p|
  p.on('--bim PATH')            { |v| opts[:bim] = v }
  p.on('--connection ID')       { |v| opts[:conn] = v }
  p.on('--database DB')         { |v| opts[:db] = v }
  p.on('--schema S')            { |v| opts[:schema] = v }
  p.on('--converter-out PATH')  { |v| opts[:cvt] = v }
  p.on('--ref-dm ID')           { |v| opts[:ref_dm] = v }
  p.on('--folder-id ID')        { |v| opts[:folder] = v }
  p.on('--owner-id ID')         { |v| opts[:owner] = v }
  p.on('--name NAME')           { |v| opts[:name] = v }
  p.on('--out PATH')            { |v| opts[:out] = v }
  p.on('--restructure-map PATH','Optional JSON: measure name -> {generator, args} overrides for (b)-bucket DAX') { |v| opts[:rmap] = v }
  p.on('--table-map PATH','Optional JSON: model table -> actual warehouse table name; repoints sources + base column refs (use when the customer landed import-mode data under different table names)') { |v| opts[:tmap] = v }
  p.on('--restructure-from-bim PATH','model.bim to scan for (b)-bucket DAX measures to auto-emit as elements') { |v| opts[:rbim] = v }
end.parse!

# bead hjke(a): a truncated/partial --connection id posts a DM whose sources
# silently fail downstream ("Source not found" only at POST, or worse). Abort
# early with a clear message unless it is a full UUID.
UUID_RE = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
if opts[:conn] && opts[:conn] !~ UUID_RE
  abort "FATAL: --connection must be a FULL Sigma connection UUID " \
        "(8-4-4-4-12 hex, e.g. ab12cd34-1234-5678-9abc-def012345678); got #{opts[:conn].inspect}. " \
        "List connections with GET /v2/connections."
end

# ---- MODE A: emit the MCP conversion instruction --------------------------
if opts[:bim]
  abort('--bim not found: ' + opts[:bim]) unless File.exist?(opts[:bim])
  warn "=" * 64
  warn "convert-model.rb MODE A — run this MCP call to convert the model:"
  warn "=" * 64
  warn "  mcp__sigma-data-model__convert_powerbi_to_sigma"
  warn "    model_json    = <contents of #{opts[:bim]}>"
  warn "    connection_id = #{opts[:conn] || '<conn UUID, or \"\" to omit>'}"
  warn "    database      = #{opts[:db] || '<DB, or \"\" — needed for the M-Snowflake gap j89>'}"
  warn "    schema        = #{opts[:schema] || '<SCHEMA, or \"\">'}"
  warn ""
  warn "Save the tool's `sigmaDataModel` JSON to a file, then re-run:"
  warn "  ruby scripts/convert-model.rb --converter-out <that file> \\"
  warn "    --ref-dm <referenceDataModelId> --out /tmp/pbix/dm-spec.json"
  warn "=" * 64
  exit 0
end

# ---- MODE B: apply the 3 fixups -------------------------------------------
abort('mode B needs --converter-out and --out') unless opts[:cvt] && opts[:out]
raw = JSON.parse(File.read(opts[:cvt]))
# The converter may wrap the spec as {sigmaDataModel: {...}} (MCP), {model: {...}}
# (convertPowerBIToSigma returns {model, warnings, stats}), or return it bare —
# handle all three (and a sigmaDataModel that itself nests model).
dm = raw['sigmaDataModel'] || raw['model'] || raw
dm = dm['model'] if dm.is_a?(Hash) && dm['model']

# Harvest folderId/ownerId from a reference DM unless both supplied.
folder, owner = opts[:folder], opts[:owner]
if (folder.nil? || owner.nil?)
  abort('need --ref-dm (or both --folder-id and --owner-id)') unless opts[:ref_dm]
  require_relative 'lib/sigma_rest'
  begin
    ref = Sigma.request(:get, "/v2/dataModels/#{opts[:ref_dm]}/spec")
  rescue Sigma::Error => e
    abort("ref-dm spec fetch -> #{e.message}")
  end
  abort("ref-dm spec fetch returned #{ref.class}, expected JSON object") unless ref.is_a?(Hash)
  folder ||= ref['folderId']; owner ||= ref['ownerId']
  warn "[convert-model] harvested folderId=#{folder} ownerId=#{owner} from ref-dm #{opts[:ref_dm]}"
end

# Fixup 1: schemaVersion
dm['schemaVersion'] = 1
# Fixup 2: folderId + ownerId
dm['folderId'] = folder
dm['ownerId']  = owner
# Fixup 3: name base warehouse-table elements (= source.path[-1]) if unnamed.
named = 0
(dm['pages'] || []).each do |pg|
  (pg['elements'] || []).each do |el|
    next if el['name'] && !el['name'].to_s.empty?
    path = el.dig('source', 'path')
    if path.is_a?(Array) && !path.empty?
      el['name'] = path[-1]
      named += 1
    end
  end
end
dm['name'] = opts[:name] if opts[:name]

# Sigma connections can disable "Use friendly names". In that mode a converter
# formula such as [ORDER_FACT/Order Id] does not resolve; the exact catalog name
# is [ORDER_FACT/ORDER_ID]. Ground base columns, inode ids, and qualified derived
# references before local validation or POST. Placeholder/offline specs skip the
# live check and retain the converter output.
connection_ids = (dm['pages'] || []).flat_map { |page| page['elements'] || [] }
                 .select { |element| element.dig('source', 'kind') == 'warehouse-table' }
                 .map { |element| element.dig('source', 'connectionId').to_s }.uniq
if connection_ids.any? && connection_ids.all? { |id| id.match?(UUID_RE) }
  require_relative 'lib/sigma_rest'
  grounding = WarehouseColumnRefs.apply!(
    dm,
    requester: ->(method, path, **kwargs) { Sigma.request(method, path, **kwargs) },
    lister: ->(path) { Sigma.list_entries(path) }
  )
  modes = grounding['connectionModes'].map { |id, friendly| "#{id}=#{friendly ? 'friendly' : 'physical'}" }.join(', ')
  warn "   [convert-model] connection naming: #{modes}; grounded #{grounding['rewritten']} formula(s), " \
       "re-keyed #{grounding['rekeyed']} column id(s), re-prefixed #{grounding['reprefixed']} reference(s)"
end

# Fixup 3b (beads-sigma-<1b>): reconcile a base warehouse-table column's formula
# PREFIX to its OWN element name. The converter prefixes base columns with the PBI
# FRIENDLY table name ("[Sales/Amount]") while Fixup 3 names the element
# after the PHYSICAL path-tail ("VW_SALES"); when the friendly name != the
# physical view name (vw_* views / renames — common in enterprise models) the prefix
# is UNKNOWN and the POST fails ("prefix '…' unknown" / "dependency not found"). This
# is the customer's manual "proper-case element naming" workaround, automated. Only
# rewrite a base element's OWN 2-segment ref whose prefix matches NO element name — a
# valid cross-element ref (prefix IS a known element) is left untouched.
known_names = []
(dm['pages'] || []).each { |pg| (pg['elements'] || []).each { |el| known_names << el['name'].to_s } }
reprefixed = 0
(dm['pages'] || []).each do |pg|
  (pg['elements'] || []).each do |el|
    next unless (el['source'] || {})['kind'] == 'warehouse-table'
    name = el['name'].to_s
    next if name.empty?
    (el['columns'] || []).each do |c|
      f = c['formula']
      next unless f.is_a?(String)
      m = f.match(%r{\A\[([^\]/]+)/([^\]/]+)\]\z}) # exactly [Prefix/Leaf], a single slash
      next unless m
      pfx = m[1]
      next if pfx == name # already references its own element
      # Sigma element references are literal. Treating spaces/underscores or
      # case as equivalent makes `[Cost Center/X]` look valid when the actual
      # element is `COST_CENTER`, leaving a dependency-not-found formula.
      next if known_names.include?(pfx) # exact valid ref to a known element
      c['formula'] = "[#{name}/#{m[2]}]"
      reprefixed += 1
    end
  end
end
warn "   [convert-model] re-prefixed #{reprefixed} base column formula(s) to their element name (friendly!=physical table name)" if reprefixed.positive?

# Fixup 4 (bead xe7r): --table-map repoints warehouse-table sources at the
# tables the customer actually landed the import-mode data in (a JSON map,
# e.g. {"Store": "RETAIL_STORE"}). Two coupled rewrites, both required:
#   1. source.path tail -> the landed table name;
#   2. base column formulas "[<OLD_TAIL>/Col]" -> "[<NEW_TAIL>/Col]" — raw
#      warehouse-column refs are TABLE-TAIL-prefixed, not element-name-prefixed,
#      so a path change without the formula rewrite fails the POST with
#      "dependency not found". Element NAMES stay untouched (derived "View"
#      elements reference base elements BY NAME).
if opts[:tmap]
  require_relative 'lib/table_map'
  loaded = TableMap.load(opts[:tmap])
  warn "[convert-model] table-map: #{loaded[:tmap].size} mapping(s) from " \
       "#{loaded[:from_manifest] ? 'import-to-snowflake manifest.json' : 'plain map'}"
  applied = TableMap.apply!(dm, loaded[:tmap])
  applied.each { |a| warn "[convert-model] table-map: #{a['tail']} -> #{a['path'].join('.')}" }
  warn "[convert-model] table-map applied to #{applied.size} element(s)"
end

# ---- bjd: auto-emit (b)-bucket DAX restructure elements --------------------
# Scan the model.bim measures, classify each with DaxRestructure.classify, and
# for recognized (b)-bucket shapes splice a child SQL / grouped / join element
# (or a partitioned RankDense calc column) into the DM spec — so the hard DAX is
# migrated during convert, unattended. Extraction is best-effort from the DAX
# shape; for shapes whose join keys can't be inferred, an explicit override is
# read from --restructure-map (measure name -> {generator, args:{...}}).
def _measure_dax(m)
  e = m['expression']
  e.is_a?(Array) ? e.join : e.to_s
end

def _scan_bim_measures(bim_path)
  return [] unless bim_path && File.exist?(bim_path)
  model = JSON.parse(File.read(bim_path))
  out = []
  walk = lambda do |o|
    if o.is_a?(Hash)
      (o['measures'] || []).each { |m| out << [m['name'], _measure_dax(m)] }
      o.each_value { |v| walk.call(v) }
    elsif o.is_a?(Array)
      o.each { |x| walk.call(x) }
    end
  end
  walk.call(model)
  out
end

# Infer time-intelligence restructure args from the DM spec + measure DAX:
#   parent  = the denormalized "* View" join element (has fact + dim cols),
#   date_ref= a date column on it (prefers "Full Date", else a non-key *Date* col),
#   value   = the DAX inner aggregation (SUM/AVG/...) mapped to the View's column.
# Returns nil if it can't infer (caller falls back to --restructure-map args).
def _infer_timeintel(dm, dax)
  els = (dm['pages']&.first&.dig('elements')) || []
  parent = els.find { |e| e['name'].to_s =~ /View$/ } ||
           els.find { |e| (e['metrics'] || []).any? } || els.first
  return nil unless parent
  # Converter View cols have only {id, formula} (no name pre-POST); derive the
  # display name Sigma will assign: [A/Col]->"Col"; [A/DIM/Col]->"Col (DIM)".
  disp = lambda do |formula|
    p = formula.to_s.gsub(/^\[|\]$/, '').split('/')
    p.size <= 2 ? p[-1] : "#{p[-1]} (#{p[-2]})"
  end
  last = ->(formula) { formula.to_s.gsub(/^\[|\]$/, '').split('/')[-1] }
  cols = parent['columns'] || []
  datec = cols.find { |c| disp.call(c['formula']) =~ /full date/i } ||
          cols.find { |c| last.call(c['formula']) =~ /date/i && last.call(c['formula']) !~ /key/i }
  m = dax.match(/\b(SUM|AVERAGE|AVG|MIN|MAX|COUNT|DISTINCTCOUNT)\s*\(\s*'?[^'\[]+'?\[([^\]]+)\]/i)
  return nil unless datec && m
  agg = { 'SUM' => 'Sum', 'AVERAGE' => 'Avg', 'AVG' => 'Avg', 'MIN' => 'Min',
          'MAX' => 'Max', 'COUNT' => 'Count', 'DISTINCTCOUNT' => 'CountDistinct' }[m[1].upcase]
  col = m[2]
  vc = cols.find { |c| last.call(c['formula']).to_s.casecmp(col).zero? }
  return nil unless vc
  pn = parent['name']
  { 'parent_id' => parent['id'], 'parent' => pn,
    'date_ref' => "[#{pn}/#{disp.call(datec['formula'])}]",
    'value_formula' => "#{agg}([#{pn}/#{disp.call(vc['formula'])}])",
    'value_name' => disp.call(vc['formula']) }
end

rmap = opts[:rmap] && File.exist?(opts[:rmap]) ? JSON.parse(File.read(opts[:rmap])) : {}
conn = opts[:conn] || (dm['pages']&.first&.dig('elements')&.first&.dig('source','connectionId'))
emitted = []
restruct_cols = []  # earlier_rank columns get appended to base elements later

if opts[:rbim] || opts[:rmap]
  measures = _scan_bim_measures(opts[:rbim])
  measures.each do |name, dax|
    ov = rmap[name] || {}
    shape = (ov['generator'] && ov['generator'].to_sym) || DaxRestructure.classify(dax)
    args = ov['args'] || {}
    # Auto-infer time-intel args (parent View + date column + value agg) from the
    # DM spec + DAX so no manual --restructure-map is needed. Explicit map wins.
    if %i[time_prior_period time_ytd].include?(shape) && !(args['date_ref'] && args['value_formula'])
      inf = _infer_timeintel(dm, dax)
      args = inf.merge(args) if inf
    end
    begin
      case shape
      when :concatenatex_listagg
        # CONCATENATEX(VALUES(T[grp]), T[txt], sep, ...) — extract T, grp/txt.
        m = dax.match(/CONCATENATEX\s*\(\s*VALUES\s*\(\s*([A-Za-z0-9_]+)\[([^\]]+)\]\s*\)\s*,\s*[A-Za-z0-9_]+\[([^\]]+)\]\s*,\s*["']([^"']*)["']/i)
        next unless m || args['table']
        el = DaxRestructure.concatenatex_listagg(
          name: name, conn: args['conn'] || conn,
          db: args['db'] || opts[:db] || 'DEMO_DB', schema: args['schema'] || opts[:schema] || 'PUBLIC',
          table: args['table'] || m[1], group_col: args['group_col'] || m[2],
          text_col: args['text_col'] || m[3], sep: args['sep'] || (m && m[4]) || ', ')
        emitted << [name, el]
      when :treatas_virtual_rel
        # join keys are not reliably inferable from TREATAS DAX -> require override args.
        next if args.empty?
        el = DaxRestructure.treatas_virtual_rel(
          name: name, conn: args['conn'] || conn,
          db: args['db'] || opts[:db] || 'DEMO_DB', schema: args['schema'] || opts[:schema] || 'PUBLIC',
          fact: args['fact'], fact_key: args['fact_key'], dim: args['dim'], dim_key: args['dim_key'],
          group_col: args['group_col'], agg: args['agg'], agg_alias: args['agg_alias'] || 'VAL')
        emitted << [name, el]
      when :banded_grouping
        next if args.empty?
        el = DaxRestructure.banded_grouping(
          name: name, conn: args['conn'] || conn,
          db: args['db'] || opts[:db] || 'DEMO_DB', schema: args['schema'] || opts[:schema] || 'PUBLIC',
          table: args['table'], value_col: args['value_col'], bands: args['bands'])
        emitted << [name, el]
      when :time_prior_period
        # prior-period (SAMEPERIODLASTYEAR/DATEADD/hand-rolled prior-year) -> grouped
        # DateLookback element. Needs the parent (denormalized fact/view) + the date
        # and value column refs — supplied via --restructure-map (can't infer reliably).
        pid = args['parent_id'] || begin
          pel = (dm['pages']&.first&.dig('elements') || []).find { |e| e['name'] == args['parent'] }
          pel && pel['id']
        end
        next unless pid && args['date_ref'] && args['value_formula']
        el = DaxRestructure.prior_period_element(
          name: name, parent_id: pid, date_ref: args['date_ref'],
          value_formula: args['value_formula'], value_name: args['value_name'] || name,
          amount: args['amount'] || 1, period: args['period'] || 'year',
          with_yoy: args.fetch('with_yoy', true))
        emitted << [name, el]
      when :time_ytd
        pid = args['parent_id'] || begin
          pel = (dm['pages']&.first&.dig('elements') || []).find { |e| e['name'] == args['parent'] }
          pel && pel['id']
        end
        next unless pid && args['date_ref'] && args['value_formula']
        el = DaxRestructure.ytd_element(
          name: name, parent_id: pid, date_ref: args['date_ref'],
          value_formula: args['value_formula'], value_name: args['value_name'] || name,
          outer: args['outer'] || 'year', inner: args['inner'] || 'month')
        emitted << [name, el]
      when :earlier_rank
        # COUNTROWS(FILTER(T, T[p]=EARLIER(T[p]) && T[m]>EARLIER(T[m])))+1 -> RankDense
        next if args.empty? && !(args['value_ref'] && args['partition_ref'])
        col = DaxRestructure.earlier_rank_column(
          name: name, value_ref: args['value_ref'], partition_ref: args['partition_ref'],
          direction: args['direction'] || 'desc')
        # attach to the named base element (args['element']) or the first base element
        restruct_cols << [args['element'], col]
      else
        # :mechanical_or_flag — handled by the converter; nothing to emit.
      end
    rescue => e
      warn "[convert-model] restructure '#{name}' (#{shape}) skipped: #{e.message}"
    end
  end
end

# Splice emitted SQL/join/grouped elements onto the first page.
unless emitted.empty?
  pg = (dm['pages'] ||= [{}]).first
  (pg['elements'] ||= []).concat(emitted.map { |_n, el| el })
  warn "[convert-model] auto-emitted #{emitted.size} restructure element(s): #{emitted.map(&:first).join(', ')}"
end
# Append EARLIER->RankDense calc columns to their base elements.
restruct_cols.each do |elname, col|
  pg = dm['pages']&.first
  els = pg && pg['elements'] || []
  target = elname ? els.find { |e| e['name'] == elname } : els.find { |e| e.dig('source','path') }
  next unless target
  (target['columns'] ||= []) << col
  warn "[convert-model] appended RankDense column '#{col['name']}' to element '#{target['name']}'"
end


File.write(opts[:out], JSON.pretty_generate(dm))
warn "[convert-model] fixups applied (schemaVersion=1, folderId/ownerId set, #{named} element name(s) added)"
warn "[convert-model] wrote #{opts[:out]} — post with:"
warn "  ruby scripts/post-and-readback.rb --type datamodel --spec #{opts[:out]}"
