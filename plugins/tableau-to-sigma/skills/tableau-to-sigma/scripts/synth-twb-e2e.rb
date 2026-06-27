#!/usr/bin/env ruby
# frozen_string_literal: true
#
# synth-twb-e2e — live end-to-end test of the mechanical Tableau→Sigma chain
# against a SYNTHETIC / EMPTY warehouse, with NO live Tableau (n4pi.5).
#
# WHY: a dataless .twb (customer can't share data) still has to MIGRATE — the
# converter must emit a data model whose custom-SQL executes and a workbook whose
# charts RESOLVE at live POST. A code-only Stage-1 "build" is optimistic: it
# happily emits charts that reference columns the live model can't see. Only a
# real POST against a warehouse reveals that. So we:
#   1. (you, once) synthesize an EMPTY but correctly-TYPED warehouse from the
#      .twb's custom-SQL — the DM POST executes kind:sql, so empty rows suffice,
#      and custom-SQL elements bypass the Sigma catalog (no schema refresh).
#   2. run converter → DM POST (with an error-column repair loop) → derive_master
#      → build-charts → build-workbook → POST workbook → render.
# Charts resolving at POST == the blend collapsed correctly and the build layer
# wired every measure/dim/control. Empty tabs are then provably SOURCE-side
# (custom-SQL omits the field) or inert source calcs, surfaced in migration-notes.
#
# This drives the skill's own scripts/*.rb directly (migrate-tableau.rb has no
# offline mode). It does NOT touch the .twb — discovery artifacts are reused or
# regenerated from the static workbook XML.
#
# Usage:
#   ruby scripts/synth-twb-e2e.rb \
#     --twb /path/workbook-content.twb \
#     --conn <sigma-connection-id> --db <DB> --schema <SCHEMA> \
#     --folder <sigma-folder-id> \
#     [--build /path/build/tableau.js]   # local converter; omit → hosted MCP
#     [--discover-dir DIR]               # pre-staged layout.json/get-workbook.json/views/
#     [--workdir DIR] [--name "WB NAME"] \
#     [--dashboard "Name"]...            # per-dashboard scoping (repeatable) \
#     [--grant-role ROLE]                # GRANT SELECT on synth tables via `snow` CLI
#     [--no-render] [--keep]
#
# Prereqs: SIGMA_API_TOKEN reachable via scripts/get-token.sh; node (for a local
# --build); python3 + PyYAML (for enrich-master-map.py); the synth warehouse
# tables already created + granted to the connection's role.
require 'json'
require 'yaml'
require 'fileutils'
require 'open3'
require 'optparse'
require 'set'
require 'tmpdir'

HERE = __dir__
$LOAD_PATH.unshift HERE
$LOAD_PATH.unshift File.join(HERE, 'lib')
require File.join(HERE, 'mechanical-specs.rb')
require 'sigma_rest'

opts = { render: true }
OptionParser.new do |p|
  p.on('--twb PATH')          { |v| opts[:twb] = v }
  p.on('--conn ID')           { |v| opts[:conn] = v }
  p.on('--db DB')             { |v| opts[:db] = v }
  p.on('--schema SCHEMA')     { |v| opts[:schema] = v }
  p.on('--folder ID')         { |v| opts[:folder] = v }
  p.on('--build PATH')        { |v| opts[:build] = v }
  p.on('--discover-dir DIR')  { |v| opts[:discover] = v }
  p.on('--workdir DIR')       { |v| opts[:workdir] = v }
  p.on('--name NAME')         { |v| opts[:name] = v }
  p.on('--dashboard NAME')    { |v| (opts[:dashboards] ||= []) << v }
  p.on('--grant-role ROLE')   { |v| opts[:grant_role] = v }
  p.on('--no-render')         { opts[:render] = false }
  p.on('--keep')              { opts[:keep] = true }
end.parse!

%i[twb conn db schema folder].each { |k| abort("missing --#{k.to_s.tr('_', '-')}") unless opts[k] }
abort("twb not found: #{opts[:twb]}") unless File.exist?(opts[:twb])

