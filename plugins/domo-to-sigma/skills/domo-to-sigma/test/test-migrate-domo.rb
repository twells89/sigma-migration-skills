#!/usr/bin/env ruby
# End-to-end (offline): migrate-domo.rb's --offline mode against the scrubbed
# synthetic fixture at test/fixtures/domo-estate/ (pages.json + cards.json —
# 2x2 grid geometry: a KPI card and a bar chart share a row at distinct x_pct,
# an image card ("Logo", referencing the synthetic png/cards/img1.png) sits to
# their right, and a table card sits in the row below). Exercises the real
# subprocess entrypoint (like test-e2e.rb / test-build-domo-layout.rb), not
# just individual functions, so this proves the phase chain actually composes:
#   seed discovery -> build-workbook -> build-workbook-spec[offline-local] ->
#   build-domo-layout -> build-dashboard-layout -> put-layout[offline-local]
#
#   ruby test/test-migrate-domo.rb

require 'json'
require 'tmpdir'

SKILL   = File.expand_path('..', __dir__)
SCRIPTS = File.join(SKILL, 'scripts')
FIXTURE = File.join(__dir__, 'fixtures', 'domo-estate')

$failures = 0
def ok(c, m) if c then puts "  ok: #{m}" else $failures += 1; puts "  FAIL: #{m}" end end
def eq(actual, expected, msg)
  if actual == expected
    puts "  ok: #{msg}"
  else
    $failures += 1
    puts "  FAIL: #{msg}\n        expected #{expected.inspect}\n        got      #{actual.inspect}"
  end
end

# Sanity: the fixture itself must actually carry a KPI card, an image card
# referencing the synthetic logo, and multi-column (not single-column) x
# geometry — otherwise the assertions below would be vacuous.
cards = JSON.parse(File.read(File.join(FIXTURE, 'cards.json')))
ok(cards.any? { |c| c['sigmaKindHint'] == 'kpi-chart' }, 'sanity: fixture cards.json includes a KPI card')
ok(cards.any? { |c| c['chartType'].to_s == 'image' }, 'sanity: fixture cards.json includes an image card')
ok(File.exist?(File.join(FIXTURE, 'png', 'cards', 'img1.png')), 'sanity: fixture stages png/cards/img1.png for the image card')
ok(cards.map { |c| c['x'] }.uniq.size >= 3, 'sanity: fixture geometry spans >= 3 distinct x values (a real 2D layout, not a stack)')

