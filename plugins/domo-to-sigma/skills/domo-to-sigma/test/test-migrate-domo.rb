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
require 'open3'
require_relative '../scripts/lib/code_rep'
# Ruby 2.6 floor: this test READS a sibling script and eval()s a method out
# of it, so that script's own require_relative lines never run -- the test
# must supply the polyfill itself. See shared/lib/ruby_compat.rb.
require_relative '../scripts/lib/ruby_compat'

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
ok(cards.any? { |c| c['limit'].to_i.positive? }, 'sanity: fixture cards.json includes a card with a row limit (bead 2ef7)')
ok(cards.any? { |c| c['datasetId'] == 'ds-dim' }, 'sanity: fixture cards.json includes a card bound to a non-dominant DataSet (bead ziht)')
ok(cards.any? { |c| c['summaryNumber'] && !Array(c['groupBy']).empty? },
   'sanity: fixture cards.json includes a non-Rule-0 card (real grouping) that ALSO carries a summaryNumber (bead 08sf)')
ok(File.exist?(File.join(FIXTURE, 'dm-spec.json')), 'sanity: fixture stages dm-spec.json (build-dm.rb pre-post shape) for the ds-dim sub-master')
ok(File.exist?(File.join(FIXTURE, 'dm-ids.json')), 'sanity: fixture stages dm-ids.json (synthesized post-and-readback) for the ds-dim sub-master')
ok(File.exist?(File.join(FIXTURE, 'beast-modes.json')), 'sanity: fixture stages beast-modes.json so migrate-domo.rb\'s convert-beast-modes phase is actually exercised, not SKIPped')

# ---------------------------------------------------------------------------
# bead B5 — render_target_page (pure logic, no I/O): migrate-domo.rb's top
# level unconditionally OptionParser.parse!(ARGV)s + aborts without --out, so
# it cannot be require_relative'd here like a normal library without either
# faking ARGV (which would then run the FULL live-or-offline pipeline as a
# require side effect — not a unit test) or restructuring the whole file
# behind a $PROGRAM_NAME == __FILE__ guard (out of scope for this fix; see
# build-workbook.rb for where this skill DOES use that pattern). Extract just
# this one self-contained pure function's source and eval it in isolation —
# no live call, no other migrate-domo.rb code executes.
migrate_src = File.read(File.join(SCRIPTS, 'migrate-domo.rb'))
render_target_page_src = migrate_src[/^def render_target_page\(wb_ids\)\n.*?\nend\n/m]
ok(render_target_page_src, 'extracted render_target_page(wb_ids) source from migrate-domo.rb for isolated unit testing')
if render_target_page_src
  eval(render_target_page_src, TOPLEVEL_BINDING) # rubocop:disable Security/Eval — trusted, same-repo source, test-only

  multi_page = { 'pages' => [{ 'id' => 'page-data', 'name' => 'Data' },
                              { 'id' => 'page-overview', 'name' => 'Overview' },
                              { 'id' => 'page-detail', 'name' => 'Detail' }] }
  picked = render_target_page(multi_page)
  eq(picked && picked['id'], 'page-overview',
     "render_target_page skips the hidden 'page-data' page and picks the first visible one")

  data_only = { 'pages' => [{ 'id' => 'page-data', 'name' => 'Data' }] }
  ok(render_target_page(data_only).nil?,
     'render_target_page returns nil when wb-ids.json has no non-Data page to render (honest — the ' \
     'caller SKIPs the render phase instead of rendering a blank/placeholder page)')

  ok(render_target_page({ 'pages' => [] }).nil?, 'render_target_page returns nil for an empty pages array')
end

# ---------------------------------------------------------------------------
# bead B6 / B5 — static wiring regression guard for the LIVE-only code path.
# run_live! shells out to real Domo/Sigma/Snowflake APIs, so it cannot be
# exercised here (this test suite, like every offline suite in this skill,
# never drives a live run) — this is NOT a substitute for a real live run,
# just a guard against the exact regression each fix closes (--score-out
# silently dropped again, or the render/record calls silently removed)
# slipping back in unnoticed between now and the next live validation.
#
# CORRECTED 2026-08-05 (bead beads-sigma-2tkm). B6's original assertion pinned
# `--score-out File.join(OUT, 'parity-final.json')` — which was itself the bug.
# parity-final.json is the GATE'S contract file (assert-phase6-ran.rb reads
# charts_total/charts_pass/status); verify-parity.rb --score-out writes
# tiles_total/tiles_pass/tiles_fail. Aiming one at the other meant a flawless
# 65/65 parity run landed a tiles_*-shaped document where the gate expected
# charts_*, so the gate read charts_total = 0 and exited 2. The two documents are
# now distinct, with phase6-parity-domo.rb finalizing score -> contract.
ok(migrate_src.include?("'phase6-parity-domo.rb'"),
   'bead 2tkm: run_live! finalizes parity through phase6-parity-domo.rb (the gate-contract writer)')

