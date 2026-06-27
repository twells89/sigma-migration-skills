#!/usr/bin/env ruby
# Hard gate that proves a tableau-to-sigma conversion is actually complete.
# The subagent MUST run this script before declaring GREEN. It checks seven
# independent things — failing ANY of them blocks the GREEN declaration:
#
#   1. Phase 6 ran (parity-final.json exists, status=PASS, pass-rate met)
#      → beads-sigma-4pm. Raw-mode: when the source tool is unreachable,
#      verify-warehouse.rb writes parity-final.json with
#      verified_against=warehouse — accepted as PASS but flagged with a loud
#      banner ("verified vs warehouse, NOT source"). intake.json input_mode=file
#      without a warehouse-verified parity triggers an advisory WARN.
#   2. No orphan workbooks left in the customer's My Documents
#      (posted-workbooks.jsonl has ≤1 entry OR cleanup-marker.json shows
#      cleanup ran with no failed deletes)  → beads-sigma-38a
#   3. The live workbook's /columns endpoint shows no column with
#      type=error (catches circular refs / runtime errors introduced
#      AFTER the initial POST's column-type guard ran)  → beads-sigma-38a
#   4. The workbook has a non-empty layout XML applied (catches the
#      "elements just listed in a single column" regression where the
#      agent forgot to PUT a layout)  → beads-sigma-bw3
#   5. Tile census — parity-final.json's `tile_census` field (emitted by the
#      converter's phase6 finalize when a dashboard zone tree is available)
#      shows no unexplained dashboard zones without a matching chart in the
#      parity plan. Catches the "empty view CSV silently dropped a tile and
#      the workbook shipped with N-1 charts" escape (bead gjhe). Skipped
#      (with a note) when the converter doesn't emit a census.
#   6. Layout lint (scripts/lib/layout_lint.rb, shared) — no raw-id element
#      display names, no input controls outside the GridContainer bands on a
#      banded page, no dead zones (>25% empty grid rows between a page's
#      first and last element), no generic header-band title ("Page 1" /
#      "Sheet 3" / "Dashboard 2" must never title a dashboard), and no
#      under-filled band (<60% of the 24 grid columns covered; deliberate
#      KPI bands of <=4 tiles exempt). Catches the "PHASEE PBI Employee
#      Dashboard" visual-mess regression (and its PHASEE2 sequel: "Page 1"
#      header + a lone small chart beside a 19-column hole) that every data
#      gate waved through.
#   7. Control lint (scripts/lib/control_lint.rb, shared) — no dead controls
#      (a control with no resolving `filters` target AND no [controlId]
#      formula reference is furniture: the "Orders Overview (from Looker)"
#      estate shipped three of them), no ghost filter targets, and no control
#      whose source-closure misses same-page queryable elements (the PHASEE
#      "Action(Region) -> Monthly Revenue Trend" escape). Honors the
#      control-scope sidecar (<workdir>/control-scope.json or
#      --control-scope) for source-signal coverage (zero controls built from
#      an interactive source = FAIL, the Qlik class) and per-control
#      scope:[...] allowlists (intentional single-chart switchers like grain
#      controls). See the lib header CONTRACT.
#
# Usage:
#   ruby scripts/assert-phase6-ran.rb --tableau /tmp/<name> \
#     [--workbook-id <id>]     # override; default = read from wb-ids.json
#     [--min-pass-rate 1.0]    # default 1.0 (every chart must PASS)
#     [--allow-extract]        # treat extract-mode as acceptable
#     [--skip-column-check]    # skip the live /columns type=error scan
#     [--skip-orphan-check]    # skip the orphan-workbook scan (for callers
#                              # that genuinely want multiple workbooks)
#     [--skip-layout-check]    # skip the layout-applied scan
#     [--skip-layout-lint]     # skip gate 6 (layout-quality lint) — escape
#                              # hatch for legacy workbooks; name the reason
#                              # in your report
#     [--skip-control-lint]    # skip gate 7 (control-wiring lint) — escape
#                              # hatch for legacy workbooks; name the reason
#                              # in your report
#     [--control-scope PATH]   # control-scope.json sidecar for gate 7
#                              # (default: <workdir>/control-scope.json)
#     [--min-layout-elements N] default 2 — single-page bare-element layouts
#                              # often have just the page wrapper; require this
#                              # many <LayoutElement> tags
#     [--allow-missing-tiles N] default 0 — tolerate up to N unmatched dashboard
#                              # zones in the tile census (for legitimately
#                              # unbuildable zones; name them in your report)
#
# Exit codes:
#   0  every gate passes — conversion is allowed to declare GREEN
#   1  parity-final.json missing (Phase 6 skipped — the regression case)
#   2  parity-final.json exists but status=FAIL / pass-rate below min /
#      extract-mode without --allow-extract / charts_total==0
#   3  parity-final.json malformed
#   4  orphan workbooks left uncleaned (beads-sigma-38a)
#   5  live workbook has column(s) with type=error (beads-sigma-38a)
#   6  live workbook has no layout applied — single-column fallback
#      (beads-sigma-bw3)
#   7  tile census shows unexplained unmatched dashboard zones beyond
#      --allow-missing-tiles (bead gjhe)
#   8  layout lint violations — raw-id display names / orphan controls /
#      dead zones (gate 6; scripts/lib/layout_lint.rb)
#   9  control lint violations — dead controls / ghost targets / partial
#      reach / source filter signals with zero controls
#      (gate 7; scripts/lib/control_lint.rb)
#  10  Phase 6f visual render missing — no valid Sigma render PNG was produced,
#      so the mandatory full-dashboard visual comparison could not have run
#      ("declared done on HTTP 200" regression; gate 8). Render with
#      scripts/sigma-export-png.py --page <pageId>, Read it against the source
#      dashboard PNG, then re-run. Escape hatch: --skip-visual-gate "<reason>".
#  11  Build-from-signals tile(s) not image-verified (gate 9). Escape hatch:
#      --skip-visual-tiles "<reason>".
#  12  Telemetry consent decision missing — the anonymous usage ping was never
#      sent or declined (no telemetry-sent.json marker; gate 10, delegated to
#      assert-telemetry-ran.rb). Ask the user, then run report-telemetry.py
#      (--declined if they decline). Escape hatch: --skip-telemetry-gate "<reason>".
#
# Prints a per-gate summary to stdout regardless of exit code.

