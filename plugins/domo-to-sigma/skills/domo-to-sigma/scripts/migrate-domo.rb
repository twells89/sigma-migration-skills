#!/usr/bin/env ruby
# migrate-domo.rb — turnkey Domo -> Sigma migration orchestrator (PR-C, Task 5b).
#
# Chains this skill's phase scripts end-to-end: one clear log line per phase, a
# run-state.json ledger (lib/run_state.rb — structure borrowed, not copied,
# from tableau-to-sigma's migrate-tableau.rb / lib/run_state.rb, trimmed to
# this skill's phase set), fail-fast the instant any phase genuinely errors,
# and idempotent re-runs (a phase whose output already exists is skipped
# unless --force). Windows-safe: every phase shells out via `ruby <script>`
# with an argv array (Open3.capture2e), never a string-interpolated shell
# command.
#
# LIVE phase chain (real Domo + Sigma creds in ENV; see refs/connection.md):
#   discover -> capture-visuals -> convert-beast-modes -> build-dm* ->
#   post-and-readback(data-model)* -> build-workbook -> build-workbook-spec ->
#   post-and-readback(workbook) -> build-domo-layout -> build-dashboard-layout ->
#   put-layout -> render-visual -> verify-parity -> record-visual-check ->
#   assert-phase6-ran
#
#   render-visual writes <out>/sigma-render.png. The visual gate is resumable:
#   --source-dashboard-png stages the source, an optional --visual-grader
#   adapter can produce a context-free blind grade in-process, and otherwise
#   the run exits 20 WAITING with visual-grade-request.json. A calling agent
#   fulfills that request and reruns the same command; the orchestrator then
#   validates, records, and gates the grade without artifact hand-editing.
#
#   * build-dm + the data-model half of post-and-readback are NOT named as
#     their own step in this task's phase list, but build-workbook-spec.rb
#     hard-requires a --dm-ids file (a posted Data Model's readback) as input —
#     there is no way to assemble a workbook spec without one. They are folded
#     in here, logged under their own run-state keys, right before the
#     workbook-spec step that consumes their output. Documented, not silent.
#
# --offline DIR mode (no live creds; proves the deterministic build pipeline
# end to end against a fixture shaped like discovery/ output — pages.json,
# cards.json, optional beast-modes.json, optional png/cards/*.png):
#   seed discovery from DIR -> build-workbook -> build-workbook-spec[local] ->
#   build-domo-layout -> build-dashboard-layout -> put-layout[local]
# writing workbook-spec.json + layout-2d.flag ('grid' | 'stack'). Every other
# named phase (discover, capture-visuals, convert-beast-modes when the fixture
# carries no beast-modes.json, post-and-readback, verify-parity,
# assert-phase6-ran, and any render/visual gate) is stamped SKIP with a reason
# in run-state.json — never silently omitted.
#
# WHY build-workbook-spec / put-layout get a LOCAL, network-free implementation
# in --offline mode instead of shelling out to the vendored scripts unchanged:
# both make a LIVE Sigma REST call on their normal path — build-workbook-spec.rb
# GETs the target Data Model's spec to resolve the master element's source and
# name; put-layout.rb GETs + PUTs a live workbook spec. There is no live
# Sigma workbook/DM to talk to in --offline mode (that is the whole point of
# the flag). offline_build_workbook_spec! / offline_put_layout! below reproduce
# the SAME assembly rules — a "Data" page + master element, page/element
# shape, layout-XML + container injection — without the network round trip,
# and stamp the assembled workbook-spec.json with an "_offline" note so it can
# never be mistaken for a live-postable spec. Nothing about the chart elements
# themselves (the KPI's Sum([Master/...]) formula, the inline data-URI image
# element) is touched by this substitution — those come straight out of
# build-workbook.rb, unmodified, exactly as they would in live mode.
#
# The 'grid' vs 'stack' flag is derived from build-domo-layout.rb's real
# output (discovery/dashboard-layout.json) using the SAME zone-census
# predicate (lib/zone_census.rb's ZoneCensus.content_zones) build-dashboard-
# layout.rb itself uses internally to decide what is placeable — grouping the
# real, non-furniture zones by row (y_pct) and checking whether any row holds
# >= 2 zones at DISTINCT x_pct (a true 2D grid, not a single-column stack).
# This is computed, never hardcoded, and is independent of build-dashboard-
# layout.rb's own container-synthesis choices for the layout XML.
#
# Usage:
#   ruby scripts/migrate-domo.rb --offline test/fixtures/domo-estate --out /tmp/run1
#   ruby scripts/migrate-domo.rb --pages 123,456 --workbook-name "Sales" \
#        --folder-id <uuid> --out /tmp/run2

require 'json'
require 'fileutils'
require 'optparse'
require 'open3'
require_relative 'lib/run_state'
require_relative 'lib/domo_sigma_util'
require_relative 'lib/zone_census'
require_relative 'lib/code_rep'
require_relative 'lib/layout'
require_relative 'lib/sigma_rest'
require_relative 'lib/domo_warehouse_column_refs'
require_relative 'lib/visual_handoff'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'
include DomoSigma

opts = { mode: 'page-per-worksheet', workbook_name: 'Domo Migration' }
OptionParser.new do |o|
  o.banner = 'Usage: ruby migrate-domo.rb --offline DIR --out DIR [options]'
  o.on('--offline DIR', 'Run offline: seed discovery/ from this fixture dir (pages.json, ' \
       'cards.json, optional beast-modes.json / png/cards/*.png) and skip every ' \
       'live/private-API phase.') { |v| opts[:offline] = v }
  o.on('--out DIR', 'Working directory for this run (required). discovery/, run-state.json, ' \
       'workbook-spec.json, and layout-2d.flag are all written here.') { |v| opts[:out] = v }
  o.on('--force', 'Ignore idempotency — rerun every phase even when its output already exists.') { opts[:force] = true }
  o.on('--pages IDS', Array, 'LIVE mode: comma-separated Domo page ids to discover.') { |v| opts[:pages] = v }
  o.on('--workbook-name NAME', 'Sigma workbook name (default "Domo Migration").') { |v| opts[:workbook_name] = v }
  o.on('--folder-id ID', 'LIVE mode: Sigma folder id to post the workbook into.') { |v| opts[:folder_id] = v }
  o.on('--workbook-id ID', 'LIVE mode: update this existing workbook instead of posting a new one.') { |v| opts[:workbook_id] = v }
  o.on('--description STR', 'Workbook description.') { |v| opts[:description] = v }
  o.on('--mode MODE', %w[dashboard page-per-worksheet], 'build-workbook-spec.rb page layout mode ' \
       '(default page-per-worksheet).') { |v| opts[:mode] = v }
  o.on('--parity-plan PATH', 'LIVE mode: a hand-supplied verify-parity.rb plan. Overrides the ' \
       'built-in parity oracle, which otherwise builds one automatically.') { |v| opts[:parity_plan] = v }
  o.on('--skip-parity-oracle REASON', 'Do NOT build the parity oracle automatically. Without a ' \
       '--parity-plan this leaves the run with no gate-1 evidence at all, so ' \
       'assert-phase6-ran.rb gets --skip-parity-gate and rejects it (exit 18) absent a passing ' \
       'anchors-verdict.json. In other words: this run cannot then be GREEN.') { |v| opts[:skip_parity_oracle] = v }
  o.on('--source-dashboard-png PATH', 'Full source dashboard PNG for the blind visual gate. ' \
       'Staged into <out>/source-dashboard.png so an idempotent rerun needs no repeated flag.') {
    |v| opts[:source_dashboard_png] = v
  }
  o.on('--blind-grade PATH', 'Completed context-free blind-grade JSON. Defaults to ' \
       '<out>/blind-grade.json; consumed and recorded automatically.') { |v| opts[:blind_grade] = v }
  o.on('--visual-grader PATH', 'Optional executable adapter. Receives visual-grade-request.json ' \
       'as its only argument and must write the request output_json; no shell is used.') {
    |v| opts[:visual_grader] = v
  }
