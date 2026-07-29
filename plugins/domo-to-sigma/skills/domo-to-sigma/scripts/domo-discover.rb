#!/usr/bin/env ruby
# Phase 1 discovery for domo-to-sigma.
#
#   ruby scripts/domo-discover.rb --probe              # detect extraction tier (A/B)
#   ruby scripts/domo-discover.rb --pages 123,456      # discover specific dashboards
#   ruby scripts/domo-discover.rb --datasets           # list all DataSets
#
# Writes discovery/*.json. PUBLIC-API paths follow Domo's documented API. PRIVATE
# card-definition shapes are confirmed against Domo's OpenAPI ("Get Chart Card
# Definition") + three production reference impls (jsade/domo-query-cli,
# brycewc/domo-toolkit, newli5737/domo-chousa); do a final field-path check on
# first contact with a live instance.
#
# Domo returns a card definition in TWO different shapes with different field
# names; normalize_card() below detects and flattens both into ONE record that the
# build steps (build-dm.rb / build-workbook.rb) consume:
#   Shape A — official "CardDefinition": chartBody/summaryNumber Components,
#             chartType, calculatedFields, conditionalFormats.
#   Shape B — internal analyzer def (definition.subscriptions.main.*,
#             definition.formulas[]); beast-mode refs are "calculation_<uuid>" ids.
#
# Prereqs (see refs/connection.md):
#   export DOMO_CLIENT_ID=... DOMO_CLIENT_SECRET=... DOMO_INSTANCE=acme
#   export DOMO_DEV_TOKEN=...        # omit for Tier B (public only)
#   eval "$(scripts/get-domo-token.sh)"   # sets DOMO_ACCESS_TOKEN

require 'json'
require 'fileutils'
require 'optparse'
require_relative 'lib/domo_rest'
require_relative 'lib/domo_sigma_util'
include DomoSigma   # merge_geometry — shared with build-domo-layout.rb

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)
FileUtils.mkdir_p(OUT)

def dump(name, obj)
  path = File.join(OUT, name)
  File.write(path, JSON.pretty_generate(obj))
  warn "  wrote #{path} (#{obj.is_a?(Array) ? obj.size : obj.keys.size} entries)"
end

# ---------------------------------------------------------------------------
# Beast Mode id prefix that card columns/filters use to reference a calc field.
CALC_PREFIX = 'calculation_'

# Map a Domo chartType token (a FREE STRING — no enum) to a Sigma element kind by
# substring. Returns nil when the token is unknown; the build step then reads the
# card PNG (refs/card-to-element.md: the render is authoritative). A summary-number
# card is decided as KPI in the build step, not here.
def sigma_kind_hint(chart_type)
  t = chart_type.to_s.downcase
  return 'kpi-chart'    if t.include?('singlevalue') || t.include?('summary') ||
                           t.include?('gauge') || t == 'badge'
  return 'pivot-table'  if t.include?('pivot')
  return 'table'        if t.include?('datagrid') || t.include?('table')
  return 'bar-chart'    if t.include?('bar')
  return 'line-chart'   if t.include?('line')
  return 'area-chart'   if t.include?('area')
  return 'donut-chart'  if t.include?('pie') || t.include?('donut')
  return 'scatter-chart' if t.include?('scatter') || t.include?('bubble')
  return 'combo-chart'  if t.include?('combo') || t.include?('barline')
  nil
end