require 'json'
require 'net/http'
require 'uri'
require 'optparse'
require 'rbconfig'

opts = { min_pass_rate: 1.0, allow_extract: false, min_layout_elements: 2,
         allow_missing_tiles: 0, min_parity_score: 0.0 }
OptionParser.new do |p|
  p.on('--tableau DIR')              { |v| opts[:tab] = v }
  p.on('--workdir DIR', 'alias of --tableau for non-Tableau converters') { |v| opts[:tab] = v }
  p.on('--workbook-id ID')           { |v| opts[:wb] = v }
  p.on('--min-pass-rate F', Float)   { |v| opts[:min_pass_rate] = v }
  p.on('--min-parity-score F', Float, 'gate 1: fail if value_parity_score (mean per-tile, parity-score.json) < F (0..1, default 0 = off)') { |v| opts[:min_parity_score] = v }
  p.on('--allow-extract')            { opts[:allow_extract] = true }
  p.on('--skip-column-check')        { opts[:skip_column] = true }
  p.on('--skip-orphan-check')        { opts[:skip_orphan] = true }
  p.on('--skip-layout-check')        { opts[:skip_layout] = true }
  p.on('--skip-layout-lint')         { opts[:skip_lint] = true }
  p.on('--skip-control-lint')        { opts[:skip_control_lint] = true }
  p.on('--control-scope PATH')       { |v| opts[:control_scope] = v }
  p.on('--min-layout-elements N', Integer) { |v| opts[:min_layout_elements] = v }
  p.on('--allow-missing-tiles N', Integer, 'tolerate N unmatched dashboard zones in the tile census') { |v| opts[:allow_missing_tiles] = v }
  p.on('--skip-parity-gate REASON', 'waive gate 1 (Phase 6 source-parity) — REQUIRED reason string. Use ONLY when source parity is genuinely unavailable (e.g. no source workspace/dataset/warehouse access). The reason MUST be named in your migration report.') { |v| opts[:skip_parity] = v }
  p.on('--sigma-render PATH', 'gate 8: path to the rendered Sigma dashboard PNG (default: <workdir>/sigma-render.png; also accepts <workdir>/screenshots/_manifest.json)') { |v| opts[:sigma_render] = v }
  p.on('--skip-visual-gate REASON', 'waive gate 8 (Phase 6f visual render) — REQUIRED reason string. Use ONLY when the workbook genuinely cannot be rendered (e.g. export API unavailable). The reason MUST be named in your migration report.') { |v| opts[:skip_visual] = v }
  p.on('--skip-visual-tiles REASON', 'waive gate 9 (build-from-signals tile image-verification) — REQUIRED reason string. The reason MUST be named in your migration report.') { |v| opts[:skip_visual_tiles] = v }
  p.on('--skip-telemetry-gate REASON', 'waive gate 10 (telemetry consent decision) — REQUIRED reason string. Use ONLY when the run genuinely cannot prompt (e.g. unattended CI). The reason MUST be named in your migration report.') { |v| opts[:skip_telemetry] = v }
end.parse!
abort('--workdir (or --tableau) required') unless opts[:tab]

summary_path = File.join(opts[:tab], 'parity-final.json')

if opts[:skip_parity]
  puts "[SKIP] gate 1/7: Phase 6 source-parity WAIVED via --skip-parity-gate (#{opts[:skip_parity]})."
  puts "       This waiver MUST be named in the migration report — the workbook was NOT numerically verified vs the source."
