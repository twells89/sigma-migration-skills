#!/usr/bin/env ruby
# frozen_string_literal: true

# Locale-proof the whole run: with LANG unset (fresh machines, CI, some SSH
# sessions) Ruby defaults external encoding to US-ASCII, and any UTF-8 byte in
# child-process output or an API error body then raises mid-pipeline. Field
# names in real workbooks routinely carry non-ASCII ($, ©, accented captions).
Encoding.default_external = Encoding::UTF_8

# migrate-tableau.rb — ONE-SHOT, single-process orchestrator for the
# tableau-to-sigma pipeline. Runs the whole phased workflow in one Ruby process
# to cut agent turns / token cost, WITHOUT turning the migration into a black
# box: every phase prints a visible header + concise result, and the genuine
# human decision points (window/table-calc degradations, untranslatable calcs,
# custom-SQL / file-based datasources, unsupported viz) are surfaced as a
# structured OPEN QUESTIONS block (exit 10) rather than silently auto-resolved.
#
# This script does NOT re-implement any mechanical phase — it chains the
# existing skill scripts:
#   tableau-discover.rb     (Phase 1 — workbook + views + .twb + ds-metadata + PNG)
#   parse-twb-layout.rb     (Phase 1 — dashboard zone tree + chart kinds)
#   extract-calc-fields.rb  (Phase 1 — calc formulas + requires_custom_sql flag)
#   extract-custom-sql.rb   (Phase 1 — custom-SQL blocks behind the datasource)
#   scan-workbook-gaps.rb   (Phase 1 — feature-gap inventory)
#   discover-columns.rb     (Phase 2 — real warehouse column names/types)
#   validate-spec.rb + post-and-readback.rb (Phase 3 DM, Phase 4 workbook)
#   build-dashboard-layout.rb + put-layout.rb (Phase 5 layout)
#   phase6-parity.rb        (Phase 6 parity, best-effort; falls back to the
#                            post-and-readback column-type guard as the hard signal)
#
# Spec GENERATION (the DM spec + workbook spec) is the one genuinely
# agent-owned step in this skill — there is no mechanical converter the way
# QuickSight has. The orchestrator delegates it to a pluggable generator:
#   * If a `Specs` module is reachable (the validated reference generator at
#     ~/orders-migration/specs.rb, or a per-workbook generator the agent drops
#     next to the working dir), it is used verbatim — deterministic, validated.
#   * Otherwise the orchestrator builds a data-driven DM from the warehouse
#     tables discovered in Phase 2 (one warehouse-table element per table,
#     *_KEY-inferred relationships, calc fields translated by the built-in
#     Tableau->Sigma translator) and the workbook via the skill's own
#     build-charts-from-signals.rb + build-workbook-spec.rb.
#
# Usage (PASS 1 — discover → gates → DM → workbook → layout → parity plan):
#   ruby scripts/migrate-tableau.rb \
#     --workbook "<name>" | --workbook-id <luid> \
#     --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID> \
#     [--db <DB> --schema <SCHEMA>] [--specs <path/to/specs.rb>] \
#     [--name '<prefix for DM/workbook names>'] \
#     [--row-scale F | --page-rows N]  # row-model OVERRIDES: pass only to override —
#                             # either flag disables the px-derived canvas rows \
#     [--force]               # proceed past ❌-unhandled gap-scan features
#     [--reuse-dm [ID]]       # opt IN to DM reuse (default: build new; bare
#                             # flag = use find-or-pick-dm's recommendation)
#     [--skip-reuse-scan]     # don't scan existing DMs at all
#     [--out DIR] [--answers '<json>'] [--yes]
#
# Phase 6 parity is TWO-PASS (Sigma has no synchronous chart-data REST endpoint;
# actuals come from mcp-v2 queries). Pass 1 ends by emitting the per-chart MCP
# query list + exit 12. Collect the actuals, then resume (PASS 2 — finalize +
# cleanup-orphans + the census-aware assert-phase6-ran hard gate):
#   ruby scripts/migrate-tableau.rb --workbook "<name>" [--out DIR] \
#     --finalize --actuals <WORKDIR>/parity-actuals.json \
#     [--allow-missing-tiles N]   # explain legitimately unbuildable zones
#
# FAST PATH (workbook-layer re-entry — the exit-4 handoff):
#   ruby scripts/migrate-tableau.rb --workbook "<name>" [--out DIR] \
#     --connection <id> --reuse-dm <dataModelId> --wb-spec <WORKDIR>/wb-spec.json [--yes]
#   When BOTH --reuse-dm <explicit id> AND --wb-spec are passed, the run skips
#   Tableau discovery and the decisions checkpoint ENTIRELY (the spec is
#   agent-authored — the open questions were answered when it was written; the
#   DM is live) and runs: DM readback (GET spec/columns for element ids) →
#   __DM_ID__/__DM_ELEMENT__ placeholder substitution → validate → preflight →
#   workbook POST/PUT → layout → parity plan → exit 12, identical to the
#   documented exit-4 re-entry. Discovery artifacts already in the workdir
#   (dashboard-layout.json, views/*.csv, workbook-content.twb) are reused for
#   layout/parity as normal; when any are MISSING the run degrades LOUDLY:
#   with --yes it proceeds and prints exactly what's missing (Tableau discovery
#   is never re-run under --yes); without --yes it falls back to the full
#   discovery pipeline. A bare --reuse-dm (no id) or --dm-spec (fresh DM build)
#   always takes the full path. Fresh runs, --finalize, resume-from-state, and
#   the --dm-spec path are unaffected.
#
# Preflight hook (wired defensively — fires only when the lib exists):
#   * scripts/lib/formula_normalize.rb → case-normalizes converter formulas on
#     the mechanical dm-spec/wb-spec (one NOTE line per rewrite).
#
# Phase E (OPT-IN) — Enhance: pass --enhance (pass 1 or --finalize) to run the
# shared enhancement engine AFTER all gates are green: enhance-scan.rb emits
# candidates + app_options; design interview via enhance-select.rb /
# enhance-app-plan.rb; nothing applies without --enhance-accept
# <ids|all-low-risk> (without it the run stops at exit 14 with the proposals);
# enhance-apply.rb then clones the parity workbook ("<name> — Enhanced") and
# applies accepted items one at a time under a parity-unchanged gate.
# Default = OFF everywhere. See refs/phase-e-enhance.md.
#
# Exit codes: 0 = done (ALL gates green — only possible via --finalize);
# 10 = decisions needed (OPEN QUESTIONS printed, NO Sigma objects created);
# 11 = gap scan found ❌-unhandled features (re-run with --force to accept);
# 12 = pass 1 complete, parity PENDING (run the printed MCP queries, then
#      re-run with --finalize --actuals);
# 13 = calc extraction returned 0 calcs though the .twb defines calc fields
#      (broken extraction — re-run calc discovery; NO Sigma objects created);
# 14 = migration GREEN + Phase E proposals pending acceptance (re-run
#      --finalize with --enhance --enhance-accept ...);
# 15 = converter produced an EMPTY data model (0 elements/columns) — unsupported
#      datasource shape; NO Sigma objects created (capture the .twb for the converter);
# 16 = pass 1 built + POSTed, but <workdir>/manual-residues.json carries
#      'unbuilt' window/table-calc residue(s) a dashboard tile plots
#      (requires_custom_sql — the STAYS-MANUAL family): the tile currently
#      renders a magnitude proxy. Build each residue as a Custom SQL DM
#      element, repoint the tile measure, set status:"built" in the ledger
#      (the blocking checklist prints the formula + SQL skeleton + bind
#      steps), then run --finalize. assert-phase6-ran refuses GREEN while any
#      residue is 'unbuilt' (waiver: --accept-manual-residues, budget-counted);
# 17 = every datasource is an EMBEDDED file extract and no landing manifest was
#      found — land the frozen data first (scripts/land-extracts.py, see
#      refs/extract-landing.md), or re-run with --skip-extract-landing "<reason>";
# 18 = the Phase-1d dashboard-read WAIT-GATE deadline passed: png-read.json is
#      still missing/unverified/stale after SIGMA_PNG_READ_TIMEOUT_S (default
#      480s). The banner names exactly what is missing. Verify the read (or
#      --skip-dashboard-read "<reason>") and re-run — discovery is cached;
# 19 = scoped-run mismatch: a --dashboard / mission.json stated scope named a
#      dashboard that matches NOTHING in the workbook — the banner lists the
#      workbook's dashboards (E9.6: never a silent full-workbook run);
# 20 = the pre-POST Custom-SQL identifier gate (check-sql-idents.rb) found a
#      statement referencing an identifier that does not exist on its FROM
#      table — waive with --skip-sql-ident-gate "<reason>";
# 21 = an element still carries the mechanical converter's placeholder
#      warehouse-table name/path ("UNKNOWN") after every attribution chance
#      (extract-landing manifest remap, phantom-column filter) has already
#      run — POSTing it would 404 late with an unnamed "Source not found"
#      error (#685-A). Land the embedded extract (or repoint the element by
#      hand with --table-mapping) and re-run;
# 3 = parity/guard fail; 4 = workbook layer needs the agent path; other = error.
#
# SINGLE-INVOCATION (speed review #2, wave 1):
#   * The Phase-1d dashboard-read is a WAIT-GATE at the DM-POST barrier, not a
#     guaranteed abort: the orchestrator polls for a VERIFIED png-read.json
#     (bounded, SIGMA_PNG_READ_TIMEOUT_S) while the agent reads the PNGs the
#     discovery lane already downloaded. No stale-seed reuse: a png-read.json
#     older than this run's discovery fetch is set aside as .stale.
#   * Gap-scan review (exit 11), decisions (exit 10), and the E9.4 cost
#     ADVISORY (WARN-only) batch into ONE consolidated pre-build checkpoint:
#     single combined artifact (<WORK>/open-questions.json), single re-entry
#     (--answers/--force/--yes).
#   * When the agent-mediated actuals list is EMPTY at the pass-1 tail (strict,
#     artifact-derived: every exportable chart machine-collected, no pivot
#     grids, no render-verify/too-large markers, no per-tile visual sidecar)
#     AND the agent-side gate obligations are already discharged (recorded
#     visual verdict — gate 8b, --fast waives; staged RCF ledger resolved —
#     gate 8d), pass 1 chains --finalize in-process instead of exit 12. Cold
#     runs never chain (the verdict only exists on re-entry workdirs). Escape
#     hatch: SIGMA_NO_CHAIN_FINALIZE=1.
#   * --quiet: machine stdout for background-log poll turns — one JSON event
#     line per phase entry/completion + WARN/FATAL/error lines + a terminal
#     state JSON; everything else goes to <WORK>/migrate-full.log. Default
#     (no --quiet) output is byte-identical to before (refs/performance.md).
require 'json'
require 'csv'
require 'yaml'
require 'optparse'
require 'fileutils'
require 'open3'
require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)
begin; require_relative 'lib/modeling_advisory'; rescue LoadError; end # shared, vendor-neutral CDW join-cost advisory (optional; synced from shared/)
require 'date'
require 'time'
require 'set'
require_relative 'lib/scout_gate'
require_relative 'lib/dashboard_read'
require_relative 'lib/recipe_multimetric'
require_relative 'lib/run_state'
require_relative 'lib/offramp' # structured "where did this run leave the golden path" trail
require_relative 'lib/fast_path' # FAST-PATH routing + BOM-tolerant JSON reads
require_relative 'lib/phase_cache' # sha-stamped phase-output reuse on re-entry (refs/performance.md)
require_relative 'lib/sigma_rest' # in-process Sigma token minting (no bash/eval)
require_relative 'lib/code_rep' # workbook code-rep document-wrapper adapter (nested GET/PUT shape)
require_relative 'lib/workbook_code' # flat workbook elements + layout-owned page membership
require_relative 'lib/metric_binding' # shared DM-metric binder ([Metrics/<name>] over inline re-derive)
require_relative 'lib/tableau_warehouse_column_refs'
require_relative 'lib/tableau_rest' # in-process Tableau token minting (Windows-safe; no bash/eval)
require_relative 'hydrate-custom-sql'

$stdout.sync = true # progress lines interleave correctly when piped/captured

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)
require 'coverage_gate' # build-charts coverage.json → consolidated report (bead beads-sigma-59mk)
# Local per-phase timing capture (wave-1, ratified decision #5: measure before
# optimizing; files LOCAL, never sent off-box). The lib is owned by the
# shared phase-metrics lane (shared/lib/phase_metrics.rb → lib/phase_metrics.rb);
# wired DEFENSIVELY — absent lib or a raising lib is a silent no-op, and the
# artifact (<WORK>/phase-metrics.jsonl) is a machine-local workdir file.
begin
  require 'phase_metrics'
rescue LoadError, StandardError
  nil
end
require 'join_plan_resolutions' # join-plan.json gate-16 resolutions → consolidated report (beads-sigma-zjkw)

require 'rbconfig'
# Children (post-and-readback.rb, phase6-parity.rb, …) inherit this marker so
# they can tell an ORCHESTRATED invocation from a cold standalone one — the
# standalone manual-path gate in post-and-readback.rb keys off it.
ENV['SIGMA_ORCHESTRATED_RUN'] = '1'
# Snapshot ARGV before OptionParser consumes it — the reuse self-heal re-invokes
# this orchestrator verbatim + `--skip-reuse-scan` (see the WorkbookBuildError
# rescue). :recommended reuse comes from auto-pick, never a CLI arg, so the
# snapshot carries no --reuse-dm to strip.
ORIGINAL_ARGV = ARGV.dup.freeze
opts = { per_page_masters: true }
OptionParser.new do |o|
  o.banner = <<~BANNER
    Usage: ruby scripts/migrate-tableau.rb --workbook <name>|--workbook-id <luid> \\
             --connection <SIGMA_CONNECTION_ID> [--folder <id>] [options]

    FAST PATH (workbook-layer re-entry, the exit-4 handoff): passing BOTH
    --reuse-dm <id> AND --wb-spec <path> skips Tableau discovery and the
    decisions checkpoint entirely and runs: DM readback -> __DM_ID__/
    __DM_ELEMENT__ substitution -> validate -> preflight -> workbook POST/PUT ->
    layout -> parity plan -> exit 12. Discovery artifacts already in the workdir
    (dashboard-layout.json, views/*.csv, workbook-content.twb) are reused for
    layout/parity; if any are missing, --yes proceeds DEGRADED and prints what's
    missing (discovery is never re-run under --yes), while without --yes the run
    falls back to full discovery. A bare --reuse-dm (no id) or --dm-spec always
    takes the full path.

    Options:
  BANNER
  o.on('--workbook NAME')    { |v| opts[:wb_name] = v }
  o.on('--workbook-id LUID') { |v| opts[:wb_id]   = v }
  o.on('--connection ID')    { |v| opts[:conn]    = v }
  o.on('--folder ID')        { |v| opts[:folder]  = v }
  o.on('--db NAME')          { |v| opts[:db]      = v }
  o.on('--schema NAME')      { |v| opts[:schema]  = v }
  o.on('--table-mapping PAIR',
       "'TabRelation=WAREHOUSE_TABLE' — remap a Tableau logical table to its physical " \
       'warehouse table (repeatable). Needed for packaged-extract (.twbx) workbooks whose ' \
       'sheet name ("Orders$") does not match the warehouse table ("ORDERS"). The trailing ' \
       '"$" extract suffix is stripped automatically, so a mapping is only required when the ' \
       'stripped name still differs.') do |v|
    k, val = v.split('=', 2)
    abort "--table-mapping expects 'Src=DEST' (got #{v.inspect})" if val.nil? || k.to_s.empty? || val.empty?
    (opts[:table_mapping] ||= {})[k.strip] = val.strip
  end
  o.on('--column-mapping PAIR',
       "'ExtractCaption=WAREHOUSE_COL' — remap a base column whose extract caption " \
       'is a genuine RENAME of the warehouse column (repeatable). Separator-folding ' \
       'already handles "Country/Region"/"Sub-Category"; use this only for true renames ' \
       'like "State"=STATE_PROVINCE, else the column is dropped as phantom. The original ' \
       'caption is kept as the Sigma column display name.') do |v|
    k, val = v.split('=', 2)
    abort "--column-mapping expects 'Src=DEST' (got #{v.inspect})" if val.nil? || k.to_s.empty? || val.empty?
    (opts[:column_mapping] ||= {})[k.strip] = val.strip
  end
  o.on('--specs PATH')       { |v| opts[:specs]   = File.expand_path(v) }
  # Agent-authored JSON specs — the manual path's re-entry into the GATED spine.
  # When the mechanical converter backend is unavailable, the agent authors the DM
  # (and optionally the workbook) spec as JSON and re-runs with these flags, instead
  # of hand-driving raw POSTs that skip preflight/control lint + Phase-6 + the hard
  # gate. The JSON is wrapped into the same `Specs` contract the .rb override uses,
  # so POST → lint → layout → parity → assert-phase6-ran all run unchanged.
  # The workbook JSON may reference the data model via the placeholder idiom
  # "__DM_ID__" (top-level dataModelId) and "__DM_ELEMENT__:<ElementName>"
  # (per-element source) — both are substituted against the live readback ids.
  o.on('--dm-spec PATH', 'agent-authored data-model spec JSON (fresh DM build through the gated spine)') { |v| opts[:dm_spec] = File.expand_path(v) }
  o.on('--wb-spec PATH', 'agent-authored workbook spec JSON (re-enters the gated spine). With an explicit ' \
                         '--reuse-dm <id> this takes the FAST PATH (see banner).') { |v| opts[:wb_spec] = File.expand_path(v) }
  o.on('--allow-manual-spec REASON', 'deliberately hand-author --dm-spec/--wb-spec COLD (no prior ' \
                                     'orchestrator STOP). Normally the orchestrator authorizes this path; ' \
                                     'this waives that requirement — named in the report.') { |v| opts[:allow_manual_spec] = v }
  o.on('--force-route-switch REASON', 'override the route-persistence check (a workdir driven via one route ' \
                                      'must normally be finished the same way) — counted as a quality waiver; ' \
                                      'name it in your report.') { |v| opts[:force_route_switch] = v }
  o.on('--out DIR')          { |v| opts[:out]     = File.expand_path(v) }
  # Alias: every sibling script (doctor, intake, verify-complete, assert-*)
  # takes --workdir; this orchestrator uniquely used --out — a copy-paste trap
  # that aborted runs at argv parse (field-caught round 2). Both now work.
  o.on('--workdir DIR', 'alias of --out') { |v| opts[:out] = File.expand_path(v) }
  o.on('--answers JSON')     { |v| opts[:answers] = v }
  o.on('--yes')              {     opts[:yes]     = true }
  # W2.5 — foreground half of the wave-2 poll/wait contract. Optparse consumes
  # both --wait=900 and a separated bare integer; a bare --wait takes 1500s.
  o.on('--wait [SECONDS]', Integer, 'W2.5: drive the FULL run as ONE tool call — re-spawns this command in the ' \
       'background (stdout+stderr → <WORK>/migrate-full.log), waits up to SECONDS (default 1500), then exits with ' \
       'the INNER exit code verbatim; exit 26 = budget exhausted, run STILL ALIVE (pid + log named — never a failure). ' \
       'Pair with a tool timeout ≥ 25 min.') { |v| opts[:wait_mode] = true; opts[:wait_budget] = v }
  o.on('--quiet', 'machine stdout for background-log poll turns: one JSON event line per phase ' \
                  'entry/completion + WARN/FATAL/error lines + a terminal state JSON; full ' \
                  'human output goes to <WORK>/migrate-full.log. Default output unchanged.') { opts[:quiet] = true }
  o.on('--name PREFIX')      { |v| opts[:name]    = v }
  o.on('--force')            {     opts[:force]   = true }
  o.on('--reuse-dm [ID]', 'opt IN to DM reuse (default: build new; bare flag = use find-or-pick-dm\'s ' \
                          'recommendation). An EXPLICIT id combined with --wb-spec takes the FAST PATH.') { |v| opts[:reuse_dm] = v || :recommended }
  o.on('--skip-reuse-scan')  {     opts[:skip_reuse] = true }
  o.on('--fact-table NAME', 'override the object-model fact election: NAME (case-insensitive warehouse table / ' \
                            'logical-table name) becomes the fact/base element every LOD/Top-N/window helper and ' \
                            'the master build from. Use when the announced election is wrong. LOCAL converter build ' \
                            'only — the hosted MCP arg schema cannot take it (a hosted run WARNs and keeps only the ' \
                            'Ruby-side pick_fact preference).') { |v| opts[:fact_table] = v }
  o.on('--skip-sql-ident-gate REASON', 'waive the pre-POST Custom-SQL identifier gate (check-sql-idents against the ' \
                                       'fetched warehouse catalog) — REQUIRED reason; recorded as a quality waiver; ' \
                                       'name it in your report') { |v| opts[:skip_sql_ident_gate] = v }
  o.on('--skip-dashboard-read REASON', 'waive the Phase 1d source dashboard-read gate — REQUIRED reason; name it in your report') { |v| opts[:skip_dashboard_read] = v }
  o.on('--skip-doctor-gate REASON', 'waive the Step-0 environment gate (doctor.json) — REQUIRED reason; name it in your report') { |v| opts[:skip_doctor_gate] = v }
  o.on('--skip-ref-check REASON', 'waive the pre-POST workbook ref-resolution gate — REQUIRED reason; name it in your report') { |v| opts[:skip_ref_check] = v }
  o.on('--fast REASON', 'TRUSTED table/pivot-only fast path (opt-in, OFF by default): at --finalize, waive the ' \
                        'Phase-6f visual render gate (8) + recorded visual comparison (8b) with REASON — for a ' \
                        'workbook whose elements are detail tables / pivots with no charts, so no PNG render or ' \
                        'side-by-side is needed. Recorded as a quality waiver (counts toward the >2 budget cap). ' \
                        'Do NOT use for chart-bearing dashboards.') { |v| opts[:fast] = v }
  o.on('--skip-extract-landing REASON', 'proceed although every datasource is an embedded file extract and no ' \
                                        'landing manifest was found (exit 17 otherwise) — you own the DM table paths') { |v| opts[:skip_extract_landing] = v }
  o.on('--no-auto-land', 'keep the manual extract-landing gate (exit 17) instead of auto-running land-extracts.py ' \
                         'when the .twbx payload + connection id are already available') { opts[:no_auto_land] = true }
  o.on('--skip-postpublish-guide REASON', 'waive the shared gate 11 (POSTPUBLISH_GUIDE.md must exist when the ' \
                                          'source carries dashboard actions) AND the Tableau-only guide-residue ' \
                                          'check (assert-action-gates.rb — the guide must equal the action ' \
                                          'ledger residue) — name it in your report. Does NOT waive G1 ' \
                                          '(action-schema validation, also in assert-action-gates.rb): a waiver ' \
                                          'on the hand-off guide is not a waiver on spec validity.') { |v| opts[:skip_postpublish_guide] = v }
  o.on('--skip-datasource-filters REASON', 'waive the #483 datasource-filter gate (always-on Tableau data-source ' \
                                           'filters must be applied as master defaults, not silently dropped) — REQUIRED reason; name it in your report') { |v| opts[:skip_datasource_filters] = v }
  o.on('--row-scale F', Float) { |v| opts[:row_scale] = v }
  o.on('--page-rows N', Integer, 'override the layout row model (passed through to build-dashboard-layout.rb; ' \
                                 'wins over the px-derived canvas rows)') { |v| opts[:page_rows] = v }
  o.on('--master-col PAIR', "'Name=<Sigma formula>' — extra master column (repeatable). The resume path " \
                            'for the exit-4 handoff when a chart dim is a master-level calc the mechanical ' \
                            'map cannot derive (e.g. a binned/categorized dimension).') do |v|
    nm, fx = v.split('=', 2)
    abort "--master-col expects 'Name=<Sigma formula>', got #{v.inspect}" if nm.to_s.empty? || fx.to_s.empty?
    (opts[:master_cols] ||= []) << [nm, fx]
  end
  # PLAN-v3 PR-17 (default ON). De-share the single hidden master
  # into per-page (per-dashboard) instances so a page's controls filter only
  # that page's tiles (a shared cross-page master composes every page's filters
  # on one master — V5.6-CONTROLS-AUDIT D11). Self-gating: a no-op unless >=2
  # pages draw on the master, so single-page builds stay byte-identical.
  o.on('--per-page-masters', 'give each dashboard page its own thin master instance (default; fixes cross-page control ' \
                             'leakage and wide-master query cost; no-op for single-page workbooks)') { opts[:per_page_masters] = true }
  o.on('--finalize')         {     opts[:finalize] = true }
  o.on('--actuals PATH')     { |v| opts[:actuals] = File.expand_path(v) }
  # Finalize ergonomics (issue #422): forward two flags phase6-parity /
  # assert-phase6-ran already accept but the orchestrator previously swallowed,
  # blocking operators mid-finalize.
  o.on('--regen-plan', 'force phase6-parity to REBUILD parity-plan.json from scratch (forwarded to phase6-parity.rb). Use after a workbook re-POST changes element ids, or to discard a stale plan.') { opts[:regen_plan] = true }
  o.on('--skip-anchors-gate REASON', 'waive gate 13 (source-anchor value verification) at --finalize — REQUIRED reason; ' \
       'forwarded to assert-phase6-ran.rb (budget-counted waiver). Use ONLY when the source image values are genuinely ' \
       'untranscribable; name it in your migration report.') { |v| opts[:skip_anchors_gate] = v }
  o.on('--allow-empty-tiles REASON', 'accept gate 13\'s empty-tile block at --finalize — REQUIRED reason; forwarded to ' \
       'assert-phase6-ran.rb (budget-counted waiver; W2.10 audit rider).') { |v| opts[:allow_empty_tiles_gate] = v }
  o.on('--allow-missing-tiles N', Integer) { |v| opts[:allow_missing_tiles] = v }
  o.on('--min-pass-rate F', Float, 'accept a parity pass-rate below 1.0 at the gate — ONLY for honest, ' \
                                   'NAMED divergences (LOD placeholders / cross-grain semantics)') { |v| opts[:min_pass_rate] = v }
  # Phase E (opt-in) — Enhance. NEVER runs without --enhance; with --enhance
  # but no --enhance-accept the run stops at exit 14 with the scan proposals
  # (present them per-item to the human, e.g. AskUserQuestion), then re-run
  # --finalize with --enhance-accept <id,id,...> or 'all-low-risk'.
  o.on('--enhance')          {     opts[:enhance] = true }
  o.on('--enhance-accept L') { |v| opts[:enhance_accept] = v }
  # Phase 5g — RCF (render-compare-fix) loop budget. Default 5 passes; the loop
  # is agent-driven (staged at pass-1 tail, enforced at --finalize via gate 8d /
  # --require-fidelity-ledger — DEFAULT-ON, PR-11). --rcf-passes 0 DISABLES it
  # with a loud WARN and the finalize gate records the NAMED --skip-fidelity-gate
  # waiver (budget-counted) instead of requiring the ledger. Batch/headless
  # callers pass 2.
  o.on('--rcf-passes N', Integer, 'Phase 5g render-compare-fix loop budget (default 5; 0 disables it with a loud WARN and records the named gate-8d waiver — budget-counted, never silent).') { |v| opts[:rcf_passes] = v }
  # W2.1 — tier ratchet. 'auto' (default) = the mechanical Tier.detect predicate
  # over on-disk 0c artifacts; S|M|full override the predicate (a ledgered
  # decision). Tier never removes a gate — Tier-S shrinks budgets/duplicate
  # oracles only (rcf 5→1, W2.4 checkpoint auto-defaults, lane B's gate scale).
  o.on('--tier T', %w[auto S M full], "tier ratchet (W2.1): 'auto' (default) detects from 0c artifacts (fail-closed to " \
       "'full' on unreadable inputs); S|M|full override the predicate — the override is recorded in decisions.jsonl.") { |v| opts[:tier] = v }
  # W2.2 — factory default = ONE pass + measured parity + the punch list
  # (PUNCHLIST.md rendered from the shipped degradation ledger at every
  # finalize terminal). --certified opts back into loop-to-green.
  o.on('--certified', 'W2.2: certified loop-to-green — RCF budget restored to 5 (even on Tier-S) and the verifier ' \
       'countersignature contract applies (refs/orchestration.md). Without it, factory mode ships one pass + ' \
       'measured parity + <WORK>/PUNCHLIST.md.') { opts[:certified] = true }
  # Gate 7b (PR-13) — the runtime control flip test is DEFAULT-ON at --finalize
  # (pass 1 also stamps control_flip_required into migrate-state.json so even a
  # standalone gate run enforces it). The census (gate 7c) proves the controls
  # EXIST; only the flip proves they DO something. The probe needs the live
  # export API — this waiver is the sanctioned out when it genuinely cannot run
  # (recorded, budget-counted, named in the report). Never silent.
  o.on('--skip-flip-test REASON', 'waive gate 7b (runtime control flip test, DEFAULT-ON at --finalize) — rides to ' \
                                  'assert-phase6-ran.rb as the named --skip-control-flip waiver (budget-counted); ' \
                                  'name it in your report.') { |v| opts[:skip_flip_test] = v }
  o.on('--converter MODE', %w[local hosted], "converter backend: 'local' (default; zero-config, no " \
       'data egress — uses the vendored converter/tableau.mjs unless TABLEAU_MCP_BUILD points at a ' \
       "fresher build) or 'hosted' (sends the .twb to sigma-data-model-mcp.onrender.com — explicit " \
       'consent to upload customer schema/SQL).') { |v| opts[:converter] = v }
  # ---- Per-dashboard scoping (LARGE workbooks: build+gate ONE tab at a time) ----
  # `--dashboard "<name>"` (repeatable) scopes parse-twb-layout, build-charts, and
  # the parity plan to a single Tableau dashboard, so a 14-tab workbook is built
  # and gated one tab at a time. `--page <id>` is the zone-root-id equivalent. When
  # a Sigma workbook ALREADY exists for the prior tabs, pass `--workbook <sigma-id>`
  # to APPEND the new dashboard's page to that workbook (PUT the merged spec)
  # instead of POSTing a brand-new workbook.
  o.on('--dashboard NAME', 'Build/gate only this Tableau dashboard (repeatable). Enables one-tab-at-a-time large-workbook migration.') { |v| (opts[:dashboards] ||= []) << v }
  o.on('--page ID',        'Scope to the dashboard with this zone-root id (alt to --dashboard; repeatable).') { |v| (opts[:pages] ||= []) << v }
  o.on('--workbook-target ID', 'Existing Sigma workbook id to APPEND the scoped dashboard page to (PUT-append instead of POST-new).') { |v| opts[:wb_target] = v }
  o.on('--reuse-workbook ID', 'Existing Sigma workbook id to UPDATE IN PLACE (PUT the freshly-built full spec to it, ' \
                              'same id/URL, layout preserved) instead of POSTing a NEW workbook — the workbook twin of ' \
                              '--reuse-dm. Iterating a fix? Re-run with --reuse-dm <id> --reuse-workbook <id> to edit the ' \
                              'SAME dashboard rather than orphaning it.') { |v| opts[:reuse_workbook] = v }
end.parse!

# --db/--schema travel together: a lone half used to be silently completed by a
# fabricated default, which 404s in every real org (E2E-caught). Fail loudly.
if opts[:db].nil? ^ opts[:schema].nil?
  abort 'FATAL: --db and --schema must be passed together (a warehouse table path needs both).'
end

# Share-URL intake (field-caught: three independent runs each rediscovered that
# the MOST COMMON Tableau link shape — /#/site/<site>/views/<workbookContentUrl>/<view>
# — resolves through NO existing path: resolve-project.rb is numeric-vizportal-only
# and --workbook <name> fails because a workbook's display Name routinely diverges
# from its contentUrl slug). Accept a URL pasted into --workbook, parse the
# workbookContentUrl segment, and resolve it via the REST contentUrl filter.
# Numeric /workbooks/<id> and /projects/<id> URLs keep routing to resolve-project.rb.
if opts[:wb_name].to_s =~ %r{\Ahttps?://} || opts[:wb_name].to_s =~ %r{#/site/}
  url = opts[:wb_name]
  if (m = url.match(%r{/views/([^/?#]+)}))
    content_url = m[1]
    puts "── share-URL intake: /views/ link → resolving workbook contentUrl #{content_url.inspect}"
    require_relative 'lib/tableau_rest'
    # Cold-env order bug (field-caught round 2, re-caught round 3): with only PAT
    # creds set this resolver ran before a session existed and crashed. Round 2
    # rescued a missing TABLEAU_SITE_ID — but a 2026-07 field-workbook run had a
    # STALE TABLEAU_SITE_ID set in the env file with NO AUTH_TOKEN, so site_id
    # returned fine, the mint was skipped, and find_workbook_by_content_url then
    # crashed on "TABLEAU_AUTH_TOKEN not set" — sending the run down a 4.5-min
    # token detour (incl. a permission-classifier denial). Mint when EITHER the
    # site id OR the auth token is unavailable.
    begin
      Tableau.site_id
      Tableau.auth_token
    rescue Tableau::Error
      puts '   no Tableau session yet (missing site id or auth token) — minting one in-process (PAT signin)'
      Tableau.refresh_token!
    end
    hit = Tableau.find_workbook_by_content_url(content_url)
    abort "FATAL: no workbook with contentUrl #{content_url.inspect} is visible to this PAT — " \
          'check the site (TABLEAU_SITE_CONTENT_URL) and the PAT user\'s project permissions.' unless hit
    opts[:wb_id] = hit['id']
    opts[:wb_name] = nil
    puts "   resolved: #{hit['name'].inspect} → workbook LUID #{hit['id']}"
  elsif url =~ %r{/(workbooks|projects)/(\d+)}
    abort "FATAL: numeric vizportal URL — resolve it first:\n" \
          "  ruby scripts/resolve-project.rb --vizportal-id #{Regexp.last_match(2)}\n" \
          'then re-run with --workbook-id <luid>.'
  else
    abort 'FATAL: unrecognized Tableau URL shape — pass --workbook-id <luid>, or a /views/… share link.'
  end
end

abort 'missing --workbook or --workbook-id' unless opts[:wb_name] || opts[:wb_id]
# intake.rb (front-door) caches the resolved connection in <out>/connection.json; honor it
# when --connection is omitted so the agent need not re-pass the id it just resolved.
opts[:conn] ||= (JSON.parse(File.read(File.join(opts[:out], 'connection.json')))['connection_id'] rescue nil) if opts[:out]
abort 'missing --connection (pass --connection <id>, or run intake.rb first and point --out at its --workdir)' unless opts[:conn] || opts[:finalize]

slug = (opts[:wb_name] || opts[:wb_id]).gsub(/[^A-Za-z0-9_-]/, '-').squeeze('-')
WORK = opts[:out] || File.expand_path("~/tableau-migration/#{slug}")
FileUtils.mkdir_p(File.join(WORK, 'views'))

# ── --quiet machine stdout (speed review #3 slice; refs/performance.md) ──────
# Poll turns against a background log re-pay every banner on every read. With
# --quiet, receiverless `puts` output (banners, child output, detail lines) is
# written to <WORK>/migrate-full.log instead of stdout; stdout carries ONLY
# WARN/FATAL/error-shaped lines, one JSON event line per phase entry/completion
# (quiet_event), and a terminal state JSON at exit. `warn` (stderr) is
# untouched. Default (no --quiet) behavior is byte-identical — the override is
# not even defined.
QUIET = !!opts[:quiet]
QUIET_FULL_LOG = File.join(WORK, 'migrate-full.log')
# Pass-through classes: error shapes AND the house one-line verdict markers
# ([OK]/[PASS]/[SKIP]/[FAIL]/[WARN]) — children spawned via system() (the
# Step-0 doctor gate) write those markers straight to stdout, and they are
# exactly the "one-line verdicts" a poll turn wants.
QUIET_PASS_RE = /\A\s*(?:⚠|⛔|✗|WARN\b|FATAL\b|ERROR\b|error:|\[(?:OK|PASS|SKIP|FAIL|WARN)\])/i
if QUIET
  def puts(*args)
    lines = args.empty? ? [''] : args.flatten.map(&:to_s)
    begin
      File.open(QUIET_FULL_LOG, 'a') { |f| lines.each { |l| f.puts(l) } }
    rescue StandardError
      lines.each { |l| $stdout.puts(l) } # sidecar unwritable → degrade to loud
      return nil
    end
    lines.each { |l| $stdout.puts(l) if l =~ QUIET_PASS_RE }
    nil
  end
end
# One machine-readable event line (stdout, bypasses the quiet filter). No-op
# without --quiet so default stdout stays byte-identical.
def quiet_event(ev, fields = {})
  return unless QUIET
  $stdout.puts(JSON.generate({ 'ev' => ev }.merge(fields)))
rescue StandardError
  nil
end
at_exit do
  code = $!.is_a?(SystemExit) ? $!.status : ($! ? 1 : 0)
  quiet_event('exit', 'code' => code, 'workdir' => WORK, 'full_log' => QUIET_FULL_LOG)
end if QUIET

# ── W2.5 — --wait[=SECONDS]: the one-tool-call driving contract ──────────────
# Foreground half of the wave-2 poll/wait contract. The wrapper re-spawns this
# exact command (minus --wait) in the BACKGROUND, stdout+stderr appended to
# <WORK>/migrate-full.log, and waits up to the budget (default 1500s):
#   child exits within budget → the wrapper exits with the INNER exit code,
#     VERBATIM — 0/3/4/10/11/12/16/18/… keep their documented meanings;
#   budget exhausted → exit 26 = "wait budget exhausted, run STILL ALIVE":
#     pid + log + state path are named, the child keeps running, nothing is
#     killed and no failure is invented. Re-attach with another --wait run of
#     the same command, or poll per the G2 cadence (a migrate-state.json
#     phase transition, else every ≥90s — never tighter).
# Wait-mode stdout is ≤5 lines (plus quiet_event JSON under --quiet): the
# point is ONE cheap tool call instead of the ~8-12 background poll turns.
# Exit 26 is free in this script's exit space (the gate's own exit 26 lives in
# assert-phase6-ran's process; the finalize spine re-maps it to 0/3).
if opts[:wait_mode]
  _wb = (opts[:wait_budget] || 1500).to_i
  _wb = 1500 unless _wb.positive?
  _child_argv = []
  _i = 0
  while _i < ORIGINAL_ARGV.length
    _a = ORIGINAL_ARGV[_i]
    if _a == '--wait'
      _i += 1
      _i += 1 if ORIGINAL_ARGV[_i].to_s =~ /\A\d+\z/ # optparse consumed the separated value
      next
    elsif _a.start_with?('--wait=')
      _i += 1
      next
    end
    _child_argv << _a
    _i += 1
  end
  _wait_state = File.join(WORK, 'migrate-state.json')
  _wait_pid = Process.spawn(RbConfig.ruby, __FILE__, *_child_argv, { %i[out err] => [QUIET_FULL_LOG, 'a'] })
  puts "── --wait: run driving in background (pid #{_wait_pid}; budget #{_wb}s) ──"
  puts "   log:   #{QUIET_FULL_LOG}"
  puts "   state: #{_wait_state} (G2 poll cadence if you detach: phase transition, else ≥90s)"
  quiet_event('wait', 'pid' => _wait_pid, 'log' => QUIET_FULL_LOG, 'state' => _wait_state, 'budget_s' => _wb)
  _wait_deadline = Time.now + _wb
  _wait_st = nil
  loop do
    _done = begin
      Process.waitpid2(_wait_pid, Process::WNOHANG)
    rescue Errno::ECHILD
      nil
    end
    if _done
      _wait_st = _done[1]
      break
    end
    break if Time.now >= _wait_deadline
    sleep 2
  end
  if _wait_st
    _code = _wait_st.exitstatus || 1 # signal-killed child → generic failure, still verbatim-shaped
    puts "   inner exit #{_code} (passed through verbatim)"
    quiet_event('wait-exit', 'code' => _code)
    exit(_code)
  end
  puts "⚠ WAIT BUDGET EXHAUSTED (#{_wb}s) — the run is STILL ALIVE (pid #{_wait_pid}); exit 26 is NOT a failure."
  puts "   re-attach: re-run this exact command (same --wait), or tail #{QUIET_FULL_LOG}"
  quiet_event('wait-timeout', 'code' => 26, 'pid' => _wait_pid, 'log' => QUIET_FULL_LOG)
  exit 26
end

# ── E9.6 — thread mission.json STATED scope into the orchestrator ────────────
# The mission intake (SKILL.md Step −1 / MIGRATION_REQUEST.md) records the
# user's stated scope; field session S3 proved the datum was consumed by
# NOTHING — a one-dashboard mission ran unscoped over all 5 dashboards. Consume
# it here: a stated dashboard scope (scope.dashboards / scope.dashboard, or a
# single-view /#/views/<wb>/<view> URL in scope.value/scope.url) maps onto the
# existing --dashboard machinery. Explicit --dashboard/--page flags OVERRIDE
# mission.json; inferred provenance is never silently acted on (WARN — the
# MIGRATION_REQUEST rule routes inferred scope through the user first);
# unscoped missions behave exactly as today. --finalize resumes pass 1's scope.
def mission_scope_for(work)
  path = File.join(work.to_s, 'mission.json')
  return nil unless File.exist?(path)
  doc = begin
    JSON.parse(File.read(path, encoding: 'bom|utf-8'))
  rescue StandardError
    return { 'error' => 'mission.json is unreadable/malformed JSON' }
  end
  scope = doc.is_a?(Hash) ? doc['scope'] : nil
  return nil unless scope.is_a?(Hash)
  names = Array(scope['dashboards']).map(&:to_s).reject(&:empty?)
  names << scope['dashboard'].to_s unless scope['dashboard'].to_s.empty?
  segments = []
  (Array(scope['value']) + [scope['url']]).flatten.compact.each do |v|
    m = v.to_s.match(%r{/views/[^/?#]+/([^/?#]+)})
    segments << m[1] if m
  end
  return nil if names.empty? && segments.empty?
  { 'names' => names.uniq, 'view_segments' => segments.uniq,
    'provenance' => scope['provenance'].to_s }
end

MISSION_SCOPE = opts[:finalize] ? nil : mission_scope_for(WORK)
MISSION_VIEW_SEGMENTS = []
if MISSION_SCOPE && MISSION_SCOPE['error']
  warn "WARN: #{MISSION_SCOPE['error']} — mission scope NOT applied"
elsif MISSION_SCOPE
  if (opts[:dashboards] || []).any? || (opts[:pages] || []).any?
    # Explicit flags override mission.json. Narrower-than-mission is never
    # silent (red-team scope-cut amendment): record the decision.
    m_names = MISSION_SCOPE['names'].map(&:downcase)
    f_names = (opts[:dashboards] || []).map(&:downcase)
    if MISSION_SCOPE['provenance'] == 'stated' && m_names.any? && f_names.any? &&
       (f_names - m_names).empty? && f_names.length < m_names.length
      warn "WARN: --dashboard flags narrow the mission's stated scope " \
           "(#{f_names.length} of #{m_names.length} dashboard(s)) — recorded in decisions.jsonl"
      Offramp.decision(WORK, kind: 'scope-narrowed',
                       question: "mission.json stated scope: #{MISSION_SCOPE['names'].join(', ')}",
                       answer: "flags narrowed to: #{(opts[:dashboards] || []).join(', ')}",
                       decided_by: 'relayed')
      Offramp.log(WORK, kind: 'mission-scope', detail: "narrowed by flags: #{(opts[:dashboards] || []).join(', ')}")
    end
  elsif MISSION_SCOPE['provenance'] != 'stated'
    warn "WARN: mission.json scope has provenance #{MISSION_SCOPE['provenance'].inspect} (not 'stated') — " \
         'NOT applied. Confirm the scope with the user (MIGRATION_REQUEST.md: any inferred field → stop and confirm).'
  else
    opts[:dashboards] = MISSION_SCOPE['names'].dup if MISSION_SCOPE['names'].any?
    MISSION_VIEW_SEGMENTS.concat(MISSION_SCOPE['view_segments'])
    applied = MISSION_SCOPE['names'] + MISSION_VIEW_SEGMENTS.map { |s| "view-URL:#{s}" }
    puts "── mission scope (stated): #{applied.join(', ')} — parse, open questions, gap stops, and build planning " \
         'run scoped (the gap scan itself is workbook-wide; gaps it cannot attribute to a worksheet still stop)'
    Offramp.log(WORK, kind: 'mission-scope', detail: "stated scope applied: #{applied.join(', ')}")
  end
end

# Per-dashboard scope flags, assembled once and threaded into parse-twb-layout,
# extract-calc-fields, build-charts, and auto-parity. Empty ⇒ whole-workbook
# (current behavior). MUTABLE on purpose: a mission single-view URL scope
# resolves its view segment to a dashboard NAME only after get-workbook.json
# lands (the views list), and appends here before the first consumer.
DASH_SCOPE = (opts[:dashboards] || []).flat_map { |d| ['--dashboard', d] } +
             (opts[:pages]      || []).flat_map { |p| ['--page', p] }
def scoped?
  !DASH_SCOPE.empty?
end

# ── run_id (run-scoped completion sentinels) ─────────────────────────────────
# Each PASS-1 invocation mints a fresh uuid (persisted in the run-state ledger,
# copied into migrate-state.json at the end of pass 1). --finalize RESUMES the
# run, so it reuses the pass-1 id. The sentinels (parity-pending.json /
# phase6-success.json) are keyed to it: a success marker from a previous run id
# can never vouch for the current run.
RUN_ID = if opts[:finalize]
           (JSON.parse(File.read(File.join(WORK, 'migrate-state.json')))['run_id'] rescue nil) ||
             RunState.run_id(WORK)
         else
           RunState.new_run_id!(WORK)
         end

# G2 launch banner (run-2 field failure): a full pass runs 5–20+ minutes, and a
# driving agent that launched it under the DEFAULT 2-minute foreground Bash
# timeout killed PASS-1 at 120s (exit 143) and wasted the whole pass. Say so
# IMMEDIATELY at launch, before any long phase, so the kill is prevented rather
# than diagnosed. STDOUT flushes line-by-line, so a backgrounded run's log shows
# liveness via the per-phase banners.
$stdout.sync = true
puts "── migrate-tableau #{opts[:finalize] ? '--finalize' : 'PASS'} · run #{RUN_ID.to_s[0, 8]} ──"
puts '   ⏱  a full pass runs 5–20+ minutes. Run me IN BACKGROUND (writing a log) or with a'
puts '   tool timeout ≥ 20 minutes — the default 2-minute foreground limit WILL kill the pass.'

# 🚧 Step-0 STALENESS HARD GATE (escalates the doctor's SHA/build-age WARN).
# The doctor stamps {behind_count, days_since_commit} into doctor.json; a
# checkout behind upstream (or >14 days old) silently re-hits bugs fixed weeks
# earlier, so the WARN is now enforced at run start. Waive with
# SIGMA_ALLOW_STALE="<reason>" (recorded as an off-ramp). Best-effort read:
# a missing/unreadable doctor.json is the doctor gate's problem, not this one's.
# ORDER IS DELIBERATE: staleness runs BEFORE the bootstrap-sentinel environment
# gate below. A stale checkout must refuse with the stale remediation (git pull /
# reinstall) even when the sentinel is missing — the sentinel gate's remediation
# is "run the bootstrap", which on a stale checkout would just bootstrap (and
# bless) a stale build. Pinned by test-stale-gate.rb legs 1-2.
begin
  _st_path = [File.join(WORK, 'doctor.json'),
              File.expand_path('~/.sigma-migration/doctor.json')].find { |p| File.exist?(p) }
  _st = _st_path ? JSON.parse(File.read(_st_path, encoding: 'bom|utf-8')) : {}
  _st_bc = _st['behind_count']
  _st_days = _st['days_since_commit']
  _stale_why = if _st_bc.is_a?(Integer) && _st_bc.positive?
                 "#{_st_bc} commit(s) behind upstream"
               elsif _st_days.is_a?(Integer) && _st_days > 14
                 "build is #{_st_days} days old (>14)"
               end
  if _stale_why
    _stale_reason = ENV['SIGMA_ALLOW_STALE']
    if _stale_reason && !_stale_reason.to_s.empty?
      warn "WARN: STALE skill checkout (#{_stale_why}) — proceeding on SIGMA_ALLOW_STALE=#{_stale_reason}."
      Offramp.log(WORK, kind: 'stale-skill-waived', reason: _stale_reason.to_s, detail: _stale_why)
    else
      abort <<~MSG
        FATAL: stale skill checkout — #{_stale_why} (doctor report: #{_st_path}).
        A stale build silently re-runs bugs already fixed upstream. Update it first:
            git pull            # in the skill/marketplace clone
        …or reinstall the plugin, re-run the doctor (bash scripts/doctor.sh), then retry.
        (Deliberately running a stale build? SIGMA_ALLOW_STALE="<reason>" waives this
        gate — the waiver is recorded and must be named in your report.)
      MSG
    end
  end
rescue JSON::ParserError
  # unreadable doctor.json was already handled (or waived) by the doctor gate
end

# 🚧 Step-0 environment GATE. The doctor writes a doctor.json fingerprint; this
# refuses to run on an env that never passed the doctor, instead of letting the
# pipeline improvise around a missing runtime (the #1 source of cross-user
# inconsistency at multi-user events). Waive with --skip-doctor-gate "<reason>"
# or SIGMA_SKIP_DOCTOR_GATE=<reason>. Runs before every path (pass-1 + finalize).
# Runs AFTER the staleness gate above (see ORDER IS DELIBERATE) — it also
# enforces main's bootstrap-sentinel semantics (PR-15) for non-stale checkouts.
_dg_skip = opts[:skip_doctor_gate] || ENV['SIGMA_SKIP_DOCTOR_GATE']
_dg_cmd = ['ruby', File.join(HERE, 'assert-doctor-ran.rb'), '--workdir', WORK]
_dg_cmd += ['--skip-doctor-gate', _dg_skip] if _dg_skip && !_dg_skip.to_s.empty?
unless system(*_dg_cmd)
  # Host-dispatched bootstrap hint: PowerShell/cmd users get the .ps1 twin, not
  # a bash script they cannot run (RbConfig::CONFIG['host_os'] — docs-level P1.3).
  # PR-15: the remediation is the ONE bootstrap command (idempotent; ends in a
  # doctor run + sentinel) — never a hand-driven runtime install.
  _doc_hint = RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/ ?
                'powershell -ExecutionPolicy Bypass -File scripts\\bootstrap.ps1' :
                'bash scripts/bootstrap.sh'
  abort "FATAL: environment gate failed — run the bootstrap first (#{_doc_hint}; see remediation above), " \
        'or re-run with --skip-doctor-gate "<reason>".'
end

# 🚧 Step-0 CREDENTIAL GATE (fail-closed). The doctor treats missing creds as a
# warning, so a harness that does NOT auto-load ~/.claude/settings.json (Coco,
# Cursor, plain shell) can sail past it and then die at the FIRST Sigma API call
# with an opaque auth error — which a low-context agent misreads as a TASK
# failure and improvises around (hand-rolled curl, self-writing creds, a
# hallucinated token). Resolve creds HERE, before any Tableau/discovery work, and
# stop with the exact remediation if they're absent. Waive only for genuinely
# offline runs with SIGMA_SKIP_CRED_GATE="<reason>".
_cred_skip = ENV['SIGMA_SKIP_CRED_GATE']
_neutral_env = File.expand_path('~/.sigma-migration/env')
_creds_ok = !ENV['SIGMA_API_TOKEN'].to_s.empty? ||
            (!ENV['SIGMA_CLIENT_ID'].to_s.empty? && !ENV['SIGMA_CLIENT_SECRET'].to_s.empty?) ||
            File.exist?(_neutral_env)
if !_creds_ok && (_cred_skip.nil? || _cred_skip.to_s.empty?)
  abort <<~MSG
    FATAL: no Sigma credentials resolvable — the run would fail at the first API call.
    This almost always means you are NOT on Claude Code (which auto-loads
    ~/.claude/settings.json). Other harnesses (Coco, Cursor, plain shell) do not,
    so the neutral credential file is REQUIRED. Fix it ONCE, in a real terminal:
        ruby scripts/setup.rb        # writes ~/.sigma-migration/env
    …or export SIGMA_CLIENT_ID + SIGMA_CLIENT_SECRET (and SIGMA_BASE_URL) into the
    environment this orchestrator runs in. Then re-run this exact command.
    (Genuinely offline/no-Sigma run? Re-run with SIGMA_SKIP_CRED_GATE="<reason>".)
  MSG
end
if !_creds_ok && _cred_skip && !_cred_skip.to_s.empty?
  warn "WARN: credential gate waived (SIGMA_SKIP_CRED_GATE=#{_cred_skip}) — Sigma calls will fail if reached."
  Offramp.log(WORK, kind: 'cred-gate-waived', reason: _cred_skip.to_s)
end
Offramp.log(WORK, kind: 'doctor-gate-waived', reason: _dg_skip.to_s) if _dg_skip && !_dg_skip.to_s.empty?

# 🚧 Step-0 TABLEAU CREDENTIAL GATE (fail-closed). Tableau auth is a SECOND,
# separate system from Sigma — and its absence was the #1 recurring blocker: the
# orchestrated discovery lane signs in via PAT REST (tableau_rest.rb), so when
# TABLEAU_PAT_* aren't in the env (people run setup.rb for Sigma but not
# setup-tableau.rb; non-Claude-Code harnesses don't auto-load them) the run
# starts and dies DEEP in discovery with an opaque "could not mint a Tableau
# token / end of file reached" that a low-context agent flails against. Resolve
# it HERE instead. Only required when FRESH discovery will run — skip on
# --finalize (no discovery) and when discovery is being REUSED (stamp present),
# and skip if the agent is driving discovery through the Tableau MCP
# (SIGMA_TABLEAU_VIA_MCP=1). Waive with SIGMA_SKIP_TABLEAU_GATE="<reason>".
_tab_skip     = ENV['SIGMA_SKIP_TABLEAU_GATE']
_tab_via_mcp  = ENV['SIGMA_TABLEAU_VIA_MCP'].to_s == '1'
_tab_reuse    = File.exist?(File.join(WORK, 'discovery-stamp.json'))
_tab_needed   = !opts[:finalize] && !_tab_reuse && !_tab_via_mcp
# Contents check, not mere existence: the neutral file often has Sigma creds
# (setup.rb) but NOT Tableau (setup-tableau.rb) — the exact gap that let runs
# start and fail deep. Require the Tableau PAT to actually be present.
_tab_creds_ok = (!ENV['TABLEAU_PAT_NAME'].to_s.empty? && !ENV['TABLEAU_PAT_SECRET'].to_s.empty?) ||
                (File.exist?(_neutral_env) && File.read(_neutral_env).include?('TABLEAU_PAT_SECRET'))
if _tab_needed && !_tab_creds_ok && (_tab_skip.nil? || _tab_skip.to_s.empty?)
  abort <<~MSG
    FATAL: no Tableau credentials resolvable — discovery would fail at the Tableau
    sign-in (the "could not mint a Tableau token" / "end of file reached" error).
    Tableau auth is SEPARATE from Sigma: running setup.rb configures Sigma only.
    Fix it ONCE, in a real terminal:
        ruby scripts/setup-tableau.rb    # writes the Tableau PAT to ~/.sigma-migration/env
    …or export TABLEAU_PAT_NAME + TABLEAU_PAT_SECRET + TABLEAU_SITE_CONTENT_URL
    (+ TABLEAU_SERVER_URL) into this environment. If you are driving discovery via
    the Tableau MCP tools instead of a PAT, re-run with SIGMA_TABLEAU_VIA_MCP=1.
    (If sign-in fails even WITH creds set, that is a network/TLS-proxy issue
    reaching your Tableau server, not a missing-cred issue — check connectivity.)
    Then re-run this exact command.  (Waive: SIGMA_SKIP_TABLEAU_GATE="<reason>".)
  MSG
end
if _tab_needed && !_tab_creds_ok && _tab_skip && !_tab_skip.to_s.empty?
  warn "WARN: Tableau credential gate waived (SIGMA_SKIP_TABLEAU_GATE=#{_tab_skip})."
  Offramp.log(WORK, kind: 'tableau-gate-waived', reason: _tab_skip.to_s)
end

# ── Stale-PAT preflight (single, non-retrying live sign-in) ──────────────────
# The presence gate above proves creds EXIST; it does not prove the PAT WORKS. A
# revoked/expired/mistyped PAT otherwise fails deep in discovery after work is
# done — and Tableau LOCKS a PAT after 4 consecutive FAILED sign-ins. Validate it
# ONCE here (a SUCCESSFUL sign-in does NOT count toward lockout, so a healthy PAT
# costs ~1s and warms the token discovery reuses). No retry: on failure we abort
# clean at Step 0 with the regenerate message rather than hammering toward lockout.
# Only on the fresh-PAT discovery path, and skippable with SIGMA_SKIP_CRED_SMOKE
# (the same switch the doctor honors) for offline tests / air-gapped setups.
if _tab_needed && _tab_creds_ok && !_tab_via_mcp && ENV['SIGMA_SKIP_CRED_SMOKE'].to_s.empty?
  begin
    Tableau.refresh_token!   # one live PAT sign-in; raises Tableau::Error on 401 / bad config
    puts '  [preflight] Tableau PAT sign-in OK — token minted.'
  rescue Tableau::Error => e
    Offramp.log(WORK, kind: 'tableau-pat-preflight-failed', reason: e.message.lines.first.to_s.strip) rescue nil
    abort <<~MSG
      FATAL: Tableau PAT sign-in failed at preflight — #{e.message.lines.first.to_s.strip}
      The personal access token is invalid / expired / revoked, or the site is wrong.
      Regenerate the PAT (Tableau → My Account Settings → Personal Access Tokens),
      re-run scripts/setup-tableau.rb, or fix TABLEAU_SITE_CONTENT_URL / TABLEAU_SERVER_URL.
      Validated ONCE on purpose: a bad PAT locks after 4 failed sign-ins, so we do NOT
      retry. (Waive the preflight: SIGMA_SKIP_CRED_SMOKE="<reason>".)
    MSG
  end
end

# ── Design-consistency advisory readout (doctor.json) ────────────────────────
# The hard gate above proves the environment passed; these two are the silent
# DESIGN-variance killers the gate does not block on — surface them at every
# run start. Advisory: the visual gates (8/8b/8d) enforce agent_vision later.
begin
  dj = JSON.parse(File.read(File.join(WORK, 'doctor.json')))
  bc = dj['behind_count']
  if bc.is_a?(Integer) && bc.positive?
    warn "WARN: skill clone is #{bc} commit(s) behind origin/main — newer fidelity machinery exists. " \
         'Run `git pull` in the marketplace clone before converting.'
  end
  if dj['agent_vision'] == false
    warn 'WARN: doctor.json records agent_vision=false — the visual gates (8/8b/8d) cannot legitimately ' \
         'pass from this session (export SIGMA_AGENT_VISION=true from a vision-capable session); ' \
         'see refs/model-fit.md.'
  end
rescue StandardError
  # never fatal — the hard gate above already validated presence/shape
end

TOTAL = 6

# ── Total-runtime handoff nudge (refs/orchestration.md O2) ──────────────────
# Field failure, 2026-07: TWO context-runaways in one quarter — a 6+ hour run,
# and a 131-minute / ~12-pass run (the field workbook) that ended GREEN
# over a dataless workbook. The nudge that should have fired at 90m never did,
# because RunState.stamp overwrote each phase's `ts` on every pass, resetting
# min(ts) each re-run (the comment claiming "the FIRST stamp of pass 1 survives"
# was false). The ledger now persists run_started_at (stamped ONCE) so TOTAL run
# age — across passes/resumes — is computable regardless of re-stamping. When it
# crosses the escalating thresholds, print ONE loud line per threshold pointing
# at the handoff protocol. Advisory only — never changes behavior.
HANDOFF_THRESHOLDS_MIN = [60, 90, 120].freeze
$handoff_nudged_at = []
def handoff_nudge
  return unless defined?(WORK) && WORK
  started = RunState.started_at(WORK)
  first = begin; Time.parse(started.to_s); rescue StandardError; nil; end
  return unless first
  elapsed_min = ((Time.now - first) / 60).round
  crossed = HANDOFF_THRESHOLDS_MIN.select { |t| elapsed_min >= t && !$handoff_nudged_at.include?(t) }.max
  return unless crossed
  $handoff_nudged_at << crossed
  budget = HANDOFF_THRESHOLDS_MIN.last
  puts
  puts "⏰⏰⏰ HANDOFF NUDGE — this run has been going #{elapsed_min}m (thresholds #{HANDOFF_THRESHOLDS_MIN.join('/')}m; hard budget #{budget}m)."
  puts "   Long single-context runs compaction-loop and (field-proven) can drift to a FALSE GREEN."
  puts "   Per refs/orchestration.md (O2): write #{File.join(WORK, 'HANDOFF.md')} and hand off to a"
  puts '   fresh builder agent; resume is cheap (discovery caches + phase stamps skip completed work).'
  puts "   Over #{budget}m: STOP and hand off — do not push a run to GREEN this deep in one context." if elapsed_min >= budget
rescue StandardError
  nil # advisory only — a nudge failure must never touch the conversion
end

# Authorize the manual (hand-authored spec) path — written at every designed
# judgment STOP (converter-stop, the exit-4 workbook handoff, exit-10 decisions,
# exit-11 gap stops). The manual-spec gate refuses --dm-spec/--wb-spec (and
# post-and-readback refuses a standalone run on an orchestrated workdir) unless
# this token exists: the manual path is entered via an orchestrator STOP, not
# cold. Best-effort — bookkeeping never sinks a run.
def authorize_manual_path!(via:, reason:, exit_code:, extra: {})
  # `via` tokens come from the ONE shared vocabulary (E3.6 vocab half:
  # Offramp::AUTHORIZATION_VIA). A token outside it is a coding error at the
  # call site — warn loudly, but never sink the run over bookkeeping.
  warn "WARN: authorize_manual_path! via=#{via.inspect} is not in Offramp::AUTHORIZATION_VIA — " \
       'add the token to the shared vocabulary (lib/offramp.rb) first' \
    unless Offramp::AUTHORIZATION_VIA.include?(via.to_s)
  File.write(File.join(WORK, 'manual-path-authorized.json'),
             JSON.pretty_generate({ 'via' => via, 'reason' => reason,
                                    'exit_code' => exit_code,
                                    'run_id' => (defined?(RUN_ID) ? RUN_ID : nil),
                                    'at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }.merge(extra).compact))
rescue StandardError
  nil
end

def hdr(n, title)
  puts; puts "── Phase #{n}/#{TOTAL} · #{title} ──"
  # Ledger stamp — records that the orchestrator entered this phase (Tier 2
  # run-state chain; assert-run-state.rb audits it). Best-effort; never fatal.
  RunState.stamp(WORK, "phase-#{n}", note: title) if defined?(WORK)
  quiet_event('phase', 'phase' => n.to_s, 'title' => title)
  # Total-runtime check rides every phase header (prints at most once per run).
  handoff_nudge
end
def line(m) puts "   #{m}"; end

# Phase-timing summary — printed at every terminal exit so the discovery
# interleave speedup stays visible in every run (and regressions show up in
# the first slow report instead of an investigation).
START_T = Time.now
PHASE_T = {}
$t_mark = Time.now

# ── Wall-clock budgets (refs/performance.md, workstream S2) ─────────────────
# EXPECTED seconds per phase for a MEDIUM workbook (~10 views / 1-2 dashboards,
# warm caches where a cache exists), calibrated from the GREEN reference run
# (~45-60 min per comparable workbook end-to-end). mark() prints ONE loud
# advisory line when a phase's cumulative time exceeds ~3x its budget — no
# behavioral change, just "this should have taken ~Ys; stop and read
# refs/performance.md#slow-<phase> instead of restarting from scratch".
# A COLD first run legitimately runs at the top of these ranges; the 3x
# multiplier keeps cold runs quiet and only flags genuinely-wedged phases.
PHASE_BUDGET = {
  'fastpath-route'    => 10,  # pure routing + DM readback (no Tableau work)
  'phase1-foreground' => 150, # parse-twb-layout + mechanical converter (cold); sha-cached re-entry ~5s
  'phase1-lane(bg)'   => 240, # Tableau 5-fetch discovery pool, cold 2-4min; stamp-reused <5s
  'join-wait'         => 240, # foreground wait on the lane (≈ lane time on a cold run, ~0s on reuse)
  'phase1.6-dm-scan'  => 45,  # DM list + ≤25 spec fetches; signature-cached re-entry <1s
  'phase2.6-reuse-augment' => 30, # #691: reuse-candidate readback + gap plan + one optional DM PUT
  'phase2-columns'    => 90,  # ~2-5s per table via the Sigma catalog; cols-*.json reused on re-entry
  'phase1-join'       => 120, # calc extraction + custom-SQL scan + gap-report parse (sha-cached on re-entry)
  'phase0c-cost'      => 15,  # estimate-cost.rb over workdir artifacts (pure local) + sign-off print
  'decisions'         => 10,  # pure local
  'folder-resolve'    => 15,  # one whoami + files listing
  'phase3-dm'         => 90,  # validate + POST + readback (skipped entirely on --reuse-dm)
  'phase4-workbook'   => 150, # master derive + build-charts + validate + ref-gate + POST
  'phase5-layout'     => 45,  # layout build + PUT
  'phase5b-visual-qa' => 120, # ~15s per page render
  'phase5g-init'      => 10,  # ledger init only
  'phase6-pass1'      => 240, # structural checks + pooled actuals collection (1-3min)
  'phase6-finalize'   => 180, # verifier + census over collected actuals
  'cleanup-orphans'   => 45,
  'assert-run-state'  => 10,
  'assert-phase6-ran' => 90,
  'assert-datasource-filters' => 15, # one GET /v2/workbooks/<id>/spec + local checks (SKIPs offline)
  'assert-action-gates' => 10, # local checks only (spec + ledger + guide) — no network
  'phaseE'            => 240,
  'pivot-totals-ship' => 20   # one GET+PUT to re-hide pivot grand totals at ship
}.freeze

$budget_warned = {}
def mark(key)
  now = Time.now
  seg = now - $t_mark
  PHASE_T[key] = (PHASE_T[key] || 0.0) + seg
  $t_mark = now
  # Wave-1 timing hook: append {phase, wall_s, at} for the segment just
  # measured to <WORK>/phase-metrics.jsonl via the shared phase-metrics lib
  # (shared/lib/phase_metrics.rb — capture ≠ send; file stays machine-local).
  # Guarded on every axis (lib absent → no-op; lib raising → no-op): a metrics
  # write must never touch the conversion. This is the calibration source the
  # ratified local-capture decision feeds (reconciled program #5 / ADD-6).
  if defined?(PhaseMetrics) && PhaseMetrics.respond_to?(:record) && defined?(WORK)
    begin
      # W2.22 rider: turn ordinal + invocation token ride each mark record —
      # turn events countable from state transitions; distinct inv = invocations.
      PhaseMetrics.record(workdir: WORK, phase: key, wall_s: seg, at: now.utc,
                          turn: ($pm_turn = $pm_turn.to_i + 1),
                          inv: (PhaseMetrics.respond_to?(:invocation_token) ? PhaseMetrics.invocation_token : nil))
    rescue StandardError
      nil
    end
  end
  quiet_event('mark', 'phase' => key, 'wall_s' => PHASE_T[key].round(1))
  budget = PHASE_BUDGET[key]
  return unless budget && PHASE_T[key] > 3 * budget && !$budget_warned[key]
  $budget_warned[key] = true
  anchor = key.gsub(/[^A-Za-z0-9]+/, '-').gsub(/\A-|-\z/, '').downcase
  puts "⚠️  PHASE '#{key}' is OVER BUDGET (#{(PHASE_T[key] / 60.0).round(1)}m elapsed > ~#{budget}s expected) — " \
       "see refs/performance.md#slow-#{anchor} before retrying. Do NOT restart the migration from " \
       'scratch: the resume machinery skips completed phases; a restart re-pays everything.'
end
def phase_summary
  return if PHASE_T.empty?
  puts
  puts "PHASE TIMINGS  #{PHASE_T.map { |k, v| "#{k}=#{v.round(1)}s" }.join('  ')}  " \
       "total=#{(Time.now - START_T).round(1)}s"
  over = PHASE_T.select { |k, v| PHASE_BUDGET[k] && v > 3 * PHASE_BUDGET[k] }
  puts "PHASE BUDGET   over-budget: #{over.map { |k, v| "#{k}=#{v.round(0)}s(>#{PHASE_BUDGET[k]}s)" }.join('  ')}  — see refs/performance.md" if over.any?
end

# Reap the background discovery lane with a HARD bound — an abort/stop path
# must never hang forever on a wedged child process (poll-bounds audit,
# refs/performance.md). Returns false when the lane did not exit in time; the
# caller proceeds anyway (the child is detached and the run is stopping).
def reap_lane!(lane_done, timeout = 60)
  t0 = Time.now
  until lane_done.call
    if Time.now - t0 > timeout
      puts "   WARN: discovery lane did not exit within #{timeout}s — proceeding without reaping it"
      return false
    end
    sleep 0.1
  end
  true
end

# Run a child command, indenting its output. token_env: prepend a fresh
# Sigma/Tableau token via the skill's get-token scripts so long runs survive
# the ~1h token TTL.
def run!(cmd, allow_fail: false, env: nil)
  out, st = env ? Open3.capture2e(env, *cmd) : Open3.capture2e(*cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  abort "FATAL: command failed (#{st.exitstatus}): #{cmd.join(' ')}" unless st.success? || allow_fail
  [out, st]
end

# Persist the render-only health record consumed by build-migration-report.rb.
# visual-similarity.py already runs png_health over the target render, so reuse
# that measured object when present. Otherwise analyze the canonical
# sigma-render.png directly. No image or an unreadable artifact is left for the
# report's render check to fail closed; this helper never fabricates health.
def refresh_render_health(work)
  output = File.join(work, 'render-health.json')
  FileUtils.rm_f(output)
  similarity = File.join(work, 'visual-similarity.json')
  if File.file?(similarity)
    begin
      doc = JSON.parse(File.read(similarity, encoding: 'UTF-8'))
      health = doc['render_health'] if doc.is_a?(Hash)
      if health.is_a?(Hash)
        temporary = "#{output}.tmp.#{$$}"
        File.write(temporary, JSON.pretty_generate(health) + "\n")
        File.rename(temporary, output)
        return [true, 'extracted visual-similarity.json render_health']
      end
    rescue JSON::ParserError, SystemCallError => e
      warn "WARN: could not extract render_health from visual-similarity.json: #{e.message}"
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end
  end

  render = File.join(work, 'sigma-render.png')
  return [false, 'no visual-similarity render_health or sigma-render.png'] unless File.file?(render)
  _, status = run!(['python3', File.join(HERE, 'png_health.py'), render,
                    '--json-out', output], allow_fail: true)
  [status.success?, "png_health.py #{status.success? ? 'PASS' : "exit #{status.exitstatus}"}"]
end

# Return a Sigma bearer token that is live RIGHT NOW, minting IN-PROCESS (pure
# Ruby net/http via the Sigma lib) — no bash, no `eval "$(get-token.sh)"`, so
# this works identically under PowerShell / cmd / a Cowork sandbox.
# Mint once per TTL, not per child: this used to refresh_token! on every call,
# so each child spawn paid a fresh client_credentials exchange (~15-25 mints
# per run against Sigma's 1 req/s auth rate limit). The Sigma lib already
# tracks mint time (TOKEN_TTL_SECONDS = 50 min, lib/sigma_rest.rb), so reuse
# the current token while its age is KNOWN and under TTL; re-mint otherwise —
# including an unknown-age env token, which gets minted-over ONCE and stamped,
# so a long run still never carries a stale token.
def sigma_token!
  tok = ENV['SIGMA_API_TOKEN'].to_s
  return tok unless tok.empty? || Sigma.token_minted_at.nil? || Sigma.token_stale?
  Sigma.refresh_token!
rescue StandardError => e
  abort "FATAL: could not mint a Sigma token: #{e.message}\n" \
        '  Check SIGMA_BASE_URL / SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (run: ruby scripts/setup.rb).'
end

# Wrap a command so a Sigma token is live for it (injected via child env). The
# mint stamp rides along so the child's own TTL logic ages the token from its
# TRUE mint time instead of treating an inherited token as age-unknown.
def sigma_run!(cmd, allow_fail: false)
  env = { 'SIGMA_API_TOKEN' => sigma_token!,
          'SIGMA_TOKEN_MINTED_AT' => ENV['SIGMA_TOKEN_MINTED_AT'] }
  run!(cmd, allow_fail: allow_fail, env: env.reject { |_, v| v.nil? })
end

# Mint a fresh Tableau token IN-PROCESS (pure Ruby via tableau_rest) and return
# the env a child needs, instead of `bash -c "eval \"$(get-tableau-token.sh)\""`.
# On Windows the bash path fails — PowerShell env vars don't propagate into the
# bash subprocess and $HOME isn't set, so get-tableau-token.sh can't source
# ~/.sigma-migration/env (a Windows/PowerShell subprocess token failure). Ruby's Tableau.refresh_token!
# resolves the neutral cred file via Ruby's own ~ expansion and mints over
# net/http — no shell involved. Falls back to a pre-set TABLEAU_AUTH_TOKEN when
# no PAT creds are available to refresh (parity with a hand-minted token).
# Sign in once per TTL, not per child: Tableau sessions outlive a single child
# by hours (Cloud idle default: 240 min), so re-signing in on every spawn paid
# ~10-20 PAT signins per run and multiplied exposure to the transient signin
# 401s retried below. 50 min mirrors Sigma's token TTL — well inside even
# strict site policies; a child that DOES hit an expired session re-signs
# itself via tableau_rest's own 401 handler.
TABLEAU_ENV_TTL_SECONDS = 50 * 60
def tableau_env
  if $tableau_env_cache && (Time.now - $tableau_env_cache[:minted_at]) < TABLEAU_ENV_TTL_SECONDS
    return $tableau_env_cache[:env]
  end
  begin
    # v5.2 (speed): PAT signin 401s are routinely TRANSIENT on Tableau Online
    # (session teardown races, concurrent signins on one PAT) — round 4's run
    # died on one and the very next re-run succeeded, costing a full
    # orchestrator round-trip. Retry twice with backoff before giving up.
    attempts = 0
    begin
      Tableau.refresh_token! # fresh PAT signin, in-process
    rescue Tableau::Error => te
      attempts += 1
      # retry only when there is NO hand-minted fallback token — with one
      # available, fail FAST to it (a permanently-revoked PAT would otherwise
      # tax every call 9s; review-caught)
      if attempts <= 2 && te.message =~ /401|Signin/i && ENV['TABLEAU_AUTH_TOKEN'].to_s.empty?
        warn "Tableau signin failed (#{te.message.lines.first.to_s.strip[0, 80]}) — retry #{attempts}/2 in #{3 * attempts}s"
        sleep(3 * attempts)
        retry
      end
      raise
    end
  rescue Tableau::Error
    raise if ENV['TABLEAU_AUTH_TOKEN'].to_s.empty? # nothing to fall back on
  end
  env = {
    'TABLEAU_SERVER_URL'  => (Tableau.server_url  rescue ENV['TABLEAU_SERVER_URL']),
    'TABLEAU_SITE_ID'     => (Tableau.site_id     rescue ENV['TABLEAU_SITE_ID']),
    'TABLEAU_AUTH_TOKEN'  => (Tableau.auth_token  rescue ENV['TABLEAU_AUTH_TOKEN']),
    'TABLEAU_API_VERSION' => (Tableau.api_version rescue (ENV['TABLEAU_API_VERSION'] || '3.22')),
  }.compact
  # The hand-minted-fallback env is cached too — a revoked PAT would otherwise
  # re-pay the failed-signin tax on every child (the fail-FAST rationale above).
  $tableau_env_cache = { env: env, minted_at: Time.now }
  env
rescue StandardError => e
  abort "FATAL: could not mint a Tableau token in-process: #{e.message}\n" \
        '  Check Tableau creds (run: ruby scripts/setup-tableau.rb), or set TABLEAU_AUTH_TOKEN.'
end

# Run a Ruby child script with a live Tableau token injected via env — the
# Windows-safe, bash-free replacement for
# `run!(['bash','-c',"eval \"$(get-tableau-token.sh)\" && <cmd>"])`.
def tableau_run!(cmd, allow_fail: false)
  run!(cmd, allow_fail: allow_fail, env: tableau_env)
end

# Raised when the MECHANICAL WORKBOOK layer (build / validate / POST) fails after
# the data model is already posted + valid. The orchestrator catches this and
# degrades to a FRIENDLY agent-path handoff instead of a bare crash — the DM is
# ready, so the agent path can rebuild just the workbook against it.
class WorkbookBuildError < StandardError
  attr_reader :captured_output
  def initialize(msg, captured_output = '')
    super(msg)
    @captured_output = captured_output.to_s
  end
end

# Like run!, but on failure raises WorkbookBuildError (catchable) instead of
# abort()ing the process. Captures the child output for field-name mining.
def run_wb!(cmd, env: nil)
  out, st = env ? Open3.capture2e(env, *cmd) : Open3.capture2e(*cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  raise WorkbookBuildError.new("command failed (#{st.exitstatus}): #{cmd.join(' ')}", out) unless st.success?
  out
end

# sigma_run! variant that raises WorkbookBuildError instead of aborting.
def sigma_run_wb!(cmd)
  env = { 'SIGMA_API_TOKEN' => sigma_token!,
          'SIGMA_TOKEN_MINTED_AT' => ENV['SIGMA_TOKEN_MINTED_AT'] }
  run_wb!(cmd, env: env.reject { |_, v| v.nil? })
end

# Pull likely-offending field/column names out of a failed workbook build/POST log.
def plausible_field_name?(s)
  # v5.4: the capture regexes below take "everything to the newline/comma" —
  # an error body like "Dependency not found. The usual cause is …" captured
  # ". The usual cause is …" as a FIELD NAME (round-6: exit-4 offramps named
  # the untranslatable field '. The usual'). A field name never starts with
  # sentence punctuation — reject prose shapes. v5.4.9 review fix: the word
  # cap was 7, which culled legitimate long enterprise KPI captions ("Average
  # Revenue Per Paying User Per Month (USD)" is 8 words) from the exit-4
  # recovery list; the prose class is already rejected by the leading-
  # punctuation check plus the mandatory-colon capture, so the cap is only a
  # backstop — keep it generous.
  t = s.to_s.strip
  return false if t.empty? || t.length > 80
  return false if t.start_with?('.', ',', ';', ':', '-')
  return false if t.split.length > 12
  # Prose, not a caption: a clause starting with a lowercase English function
  # word ("the element you referenced was removed …"). Tableau captions are
  # Title Case / CONSTANT_CASE; a lowercase-article lead is sentence tail.
  return false if t =~ /\A(?:the|a|an|this|that|these|those|it|its|you|your|is|are|was|were|be|been|has|have|had|and|or|of|in|on|to|for|with)\s/
  true
end

def cull_failed_fields(*logs)
  # Child output arrives in the LOCALE encoding (US-ASCII when LANG is unset —
  # common on fresh machines/CI), and Sigma error bodies carry UTF-8 field
  # names; an un-scrubbed scan then crashes the RESCUE path itself with
  # "invalid byte sequence in US-ASCII". Never let log mining raise.
  text = logs.join("\n")
  text = text.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
  text = text.scrub('?') unless text.valid_encoding?
  names = []
  # v5.4: the colon is MANDATORY — "Dependency not found. The usual cause…"
  # (prose after a period) previously captured '. The usual' as a field name.
  text.scan(/Dependency not found:\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Unknown column\s*"?\[?([^"\]\n]+)\]?"?/i) { |m| names << m[0].strip }
  text.scan(/unmapped (?:derived[- ]dim|measure|field)\s*[:=]?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Circular column reference[^\n]*\[([^\]]+)\]/i) { |m| names << m[0].strip }
  names.map { |n| n.gsub(/[\[\]"]/, '').strip }
       .select { |n| plausible_field_name?(n) }.uniq
end

# EXIT-4 SALVAGE INVENTORY (v5.6): a field run burned ~90 min re-deriving, per
# untranslatable field, exactly what the workdir already knew — the Tableau
# formula (calc-fields.json), its translation class, and which documented route
# applies. Print that at the STOP so the fix starts from the answer, not the
# question. Pure lookup, never raises (a malformed calc-fields.json just yields
# the 'no entry' route).
def salvage_inventory(work, failed)
  calcs = begin
    doc = JSON.parse(File.read(File.join(work, 'calc-fields.json'), encoding: 'UTF-8'))
    Array(doc['calcs']).select { |c| c.is_a?(Hash) }
  rescue StandardError
    []
  end
  norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
  by_norm = {}
  calcs.each { |c| by_norm[norm.call(c['name'])] ||= c }
  Array(failed).map do |nm|
    c = by_norm[norm.call(nm)]
    if c.nil?
      { 'field' => nm, 'class' => 'unknown (no calc-fields.json entry under this name)',
        'route' => 'not a workbook calc — check calc-fields.json captions and the DM column names; ' \
                   'a BASE column failing here is a column-mapping fix (--column-mapping), not a formula translation' }
    else
      klass, route =
        if c['requires_custom_sql'] && !c['is_lod']
          ['window/table calc (requires_custom_sql — STAYS-MANUAL family)',
           'manual-residue SQL: build it as a Custom SQL / grouped helper element ' \
           '(template: refs/window-functions.md), declare it in <workdir>/manual-residues.json so gate 15 ' \
           'tracks it, or knowingly ship the magnitude proxy via --accept-manual-residues — ' \
           'never fold it into a master formula']
        elsif c['is_lod']
          ['LOD calc' + (c['requires_custom_sql'] ? ' (requires_custom_sql)' : ''),
           "translate over master columns and re-run this exact command with --master-col '#{c['name']}=<Sigma formula>' " \
           '(FIXED → the helper-element recipe in refs/window-functions.md when a plain master formula cannot express it)']
        else
          ['row-level calc',
           "translate the formula to Sigma syntax and re-run this exact command with --master-col '#{c['name']}=<Sigma formula>'"]
        end
      { 'field' => c['name'], 'class' => klass, 'formula' => c['formula'],
        'route' => route, 'notes' => Array(c['translation_notes']) }
    end
  end
end

def yp(s) YAML.safe_load(s, permitted_classes: [Date, Time]) rescue {} end

# Formula-normalize hook (fix-workstream G: scripts/lib/formula_normalize.rb).
# Case-normalizes function names the converter can emit lowercase (round( →
# Round() so Sigma's compiler doesn't reject them. Contract:
#   spec, rewrites = FormulaNormalize.normalize_spec!(spec)   # mutates in place
#   rewrites: [{ from:, to:, path: }, ...]
# Wired DEFENSIVELY: a no-op when the lib is absent, and a hook failure never
# sinks the run — the live POST + column-type guard remain the authoritative gate.
def normalize_formulas!(spec, label)
  fn = File.join(HERE, 'lib', 'formula_normalize.rb')
  return unless File.exist?(fn)
  require fn
  return unless defined?(FormulaNormalize) && FormulaNormalize.respond_to?(:normalize_spec!)
  _, rewrites = FormulaNormalize.normalize_spec!(spec)
  Array(rewrites).each do |r|
    if r.is_a?(Hash)
      line "NOTE: normalized #{r[:from] || r['from']}( → #{r[:to] || r['to']}( at #{r[:path] || r['path']}"
    else
      line "NOTE: #{r}"
    end
  end
rescue StandardError => e
  line "WARN: formula-normalize hook (#{label}) failed: #{e.message} — spec left as the converter emitted it"
end

# ---------------------------------------------------------------------------
# PASS 2 (--finalize) — phase6 finalize + cleanup-orphans + the census-aware
# assert-phase6-ran hard gate. Resumes from <WORK>/migrate-state.json; phases
# 1–5 are NOT re-run. Exit 0 here is the ONLY green exit of the orchestrator.
# ---------------------------------------------------------------------------
if opts[:finalize]
  abort '--actuals required with --finalize (the parity-actuals.json you built from the MCP queries)' unless opts[:actuals]
  state_path = File.join(WORK, 'migrate-state.json')
  abort "FATAL: no #{state_path} — run pass 1 first (same --workbook/--out)" unless File.exist?(state_path)
  state = JSON.parse(File.read(state_path))
  wb_id = state['workbook_id'] or abort 'FATAL: state has no workbook_id (pass 1 never completed Phase 4)'

  hdr(6, 'Parity (pass 2 — finalize)')
  $t_mark = Time.now
  p6 = ['ruby', File.join(HERE, 'phase6-parity.rb'), '--tableau', WORK,
        '--finalize', '--actuals', opts[:actuals]]
  p6 += ['--extract-mode', '--extract-tol', '0.30'] if state['extract_mode']
  p6 += ['--regen-plan'] if opts[:regen_plan]
  p6out, p6st = sigma_run!(p6, allow_fail: true)
  line "phase6-parity finalize: #{p6st.success? ? 'PASS' : "FAIL (exit #{p6st.exitstatus})"}"
  mark('phase6-finalize')

  # Cleanup: delete orphan workbooks from spec-iteration retries (keep the live one).
  clout, clst = sigma_run!(['ruby', File.join(HERE, 'cleanup-orphan-workbooks.rb'),
                            '--workdir', WORK, '--keep', wb_id], allow_fail: true)
  line 'WARN: orphan cleanup reported failures — assert-phase6-ran will gate on it' unless clst.success?
  mark('cleanup-orphans')

  # Run-state chain audit (Tier 2 ledger) — confirms every always-required phase
  # was actually entered this run, catching a silent shortcut the output gates
  # can miss. Advisory in the orchestrator (allow_fail) since the hard gate below
  # is authoritative; run standalone (SKILL.md Phase 6) it exits non-zero.
  _, rsst = run!(['ruby', File.join(HERE, 'assert-run-state.rb'), '--workdir', WORK], allow_fail: true)
  line 'WARN: run-state chain audit found a missing phase (see above)' unless rsst.success?
  mark('assert-run-state')

  # The census-aware hard gate. NEVER bypassed — this command fails when it fails.
  gate = ['ruby', File.join(HERE, 'assert-phase6-ran.rb'), '--tableau', WORK, '--workbook-id', wb_id]
  # Require a RECORDED source-vs-target visual comparison (gate 8b) — not just a
  # render that exists. The agent records the verdict with record-visual-check.rb
  # after the Phase 6f side-by-side read (see SKILL.md); without it the gate
  # exits 13. tableau-to-sigma is the reference adopter of this opt-in gate.
  # --fast (opt-in, trusted table/pivot-only workbooks): waive the two VISUAL gates
  # (8 render + 8b recorded comparison) with the operator's recorded reason, and do
  # NOT require the comparison. OFF by default — this trades visual QA and violates
  # the "never declare done on HTTP 200" contract, so it is never implicit.
  gate += ['--require-visual-comparison'] unless opts[:fast]
  # Phase 5g — require the RCF fidelity ledger (gate 8d) unless the loop was
  # explicitly disabled at pass 1 (--rcf-passes 0). Legacy state (pre-5g) has no
  # rcf_passes key → default to requiring it, since the ledger is the new bar.
  # PR-11: the opt-out is NEVER silent — it rides to the gate as the named
  # --skip-fidelity-gate waiver (recorded in waivers.json + the census,
  # budget-counted), so a skipped RCF phase is visible in every report.
  rcf_enabled = state.fetch('rcf_passes', 5).to_i.positive?
  gate += rcf_enabled ? ['--require-fidelity-ledger'] : ['--skip-fidelity-gate', 'RCF loop disabled at pass 1 via --rcf-passes 0']
  # Gate 7b (PR-13): the runtime control flip test is DEFAULT-ON for the
  # tableau finalize path — gate 7c (controls census) proves the controls
  # EXIST; only the flip proves they DO something at runtime. The opt-out is
  # NEVER silent: --skip-flip-test rides to the gate as the named
  # --skip-control-flip waiver (recorded in waivers.json + the parity-final
  # census, budget-counted). Offline finalize runs without the waiver rely on
  # the gate's recorded-evidence fallback (a prior probe-results.json /
  # control-flip-unverified.json marker) — or fail closed, by design.
  gate += opts[:skip_flip_test] ? ['--skip-control-flip', opts[:skip_flip_test]] : ['--require-control-flip']
  gate += ['--allow-extract'] if state['extract_mode']
  gate += ['--allow-missing-tiles', opts[:allow_missing_tiles].to_s] if opts[:allow_missing_tiles]
  gate += ['--min-pass-rate', opts[:min_pass_rate].to_s] if opts[:min_pass_rate]
  # Gate 11 (post-publish interactivity guide) waiver pass-through — the gate
  # itself decides whether the source's actions require POSTPUBLISH_GUIDE.md.
  gate += ['--skip-postpublish-guide', opts[:skip_postpublish_guide]] if opts[:skip_postpublish_guide]
  # Gate 13 (source-anchor values) waiver pass-through (W2.10) — REASON rides to
  # the gate (recorded in waivers.json + the census, budget-counted).
  gate += ['--skip-anchors-gate', opts[:skip_anchors_gate]] if opts[:skip_anchors_gate]
  gate += ['--allow-empty-tiles', opts[:allow_empty_tiles_gate]] if opts[:allow_empty_tiles_gate]
  # --fast: stamp the two visual-gate waivers with the operator's reason (recorded
  # in parity-final.json's waivers[] and counted toward the >2-waiver budget cap).
  gate += ['--skip-visual-gate', opts[:fast], '--skip-visual-comparison', opts[:fast]] if opts[:fast]
  _, gst = sigma_run!(gate, allow_fail: true)
  # `_` holds the gate's captured output (run! returns [out, st]); the finalize
  # breaker digests its error region below. Kept as `_, gst = …` because
  # test-fast-flag.rb pins this exact line shape for its waiver-ordering check.
  gout = _
  mark('assert-phase6-ran')

  # #483 datasource-filter gate — always-on Tableau data-source filters (a
  # <shared-view> database-domain filter like company_active=true, or a
  # <datasource>/<extract> filter) render NOTHING on any dashboard, so a visual
  # check can't catch a miss. This verifies each tagged filter was APPLIED as a
  # workbook-wide master default (not silently dropped → every aggregate
  # over-reports). Kept a STANDALONE tableau-local gate (not folded into the
  # SHARED assert-phase6-ran.rb) so it ships in one plugin PR; blocks GREEN via
  # all_green below. SKIPs cleanly offline / without a token.
  dsf_cmd = ['ruby', File.join(HERE, 'assert-datasource-filters.rb'), '--workdir', WORK, '--workbook-id', wb_id]
  dsf_cmd += ['--skip-datasource-filters', opts[:skip_datasource_filters]] if opts[:skip_datasource_filters]
  dsfout, dsfst = sigma_run!(dsf_cmd, allow_fail: true)
  mark('assert-datasource-filters')

  # Task 6 (2026-08-07 restructure) — action gates (G1 action-schema
  # validation + the post-publish guide-residue check). Kept a STANDALONE
  # tableau-local gate (scripts/assert-action-gates.rb, NOT folded into the
  # SHARED assert-phase6-ran.rb — same #483 pattern as assert-datasource-
  # filters.rb above) because the action-ledger concept it checks (Tableau
  # dashboard filter/highlight/nav/parameter/set actions) has no equivalent in
  # the other 7 converters that vendor assert-phase6-ran.rb.
  #
  # Resolve the built spec the SAME way Phase 4 itself wrote it: the
  # mechanical/hosted-converter path writes <WORK>/wb-spec.json; the
  # agent-authored manual-spec route (--wb-spec) writes
  # <WORK>/wb-spec.resolved.json instead, specifically so the authored,
  # re-resolvable placeholders file is never clobbered (see Phase 4's own
  # "NON-DESTRUCTIVE placeholder resolution" comment). By --finalize time
  # Phase 4 has ALWAYS run (migrate-state.json exists, wb_id resolved above),
  # so exactly one of these two files must exist. If NEITHER does, that is a
  # real gap, not a "nothing to check" SKIP — FAIL LOUDLY here rather than let
  # G1 silently no-op on whichever route left no spec file behind (the
  # manual-spec route is exactly the one MOST likely to carry a hand-authored
  # action with a missing/duplicate id, so silently skipping it there would be
  # worse than not having the gate at all).
  ag_spec_path = File.join(WORK, 'wb-spec.json')
  ag_spec_path = File.join(WORK, 'wb-spec.resolved.json') unless File.exist?(ag_spec_path)
  unless File.exist?(ag_spec_path)
    puts
    puts '================ ACTION-GATES STOP (no built spec found) ===================='
    puts "Neither #{File.join(WORK, 'wb-spec.json')} nor #{File.join(WORK, 'wb-spec.resolved.json')}"
    puts 'exists, but Phase 4 must have already run by --finalize time (migrate-state.json'
    puts 'and a workbook_id are both present). G1 (action-schema validation) cannot silently'
    puts 'skip here — investigate why Phase 4 left no spec file on disk, then re-run --finalize.'
    puts '==============================================================================='
    exit 32
  end
  ag_cmd = ['ruby', File.join(HERE, 'assert-action-gates.rb'), '--workdir', WORK, '--spec', ag_spec_path]
  # Waives the guide-residue check ONLY — assert-action-gates.rb never lets
  # this flag touch G1.
  ag_cmd += ['--skip-postpublish-guide', opts[:skip_postpublish_guide]] if opts[:skip_postpublish_guide]
  agout, agst = sigma_run!(ag_cmd, allow_fail: true)
  mark('assert-action-gates')

  if gst.exitstatus == 7
    census = (JSON.parse(File.read(File.join(WORK, 'parity-final.json')))['tile_census'] rescue {}) || {}
    unmatched = census['unmatched_zone_names'] || []
    puts
    puts '==================== CENSUS STOP (agent action required) ===================='
    puts "The Tableau dashboard has #{census['zones_total']} chart zone(s) but only"
    puts "#{census['charts_built']} made it into the parity plan. Unmatched zone(s):"
    unmatched.each { |z| puts "  - #{z}" }
    puts ''
    puts 'This usually means the Tableau view CSV came back EMPTY (filtered viz /'
    puts 'export quirk) so the chart was silently dropped, or a chart was renamed.'
    puts 'Handle each zone, then re-run this exact --finalize command:'
    puts "  1. Re-export the view CSV (scripts/fetch-view-data.rb / MCP get-view-data"
    puts '     with filters relaxed) into the workdir and rebuild the missing chart'
    puts "     against DM #{state['data_model_id']} / workbook #{wb_id} (see SKILL.md),"
    puts '     then re-run phase6-parity pass 1 + the MCP queries + --finalize; OR'
    puts "  2. If it was a RENAME, re-run pass 1 with --rename plumbed via phase6-parity; OR"
    puts "  3. If the zone is legitimately unbuildable, re-run --finalize with"
    puts "     --allow-missing-tiles #{unmatched.size} and NAME the zone(s) in your report."
    puts '============================================================================='
  end

  if gst.exitstatus == 10
    puts
    puts '==================== VISUAL STOP (agent action required) ===================='
    puts 'Phase 6f visual verification has not run: no Sigma render PNG exists in the'
    puts 'workdir. CSV parity passing does NOT mean the workbook renders correctly'
    puts '(overlaps, dead zones, dropped log scale, missing labels, wrong chart kind).'
    puts 'Do this, then re-run this exact --finalize command:'
    puts "  1. Render the full page(s) of workbook #{wb_id}:"
    puts "       python3 scripts/sigma-export-png.py --workbook #{wb_id} \\"
    puts "         --page <pageId> --out #{File.join(WORK, 'sigma-render.png')}"
    puts "  2. READ #{File.join(WORK, 'sigma-render.png')} with the Read tool and compare it"
    puts "     side-by-side against the source dashboard PNG in #{WORK} (Phase 1d)."
    puts '     Fix any visual divergence (re-PUT the spec) and re-render until they match.'
    puts '  3. Spawn the CONTEXT-FREE blind grader (PR-9: refs/blind-grader-brief.md — give it ONLY the'
    puts "     two image paths + the rubric; it writes #{File.join(WORK, 'blind-grade.json')})."
    puts '  4. Record the verdict so gate 8b confirms the comparison ran, then re-run --finalize:'
    puts "       ruby scripts/record-visual-check.rb --workdir #{WORK} --verdict pass --notes \"<what you compared>\" --checklist \"<layout-visual-qa.md section 1b>\" --blind-grade #{File.join(WORK, 'blind-grade.json')}"
    puts '  If the workbook genuinely cannot be rendered (export API unavailable), the gate'
    puts '  can be waived ONLY via assert-phase6-ran.rb --skip-visual-gate "<reason>" —'
    puts '  name the reason in your migration report.'
    puts '============================================================================='
  end

  if gst.exitstatus == 13
    puts
    puts '==================== VISUAL STOP (comparison not recorded) =================='
    puts 'A valid Sigma render exists, but no source-vs-target visual comparison was'
    puts 'RECORDED (gate 8b). CSV/number parity does NOT prove the dashboard looks right.'
    puts 'Do this, then re-run this exact --finalize command:'
    puts "  1. READ the rendered page (#{File.join(WORK, 'sigma-render.png')}) side-by-side"
    puts "     against the source dashboard PNG in #{WORK} (Phase 1d)."
    puts '  2. Spawn the CONTEXT-FREE blind grader (PR-9: refs/blind-grader-brief.md — ONLY the two'
    puts "     image paths + the rubric; it writes #{File.join(WORK, 'blind-grade.json')}). Your own"
    puts '     read is the fix loop; the blind grade is the verdict.'
    puts '  3. Record your verdict (this is what the gate checks):'
    puts "       ruby scripts/record-visual-check.rb --workdir #{WORK} --verdict pass --notes \"<what matched>\" --checklist \"<layout-visual-qa.md section 1b>\" --blind-grade #{File.join(WORK, 'blind-grade.json')}"
    puts '     If they DIVERGE (your read OR the blind grade): --verdict divergent --notes "<gap>",'
    puts '     fix the spec, re-render, re-read, re-grade, then re-record --verdict pass. The gate'
    puts '     stays blocked until a blind-graded pass is recorded.'
    puts '============================================================================='
  end

  if gst.exitstatus == 16
    puts
    puts '================ INTERACTIVITY STOP (post-publish guide missing) ============'
    puts 'The source dashboards carry interactive actions (filter/highlight/navigation/'
    puts 'parameter actions, dynamic zones, drills) that workbooks-as-code CANNOT port.'
    puts 'The user must be handed exact Sigma UI steps for each — generate the guide,'
    puts 'then re-run this exact --finalize command:'
    # `--emitted-manifest` is the actions-emitted sidecar build-charts-from-signals.rb
    # writes next to its --out (always 'chart-specs.json' in this orchestrator —
    # see the build_cmd assembly above); derived with the SAME
    # .sub(/\.json$/, '-actions-emitted.json') build-charts-from-signals.rb itself
    # uses to write it, not a separately-guessed filename. Without this flag the
    # guide can't tell an auto-wired nav-button apart from one still needing
    # manual wiring, and will wrongly re-instruct the user to redo it by hand.
    manifest_path = File.join(WORK, 'chart-specs.json').sub(/\.json$/, '-actions-emitted.json')
    puts "    ruby scripts/build-postpublish-guide.rb --twb #{File.join(WORK, 'workbook-content.twb')} \\"
    puts "      --wb-ids #{File.join(WORK, 'wb-ids.json')} --out #{File.join(WORK, 'POSTPUBLISH_GUIDE.md')} \\"
    puts "      --emitted-manifest #{manifest_path} \\"
    # CONTRACTUAL path — gate 11 (a later task) reads exactly <workdir>/action-ledger.json.
    puts "      --json-out #{File.join(WORK, 'action-ledger.json')}"
    puts 'LINK the guide in your migration report and walk the user through it.'
    puts 'Waivable ONLY via --skip-postpublish-guide "<reason>" — name it in the report.'
    puts '============================================================================='
  end

  if gst.exitstatus == 14
    fill = (JSON.parse(File.read(census_path))['pages'] rescue []) || []
    bad = fill.select { |p| p['placed'].to_i < p['zones'].to_i || p['grid_fill_pct'].to_f < 0.45 }
    puts
    puts '==================== FILL STOP (agent action required) ======================'
    puts 'A page shipped with dropped tiles or a mostly-empty grid (gate 8c). Structural'
    puts 'and value parity passing does NOT mean every source tile made it onto the page.'
    bad.each do |p|
      drop = p['zones'].to_i - p['placed'].to_i
      puts "  - #{p['page'].inspect}: #{drop.positive? ? "#{drop} dropped tile(s) (#{p['placed']}/#{p['zones']}), " : ''}grid fill #{(p['grid_fill_pct'].to_f * 100).round}%"
    end
    puts 'Do this, then re-run this exact --finalize command:'
    puts '  1. Check build-dashboard-layout.rb WARN lines for dropped/unmatched zones; a drop'
    puts '     usually means an empty view CSV or an unhandled --rename. Rebuild the missing'
    puts '     tile, re-PUT the layout, re-render.'
    puts '  2. If the page is INTENTIONALLY sparse, waive with'
    puts '     assert-phase6-ran.rb --skip-layout-fill "<reason>" (name it in your report),'
    puts '     or lower the bar with --min-grid-fill F.'
    puts '============================================================================='
  end

  if gst.exitstatus == 15
    puts
    puts '==================== FIDELITY STOP (agent action required) =================='
    puts 'The Phase 5g RCF (render-compare-fix) ledger is missing or still carries UNRESOLVED'
    puts 'spec-fixable deltas (gate 8d). Data + structure + a single visual verdict passing does'
    puts 'NOT mean the composition matches the source (palette, chart kind, KPI format, containers).'
    puts 'Do this, then re-run this exact --finalize command:'
    puts "  1. Render + compare a pass:  ruby scripts/fidelity-loop.rb render --workdir #{WORK}"
    puts '     READ rcf-pass-N.png vs the source PNG, score against refs/fidelity-rubric.md.'
    puts '  2. Per delta:  ruby scripts/fidelity-loop.rb record --workdir '"#{WORK}"' --dimension <d> \\'
    puts '                   --delta "<what differs>" --class spec-fixable|ui-only|sigma-capability|data'
    puts '  3. For spec-fixable deltas, author a patch (refs/fidelity-recipes.md) and apply it:'
    puts "       ruby scripts/fidelity-loop.rb apply-patch --workdir #{WORK} --patch patch.json --resolves <ids>"
    puts '     then render again. Loop until `fidelity-loop.rb status` is clean.'
    puts '  4. Genuinely-unclosable residuals: waive them by name via'
    puts '       assert-phase6-ran.rb --accept-residuals id,id  (name them in your report),'
    puts '     or disable the loop entirely by re-running pass 1 with --rcf-passes 0 (this records'
    puts '     the named --skip-fidelity-gate waiver — budget-counted, named in the report).'
    puts '============================================================================='
  end

  # Refresh source accounting from the FINAL built/readback, coverage, control,
  # formula, and parity artifacts. Remove the preliminary discovery census
  # first: a failed refresh must never let a stale pre-build inventory vouch for
  # completion.
  source_census_path = File.join(WORK, 'source-object-census.json')
  FileUtils.rm_f(source_census_path)
  census_out, census_st = run!(
    ['ruby', File.join(HERE, 'build-source-object-census.rb'), '--workdir', WORK],
    allow_fail: true
  )
  line "source-object census: #{census_st.success? ? 'PASS' : "FAIL (exit #{census_st.exitstatus})"}"

  render_health_ok, render_health_note = refresh_render_health(WORK)
  line "render health: #{render_health_note}"

  # The shared/vendored report is the terminal accounting authority. It always
  # runs on finalize (GREEN and non-GREEN gate batteries alike), before the
  # result banner. Exit 1 means it wrote a diagnostic RED report; that RED is a
  # real all_green input, not advisory output.
  report_out, report_st = run!(
    ['ruby', File.join(HERE, 'build-migration-report.rb'), '--workdir', WORK],
    allow_fail: true
  )
  report_doc = (JSON.parse(File.read(File.join(WORK, 'migration-result.json'))) rescue {})
  report_verdict = report_doc['verdict'] || 'unavailable'
  line "migration report: #{report_verdict}#{report_st.success? ? '' : " (exit #{report_st.exitstatus})"}"

  # With an explicit --min-pass-rate (honest NAMED divergences), the census-
  # aware gate is the parity authority — phase6's own exit stays strict-100%.
  parity_ok = p6st.success? || (opts[:min_pass_rate] && gst.success?)
  accounting_ok = census_st.success? && report_st.success? && report_verdict != 'RED'
  all_green = parity_ok && clst.success? && gst.success? && dsfst.success? &&
              agst.success? && accounting_ok

  # ---------------------------------------------------------------------------
  # Phase E (OPT-IN) — Enhance. Runs ONLY when --enhance was passed (here or on
  # pass 1) AND every gate above is green: enhancements clone a PARITY-VERIFIED
  # workbook, never an unproven one. Clone-first / scan-then-propose /
  # accept-only / parity-unchanged-gated — see enhance-scan.rb + enhance-apply.rb.
  # ---------------------------------------------------------------------------
  enhance_requested = opts[:enhance] || state['enhance_requested']
  enhance_line = nil
  $t_mark = Time.now # Phase E timing starts here (mark('phaseE') at each terminal)
  if enhance_requested && !all_green
    enhance_line = 'SKIPPED — gates not green (Phase E only clones a parity-verified workbook)'
  elsif enhance_requested
    puts
    puts '── Phase E (opt-in) · Enhance ──'
    enh_path = File.join(WORK, 'enhancements.json')
    _, est = sigma_run!(['ruby', File.join(HERE, 'enhance-scan.rb'),
                         '--workbook-id', wb_id, '--workdir', WORK,
                         '--source', 'tableau', '--out', enh_path], allow_fail: true)
    if !est.success?
      enhance_line = 'scan FAILED (migration itself is green; see output above)'
    elsif opts[:enhance_accept].nil?
      enh_doc = (JSON.parse(File.read(enh_path)) rescue {})
      cands = enh_doc['candidates'] || []
      app_options = enh_doc['app_options'] || []
      puts
      puts '==================== PHASE E PROPOSALS (acceptance required) ===================='
      puts "#{cands.size} enhancement candidate(s) in #{enh_path}. NOTHING has been applied."
      if app_options.empty?
        puts 'present each candidate to the human (interactive: one AskUserQuestion checklist),'
        puts 'then re-run this exact --finalize command adding:'
        puts '  --enhance --enhance-accept <id,id,...>   # or: --enhance-accept all-low-risk'
      else
        puts
        puts 'RUN THE DESIGN INTERVIEW FIRST — ask what the app should BE, not which'
        puts 'patches to apply. Options below are derived from this source\'s own data'
        puts '(see refs/phase-e-enhance.md -> "The design interview"):'
        app_options.each do |o|
          detail = o['archetype'] ?
            "#{o['archetype']} score=#{o['score']} confidence=#{o['confidence']}" :
            o['risk'].to_s
          puts format('  %-1s %-34s %s [%s]',
                      o['recommended'] ? '*' : ' ', o['id'], o['label'], detail)
          puts format('      why: %s', o['evidence'].to_s.gsub(/\s+/, ' ')[0, 96])
        end
        puts
        puts 'Present these with ONE AskUserQuestion (include the parity-only choice),'
        puts 'confirm any medium-risk item by name, then record the answer:'
        puts "  ruby scripts/enhance-select.rb --enhancements #{enh_path} \\"
        puts '    --option <option-id> [--confirm-medium <ids>]'
        puts 'For an app archetype, ask editable/approval/scenario/agent/seed choices'
        puts 'and write app-plan.json before authoring:'
        puts "  ruby scripts/enhance-app-plan.rb --enhancements #{enh_path} \\"
        puts '    --option <option-id> --out <workdir>/app-plan.json'
        puts 'then re-run this exact --finalize command adding:'
        puts '  --enhance --enhance-accept <accepted_candidate_ids from enhance-selection.json>'
      end
      puts '================================================================================='
      mark('phaseE')
      phase_summary
      exit 14
    else
      _, ast = sigma_run!(['ruby', File.join(HERE, 'enhance-apply.rb'),
                           '--workbook-id', wb_id, '--enhancements', enh_path,
                           '--accept', opts[:enhance_accept],
                           '--out', File.join(WORK, 'enhance-report.json')], allow_fail: true)
      rep = (JSON.parse(File.read(File.join(WORK, 'enhance-report.json'))) rescue {})
      enhance_line = if ast.success?
                       "clone #{rep['clone_id']} '#{rep['clone_name']}': " \
                       "#{(rep['applied'] || []).size} applied, #{(rep['skipped'] || []).size} skipped, " \
                       "#{(rep['reverted'] || []).size} reverted; parity-unchanged gate GREEN"
                     else
                       "apply NOT GREEN (exit #{ast.exitstatus}) — see enhance-report.json"
                     end
    end
  end

  mark('phaseE') if enhance_requested

  # ---- v5.4: pivot grand-totals SHIP step -------------------------------------
  # A pivot carrying a `totals` key 500s its CSV export (probe-isolated v5.4:
  # the key's PRESENCE is the sole trigger — value type irrelevant), which
  # poisons verify-anchors' pivot exports, so verify-anchors STRIPS the key
  # around its own pivot CSV exports and restores it after (generated pivots
  # otherwise carry `totals` from build onward). Now that every gate is GREEN,
  # repair any pivot the bracket left totals-less on the shipped workbook as
  # the FINAL spec mutation — the same put-layout late-mutation channel
  # hidden-titles uses. Runs AFTER Phase E (the enhance clone verifies against
  # totals-free pivots too). Idempotent + non-fatal: a failure only means
  # visible grand-total rows, a documented cosmetic residual (ROUND6 §2.4).
  # --workdir (v5.4.9) lets the *-pivot-totals.json sidecar override apply on
  # this automated path too (incl. the restore sidecar verify-anchors writes).
  if all_green
    _, tst = sigma_run!(['ruby', File.join(HERE, 'put-layout.rb'),
                         '--workbook', wb_id, '--apply-pivot-totals',
                         '--workdir', WORK], allow_fail: true)
    line(tst.success? ? 'pivot grand-totals re-hidden on shipped workbook (final mutation)' :
         'WARN: pivot totals re-apply failed — workbook ships with visible grand-total rows (cosmetic residual)')
    mark('pivot-totals-ship')
  end

  pf = (JSON.parse(File.read(File.join(WORK, 'parity-final.json'))) rescue {})
  # ── W2.2 — factory punch list at EVERY finalize terminal ───────────────────
  # The gate battery above just derived + wrote degradation-ledger.json (its
  # own seam); render it into PUNCHLIST.md/punchlist.json — one re-entry
  # command per ledger line — whatever the verdict. GREEN ⇒ empty list
  # (shipped doctrine); a run that shipped LESS than the source now hands the
  # operator the exact converging commands instead of a prose apology.
  _pl_note = nil
  begin
    _, _plst = run!(['ruby', File.join(HERE, 'build-punchlist.rb'), '--workdir', WORK], allow_fail: true)
    _pl = (JSON.parse(File.read(File.join(WORK, 'punchlist.json'))) rescue nil)
    if _plst.success? && _pl.is_a?(Hash)
      _pl_note = "#{Array(_pl['items']).size} item(s), ledger verdict #{_pl['verdict']} → #{File.join(WORK, 'PUNCHLIST.md')}"
      Offramp.log(WORK, kind: 'punchlist-emitted', detail: _pl_note) if Array(_pl['items']).any?
      quiet_event('punchlist', 'items' => Array(_pl['items']).size, 'verdict' => _pl['verdict'])
    elsif !_plst.success?
      line "WARN: punch-list render failed (exit #{_plst.exitstatus}) — see build-punchlist.rb output above"
    end
  rescue StandardError
    nil
  end
  puts
  puts '================ RESULT ================'
  puts "dataModelId : #{state['data_model_id']}"
  puts "workbookId  : #{wb_id}"
  # An all-embedded workbook has 0 exportable charts — when the hard gate
  # accepted the anchors oracle instead, say THAT (a "FAIL (0/0)" line next to
  # STATUS: GREEN reads like a contradiction in the report).
  _av_sum = (JSON.parse(File.read(File.join(WORK, 'anchors-verdict.json'))) rescue nil)
  if pf['charts_total'].to_i.zero? && gst.success? && _av_sum && _av_sum['pass']
    puts "PARITY      : ANCHORS ORACLE (0 exportable view CSVs; #{_av_sum['matched']}/#{_av_sum['checked']} source anchors matched)"
  else
    puts "PARITY      : #{pf['status'] || '?'} (#{pf['charts_pass']}/#{pf['charts_total']} charts#{state['extract_mode'] ? ', extract-mode' : ''})"
  end
  puts "GATES       : phase6=#{p6st.success? ? 'PASS' : 'FAIL'} cleanup=#{clst.success? ? 'PASS' : 'FAIL'} assert-phase6-ran=#{gst.success? ? 'PASS' : "FAIL(#{gst.exitstatus})"} ds-filters=#{dsfst.success? ? 'PASS' : "FAIL(#{dsfst.exitstatus})"} action-gates=#{agst.success? ? 'PASS' : "FAIL(#{agst.exitstatus})"} source-census=#{census_st.success? ? 'PASS' : "FAIL(#{census_st.exitstatus})"} report=#{report_verdict}#{report_st.success? ? '' : "(#{report_st.exitstatus})"}"
  puts "ENHANCE     : #{enhance_line}" if enhance_line
  puts "PUNCH LIST  : #{_pl_note}" if _pl_note
  puts "STATUS      : #{all_green ? 'GREEN' : 'NOT GREEN'}"
  puts '======================================='
  quiet_event('result', 'stage' => 'finalize', 'status' => all_green ? 'GREEN' : 'NOT GREEN',
              'workbook_id' => wb_id, 'data_model_id' => state['data_model_id'],
              'gates' => { 'phase6' => p6st.exitstatus, 'cleanup' => clst.exitstatus,
                           'assert_phase6_ran' => gst.exitstatus, 'ds_filters' => dsfst.exitstatus,
                           'action_gates' => agst.exitstatus, 'source_census' => census_st.exitstatus,
                           'migration_report' => report_st.exitstatus,
                           'migration_report_verdict' => report_verdict })
  phase_summary
  # ── Same-failure loop breaker (signature + attempt cap) ────────────────────
  # A NOT-GREEN finalize records its gate signature; re-running --finalize into
  # the SAME failure a second time is grinding, not converging — hard-STOP and
  # hand control to the operator instead of looping toward a forced green
  # (refs/operating-contract.md: "don't spin, don't fake").
  # The signature keys every gate status that decides all_green — phase6,
  # cleanup, the census gate, assert-datasource-filters (PR-507 N1: the
  # ds-filters status was in all_green but absent here, so a ds-filter-only
  # NOT-GREEN signed as a tuple naming three PASSING gates — the exact
  # pathology the cleanup-key note below records), AND assert-action-gates
  # (Task 6 restructure — same reasoning: an action-gates-only NOT-GREEN must
  # not sign as a tuple naming four PASSING gates), source census, and the
  # terminal migration report — PLUS a digest of the
  # first FAILING child's error region. Exit codes alone collapse distinct
  # root causes (assert-phase6-ran.rb folds 84 exit sites into 31 codes; exit
  # 18 alone carries 6 causes), so a sub-cause flip used to read as "the EXACT
  # same failure". No mode/measure here, deliberately: the S2 progress rule
  # needs a known-polarity count, and these gates emit bigger-is-better rate
  # lines ("pass-rate=83.3%") where "no strict decrease" would false-stop
  # genuine progress; the unconditional attempt cap bounds finalize churn
  # instead. (Note: enriching the key changes finalize signature strings, so
  # 1-counts recorded by older builds no longer pair with new records —
  # acceptable: the breaker restarts counting on the more truthful signature,
  # the same trade taken when the cleanup key was added.)
  unless all_green
    _fail_out = if !gst.success? then gout
                elsif !parity_ok then p6out # p6 failure NOT excused by --min-pass-rate
                elsif !dsfst.success? then dsfout
                elsif !agst.success? then agout
                elsif !census_st.success? then census_out
                elsif !report_st.success? then report_out
                else clout
                end
    _fregion = Offramp.error_region(_fail_out)
    _fsig = Offramp.failure_signature(script: 'migrate-tableau', context: 'finalize',
                                      exit_code: { phase6: p6st.exitstatus, gate: gst.exitstatus,
                                                   cleanup: clst.exitstatus,
                                                   dsfilters: dsfst.exitstatus,
                                                   actiongates: agst.exitstatus,
                                                   census: census_st.exitstatus,
                                                   report: report_st.exitstatus,
                                                   report_verdict: report_verdict },
                                      error_region: _fregion)
    _fverdict = Offramp.loop_check(WORK, signature: _fsig, scope: 'migrate-tableau:finalize')
    if _fverdict != :first
      puts
      puts '==================== LOOP STOP (operator action required) ==================='
      if _fverdict == :cap
        puts "#{Offramp.scope_attempts(WORK, 'migrate-tableau:finalize')} NOT-GREEN finalize attempts in this " \
             'workdir — attempt budget exhausted'
        puts "(SIGMA_LOOP_ATTEMPT_CAP=#{Offramp::ATTEMPT_CAP}). The failures kept changing, so the"
        puts 'same-signature rule never fired; re-running --finalize is churning, not converging.'
      else
        _prior = Offramp.loop_active_trail(WORK).select { |r| r['signature'] == _fsig }[0..-2]
        puts 'A finalize failure with this same signature — the same failing-gate statuses and'
        puts "the same failing gate's error text — has now occurred #{_prior.size + 1} times:"
        _prior.each { |r| puts "  • #{r['at']}" }
        puts "  • (now)                #{_fsig}"
      end
      puts 'Re-running the same --finalize will not converge. STOPPING — hand this to the'
      puts "operator with the gate output above and the loop log (#{File.join(WORK, 'loop-log.jsonl')})."
      puts 'To re-arm the breaker once the cause is actually fixed: a GREEN finalize'
      puts "re-arms it automatically; otherwise clear #{File.join(WORK, 'loop-log.jsonl')} (operator-only)."
      puts '============================================================================='
      Offramp.log(WORK, kind: 'loop-stop', reason: _fsig)
    end
  else
    # GREEN re-arms the breaker: append a reset record (append-only — never
    # truncate) so signatures counted BEFORE this green cannot convert the
    # next unrelated same-signature failure, possibly days later on this
    # long-lived workdir, into a false hard-STOP. A green gate pass has just
    # disproven that those earlier occurrences were a non-converging loop.
    Offramp.loop_reset(WORK)
  end
  exit(all_green ? 0 : 3)
end

# ---------------------------------------------------------------------------
# Agent-authored JSON specs (--dm-spec / --wb-spec) — validated + wrapped into
# the `Specs` contract BEFORE discovery, so the FAST PATH below can route on
# them. The manual path's re-entry into the GATED spine: instead of hand-driving
# raw POSTs (which skip preflight/control lint, Phase 6 parity, and the
# assert-phase6-ran hard gate), the agent drops JSON specs and re-runs. The JSON
# is wrapped into the same `Specs` contract the .rb override uses, so the
# DOWNSTREAM flow (validate → post-and-readback → layout → parity → assert) is
# byte-for-byte identical to the hand-authored-.rb path. `wb_spec` returns the
# raw JSON; live-id binding (the "__DM_ID__" / "__DM_ELEMENT__:<Name>"
# placeholders) happens at the workbook assembly step, where dm_id / fact_eid /
# the DM readback elements are known. Reads are BOM-tolerant (PowerShell's
# Set-Content -Encoding UTF8 prepends a BOM plain JSON.parse rejects).
# ---------------------------------------------------------------------------
if opts[:dm_spec] || opts[:wb_spec]
  # 🚧 Manual-spec authorization gate (P1). Hand-authored specs must be a ROUTED
  # fallback, not a cold default — cold hand-authoring is the #1 way a run skips
  # the converter + gated spine. Accept --dm-spec/--wb-spec only when: (a) an
  # orchestrator STOP emitted <WORK>/manual-path-authorized.json, (b) --reuse-dm
  # carries an EXPLICIT id (the documented exit-4 fast-path re-entry against an
  # already-posted DM), or (c) an explicit --allow-manual-spec "<reason>" waiver.
  _ms_token  = File.exist?(File.join(WORK, 'manual-path-authorized.json'))
  _ms_reuse  = opts[:reuse_dm] && opts[:reuse_dm] != :recommended
  _ms_waiver = opts[:allow_manual_spec].to_s
  unless _ms_token || _ms_reuse || !_ms_waiver.empty?
    abort <<~MSG
      FATAL: --dm-spec/--wb-spec (hand-authored specs) is a ROUTED fallback, not a cold
      entry point. No orchestrator STOP is on record for this workdir
      (#{File.join(WORK, 'manual-path-authorized.json')} is absent) and no --reuse-dm <id>
      was given. Start with the one command so the converter + gates actually run:
          ruby scripts/migrate-tableau.rb --workbook "<name>" --connection <id>
      If it STOPS (CONVERTER STOP / workbook handoff) it authorizes this path and prints
      the exact --dm-spec/--wb-spec (or --reuse-dm --wb-spec) re-run.
      Deliberately hand-authoring anyway? Re-run adding --allow-manual-spec "<reason>".
    MSG
  end
  # Reason tokens come from the ONE shared vocabulary (E3.6 vocab half:
  # Offramp::MANUAL_SPEC_REASON_*) — never minted at the call site.
  Offramp.log(WORK, kind: 'manual-spec',
              reason: if !_ms_waiver.empty?
                        "#{Offramp::MANUAL_SPEC_REASON_WAIVER}: #{_ms_waiver}"
                      elsif _ms_token
                        Offramp::MANUAL_SPEC_REASON_STOP
                      else
                        Offramp::MANUAL_SPEC_REASON_REUSE
                      end)

  # The workbook spec is always agent-authored on this path.
  abort 'FATAL: --wb-spec is required for the agent-authored manual path ' \
        '(pair it with --dm-spec for a fresh build, or --reuse-dm for an existing model).' \
    unless opts[:wb_spec]
  # The DATA-MODEL source is exactly one of: --dm-spec (build it fresh) OR
  # --reuse-dm (attach to a model already in the org — the exit-4 re-entry, where
  # the DM is already posted). Both/neither is ambiguous.
  dm_sources = (opts[:dm_spec] ? 1 : 0) + (opts[:reuse_dm] ? 1 : 0)
  abort 'FATAL: provide the data model via EITHER --dm-spec <json> (fresh build) OR ' \
        '--reuse-dm <id> (attach to an existing model) — not both, not neither.' \
    unless dm_sources == 1
  abort "FATAL: --wb-spec #{opts[:wb_spec]} not found" unless File.exist?(opts[:wb_spec])
  begin
    wb_json = FastPath.read_json_utf8(opts[:wb_spec])
    dm_json = opts[:dm_spec] ? FastPath.read_json_utf8(opts[:dm_spec]) : nil
  rescue JSON::ParserError => e
    abort "FATAL: --dm-spec/--wb-spec is not valid JSON: #{e.message}"
  rescue Errno::ENOENT => e
    abort "FATAL: #{e.message}"
  end
  abort 'FATAL: --dm-spec JSON is not a page-bearing data-model spec (no top-level "pages" array)' \
    if dm_json && !(dm_json.is_a?(Hash) && dm_json['pages'].is_a?(Array))
  abort 'FATAL: --wb-spec JSON is not a page-bearing workbook spec (no document.pages array)' \
    unless wb_json.is_a?(Hash) && WorkbookCode.document(wb_json)['pages'].is_a?(Array)
  # Vendor-neutral CDW join-cost advisory (informational only; never gates). See refs/modeling-strategy.md.
  ModelingAdvisory.from_dm_spec(dm_json) if dm_json && defined?(ModelingAdvisory) && ModelingAdvisory.respond_to?(:from_dm_spec)
  Object.const_set(:Specs, Module.new do
    # nil on the --reuse-dm path: the DM is read back from the API, never rebuilt
    # from this module (so dm_spec is only consulted on the fresh --dm-spec path).
    define_singleton_method(:dm_spec) { dm_json }
    # Raw passthrough — live-id binding (the __DM_ID__/__DM_ELEMENT__ placeholders)
    # is applied at the assembly step where the readback ids exist.
    define_singleton_method(:wb_spec) { |_dm_id, _fact_eid| wb_json }
  end)
end
MANUAL_JSON_SPECS = !opts[:wb_spec].nil?

# ---------------------------------------------------------------------------
# 🚧 ROUTE PERSISTENCE (P2). migrate-state.json records HOW this workdir was
# driven ('orchestrated' | 'manual-authorized'). A re-entry on the OTHER route
# produces inconsistent state (a mechanical rebuild over hand-authored specs, or
# vice versa), so it fails closed. Sanctioned exceptions:
#   * switching TO the manual route through the same admit set as the
#     manual-spec gate above (STOP token / explicit --reuse-dm id /
#     --allow-manual-spec) — the designed handoff;
#   * an explicit --force-route-switch "<reason>" (recorded as an off-ramp and
#     counted as a quality waiver by assert-phase6-ran).
# --finalize is route-neutral: it resumes whatever pass 1 recorded.
# ---------------------------------------------------------------------------
CURRENT_ROUTE = MANUAL_JSON_SPECS ? 'manual-authorized' : 'orchestrated'
unless opts[:finalize]
  _prev_route = (JSON.parse(File.read(File.join(WORK, 'migrate-state.json')))['route'] rescue nil)
  if _prev_route && _prev_route != CURRENT_ROUTE
    _switch_ok =
      if opts[:force_route_switch] && !opts[:force_route_switch].to_s.empty?
        warn "WARN: route switch FORCED (#{_prev_route} → #{CURRENT_ROUTE}): #{opts[:force_route_switch]} — " \
             'counted as a quality waiver; name it in your report.'
        Offramp.log(WORK, kind: 'route-switch-forced',
                    reason: opts[:force_route_switch].to_s,
                    detail: "#{_prev_route} → #{CURRENT_ROUTE}")
        true
      elsif CURRENT_ROUTE == 'manual-authorized'
        # same admit set as the manual-spec gate (which already ran above)
        File.exist?(File.join(WORK, 'manual-path-authorized.json')) ||
          (opts[:reuse_dm] && opts[:reuse_dm] != :recommended) ||
          !opts[:allow_manual_spec].to_s.empty?
      else
        false
      end
    unless _switch_ok
      abort <<~MSG
        FATAL: this workdir was driven via the #{_prev_route} route; finish it the same way.
        (migrate-state.json records route=#{_prev_route}; this invocation is #{CURRENT_ROUTE}.)
        Re-run the way pass 1 was driven#{_prev_route == 'manual-authorized' ? ' (--reuse-dm <id> --wb-spec <path>)' : ' (the plain orchestrator command, no --wb-spec)'} —
        or, if the switch is deliberate, add --force-route-switch "<reason>" (a quality
        waiver: it is counted against the gate's waiver budget and must be in your report).
      MSG
    end
  end
end

# ---------------------------------------------------------------------------
# FAST PATH routing (--reuse-dm <id> + --wb-spec). See the header comment +
# --help banner for the exact semantics; the decision itself is a pure,
# offline-testable function (lib/fast_path.rb, scripts/test-fastpath-flags.rb).
# ---------------------------------------------------------------------------
twb = File.join(WORK, 'workbook-content.twb')
layout_json = File.join(WORK, 'dashboard-layout.json')
fp_artifacts = {
  'dashboard-layout.json' => File.exist?(layout_json),
  'views/*.csv'           => Dir[File.join(WORK, 'views', '*.csv')].any?,
  'workbook-content.twb'  => File.exist?(twb)
}
FAST = FastPath.decide(reuse_dm: opts[:reuse_dm], wb_spec: opts[:wb_spec],
                       dm_spec: opts[:dm_spec], finalize: opts[:finalize],
                       yes: opts[:yes], artifacts: fp_artifacts)
FASTPATH = FAST[:route] == :fast

if FASTPATH
  require File.join(HERE, 'mechanical-specs') # placeholder binding at Phase 4
  puts
  puts '── FAST PATH · --reuse-dm + --wb-spec ──'
  line 'skipping Tableau discovery and the decisions checkpoint: the wb-spec is'
  line "agent-authored (open questions were answered when it was written) and DM #{opts[:reuse_dm]} is live."
  if (FAST[:degraded] || []).any?
    line "WARN: DEGRADED — #{FAST[:degraded].size} discovery artifact(s) missing from #{WORK}:"
    FAST[:degraded].each { |a| line "  - #{a}" }
    line '  --yes: Tableau discovery is NOT re-run. Layout falls back to a stacked page and the'
    line '  parity plan may be unbuildable — restore the workdir (or re-run without --yes to'
    line '  re-fetch) before relying on the Phase 6 gates.'
    Offramp.log(WORK, kind: 'degraded-fastpath',
                detail: "#{FAST[:degraded].size} missing discovery artifact(s): #{FAST[:degraded].join(', ')}")
  else
    line "discovery artifacts present in #{WORK} — reused for layout + parity as normal"
  end
  RunState.skip(WORK, 'phase-1', 'FAST PATH (--reuse-dm + --wb-spec): discovery skipped, workdir artifacts reused')
  RunState.skip(WORK, 'phase-2', 'FAST PATH: DM is live — columns come from the readback')
  gwp = File.join(WORK, 'get-workbook.json')
  gw = File.exist?(gwp) ? (FastPath.read_json_utf8(gwp) rescue {}) : {}
  wb = gw['workbook'] || gw
  wb_name = wb['name'] || opts[:wb_name] || slug
  has_extracts = wb['hasExtracts'] == true || [wb['hasExtracts'], wb['datasources']].to_s.include?('true')
  reuse_dm_id = opts[:reuse_dm] # decide() guarantees an explicit id here (never :recommended)
  mechanical = false
  conv = nil
  mark('fastpath-route')
elsif opts[:reuse_dm] && opts[:wb_spec]
  line "fast path NOT taken: #{FAST[:reason]}"
end

unless FASTPATH # ═══ FULL PIPELINE (discovery → gates → decisions) ═══════════
# ---------------------------------------------------------------------------
# Phase 1 — Discover (Tableau side), INTERLEAVED. tableau-discover.rb (its own
# unified 5-fetch pool) + scan-workbook-gaps run as a BACKGROUND lane; the
# pure-Sigma-side phases (1.6 DM-reuse scan + 2 warehouse columns — read-only,
# no Sigma objects created) run concurrently in the foreground. The lanes JOIN
# before anything that consumes discovery output (calc fields, gap gate, view
# CSVs, decisions checkpoint) — every designed stop/gate fires exactly as in
# the serial flow, just sooner.
# ---------------------------------------------------------------------------
hdr(1, 'Discover')
$t_mark = Time.now

# ---------------------------------------------------------------------------
# Discovery REUSE (bead mg92). A 4-stop run must pay the ~112s Tableau fetch
# ONCE: stamp the out-dir per source revision (workbook luid + updatedAt). On
# re-entry, ONE cheap REST probe (~1s) decides:
#   * stamp matches + artifacts complete → SKIP the discovery lane entirely
#   * stamp differs / artifacts missing  → CLEAR the stale artifacts first so
#     lane_wait_for can never pick up a prior run's workbook-content.twb,
#     then re-fetch and re-stamp.
# ---------------------------------------------------------------------------
FAKE_OK = Struct.new(:exitstatus) do
  def success?
    exitstatus.zero?
  end
end
stamp_path = File.join(WORK, 'discovery-stamp.json')
disc_artifacts = [File.join(WORK, 'get-workbook.json'), twb, File.join(WORK, 'timings.json')]
probe = nil
probe_rb = +"$LOAD_PATH.unshift #{File.join(HERE, 'lib').inspect}; require 'tableau_rest'; require 'json'; "
probe_rb << if opts[:wb_id]
              "wb = Tableau.get_workbook(#{opts[:wb_id].inspect}); "
            else
              "h = Tableau.find_workbook_by_name(#{opts[:wb_name].inspect}) or abort 'no workbook'; wb = Tableau.get_workbook(h['id']); "
            end
probe_rb << "puts JSON.generate({ 'id' => wb['id'], 'updatedAt' => wb['updatedAt'] })"
# Run ruby directly with the Tableau token injected via env (Windows-safe) —
# no bash, no `eval "$(get-tableau-token.sh)"`, no shell-quoting of the script.
probe_out, probe_st = Open3.capture2e(tableau_env, RbConfig.ruby, '-e', probe_rb)
probe = (JSON.parse(probe_out.lines.last.to_s) rescue nil) if probe_st.success?
stamp = (JSON.parse(File.read(stamp_path)) rescue nil)
disc_complete = disc_artifacts.all? { |p| File.exist?(p) } &&
                Dir[File.join(WORK, 'views', '*.csv')].any?
disc_scope = (opts[:dashboards] || []).sort # W2.20: scoped runs fetch FEWER view CSVs
stamp_scope_ok = stamp && ((s = stamp['csv_scope'].to_a) == disc_scope || s.empty?) # []/legacy stamp = unscoped superset, serves any scope
reuse_discovery = probe && stamp && stamp_scope_ok &&
                  stamp['workbook_id'] == probe['id'] && stamp['updatedAt'] == probe['updatedAt'] &&
                  disc_complete
# Probe-failure resilience (speed hardening): a TRANSIENT probe failure must
# not nuke a complete, stamped discovery and re-pay the full Tableau fetch —
# worse, if Tableau is genuinely unreachable the re-fetch dies too, AFTER
# clearing a perfectly good cache. Reuse the stamped artifacts with a loud
# WARN instead; delete discovery-stamp.json to force a re-fetch.
probe_failed_reuse = !probe && stamp && stamp_scope_ok && disc_complete
reuse_discovery ||= probe_failed_reuse

disc_log = File.join(WORK, 'phase1-discover.log')
if reuse_discovery
  lane = { started: Time.now, ended: Time.now, status: FAKE_OK.new(0), reused: true }
  if probe_failed_reuse
    line "WARN: workbook-revision probe FAILED (#{probe_out.lines.last.to_s.strip[0, 120]})"
    line "      REUSING stamped discovery from #{stamp['stamped_at']} (workbook #{stamp['workbook_id']}, " \
         'source revision UNVERIFIED this run) — delete discovery-stamp.json to force a re-fetch.'
  else
    line "discovery REUSED (stamp match: workbook #{probe['id']} updatedAt=#{probe['updatedAt']}; " \
         "#{Dir[File.join(WORK, 'views', '*.csv')].size} view CSVs already on disk) — Tableau fetch skipped"
  end
else
  unless probe
    line "WARN: workbook-revision probe failed (#{probe_out.lines.last.to_s.strip[0, 120]}); discovery will re-fetch"
  end
  # Clear stale artifacts from any prior run — lane_wait_for polls File.exist?,
  # so a leftover file would short-circuit the wait with stale content.
  stale = (disc_artifacts + [stamp_path, File.join(WORK, 'ds-metadata.json'),
                             File.join(WORK, 'graphql-fields.json'), File.join(WORK, 'calc-fields.json'),
                             File.join(WORK, 'workbook-content.twbx')] +
           Dir[File.join(WORK, 'views', '*')] + Dir[File.join(WORK, '*gaps*report*')])
          .select { |p| File.exist?(p) }
  if stale.any?
    line "cleared #{stale.size} stale discovery artifact(s) from a prior run (source revision unknown or changed)"
    stale.each { |p| FileUtils.rm_f(p) }
  end
  disc = ['ruby', File.join(HERE, 'tableau-discover.rb'), '--out', WORK]
  disc += opts[:wb_id] ? ['--workbook-id', opts[:wb_id]] : ['--workbook-name', opts[:wb_name]]
  # Live repoint (--skip-extract-landing): the operator owns the DM table paths,
  # so the frozen extract bytes are never consumed on this route — skip
  # discovery's heavy includeExtract=true re-download instead of paying for an
  # unused multi-GB payload.
  disc << '--no-extract-refetch' if opts[:skip_extract_landing]
  # W2.20 (lane F): thread the dashboard scope into discovery (member-sheet CSVs
  # only; discovery FAILS OPEN to all views, stated, when membership is unresolvable).
  (opts[:dashboards] || []).each { |d| disc += ['--dashboard', d] }
  disc_sh = disc.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')
  scan_sh = ['ruby', File.join(HERE, 'scan-workbook-gaps.rb'), twb]
            .map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')
  File.write(disc_log, '')
  # Gap scan runs in the lane as soon as its input (the .twb) is ready — i.e.
  # right after discovery lands it. Scan failure is tolerated (same as before);
  # discovery failure is the lane's exit code.
  # Token injected via env (Windows-safe); bash still orchestrates the lane
  # (rc capture + conditional gap scan) but no longer sources creds via a
  # fragile `eval "$(get-tableau-token.sh)"` that breaks under PowerShell/$HOME.
  lane_cmd = "#{disc_sh}; rc=$?; " \
             "if [ $rc -eq 0 ] && [ -f '#{twb}' ]; then #{scan_sh} || true; fi; exit $rc"
  lane = { started: Time.now, status: nil }
  lane[:pid] = Process.spawn(tableau_env, 'bash', '-c', lane_cmd, %i[out err] => [disc_log, 'a'])
  line "Tableau discovery + gap scan: BACKGROUND lane (pid #{lane[:pid]}, log #{File.basename(disc_log)})"
  line 'Sigma-side phases 1.6 + 2 run concurrently; lanes join before discovery output is consumed.'
end

lane_done = lambda do
  next true if lane[:status]
  if (st = Process.wait2(lane[:pid], Process::WNOHANG))
    lane[:status] = st[1]
    lane[:ended] = Time.now
    # Stamp the completed discovery for resume reuse (bead mg92) — but ONLY a
    # COMPLETE one: a run with failed fetch tasks (Tableau Cloud's transient
    # 400s) must not be blessed, or the resume reuses a discovery with missing
    # view CSVs and tiles silently drop. No stamp = the next run re-fetches.
    if st[1].success? && probe
      tj = (JSON.parse(File.read(File.join(WORK, 'timings.json'))) rescue nil)
      # Only ESSENTIAL tasks block the stamp (view CSVs / .twb / workbook meta).
      # A persistently-failing dashboard PNG must not force re-paying discovery
      # on every resume.
      failed = tj ? (tj['tasks'] || []).select { |t| t['ok'] == false && t['task'].to_s =~ /\A(csv:|twb|get-workbook)/ } : []
      if failed.empty?
        File.write(stamp_path, JSON.pretty_generate(
                                 'workbook_id' => probe['id'], 'updatedAt' => probe['updatedAt'],
                                 'csv_scope' => disc_scope, 'stamped_at' => Time.now.utc.iso8601))
      else
        line "discovery NOT stamped for reuse — #{failed.size} fetch task(s) failed " \
             "(#{failed.map { |t| t['task'] }.join(', ')[0, 120]}); a resume will re-fetch"
      end
    end
    true
  else
    false
  end
end
print_lane_log = lambda do
  next if lane[:reused] # prior run's log — already shown on the run that fetched
  File.read(disc_log, encoding: 'UTF-8').each_line { |l| puts "   │ #{l.rstrip}" } if File.exist?(disc_log)
end
# Wait for a lane artifact (tableau-discover writes them atomically). Returns
# false when the lane exits without producing it. Bounded (hard timeout) with a
# 30s progress heartbeat so a long fetch never LOOKS wedged (poll-bounds audit).
lane_wait_for = lambda do |path, what, timeout = 600|
  t0 = Time.now
  beat = t0
  until File.exist?(path)
    if lane_done.call
      return File.exist?(path)
    end
    if Time.now - beat > 30
      beat = Time.now
      puts "   … still waiting for #{what} from the discovery lane " \
           "(#{(Time.now - t0).round}s elapsed, timeout #{timeout}s; tail #{File.basename(disc_log)} for progress)"
    end
    abort "FATAL: timed out (#{timeout}s) waiting for #{what} from the discovery lane" if Time.now - t0 > timeout
    sleep 0.1
  end
  true
end

unless lane_wait_for.call(File.join(WORK, 'get-workbook.json'), 'get-workbook.json')
  print_lane_log.call
  abort "FATAL: discovery lane exited (#{lane[:status]&.exitstatus}) before producing get-workbook.json"
end

gw = JSON.parse(File.read(File.join(WORK, 'get-workbook.json')))
wb = gw['workbook'] || gw
wb_luid = wb['id'] || opts[:wb_id]
wb_name = wb['name'] || opts[:wb_name] || slug
has_extracts = [wb['hasExtracts'], wb.dig('datasources')].to_s.include?('true') ||
               wb['hasExtracts'] == true
views = (wb.dig('views', 'view') || [])
views = [views] unless views.is_a?(Array)
line "workbook '#{wb_name}' (#{wb_luid}): #{views.size} view(s)#{has_extracts ? ', hasExtracts=true' : ''}"

# E9.6 — resolve a mission single-view URL scope to its dashboard NAME now
# that the views list exists (the /#/views/<wb>/<segment> segment is the
# view's contentUrl tail — the display name with spaces/punctuation stripped).
# Appends to the mutable DASH_SCOPE BEFORE its first consumer (the parse).
if MISSION_VIEW_SEGMENTS.any? && (opts[:dashboards] || []).empty? && (opts[:pages] || []).empty?
  seg_names = MISSION_VIEW_SEGMENTS.map do |seg|
    hit = views.find do |vw|
      vw.is_a?(Hash) &&
        (vw['contentUrl'].to_s.split('/').last == seg ||
         vw['name'].to_s.gsub(/[^A-Za-z0-9]/, '') == seg.gsub(/[^A-Za-z0-9]/, ''))
    end
    hit ? hit['name'].to_s : seg # unresolved → the raw segment (mismatch STOP names it below)
  end.uniq
  opts[:dashboards] = seg_names
  DASH_SCOPE.concat(seg_names.flat_map { |n| ['--dashboard', n] })
  line "mission scope: single-view URL → dashboard #{seg_names.map(&:inspect).join(', ')}"
end

have_twb = lane_wait_for.call(twb, 'workbook-content.twb') # layout_json defined at the FAST PATH routing block
# .twb content sha — the input key for every phase that is a pure function of
# the workbook XML (parse-twb-layout, calc extraction, custom-SQL scan). On a
# re-entry with the same .twb these skip via PhaseCache (refs/performance.md).
twb_sha = have_twb ? PhaseCache.file_sha(twb) : nil
if have_twb
  # The key carries the PARSER's own sha too: the output is a function of the
  # .twb AND the parser code — without it, a resumed workdir kept serving a
  # stale dashboard-layout.json across parser upgrades (v5.1.1 review-caught).
  parser_sha = PhaseCache.file_sha(File.join(HERE, 'parse-twb-layout.rb'))
  parse_st = PhaseCache.cached(WORK, 'parse-twb-layout',
                               key: PhaseCache.key(twb_sha, parser_sha, DASH_SCOPE.join(' ')),
                               outputs: [layout_json]) do
    run!(['ruby', File.join(HERE, 'parse-twb-layout.rb'), twb, layout_json] + DASH_SCOPE)
  end
  line 'parse-twb-layout REUSED (.twb sha + scope unchanged) — delete dashboard-layout.json to force a re-parse' if parse_st == :reused
  line "per-dashboard scope: #{(opts[:dashboards] || []) + (opts[:pages] || [])} (single-tab build)" if scoped?
  dash = JSON.parse(File.read(layout_json))
  # E9.6 — a scoped name that matches NOTHING is a named STOP listing the
  # workbook's dashboards, never a silent full-workbook (or silent EMPTY) run.
  if scoped?
    emitted = (dash.is_a?(Array) ? dash : [dash]).map { |d| d.is_a?(Hash) ? d['dashboard'].to_s : '' }
                                                 .reject(&:empty?)
    asked = (opts[:dashboards] || [])
    unmatched = asked.reject do |a|
      emitted.any? { |e| e.casecmp?(a) || e.downcase.include?(a.downcase) }
    end
    if emitted.empty? || unmatched.any?
      avail = begin
        # binread + scrub: a Windows UTF-16 .twb read as UTF-8 would list zero
        # dashboards in this banner (error-message-only path, never a gate).
        # ACCEPTED LIMITATION (PR #509 review R10): BOM-LESS UTF-16 (no FF FE /
        # FE FF prefix) is not sniffed, so such a .twb still lists zero
        # dashboards here. Banner-only blast radius — scope MATCHING uses
        # `emitted` (from layout_json), and the rescue fails open to [] — so
        # the optional NUL-heavy-window sniff stays a wave-2 nicety, not a fix
        # this stop depends on.
        raw = File.binread(twb)
        raw = raw.encode('UTF-8', 'UTF-16', invalid: :replace, undef: :replace) if raw[0, 2] == "\xFF\xFE".b || raw[0, 2] == "\xFE\xFF".b
        raw.force_encoding('UTF-8').scrub('?').scan(/<dashboard\s+[^>]*name=['"]([^'"]+)['"]/).flatten.uniq
      rescue StandardError
        []
      end
      puts
      puts '==================== SCOPE STOP (dashboard not found — exit 19) ============='
      if unmatched.any?
        puts "The stated scope names #{unmatched.size} dashboard(s) that match NOTHING in this workbook:"
        unmatched.each { |a| puts "  - #{a.inspect}" }
      else
        puts 'The stated scope (--page ids / mission.json) matched NO dashboard in this workbook.'
      end
      puts "This workbook's dashboards#{avail.any? ? '' : ' (none found in the .twb)'}:"
      avail.each { |d| puts "  - #{d.inspect}" }
      puts 'Fix the scope (mission.json scope / --dashboard flag — name or unambiguous substring,'
      puts 'case-insensitive) and re-run; a scoped mission must never silently fan out to all'
      puts 'dashboards, and an empty scoped build would ship nothing.'
      puts '============================================================================='
      puts 'No Sigma objects were created.'
      Offramp.log(WORK, kind: 'scope-mismatch-stop',
                  detail: "asked: #{asked.join(', ')}; workbook has: #{avail.join(', ')[0, 300]}")
      quiet_event('stop', 'code' => 19, 'unmatched' => unmatched)
      mark('phase1-foreground')
      phase_summary
      exit 19
    end
  end
  zones = dash.is_a?(Array) ? dash.flat_map { |d| d['zones'] || [] } : (dash['zones'] || [])
  chart_zones = zones.select { |z| z['kind'] == 'chart' }
  kinds = chart_zones.map { |z| z['chart_kind'] }.compact
                     .each_with_object(Hash.new(0)) { |k, h| h[k] += 1 }
                     .map { |k, c| c > 1 ? "#{k}×#{c}" : k }.join(', ')
  line "parsed .twb: #{chart_zones.size} chart zone(s) (#{kinds})"
else
  chart_zones = []
  line 'no .twb content (MCP-only datasource?) — chart-kind/calc discovery degraded'
end

# calc fields / custom-SQL / gap gate / empty-CSV preflight all consume
# discovery-lane output — they run AFTER the lane join below. The spec
# generation here only needs the .twb (already landed).

# ---------------------------------------------------------------------------
# Spec generation. The DEFAULT path is MECHANICAL (no agent hand-authoring):
#   convert_tableau_to_sigma → DM spec; parse-twb-layout + build-charts-from-
#   signals + an auto-derived master-map → workbook spec. An explicit --specs
#   <path> (or a per-workbook <workdir>/specs.rb the human dropped in) overrides
#   the mechanical path with a hand-authored `Specs` module, used verbatim.
# ---------------------------------------------------------------------------
require File.join(HERE, 'mechanical-specs')
# Agent-authored JSON specs (--dm-spec / --wb-spec) were validated + wrapped
# into the `Specs` contract BEFORE discovery (see the hoisted block above the
# FAST PATH routing) so the fast path can route on them. They take precedence
# over a workdir specs.rb — an explicit CLI flag wins.
have_specs = MANUAL_JSON_SPECS
if MANUAL_JSON_SPECS
  line "spec generator: agent-authored JSON specs (#{opts[:dm_spec] ? "--dm-spec #{opts[:dm_spec]}" : "--reuse-dm #{opts[:reuse_dm]}"}, --wb-spec #{opts[:wb_spec]}) — routing through the gated spine"
else
  specs_path = opts[:specs] || [File.join(WORK, 'specs.rb')].find { |p| File.exist?(p) }
  if specs_path && File.exist?(specs_path)
    begin
      require specs_path.sub(/\.rb$/, '')
      have_specs = defined?(Specs) && Specs.respond_to?(:dm_spec) && Specs.respond_to?(:wb_spec)
      line "spec generator: hand-authored Specs module (#{specs_path})" if have_specs
    rescue StandardError => e
      line "(spec generator at #{specs_path} failed to load: #{e.message})"
    end
  end
end

# Mechanical converter run (the default). Requires the .twb (parse-twb-layout
# already gated on have_twb above) and a converter backend — local build by
# default, hosted MCP only on explicit consent (see backend resolution below).
# -------------------------------------------------------------------------
# WAREHOUSE DB/SCHEMA RESOLUTION — there is NO default database. Every org
# has its own warehouse (and the workbook itself usually names it), so a
# fabricated fallback turns "could not derive" into a wall of 404s at DM
# POST. E2E-caught: a Virtual-Connection workbook derived nothing, shipped a
# placeholder default, and every table pointed at a nonexistent database —
# while offline CI stayed green because the fixtures carried the same
# placeholder. Field-caught twice more (C1): live warehouse workbooks carry
# dbname/schema on their <connection> elements, but only explicit flags were
# honored. Precedence: --db/--schema flags → landing manifest (landed
# extracts are authoritative) → the workbook's own <connection> attributes →
# hard STOP naming the flags. Never a guess.
#
# G7 (run-2 field failure, 2026-07-15): when extracts were landed, the
# AUTHORITATIVE db/schema is the landing manifest's fully-qualified sf_table
# paths. A generic default here once returned ZERO real columns for a landed
# schema, which silently disabled fixup_dm_spec's caption→physical remap AND
# its phantom-column drop AND the rollup discriminator — one wiring gap
# defanged three codified mechanisms and cost ~16 min of hand re-derivation.
manifest_dbschema = lambda do
  mani = Dir[File.join(WORK, '*landing-manifest*.json')].first
  return nil unless mani
  rows = JSON.parse(File.read(mani))
  rows = rows['tables'] if rows.is_a?(Hash) && rows['tables'].is_a?(Array)
  fqns = Array(rows).map { |r| r.is_a?(Hash) ? r['sf_table'].to_s : '' }
                    .select { |s| s.count('.') >= 2 }
  return nil if fqns.empty?
  pairs = fqns.map { |s| s.split('.')[0, 2] }.uniq
  if pairs.length > 1
    line "WARN: landing manifest spans multiple db.schema pairs (#{pairs.map { |p| p.join('.') }.join(', ')}) — using the first; pass --db/--schema to override"
  end
  pairs.first
rescue StandardError => e
  line "WARN: could not derive db/schema from landing manifest (#{e.class}) — falling back"
  nil
end
wh_try = lambda do |twb_p|
  return [opts[:db], opts[:schema], '--db/--schema flags'] if opts[:db] && opts[:schema]
  mani = manifest_dbschema.call
  return [mani[0], mani[1], 'landing manifest'] if mani
  pairs = HydrateCustomSql.twb_dbschema(twb_p)
  if pairs.length > 1
    line "NOTE: workbook connections span multiple db.schema pairs (#{pairs.map { |p| p.join('.') }.join(', ')}) — " \
         'using the first for catalog discovery; each datasource keeps its own connection path; --db/--schema overrides all'
  end
  return [pairs[0][0], pairs[0][1], 'workbook <connection> attributes'] if pairs.any?
  nil
end
wh_announced = false
wh_require = lambda do |twb_p|
  got = wh_try.call(twb_p)
  abort <<~MSG unless got
    FATAL: cannot determine the warehouse database/schema for this workbook — and there
    is NO default (every org's warehouse is different; a guessed name 404s at DM POST).
    Searched, in order: --db/--schema flags (absent) → landing manifest (none) → the
    workbook's own <connection dbname=/schema=> attributes (none usable — published,
    virtual-connection, and extract-only connections don't carry a warehouse path).
    Re-run with explicit flags naming where this workbook's tables live in YOUR warehouse:
      --db <DATABASE> --schema <SCHEMA>
    Find them in the Tableau datasource's connection details (Data Source tab → connection),
    or by browsing the Sigma connection's catalog to the tables.
  MSG
  unless wh_announced
    line "warehouse db/schema: #{got[0]}.#{got[1]} (#{got[2]})"
    wh_announced = true
  end
  got
end

mechanical = !have_specs
conv = nil
if mechanical
  unless have_twb
    reap_lane!(lane_done) # bounded reap of the background lane before aborting
    print_lane_log.call
    abort <<~MSG
      FATAL: mechanical conversion needs the workbook .twb (for the data model +
      chart signals), but none was downloaded (MCP-only datasource?). Either
      supply a hand-authored Specs module via --specs, or use a .twb-backed
      workbook.
    MSG
  end
  # Converter backend — LOCAL-FIRST, never silently upload customer data. The
  # .twb holds customer schema / SQL / calc formulas; the hosted converter MCP
  # would send it to a third-party server, which many customers cannot allow.
  #   1. LOCAL (default, no egress): TABLEAU_MCP_BUILD → a local build/tableau.js
  #      (or a locally-run sigma-data-model MCP). Data never leaves the machine.
  #   2. HOSTED (sigma-data-model-mcp.onrender.com) ONLY on explicit consent
  #      (--converter hosted or SIGMA_CONVERTER_ALLOW_HOSTED=1) — the .twb is
  #      uploaded off-box.
  #   3. Otherwise STOP with both options — NEVER fall back to hosted silently.
  mcp_build = ENV['TABLEAU_MCP_BUILD']
  if mcp_build && !File.exist?(mcp_build)
    line "WARN: TABLEAU_MCP_BUILD=#{mcp_build} does not exist — ignoring"
    mcp_build = nil
  end
  # Resolve the LOCAL converter build when TABLEAU_MCP_BUILD is unset, so the
  # no-egress local path is the ZERO-config default — the mechanical path runs
  # without any setup instead of dropping to the manual STOP. The VENDORED build
  # (converter/tableau.mjs, shipped inside this skill) is the guaranteed final
  # fallback: no clone, no npm install, no network. The local converter is NOT a
  # server — it's a pure function (XML → Sigma JSON) run via `node`; nothing
  # leaves the box. First hit wins; purely filesystem (never the network), so a
  # miss just falls through to the consent/STOP logic below.
  #
  # issue #227: a local dev checkout is used ONLY when EXPLICITLY pointed at —
  # TABLEAU_MCP_BUILD, SIGMA_DATA_MODEL_MCP, or the fetch-converter.sh vendor
  # target. There is NO silent auto-discovery of ~/… checkouts (that made a dev's
  # machine convert differently from a customer's). Otherwise the pinned vendored
  # bundle runs, so output is identical everywhere.
  # Explicit `--converter hosted` is a deliberate opt-in to off-box conversion —
  # don't let local resolution (esp. the always-present vendored build) silently
  # override it. SIGMA_CONVERTER_ALLOW_HOSTED is only a *permission*, not a
  # preference, so it still prefers local when a build is found.
  if mcp_build.nil? && opts[:converter] != 'hosted'
    auto = [
      (ENV['SIGMA_DATA_MODEL_MCP'] && File.join(ENV['SIGMA_DATA_MODEL_MCP'], 'build', 'tableau.js')),
      File.join(HERE, 'vendor', 'sigma-data-model-mcp', 'build', 'tableau.js'), # fetch-converter.sh target (gitignored, explicit dev opt-in)
      File.expand_path('../converter/tableau.mjs', HERE) # vendored in-skill — always present
    ].compact.find { |p| File.exist?(p) }
    if auto
      mcp_build = auto
      vendored = auto == File.expand_path('../converter/tableau.mjs', HERE)
      msg = vendored ? 'vendored build (converter/tableau.mjs)' : "build #{auto}"
      line "converter: auto-discovered LOCAL #{msg} (no data leaves this machine" \
           "#{vendored ? '' : '; set TABLEAU_MCP_BUILD to override'})"
    end
  end
  allow_hosted = opts[:converter] == 'hosted' || ENV['SIGMA_CONVERTER_ALLOW_HOSTED'] == '1'
  if mcp_build
    line "converter: LOCAL build #{mcp_build} (no data leaves this machine)"
  elsif allow_hosted
    line 'converter: HOSTED MCP (sigma-data-model-mcp.onrender.com) — NOTE: the .twb is uploaded'
    line '           to this third-party server (opted in via --converter hosted / SIGMA_CONVERTER_ALLOW_HOSTED).'
    if opts[:fact_table]
      line "WARN: --fact-table #{opts[:fact_table]} cannot reach the HOSTED converter (no factTable in its arg schema) —"
      line '      the converter-side fact election (helper SQL FROM tables, relationship orientation) runs unoverridden;'
      line '      only the Ruby-side pick_fact preference applies. For the full override use a LOCAL build (TABLEAU_MCP_BUILD).'
    end
  else
    reap_lane!(lane_done) # bounded reap of the background lane before aborting
    print_lane_log.call
    # Authorize the option-2 agent-authored-spec re-entry (the re-run passes
    # --dm-spec/--wb-spec; the manual-spec gate requires this token or refuses a
    # cold hand-author).
    authorize_manual_path!(via: 'converter-stop', reason: 'no converter backend configured', exit_code: 1)
    Offramp.log(WORK, kind: 'converter-stop', reason: 'no converter backend configured')
    abort <<~MSG
      ==================== CONVERTER STOP (no backend) ====================
      No mechanical Tableau→Sigma converter is configured, and hosted conversion was not
      consented to. The .twb holds customer schema/SQL/formulas, so this skill will NOT
      upload it to the hosted converter without explicit consent.

      DO NOT hand-drive raw POSTs from here — that path skips preflight/control lint, the
      Phase-6 parity check, and the assert-phase6-ran hard gate (the exact regression that
      ships a workbook with missing controls and an unverified parity claim). Instead pick
      one of the three options below; the spec you produce re-enters the SAME gated spine.

        1. LOCAL converter (no data egress, RECOMMENDED): set TABLEAU_MCP_BUILD to a local
           build/tableau.js (or run the sigma-data-model MCP locally), then re-run this command
           verbatim. The mechanical path takes over. See QUICKSTART "Converter backend".

        2. AGENT-AUTHORED SPECS (when no local build is available): produce the specs once,
           then re-enter the gated spine — DO NOT POST them yourself:
             • If the sigma-data-model MCP is available to you, call convert_tableau_to_sigma
               on this .twb to get the DM spec; author the matching workbook spec (use the
               companion sigma-workbooks skill). Reference the data model via the placeholders
               "__DM_ID__" and "__DM_ELEMENT__:<ElementName>" (fact = "__DM_ELEMENT__:__FACT__").
             • Write #{WORK}/dm-spec.json and #{WORK}/wb-spec.json, then re-run:
                 ruby scripts/migrate-tableau.rb <same flags> \\
                   --dm-spec #{WORK}/dm-spec.json --wb-spec #{WORK}/wb-spec.json
             • This runs validate → post-and-readback (preflight/control lint + column guard)
               → layout → parity, and STOPS at exit 12 for you to collect actuals + --finalize.

        3. HOSTED converter (uploads the .twb to sigma-data-model-mcp.onrender.com): re-run with
           --converter hosted (or SIGMA_CONVERTER_ALLOW_HOSTED=1) to consent.

      A conversion is NOT done until `scripts/assert-phase6-ran.rb` exits 0 — that is a hard
      gate, not a guideline, on every path above.
      =====================================================================
    MSG
  end
  # ── Published-datasource (sqlproxy) hydration ──────────────────────────────
  # A workbook that connects to a PUBLISHED data source carries only a
  # <connection class='sqlproxy'> placeholder — the real relation (a warehouse
  # TABLE or a Custom SQL <relation type='text'>) lives in the PDS object on
  # Tableau Server, not the .twb. Left as-is the converter fabricates a phantom
  # table (<db>.<schema>.SQLPROXY) → POST "Source not found".
  #
  # PRIMARY: resolve-published-ds.rb resolves each PDS by contentUrl (== the
  # sqlproxy `dbname`), downloads GET /datasources/{id}/content, and reads the
  # inner .tds's real relation — reliable regardless of Metadata-API lineage lag.
  # FALLBACK: extract-custom-sql.rb (Metadata GraphQL) for Custom SQL. Then
  # hydrate-custom-sql.rb splices the real relation (table or SQL) so the
  # converter's normal path builds the model. No-ops for non-sqlproxy workbooks.
  # ── Embedded-extract (file-based) source routing ────────────────────────────
  # A workbook whose datasources are ALL embedded file federations (excel-direct /
  # textscan / hyper / ogrdirect / csv / msexcel) has no live warehouse for Sigma
  # to query — the frozen extract data must be LANDED first (scripts/
  # land-extracts.py; refs/extract-landing.md). Landing is byte-identical to what
  # Tableau rendered, so Phase 6 parity runs in EXACT mode — never drift mode.
  embedded_classes = %w[excel-direct textscan hyper ogrdirect csv msexcel]
  # Basemap / non-data connection classes carry NO queryable data (map tile
  # providers, WMS). They must not defeat the embedded-extract detection the way
  # a stray class='MapBox' (from a geo mark) otherwise would — dropping the
  # embedded path, the landing manifest, and the source.path remap.
  nondata_classes = %w[mapbox tableau-map wms wms-server]
  # #685-A: sqlproxy detection must be scoped PER-DATASOURCE, not per-workbook.
  # twb_has_sqlproxy?(twb) is a workbook-wide "does ANY datasource here use
  # sqlproxy" question — gating this whole embedded-extract-landing block on
  # its negation used to disable landing/remap for the ENTIRE workbook the
  # moment ONE unrelated datasource was sqlproxy-backed (e.g. Superstore's
  # "Commission Model" dashboard, fed by a published/file-based datasource
  # with no landing path), even though a perfectly landable SIBLING datasource
  # (the embedded "Sample - Superstore" Hyper extract) sat right next to it.
  # non_sqlproxy_conn_classes scopes the eligibility scan to datasources that
  # are NOT themselves sqlproxy-only, so the sqlproxy sibling's class can never
  # leak into "is everything else here an embedded extract" — the sqlproxy
  # datasource itself is still handled separately by the PDS-hydration block
  # below (HydrateCustomSql.twb_has_sqlproxy? there is unchanged; both blocks
  # can now fire in the SAME run for a mixed workbook).
  if have_twb
    sqlproxy_ds_names = HydrateCustomSql.sqlproxy_only_datasource_names(twb)
    if sqlproxy_ds_names.any?
      line "sqlproxy datasource(s) detected (#{sqlproxy_ds_names.join(', ')}) — scoping embedded-extract " \
           'detection to the REMAINING datasource(s) only (#685-A: a sqlproxy datasource must not disable ' \
           'landing/remap for an unrelated, landable sibling datasource)'
    end
    conn_classes = begin
      HydrateCustomSql.non_sqlproxy_conn_classes(twb)
        .reject { |c| c == 'federated' || nondata_classes.include?(c.to_s.downcase) }
    rescue StandardError
      []
    end
    if conn_classes.any? && (conn_classes - embedded_classes).empty?
      landing_manifest = Dir[File.join(WORK, '*landing-manifest*.json')].first
      # A pre-existing EMPTY manifest ([], from a pre-v5.2.1 payload-less run)
      # must not satisfy the gate either (review-caught) — treat as absent.
      if landing_manifest
        lm_body = JSON.parse(File.read(landing_manifest)) rescue nil
        if lm_body.is_a?(Array) && lm_body.empty?
          line "WARN: #{File.basename(landing_manifest)} is EMPTY (0 tables) — ignoring it (nothing was landed)"
          File.delete(landing_manifest)
          landing_manifest = nil
        end
      end
      # v5.2 (speed): AUTO-LAND when everything the manual step needs is
      # already on disk — discovery auto-refetched the .twbx WITH the extract
      # payload (v4.4), the connection id is a required arg, and --db/--schema
      # default the target. Round 4 burned a full exit-17 → model → re-run
      # round-trip on a step that was deterministic. Failure falls through to
      # the original exit-17 instructions; --no-auto-land opts out.
      twbx_payload = File.join(WORK, 'workbook-content.twbx')
      # Identity PRECONDITION (v5.2.1 review-caught: without it the AUTO-LANDING
      # banner printed and then always failed — land-extracts.py hard-requires
      # account+user). Resolvable = env or the neutral cred file carries them;
      # land-extracts.py itself resolves the same way.
      sf_env = {}
      neutral = File.expand_path('~/.sigma-migration/env')
      if File.exist?(neutral)
        File.readlines(neutral).each do |l|
          # SAME grammar as land-extracts.py's load_neutral_env (KEY=VALUE, no
          # whitespace around '=') — a laxer Ruby regex would say "resolvable"
          # for a line Python then can't read (review-caught).
          m = l.match(/\A\s*(?:export\s+)?(SNOWFLAKE_\w+)=(.+?)\s*\z/)
          sf_env[m[1]] = m[2].gsub(/\A["']|["']\z/, '') if m
        end
      end
      sf_ok = %w[SNOWFLAKE_ACCOUNT SNOWFLAKE_USER].all? { |k| !ENV[k].to_s.empty? || !sf_env[k].to_s.empty? }
      # Landing TARGET db/schema — where the extract tables get written. There is
      # NO default (E2E-caught: a fabricated one 404s in every real org): explicit
      # flags win, else the Snowflake env (process env or the neutral cred file)
      # may name a landing database/schema. Absent both, auto-land steps aside and
      # the manual exit-17 gate owns the decision.
      land_db  = opts[:db]     || [ENV['SNOWFLAKE_DATABASE'], sf_env['SNOWFLAKE_DATABASE']].find { |v| !v.to_s.empty? }
      land_sch = opts[:schema] || [ENV['SNOWFLAKE_SCHEMA'],   sf_env['SNOWFLAKE_SCHEMA']].find { |v| !v.to_s.empty? }
      # v5.3: the extract re-download lane can still be REPLACING the .twbx
      # when this gate runs (round 5: auto-land saw the thin pre-refetch file,
      # found "no .hyper payloads", and fell to exit 17 while the payload
      # arrived seconds later). A .twbx is a ZIP — the .hyper member names are
      # visible as plain bytes; wait briefly for them before invoking.
      # Wait ONLY when auto-land could actually proceed (v5.3.1 review-caught:
      # the loop stalled 30s on runs that were headed to the manual gate
      # anyway), and stop as soon as the discovery lane has exited — no
      # further .twbx replacement is possible after that.
      if landing_manifest.nil? && !opts[:no_auto_land] && !opts[:skip_extract_landing] &&
         opts[:conn] && sf_ok && land_db && land_sch && File.exist?(twbx_payload)
        6.times do
          break if (File.binread(twbx_payload).include?('.hyper') rescue false)
          break if (defined?(lane_done) && (lane_done.call rescue true)) # lane exited — file is final
          line 'auto-land: .twbx has no .hyper payload yet — waiting 5s for the extract re-download lane'
          sleep 5
        end
      end
      if landing_manifest.nil? && !opts[:no_auto_land] && !opts[:skip_extract_landing] &&
         File.exist?(twbx_payload) && opts[:conn] && sf_ok && !(land_db && land_sch)
        line 'auto-land: SKIPPED — landing target unknown, and there is NO default db/schema. ' \
             'Pass --db/--schema (or set SNOWFLAKE_DATABASE/SNOWFLAKE_SCHEMA in the env / ' \
             '~/.sigma-migration/env); the manual landing gate (exit 17) follows.'
      end
      if landing_manifest.nil? && !opts[:no_auto_land] && !opts[:skip_extract_landing] &&
         File.exist?(twbx_payload) && opts[:conn] && sf_ok && land_db && land_sch
        # Prefix carries a LUID fragment so two workbooks whose names share the
        # slug can never clobber each other's landed tables (write_pandas
        # overwrite=true; review-caught) — and stays stable across re-runs.
        slug = (opts[:name] || File.basename(WORK)).to_s.upcase.gsub(/[^A-Z0-9]+/, '_')
                                                    .sub(/\A_+|_+\z/, '')[0, 17]
        prefix = wb_luid ? "#{slug}_#{wb_luid.to_s.delete('-')[0, 6].upcase}" : slug
        line "embedded-extract sources (#{conn_classes.join(', ')}) — AUTO-LANDING the frozen extract " \
             "(prefix #{prefix}; --no-auto-land to keep the manual gate)"
        _o, lst = run!([*PyResolve.argv, PyResolve.winpath(File.join(HERE, 'land-extracts.py')),
                        '--twbx', PyResolve.winpath(twbx_payload),
                        '--db', land_db, '--schema', land_sch,
                        '--prefix', prefix, '--sigma-connection-id', opts[:conn],
                        '--manifest-out', PyResolve.winpath(File.join(WORK, 'landing-manifest.json'))],
                       allow_fail: true)
        mani_p = File.join(WORK, 'landing-manifest.json')
        # Parse the manifest INDEPENDENTLY of the exit status — a nonzero exit
        # AFTER the tables landed (e.g. the catalog /sync step failed) leaves a
        # POPULATED manifest that must survive (review-caught: the delete-if-
        # empty guard, keyed off a short-circuited [], destroyed it).
        mani_body = File.exist?(mani_p) ? (JSON.parse(File.read(mani_p)) rescue nil) : nil
        if lst.success? && mani_body.is_a?(Array) && mani_body.any?
          landing_manifest = mani_p
          Offramp.log(WORK, kind: 'auto-land', detail: "landed #{mani_body.size} table(s), prefix #{prefix}") if defined?(Offramp)
        elsif mani_body.is_a?(Array) && mani_body.any?
          line "WARN: auto-landing exited nonzero AFTER landing #{mani_body.size} table(s) (manifest kept) — " \
               'verify the landing log, then re-run (the manifest satisfies the gate on re-entry)'
        else
          # An EMPTY manifest (twbx without .hyper payloads) exits 0 — it must
          # NOT pass the gate as "landed" (review-caught false pass).
          File.delete(mani_p) if mani_body.is_a?(Array) && mani_body.empty?
          line 'WARN: auto-landing landed nothing (failure or payload-less .twbx) — manual landing gate (exit 17)'
        end
      elsif landing_manifest.nil? && !opts[:no_auto_land] && !opts[:skip_extract_landing] &&
            File.exist?(twbx_payload) && opts[:conn] && !sf_ok
        line 'NOTE: auto-landing available but SNOWFLAKE_ACCOUNT/SNOWFLAKE_USER are not in env or ' \
             '~/.sigma-migration/env — add them once to skip this manual gate on future runs.'
      end
      if landing_manifest
        line "embedded-extract sources (#{conn_classes.join(', ')}) — landing manifest found " \
             "(#{File.basename(landing_manifest)}); parity mode is EXACT (frozen extract landed byte-identical)"
      elsif opts[:skip_extract_landing]
        line "WARN: embedded-extract sources with NO landing manifest — proceeding on --skip-extract-landing " \
             "(#{opts[:skip_extract_landing]}); the DM's table paths are on you (--db/--schema)"
        # PR-14: every honored --skip-* leaves a record on the off-ramp trail.
        Offramp.log(WORK, kind: 'skip-flag-waived', reason: opts[:skip_extract_landing],
                    detail: '--skip-extract-landing')
      else
        puts <<~MSG

          ==================== EXTRACT LANDING REQUIRED (exit 17) ====================
          Every datasource in this workbook is an EMBEDDED file extract
          (#{conn_classes.join(', ')}) — there is no live warehouse for Sigma to query.
          Land the frozen extract data first:

            python3 scripts/land-extracts.py --twbx <workbook-with-extract.twbx> \\
              --db <DB> --schema <SCHEMA> --prefix <WB_PREFIX> \\
              --sigma-connection-id <connection-id> \\
              --manifest-out #{File.join(WORK, 'landing-manifest.json')}

          (Download the .twbx WITH extract payloads first:
             GET .../workbooks/<luid>/content?includeExtract=true
           Full guide incl. type rules + the /sync catalog step: refs/extract-landing.md.
           The landed data is byte-identical to what Tableau rendered, so Phase 6
           parity runs in EXACT mode — do NOT use extract-drift tolerance.)

          Already landed under different names? Put the manifest in #{WORK} (or point
          --db/--schema at the tables) and re-run with --skip-extract-landing "<reason>".
          ============================================================================
        MSG
        exit 17
      end
    end
  end

  conv_twb = twb
  # v5.3: UNION-OF-ONE collapse. Tableau serializes a single-table datasource
  # that was once a wildcard union as <relation type='union' all='true'> with
  # ONE inner table relation — the converter models unions as unsupported and
  # emits an EMPTY data model (round-5 root cause: a course-analysis field workbook forced all
  # three models onto the manual path). A union of one is semantically its
  # inner table; collapse it on a COPY (inner relation inherits the union's
  # name so downstream column refs keep resolving).
  if have_twb
    begin
      require 'rexml/document'
      raw = File.read(conv_twb, encoding: 'UTF-8')
      if raw.include?("type='union'") || raw.include?('type="union"')
        doc = REXML::Document.new(raw)
        collapsed = 0
        REXML::XPath.each(doc, "//relation[@type='union']").to_a.each do |u|
          rels = u.get_elements('relation')
          next unless rels.size == 1 && rels.first.attributes['type'] == 'table'
          inner = rels.first
          inner.remove
          inner.attributes['name'] = u.attributes['name'] if u.attributes['name']
          u.parent.replace_child(u, inner)
          collapsed += 1
        end
        if collapsed.positive?
          uc_twb = File.join(WORK, 'workbook-unioncollapsed.twb')
          File.open(uc_twb, 'w:UTF-8') { |f| doc.write(f) }
          conv_twb = uc_twb
          line "union-of-one collapse: #{collapsed} single-table union relation(s) collapsed to their " \
               'inner table (converter models unions as unsupported → empty DM; round-5 fix)'
        end
      end
    rescue StandardError => e
      line "WARN: union-of-one collapse skipped (#{e.class}: #{e.message.to_s[0, 80]}) — converter sees the raw twb"
    end
  end
  if have_twb && HydrateCustomSql.twb_has_sqlproxy?(twb)
    line 'published-datasource (sqlproxy) connection detected — chasing the published DS to hydrate before conversion'
    pds_json = File.join(WORK, 'pds.json')
    hcsql = File.join(WORK, 'hydrate-custom-sql.json')
    if wb_luid || true # resolution + GraphQL both need a Tableau token; get-*-token guards if absent
      # PRIMARY — REST content chase (covers table + Custom SQL PDSes).
      tableau_run!(['ruby', File.join(HERE, 'resolve-published-ds.rb'), '--twb', twb, '--out', pds_json],
                   allow_fail: true)
      # FALLBACK — GraphQL Custom SQL blocks (only helps the text case).
      if wb_luid
        tableau_run!(['ruby', File.join(HERE, 'extract-custom-sql.rb'), '--workbook-luid', wb_luid, '--twb', twb, '--out', hcsql],
                     allow_fail: true)
      end
    end
    hyd_twb = File.join(WORK, 'workbook-hydrated.twb')
    # hydrate from conv_twb (not twb) so a union-of-one collapse survives hydration
    hyd_args = ['ruby', File.join(HERE, 'hydrate-custom-sql.rb'), '--twb', conv_twb, '--out', hyd_twb]
    # db/schema are a fallback only — each PDS descriptor carries its own real
    # pair (resolve-published-ds.rb), which hydrate_pds! prefers. NO default:
    # when nothing resolves, splice without and let the converter/gates decide.
    if (hyd_dbsch = wh_try.call(conv_twb))
      hyd_args += ['--db', hyd_dbsch[0], '--schema', hyd_dbsch[1]]
    end
    hyd_args += ['--pds', pds_json] if File.exist?(pds_json)
    hyd_args += ['--custom-sql', hcsql] if File.exist?(hcsql)
    # #454: derive the target warehouse class from the resolved PDS metadata and
    # pass it as the splice default. Each descriptor also carries its own class
    # (hydrate_pds! prefers that per-PDS); this default covers the GraphQL-fallback
    # splice and any classless descriptor, so a case-preserving warehouse
    # (Databricks) is never normalized with Snowflake's upper-folding rules.
    if File.exist?(pds_json)
      pds_wcls = begin
        ds_list = JSON.parse(File.read(pds_json, encoding: 'UTF-8'))
        ds_list.is_a?(Array) ? ds_list.map { |d| d['warehouseClass'] }.compact.map(&:to_s).reject(&:empty?).first : nil
      rescue StandardError
        nil
      end
      hyd_args += ['--warehouse-class', pds_wcls] if pds_wcls
    end
    if hyd_args.include?('--pds') || hyd_args.include?('--custom-sql')
      _out, hst = run!(hyd_args, allow_fail: true)
      conv_twb = hyd_twb if hst.success? && File.exist?(hyd_twb) && File.read(hyd_twb, encoding: 'UTF-8') != File.read(twb, encoding: 'UTF-8')
    end
    # Phantom guard: if any sqlproxy datasource is STILL unresolved, do NOT let the
    # converter fabricate a bogus warehouse table (<db>.<schema>.SQLPROXY) that POSTs and
    # then fails at the API. Stop with an actionable message instead.
    if HydrateCustomSql.twb_has_sqlproxy?(conv_twb)
      (reap_lane!(lane_done) rescue nil) # bounded reap before aborting
      print_lane_log.call rescue nil
      abort <<~MSG
        FATAL: workbook is bound to a PUBLISHED data source (sqlproxy) that could not be resolved.
        The real table / Custom SQL lives in the published DS on Tableau Server, and it could not be
        fetched (not found by contentUrl, no permission, or no Tableau token). Converting as-is would
        fabricate a nonexistent "SQLPROXY" table and fail at DM POST. To proceed, either:
          • ensure the PAT can read the published DS (GET /datasources/{id}/content), then re-run; or
          • provide the Custom SQL manually (paste it into a <relation type='text'> in the .twb); or
          • materialize the published DS as a warehouse view and point a table datasource at it.
      MSG
    elsif conv_twb != twb
      line '  hydrated → workbook-hydrated.twb (converter will build from the published DS\'s real relation)'
    end
  end

  # Resolve-or-STOP before converting: the converter builds a warehouse table
  # path for every element; a wrong database 404s them all at DM POST. The
  # hydrated conv_twb is the richest source — PDS splices stamped real
  # dbname/schema onto it above.
  wh_db, wh_schema, = wh_require.call(conv_twb)
  conv = MechanicalSpecs.run_converter(
    twb_path: conv_twb, conn: opts[:conn], db: wh_db,
    schema: wh_schema, mcp_build: mcp_build, workdir: WORK,
    table_mapping: opts[:table_mapping], fact_table: opts[:fact_table])
  if opts[:table_mapping]&.any?
    line "table mapping: #{opts[:table_mapping].map { |k, v| "#{k}→#{v}" }.join(', ')}"
  end
  st = conv['stats'] || {}
  line "mechanical converter: #{st['elements']} element(s), #{st['columns']} column(s), " \
       "#{st['metrics']} metric(s), #{st['relationships']} relationship(s); #{(conv['warnings'] || []).size} warning(s)"
  # Surface the object-model fact election verbatim — the single line an
  # operator must sanity-check on a relationship-model workbook (wrong fact =
  # every LOD/Top-N/window helper FROM the wrong table + a wrong master).
  (conv['warnings'] || []).grep(/fact election/i).each { |w| line "  #{w[0, 220]}" }

  # CONVERTER EMPTY-MODEL GUARD (never silently blank): if the converter parsed
  # the datasource but produced ZERO data-model elements/columns, the mechanical
  # path has nothing to build — proceeding ships an element-less workbook (the
  # object-model "empty DM" dead-end). Hard-stop with the converter's own warnings
  # and a clear pointer, before any Sigma object is created. (The encapsulated
  # object model is now supported; this catches the next unsupported shape loudly
  # instead of as a blank dashboard.)
  if st['elements'].to_i.zero? || st['columns'].to_i.zero?
    puts
    puts '==================== CONVERTER STOP (empty data model) ===================='
    puts "The Tableau→Sigma converter produced #{st['elements'].to_i} element(s) / " \
         "#{st['columns'].to_i} column(s) from this workbook — nothing to build a data model from."
    puts 'Likely an unsupported datasource shape (e.g. a relationship/object model variant'
    puts "the converter can't yet model). Converter warnings:"
    (conv['warnings'] || []).first(8).each { |w| puts "  - #{w.to_s[0, 160]}" }
    puts ''
    puts 'No Sigma objects were created. Capture the .twb datasource shape for the converter repo.'
    puts 'The MANUAL-SPEC route is authorized: author dm-spec.json/wb-spec.json against the landed'
    puts 'tables (see the sigma-workbooks skill) and re-enter with --reuse-dm/--dm-spec/--wb-spec.'
    # v5.3: stamp the manual-path token (the exit-1 no-backend stop already
    # does) — round 5 proved the printed route was unreachable without a
    # waiver flag, costing every empty-DM run an extra round-trip.
    authorize_manual_path!(via: 'converter-empty-model',
                           reason: "converter produced 0 elements/columns (unsupported datasource shape)",
                           exit_code: 15)
    mark('phase1-join')
    phase_summary
    exit 15
  end

  # ---- RLS gate (never silently drop) -------------------------------------
  # The converter detects row-level security (USERNAME/USERATTRIBUTE/ISMEMBEROF
  # calcs) and reports it in conv['security'] (architecture B: reported, not
  # injected). Persist it to security.json and surface a LOUD, un-missable
  # checkpoint — RLS is provisioned + applied by scripts/apply_sigma_rls.py, NOT
  # by this converter. Also surface the cross-element warnings (an RLS calc over
  # a joined-dim column that needs manual placement on the owning element), so
  # those can't hide inside the warnings count either.
  rls_rules = conv['security'] || []
  rls_xelem = (conv['warnings'] || []).grep(/row-level security but references a related-table/)
  $rls_pending = rls_rules.any? || rls_xelem.any?
  if $rls_pending
    sec_path = File.join(WORK, 'security.json')
    File.write(sec_path, JSON.pretty_generate(rls_rules))
    line ''
    line '🔐 ROW-LEVEL SECURITY DETECTED — NOT yet applied to the Sigma model'
    ent_rules, plain_rules = rls_rules.partition { |r| r['kind'] == 'rls-entitlement-table' }
    plain_rules.each do |r|
      nm = r.dig('rls', 'name') || r['source']
      attrs = (r.dig('rls', 'userAttributes') || []).join(', ')
      line "   • #{nm}#{attrs.empty? ? '' : "  (user attribute(s): #{attrs})"}"
    end
    # Table-based entitlement RLS (structural detection): until the checkpoint
    # decision the entitlement relationship is an UNCONSTRAINED live join — the
    # Tableau restriction is gone AND multi-entitlement users fan out row
    # counts. Port strategies (refs/security-rls.md §entitlement): A filtered
    # entitlement + inner-join gate, B Lookup boolean gate, C de-entitle to
    # user attributes/teams. NEVER auto-applied.
    ent_rules.each do |r|
      idcol = r.dig('entitlement', 'identityColumn')
      keys = (r.dig('entitlement', 'keys') || []).map { |k| "#{k['entitlementColumn']}↔#{k['relatedColumn']}" }.join(', ')
      line "   • ENTITLEMENT TABLE \"#{r['elementName']}\" (identity column [#{idcol}]; keys #{keys})"
      line '     ⚠ until decided, this relationship is an UNCONSTRAINED live join (restriction dropped + fan-out risk).'
      line '     Decide Port (strategy A or B) / Customize / loud Skip — refs/security-rls.md §Entitlement-table pattern.'
    end
    rls_xelem.each { |w| line "   • #{w[0, 150]}" }
    line "   wrote #{sec_path} (#{plain_rules.size} emit-ready rule(s); #{ent_rules.size} entitlement-table rule(s) " \
         "needing a Port/Customize/Skip decision; #{rls_xelem.size} cross-element rule(s) need manual placement)"
    line '   PROVISION + APPLY before this model is safe to share:'
    line "     python3 scripts/apply_sigma_rls.py --from-security #{sec_path} --dm-id <dataModelId>            # plan"
    line "     python3 scripts/apply_sigma_rls.py --from-security #{sec_path} --dm-id <dataModelId> --provision --apply"
    line '     (entitlement-table rules are PLANNED ONLY by --apply — they are authored per the chosen strategy, never auto-injected)'
    line ''
  end

  # Embedded-extract manifest remap (before any fixup / pick_fact): the converter
  # can only see the generic in-.twbx table name ("Extract") for every embedded
  # datasource, so multiple datasources collapse onto an identical source.path +
  # element name and unresolvable [EXTRACT/...] formula prefixes. Repoint each
  # element onto its landed Snowflake table (matched by column-caption overlap,
  # NOT name) and thread the manifest's orig→landed column map into the
  # phantom-filter (line ~1907) so long/sanitized indicator names fold to their
  # real warehouse column instead of dropping. No-op without a manifest.
  if defined?(landing_manifest) && landing_manifest
    rm = MechanicalSpecs.remap_from_manifest!(conv['model'], landing_manifest)
    if rm[:elements].to_i.positive?
      opts[:column_mapping] ||= {}
      rm[:colmap].each { |orig, landed| opts[:column_mapping][orig] ||= landed } # user --column-mapping wins
      line "extract manifest remap: repointed #{rm[:elements]} element(s) onto landed table(s) " \
           "#{rm[:tables].join(', ')}; threaded #{rm[:colmap].size} column rename(s) into the phantom-filter"
    end
    if rm[:sql_elements].to_i.positive?
      line "extract manifest remap: rewrote FROM + column identifiers on #{rm[:sql_elements]} custom-SQL " \
           'element(s) (single-table statements attributed by column overlap)'
    end
  end

  # Fact hint for a MULTI-embedded-extract workbook: the datasource the dashboard
  # worksheets actually use (column count alone picks the wrong one — an unused
  # secondary can project MORE columns than the plotted table). Computed from the
  # .twb worksheet dependencies + the landing manifest; threaded into pick_fact.
  prefer_fact_table = opts[:fact_table] && opts[:fact_table].to_s.split('.').last&.upcase
  line "fact hint: --fact-table override → prefer table #{prefer_fact_table}" if prefer_fact_table
  if prefer_fact_table.nil? && have_twb && defined?(landing_manifest) && landing_manifest
    prefer_fact_table = (MechanicalSpecs.dominant_fact_table(File.read(twb, encoding: 'UTF-8'), landing_manifest) rescue nil)
    line "fact hint: dashboard datasource → prefer table #{prefer_fact_table}" if prefer_fact_table
  end
  # Single-datasource multi-table (object-model / noodle) workbooks have no
  # landing manifest — derive the hint from the .twb's own <object-graph>
  # relationship degree instead (the converter's election tier 1), so
  # pick_fact's width heuristic can never elect a wide dim view unchallenged.
  if prefer_fact_table.nil? && have_twb
    prefer_fact_table = (MechanicalSpecs.object_model_fact_table(File.read(twb, encoding: 'UTF-8')) rescue nil)
    line "fact hint: object-model relationship degree → prefer table #{prefer_fact_table}" if prefer_fact_table
  end

  # Mechanical DM fixup NOW (so dropped calcs feed the checkpoint): resolve
  # raw-table-name prefixes + GUID sibling refs, and DROP calc columns that
  # still cannot resolve (unknown functions / unresolved refs).
  fx = MechanicalSpecs.fixup_dm_spec(conv['model'])
  line "DM fixup: rewrote #{fx[:fixed]} formula(s); dropped #{fx[:dropped].size} unresolvable calc col(s)" if fx[:fixed].positive? || fx[:dropped].any?
  dropped_calcs = fx[:dropped]
  grounding = TableauWarehouseColumnRefs.apply!(
    conv['model'],
    requester: ->(method, path, **kwargs) { Sigma.request(method, path, **kwargs) },
    lister: ->(path) { Sigma.list_entries(path) },
    drop_unresolved: true
  )
  modes = grounding[:connection_modes].map { |id, friendly| "#{id}=#{friendly ? 'friendly' : 'physical'}" }.join(', ')
  line "connection naming: #{modes}; grounded #{grounding[:rewritten]} formula(s), " \
       "re-keyed #{grounding[:rekeyed]} id(s), re-prefixed #{grounding[:reprefixed]} ref(s), " \
       "dropped #{grounding[:dropped].size} catalog-missing passthrough(s)"
  # v5.4: prune orphaned BROKEN leftovers (union-collapse class) AFTER remap +
  # fixup have had their chance to repair refs — strict double condition
  # (broken cross-refs AND unreferenced), loud per-element log.
  # v5.4.9 review fix: pass keep: (a provisional fact pick) so a single-table
  # model whose FACT carries one stale cross-ref can never be pruned to an
  # empty model — the docstring's "not the kept fact" invariant was dead code
  # because no caller passed keep:.
  begin
    keep_fact = (MechanicalSpecs.pick_fact(conv['model'], prefer_table: prefer_fact_table) rescue nil)
    pruned = MechanicalSpecs.prune_broken_orphans!(conv['model'], keep: keep_fact && keep_fact['name'])
    line "DM prune: removed #{pruned.size} orphaned broken element(s): #{pruned.join(', ')}" if pruned.any?
  rescue StandardError => e
    line "WARN: orphan prune failed (#{e.message}) — model left as converted"
  end

  # Pre-derive the master-map now (deterministic; uses the converter element
  # name — Phase 4 re-derives against the authoritative readback name). This lets
  # us surface any chart-PLOTTED metric that did not fully translate (GUID refs
  # the converter could not resolve) as an OPEN QUESTION rather than a silent
  # blank chart. Metrics that aren't plotted by any view are ignored.
  conv_fact = MechanicalSpecs.pick_fact(conv['model'], prefer_table: prefer_fact_table)
  # FIXED-LOD synthesis: the converter emits nothing for per-year `{FIXED
  # DATEPART('year',[Date]): SUM(m)}` "World"-total calcs, so a chart referencing
  # them dangles + blocks the POST. Synthesize the grouped Custom SQL helper +
  # `FIXED Year` relationship on the fact; derive_master surfaces the columns.
  world_lod_map = {}
  _disc = nil
  _rollup_flag = nil
  _real_map = nil
  if have_twb && conv_fact
    # The fact table's REAL columns (landing manifest) — the LOD's base metric is
    # usually never plotted, so it's absent from the projected DM element and a
    # projection-only check drops the LOD (the chart ref then dangles).
    _fact_tbl = (conv_fact.dig('source', 'path') || []).last.to_s.upcase
    # landing_manifest is a PATH (Dir[] hit above) — parse it here.
    _real_map = if defined?(landing_manifest) && landing_manifest && !_fact_tbl.empty?
                  _man = (JSON.parse(File.read(landing_manifest, encoding: 'UTF-8')) rescue nil)
                  ent = Array(_man).find { |e| e.is_a?(Hash) && e['sf_table'].to_s.upcase.end_with?(".#{_fact_tbl}") }
                  ent && ent['columns']
                end
    # The real-entity discriminator (png-read point_in_time) also scopes the World
    # per-year SUM to real entities, so it doesn't double-count rollup rows. A
    # `rollup_flag` block (flag-valued discriminator — rollups marked by VALUE, not
    # NULL) takes over the scoping column; its equality predicate replaces the
    # synthesizers' IS NOT NULL below (apply_rollup_flag_where!).
    _pit_png = ((JSON.parse(File.read(DashboardRead.path(WORK)))['point_in_time'] rescue nil) || {})
    _rf_errs = RecipeMultimetric.validate_rollup_flag(_pit_png)
    _rf_errs.each { |e| line "WARN: png-read #{e} — rollup_flag IGNORED" }
    _rollup_flag = _pit_png['rollup_flag'] if _rf_errs.empty? && RecipeMultimetric.rollup_flag_active?(_pit_png)
    _scope_raw = (_rollup_flag && _rollup_flag['column']) || _pit_png['entity_discriminator']
    # G9 run-2 root cause: the png-read caption ("Entity Group") vs the landed
    # physical column (ENTITYGROUP) failed the synthesizers' exact/underscore
    # check and the rollup-exclusion WHERE was SILENTLY omitted (world totals
    # then double-count rollup rows). Resolve the caption variant HERE, loudly.
    _fact_caps = (conv_fact['columns'] || []).map { |c| RecipeMultimetric.col_disp(c) }.compact
    _res = RecipeMultimetric.resolve_scope_column(_scope_raw, real_map: _real_map, fact_captions: _fact_caps)
    if _scope_raw.to_s.strip.empty?
      _disc = nil
    elsif _res['resolved']
      _disc = _res['name']
      line "rollup-scope column '#{_scope_raw}' -> '#{_disc}' (caption-variant resolution vs landed columns)" if _disc != _scope_raw
    else
      _disc = nil
      puts
      puts '========== ROLLUP-EXCLUSION SCOPE COLUMN UNRESOLVED (world/YoY helpers) =========='
      puts "png-read point_in_time names #{_rollup_flag ? 'rollup_flag.column' : 'entity_discriminator'} = '#{_scope_raw}',"
      puts "but it matches NO landed column on #{_fact_tbl.empty? ? 'the fact table' : _fact_tbl} (case/spacing/punctuation variants checked)."
      puts 'Without it the world-by-year / YoY helper SQL would SUM ROLLUP ROWS TOO (double-counted'
      puts 'totals — the exact run-2 failure). The rollup-exclusion WHERE is being OMITTED — this is'
      puts 'only correct if the table truly has no rollup rows. Candidate columns:'
      _res['candidates'].first(30).each { |c| puts "  - #{c}" }
      puts "Fix png-read.json point_in_time (or the landing manifest captions) and re-run; verify the"
      puts 'world totals against the source render in Phase 6 if you proceed.'
      puts '==================================================================================='
    end
    world_lod_map = (MechanicalSpecs.synthesize_fixed_lods!(conv['model'], conv_fact, File.read(twb, encoding: 'UTF-8'), (opts[:column_mapping] || {}), discriminator: _disc, real_map: _real_map) rescue {})
    line "FIXED-LOD synthesis: materialized #{world_lod_map.size} per-year world-total column(s) via a grouped Custom SQL helper#{_disc ? " (real-entity scoped by #{_disc})" : ''}" if world_lod_map.any?
  end
  # YoY-% helper for the multi-metric recipe (the signed % the source prints
  # beside each YoY bar — source-anchor values, so approximating them away
  # fails the anchors gate). Inputs are all deterministic: the bar tiles' dim
  # and the top tables' entity come from the parsed shelf signals, metrics +
  # snapshot years from png-read point_in_time.
  yoy_map = {}
  if have_twb && conv_fact
    begin
      _pngr = (JSON.parse(File.read(DashboardRead.path(WORK))) rescue nil) || {}
      _pit2 = _pngr['point_in_time'] || {}
      _hl = Array(_pngr['filter_shelf']).flat_map { |f| Array(f['highlight_tiles']) }.map(&:to_s)
      _zones = ((JSON.parse(File.read(File.join(WORK, 'dashboard-layout.json'), encoding: 'UTF-8')) rescue nil) || [])
               .flat_map { |dd| dd['zones'] || [] }
      _shelf_dim = lambda do |cap|
        z = _zones.find { |zz| zz['caption'] == cap }
        f = z && z.dig('rows_shelf', 'fields')
        f && f.length == 1 && f[0]['role'] == 'dim' ? f[0]['guid'] : nil
      end
      _bar_dims = _hl.map { |t| _shelf_dim.call(t) }.compact.uniq
      _entities = Array(_pngr['tiles']).select { |t| t['kind'].to_s == 'table' }
                                       .map { |t| _shelf_dim.call(t['title'].to_s) }.compact.uniq
      if _bar_dims.length == 1 && _entities.length == 1 && _pit2['latest_year'] && _hl.any?
        require_relative 'lib/recipe_multimetric'
        _metrics = {}
        Array(_pngr['tiles']).each do |t|
          # {"manual_residue": ...} measures are custom-SQL residues, not
          # rebuildable magnitudes — no YoY helper for them.
          next unless _hl.include?(t['title'].to_s) && t['measure'].is_a?(String)
          y = RecipeMultimetric.latest_year_for(_pit2, t['measure'], context: t['title'])
          _metrics[t['measure']] = y if y
        end
        yoy_map = MechanicalSpecs.synthesize_yoy_by_dim!(
          conv['model'], conv_fact,
          dim: _bar_dims[0], entity: _entities[0], metrics: _metrics,
          year: _pit2['year_column'] || 'Year',
          discriminator: _disc, real_map: _real_map, colmap: (opts[:column_mapping] || {})
        )
        line "YoY synthesis: #{yoy_map.size} pairwise-complete YoY column(s) by #{_bar_dims[0]} (helper SQL + FIXED YoY relationship)" if yoy_map.any?
      end
    rescue StandardError => e
      line "WARN: YoY synthesis skipped (#{e.class}: #{e.message})"
    end
  end
  # Flag-valued discriminator (png-read point_in_time.rollup_flag): the helper
  # SQL just synthesized above scopes rollups with `"<flag>" IS NOT NULL`, but a
  # FLAG column is non-null on EVERY row — rewrite the WHERE into the declared
  # equality predicate (entity_values IN / rollup_values NOT IN + keep-NULL).
  if _rollup_flag && _disc
    _rw = RecipeMultimetric.apply_rollup_flag_where!(conv['model'], _rollup_flag)
    line "rollup_flag: rewrote the rollup-exclusion WHERE on #{_rw} helper SQL element(s) " \
         "(#{Array(_rollup_flag['entity_values']).any? ? "entity_values #{Array(_rollup_flag['entity_values']).join(',')}" : "rollup_values #{Array(_rollup_flag['rollup_values']).join(',')}"})" if _rw.positive?
  end
  conv_base = conv_fact ? MechanicalSpecs.base_of(conv['model'], conv_fact) : nil
  pre = conv_fact ? MechanicalSpecs.derive_master(conv_fact, (conv_fact['name'] || 'Order Fact'), conv_base, nil, conv['model']) : { 'untranslated_metrics' => [] }
  pre_untranslated = pre['untranslated_metrics'] || []
  # plotted_untranslated (the CSV-header match) is computed after the lane join
  # — it needs the view CSVs.
end
mark('phase1-foreground')

# ---------------------------------------------------------------------------
# Phase 1.6 — DM-reuse scan (find-or-pick-dm). Default = BUILD NEW; candidates
# are printed so a human can opt in with --reuse-dm. Non-destructive.
# Pure Sigma-side — runs CONCURRENTLY with the background discovery lane.
# ---------------------------------------------------------------------------
hdr('1.6', 'DM-reuse scan (concurrent with discovery)')
reuse_dm_id = nil
dm_match = {}
src_model = mechanical ? conv['model'] : (have_specs ? Specs.dm_spec : nil)
if opts[:skip_reuse]
  line 'skipped (--skip-reuse-scan)'
elsif src_model.nil?
  line 'no spec source to derive a signature from — building new'
else
  sig_els = (src_model['pages'] || []).flat_map { |p| p['elements'] || [] }
  sig_tables = sig_els.map do |e|
    s = e['source'] || {}
    next 'CUSTOM_SQL' if s['kind'] == 'sql'
    pth = s['path']
    pth.is_a?(Array) ? pth.join('.').upcase : nil
  end.compact.uniq
  sig_cols = sig_els.flat_map { |e| (e['columns'] || []).map { |c| c['name'] } }.compact.uniq
  sig_meas = sig_els.flat_map do |e|
    (e['metrics'] || []).map { |m| { 'col' => m['name'], 'derivation' => m['aggregation'] || m['derivation'] } }
  end
  sig_path = File.join(WORK, 'workbook-signature.json')
  File.write(sig_path, JSON.pretty_generate(
    'tableau_workbook' => wb_name, 'warehouse_tables' => sig_tables,
    'referenced_columns' => sig_cols, 'measures' => sig_meas))
  match_path = File.join(WORK, 'dm-match.json')
  sigma_run!(['ruby', File.join(HERE, 'find-or-pick-dm.rb'),
              '--workbook-signature', sig_path, '--out', match_path,
              '--auto-pick', '--auto-pick-threshold', '0.5'],
             allow_fail: true) # exit 1 = no candidate ≥ min-score (normal: build new)
  dm_match = (JSON.parse(File.read(match_path)) rescue {})
  # #691: find-or-pick-dm.rb's own ambiguous_wide_tie guard only refuses a WIDE
  # (>=3-way) tie; a narrow tie at an identical score still auto-picks (its
  # rationale even says "collapsing a 0.9-score tie — duplicate-DM sprawl").
  # Don't silently collapse that here either — prefer a source-name match,
  # else refuse the auto-pick and fall back to a fresh build.
  _tie = MechanicalSpecs.reuse_tie_guard(dm_match, wb_name)
  line "DM-REUSE tie guard: #{_tie['reason']}" if _tie['blocked']
  # Reuse-first: if the picker auto-picked a safe candidate (covers ALL source
  # tables), reuse it automatically unless the user passed an explicit --reuse-dm.
  if !opts[:reuse_dm] && _tie['auto_picked'] && dm_match['recommended_dm_id']
    opts[:reuse_dm] = :recommended
    line "DM-REUSE (auto): #{dm_match['rationale']}"
  end
  cands = (dm_match['candidates'] || []).first(3)
  if cands.any?
    line 'top candidate(s):' if opts[:reuse_dm]
    line 'top candidate(s) — default is BUILD NEW; pass --reuse-dm to opt in:' unless opts[:reuse_dm]
    cands.each { |c| line "  score #{format('%.2f', c['score'] || 0)}  #{c['dm_id']}  '#{c['dm_name']}'" }
  else
    line 'no existing DM covers this workbook — building new'
  end
end
if opts[:reuse_dm]
  reuse_dm_id = opts[:reuse_dm] == :recommended ? dm_match['recommended_dm_id'] : opts[:reuse_dm]
  abort 'FATAL: --reuse-dm: the picker found no candidate ≥ min-score; pass an explicit ' \
        '--reuse-dm <dataModelId> or drop the flag to build new' unless reuse_dm_id
  line "REUSING data model #{reuse_dm_id} — Phase 3 build+POST will be skipped."
  line "  #{dm_match['warning']}" if dm_match['warning']
  line '  NOTE: master-column formulas are derived against the reused DM\'s readback labels;'
  line '  if its shape differs (separate dim elements), the workbook gate will stop with the'
  line '  agent-path handoff (exit 4) — run SKILL.md Phase 1.5b (inspect-dm-shape.rb) then.'
end
mark('phase1.6-dm-scan')

# ---------------------------------------------------------------------------
# Phase 2 — Discover warehouse column names (per table) for the DM build.
# Pure Sigma-side — runs CONCURRENTLY with the background discovery lane.
# ---------------------------------------------------------------------------
hdr(2, 'Discover warehouse columns (concurrent with discovery)')
# db/schema come from the shared warehouse resolver (flags → landing manifest →
# workbook <connection> attributes → STOP; defined above `mechanical`) — NEVER a
# default (G7: a generic pair here returned ZERO real columns for a landed
# schema and silently defanged fixup_dm_spec's remap, phantom-drop, and rollup
# discriminator; the E2E showed the same pair 404-ing every table at DM POST).
# Table set first: with no warehouse tables there is nothing to probe, so the
# resolver's hard STOP is reserved for runs that actually need the catalog.
wh_tables =
  if mechanical
    (conv['model']['pages'] || []).flat_map { |p| p['elements'] || [] }
      .select { |e| e.dig('source', 'kind') == 'warehouse-table' }
      .map { |e| e.dig('source', 'path')&.last }.compact.uniq
  elsif have_specs
    Specs.dm_spec['pages'].flat_map { |p| p['elements'] }
         .map { |e| e.dig('source', 'path')&.last }.compact.uniq
  else
    md = (JSON.parse(File.read(File.join(WORK, 'ds-metadata.json'))) rescue {})
    fields = md['data'] || []
    fields.flat_map { |f| (f['name'] || '').scan(/\b([A-Z][A-Z0-9_]*(?:_DIM|_FACT))\b/) }
          .flatten.uniq
  end
wh_tables = [] if wh_tables.nil?
if wh_tables.empty?
  line 'no warehouse tables resolved from metadata; relying on spec generator'
  db, schema = (wh_try.call((defined?(conv_twb) && conv_twb) || twb) || [nil, nil])[0, 2]
else
  db, schema, db_src = wh_require.call((defined?(conv_twb) && conv_twb) || twb)
  line "warehouse column discovery target: #{db}.#{schema} (#{db_src})"
  wh_tables.each do |t|
    cols_path = File.join(WORK, "cols-#{t}.json")
    # Re-entry reuse: a prior run of THIS workdir already probed the catalog for
    # this table on this connection — the schema doesn't change between loop
    # re-entries (minutes apart). Reuse only a NON-EMPTY catalog answer (an
    # empty/failed probe is always re-tried). Delete cols-<T>.json to re-probe.
    prior = (JSON.parse(File.read(cols_path)) rescue nil) if File.exist?(cols_path)
    if prior.is_a?(Hash) && prior['columns'].is_a?(Array) && prior['columns'].any? &&
       prior['connection_id'].to_s == opts[:conn].to_s &&
       Array(prior['path']).join('.').to_s.casecmp?("#{db}.#{schema}.#{t}")
      line "#{db}.#{schema}.#{t}: #{prior['columns'].size} columns (REUSED cols-#{t}.json — delete to re-probe)"
      next
    end
    _, st = sigma_run!(['ruby', File.join(HERE, 'discover-columns.rb'),
                        '--connection-id', opts[:conn],
                        '--table-path', "#{db}.#{schema}.#{t}",
                        '--out', cols_path], allow_fail: true)
    cj = (JSON.parse(File.read(cols_path)) rescue nil)
    n = cj && cj['columns'] ? cj['columns'].size : '?'
    line "#{db}.#{schema}.#{t}: #{n} columns#{st.success? ? '' : ' (not in catalog — Custom SQL fallback may be needed)'}"
  end
end
mark('phase2-columns')

# ---------------------------------------------------------------------------
# Phase 1 (join) — wait for the background Tableau lane, then run everything
# that consumes its output: calc fields, custom-SQL scan, the gap-scan HARD
# GATE, the empty-view-CSV preflight, and the plotted-untranslated check.
# Every designed stop below is byte-identical to the serial flow.
# ---------------------------------------------------------------------------
puts
puts '── Phase 1 (join) · Tableau discovery lane ──'
# Bound the join so a wedged discovery lane (e.g. a Tableau REST call that never
# returns) can't leave the whole migration "stuck" indefinitely. Default 600s —
# a healthy discovery finishes in ~2 min, and the prior 1800s default let a
# transient render wedge silently burn 30 minutes (Twin-B e2e 2026-07-19).
# Large sites override with TABLEAU_LANE_TIMEOUT (seconds).
_lane_timeout = (ENV['TABLEAU_LANE_TIMEOUT'] || '600').to_i
_lane_t0 = Time.now
_lane_beat = _lane_t0
until lane_done.call
  if Time.now - _lane_t0 > _lane_timeout
    print_lane_log.call
    `pkill -TERM -P #{lane[:pid]} 2>/dev/null` rescue nil # W2.21 fence: children (the wedged
    (Process.kill('TERM', lane[:pid]) rescue nil)         # ruby fetch) first, then the lane shell,
    (reap_lane!(lane_done, 5) rescue nil)                 # bounded reap — no orphan trickler survives the abort
    abort "FATAL: Tableau discovery lane did not finish within #{_lane_timeout}s — likely a " \
          "wedged Tableau REST call (see lane log above). Re-run, raise TABLEAU_LANE_TIMEOUT, " \
          "or pass the .twb directly with --twb to skip live discovery."
  end
  if Time.now - _lane_beat > 30 # heartbeat: a long fetch must never LOOK wedged
    _lane_beat = Time.now
    puts "   … discovery lane still running (#{(Time.now - _lane_t0).round}s elapsed, " \
         "timeout #{_lane_timeout}s; tail #{File.basename(disc_log)} for per-task progress)"
  end
  sleep 0.1
end
mark('join-wait')
print_lane_log.call
unless lane[:status].success?
  abort "FATAL: Tableau discovery failed (exit #{lane[:status].exitstatus}) — see lane log above"
end
PHASE_T['phase1-lane(bg)'] = (lane[:ended] - lane[:started])
tjs = (JSON.parse(File.read(File.join(WORK, 'timings.json'))) rescue nil)
line "discovery lane: #{(lane[:ended] - lane[:started]).round(1)}s wall" \
     "#{tjs ? " (tableau-discover #{tjs['total_seconds']}s, pool=#{tjs['pool']}; per-task breakdown in timings.json)" : ''}"

calc_path = File.join(WORK, 'calc-fields.json')
calcs = []
if wb_luid
  # sha-stamped reuse (stronger than extract-calc-fields' own 1h TTL): the
  # extraction is a pure function of the .twb + workbook (+ the dashboard
  # scope — E9.6: a scoped and an unscoped run must never cross-serve each
  # other's cache), so a re-entry with an unchanged .twb skips it entirely —
  # hours later, not just within the TTL.
  calc_key = have_twb ? PhaseCache.key('calc-fields', twb_sha, wb_luid,
                                       PhaseCache.file_sha(File.join(HERE, 'extract-calc-fields.rb')),
                                       DASH_SCOPE.join(' ')) : nil
  if calc_key && PhaseCache.fresh?(WORK, 'calc-fields', key: calc_key, outputs: [calc_path])
    line 'calc-fields REUSED (.twb sha + scope unchanged) — extract-calc-fields.rb --refresh to force'
  else
    cf = ['ruby', File.join(HERE, 'extract-calc-fields.rb'),
          '--workbook-luid', wb_luid, '--out', calc_path]
    cf += ['--twb', twb] if have_twb
    # E9.6 — the stated dashboard scope constrains the calc working set (and so
    # the calc-derived open questions). extract-calc-fields.rb owns the
    # resolution (--dashboard is its documented working-set scoping).
    cf += (opts[:dashboards] || []).flat_map { |d| ['--dashboard', d] }
    _, st = tableau_run!(cf, allow_fail: true)
  end
  if File.exist?(calc_path)
    cfj = JSON.parse(File.read(calc_path)) rescue {}
    calcs = cfj['calcs'] || []
    n_csql = calcs.count { |c| c['requires_custom_sql'] }
    line "#{calcs.size} calc field(s); #{n_csql} require Custom SQL (window/LOD)"
    # Stamp ONLY a non-empty extraction: an empty result with calc nodes in the
    # .twb is the BROKEN-extraction case (exit 13 below) and must never be
    # blessed for reuse, or every re-entry would replay the failure.
    PhaseCache.stamp!(WORK, 'calc-fields', key: calc_key, outputs: [calc_path]) if calc_key && calcs.any?
  end
end

# EMPTY-PAGE GUARD (DDMX regression): extract-calc-fields runs allow_fail, so a
# hang/error/auth failure silently leaves calcs=[] and the build then ships
# pages whose elements have no backing calculation — the "blank workbook, must
# re-prompt to finish" symptom. If the .twb plainly defines Tableau calc fields
# but extraction returned none, that's a BROKEN extraction, not a calc-free
# workbook: hard-stop here, before any Sigma object is created. (Parser-free raw
# count so the guard doesn't depend on the same path that just failed.)
if have_twb && calcs.empty?
  raw_calc_nodes = (File.read(twb, encoding: 'UTF-8').scan(/<calculation\s+class=['"]tableau['"]/i).size rescue 0)
  if raw_calc_nodes.positive?
    puts
    puts '==================== CALC-EXTRACTION STOP (empty result) ===================='
    puts "The .twb defines ~#{raw_calc_nodes} Tableau calculation node(s) but"
    puts 'extract-calc-fields.rb returned 0 calcs — extraction failed (hang/error/auth),'
    puts 'NOT a calc-free workbook. Proceeding would post a workbook whose elements'
    puts 'have no backing calculations (blank pages).'
    puts ''
    puts 'Re-run calc discovery and confirm it completes (now Nokogiri-fast):'
    puts "  ruby #{File.join(HERE, 'extract-calc-fields.rb')} " \
         "--workbook-luid #{wb_luid || '<luid>'} --twb #{twb} --out #{calc_path} --refresh"
    puts '======================================================='
    puts 'No Sigma objects were created.'
    mark('phase1-join')
    phase_summary
    exit 13
  end
end

custom_sql = []
csql_path = File.join(WORK, 'custom-sql.json')
if wb_luid && have_twb
  csql_key = PhaseCache.key('custom-sql', twb_sha, wb_luid)
  if PhaseCache.fresh?(WORK, 'custom-sql', key: csql_key, outputs: [csql_path])
    line 'custom-SQL scan REUSED (.twb sha unchanged) — delete custom-sql.json to force'
  else
    csql_cmd = ['ruby', File.join(HERE, 'extract-custom-sql.rb'),
                '--workbook-luid', wb_luid, '--twb', twb, '--out', csql_path]
    _, csql_st = tableau_run!(csql_cmd, allow_fail: true)
    # Stamp only a SUCCESSFUL scan (an [] from a clean run is a legit "no
    # custom SQL" answer; an auth/network failure is not, and must re-try).
    PhaseCache.stamp!(WORK, 'custom-sql', key: csql_key, outputs: [csql_path]) if csql_st.success? && File.exist?(csql_path)
  end
  custom_sql = (JSON.parse(File.read(csql_path)) rescue []) if File.exist?(csql_path)
  custom_sql = [] unless custom_sql.is_a?(Array)
end

# Gap scan already ran in the discovery lane (right after the .twb landed);
# parse its report here. Lane scan failure degrades the same way the serial
# allow_fail run did: gaps stays empty.
gaps = []
gap_report_md = nil
if have_twb
  gj = Dir[File.join(WORK, '*gaps*report*.json')].first || Dir[File.join(WORK, '*gaps*.json')].first
  if gj.nil? && lane[:reused]
    # Discovery was REUSED but no gap report exists (the prior lane's scan
    # failed, or the stamp predates the report). The gap GATE below must never
    # run against a silently-empty inventory — re-scan in the foreground: it is
    # pure-local .twb parsing (<10s), no Tableau call.
    line 'gap scan: no report on disk from the reused discovery — re-running scan-workbook-gaps.rb (local)'
    run!(['ruby', File.join(HERE, 'scan-workbook-gaps.rb'), twb], allow_fail: true)
    gj = Dir[File.join(WORK, '*gaps*report*.json')].first || Dir[File.join(WORK, '*gaps*.json')].first
  elsif gj && lane[:reused]
    line 'gap scan REUSED (ran with the stamped discovery; the .twb revision is unchanged)'
  end
  if gj && File.exist?(gj)
    gap_report_md = gj.sub(/\.json$/, '.md')
    gaps = (JSON.parse(File.read(gj))['detected_features'] || []) rescue []
    bys = gaps.group_by { |g| g['status'] }.transform_values(&:size)
    line "gap scan: #{bys.map { |k, v| "#{v} #{k}" }.join(', ')}"
    # Model-fit checkpoint trigger (refs/model-fit.md): on complex workbooks a
    # non-top-tier driving model must ASK the user once before building. The
    # orchestrator cannot see which model is driving — print the trigger so the
    # agent executes the checkpoint (it is mandatory per SKILL.md preflight).
    begin
      dl = JSON.parse(File.read(File.join(WORK, 'dashboard-layout.json')))
      dashes = dl.is_a?(Array) ? dl : (dl['dashboards'] || [dl])
      zones_max = dashes.map { |d| (d['zones'] || []).size }.max.to_i
      if dashes.size > 1 || zones_max > 30 || bys['unhandled'].to_i.positive? || bys['manual'].to_i > 1
        line "MODEL FIT: complex workbook (#{dashes.size} dashboard(s), max #{zones_max} zones/dashboard) — " \
             'if the driving model is not top-tier, execute the ask-once checkpoint in refs/model-fit.md ' \
             'BEFORE building (and confirm image input for the visual gates).'
      end
    rescue StandardError
      # layout json not parsed yet on some paths — the SKILL.md checkpoint still applies
    end
  end
end

# Source accounting starts as soon as the required discovery facts exist. This
# preliminary census is deliberately conservative: before a built spec/parity
# exists, in-scope objects remain needs-review rather than being guessed
# migrated. Phase 6 finalize refreshes it from the gate artifacts.
_source_census_path = File.join(WORK, 'source-object-census.json')
FileUtils.rm_f(_source_census_path)
_, _source_census_discovery_st = run!(
  ['ruby', File.join(HERE, 'build-source-object-census.rb'), '--workdir', WORK],
  allow_fail: true
)
line "WARN: preliminary source-object census failed (exit #{_source_census_discovery_st.exitstatus})" \
  unless _source_census_discovery_st.success?

# GAP-SCAN HARD GATE: ❌-unhandled features mean part of the workbook cannot be
# migrated by this skill yet. Abort WITH the report unless the human accepts the
# degradation explicitly via --force. (auto/hint/manual statuses flow into the
# decisions checkpoint below instead.)
unhandled_gaps = gaps.select { |g| g['status'].to_s == 'unhandled' }
# E9.6/A2 (wave-1 review): the gap SCAN is workbook-wide, but on a SCOPED run
# the gap STOP must not fire for an ❌ feature attributed ENTIRELY to
# worksheets outside the scoped zone tree — that is another dashboard's
# migration, and stopping for it is a false stop under the ≤5% budget.
# Matching reuses the empty-CSV normalize/fail-open pattern below: normalized
# names against the scoped chart zones; a gap with NO `worksheets`
# attribution (scan-workbook-gaps.rb couldn't place it) FAILS OPEN and still
# stops, and an unusable zone tree fails OPEN wholesale. Dropped items are
# ledgered as out-of-scope notes — the report still lists them.
if scoped? && unhandled_gaps.any?
  _gap_norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
  _scoped_ws = (defined?(chart_zones) && chart_zones ? chart_zones : [])
               .flat_map { |z| [z['caption'], z['view_ref']] }
               .compact.map { |s| _gap_norm.call(s) }.reject(&:empty?)
  if _scoped_ws.any?
    dropped, unhandled_gaps = unhandled_gaps.partition do |g|
      ws = Array(g['worksheets']).map { |w| _gap_norm.call(w) }.reject(&:empty?)
      ws.any? && (ws & _scoped_ws).empty?
    end
    if dropped.any?
      line "scope: #{dropped.size} ❌-unhandled gap(s) on out-of-scope worksheets only — not stopped for " \
           "(#{dropped.map { |g| g['name'] }.join(', ')[0, 120]}); the workbook-wide gap report still lists them"
      dropped.each do |g|
        Offramp.log(WORK, kind: 'gap-out-of-scope',
                    detail: "#{g['name']} (×#{g['count']}) on #{Array(g['worksheets']).join(', ')[0, 120]} — " \
                            'outside the stated scope; surfaced in the gap report, not stopped for')
      end
    end
  end
end
gap_stop = nil # deferred gap-scan stop — resolved at the consolidated checkpoint (#2c)
if unhandled_gaps.any?
  # RUN-EACH-TIME GATE (bead 5l5e): the gap-scout must have run for EVERY
  # ❌-unhandled feature before the conversion proceeds. scout-validate-and-
  # persist.rb records each scouted gap to <WORK>/scout-ledger.jsonl as
  # {gap_id, status: validated|escalated}. --force is NOT a blanket skip: it
  # only accepts gaps the scout actually tried and escalated — never a gap the
  # scout never ran for. A 'validated' row is honored only when it carries
  # signed live-probe evidence (ScoutGate integrity, issue #458): a hand-written
  # or forged 'validated' line is treated as unvalidated (→ escalated bucket),
  # so the gate still blocks / requires real scouting.
  # Gap-id = the gap-report row name; the scout records under --gap-id '<name>'.
  by_name = unhandled_gaps.each_with_object({}) { |g, h| h[g['name'].to_s] = g }
  buckets = ScoutGate.classify(WORK, unhandled_gaps.map { |g| g['name'].to_s })
  unscouted = buckets[:unscouted].map { |id| by_name[id] }
  escalated = buckets[:escalated].map { |id| by_name[id] }

  # Regression fix (gap-scout PR #153): the unscouted branch hard-stopped even
  # under --yes/--force, stalling the unattended/demo path. Under unattended mode
  # (--yes/--answers/--force) the gate is ADVISORY — record the gaps as accepted and
  # proceed (the features are MISSING/flagged in Sigma, as before the gate existed).
  # Interactive runs still hard-stop — but the stop is now DEFERRED into the ONE
  # consolidated pre-build checkpoint below (speed review #2c): gap review,
  # decisions, and the cost advisory batch into a single operator
  # round-trip (single artifact, single re-entry) instead of serial stops. The
  # exit-code contract is unchanged: gap items present → exit 11, else exit 10.
  unattended = opts[:yes] || opts[:answers] || opts[:force]
  if unscouted.any? && !unattended
    gap_stop = { 'kind' => 'unscouted', 'items' => unscouted }
  elsif escalated.any? && !unattended
    gap_stop = { 'kind' => 'escalated', 'items' => escalated }
  else
    if unscouted.any?
      line "gap-scout: #{unscouted.size} ❌-unhandled feature(s) NOT scouted — proceeding (unattended); they will be MISSING/flagged in Sigma. (optional: scripts/gap-scout.md to translate)"
      unscouted.each do |g|
        ScoutGate.record(WORK, gap_id: g['name'].to_s, feature: 'feature', status: 'accepted')
        # E3.6 (vocab half): the acceptance is an operator decision — ledger it.
        Offramp.decision(WORK, kind: 'gap-accepted', question: "unscouted ❌-unhandled feature: #{g['name']}",
                         answer: 'accepted (unattended — feature will be MISSING/flagged)',
                         decided_by: opts[:yes] || opts[:force] ? 'unattended-flag' : 'relayed')
      end
    end
    if escalated.any?
      line "--force/--yes: proceeding past #{escalated.size} scouted-but-escalated feature(s) — they will NOT migrate"
      escalated.each do |g|
        Offramp.decision(WORK, kind: 'gap-accepted', question: "scouted-but-escalated feature: #{g['name']}",
                         answer: 'accepted (unattended — feature will NOT migrate)',
                         decided_by: opts[:yes] || opts[:force] ? 'unattended-flag' : 'relayed')
      end
    end
    line "gap-scout: all #{unhandled_gaps.size} ❌-unhandled feature(s) resolved via validated rules" if unscouted.empty? && escalated.empty?
  end
end

# EMPTY-VIEW-CSV preflight (honesty stop): a view whose CSV exported 0 data rows
# produces NO chart — the tile silently drops and the census gate stops the
# --finalize pass. Surface it NOW as a decision instead of a surprise later.
empty_csvs = Dir[File.join(WORK, 'views', '*.csv')].select do |c|
  (File.readlines(c).reject { |l| l.strip.empty? }.size rescue 0) <= 1
end.map { |c| File.basename(c, '.csv') }
# E9.6 — a scoped run only surfaces the TARGET dashboard's views: an empty CSV
# for an out-of-scope worksheet is not this build's decision. Matching is
# normalized (case/punctuation-stripped) against the scoped zone tree; when the
# scoped zones carry no usable names, fail OPEN (keep everything surfaced).
if scoped? && defined?(chart_zones) && chart_zones.any? && empty_csvs.any?
  _csv_norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
  _scoped_views = chart_zones.flat_map { |z| [z['caption'], z['view_ref']] }
                             .compact.map { |s| _csv_norm.call(s) }.reject(&:empty?)
  if _scoped_views.any?
    dropped = empty_csvs.reject { |v| _scoped_views.include?(_csv_norm.call(v)) }
    empty_csvs -= dropped
    line "scope: #{dropped.size} empty view CSV(s) outside the stated dashboard scope not surfaced (#{dropped.join(', ')[0, 120]})" if dropped.any?
  end
end
line "WARN: #{empty_csvs.size} view CSV(s) came back EMPTY: #{empty_csvs.join(', ')}" if empty_csvs.any?

# PLOTTED metrics whose formula did not fully translate — deferred from spec
# generation (needs the lane's view CSVs to know what is actually charted).
if mechanical
  csv_headers = Dir[File.join(WORK, 'views', '*.csv')].flat_map do |c|
    (CSV.read(c).first rescue nil) || []
  end.compact.map { |h| h.to_s.strip }.uniq
  plotted_untranslated = pre_untranslated.select do |nm|
    csv_headers.any? { |h| h.casecmp?(nm) || h.sub(/^(sum|avg|min|max|median|distinct count|count) of /i, '').casecmp?(nm) }
  end
end
mark('phase1-join')

# ---------------------------------------------------------------------------
# Phase 0c — scope/cost estimate + SIGN-OFF (PLAN-v3 PR-3). This is the first
# point where BOTH discovery metadata (get-workbook / dashboard-layout /
# calc-fields / custom-sql) and the gap-scan artifacts exist, and it runs
# BEFORE the decisions checkpoint and any DM build/POST — the human signs off
# on scope (tiles, calc classes, untranslatable gap classes) and rough token
# cost while aborting is still free. estimate-cost.rb runs allow_fail and
# degrades gracefully on missing inputs (it NAMES them) — a scoping estimate
# must never block a migration. The acknowledgment lands in run-state.json:
#   --yes / --answers (unattended)  → provenance "auto-yes"
#   interactive                     → provenance "stated" (the operator saw
#                                     the printed block and continued)
# A missing ack is WARNed at the Phase 3 seam — WARN-only this release
# (hard-gating waits for field calibration confidence in the estimator).
# ---------------------------------------------------------------------------
cost_est_path = File.join(WORK, 'cost-estimate.json')
run!(['ruby', File.join(HERE, 'estimate-cost.rb'), '--workdir', WORK, '--out', cost_est_path],
     allow_fail: true)
cost_est = (JSON.parse(File.read(cost_est_path)) rescue nil)
# The SCOPE / COST SIGN-OFF advisory is COMPOSED here — before the decisions
# checkpoint, so the operator always sees scope/cost before deciding — and
# printed either standalone (run proceeds — the pre-#2c behavior) or folded
# into the consolidated checkpoint banner (run stops — E9.4 ratified: the
# advisory is WARN-only and rides the ONE pre-build stop, never a standalone
# stop of its own).
cost_lines = []
if cost_est
  ce_est = cost_est['estimate'] || {}
  ce_scope = cost_est['scope'] || {}
  ce_calcs = ce_scope['calcs'] || {}
  ce_unt = ce_scope['untranslatable_classes'] || []
  cost_lines << "  workbook:        #{cost_est['workbook'] || wb_name}"
  cost_lines << "  tiles:           #{ce_scope['tiles'] || '? (dashboard-layout.json missing)'}"
  cost_lines << "  calc fields:     #{ce_calcs['total'] || 0} " \
                "(#{ce_calcs['simple'] || 0} simple, #{ce_calcs['complex'] || 0} complex, " \
                "#{ce_calcs['requires_custom_sql'] || 0} custom-SQL residue)"
  cost_lines << "  gap classes:     #{(ce_scope['gap_classes'] || {}).map { |k, v| "#{v} #{k}" }.join(', ')}"
  cost_lines << "  untranslatable:  #{ce_unt.any? ? ce_unt.join(', ') : '(none)'}"
  cost_lines << "  estimate:        ~#{ce_est['agent_turns']} agent turns ≈ #{ce_est['input_tokens']} in / " \
                "#{ce_est['output_tokens']} out tokens, ~#{ce_est['estimated_minutes']} min " \
                "(#{ce_est['complexity']}; confidence: #{cost_est['confidence'] || 'rough'})"
  (cost_est.dig('inputs', 'missing') || []).each do |m|
    cost_lines << "  degraded:        missing #{m['artifact']} — #{m['provides']}"
  end
  cost_lines << "  full breakdown:  #{cost_est_path}"
else
  line "WARN: cost estimate unavailable (no readable #{File.basename(cost_est_path)}) — " \
       'proceeding without a scope/cost sign-off; Phase 3 will WARN.'
end
# The ack is recorded only when the run PROCEEDS past this point (the operator
# saw the block or waved it through unattended) — a run that STOPS at the
# consolidated checkpoint records the ack on the re-entry pass instead, when
# the sign-off was actually before the operator's eyes.
record_cost_ack = lambda do
  next unless cost_est
  ack_prov = (opts[:yes] || opts[:answers]) ? 'auto-yes' : 'stated'
  RunState.record(WORK, 'cost_estimate_acknowledged' => true,
                        'cost_estimate_provenance'   => ack_prov)
  line "scope/cost sign-off recorded in run-state (cost_estimate_acknowledged: true, provenance: #{ack_prov})"
end
# ---------------------------------------------------------------------------
# W2.1 — TIER RATCHET (orchestrator half). Resolve the run's tier HERE, at the
# 0c checkpoint: the first point where every predicate input is on disk
# (discovery metadata + dashboard layout + the gap scan), before the decisions
# checkpoint and any DM/workbook POST. Detection is Tier.detect — a PURE
# function over artifacts, never an agent-supplied count (anti-gaming). An
# operator --tier S|M|full overrides the predicate and is itself a ledgered
# decision; --tier auto (default) takes the predicate; fail-closed → 'full'.
# The resolved tier + basis are written to migrate-state.json ('tier'/
# 'tier_basis' — lane B's gate reads them; strings pinned in
# shared/lib/testdata/wave2-tier-state.json), logged to the Offramp trail
# (kind 'tier-assigned'), and stamped into the RESULT block. Tier never
# removes a gate — Tier-S shrinks budgets and duplicate oracles only
# (rcf_passes default 5→1 at both sites, W2.4 checkpoint auto-defaults,
# lane B's gate-side waiver-budget scale + gate-18 GT-trio skip).
# ---------------------------------------------------------------------------
require_relative 'lib/tier'
_tier_det = Tier.detect(WORK)
if opts[:tier] && opts[:tier] != 'auto'
  $tier = opts[:tier]
  $tier_basis = Tier::BASIS_OVERRIDE
  # The override is a ledgered decision (existing DECIDED_BY tokens only —
  # the gap-scout acceptance provenance convention).
  Offramp.decision(WORK, kind: 'tier-override',
                   question: "--tier #{opts[:tier]} (auto-predicate said #{_tier_det['tier']}#{_tier_det['reasons'].any? ? ": #{_tier_det['reasons'].join('; ')}" : ''})",
                   answer: $tier,
                   decided_by: opts[:yes] || opts[:force] ? 'unattended-flag' : 'relayed')
else
  $tier = _tier_det['tier']
  $tier_basis = _tier_det['tier_basis']
end
line "tier: #{$tier} (#{$tier_basis}#{_tier_det['reasons'].any? ? " — #{_tier_det['reasons'].join('; ')}" : ''})"
Offramp.log(WORK, kind: 'tier-assigned',
            detail: "tier=#{$tier} basis=#{$tier_basis} features=#{_tier_det['features'].to_json}")
quiet_event('tier', 'tier' => $tier, 'basis' => $tier_basis)
begin # persist NOW (pass 1's full state write at the Phase-6 seam preserves it)
  _ms_p = File.join(WORK, 'migrate-state.json')
  _ms = (JSON.parse(File.read(_ms_p)) rescue {})
  File.write(_ms_p, JSON.pretty_generate(_ms.merge('tier' => $tier, 'tier_basis' => $tier_basis)))
rescue StandardError
  nil
end
mark('phase0c-cost')

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine human questions ONLY. Mechanical
# fixup / POST / layout / parity are never asked about.
# ---------------------------------------------------------------------------
questions = []

# (a0) MECHANICAL CONVERTER WARNINGS — the authoritative un-mappable signal.
# convert_tableau_to_sigma marks each calc/LOD/window translation outcome:
#   ⛔ = no/failed translation (calc dropped → charts using it degrade)
#   ⚠  = best-effort / unsupported mode (verify in Sigma)
#   ℹ / ✅ = clean auto-handle (NOT a decision)
(mechanical ? (conv['warnings'] || []) : []).each do |w|
  ws = w.to_s.gsub(/\s+/, ' ').strip
  next if ws.start_with?('ℹ', '✅')
  next if ws.include?('Connection ID not set') # mechanical: --connection always supplied
  if ws.start_with?('⛔')
    questions << { 'id' => 'calc_no_translation', 'severity' => 'review', 'detail' => ws,
                   'options' => ['proceed (calc dropped; dependent charts degrade)',
                                 'abort and re-author the calc manually'],
                   'default' => 'proceed (calc dropped; dependent charts degrade)' }
  else # ⚠ and any unmarked warning
    questions << { 'id' => 'calc_best_effort', 'severity' => 'review', 'detail' => ws,
                   'options' => ['proceed (converter best-effort; verify in Sigma)',
                                 'restructure manually'],
                   'default' => 'proceed (converter best-effort; verify in Sigma)' }
  end
end

# (a1) PLOTTED metrics whose formula did not fully translate (unresolved Tableau
# internal field refs). These are charted by a Tableau view but cannot resolve
# mechanically against the master — a genuine human decision.
(mechanical ? (defined?(plotted_untranslated) && plotted_untranslated || []) : []).each do |nm|
  questions << { 'id' => 'metric_untranslated', 'severity' => 'review', 'calc' => nm,
                 'detail' => "Metric '#{nm}' is plotted in a Tableau view but the converter left unresolved " \
                             'internal field references in its formula — it cannot be rebuilt mechanically.',
                 'options' => ['proceed (chart measure left blank; re-author the calc in Sigma)',
                               'skip this metric'],
                 'default' => 'proceed (chart measure left blank; re-author the calc in Sigma)' }
end

# (a2) calc COLUMNS the mechanical fixup had to DROP (unknown function like
# DATEPARSE, or refs that never resolved). Genuinely un-mappable → human.
(mechanical ? (defined?(dropped_calcs) && dropped_calcs || []) : []).each do |nm|
  questions << { 'id' => 'calc_dropped', 'severity' => 'review', 'calc' => nm,
                 'detail' => "Calc column '#{nm}' could not be translated mechanically (unsupported function " \
                             'or unresolved reference) and was dropped from the data model.',
                 'options' => ['proceed (column dropped; re-author as a Custom SQL element or Sigma calc)',
                               'skip this calc'],
                 'default' => 'proceed (column dropped; re-author as a Custom SQL element or Sigma calc)' }
end

# (a) calc fields that have NO Sigma translation AT ALL — the manual window
#     residues (WINDOW_MEDIAN/PERCENTILE/CORR/..., PREVIOUS_VALUE, SIZE,
#     FIRST/LAST) and INCLUDE/EXCLUDE LODs. The mainstream window/table-calc
#     family (RUNNING_*/bounded WINDOW_*/RANK*/INDEX/LOOKUP/TOTAL) no longer
#     lands here: build-charts auto-emits it as Sigma-native chart formulas
#     (refs/window-functions.md) with no decision needed.
calcs.select { |c| c['requires_custom_sql'] }.each do |c|
  questions << {
    'id' => 'calc_requires_custom_sql', 'severity' => 'review',
    'calc' => c['name'],
    'detail' => "Tableau calc '#{c['name']}' (#{c['is_lod'] ? 'LOD' : 'manual window residue'}) has no validated Sigma " \
                "translation: #{c['formula'].to_s.gsub(/\s+/, ' ').strip[0, 120]}",
    'options' => ['implement as a Custom SQL data-model element (kind: sql)',
                  'degrade (drop the calc; charts using it go blank)',
                  'skip this calc'],
    'default' => 'implement as a Custom SQL data-model element (kind: sql)'
  }
end

# (b) custom-SQL datasource blocks — preserve the semantics, but do not mistake
#     source SQL for a mandate to embed SQL in the target model. Tables are the
#     maintainable default when decomposition is exact + equivalence-proven.
custom_sql.each do |b|
  q = (b['query'] || b['sql'] || '').to_s.gsub(/\s+/, ' ').strip[0, 120]
  questions << {
    'id' => 'custom_sql_datasource', 'severity' => 'review',
    'detail' => "Datasource is backed by Tableau Custom SQL. Prefer warehouse-table elements + relationships/calcs " \
                "when they preserve every join/filter/grain rule and pass the equivalence probe; otherwise retain source.kind=sql: #{q}",
    'options' => ['normalize to warehouse-table elements (only with a passing semantic equivalence proof)',
                  'preserve the Custom SQL in source.kind=sql for exact parity',
                  'abort and refactor the source in the warehouse first'],
    'default' => 'normalize to warehouse-table elements when equivalence is provable; otherwise preserve source.kind=sql'
  }
end

# (c) file-based / "land in warehouse" datasources (Excel/CSV/Hyper extract not
#     backed by a live warehouse table).
ds_type = (wb.dig('datasources') || []).to_s
file_based = ds_type =~ /excel|csv|textscan|hyper|\.tde|google-sheets/i
if file_based || (has_extracts && custom_sql.empty? && !have_twb)
  questions << {
    'id' => 'file_based_datasource', 'severity' => 'required',
    'detail' => 'Datasource appears to be file-based (Excel/CSV/Hyper) — Sigma reads a warehouse, ' \
                'so the data must first land in a warehouse table on the chosen connection',
    'options' => ['land the file in the warehouse, then point the DM at that table',
                  'abort until the data is in the warehouse'],
    'default' => nil
  }
end

# (d) extract-backed workbook — Tableau CSVs are a frozen snapshot; parity will
#     drift vs live warehouse. This is an expectations decision, not a failure.
if has_extracts
  questions << {
    'id' => 'extract_drift', 'severity' => 'review',
    'detail' => 'Workbook/datasource hasExtracts=true: Tableau view CSVs are a frozen snapshot. ' \
                'Sigma reads the warehouse live, so absolute values will drift; parity runs in ' \
                'structural (extract) mode.',
    'options' => ['proceed (structural parity, value drift expected)', 'abort and refresh the extract first'],
    'default' => 'proceed (structural parity, value drift expected)'
  }
end

# (e) unsupported / approximate viz kinds. Keep in lock-step with build-charts'
#     SIGMA_KIND map + the SKILL's "Sigma spec supports" list.
NATIVE = %w[bar line area combo scatter pie kpi map-region map-point pivot-table
            table automatic other table-or-text].freeze
APPROX = {
  'gantt' => 'approximate-to-bar', 'bullet' => 'approximate-to-bar',
  'heatmap' => 'data-migrate-as-table', 'treemap' => 'data-migrate-as-table',
  'packed-bubble' => 'data-migrate-as-table', 'density' => 'data-migrate-as-table'
}.freeze
chart_zones.each do |z|
  k = z['chart_kind'].to_s
  next if NATIVE.include?(k)
  cap = z['caption'] || z['view_ref'] || k
  if APPROX.key?(k)
    questions << { 'id' => 'viz_no_native_kind', 'severity' => 'review',
                   'viz' => cap, 'tableau_kind' => k,
                   'detail' => "Tableau '#{k}' has no native Sigma element kind",
                   'options' => [APPROX[k], 'skip this viz'], 'default' => APPROX[k] }
  else
    questions << { 'id' => 'viz_unknown_kind', 'severity' => 'review',
                   'viz' => cap, 'tableau_kind' => k,
                   'detail' => "Tableau mark '#{k}' did not map to a known Sigma kind — confirm from the dashboard PNG",
                   'options' => ['build as a bar-chart (default fallback)', 'skip this viz'],
                   'default' => 'build as a bar-chart (default fallback)' }
  end
end

# (e2) empty view CSVs — the chart for that view CANNOT be built mechanically
#      (no headers/rows to derive columns from). Genuine human decision: recover
#      the data or accept a missing tile (which the census gate will then stop on).
empty_csvs.each do |v|
  questions << {
    'id' => 'empty_view_csv', 'severity' => 'review', 'viz' => v,
    'detail' => "View '#{v}' exported an EMPTY CSV — its chart cannot be built mechanically and " \
                'the tile census will stop the --finalize gate. Recover the CSV (re-export with ' \
                'filters relaxed / MCP get-view-data) before re-running, or proceed and rebuild ' \
                'the chart manually against the posted DM, then explain via --allow-missing-tiles.',
    'options' => ['proceed (tile missing; rebuild manually + --allow-missing-tiles at --finalize)',
                  'abort and recover the view CSV first'],
    'default' => 'proceed (tile missing; rebuild manually + --allow-missing-tiles at --finalize)'
  }
end

# (f) missing folder (DM + workbook land in My Documents).
unless opts[:folder]
  questions << { 'id' => 'folder', 'severity' => 'required',
                 'detail' => 'No Sigma --folder supplied; DM + workbook will land in My Documents',
                 'options' => ['supply --folder <id>', 'proceed into My Documents'],
                 'default' => 'proceed into My Documents' }
end

answers = nil
if opts[:answers]
  answers = JSON.parse(opts[:answers]) rescue abort('FATAL: --answers is not valid JSON')
  abort 'FATAL: --answers must be a JSON OBJECT — {"<id>":"<choice>", "<id>:<slug>":"<choice>"}' unless answers.is_a?(Hash)
end

# E5.10 addressability: the ONE derivation of a question's targeted --answers
# key ("<id>:<slug>", slug = calc/viz tag downcased, non-alnum → '-', trimmed).
# The computed key is EMBEDDED per entry in open-questions.json at write time
# (wave-1 review): a driver that re-derived the slug and drifted (unicode,
# doubled separators) silently fell back to the bulk class answer with no
# warning. nil for untagged questions — those are addressed by class id only.
def question_targeted_key(q)
  slug = (q['calc'] || q['viz']).to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
  slug.empty? ? nil : "#{q['id']}:#{slug}"
end

# ---------------------------------------------------------------------------
# CONSOLIDATED PRE-BUILD CHECKPOINT (speed review #2c + reconciled amendments).
# Gap-scan review (exit 11), decisions (exit 10), and the E9.4 cost ADVISORY
# (WARN-only, ratified) batch into ONE operator stop over
# the open-questions.json --answers substrate: single combined artifact
# (<WORK>/open-questions.json), single re-entry. The exit-code contract is
# unchanged — gap items pending → 11, else questions pending → 10 — so
# existing drivers keep working; they just stop ONCE instead of serially.
# ---------------------------------------------------------------------------
oq_path = File.join(WORK, 'open-questions.json')
_prior_oq = File.exist?(oq_path) ? (JSON.parse(File.read(oq_path)) rescue nil) : nil
# W2.4 — Tier-S checkpoint AUTO-DEFAULTS. A clean Tier-S run (predicate-clean:
# no gap stop) whose open questions ALL carry safe defaults (severity 'review',
# non-nil default — the defaults the checkpoint itself would apply under --yes)
# pre-derives the answers from the artifacts, prints the one-line notice, and
# PROCEEDS — no operator stop, no re-entry. Every auto-answer is ledgered to
# decisions.jsonl under the greppable kind 'unattended-tier-default'; its
# provenance is decided_by 'unattended-flag' (closed vocabulary; nobody asked).
# Any unattributable question — severity 'required' or no default — still
# stops exactly as today (the conservative direction: a stop that could have
# been skipped costs one turn; a skipped stop that shouldn't have been is a
# correctness leak). Tier-M/full runs are untouched.
_tier_autodefault = $tier == 'S' && !gap_stop && questions.any? &&
                    !opts[:yes] && answers.nil? &&
                    questions.all? { |q| q['severity'] != 'required' && !q['default'].nil? }
if _tier_autodefault
  line "TIER-S auto-defaults: #{questions.size} checkpoint question(s) auto-answered with their safe defaults " \
       "(recorded as 'unattended-tier-default' in decisions.jsonl) — proceeding without the operator stop."
end
if (gap_stop || questions.any?) && !opts[:yes] && answers.nil? && !_tier_autodefault
  gap_items = gap_stop ? gap_stop['items'] : []
  block = {
    'status' => gap_stop ? 'gap_review_and_decisions_needed' : 'decisions_needed',
    'workbook' => wb_name,
    'phases_completed' => ['1 Discover', '1.6 DM-reuse scan (read-only)', '2 Warehouse columns (read-only)'],
    'note' => 'Deterministic mechanical steps (DM/workbook POST, layout, parity) are NOT asked about. ' \
              'ONE re-entry resolves everything: re-run with --yes to accept all defaults, or ' \
              '--answers \'{"<id>":"<choice>"}\' (bulk by class id, or targeted via the entry\'s ' \
              "embedded 'targeted_key' — copy it verbatim, targeted wins)" \
              "#{gap_stop ? ' plus --force to accept the gap review items' : ''}.",
    'gap_review' => gap_items.map do |g|
      { 'name' => g['name'], 'count' => g['count'], 'status' => gap_stop['kind'],
        'blurb' => g['blurb'],
        'resolution' => gap_stop['kind'] == 'unscouted' ?
          "spawn a gap-scout (scripts/gap-scout.md) with --gap-id '#{g['name']}' --workdir #{WORK}, or accept via --force/--yes (feature MISSING/flagged)" :
          'accept via --force/--yes (feature will NOT migrate), or translate manually' }
    end,
    'cost_advisory' => cost_est ? {
      'estimated_minutes' => cost_est.dig('estimate', 'estimated_minutes'),
      'agent_turns' => cost_est.dig('estimate', 'agent_turns'),
      'input_tokens' => cost_est.dig('estimate', 'input_tokens'),
      'output_tokens' => cost_est.dig('estimate', 'output_tokens'),
      'complexity' => cost_est.dig('estimate', 'complexity'),
      'confidence' => cost_est['confidence'] || 'rough',
      'note' => 'ADVISORY (WARN-only, E9.4 ratified) — folded into this checkpoint; not a standalone stop.'
    } : nil,
    # Each tagged entry carries its COMPUTED targeted key — drivers copy it
    # verbatim into --answers instead of re-deriving the slug normalization.
    'open_questions' => questions.map do |q|
      (tk = question_targeted_key(q)) ? q.merge('targeted_key' => tk) : q
    end
  }.reject { |_, v| v.nil? }
  File.write(oq_path, JSON.pretty_generate(block) + "\n")
  puts
  puts '==================== PRE-BUILD CHECKPOINT (ONE stop: gaps + decisions + cost) ===================='
  if gap_stop
    puts "GAP REVIEW (#{gap_stop['kind']}): #{gap_items.size} ❌-unhandled feature(s) need review:"
    gap_items.each { |g| puts "  - #{g['name']} (×#{g['count']}): #{g['blurb'].to_s[0, 160]}" }
    puts "  Full report: #{gap_report_md || '(see workdir *gaps-report.md)'}"
    if gap_stop['kind'] == 'unscouted'
      puts '  Scout each row (scripts/gap-scout.md, one subagent per row, --gap-id \'<name>\'), or accept'
      puts '  the degradation with --force/--yes on the re-entry (features MISSING/flagged in Sigma).'
    else
      puts '  All were scouted; these escalated (no auto-translation). Accept with --force/--yes on the'
      puts '  re-entry (they will NOT migrate), or translate manually first.'
    end
    puts
  end
  if cost_lines.any?
    puts 'SCOPE / COST ADVISORY (WARN-only — E9.4; sign-off rides this one stop):'
    cost_lines.each { |l| puts l }
    puts
  end
  puts 'OPEN QUESTIONS (also written to open-questions.json — the machine copy):'
  puts JSON.pretty_generate(block)
  puts '=========================================================================================================='
  puts
  puts "#{questions.size} decision(s)#{gap_stop ? " + #{gap_items.size} gap review item(s)" : ''} need a human — " \
       'ONE re-entry resolves all of it. No Sigma objects were created.'
  # A9 (wave-1 review): no ` --force` suffix on the gap-run hint — --answers
  # alone already proceeds through gaps (unattended = yes||answers||force) AND
  # records the more honest decided_by:'relayed'; adding --force degrades the
  # provenance to 'unattended-flag'. --force stays documented for the
  # no-answers path (gap_review resolution lines above).
  puts "  re-run this exact command adding:  --answers '<json>'   # or --yes for all defaults"
  _cp_via = gap_stop ? 'gap-scan-stop' : 'decisions-stop'
  _cp_reason = "#{questions.size} open question(s)#{gap_stop ? " + #{gap_items.size} #{gap_stop['kind']} gap(s)" : ''} need a human"
  authorize_manual_path!(via: _cp_via, reason: _cp_reason, exit_code: gap_stop ? 11 : 10)
  Offramp.log(WORK, kind: _cp_via, detail: "consolidated checkpoint: #{_cp_reason}")
  quiet_event('stop', 'code' => gap_stop ? 11 : 10, 'artifact' => oq_path,
              'questions' => questions.size, 'gap_items' => gap_items.size)
  phase_summary
  exit(gap_stop ? 11 : 10)
end

# The advisory printed standalone on the proceed-through path (unchanged
# pre-#2c surface: the operator still sees scope/cost on every run) + the ack.
if cost_lines.any?
  puts
  puts '==================== SCOPE / COST SIGN-OFF ===================='
  cost_lines.each { |l| puts l }
  puts '=============================================================='
end
record_cost_ack.call

# E5.10: an --answers key that matches NO surfaced question — neither a bulk
# class id nor an embedded targeted_key — is almost always a mis-derived slug;
# SAY so instead of silently falling back to the class/default answer.
# WARN-only, never a stop: a changed input can legitimately retire a question
# between the stop and the re-entry.
if answers
  _known_keys = questions.flat_map { |q| [q['id'], question_targeted_key(q)] }.compact
  (answers.keys - _known_keys).each do |k|
    line "WARN: --answers key '#{k}' matches no open question — IGNORED (any question it meant to " \
         "target resolves by bulk id/default instead; copy targeted keys verbatim from " \
         "open-questions.json 'targeted_key', bulk ids from 'id')"
  end
end

if questions.any?
  puts
  line "decisions auto-resolved (#{opts[:yes] ? '--yes: defaults' : (answers ? '--answers supplied' : 'TIER-S auto-defaults')}):"
  questions.each do |q|
    tag = q['calc'] || q['viz']
    # E5.10 substrate: targeted "<id>:<slug>" answers take precedence over the
    # bulk class-id answer; both fall back to the default. The key here is the
    # SAME question_targeted_key the checkpoint artifact embeds — one derivation.
    tkey = question_targeted_key(q)
    chosen = (answers && tkey && answers[tkey]) ||
             (answers && answers[q['id']]) || q['default']
    line "  - #{q['id']}#{tag ? " [#{tag}]" : ''}: #{chosen || '(no default — required)'}"
    # E3.6 (vocab half): every resolved checkpoint question is ledgered.
    # decided_by is honest provenance — an --answers value is agent-RELAYED
    # operator text, never first-hand consent; --yes defaults are unattended.
    # W2.4: a Tier-S auto-default is ledgered under the greppable kind
    # 'unattended-tier-default' (question text still carries the class id).
    Offramp.decision(WORK, kind: _tier_autodefault ? 'unattended-tier-default' : q['id'],
                     question: "#{_tier_autodefault ? "#{q['id']}: " : ''}#{(q['detail'] || q['id']).to_s[0, 200]}",
                     answer: chosen.to_s,
                     decided_by: answers ? 'relayed' : 'unattended-flag')
    if chosen.nil? && q['severity'] == 'required'
      abort "FATAL: required decision '#{q['id']}' has no default; re-run with --answers or fix inputs"
    end
  end
  # Mark the checkpoint artifact RESOLVED (answers ledgered above) so later
  # re-entries don't re-surface already-answered questions; the doc survives
  # as history, decisions.jsonl is the append-only record.
  if _prior_oq.is_a?(Hash) && _prior_oq['status'].to_s != 'resolved'
    begin
      _prior_oq['status'] = 'resolved'
      _prior_oq['resolved_at'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
      _prior_oq['resolved_by'] = opts[:yes] ? '--yes (defaults)' : '--answers'
      File.write(oq_path, JSON.pretty_generate(_prior_oq) + "\n")
    rescue StandardError
      nil
    end
  end
else
  line 'no open questions — running straight through'
end
mark('decisions')
end # ═══ unless FASTPATH (full discovery → gates → decisions pipeline) ═══════

# ---------------------------------------------------------------------------
# folderId default (bead epvr). POST /v2/dataModels/spec REQUIRES folderId
# ("Expecting UUID at 0.folderId"). When the human chose "proceed into My
# Documents" (--yes / answered default), RESOLVE the caller's My Documents
# folder id and inject it — never emit a folderId-less spec. (Same contract
# the quicksight converter enforces with its mandatory --folder-id.)
# ---------------------------------------------------------------------------
if opts[:folder].to_s.empty?
  require 'sigma_rest'
  require 'destination_resolver'
  begin
    opts[:folder] = DestinationResolver.my_documents_id
    line "folderId default: resolved caller's My Documents = #{opts[:folder]} (no --folder supplied)"
  rescue Sigma::Error, DestinationResolver::Error => e
    abort "FATAL: My Documents folder resolution failed (#{e.message.lines.first&.strip}) — pass --folder <id>"
  end
end
mark('folder-resolve')

# ---------------------------------------------------------------------------
# 🚧 WAIT-GATE (Phase 1d) — source dashboard-read at the DM-POST barrier,
# enforced BEFORE any DM/workbook POST (speed review #2a). The orchestrated
# pass fetches CSVs but CANNOT read the source dashboard PNG (that's an agent
# vision step), so historically it shipped number-correct workbooks missing
# tiles/text/filters the source rendered — and the old gate GUARANTEED one
# full abort/re-invocation per cold run. Now the orchestrator WAITS here,
# polling for a verified png-read.json while the agent reads the PNGs the
# discovery lane already downloaded — bounded (SIGMA_PNG_READ_TIMEOUT_S,
# default 480s; 0 = don't wait), with an explicit exit-code contract (exit 18
# + a banner naming exactly what is missing) when the deadline passes.
# NO STALE-SEED REUSE: a png-read.json that predates THIS run's discovery
# fetch describes a possibly-different source revision — it is set aside as
# png-read.stale.json (nothing silently consumed, nothing destroyed) and the
# read must be re-verified against the fresh PNG. The freshness bound applies
# only when a fetch actually ran this run (stamp-reused discovery keeps a
# prior verified read — same source revision). Fires only on a Tableau workdir.
# ---------------------------------------------------------------------------
PNG_WAIT_TIMEOUT_S = (ENV['SIGMA_PNG_READ_TIMEOUT_S'] || '480').to_i
def png_read_stale?(png_path, fetch_started_at)
  return false unless fetch_started_at && File.exist?(png_path)
  File.mtime(png_path) < fetch_started_at
rescue StandardError
  false
end
if FASTPATH
  # The spec is agent-authored against a workdir whose dashboard read (and every
  # other Phase-1 stop) already ran before the exit-4 handoff — re-blocking here
  # recreates the friction the fast path removes. Recorded, never silent.
  line 'dashboard-read gate: SKIPPED (FAST PATH — the wb-spec was authored after the Phase 1d read)'
  RunState.skip(WORK, 'phase-1d', 'FAST PATH (--reuse-dm + --wb-spec)')
elsif opts[:skip_dashboard_read]
  line "dashboard-read gate WAIVED (--skip-dashboard-read: #{opts[:skip_dashboard_read]}) — name this in your report"
  # PR-14: every honored --skip-* leaves a record on the off-ramp trail.
  Offramp.log(WORK, kind: 'skip-flag-waived', reason: opts[:skip_dashboard_read],
              detail: '--skip-dashboard-read')
elsif DashboardRead.expected?(WORK)
  _dr_path = DashboardRead.path(WORK)
  # When did THIS run's discovery fetch start? nil on stamp-reused discovery
  # (no fetch this run → no freshness bound; the stamped revision matched).
  _dr_fetch_started = (defined?(lane) && lane.is_a?(Hash) && !lane[:reused]) ? lane[:started] : nil
  _dr_set_aside_stale = lambda do
    next false unless png_read_stale?(_dr_path, _dr_fetch_started)
    stale_to = _dr_path.sub(/\.json\z/, '.stale.json')
    begin
      File.rename(_dr_path, stale_to)
      line "png-read.json predates this run's discovery fetch — STALE SEED set aside as #{File.basename(stale_to)} " \
           '(no stale-seed reuse; re-verify against the freshly-fetched PNG)'
      Offramp.log(WORK, kind: 'png-read-stale',
                  detail: "set aside #{File.basename(stale_to)} (older than this run's discovery fetch)")
    rescue StandardError
      nil
    end
    true
  end
  _dr_set_aside_stale.call
  # Seed a DRAFT png-read.json from the .twb zone tree if none exists yet, so the
  # agent EDITS a starting point instead of writing from scratch (finding #8). The
  # draft is verified:false, so the gate below STILL requires the agent to Read
  # the dashboard PNG and confirm/correct it — the .twb can't tell bar-vs-pie,
  # text annotations, or the filter shelf.
  unless File.exist?(_dr_path)
    seeded = DashboardRead.seed_from_layout(WORK)
    line "seeded a DRAFT png-read.json from the .twb (#{DashboardRead.tile_count(WORK)} tile(s)) — must be verified against the dashboard PNG" if seeded
  end
  dr_ok, dr_errs = DashboardRead.validate(WORK)
  unless dr_ok
    warn ''
    # First line names the bound AND the fail-fast switch (wave-1 review):
    # a headless caller with nobody to write the read must learn
    # SIGMA_PNG_READ_TIMEOUT_S=0 from line ONE, not from a mid-banner aside,
    # or it silently blocks the full default bound before the old abort.
    warn "[WAIT] Phase 1d source dashboard-read gate — waits up to #{PNG_WAIT_TIMEOUT_S}s " \
         '(SIGMA_PNG_READ_TIMEOUT_S overrides; 0 = fail-fast exit 18 for headless callers ' \
         "with no driving agent to do the read) — #{_dr_path}"
    dr_errs.each { |e| warn "       - #{e}" }
    warn ''
    warn '       A DRAFT png-read.json was seeded from the .twb parse. The orchestrator cannot read'
    warn '       images — DO THE READ NOW, while this process WAITS at the DM-POST barrier'
    warn "       (up to #{PNG_WAIT_TIMEOUT_S}s; SIGMA_PNG_READ_TIMEOUT_S overrides; no DM was posted):"
    # A4 (wave-1 review): the discovery lane already downloaded the dashboard
    # PNG(s) on every PAT run (dashboards/<name>.png at resolution=high, plus
    # views/<id>.png) — instructing a fresh solo MCP fetch here re-pays a
    # serialized image call for bytes already on disk. Point at the local file
    # when it exists; the MCP fetch stays as the no-PAT/no-download fallback.
    _dr_pngs = Dir[File.join(WORK, 'dashboards', '*.png')] + Dir[File.join(WORK, 'views', '*.png')]
    if _dr_pngs.any?
      warn "         1. Read #{_dr_pngs.first} (already downloaded by the discovery lane" \
           "#{_dr_pngs.size > 1 ? "; #{_dr_pngs.size} PNGs under #{WORK}/dashboards|views" : ''})."
      warn '            (No PNG for YOUR dashboard there? Fallback: fetch it with'
      warn "            mcp__tableau__get-view-image (solo) into #{WORK}/views/.)"
    else
      warn "         1. Fetch the dashboard view PNG with mcp__tableau__get-view-image (solo) into #{WORK}/views/"
    end
    warn '         2. Read it, CORRECT the draft tiles/text_elements/filter_shelf (esp. bar-vs-pie, text'
    warn '            annotations, and the filter shelf — the .twb cannot see these), and set "verified": true.'
    warn '         3. Save the file — this run picks it up within seconds and continues (no re-invocation).'
    warn '       Genuinely no PNG access? Re-run with --skip-dashboard-read "<reason>" (name it in your report).'
    quiet_event('wait', 'gate' => 'phase-1d-dashboard-read', 'artifact' => _dr_path,
                'timeout_s' => PNG_WAIT_TIMEOUT_S)
    _dr_deadline = Time.now + PNG_WAIT_TIMEOUT_S
    _dr_beat = Time.now
    while Time.now < _dr_deadline
      sleep 2
      _dr_set_aside_stale.call # a stale file copied in mid-wait is refused too
      dr_ok, dr_errs = DashboardRead.validate(WORK)
      break if dr_ok
      next unless Time.now - _dr_beat > 30 # heartbeat: a wait must never LOOK wedged
      _dr_beat = Time.now
      puts "   … waiting for a verified png-read.json (#{(_dr_deadline - Time.now).round}s left " \
           'before exit 18; write the file with "verified": true to continue)'
      quiet_event('waiting', 'gate' => 'phase-1d-dashboard-read',
                  'remaining_s' => (_dr_deadline - Time.now).round)
    end
    unless dr_ok
      missing = if !File.exist?(_dr_path)
                  "#{File.basename(_dr_path)} does not exist"
                elsif png_read_stale?(_dr_path, _dr_fetch_started)
                  "#{File.basename(_dr_path)} is STALE (predates this run's discovery fetch)"
                else
                  "#{File.basename(_dr_path)} is present but not verified"
                end
      puts
      puts '=============== DASHBOARD-READ WAIT-GATE TIMEOUT (exit 18) ================='
      puts "Waited #{PNG_WAIT_TIMEOUT_S}s at the DM-POST barrier; still missing: #{missing}."
      (dr_errs || []).each { |e| puts "  - #{e}" }
      puts 'No Sigma objects were created. Do the Phase-1d read (fetch the dashboard PNG,'
      puts "Read it, write #{_dr_path} with \"verified\": true — schema in refs/phase-1-discover.md),"
      puts 'then re-run this exact command: discovery is cached, so the re-entry is cheap.'
      puts 'Genuinely no PNG access? Re-run with --skip-dashboard-read "<reason>".'
      puts 'Headless/CI callers (no driving agent to write the read): set'
      puts 'SIGMA_PNG_READ_TIMEOUT_S=0 so this gate fails fast instead of waiting.'
      puts '============================================================================='
      Offramp.log(WORK, kind: 'png-wait-timeout',
                  detail: "#{missing} after #{PNG_WAIT_TIMEOUT_S}s at the DM-POST barrier")
      quiet_event('stop', 'code' => 18, 'missing' => missing)
      phase_summary
      exit 18
    end
    line 'dashboard-read verified MID-WAIT — continuing in-process (no re-invocation paid)'
  end
  line "dashboard-read gate: #{DashboardRead.tile_count(WORK)} tile(s) verified (png-read.json)"
  RunState.stamp(WORK, 'phase-1d', note: 'source dashboard-read (png-read.json)')
end

# ---------------------------------------------------------------------------
# Phase 2.6 — DM-reuse augmentation gate (#691). A reused DM never runs
# through THIS conversion's Phase 3 build+POST, so the converter's own fact
# element (conv_fact) can carry mechanically-derived columns (date-key
# synthesis, cross-element Lookups, translated calc fields) that a fresh
# build would have POSTed as real columns and reuse simply never emitted.
# Verify the candidate against the ACTUAL columns the workbook will need
# (not the raw column-superset score find-or-pick-dm.rb computed — a name
# existing ANYWHERE in the DM is not the same as it being reachable from the
# fact grain the workbook needs) and either author the missing ones onto the
# live DM — replaying the SAME derivation a fresh build emits, never a second
# implementation — or abandon reuse for a fresh build when a gap can't be
# closed (a formula depends on an element/relationship the candidate lacks).
# ---------------------------------------------------------------------------
if reuse_dm_id && mechanical && conv_fact
  hdr('2.6', 'DM-reuse augmentation gate')
  $LOAD_PATH.unshift File.expand_path('lib', HERE) unless $LOAD_PATH.include?(File.expand_path('lib', HERE))
  require 'sigma_rest'
  _reuse_spec = begin
    Sigma.request(:get, "/v2/dataModels/#{reuse_dm_id}/spec")
  rescue StandardError => e
    line "WARN: could not read back reuse candidate #{reuse_dm_id} to plan augmentation " \
         "(#{e.class}: #{e.message.to_s[0, 100]}) — proceeding without it"
    nil
  end
  if _reuse_spec.is_a?(Hash) && _reuse_spec['pages']
    _reuse_els = MechanicalSpecs.all_elements(_reuse_spec)
    _dim_re = /(^Dim\b| Dim$)/i
    _reuse_fact = _reuse_els.reject { |e| e['name'] =~ _dim_re }
                            .max_by { |e| (e['columns'] || []).size } ||
                  _reuse_els.find { |e| e['name'] !~ _dim_re } || _reuse_els.first
    if _reuse_fact
      _plan = MechanicalSpecs.plan_reuse_derived_columns(conv_fact, _reuse_spec, _reuse_fact['name'])
      if _plan['unclosable'].any?
        _gap_names = _plan['unclosable'].map { |c| c['name'] }.join(', ')
        line "REUSE REFUSED: candidate #{reuse_dm_id} is missing #{_plan['unclosable'].size} required " \
             "derived field(s) with no derivable relationship/key on the live DM (#{_gap_names}) — " \
             'abandoning reuse; building a fresh data model instead.'
        Offramp.log(WORK, kind: 'reuse-gap-unclosable', detail: "#{reuse_dm_id}: #{_gap_names}") if defined?(Offramp)
        reuse_dm_id = nil
        opts[:reuse_dm] = nil
      elsif _plan['closable'].any?
        _added_names = _plan['closable'].map { |c| c['name'] }.join(', ')
        line "REUSE AUGMENT: candidate #{reuse_dm_id} is missing #{_plan['closable'].size} derived " \
             "field(s) a fresh build would have created (#{_added_names}) — authoring them onto the " \
             'live DM (same derivation the fresh path would emit, not re-derived).'
        _added = MechanicalSpecs.apply_reuse_augmentation!(_reuse_spec, _reuse_fact['name'], _plan['closable'])
        _aug_path = File.join(WORK, 'dm-spec-reuse-augment.json')
        File.write(_aug_path, JSON.pretty_generate(_reuse_spec))
        sigma_run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
                    '--spec', _aug_path, '--update-id', reuse_dm_id,
                    '--out', File.join(WORK, 'dm-ids-reuse-augment.json')])
        line "REUSE AUGMENT: added #{_added} column(s) to '#{_reuse_fact['name']}' on #{reuse_dm_id}"
      else
        line "REUSE: candidate #{reuse_dm_id} already carries every field the workbook needs — no augmentation required."
      end
    end
  end
  mark('phase2.6-reuse-augment')
end

# ---------------------------------------------------------------------------
# Phase 3 — Build + POST the data model.
# ---------------------------------------------------------------------------
hdr(3, 'Build data model')
# PLAN-v3 PR-3: the DM build is the first Sigma WRITE — a scope/cost sign-off
# (Phase 0c) should be on record by now. WARN-only this release: hard-gating
# waits for field calibration confidence in the estimator. (The FAST PATH and
# hand-driven re-entries reuse the workdir, so an earlier run's ack carries.)
unless RunState.load(WORK)['cost_estimate_acknowledged']
  line 'WARN: no scope/cost sign-off in run-state (cost_estimate_acknowledged missing) — ' \
       'estimate-cost.rb never ran or was not acknowledged (PLAN-v3 PR-3). WARN-only this ' \
       'release; this becomes a gate once the estimator is field-calibrated.'
end
dm_spec_path = File.join(WORK, 'dm-spec.json')
dm_ids_path = File.join(WORK, 'dm-ids.json')
if reuse_dm_id
  # REUSE: no build, no POST. Read the existing DM back into the same id-map
  # shape post-and-readback.rb emits (incl. per-element columnLabels — Phase 4's
  # master derivation resolves against them).
  $LOAD_PATH.unshift File.expand_path('lib', HERE)
  require 'sigma_rest'
  dm_spec_rb = begin
    Sigma.request(:get, "/v2/dataModels/#{reuse_dm_id}/spec")
  rescue StandardError => e
    abort "FATAL: could not read back reused DM #{reuse_dm_id} (#{e.message.lines.first&.strip}) — " \
          'the readback supplies the element ids for placeholder substitution. Check the id and the ' \
          'SIGMA_* credentials (ruby scripts/setup.rb).'
  end
  abort "FATAL: could not read back reused DM #{reuse_dm_id} spec" unless dm_spec_rb.is_a?(Hash) && dm_spec_rb['pages']
  # list_entries: /columns paginates (default page 50) — the reuse case that
  # motivated the ref gate is a 599-column DM, so a first-page read starves
  # the columnLabels map and every later-page ref false-fails resolution.
  col_entries = (Sigma.list_entries("/v2/dataModels/#{reuse_dm_id}/columns") rescue [])
  labels_by_el = Hash.new { |h, k| h[k] = [] }
  col_entries.each { |c| labels_by_el[c['elementId']] << c['label'] if c['elementId'] && c['label'] }
  dm_ids = {
    'dataModelId' => reuse_dm_id,
    'pages' => (dm_spec_rb['pages'] || []).map do |p|
      { 'id' => p['id'], 'name' => p['name'],
        'elements' => (p['elements'] || []).map do |e|
          el = { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'] }
          if e['kind'] == 'control'
            el['controlId'] = e['controlId']
            el['controlType'] = e['controlType']
          end
          el['columnLabels'] = labels_by_el[e['id']] if labels_by_el.key?(e['id'])
          el
        end }
    end
  }
  File.write(dm_ids_path, JSON.pretty_generate(dm_ids))
  dm_id = reuse_dm_id
  dm_els = dm_ids['pages'].flat_map { |p| p['elements'] }
  # The fact is the WIDEST non-dim element. Exclude both "<X> Dim" and "Dim <X>"
  # (so a date/time dim like "Dim Time" can't be picked) and tie-break by column
  # count, not list order.
  dim_re = /(^Dim\b| Dim$)/i
  fact = dm_els.reject { |e| e['name'] =~ dim_re }.max_by { |e| (e['columnLabels'] || []).size } ||
         dm_els.find { |e| e['name'] !~ dim_re } || dm_els.first
  fact_eid = fact['id']
  line "REUSED dataModelId = #{dm_id}  (fact element '#{fact['name']}' = #{fact_eid}, name-heuristic pick)"
elsif mechanical
  # The converter output IS the DM spec (schemaVersion:1 already set). Apply the
  # mechanical fixup (resolve raw-table-name prefixes + GUID sibling refs the
  # converter left unresolved) then stamp the human-supplied folderId. No agent
  # authoring.
  dm = conv['model'] # already fixed up in Phase 1 (prefixes/GUIDs resolved, bad calcs dropped)
  dm['name'] = wb_name if dm['name'].to_s.empty?
  dm['name'] = "#{opts[:name]} #{dm['name']}" if opts[:name]
  # Phantom-column filter (needs Phase 2's live warehouse columns): Tableau
  # virtual-connection datasources flatten dim columns into the fact and emit
  # base-column refs that don't exist in the real table. Drop them so the POST
  # resolves. Load the cols-<TABLE>.json files discovered in Phase 2.
  real_cols = {}
  dim_catalogs = {}
  Dir[File.join(WORK, 'cols-*.json')].each do |cf|
    cj = (JSON.parse(File.read(cf)) rescue nil)
    next unless cj && cj['columns']
    tname = File.basename(cf, '.json').sub(/^cols-/, '')
    real_cols[tname] = cj['columns'].map { |c| c['name'] }
    dim_catalogs[tname.upcase] = cj['columns']
  end
  unless real_cols.empty?
    # #700: the converter intentionally omits Tableau GUID-backed virtual-
    # connection dates because their physical identity is not present in the
    # converter output. Recover them BEFORE the phantom filter, and only when
    # the TWB date metadata, owning relation, live physical column, and
    # warehouse type all agree. --column-mapping is an explicit physical-name
    # signal, but it does not weaken any of the other evidence requirements.
    if have_twb
      date_recovery = MechanicalSpecs.recover_guid_backed_date_fields!(
        dm, File.binread(twb), real_cols, dim_catalogs,
        column_mapping: opts[:column_mapping]
      )
      date_recovery[:messages].each do |message|
        line message
        Offramp.log(WORK, kind: 'guid-date-recovery-gap', detail: message.sub(/\AGAP:\s*/, '')) \
          if message.start_with?('GAP:') && defined?(Offramp)
      end
    end
    pf = MechanicalSpecs.fixup_dm_spec(dm, real_cols, column_mapping: opts[:column_mapping])
    line "phantom-column filter: dropped #{pf[:phantom]} non-existent base column(s) using #{real_cols.size} live table catalog(s)" if pf[:phantom].to_i.positive?
    line "column-rename remap: rewired #{pf[:remapped]} base column(s) to their warehouse names (--column-mapping)" if pf[:remapped].to_i.positive?
    # Calc-field-as-physical-column guard (#685-C): a generated Custom-SQL
    # window/LOD helper can reference a Tableau CALCULATED field's sanitized
    # caption (e.g. DAYS_TO_SHIP for "Days to Ship" = DATEDIFF('day',[Order
    # Date],[Ship Date])) as though it were a physical warehouse column. Fix
    # it here, BEFORE the sql-ident gate / POST, using the SAME live catalogs
    # just loaded — never weakens that gate; only prevents feeding it something
    # it would rightly reject.
    begin
      _calc_path = File.join(WORK, 'calc-fields.json')
      if File.exist?(_calc_path)
        _calc_doc = JSON.parse(File.read(_calc_path, encoding: 'UTF-8'))
        _calcs = Array(_calc_doc['calcs'])
        cf = MechanicalSpecs.fix_calc_masquerading_as_physical!(dm, _calcs, real_cols)
        if cf[:rewritten].to_i.positive?
          line "calc-as-physical guard: substituted #{cf[:rewritten]} calculated-field reference(s) " \
               "with their own translated SQL in #{cf[:elements].uniq.join(', ')} (#685-C)"
        end
      end
    rescue StandardError => e
      line "WARN: calc-as-physical guard failed (#{e.class}: #{e.message.to_s[0, 100]}) — " \
           'a phantom physical-column reference (if any) is left for check-sql-idents to catch'
    end
    # Retain the multi-metric recipe's point-in-time columns on the fact (the
    # discriminator / rollup flag + year the source didn't plot) so the
    # real-entity filter can run instead of being skipped as a dangling ref.
    # From png-read point_in_time.
    if defined?(conv_fact) && conv_fact
      _pit = ((JSON.parse(File.read(DashboardRead.path(WORK)))['point_in_time'] rescue nil) || {})
      want = [_pit['entity_discriminator'], _pit['year_column'] || 'Year'].compact
      want << _pit['rollup_flag']['column'] if RecipeMultimetric.rollup_flag_active?(_pit)
      # The world-LOD BASE metrics too: the recipe's dual-axis trend plots the
      # region-filtered Country line Sum([Master/<metric>]) opposite each
      # synthesized World line, and an LOD-only metric is typically never
      # plotted directly — absent from the fact, the country line dangles.
      want |= world_lod_map.values if defined?(world_lod_map) && world_lod_map.is_a?(Hash)
      # G9 run-2 root cause: retain_columns! checks the name via an
      # underscore-inserting normalization ('Entity Group' -> ENTITY_GROUP), so
      # a landed column WITHOUT the underscore (ENTITYGROUP) silently failed the
      # check, the column was never retained, and the recipe guard then gutted
      # the whole point-in-time rewrite. Resolve each caption variant against
      # the live table catalog FIRST; a name retain's own check would miss is
      # passed as the landed physical column. A name matching NOTHING is loud.
      _tbl = (conv_fact.dig('source', 'path') || []).last.to_s
      _rc_names = (real_cols[_tbl] || real_cols[_tbl.upcase] || []).map(&:to_s)
      want = want.map do |nm|
        direct = nm.to_s.gsub(/[^0-9A-Za-z]+/, '_').gsub(/\A_+|_+\z/, '').upcase
        next nm if _rc_names.empty? || _rc_names.any? { |c| c.to_s.upcase == direct || c.to_s.casecmp?(nm.to_s) }
        hit = RecipeMultimetric.resolve_field(nm, _rc_names)
        if hit
          line "point-in-time retain: '#{nm}' -> landed column '#{hit}' (caption-variant resolution)"
          hit
        else
          line "WARN: point-in-time column '#{nm}' matches NO landed column on #{_tbl} — NOT retained; " \
               "the recipe's real-entity/latest-year rewrite will drop it (candidates: #{_rc_names.first(20).join(', ')})"
          nm
        end
      end
      kept = MechanicalSpecs.retain_columns!(conv_fact, want, real_cols)
      line "point-in-time retain: added #{kept} recipe column(s) (#{want.join(', ')}) to the fact" if kept.positive?
    end
  end
  # Computed-key join recovery (bead ovud): joins the converter skipped
  # ("DATE([Order Date]) = [Date Key]") are recovered mechanically — via a calc
  # key column, or via the physical "<X>_KEY" FK when the wrapped column is
  # VDS-only — so date axes resolve instead of NULL-bucketing.
  if have_twb
    MechanicalSpecs.recover_computed_key_joins!(dm, File.read(twb, encoding: 'UTF-8'), real_cols, dim_catalogs)
                   .each do |m|
      line m
      # Refused (ambiguous role attribution / no safe key) recoveries are
      # checkpoint items, not drive-by log lines: record each to offramps.jsonl
      # so the punchlist/gate context surfaces the unwired role join.
      Offramp.log(WORK, kind: 'computed-key-role-gap', detail: m.sub(/\AGAP:\s*/, '')) \
        if m.start_with?('GAP:') && defined?(Offramp)
    end
  end
  # Relationship reachability guard (bead ovud): duplicate relationship names /
  # refs through nonexistent relationships make charts NULL-bucket SILENTLY.
  # Fail loudly BEFORE the POST.
  viols = MechanicalSpecs.relationship_reachability_violations(dm)
  if viols.any?
    puts
    puts '==================== RELATIONSHIP GUARD STOP ===================='
    viols.each { |v| puts "  - #{v}" }
    puts 'Every cross-element ref must resolve through a uniquely-named,'
    puts 'existing relationship ([Base/REL_NAME/Field]) or charts grouped'
    puts 'through it silently NULL-bucket. Fix the converter output / report'
    puts 'this as a converter bug — do NOT proceed to the POST.'
    puts '================================================================='
    abort 'FATAL: relationship reachability guard failed'
  end
  # Formula-normalize hook (sibling workstream): case-fix converter-emitted
  # function names on the mechanical DM spec before validate/POST.
  normalize_formulas!(dm, 'dm-spec')
else
  dm = Specs.dm_spec
  dm['name'] = "#{opts[:name]} #{dm['name'] || wb_name}".strip if opts[:name]
end
# Join-cardinality ledger (PR-4): one entry per federated .twb join + per
# synthesized Coalesce/Lookup in the DM spec, each carrying the "right unique
# on keys" grain assumption at status "unprobed". Sigma's Lookup() returns one
# ARBITRARY match per key — an unproven target grain silently undercounts
# every aggregate over the looked-up column (zero errors anywhere). The final
# gate (assert-phase6-ran.rb gate 16, exit 23) refuses GREEN until every entry
# is probed unique or resolved; an EMPTY ledger is still written — its
# presence is the gate's evidence the derivation ran.
#
# Runs on BOTH paths (live-e2e defect): --reuse-dm used to skip this block
# entirely, so join-plan.json was never written — and gate 16's belt-and-braces
# only greps dm-spec.json for Lookup( (absent on reuse), so a reused DM over a
# federated source silently bypassed the gate. On reuse the spec scanned is the
# LIVE DM readback (dm_spec_rb — it carries the synthesized Lookup() formulas);
# the .twb still supplies the federated joins. Same <workdir>/join-plan.json
# either way, so the gate sees it unchanged.
begin
  require_relative 'lib/join_plan'
  _jp_spec = reuse_dm_id ? dm_spec_rb : dm
  # FAST PATH live defect (Twin-B e2e 2026-07-19): have_twb is assigned inside
  # the full-pipeline block only, so the FAST PATH (--reuse-dm + --wb-spec)
  # left it nil even though workbook-content.twb sat in the workdir — the .twb
  # LEFT JOIN never landed in the ledger, gate 16 passed on an EMPTY ledger,
  # and the DM shipped without the join (every tile diverged 3-23x, fan-out
  # trap). Read the .twb straight from the workdir on EVERY route; db/schema
  # fall back to the explicit flags (nil-safe: an uncompleted right_table
  # keeps the probe erroring and the gate blocking — the safe direction).
  _jp_twb = have_twb ? File.read(twb, encoding: 'UTF-8') : JoinPlan.workdir_twb(WORK)
  _jp = JoinPlan.derive(_jp_spec, _jp_twb,
                        db: db || opts[:db], schema: schema || opts[:schema])
  JoinPlan.write(File.join(WORK, 'join-plan.json'), _jp)
  _jp_src = reuse_dm_id ? 'reuse path: .twb + live DM readback' : 'dm-spec + .twb'
  if _jp.any?
    line "join-plan ledger (#{_jp_src}): #{_jp.size} join/Lookup grain assumption(s) recorded (join-plan.json, status unprobed)"
    line "  PROVE them before --finalize:  ruby #{File.join(HERE, 'probe-join-keys.rb')} --workdir #{WORK} --connection-id #{opts[:conn]}"
  else
    line "join-plan ledger (#{_jp_src}): empty (no federated joins / Lookup synthesis) — join-plan.json written as gate evidence"
  end
rescue StandardError => e
  line "WARN: join-plan ledger derivation failed (#{e.class}: #{e.message.to_s[0, 80]}) — " \
       'gate 16 will fail if the DM carries Lookup() synthesis; derive by hand via lib/join_plan.rb'
end
unless reuse_dm_id
  dm['folderId'] = opts[:folder] if opts[:folder]
  # Unresolved-warehouse-table GATE (#685-A part 2): remap_from_manifest! and
  # fixup_dm_spec have both had their chance by now. An element STILL carrying
  # the converter's "UNKNOWN" placeholder name/path means nothing could
  # attribute it to a real warehouse table (no landing manifest, --skip-
  # extract-landing was waived, or 0% column-caption overlap with any manifest
  # entry) — POSTing it 404s late and cryptically ("Source not found:
  # warehouse table '<schema>.UNKNOWN'"). Fail loud and NAMED here instead.
  unresolved = MechanicalSpecs.unresolved_warehouse_elements(dm)
  if unresolved.any?
    puts
    puts '========== UNRESOLVED WAREHOUSE TABLE (exit 21) =========='
    puts "The mechanical converter could not resolve a real warehouse table for #{unresolved.size} " \
         'element(s) below — every attribution chance (extract-landing manifest remap, phantom-column'
    puts 'filter) has already run. POSTing this DM would fail LATE with an unnamed "Source not found"'
    puts 'error instead. Offending element(s):'
    unresolved.each { |e| puts "  - #{e['name'].inspect}  path=#{(e.dig('source', 'path') || []).inspect}" }
    puts
    puts 'Likely causes, in order of likelihood:'
    puts '  * an embedded-extract datasource that never got landed — check for a landing-manifest.json'
    puts '    in this workdir (refs/extract-landing.md); land it (scripts/land-extracts.py), then re-run;'
    puts '  * --skip-extract-landing was used and the DM table paths were knowingly left on you;'
    puts "  * the manifest could not attribute this element by column-caption overlap (0% overlap) —"
    puts '    repoint it by hand with --table-mapping.'
    puts '==========================================================='
    exit 21
  end
  File.write(dm_spec_path, JSON.pretty_generate(dm))
  # In mechanical mode validate-spec.rb is advisory only: it flags cross-element
  # sibling refs that Sigma actually resolves via relationships (documented
  # false-negative class — see project CLAUDE.md). The authoritative gate is the
  # live POST + readback column-type guard below (post-and-readback exits 2 on any
  # error-typed column). For hand-authored Specs, keep validation hard.
  _, dvst = run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'datamodel', dm_spec_path],
                 allow_fail: mechanical)
  line 'DM validate-spec flagged issues (advisory in mechanical mode — live POST is the gate)' if mechanical && !dvst.success?
  # W2.2 / v5.6-P0.4 wiring: typed-literal lint over the generated DM spec.
  # The 2026-07-13 field class: a NUMBER column compared to a quoted string
  # (If([Year] = "2014", …)) compiles clean in Sigma and renders NULL for every
  # affected measure — 6 of 9 charts blanked with zero errors. The lint
  # (lib/typed_literal_lint.rb) existed but was wired to NOTHING. It runs here
  # whenever a warehouse TYPE source exists in the workdir: the cols-<TABLE>.json
  # catalogs Phase 2 discovered (name+type per column), aliased through the
  # landing manifest's sf_table FQN + orig→landed caption map when extracts were
  # landed. ADVISORY (WARN, never fatal): the lint is conservative by design, but
  # corpus safety says a new lint must not block existing migrations — gate 13's
  # tile-emptiness measurement remains the hard backstop. Findings also land in
  # <workdir>/typed-literal-findings.json for the report.
  begin
    _tl_types = {}
    Dir[File.join(WORK, 'cols-*.json')].each do |cf|
      cj = (JSON.parse(File.read(cf)) rescue nil)
      next unless cj.is_a?(Hash) && cj['columns'].is_a?(Array)
      t = File.basename(cf, '.json').sub(/^cols-/, '')
      _tl_types[t] = cj['columns'].each_with_object({}) do |c, h|
        h[c['name'].to_s] = c['type'].to_s if c.is_a?(Hash) && c['name']
      end
    end
    _tl_mani = Dir[File.join(WORK, '*landing-manifest*.json')].first
    if _tl_mani
      _tl_rows = (JSON.parse(File.read(_tl_mani)) rescue [])
      _tl_rows = _tl_rows['tables'] if _tl_rows.is_a?(Hash) && _tl_rows['tables'].is_a?(Array)
      Array(_tl_rows).each do |r|
        next unless r.is_a?(Hash) && r['sf_table']
        _tl_last = r['sf_table'].to_s.split('.').last.to_s
        base = _tl_types[_tl_last] || _tl_types[_tl_last.upcase]
        next unless base
        fq = (_tl_types[r['sf_table'].to_s] ||= {})
        base.each { |k, v| fq[k] = v unless fq.key?(k) }
        # Alias the ORIGINAL captions onto their landed columns' types so a
        # formula ref written against the Tableau caption still resolves.
        (r['columns'].is_a?(Hash) ? r['columns'] : {}).each do |orig, landed|
          v = base[landed.to_s]
          fq[orig.to_s] = v if v && !fq.key?(orig.to_s)
        end
      end
    end
    if _tl_types.empty? || _tl_types.values.all?(&:empty?)
      line 'typed-literal lint: SKIPPED — no warehouse type source in the workdir (no cols-*.json catalogs)'
    else
      _tl_types_path = File.join(WORK, 'typed-literal-types.json')
      File.write(_tl_types_path, JSON.pretty_generate(_tl_types))
      _tl_out = File.join(WORK, 'typed-literal-findings.json')
      _, _tl_st = run!(['ruby', File.join(HERE, 'lint-typed-literals.rb'),
                        '--spec', dm_spec_path, '--types', _tl_types_path, '--out', _tl_out],
                       allow_fail: true)
      if _tl_st.exitstatus == 3
        _tl_n = ((JSON.parse(File.read(_tl_out)).length rescue nil) || '?')
        line "WARN: typed-literal lint: #{_tl_n} finding(s) (printed above; #{_tl_out}) — these comparisons"
        line '      compile clean and render NULL (the 2026-07-13 blanking class). Advisory here; fix the'
        line '      formulas per the printed suggestions BEFORE gate 13 fails on the empty tiles they cause.'
      elsif _tl_st.success?
        line "typed-literal lint: clean (0 findings across #{_tl_types.size} typed table(s))"
      else
        line "WARN: typed-literal lint could not run (exit #{_tl_st.exitstatus}) — advisory, continuing"
      end
    end
  rescue StandardError => e
    line "WARN: typed-literal lint wiring failed (#{e.class}: #{e.message.to_s[0, 80]}) — advisory, continuing"
  end
  # 🚧 Custom-SQL identifier GATE (wave-2 §6.5 — was a printed hint, and the
  # hint would have caught the field failure). Two classes it stops BEFORE the
  # POST: (a) hackathon F2 — CUSTOMER_SFDC_ID unquoted while the live column
  # is "Customer SFDC ID"; (b) the object-model wrong-FROM class — LOD/Top-N/
  # window helper SQL built off a mis-elected fact selects columns its FROM
  # table does not own (mass "invalid identifier"/"Dependency not found" only
  # at POST). The catalog fetch uses the same creds the POST below needs, so
  # it runs inline: reuse the Phase-2 cols-<TABLE>.json catalogs when present,
  # fetch columns-<TABLE>.json via discover-columns.rb otherwise. Bounded by
  # the false-trip budget: a table whose catalog CANNOT be fetched degrades to
  # the old printed hint (WARN, identifiers unverified) — only VERIFIED
  # unknown identifiers stop the run (exit 20). Waive with
  # --skip-sql-ident-gate REASON (recorded, budget-counted like siblings).
  begin
    require_relative 'lib/sql_ident_check'
    _sql_tables = SqlIdentCheck.referenced_tables(JSON.parse(File.read(dm_spec_path, encoding: 'UTF-8')))
  rescue StandardError => e
    _sql_tables = []
    line "WARN: sql-ident gate unavailable (#{e.class}: #{e.message.to_s[0, 100]}) — identifiers unverified"
  end
  if _sql_tables.any?
    line "DM spec contains Custom SQL element(s) referencing: #{_sql_tables.join(', ')}"
    if opts[:skip_sql_ident_gate]
      line "[SKIP] Custom-SQL identifier gate WAIVED (#{opts[:skip_sql_ident_gate]}) — name this in your report."
      # PR-14: every honored --skip-* leaves a record on the off-ramp trail.
      Offramp.log(WORK, kind: 'skip-flag-waived', reason: opts[:skip_sql_ident_gate],
                  detail: '--skip-sql-ident-gate')
    else
      _si_cols = {}      # TABLE => catalog path (reused or freshly fetched)
      _si_unfetched = {} # TABLE => why the catalog is unavailable
      _sql_tables.each do |t|
        reuse = [File.join(WORK, "columns-#{t}.json"), File.join(WORK, "cols-#{t}.json"),
                 File.join(WORK, "cols-#{t.upcase}.json")].find { |p| File.exist?(p) }
        next _si_cols[t] = reuse if reuse
        unless opts[:conn] && db && schema
          _si_unfetched[t] = 'no connection/db/schema context to fetch its catalog'
          next
        end
        cpath = File.join(WORK, "columns-#{t}.json")
        _, _cst = run!(['ruby', File.join(HERE, 'discover-columns.rb'), '--connection-id', opts[:conn].to_s,
                        '--table-path', "#{db}.#{schema}.#{t}", '--out', cpath], allow_fail: true)
        if _cst.success? && File.exist?(cpath)
          _si_cols[t] = cpath
        else
          _si_unfetched[t] = "catalog fetch failed (discover-columns exit #{_cst.exitstatus})"
        end
      end
      _si_unfetched.each do |t, why|
        line "WARN: sql-ident gate cannot verify #{t} — #{why}; its identifiers go to POST unverified."
        line '      If the POST fails with a SQL compile error, fetch + preflight by hand:'
        line "        ruby #{File.join(HERE, 'discover-columns.rb')} --connection-id #{opts[:conn] || '<connection-id>'} --table-path #{db || '<DB>'}.#{schema || '<SCHEMA>'}.#{t} --out #{File.join(WORK, "columns-#{t}.json")}"
        line "        ruby #{File.join(HERE, 'check-sql-idents.rb')} --dm-spec #{dm_spec_path} --columns #{t}=#{File.join(WORK, "columns-#{t}.json")}"
      end
      if _si_cols.any?
        _, _si_st = run!(['ruby', File.join(HERE, 'check-sql-idents.rb'), '--dm-spec', dm_spec_path] +
                         _si_cols.flat_map { |t, p| ['--columns', "#{t}=#{p}"] }, allow_fail: true)
        if _si_st.exitstatus == 1
          puts <<~MSG

            ==================== SQL IDENTIFIER GATE (exit 20) ====================
            check-sql-idents resolved the Custom-SQL statements against the LIVE
            warehouse catalog and found identifiers that do not exist on their
            FROM table (per-element fix list printed above). POSTing now would
            fail with Snowflake "invalid identifier" / Sigma "Dependency not
            found" — one opaque error at a time. The usual causes:
              * wrong-FROM helper SQL from a mis-elected fact/base table — check
                the announced "Elected fact" warning; if it names the wrong
                table, re-run with --fact-table NAME (refs/troubleshooting.md,
                "Dependency not found en masse" row)#{(defined?(mcp_build) && mcp_build.nil?) ? "\n    NOTE: this run used the HOSTED converter, which cannot take the\n    --fact-table override — set TABLEAU_MCP_BUILD to a local build\n    first, or the re-run's election is unchanged" : ''}
              * an unquoted spaced/mixed-case Snowflake column — double-quote it
                in the element's source.statement
            Fix the statements in #{dm_spec_path} (or re-run with the corrected
            election), then re-run. Escape hatch (recorded as a quality waiver):
            --skip-sql-ident-gate "<reason>".
            =======================================================================
          MSG
          exit 20
        elsif _si_st.success?
          line "sql-ident gate: clean — Custom-SQL identifiers resolve against #{_si_cols.size} catalog(s)" +
               (_si_unfetched.any? ? " (#{_si_unfetched.size} table(s) unverifiable, see WARNs above)" : '')
        else
          line "WARN: check-sql-idents could not run (exit #{_si_st.exitstatus}) — identifiers unverified; continuing"
        end
      end
    end
  end
  sigma_run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
              '--spec', dm_spec_path, '--out', dm_ids_path, '--workdir', WORK])
  dm_ids = JSON.parse(File.read(dm_ids_path))
  dm_id = dm_ids['dataModelId']
  dm_els = dm_ids['pages'].flat_map { |p| p['elements'] }
  if mechanical
    # The master must source the SAME chart-ready element pick_fact chose (the
    # derived "<Fact> View" when present). Match it into the readback by name.
    cf = MechanicalSpecs.pick_fact(conv['model'], prefer_table: (defined?(prefer_fact_table) ? prefer_fact_table : nil))
    cf_name = cf && (cf['name'] || MechanicalSpecs.elem_name(cf))
    # Fallback (when the exact name match misses): the fact is the WIDEST non-dim
    # element — never a narrow date/time dim. Match pick_fact's dim test (both
    # "<X> Dim" and "Dim <X>") and tie-break by column count, not list order, so
    # "Dim Time" can't win just by appearing first.
    fact = dm_els.find { |e| e['name'] == cf_name } ||
           dm_els.reject { |e| MechanicalSpecs.dim_like?(e['name']) }.max_by { |e| (e['columnLabels'] || []).size } ||
           dm_els.max_by { |e| (e['columnLabels'] || []).size } || dm_els.first
  else
    fact = dm_els.reject { |e| MechanicalSpecs.dim_like?(e['name']) }.max_by { |e| (e['columnLabels'] || []).size } ||
           dm_els.find { |e| !MechanicalSpecs.dim_like?(e['name']) } || dm_els.first
  end
  fact_eid = fact['id']
  line "dataModelId = #{dm_id}  (fact element '#{fact['name']}' = #{fact_eid})"
end
mark('phase3-dm')

# ---------------------------------------------------------------------------
# Phase 4 — Build + POST the workbook.
# ---------------------------------------------------------------------------
hdr(4, 'Build workbook')
wb_spec_path = File.join(WORK, 'wb-spec.json')
display_wb_name = opts[:name] ? "#{opts[:name]} #{wb_name}" : wb_name
layout_xml = nil
if mechanical
  # 1) Derive the master-map DETERMINISTICALLY from the converter fact element,
  #    using the AUTHORITATIVE readback element name for the [fact/Col] formulas,
  #    AND the readback element's REAL column labels (the suffixed display names
  #    Sigma assigns to joined-dim columns, e.g. "Customer Id (CUSTOMER_DIM)") so
  #    the [fact/Col] formulas resolve for virtual-connection (denormalized) DMs.
  # Thread the fact hint (dominant dashboard datasource) so the master-map is
  # derived from the SAME element the readback fact-selection (line ~2024/2031)
  # picked. Without this, pick_fact defaults to the widest element (an unused
  # secondary can be wider than the plotted table); derive_master then emits the
  # secondary's columns under the MAIN fact's name → orphan [MainFact/SecondaryCol]
  # refs that fail the workbook POST ("Dependency not found"). Mirrors line 2024.
  conv_fact = MechanicalSpecs.pick_fact(conv['model'], prefer_table: (defined?(prefer_fact_table) ? prefer_fact_table : nil))
  abort 'FATAL: mechanical path could not identify a fact element in the converter output' unless conv_fact
  conv_base = MechanicalSpecs.base_of(conv['model'], conv_fact)
  real_labels = fact['columnLabels'] # from post-and-readback /columns (may be nil)
  derived = MechanicalSpecs.derive_master(conv_fact, fact['name'], conv_base, real_labels, conv['model'])
  master_columns = derived['master_columns']
  mmap = derived['mmap']
  # Human-supplied master-calc overrides (--master-col): appended verbatim so a
  # chart ref like [master/Delivery Speed Tier] resolves on the next run.
  (opts[:master_cols] || []).each do |(nm, fx)|
    id = "m-#{nm.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')}"
    master_columns.reject! { |c| c['name'].casecmp?(nm) }
    # v5.4: slug collision guard — two DIFFERENT names can slug identically
    # (an alias like "NUM_ENROLLED" vs the auto-derived "Num Enrolled"),
    # and duplicate column ids fail the POST. Suffix until unique.
    base_id = id
    n = 2
    while master_columns.any? { |c| c['id'] == id }
      id = "#{base_id}-#{n}"
      n += 1
    end
    master_columns << { 'id' => id, 'name' => nm, 'formula' => fx }
    # Register the override in the header->column regex map too (same pattern
    # shape as derive_master's entries) so chart dim headers AND shared-filter
    # captions resolve to it — without this, an --master-col like 'Order Date'
    # still left the shared Order-Date filter unmapped (no auto-control, charts
    # silently unfiltered vs the source view).
    mmap["(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of )?#{Regexp.escape(nm)}$"] =
      { 'id' => id, 'name' => nm }
    line "master-col override: '#{nm}' = #{fx[0, 80]}"
  end
  # A Tableau object-model dashboard can mix logical-table grains on one page
  # (for example child-fact Absence Records beside parent Employees). Build a
  # registry of the converter's grain-correct DM sources and teach the CSV
  # header mapper that Tableau's generated "Count of <logical table>" means a
  # Count() over that table's relationship key AT THAT TABLE'S GRAIN. The chart
  # router below consumes the same registry and repoints only the affected
  # worksheets to a hidden sub-master.
  grain_plan = MechanicalSpecs.object_grain_plan(conv['model'], default_element_name: fact['name'])
  grain_plan_path = File.join(WORK, 'grain-plan.json')
  if grain_plan
    grain_plan['datasources'].each do |grain|
      Array(grain['columns']).each do |column_name|
        next if mmap.values.any? { |entry| entry['name'].to_s.casecmp?(column_name.to_s) }
        synthetic_id = "m-grain-#{MechanicalSpecs.slug(column_name)}"
        mmap[MechanicalSpecs.header_regex(column_name)] = {
          'id' => synthetic_id,
          'name' => column_name,
          'grain_element' => grain['caption']
        }
      end
      next if grain['count_key'].to_s.empty?
      key_entry = mmap.values.find { |entry| entry['name'].to_s.casecmp?(grain['count_key'].to_s) }
      next unless key_entry
      table = Regexp.escape(grain['table'].to_s)
      display = Regexp.escape(MechanicalSpecs.display_name(grain['table'].to_s))
      pattern = "(?i)^Count of (?:#{table}|#{display})(?:\\s*\\([^)]*#{table}\\))?$"
      mmap[pattern] = key_entry.merge('grain_element' => grain['caption'], 'generated_table_count' => true)
      grain['count_pattern'] = pattern
    end
    File.write(grain_plan_path, JSON.pretty_generate(grain_plan))
    line "grain plan: #{grain_plan['datasources'].size} logical table source(s); " \
         "#{grain_plan['datasources'].count { |grain| grain['count_pattern'] }} generated table-count mapping(s)"
  end
  mmap_path = File.join(WORK, 'master-map.json')
  File.write(mmap_path, JSON.pretty_generate(mmap))
  line "master-map: #{master_columns.size} master column(s) (fact element '#{fact['name']}', #{real_labels ? real_labels.size : 0} readback labels)"

  # DM metrics referenceable on the master (own on the fact element + inherited via
  # source.elementId): a chart/KPI measure whose inline aggregate matches one binds
  # to a governed [Metrics/<name>] ref instead of re-deriving inline (formula
  # equivalence; ratios/LODs/table-calcs/no-match stay inline — byte-identical).
  metrics_path = File.join(WORK, 'metrics.json')
  begin
    els_by_id = MechanicalSpecs.all_elements(conv['model']).each_with_object({}) { |e, h| h[e['id']] = e }
    wb_metrics = MetricBinding.available_metrics(conv_fact['id'], els_by_id)
    metric_exclusions = MetricBinding.collision_exclusions(conv_fact['id'], els_by_id)
  rescue StandardError => e
    line "metric-binding: could not resolve DM metrics (#{e.class}: #{e.message}) — measures stay inline"
    wb_metrics = []
    metric_exclusions = []
  end
  # F4 (wave-2 measurement, field-caught): a DM element POSTing a governed metric
  # NAMED like one of its own columns is accepted by the API, but the live
  # readback then omits that element's metrics WHOLESALE — so every
  # [Metrics/<name>] ref bound to one deterministically fails the pre-POST
  # workbook ref gate (exit 4) on a cold run. The binder withholds ALL metrics of
  # a collision-shaped element (structural same-element exact-name detection);
  # the affected measures re-derive INLINE — the remedy shape validated live. The
  # ref gate stays fail-closed; the fallback is surfaced here + ledgered, never
  # silent.
  metric_exclusions.each do |x|
    shown = x['collisions'].first(3).join(', ')
    shown += ", … +#{x['collisions'].size - 3} more" if x['collisions'].size > 3
    line "metric-binding: NOTE — DM element '#{x['element_name']}' carries #{x['collisions'].size} column/metric name collision(s) (#{shown}); " \
         "its #{x['excluded_metrics'].size} metric(s) stay INLINE in the workbook (live readback drops metrics on this shape — F4)"
    Offramp.decision(WORK, kind: 'metric-collision-inline',
                     question: "DM element '#{x['element_name']}' POSTs #{x['collisions'].size} column/metric name collision(s) (#{shown}) — " \
                               'its governed metrics are not provably referenceable after readback (F4 collision shape)',
                     answer: "#{x['excluded_metrics'].size} metric(s) fall back to inline aggregate formulas (no [Metrics/…] refs to this element)",
                     decided_by: 'unattended-flag')
  end
  File.write(metrics_path, JSON.pretty_generate(wb_metrics))
  line "metric-binding: #{wb_metrics.size} referenceable DM metric(s) for [Metrics/<name>] refs" if wb_metrics.any?

  # 1.5) Detect Tableau dashboard actions from the .twb BEFORE the chart build.
  #      Detection (build-postpublish-guide.rb's extract_* methods) only needs
  #      the .twb, which has been sitting in WORK since Phase 1 — no need to
  #      wait for wb-ids.json/--sigma-url, those are optional POST-PUBLISH
  #      enrichment the LATE guide invocation (its two advisory print sites,
  #      unchanged) applies after publish. Handing the raw detected-entries
  #      array to build-charts-from-signals.rb via --detected-actions is the
  #      BRIDGE between detection and emission; this step does not itself
  #      auto-wire anything (no nav-action/parameter-action emission here —
  #      that is a follow-up task). --detect-only never writes
  #      action-ledger.json — only the late guide invocation owns that
  #      CONTRACTUAL path, so an early run here can never be mistaken by gate
  #      11 for the authoritative ledger.
  #
  #      NOT allow_fail. Detection feeding emission means a crashed detection and a
  #      zero-action workbook produce the same downstream artifact — the exact
  #      silent no-op this workstream has now hit four times. build-postpublish-guide.rb
  #      aborts on a malformed parse and writes no file, so reaching here with a
  #      non-zero status means something worse; fail the run.
  detected_actions_path = File.join(WORK, 'detected-actions.json')
  if have_twb
    run!(['ruby', File.join(HERE, 'build-postpublish-guide.rb'),
          '--twb', twb, '--detect-only', detected_actions_path])
  end

  # 2) Build the chart-element specs from the parsed zones + view CSVs + map.
  #    ONE SIGMA PAGE PER TABLEAU DASHBOARD (bead ptrt) — a fat workbook's 4
  #    dashboards become 4 laid-out pages, each with its own banded layout.
  charts_path = File.join(WORK, 'chart-specs.json')
  build_cmd = ['ruby', File.join(HERE, 'build-charts-from-signals.rb'),
               '--tableau-dir', WORK, '--layout', layout_json,
               '--master-map', mmap_path, '--master-element-id', 'master',
               '--metrics', metrics_path,
               '--page-per-dashboard',
               '--out', charts_path,
               '--coverage-out', File.join(WORK, 'coverage.json')]
  build_cmd += ['--meta', layout_json.sub(/\.json$/, '-meta.json')] if File.exist?(layout_json.sub(/\.json$/, '-meta.json'))
  build_cmd += ['--auto-controls'] if File.exist?(layout_json.sub(/\.json$/, '-meta.json'))
  build_cmd += ['--detected-actions', detected_actions_path] if File.exist?(detected_actions_path)
  build_cmd += ['--grain-plan', grain_plan_path] if grain_plan && File.exist?(grain_plan_path)
  # Per-dashboard scope (defensive — the layout is already pre-scoped, so a single
  # dashboard yields exactly one page; passing the flags keeps a standalone build
  # honest if it's ever handed a full layout).
  build_cmd += DASH_SCOPE if scoped?
  run!(build_cmd, allow_fail: true)
  raw_charts = (JSON.parse(File.read(charts_path)) rescue [])
  chart_pages = raw_charts.is_a?(Hash) ? (raw_charts['pages'] || []) : nil
  data_elements = raw_charts.is_a?(Hash) ? (raw_charts['data_elements'] || []) : []
  chart_elements = chart_pages ? chart_pages.flat_map { |p| p['elements'] || [] } : raw_charts
  # PR-18: integer-coded dimension DECODE columns build-charts routed onto the
  # MASTER (a master-rooted list control's Text() decode must live on the master
  # so the filter propagates to every chart sourcing from it). Inject them into
  # master_columns now — before the ref-label repair below picks up the registry.
  # Empty when no integer-dim control was detected (additive / byte-identical).
  Array(raw_charts.is_a?(Hash) ? raw_charts['master_decode_columns'] : nil).each do |dc|
    next unless dc.is_a?(Hash) && dc['id'] && dc['formula']
    next if master_columns.any? { |c| c['id'] == dc['id'] }
    master_columns << dc
    line "integer-dim decode: added master column '#{dc['name']}' (#{dc['formula']}) — list control filters STRING values (raw numeric list-filter targets are silently stripped by Sigma)"
  end
  # A Tableau calculated filter's formula wins over a same-named DM physical
  # passthrough. The builder emits only confidently translated, fully resolved
  # replacements; preserving the passthrough can make a saved selection blank
  # every dashboard tile when that physical column is NULL.
  Array(raw_charts.is_a?(Hash) ? raw_charts['master_calc_columns'] : nil).each do |cc|
    next unless cc.is_a?(Hash) && cc['id'] && cc['name'] && cc['formula']
    existing = master_columns.find { |column| column['id'] == cc['id'] } ||
               master_columns.find { |column| column['name'].to_s.casecmp?(cc['name'].to_s) }
    if existing
      existing['formula'] = cc['formula']
    else
      master_columns << cc
    end
    line "calculated-filter fidelity: master '#{cc['name']}' uses the translated Tableau formula, not a same-named passthrough"
  end
  # Dim-grain helper placeholder resolution: build-charts runs before it knows
  # the live DM element ids, so grain helpers carry source.elementId =
  # "__DM_ELEMENT__:<name>". Resolve against the readback (dm_els) NOW — an
  # unresolvable grain element means the two-stage chart would silently misbind,
  # so fail loudly (same contract as the relationship guard).
  data_elements.each do |de|
    ph = de.dig('source', 'elementId').to_s
    next unless ph.start_with?('__DM_ELEMENT__:')
    want = ph.split(':', 2).last
    hit = dm_els.find { |e| e['name'].to_s.strip.casecmp?(want) }
    # v5.0 hardening (multi-DS sub-masters ONLY): DM element names don't
    # always equal plan captions ("Workbook Sum Dir Bias by Bilevel Preset" vs
    # plan "Sum Dir Bias by BiLevel Preset" — prefix + case). Fall back to
    # normalized matching: exact normalized, then UNIQUE containment with a
    # length floor (the shorter normalized name must be ≥8 chars and ≥50% of
    # the longer — a short generic element name must never absorb an
    # unrelated caption). Grain helpers keep the strict exact contract (their
    # names are converter-derived and DO match; fuzzy there is pure risk).
    if hit.nil? && de['id'].to_s.start_with?('submaster-')
      nrm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
      wantn = nrm.call(want)
      cands = dm_els.select { |e| nrm.call(e['name']) == wantn }
      if cands.empty?
        cands = dm_els.select do |e|
          en = nrm.call(e['name'])
          shorter, longer = [en, wantn].sort_by(&:length)
          shorter.length >= 8 && shorter.length >= (longer.length * 0.5).ceil && longer.include?(shorter)
        end
      end
      abort "FATAL: sub-master '#{de['name']}' needs DM element '#{want}' but the match is AMBIGUOUS " \
            "(#{cands.map { |e| e['name'] }.join(' | ')}) — rename to disambiguate" if cands.size > 1
      hit = cands.first
    end
    abort "FATAL: helper '#{de['name']}' needs DM element '#{want}' but the posted data model has no element " \
          "by that name (have: #{dm_els.map { |e| e['name'] }.join(', ')})." +
          (de['id'].to_s.start_with?('submaster-') ?
            ' This sub-master was auto-created by multi-DS routing — either add the datasource to the DM, ' \
            'or re-run with SIGMA_MULTI_DS_ROUTING=off to restore the warn-and-ship behavior.' : '') unless hit
    de['source'] = { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => hit['id'] }
    # A fuzzy match means the helper's passthrough formulas were authored with
    # the REQUESTED name prefix ([<want>/Col]) — rewrite to the live element's
    # real name in lock-step or every column errors on POST.
    real = hit['name'].to_s.strip
    if real != want && de['columns'].is_a?(Array)
      de['columns'].each do |c|
        c['formula'] = c['formula'].gsub("[#{want}/", "[#{real}/") if c['formula'].is_a?(String)
      end
    end
    # v5.3: repair COLUMN names against the DM element's live columnLabels.
    # The builder authors refs from RAW Tableau field names ('runner_dir');
    # the DM labels them cased ('Runner Dir') — round 5 proved this pushed
    # all three field runs off the mechanical path into exit-4 hand-patching.
    # Normalized (case/punct-insensitive) match, exact rewrite, loud misses.
    labels = Array(hit['columnLabels']).map(&:to_s)
    if labels.any? && de['columns'].is_a?(Array)
      nrmc = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
      by_norm = labels.each_with_object({}) { |l, h| h[nrmc.call(l)] ||= l }
      # ambiguity is a repair hazard, not a silent choice (v5.3.1 review)
      dup_norms = labels.group_by { |l| nrmc.call(l) }.select { |_k, v| v.size > 1 }
      dup_norms.each_value do |ls|
        line "  WARN: DM labels #{ls.map(&:inspect).join(' / ')} normalize identically — " \
             'column-label repair uses the FIRST; verify refs on this helper'
      end
      fixed = 0
      missed = []
      de['columns'].each do |c|
        next unless c['formula'].is_a?(String)
        c['formula'] = c['formula'].gsub(/\[#{Regexp.escape(real)}\/([^\]]+)\]/) do
          col = Regexp.last_match(1)
          exact = labels.include?(col) ? col : by_norm[nrmc.call(col)]
          # Related columns on a derived grain view round-trip with the target
          # element suffix ("Employment Type (EMPLOYEES)"). The builder asks
          # for the unsuffixed Tableau caption. Accept ONLY a unique
          # prefix+parenthetical match; two role-played/duplicate candidates
          # remain unresolved rather than guessing.
          unless exact
            stem = nrmc.call(col)
            suffixed = labels.select do |label|
              label.match?(/\A#{Regexp.escape(col)}\s+\([^)]+\)\z/i) ||
                (nrmc.call(label).start_with?(stem) && label.include?('('))
            end
            exact = suffixed.first if suffixed.one?
          end
          if exact
            fixed += 1 if exact != col
            "[#{real}/#{exact}]"
          else
            missed << col
            "[#{real}/#{col}]"
          end
        end
      end
      line "  column-label repair: #{fixed} ref(s) re-cased to live DM labels" if fixed.positive?
      missed.uniq.each do |col|
        line "  WARN: '#{de['name']}' references [#{real}/#{col}] — no matching DM column label " \
             "(have: #{labels.join(', ')[0, 120]}); the pre-POST ref gate will name it if plotted"
      end
    end
    line "grain helper '#{de['name']}' → DM element '#{real}' (#{hit['id']})#{real == want ? '' : " [name-normalized from '#{want}']"}"
  end
  # v5.4: GLOBAL ref-label repair — the v5.3 columnLabels repair above only
  # covered grain helpers' refs to their DM source element. Chart elements
  # carry the same drift class against WORKBOOK-LOCAL elements: the builder
  # authors [Master/<raw twb token>] (physical names, twb casing) while the
  # master columns carry Sigma display labels; cross-element refs to generated
  # source elements drift the same way. Repair EVERY generated element's
  # column formulas against the live labels of every workbook-local element
  # (master + hidden data elements). Normalized match, exact rewrite, loud
  # misses; ambiguity is reported, never guessed (same contract as v5.3).
  begin
    require File.join(HERE, 'lib', 'ref_label_repair')
    registry = { 'Master' => master_columns.map { |c| c['name'].to_s } }
    data_elements.each do |de|
      next unless de['name'].is_a?(String) && de['columns'].is_a?(Array)
      registry[de['name']] = de['columns'].map { |c| c['name'].to_s }
    end
    rep = RefLabelRepair.repair!(chart_elements + data_elements, registry)
    line "ref-label repair: #{rep[:fixed]} formula ref(s) re-cased to live element labels" if rep[:fixed].positive?
    rep[:ambiguous].each { |m| line "  WARN: ref-label repair skipped #{m} — disambiguate manually" }
    rep[:misses].each do |m|
      line "  WARN: #{m} — no matching live label; the pre-POST ref gate will name it if plotted"
    end
  rescue StandardError => e
    line "WARN: global ref-label repair failed: #{e.message} — formulas left as the builder authored them"
  end
  if chart_elements.empty?
    line 'WARN: build-charts produced 0 elements (no usable view CSVs / zones); emitting an empty dashboard page'
  else
    line "build-charts: #{chart_elements.size} chart/control element(s) across #{chart_pages ? chart_pages.size : 1} page(s)" \
         "#{data_elements.any? ? " + #{data_elements.size} hidden data element(s)" : ''}"
  end

  # MIGRATION COVERAGE — one consolidated "what carried over (and what didn't)"
  # readout (bead beads-sigma-59mk; ports powerbi-to-sigma PR #177). Leads with
  # what converted; nothing is silently dropped. Non-blocking — the build's
  # control_lint + visual-verify gates already hard-gate the recoverable classes.
  coverage = CoverageGate.load(File.join(WORK, 'coverage.json'))
  if coverage
    puts
    puts '==================== MIGRATION COVERAGE ===================='
    puts "   #{CoverageGate.headline(coverage)}"
    rlines = CoverageGate.report_lines(coverage)
    (puts; puts rlines.join("\n")) unless rlines.empty?
    cov_qs = CoverageGate.questions(coverage)
    unless cov_qs.empty?
      puts
      if opts[:yes] || opts[:answers]
        puts "   #{cov_qs.size} recoverable gap(s) — proceeding (unattended); recorded as accepted degradations."
      else
        puts '-------------------- ASSISTANCE AVAILABLE --------------------'
        puts "   #{cov_qs.size} gap(s) are RECOVERABLE — ask the user whether to recover or accept each."
        puts JSON.pretty_generate('recoverable_gaps' => cov_qs)
      end
    end
    puts '==========================================================='
  end

  # JOIN-CARDINALITY RESOLUTIONS — surfaces gate-16's operator-recorded
  # explanations (beads-sigma-zjkw) for any join-plan.json entry resolved via
  # `probe-join-keys.rb --resolve <i> --how preaggregated|waived --reason
  # "<...>"`. Without this, a `preaggregated` resolution's helper element (a
  # pre-aggregated / Custom-SQL-shaped table added to the DM to fix a
  # non-unique join target) had a recorded reason that never reached any
  # customer-visible surface — confirmed root cause of a field report ("it
  # created a custom SQL aggregate table in a data model that didn't exist in
  # the Tableau data set"). Same consolidated readout as MIGRATION COVERAGE
  # above, not a stderr-only warning. Non-blocking; purely informational.
  jp_doc = JoinPlanResolutions.load(File.join(WORK, 'join-plan.json'))
  jp_resolved_lines = JoinPlanResolutions.report_lines(jp_doc)
  unless jp_resolved_lines.empty?
    puts
    puts '============== JOIN-CARDINALITY RESOLUTIONS (gate 16) =============='
    puts "   #{JoinPlanResolutions.headline(jp_doc)}"
    puts
    puts jp_resolved_lines.join("\n")
    puts '======================================================================'
  end

  # 3) Assemble the workbook spec (page-data master [+ hidden helpers] + one
  #    page per dashboard).
  spec = MechanicalSpecs.build_wb_spec(
    name: display_wb_name, dm_id: dm_id, fact_eid: fact_eid,
    master_columns: master_columns,
    chart_elements: (chart_pages && chart_pages.any? ? chart_pages : chart_elements),
    data_elements: data_elements,
    theme: (raw_charts.is_a?(Hash) ? raw_charts['theme'] : nil),
    folder_id: opts[:folder], canonical: false)
  if (theme_overrides = spec.dig('settings', 'theme', 'overrides'))
    line "theme: #{theme_overrides.keys.join(', ')} (derived from source style rules)"
  end
  # Formula-normalize hook (sibling workstream): case-fix converter-derived
  # formulas on the mechanical workbook spec before validate/POST.
  normalize_formulas!(spec, 'wb-spec')
  # Multi-metric region dashboard recipe (refs/fidelity-recipes.md): when png-read
  # declares a control with `highlight_tiles`, rewrite the mechanical spec into the
  # recipe shape — master/masterAll split + highlight color column, and (with
  # png-read `point_in_time`) latest-year + real-entity grouped Top-N measures.
  # No-op when the pattern isn't present. Tolerant: never aborts the build.
  begin
    _pr = (JSON.parse(File.read(DashboardRead.path(WORK))) rescue nil)
    if _pr && RecipeMultimetric.applicable?(_pr)
      rsum = RecipeMultimetric.apply!(spec, _pr, world_lod_map: (defined?(world_lod_map) ? world_lod_map : {}),
                                                 yoy_map: (defined?(yoy_map) ? yoy_map : {}))
      if rsum[:applied]
        line "multi-metric recipe: +#{rsum[:masters_added]} masterAll, #{rsum[:highlight_tiles]} highlight tile(s), " \
             "#{rsum[:top_tables]} point-in-time measure(s) rewritten"
      end
      rsum[:notes].each { |n| line "  recipe note: #{n}" }
    end
  rescue StandardError => e
    line "WARN: multi-metric recipe transform skipped (#{e.class}: #{e.message})"
  end
else
  spec = Specs.wb_spec(dm_id, fact_eid)
  # Agent-authored JSON path: bind the DM placeholders ("__DM_ID__" and
  # "__DM_ELEMENT__:<name>") in the workbook spec to the live readback ids now
  # that the data model is posted. A reference to a non-existent element aborts
  # loudly (same contract as the mechanical grain-helper resolver), so the manual
  # path can't silently misbind a chart source.
  spec = MechanicalSpecs.bind_manual_wb_spec(
    spec, dm_id: dm_id, fact_eid: fact_eid,
    dm_els: (defined?(dm_els) && dm_els) || []) if opts[:wb_spec]
  # Manual specs may already use the release document envelope. The
  # Tableau-specific transforms below still need a transient page assignment;
  # derive it from layout and never serialize this compatibility view.
  if spec['document'].is_a?(Hash) || spec['elements'].is_a?(Array)
    spec = WorkbookCode.legacy_view(WorkbookCode.canonicalize(spec))
  end
  spec['name'] = display_wb_name if opts[:name]
  spec['folderId'] = opts[:folder] if opts[:folder]
  layout_xml = (Specs.respond_to?(:layout_xml) ? Specs.layout_xml : nil)
end
# A control in the workbook cannot reference a control in the data model by
# merely reusing `[controlId]`: formula control scope is document-local. Bridge
# every matching Tableau parameter control through the released parameters[]
# target shape, using ONLY the post/GET readback census in dm_els.
require File.join(HERE, 'lib', 'dm_control_binding')
dm_control_bindings = DmControlBinding.bind!(
  spec, data_model_id: dm_id, data_model_elements: dm_els
)
File.write(
  File.join(WORK, 'dm-control-bindings.json'),
  JSON.pretty_generate(dm_control_bindings)
)
if dm_control_bindings[:bound].any?
  line "DM control binding: #{dm_control_bindings[:bound].size} workbook control instance(s) " \
       'target readback-confirmed data-model controls through parameters[]'
end
dm_control_bindings[:ambiguous].each do |ambiguity|
  line "WARN: workbook control '#{ambiguity['workbook_control']}' matches multiple data-model controls " \
       "(#{ambiguity['data_model_controls'].join(', ')}) — no parameters[] target emitted; disambiguate the control IDs"
end
# ---- PR-17: thin per-page master instances (default ON) ---------------------
# Final structural pass over the assembled spec — runs AFTER the multi-metric
# recipe and formula-normalize so those see the shared-master shape they were
# written against, then de-shares. Self-gating (no-op unless >=2 pages use the
# master), so single-page and page-mode-with-one-data-page builds are unchanged.
if opts[:per_page_masters]
  require File.join(HERE, 'lib', 'per_page_masters')
  ppm = PerPageMasters.split!(spec)
  if ppm[:applied]
    line "per-page-masters (PR-17): #{ppm[:masters]} master instance(s) across #{ppm[:pages]} page(s) " \
         "(#{ppm[:clones]} Data-page element(s), #{ppm[:master_columns_before]} -> " \
         "#{ppm[:master_columns_after]} master columns); each page's controls now filter only its own tiles"
  else
    line 'per-page-masters (PR-17): no split needed (<=1 page draws on the master) — shared master kept'
  end
end
# ---- PUT-APPEND: incremental one-tab-at-a-time into an EXISTING workbook ----
# When --workbook-target <id> is set with a single-dashboard build, append the
# newly-built page(s) to the existing workbook's spec instead of POSTing a brand
# new workbook. We GET the live spec, merge in (a) any data-page elements
# (master/helpers) not already present and (b) the new dashboard page(s), then
# hand the MERGED spec to post-and-readback in PUT mode (--update-id). This is
# the keystone of large-workbook migration: build + gate one tab, then append
# the next without rebuilding the whole workbook.
append_update_id = nil
if opts[:wb_target]
  require 'sigma_rest'
  abort 'FATAL: --workbook-target requires --dashboard/--page (append is per-tab)' unless scoped?
  line "PUT-append: merging the scoped page(s) into existing workbook #{opts[:wb_target]}"
  existing = begin
    # accept: application/json ⇒ Sigma.request returns an ALREADY-PARSED Hash
    # (see lib/sigma_rest.rb) — do not JSON.parse again.
    raw_existing = Sigma.request(:get, "/v2/workbooks/#{opts[:wb_target]}/spec", accept: 'application/json')
    # Workbook code-rep GETs nest pages/schemaVersion under a top-level `document`
    # key (live since 2026-08); flatten metadata+document onto ONE hash so the
    # existing['pages']/existing_el_ids reads below (and the eventual PUT via
    # post-and-readback --update-id, which re-wraps at the wire boundary) see the
    # same flat shape this file always worked with. Without this, a bare
    # existing['pages'] read is nil and the FATAL guard just below fires on
    # EVERY --workbook-target append, even against a perfectly valid workbook.
    WorkbookCode.legacy_view(raw_existing)
  rescue StandardError => e
    abort "FATAL: could not GET existing workbook #{opts[:wb_target]} spec for append (#{e.class}: #{e.message}). " \
          'Verify the id and that the token can read it.'
  end
  unless existing.is_a?(Hash) && existing['pages'].is_a?(Array)
    abort "FATAL: workbook #{opts[:wb_target]} spec readback is not a page-bearing spec (got #{existing.class}); " \
          'the readback may have returned YAML — append aborted to avoid clobbering the workbook.'
  end
  existing_page_names = existing['pages'].map { |p| p['name'] }.compact
  existing_el_ids = existing['pages'].flat_map { |p| (p['elements'] || []).map { |e| e['id'] } }.compact.to_set
  # Append only the NEW page(s) (skip a page name that already exists — re-running
  # the same tab updates in place rather than duplicating).
  new_pages = (spec['pages'] || []).reject do |p|
    nm = p['name']
    data_page = p['id'].to_s.downcase.include?('data')
    if data_page
      # Data-page elements: merge any element id not already in the workbook.
      true # handled below; don't append the whole data page again
    else
      existing_page_names.include?(nm)
    end
  end
  # Merge data-page elements (master/helpers) that the existing workbook lacks
  # into its FIRST data page (or create one). New tabs reuse the same master.
  built_data_pages = (spec['pages'] || []).select { |p| p['id'].to_s.downcase.include?('data') }
  new_data_els = built_data_pages.flat_map { |p| p['elements'] || [] }
                                 .reject { |e| existing_el_ids.include?(e['id']) }
  if new_data_els.any?
    target_data = existing['pages'].find { |p| p['id'].to_s.downcase.include?('data') }
    if target_data
      target_data['elements'] = (target_data['elements'] || []) + new_data_els
    else
      existing['pages'] << (built_data_pages.first || { 'id' => 'data', 'name' => 'Data', 'elements' => new_data_els })
    end
    line "append: +#{new_data_els.size} data-page element(s) (shared master/helpers not yet in workbook)"
  end
  if new_pages.empty?
    line "append: page(s) #{(spec['pages'] || []).map { |p| p['name'] }.compact.inspect} already present in workbook — PUT will refresh in place"
  end
  existing['pages'] = existing['pages'] + new_pages
  # Preserve the existing workbook's identity (name/folder); don't clobber.
  spec = existing
  append_update_id = opts[:wb_target]
  line "append: workbook now has #{existing['pages'].size} page(s) after merge (+#{new_pages.size} new content page(s))"
end

# NON-DESTRUCTIVE placeholder resolution (field-caught round 2): on the
# agent-authored path the __DM_ID__/__DM_ELEMENT__ substitution used to
# OVERWRITE the authored wb-spec.json with resolved live ids — and since every
# DM PUT mints new element ids, any fix-and-retry loop silently went stale
# with no placeholder source left to re-resolve. Write the resolved spec to a
# sibling file and leave the authored source untouched.
if MANUAL_JSON_SPECS
  resolved_path = File.join(WORK, 'wb-spec.resolved.json')
  File.write(resolved_path, JSON.pretty_generate(WorkbookCode.canonicalize(spec)))
  line "resolved spec → #{File.basename(resolved_path)} (authored wb-spec.json left untouched — placeholders stay re-resolvable)"
  wb_spec_path = resolved_path
else
  File.write(wb_spec_path, JSON.pretty_generate(WorkbookCode.canonicalize(spec)))
end
# LOD translation ledger (#423): one entry per source {FIXED/INCLUDE/EXCLUDE}
# calc, classified against the emitted dm-spec + wb-spec. The converter/builder
# path can leave an LOD fuzzy-aliased to a look-alike raw column (silently
# wrong numbers) or dropped outright (silently missing) — the final gate
# (assert-phase6-ran.rb gate 17, exit 24) refuses GREEN until every entry is a
# recognized translation (lod-synth / manual-residue / reference-derived) or
# carries a recorded resolution. An EMPTY ledger is still written — its
# presence is the gate's evidence the audit ran.
begin
  require_relative 'lib/lod_audit'
  _la_read = ->(p) { File.exist?(p) ? (JSON.parse(File.read(p, encoding: 'UTF-8')) rescue nil) : nil }
  _la_cf = _la_read.call(File.join(WORK, 'calc-fields.json'))
  _la_calcs = if _la_cf
                LodAudit.lod_calcs(_la_cf)
              elsif have_twb
                LodAudit.lod_calcs_from_twb(File.read(twb, encoding: 'UTF-8'))
              else
                []
              end
  _la_entries = LodAudit.derive(_la_calcs,
                                dm_spec: _la_read.call(dm_spec_path) || (defined?(dm) ? dm : nil),
                                wb_spec: spec,
                                manual_residues: _la_read.call(File.join(WORK, 'manual-residues.json')),
                                prior: _la_read.call(File.join(WORK, 'lod-audit.json')))
  LodAudit.write(File.join(WORK, 'lod-audit.json'), _la_entries)
  _la_block = _la_entries.reject { |e| LodAudit.resolved?(e) }
  if _la_block.any?
    line "LOD audit: #{_la_block.size} of #{_la_entries.size} LOD calc(s) UNRESOLVED (#{_la_block.map { |e| "#{e['calc']} [#{e['class']}]" }.join('; ')}) — lod-audit.json"
    line "  RESOLVE them before --finalize:  ruby #{File.join(HERE, 'audit-lod-calcs.rb')} --workdir #{WORK}"
  elsif _la_entries.any?
    line "LOD audit: #{_la_entries.size} LOD calc(s) all resolved (lod-audit.json)"
  else
    line 'LOD audit: no {FIXED/INCLUDE/EXCLUDE} calcs — lod-audit.json written as gate evidence'
  end
rescue StandardError => e
  line "WARN: LOD audit derivation failed (#{e.class}: #{e.message.to_s[0, 80]}) — " \
       'gate 17 will fail if the calc census carries LOD calcs; derive by hand via scripts/audit-lod-calcs.rb'
end
# Aggregation-semantics ledger (PR-7): one entry per additive-over-preagg /
# countd-as-sum / preagg-ratio hit, classified against the calc census + the
# emitted dm-spec/wb-spec (+ landing-manifest grain info when present).
# Additive aggregation over a pre-aggregated column compiles clean and ships
# wrong-looking-right numbers (the 103.3%-KPI field twin) — the final gate
# (assert-phase6-ran.rb gate 19, exit 26) refuses GREEN until every hit
# records a resolution (reaggregated | n/a | faithful-to-source). An EMPTY
# ledger is still written — its presence is the gate's evidence the lint ran.
begin
  require_relative 'lib/agg_semantics_lint'
  _as_read = ->(p) { File.exist?(p) ? (JSON.parse(File.read(p, encoding: 'UTF-8')) rescue nil) : nil }
  _as_cf = _as_read.call(File.join(WORK, 'calc-fields.json'))
  _as_calcs = if _as_cf
                AggSemanticsLint.calc_census(_as_cf)
              elsif have_twb
                AggSemanticsLint.calc_census_from_twb(File.read(twb, encoding: 'UTF-8'))
              else
                []
              end
  _as_entries = AggSemanticsLint.derive(_as_calcs,
                                        dm_spec: _as_read.call(dm_spec_path) || (defined?(dm) ? dm : nil),
                                        wb_spec: spec,
                                        landing_manifest: _as_read.call(File.join(WORK, 'landing-manifest.json')),
                                        prior: _as_read.call(File.join(WORK, 'agg-semantics.json')))
  AggSemanticsLint.write(File.join(WORK, 'agg-semantics.json'), _as_entries)
  _as_block = _as_entries.reject { |e| AggSemanticsLint.resolved?(e) }
  if _as_block.any?
    line "agg-semantics lint: #{_as_block.size} of #{_as_entries.size} hit(s) UNRESOLVED " \
         "(#{_as_block.first(4).map { |e| "#{e['consumer']} [#{e['class']}]" }.join('; ')}#{_as_block.size > 4 ? '; …' : ''}) — agg-semantics.json"
    line "  RESOLVE them before --finalize:  ruby #{File.join(HERE, 'audit-agg-semantics.rb')} --workdir #{WORK}" \
         ' --resolve <i> --how <reaggregated|n/a|faithful-to-source> --reason "..."'
  elsif _as_entries.any?
    line "agg-semantics lint: #{_as_entries.size} hit(s) all resolved (agg-semantics.json)"
  else
    line 'agg-semantics lint: no additive-over-preagg/countd-as-sum/preagg-ratio hits — agg-semantics.json written as gate evidence'
  end
rescue StandardError => e
  line "WARN: agg-semantics lint failed (#{e.class}: #{e.message.to_s[0, 80]}) — " \
       'gate 19 will fail if the workdir carries pre-aggregate evidence; derive by hand via scripts/audit-agg-semantics.rb'
end
wb_ids_path = File.join(WORK, 'wb-ids.json')

# GRACEFUL AGENT-PATH FALLBACK. The DM is already posted + valid (dm_id above), so
# if the MECHANICAL workbook layer (validate-spec / build / POST) hits a field it
# cannot translate (Sigma rejects the spec / unresolved "Dependency not found" /
# unmapped derived-dim or measure), we must NOT bare-crash. Catch it and exit with
# a clear, FRIENDLY non-zero handoff: the agent path rebuilds the workbook against
# this DM (see SKILL.md). Never worse than the proven agent path.
begin
  v_log = run_wb!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'workbook',
                   '--dm-context', dm_ids_path, wb_spec_path])
  # 🚧 Pre-POST ref-resolution gate: every [Element/Column] ref in the wb-spec must
  # exist in the LIVE DM, or the POST fails one opaque "Dependency not found" at a
  # time AFTER the DM is created (a multi-datasource enterprise workbook: multi-datasource
  # collapse left 550 refs unresolvable). Catch it here with the full list; the
  # WorkbookBuildError this raises routes to the friendly rebuild-against-DM handoff.
  ref_cmd = ['ruby', File.join(HERE, 'assert-wb-refs-resolve.rb'),
             '--wb-spec', wb_spec_path, '--dm-ids', dm_ids_path,
             '--workdir', WORK] # PR-14: a waived run records itself to offramps.jsonl
  ref_cmd += ['--metrics', metrics_path] if metrics_path && File.exist?(metrics_path)
  ref_cmd += ['--skip-ref-check', opts[:skip_ref_check]] if opts[:skip_ref_check]
  run_wb!(ref_cmd)
  par_cmd = ['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
             '--spec', wb_spec_path, '--out', wb_ids_path, '--workdir', WORK]
  # UPDATE-IN-PLACE: --reuse-workbook PUTs the freshly-built full spec to an
  # existing workbook (same id/URL, layout preserved by post-and-readback's re-PUT
  # path) instead of POSTing a new one — so iterating a fix edits the SAME
  # dashboard rather than orphaning it. --workbook-target (append) takes priority
  # when both are set (it already computed append_update_id + merged the spec).
  # Even without either flag, post-and-readback itself forces PUT when this
  # workdir already recorded a workbook id (posted-workbooks.jsonl /
  # migrate-state.json) — see its same-workbook PUT discipline.
  update_wb = append_update_id || opts[:reuse_workbook]
  line "reuse-workbook: PUT the full spec to existing workbook #{opts[:reuse_workbook]} (no new workbook)" \
    if opts[:reuse_workbook] && !append_update_id
  par_cmd += ['--update-id', update_wb] if update_wb
  p_log = sigma_run_wb!(par_cmd)
rescue WorkbookBuildError => e
  # ── SELF-HEAL: auto-picked reuse DM couldn't satisfy the workbook ──────────
  # When the DM was AUTO-PICKED for reuse (opts[:reuse_dm] == :recommended, the
  # orchestrator's choice — not an explicit user --reuse-dm <id>) and the build
  # failed, rebuild a FRESH DM automatically instead of the exit-4 handoff. This
  # closes the column-superset gate's KNOWN RESIDUAL: a reused DM can be a full
  # column-superset yet lack a role-playing dimension alias the master needs
  # (DATE_DIM as both Order + Return Date), which only surfaces at the pre-POST
  # ref gate — after Phase 3 was skipped. A fresh DM is built from the workbook's
  # own model, so it has exactly the structure the wb-spec needs. Re-invokes this
  # orchestrator verbatim + --skip-reuse-scan (same --out → discovery is reused,
  # so it's fast and creates no orphan: the ref gate is PRE-POST, nothing shipped).
  # Fires once (SIGMA_SELFHEAL_RETRIED guard); an EXPLICIT --reuse-dm <id> is the
  # user's decision and is respected (falls through to the handoff below).
  if opts[:reuse_dm] == :recommended && ENV['SIGMA_SELFHEAL_RETRIED'].to_s.empty?
    puts
    puts "── SELF-HEAL: the auto-picked reuse DM (#{reuse_dm_id}) could not satisfy the"
    puts "   workbook (#{e.message.lines.first&.strip}). Rebuilding a FRESH data model"
    puts '   automatically (--skip-reuse-scan) — no manual step needed. ──'
    Offramp.log(WORK, kind: 'reuse-selfheal', detail: "auto-picked DM #{reuse_dm_id} failed the build; rebuilding fresh") if defined?(Offramp)
    ok = system({ 'SIGMA_SELFHEAL_RETRIED' => '1' }, RbConfig.ruby, File.expand_path(__FILE__),
                *ORIGINAL_ARGV, '--skip-reuse-scan')
    child = $?&.exitstatus
    exit(ok ? 0 : (child.nil? ? 1 : child))
  end
  failed = cull_failed_fields(e.captured_output,
                              (defined?(v_log) ? v_log : ''), (defined?(p_log) ? p_log : ''))
  # Fall back to the mechanically-known untranslatable fields when the log itself
  # doesn't name one (plotted-but-unresolved metrics + dropped calc columns).
  if failed.empty? && mechanical
    failed = ((defined?(plotted_untranslated) && plotted_untranslated || []) +
              (defined?(dropped_calcs) && dropped_calcs || [])).compact.uniq
  end
  names = failed.empty? ? 'one or more fields' : failed.join(', ')
  n = failed.empty? ? 'some' : failed.size.to_s
  # ── Same-failure loop breaker (mode + progress measure + attempt cap) ──────
  # Every exit-4 handoff records a failure signature: script + exit codes +
  # error class + a digest of the ERROR REGION (the [FAIL] summary line and its
  # blank-line-terminated ✗-detail block, identifiers normalized, detail
  # sorted). Counts SURVIVE normalization now, so a converging repair loop
  # (5 → 3 → 1 unresolved refs) mints distinct signatures and keeps going —
  # the old whole-line digit masking collapsed every count into one signature
  # and hard-stopped runs that were repairing (PR-507 finding 1A). Grinding is
  # caught by the failure MODE (same region head with counts masked) recurring
  # with no strict improvement in the measure (the head's leading count), by a
  # verbatim signature repeat (identical/reordered failure), or by the
  # unconditional SIGMA_LOOP_ATTEMPT_CAP budget — see Offramp.loop_check
  # (refs/operating-contract.md: "don't spin, don't fake").
  #
  # Signature the ERROR, not the first output line: children print NORMALIZE:/
  # WARN: report lines BEFORE their ERROR: lines (validate-spec.rb), so a
  # stable leading report line would collide two DIFFERENT root causes into
  # one false :stop — and removing a warning would mint a fresh signature for
  # the SAME error (Offramp.first_error_line owns the selection rule;
  # error_region starts at the same line). And key WHICH child failed + its
  # real exit status (run_wb! raises the same WorkbookBuildError for
  # validate-spec / assert-wb-refs-resolve / post-and-readback alike; the
  # handoff exit is always 4) so different children with a similar first line
  # cannot collide either.
  _err_line = Offramp.first_error_line(e.captured_output) ||
              e.message.lines.first.to_s.strip
  _err_region = Offramp.error_region(e.captured_output)
  _err_region = [_err_line.to_s] if _err_region.empty? # crashed before any output
  _child_exit = e.message[/\Acommand failed \((\d+)\)/, 1]
  _exit_key = _child_exit ? { handoff: 4, child: _child_exit } : 4
  _mode = Offramp.failure_mode(script: 'migrate-tableau', context: 'exit4',
                               exit_code: _exit_key, error_class: e.class,
                               error_region: _err_region)
  _measure = Offramp.region_measure(_err_region)
  _sig = Offramp.failure_signature(script: 'migrate-tableau', context: 'exit4',
                                   exit_code: _exit_key, error_class: e.class,
                                   error_line: _err_line, error_region: _err_region)
  _verdict = Offramp.loop_check(WORK, signature: _sig, mode: _mode, measure: _measure,
                                scope: 'migrate-tableau:exit4')
  if _verdict != :first
    puts
    puts '==================== LOOP STOP (operator action required) ==================='
    if _verdict == :cap
      puts "#{Offramp.scope_attempts(WORK, 'migrate-tableau:exit4')} workbook-build attempts in this workdir " \
           'without reaching green — attempt budget exhausted'
      puts "(SIGMA_LOOP_ATTEMPT_CAP=#{Offramp::ATTEMPT_CAP}). The failure kept changing, so the"
      puts 'recurring-failure rules never fired; the budget is the backstop. Latest failure:'
      puts "  • #{_err_line.to_s[0, 160]}"
    else
      _prior = Offramp.loop_active_trail(WORK).select { |r| r['mode'] == _mode }[0..-2]
      puts "The workbook build has failed the same WAY #{_prior.size + 1} times with no improvement"
      puts "in its failure count (#{_measure ? "now #{_measure}" : 'not measurable'}) — grinding, not converging:"
      _prior.each { |r| puts "  • #{r['at']}  count=#{r['measure'] || '?'}" }
      puts "  • (now)                count=#{_measure || '?'}  #{_err_line.to_s[0, 120]}"
    end
    puts 'Re-running the same command will not converge. STOPPING — hand this to the'
    puts 'operator with the error above, the salvage inventory (if written), and the'
    puts "loop log (#{File.join(WORK, 'loop-log.jsonl')}). Signature: #{_sig}"
    puts 'To re-arm the breaker once the cause is actually fixed: a GREEN --finalize'
    puts "re-arms it automatically; otherwise clear #{File.join(WORK, 'loop-log.jsonl')} (operator-only)."
    puts '============================================================================='
    # A loop STOP is still an orchestrator STOP: mint the manual-path token so
    # the operator's sanctioned repair route (--reuse-dm/--wb-spec re-entry
    # once the cause is fixed) is never stranded behind the manual-spec gate.
    # The attempt-1 handoff below normally minted it already, but a crash
    # between that attempt's loop_check and its authorize call leaves this
    # stop tokenless — and re-stamping records WHICH stop last authorized the
    # path (PR-507 review, design B §1b). The breaker itself still gates any
    # grinding re-entry, so this loosens nothing.
    authorize_manual_path!(via: 'loop-stop', reason: "loop breaker: #{_sig}",
                           exit_code: 4, extra: { 'dataModelId' => dm_id, 'fields' => failed })
    Offramp.log(WORK, kind: 'loop-stop', reason: _sig, detail: _err_line.to_s[0, 200])
    mark('phase4-workbook')
    phase_summary
    exit 4
  end
  puts
  puts '── EXIT 4 — WORKBOOK HANDOFF (this is NOT the finish line, and NOT a handoff to a human).'
  puts '   This STOP is an instruction to YOU, the agent: the data model is posted; now build the'
  puts '   workbook and re-enter the gated spine. A data model without its workbook is an INCOMPLETE'
  puts '   migration — do NOT report success, do NOT ask the user to build the workbook, and do NOT'
  puts '   substitute a "lighter"/"demo"/reduced-scope workbook. Keep going until verify-complete.rb'
  puts '   exits 0. Pick ONE of the two paths below and continue in this same run:'
  puts
  puts "── Mechanical path: data model built OK (dataModelId=#{dm_id}). The WORKBOOK " \
       "layer hit #{n} field(s) the mechanical path can't translate (#{names}). " \
       'Two ways forward:'
  puts "   1. If the field is a MASTER-LEVEL CALC (a binned/categorized dim like 'Ship"
  puts "      Speed Category'), translate its Tableau formula (see calc-fields.json) to"
  puts '      a Sigma formula over master columns and re-run this exact command with:'
  puts "        --master-col '<Name>=<Sigma formula>'   (repeatable)"
  puts "   2. Otherwise: the workbook layer ALREADY auto-built a FULL spec at #{wb_spec_path}"
  puts '      — PATCH THAT FILE IN PLACE. Do NOT rewrite it from scratch and do NOT hand-POST'
  puts '      it (hand-POST skips control lint + Phase-6 + the hard gate):'
  puts "        • Edit ONLY the #{n} failing field(s)/tile(s) named above in that file. Keep"
  puts '          every other element, control, and controlId EXACTLY as the builder wrote them.'
  puts '          A from-scratch rewrite throws away working tiles AND drifts your controlIds away'
  puts '          from control-scope.json — which then fails control-lint with spurious "missing'
  puts '          control" violations on re-entry (this is the #1 way this handoff spirals).'
  puts '        • If a failing field is a MASTER-LEVEL calc, prefer option 1 (--master-col) over'
  puts '          hand-editing the tile. Reference DM elements by their live ids already in the'
  puts '          file (or "__DM_ID__" / "__DM_ELEMENT__:<Name>" if you add new ones).'
  puts '        • Re-run this exact command to RE-GATE the patched spec (REUSE the posted DM):'
  puts "            --reuse-dm #{dm_id} --wb-spec #{wb_spec_path}"
  puts '          (attaches to the existing DM; the workbook re-POST is re-gated. FAST PATH: the'
  puts '          re-run skips discovery + the decisions checkpoint — see --help.)'
  puts '   The data model is posted and ready to attach either way. A conversion is NOT done'
  puts '   until scripts/assert-phase6-ran.rb exits 0 — that hard gate applies on both paths.'
  # SALVAGE INVENTORY: everything already known about each blocked field, so the
  # re-entry starts from the answer (formula + class + route) instead of
  # re-deriving it from the .twb by hand.
  begin
    inv = salvage_inventory(WORK, failed)
    unless inv.empty?
      puts
      puts '── SALVAGE INVENTORY — per blocked field: what it is + its concrete route ──'
      inv.each do |i|
        puts "   • #{i['field']}  [#{i['class']}]"
        puts "       Tableau formula: #{i['formula'].to_s.gsub(/\s+/, ' ').strip[0, 220]}" if i['formula']
        Array(i['notes']).first(2).each { |nt| puts "       note: #{nt.to_s.strip[0, 200]}" }
        puts "       ROUTE: #{i['route']}"
      end
      File.write(File.join(WORK, 'salvage-inventory.json'), JSON.pretty_generate(inv))
      puts "   (inventory also written to #{File.join(WORK, 'salvage-inventory.json')})"
    end
  rescue StandardError => e
    puts "   (salvage inventory unavailable: #{e.class}: #{e.message.to_s[0, 80]})"
  end
  puts '   Reminder: continue now. Shipping only the data model, or a scaled-down "demo" workbook,'
  puts '   does NOT satisfy this migration — the next action is yours.'
  # Authorize the hand-authoring re-entry: this STOP is the ONLY sanctioned way to
  # reach --wb-spec/--dm-spec. The token lets the re-run's manual-spec gate pass
  # (a COLD hand-author with no prior orchestrator run is refused).
  authorize_manual_path!(via: 'workbook-handoff', reason: "untranslatable field(s): #{names}",
                         exit_code: 4, extra: { 'dataModelId' => dm_id, 'fields' => failed })
  Offramp.log(WORK, kind: 'workbook-handoff', detail: "untranslatable field(s): #{names}")
  mark('phase4-workbook')
  phase_summary
  exit 4
end
wb_ids = JSON.parse(File.read(wb_ids_path))
wb_id = wb_ids['workbookId']
line "workbookId = #{wb_id}"
mark('phase4-workbook')

# "Not Migrated (and why)" punch-list — turn every dropped tile into an actionable
# entry (param measure-picker → control-driven Switch, field absent from source SQL,
# inert/commented source calc, window/LOD, aggregate-metric) so no empty/sparse tab
# is mysterious. Best-effort: never fail the migration over the report.
notes_meta   = File.join(WORK, 'conv-meta.json')
notes_charts = File.join(WORK, 'chart-specs.json')
if File.exist?(notes_meta) && File.exist?(notes_charts) && File.exist?(wb_spec_path)
  notes_out = File.join(WORK, 'migration-notes.md')
  nc = ['ruby', File.join(HERE, 'migration-notes.rb'), '--conv-meta', notes_meta,
        '--chart-specs', notes_charts, '--wb-spec', wb_spec_path, '--twb', twb, '--out', notes_out]
  _o, ne, nst = Open3.capture3(*nc)
  if nst.success?
    line "Not-Migrated report → #{notes_out}"
    (ne || '').each_line { |l| line l.rstrip if l.strip.start_with?(/\d/) || l.include?('categorized') }
  else
    line "Not-Migrated report skipped (#{(ne || '').lines.first&.strip})"
  end
end

# ---------------------------------------------------------------------------
# Phase 5 — Layout. Prefer the generator's layout_xml; else auto-build from the
# parsed Tableau zone tree via build-dashboard-layout.rb.
# ---------------------------------------------------------------------------
hdr(5, 'Layout')
layout_path = File.join(WORK, 'layout.xml')
census_path = File.join(WORK, 'layout-census.json') # gate 8c reads this (default: <WORK>)
if layout_xml
  File.write(layout_path, layout_xml)
  line 'layout from spec generator'
  # The spec generator's layout XML doesn't emit a fill census, so gate 8c
  # would have nothing to check on a dashboard build. Derive one from the
  # parsed zone tree (best-effort, scratch --out so the shipped layout.xml is
  # untouched) — the placed/zones drop count is layout-source-independent and
  # the grid-fill is a faithful proxy for these dense hand-composed layouts.
  # Row-model overrides ride through ONLY when the user gave them — an
  # unconditional --row-scale 1.5 would mark row_scale explicit downstream and
  # disable the px-derived canvas row model on every orchestrated run
  # (v5.1.1 review-caught).
  row_model_args = []
  row_model_args += ['--row-scale', opts[:row_scale].to_s] if opts[:row_scale]
  row_model_args += ['--page-rows', opts[:page_rows].to_s] if opts[:page_rows]
  if File.exist?(layout_json)
    run!(['ruby', File.join(HERE, 'build-dashboard-layout.rb'),
          '--layout', layout_json, '--wb-ids', wb_ids_path,
          '--out', File.join(WORK, 'layout-census-scratch.xml'),
          '--census-out', census_path] + row_model_args,
         allow_fail: true)
  end
elsif File.exist?(layout_json)
  row_model_args = []
  row_model_args += ['--row-scale', opts[:row_scale].to_s] if opts[:row_scale]
  row_model_args += ['--page-rows', opts[:page_rows].to_s] if opts[:page_rows]
  _, lst = run!(['ruby', File.join(HERE, 'build-dashboard-layout.rb'),
                 '--layout', layout_json, '--wb-ids', wb_ids_path, '--out', layout_path,
                 '--census-out', census_path] + row_model_args,
                allow_fail: true)
  line 'WARN: layout build failed — workbook will render in default stacked order' unless lst.success?
else
  line 'no layout source — skipping (workbook renders single-column stack)'
end
line "layout fill census → #{census_path}" if File.exist?(census_path)
# Layout is cosmetic: a bad grid PUT must NOT fail an otherwise-good migration
# (the workbook still renders + queries). Apply best-effort.
if File.exist?(layout_path)
  _, pst = sigma_run!(['ruby', File.join(HERE, 'put-layout.rb'),
                       '--workbook', wb_id, '--layout', layout_path], allow_fail: true)
  line(pst.success? ? "layout applied to workbook #{wb_id}" :
       'WARN: layout PUT rejected (Invalid element position) — keeping default stacked layout; charts unaffected')
end
mark('phase5-layout')

# ---------------------------------------------------------------------------
# W2.7 helpers — render-once per latestDocumentVersion (call-site only).
# Current document version straight from the live workbook (same field
# ExportPool.resolve_doc_version keys its export cache on); nil on any
# failure → no reuse anywhere (fail-open to fresh renders).
def sigma_doc_version(wb_id)
  spec = Sigma.request(:get, "/v2/workbooks/#{wb_id}")
  v = spec.is_a?(Hash) ? (spec['latestDocumentVersion'] || spec['latestVersion']) : nil
  v.nil? || v.to_s.empty? ? nil : v.to_s
rescue StandardError
  nil
end

# PURE reuse decision for the 6f staging: given the 5b render-versions sidecar
# and the CURRENT doc version, return the complete staging plan iff EVERY
# dashboard pair can be staged from on-disk artifacts at the SAME version —
# source side from the discovery PNG cache (views/<viewId>.png, else
# dashboards/<name>.png — verify-dashboard-visual.rb's own fallback order),
# sigma side from the version-keyed 5b render. ANY gap → nil (fail-open: the
# child renderer runs exactly as before). Raw evidence only — this plan copies
# PNGs; it never touches a verdict or a manifest judgment field.
def render_reuse_plan(work, doc_version)
  return nil if doc_version.nil?
  rv = JSON.parse(File.read(File.join(work, 'visual-qa', 'render-versions.json')))
  return nil unless rv.is_a?(Hash) && rv['doc_version'] == doc_version && rv['pages'].is_a?(Hash)
  dash_layout = JSON.parse(File.read(File.join(work, 'dashboard-layout.json')))
  wb_ids = JSON.parse(File.read(File.join(work, 'wb-ids.json')))
  gw = begin
    JSON.parse(File.read(File.join(work, 'get-workbook.json')))
  rescue StandardError
    {}
  end
  views = gw.dig('workbook', 'views', 'view') || gw.dig('views', 'view') || []
  views = [views] unless views.is_a?(Array)
  view_id_by_name = views.each_with_object({}) { |v, h| h[v['name']] = v['id'] if v.is_a?(Hash) && v['name'] }
  page_id_by_name = WorkbookCode.pages(wb_ids).each_with_object({}) { |p, h| h[p['name']] = p['id'] if p['name'] }
  slugify = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')[0..50] }
  names = (dash_layout.is_a?(Array) ? dash_layout : []).map { |d| d['dashboard'] }
                                                       .reject { |n| n.to_s.start_with?('[synthetic]') }
  return nil if names.empty?
  names.map do |name|
    vid = view_id_by_name[name]
    src = vid && File.join(work, 'views', "#{vid}.png")
    unless src && File.size?(src)
      fb = File.join(work, 'dashboards', "#{name.to_s.strip.gsub(/[^\w.-]+/, '_').gsub(/\A_+|_+\z/, '')}.png")
      src = File.size?(fb) ? fb : nil
    end
    pid = page_id_by_name[name] || page_id_by_name.reject { |k, _| k == 'Data' }.values.first
    sig = pid && rv['pages'][pid]
    return nil unless src && sig && File.size?(sig.to_s)
    { 'dashboard' => name, 'slug' => slugify.call(name), 'source_from' => src, 'sigma_from' => sig }
  end
rescue StandardError
  nil
end

# ---------------------------------------------------------------------------
# Phase 5b — Visual QA: render each content page to a full-page PNG so the
# layout can be reviewed against refs/layout-visual-qa.md AND compared to the
# source Tableau dashboard — the cross-converter visual-QA gate. Page ids come
# from the LOCAL wb-spec.json (deterministic; the live /spec readback is flaky
# and returns YAML); token minted IN-PROCESS (Sigma.refresh_token!) and injected
# into the child env by sigma_run! — no get-token.sh subshell (#299/#310). Non-fatal — a
# transient export failure must not sink a green migration; the REVIEW is the gate.
# ---------------------------------------------------------------------------
hdr('5b', 'Visual QA')
vqa = File.join(WORK, 'visual-qa'); FileUtils.mkdir_p(vqa)
wbspec_local = (JSON.parse(File.read(wb_spec_path)) rescue {})
content_pages = WorkbookCode.pages(wbspec_local).reject { |p| p['id'].to_s.downcase.include?('data') }
# v5.2 (speed): pages render CONCURRENTLY (pool 3) — each export is a 30-90s
# server-side render; multi-page workbooks paid it serially.
rendered = 0
vqa_tok = sigma_token! # mint ONCE, serially (concurrent mints race)
vqa_mx = Mutex.new
vqa_q = Queue.new
content_pages.each { |pg| vqa_q << pg }
Array.new([3, content_pages.size].min.clamp(1, 3)) do
  Thread.new do
    loop do
      pg = begin
        vqa_q.pop(true)
      rescue ThreadError
        break
      end
      out = File.join(vqa, "#{pg['id']}.png")
      o, st = Open3.capture2e({ 'SIGMA_API_TOKEN' => vqa_tok },
                              *PyResolve.argv, PyResolve.winpath(File.join(HERE, 'sigma-export-png.py')),
                              '--workbook', wb_id, '--page', pg['id'], '--out', PyResolve.winpath(out), '--w', '1800', '--h', '1000')
      # K11: the PNG-export subprocess emits console-codepage bytes on Windows.
      # Ruby tags Open3 output UTF-8 regardless, so `o.strip` on invalid bytes
      # raises Encoding::CompatibilityError and kills this render thread. Scrub
      # before ANY use of `o` — same idiom as :1191 and :2105.
      o = o.force_encoding(Encoding::UTF_8)
      o = o.scrub('?') unless o.valid_encoding?
      vqa_mx.synchronize do
        o.each_line { |l| puts "   #{l.rstrip}" } unless o.strip.empty?
        st.success? ? (rendered += 1) : line("WARN: visual-QA render failed for page #{pg['id']}")
      end
    end
  end
end.each(&:join)
line "rendered #{rendered}/#{content_pages.size} full-page PNG(s) → #{vqa}"
line 'VISUAL QA (review, do not skip): open each PNG; check vs refs/layout-visual-qa.md AND the source Tableau dashboard — titles, right chart kinds, colors, no overlaps/dead zones.' if rendered.positive?
# W2.7 — render-once bookkeeping: key the 5b renders to the CURRENT document
# version (the ExportPool::Cache keying discipline — raw evidence only, PNGs
# version-keyed; VERDICTS are never reused). A later stage may reuse these
# renders only while latestDocumentVersion is UNCHANGED; a version bump
# always forces a fresh render (red line, pinned by test-render-once.rb).
begin
  _rv_pages = content_pages.map { |pg| [pg['id'], File.join(vqa, "#{pg['id']}.png")] }
                           .select { |_, p| File.size?(p) }.to_h
  File.write(File.join(vqa, 'render-versions.json'), JSON.pretty_generate(
               'doc_version' => sigma_doc_version(wb_id), 'pages' => _rv_pages,
               'rendered_at' => Time.now.utc.iso8601))
rescue StandardError
  nil
end
mark('phase5b-visual-qa')

# ---------------------------------------------------------------------------
# Phase 6 — Parity, PASS 1 of 2. Structural hard signals first (live /columns
# type=error re-check after the layout PUT + per-chart compile check), then
# phase6-parity.rb pass 1 builds the parity plan and emits the per-chart MCP
# query list. VALUE parity needs the mcp-v2 actuals — this process cannot fetch
# them (no synchronous chart-data REST endpoint), so it stops HONESTLY at exit
# 12 with resume instructions instead of declaring a fake PASS.
# ---------------------------------------------------------------------------
hdr(6, 'Parity (pass 1 of 2)')
require 'sigma_rest'

# Structural hard signal: no live column resolves to type "error".
# list_entries: /columns paginates (default page 50) — a first-page-only read
# audited <10% of the 599-column field case, so an error-typed column past
# page 1 sailed through this gate.
col_entries = (Sigma.list_entries("/v2/workbooks/#{wb_id}/columns") rescue [])
err_cols = col_entries.select { |c| c.dig('type', 'type') == 'error' }
total_cols = col_entries.size
# Compile-check chart elements (Unknown column / Circular ref markers).
chart_els = WorkbookCode.pages(wb_ids).reject { |p| p['id'].to_s =~ /data/ }
                           .flat_map { |p| WorkbookCode.elements_for_page(wb_ids, p) }
                           .select { |e| e['kind'].to_s.end_with?('-chart') }
bad = []
chart_els.each do |e|
  b = (Sigma.request(:get, "/v2/workbooks/#{wb_id}/elements/#{e['id']}/query", accept: 'text/plain') rescue '')
  bad << (e['name'] || e['id']) if b.to_s =~ /Unknown column "\[|Circular column reference/
end
structural_ok = err_cols.empty? && bad.empty?
if structural_ok
  line "structural: PASS — #{total_cols} workbook column(s) resolve (0 error-typed); " \
       "#{chart_els.size} chart element(s) compile clean"
else
  line "structural: FAIL — #{err_cols.size}/#{total_cols} error-typed column(s)#{bad.any? ? ", #{bad.size} chart(s) with unresolved refs (#{bad.join(', ')})" : ''}"
  err_cols.first(8).each { |c| line "  [#{c['elementId']}] #{c['label']}: #{c['formula']}" }
end

# Persist resume state for --finalize (pass 2) BEFORE stopping. run_id scopes
# the completion sentinels to THIS run; route records how the workdir was driven
# (the route-persistence check refuses a re-entry on the other route).
_prior_state = (JSON.parse(File.read(File.join(WORK, 'migrate-state.json'))) rescue {})
state = { 'workbook_id' => wb_id, 'data_model_id' => dm_id,
          'extract_mode' => !!has_extracts, 'workbook_name' => display_wb_name,
          'reused_dm' => !!reuse_dm_id, 'pass1_at' => Time.now.utc.iso8601,
          'enhance_requested' => !!opts[:enhance],
          'run_id' => RUN_ID, 'route' => CURRENT_ROUTE,
          # W2.1: tier rides the state file (lane B's gate reads 'tier'/'tier_basis';
          # strings pinned in shared/lib/testdata/wave2-tier-state.json). Preserved
          # from the 0c write; keys absent on routes that never resolved a tier.
          'tier' => ($tier || _prior_state['tier']),
          'tier_basis' => ($tier_basis || _prior_state['tier_basis']),
          # W2.1: Tier-S shrinks the RCF budget 5→1 (site 1 of 2; `0` is a
          # DIFFERENT contract that waives gate 8d — never the tier default).
          # W2.2: --certified restores the loop-to-green budget of 5.
          'certified' => (opts[:certified] ? true : nil),
          'rcf_passes' => (opts[:rcf_passes] || (opts[:certified] ? 5 : ($tier == 'S' ? 1 : 5))),
          # PR-13: gate 7b (runtime control flip test) is DEFAULT-ON for the
          # tableau path — this stamp auto-enables it even on a STANDALONE
          # assert-phase6-ran run (the 8d/rcf_passes pattern from #439).
          'control_flip_required' => true }
File.write(File.join(WORK, 'migrate-state.json'), JSON.pretty_generate(state.reject { |_, v| v.nil? }))

# ---------------------------------------------------------------------------
# Phase 5g — stage the RCF (render-compare-fix) fidelity loop. Agent-driven:
# init the ledger now (so the pass budget + source-image pointer are recorded),
# then the agent runs render → compare → record → apply-patch to convergence
# BEFORE --finalize (which enforces the ledger via gate 8d). Skipped, with a
# loud WARN, when --rcf-passes 0.
# ---------------------------------------------------------------------------
rcf_passes = (opts[:rcf_passes] || (opts[:certified] ? 5 : ($tier == 'S' ? 1 : 5))) # W2.1: Tier-S 5→1 (site 2 of 2); W2.2: --certified restores 5
if rcf_passes.to_i <= 0
  line 'WARN: Phase 5g RCF fidelity loop DISABLED (--rcf-passes 0). The workbook will be gated on'
  line '      structure + data + a single visual verdict only — composition drift (palette, chart'
  line '      kind, KPI format) will NOT be iterated. --finalize will not require the fidelity ledger'
  line '      but RECORDS the named --skip-fidelity-gate waiver (budget-counted, PR-11) — name it in'
  line '      your migration report; it is never silent.'
else
  # Best-effort resolve a source image to compare against from the artifacts
  # pass 1 already wrote. The page is NOT pre-picked here any more (#422: the
  # old first-non-"Data"-page pick landed on a second data page rendering a
  # hidden helper table) — fidelity-loop.rb init auto-picks the page with the
  # most VISIBLE elements from wb-ids.json + wb-spec.json, and an operator
  # --page-id override now works even on an existing ledger.
  cmani = (JSON.parse(File.read(File.join(WORK, 'visual-qa', 'compare-manifest.json'))) rescue [])
  src_img = (cmani.find { |m| m['source_png'] } || {})['source_png']
  _, ist = run!(['ruby', File.join(HERE, 'fidelity-loop.rb'), 'init',
                 '--workdir', WORK, '--workbook-id', wb_id,
                 '--max-passes', rcf_passes.to_s] +
                (src_img ? ['--source-image', src_img] : []), allow_fail: true)
  if ist.success?
    led_pg = (JSON.parse(File.read(File.join(WORK, 'fidelity-ledger.json')))['page_id'] rescue '?')
    line "Phase 5g: RCF fidelity ledger initialized (page #{led_pg}, budget #{rcf_passes})"
  else
    line 'Phase 5g: ledger init could not auto-pick a page — init manually with --page-id (see the prompt below)'
  end
  mark('phase5g-init')
end

unless structural_ok
  puts
  puts '================ RESULT ================'
  puts "dataModelId : #{dm_id}"
  puts "workbookId  : #{wb_id}"
  puts "PARITY      : FAIL (structural — #{err_cols.size} error column(s); fix before the value pass)"
  puts '======================================='
  mark('phase6-pass1')
  phase_summary
  exit 3
end

# phase6-parity PASS 1: builds parity-plan.json + prints one mcp-v2 query per chart.
p6 = ['ruby', File.join(HERE, 'phase6-parity.rb'),
      '--tableau', WORK, '--workbook-id', wb_id]
p6 += ['--extract-mode', '--extract-tol', '0.30'] if has_extracts
p6 += ['--regen-plan'] if opts[:regen_plan]
if FASTPATH && (FAST[:degraded] || []).any?
  # Degraded fast path (--yes, discovery artifacts missing): the plan may be
  # unbuildable without the view CSVs / layout. Degrade LOUDLY, never re-fetch.
  _, p6deg = sigma_run!(p6, allow_fail: true)
  unless p6deg.success?
    line 'WARN: FAST PATH degraded — parity pass 1 could not build a plan (missing discovery ' \
         "artifact(s): #{FAST[:degraded].join(', ')}). The workbook is POSTed, but the Phase 6 " \
         'gates need the discovery workdir: restore it (or re-run WITHOUT --yes to re-fetch) ' \
         'before --finalize.'
  end
else
  sigma_run!(p6)
end

# Phase 6f-visual — tiles whose Tableau data export came back EMPTY (action-
# filter-gated etc.) were BUILT from .twb signals and have no actuals to value-
# diff. Stage an IMAGE comparison (Tableau view image vs Sigma element render)
# so they're verified visually instead of silently passing parity.
vv_sidecar = File.join(WORK, 'visual-verify-tiles.json')
vv_tiles = File.exist?(vv_sidecar) ? (JSON.parse(File.read(vv_sidecar)) rescue []) : []
# v5.2 (speed): the per-tile and full-dashboard visual stages are independent
# (distinct outputs, both read-only against the live workbook) — run them
# CONCURRENTLY instead of paying two serial render waits.
vis_tok = sigma_token!
vis_threads = []
if vv_tiles.any?
  line "Phase 6f-visual: #{vv_tiles.size} tile(s) had EMPTY data exports / inferred chart kinds — staging per-tile image comparison"
  vis_threads << Thread.new do
    Open3.capture2e({ 'SIGMA_API_TOKEN' => vis_tok }, 'ruby', File.join(HERE, 'verify-visual-tiles.rb'),
                    '--workbook', wb_id, '--tableau-dir', WORK)
  end
end

# Phase 6f — FULL-DASHBOARD ground truth: stage the source Tableau dashboard
# image next to the Sigma page render per dashboard, so the mandatory whole-page
# visual comparison (and the repair loop: diff → fix → re-render) has both sides
# ready. Writes visual-qa/compare-manifest.json (agent sets visual_match).
# W2.7 — render-once: when latestDocumentVersion is UNCHANGED since the 5b
# renders and every pair stages from disk, copy instead of re-rendering
# (each server-side page render is 30-90s). Any gap → the child renderer runs
# exactly as before (fail-open). Version bump → fresh render, always.
_doc_v6f = sigma_doc_version(wb_id)
_reuse_plan = render_reuse_plan(WORK, _doc_v6f)
if _reuse_plan
  line "Phase 6f-visual: REUSING the 5b renders (documentVersion unchanged: #{_doc_v6f}) — " \
       "#{_reuse_plan.size} pair(s) staged from disk, 0 fresh renders (W2.7)"
  _vqa6 = File.join(WORK, 'visual-qa')
  FileUtils.mkdir_p(_vqa6)
  _manifest6 = _reuse_plan.map do |r|
    src_png = File.join(_vqa6, "#{r['slug']}.source.png")
    sig_png = File.join(_vqa6, "#{r['slug']}.sigma.png")
    FileUtils.cp(r['source_from'], src_png) unless r['source_from'] == src_png
    FileUtils.cp(r['sigma_from'], sig_png) unless r['sigma_from'] == sig_png
    { 'dashboard' => r['dashboard'], 'source_png' => src_png,
      'sigma_png' => sig_png, 'visual_match' => false }
  end
  File.write(File.join(_vqa6, 'compare-manifest.json'), JSON.pretty_generate(_manifest6))
  quiet_event('render-reuse', 'doc_version' => _doc_v6f, 'pairs' => _manifest6.size)
else
  line 'Phase 6f-visual: staging full-dashboard source-vs-Sigma image pairs for the repair loop'
  vis_threads << Thread.new do
    Open3.capture2e({ 'SIGMA_API_TOKEN' => vis_tok }, 'ruby', File.join(HERE, 'verify-dashboard-visual.rb'),
                    '--workbook', wb_id, '--tableau-dir', WORK)
  end
end
vis_threads.each do |th|
  o, _st = th.value
  o.each_line { |l| puts "   #{l.rstrip}" } unless o.to_s.strip.empty?
end

puts
puts '================ RESULT (pass 1 — parity PENDING) ================'
quiet_event('result', 'stage' => 'pass1', 'status' => 'PENDING',
            'workbook_id' => wb_id, 'data_model_id' => dm_id)
puts "dataModelId : #{dm_id}#{reuse_dm_id ? '  (REUSED existing DM)' : ''}"
puts "workbookId  : #{wb_id}"
puts "structural  : PASS (#{total_cols} cols resolve, #{chart_els.size} charts compile)"
puts "TIER        : #{$tier} (#{$tier_basis}) — budgets/duplicate-oracles only; all gates still run" if $tier
if $rls_pending
  puts "RLS         : DETECTED, NOT APPLIED — see #{File.join(WORK, 'security.json')}; provision + apply"
  puts '              via scripts/apply_sigma_rls.py before sharing (the model returns ALL rows until then)'
end
puts 'PARITY      : PENDING — the pooled collector filled parity-actuals.json for every'
puts '              exportable chart; run the REMAINING mcp-v2 queries printed above'
puts "              (if any), merge into #{File.join(WORK, 'parity-actuals.json')}, then:"
puts 'VISUAL      : FULL-DASHBOARD comparison staged — READ each source vs Sigma pair under'
puts "              #{File.join(WORK, 'visual-qa')}/ (<dash>.source.png vs <dash>.sigma.png). Diff layout,"
puts '              chart kinds, sizing; fix the spec + re-render for any divergence; set "visual_match":true'
puts '              per dashboard in compare-manifest.json (the repair loop).'
if vv_tiles.any?
  puts "              ALSO #{vv_tiles.size} per-tile pair(s) under #{File.join(WORK, 'visual-verify')}/ — tiles with"
  puts '              EMPTY data exports or INFERRED chart kinds (no value-diff possible). Confirm each and set'
  puts '              "visual_verified": true in visual-verify/manifest.json (gate 9 blocks GREEN until done).'
end
if rcf_passes.to_i.positive?
  puts "FIDELITY    : Phase 5g RCF loop STAGED (budget #{rcf_passes}). Iterate render→compare→fix to"
  puts '              near-exact parity BEFORE --finalize (which requires the ledger — gate 8d):'
  if defined?(_reuse_plan) && _reuse_plan
    puts "              W2.7: documentVersion #{_doc_v6f} is unchanged since 5b — START pass 1 from the"
    puts '              staged 6f render (visual-qa/<dash>.sigma.png): compare + record deltas against it'
    puts '              FIRST; call `fidelity-loop.rb render` only for pass 2+ (a render is 30-90s).'
  end
  puts "                ruby scripts/fidelity-loop.rb render --workdir #{WORK}"
  puts '              READ rcf-pass-N.png vs the source PNG, score against refs/fidelity-rubric.md, then'
  puts '              per delta: fidelity-loop.rb record (classify spec-fixable/ui-only/sigma-capability/data),'
  puts '              author a patch from refs/fidelity-recipes.md, fidelity-loop.rb apply-patch --resolves,'
  puts '              and render again. Loop until `fidelity-loop.rb status` is clean (0 unresolved spec-fixable).'
end
# v5.0-P2 advisory oracles (never gate; results ride the report):
wc_side = File.join(WORK, 'window-calcs.json')
wc_any = File.exist?(wc_side) &&
         ((JSON.parse(File.read(wc_side))['entries'] || []).any? rescue false)
if wc_any
  puts 'VDS ORACLE  : window calcs detected — verify the translations against Tableau itself:'
  puts "                ruby scripts/vds-oracle.rb --workdir #{WORK}"
  puts "              (advisory; emits #{File.join(WORK, 'vds-oracle.json')}; published datasources only)"
end
puts 'RENDER/INTERACTION (advisory): exact-size Tableau baseline + one-control flip oracle:'
puts "                ruby scripts/render-baseline.rb --tableau-dir #{WORK}"
puts "                ruby scripts/verify-interaction.rb --workdir #{WORK} --workbook-id #{wb_id}"
puts 'INTERACTIVITY: generate the post-publish handoff guide — dashboard actions, nav'
puts '              buttons, dynamic zones, drills, and tooltips cannot ride the spec;'
puts '              the guide walks the user through adding each in the Sigma UI'
puts '              (gate 11 at --finalize REQUIRES the file when the source has actions):'
# Same derivation as the exitstatus==16 advisory above — recomputed locally
# (not read off `charts_path`) since this print site is reached from a
# different point in the run than that one; deriving it fresh from the same
# fixed 'chart-specs.json' --out name build-charts-from-signals.rb was
# actually invoked with, rather than assuming a variable from elsewhere in
# the script is in scope, keeps both sites correct independently.
manifest_path2 = File.join(WORK, 'chart-specs.json').sub(/\.json$/, '-actions-emitted.json')
puts "                ruby scripts/build-postpublish-guide.rb --twb #{File.join(WORK, 'workbook-content.twb')} \\"
puts "                  --wb-ids #{File.join(WORK, 'wb-ids.json')} --out #{File.join(WORK, 'POSTPUBLISH_GUIDE.md')} \\"
puts "                  --emitted-manifest #{manifest_path2} \\"
puts "                  --json-out #{File.join(WORK, 'action-ledger.json')}"
puts '              LINK the guide in your migration report and walk the user through it.'
finalize_cmd = "  ruby scripts/migrate-tableau.rb #{opts[:wb_id] ? "--workbook-id #{opts[:wb_id]}" : "--workbook \"#{opts[:wb_name]}\""}" \
               "#{opts[:out] ? " --out #{WORK}" : ''} \\\n    --finalize --actuals #{File.join(WORK, 'parity-actuals.json')}"
puts finalize_cmd
puts '(--finalize runs phase6 finalize + orphan cleanup + the census-aware'
puts ' assert-phase6-ran hard gate; exit 0 there is the ONLY green exit.)'
puts 'PHASE E     : requested (--enhance) — runs at --finalize AFTER all gates are green' if opts[:enhance]
puts '=================================================================='

# Completion sentinel (run-scoped). PASS 1 is NOT a done state: the gate suite
# lives in --finalize. Drop a pending marker keyed to this workbook AND this
# run_id, and CLEAR any stale success marker from a prior run, so
# verify-complete.rb (the sole done-check the SKILL points at) reports NOT DONE
# until --finalize's hard gate stamps phase6-success.json. This is the
# structural backstop for the "agent stops at PASS 1 and narrates success"
# failure mode.
begin
  File.write(File.join(WORK, 'parity-pending.json'),
             JSON.pretty_generate('workbookId' => wb_id, 'dataModelId' => dm_id,
                                  'run_id' => RUN_ID,
                                  'written_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
                                  'stage' => 'pass1', 'note' => 'parity + gates NOT run — run --finalize'))
  _succ = File.join(WORK, 'phase6-success.json')
  File.delete(_succ) if File.exist?(_succ)
rescue StandardError
  # best-effort — never fail the run on sentinel bookkeeping
end
Offramp.log(WORK, kind: 'pass1-stop', detail: "workbook #{wb_id} — parity + gates not yet run")

# 🚧 G6 — MANUAL CUSTOM-SQL RESIDUES (exit 16). Phase 1e routed these
# window/table-calc chains to the Custom SQL path correctly, but the build can
# only ship the plotting tile with a magnitude proxy until the Custom SQL DM
# element exists and the tile measure is repointed at it. Run-2 shipped the
# proxy silently and the divergence surfaced only at Phase 6, ~2h later — so
# pass 1 now BLOCKS here with the exact build+bind checklist instead of exit 12.
_mr_doc = (JSON.parse(File.read(File.join(WORK, 'manual-residues.json'))) rescue nil)
_mr = _mr_doc.is_a?(Hash) ? Array(_mr_doc['residues']) : Array(_mr_doc)
_mr_unbuilt = _mr.select { |e| e.is_a?(Hash) && e['status'].to_s == 'unbuilt' }
if _mr_unbuilt.any?
  puts
  puts '=========== MANUAL CUSTOM-SQL RESIDUES — BUILD REQUIRED BEFORE --finalize (exit 16) ==========='
  puts "#{_mr_unbuilt.size} window/table-calc residue(s) are PLOTTED BY DASHBOARD TILES but have no Sigma"
  puts 'translation (requires_custom_sql — refs/window-functions.md STAYS-MANUAL). Their tiles currently'
  puts 'render a MAGNITUDE PROXY, not the source measure. For EACH residue below:'
  puts "  1. Create a Custom SQL DM element from the skeleton (edit + PUT the DM spec:"
  puts "     ruby scripts/post-and-readback.rb --type datamodel --update-id #{dm_id} --spec #{File.join(WORK, 'dm-spec.json')} ...)"
  puts '  2. Repoint the tile\'s measure column at the new element\'s output column (wb-spec PUT).'
  puts "  3. Set \"status\": \"built\" for that entry in #{File.join(WORK, 'manual-residues.json')}."
  _mr_unbuilt.each_with_index do |e, i|
    puts
    puts "  #{i + 1}. #{e['calc'].inspect}  (tile: #{e['tile'].inspect})"
    puts "     Tableau: #{e['formula'].to_s.gsub(/\s+/, ' ')[0, 220]}"
    puts '     Suggested Custom SQL:'
    e['suggested_sql'].to_s.each_line { |l| puts "       #{l.rstrip}" }
  end
  puts
  puts 'Then re-run --finalize. assert-phase6-ran REFUSES GREEN while any residue is "unbuilt"'
  puts '(waiver: --accept-manual-residues "<calc,...>" — budget-counted; name it in your report).'
  puts '==============================================================================================='
  mark('phase6-pass1')
  phase_summary
  exit 16
end

# ---------------------------------------------------------------------------
# SINGLE-INVOCATION finalize chain (speed review #2b + reconciled amendment:
# STRICT empty-actuals predicate, derived from the artifacts — never guessed).
# When the agent-mediated actuals list is EMPTY — every exportable plan chart
# was machine-collected by the pooled exporter, no pivot grids, no
# render-verify/too-large/timeout markers, no per-tile visual sidecar — the
# exit-12 → separate --finalize invocation is a pure round-trip tax: chain
# finalize IN-PROCESS (same pid, same invocation: exec self with --finalize
# --actuals). Anything short of the strict predicate keeps today's exit-12
# contract unchanged. Escape hatch: SIGMA_NO_CHAIN_FINALIZE=1.
#
# The predicate ALSO requires the agent-side gate obligations to be already
# DISCHARGED (wave-1 review): empty actuals alone made a COLD chain guaranteed
# NOT-GREEN — the 6f renders are staged seconds earlier, so gate 8b (recorded
# visual verdict, exit 13) could not hold yet, and the chained battery burned
# a full gate suite plus a loop-log attempt in scope migrate-tableau:finalize
# to reach a predictable stop. Chain only when:
#   - a visual verdict is RECORDED on parity-final.json (record-visual-check.rb
#     — only possible on a re-entry workdir, since finalize writes that file;
#     'not-executable' still stops gate 8b, so it does not qualify; --fast
#     waives both visual gates at --finalize and skips this leg), AND
#   - the staged RCF ledger is RESOLVED (gate 8d): fidelity-ledger.json carries
#     no unresolved spec-fixable/data deltas; a staged loop (rcf_passes > 0,
#     the finalize default when state is silent) with no readable ledger
#     refuses the chain the same way the gate would exit 15.
# ---------------------------------------------------------------------------
def finalize_chain_predicate(work, fast: false)
  plan = begin
    JSON.parse(File.read(File.join(work, 'parity-plan.json')))
  rescue StandardError
    nil
  end
  charts = plan.is_a?(Hash) ? Array(plan['charts']).select { |c| c.is_a?(Hash) } : []
  return [false, 'no parity-plan.json charts on disk'] if charts.empty?
  pivots = charts.select { |c| c['sigma_kind'].to_s.downcase.include?('pivot') }
  return [false, "#{pivots.size} pivot grid(s) in the plan (agent-mediated MCP queries)"] if pivots.any?
  vv = begin
    JSON.parse(File.read(File.join(work, 'visual-verify-tiles.json')))
  rescue StandardError
    []
  end
  return [false, "#{vv.size} tile(s) staged for per-tile visual verification"] if vv.is_a?(Array) && vv.any?
  actuals = begin
    JSON.parse(File.read(File.join(work, 'parity-actuals.json')))
  rescue StandardError
    nil
  end
  return [false, 'no readable parity-actuals.json'] unless actuals.is_a?(Hash)
  markers = actuals.values.reject { |v| v.is_a?(Array) }
  return [false, "#{markers.size} agent-mediated marker(s) in parity-actuals.json (render-verify/too-large/timeout)"] if markers.any?
  collectible = charts.select { |c| Array(c['sigma_columns']).length >= 1 }
  return [false, 'no exportable charts (anchors-oracle path — visual/anchor work is agent-mediated)'] if collectible.empty?
  missing = collectible.reject do |c|
    a = actuals[c['chart']] || actuals[c['name']]
    a.is_a?(Array) && a.any?
  end
  return [false, "#{missing.size} exportable chart(s) not machine-collected"] if missing.any?
  # Agent-side obligations at the finalize gates (see header): a chain that is
  # guaranteed to stop at gate 8b/8d is a battery burn, not a saved round-trip.
  unless fast # --fast waives gates 8 + 8b at --finalize
    pf = begin
      JSON.parse(File.read(File.join(work, 'parity-final.json')))
    rescue StandardError
      nil
    end
    verdict = pf.is_a?(Hash) ? pf['visual_verdict'].to_s : ''
    return [false, 'no recorded visual verdict (record-visual-check.rb) — gate 8b would stop the chained finalize'] if verdict.empty?
    return [false, "recorded visual verdict is 'not-executable' — gate 8b would stop the chained finalize"] if verdict == 'not-executable'
  end
  ms_state = begin
    JSON.parse(File.read(File.join(work, 'migrate-state.json')))
  rescue StandardError
    nil
  end
  rcf_staged = (ms_state.is_a?(Hash) ? ms_state : {}).fetch('rcf_passes', 5).to_i.positive?
  fl_path = File.join(work, 'fidelity-ledger.json')
  if File.exist?(fl_path)
    ledger = begin
      JSON.parse(File.read(fl_path))
    rescue StandardError
      nil
    end
    return [false, 'unreadable fidelity-ledger.json — gate 8d would stop the chained finalize'] unless ledger.is_a?(Hash)
    unresolved = Array(ledger['entries']).count do |e|
      e.is_a?(Hash) && %w[spec-fixable data].include?(e['cls'].to_s) && !e['resolved']
    end
    return [false, "#{unresolved} unresolved spec-fixable/data RCF delta(s) in fidelity-ledger.json — gate 8d would stop the chained finalize"] if unresolved.positive?
  elsif rcf_staged
    return [false, 'RCF loop staged (rcf_passes > 0) but no fidelity-ledger.json — gate 8d would stop the chained finalize']
  end
  [true, "all #{collectible.size} exportable chart(s) machine-collected; no pivot grids; no agent-mediated markers; " \
         "visual verdict #{fast ? 'waived (--fast)' : 'recorded'}; RCF ledger #{rcf_staged ? 'resolved' : 'unstaged'}"]
end

# W2.6: classify a failed chain predicate — :wait when the ONLY blockers are
# agent-DISCHARGEABLE obligations at the pass-1 tail (record the visual
# verdict; write/resolve the staged RCF ledger), :terminal for everything
# structural (pivot grids, agent-mediated markers, missing actuals — nothing
# an agent can discharge in minutes) AND for a recorded 'not-executable'
# verdict, which is an ANSWER (the agent cannot do vision), not a pending one.
WAITABLE_CHAIN_RES = [/\Ano recorded visual verdict/,
                      /\ARCF loop staged \(rcf_passes > 0\) but no fidelity-ledger\.json/,
                      /unresolved spec-fixable\/data RCF delta/,
                      /\Aunreadable fidelity-ledger\.json/].freeze
def chain_wait_class(chain_ok, why)
  return :chain if chain_ok
  WAITABLE_CHAIN_RES.any? { |re| re =~ why.to_s } ? :wait : :terminal
end

_chain_ok, _chain_why = finalize_chain_predicate(WORK, fast: !!opts[:fast])
# ── W2.6 — 🚧 pass-1-tail visual-verdict WAIT-GATE (mirror of Phase 1d) ──────
# On a COLD run the chain predicate is structurally unsatisfiable here: the
# visual verdict records ONTO parity-final.json, which only the finalize leg
# writes — so wave-1's in-process chain could never fire on the very cold runs
# it was justified by (wave-1 review R4; both reviewers converged on this
# gate). While the obligations are merely UNDISCHARGED (not terminal), banner
# + bounded poll — SIGMA_VISUAL_VERDICT_TIMEOUT_S, default 480s, 0 = don't
# wait (named on the banner's first line) — re-evaluating the predicate; on
# satisfied → chain below, one invocation end-to-end. Deadline passes → the
# unchanged exit-12 two-invocation contract (fail-open, never invents a
# failure). SIGMA_NO_CHAIN_FINALIZE=1 disables the wait AND the chain.
if ENV['SIGMA_NO_CHAIN_FINALIZE'].to_s.empty? && chain_wait_class(_chain_ok, _chain_why) == :wait
  _vv_wait = (ENV['SIGMA_VISUAL_VERDICT_TIMEOUT_S'] || '480').to_i
  if _vv_wait.positive?
    puts
    puts "── 🚧 PASS-1-TAIL WAIT (W2.6) · visual verdict → in-process --finalize · SIGMA_VISUAL_VERDICT_TIMEOUT_S=#{_vv_wait}s (0 = don't wait; exit 12 immediately) ──"
    line "chain blocked only by agent-dischargeable obligation(s): #{_chain_why}"
    line 'Discharge them NOW — the 6f render pairs are already staged:'
    line "  1. write the parity result:  ruby scripts/phase6-parity.rb --tableau #{WORK} --finalize --actuals #{File.join(WORK, 'parity-actuals.json')}"
    line "  2. READ each pair under #{File.join(WORK, 'visual-qa')}/ (<dash>.source.png vs <dash>.sigma.png); run the staged RCF loop (fidelity-loop.rb) to resolution"
    line '  3. record the verdict:       ruby scripts/record-visual-check.rb --workdir ' \
         "#{WORK} --agent-vision true --verdict <pass|divergent> [--blind-grade <blind-grade.json>]"
    line 'On the recorded verdict this run chains --finalize IN-PROCESS (single invocation, cold).'
    quiet_event('wait-visual-verdict', 'timeout_s' => _vv_wait, 'why' => _chain_why)
    _vv_deadline = Time.now + _vv_wait
    loop do
      sleep 5
      _chain_ok, _chain_why = finalize_chain_predicate(WORK, fast: !!opts[:fast])
      break if _chain_ok
      if chain_wait_class(_chain_ok, _chain_why) == :terminal
        line "visual-verdict wait ended: #{_chain_why} — exit 12 (run --finalize separately)"
        break
      end
      if Time.now >= _vv_deadline
        line "visual-verdict wait deadline passed (#{_vv_wait}s; still: #{_chain_why}) — " \
             'fail-open to the exit-12 two-invocation contract'
        quiet_event('wait-visual-verdict-timeout', 'timeout_s' => _vv_wait)
        break
      end
    end
  else
    line 'SIGMA_VISUAL_VERDICT_TIMEOUT_S=0 — not waiting for the visual verdict; exit-12 two-invocation contract'
  end
end
if _chain_ok && ENV['SIGMA_NO_CHAIN_FINALIZE'].to_s.empty?
  puts
  puts '── SINGLE-INVOCATION · chaining --finalize in-process ──'
  line "agent-mediated actuals list is EMPTY and the agent-side gate obligations are discharged (#{_chain_why})"
  line 'exit 12 would only tax a re-invocation — running the finalize gate battery now.'
  line 'NOTE: a gate can still stop with its own banner; fix and re-run --finalize'
  line '(SIGMA_NO_CHAIN_FINALIZE=1 disables chaining).'
  Offramp.log(WORK, kind: 'finalize-chained', detail: _chain_why)
  quiet_event('chain', 'to' => 'finalize', 'why' => _chain_why)
  mark('phase6-pass1')
  phase_summary
  $stdout.flush
  begin
    exec(RbConfig.ruby, __FILE__,
         *(ORIGINAL_ARGV + ['--finalize', '--actuals', File.join(WORK, 'parity-actuals.json')]))
  rescue SystemCallError => e
    line "WARN: in-process finalize chain failed to exec (#{e.class}: #{e.message}) — falling back to exit 12"
  end
end

puts
puts '⛔ NOT DONE — this is PASS 1 of 2. Do NOT report success or hand off yet.'
puts '   To confirm completion at any point, run (exit 0 == done, nothing else counts):'
puts "     ruby scripts/verify-complete.rb --workdir #{WORK}"
puts '=================================================================='
mark('phase6-pass1')
phase_summary
exit 12