end.parse!(ARGV)

abort('FATAL: --out DIR is required') unless opts[:out]
OUT = File.expand_path(opts[:out])
FileUtils.mkdir_p(OUT)
DISCOVERY = File.join(OUT, 'discovery')
FileUtils.mkdir_p(DISCOVERY)
SCRIPTS = __dir__
BASE_ENV = { 'DOMO_DISCOVERY_DIR' => DISCOVERY, 'DOMO_DM_IDS_PATH' => File.join(OUT, 'dm-ids.json') }.freeze

class VisualGradePending < StandardError
  attr_reader :request_path

  def initialize(message, request_path)
    super(message)
    @request_path = request_path
  end
end

if opts[:source_dashboard_png]
  begin
    staged = DomoVisualHandoff.stage_source!(opts[:source_dashboard_png], OUT)
    opts[:source_dashboard_png] = staged
  rescue ArgumentError => e
    abort("FATAL: #{e.message}")
  end
elsif File.file?(File.join(OUT, DomoVisualHandoff::SOURCE_BASENAME))
  opts[:source_dashboard_png] = File.join(OUT, DomoVisualHandoff::SOURCE_BASENAME)
end

DomoRunState.record(OUT, 'mode' => (opts[:offline] ? 'offline' : 'live'), 'started_at' => Time.now.utc.iso8601)

# ---------------------------------------------------------------------------
# small logging / process helpers

def hr(title)
  puts
  puts '=' * 78
  puts "  [phase] #{title}"
  puts '=' * 78
end

def log(msg) puts "  #{msg}" end

def out_exists?(*paths) paths.all? { |p| File.exist?(p) } end

# Shell out to a sibling script with an argv array (never a shell string) so
# this orchestrator behaves the same on Windows/macOS/Linux. Returns
# [success?, exitstatus, combined_stdout_stderr].
def run_script!(script, *args)
  path = File.join(SCRIPTS, script)
  log "$ ruby #{script} #{args.join(' ')}".rstrip
  out, status = Open3.capture2e(BASE_ENV, 'ruby', path, *args)
  out.each_line { |l| print "    #{l}" }
  puts if !out.empty? && !out.end_with?("\n")
  [status.success?, status.exitstatus, out]
end

# Same argv-array discipline as run_script!, for this skill's one Python
# phase script (sigma-export-png.py — the /v2/workbooks/{id}/export REST
# contract; see its header). Unlike the vendored converters (tableau/
# quicksight/qlik/powerbi) this skill never carried a lib/py_resolve.rb
# python3/python/py-3 Windows resolver for a single call site — invoked the
# same plain `python3` refs/layout-visual-qa.md already documents. Returns
# [success?, exitstatus-or-nil, combined_output]; exitstatus is nil ONLY when
# python3 itself is missing from PATH (Errno::ENOENT) — the caller treats
# that as a genuinely-absent prerequisite (honest SKIP), never a phase FAIL.
def run_py_script!(script, *args)
  path = File.join(SCRIPTS, script)
  log "$ python3 #{script} #{args.join(' ')}".rstrip
  out, status = Open3.capture2e('python3', path, *args)
  out.each_line { |l| print "    #{l}" }
  puts if !out.empty? && !out.end_with?("\n")
  [status.success?, status.exitstatus, out]
rescue Errno::ENOENT
  [false, nil, '']
end

def fail_phase!(name, reason)
  DomoRunState.fail(OUT, name, reason)
  hr("FATAL — phase '#{name}' failed")
  log reason
  log "see #{DomoRunState.path(OUT)} for the full run ledger"
  exit 1
end

def skip_phase!(name, reason)
  DomoRunState.skip(OUT, name, reason)
  log "SKIP #{name} — #{reason}"
end

def done_phase!(name, note = nil)
  DomoRunState.stamp(OUT, name, status: 'done', note: note)
end

# ---------------------------------------------------------------------------
# offline seeding

def seed_discovery!(fixture_dir)
  FileUtils.mkdir_p(DISCOVERY)
  copied = []
  Dir.glob(File.join(fixture_dir, '*.json')).sort.each do |f|
    base = File.basename(f)
    if base == 'dm-ids.json'
      # bead ziht (Task 6): dm-ids.json is a POST-READBACK artifact — the LIVE
      # path writes it via post-and-readback.rb --type datamodel to
      # DOMO_DM_IDS_PATH, which BASE_ENV above points at THIS run's OUT dir
      # (not discovery/ — see build-workbook.rb's DM_IDS_PATH comment: it lives
      # in migrate-domo.rb's OUT, a different directory than DISCOVERY,
      # because a hand run of build-workbook.rb alone has no OUT of its own).
      # --offline mode never runs post-and-readback.rb (no live DM exists to
      # post — see the "post-and-readback" phase below, always skipped), so a
      # fixture wanting to exercise sub_master_for's live-element resolution
      # provides this file directly, as the synthesized equivalent of that
      # readback. Route it to OUT/dm-ids.json to match DOMO_DM_IDS_PATH —
      # dropping it in discovery/ alongside dm-spec.json (like every other
      # fixture *.json) left it somewhere build-workbook.rb never looks.
      FileUtils.cp(f, File.join(OUT, base))
      copied << "#{base} (-> #{OUT}, matching DOMO_DM_IDS_PATH — not discovery/)"
      next
    end
    FileUtils.cp(f, File.join(DISCOVERY, base))
    copied << base
  end
  png_src = File.join(fixture_dir, 'png')
  if Dir.exist?(png_src)
    FileUtils.cp_r(png_src, File.join(DISCOVERY, 'png'))
    copied << 'png/**'
  end
  copied
end

# ---------------------------------------------------------------------------
# offline-local workbook-spec assembly (see header comment for WHY)

MASTER_REF_RE = /\[Master\/([^\]]+)\]/.freeze

# Every distinct "[Master/<Name>]" reference used by the built chart elements,
# in first-seen order — these become the (placeholder-sourced) master table
# columns so the assembled spec is internally self-consistent even with no
# live Data Model behind it.
def collect_master_refs(pages)
  seen = {}
  order = []
  Array(pages).each do |p|
    Array(p['elements']).each do |el|
      Array(el['columns']).each do |c|
        c['formula'].to_s.scan(MASTER_REF_RE).each do |(nm)|
          next if seen[nm]
          seen[nm] = true
          order << nm
        end
      end
    end
  end
  order
end

# Mirrors build-workbook-spec.rb's page-id slugging so a hand run and an
# offline run produce comparable ids; not load-bearing (this orchestrator
# controls both the spec and the wb-ids.json derived from it).
def slugify_page_id(name, used_ids)
  slug = name.to_s.downcase
  %w[/ ( ) %].each { |ch| slug = slug.tr(ch, '-') }
  slug = slug.tr(' ', '-').gsub(/-+/, '-').sub(/^-/, '').sub(/-$/, '')[0..40]
  base = "page-#{slug}"
  id = base
  n = 2
  while used_ids[id]
    id = "#{base}-#{n}"
    n += 1
  end
  used_ids[id] = true
  id
end