else
  unless File.exist?(summary_path)
    warn "[FAIL] Phase 6 skipped — #{summary_path} does not exist."
    warn "       Run: ruby scripts/phase6-parity.rb --tableau #{opts[:tab]} --workbook-id <id>"
    warn "       then collect actuals via mcp__sigma-mcp-v2__query and re-run with --finalize."
    warn "       See SKILL.md Phase 6. This is the hard gate (beads-sigma-4pm)."
    warn "       If source parity is genuinely unavailable (no workspace/dataset/warehouse access), waive"
    warn "       with --skip-parity-gate \"<reason>\" and name it in the report."
    exit 1
  end

  begin
    summary = JSON.parse(File.read(summary_path))
  rescue JSON::ParserError => e
    warn "[FAIL] #{summary_path} is malformed JSON: #{e.message}"
    exit 3
  end

  total = summary['charts_total'].to_i
  passed = summary['charts_pass'].to_i
  status = summary['status'].to_s
  mode = summary['mode'].to_s

  if total <= 0
    warn "[FAIL] parity-final.json reports charts_total=#{total} — no charts were verified."
    warn "       This usually means auto-parity-plan.rb matched zero Tableau views."
    warn "       Phase 6 must verify at least one chart to declare GREEN."
    exit 2
  end

  if mode == 'extract' && !opts[:allow_extract]
    warn "[FAIL] parity ran in extract-mode but --allow-extract was not passed."
    warn "       Extract-mode permits up to ±#{((summary['extract_tol'] || 0.30) * 100).to_i}% drift —"
    warn "       only acceptable when the source Tableau workbook has hasExtracts=true."
    exit 2
  end

  pass_rate = passed.to_f / total
  # status=PASS requires 100% — when the caller explicitly accepts a lower
  # pass-rate (--min-pass-rate, for honest NAMED divergences like LOD
  # placeholders / cross-grain semantics), the rate is the gate, not the status.
  rate_gate_only = opts[:min_pass_rate] < 1.0
  if (rate_gate_only ? pass_rate < opts[:min_pass_rate] : (status != 'PASS' || pass_rate < opts[:min_pass_rate]))
    warn "[FAIL] parity status=#{status} pass-rate=#{(pass_rate * 100).round(1)}% (#{passed}/#{total})"
    warn "       Required: #{rate_gate_only ? '' : 'status=PASS and '}pass-rate >= #{(opts[:min_pass_rate] * 100).to_i}%"
    if (fail_names = summary['fail_names']) && !fail_names.empty?
      warn "       Failing charts: #{fail_names.join(', ')}"
    end
    exit 2
  end

  # Value-parity SCORE gate (bead y9rd.2): the mean per-tile value-fidelity score
  # is a finer signal than pass/fail — a tile can PASS the bucket check yet score
  # low on value drift. When --min-parity-score is set, gate on the real number.
  if opts[:min_parity_score] > 0.0
    vps = summary['value_parity_score']
    if vps.nil?
      warn "[FAIL] --min-parity-score #{opts[:min_parity_score]} requested but parity-final.json has no value_parity_score."
      warn "       Re-run phase6-parity.rb --finalize (it now writes the score via verify-parity --score-out)."
      exit 2
    end
    if vps.to_f < opts[:min_parity_score]
      warn "[FAIL] value-parity score=#{(vps.to_f * 100).round(1)}% < required #{(opts[:min_parity_score] * 100).round(1)}%"
      low = (summary['per_tile_scores'] || []).select { |t| t['score'].to_f < opts[:min_parity_score] }
                                              .sort_by { |t| t['score'].to_f }.first(5)
      low.each { |t| warn format('       %-40s %.0f%% (%s)', t['chart'], t['score'].to_f * 100, t['status']) }
      exit 2
    end
    puts "[OK] gate 1/7: value-parity score=#{(vps.to_f * 100).round(1)}% (>= #{(opts[:min_parity_score] * 100).round(1)}% required)"
  end

  if rate_gate_only && status != 'PASS'
    puts "[OK] gate 1/7: Phase 6 ran — #{passed}/#{total} charts PASS (>= #{(opts[:min_pass_rate] * 100).to_i}% accepted); " \
         "DIVERGING (accepted, must be NAMED in the report): #{(summary['fail_names'] || []).join(', ')}"
  else
    puts "[OK] gate 1/7: Phase 6 ran cleanly — #{passed}/#{total} charts PASS (mode=#{mode}, status=#{status})"
  end

  # Raw-mode honesty banner. When the source tool was unreachable, parity is run
  # against the live Sigma WAREHOUSE (verify-warehouse.rb) instead of the source —
  # every element evaluates against real warehouse data, but the values were NOT
  # diffed against the source tool's rendered output. Surface that loudly so a
  # warehouse-verified run is never mistaken for source parity.
  verified_against = summary['verified_against'].to_s
  if verified_against == 'warehouse'
    puts '     ┌─────────────────────────────────────────────────────────────────────────┐'
    puts '     │ VERIFIED AGAINST THE LIVE SIGMA WAREHOUSE — NOT against the source tool.   │'
    puts '     │ Each element evaluates against real warehouse data; values were NOT diffed │'
    puts '     │ vs the source (it was unreachable). State this in the migration report.    │'
    puts '     └─────────────────────────────────────────────────────────────────────────┘'
  else
    # Advisory only: if intake recorded file-mode (no live source) but parity was
    # not warehouse-verified, the run may be over-claiming source parity.
    intake = (JSON.parse(File.read(File.join(opts[:tab], 'intake.json'))) rescue nil)
    if intake.is_a?(Hash) && intake['input_mode'].to_s == 'file'
      warn '[WARN] gate 1: intake.json records input_mode=file (no live source) but parity-final.json is'
      warn '       not marked verified_against=warehouse. In raw-mode, verify against the warehouse'
      warn '       (ruby scripts/verify-warehouse.rb) so the result is not mistaken for source parity.'
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 2 — orphan workbooks (beads-sigma-38a)
# ---------------------------------------------------------------------------
unless opts[:skip_orphan]
  log = File.join(opts[:tab], 'posted-workbooks.jsonl')
  if File.exist?(log)
    posted = File.readlines(log).map { |l| JSON.parse(l) rescue nil }.compact
    unique_ids = posted.map { |e| e['id'] }.uniq
    if unique_ids.length > 1
      marker_path = File.join(opts[:tab], 'cleanup-marker.json')
      unless File.exist?(marker_path)
        warn "[FAIL] gate 2/7: #{unique_ids.length} workbooks created during this conversion (orphans not cleaned)."
        warn "       posted-workbooks.jsonl entries:"
        unique_ids.each { |id| warn "         - #{id}" }
        warn "       Run: ruby scripts/cleanup-orphan-workbooks.rb --workdir #{opts[:tab]}"
        warn "       See beads-sigma-38a."
        exit 4
      end
      marker = JSON.parse(File.read(marker_path)) rescue {}
      if marker['failed'] && !marker['failed'].empty?
        warn "[FAIL] gate 2/7: cleanup-marker.json reports #{marker['failed'].length} failed delete(s)."
        warn "       Orphan workbooks are still in the customer's My Documents:"
        marker['failed'].each { |f| warn "         - #{f['id']} (HTTP #{f['status']})" }
        exit 4
      end
      if marker['dry_run']
        warn "[FAIL] gate 2/7: cleanup-marker.json is from a --dry-run; orphans were not actually deleted."
        warn "       Re-run cleanup-orphan-workbooks.rb without --dry-run."
        exit 4
      end
      kept = marker['kept'] || '(unknown)'
      deleted = (marker['deleted'] || []).length
      puts "[OK] gate 2/7: orphan cleanup ran — kept #{kept}, deleted #{deleted}"
    else
      puts "[OK] gate 2/7: only one workbook POSTed (#{unique_ids.first}) — no orphan check needed"
    end
  else
    puts "[OK] gate 2/7: posted-workbooks.jsonl missing — assuming no orphans (legacy or external POST flow)"
  end