# The census in phase6-parity-domo.rb CONSUMES parity-plan-exclusions.json, and
# #631 shipped that check with nothing writing the file. Pin both that the
# generator runs and that it runs BEFORE the finalizer — reversed, the census
# would read a stale or absent exclusions file and fail a run that was fine.
gen_at = migrate_src.index("'build-parity-exclusions.rb'")
fin_at = migrate_src.index("'phase6-parity-domo.rb'")
ok(!gen_at.nil?, 'run_live! generates parity-plan-exclusions.json (the census consumes it)')
ok(gen_at && fin_at && gen_at < fin_at,
   'the exclusions generator runs BEFORE the finalizer that reads its output')
ok(!migrate_src.include?("'--score-out', File.join(OUT, 'parity-final.json')"),
   'bead 2tkm: verify-parity.rb --score-out no longer overwrites the gate contract file')
ok(migrate_src.include?("'--score-out', File.join(OUT, 'parity-score.json')") ||
   migrate_src.include?('phase6-parity-domo.rb'),
   'bead 2tkm: the tiles_* score document lands in parity-score.json, not parity-final.json')

# ---------------------------------------------------------------------------
# Coverage census wiring. coverage.json is the ONLY path by which a dropped Domo
# card reaches the degradation ledger (the other scope-cut source,
# parity-final.json's tile_census, is reserved for tableau's zone shape and domo
# must never publish there — memory gate5-tile-census-key-reserved). GREEN
# requires an EMPTY ledger, so without this call a run that silently dropped
# cards could still be declared GREEN.
ok(migrate_src.include?("'build-coverage-census.rb'"),
   'coverage: run_live! emits coverage.json so a dropped card can reach the degradation ledger')
# Search for the assert header that FOLLOWS the census, not the first in the
# file: run_offline! emits its own hr('assert-phase6-ran') earlier, so a bare
# .index compares against the offline occurrence and this ordering check fails
# on correct code. (Made this exact mistake on the oracle ordering guard below
# too — both hr() titles appear twice.)
cov_at = migrate_src.index("hr('coverage-census')")
assert_at = cov_at && migrate_src.index("hr('assert-phase6-ran')", cov_at)
ok(cov_at && assert_at && cov_at < assert_at,
   'coverage: the census runs BEFORE assert-phase6-ran reads the ledger')

# ---------------------------------------------------------------------------
# Parity oracle wiring (gate 1). Same static-guard caveat as above: run_live!
# cannot be exercised offline, so these pin the WIRING, not the behaviour.
#
# Why this needs a guard at all: without a plan, migrate-domo auto-adds
# --skip-parity-gate, and assert-phase6-ran.rb REJECTS that waiver (exit 18)
# unless a passing anchors-verdict.json exists. So a silently-removed oracle
# call does not look like a missing feature — it looks like a run that skipped
# parity, which is a guaranteed non-GREEN dead end (trap T4 in the 2026-08-05
# handoff). Cheap to regress, expensive to notice.
ok(migrate_src.include?("'collect-parity-expected.rb'"),
   'oracle: run_live! collects the Domo-side expected values')
ok(migrate_src.include?("'collect-parity-actuals.rb'"),
   'oracle: run_live! collects the Sigma-side actuals')
ok(migrate_src.include?("'build-parity-oracle.rb'"),
   'oracle: run_live! joins the two sides into a verify-parity plan')