def offline_build_workbook_spec!(chart_specs_path, name:, description:, folder_id:, out_path:)
  specs = JSON.parse(File.read(chart_specs_path))
  raise 'discovery/chart-specs.json must be shaped { "pages": [...] }' unless specs.is_a?(Hash) && specs['pages'].is_a?(Array)

  master_columns = collect_master_refs(specs['pages']).map do |nm|
    { 'id' => mcol_id(nm), 'name' => nm, 'formula' => "[Domo Source/#{nm}]" }
  end
  # Defensive id-dedupe (mirrors build-workbook-spec.rb) — two distinct display
  # names could slug to the same master column id.
  seen_ids = {}
  master_columns.each do |c|
    base = c['id']
    next unless seen_ids[base]
    n = 2
    n += 1 while seen_ids["#{base}-#{n}"]
    c['id'] = "#{base}-#{n}"
  ensure
    seen_ids[c['id']] = true
  end

  # bead ziht: build-workbook.rb may emit one hidden sub-master per
  # non-dominant DataSet under chart-specs.json's top-level `data_elements`
  # key (mirrors build-workbook-spec.rb's own `helper_elements` handling for
  # the LIVE path — see its header comment on the Data page). Any visible
  # element retargeted to one of these (retarget_to_submaster!) sources it by
  # id, so it must land on the Data page here too or the reference dangles —
  # the offline path had never wired this key in at all.
  helper_elements = (specs['data_elements'].is_a?(Array) ? specs['data_elements'] : [])

  data_page = {
    'id' => 'page-data', 'name' => 'Data',
    'elements' => [{
      'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'visibleAsSource' => false,
      'source' => { 'kind' => 'offline-placeholder',
                    'note' => 'no live Domo/Sigma Data Model in --offline mode — replace with a real ' \
                              'data-model source (see post-and-readback --type datamodel) before posting.' },
      'columns' => master_columns, 'order' => master_columns.map { |c| c['id'] },
    }] + helper_elements,
  }
  log "Data page: + #{helper_elements.size} hidden sub-master(s) [#{helper_elements.map { |h| h['id'] }.join(', ')}]" if helper_elements.any?

  used_ids = { 'page-data' => true }
  visible_pages = specs['pages'].map do |p|
    { 'id' => slugify_page_id(p['name'], used_ids), 'name' => p['name'], 'elements' => p['elements'] }
  end

  if visible_pages.size > 1
    page_labels = visible_pages.each_with_object({}) { |page, labels| labels[page['id']] = page['name'] }
    visible_pages.each do |page|
      page['elements'].unshift(
        'id' => "nav-#{page['id']}",
        'kind' => 'navigation',
        'mode' => 'auto',
        'pageLabels' => page_labels
      )
    end
  end

  page_records = [data_page] + visible_pages
  layout_pages = page_records.map do |page|
    row = 1
    children = Array(page['elements']).map do |element|
      height = case element['kind']
               when 'page-break' then 1
               when 'control', 'text', 'navigation', 'progress', 'image', 'divider' then 3
               when 'kpi-chart' then 6
               when 'table', 'pivot-table' then 12
               else 10
               end
      placed = SigmaLayout.le(element['id'], 1, 25, row, row + height)
      row += height
      placed
    end
    SigmaLayout.page_xml(page['id'], children.join("\n"))
  end
  document = {
    'schemaVersion' => 1,
    'kind' => 'workbook',
    'pages' => page_records.map do |page|
      metadata = page.reject { |key, _| key == 'elements' }
      metadata['visibility'] = 'hidden' if page['id'] == 'page-data'
      metadata
    end,
    'elements' => page_records.flat_map { |page| Array(page['elements']) },
    'layout' => SigmaLayout.assemble(*layout_pages),
    'panels' => [],
    'overlays' => []
  }
  if visible_pages.size > 1
    document['settings'] = { 'navigation' => { 'pageTabsInViewMode' => 'shown' } }
  end

  metadata = {
    'name' => name, 'folderId' => folder_id,
    '_offline' => true,
    '_note' => 'assembled by migrate-domo.rb --offline without a live Sigma Data Model readback — ' \
               'the master element source and folderId are placeholders; NOT postable as-is.',
  }
  metadata['description'] = description if description
  wb = Sigma::CodeRep.wrap(document, extra: metadata)
  File.write(out_path, JSON.pretty_generate(wb) + "\n")
  wb
end

# Local, network-free equivalent of put-layout.rb's merge step: fold the
# generated layout XML (+ its container/header elements sidecar) into an
# already-written workbook-spec.json, in place. Same rules as put-layout.rb
# minus the GET/PUT round trip (see header comment for why offline mode can't
# make that call).
def offline_put_layout!(spec_path, layout_xml_path, elements_sidecar_path)
  xml = File.read(layout_xml_path, encoding: 'UTF-8')
  raise 'FATAL: empty elementId in layout XML' if xml.match?(/elementId=""/)

  raw_spec = JSON.parse(File.read(spec_path))
  spec = Sigma::CodeRep.document(raw_spec)
  metadata = Sigma::CodeRep.metadata(raw_spec)
  spec['pages'].each { |p| p.delete('layout') }
  spec['layout'] = xml

  if File.exist?(elements_sidecar_path)
    inject = JSON.parse(File.read(elements_sidecar_path))
    injected = 0
    inject.each do |page_id, els|
      page = spec['pages'].find { |p| p['id'] == page_id }
      unless page
        log "WARN: layout elements sidecar references unknown page #{page_id.inspect} — skipped"
        next
      end
      spec['elements'] ||= []
      existing = spec['elements'].map { |e| e['id'] }
      els.each do |el|
        next if existing.include?(el['id'])
        spec['elements'] << el
        existing << el['id']
        injected += 1
      end
    end
    log "injected #{injected} container/header element(s) from #{File.basename(elements_sidecar_path)}"
  end

  element_ids = Array(spec['elements']).map { |element| element['id'] }
  placed_ids = xml.scan(/\belementId="([^"]+)"/).flatten
  duplicate_elements = element_ids.tally.select { |_id, count| count > 1 }.keys
  duplicate_placements = placed_ids.tally.select { |_id, count| count > 1 }.keys
  unplaced = element_ids - placed_ids
  unknown = placed_ids - element_ids
  unless duplicate_elements.empty? && duplicate_placements.empty? && unplaced.empty? && unknown.empty?
    raise "FATAL: layout must place every flat workbook element exactly once: " \
          "duplicate element ids=#{duplicate_elements.inspect}; duplicate placements=#{duplicate_placements.inspect}; " \
          "unplaced=#{unplaced.inspect}; unknown=#{unknown.inspect}"
  end

  wrapped = Sigma::CodeRep.wrap(spec, extra: metadata)
  File.write(spec_path, JSON.pretty_generate(wrapped) + "\n")
  wrapped
end

# wb-ids.json (the shape post-and-readback.rb --type workbook emits and
# build-dashboard-layout.rb --wb-ids consumes) derived directly from the
# just-assembled workbook-spec.json's pages/elements — no live workbook exists
# in --offline mode to read this back from.
def wb_ids_from_spec(spec)
  document = Sigma::CodeRep.document(spec)
  elements_by_id = Sigma::CodeRep.workbook_elements(document).each_with_object({}) do |element, index|
    index[element['id']] = element if element['id']
  end
  page_element_ids = Sigma::CodeRep.workbook_page_element_ids(document)
  {
    'pages' => Array(document['pages']).map do |p|
      { 'id' => p['id'], 'name' => p['name'],
        'visibility' => p['visibility'],
        'elements' => Array(page_element_ids[p['id']]).filter_map do |element_id|
          element = elements_by_id[element_id]
          { 'id' => element['id'], 'kind' => element['kind'], 'name' => element['name'] }.compact if element
        end }
    end,
  }
end

# ---------------------------------------------------------------------------
# Phase 6f (gate 8) — which posted page to render. The hidden "Data" page
# (id 'page-data' — build-workbook-spec.rb's master-table container) carries
# no user-visible content; rendering it would produce a blank/placeholder
# PNG that satisfies gate 8's file-exists check while proving nothing. Pick
# the first VISIBLE page instead — the same id-substring filter every sibling
# converter's own visual-QA phase uses (tableau/quicksight/qlik/powerbi
# migrate-*.rb: `.reject { |p| p['id'].to_s.downcase.include?('data') }`).
# Pure/no I/O so it is unit-testable without a live wb-ids.json (see
# test-migrate-domo.rb).
def render_target_page(wb_ids)
  Array(wb_ids['pages']).find { |p| !p['id'].to_s.downcase.include?('data') }
end

