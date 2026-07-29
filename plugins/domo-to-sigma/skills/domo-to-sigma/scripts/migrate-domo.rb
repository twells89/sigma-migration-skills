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
#   put-layout -> verify-parity -> assert-phase6-ran
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
  o.on('--parity-plan PATH', 'LIVE mode: verify-parity.rb plan (phase skipped with a note when absent).') { |v| opts[:parity_plan] = v }
end.parse!(ARGV)

abort('FATAL: --out DIR is required') unless opts[:out]
OUT = File.expand_path(opts[:out])
FileUtils.mkdir_p(OUT)
DISCOVERY = File.join(OUT, 'discovery')
FileUtils.mkdir_p(DISCOVERY)
SCRIPTS = __dir__
BASE_ENV = { 'DOMO_DISCOVERY_DIR' => DISCOVERY }.freeze

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
    FileUtils.cp(f, File.join(DISCOVERY, File.basename(f)))
    copied << File.basename(f)
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

  data_page = {
    'id' => 'page-data', 'name' => 'Data',
    'elements' => [{
      'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'visibleAsSource' => false,
      'source' => { 'kind' => 'offline-placeholder',
                    'note' => 'no live Domo/Sigma Data Model in --offline mode — replace with a real ' \
                              'data-model source (see post-and-readback --type datamodel) before posting.' },
      'columns' => master_columns, 'order' => master_columns.map { |c| c['id'] },
    }],
  }

  used_ids = { 'page-data' => true }
  visible_pages = specs['pages'].map do |p|
    { 'id' => slugify_page_id(p['name'], used_ids), 'name' => p['name'], 'elements' => p['elements'] }
  end

  wb = {
    'name' => name, 'schemaVersion' => 1, 'folderId' => folder_id,
    'pages' => [data_page] + visible_pages,
    '_offline' => true,
    '_note' => 'assembled by migrate-domo.rb --offline without a live Sigma Data Model readback — ' \
               'the master element source and folderId are placeholders; NOT postable as-is.',
  }
  wb['description'] = description if description
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

  spec = JSON.parse(File.read(spec_path))
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
      page['elements'] ||= []
      existing = page['elements'].map { |e| e['id'] }
      els.each do |el|
        next if existing.include?(el['id'])
        page['elements'] << el
        injected += 1
      end
    end
    log "injected #{injected} container/header element(s) from #{File.basename(elements_sidecar_path)}"
  end

  File.write(spec_path, JSON.pretty_generate(spec) + "\n")
  spec
end

# wb-ids.json (the shape post-and-readback.rb --type workbook emits and
# build-dashboard-layout.rb --wb-ids consumes) derived directly from the
# just-assembled workbook-spec.json's pages/elements — no live workbook exists
# in --offline mode to read this back from.
def wb_ids_from_spec(spec)
  {
    'pages' => spec['pages'].map do |p|
      { 'id' => p['id'], 'name' => p['name'],
        'elements' => Array(p['elements']).map { |e| { 'id' => e['id'], 'name' => e['name'] }.compact } }
    end,
  }
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

  pending_path = File.join(DISCOVERY, 'formulas.pending.json')
  pending = begin
    JSON.parse(File.read(pending_path))
  rescue StandardError
    []
  end
  unresolved = pending.count { |e| e['sigmaFormula'].nil? || e['sigmaFormula'].to_s.strip.empty? }
  if unresolved.positive?
    log "NOTE: #{unresolved} Beast Mode(s) still lack a sigmaFormula — normally filled by calling " \
        'convert_sql_to_sigma_formula per pending entry (see the script header) before --lint. ' \
        'Running --lint now anyway: unresolved entries are DROPPED from formulas.json (never shipped ' \
        'silently as-is), so this phase is only fully complete once formulas.pending.json is filled in ' \
        'and re-linted.'
  end

  ok, code, _out = run_script!('convert-beast-modes.rb', '--lint')
  fail_phase!('convert-beast-modes', "--lint step exited #{code}") unless ok

  if unresolved.positive?
    done_phase!('convert-beast-modes', "#{unresolved} Beast Mode(s) unresolved — see discovery/formulas.pending.json")
  else
    done_phase!('convert-beast-modes')
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
  if !opts[:force] && (JSON.parse(File.read(spec_path))['layout'])
    log 'workbook-spec.json already has a layout — skip (idempotent; pass --force to rebuild)'
    skip_phase!('put-layout', 'already merged (idempotent skip)')
  else
    offline_put_layout!(spec_path, layout_xml, "#{layout_xml}.elements.json")
    log "merged layout into #{spec_path}"
    done_phase!('put-layout', 'offline-local merge — no live workbook GET/PUT (see build-workbook-spec / put-layout header note)')
  end

  phase_write_2d_flag!

  hr('verify-parity')
  skip_phase!('verify-parity', 'offline: no live Sigma query results to compare against')

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
    ok, code, _out = run_script!('build-dm.rb')
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
    ok, code, _out = run_script!('post-and-readback.rb', '--type', 'datamodel', '--spec', dm_spec_path,
                                  '--out', dm_ids_path, '--workdir', OUT)
    fail_phase!('post-and-readback-dm', "post-and-readback.rb --type datamodel exited #{code}") unless ok
    done_phase!('post-and-readback-dm')
  end

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

  hr('verify-parity')
  if opts[:parity_plan] && File.exist?(opts[:parity_plan])
    ok, code, _out = run_script!('verify-parity.rb', '--plan', opts[:parity_plan])
    fail_phase!('verify-parity', "verify-parity.rb exited #{code}") unless ok
    done_phase!('verify-parity')
  else
    skip_phase!('verify-parity', 'no --parity-plan supplied — run verify-parity.rb by hand before declaring GREEN')
  end

  hr('assert-phase6-ran')
  args = ['--workdir', OUT, '--workbook-id', workbook_id]
  args += ['--skip-visual-gate', 'Tier B — private render endpoint unavailable'] if tier_b
  args += ['--skip-parity-gate', 'no --parity-plan supplied to migrate-domo.rb'] unless opts[:parity_plan]
  ok, code, _out = run_script!('assert-phase6-ran.rb', *args)
  fail_phase!('assert-phase6-ran', "assert-phase6-ran.rb exited #{code}") unless ok
  done_phase!('assert-phase6-ran')
end

# ---------------------------------------------------------------------------

if opts[:offline]
  run_offline!(opts)
else
  run_live!(opts)
end

DomoRunState.record(OUT, 'finished_at' => Time.now.utc.iso8601)
hr('DONE')
log "run-state: #{DomoRunState.path(OUT)}"
log "workbook-spec: #{File.join(OUT, 'workbook-spec.json')}"
log "layout-2d.flag: #{File.read(File.join(OUT, 'layout-2d.flag')).inspect}" if File.exist?(File.join(OUT, 'layout-2d.flag'))