else
  puts "[SKIP] gate 2/7: --skip-orphan-check"
end

# ---------------------------------------------------------------------------
# Gate 3 — live /columns type=error scan (beads-sigma-38a)
# Catches circular references and runtime errors that the initial post-and-
# readback column-type guard missed because they were introduced by later
# PUTs (layout updates, spec edits during error recovery).
# ---------------------------------------------------------------------------
unless opts[:skip_column]
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end

  if wb_id.nil? || wb_id.empty?
    puts "[SKIP] gate 3/7: no workbook ID resolvable (pass --workbook-id or ensure wb-ids.json exists)"
  else
    base = ENV['SIGMA_BASE_URL']
    tok  = ENV['SIGMA_API_TOKEN']
    if base.nil? || base.empty? || tok.nil? || tok.empty?
      warn "[SKIP] gate 3/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch /columns"
    else
      uri = URI("#{base}/v2/workbooks/#{wb_id}/columns")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }

      if res.is_a?(Net::HTTPSuccess)
        cols = (JSON.parse(res.body)['entries'] rescue []) || []
        error_cols = cols.select { |c| c.dig('type', 'type') == 'error' }
        if error_cols.any?
          warn "[FAIL] gate 3/7: live workbook #{wb_id} has #{error_cols.length} column(s) with type=error."
          warn "       These render as visible errors in the Sigma UI (circular ref, unknown column,"
          warn "       unsupported function, etc.). Fix the offending formulas and re-PUT before declaring GREEN."
          error_cols.first(10).each do |c|
            warn "         element=#{c['elementId']} col=#{c['columnId']} label=#{c['label'].inspect}"
            warn "           formula: #{c['formula']}"
          end
          warn "       See beads-sigma-38a."
          exit 5
        end
        puts "[OK] gate 3/7: #{cols.length} live columns clean (no type=error)"
      else
        warn "[SKIP] gate 3/7: GET /v2/workbooks/#{wb_id}/columns returned HTTP #{res.code} — cannot verify"
      end
    end
  end