Dir.mktmpdir('migrate-domo-e2e') do |out_dir|
  cmd = ['ruby', File.join(SCRIPTS, 'migrate-domo.rb'), '--offline', FIXTURE, '--out', out_dir]
  output = IO.popen(cmd, err: [:child, :out], &:read)
  status = $?.success?
  ok(status, "migrate-domo.rb --offline exits 0\n#{output unless status}")

  # ---- run-state.json: every named phase accounted for (done or skip, never
  # silently missing) ----------------------------------------------------
  run_state_path = File.join(out_dir, 'run-state.json')
  ok(File.exist?(run_state_path), 'wrote run-state.json')
  run_state = JSON.parse(File.read(run_state_path))
  required_phases = %w[discover capture-visuals convert-beast-modes build-workbook
                       build-workbook-spec post-and-readback build-domo-layout
                       build-dashboard-layout put-layout layout-2d-flag
                       verify-parity assert-phase6-ran]
  missing = required_phases.reject { |p| run_state['phases'].key?(p) }
  ok(missing.empty?, "run-state.json accounts for every phase in the chain (missing: #{missing.join(', ')})")
  eq(run_state['mode'], 'offline', 'run-state.json records mode=offline')

  # ---- (a) layout-2d.flag == 'grid' (NOT 'stack') ------------------------
  flag_path = File.join(out_dir, 'layout-2d.flag')
  ok(File.exist?(flag_path), 'wrote layout-2d.flag')
  flag = File.read(flag_path).strip
  eq(flag, 'grid', "layout-2d.flag is 'grid' (fixture has >= 2 zones at distinct x within a row) — NOT 'stack'")

  # ---- workbook-spec.json assembled with the layout merged in ------------
  spec_path = File.join(out_dir, 'workbook-spec.json')
  ok(File.exist?(spec_path), 'wrote workbook-spec.json')
  spec = JSON.parse(File.read(spec_path))
  all_elements = spec['pages'].flat_map { |p| p['elements'] || [] }
  ok(spec['layout'].is_a?(String) && spec['layout'].include?('<Page'), 'workbook-spec.json has a merged <Page> layout XML (put-layout offline step ran)')

  # ---- (b) an inline data-URI image element ------------------------------
  image_el = all_elements.find { |e| e['kind'] == 'image' }
  ok(image_el, 'workbook-spec.json contains an image-kind element')
  if image_el
    ok(image_el['url'].to_s.start_with?('data:image/png;base64,'),
       "image element's url is an inline data-URI (data:image/png;base64,...), got #{image_el['url'].to_s[0, 40].inspect}")
    b64 = image_el['url'].to_s.sub('data:image/png;base64,', '')
    ok(!b64.strip.empty?, 'image data-URI carries non-empty base64 payload')
  end

  # ---- (c) the KPI element's formula is <Agg>([Master/...]) -------------
  kpi_el = all_elements.find { |e| e['kind'] == 'kpi-chart' }
  ok(kpi_el, 'workbook-spec.json contains a kpi-chart element')
  if kpi_el
    formula = kpi_el.dig('columns', 0, 'formula').to_s
    ok(formula =~ /\A(Sum|Avg|Count|CountDistinct|Min|Max)\(\[Master\/[^\]]+\]\)\z/,
       "KPI formula is <Agg>([Master/...]) — got #{formula.inspect}")
    ok(kpi_el.dig('value', 'columnId') == kpi_el.dig('columns', 0, 'id'), 'KPI value binds via value.columnId (not id)')
  end

  # ---- idempotency: a second run with no --force is a no-op (all skip) --
  cmd2 = ['ruby', File.join(SCRIPTS, 'migrate-domo.rb'), '--offline', FIXTURE, '--out', out_dir]
  output2 = IO.popen(cmd2, err: [:child, :out], &:read)
  ok($?.success?, "re-run without --force exits 0\n#{output2 unless $?.success?}")
  rerun_state = JSON.parse(File.read(run_state_path))
  built_phases = %w[build-workbook build-workbook-spec build-domo-layout build-dashboard-layout put-layout]
  ok(built_phases.all? { |p| rerun_state['phases'][p]['status'] == 'skip' },
     'idempotent re-run (no --force) skips every previously-built phase')

  # ---- --force rebuilds (still lands on the same, deterministic flag) ---
  cmd3 = ['ruby', File.join(SCRIPTS, 'migrate-domo.rb'), '--offline', FIXTURE, '--out', out_dir, '--force']
  output3 = IO.popen(cmd3, err: [:child, :out], &:read)
  ok($?.success?, "--force re-run exits 0\n#{output3 unless $?.success?}")
  forced_state = JSON.parse(File.read(run_state_path))
  ok(built_phases.all? { |p| forced_state['phases'][p]['status'] == 'done' }, '--force rebuilds every phase (status done, not skip)')
  eq(File.read(flag_path).strip, 'grid', '--force re-run recomputes the same grid flag')
end

# ---- fail-fast: a fixture missing cards.json aborts loudly, non-zero ------
Dir.mktmpdir('migrate-domo-badfixture') do |bad_fixture|
  Dir.mktmpdir('migrate-domo-badout') do |out_dir|
    File.write(File.join(bad_fixture, 'pages.json'), '[]') # cards.json deliberately absent
    cmd = ['ruby', File.join(SCRIPTS, 'migrate-domo.rb'), '--offline', bad_fixture, '--out', out_dir]
    output = IO.popen(cmd, err: [:child, :out], &:read)
    ok(!$?.success?, 'a fixture missing cards.json fails fast (non-zero exit), not a silent partial run')
    ok(output.include?('cards.json'), 'the failure message names the missing file')
  end
end

puts
if $failures.zero? then puts "ALL PASS"; exit 0 else puts "#{$failures} FAILURE(S)"; exit 1 end