# Classify a Beast Mode as aggregate | window | lod | projection. Prefer the API
# flags from the standalone template (aggregated/analytic) — no SQL parsing; fall
# back to a regex heuristic when the template isn't available (Tier B).
def classify_beast_mode(sql, template = nil)
  return 'lod'    if sql.to_s =~ /\bFIXED\s*\(/i          # Domo LOD → Sigma LOD
  if template.is_a?(Hash)
    return 'window'    if template['analytic']
    return 'aggregate' if template['aggregated']
    return 'projection'
  end
  s = sql.to_s
  return 'window'    if s =~ /\bOVER\s*\(/i
  # A top-level aggregate wrapping the whole expression → aggregate.
  return 'aggregate' if s =~ /\A\s*\(?\s*(SUM|COUNT|AVG|MIN|MAX|STDDEV_POP|STDDEV_SAMP|VAR_POP|VAR_SAMP|CEILING|FLOOR|APPROXIMATE_COUNT_DISTINCT)\s*\(/i
  'projection'
end

# Normalize a Component's column list ({column,alias,aggregation,format}) —
# used for chartBody, summaryNumber, groupBy, orderBy (Shape A DataSetColumn[]).
def norm_columns(component)
  Array(component && component['columns']).map do |c|
    raw = c['column'] || c['dataColumn'] || c['field']
    {
      'column'      => raw,
      'alias'       => c['alias'],                 # display label override (fixes raw-name bug)
      'aggregation' => c['aggregation'] || c['aggr'],
      'format'      => c['format'] || c['numberFormat'],
      'order'       => c['order'],
      'beastModeId' => (raw.to_s.start_with?(CALC_PREFIX) ? raw : c['formulaId']),
    }.compact
  end
end

# Normalize a card definition (either shape) into one record.
def normalize_card(raw, card_id)
  # The parts-form (Shape A) endpoint can return an array of card objects.
  raw = raw.first if raw.is_a?(Array)
  raw ||= {}
  defn = raw['definition']

  if defn.is_a?(Hash) && (defn['subscriptions'] || defn['formulas'])
    # ---- Shape B (internal analyzer definition) ----
    main = defn.dig('subscriptions', 'main') || {}
    title = defn.dig('dynamicTitle', 'text')&.map { |t| t['text'] }&.join ||
            raw['title'] || raw.dig('metadata', 'title')
    columns = norm_columns(main.empty? ? nil : { 'columns' => main['columns'] })
    filters = Array(main['filters']).map do |f|
      { 'column' => f['column'], 'operator' => f['filterType'] || f['operator'],
        'values' => f['values'] }.compact
    end
    {
      'id'                 => card_id,
      'title'              => title,
      'chartType'          => raw['chartType'] || defn['chartType'],
      'sigmaKindHint'      => sigma_kind_hint(raw['chartType'] || defn['chartType']),
      'datasetId'          => raw['dataSetId'] || raw.dig('dataProvider', 'dataSourceId'),
      'columns'            => columns,
      'summaryNumber'      => norm_summary_number(defn['summaryNumber'] || main['summaryNumber']),
      'groupBy'            => Array(main['groupBy']).map { |c| c['column'] }.compact,
      'orderBy'            => Array(main['orderBy']).map { |c| c['column'] }.compact,
      'filters'            => filters,
      'conditionalFormats' => Array(defn['conditionalFormats']),
      'cardFormulas'       => Array(defn['formulas']),  # {id,name,columnPositions,...}
      '_shape'             => 'B',
    }.compact
  else
    # ---- Shape A (official CardDefinition) ----
    body = raw['chartBody'] || {}
    filters = Array(body['filters']).map do |f|
      { 'column' => f['column'], 'operator' => f['operand'] || f['operator'],
        'values' => f['values'] }.compact
    end
    {
      'id'                 => card_id,
      'title'              => raw['title'] || raw.dig('metadata', 'title'),
      'chartType'          => raw['chartType'],
      'sigmaKindHint'      => sigma_kind_hint(raw['chartType']),
      'datasetId'          => raw['dataSetId'],
      'columns'            => norm_columns(body),
      'summaryNumber'      => norm_summary_number(raw['summaryNumber']),
      'groupBy'            => norm_columns('columns' => body['groupBy']).map { |c| c['column'] },
      'orderBy'            => norm_columns('columns' => body['orderBy']).map { |c| c['column'] },
      'filters'            => filters,
      'conditionalFormats' => Array(raw['conditionalFormats']),
      'cardFormulas'       => Array(raw['calculatedFields']),  # {formula,id,name,saveToDataSet}
      '_shape'             => 'A',
    }.compact
  end
end

# Extract the card's Summary Number — the single big value Domo shows at the top of
# EVERY viz card (column + aggregation + label + number format). This is what a
# table-that-looks-like-a-KPI is built from; the build step maps it to a Sigma
# kpi-chart (refs/card-to-element.md Rule 0), NOT a table.
#
# CONFIRMED path (official "Get Chart Card Definition"): summaryNumber.columns[]
# with {column, aggregation, alias, format}. A Domo TABLE card's summary number
# DEFAULTS to COUNT of the bound (often id/first) column — so a faithful read can
# emit Count([id]). We flag that so build-workbook.rb prefers the authored measure.
def norm_summary_number(sn)
  return nil unless sn.is_a?(Hash)
  col = sn['columns'].is_a?(Array) ? sn['columns'].first : sn
  return nil unless col.is_a?(Hash)
  agg = col['aggregation'] || col['aggr'] || col['func']
  {
    'column'             => col['column'] || col['dataColumn'] || col['field'],
    'aggregation'        => agg,
    'label'              => col['alias'] || col['label'] || col['title'],
    'format'             => col['format'] || col['numberFormat'],
    # Domo's default for a table card is COUNT — scrutinize in the build step so a
    # KPI shows the intended measure, not a distinct/row count of the row key.
    '_defaultCountSuspect' => (agg.to_s.upcase == 'COUNT'),
    '_raw'               => sn,
  }.compact
end

# Collect + classify every Beast Mode reachable from a normalized card:
#   - dataset-level formulas  (properties.formulas.formulas — a MAP keyed by id)
#   - card-local formulas     (Shape A calculatedFields / Shape B definition.formulas)
# Joins card column/filter refs via the "calculation_<uuid>" id, tags each with
# scope (dataset|card) and class (aggregate|projection|window|lod).
def dig_beast_modes(card, ds_formula_map, template_cache)
  out = []
  # 1. Dataset-level Beast Modes (map → values).
  (ds_formula_map || {}).each_value do |f|
    sql = f['formula'] || f['expression']
    next unless sql
    tmpl = fetch_template(f['templateId'] || f['id'], template_cache)
    out << { 'id' => f['id'], 'name' => f['name'], 'sql' => sql,
             'scope' => 'dataset', 'class' => classify_beast_mode(sql, tmpl),
             'dataSourceId' => card['datasetId'], 'cardId' => card['id'] }
  end
  # 2. Card-local Beast Modes.
  Array(card['cardFormulas']).each do |f|
    sql = f['formula'] || f['expression']
    next unless sql
    tmpl = fetch_template(f['templateId'] || f['id'], template_cache)
    out << { 'id' => f['id'], 'name' => f['name'], 'sql' => sql,
             'scope' => 'card', 'class' => classify_beast_mode(sql, tmpl),
             'cardId' => card['id'] }
  end
  out
end

def fetch_template(fn_id, cache)
  return nil if fn_id.nil? || Domo.dev_token.nil?
  cache[fn_id] ||= (Domo.beast_mode_template(fn_id) rescue nil)
end

# Fetch a card definition, trying Shape B (v3 analyzer def, what production tools
# use) then Shape A (parts form). Returns the raw response or nil.
def fetch_card_def(card_id)
  b = (Domo.card_definition_v3(card_id) rescue nil)
  return b if b.is_a?(Hash) && b['definition']
  Domo.card_definition(card_id) rescue nil
end

# C9 wiring: merge each dataset's `permission` block — captured below from the
# ALREADY-FETCHED Domo.dataset_formulas response (parts=core,permission,formulas),
# no extra HTTP call — onto the matching datasets.json record, so build-dm.rb's
# DomoSigma.detect_pdp() can actually see it live. Pure/side-effect-free (returns
# a new array) so this is unit-testable offline without a network stub.
#
# Defensive: `permission_cache` values are attached as-is, whatever top-level
# `permission` the response carried. detect_pdp already tolerantly reads
# dataset['permission']['policies'] || dataset['pdp'] and returns [] (never
# raises) if the real nesting differs — this function does not assert or guess
# any deeper shape.
def merge_dataset_permissions(datasets, permission_cache)
  return [0, Array(datasets)] if permission_cache.nil? || permission_cache.empty?
  merged = 0
  out = Array(datasets).map do |d|
    next d unless d.is_a?(Hash)
    perm = permission_cache[d['id']]
    next d unless perm
    merged += 1
    d.merge('permission' => perm)
  end
  [merged, out]
end

# ---------------------------------------------------------------------------

opts = {}
OptionParser.new do |o|
  o.on('--probe')            { opts[:probe] = true }
  o.on('--datasets')         { opts[:datasets] = true }
  o.on('--pages IDS', Array) { |v| opts[:pages] = v }
end.parse!(ARGV)

# --- Tier probe -------------------------------------------------------------
# Tier A = private API reachable (full fidelity). Tier B = public only.
if opts[:probe]
  public_ok = begin
    Domo.list_datasets(limit: 1); true
  rescue => e
    warn "PUBLIC API: FAIL — #{e.message}"; false
  end
  warn "PUBLIC API: OK" if public_ok

  if Domo.dev_token.nil?
    warn "PRIVATE API: skipped (DOMO_DEV_TOKEN unset) => TIER B (public only)."
    warn "  Card defs, Beast Modes, and layout will NOT be auto-extractable."
    warn "  Fall back to PNG-read per card (see feedback_phase1d_dashboard_png)."
  else
    private_ok = begin
      # A cheap private-API reachability check.
      Domo.private_get('/api/content/v1/cards', query: { urns: 'PROBE', parts: 'metadata' })
      true
    rescue => e
      warn "PRIVATE API: FAIL — #{e.message}"; false
    end
    warn(private_ok ? "PRIVATE API: OK => TIER A (full fidelity)" : "PRIVATE API: unreachable => TIER B")
  end
  exit 0
end

# --- DataSet inventory ------------------------------------------------------
# Domo.list_datasets hits the PUBLIC /v1/datasets endpoint, which does NOT
# carry a `permission`/`pdp` block by itself. The --pages branch below already
# fetches each used dataset's `permission` part as a side effect of pulling
# Beast Mode formulas (Domo.dataset_formulas requests parts=core,permission,
# formulas) — after that loop we merge the captured permission data onto the
# matching datasets.json record (see merge_dataset_permissions above). NO
# extra HTTP call is added. `datasets_snapshot` lets that merge target this
# run's in-memory list when --datasets and --pages are invoked together in one
# process; otherwise it falls back to reading discovery/datasets.json off disk
# (run --datasets first so it exists). TODO(on-access): the exact `permission`
# nesting is still unconfirmed against a live instance — detect_pdp() in
# lib/domo_sigma_util.rb tolerates whatever shape actually comes back.
datasets_snapshot = nil
if opts[:datasets]
  all = []
  offset = 0
  loop do
    batch = Domo.list_datasets(limit: 50, offset: offset)
    break if batch.nil? || batch.empty?
    all.concat(batch)
    offset += 50
    break if batch.size < 50
  end
  datasets_snapshot = all
  dump('datasets.json', all)
end

# --- Per-page discovery -----------------------------------------------------
if opts[:pages]
  pages_out = []
  cards_out = []
  beast_out = []
  ds_formula_cache    = {}   # datasetId → formulas map
  ds_permission_cache = {}   # datasetId → raw `permission` value (C9 PDP wiring)
  template_cache      = {}   # templateId → standalone Beast Mode (for classification)

  opts[:pages].each do |pid|
    page = Domo.page(pid) # PUBLIC: page hierarchy + card IDs
    pages_out << page

    # PUBLIC gives card IDs; layout geometry + collections need PRIVATE. Merged
    # onto each of this page's cards below (merge_geometry) so cards.json
    # carries real x/y/w/h for the 2D layout builder instead of auto-stacking.
    layout = (Domo.page_layout(pid) rescue nil)

    card_ids = Array(page['cardIds'] || page['cards'])
    page_cards = []

    card_ids.each do |cid|
      if Domo.dev_token
        raw = fetch_card_def(cid)
        if raw.nil?
          page_cards << { 'id' => cid, '_error' => 'card definition unavailable' }
          next
        end
        card = normalize_card(raw, cid)

        # Fetch + cache dataset-level Beast Modes for this card's dataset. This
        # SAME response (parts=core,permission,formulas) also carries the C9
        # PDP `permission` block — capture it too, no extra HTTP call.
        dsid = card['datasetId']
        if dsid && !ds_formula_cache.key?(dsid)
          det = (Domo.dataset_formulas(dsid) rescue nil)
          ds_formula_cache[dsid] = det&.dig('properties', 'formulas', 'formulas') || {}
          ds_permission_cache[dsid] = det['permission'] if det.is_a?(Hash) && det['permission']
        end

        card['beastModes'] = dig_beast_modes(card, ds_formula_cache[dsid], template_cache)
        beast_out.concat(card['beastModes'])
        page_cards << card
      else
        page_cards << { 'id' => cid, '_tierB' => true,
                        '_note' => 'no private API — capture PNG + transcribe Beast Modes manually' }
      end
    end

    cards_out.concat(merge_geometry(page_cards, layout))
  end

  # De-dupe Beast Modes by id (a dataset formula shared by many cards appears once).
  beast_out.uniq! { |b| [b['id'], b['scope']] }

  # C9/PDP: merge captured `permission` data onto datasets.json (this run's
  # in-memory list if --datasets ran too, else re-read the file from a prior
  # --datasets run) so DomoSigma.detect_pdp can see it in build-dm.rb.
  if ds_permission_cache.any?
    ds_path  = File.join(OUT, 'datasets.json')
    existing = datasets_snapshot || (JSON.parse(File.read(ds_path)) rescue nil)
    if existing.is_a?(Array)
      merged, datasets = merge_dataset_permissions(existing, ds_permission_cache)
      if merged > 0
        dump('datasets.json', datasets)
        warn "  C9/PDP: merged permission data into #{merged} datasets.json record(s) (see DomoSigma.detect_pdp)."
      end
    else
      warn "  C9/PDP: fetched permission data for #{ds_permission_cache.size} dataset(s) but " \
           'discovery/datasets.json is missing/unparseable — run --datasets (before or with ' \
           '--pages) so the merge has a target.'
    end
  end

  dump('pages.json', pages_out)
  dump('cards.json', cards_out)
  dump('beast-modes.json', beast_out)
  warn "\nNext: ruby scripts/convert-beast-modes.rb   (translate Beast Mode SQL -> Sigma formulas)"
end