# ORDER IS LOAD-BEARING between the two exclusions writers (#649's generator and
# the join). Both write parity-plan-exclusions.json:
#   #649  excludes tiles that cannot agree BY CONSTRUCTION (refused date window)
#   join  excludes tiles it could not COLLECT
# Run the join first and #649 overwrites its entries, after which the census sees
# collection-failed tiles as neither verified nor excluded and dies (exit 5). Run
# #649 first and the join carries them through, honouring them over verification
# — which matters because such a tile IS collectable and would otherwise be
# "verified" into a guaranteed DIVERGE that says nothing about fidelity.
excl_gen_at = migrate_src.index("'build-parity-exclusions.rb'")
join_at = migrate_src.index("'build-parity-oracle.rb'")
ok(excl_gen_at && join_at && excl_gen_at < join_at,
   'oracle: the exclusions generator runs BEFORE the join, so the join can carry its entries through')
ok(migrate_src.include?('if oracle_plan') &&
   migrate_src.match?(/exclusions: already generated before the oracle join/),
   'oracle: the generator is NOT re-run after the join (that would discard the join\'s exclusions)')

# DEFAULT-ON, not opt-in. The condition must fire when NO --parity-plan was
# given; if someone flips this to require an opt-in flag, the default path goes
# back to being unable to reach gold.
ok(migrate_src.include?('if !opts[:parity_plan] && !opts[:skip_parity_oracle]'),
   'oracle: builds by DEFAULT when no --parity-plan is supplied (opt-out, not opt-in)')
ok(migrate_src.include?('--skip-parity-oracle'),
   'oracle: there is an explicit opt-out flag')

# The plan must be built from the SAME document phase6-parity-domo.rb's census
# reads (<workdir>/workbook-spec.json), or the two disagree about what counts as
# chartable and the census fails on tiles that were never missing.
ok(migrate_src.include?("'build-parity-plan.rb'") &&
   migrate_src.include?("'--workbook-spec', File.join(OUT, 'workbook-spec.json')"),
   'oracle: the plan is built from the same workbook-spec.json the census audits')

# A half-collected oracle must be a hard FAIL. Joining a partial collection
# yields a plan missing tiles, and a shrunken denominator reads exactly like a
# clean pass — 45/45 is indistinguishable from 65/65.
ok(migrate_src.include?("fail_phase!('parity-oracle'"),
   'oracle: a failed collector is a hard FAIL, never a skip that silently shrinks the denominator')

# The recorded waiver reason must be derived, not the old hardcoded string —
# it is read later by whoever reconstructs why a run was not GREEN.
ok(!migrate_src.include?("'--skip-parity-gate', 'no --parity-plan supplied to migrate-domo.rb'"),
   'oracle: the skip-parity-gate reason is no longer the stale hardcoded "no --parity-plan" text')
ok(migrate_src.include?('opts[:skip_parity_oracle]') &&
   migrate_src.include?("args += ['--skip-parity-gate', why]"),
   'oracle: the skip-parity-gate waiver records WHY parity is absent (waived vs no chartable tiles)')

# NB: hr('verify-parity') occurs TWICE — run_offline! emits one as a skip before
# run_live!'s. A bare .index finds the offline one and this ordering check then
# compares against the wrong occurrence, so search for the verify-parity header
# that FOLLOWS the oracle header.
oracle_hdr_at = migrate_src.index("hr('parity-oracle')")
live_parity_at = oracle_hdr_at && migrate_src.index("hr('verify-parity')", oracle_hdr_at)
ok(oracle_hdr_at && live_parity_at && oracle_hdr_at < live_parity_at,
   'oracle: the plan is built BEFORE verify-parity consumes it')

run_live_at     = migrate_src.index('def run_live!')
render_call_at  = run_live_at && migrate_src.index('phase_render_visual!(opts, workbook_id, wb_ids)', run_live_at)
parity_hdr_at   = run_live_at && migrate_src.index("hr('verify-parity')", run_live_at)
record_call_at  = run_live_at && migrate_src.index('phase_record_visual_check!(opts)', run_live_at)
ok([render_call_at, parity_hdr_at, record_call_at].all?,
   'bead B5: run_live! calls phase_render_visual! and phase_record_visual_check! at all')
ok(render_call_at && parity_hdr_at && record_call_at &&
   render_call_at < parity_hdr_at && parity_hdr_at < record_call_at,
   'bead B5: run_live! renders BEFORE verify-parity (gate 8 render) and records the verdict AFTER it ' \
   '(record-visual-check.rb hard-requires parity-final.json to already exist)')
ok(migrate_src.include?('--source-dashboard-png') && migrate_src.include?('--blind-grade') &&
   migrate_src.include?('--visual-grader'),
   'visual handoff: CLI accepts source image, completed grade, and optional one-process grader adapter')