# ---------------------------------------------------------------------------
# 'grid' vs 'stack' — see header comment for the derivation rule.
def compute_2d_flag(dashboard_layout_path)
  dashboards = JSON.parse(File.read(dashboard_layout_path))
  all_zones = Array(dashboards).flat_map { |d| Array(d['zones']) }
  content = ZoneCensus.content_zones(all_zones)
  by_row = content.group_by { |z| z['y_pct'].to_f.round(1) }
  grid = by_row.values.any? { |zs| zs.map { |z| z['x_pct'].to_f.round(1) }.uniq.size >= 2 }
  grid ? 'grid' : 'stack'
end

# ---------------------------------------------------------------------------
# phases shared by both modes

def phase_convert_beast_modes!(opts)
  hr('convert-beast-modes')
  beast_path = File.join(DISCOVERY, 'beast-modes.json')
  unless File.exist?(beast_path)
    skip_phase!('convert-beast-modes', 'no discovery/beast-modes.json present — nothing to translate')
    return
  end
  beast = begin
    JSON.parse(File.read(beast_path))
  rescue JSON::ParserError
    []
  end
  if beast.empty?
    log 'beast-modes.json is empty — nothing to translate'
  end
  formulas_path = File.join(DISCOVERY, 'formulas.json')
  if !opts[:force] && File.exist?(formulas_path)
    log 'discovery/formulas.json already present — skip (idempotent; pass --force to retranslate)'
    skip_phase!('convert-beast-modes', 'already translated (idempotent skip)')
    return
  end

  ok, code, _out = run_script!('convert-beast-modes.rb')
  fail_phase!('convert-beast-modes', "normalize step exited #{code}") unless ok

  ok, code, _out = run_script!('convert-beast-modes.rb', '--convert')
  if !ok && code == 10
    fail_phase!('convert-beast-modes',
                'no vendored converter/sql.mjs and no --mcp-dir/DOMO_MCP_DIR — re-run ' \
                "'ruby scripts/convert-beast-modes.rb --convert' directly to see the manual " \
                'convert_sql_to_sigma_formula + --converter-out fallback instructions')
  end
  fail_phase!('convert-beast-modes', "--convert step exited #{code}") unless ok

  pending_path = File.join(DISCOVERY, 'formulas.pending.json')
  pending = begin
    JSON.parse(File.read(pending_path))
  rescue StandardError
    []
  end
  unresolved = pending.count { |e| e['sigmaFormula'].nil? || e['sigmaFormula'].to_s.strip.empty? }
  unreliable = pending.count { |e| e['converted'] == false }
  if unresolved.positive?
    log "NOTE: #{unresolved} Beast Mode(s) still lack a sigmaFormula after --convert — unexpected " \
        '(lookConvertExpression is a total fallback that never returns nil); check ' \
        "convert-beast-modes.rb --convert's stderr output above."
  end
  if unreliable.positive?
    log "NOTE: #{unreliable} Beast Mode(s) flagged converted:false by --convert — has a sigmaFormula " \
        '(never silently dropped) but still contains untranslated CASE/WHEN/THEN or an infix ' \
        'LIKE/BETWEEN; review before shipping (discovery/formula-overrides.json can supply a ' \
        'hand-authored replacement).'
  end

  ok, code, _out = run_script!('convert-beast-modes.rb', '--lint')
  fail_phase!('convert-beast-modes', "--lint step exited #{code}") unless ok

  if unresolved.positive? || unreliable.positive?
    done_phase!('convert-beast-modes',
                "#{unresolved} unresolved, #{unreliable} unreliable (converted:false) — see " \
                'discovery/formulas.pending.json')
  else
    done_phase!('convert-beast-modes',
                'no residual CASE/infix syntax detected — not a full validity guarantee')
  end
end

def phase_build_workbook!(opts)
  hr('build-workbook')
  cs_path = File.join(DISCOVERY, 'chart-specs.json')
  if !opts[:force] && File.exist?(cs_path)
    log 'discovery/chart-specs.json already present — skip (idempotent; pass --force to rebuild)'
    skip_phase!('build-workbook', 'already built (idempotent skip)')
    return
  end
  ok, code, _out = run_script!('build-workbook.rb')
  fail_phase!('build-workbook', "build-workbook.rb exited #{code}") unless ok
  done_phase!('build-workbook')
end

# Source-derived presentation styling (card headers, compact KPI/axis formats,
# categorical order) — the automation that replaces the hand-authored sidecars
# the gold acceptance run first used. Runs BEFORE build-workbook (the builders
# read these sidecars) and is a NICE-TO-HAVE refinement: a failure never fails
# the run, and any operator-authored sidecar already on disk is preserved
# (derive-presentation-overrides.rb only writes files that don't already exist
# unless --force). In live mode collect-parity-expected.rb (Domo-only, no Sigma
# dependency) runs first so the display-scaling decisions see real values;
# offline/metadata-only still produces headers, KPI font sizing, and category
# order from whatever the fixture carries.
def phase_derive_presentation!(opts, collect_expected:)
  hr('derive-presentation-overrides')
  manifest = File.join(DISCOVERY, 'presentation-overrides.json')
  if !opts[:force] && File.exist?(manifest)
    log 'discovery/presentation-overrides.json already present — skip (idempotent; pass --force to rederive)'
    skip_phase!('derive-presentation-overrides', 'already derived (idempotent skip)')
    return
  end
  if collect_expected
    expected_path = File.join(OUT, 'parity-expected.json')
    if opts[:force] || !File.exist?(expected_path)
      ok_e, code_e, _e = run_script!('collect-parity-expected.rb', '--workdir', OUT)
      log "collect-parity-expected exited #{code_e} — deriving from metadata only" unless ok_e
    end
  end
  args = ['--workdir', OUT, '--discovery', DISCOVERY]
  args << '--force' if opts[:force]
  ok, code, _out = run_script!('derive-presentation-overrides.rb', *args)
  if ok
    done_phase!('derive-presentation-overrides')
  else
    skip_phase!('derive-presentation-overrides',
                "derive-presentation-overrides.rb exited #{code} — builders fall back to plain " \
                'formatting; not fatal')
  end
end

def phase_build_domo_layout!(opts)
  hr('build-domo-layout')
  layout_path = File.join(DISCOVERY, 'dashboard-layout.json')
  if !opts[:force] && File.exist?(layout_path)
    log 'discovery/dashboard-layout.json already present — skip (idempotent; pass --force to rebuild)'
    skip_phase!('build-domo-layout', 'already built (idempotent skip)')
    return
  end
  ok, code, _out = run_script!('build-domo-layout.rb')
  fail_phase!('build-domo-layout', "build-domo-layout.rb exited #{code}") unless ok
  done_phase!('build-domo-layout')
end

def phase_build_dashboard_layout!(opts, wb_ids_path)
  hr('build-dashboard-layout')
  layout_xml = File.join(OUT, 'layout.xml')
  if !opts[:force] && File.exist?(layout_xml)
    log 'layout.xml already present — skip (idempotent; pass --force to rebuild)'
    skip_phase!('build-dashboard-layout', 'already built (idempotent skip)')
    return layout_xml
  end
  dash_layout = File.join(DISCOVERY, 'dashboard-layout.json')
  fail_phase!('build-dashboard-layout', 'discovery/dashboard-layout.json missing — build-domo-layout did not run') unless File.exist?(dash_layout)
  ok, code, _out = run_script!('build-dashboard-layout.rb', '--layout', dash_layout, '--wb-ids', wb_ids_path, '--out', layout_xml)
  fail_phase!('build-dashboard-layout', "build-dashboard-layout.rb exited #{code}") unless ok
  done_phase!('build-dashboard-layout')
  layout_xml
end

def phase_write_2d_flag!
  hr('layout-2d-flag')
  dash_layout = File.join(DISCOVERY, 'dashboard-layout.json')
  flag_path = File.join(OUT, 'layout-2d.flag')
  flag = compute_2d_flag(dash_layout)
  File.write(flag_path, flag)
  log "wrote #{flag_path} = #{flag.inspect} (derived from build-domo-layout.rb's zone census — never hardcoded)"
  done_phase!('layout-2d-flag', "computed #{flag.inspect}")
  flag
end