else
  puts "[SKIP] gate 3/7: --skip-column-check"
end

# ---------------------------------------------------------------------------
# Gate 4 — layout applied (beads-sigma-bw3)
# Fetches the live workbook spec and confirms a non-empty top-level `layout`
# XML is set, with at least --min-layout-elements <LayoutElement> tags.
# Catches the "agent forgot to PUT a layout" regression where elements
# render as a single-column stack instead of the dashboard grid.
# ---------------------------------------------------------------------------
unless opts[:skip_layout]
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end

  if wb_id.nil? || wb_id.empty?
    puts "[SKIP] gate 4/7: no workbook ID resolvable for layout check"
  else
    base = ENV['SIGMA_BASE_URL']
    tok  = ENV['SIGMA_API_TOKEN']
    if base.nil? || base.empty? || tok.nil? || tok.empty?
      warn "[SKIP] gate 4/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch spec"
    else
      uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }

      if res.is_a?(Net::HTTPSuccess)
        body = res.body.to_s
        spec =
          begin
            JSON.parse(body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(body, permitted_classes: [Date, Time]) || {}
          end
        layout_xml = spec['layout'].to_s
        elem_count = layout_xml.scan(/<LayoutElement\b/).length

        # Detect the Sigma "auto-generated single-column stack" layout that
        # the server produces when a workbook is POSTed without a layout.
        # Signature: every non-Data page has all its elements at the same
        # gridColumn value (typically "1 / 13" — left half, vertically stacked).
        # Note: per-page detection — a workbook with one element per content
        # page is structurally fine (degenerate case, not a stack).
        # Container-banded pages (<GridContainer> bands per layout-playbook.md)
        # are exempt: full-width band containers (and single-chart rows inside
        # them) legitimately share gridColumn="1 / 25" — that is deliberate
        # banding, not the auto-stack regression.
        non_data_stack_pages = []
        # Walk one page at a time using the <Page id="..."> blocks
        layout_xml.scan(/<Page\b[^>]*id="([^"]*)"[^>]*>(.*?)<\/Page>/m).each do |page_id, page_body|
          next if page_id.to_s.downcase.include?('data')
          next if page_body.include?('<GridContainer')
          cols_on_page = page_body.scan(/gridColumn="([^"]+)"/).map(&:first).uniq
          elems_on_page = page_body.scan(/<LayoutElement\b/).length
          if elems_on_page >= 2 && cols_on_page.length == 1
            non_data_stack_pages << [page_id, cols_on_page.first, elems_on_page]
          end
        end

        if layout_xml.empty?
          warn "[FAIL] gate 4/7: live workbook #{wb_id} has NO top-level layout XML."
          warn "       Elements render as a single-column stack instead of the"
          warn "       dashboard grid. Rebuild the layout with this skill's layout"
          warn "       builder (see SKILL.md — layout phase) into #{opts[:tab]}/layout.xml,"
          warn "       then PUT it:"
          warn "         ruby scripts/put-layout.rb --workbook #{wb_id} \\"
          warn "           --layout #{opts[:tab]}/layout.xml"
          warn "       See beads-sigma-bw3."
          exit 6
        elsif elem_count < opts[:min_layout_elements]
          warn "[FAIL] gate 4/7: layout XML has only #{elem_count} <LayoutElement> tag(s);"
          warn "       at least #{opts[:min_layout_elements]} required (one master + ≥1 chart)."
          warn "       The layout likely covers only the Data page — chart page is unstyled."
          exit 6
        elsif non_data_stack_pages.any?
          warn "[FAIL] gate 4/7: live workbook #{wb_id} has Sigma's auto-generated"
          warn "       single-column stack layout (multiple elements at the same gridColumn"
          warn "       on a non-Data page). This is what Sigma defaults to when you POST"
          warn "       a workbook without a layout — exactly the CoCo regression."
          non_data_stack_pages.each do |pid, col, n|
            warn "         page=#{pid.inspect}: #{n} elements all at gridColumn=#{col.inspect}"
          end
          warn "       Rebuild the layout with this skill's layout builder (see SKILL.md —"
          warn "       layout phase) into #{opts[:tab]}/layout.xml, then PUT it:"
          warn "         ruby scripts/put-layout.rb --workbook #{wb_id} --layout #{opts[:tab]}/layout.xml"
          warn "       See beads-sigma-bw3."
          exit 6
        else
          puts "[OK] gate 4/7: layout XML applied with #{elem_count} positioned element(s)"
        end
      else
        warn "[SKIP] gate 4/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot verify"
      end
    end
  end
else
  puts "[SKIP] gate 4/7: --skip-layout-check"
end

