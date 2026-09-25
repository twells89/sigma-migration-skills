#!/usr/bin/env ruby
# Parameter actions: on-select -> set-control-value {type: "column"}.
#
# The blocker was never just "field_caption is the wrong lookup" — the RAW ref
# is discarded at the detector, so by the time emission sees the entry there is
# nothing left to resolve a columnId from. This test locks the raw refs in,
# THEN drives the real build pipeline end to end so emission is not just typed
# but actually exercised — deterministically, on every run (no either/or
# branch): a fixture --master-map makes the source field resolve to a real
# emitted column, and a synthetic filter-calc in layout-meta.json wires the
# target control's filters[] so it is not dropped as a dead control (see the
# comment inline below for why that's the honest way to make it deterministic).
require 'json'
require 'tmpdir'
require 'rbconfig'
require 'open3'

DIR     = __dir__
GUIDE   = File.join(DIR, 'build-postpublish-guide.rb')
FIXTURE = File.join(DIR, 'test-fixtures', 'postpublish-actions.twb')
RUBY    = RbConfig.ruby

$fails = []
def check(cond, msg)
  $fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

Dir.mktmpdir do |d|
  detected = File.join(d, 'detected-actions.json')
  _, st = Open3.capture2e(RUBY, GUIDE, '--twb', FIXTURE, '--detect-only', detected)
  check(st.success?, 'detection succeeded on the fixture')
  entries = JSON.parse(File.read(detected))
  pa = entries.find { |e| e['kind'] == 'parameter-action' }
  check(!pa.nil?, 'the fixture still contains a parameter-action')

  puts '== The RAW refs survive detection ======================================='
  check(pa['sourceFieldRef'] == '[federated.f1].[none:Calculation_100:nk]',
        'sourceFieldRef carries the raw source-field, not the tidied caption ' \
        "(got #{pa['sourceFieldRef'].inspect})")
  check(pa['targetParameterRef'] == '[Parameters].[Parameter 1]',
        'targetParameterRef carries the raw target-parameter ' \
        "(got #{pa['targetParameterRef'].inspect})")

  puts '== The human captions are UNCHANGED (additive only) ====================='
  check(pa['fields'] == ['Metric Button'],
        "the rendered caption is untouched (got #{pa['fields'].inspect})")
  check(pa['targets'].first['name'] == 'Metric Picker',
        "the target caption is untouched (got #{pa['targets'].first['name'].inspect})")

  puts '== The stale roadmap claim is gone ======================================'
  check(!pa['ui_steps'].to_s.include?('on the Sigma UI roadmap'),
        'ui_steps no longer says chart-click-sets-control is "on the Sigma UI roadmap" — ' \
        'it is spec-authorable and runtime-proven')

  puts '== The parameter action is EMITTED ======================================'
  layout = File.join(d, 'layout.json')
  # parse-twb-layout.rb takes positional args (<twb> <out.json>), not
  # --twb/--out flags — matches its own usage banner and the existing correct
  # call sites in test-action-detection-bridge.rb / test-nav-action-emission.rb.
  _, pst = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'), FIXTURE, layout)
  check(pst.success?, 'parse-twb-layout succeeded')

  meta = layout.sub(/\.json$/, '-meta.json')
  # DETERMINISM: the target control ("Metric Picker") is a Tableau parameter
  # with no quick-filter zone and no calc that references it in the fixture —
  # so its auto-generated control would carry an EMPTY filters[] and be turned
  # into named residue by the filters[] guard (constraint 2), making emission
  # conditional on facts of the fixture rather than deterministic. Wire it the
  # same way a real workbook would: inject a synthetic boolean filter-calc
  # ("[Metric Button] = [Metric Picker]") into the parsed meta so
  # param_filter_targets finds it and the auto-emitted control is born with a
  # real, non-empty filters[] — the SAME mechanism (data-scoping wiring,
  # build-charts-from-signals.rb ~:7280) a hand-authored .twb would trigger.
  # This does not touch the shared fixture .twb; only this test's own parsed
  # copy of it.
  meta_data = JSON.parse(File.read(meta))
  meta_data['worksheets']['Metric Buttons']['calculations'] = [
    { 'caption' => 'Metric Filter Calc', 'formula' => '[Metric Button] = [Metric Picker]' }
  ]
  File.write(meta, JSON.generate(meta_data))

  # build-charts-from-signals.rb requires --master-map (abort otherwise) and
  # the Phase 1d dashboard-read gate artifacts (get-workbook.json / views/*.csv
  # / png-read.json) — same fixture setup test-action-detection-bridge.rb and
  # test-nav-action-emission.rb already use for this exact .twb. The
  # 'Metric Button' entry is what makes ActionColumnResolver.resolve return a
  # real, non-nil column NAME instead of falling to residue.
  mmap = File.join(d, 'master-map.json')
  File.write(mmap, JSON.dump(
               '(?i)^Region$'        => { 'id' => 'm-region',        'name' => 'Region' },
               '(?i)^Metric Button$' => { 'id' => 'm-metric-button', 'name' => 'Metric Button' }
             ))
  File.write(File.join(d, 'get-workbook.json'), JSON.dump(
               'views' => { 'view' => [
                 { 'id' => 'v1', 'name' => 'Sales by Region' },
                 { 'id' => 'v2', 'name' => 'Region Detail' },
                 { 'id' => 'v3', 'name' => 'Metric Buttons' },
                 { 'id' => 'v4', 'name' => 'Filter Panel Sheet' }
               ] }
             ))
  Dir.mkdir(File.join(d, 'views'))
  %w[v2 v4].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') }
  # 'Sales by Region' and 'Metric Buttons' both need REAL rows, not empty
  # stubs: neither worksheet's XML carries <rows>/<cols> shelf signals (this is
  # a minimal detection-only fixture), so synthesize_view_from_signals can't
  # reconstruct them from an empty CSV — the zone (and the parameter-action's
  # HOST element) would be dropped before anything exists to hang the action
  # on. 'Metric Buttons' header 'Metric Button' is the resolved column the
  # parameter action's clicked mark must bind to.
  File.write(File.join(d, 'views', 'v1.csv'), "Region,Profit Ratio\nWest,0.42\n")
  File.write(File.join(d, 'views', 'v3.csv'), "Metric Button,Metric Count\nSales,5\n")
  File.write(File.join(d, 'png-read.json'), JSON.dump(
               'source_png' => 'views/v1.png',
               'tiles' => [
                 { 'title' => 'Sales by Region',    'kind' => 'bar-chart', 'orientation' => 'vertical' },
                 { 'title' => 'Region Detail',      'kind' => 'table' },
                 { 'title' => 'Metric Buttons',     'kind' => 'scatter-chart' },
                 { 'title' => 'Filter Panel Sheet', 'kind' => 'table' }
               ],
               'text_elements' => [], 'filter_shelf' => []
             ))

  charts = File.join(d, 'chart-specs.json')
  blog, bst = Open3.capture2e(RUBY, File.join(DIR, 'build-charts-from-signals.rb'),
                              '--tableau-dir', d, '--layout', layout, '--meta', meta,
                              '--master-map', mmap, '--master-element-id', 'master',
                              '--page-per-dashboard', '--auto-controls',
                              '--detected-actions', detected,
                              '--out', charts)
  check(bst.success?, 'the chart build succeeded' + (bst.success? ? '' : " (log:\n#{blog})"))

  emitted = JSON.parse(File.read(charts.sub(/\.json$/, '-actions-emitted.json')))
  pas = emitted.select { |e| e.dig('source', 'kind') == 'parameter-action' }
  spec = JSON.parse(File.read(charts))

  # DETERMINISTIC by design (Correction 2): the fixture above always resolves
  # the source column AND wires the target control's filters[], so emission is
  # never optional here — a residue fallback would hide a real regression.
  #
  # On failure, name the reason from the REAL build log (`blog`, captured
  # above via Open3.capture2e — stdout+stderr merged), not from `spec`:
  # build-charts-from-signals.rb never writes a `warnings` key into the
  # output JSON (warnings only ever go to stderr via `warn`, :8960-8962) — a
  # `spec['warnings']` read is always nil and always prints an empty array,
  # which is exactly the silent-drop failure mode this whole feature exists
  # to avoid. Every one of the six parameter-action rejection paths' messages
  # starts with "parameter-action '<caption>'" (build-charts-from-signals.rb
  # :7909, :7915, :7921, :7929, :7946, :7951), so grepping the log for that
  # substring surfaces the actual named-residue reason.
  check(pas.length == 1, "exactly one parameter-action was emitted (got #{pas.length})" +
        (pas.empty? ? " — build log's parameter-action line(s): " \
                       "#{blog.lines.grep(/parameter-action/).map(&:strip).inspect}" : ''))

  pa_entry = pas.first
  if pa_entry
    eff = pa_entry['effects'].first
    check(pa_entry['trigger'] == 'on-select', "trigger is on-select (got #{pa_entry['trigger'].inspect})")
    check(eff['effect'] == 'set-control-value', 'the effect is set-control-value')
    check(eff.dig('value', 'type') == 'column', 'the value binds to the clicked column')
    # The design's VERIFIED SIGMA SHAPES section pins
    # `value: {type: "column", columnId: <columnId>}` — a columnId, NOT a bare
    # column name. (The key itself was `column` before the 2026-08-26 action
    # field rename; the bare `column` key is now rejected by the API.) The id is the HOST element's own column id, which is what
    # makes the binding real: a name that no column of the clicked element
    # carries would set the control to nothing (or to the wrong thing).
    check(eff.dig('value', 'columnId') == 'x-el-metric-buttons',
          "the value binds to the HOST element's columnId, not a bare name " \
          "(got #{eff.dig('value', 'columnId').inspect})")
    check(!eff['control'].to_s.empty?, 'the effect names a control')

    puts '== HOST-COLUMN BINDING: value.columnId is a column OF THE HOST ==========='
    host_el_spec = spec['pages'].flat_map { |p| p['elements'] || [] }
                     .find { |e| e['id'] == pa_entry['hostElementId'] }
    check(!host_el_spec.nil?,
          "the manifest's hostElementId #{pa_entry['hostElementId'].inspect} names a real posted element")
    host_col = host_el_spec && Array(host_el_spec['columns']).find { |c| c['id'] == eff.dig('value', 'columnId') }
    check(!host_col.nil?,
          "value.columnId #{eff.dig('value', 'columnId').inspect} is an id carried by the HOST element " \
          "(host columns: #{host_el_spec ? Array(host_el_spec['columns']).map { |c| c['id'] }.inspect : 'n/a'})")
    check(host_col && host_col['name'] == 'Metric Button',
          "that host column is the one the Tableau source-field resolved to, 'Metric Button' " \
          "(got #{host_col && host_col['name'].inspect})")

    puts '== TRAP 2: control is a controlId, NOT an element id ===================='
    all_element_ids = []
    walk = lambda do |n|
      case n
      when Hash
        all_element_ids << n['id'] if n['id'] && n['kind']
        n.each_value { |v| walk.call(v) }
      when Array then n.each { |v| walk.call(v) }
      end
    end
    walk.call(spec)
    check(!all_element_ids.include?(eff['control']),
          "effects[0].control #{eff['control'].inspect} is NOT an element id — " \
          '/verify accepts the wrong form; the live create rejects it')

    puts '== TRAP 3: the target control MUST carry filters[] ======================'
    controls = []
    cwalk = lambda do |n|
      case n
      when Hash
        controls << n if n['controlId']
        n.each_value { |v| cwalk.call(v) }
      when Array then n.each { |v| cwalk.call(v) }
      end
    end
    cwalk.call(spec)
    target_ctl = controls.find { |c| c['controlId'] == eff['control'] }
    check(!target_ctl.nil?,
          "the referenced controlId #{eff['control'].inspect} exists in the spec")
    check(target_ctl && !Array(target_ctl['filters']).empty?,
          'the target control carries a non-empty filters[] — without it the effect ' \
          'is a SILENT no-op (there is no direct chart->chart filter in Sigma)')
  end

  puts '== Conservation: nothing vanished ======================================='
  detected_count = entries.length
  emitted_keys = emitted.map { |e| [e.dig('source', 'kind'), e.dig('source', 'actionName')] }
  check(emitted_keys.uniq.length == emitted_keys.length,
        'no two emitted entries share an identity key')
  check(emitted.length <= detected_count,
        "emitted (#{emitted.length}) never exceeds detected (#{detected_count})")