# bead B5: nothing upstream of this ever rendered a Sigma PNG, so
# assert-phase6-ran.rb's gate 8 (requires <out>/sigma-render.png or a
# screenshots manifest) deterministically exit-10'd on every LIVE run. Render
# the posted workbook's first visible page via the existing sigma-export-png.py
# (the /v2/workbooks/{id}/export REST contract — see its header for the
# POST-then-poll shape); non-fatal on a genuinely-absent prerequisite (no
# page to render, or no python3 on PATH), but a real export failure still
# fails the phase — a render that silently never happened is exactly the bug
# this closes.
def phase_render_visual!(opts, workbook_id, wb_ids)
  hr('render-visual (Phase 6f render — gate 8)')
  render_path = File.join(OUT, 'sigma-render.png')
  if !opts[:force] && File.exist?(render_path)
    log 'sigma-render.png already present — skip (idempotent; pass --force to re-render)'
    skip_phase!('render-visual', 'already rendered (idempotent skip)')
    return
  end
  page = render_target_page(wb_ids)
  if page.nil?
    skip_phase!('render-visual', 'wb-ids.json has no non-Data page to render (only the hidden master page exists)')
    return
  end
  ok, code, _out = run_py_script!('sigma-export-png.py', '--workbook', workbook_id, '--page', page['id'], '--out', render_path)
  if code.nil?
    skip_phase!('render-visual', 'python3 not found on PATH — cannot run sigma-export-png.py; render by ' \
                                  "hand per refs/layout-visual-qa.md (--out #{render_path}), then re-run")
    return
  end
  fail_phase!('render-visual', "sigma-export-png.py exited #{code}") unless ok
  done_phase!('render-visual', "rendered page #{page['id'].inspect} -> #{render_path}")
end

# Gate 8b requires an independent, hash-bound visual grade. Ruby cannot honestly
# invent one, so the orchestration contract is resumable:
#   1. stage --source-dashboard-png, render Sigma, finalize parity;
#   2. consume <out>/blind-grade.json when already present, OR invoke the
#      optional --visual-grader adapter;
#   3. if neither exists, write visual-grade-request.json and exit 20 WAITING
#      instead of recording not-executable and crashing the final gate.
# The calling agent handles exit 20 by launching a fresh context-free grader
# from the request and rerunning the SAME command. No artifact hand-edit or
# special finalize command is required.
def phase_record_visual_check!(opts)
  hr('record-visual-check (Phase 6f verdict — gate 8b)')
  parity_final_path = File.join(OUT, 'parity-final.json')
  unless File.exist?(parity_final_path)
    skip_phase!('record-visual-check',
                'no parity-final.json yet — verify-parity ran without a --parity-plan (nothing to ' \
                'record the visual verdict onto). Once a plan is supplied, read ' \
                "#{File.join(OUT, 'sigma-render.png')} against the source and record the real verdict " \
                "by hand: ruby scripts/record-visual-check.rb --workdir #{OUT} --agent-vision true --verdict pass ...")
    return
  end

  render_path = File.join(OUT, 'sigma-render.png')
  grade_path = File.expand_path(opts[:blind_grade] || DomoVisualHandoff::GRADE_BASENAME, OUT)
  source_path = opts[:source_dashboard_png]
  rubric_path = File.expand_path('../refs/layout-visual-qa.md', __dir__)
  brief_path = File.expand_path('../refs/blind-grader-brief.md', __dir__)

  validation = DomoVisualHandoff.validate_grade(grade_path, workdir: OUT) if File.file?(grade_path)
  invalid_reason = validation && validation['errors'].any? ? validation['errors'].join('; ') : nil

  unless validation && validation['errors'].empty?
    request_path = DomoVisualHandoff.write_request!(
      workdir: OUT,
      source_path: source_path,
      target_path: render_path,
      rubric_path: rubric_path,
      brief_path: brief_path,
      grade_path: grade_path,
      reason: invalid_reason
    )

    if opts[:visual_grader] && source_path
      log "$ #{opts[:visual_grader]} #{request_path}"
      begin
        output, status = Open3.capture2e(BASE_ENV, opts[:visual_grader], request_path)
      rescue Errno::ENOENT
        fail_phase!('record-visual-check',
                    "visual grader executable not found: #{opts[:visual_grader]}")
      end
      output.each_line { |line| print "    #{line}" }
      fail_phase!('record-visual-check',
                  "visual grader adapter exited #{status.exitstatus}") unless status.success?
      validation = DomoVisualHandoff.validate_grade(grade_path, workdir: OUT)
      unless validation['errors'].empty?
        fail_phase!('record-visual-check',
                    "visual grader wrote an invalid grade: #{validation['errors'].join('; ')}")
      end
    else
      reason =
        if source_path.nil?
          "source dashboard PNG required — rerun with --source-dashboard-png PATH; request: #{request_path}"
        else
          "context-free blind grade required — request: #{request_path}; write #{grade_path} and rerun the same command"
        end
      DomoRunState.wait(OUT, 'record-visual-check', reason)
      DomoRunState.record(OUT, 'status' => 'waiting-for-visual-grade',
                               'visual_grade_request' => request_path)
      raise VisualGradePending.new(reason, request_path)
    end
  end

  args = DomoVisualHandoff.record_args(
    validation,
    workdir: OUT,
    target_path: render_path,
    grade_path: grade_path
  )
  ok, code, _out = run_script!('record-visual-check.rb', *args)
  fail_phase!('record-visual-check', "record-visual-check.rb exited #{code}") unless ok
  done_phase!('record-visual-check', "consumed context-free blind grade #{grade_path}")
  DomoRunState.record(OUT, 'status' => 'running')
end

# ---------------------------------------------------------------------------
# offline driver

def run_offline!(opts)
  fixture = File.expand_path(opts[:offline])
  abort("FATAL: --offline fixture dir not found: #{fixture}") unless Dir.exist?(fixture)

  hr('discover (offline seed)')
  if !opts[:force] && out_exists?(File.join(DISCOVERY, 'cards.json'), File.join(DISCOVERY, 'pages.json'))
    log "cards.json/pages.json already present in #{DISCOVERY} — skip (idempotent; pass --force to reseed)"
    skip_phase!('discover', 'offline: discovery already seeded (idempotent skip)')
  else
    copied = seed_discovery!(fixture)
    log "seeded #{copied.join(', ')} from #{fixture} -> #{DISCOVERY}"
    %w[cards.json pages.json].each do |f|
      unless File.exist?(File.join(DISCOVERY, f))
        fail_phase!('discover', "offline fixture #{fixture} is missing required #{f}")
      end
    end
    skip_phase!('discover', "offline: seeded from fixture #{fixture} (no live domo-discover.rb call)")
  end

  hr('capture-visuals')
  skip_phase!('capture-visuals', 'offline: PNG assets (if any) are pre-seeded by the fixture at png/cards/*.png; no live render')

  phase_convert_beast_modes!(opts)
  phase_derive_presentation!(opts, collect_expected: false)
  phase_build_workbook!(opts)

  hr('build-workbook-spec')
  spec_path = File.join(OUT, 'workbook-spec.json')
  if !opts[:force] && File.exist?(spec_path)
    log 'workbook-spec.json already present — skip (idempotent; pass --force to rebuild)'
    skip_phase!('build-workbook-spec', 'already built (idempotent skip)')
  else
    cs_path = File.join(DISCOVERY, 'chart-specs.json')
    fail_phase!('build-workbook-spec', 'discovery/chart-specs.json missing — build-workbook did not run') unless File.exist?(cs_path)
    offline_build_workbook_spec!(cs_path, name: opts[:workbook_name], description: opts[:description],
                                  folder_id: opts[:folder_id] || 'offline-placeholder', out_path: spec_path)
    log "wrote #{spec_path}"
    done_phase!('build-workbook-spec', 'offline-local assembly — no live Data Model readback (see workbook-spec.json._note)')
  end

  hr('post-and-readback')
  skip_phase!('post-and-readback', 'offline: no live Sigma DM/workbook to post/read back')

  phase_build_domo_layout!(opts)

  spec = JSON.parse(File.read(spec_path))
  wb_ids_path = File.join(OUT, 'wb-ids.json')
  File.write(wb_ids_path, JSON.pretty_generate(wb_ids_from_spec(spec)))
  layout_xml = phase_build_dashboard_layout!(opts, wb_ids_path)

  hr('put-layout')
  existing_document = Sigma::CodeRep.document(JSON.parse(File.read(spec_path)))
  if !opts[:force] && !existing_document['layout'].to_s.strip.empty?
    log 'workbook-spec.json already has a layout — skip (idempotent; pass --force to rebuild)'
    skip_phase!('put-layout', 'already merged (idempotent skip)')
  else
    offline_put_layout!(spec_path, layout_xml, "#{layout_xml}.elements.json")
    log "merged layout into #{spec_path}"
    done_phase!('put-layout', 'offline-local merge — no live workbook GET/PUT (see build-workbook-spec / put-layout header note)')
  end

  phase_write_2d_flag!

  hr('render-visual')
  skip_phase!('render-visual', 'offline: no live posted workbook to render (see --offline header note)')

  hr('verify-parity')
  skip_phase!('verify-parity', 'offline: no live Sigma query results to compare against')

  hr('record-visual-check')
  skip_phase!('record-visual-check', 'offline: no live render / parity-final.json to record a verdict onto')

  hr('assert-phase6-ran')
  skip_phase!('assert-phase6-ran', 'offline: gate requires a live posted workbook + source parity; not applicable to --offline')