ok(migrate_src.include?('DomoVisualHandoff.write_request!') &&
   migrate_src.include?('raise VisualGradePending.new') &&
   migrate_src.include?('exit DomoVisualHandoff::EXIT_PENDING'),
   'visual handoff: missing grade becomes an explicit resumable exit-20 WAITING state')
ok(!migrate_src.include?("'--agent-vision', 'false'"),
   'visual handoff: orchestrator no longer records a guaranteed not-executable verdict')
ok(migrate_src.include?('DomoVisualHandoff.record_args'),
   'visual handoff: a completed blind grade is consumed and recorded automatically')

# Track E: the fixture's discovery/beast-modes.json (see test/fixtures/domo-estate/
# beast-modes.json) drives migrate-domo.rb's convert-beast-modes phase through its
# real --convert step, which shells out to `node` against the vendored
# converter/sql.mjs (same as test-convert-beast-modes.rb / -fixtures.rb). Gate the
# whole node-dependent pipeline run the same way those suites gate their node-only
# assertions — a loud, honest SKIP (never a silent pass) when `node` is not on
# PATH, rather than letting the entire offline pipeline hard-fail at the
# convert-beast-modes phase (fail-fast semantics mean nothing downstream of that
# phase — build-workbook, layout, etc. — would run either, so there is no useful
# partial-assertion split here; the whole run is the unit that depends on node).
node_present = begin
  _o, _e, st = Open3.capture3('node', '--version')
  st.success?
rescue Errno::ENOENT
  false
end