WORK = opts[:workdir] || File.join(Dir.tmpdir, "synth-e2e-#{File.basename(opts[:twb], '.*')}")
FileUtils.mkdir_p WORK
NAME = opts[:name] || "Synth E2E — #{File.basename(opts[:twb], '.*')}"

def run!(cmd, allow_fail: false)
  puts "+ #{cmd.join(' ')}"
  o, e, s = Open3.capture3(*cmd)
  puts o[-2000..] || o unless o.to_s.empty?
  warn e[-2000..] || e unless e.to_s.empty?
  abort "FAILED (#{s.exitstatus}): #{cmd.first}" unless s.success? || allow_fail
  [o, e, s]
end

# ---------------------------------------------------------------------------
# 0. Discovery artifacts (layout.json, layout-meta.json, get-workbook.json,
#    views/). Reuse a pre-staged --discover-dir if given; otherwise regenerate
#    layout from the static .twb and SYNTHESIZE a get-workbook.json from the
#    worksheet names the layout references (dataless run → no view CSVs → charts
#    build from shelf signals via build-charts' synthesize_view_from_signals).
# ---------------------------------------------------------------------------
puts "\n== 0. discovery artifacts =="
if opts[:discover]
  %w[layout.json layout-meta.json get-workbook.json].each do |f|
    src = File.join(opts[:discover], f)
    FileUtils.cp(src, File.join(WORK, f)) if File.exist?(src)
  end
  vsrc = File.join(opts[:discover], 'views')
  FileUtils.cp_r(vsrc, WORK) if File.directory?(vsrc) && !File.directory?(File.join(WORK, 'views'))
end

layout_path = File.join(WORK, 'layout.json')
unless File.exist?(layout_path)
  cmd = ['ruby', File.join(HERE, 'parse-twb-layout.rb'), opts[:twb], layout_path]
  (opts[:dashboards] || []).each { |d| cmd += ['--dashboard', d] }
  run!(cmd)
end
meta_path = File.join(WORK, 'layout-meta.json')
abort("layout-meta.json missing after discovery (#{meta_path})") unless File.exist?(meta_path)

gw_path = File.join(WORK, 'get-workbook.json')
unless File.exist?(gw_path)
  # Synthesize from the layout's worksheet names so build-charts can map each
  # chart zone to a "view" (id == slug(name)); no CSV → signal-built tile.
  # build-charts keys the view lookup off z['caption'] (the worksheet name), so
  # synthesize one stub per chart zone caption (not 'worksheet'/'name', which the
  # layout zones don't carry — that left standard charts unmatched).
  layout = JSON.parse(File.read(layout_path))
  names = layout.flat_map do |d|
    (d['zones'] || []).select { |z| z['kind'] == 'chart' }
                      .map { |z| z['caption'] || z['worksheet'] || z['name'] }
  end.compact.uniq
  views = names.map { |n| { 'name' => n, 'id' => n.downcase.gsub(/\W+/, '-').gsub(/^-|-$/, '') } }
  File.write(gw_path, JSON.pretty_generate('views' => { 'view' => views }))
  puts "  synthesized get-workbook.json with #{views.size} view stub(s) from layout worksheets"
end
FileUtils.mkdir_p File.join(WORK, 'views')
# Also copy the .twb into WORK so migration-notes (and a later re-run) find it.
FileUtils.cp(opts[:twb], File.join(WORK, 'workbook-content.twb')) unless
  File.exist?(File.join(WORK, 'workbook-content.twb'))

# ---------------------------------------------------------------------------
# Optional: GRANT SELECT on the synth warehouse tables to the connection's role
# (the converter qualifies tables as <db>.<schema>.<table>). Best-effort via the
# `snow` CLI; the DM POST is the real verifier so a grant failure only warns.
# ---------------------------------------------------------------------------
if opts[:grant_role]
  puts "\n== 0b. grant synth schema to #{opts[:grant_role]} =="
  sql = "GRANT SELECT ON ALL TABLES IN SCHEMA #{opts[:db]}.#{opts[:schema]} TO ROLE #{opts[:grant_role]}; " \
        "GRANT USAGE ON SCHEMA #{opts[:db]}.#{opts[:schema]} TO ROLE #{opts[:grant_role]}; " \
        "GRANT USAGE ON DATABASE #{opts[:db]} TO ROLE #{opts[:grant_role]};"
  run!(['snow', 'sql', '-q', sql], allow_fail: true)