end

# ---------------------------------------------------------------------------
# Stage the Phase-1d gate artifacts every build in this file needs. Factored
# out because the two regression blocks below need the SAME four-view fixture
# the main block builds by hand, and a third verbatim copy of it would be the
# thing that drifts.
# ---------------------------------------------------------------------------
def stage_fixture(d, mmap_entries, tiles: nil)
  File.write(File.join(d, 'get-workbook.json'), JSON.dump(
               'views' => { 'view' => [
                 { 'id' => 'v1', 'name' => 'Sales by Region' },
                 { 'id' => 'v2', 'name' => 'Region Detail' },
                 { 'id' => 'v3', 'name' => 'Metric Buttons' },
                 { 'id' => 'v4', 'name' => 'Filter Panel Sheet' },
                 { 'id' => 'v5', 'name' => 'Metric  Buttons' }
               ] }
             ))
  Dir.mkdir(File.join(d, 'views'))
  %w[v2 v4].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') }
  File.write(File.join(d, 'views', 'v1.csv'), "Region,Profit Ratio\nWest,0.42\n")
  File.write(File.join(d, 'views', 'v3.csv'), "Metric Button,Metric Count\nSales,5\n")
  File.write(File.join(d, 'views', 'v5.csv'), "Metric Button,Metric Count\nProfit,7\n")
  File.write(File.join(d, 'png-read.json'), JSON.dump(
               'source_png' => 'views/v1.png',
               'tiles' => tiles || [
                 { 'title' => 'Sales by Region',    'kind' => 'bar-chart', 'orientation' => 'vertical' },
                 { 'title' => 'Region Detail',      'kind' => 'table' },
                 { 'title' => 'Metric Buttons',     'kind' => 'scatter-chart' },
                 { 'title' => 'Filter Panel Sheet', 'kind' => 'table' }
               ],
               'text_elements' => [], 'filter_shelf' => []
             ))
  mmap = File.join(d, 'master-map.json')
  File.write(mmap, JSON.dump(mmap_entries))
  mmap