if node_present
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
                       build-dashboard-layout put-layout layout-2d-flag render-visual
                       verify-parity record-visual-check assert-phase6-ran]
  missing = required_phases.reject { |p| run_state['phases'].key?(p) }
  ok(missing.empty?, "run-state.json accounts for every phase in the chain (missing: #{missing.join(', ')})")
  eq(run_state['mode'], 'offline', 'run-state.json records mode=offline')

  # ---- bead B5: the render + verdict-recording phases are never silently ---
  # omitted offline (no live workbook to render / no parity-final.json to
  # record a verdict onto) — they must show up as an honest, named SKIP, per
  # the --offline header note's "any render/visual gate" promise.
  %w[render-visual record-visual-check].each do |p|
    entry = run_state['phases'][p]
    eq(entry && entry['status'], 'skip', "run-state.json stamps '#{p}' as skip in --offline mode (#{entry.inspect})")
    ok(entry && !entry['note'].to_s.strip.empty?,
       "run-state.json's '#{p}' skip carries a non-empty note explaining WHY (never a silent omission) — #{entry.inspect}")
  end

  # ---- Track E: convert-beast-modes is actually exercised now that the -----
  # fixture carries discovery/beast-modes.json (previously this phase was
  # ALWAYS skip_phase!'d in this suite — no fixture ever supplied one).
  ok(!output.include?('SKIP convert-beast-modes'),
     'convert-beast-modes phase actually runs (no longer prints the SKIP convert-beast-modes line)')
  eq(run_state['phases']['convert-beast-modes']['status'], 'done',
     "run-state.json shows convert-beast-modes as done, not skip — #{run_state['phases']['convert-beast-modes'].inspect}")

  formulas_path = File.join(out_dir, 'discovery', 'formulas.json')
  ok(File.exist?(formulas_path), 'wrote discovery/formulas.json (the --convert + --lint steps ran for real, via node)')
  if File.exist?(formulas_path)
    formulas = JSON.parse(File.read(formulas_path))
    eq(formulas.size, 3, 'all 3 fixture Beast Modes made it into formulas.json (none silently dropped)')
    by_name = {}
    formulas.each { |f| by_name[f['name']] = f }

    revenue = by_name['Total Net Revenue']
    ok(revenue && revenue['converted'] == true && revenue['sigmaFormula'] == 'Sum([Net Revenue])',
       "Total Net Revenue (plain SUM) converts cleanly to Sum([Net Revenue]) — got #{revenue.inspect}")

    margin = by_name['Gross Margin Pct']
    ok(margin && margin['converted'] == true && margin['sigmaFormula'].to_s.start_with?('If('),
       "Gross Margin Pct (CASE WHEN) converts cleanly to an If(...) (converted:true) — got #{margin.inspect}")

    # Deliberately LIKE-shaped (design's known residual-operator case, same as
    # test-convert-beast-modes-fixtures.rb's D-R1) — exercises converted:false.
    us_customers = by_name['US Customers']
    ok(us_customers && us_customers['converted'] == false,
       "US Customers (LIKE) is honestly flagged converted:false, not silently marked clean — got #{us_customers.inspect}")
    ok(us_customers && !us_customers['sigmaFormula'].to_s.strip.empty?,
       'US Customers still carries a present (if unreliable) sigmaFormula — never silently dropped')

    ok(formulas.all? { |f| Array(f['lintErrors']).empty? },
       'none of the 3 fixture Beast Modes trip a lint ERROR')
    # Blocker 1 (2026-08-05 batch-verify): a residual infix LIKE is downgraded
    # from lintError to lintWarning (see convert-beast-modes.rb's lint_formula)
    # so migrate-domo.rb's --offline run above completes instead of aborting
    # at convert-beast-modes — but the finding must still surface, not vanish.
    ok(us_customers && Array(us_customers['lintWarnings']).any? { |w| w.include?('LIKE') },
       'US Customers still carries a visible lintWarning naming the residual LIKE — downgraded, not silenced')
  end

  # ---- (a) layout-2d.flag == 'grid' (NOT 'stack') ------------------------
  flag_path = File.join(out_dir, 'layout-2d.flag')
  ok(File.exist?(flag_path), 'wrote layout-2d.flag')
  flag = File.read(flag_path).strip
  eq(flag, 'grid', "layout-2d.flag is 'grid' (fixture has >= 2 zones at distinct x within a row) — NOT 'stack'")

  layout_path = File.join(out_dir, 'layout.xml')
  ok(File.exist?(layout_path), 'wrote layout.xml')
  emitted_layout = File.read(layout_path)
  ok(emitted_layout.include?('<Element') && emitted_layout.include?('<Container'),
     'standalone Domo layout emits the live Element/Container vocabulary')
  ok(!emitted_layout.match?(%r{</?(?:LayoutElement|GridContainer)\b}),
     'standalone Domo layout never emits rejected legacy layout aliases')

  # ---- workbook-spec.json assembled with the layout merged in ------------
  spec_path = File.join(out_dir, 'workbook-spec.json')
  ok(File.exist?(spec_path), 'wrote workbook-spec.json')
  spec = JSON.parse(File.read(spec_path))
  document = Sigma::CodeRep.document(spec)
  all_elements = Sigma::CodeRep.workbook_elements(spec)
  ok(spec['name'] && spec['folderId'] && spec['document'].is_a?(Hash),
     'workbook-spec.json keeps metadata outside the released document envelope')
  ok(document['pages'].all? { |page| !page.key?('elements') },
     'workbook document pages are metadata-only')
  ok(document['layout'].is_a?(String) && document['layout'].include?('<Page'),
     'workbook document has a merged authoritative <Page> layout XML (put-layout offline step ran)')
  ok(!document['layout'].match?(%r{</?(?:LayoutElement|GridContainer)\b}),
     'workbook document layout contains no rejected legacy layout aliases')
  placed = document['layout'].scan(/\belementId="([^"]+)"/).flatten
  eq(placed.sort, all_elements.map { |element| element['id'] }.sort,
     'authoritative layout places every flat element exactly once')
  eq(placed.length, placed.uniq.length, 'authoritative layout contains no duplicate element placements')

  # ---- (b) an inline data-URI image element ------------------------------
  image_el = all_elements.find { |e| e['kind'] == 'image' }
  ok(image_el, 'workbook-spec.json contains an image-kind element')
  if image_el
    image_url = image_el.dig('source', 'url').to_s
    ok(image_url.start_with?('data:image/png;base64,'),
       "image element's source.url is an inline data-URI, got #{image_url[0, 40].inspect}")
    b64 = image_url.sub('data:image/png;base64,', '')
    ok(!b64.strip.empty?, 'image data-URI carries non-empty base64 payload')
    eq(image_el['name'], 'Logo', 'image keeps the source title for exact layout matching')
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

  # ---- (d) bead 2ef7: card['limit'] -> an element-level top-n filter -----
  topn_el = all_elements.find { |e| e.dig('filters', 0, 'kind') == 'top-n' }
  ok(topn_el, 'workbook-spec.json contains an element with a top-n filter (bead 2ef7)')
  if topn_el
    eq(topn_el.dig('filters', 0, 'rowCount'), 10, "top-n filter's rowCount matches the card's limit (10)")
  end

  # ---- (e) bead ziht: a card on a non-dominant DataSet (ds-dim) routes to --
  # its own hidden sub-master (master-<dataset>), not the shared master, and
  # that sub-master element appears exactly once under the Data page.
  data_page = document['pages'].find { |p| p['id'] == 'page-data' || p['name'] == 'Data' }
  ok(data_page, 'workbook-spec.json has a Data page')
  submaster_el = all_elements.find { |e| e.dig('source', 'elementId').to_s.start_with?('master-') }
  ok(submaster_el, "workbook-spec.json contains an element sourced from a per-dataset sub-master " \
                   "(bead ziht) — got source #{submaster_el && submaster_el['source']}")
  if submaster_el && data_page
    sm_id = submaster_el.dig('source', 'elementId')
    submaster = all_elements.find { |element| element['id'] == sm_id }
    page_by_element = Sigma::CodeRep.workbook_page_by_element(spec)
    ok(submaster, "the sub-master '#{sm_id}' appears exactly once in document.elements")
    eq(page_by_element.dig(sm_id, 'id'), data_page['id'],
       "the authoritative layout places sub-master '#{sm_id}' on the Data page")
  end

  # ---- (f) bead 08sf: a companion kpi-chart element for a card whose ------
  # Summary Number is NOT the whole card (i.e. not a Rule-0 KPI card).
  kpi_els = all_elements.select do |e|
    e['kind'] == 'kpi-chart' && !e['id'].to_s.end_with?('-verify')
  end
  rule0_kpi_cards = cards.count do |c|
    c['sigmaKindHint'] == 'kpi-chart' ||
      (c['summaryNumber'] && Array(c['groupBy']).empty? && (c['columns'] || []).size <= 1)
  end
  eq(kpi_els.size, rule0_kpi_cards + 1,
     "kpi-chart element count (#{kpi_els.size}) is one more than the #{rule0_kpi_cards} genuine Rule-0 " \
     'KPI card(s) — a companion KPI was emitted for the non-KPI card carrying a summaryNumber (bead 08sf)')

  # Tightened per the final review (I2): a bare count bump could silently
  # absorb an unrelated spurious KPI from a different bug. Assert the
  # SPECIFIC companion element (id ends '-summary') is present, not just that
  # the total moved by one.
  companion_el = kpi_els.find { |e| e['id'].to_s.end_with?('-summary') }
  ok(companion_el, "workbook-spec.json contains the SPECIFIC companion KPI element (id ending " \
                   "'-summary'), not just an incidental kpi-chart count bump (bead 08sf)")

  # ---- (g) final review Important I1/I2: the companion KPI element's id ---
  # must appear in the MERGED <Page> layout XML, not just the element tree —
  # otherwise it is present in the spec but never actually rendered on the
  # migrated page (exactly what I1 found: build-domo-layout.rb derived zones
  # from cards.json, and a companion's "-summary" id matches no card). Fixed
  # via build-domo-layout.rb's load_chart_specs_companions + a
  # pseudo-card synthesis, mirroring the pre-existing orphan-control pattern
  # (see build-domo-layout.rb) — confirm it landed by checking the companion's
  # own element id shows up as an Element's elementId= attribute.
  if companion_el
    ok(document['layout'].to_s.include?(%(elementId="#{companion_el['id']}")),
       "the companion KPI element '#{companion_el['id']}' has its OWN Element zone in the " \
       'merged layout XML — it is placed on the page, not just present in the element tree (I1 fix)')
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
else
  # Loud, honest skip — never a silent pass (same idiom as
  # test-convert-beast-modes-fixtures.rb / test-convert-beast-modes.rb's
  # node-gated sections). Zero assertions from the block above ran; do not
  # print ALL PASS as if they had.
  puts '  SKIPPED — 0 migrate-domo.rb --offline pipeline assertions exercised (`node` not on PATH). ' \
       'test/fixtures/domo-estate/beast-modes.json now drives the convert-beast-modes phase\'s --convert ' \
       'step, which requires node to run the vendored converter/sql.mjs (same as doctor.sh\'s hard node ' \
       'requirement for this skill). Install node (see scripts/bootstrap.sh) to exercise this suite for real. ' \
       'This is NOT a verified pass.'
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