end

# ---------------------------------------------------------------------------
# 1. Converter (local build or hosted MCP) → DM spec.
# ---------------------------------------------------------------------------
puts "\n== 1. converter (#{opts[:build] ? 'local build' : 'hosted MCP'}) =="
conv = MechanicalSpecs.run_converter(twb_path: opts[:twb], conn: opts[:conn], db: opts[:db],
                                     schema: opts[:schema], mcp_build: opts[:build], workdir: WORK)
puts "stats: #{conv['stats'].to_json}"
fx = MechanicalSpecs.fixup_dm_spec(conv['model'])
puts "fixup: fixed=#{fx[:fixed]} dropped=#{fx[:dropped].size}"

# The converter now self-validates calc columns/metrics (decodes XML entities,
# translates IN→or-chain, strips // comments, resolves calc-on-calc refs to
# captions, reconciles caption↔SQL-alias, routes untranslatable table-calc/LOD/
# param calcs to workbookPatterns, and drop-and-surfaces any calc with an
# unresolvable sibling ref). So we DON'T pre-prune here (the old harness did, and
# it dropped every calc column); we trust the output and just report its shape.
conv['model']['pages'].each do |pg|
  (pg['elements'] || []).each do |el|
    next unless el.dig('source', 'kind') == 'sql'
    alias_cols = (el['columns'] || []).count { |c| (c['formula'] || '') =~ %r{\A\[Custom SQL/[^\]]+\]\z} }
    calc_cols  = (el['columns'] || []).size - alias_cols
    puts "  element '#{el['name']}': #{alias_cols} alias + #{calc_cols} calc col(s), #{(el['metrics'] || []).size} metric(s)"
  end
end

conv['model']['folderId'] = opts[:folder]
dm_spec_path = File.join(WORK, 'dm-spec.json')
File.write(dm_spec_path, JSON.pretty_generate(conv['model']))

