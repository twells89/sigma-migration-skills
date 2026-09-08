#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-viz-role-routing.rb — regression for build-workbook-from-pbir.rb honoring
# `role_class` (from the viz-kind/custom-visual catalogs, task 1). A control-class
# visual must build a CONTROL, an unsupported visual must be recorded as a real
# loss with catalog guidance (not folded into 'approximated', which the coverage
# headline counts as carried over), and a decorative visual must build NOTHING —
# but an `image` visual (its OWN role_class, distinct from `decoration`) must
# still build a real Sigma element, exactly as before this task.
#
# The crux case: fixtures/viz-roles/signals.json's third-party datepicker binds
# its sliced date column under a CUSTOM role name (`categories`), not one of the
# known PBI roles (Values/Category/Fields). Without generalizing the control's
# role lookup, the column would not resolve and the control would be silently
# SKIPPED even after routing it to kind 'control' — reproducing exactly the "21
# third-party Powerviz date-picker slicers turned into bar charts" bug this task
# fixes, just one step later in the pipeline.
#
# Offline: no API, no creds — runs the real builder as a subprocess against the
# committed fixture (plus small inline fixtures for two negative-path checks).
# Run: ruby scripts/test-viz-role-routing.rb
require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'

HERE    = __dir__
BUILDER = File.join(HERE, 'build-workbook-from-pbir.rb')
RUBY    = RbConfig.ruby
SIG     = File.join(HERE, '..', 'fixtures', 'viz-roles', 'signals.json')
MMAP    = File.join(HERE, '..', 'fixtures', 'viz-roles', 'master-map.json')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Runs the real builder against arbitrary signals/master-map (paths, or Hashes
# that get written to a tmp file) plus optional --model / --image-map. Returns
# [spec, coverage]; aborts loudly if the builder itself errors (a crash is
# never a valid test outcome here).
def run_builder(sig:, mmap:, model: nil, image_map: nil)
  Dir.mktmpdir do |dir|
    sig_path  = sig.is_a?(String) ? sig : File.join(dir, 'signals.json').tap { |p| File.write(p, JSON.generate(sig)) }
    mmap_path = mmap.is_a?(String) ? mmap : File.join(dir, 'master-map.json').tap { |p| File.write(p, JSON.generate(mmap)) }
    spec_path = File.join(dir, 'wb-spec.json')
    cov_path  = File.join(dir, 'cov.json')
    args = [RUBY, BUILDER, '--signals', sig_path, '--master-map', mmap_path,
            '--data-model', 'dm-1', '--out', spec_path, '--coverage-out', cov_path]
    if model
      model_path = File.join(dir, 'model.bim')
      File.write(model_path, JSON.generate(model))
      args += ['--model', model_path]
    end
    if image_map
      imap_path = File.join(dir, 'image-map.json')
      File.write(imap_path, JSON.generate(image_map))
      args += ['--image-map', imap_path]
    end
    _o, e, st = Open3.capture3(*args)
    abort("builder failed:\n#{e}") unless st.success? && File.exist?(spec_path)
    [JSON.parse(File.read(spec_path)), JSON.parse(File.read(cov_path))]
  end
end

# =============================================================================
# Scenario 1: the committed viz-roles fixture, WITH --image-map supplied — the
# primary pass covering control/decoration/unsupported/kpi/table routing, plus
# the image visual building a real element (byte-equivalent to pre-task-2
# behavior: {"kind":"image","url":...}).
# =============================================================================
out, cov = run_builder(sig: SIG, mmap: MMAP, image_map: { 'logo1' => 'https://example.com/logo.png' })
els = out.dig('document', 'elements')
unresolved = cov['unresolved']

# --- control: third-party datepicker (custom role `categories`) ------------
ctl = els.find { |e| e['kind'] == 'control' }
check(ctl && ctl['controlType'] == 'date-range',
      'third-party datepicker built a date-range CONTROL', fails)
check(els.none? { |e| e['name'].to_s =~ /date/i && e['kind'] =~ /chart/ },
      'no datepicker was built as a chart', fails)
if ctl
  wired_col = (ctl['filters'] || []).map { |f| f['columnId'] }.compact.first ||
              ctl.dig('source', 'columnId')
  check(wired_col == 'mc-date',
        "control is wired to the DATE column, not the aggregate preset (got #{wired_col.inspect})", fails)
end

# --- decoration: shape produces no element ----------------------------------
check(els.none? { |e| e['name'].to_s =~ /deco/i },
      'decorative shape produced NO element', fails)
deco = unresolved.find { |u| u['role_class'] == 'decoration' }
check(deco && deco['severity'] == 'approximated',
      'decoration recorded cosmetic-only (severity approximated, not a data loss)', fails)

# --- unsupported: sankeyDiagram recorded as a real DROPPED loss -------------
unsup = unresolved.select { |u| u['severity'] == 'dropped' && u['role_class'] == 'unsupported' }
check(unsup.any? { |u| u['action'].to_s.length > 40 },
      'unsupported visual recorded as DROPPED with substantive catalog guidance', fails)
check(els.none? { |e| e['name'].to_s =~ /flow/i },
      'unsupported sankeyDiagram produced NO element', fails)

# --- a control is never merely "approximated" -------------------------------
# NOTE: the fixture's datepicker carries approximate:true specifically so this
# check is non-vacuous (mutation-tested: deleting the `role != 'control'`
# guard in build-workbook-from-pbir.rb must turn this FAIL). It does not
# reflect the catalog's real approximate_types for this token.
check(unresolved.none? { |u| u['severity'] == 'approximated' && u['role_class'] == 'control' },
      'a control is never merely "approximated" (mutation-tested: bites if the role!=control guard is dropped)', fails)

# --- kpi + table (native, role_class-tagged) still build normally ----------
check(els.any? { |e| e['kind'] == 'kpi-chart' }, 'cardVisual (role_class kpi) still builds a KPI', fails)
check(els.any? { |e| e['kind'] == 'table' }, 'tableEx (role_class table) still builds a table', fails)

# --- image: its OWN role_class (not 'decoration') still builds a real element,
# byte-equivalent to pre-task-2 behavior, when --image-map resolves it -------
img = els.find { |e| e['kind'] == 'image' }
check(img && img['url'] == 'https://example.com/logo.png',
      'image visual (role_class image, distinct from decoration) builds {kind:image,url:...} with --image-map', fails)
check(unresolved.none? { |u| u['pbi_type'] == 'image' },
      'image visual is NOT recorded as a loss when --image-map resolves it', fails)

# =============================================================================
# Scenario 2: same fixture, NO --image-map — the pre-existing, more actionable
# severity:dropped "Supply --image-map ..." entry (build-workbook-from-pbir.rb
# ~:1353-1357) must be REACHABLE: role_class routing must not intercept image
# before it reaches its own build/coverage logic.
# =============================================================================
_out2, cov2 = run_builder(sig: SIG, mmap: MMAP)
els2 = _out2.dig('document', 'elements')
check(els2.none? { |e| e['kind'] == 'image' },
      'without --image-map, no image element is built', fails)
img_drop = cov2['unresolved'].find { |u| u['pbi_type'] == 'image' }
check(img_drop && img_drop['severity'] == 'dropped' && img_drop['role_class'] == 'image',
      'without --image-map, the image is recorded DROPPED with role_class image (reachable again)', fails)
check(img_drop && img_drop['action'].to_s.include?('--image-map'),
      'the dropped image entry names the concrete --image-map fix', fails)

# =============================================================================
# Scenario 3 (Finding 2): pbi_viz_kind's NAME heuristic can set sigma_target=
# 'date-range' from a visualType match alone (slicer_hint + date_hint regex on
# the vendor package id) — it is a GUESS, not a column-type fact. When a TMSL
# --model IS supplied and says the bound column is a plain string, the model
# is authoritative and must win: tmsl_boolean_column? already encodes this
# rule ("a modeled non-boolean column is authoritative — do NOT guess from its
# name") and tmsl_date_column?'s caller must apply the same rule.
# =============================================================================
heuristic_mmap = {
  'masters' => { 'H' => { 'id' => 'master-h', 'element_id' => 'el-h', 'data_model' => 'dm-1',
                          'columns' => [{ 'id' => 'mc-status', 'name' => 'Status', 'formula' => '[H/Status]' }] } },
  'fields' => { 'H.Status' => { 'master' => 'H', 'ref' => '[master-h/Status]', 'agg' => nil } },
}
heuristic_signals = {
  'source' => 'powerbi', 'pages' => [{ 'page_id' => 'p0', 'page_title' => 'P0', 'page_w' => 1280, 'page_h' => 720,
    'interactions' => [], 'visuals' => [
      { 'visual_id' => 'p0v0', 'visual_type' => 'FancyDateRangePicker_9', 'title' => 'Status Filter',
        'sigma_kind' => 'control', 'role_class' => 'control', 'sigma_target' => 'date-range',
        'viz_guidance' => 'Unlisted visual looks like a filter.', 'viz_catalog' => 'heuristic', 'approximate' => false,
        'orientation' => nil, 'x' => 0, 'y' => 0, 'w' => 300, 'h' => 100, 'z' => 0, 'parent_group' => nil,
        'bindings' => { 'Values' => ['H.Status'] }, 'sort' => nil, 'stacking' => nil, 'formats' => {},
        'data_labels' => nil, 'legend' => nil },
    ] }],
}
model_string_col = { 'model' => { 'tables' => [{ 'name' => 'H', 'columns' => [{ 'name' => 'Status', 'dataType' => 'string' }] }],
                                  'relationships' => [] } }
out3, = run_builder(sig: heuristic_signals, mmap: heuristic_mmap, model: model_string_col)
els3 = out3.dig('document', 'elements')
ctl3 = els3.find { |e| e['kind'] == 'control' }
check(ctl3 && ctl3['controlType'] == 'list',
      "heuristic sigma_target='date-range' does NOT override a modeled STRING column (got controlType=#{ctl3 && ctl3['controlType'].inspect})",
      fails)

# =============================================================================
# Scenario 4 (Minor 1, DECLARED behavior change): control_slice_qr uses
# Array(b[role]).first per known role, so {"Values":[], "Category":[...]} now
# falls through to Category — the OLD `(b['Values'] || b['Category'] || ...)`
# chain treated an explicit-but-EMPTY b['Values'] as present (`[] || x` is `[]`
# in Ruby) and never fell through, so the control used to be dropped. This is
# a genuine improvement (extract-pbir.py can emit {"Values": []} for a real
# slicer), but it is NOT byte-for-byte identical to the old chain, so it is
# pinned here explicitly rather than left as an undeclared side effect.
# =============================================================================
empty_role_signals = {
  'source' => 'powerbi', 'pages' => [{ 'page_id' => 'p0', 'page_title' => 'P0', 'page_w' => 1280, 'page_h' => 720,
    'interactions' => [], 'visuals' => [
      { 'visual_id' => 'p0v0', 'visual_type' => 'slicer', 'title' => 'Name Filter',
        'sigma_kind' => 'control', 'role_class' => 'control', 'sigma_target' => nil,
        'viz_guidance' => nil, 'viz_catalog' => 'viz-kind', 'approximate' => false,
        'orientation' => nil, 'x' => 0, 'y' => 0, 'w' => 300, 'h' => 100, 'z' => 0, 'parent_group' => nil,
        'bindings' => { 'Values' => [], 'Category' => ['T.Name'] }, 'sort' => nil, 'stacking' => nil,
        'formats' => {}, 'data_labels' => nil, 'legend' => nil },
    ] }],
}
out4, = run_builder(sig: empty_role_signals, mmap: MMAP)
els4 = out4.dig('document', 'elements')
ctl4 = els4.find { |e| e['kind'] == 'control' }
check(ctl4 && (ctl4['filters'] || []).any? { |f| f['columnId'] == 'mc-name' },
      'DECLARED: an empty Values=[] role falls through to Category (control wired to T.Name, not dropped)', fails)

# =============================================================================
# Scenario 5: Azure Maps encodes longitude/latitude as X/Y. Older persisted
# signals retain those raw roles, so the builder must normalize them before map
# resolution, never use latitude as bubble size, and retain Series as category
# color. A real Size role remains independently available.
# =============================================================================
geo_mmap = {
  'masters' => { 'G' => {
    'id' => 'master-geo', 'element_id' => 'el-geo', 'data_model' => 'dm-1',
    'columns' => [
      { 'id' => 'mc-lng', 'name' => 'Coordinate A', 'formula' => '[G/Coordinate A]' },
      { 'id' => 'mc-lat', 'name' => 'Coordinate B', 'formula' => '[G/Coordinate B]' },
      { 'id' => 'mc-group', 'name' => 'Group', 'formula' => '[G/Group]' },
      { 'id' => 'mc-metric', 'name' => 'Metric', 'formula' => '[G/Metric]' }
    ]
  } },
  'fields' => {
    'G.Coordinate A' => { 'master' => 'G', 'ref' => '[master-geo/Coordinate A]', 'agg' => nil },
    'G.Coordinate B' => { 'master' => 'G', 'ref' => '[master-geo/Coordinate B]', 'agg' => nil },
    'G.Group' => { 'master' => 'G', 'ref' => '[master-geo/Group]', 'agg' => nil },
    'G.Metric' => { 'master' => 'G', 'ref' => '[master-geo/Metric]', 'agg' => 'Sum' }
  }
}
azure_visual = lambda do |id, title, bindings|
  { 'visual_id' => id, 'visual_type' => 'azureMap', 'title' => title,
    'sigma_kind' => 'map', 'role_class' => 'chart', 'sigma_target' => 'map',
    'viz_guidance' => nil, 'viz_catalog' => 'viz-kind', 'approximate' => false,
    'orientation' => nil, 'x' => 0, 'y' => 0, 'w' => 400, 'h' => 300, 'z' => 0,
    'parent_group' => nil, 'bindings' => bindings, 'sort' => nil, 'stacking' => nil,
    'formats' => {}, 'data_labels' => nil, 'legend' => true }
end
azure_signals = {
  'source' => 'powerbi', 'pages' => [{
    'page_id' => 'p0', 'page_title' => 'Coordinate Maps', 'page_w' => 1280, 'page_h' => 720,
    'interactions' => [], 'visuals' => [
      azure_visual.call('map-no-size', 'Coordinate Map', {
                          'X' => ['G.Coordinate A'], 'Y' => ['G.Coordinate B'],
                          'Series' => ['G.Group']
                        }),
      azure_visual.call('map-sized', 'Sized Coordinate Map', {
                          'X' => ['G.Coordinate A'], 'Y' => ['G.Coordinate B'],
                          'Series' => ['G.Group'], 'Size' => ['G.Metric']
                        })
    ]
  }]
}
out5, cov5 = run_builder(sig: azure_signals, mmap: geo_mmap)
els5 = out5.dig('document', 'elements')
plain_map = els5.find { |e| e['name'] == 'Coordinate Map' }
sized_map = els5.find { |e| e['name'] == 'Sized Coordinate Map' }
check(plain_map && sized_map && [plain_map, sized_map].all? { |e| e['kind'] == 'point-map' },
      'raw legacy azureMap X/Y signals build native Sigma point maps', fails)
check(plain_map && plain_map.dig('latitude', 'columnId') && plain_map.dig('longitude', 'columnId'),
      'Azure Y binds latitude and X binds longitude', fails)
plain_lat = plain_map && plain_map['columns'].find { |c| c['id'] == plain_map.dig('latitude', 'columnId') }
plain_lng = plain_map && plain_map['columns'].find { |c| c['id'] == plain_map.dig('longitude', 'columnId') }
check(plain_lat && plain_lat['formula'] == '[master-geo/Coordinate B]' &&
      plain_lng && plain_lng['formula'] == '[master-geo/Coordinate A]',
      'coordinate role normalization is semantic and independent of column naming', fails)
check(plain_map && !plain_map.key?('size'),
      'latitude Y is never reused as bubble size when no Size role exists', fails)
size_col = sized_map && sized_map['columns'].find { |c| c['id'] == sized_map.dig('size', 'columnId') }
check(size_col && size_col['formula'] == 'Sum([master-geo/Metric])',
      'an explicit Azure Size role independently drives bubble size', fails)
color_col = plain_map && plain_map['columns'].find { |c| c['id'] == plain_map.dig('color', 'column') }
check(plain_map && plain_map.dig('color', 'by') == 'category' &&
      color_col && color_col['formula'] == '[master-geo/Group]' &&
      plain_map.dig('legend', 'visibility') == 'shown',
      'Azure Series becomes categorical point color with a visible legend', fails)
check(Array(cov5['unresolved']).none? { |u| %w[Coordinate\ Map Sized\ Coordinate\ Map].include?(u['visual']) },
      'correctly bound Azure Maps emit no false bar-approximation coverage entry', fails)
check(cov5.dig('summary', 'sourceBindings') == 7 && cov5.dig('summary', 'resolvedBindings') == 7,
      'all seven source coordinate/size/series bindings are honestly resolved', fails)

# =============================================================================
# Scenario 6: Azure Map without coordinates/geocodable metadata downgrades to a
# DATA-PRESERVING bar. Series becomes the category and Size becomes Y; the
# consumed Series must not also emit a color legend/control.
# =============================================================================
fallback_signals = {
  'source' => 'powerbi', 'pages' => [{
    'page_id' => 'p0', 'page_title' => 'Fallback Map', 'page_w' => 1280, 'page_h' => 720,
    'interactions' => [], 'visuals' => [
      azure_visual.call('map-fallback', 'Group Magnitude', {
                          'Series' => ['G.Group'], 'Size' => ['G.Metric']
                        })
    ]
  }]
}
out6, cov6 = run_builder(sig: fallback_signals, mmap: geo_mmap)
els6 = out6.dig('document', 'elements')
fallback = els6.find { |e| e['name'] == 'Group Magnitude' }
check(fallback && fallback['kind'] == 'bar-chart',
      'coordinate-less Azure Map uses the documented bar fallback', fails)
fallback_y = fallback && fallback['columns'].find { |c| Array(fallback.dig('yAxis', 'columnIds')).include?(c['id']) }
check(fallback_y && fallback_y['formula'] == 'Sum([master-geo/Metric])',
      "Azure Size survives downgrade as the bar measure (got #{fallback_y && fallback_y['formula']})", fails)
fallback_x = fallback && fallback['columns'].find { |c| c['id'] == fallback.dig('xAxis', 'columnId') }
check(fallback_x && fallback_x['formula'] == '[master-geo/Group]' && !fallback.key?('color'),
      'Azure Series is consumed as the bar category, not duplicated as color', fails)
check(els6.none? { |e| e['kind'] == 'control' && e['controlType'] == 'legend' },
      'no dependent legend control is emitted for the consumed Series role', fails)
fallback_cov = Array(cov6['unresolved']).find { |u| u['visual'] == 'Group Magnitude' }
check(fallback_cov && fallback_cov['severity'] == 'approximated' &&
      Array(cov6['unresolved']).none? { |u| u['visual'] == 'Group Magnitude' && u['detail'].to_s.include?('no measure') },
      'coverage records only the honest map→bar approximation, not a missing-measure defect', fails)

puts
puts(fails.empty? ? 'ALL PASS' : "#{fails.size} FAILURE(S)")
fails.each { |f| puts "  - #{f}" }
exit(fails.empty? ? 0 : 1)