end

# The synthetic boolean filter-calc that gives the "Metric Picker" parameter
# control a real, non-empty filters[] — see the main block's comment for why
# this is the honest way to make emission deterministic instead of
# fixture-dependent.
def wire_metric_picker_filters!(meta_path)
  meta_data = JSON.parse(File.read(meta_path))
  meta_data['worksheets']['Metric Buttons']['calculations'] = [
    { 'caption' => 'Metric Filter Calc', 'formula' => '[Metric Button] = [Metric Picker]' }
  ]
  File.write(meta_path, JSON.generate(meta_data))
end

puts
puts '== HOST-COLUMN BINDING: a field the HOST does not carry is NAMED RESIDUE =='
puts '   (build-charts-from-signals.rb parameter-action block — the third'
puts '   documented hard constraint. `mmap` is workbook-GLOBAL; {type:"column"}'
puts '   is per-element, so a globally-resolvable field that is not on the'
puts '   clicked chart binds to nothing and sets the control to the wrong'
puts '   value through a schema-valid action every gate passes.)'
Dir.mktmpdir do |d3|
  layout3 = File.join(d3, 'layout.json')
  plog3, pst3 = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'), FIXTURE, layout3)
  check(pst3.success?, "setup: parse-twb-layout succeeded (log:\n#{plog3})")
  meta3 = layout3.sub(/\.json$/, '-meta.json')
  wire_metric_picker_filters!(meta3)

  # [Order ID] IS in the master map (so ActionColumnResolver.resolve returns a
  # real, non-nil column NAME — this is NOT the resolver-nil path) but the host
  # worksheet 'Sales by Region' emits only Region / Profit Ratio / Region Not
  # Null. Exactly the case proven to ship a wrong binding before the guard.
  mmap3 = stage_fixture(d3,
                        { '(?i)^Region$'        => { 'id' => 'm-region',        'name' => 'Region' },
                          '(?i)^Order ID$'      => { 'id' => 'm-orderid',       'name' => 'Order ID' },
                          '(?i)^Metric Button$' => { 'id' => 'm-metric-button', 'name' => 'Metric Button' } })

  detected3 = File.join(d3, 'detected-actions.json')
  File.write(detected3, JSON.generate([
    { 'kind' => 'parameter-action', 'caption' => 'Pick By Order',
      'source' => { 'dashboard' => 'Overview', 'worksheets' => ['Sales by Region'] },
      'trigger' => 'on select',
      'targets' => [{ 'name' => 'Metric Picker' }],
      'sourceFieldRef' => '[federated.f1].[Order ID]',
      'targetParameterRef' => '[Parameters].[Parameter 1]',
      'actionName' => '[Action90_OFFHOST]' }
  ]))

  charts3 = File.join(d3, 'chart-specs.json')
  blog3, bst3 = Open3.capture2e(RUBY, File.join(DIR, 'build-charts-from-signals.rb'),
                                '--tableau-dir', d3, '--layout', layout3, '--meta', meta3,
                                '--master-map', mmap3, '--master-element-id', 'master',
                                '--page-per-dashboard', '--auto-controls',
                                '--detected-actions', detected3,
                                '--out', charts3)
  check(bst3.success?, 'the off-host chart build succeeded' + (bst3.success? ? '' : " (log:\n#{blog3})"))

  if bst3.success?
    manifest3 = JSON.parse(File.read(charts3.sub(/\.json$/, '-actions-emitted.json')))
    check(manifest3.none? { |e| e.dig('source', 'kind') == 'parameter-action' },
          'the off-host parameter-action was NOT emitted — a guessed column ships a schema-valid ' \
          "action that silently sets the control wrong (manifest: #{manifest3.map { |e| e.dig('source', 'caption') }.inspect})")

    residue_line = blog3.lines.grep(/parameter-action 'Pick By Order'/).map(&:strip)
    check(residue_line.any?, 'the rejection is NAMED in the build log, never silent ' \
                             "(parameter-action lines: #{blog3.lines.grep(/parameter-action/).map(&:strip).inspect})")
    joined3 = residue_line.join(' ')
    check(joined3.include?('(named residue)'),
          "the reason uses the house '(named residue)' phrasing (got #{joined3.inspect})")
    check(joined3.include?('NOT a column of its host element'),
          'the reason names the real cause — the resolved column is not on the host element ' \
          "(got #{joined3.inspect})")
    check(joined3.include?('el-sales-by-region'),
          "the reason names the host element whose columns were checked (got #{joined3.inspect})")

    # No action of ANY kind may have reached the spec for this rejected entry.
    spec3 = JSON.parse(File.read(charts3))
    set_ctl = spec3['pages'].flat_map { |p| p['elements'] || [] }
                .flat_map { |e| Array(e['actions']) }
                .flat_map { |a| Array(a['effects']) }
                .select { |ef| ef['effect'] == 'set-control-value' }
    check(set_ctl.empty?,
          "no set-control-value effect reached the spec either (got #{set_ctl.inspect})")
  end