# ---------------------------------------------------------------------------
# 2. POST DM with an error-column repair loop. The converter self-validates, but
#    Sigma's authoritative type checker may still reject a calc for a reason we
#    can't predict offline (a boolean comparison form, an exotic arg shape).
#    post-and-readback exits 2 and names the error columns; use Sigma as ground
#    truth — prune them + any calc that transitively depends on them, delete the
#    bad DM, re-post. Never silent: every pruned column is printed.
# ---------------------------------------------------------------------------
def prune_error_cols!(spec, error_names)
  bad = error_names.map(&:downcase).to_set
  loop do
    grew = false
    spec['pages'].each do |pg|
      (pg['elements'] || []).each do |el|
        next unless el.dig('source', 'kind') == 'sql'
        %w[columns metrics].each do |k|
          (el[k] || []).each do |c|
            nm = (c['name'] || '').downcase
            next if nm.empty? || bad.include?(nm)
            refs = (c['formula'] || '').scan(/\[([^\]\[\/]+)\]/).flatten.map(&:downcase)
            if refs.any? { |r| bad.include?(r) } && !(c['formula'] =~ %r{\A\[Custom SQL/})
              bad << nm
              grew = true
            end
          end
        end
      end
    end
    break unless grew
  end
  spec['pages'].each do |pg|
    (pg['elements'] || []).each do |el|
      next unless el.dig('source', 'kind') == 'sql'
      if el['columns']
        el['columns'] = el['columns'].reject { |c| bad.include?((c['name'] || '').downcase) }
        keepids = el['columns'].map { |c| c['id'] }.to_set
        el['order'] = (el['order'] || []).select { |i| keepids.include?(i) } if el['order']
      end
      el['metrics'] = el['metrics'].reject { |c| bad.include?((c['name'] || '').downcase) } if el['metrics']
    end
  end
  bad
end

puts "\n== 2. POST DM (with error-column repair loop) =="
dm_ids_path = File.join(WORK, 'dm-ids.json')
dm = nil
3.times do |attempt|
  _o, _e, st = run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
                     '--spec', dm_spec_path, '--out', dm_ids_path, '--workdir', WORK], allow_fail: true)
  dm = (JSON.parse(File.read(dm_ids_path)) rescue nil)
  break if st.success?
  abort 'DM post failed and no dataModelId written — cannot repair' unless dm && dm['dataModelId']
  cols = Sigma.request(:get, "/v2/dataModels/#{dm['dataModelId']}/columns")
  errs = (cols['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }.map { |c| c['label'] }
  abort "post-and-readback failed (exit #{st.exitstatus}) but no error-type columns — different failure" if errs.empty?
  puts "  repair attempt #{attempt + 1}: Sigma flagged #{errs.size} error column(s): #{errs.join(', ')}"
  spec = JSON.parse(File.read(dm_spec_path))
  pruned = prune_error_cols!(spec, errs)
  puts "  pruned #{pruned.size} column(s)/metric(s) (incl. transitive dependents); deleting bad DM #{dm['dataModelId']} and re-posting"
  Sigma.request(:delete, "/v2/files/#{dm['dataModelId']}") rescue nil
  File.write(dm_spec_path, JSON.pretty_generate(spec))
end
abort 'DM still failing after repair attempts' unless dm
# Re-sync the in-memory model with the (repaired) posted spec so master derivation
# doesn't emit master columns for pruned fields (which would 400 the workbook POST).
conv['model'] = JSON.parse(File.read(dm_spec_path))

dm_els = dm['pages'].flat_map { |p| p['elements'] }
dim_re = /(?i)\b(dim|date|calendar)\b/
fact = dm_els.reject { |e| e['name'] =~ dim_re }.max_by { |e| (e['columnLabels'] || []).size } ||
       dm_els.max_by { |e| (e['columnLabels'] || []).size }
puts "DM #{dm['dataModelId']}: #{dm_els.size} element(s); fact='#{fact['name']}' (#{(fact['columnLabels'] || []).size} labels)"

# ---------------------------------------------------------------------------
# 3. derive_master. pick_fact only recognizes warehouse-table/derived elements;
#    a collapsed blend is a single kind:sql element, so fall back to selecting
#    the widest kind:sql element directly.
# ---------------------------------------------------------------------------
puts "\n== 3. derive_master =="
conv_fact = MechanicalSpecs.pick_fact(conv['model']) ||
            conv['model']['pages'].flat_map { |p| p['elements'] || [] }
                                  .select { |e| e.dig('source', 'kind') == 'sql' }
                                  .max_by { |e| (e['columns'] || []).size }
conv_base = MechanicalSpecs.base_of(conv['model'], conv_fact)
derived = MechanicalSpecs.derive_master(conv_fact, fact['name'], conv_base, fact['columnLabels'], conv['model'])
mcols = derived['master_columns']
mmap = derived['mmap']
master_map_path = File.join(WORK, 'master-map.json')
master_cols_path = File.join(WORK, 'master-cols.yaml')
File.write(master_map_path, JSON.pretty_generate(mmap))
File.write(master_cols_path, { 'columns' => mcols }.to_yaml)
puts "master: #{mcols.size} column(s)"

# Enrich the master-map with caption/space/underscore-flexible keys so chart refs
# that use friendly captions resolve to warehouse-named master columns (n4pi.7).
run!(['python3', File.join(HERE, 'enrich-master-map.py'), WORK, opts[:twb]])

# ---------------------------------------------------------------------------
# 4. build-charts. --auto-controls materializes Tableau parameters/shared-view
#    filters as Sigma controls; --workbook-patterns (when the installed
#    build-charts supports it) auto-wires param measure-pickers into a
#    control-driven Switch tile measure (n4pi.10).
# ---------------------------------------------------------------------------
puts "\n== 4. build-charts =="
chart_specs_path = File.join(WORK, 'chart-specs.json')
conv_meta_path = File.join(WORK, 'conv-meta.json')
bc = ['ruby', File.join(HERE, 'build-charts-from-signals.rb'),
      '--tableau-dir', WORK, '--layout', layout_path, '--master-map', master_map_path,
      '--master-element-id', 'master', '--page-per-dashboard',
      '--out', chart_specs_path, '--coverage-out', File.join(WORK, 'coverage.json'),
      '--meta', meta_path, '--auto-controls']
if File.exist?(conv_meta_path) &&
   File.read(File.join(HERE, 'build-charts-from-signals.rb')).include?('--workbook-patterns')
  bc += ['--workbook-patterns', conv_meta_path]
end
run!(bc, allow_fail: true)

# ---------------------------------------------------------------------------
# 5. build-workbook-spec.
# ---------------------------------------------------------------------------
puts "\n== 5. build-workbook-spec =="
wb_spec_path = File.join(WORK, 'wb-spec.json')
run!(['ruby', File.join(HERE, 'build-workbook-spec.rb'),
      '--chart-specs', chart_specs_path, '--dm-ids', dm_ids_path,
      '--master-cols', master_cols_path, '--workbook-name', NAME,
      '--folder-id', opts[:folder], '--mode', 'dashboard',
      '--dm-element-name', fact['name'], '--out', wb_spec_path], allow_fail: true)

wbspec = JSON.parse(File.read(wb_spec_path))
# Sigma page ids must match /^[a-zA-Z0-9_-]{1,64}$/; the slug can contain invalid
# chars (e.g. '+' from a dashboard caption). Sanitize before POST.
(wbspec['pages'] || []).each { |pg| pg['id'] = pg['id'].gsub(/[^a-zA-Z0-9_-]/, '-')[0, 64] if pg['id'] }

# Prune viz elements that still reference master columns we don't have (charts
# plotting untranslated calcs/params). Surface the count — never silent.
master_names = mcols.map { |c| c['name'].downcase }.to_set
ref_re = %r{\[master/([^\]]+)\]}i
collect = lambda do |o, acc|
  case o
  when Hash  then o.each_value { |v| v.is_a?(String) ? acc.concat(v.scan(ref_re).flatten) : collect.call(v, acc) }
  when Array then o.each { |v| collect.call(v, acc) }
  end
  acc
end
dropped_viz = 0
(wbspec['pages'] || []).each do |pg|
  pg['elements'] = (pg['elements'] || []).select do |e|
    miss = collect.call(e, []).reject { |r| master_names.include?(r.downcase) }
    if miss.any? then dropped_viz += 1; false else true end
  end
end
puts "viz prune: dropped #{dropped_viz} element(s) referencing untranslated calcs/params"
File.write(wb_spec_path, JSON.pretty_generate(wbspec))

# ---------------------------------------------------------------------------
# 6. POST workbook.
# ---------------------------------------------------------------------------
puts "\n== 6. POST workbook =="
wb_ids_path = File.join(WORK, 'wb-ids.json')
_o, e, _s = run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
                  '--spec', wb_spec_path, '--out', wb_ids_path, '--workdir', WORK], allow_fail: true)