# ---------------------------------------------------------------------------
# Gate 5 — tile census (bead gjhe)
# parity-final.json's `tile_census` field compares the source dashboard's
# chart-zone count against the charts that made it into the parity plan.
# Catches the empty-view-CSV escape where the builder silently emits N-1
# charts and parity still reports PASS (every chart it knows about passes —
# it just doesn't know about the dropped one).
# ---------------------------------------------------------------------------
census = summary && summary['tile_census']  # summary is nil when gate 1 was waived
if census.nil?
  puts "[SKIP] gate 5/7: no tile_census in parity-final.json (converter did not emit one — re-run phase6 finalize with the dashboard zone tree available to enable)"
else
  zones     = census['zones_total'].to_i
  built     = census['charts_built'].to_i
  unmatched = census['zones_unmatched'].to_i
  names     = Array(census['unmatched_zone_names'])
  if unmatched > opts[:allow_missing_tiles]
    warn "[FAIL] gate 5/7: tile census — #{zones} dashboard zone(s), #{built} chart(s) built, #{unmatched} unmatched:"
    names.each { |n| warn "         - #{n}" }
    warn "       A zone that rendered in the source dashboard has NO matching chart in the"
    warn "       parity plan. Common causes: empty/0-byte view CSV silently dropped the tile"
    warn "       (re-fetch the view data and rebuild), or the tile was renamed without"
    warn "       passing --rename to phase6-parity.rb / build-dashboard-layout.rb."
    warn "       If #{unmatched} zone(s) are legitimately unbuildable, re-run with"
    warn "       --allow-missing-tiles #{unmatched} and name them in your report. Bead gjhe."
    exit 7
  elsif unmatched > 0
    puts "[OK] gate 5/7: tile census — #{zones} zones, #{built} charts built, #{unmatched} unmatched (within --allow-missing-tiles #{opts[:allow_missing_tiles]}): #{names.join(', ')}"
  else
    puts "[OK] gate 5/7: tile census — #{zones} zones, #{built} charts built, 0 unmatched"
  end
end

# ---------------------------------------------------------------------------
# Gate 6 — layout-quality lint (scripts/lib/layout_lint.rb, shared)
# A workbook can pass every data gate above and still ship as a visual mess:
# raw element ids as chart titles, controls dumped loose at the page foot,
# dead zones between elements (the "PHASEE PBI Employee Dashboard" escape).
# This gate mechanizes those checks on the LIVE spec.
# ---------------------------------------------------------------------------
if opts[:skip_lint]
  puts "[SKIP] gate 6/7: --skip-layout-lint (name the reason in your report)"