end

# ---------------------------------------------------------------------------
# live driver

def run_live!(opts)
  abort('FATAL: --pages IDS is required in live mode (or pass --offline DIR)') unless opts[:pages]

  tier_b = ENV['DOMO_DEV_TOKEN'].to_s.strip.empty?
  hr('tier probe')
  log(tier_b ? 'Tier B (no DOMO_DEV_TOKEN) — public API only; card defs, Beast Modes, private render, and ' \
               'layout geometry will NOT be auto-extractable. See refs/connection.md for the manual fallback.'
             : 'Tier A (DOMO_DEV_TOKEN set) — full private-API fidelity available.')
  DomoRunState.record(OUT, 'tier' => (tier_b ? 'B' : 'A'))

  hr('discover')
  if !opts[:force] && File.exist?(File.join(DISCOVERY, 'cards.json'))
    log 'discovery/cards.json already present — skip (idempotent; pass --force to rediscover)'
    skip_phase!('discover', 'already discovered (idempotent skip)')
  else
    ok, code, _out = run_script!('domo-discover.rb', '--datasets')
    fail_phase!('discover', "domo-discover.rb --datasets exited #{code}") unless ok
    ok, code, _out = run_script!('domo-discover.rb', '--pages', opts[:pages].join(','))
    fail_phase!('discover', "domo-discover.rb --pages exited #{code}") unless ok
    done_phase!('discover')
  end

  hr('capture-visuals')
  if tier_b
    skip_phase!('capture-visuals', 'Tier B — private render endpoint unavailable; export card PNGs manually per refs/connection.md')
  elsif !opts[:force] && !Dir.glob(File.join(DISCOVERY, 'png', 'cards', '*')).empty?
    log 'discovery/png/cards already populated — skip (idempotent; pass --force to recapture)'
    skip_phase!('capture-visuals', 'already captured (idempotent skip)')
  else
    ok, code, _out = run_script!('domo-capture-visuals.rb', '--pages', opts[:pages].join(','))
    if code == 3
      skip_phase!('capture-visuals', 'Tier B reported by domo-capture-visuals.rb (exit 3) — private render unavailable')
    else
      fail_phase!('capture-visuals', "domo-capture-visuals.rb exited #{code}") unless ok
      done_phase!('capture-visuals')
    end
  end

  phase_convert_beast_modes!(opts)

  # ---- build-dm + its post-and-readback: NOT in the task's phase list, but a
  # hard prerequisite of build-workbook-spec.rb's --dm-ids — see header note.
  hr('build-dm (implicit prerequisite of build-workbook-spec)')
  dm_spec_path = File.join(DISCOVERY, 'dm-spec.json')
  if !opts[:force] && File.exist?(dm_spec_path)
    log 'discovery/dm-spec.json already present — skip (idempotent; pass --force to rebuild)'
    skip_phase!('build-dm', 'already built (idempotent skip)')
  else
    # Column pre-flight (bead m655): only meaningful once dataset-map.json is
    # human-resolved — the FIRST build-dm.rb attempt below (no dataset-map.json
    # yet) writes dataset-map.template.json and fails, same as before this
    # bead; there is nothing to pre-flight until a human finishes that file.
    map_path = File.join(DISCOVERY, 'dataset-map.json')
    if File.exist?(map_path)
      hr('preflight-columns (Domo columns vs the real warehouse schema)')
      # Unlike other idempotent phases in this file, this one is NOT skipped
      # just because its output file already exists: dataset-map.json is
      # human-editable between runs (a newly-resolved connectionId, a fix via
      # excludeColumns/columnOverrides), and a stale column-preflight.json
      # would either silently re-admit a gap that was never actually
      # re-checked, or permanently deadlock the fix-and-re-run loop (the
      # operator's fix is never validated). The live check itself is cheap
      # (a couple of Sigma API calls per dataset), so always re-running it
      # here is the safe default.
      pf_ok, pf_code, _pf_out = run_script!('preflight-columns.rb')
      skip_env = ENV['SIGMA_SKIP_COLUMN_PREFLIGHT'].to_s.strip
      if !pf_ok
        if skip_env.empty?
          fail_phase!('preflight-columns',
                      "preflight-columns.rb exited #{pf_code} — unresolved column(s) or a fetch error " \
                      'found; see discovery/column-preflight.json for names + any auto-suggested ' \
                      'columnOverrides, resolve via excludeColumns/columnOverrides in dataset-map.json, ' \
                      'then re-run (or set SIGMA_SKIP_COLUMN_PREFLIGHT="<reason>" to waive, same as ' \
                      "build-dm.rb's gate)")
        else
          skip_phase!('preflight-columns',
                      "unresolved columns found but WAIVED via SIGMA_SKIP_COLUMN_PREFLIGHT=#{skip_env.inspect}")
        end
      else
        done_phase!('preflight-columns')
      end
    end

    # --folder-id must reach build-dm too, not just build-workbook-spec: the DM
    # spec itself needs a folderId or POST /v2/dataModels/spec 400s with
    # "Expecting UUID at 0.folderId" (live-validated 2026-07-30).
    dm_args = ['build-dm.rb']
    dm_args += ['--folder-id', opts[:folder_id]] if opts[:folder_id]
    ok, code, _out = run_script!(*dm_args)
    if !ok && File.exist?(File.join(DISCOVERY, 'dataset-map.template.json')) && !File.exist?(File.join(DISCOVERY, 'dataset-map.json'))
      fail_phase!('build-dm', 'wrote discovery/dataset-map.template.json — fill in the warehouse mapping for ' \
                              'each DataSet as discovery/dataset-map.json and re-run')
    end
    fail_phase!('build-dm', "build-dm.rb exited #{code}") unless ok
    done_phase!('build-dm')
  end

  hr('post-and-readback (data-model)')
  dm_ids_path = File.join(OUT, 'dm-ids.json')
  if !opts[:force] && File.exist?(dm_ids_path)
    log 'dm-ids.json already present — skip (idempotent; pass --force to re-post)'
    skip_phase!('post-and-readback-dm', 'already posted (idempotent skip)')
  else
    dm_spec = JSON.parse(File.read(dm_spec_path))
    grounding = DomoWarehouseColumnRefs.apply!(
      dm_spec,
      requester: ->(method, path, **kwargs) { Sigma.request(method, path, **kwargs) },
      lister: ->(path) { Sigma.list_entries(path) }
    )
    File.write(dm_spec_path, JSON.pretty_generate(dm_spec))
    modes = grounding[:connection_modes].map { |id, friendly| "#{id}=#{friendly ? 'friendly' : 'physical'}" }.join(', ')
    log "connection naming: #{modes}; grounded #{grounding[:rewritten]} formula(s), " \
        "re-keyed #{grounding[:rekeyed]} id(s), re-prefixed #{grounding[:reprefixed]} ref(s)"
    ok, code, _out = run_script!('post-and-readback.rb', '--type', 'datamodel', '--spec', dm_spec_path,
                                  '--out', dm_ids_path, '--workdir', OUT)
    fail_phase!('post-and-readback-dm', "post-and-readback.rb --type datamodel exited #{code}") unless ok
    done_phase!('post-and-readback-dm')
  end

  phase_derive_presentation!(opts, collect_expected: !tier_b)
  phase_build_workbook!(opts)

  hr('build-workbook-spec')
  spec_path = File.join(OUT, 'workbook-spec.json')
  if !opts[:force] && File.exist?(spec_path)
    log 'workbook-spec.json already present — skip (idempotent; pass --force to rebuild)'
    skip_phase!('build-workbook-spec', 'already built (idempotent skip)')
  else
    fail_phase!('build-workbook-spec', '--folder-id required in live mode') unless opts[:folder_id]
    cs_path = File.join(DISCOVERY, 'chart-specs.json')
    args = ['--chart-specs', cs_path, '--dm-ids', dm_ids_path, '--workbook-name', opts[:workbook_name],
            '--folder-id', opts[:folder_id], '--mode', opts[:mode], '--out', spec_path]
    args += ['--description', opts[:description]] if opts[:description]
    ok, code, _out = run_script!('build-workbook-spec.rb', *args)
    fail_phase!('build-workbook-spec', "build-workbook-spec.rb exited #{code}") unless ok
    done_phase!('build-workbook-spec')
  end

  hr('post-and-readback (workbook)')
  wb_ids_path = File.join(OUT, 'wb-ids.json')
  if !opts[:force] && File.exist?(wb_ids_path)
    log 'wb-ids.json already present — skip (idempotent; pass --force to re-post)'
    skip_phase!('post-and-readback-wb', 'already posted (idempotent skip)')
  else
    args = ['--type', 'workbook', '--spec', spec_path, '--out', wb_ids_path, '--workdir', OUT]
    args += ['--update-id', opts[:workbook_id]] if opts[:workbook_id]
    ok, code, _out = run_script!('post-and-readback.rb', *args)
    fail_phase!('post-and-readback-wb', "post-and-readback.rb --type workbook exited #{code}") unless ok
    done_phase!('post-and-readback-wb')
  end

  phase_build_domo_layout!(opts)
  layout_xml = phase_build_dashboard_layout!(opts, wb_ids_path)

  hr('put-layout')
  wb_ids = JSON.parse(File.read(wb_ids_path))
  workbook_id = wb_ids['workbookId'] || opts[:workbook_id]
  fail_phase!('put-layout', 'no workbookId in wb-ids.json and no --workbook-id given') unless workbook_id
  ok, code, _out = run_script!('put-layout.rb', '--workbook', workbook_id, '--layout', layout_xml)
  fail_phase!('put-layout', "put-layout.rb exited #{code}") unless ok
  done_phase!('put-layout')

  phase_write_2d_flag!
  phase_render_visual!(opts, workbook_id, wb_ids)

  # ---- coverage census ----------------------------------------------------
  # Emits coverage.json: which source cards produced NO Sigma element.
  #
  # This is the ONLY route by which a dropped Domo card can reach the degradation
  # ledger. DegradationLedger.scope_cuts derives scope-cuts from just two places
  # — coverage.json, and parity-final.json's `tile_census` — and domo can never
  # fill the second, because `tile_census` is reserved for tableau's ZONE shape
  # (publishing anything else there turns gate 5's honest SKIP into a vacuous
  # "0 zones, 0 unmatched"; caught in review on #631, hence `parity_tile_census`).
  #
  # Until now domo emitted no coverage.json at all, so a card that never became
  # an element was invisible to the ledger — and since GREEN requires an EMPTY
  # ledger, a run that silently dropped cards could still be declared GREEN.
  # phase6-parity-domo.rb's census does not cover this: its denominator is
  # elements in workbook-spec.json, so a card missing from the spec entirely is
  # missing from the census too.
  #
  # Verified by planting a drop: removing one card's elements yields 35/36, one
  # scope-cut, and a verdict of PARTIAL where an empty ledger gives GREEN.
  hr('coverage-census')
  ok_cov, code_cov, _cov = run_script!('build-coverage-census.rb', '--workdir', OUT)
  if ok_cov
    done_phase!('coverage-census')
  else
    # Not fatal — but say plainly what was lost, because the ledger will now be
    # silent about dropped cards rather than empty-because-clean.
    skip_phase!('coverage-census',
                "build-coverage-census.rb exited #{code_cov} — no coverage.json, so a dropped " \
                'card cannot reach the degradation ledger; do not read a GREEN verdict as ' \
                'evidence that every card was migrated')
  end

  # ---- parity oracle (gate 1) ---------------------------------------------
  # DEFAULT-ON, same stance as gate 7b's --require-control-flip above, and for a
  # blunter reason: WITHOUT A PLAN THIS RUN CANNOT REACH GOLD. With no
  # --parity-plan the orchestrator auto-adds --skip-parity-gate below, and gate 1
  # rejects that waiver with exit 18 unless a passing anchors-verdict.json
  # already exists. So the historic default path was a guaranteed dead end that
  # merely looked like a skip.
  #
  # build-parity-plan.rb emits the tile LIST but, by design, no values —
  # verify-parity.rb is a pure differ needing BOTH sides pre-collected. The two
  # collectors supply them:
  #   collect-parity-expected.rb  Domo's own rendered card values
  #   collect-parity-actuals.rb   the live Sigma element exports
  #   build-parity-oracle.rb      joins them + writes the exclusion ledger
  # Both sides are fetched inside THIS run so a card's relative date window is
  # evaluated once (build-parity-oracle refuses a cross-UTC-day join).
  #
  # Waive with --skip-parity-oracle "<reason>" — which lands you back on the
  # dead-end path, so the reason had better be good.
  oracle_plan = nil
  oracle_skip_reason = nil
  if !opts[:parity_plan] && !opts[:skip_parity_oracle]
    hr('parity-oracle')
    plan_path = File.join(OUT, 'parity-plan.json')
    # --workbook-spec, NOT --workbook-id: phase6-parity-domo.rb's anti-inflation
    # census reads <workdir>/workbook-spec.json, so the plan must be built from
    # the SAME document or the two disagree about what "chartable" means and the
    # census fails on tiles that were never really missing (put-layout injects
    # header elements into the live spec that the local one has no idea about).
    ok, code, _o = run_script!('build-parity-plan.rb',
                               '--workbook-spec', File.join(OUT, 'workbook-spec.json'),
                               '--workbook-id', workbook_id,
                               '--out', plan_path)
    if !ok
      # Exit 2 is build-parity-plan.rb's DELIBERATE "zero chartable elements".
      # Anything else is a crash (it has no rescue around JSON.parse, so a
      # truncated workbook-spec.json raises and exits 1). Reporting a crash as
      # "no chartable tiles" is a lie that propagates: the same wording ends up
      # in the --skip-parity-gate waiver text below, sending whoever debugs the
      # non-GREEN run to look for an empty workbook instead of a broken artifact.
      why = code == 2 ? 'build-parity-plan.rb found no chartable tiles (exit 2)'
                      : "build-parity-plan.rb FAILED with exit #{code} — this is a crash, not an " \
                        'empty workbook; check workbook-spec.json is complete and parseable'
      oracle_skip_reason = why
      skip_phase!('parity-oracle', why)
    else
      ok_e, code_e, _e = run_script!('collect-parity-expected.rb', '--workdir', OUT)
      ok_a, code_a, _a = run_script!('collect-parity-actuals.rb',
                                     '--plan', plan_path,
                                     '--workbook-id', workbook_id,
                                     '--out', File.join(OUT, 'parity-actuals.json'))
      if !ok_e || !ok_a
        # Deliberately a hard FAIL, not a skip. A half-collected oracle would
        # join into a plan missing tiles, and a shrunken denominator reads
        # exactly like a clean pass — the one failure mode this whole chain is
        # built to refuse.
        fail_phase!('parity-oracle',
                    "collector failed (expected exit #{code_e}, actuals exit #{code_a}) — " \
                    'refusing to build a partial plan')
      end
      # build-parity-exclusions.rb (#649) FIRST, so its construction-level
      # exclusions exist before the join reads them. The two are complementary:
      # #649 excludes tiles that can never agree (a refused date window — Domo
      # aggregates over a window the Sigma tile lacks), while the join excludes
      # tiles it could not COLLECT. Both write parity-plan-exclusions.json, so
      # order decides who wins: run the join first and #649 overwrites its
      # exclusions, after which the census sees collection-failed tiles as
      # neither verified nor excluded and dies (exit 5). Run #649 first and the
      # join carries its entries through, honouring them over verification —
      # which matters, because such a tile IS collectable and would otherwise be
      # "verified" into a guaranteed DIVERGE that says nothing about fidelity.
      ok_x, code_x, _x = run_script!('build-parity-exclusions.rb', '--workdir', OUT)
      fail_phase!('parity-oracle',
                  "build-parity-exclusions.rb exited #{code_x} — either the runaway guard " \
                  'tripped (fix the converter, do not widen exclusions) or the artifact is ' \
                  'unreadable; continuing would hand the join a stale exclusions file') unless ok_x

      ok_j, code_j, _j = run_script!('build-parity-oracle.rb', '--workdir', OUT)
      fail_phase!('parity-oracle', "build-parity-oracle.rb exited #{code_j}") unless ok_j
      oracle_plan = File.join(OUT, 'parity-plan-verified.json')
      done_phase!('parity-oracle')
    end
  end

  hr('verify-parity')
  opts[:parity_plan] ||= oracle_plan
  if opts[:parity_plan] && File.exist?(opts[:parity_plan])
    # Bead 2tkm — finalize through phase6-parity-domo.rb, do NOT aim
    # verify-parity.rb's --score-out at parity-final.json.
    #
    # B6 correctly spotted that --score-out was never plumbed through (without it
    # verify-parity.rb only prints a report). But it aimed the score document at
    # parity-final.json, which is the GATE'S contract file: assert-phase6-ran.rb
    # reads charts_total/charts_pass/status, while --score-out writes
    # tiles_total/tiles_pass/tiles_fail. So a flawless 65/65 run wrote a document
    # in which the gate found none of its three keys, computed charts_total = 0,
    # dropped into the anchors-oracle substitution branch, found no
    # anchors-verdict.json, and exited 2 — a perfect parity run was
    # indistinguishable from parity never having run.
    #
    # domo was the only converter of six with no phase6-parity-*.rb finalizer
    # (tableau's phase6-parity.rb:344-382 is the reference). It now runs
    # verify-parity.rb itself (--score-out -> parity-score.json), derives the
    # gate contract into parity-final.json, and refuses to emit a contract when
    # the plan silently omits chartable tiles.
    # Generate parity-plan-exclusions.json FIRST — the finalizer's census consumes
    # it, and #631 shipped the census with nothing writing the file it reads. The
    # generator derives exclusions only from machine facts already in
    # warnings.json (today: refused date windows, where Domo applies a window the
    # Sigma tile lacks, so the two cannot agree by construction) and aborts rather
    # than excluding a runaway share of the pool.
    #
    # A non-zero exit here is FATAL, not advisory: it means either the runaway
    # guard tripped (fix the converter) or the artifact is unreadable — and
    # continuing would hand the census a stale or absent exclusions file.
    #
    # SKIPPED when the oracle already ran it. The oracle path invokes this
    # generator BEFORE the join so the join can carry its entries through
    # (build-parity-oracle.rb honours prior exclusions over verification).
    # Re-running it here would rewrite the file from warnings.json alone and
    # discard every collection-failure exclusion the join added — after which the
    # census sees those tiles as neither verified nor excluded and dies (exit 5).
    # This branch therefore only serves the hand-supplied --parity-plan path,
    # where no oracle ran and nothing else writes the file.
    if oracle_plan
      log 'exclusions: already generated before the oracle join (not re-running — it would ' \
          'discard the join\'s collection-failure exclusions)'
    else
      ok, code, _out = run_script!('build-parity-exclusions.rb', '--workdir', OUT)
      fail_phase!('verify-parity', "build-parity-exclusions.rb exited #{code}") unless ok
    end

    ok, code, _out = run_script!('phase6-parity-domo.rb',
                                  '--workdir', OUT,
                                  '--plan', opts[:parity_plan],
                                  '--workbook-id', workbook_id,
                                  '--score-out', File.join(OUT, 'parity-score.json'))
    fail_phase!('verify-parity', "phase6-parity-domo.rb exited #{code}") unless ok
    done_phase!('verify-parity')
  else
    skip_phase!('verify-parity',
                opts[:skip_parity_oracle] ?
                  "parity oracle waived (#{opts[:skip_parity_oracle]}) and no --parity-plan given — " \
                  'gate 1 has no evidence; this run cannot be GREEN' :
                  'no parity plan available (the oracle found no chartable tiles) — ' \
                  'run verify-parity.rb by hand before declaring GREEN')
  end

  phase_record_visual_check!(opts)

  hr('assert-phase6-ran')
  args = ['--workdir', OUT, '--workbook-id', workbook_id]
  # gate 7b (runtime control-flip proof) DEFAULT-ON: flip each control live via
  # probe-controls.rb and FAIL if a control is wired but INERT. Mirrors the
  # looker reference; waive with --skip-control-flip "<reason>".
  args += ['--require-control-flip']
  args += ['--skip-visual-gate', 'Tier B — private render endpoint unavailable'] if tier_b
  # The reason must say what ACTUALLY happened — it is recorded as a waiver and
  # read later by someone reconstructing why a run was not GREEN. "no
  # --parity-plan supplied" was true when that was the only way to get a plan;
  # now the oracle builds one by default, so the honest reason is whichever of
  # these applies.
  unless opts[:parity_plan]
    why = if opts[:skip_parity_oracle]
            "parity oracle waived via --skip-parity-oracle: #{opts[:skip_parity_oracle]}"
          else
            # Reuse the reason the oracle phase actually recorded, so a CRASH in
            # build-parity-plan.rb is not laundered into the benign-sounding
            # "found no chartable tiles". This text is the run's permanent record
            # of why gate 1 had no evidence.
            oracle_skip_reason || 'parity oracle produced no plan'
          end
    args += ['--skip-parity-gate', why]
  end
  ok, code, _out = run_script!('assert-phase6-ran.rb', *args)
  fail_phase!('assert-phase6-ran', "assert-phase6-ran.rb exited #{code}") unless ok
  done_phase!('assert-phase6-ran')
end

# ---------------------------------------------------------------------------

begin
  if opts[:offline]
    run_offline!(opts)
  else
    run_live!(opts)
  end
rescue VisualGradePending => e
  hr('WAITING — visual grade required')
  log e.message
  log 'No failure or waiver was recorded. A vision-capable agent should fulfill the request and rerun this command.'
  exit DomoVisualHandoff::EXIT_PENDING
end

DomoRunState.record(OUT, 'finished_at' => Time.now.utc.iso8601, 'status' => 'complete')
hr('DONE')
log "run-state: #{DomoRunState.path(OUT)}"
log "workbook-spec: #{File.join(OUT, 'workbook-spec.json')}"
log "layout-2d.flag: #{File.read(File.join(OUT, 'layout-2d.flag')).inspect}" if File.exist?(File.join(OUT, 'layout-2d.flag'))