puts "\n-- POST workbook stderr tail (resolution errors, if any) --"
puts (e || '')[-3000..] || e

# ---------------------------------------------------------------------------
# 7. migration notes ("Not Migrated (and why)") + optional render.
# ---------------------------------------------------------------------------
puts "\n== 7. migration notes =="
run!(['ruby', File.join(HERE, 'migration-notes.rb'),
      '--conv-meta', conv_meta_path, '--chart-specs', chart_specs_path,
      '--wb-spec', wb_spec_path, '--twb', opts[:twb],
      '--out', File.join(WORK, 'migration-notes.md')], allow_fail: true)
puts "→ #{File.join(WORK, 'migration-notes.md')}"

if opts[:render]
  wb = (JSON.parse(File.read(wb_ids_path)) rescue nil)
  wb_id = wb && (wb['workbookId'] || wb['id'])
  page_id = (wbspec['pages'] || []).map { |pg| pg['id'] }.compact.first
  if wb_id && page_id
    puts "\n== 8. render PNG =="
    run!(['python3', File.join(HERE, 'sigma-export-png.py'), '--workbook', wb_id,
          '--page', page_id, '--out', File.join(WORK, 'rendered.png')], allow_fail: true)
  else
    puts '  render skipped (no workbook id / page id)'
  end
end

puts "\n✅ synth-twb-e2e complete. Artifacts in #{WORK}"
puts "   DM: #{dm['dataModelId']}  workbook: #{(JSON.parse(File.read(wb_ids_path)) rescue {})['workbookId'] rescue '(see wb-ids.json)'}"