else
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end
  base = ENV['SIGMA_BASE_URL']
  tok  = ENV['SIGMA_API_TOKEN']
  if wb_id.nil? || wb_id.to_s.empty?
    puts "[SKIP] gate 6/7: no workbook ID resolvable for layout lint"
  elsif base.nil? || base.empty? || tok.nil? || tok.empty?
    warn "[SKIP] gate 6/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch spec"
  else
    begin
      require_relative 'lib/layout_lint'
    rescue LoadError
      warn "[SKIP] gate 6/7: scripts/lib/layout_lint.rb not vendored in this plugin — re-vendor (md5 discipline)"
    end
    if defined?(LayoutLint)
      uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
      if res.is_a?(Net::HTTPSuccess)
        spec =
          begin
            JSON.parse(res.body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(res.body, permitted_classes: [Date, Time]) || {}
          end
        violations = LayoutLint.lint(spec)
        if violations.any?
          warn "[FAIL] gate 6/7: layout lint — #{violations.length} violation(s) on live workbook #{wb_id}:"
          violations.each { |v| warn "         - #{v}" }
          warn "       Fix the spec/layout and re-PUT (raw-id names -> derive human titles;"
          warn "       loose controls -> place into a band/container; dead zones -> re-band the page),"
          warn "       then re-run this gate. Escape hatch (legacy workbooks only): --skip-layout-lint."
          exit 8
        end
        puts '[OK] gate 6/7: layout lint clean (no raw-id names, no orphan controls, no dead zones, ' \
             'no generic header title, no under-filled bands)'
      else
        warn "[SKIP] gate 6/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot lint"
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 7 — control-wiring lint (scripts/lib/control_lint.rb, shared)
# A workbook can pass every gate above and still ship controls that do
# NOTHING (dead controls: no resolving filter target, no [controlId] formula
# reference — the "Orders Overview (from Looker)" estate escape) or controls
# that silently skip same-page charts (the PHASEE "Action(Region) ->
# Monthly Revenue Trend" escape). This gate mechanizes those checks on the
# LIVE spec, plus source-signal coverage when a control-scope sidecar exists
# (zero controls built from an interactive source = FAIL, the Qlik class).
# ---------------------------------------------------------------------------
if opts[:skip_control_lint]
  puts "[SKIP] gate 7/7: --skip-control-lint (name the reason in your report)"
else
  wb_id = opts[:wb]
  if wb_id.nil?
    wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
    if File.exist?(wb_ids_path)
      wb_ids = JSON.parse(File.read(wb_ids_path)) rescue {}
      wb_id = wb_ids['workbookId']
    end
  end
  base = ENV['SIGMA_BASE_URL']
  tok  = ENV['SIGMA_API_TOKEN']
  if wb_id.nil? || wb_id.to_s.empty?
    puts "[SKIP] gate 7/7: no workbook ID resolvable for control lint"
  elsif base.nil? || base.empty? || tok.nil? || tok.empty?
    warn "[SKIP] gate 7/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — cannot fetch spec"
  else
    begin
      require_relative 'lib/control_lint'
    rescue LoadError
      warn "[SKIP] gate 7/7: scripts/lib/control_lint.rb not vendored in this plugin — re-vendor (md5 discipline)"
    end
    if defined?(ControlLint)
      uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
      req = Net::HTTP::Get.new(uri)
      req['Authorization'] = "Bearer #{tok}"
      req['Accept'] = 'application/json'
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
      if res.is_a?(Net::HTTPSuccess)
        spec =
          begin
            JSON.parse(res.body)
          rescue JSON::ParserError
            require 'yaml'
            require 'date'
            YAML.safe_load(res.body, permitted_classes: [Date, Time]) || {}
          end
        scope_path = opts[:control_scope] || File.join(opts[:tab], 'control-scope.json')
        scope = nil
        if File.exist?(scope_path)
          scope = JSON.parse(File.read(scope_path)) rescue nil
          warn "[WARN] gate 7/7: #{scope_path} is not valid JSON — linting without source scope" if scope.nil?
        end
        violations = ControlLint.lint(spec, scope: scope)
        if violations.any?
          warn "[FAIL] gate 7/7: control lint — #{violations.length} violation(s) on live workbook #{wb_id}:"
          violations.each { |v| warn "         - #{v}" }
          warn "       Fix the control wiring and re-PUT (dead controls -> add filters targets"
          warn "       ({source:{elementId}, columnId}) or remove the control; partial reach ->"
          warn "       wire the uncovered elements or annotate controlScope in control-scope.json;"
          warn "       see scripts/lib/control_lint.rb CONTRACT), then re-run this gate."
          warn "       Flip-test the wiring live with: ruby scripts/probe-controls.rb --workbook-id #{wb_id}"
          warn "       Escape hatch (legacy workbooks only): --skip-control-lint."
          exit 9
        end
        n_controls = ControlLint.controls_report(spec).length
        puts "[OK] gate 7/7: control lint clean (#{n_controls} control(s); no dead controls, no ghost " \
             "targets, full same-page reach#{scope ? ', source scope honored' : ''})"
      else
        warn "[SKIP] gate 7/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{res.code} — cannot lint"
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 8 — Phase 6f visual render (the "declared done on HTTP 200" regression)
# CSV value parity (gate 1) confirms the DATA matches; it cannot catch a
# visually-broken workbook (dropped log scale, missing labels, overlaps, dead
# zones, wrong chart kind, palette drift). Phase 6f is documented MANDATORY but
# had no machine enforcement, so a conversion could pass every gate above and
# ship without anyone ever rendering — let alone reading — the Sigma PNG.
# This gate requires a VALID render artifact to exist as proof the visual
# comparison could run. It does not (and cannot) verify the human/agent read it
# — but you cannot compare a PNG you never produced.
# ---------------------------------------------------------------------------
if opts[:skip_visual]
  puts "[SKIP] gate 8: Phase 6f visual render WAIVED via --skip-visual-gate (#{opts[:skip_visual]})."
  puts "       This waiver MUST be named in the migration report — the workbook was NOT visually verified."
else
  default_render = File.join(opts[:tab], 'sigma-render.png')
  manifest_path  = File.join(opts[:tab], 'screenshots', '_manifest.json')
  render_path    = opts[:sigma_render] || (File.exist?(default_render) ? default_render : nil)

  # Validate a candidate PNG: real PNG magic bytes + non-trivial size (a blank /
  # error / truncated export is often a few hundred bytes).
  MIN_PNG_BYTES = 5_000
  valid_png = lambda do |path|
    next false unless path && File.file?(path)
    next false unless File.size(path) >= MIN_PNG_BYTES
    File.binread(path, 8) == "\x89PNG\r\n\x1a\n".b
  end

  ok_png = nil
  if valid_png.call(render_path)
    ok_png = render_path
  elsif opts[:sigma_render].nil? && File.exist?(manifest_path)
    # Fall back to the per-element screenshot manifest (export-chart-png.rb):
    # accept if it lists at least one rendered PNG that validates.
    entries = (JSON.parse(File.read(manifest_path)) rescue nil)
    entries = entries.values if entries.is_a?(Hash)
    if entries.is_a?(Array)
      cand = entries.map { |e| e.is_a?(Hash) ? (e['path'] || e['file']) : e }.compact
      ok_png = cand.find { |p| valid_png.call(p) || valid_png.call(File.join(opts[:tab], 'screenshots', File.basename(p.to_s))) }
    end
  end

  if ok_png.nil?
    warn '[FAIL] gate 8: Phase 6f visual render missing — no valid Sigma render PNG found.'
    warn "       Looked for: #{opts[:sigma_render] || default_render}" \
         "#{opts[:sigma_render] ? '' : " (and #{manifest_path})"}"
    warn '       CSV parity passing does NOT mean the workbook renders correctly. Render the full'
    warn '       page and READ it against the source dashboard PNG before declaring done:'
    warn "         python3 scripts/sigma-export-png.py --workbook <id> --page <pageId> --out #{default_render}"
    warn '       then re-run this gate. See SKILL.md Phase 6f. Escape hatch (genuinely un-renderable'
    warn '       workbooks only): --skip-visual-gate "<reason>" (name it in your report).'
    exit 10
  end
  size_kb = (File.size(ok_png) / 1024.0).round
  puts "[OK] gate 8: Phase 6f visual render present (#{ok_png}, #{size_kb} KB) — " \
       'valid PNG produced for source-vs-target comparison'
  # Soft nudge: the conversion result should record that the comparison ran.
  if File.exist?(summary_path)
    s = (JSON.parse(File.read(summary_path)) rescue {})
    unless s['screenshot_path'] || s['visual_checked']
      warn "[WARN] gate 8: parity-final.json records no screenshot_path/visual_checked flag — " \
           'render exists but confirm you actually compared it to the source and noted any divergence.'
    end
  end
end

# Gate 9 — Visual-verify tiles (build-from-signals). Tiles whose Tableau data
# export came back EMPTY (action-filter-gated etc.) are built from .twb signals
# and cannot be value-diffed, so they must be confirmed by IMAGE comparison
# (verify-visual-tiles.rb). Without this gate they'd pass parity silently. No-op
# (and invisible to other converters) when the sidecar is absent.
vv_sidecar = File.join(opts[:tab], 'visual-verify-tiles.json')
if File.exist?(vv_sidecar)
  vtiles = (JSON.parse(File.read(vv_sidecar)) rescue [])
  if opts[:skip_visual_tiles]
    puts "[SKIP] gate 9: #{vtiles.size} build-from-signals tile(s) visual-verify WAIVED (#{opts[:skip_visual_tiles]})."
  elsif vtiles.any?
    man_path = File.join(opts[:tab], 'visual-verify', 'manifest.json')
    man = File.exist?(man_path) ? (JSON.parse(File.read(man_path)) rescue nil) : nil
    if man.nil?
      warn "[FAIL] gate 9: #{vtiles.size} tile(s) had EMPTY data exports (built from .twb signals) but no"
      warn "       visual-verify/manifest.json exists — run: ruby scripts/verify-visual-tiles.rb"
      warn "       --workbook #{opts[:wb] || '<id>'} --tableau-dir #{opts[:tab]}, then READ each"
      warn '       <tile>.tableau.png vs <tile>.sigma.png pair and mark "visual_verified": true.'
      exit 11
    end
    unverified = man.reject { |m| m['visual_verified'] }
    if unverified.any?
      warn "[FAIL] gate 9: #{unverified.size}/#{man.size} build-from-signals tile(s) NOT visually verified: " \
           "#{unverified.map { |m| m['worksheet'] }.join(', ')}."
      warn '       These tiles have no value actuals (empty Tableau export). READ each'
      warn "       <tile>.tableau.png vs <tile>.sigma.png under #{File.join(opts[:tab], 'visual-verify')}/,"
      warn '       confirm trend/axis/magnitudes match, and set "visual_verified": true per tile in'
      warn '       visual-verify/manifest.json. Escape hatch: --skip-visual-tiles "<reason>" (name it in your report).'
      exit 11
    end
    puts "[OK] gate 9: #{man.size} build-from-signals tile(s) image-verified (empty data export → visual parity)"
  end
end

# ---------------------------------------------------------------------------
# Gate 10 — Telemetry consent decision. The anonymous usage ping (and the
# consent prompt that precedes it) lived as prose in each SKILL.md, so an agent
# could wrap up without ever asking — telemetry silently never fired. This gate
# delegates to the standalone assert-telemetry-ran.rb (single source of truth)
# which checks for the telemetry-sent.json marker written by report-telemetry.py
# on send OR decline. Never touches the network. The 3 converters that don't run
# THIS script (qlik/cognos/gooddata) call assert-telemetry-ran.rb directly.
# ---------------------------------------------------------------------------
tele_gate = File.join(__dir__, 'assert-telemetry-ran.rb')
if File.exist?(tele_gate)
  cmd = [RbConfig.ruby, tele_gate, '--workdir', opts[:tab]]
  cmd += ['--skip-telemetry-gate', opts[:skip_telemetry]] if opts[:skip_telemetry]
  unless system(*cmd)
    # assert-telemetry-ran.rb already printed the actionable failure message.
    exit 12
  end
else
  warn '[WARN] gate 10: assert-telemetry-ran.rb not found alongside this script — telemetry not enforced.'
end

puts "[OK] all gates pass — conversion may declare GREEN"
exit 0