end

puts
puts '== Cross-kind: two action KINDS on ONE host both survive the rename pass =='
puts '   (emitted_action_index was last-writer-wins across kinds — :6923 nav and'
puts '   :7987 param wrote the SAME [dashboard, host] key, so the second emitter'
puts '   EVICTED the first. The els.map! rename then synced only the survivor and'
puts '   the evicted entry shipped a stale actionId; put-layout.rb:224 looks the'
puts '   manifest up BY actionId, misses, and silently skips the whole'
puts '   navigate.target.page repair — no warning, provisional page id left live.'
puts '   Counts still match, so no gate catches it.)'
Dir.mktmpdir do |d4|
  layout4 = File.join(d4, 'layout.json')
  plog4, pst4 = Open3.capture2e(RUBY, File.join(DIR, 'parse-twb-layout.rb'), FIXTURE, layout4)
  check(pst4.success?, "setup: parse-twb-layout succeeded (log:\n#{plog4})")
  meta4 = layout4.sub(/\.json$/, '-meta.json')
  wire_metric_picker_filters!(meta4)

  # Force the host through the --page-per-dashboard dedup RENAME, the same way
  # test-nav-action-emission.rb's regression block does: element ids are
  # "el-#{caption.downcase.gsub(/\W+/, '-')[0..40]}", so the double-spaced
  # decoy "Metric  Buttons" slugs to the IDENTICAL "el-metric-buttons" while
  # staying a DIFFERENT string for the exact `_worksheet` match emission uses.
  # Decoy on Overview (dash_order[0] — claims the stem, stays unrenamed); the
  # real 'Metric Buttons' zone moves to Detail Page (dash_order[1] — the dedup
  # pass finds the stem claimed and renames it).
  layout_data = JSON.parse(File.read(layout4))
  overview = layout_data.find { |dd| dd['dashboard'] == 'Overview' }
  detail   = layout_data.find { |dd| dd['dashboard'] == 'Detail Page' }
  check(!overview.nil? && !detail.nil?, 'setup: fixture has both Overview and Detail Page dashboards')
  mb_zone = overview && (overview['zones'] || []).find { |z| z['caption'] == 'Metric Buttons' }
  check(!mb_zone.nil?, 'setup: Overview has the Metric Buttons zone to move')
  if mb_zone
    real_zone = JSON.parse(mb_zone.to_json)
    real_zone['id'] = 'zone-real-9101'
    detail['zones'] << real_zone
    mb_zone['caption'] = 'Metric  Buttons'
    mb_zone['name'] = 'Metric  Buttons' if mb_zone.key?('name')
  end
  File.write(layout4, JSON.generate(layout_data))

  mmap4 = stage_fixture(d4,
                        { '(?i)^Region$'        => { 'id' => 'm-region',        'name' => 'Region' },
                          '(?i)^Metric Button$' => { 'id' => 'm-metric-button', 'name' => 'Metric Button' } },
                        tiles: [
                          { 'title' => 'Sales by Region',    'kind' => 'bar-chart', 'orientation' => 'vertical' },
                          { 'title' => 'Region Detail',      'kind' => 'table' },
                          { 'title' => 'Metric Buttons',     'kind' => 'scatter-chart' },
                          { 'title' => 'Metric  Buttons',    'kind' => 'scatter-chart' },
                          { 'title' => 'Filter Panel Sheet', 'kind' => 'table' }
                        ])

  # BOTH kinds sourced from the SAME worksheet — the collision the scalar
  # index could not survive. nav-action is emitted first (block at ~:6871),
  # parameter-action second (~:7903), so the param entry is the one that used
  # to evict the nav entry.
  detected4 = File.join(d4, 'detected-actions.json')
  File.write(detected4, JSON.generate([
    { 'kind' => 'nav-action', 'caption' => 'GoTo Overview (cross-kind)',
      'source' => { 'dashboard' => 'Detail Page', 'worksheets' => ['Metric Buttons'] },
      'trigger' => 'on select',
      'targets' => [{ 'name' => 'Overview', 'dashboard' => true }],
      'actionName' => '[Action91_NAV]' },
    { 'kind' => 'parameter-action', 'caption' => 'Pick Metric (cross-kind)',
      'source' => { 'dashboard' => 'Detail Page', 'worksheets' => ['Metric Buttons'] },
      'trigger' => 'on select',
      'targets' => [{ 'name' => 'Metric Picker' }],
      'sourceFieldRef' => '[federated.f1].[none:Calculation_100:nk]',
      'targetParameterRef' => '[Parameters].[Parameter 1]',
      'actionName' => '[Action92_PARAM]' }
  ]))

  charts4 = File.join(d4, 'chart-specs.json')
  blog4, bst4 = Open3.capture2e(RUBY, File.join(DIR, 'build-charts-from-signals.rb'),
                                '--tableau-dir', d4, '--layout', layout4, '--meta', meta4,
                                '--master-map', mmap4, '--master-element-id', 'master',
                                '--page-per-dashboard', '--auto-controls',
                                '--detected-actions', detected4,
                                '--out', charts4)
  check(bst4.success?, 'the cross-kind chart build succeeded' + (bst4.success? ? '' : " (log:\n#{blog4})"))

  if bst4.success?
    spec4     = JSON.parse(File.read(charts4))
    manifest4 = JSON.parse(File.read(charts4.sub(/\.json$/, '-actions-emitted.json')))
    posted_els = spec4['pages'].flat_map { |p| p['elements'] || [] }

    nav4 = manifest4.find { |e| e.dig('source', 'actionName') == '[Action91_NAV]' }
    par4 = manifest4.find { |e| e.dig('source', 'actionName') == '[Action92_PARAM]' }
    check(!nav4.nil?, 'the nav-action entry SURVIVED in the manifest (it used to be evicted)')
    check(!par4.nil?, 'the parameter-action entry is in the manifest')

    # Sanity: the rename actually happened, otherwise this block proves nothing.
    check(posted_els.any? { |e| e['id'].to_s.start_with?('el-metric-buttons-') },
          'sanity: the host element id stem WAS renamed by collision/dedup handling ' \
          "(posted chart ids: #{posted_els.select { |e| e['id'].to_s.start_with?('el-metric-buttons') }.map { |e| e['id'] }.inspect})")

    [['nav-action', nav4], ['parameter-action', par4]].each do |kind, entry|
      next if entry.nil?
      # put-layout.rb:224's EXACT lookup. A nil here IS the silent-skip bug.
      posted_el = posted_els.find { |e| (e['actions'] || []).any? { |a| a['id'] == entry['actionId'] } }
      check(!posted_el.nil?,
            "#{kind}: manifest actionId #{entry['actionId'].inspect} matches an action actually " \
            'embedded in the POSTED spec (put-layout.rb\'s exact lookup — nil here is the silent skip)')
      check(!posted_el.nil? && posted_el['id'] == entry['hostElementId'],
            "#{kind}: manifest hostElementId (#{entry['hostElementId'].inspect}) matches the posted " \
            "element's actual id (#{posted_el && posted_el['id'].inspect}) after the rename")
    end

    # Both actions live on the SAME host element — that is the whole point.
    check(nav4 && par4 && nav4['hostElementId'] == par4['hostElementId'],
          'both kinds report the same host element ' \
          "(#{nav4 && nav4['hostElementId'].inspect} vs #{par4 && par4['hostElementId'].inspect})")

    # The set-control-value's column id embeds the host stem, so the manifest
    # copy must track the rename too or the readback probe diffs a pre-rename
    # id against the posted one.
    if par4
      posted_par = posted_els.flat_map { |e| Array(e['actions']) }.find { |a| a['id'] == par4['actionId'] }
      check(posted_par && posted_par['effects'] == par4['effects'],
            "parameter-action: the manifest's effects match the POSTED effects byte-for-byte " \
            "(manifest #{par4['effects'].inspect} vs posted #{posted_par && posted_par['effects'].inspect})")
    end
  end
end

puts
if $fails.empty?
  puts 'OK'
else
  puts "FAILED (#{$fails.length}):"
  $fails.each { |f| puts "  - #{f}" }
  exit 1
end
