#!/usr/bin/env ruby
# Hard gate that proves a tableau-to-sigma conversion is actually complete.
# The subagent MUST run this script before declaring GREEN. It checks seven
# independent things — failing ANY of them blocks the GREEN declaration:
#
#   0. Pre-POST render integrity — when the workdir carries a local workbook
#      authored code-rep candidate (wb-spec.json or workbook-spec.json), every
#      chart/KPI/table/pivot/crosstab must have a
#      usable data binding. Evidence is always written to
#      blank-risk-elements.json. No local candidate → stated SKIP so legacy
#      live-only runs remain valid.
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
#      display names, no input controls outside the Container bands on a
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
#   7b. Runtime control flip test (DEFAULT-ON for workdirs whose orchestrator
#      staged it — PLAN-v3 PR-13; --require-control-flip forces it anywhere) —
#      gate 7's control-scope.json sidecar is derived by build_workbook.py from
#      the same `listen` data it used to wire the spec, so a builder-level
#      mis-mapping makes spec and sidecar AGREE and gate 7 passes. This gate
#      proves the wiring INDEPENDENTLY at runtime: scripts/probe-controls.rb
#      flips each auto-probeable control via the REST export API and requires
#      its targets' output to actually change (wired-but-inert = FAIL, exit 21).
#      Enforcement resolution (the gate-8d/#439 pattern): --require-control-flip
#      forces it on; otherwise migrate-state.json control_flip_required=true
#      (stamped by migrate-tableau.rb at pass 1) auto-enables it, so a
#      standalone gate run cannot silently skip the flip test on an
#      orchestrated tableau workdir. When ENFORCED but the probe cannot run
#      here (no creds / no workbook / probe missing), RECORDED evidence is
#      accepted instead: <workdir>/probe-controls/probe-results.json with >=1
#      PASS and 0 FAIL (a prior live probe), the control-flip-unverified.json
#      advisory marker (nothing auto-probeable), or a controls census showing
#      0 source control signals. No evidence and no --skip-control-flip waiver
#      (budget-counted) → FAIL exit 21 — the flip test needs the live API, so
#      the marker OR the recorded waiver is the bar, never silence.
#      Converters that never stage it and don't pass the flag keep the old
#      opt-in SKIP. See lib/flip_gate.rb.
#   7c. Source-vs-built controls CENSUS (exit 31; V5.6 audit V-V3) —
#      build-charts-from-signals.rb reconciles EVERY source control signal
#      (.twb parameters + shared quick filters) against what it built and
#      writes <workdir>/*-controls-coverage.json. Until PR-13 that census was
#      a WARN + file nothing ever read. This gate makes it load-bearing:
#      every expected signal must be built (census status 'emitted'),
#      declared in the control-scope.json sidecar (a dropped / needs-* /
#      narrow-scope record carrying its evidence — stated per control), or
#      named in the <workdir>/controls-waivers.json ledger
#      ([{"control":"filter:Region","reason":"…"}]) with a reason. An
#      UNEXPLAINED missing control fails BY NAME. NO skip flag — the ledger
#      waiver IS the sanctioned escape (join-plan/LOD doctrine). No census
#      file → stated SKIP (back-compat / non-adopting converters).
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
#     [--require-control-flip] # gate 7b: prove control wiring at runtime via
#                              # probe-controls.rb. DEFAULT-ON when
#                              # migrate-state.json carries
#                              # control_flip_required=true (tableau pass 1);
#                              # this flag forces it for everyone else
#                              # (looker-to-sigma passes it)
#     [--skip-control-flip R]  # waive gate 7b — budget-counted; name the
#                              # reason in your report
#     [--flip-check-leaks]     # gate 7b: also assert flips don't leak
#                              # (probe --check-out-of-closure; doubles exports)
#     [--min-layout-elements N] default 2 — single-page bare-element layouts
#                              # often have just the page wrapper; require this
#                              # many <Element> tags
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
#  13  Visual comparison not recorded OR not executable (gate 8b) — ENFORCED BY
#      DEFAULT. Three variants, same exit code:
#      (a) a valid render exists but parity-final.json carries no
#          visual_checked/screenshot_path verdict. A structurally-clean workbook
#          can still ship visually empty/wrong, so the source-vs-target
#          comparison is mandatory. Run record-visual-check.rb after reading the
#          rendered page against the source dashboard PNG, then re-run.
#      (b) parity-final.json carries agent_vision=false or
#          visual_verdict="not-executable" (stamped by record-visual-check.rb
#          §D5) — the driving agent could not READ the render, so any verdict is
#          a blind attestation. Re-run the visual loop from a vision-capable
#          session (Claude Code with image input).
#      (c) a PASS verdict is SELF-ATTESTED (PLAN-v3 PR-9): parity-final.json
#          carries no valid `blind_grade` metadata and no recorded
#          `blind_grade_waiver`. A visual pass must be countersigned by a
#          CONTEXT-FREE blind grader (a fresh subagent given ONLY the source
#          PNG + render PNG + the rubric — refs/blind-grader-brief.md); the
#          field failure this closes: the builder self-graded 6/6 PASS on
#          visuals the customer rejected. The recorded grade is re-verified
#          here SHA-BOUND: blind-grade.json must still exist, its sha256s must
#          match the stamped metadata AND the actual image bytes on disk
#          (recomputed — an image swapped after grading fails), every checklist
#          dimension must be present and passing, and its per-tile chart-family
#          readings must not contradict the mechanical kind census
#          (wb-readback.json) on more than 1 tile. Remedy: spawn the blind
#          grader, then record-visual-check.rb --blind-grade. A recorded
#          no-vision waiver (record-visual-check --no-vision-waiver "<reason>",
#          for sessions that cannot spawn a vision-capable grader) is accepted
#          instead but COUNTS against the waiver budget.
#      Escape hatch for (a)/(b) (source image genuinely unobtainable / knowingly
#      accepting an unverified render): --skip-visual-comparison "<reason>".
#      A recorded `divergent` verdict passes this gate as RECORDED (the
#      comparison happened; the gaps are acknowledged) but is INJECTED into
#      the waiver census as `visual-divergent` and SPENDS waiver budget
#      (exit 19) — GREEN requires the budget to hold, and the recorded
#      divergence joins the degradation ledger as a fidelity-residual, so the
#      final verdict is at most YELLOW (PR-14 verdict model below).
#  14  Layout fill / grid coverage failed (gate 8c; #259 item 1) — a page in
#      layout-census.json dropped a tile (placed < zones) or ships under-filled
#      (grid_fill_pct < --min-grid-fill, default 0.45), OR a dashboard layout was
#      built but no census was emitted. build-dashboard-layout.rb produces the
#      census. Escape hatch: --skip-layout-fill "<reason>".
#  15  RCF fidelity ledger unresolved (gate 8d; DEFAULT-ON for converters that
#      stage the loop — PLAN-v3 PR-11) — the Phase 5g render-compare-fix ledger
#      (fidelity-ledger.json) is missing, or still carries spec-fixable deltas
#      that were never resolved. Run the RCF loop (scripts/fidelity-loop.rb) to
#      convergence, or waive named residuals with --accept-residuals id,id.
#      Enforcement resolution: --require-fidelity-ledger forces it on;
#      otherwise the gate reads <workdir>/migrate-state.json — a state whose
#      rcf_passes is positive (tableau-to-sigma stamps it at pass 1; legacy
#      pre-5g states without the key are the orchestrator's problem, it passes
#      the flag) auto-enables the gate, so a standalone gate run can no longer
#      silently skip the RCF phase. rcf_passes == 0 (the --rcf-passes 0
#      opt-out) is honored but RECORDED as the named waiver
#      --skip-fidelity-gate (budget-counted), never silence. Converters that
#      never stage the loop (no flag, no rcf_passes key) are unaffected.
#  16  Post-publish interactivity guide missing (gate 11) — the source dashboards
#      carry filter/highlight/nav ACTIONS (dashboard-layout-meta.json worksheets'
#      is_action filters, or the *-gaps-report.json "Dashboard filter / highlight /
#      nav actions" feature) that workbooks-as-code cannot port, and
#      <workdir>/POSTPUBLISH_GUIDE.md does not exist. Run
#      scripts/build-postpublish-guide.rb to generate the user handoff guide.
#      Escape hatch: --skip-postpublish-guide "<reason>".
#  17  Deferred DM elements unresolved (gate 12) — <workdir>/deferred-elements.json
#      is non-empty: post-and-readback.rb --quarantine-on-failure removed broken
#      element(s) at DM POST time to save the rest, so the LIVE data model is
#      PARTIAL. Resolve the deferred elements and re-POST: fix each element spec
#      in the file, restore it into the DM spec, PUT it back (post-and-readback
#      --update-id <dmId>), then delete the file. Escape hatch:
#      --accept-deferred-elements "<reason>" (knowingly shipping a partial DM —
#      name it AND the dropped elements in your migration report).
#  18  Source-anchor value verification failed (gate 13) — the MEASURED value
#      bar. When the workdir carries a source dashboard PNG (the Phase 1d
#      artifact: png-read.json source_png / views/*.png / dashboards/*.png),
#      <workdir>/source-anchors.json MUST exist with >= 5 anchors (printed
#      values transcribed EXACTLY as printed while reading the source image)
#      AND <workdir>/anchors-verdict.json (written by scripts/verify-anchors.rb)
#      must show pass with every anchor checked. A printed source value that
#      appears NOWHERE in the live workbook's element exports means the NUMBERS
#      are wrong — the failure two field migrations shipped behind passing
#      visual verdicts ("$1.2T" rendered where the source printed "12,345B").
#      No source dashboard PNG at all → stated SKIP. Escape hatch:
#      --skip-anchors-gate "<reason>" (counted against the waiver budget).
#      ALSO raised when --skip-parity-gate is passed WITHOUT a passing
#      anchors-verdict.json: waiving parity is now CONDITIONAL — the anchors
#      oracle replaces parity, never nothing.
#  19  Waiver budget exceeded — more than 2 QUALITY waiver/escape flags were
#      passed (--skip-*, --allow-extract, --allow-missing-tiles>0,
#      --min-pass-rate<1, --accept-*; a recorded `divergent` visual verdict is
#      injected as `visual-divergent` and counts, like the recorded no-vision
#      waiver). Each waiver is an attestation that a
#      verification could not run; stacking them is how an unverified workbook
#      ships GREEN. GREEN is unavailable on this run regardless of individual
#      escapes — the highest achievable result is YELLOW. Every run stamps
#      `waivers` + `waiver_count` (the full census) into parity-final.json so
#      the report (and any reviewer) sees the count. There is NO escape flag
#      for this cap. One POLICY exclusion never consumes the budget:
#        - --skip-visual-comparison ONLY under the sanctioned builder→verifier
#          split (its reason references the verifier, matched /verifier/i —
#          the verifier session records the verdict); any other reason counts.
#  20  Visual-similarity floor failed (gate 14) — scripts/visual-similarity.py
#      is present, a source dashboard PNG + Sigma render both exist, and the
#      measured comparison (python3 scripts/visual-similarity.py --source <src>
#      --render <render> --json-out <W>/visual-similarity.json) wrote
#      pass=false. Script absent → gate is invisible; inputs absent → stated
#      SKIP. Escape hatch: --skip-visual-similarity "<reason>" (counted against
#      the waiver budget).
#  21  Runtime control flip test failed (gate 7b; DEFAULT-ON via migrate-state
#      control_flip_required=true — tableau pass 1 stamps it — or forced via
#      --require-control-flip) — a control passed the static wiring lint
#      (gate 7) but does NOT actually filter its targets at runtime
#      (wired-but-inert / builder-level listen->column mis-mapping), proven by
#      scripts/probe-controls.rb; OR the probe could not run on an ENFORCED
#      gate and no recorded evidence exists (fail-closed: the gate requires
#      either the flip-test marker — a prior probe-results.json with >=1 PASS
#      and 0 FAIL, or the all-unprobeable control-flip-unverified.json
#      advisory marker — or the recorded waiver). Fix the listen mapping in
#      build_workbook.py + re-PUT, or re-run once the export API is reachable.
#      Un-probeable control types (date-range / slider) are an advisory WARN +
#      control-flip-unverified.json marker, not this failure.
#      Escape hatch: --skip-control-flip "<reason>" (counts against the budget).
#  22  Manual custom-SQL residues unresolved (gate 15) — <workdir>/manual-residues.json
#      (written at build time by converters that emit it) still carries entries
#      with status:"unbuilt": a window/table-calc residue (requires_custom_sql,
#      the STAYS-MANUAL family) that a dashboard tile PLOTS was never built as a
#      Custom SQL DM element and bound to the tile — the tile renders a
#      magnitude proxy, i.e. the NUMBERS are wrong. Build each residue (the
#      ledger entry carries the Tableau formula + an OVER() SQL skeleton),
#      repoint the tile measure, set status:"built" in the ledger, re-run.
#      Escape hatch: --accept-manual-residues "<calc,...>" — waives ONLY the
#      NAMED residues (budget-counted; name them in your migration report).
#      No ledger file → stated OK (converter declared no residues; back-compat).
#  23  Join-cardinality ledger unresolved (gate 16) — <workdir>/join-plan.json
#      (derived at DM-build time: one entry per federated source join + per
#      synthesized Lookup()) still carries an entry that is UNPROVEN (status
#      "unprobed"/"error") or proven "non-unique" with no recorded resolution.
#      Sigma's Lookup() returns ONE ARBITRARY match per key: a Lookup target
#      that is not unique at the key grain silently undercounts every aggregate
#      over the looked-up column — no error anywhere. Run
#      scripts/probe-join-keys.rb to prove each entry unique, pre-aggregate the
#      target (or escalate to the operator) for non-unique ones, and record the
#      evidence with --resolve. ALSO raised belt-and-braces when join-plan.json
#      is ABSENT but the workdir's dm-spec.json contains `Lookup(` — a Lookup
#      was synthesized and nothing proved its grain. No ledger AND no Lookup in
#      the dm-spec → stated OK (back-compat). NO escape flag: the resolution
#      path (probe → pre-aggregate or operator waiver, recorded in the ledger)
#      IS the sanctioned escape.
#  24  LOD translation ledger unresolved (gate 17; #423) — <workdir>/
#      lod-audit.json (derived post-convert by the source tool's LOD audit,
#      e.g. tableau audit-lod-calcs.rb / lib/lod_audit.rb) still carries an
#      entry with class "suspect-alias" (an emitted column carries an LOD
#      calc's name but its formula reads a base column NOT in the LOD
#      expression's own reference set — a fuzzy name-alias: the numbers are
#      silently WRONG) or "silently-dropped" (no emitted translation and no
#      manual-residues.json declaration) and no recorded resolution
#      {how: manual|waived, reason}. Field failure: 5 of 12
#      {FIXED entity: COUNTD(...)} measures aliased to unrelated raw flag
#      columns, 7 dropped — zero errors anywhere. Build the documented LOD
#      translation (grouped helper element / grouped Custom SQL) or declare a
#      manual residue and re-run the audit; hand-authored or operator-accepted
#      entries record their evidence via the audit script's --resolve. ALSO
#      raised belt-and-braces when lod-audit.json is ABSENT but the workdir's
#      calc-fields.json census carries an LOD calc (is_lod / {FIXED-INCLUDE-
#      EXCLUDE} formula) — LODs exist and nothing audited them. No ledger AND
#      no LOD census evidence → stated OK (back-compat / non-Tableau plugins).
#      NO escape flag: the ledger resolution IS the sanctioned escape.
#  25  Ground-truth numeric coverage failed (gate 18; PR-6) — the workdir's
#      <workdir>/ground-truth-plan.json coverage ledger (derive-ground-truth.rb)
#      exists, and at least one displayed tile is NOT numeric-verified by ANY
#      oracle: its `numeric_parity` stamp (written into parity-final.json /
#      numeric-parity.json by scripts/verify-ground-truth.rb) is not a `match`
#      from the warehouse-sql or vds ground truth, no VALUED anchors (numeric,
#      provenance view-csv|vds — never png-eyeball, never a name-only roster
#      label) matched in the tile, and the tile is not named in the ledger's
#      `coverage_waivers` [{tile, reason}]. A `diverge` or oracle-vs-anchors
#      `conflict` stamp is NEVER waivable. ALSO raised when the ledger exists
#      but the comparison never ran (or is stale vs the plan), and
#      belt-and-braces when the ledger is ABSENT on a workdir that carries the
#      derivation inputs (a .twb + parity-plan.json) — the oracle was skipped.
#      No ledger AND no derivation inputs → stated OK (back-compat /
#      non-Tableau plugins). NO escape flag: the ledger waiver IS the
#      sanctioned escape (join-plan/lod-audit pattern).
#  26  Aggregation-semantics ledger unresolved (gate 19; PR-7) — <workdir>/
#      agg-semantics.json (derived post-convert by the source tool's
#      aggregation lint, e.g. tableau audit-agg-semantics.rb /
#      lib/agg_semantics_lint.rb) still carries a hit with no recorded
#      resolution. Classes: "additive-over-preagg" (Sum/Avg over a column that
#      is itself an LOD pre-aggregate, or over a landed table whose declared
#      grain is coarser than the tile's group-by), "countd-as-sum" (a COUNTD
#      measure translated to / consumed via Sum — a distinct count is not
#      additive), "preagg-ratio" (a pre-aggregate-NAMED column — DISTINCT_*,
#      *_PCT, *_RATE, AVG_*, *_COUNT — consumed as a KPI numerator/
#      denominator). All compile clean and ship wrong-looking-right numbers
#      (field twin: a 103.3% "% entities with value" KPI from SUM over a
#      {FIXED day: COUNTD} column). Resolutions recorded via the lint script's
#      --resolve: reaggregated (rebuilt at the correct grain) | n/a(reason)
#      (the hit does not apply — first-class, never fabricate metadata) |
#      faithful-to-source(reason) (the source itself mixes grains; the
#      migration reproduces it and the resolution documents the hazard).
#      ALSO raised belt-and-braces when agg-semantics.json is ABSENT but the
#      workdir carries pre-aggregate evidence (a non-empty lod-audit.json, or
#      a calc-fields.json census with a COUNTD formula) — pre-aggregates exist
#      and nothing linted their consumption. No ledger AND no evidence →
#      stated OK (back-compat / non-Tableau plugins). NO escape flag: the
#      ledger resolution IS the sanctioned escape.
#  27  Semantic-edit equivalence ledger unproven (gate 20; PR-8) — <workdir>/
#      semantic-edits.json declares a structural edit to source semantics
#      (join drop, table collapse, filter rewrite) whose proof block is
#      MISSING (declared, never probed) or whose proof says match:false: the
#      probe measured different COUNT(*) / COUNT(DISTINCT grain) / SUM
#      checksums on the two sides, so the edit is NOT the no-op it was claimed
#      to be (field case: a LEFT JOIN on a non-unique flag key deleted as
#      "provably no-op" with zero verification — fan-out risk). "Provably
#      no-op" is proven by scripts/probe-equivalence.rb (in the source
#      plugin), never asserted. A mismatched edit NEVER ships: revert it
#      (removing the edit removes the entry) or redesign it until the probes
#      agree — an intentionally-different rewrite is not an equivalence claim
#      and belongs in the user-initiated scope-change record, not this
#      ledger. No ledger → stated OK (no structural semantic edits declared).
#      WITHDRAWN entries (the ledger's `withdrawn` array, written by
#      probe-equivalence.rb --withdraw for a refuted edit that was NOT
#      applied; the refuted proof rides along verbatim as evidence) do not
#      block but are reported informationally — a withdrawn edit whose SQL
#      nonetheless shipped is not mechanically detectable (gates 16/18 are
#      the net).
#      HONESTY NOTE: only DECLARED edits are policeable here — nothing
#      mechanical can see an edit nobody recorded. The operating-contract
#      rule makes the declaration mandatory, and the join-plan (gate 16) +
#      ground-truth (gate 18) oracles are the mechanical net for undeclared
#      ones (ground-truth SQL derives from the SOURCE signals independently
#      of the built spec, so a silently dropped join diverges there). NO
#      escape flag and NO waiver path: equivalence is measured, not
#      negotiated.
#  28  Chart-kind parity failed (gate 21; PR-10) — the workdir carries a
#      VERIFIED Phase 1d dashboard read (<workdir>/png-read.json, not a
#      verified:false draft) AND a live readback (<workdir>/wb-readback.json),
#      and at least one tile the operator verified against the source image
#      was BUILT in a different chart family: the readback element matched by
#      zone-census name normalization renders e.g. bars where the read says
#      line. The failure names each tile with its expected family (png-read)
#      and actual family (readback). Field failure this closes: corrected
#      kinds in a verified png-read.json never reached the built spec — the
#      builder propagates them (build-charts-from-signals.rb) and this gate
#      re-checks the LIVE workbook mechanically. Family vocabulary = the
#      blind-grader families (bar/line/area/combo/scatter/pie/kpi/map/table;
#      lib/blind_grade.rb). Sanctioned waiver: png-read.json kind_waivers
#      [{tile, reason}] — a fidelity decision recorded at read time (e.g. a
#      Sigma capability substitution), ledger-named like coverage_waivers and
#      NOT budget-counted. Tiles absent from png-read (unverified at read
#      time) or with no readback element by name are STATED, never failed
#      here (the dashboard-read gate / tile census own those). No png-read /
#      no readback / draft read → stated OK (N/A; never silent).
#  29  Layout-arrangement parity failed (gate 8e; OPT-IN via
#      --require-arrangement — WARN-level first release, PLAN-v3 PR-11) —
#      <workdir>/layout-arrangement.json (emitted by build-dashboard-layout.rb
#      beside the fill census) records ordering/class disagreements between
#      the SOURCE zone arrangement and the BUILT grid: row-band stacking
#      inversions, within-band left-right inversions, quadrant flips, or a
#      controls-shelf class mismatch (source top-shelf shipped as a sidebar
#      rail or vice versa — a 2026-07 field failure). Ordering/quadrant only,
#      no pixel IoU (robust to grid quantization). Without the flag the
#      violations print as advisory WARNs (stated, never silent); with it the
#      report must exist and be violation-free. Also raised under the flag
#      when a dashboard layout was built but the report is missing (rebuild
#      with a current build-dashboard-layout.rb).
#  30  Layout phase never entered (gate 4b, the layout-phase SENTINEL;
#      PLAN-v3 PR-11) — the workdir's run-state.json phase ledger is tracked
#      but its layout-phase key (tableau-to-sigma: phase-5) has NO stamp at
#      all: the orchestration took a silent shortcut and the dashboard grid
#      was never even attempted (field failure: a session skipped the layout
#      phase entirely and still handed over a workbook URL). A phase stamped
#      status:"skip" with a reason is honored but INJECTED into the waiver
#      census as `layout-phase-skip` (budget-counted) — a deliberate skip is
#      a recorded degradation, never a free pass. No run-state.json (the
#      hand-driven manual path) → stated SKIP; the artifact gates (4 live
#      layout, 8c fill census) still police the outputs. NO escape flag:
#      stamp the phase (run it, or record the skip with its reason).
#  31  Controls census failed (gate 7c; PLAN-v3 PR-13, V5.6 audit V-V3) — the
#      workdir's <workdir>/*-controls-coverage.json census (written by
#      build-charts-from-signals.rb --meta: one row per source parameter +
#      shared quick filter) carries a signal that was never built as a
#      control, has no declaring record in control-scope.json (dropped /
#      needs-* / narrow-scope — the drop decision with its evidence), and is
#      not named in the <workdir>/controls-waivers.json ledger
#      ([{"control":"filter:Region","reason":"…"}]): a source control the
#      user had that the migration silently lost. The failure names each
#      missing signal. Rebuild the controls (build-charts-from-signals.rb
#      --auto-controls), or record the ledger waiver with its reason. Also
#      raised when the census file exists but is malformed. NO escape flag:
#      the ledger waiver IS the sanctioned escape (join-plan/LOD doctrine).
#      No census file at all → stated SKIP (back-compat: builder predates the
#      census or ran without --meta; non-adopting converters).
#  32  Pre-POST render-integrity lint failed — a local workbook code-rep
#      candidate is unreadable/invalid, or one or more chart/KPI/table/pivot/
#      crosstab elements has no usable data binding. Inspect
#      <workdir>/blank-risk-elements.json, fix the local spec, then POST.
#
# ANCHORS-ORACLE substitution (charts_total==0, exit 2): when every worksheet is
# dashboard-embedded (no exportable view CSVs), the anchors oracle may stand in
# for value parity — but only when ALL FOUR hold: (a) anchors-verdict.json pass
# with every anchor matched, (b) every visual-verify tile confirmed, (c) every
# displayed tile exports >=1 data row, and (d) every displayed tile has ANCHOR
# COVERAGE (anchors-verdict.json anchor_coverage: covered==displayed) or is
# named in source-anchors.json coverage_waivers [{tile, reason}] (authored at
# Phase 1d). (d) closes the run-2 hole where all 11 anchors sat in 3 of 9 tiles
# and the oracle vouched for 6 tiles nothing was watching.
#
# VERDICT MODEL (PLAN-v3 PR-14 — cumulative-degradation accounting): on every
# run this gate derives <workdir>/degradation-ledger.json from the workdir's
# artifacts (lib/degradation_ledger.rb — scope cuts, quality waivers, recorded
# escapes, fidelity residuals, waived resolutions; deterministic, never
# self-reported) and prints ONE verdict with the ledger inline:
#   GREEN   — the ledger is EMPTY (waivers within budget alone is no longer
#             enough: any recorded degradation forfeits GREEN);
#   YELLOW  — quality degradations but no scope cut (a budget-exceeded run —
#             exit 19, doctrine unchanged — is always at least YELLOW);
#   PARTIAL — ANY scope cut (dropped tile / column / control / DM element)
#             regardless of the waiver budget; PARTIAL+YELLOW when both.
# The verdict string is stamped into phase6-success.json and parity-final.json;
# verify-complete.rb re-derives the ledger offline and FAILS (its exit 6) when
# a report's claims contradict it — the anti-"GREEN, 0 waivers" mechanism.
#
# DATA-CLASS RCF residuals (part of gate 8d, exit 15, but enforced whenever
# fidelity-ledger.json EXISTS — even without --require-fidelity-ledger): any
# UNRESOLVED ledger entry with class `data` hard-fails. Data-class residuals
# can never be waved through — the numbers are wrong; fix or reclassify with
# evidence. --accept-residuals does NOT apply to data-class ids and there is
# no escape flag.
#
# Prints a per-gate summary to stdout regardless of exit code.

require 'json'
require 'net/http'
require 'uri'
require 'optparse'
require 'rbconfig'
require 'digest'
require_relative 'lint-render-integrity'

# Degradation ledger (PLAN-v3 PR-14) — vendored at scripts/lib/ in adopting
# plugins; the canonical checkout resolves it from shared/lib. A checkout
# without it keeps the legacy final line (stated below, never silent).
DEG_LEDGER_LOADED = begin
  require_relative 'lib/degradation_ledger'
  true
rescue LoadError
  begin
    require_relative '../lib/degradation_ledger'
    true
  rescue LoadError
    false
  end
end

# Evidence ledger (PLAN-v4 E3.1) — same vendoring rule as the degradation
# ledger. A checkout without the lib still appends via the inline fallback in
# ev_append below (the substrate must exist even on stale vendorings).
EV_LEDGER_LOADED = begin
  require_relative 'lib/evidence_ledger'
  true
rescue LoadError
  begin
    require_relative '../lib/evidence_ledger'
    true
  rescue LoadError
    false
  end
end

# Workbook code-rep document wrapper (#608) — same vendoring rule as the
# ledgers above. GET /v2/workbooks/{id}/spec now nests pages/layout/
# schemaVersion/kind under a top-level `document` key (verified live
# 2026-08-03/04); a legacy flat readback (older wb-readback.json snapshots)
# still carries them at top level. fetch_live_spec below (gates 4/6/7/7b's
# shared live-spec memo) reads through CODE_REP_LOADED so a stale checkout
# without the lib keeps the old flat read (stated via a one-time WARN) rather
# than crashing — but every vendored copy carries it (manifest-listed
# alongside this file), so the flat fallback is not expected to fire live.
CODE_REP_LOADED = begin
  require_relative 'lib/code_rep'
  true
rescue LoadError
  begin
    require_relative '../lib/code_rep'
    true
  rescue LoadError
    false
  end
end

opts = { min_pass_rate: 1.0, allow_extract: false, min_layout_elements: 2,
         allow_missing_tiles: 0, min_parity_score: 0.0, min_grid_fill: 0.45 }
OptionParser.new do |p|
  p.on('--tableau DIR')              { |v| opts[:tab] = v }
  p.on('--workdir DIR', 'alias of --tableau for non-Tableau converters') { |v| opts[:tab] = v }
  p.on('--workbook-id ID')           { |v| opts[:wb] = v }
  p.on('--min-pass-rate F', Float)   { |v| opts[:min_pass_rate] = v }
  p.on('--min-parity-score F', Float, 'gate 1: fail if value_parity_score (mean per-tile, parity-score.json) < F (0..1, default 0 = off)') { |v| opts[:min_parity_score] = v }
  p.on('--allow-extract')            { opts[:allow_extract] = true }
  # These five accept an OPTIONAL reason (kept backward-compatible: a bare flag
  # still works). A skip with no reason is recorded as "NO REASON GIVEN" and
  # logged loudly so a silent bypass can't hide — see record_waiver below.
  p.on('--skip-column-check [REASON]')  { |v| opts[:skip_column] = v || true }
  p.on('--skip-orphan-check [REASON]')  { |v| opts[:skip_orphan] = v || true }
  p.on('--skip-layout-check [REASON]')  { |v| opts[:skip_layout] = v || true }
  p.on('--skip-layout-lint [REASON]')   { |v| opts[:skip_lint] = v || true }
  p.on('--skip-control-lint [REASON]')  { |v| opts[:skip_control_lint] = v || true }
  p.on('--control-scope PATH')       { |v| opts[:control_scope] = v }
  p.on('--require-control-flip', 'gate 7b: after control lint, PROVE each auto-probeable control actually filters its targets at runtime via scripts/probe-controls.rb (live REST export flip test). Closes the self-referential-sidecar hole in gate 7. DEFAULT-ON (PR-13) for workdirs whose migrate-state.json carries control_flip_required=true (tableau-to-sigma stamps it at pass 1); this flag forces it for everyone else (looker-to-sigma passes it).') { opts[:require_control_flip] = true }
  p.on('--skip-control-flip [REASON]', 'waive gate 7b (runtime control flip test) — budget-counted; the reason MUST be named in your migration report.') { |v| opts[:skip_control_flip] = v || true }
  p.on('--flip-check-leaks', 'gate 7b: also run probe --check-out-of-closure (asserts a flip does NOT leak to out-of-closure elements; doubles exports). Off by default.') { opts[:flip_check_leaks] = true }
  p.on('--min-layout-elements N', Integer) { |v| opts[:min_layout_elements] = v }
  p.on('--allow-missing-tiles N', Integer, 'tolerate N unmatched dashboard zones in the tile census') { |v| opts[:allow_missing_tiles] = v }
  p.on('--skip-parity-gate REASON', 'waive gate 1 (Phase 6 source-parity) — REQUIRED reason string. Use ONLY when source parity is genuinely unavailable (e.g. no source workspace/dataset/warehouse access). The reason MUST be named in your migration report.') { |v| opts[:skip_parity] = v }
  p.on('--sigma-render PATH', 'gate 8: path to the rendered Sigma dashboard PNG (default: <workdir>/sigma-render.png; also accepts <workdir>/screenshots/_manifest.json)') { |v| opts[:sigma_render] = v }
  p.on('--skip-visual-gate REASON', 'waive gate 8 (Phase 6f visual render) — REQUIRED reason string. Use ONLY when the workbook genuinely cannot be rendered (e.g. export API unavailable). The reason MUST be named in your migration report.') { |v| opts[:skip_visual] = v }
  p.on('--require-visual-comparison', 'DEPRECATED — gate 8b is now enforced by default; this flag is a no-op kept for back-compat.') { opts[:require_visual_cmp] = true }
  p.on('--skip-visual-comparison REASON', 'waive gate 8b (source-vs-target visual verdict) — REQUIRED reason string. Use ONLY when the source dashboard image is genuinely unobtainable (no source render/export access). The reason MUST be named in your migration report.') { |v| opts[:skip_visual_cmp] = v }
  p.on('--skip-visual-tiles REASON', 'waive gate 9 (build-from-signals tile image-verification) — REQUIRED reason string. The reason MUST be named in your migration report.') { |v| opts[:skip_visual_tiles] = v }
  p.on('--min-grid-fill F', Float, 'gate 8c: minimum per-page grid_fill_pct (0..1, default 0.45) — pages below fail as mostly-empty') { |v| opts[:min_grid_fill] = v }
  p.on('--skip-layout-fill REASON', 'waive gate 8c (layout fill / grid coverage) — REQUIRED reason string. Use ONLY when a sparse/partial page is intentional. The reason MUST be named in your migration report.') { |v| opts[:skip_layout_fill] = v }
  p.on('--skip-postpublish-guide REASON', 'waive gate 11 (post-publish interactivity guide) — REQUIRED reason string. Use ONLY when the source dashboard actions are genuinely not worth a handoff guide. The reason MUST be named in your migration report.') { |v| opts[:skip_postpublish] = v }
  p.on('--accept-deferred-elements REASON', 'waive gate 12 (deferred/quarantined DM elements) — REQUIRED reason string. Use ONLY when knowingly shipping a PARTIAL data model; the reason AND the dropped elements MUST be named in your migration report.') { |v| opts[:accept_deferred] = v }
  p.on('--require-fidelity-ledger', 'gate 8d: require an RCF fidelity-ledger.json (Phase 5g) with zero UNRESOLVED spec-fixable deltas. DEFAULT-ON (PR-11) for workdirs whose migrate-state.json staged the loop (rcf_passes > 0 — tableau-to-sigma); this flag forces it for everyone else.') { opts[:require_fidelity] = true }
  p.on('--fidelity-ledger PATH', 'gate 8d: path to the RCF ledger (default: <workdir>/fidelity-ledger.json)') { |v| opts[:fidelity_ledger] = v }
  p.on('--skip-fidelity-gate REASON', 'waive gate 8d (RCF fidelity ledger) — REQUIRED reason string; the named waiver migrate-tableau.rb --finalize records for --rcf-passes 0. Counted against the waiver budget; name it in your migration report. (Data-class ledger entries still block whenever the ledger exists.)') { |v| opts[:skip_fidelity] = v }
  p.on('--require-arrangement', 'gate 8e (OPT-IN, off by default — WARN-level first release, PR-11): require <workdir>/layout-arrangement.json (build-dashboard-layout.rb) to exist and carry ZERO source-vs-built arrangement violations (stacking/ordering inversions, quadrant flips, controls-shelf class mismatch). Without the flag, violations print as advisory WARNs.') { opts[:require_arrangement] = true }
  p.on('--arrangement-report PATH', 'gate 8e: path to the arrangement report (default: <workdir>/layout-arrangement.json)') { |v| opts[:arrangement_report] = v }
  p.on('--accept-residuals LIST', 'gate 8d: comma-separated ledger entry ids/indices to WAIVE as accepted residuals (name them in the report). Does NOT apply to data-class entries — those must be fixed or reclassified with evidence.') { |v| opts[:accept_residuals] = v.split(',').map(&:strip) }
  p.on('--skip-anchors-gate REASON', 'waive gate 13 (source-anchor value verification) — REQUIRED reason string. Use ONLY when the source image values are genuinely untranscribable. Counted against the waiver budget; name it in your migration report.') { |v| opts[:skip_anchors] = v }
  p.on('--allow-empty-tiles REASON', 'gate 13: accept displayed dashboard tile(s) that export ZERO data rows — REQUIRED reason string that MUST cite the source PNG showing the chart is genuinely empty on the SOURCE dashboard. Never use this to wave away a broken data path (filter/calc bug). Counted against the waiver budget; name it in your migration report.') { |v| opts[:allow_empty_tiles] = v }
  p.on('--skip-visual-similarity REASON', 'waive gate 14 (measured visual-similarity floor) — REQUIRED reason string. Counted against the waiver budget; name it in your migration report.') { |v| opts[:skip_vsim] = v }
  p.on('--accept-manual-residues LIST', 'gate 15: comma-separated residue CALC names from <workdir>/manual-residues.json to WAIVE as accepted-unbuilt (their tiles keep the magnitude proxy — name each in your migration report). Counted against the waiver budget. Unnamed unbuilt residues still fail (exit 22).') { |v| opts[:accept_manual_residues] = v.split(',').map(&:strip).reject(&:empty?) }
end.parse!
abort('--workdir (or --tableau) required') unless opts[:tab]

# A waived gate must never pass SILENTLY. record_waiver prints a loud banner and
# appends to <workdir>/waivers.json so the migration report (and any future
# check) can see every gate that was bypassed and why. A bare skip (no reason)
# is recorded as "NO REASON GIVEN" — visible, not invisible. (CoCo run wrapped
# up GREEN after silently skipping checks — this makes that impossible.)
# ---------------------------------------------------------------------------
# Evidence ledger (PLAN-v4 E3.1) — append-only <workdir>/evidence-ledger.jsonl.
# Every gate verdict that terminates or waives this run lands here with the
# raw-evidence pointer and the strict version-keyed identity, so factory-mode's
# punch-list (and #7's recorded-evidence acceptance) can consume it:
#   * every WAIVE  — via the record_waiver hook below;
#   * every FAIL   — via the at_exit recorder (the documented exit-code
#                    contract maps 1:1 to gates, EXIT_GATE_MAP);
#   * the terminal PASS — the success block appends the run-summary verdict;
#   * evidence-bearing gates (7b, 21) append their detail entries in-line.
# Reads happen in gate 7b: a prior probe's RAW results are accepted only
# age-+version-+sha-checked, and its verdict is RECOMPUTED (#7 red line —
# recorded verdicts are never consumed). ev_append is the inline fallback twin
# of lib/evidence_ledger.rb#append — keep the line schema in lockstep.
# ---------------------------------------------------------------------------
EXIT_GATE_MAP = {
  1 => '1', 2 => '1', 3 => '1', 4 => '2', 5 => '3', 6 => '4', 7 => '5', 8 => '6',
  9 => '7', 10 => '8', 11 => '9', 13 => '8b', 14 => '8c', 15 => '8d',
  16 => '11', 17 => '12', 18 => '13', 19 => 'waiver-budget', 20 => '14', 21 => '7b',
  22 => '15', 23 => '16', 24 => '17', 25 => '18', 26 => '19', 27 => '20', 28 => '21',
  29 => '8e', 30 => '4b', 31 => '7c', 32 => 'render-integrity'
}.freeze
# Primary raw-evidence artifact per gate (workdir-relative) — the punch-list
# pointer; gates without a stable artifact just omit the field.
GATE_EVIDENCE_PATHS = {
  '1' => 'parity-final.json', '2' => 'posted-workbooks.jsonl', '4b' => 'run-state.json',
  '5' => 'parity-final.json', '7b' => 'probe-controls/probe-results.json',
  '7c' => nil, '8' => 'sigma-render.png', '8b' => 'blind-grade.json',
  '8c' => 'layout-census.json', '8d' => 'fidelity-ledger.json',
  '8e' => 'layout-arrangement.json', '9' => 'visual-verify-tiles.json',
  '11' => 'POSTPUBLISH_GUIDE.md',
  '12' => 'deferred-elements.json', '13' => 'anchors-verdict.json',
  '14' => 'visual-similarity.json', '15' => 'manual-residues.json',
  '16' => 'join-plan.json', '17' => 'lod-audit.json', '18' => 'ground-truth-plan.json',
  '19' => 'agg-semantics.json', '20' => 'semantic-edits.json', '21' => 'png-read.json',
  'render-integrity' => 'blank-risk-elements.json',
  'waiver-budget' => 'waivers.json'
}.freeze
# The version-keyed base identity for this run's evidence: workbook id (flag /
# wb-ids.json / readback) + latestDocumentVersion (readback; refreshed by the
# live spec memo below when it fetches). "v?" marks unknown — reuse checks
# refuse it (fail-closed), recording still names the workbook.
ev_identity = begin
  _id = opts[:wb]
  _id ||= (JSON.parse(File.read(File.join(opts[:tab], 'wb-ids.json')))['workbookId'] rescue nil)
  _rb = (JSON.parse(File.read(File.join(opts[:tab], 'wb-readback.json'))) rescue nil)
  _id ||= (_rb.is_a?(Hash) ? _rb['workbookId'] : nil)
  _vr = _rb.is_a?(Hash) ? (_rb['latestDocumentVersion'] || _rb['latestVersion']) : nil
  { 'wb' => _id.to_s.empty? ? '?' : _id.to_s, 'ver' => _vr.nil? || _vr.to_s.empty? ? nil : _vr.to_s }
end
ev_key = lambda do |element_id = nil|
  k = "wb:#{ev_identity['wb']}@v#{ev_identity['ver'] || '?'}"
  element_id ? "#{k}/el:#{element_id}" : k
end
ev_append = lambda do |gate, verdict, kind = nil, epath = nil, ekey = nil, esha = nil, detail = nil|
  if EV_LEDGER_LOADED
    EvidenceLedger.append(opts[:tab], gate: gate, verdict: verdict, evidence_kind: kind,
                          evidence_path: epath, evidence_key: ekey || ev_key.call,
                          evidence_sha256: esha, detail: detail)
  else
    e = { 'gate' => gate.to_s, 'verdict' => verdict.to_s }
    e['evidence_kind'] = kind.to_s if kind
    e['evidence_path'] = epath.to_s if epath
    e['evidence_key'] = (ekey || ev_key.call).to_s
    e['evidence_sha256'] = esha.to_s if esha
    e['detail'] = detail if detail.is_a?(Hash) && !detail.empty?
    e['at'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    File.open(File.join(opts[:tab], 'evidence-ledger.jsonl'), 'a') { |f| f.puts(JSON.generate(e)) } rescue nil
    e
  end
end
# Every failing exit leaves a ledger line naming its gate (the exit-code
# contract is 1:1). Registered here — after the usage abort above — so bad
# invocations never mint entries. Success entries are appended by the
# terminal block (which knows the derived verdict), not here.
# A10 (wave-1 review): a plain `abort` is exit 1, which the map reads as gate
# '1' — so a PRE-GATE env abort (creds, workdir, lib load) would mislabel the
# ledger. gate_context_started flips true where gate-1 evaluation begins;
# until then the ambiguous statuses (1–3, the gate-'1' band) are not
# ledgered. A plain abort BETWEEN later gates still lands as gate '1' —
# accepted, documented noise (the map is deliberately coarse).
gate_context_started = false
at_exit do
  _st = $!
  next unless _st.is_a?(SystemExit) && !_st.success?
  next if _st.status <= 3 && !gate_context_started
  _g = EXIT_GATE_MAP[_st.status]
  next unless _g
  _ep = GATE_EVIDENCE_PATHS[_g]
  _ep = nil unless _ep && File.exist?(File.join(opts[:tab], _ep))
  ev_append.call(_g, 'fail', 'gate-exit', _ep, nil, nil, { 'exit' => _st.status })
end

# Current run id (minted by the orchestrator at each PASS-1 start; nil for
# converters without the concept). Read here — ABOVE record_waiver — so the
# E3.1 gate-waived offramp lines below can carry it; the run-scoped completion
# sentinel and the waivers_history merge further down are the other consumers.
current_run_id = begin
  JSON.parse(File.read(File.join(opts[:tab], 'migrate-state.json')))['run_id']
rescue StandardError
  nil
end
current_run_id ||= begin
  JSON.parse(File.read(File.join(opts[:tab], 'run-state.json')))['run_id']
rescue StandardError
  nil
end

waivers = []
record_waiver = lambda do |flag, gate, reason|
  r = (reason.is_a?(String) && !reason.strip.empty?) ? reason.strip : nil
  waivers << { 'flag' => flag, 'gate' => gate, 'reason' => r }
  puts "[SKIP] #{gate} WAIVED via #{flag}#{r ? " (#{r})" : ' — NO REASON GIVEN'}"
  puts "       MUST be named in the migration report#{r ? '' : ' WITH a reason'}; this gate did NOT verify the workbook."
  File.write(File.join(opts[:tab], 'waivers.json'), JSON.pretty_generate(waivers)) rescue nil
  # E3.1: a waived gate is a first-class ledger verdict — the punch list must
  # see what was never verified.
  _g = gate.to_s[/gate ([0-9]+[a-z]?)/, 1] || gate.to_s
  ev_append.call(_g, 'waived', 'waiver', 'waivers.json', nil, nil,
                 { 'flag' => flag, 'reason' => r || 'NO REASON GIVEN' })
  # E3.1 substrate: the same waiver is APPENDED to <workdir>/offramps.jsonl as
  # a gate-waived line (stdlib append — preserving this script's deliberate
  # no-lib-dependency stance). waivers.json and the parity-final `waivers`
  # census are REWRITTEN per invocation, so a waiver forced mid-run (flaky
  # render, later retried clean) would otherwise vanish from the final
  # accounting; the census-stamp block merges these appended records back into
  # parity-final.json `waivers_history` with status superseded-by-pass —
  # never deleted, never re-counted as zero.
  begin
    _orec = { 'kind' => 'gate-waived', 'gate' => _g, 'flag' => flag,
              'reason' => r || 'NO REASON GIVEN' }
    _orec['run_id'] = current_run_id if current_run_id
    _orec['at'] = Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    File.open(File.join(opts[:tab], 'offramps.jsonl'), 'a') { |f| f.puts(JSON.generate(_orec)) }
  rescue StandardError
    nil # bookkeeping only — never fail the gate
  end
end

# Extract-drift tolerance surfacing: verify-anchors.rb --extract-tol (extract-
# based sources only) can admit a numeric anchor within a RECORDED relative
# tolerance instead of at printed precision. Every gate that cites the anchors
# verdict must SAY so — a tolerance-admitted pass silently presented as a
# printed-precision pass is exactly the laundering the anchor lock exists to
# stop. Returns a note string ('' when no tolerance was used).
anchors_tol_note = lambda do |av|
  return '' unless av.is_a?(Hash) && av['matched_via_tolerance'].to_i.positive?
  et = av['extract_tolerance'].is_a?(Hash) ? av['extract_tolerance'] : {}
  "\n       NOTE: #{av['matched_via_tolerance']} anchor(s) matched only within the extract drift tolerance" \
    " (--extract-tol #{et['requested'] || '?'}#{et['reason'] ? ", #{et['reason']}" : ''}) — the source PNG shows" \
    ' extract-stale values; anchors were NOT edited. Name this in your migration report.'
end

summary_path = File.join(opts[:tab], 'parity-final.json')

# ── Run-scoped completion sentinel ──────────────────────────────────────────
# phase6-success.json is only valid FOR the current run id (read above
# record_waiver): on exit 0 we stamp it with the current id; on ANY failure we
# delete a success marker left by a PREVIOUS run id, so verify-complete.rb can
# never report DONE off a stale marker. Converters without a run_id concept
# fall back to nil (the marker is then deleted on every failure — fail-closed).
at_exit do
  st = $!
  next unless st.is_a?(SystemExit) && !st.success?
  succ = File.join(opts[:tab], 'phase6-success.json')
  next unless File.exist?(succ)
  old_id = (JSON.parse(File.read(succ))['run_id'] rescue nil)
  # Keep a same-run success (a re-run of an already-green run with a failing
  # extra flag must not unmint it); delete anything else — it is stale.
  unless current_run_id && old_id && old_id == current_run_id
    File.delete(succ) rescue nil
    warn "[SENTINEL] stale phase6-success.json (run #{old_id || '?'}) deleted — this run (#{current_run_id || '?'}) FAILED the gate."
  end
end

# ---------------------------------------------------------------------------
# Gate 8d enforcement resolution (PLAN-v3 PR-11) — DEFAULT-ON for converters
# that stage the RCF loop. migrate-state.json records rcf_passes at pass 1
# (tableau-to-sigma); a positive value auto-enables --require-fidelity-ledger
# so a standalone gate run (the finalize path already passes the flag) can no
# longer reach GREEN with the RCF phase silently skipped. rcf_passes == 0 is
# the explicit --rcf-passes 0 opt-out: honored, but converted into the NAMED
# --skip-fidelity-gate waiver (budget-counted, recorded in waivers.json +
# parity-final.json) instead of silence. States without the key (other
# converters / non-RCF workdirs) change nothing.
# ---------------------------------------------------------------------------
opts[:fidelity_auto] = nil
begin
  _ms_rcf = JSON.parse(File.read(File.join(opts[:tab], 'migrate-state.json')))
  if _ms_rcf.is_a?(Hash) && _ms_rcf.key?('rcf_passes') && !opts[:skip_fidelity]
    if _ms_rcf['rcf_passes'].to_i.positive?
      opts[:fidelity_auto] = "migrate-state.json rcf_passes=#{_ms_rcf['rcf_passes']}" unless opts[:require_fidelity]
      opts[:require_fidelity] = true
    elsif !opts[:require_fidelity]
      opts[:skip_fidelity] = 'RCF loop disabled at pass 1 (--rcf-passes 0, recorded in migrate-state.json)'
    end
  end
rescue StandardError
  nil # no/unreadable state → opt-in behavior unchanged
end

# ---------------------------------------------------------------------------
# Gate 7b enforcement resolution (PLAN-v3 PR-13) — DEFAULT-ON for workdirs
# whose orchestrator staged the runtime flip test. migrate-tableau.rb stamps
# control_flip_required=true into migrate-state.json at pass 1; that
# auto-enables --require-control-flip here so a STANDALONE gate run (the
# finalize path already passes the flag) cannot silently skip the flip test.
# --skip-control-flip stays the named, budget-counted waiver. States without
# the key (other converters / legacy workdirs) keep the opt-in behavior.
# ---------------------------------------------------------------------------
opts[:flip_auto] = nil
begin
  _ms_cf = JSON.parse(File.read(File.join(opts[:tab], 'migrate-state.json')))
  if _ms_cf.is_a?(Hash) && _ms_cf['control_flip_required'] &&
     !opts[:require_control_flip] && !opts[:skip_control_flip]
    opts[:flip_auto] = 'migrate-state.json control_flip_required=true'
    opts[:require_control_flip] = true
  end
rescue StandardError
  nil # no/unreadable state → opt-in behavior unchanged
end

# ---------------------------------------------------------------------------
# Layout-phase sentinel resolution (gate 4b, PLAN-v3 PR-11) — read the phase
# ledger ONCE up front so a deliberate skip stamp can join the waiver census
# below (the gate body prints/fails later). Only converters with a registered
# layout-phase key participate; run-state.json absent → not tracked.
# ---------------------------------------------------------------------------
LAYOUT_PHASE_BY_TOOL = { 'tableau-to-sigma' => 'phase-5' }.freeze
run_state_doc = begin
  _p = File.join(opts[:tab], 'run-state.json')
  File.exist?(_p) ? JSON.parse(File.read(_p)) : nil
rescue StandardError
  nil
end
layout_phase_key = run_state_doc.is_a?(Hash) ? LAYOUT_PHASE_BY_TOOL[run_state_doc['tool'].to_s] : nil
layout_phase_stamp = layout_phase_key &&
                     (run_state_doc['phases'].is_a?(Hash) ? run_state_doc['phases'][layout_phase_key] : nil)

# ---------------------------------------------------------------------------
# Waiver budget (exit 19). EVERY waiver/escape flag is counted — --skip-*,
# --allow-extract, --allow-missing-tiles>0, --min-pass-rate<1, --accept-* —
# and the census is stamped into parity-final.json (`waivers` + `waiver_count`)
# on EVERY run, pass or fail. More than 2 waivers caps the run below GREEN
# (checked at the end, so individual gate failures still surface first). Waiver
# stacking is how a field run shipped an unverified workbook: each escape was
# individually arguable, and together they waived away the whole value bar.
# ---------------------------------------------------------------------------
WAIVER_BUDGET = 2

# ---------------------------------------------------------------------------
# Wave-2 tier ratchet — the GATE half (W2.1). Lane A's orchestrator resolves
# --tier {auto|S|M|full} at pass 1 and writes the RESOLVED tier to
# <workdir>/migrate-state.json as 'tier' + 'tier_basis' (closed vocabularies:
# shared/lib/offramp.rb TIER_VALUES/TIER_BASIS; canonical example pinned in
# shared/lib/testdata/wave2-tier-state.json — cross-lane contract 4). This
# gate READS the tier; it never derives one. Doctrine (frozen): a tier NEVER
# removes a gate — the 25-gate catalog identity is fixed; tiers scale BUDGETS
# and admit duplicate-oracle substitutions only (gate 18's Tier-S
# valued-anchors acceptance below). Fail-closed: state missing/unreadable or
# an unknown tier string → nil → byte-identical full-battery behavior.
# ---------------------------------------------------------------------------
run_tier = nil
run_tier_basis = nil
begin
  _ms_tier = JSON.parse(File.read(File.join(opts[:tab], 'migrate-state.json')))
  if _ms_tier.is_a?(Hash) && %w[S M full].include?(_ms_tier['tier'].to_s)
    run_tier       = _ms_tier['tier'].to_s
    # tier_basis is display-only but still closed-vocabulary on READ
    # (Offramp::TIER_BASIS; literals — non-vendored twins run this gate too):
    # an unknown string is blanked, never printed raw into the [TIER] banner.
    _ms_basis      = _ms_tier['tier_basis'].to_s
    run_tier_basis = %w[auto-predicate operator-override fail-closed].include?(_ms_basis) ? _ms_basis : ''
  end
rescue StandardError
  nil # fail-closed: no readable tier → full battery
end
# Tier-scaled waiver budget: a Tier-S workbook is small enough that waiver
# stacking is a LOUDER signal, so the budget SHRINKS to 1 (a budget change is
# never a catalog change). M/full keep the shipped budget of 2.
effective_waiver_budget = run_tier == 'S' ? 1 : WAIVER_BUDGET
if run_tier
  puts "[TIER] #{run_tier}#{run_tier_basis.to_s.empty? ? '' : " (#{run_tier_basis})"} — " \
       "waiver budget #{effective_waiver_budget}; all 25 gates execute (tiers scale budgets, never the catalog)"
end

WAIVER_HIDES = {
  '--skip-parity-gate'         => 'gate 1: values were never diffed against the source',
  '--min-pass-rate'            => 'gate 1: charts that DIVERGE from the source were accepted',
  '--allow-extract'            => 'gate 1: value drift tolerated (extract mode)',
  '--skip-orphan-check'        => 'gate 2: orphan workbooks may remain in My Documents',
  '--skip-column-check'        => 'gate 3: live type=error columns not scanned',
  '--skip-layout-check'        => 'gate 4: layout-applied never verified on the live workbook',
  '--allow-missing-tiles'      => 'gate 5: source tiles absent from the build were accepted',
  '--skip-layout-lint'         => 'gate 6: layout quality never linted',
  '--skip-control-lint'        => 'gate 7: control wiring never linted',
  '--skip-control-flip'        => 'gate 7b: control wiring never proven at runtime',
  '--skip-visual-gate'         => 'gate 8: no rendered PNG was required',
  '--skip-visual-comparison'   => 'gate 8b: no source-vs-target visual verdict was required',
  '--no-vision-waiver'         => 'gate 8b: the visual PASS was SELF-graded — no context-free blind grader ran (recorded by record-visual-check.rb --no-vision-waiver)',
  'visual-divergent'           => 'gate 8b: the recorded visual verdict is DIVERGENT — acknowledged source-vs-target visual gaps ship in the render (joins the degradation ledger as a fidelity-residual; verdict at most YELLOW)',
  '--skip-layout-fill'         => 'gate 8c: dropped/under-filled pages were accepted',
  '--accept-residuals'         => 'gate 8d: named RCF deltas shipped unresolved',
  '--skip-fidelity-gate'       => 'gate 8d: the RCF fidelity loop was never required — compositional deltas (palette, chart kind, KPI format) were never iterated (--rcf-passes 0 records this waiver)',
  'layout-phase-skip'          => 'gate 4b: the layout phase was deliberately skipped (run-state stamp status:"skip") — the dashboard grid was never built this run',
  '--skip-visual-tiles'        => 'gate 9: build-from-signals tiles never image-verified',
  '--skip-postpublish-guide'   => 'gate 11: interactivity handoff guide not required',
  '--accept-deferred-elements' => 'gate 12: a PARTIAL data model was accepted',
  '--skip-anchors-gate'        => 'gate 13: source-anchor values never verified (the measured value bar)',
  '--allow-empty-tiles'        => 'gate 13: displayed dashboard tile(s) that render no data were accepted',
  '--skip-visual-similarity'   => 'gate 14: visual-similarity floor never measured',
  '--accept-manual-residues'   => 'gate 15: named custom-SQL residues shipped UNBUILT (their tiles render a magnitude proxy)',
  # Runtime off-ramps (recorded to <workdir>/offramps.jsonl by the scripts that
  # honored them; counted here so an escape taken MID-RUN spends budget exactly
  # like a gate flag):
  '--force-new-workbook'       => 'run: a prior workbook for this workdir was deliberately orphaned (new POST)',
  '--force-route-switch'       => 'run: the workdir was re-driven via the OTHER route (orchestrated vs manual)',
  '--allow-manual-spec'        => 'run: hand-authored specs / standalone POST with no orchestrator STOP on record'
}.freeze
waiver_flags = []
waiver_flags << '--skip-parity-gate'         if opts[:skip_parity]
waiver_flags << '--min-pass-rate'            if opts[:min_pass_rate] < 1.0
waiver_flags << '--allow-extract'            if opts[:allow_extract]
waiver_flags << '--skip-orphan-check'        if opts[:skip_orphan]
waiver_flags << '--skip-column-check'        if opts[:skip_column]
waiver_flags << '--skip-layout-check'        if opts[:skip_layout]
waiver_flags << '--allow-missing-tiles'      if opts[:allow_missing_tiles].to_i.positive?
waiver_flags << '--skip-layout-lint'         if opts[:skip_lint]
waiver_flags << '--skip-control-lint'        if opts[:skip_control_lint]
# Unconditional (the gate-8d pattern): waiving the flip test is an attestation
# whether or not enforcement resolved on — PR-13 made the gate default-on for
# tableau workdirs, so the skip is always a recorded quality degradation.
waiver_flags << '--skip-control-flip'        if opts[:skip_control_flip]
waiver_flags << '--skip-visual-gate'         if opts[:skip_visual]
waiver_flags << '--skip-visual-comparison'   if opts[:skip_visual_cmp]
waiver_flags << '--skip-layout-fill'         if opts[:skip_layout_fill]
waiver_flags << '--accept-residuals'         if opts[:accept_residuals] && !opts[:accept_residuals].empty?
waiver_flags << '--skip-fidelity-gate'       if opts[:skip_fidelity]
# A deliberate layout-phase skip stamp is an in-run waiver, injected like the
# off-ramp kinds below: the phase was consciously not run, and that spends
# budget exactly like a gate flag (gate 4b prints the record).
waiver_flags << 'layout-phase-skip'          if layout_phase_stamp.is_a?(Hash) && layout_phase_stamp['status'] == 'skip'
waiver_flags << '--skip-visual-tiles'        if opts[:skip_visual_tiles]
waiver_flags << '--skip-postpublish-guide'   if opts[:skip_postpublish]
waiver_flags << '--accept-deferred-elements' if opts[:accept_deferred]
waiver_flags << '--skip-anchors-gate'        if opts[:skip_anchors]
waiver_flags << '--allow-empty-tiles'        if opts[:allow_empty_tiles]
waiver_flags << '--skip-visual-similarity'   if opts[:skip_vsim]
waiver_flags << '--accept-manual-residues'   if opts[:accept_manual_residues] && !opts[:accept_manual_residues].empty?

# Runtime waivers taken MID-RUN (off-ramp trail, offramps.jsonl): a forced new
# workbook, a forced route switch, or an unauthorized manual-spec run each spend
# the same budget as a gate flag — otherwise an escape honored by a SCRIPT would
# be invisible to the cap that exists to stop waiver stacking. Read directly
# (plain JSONL; no lib dependency — this file is shared across plugins). Counted
# once per kind.
begin
  _or_path = File.join(opts[:tab], 'offramps.jsonl')
  if File.exist?(_or_path)
    _or_kinds = File.readlines(_or_path).map { |l| JSON.parse(l) rescue nil }.compact
    waiver_flags << '--force-new-workbook' if _or_kinds.any? { |r| r['kind'] == 'force-new-workbook' } &&
                                              !waiver_flags.include?('--force-new-workbook')
    waiver_flags << '--force-route-switch' if _or_kinds.any? { |r| r['kind'] == 'route-switch-forced' } &&
                                              !waiver_flags.include?('--force-route-switch')
    waiver_flags << '--allow-manual-spec'  if _or_kinds.any? { |r| r['kind'] == 'manual-spec' && r['reason'].to_s.start_with?('waiver:') } &&
                                              !waiver_flags.include?('--allow-manual-spec')
  end
rescue StandardError
  nil # observability only — never sink the gate on trail parsing
end

# PR-9: a pass recorded under the no-vision-grader waiver (record-visual-check
# --no-vision-waiver stamps blind_grade_waiver into parity-final.json) spends
# budget exactly like a gate flag — a self-graded visual pass is a quality
# degradation, never a freebie.
#
# A RECORDED divergent visual verdict spends budget the same way: gate 8b
# accepts it as RECORDED (the comparison happened; the gaps are acknowledged),
# but acknowledged source-vs-target visual gaps riding to GREEN unqualified is
# exactly the live-run failure this closes (blind grade FAIL 5/6, verdict
# recorded divergent, final GREEN). Injected into the census as
# `visual-divergent` so the budget line names it; the degradation ledger
# (PR-14) additionally records it as a fidelity-residual, capping the verdict
# at YELLOW even when the budget holds.
begin
  _pf_bgw = File.exist?(summary_path) ? JSON.parse(File.read(summary_path)) : nil
  waiver_flags << '--no-vision-waiver' if _pf_bgw.is_a?(Hash) && _pf_bgw['blind_grade_waiver'].is_a?(Hash) &&
                                          !waiver_flags.include?('--no-vision-waiver')
  waiver_flags << 'visual-divergent' if _pf_bgw.is_a?(Hash) && _pf_bgw['visual_verdict'].to_s == 'divergent' &&
                                        !waiver_flags.include?('visual-divergent')
rescue StandardError
  nil
end

# QUALITY waivers consume the budget; the POLICY waiver never does:
#   - --skip-visual-comparison under the sanctioned builder→verifier split
#     (reason references the verifier, /verifier/i) hands the verdict to the
#     verifier session instead of waiving it — any OTHER reason counts.
budget_flags = waiver_flags.reject do |f|
  f == '--skip-visual-comparison' && opts[:skip_visual_cmp].to_s =~ /verifier/i
end

# Reasons census (PR-14): the flag → recorded-reason map rides into
# parity-final.json beside the census, so the degradation ledger (derived
# OFFLINE here and by verify-complete.rb) can explain each waiver and decide
# the /verifier/i policy exclusion without re-parsing CLI flags.
_reason_srcs = {
  '--skip-parity-gate'         => opts[:skip_parity],
  '--skip-orphan-check'        => opts[:skip_orphan],
  '--skip-column-check'        => opts[:skip_column],
  '--skip-layout-check'        => opts[:skip_layout],
  '--skip-layout-lint'         => opts[:skip_lint],
  '--skip-control-lint'        => opts[:skip_control_lint],
  '--skip-control-flip'        => opts[:skip_control_flip],
  '--skip-visual-gate'         => opts[:skip_visual],
  '--skip-visual-comparison'   => opts[:skip_visual_cmp],
  '--skip-layout-fill'         => opts[:skip_layout_fill],
  '--skip-fidelity-gate'       => opts[:skip_fidelity],
  '--skip-visual-tiles'        => opts[:skip_visual_tiles],
  '--skip-postpublish-guide'   => opts[:skip_postpublish],
  '--accept-deferred-elements' => opts[:accept_deferred],
  '--skip-anchors-gate'        => opts[:skip_anchors],
  '--allow-empty-tiles'        => opts[:allow_empty_tiles],
  '--skip-visual-similarity'   => opts[:skip_vsim],
  '--accept-residuals'         => (Array(opts[:accept_residuals]).any? ? "accepted RCF residual(s): #{Array(opts[:accept_residuals]).join(', ')}" : nil),
  '--accept-manual-residues'   => (Array(opts[:accept_manual_residues]).any? ? "accepted unbuilt residue(s): #{Array(opts[:accept_manual_residues]).join(', ')}" : nil),
  '--min-pass-rate'            => (opts[:min_pass_rate] < 1.0 ? "accepted pass rate #{opts[:min_pass_rate]}" : nil),
  '--allow-missing-tiles'      => (opts[:allow_missing_tiles].to_i.positive? ? "tolerated #{opts[:allow_missing_tiles]} unmatched dashboard zone(s)" : nil),
  '--allow-extract'            => (opts[:allow_extract] ? 'extract mode accepted (value drift tolerated)' : nil),
  'layout-phase-skip'          => (layout_phase_stamp.is_a?(Hash) ? layout_phase_stamp['reason'] : nil)
}
waiver_reasons = {}
waiver_flags.each do |f|
  v = _reason_srcs[f]
  waiver_reasons[f] = v.to_s.strip if v.is_a?(String) && !v.to_s.strip.empty?
end

# E3.1 waivers_history: merge this run's previously APPENDED gate-waived
# offramp records (record_waiver writes them) into the stamp. waivers.json and
# the `waivers` census are rewritten per invocation, so a waiver forced on
# invocation 1 (flaky render, later retried clean) would otherwise vanish once
# invocation 2 passes. Same-run records whose flag is absent from the CURRENT
# census get status superseded-by-pass — never deleted, never re-counted as
# zero; still-active flags read active. The history is the epic-wide
# pending-state substrate (E3.2's verifier-pending rides it as an entry kind).
waivers_history = begin
  _orp = File.join(opts[:tab], 'offramps.jsonl')
  _gw = File.exist?(_orp) ? File.readlines(_orp).map { |l| JSON.parse(l) rescue nil }.compact : []
  _gw.select { |rec| rec['kind'] == 'gate-waived' && rec['run_id'].to_s == current_run_id.to_s }
     .each_with_object({}) do |rec, h|
       k = [rec['flag'].to_s, rec['gate'].to_s]
       h[k] ||= { 'flag' => rec['flag'], 'gate' => rec['gate'], 'reason' => rec['reason'],
                  'first_waived_at' => rec['at'],
                  'status' => waiver_flags.include?(rec['flag'].to_s) ? 'active' : 'superseded-by-pass' }
       h[k]['times_recorded'] = (h[k]['times_recorded'] || 0) + 1
     end.values
rescue StandardError
  [] # observability only — never sink the gate on trail parsing
end

# Stamp the census into parity-final.json on every run (best-effort — a
# missing/malformed file is gate 1's problem, not the stamp's).
if File.exist?(summary_path)
  begin
    _pf = JSON.parse(File.read(summary_path))
    _pf['waivers'] = waiver_flags
    _pf['waiver_count'] = waiver_flags.length
    _pf['waiver_reasons'] = waiver_reasons
    _pf['waivers_history'] = waivers_history
    _pf['waivers_history_count'] = waivers_history.length
    # Off-ramp telemetry fields (P2): where did this run defect? route comes from
    # the orchestrator's migrate-state.json ('orchestrated' | 'manual-authorized';
    # null for converters without the concept); manual_path_authorized records an
    # orchestrator STOP token; success_sentinel is stamped false here and flipped
    # true ONLY at the green exit below.
    _pf['route'] = (JSON.parse(File.read(File.join(opts[:tab], 'migrate-state.json')))['route'] rescue nil)
    _pf['manual_path_authorized'] = File.exist?(File.join(opts[:tab], 'manual-path-authorized.json'))
    _pf['success_sentinel'] = false
    File.write(summary_path, JSON.pretty_generate(_pf))
  rescue JSON::ParserError
    nil
  end
end
if waiver_flags.any?
  excluded = waiver_flags - budget_flags
  puts "[WAIVERS] #{waiver_flags.length} waiver/escape flag(s) on this run: #{waiver_flags.join(', ')} — " \
       "#{budget_flags.length} count against the budget of #{effective_waiver_budget}" \
       "#{effective_waiver_budget < WAIVER_BUDGET ? " (Tier-#{run_tier} scaled from #{WAIVER_BUDGET})" : ''}" \
       "#{excluded.any? ? " (policy exclusions: #{excluded.join(', ')})" : ''}" \
       ' (exceeding the budget caps the run below GREEN, exit 19)'
end
# E3.1 headline honesty: prior same-run waivers a later invocation passed are
# announced whenever they exist — INCLUDING on a zero-current-waiver run, so
# the headline count never silently drops to a clean-looking zero.
_superseded = waivers_history.select { |h| h['status'] == 'superseded-by-pass' }
if _superseded.any?
  puts "[WAIVERS] history: #{_superseded.length} prior waiver(s) this run superseded by a later pass " \
       "(#{_superseded.map { |h| h['flag'] }.join(', ')}) — retained in parity-final.json waivers_history; " \
       'the current census counts THIS invocation only, never a silent zero.'
end

# Gate evaluation begins HERE — exits 1–3 are gate-1 verdicts from now on
# (see the at_exit recorder's A10 guard above).
gate_context_started = true

# ---------------------------------------------------------------------------
# Gate 0 — local pre-POST render integrity (exit 32)
# Prefer the authored spec, then its conventional alternate name. A readback is
# deliberately not a candidate: this is a pre-POST gate, while readback-only
# fixtures and legacy runs use the later live-column/render gates. This gate is
# intentionally conditional on a LOCAL authored candidate; older live-only
# converter runs never retained one, and their
# existing live gates remain authoritative. When a candidate exists there is
# no waiver — a data element with no binding is a deterministic blank-render
# risk and must be fixed before another POST.
# ---------------------------------------------------------------------------
render_spec_path = %w[wb-spec.json workbook-spec.json]
                   .map { |name| File.join(opts[:tab], name) }
                   .find { |path| File.exist?(path) }
render_evidence_path = File.join(opts[:tab], 'blank-risk-elements.json')
if render_spec_path
  begin
    render_report = RenderIntegrity.lint_file(render_spec_path, out_path: render_evidence_path)
  rescue RenderIntegrity::InputError => e
    begin
      RenderIntegrity.write_error_report(render_spec_path, render_evidence_path, e.message)
    rescue RenderIntegrity::InputError => write_error
      warn "[FAIL] render-integrity gate could not record evidence: #{write_error.message}"
    end
    warn "[FAIL] render-integrity gate: #{e.message}"
    warn "       Fix #{render_spec_path}; evidence: #{render_evidence_path}"
    exit 32
  end

  if render_report['status'] == 'FAIL'
    warn "[FAIL] render-integrity gate: #{render_report['blank_risk_count']} of " \
         "#{render_report['elements_checked']} data element(s) have no usable data bindings:"
    render_report['elements'].each do |element|
      warn "         - #{element['id']} (#{element['name'].inspect}, #{element['kind']}): " \
           "#{element['reasons'].join('; ')}"
    end
    warn "       Fix #{render_spec_path} before POST; evidence: #{render_evidence_path}"
    exit 32
  end

  puts "[OK] render-integrity gate: #{render_report['elements_checked']} data element(s) checked in " \
       "#{File.basename(render_spec_path)}; 0 blank risks (evidence: blank-risk-elements.json)"
else
  puts '[SKIP] render-integrity gate: no local wb-spec.json or workbook-spec.json candidate; ' \
       'legacy live-only run preserved'
end

if opts[:skip_parity]
  # CONDITIONAL waiver: --skip-parity-gate is rejected unless the anchors
  # oracle stands in. Parity can be genuinely unavailable (no source workspace
  # access, dashboard-embedded worksheets with no standalone views) — but "no
  # parity AND no anchors" means the numbers were never measured against the
  # source at all, which is exactly how a wrong-numbers workbook shipped GREEN.
  # The anchors oracle replaces parity, never nothing.
  _av_path = File.join(opts[:tab], 'anchors-verdict.json')
  _av = File.exist?(_av_path) ? (JSON.parse(File.read(_av_path)) rescue nil) : nil
  unless _av.is_a?(Hash) && _av['pass'] == true
    warn '[FAIL] --skip-parity-gate REJECTED — the anchors oracle replaces parity, never nothing.'
    warn "       #{_av.nil? ? "#{_av_path} does not exist" : 'anchors-verdict.json does not show pass'} —"
    warn '       waiving source parity requires the MEASURED value bar to stand in:'
    warn '       1. Transcribe the source dashboard\'s printed values into <workdir>/source-anchors.json'
    warn '          at Phase 1d (EXACTLY as printed; schema: SKILL.md Phase 1d / refs/source-anchors.md).'
    warn "       2. Run: ruby scripts/verify-anchors.rb --workdir #{opts[:tab]} --workbook-id <id>"
    warn '       3. Re-run this gate once anchors-verdict.json shows pass.'
    warn '       (If parity IS obtainable, drop --skip-parity-gate and run Phase 6 instead.)'
    exit 18
  end
  puts "[SKIP] gate 1/7: Phase 6 source-parity WAIVED via --skip-parity-gate (#{opts[:skip_parity]})."
  puts "       Accepted because the anchors oracle stands in: anchors-verdict.json pass " \
       "(#{_av['matched']}/#{_av['checked']} anchors matched).#{anchors_tol_note.call(_av)}"
  puts '       This waiver MUST be named in the migration report — the workbook was NOT chart-by-chart verified vs the source.'
else
  unless File.exist?(summary_path)
    warn "[FAIL] Phase 6 skipped — #{summary_path} does not exist."
    warn "       Run: ruby scripts/phase6-parity.rb --tableau #{opts[:tab]} --workbook-id <id>"
    warn "       then collect actuals via mcp__sigma-mcp-v2__query and re-run with --finalize."
    warn "       See SKILL.md Phase 6. This is the hard gate (beads-sigma-4pm)."
    warn "       If source parity is genuinely unavailable (no workspace/dataset/warehouse access), waive"
    warn "       with --skip-parity-gate \"<reason>\" and name it in the report — but note the waiver is"
    warn "       CONDITIONAL: it is rejected (exit 18) unless anchors-verdict.json exists and passes"
    warn "       (ruby scripts/verify-anchors.rb). The anchors oracle replaces parity, never nothing."
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
    # ORACLE SUBSTITUTION (not a waiver): a workbook whose every worksheet is
    # dashboard-embedded exports NO standalone view CSVs, so the value-parity
    # pool is legitimately empty. The numbers are still machine-verified when
    # BOTH hold: (a) anchors-verdict.json passes with EVERY source anchor
    # matched against live element exports, and (b) every empty-export tile is
    # image-verified (visual-verify manifest all true — or, when no manifest
    # exists at all, a recorded page-level visual verdict stands in, see
    # below). Then the anchors oracle IS the parity evidence — same doctrine
    # as the conditional --skip-parity-gate acceptance, but deterministic, and
    # it burns no waiver budget because nothing is skipped.
    _av = (JSON.parse(File.read(File.join(opts[:tab], 'anchors-verdict.json'))) rescue nil)
    _vv = (JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))) rescue nil)
    if _vv.is_a?(Array) && _vv.any?
      _vv_ok = _vv.all? { |t| t['visual_verified'] == true }
      _vv_source = :manifest
    else
      # No Tableau-style per-tile visual-verify manifest (the other 7
      # converters sharing this gate script have no verify-visual-tiles.rb
      # equivalent) -- fall back to the page-level record-visual-check.rb
      # verdict already stamped into parity-final.json (same fields gate 8b
      # reads below: visual_checked/screenshot_path/visual_verdict), as long
      # as it is genuinely vision-backed, not a blind/not-executable
      # attestation (same doctrine as gate 8b's own §D5 check).
      _page_recorded = summary['visual_checked'] || summary['screenshot_path'] ||
                        summary['visual_verdict'].to_s == 'divergent'
      _page_vision_blocked = (summary.key?('agent_vision') && summary['agent_vision'] == false) ||
                             summary['visual_verdict'].to_s == 'not-executable'
      _vv_ok = _page_recorded && !_page_vision_blocked
      _vv_source = :page_verdict
    end
    # W1.1: condition (c) — every DISPLAYED dashboard tile must export >=1 data
    # row. A 2026-07 field-workbook run passed (a) + (b) with all 15 anchors
    # matched, yet every chart rendered "No data": the anchors matched only in the
    # raw unfiltered feeder table, and no gate checked that the DISPLAYED tiles
    # carry data. verify-anchors now writes tiles_all_nonempty + dashboard_tiles_empty.
    # Fail closed if the field is absent (a stale anchors-verdict from a pre-W1.1
    # verify-anchors) — re-running verify-anchors is cheap and mandatory here.
    _tiles_ok = _av.is_a?(Hash) && _av['tiles_all_nonempty'] == true
    _tiles_field_present = _av.is_a?(Hash) && _av.key?('tiles_all_nonempty')
    # G10 condition (d) — per-displayed-tile ANCHOR COVERAGE. The run-2 oracle
    # passed with all 11 anchors inside 3 of 9 displayed tiles: the other 6
    # tiles had ZERO anchors watching them, so the oracle vouched for numbers
    # nobody measured. When the oracle SUBSTITUTES for parity, every displayed
    # tile must be covered (anchors-verdict.json anchor_coverage, written by
    # verify-anchors.rb) OR be explicitly waived in source-anchors.json
    # coverage_waivers [{tile, reason}] (authored at Phase 1d, alongside the
    # anchors). A verdict predating the measurement fails closed — re-running
    # verify-anchors is cheap and mandatory here (same doctrine as W1.1).
    _cov = _av.is_a?(Hash) ? _av['anchor_coverage'] : nil
    _sa_doc = (JSON.parse(File.read(File.join(opts[:tab], 'source-anchors.json'))) rescue nil)
    _cov_waived = Array(_sa_doc.is_a?(Hash) ? _sa_doc['coverage_waivers'] : nil)
                  .map { |w| w.is_a?(Hash) ? w['tile'].to_s.downcase.strip : nil }
                  .compact.reject(&:empty?)
    if _cov.is_a?(Hash)
      _cov_unwaived = Array(_cov['uncovered']).map(&:to_s)
                      .reject { |t| _cov_waived.include?(t.downcase.strip) }
      _cov_ok = _cov_unwaived.empty?
      _n_waived = Array(_cov['uncovered']).length - _cov_unwaived.length
    else
      _cov_unwaived = nil
      _cov_ok = false
      _n_waived = 0
    end
    if _av && _av['pass'] && _av['checked'].to_i >= 5 && _av['matched'] == _av['checked'] && _vv_ok && _tiles_ok && _cov_ok
      _vv_note = _vv_source == :manifest ? "all #{_vv.size} tile(s) image-verified" :
        "page-level visual verdict recorded (#{summary['visual_verdict'] || 'checked'})"
      puts "[PASS] gate 2 (value parity): 0 exportable view CSVs (all worksheets dashboard-embedded) — " \
           "the ANCHORS ORACLE stands in: anchors-verdict.json pass " \
           "(#{_av['matched']}/#{_av['checked']} anchors matched, #{_av['anchors_matched_in_displayed'] || '?'} in displayed tiles) " \
           "+ #{_vv_note} + all displayed tiles return data " \
           "+ anchor coverage #{_cov['covered']}/#{_cov['displayed']} displayed tile(s)" \
           "#{_n_waived.positive? ? " (#{_n_waived} coverage-waived at Phase 1d)" : ''}." \
           "#{anchors_tol_note.call(_av)}"
    else
      warn "[FAIL] parity-final.json reports charts_total=#{total} — no charts were verified."
      warn "       This usually means auto-parity-plan.rb matched zero Tableau views."
      warn "       Phase 6 must verify at least one chart to declare GREEN."
      warn '       If every worksheet is dashboard-embedded (no exportable view CSVs), the'
      warn '       anchors oracle can stand in — ALL FOUR must hold:'
      warn "         a) verify-anchors.rb pass with EVERY anchor matched (#{_av ? "currently #{_av['matched']}/#{_av['checked']}" : 'anchors-verdict.json missing'})"
      warn "         b) every visual-verify tile confirmed (#{_vv_ok ? 'ok' : 'incomplete'})"
      if _vv_source == :page_verdict && !_vv_ok
        warn '            (no manifest.json + no recorded page-level visual verdict — run'
        warn '             scripts/record-visual-check.rb to satisfy this condition when your'
        warn '             converter has no visual-verify/manifest.json generator)'
      end
      if _tiles_field_present
        empty = (_av['dashboard_tiles_empty'] || [])
        warn "         c) every displayed tile returns >=1 data row (#{_tiles_ok ? 'ok' : "#{empty.length} tile(s) EMPTY: #{empty.map { |t| t['name'] }.first(6).join(', ')}"})"
      else
        warn '         c) every displayed tile returns >=1 data row (UNKNOWN — anchors-verdict.json'
        warn '            predates this gate; re-run scripts/verify-anchors.rb to measure tile emptiness)'
      end
      if _cov.is_a?(Hash)
        warn "         d) every displayed tile has anchor coverage or a Phase 1d coverage waiver " \
             "(#{_cov_ok ? 'ok' : "#{_cov_unwaived.length} tile(s) UNCOVERED: #{_cov_unwaived.first(6).join(', ')}"})"
        unless _cov_ok
          warn '            An anchor only vouches for the tile it lands in. Transcribe anchors for each'
          warn '            uncovered tile (re-read the source PNG), or — if a tile genuinely prints no'
          warn '            anchorable value — name it in source-anchors.json coverage_waivers'
          warn '            [{"tile": "<name>", "reason": "<why>"}], then re-run verify-anchors.rb.'
        end
      else
        warn '         d) per-displayed-tile anchor coverage (UNKNOWN — anchors-verdict.json predates the'
        warn '            anchor_coverage measurement; re-run scripts/verify-anchors.rb)'
      end
      exit 2
    end
  end

  if total.positive? && mode == 'extract' && !opts[:allow_extract]
    warn "[FAIL] parity ran in extract-mode but --allow-extract was not passed."
    warn "       Extract-mode permits up to ±#{((summary['extract_tol'] || 0.30) * 100).to_i}% drift —"
    warn "       only acceptable when the source Tableau workbook has hasExtracts=true."
    exit 2
  end

  # (total==0 only reaches here through the anchors-oracle substitution above —
  # there is no rate/status to gate on an empty pool.)
  pass_rate = total.positive? ? passed.to_f / total : 1.0
  # status=PASS requires 100% — when the caller explicitly accepts a lower
  # pass-rate (--min-pass-rate, for honest NAMED divergences like LOD
  # placeholders / cross-grain semantics), the rate is the gate, not the status.
  rate_gate_only = opts[:min_pass_rate] < 1.0
  if total.positive? &&
     (rate_gate_only ? pass_rate < opts[:min_pass_rate] : (status != 'PASS' || pass_rate < opts[:min_pass_rate]))
    warn "[FAIL] parity status=#{status} pass-rate=#{(pass_rate * 100).round(1)}% (#{passed}/#{total})"
    warn "       Required: #{rate_gate_only ? '' : 'status=PASS and '}pass-rate >= #{(opts[:min_pass_rate] * 100).to_i}%"
    if (fail_names = summary['fail_names']) && !fail_names.empty?
      warn "       Failing charts: #{fail_names.join(', ')}"
    end
    if (pending = summary['pending_names']) && !pending.empty?
      warn "       Pending render-verify (pivot CSV export 500/empty fallback): #{pending.join(', ')} —"
      warn '       verify each via render-read or direct SQL, set "render_verified": true on the chart'
      warn '       in parity-plan.json, then re-run phase6-parity.rb --finalize.'
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
    posted = []
    invalid_lines = []
    File.readlines(log).each_with_index do |line, index|
      next if line.strip.empty?
      entry = (JSON.parse(line) rescue nil)
      if entry.is_a?(Hash) && entry['id'].is_a?(String) && !entry['id'].empty?
        posted << entry
      else
        invalid_lines << index + 1
      end
    end
    if invalid_lines.any?
      warn "[FAIL] gate 2/7: posted-workbooks.jsonl has malformed/unsafe entries at line(s) #{invalid_lines.join(', ')}."
      warn '       Refusing to infer cleanup state from a partial ledger.'
      exit 4
    end
    unique_ids = posted.map { |e| e['id'] }.uniq
    if unique_ids.length > 1
      marker_path = File.join(opts[:tab], 'cleanup-marker.json')
      unless File.exist?(marker_path)
        warn "[FAIL] gate 2/7: #{unique_ids.length} workbooks created during this conversion (orphans not cleaned)."
        warn "       posted-workbooks.jsonl entries:"
        unique_ids.each { |id| warn "         - #{id}" }
        live_id = opts[:wb]
        if live_id.nil?
          wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
          live_id = (JSON.parse(File.read(wb_ids_path))['workbookId'] rescue nil) if File.exist?(wb_ids_path)
        end
        warn "       Review: ruby scripts/cleanup-orphan-workbooks.rb --workdir #{opts[:tab]} --keep #{live_id || '<live-workbook-id>'} --dry-run"
        warn '       Then run without --dry-run in an interactive terminal and confirm each deletion.'
        warn "       See beads-sigma-38a."
        exit 4
      end
      marker = JSON.parse(File.read(marker_path)) rescue {}
      unless marker.is_a?(Hash) && marker['kept'].is_a?(String)
        warn '[FAIL] gate 2/7: cleanup-marker.json is malformed or has no explicit kept workbook ID.'
        exit 4
      end
      if marker['failed'] && !marker['failed'].empty?
        warn "[FAIL] gate 2/7: cleanup-marker.json reports #{marker['failed'].length} failed delete(s)."
        warn "       Orphan workbooks are still in the customer's My Documents:"
        marker['failed'].each { |f| warn "         - #{f['id']} (HTTP #{f['status']})" }
        exit 4
      end
      if marker['skipped'] && !marker['skipped'].empty?
        warn "[FAIL] gate 2/7: the user kept #{marker['skipped'].length} cleanup candidate(s)."
        marker['skipped'].each { |entry| warn "         - #{entry['id']}" }
        warn '       This is safe, but orphan cleanup is incomplete.'
        exit 4
      end
      if marker['dry_run']
        warn "[FAIL] gate 2/7: cleanup-marker.json is from a --dry-run; orphans were not actually deleted."
        warn '       Re-run cleanup-orphan-workbooks.rb without --dry-run in an interactive terminal.'
        exit 4
      end
      kept = marker['kept']
      unless unique_ids.include?(kept)
        warn "[FAIL] gate 2/7: cleanup-marker.json kept #{kept}, which is not in the current ledger."
        warn '       The marker is stale or belongs to another workdir/run.'
        exit 4
      end
      live_id = opts[:wb]
      if live_id.nil?
        wb_ids_path = File.join(opts[:tab], 'wb-ids.json')
        live_id = (JSON.parse(File.read(wb_ids_path))['workbookId'] rescue nil) if File.exist?(wb_ids_path)
      end
      if live_id && kept != live_id
        warn "[FAIL] gate 2/7: cleanup kept #{kept}, but the authoritative live workbook is #{live_id}."
        warn '       Refusing a marker that could describe deletion of the wrong workbook set.'
        exit 4
      end
      deleted_ids = Array(marker['deleted']).map { |entry| entry.is_a?(Hash) ? entry['id'] : entry }.compact.uniq
      expected_deleted = unique_ids - [kept]
      missing = expected_deleted - deleted_ids
      unexpected = deleted_ids - expected_deleted
      if missing.any? || unexpected.any?
        warn '[FAIL] gate 2/7: cleanup-marker.json does not exactly cover the current ledger.'
        warn "       Missing confirmed deletions: #{missing.join(', ')}" if missing.any?
        warn "       Unexpected deletion records: #{unexpected.join(', ')}" if unexpected.any?
        warn '       Re-run the interactive cleanup review; stale markers cannot satisfy this gate.'
        exit 4
      end
      puts "[OK] gate 2/7: user-confirmed orphan cleanup — kept #{kept}, deleted #{deleted_ids.length}"
    else
      puts "[OK] gate 2/7: only one workbook POSTed (#{unique_ids.first}) — no orphan check needed"
    end
  else
    puts "[OK] gate 2/7: posted-workbooks.jsonl missing — assuming no orphans (legacy or external POST flow)"
  end
else
  record_waiver.call('--skip-orphan-check', 'gate 2 (orphan-workbook cleanup)', opts[:skip_orphan])
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

  # ruzs: a runtime SKIP of this audit must be RECORDED, never a free pass —
  # column-scan.json is derived into the degradation ledger (quality-waiver →
  # verdict at most YELLOW). complete-clean is the positive evidence that
  # keeps GREEN reachable. Written best-effort: bookkeeping must not sink the
  # gate run, and the hard-fail paths (creds, error columns) exit 5 anyway.
  record_column_scan = lambda do |h|
    File.write(File.join(opts[:tab], 'column-scan.json'),
               JSON.pretty_generate({ 'gate' => 'gate 3/7 live column type=error scan' }.merge(h)))
  rescue StandardError
    nil
  end

  if wb_id.nil? || wb_id.empty?
    puts "[SKIP] gate 3/7: no workbook ID resolvable (pass --workbook-id or ensure wb-ids.json exists)"
    puts '       Recorded to column-scan.json — joins the degradation ledger as a'
    puts '       quality-waiver: an unaudited workbook caps the verdict at YELLOW.'
    record_column_scan.call('status' => 'skipped-no-workbook-id',
                            'reason' => 'no workbook ID resolvable (no --workbook-id and no wb-ids.json)')
  else
    base = ENV['SIGMA_BASE_URL']
    tok  = ENV['SIGMA_API_TOKEN']
    if base.nil? || base.empty? || tok.nil? || tok.empty?
      # FAIL CLOSED (field-caught): a hard gate that SKIPS without credentials
      # "passes" on any machine where the env wasn't sourced — the exact way a
      # run ships with unverified live columns. The gate needs the live check.
      warn '[FAIL] gate 3/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — the live column-type check CANNOT run.'
      warn '       Source your env (e.g. `source ~/.sigma-migration/env && eval "$(scripts/get-token.sh)"`)'
      warn '       and re-run this gate. A credential-less run is NOT a passing run.'
      exit 5
    else
      # PAGINATED: limit=1000, following nextPage to exhaustion. This is gate 3/7's
      # error-column audit. A bare first-page GET truncates at the server default of
      # 50, which would let THIS GATE pass a wide workbook whose type=="error"
      # columns sat past column 50 — the exact false GREEN the gate exists to
      # prevent. Local loop rather than Sigma.list_entries: this gate deliberately
      # carries no sigma_rest dependency.
      cols = []
      res  = nil
      page = nil
      seen = {}
      complete = false   # did the scan reach the END of the column list?
      loop do
        qs  = 'limit=1000'
        qs += "&page=#{URI.encode_www_form_component(page)}" if page
        uri = URI("#{base}/v2/workbooks/#{wb_id}/columns?#{qs}")
        req = Net::HTTP::Get.new(uri)
        req['Authorization'] = "Bearer #{tok}"
        req['Accept'] = 'application/json'
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                              read_timeout: 30) { |h| h.request(req) }
        break unless res.is_a?(Net::HTTPSuccess)
        doc = (JSON.parse(res.body) rescue nil)
        break unless doc.is_a?(Hash)
        cols.concat(doc['entries'] || [])
        page = doc['nextPage']
        if page.nil? || page.to_s.empty?
          complete = true   # exhausted the list — the ONLY way this is a full scan
          break
        end
        # A repeated token means the server is misbehaving; stop, but do NOT claim
        # a complete scan.
        break if seen[page]
        seen[page] = true
      end

      # Error columns are decisive REGARDLESS of whether the scan completed. A column
      # we DID see with type=error is a real failure, and a transient failure on a
      # later page must never downgrade it to a SKIP.
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
      elsif !complete
        warn "[SKIP] gate 3/7: the live column scan of #{wb_id} did NOT complete " \
             "(#{cols.length} column(s) read; HTTP #{res&.code}) — cannot verify."
        warn '       No type=error column was found in what WAS read, but an incomplete'
        warn '       scan does not prove the workbook clean. Re-run this gate.'
        warn '       Recorded to column-scan.json — joins the degradation ledger as a'
        warn '       quality-waiver: an unverified scan caps the verdict at YELLOW.'
        record_column_scan.call('status' => 'skipped-incomplete',
                                'columns_read' => cols.length,
                                'http' => res&.code,
                                'reason' => "live column scan of #{wb_id} did not complete")
      else
        puts "[OK] gate 3/7: #{cols.length} live columns clean (no type=error)"
        record_column_scan.call('status' => 'complete-clean', 'columns_read' => cols.length)
      end
    end
  end
else
  record_waiver.call('--skip-column-check', 'gate 3 (live column type=error scan)', opts[:skip_column])
end

# ---------------------------------------------------------------------------
# ONE live spec fetch per gate run (#7 dedup — speed review, reconciled
# program). Gates 4, 6, 7, and 7b all read the live workbook spec; before this
# memo each paid its own GET /v2/workbooks/{id}/spec — up to four identical
# round-trips per gate run. The fetch happens ONCE and is shared; every gate
# still computes its own verdict from the (raw) spec. The memo also refreshes
# the evidence-key version and names a stale wb-readback.json loudly — a new
# POST/PUT bumps latestDocumentVersion, so the post-POST readback stops being
# a valid spec source the moment the live version moves past it (#7b:
# version-check before reuse; the readback is never silently substituted for
# the live spec here — live gates verify live state).
# Returns { 'spec' => Hash|nil, 'code' => nil|HTTP-code }; network-level
# exceptions propagate exactly as they did from the per-gate fetches.
# ---------------------------------------------------------------------------
live_spec_memo = {}
fetch_live_spec = lambda do |wb_id, base, tok|
  # Keyed on [workbook, base] (A8, wave-1 review): a divergent per-gate base
  # URL must never be silently served the OTHER environment's spec.
  memo_k = [wb_id.to_s, base.to_s]
  return live_spec_memo[memo_k] if live_spec_memo.key?(memo_k)
  uri = URI("#{base}/v2/workbooks/#{wb_id}/spec")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{tok}"
  req['Accept'] = 'application/json'
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 30) { |h| h.request(req) }
  live_spec_memo[memo_k] =
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
      live_ver = spec.is_a?(Hash) ? (spec['latestDocumentVersion'] || spec['latestVersion']) : nil
      if live_ver && !live_ver.to_s.empty?
        if ev_identity['ver'] && ev_identity['ver'] != live_ver.to_s
          warn "[WARN] wb-readback.json is STALE — readback doc v#{ev_identity['ver']}, live doc v#{live_ver}." \
               ' A later POST/PUT changed the workbook; artifacts derived from the readback may be outdated.' \
               ' Re-run phase6-parity.rb PASS 1 to refresh it.'
        end
        ev_identity['ver'] = live_ver.to_s # evidence keys bind to LIVE state
      end
      # Unwrap ONCE here so every downstream gate (4/6/7/7b, all read through
      # this memo) inherits the fix: the live GET nests pages/layout under
      # `document` (see CODE_REP_LOADED above) — without this, gate 4's
      # spec['layout'] read is always nil and hard-FAILs exit 6 on every
      # workbook, the regression this memo fixes. A stale checkout without
      # lib/code_rep.rb keeps the old flat spec (WARNed once, not silent).
      if CODE_REP_LOADED
        spec = Sigma::CodeRep.document(spec)
      else
        warn '[WARN] scripts/lib/code_rep.rb not vendored alongside this script (re-vendor;' \
             ' md5 discipline) — gates 4/6/7/7b read the RAW (possibly document-nested) spec' \
             ' and may misreport an empty layout/pages on a live nested readback.'
      end
      { 'spec' => spec, 'code' => nil }
    else
      { 'spec' => nil, 'code' => res.code }
    end
end

# ---------------------------------------------------------------------------
# Gate 4 — layout applied (beads-sigma-bw3)
# Fetches the live workbook spec and confirms a non-empty top-level `layout`
# XML is set, with at least --min-layout-elements canonical <Element> tags.
# Catches the "agent forgot to PUT a layout" regression where elements
# render as a single-column stack instead of the dashboard grid.
# ---------------------------------------------------------------------------
# Live positioned-element count from gate 4's spec fetch — reused by gate 8c to
# reconcile a stale zone-derived census against a hand-authored layout. nil when
# gate 4 was skipped / no token.
live_layout_positioned = nil
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
      # FAIL CLOSED — same doctrine as gate 3/7: no credentials, no live layout
      # verification, no pass.
      warn '[FAIL] gate 4/7: SIGMA_BASE_URL / SIGMA_API_TOKEN not set — the live layout check CANNOT run.'
      warn '       Source your env and re-run this gate. A credential-less run is NOT a passing run.'
      exit 6
    else
      fetched = fetch_live_spec.call(wb_id, base, tok)

      if fetched['spec']
        spec = fetched['spec']
        layout_xml = spec['layout'].to_s
        elem_count = layout_xml.scan(/<Element\b/).length
        legacy_tag_count = layout_xml.scan(%r{</?(?:LayoutElement|GridContainer)\b}).length
        live_layout_positioned = elem_count

        # Detect the Sigma "auto-generated single-column stack" layout that
        # the server produces when a workbook is POSTed without a layout.
        # Signature: every non-Data page has all its elements at the same
        # gridColumn value (typically "1 / 13" — left half, vertically stacked).
        # Note: per-page detection — a workbook with one element per content
        # page is structurally fine (degenerate case, not a stack).
        # Container-banded pages (<Container> bands per layout-playbook.md)
        # are exempt: full-width band containers (and single-chart rows inside
        # them) legitimately share gridColumn="1 / 25" — that is deliberate
        # banding, not the auto-stack regression.
        non_data_stack_pages = []
        # Walk one page at a time using the <Page id="..."> blocks
        layout_xml.scan(/<Page\b[^>]*id="([^"]*)"[^>]*>(.*?)<\/Page>/m).each do |page_id, page_body|
          next if page_id.to_s.downcase.include?('data')
          next if page_body.include?('<Container')
          cols_on_page = page_body.scan(/gridColumn="([^"]+)"/).map(&:first).uniq
          elems_on_page = page_body.scan(/<Element\b/).length
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
        elsif legacy_tag_count.positive?
          warn "[FAIL] gate 4/7: layout XML contains #{legacy_tag_count} rejected legacy layout tag(s)."
          warn '       Workbook layout emission must use <Element>/<Container>; never <LayoutElement>/<GridContainer>.'
          exit 6
        elsif elem_count < opts[:min_layout_elements]
          warn "[FAIL] gate 4/7: layout XML has only #{elem_count} <Element> tag(s);"
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
        warn "[SKIP] gate 4/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{fetched['code']} — cannot verify"
      end
    end
  end
else
  record_waiver.call('--skip-layout-check', 'gate 4 (top-level layout applied)', opts[:skip_layout])
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
  # The census keys on the PARITY PLAN's matched charts — empty for a workbook
  # whose worksheets are all dashboard-embedded (no standalone views), which
  # flags every zone "unmatched" even though each chart was BUILT and
  # image-verified. Count a zone as matched when its tile carries a confirmed
  # visual-verify entry (the per-tile side-by-side oracle) — deterministic,
  # per-name, and loud below.
  # NOTE: `_vv_ok` here is a fresh top-level reassignment for an UNRELATED
  # purpose (an Array of visually-verified worksheet NAMES for gate 5/7's own
  # name-matching), not the Boolean `_vv_ok`/`_vv_source` computed above for
  # gate 2's anchors-oracle condition (b) — gate 2's use is fully consumed
  # before this point, but don't assume shared meaning between the two blocks.
  _vv_ok = begin
    Array(JSON.parse(File.read(File.join(opts[:tab], 'visual-verify', 'manifest.json'))))
      .select { |t| t['visual_verified'] == true }.map { |t| t['worksheet'].to_s }
  rescue StandardError
    []
  end
  oracle_matched = names & _vv_ok
  if oracle_matched.any?
    names -= oracle_matched
    unmatched = names.size
    puts "[OK] gate 5/7: #{oracle_matched.size} zone(s) matched via the image-verification oracle " \
         "(no standalone view in the parity plan; visual-verify confirmed): #{oracle_matched.join(', ')}"
  end
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
  record_waiver.call('--skip-layout-lint', 'gate 6 (layout-quality lint)', opts[:skip_lint])
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
      fetched = fetch_live_spec.call(wb_id, base, tok) # memoized — shared with gates 4/7/7b
      if fetched['spec']
        spec = fetched['spec']
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
        warn "[SKIP] gate 6/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{fetched['code']} — cannot lint"
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
  record_waiver.call('--skip-control-lint', 'gate 7 (control-wiring lint)', opts[:skip_control_lint])
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
      fetched = fetch_live_spec.call(wb_id, base, tok) # memoized — shared with gates 4/6/7b
      if fetched['spec']
        spec = fetched['spec']
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
        warn "[SKIP] gate 7/7: GET /v2/workbooks/#{wb_id}/spec returned HTTP #{fetched['code']} — cannot lint"
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 7c — source-vs-built controls CENSUS (exit 31; PLAN-v3 PR-13, V5.6
# audit V-V3). build-charts-from-signals.rb reconciles EVERY source control
# signal (.twb parameters + shared quick filters) against what it built and
# writes <workdir>/*-controls-coverage.json — until PR-13 a WARN + file that
# no gate, script, or doc ever read. This gate makes the census load-bearing:
# every expected signal must be BUILT (status 'emitted'), DECLARED in the
# control-scope.json sidecar (a dropped / needs-* / narrow-scope record with
# its evidence — stated per control, never silent), or NAMED in the
# <workdir>/controls-waivers.json ledger with a reason. An unexplained missing
# control — a control the user had in Tableau that the migration silently
# lost — fails BY NAME. NO skip flag: the ledger waiver IS the sanctioned
# escape (the join-plan/LOD doctrine). File-based, so it runs offline.
# ---------------------------------------------------------------------------
ctl_census_path = Dir[File.join(opts[:tab], '*-controls-coverage.json')].min
if ctl_census_path.nil?
  puts '[SKIP] gate 7c: no *-controls-coverage.json in the workdir — controls census not emitted ' \
       '(build-charts-from-signals.rb --meta writes it; back-compat / non-adopting converter)'
else
  ctl_census = (JSON.parse(File.read(ctl_census_path)) rescue nil)
  ctl_rows = ctl_census.is_a?(Hash) ? ctl_census['detail'] : nil
  unless ctl_rows.is_a?(Array)
    warn "[FAIL] gate 7c: #{File.basename(ctl_census_path)} is malformed (no detail rows) — " \
         're-run build-charts-from-signals.rb (current version) to regenerate the controls census.'
    exit 31
  end
  ctl_norm = ->(s) { s.to_s.strip.downcase }
  # Sidecar declarations: every control-scope record — emitted (with a page or
  # narrow scope:[...]), dropped, or needs-* — is a recorded decision that
  # carries its evidence (unreachable roots, source signal, intent).
  ctl_scope_path = opts[:control_scope] || File.join(opts[:tab], 'control-scope.json')
  ctl_declared = {}
  if File.exist?(ctl_scope_path)
    _cs = (JSON.parse(File.read(ctl_scope_path)) rescue nil)
    if _cs.is_a?(Hash)
      Array(_cs['controls']).each do |c|
        next unless c.is_a?(Hash)
        note = c['scope'].is_a?(Array) ? "narrow scope: #{c['scope'].length} element(s)" : "scope=#{c['scope'] || 'page'}"
        [c['name'], c['sourceName']].each do |n|
          ctl_declared[ctl_norm.call(n)] ||= note unless n.to_s.strip.empty?
        end
      end
      Array(_cs['dropped']).each do |d|
        next unless d.is_a?(Hash) || d.is_a?(String)
        n = d.is_a?(Hash) ? d['name'] : d
        ctl_declared[ctl_norm.call(n)] ||= 'dropped — recorded in control-scope.json with its evidence' unless n.to_s.strip.empty?
      end
    end
  end
  # Waiver ledger: [{"control":"filter:Region","reason":"…"}] (or {"waivers":
  # [...]}; "name" accepted for "control"). Entries without a reason are
  # IGNORED — a reasonless waiver explains nothing.
  ctl_ledger_path = File.join(opts[:tab], 'controls-waivers.json')
  ctl_ledger = []
  if File.exist?(ctl_ledger_path)
    _lg = (JSON.parse(File.read(ctl_ledger_path)) rescue nil)
    _lg = _lg['waivers'] if _lg.is_a?(Hash)
    ctl_ledger = Array(_lg).select do |w|
      w.is_a?(Hash) && !(w['control'] || w['name']).to_s.strip.empty? && !w['reason'].to_s.strip.empty?
    end
  end
  ctl_waiver_for = lambda do |kind, name|
    ctl_ledger.find do |w|
      key = ctl_norm.call(w['control'] || w['name'])
      key == ctl_norm.call(name) || key == ctl_norm.call("#{kind}:#{name}")
    end
  end
  ctl_built = []
  ctl_declared_rows = []
  ctl_waived_rows = []
  ctl_unexplained = []
  ctl_rows.each do |r|
    next unless r.is_a?(Hash)
    kind = r['kind'].to_s
    name = r['name'].to_s
    status = r['status'].to_s
    if status == 'emitted'
      ctl_built << name
    elsif (note = ctl_declared[ctl_norm.call(name)])
      ctl_declared_rows << [kind, name, status, note]
    elsif (w = ctl_waiver_for.call(kind, name))
      ctl_waived_rows << [kind, name, status, w['reason'].to_s.strip]
    else
      ctl_unexplained << [kind, name, status]
    end
  end
  if ctl_unexplained.any?
    warn "[FAIL] gate 7c: controls census — #{ctl_unexplained.length} source control signal(s) UNEXPLAINED " \
         '(present in the source, never built, not declared, not waived):'
    ctl_unexplained.each { |k, n, s| warn "         - #{k}:#{n} (census status: #{s})" }
    warn "       Census: #{File.basename(ctl_census_path)}. Every source parameter / quick filter must be"
    warn '       (a) BUILT as a control (build-charts-from-signals.rb --auto-controls), or'
    warn '       (b) DECLARED in control-scope.json (a dropped/needs-*/narrow-scope record with evidence), or'
    warn '       (c) NAMED in <workdir>/controls-waivers.json ([{"control":"filter:Region","reason":"…"}]).'
    warn '       NO skip flag — the ledger waiver IS the sanctioned escape; name it in your report.'
    exit 31
  end
  puts "[OK] gate 7c: controls census — #{ctl_rows.length} source signal(s): #{ctl_built.length} built" +
       (ctl_declared_rows.any? ? ", #{ctl_declared_rows.length} declared in control-scope.json" : '') +
       (ctl_waived_rows.any? ? ", #{ctl_waived_rows.length} ledger-waived" : '') +
       '; 0 unexplained'
  ctl_declared_rows.each { |k, n, s, note| puts "       - declared #{k}:#{n} (#{s}; #{note})" }
  ctl_waived_rows.each { |k, n, s, r2| puts "       - WAIVED #{k}:#{n} (#{s}) — #{r2} [controls-waivers.json]" }
end

# ---------------------------------------------------------------------------
# Gate 7b — runtime control flip test (exit 21; DEFAULT-ON via migrate-state
# control_flip_required=true — PLAN-v3 PR-13 — or --require-control-flip).
# Gate 7 proves control wiring against the LIVE spec + control-scope.json — but
# that sidecar is derived by build_workbook.py from the SAME `listen` data it
# used to wire the spec, so a BUILDER-level mis-mapping yields a spec and a
# sidecar that AGREE and gate 7 passes. Gate 7c proves the controls EXIST; only
# the flip proves they DO something. The only independent proof is runtime:
# flip a control via the REST export API and confirm its targets' output
# actually changes. This gate shells out to scripts/probe-controls.rb (which
# already does exactly that) and turns its verdict into a hard gate.
# Enforcement mirrors gate 8d (#439): the tableau orchestrator stamps
# control_flip_required at pass 1 (and its --finalize passes the flag), so
# neither the finalize path nor a standalone gate run can silently skip it;
# looker-to-sigma passes the flag explicitly. ENFORCED runs that cannot reach
# the live API accept RECORDED evidence (a prior probe-results.json with >=1
# PASS / 0 FAIL, the all-unprobeable advisory marker, or a controls census
# showing 0 source signals) — otherwise they fail closed toward the
# budget-counted --skip-control-flip waiver. Unenforced converters keep the
# old opt-in SKIP. See lib/flip_gate.rb.
# ---------------------------------------------------------------------------
if opts[:skip_control_flip]
  record_waiver.call('--skip-control-flip', 'gate 7b (runtime control flip test)', opts[:skip_control_flip])
elsif !opts[:require_control_flip]
  puts '[SKIP] gate 7b: runtime control flip test not opted in (pass --require-control-flip to enable)'
else
  puts "[NOTE] gate 7b enforcement auto-enabled: #{opts[:flip_auto]}" if opts[:flip_auto]
  # ENFORCED-but-cannot-probe fallback: the flip test needs the live export
  # API, so a default-on gate must accept RECORDED evidence — or fail toward
  # the named waiver — instead of silently passing (the pre-PR-13 hole: every
  # offline path printed [SKIP] and the gate stayed green).
  flip_fallback = lambda do |why|
    cov_p = Dir[File.join(opts[:tab], '*-controls-coverage.json')].min
    cov_rows = cov_p ? (JSON.parse(File.read(cov_p))['detail'] rescue nil) : nil
    rec = (JSON.parse(File.read(File.join(opts[:tab], 'probe-controls', 'probe-results.json'))) rescue nil)
    rec = nil unless rec.is_a?(Array) && rec.any?
    rec_fails  = rec ? rec.select { |r| r.is_a?(Hash) && r['result'].to_s == 'FAIL' } : []
    rec_passes = rec ? rec.select { |r| r.is_a?(Hash) && r['result'].to_s == 'PASS' } : []
    if cov_rows.is_a?(Array) && cov_rows.empty?
      puts "[OK] gate 7b: #{why} — controls census shows 0 source control signals; nothing to flip-test"
    elsif rec_fails.any?
      warn "[FAIL] gate 7b: #{why} — and the RECORDED probe-results.json carries #{rec_fails.length} FAILed flip(s):"
      rec_fails.each { |r| warn "         - #{r['control']}: #{r['note']}" }
      warn '       A recorded inert control is a real defect: fix the listen mapping, re-PUT, re-probe.'
      warn '       Escape hatch: --skip-control-flip "<reason>" (counts against the waiver budget).'
      exit 21
    elsif rec_passes.any?
      puts "[OK] gate 7b: #{why} — accepting RECORDED runtime proof: probe-results.json shows " \
           "#{rec_passes.length} control(s) proven live (0 FAIL)"
    elsif File.exist?(File.join(opts[:tab], 'control-flip-unverified.json'))
      warn "[WARN] gate 7b: #{why} — recorded control-flip-unverified.json marker: no control was " \
           'auto-probeable on the prior probe; runtime wiring UNVERIFIED (advisory, stated).'
    else
      warn "[FAIL] gate 7b: the flip test is ENFORCED#{opts[:flip_auto] ? " (#{opts[:flip_auto]})" : ''} " \
           "but #{why} — and no recorded flip evidence exists."
      warn '       The gate requires EITHER the flip-test marker — run with live Sigma creds:'
      warn "         ruby scripts/probe-controls.rb --workbook-id <id> --out #{File.join(opts[:tab], 'probe-controls')}"
      warn '       — OR the recorded waiver: --skip-control-flip "<reason>" (counts against the budget).'
      exit 21
    end
  end
  flip_wb = opts[:wb]
  if flip_wb.nil?
    _p = File.join(opts[:tab], 'wb-ids.json')
    flip_wb = (JSON.parse(File.read(_p))['workbookId'] rescue nil) if File.exist?(_p)
  end
  flip_base = ENV['SIGMA_BASE_URL']
  flip_tok  = ENV['SIGMA_API_TOKEN']
  probe = File.join(__dir__, 'probe-controls.rb')
  if flip_wb.nil? || flip_wb.to_s.empty?
    flip_fallback.call('no workbook ID is resolvable for the flip test')
  elsif flip_base.nil? || flip_base.empty? || flip_tok.nil? || flip_tok.empty?
    flip_fallback.call('SIGMA_BASE_URL / SIGMA_API_TOKEN are not set (offline gate run)')
  elsif !File.exist?(probe)
    flip_fallback.call('scripts/probe-controls.rb is not vendored alongside this script (re-vendor; SHA-1 discipline)')
  else
    # Only meaningful when the workbook actually has controls. Reuse gate 7's
    # spec fetch + ControlLint to count them; 0 controls -> nothing to prove.
    begin
      require_relative 'lib/control_lint'
      require_relative 'lib/flip_gate'
    rescue LoadError => e
      warn "[WARN] gate 7b: #{e.message} — re-vendor scripts/lib (SHA-1 discipline)"
    end
    n_controls = nil
    if defined?(ControlLint) && defined?(FlipGate)
      fetched = fetch_live_spec.call(flip_wb, flip_base, flip_tok) # memoized — shared with gates 4/6/7
      if fetched['spec']
        n_controls = ControlLint.controls_report(fetched['spec']).length
      else
        warn "[WARN] gate 7b: GET /v2/workbooks/#{flip_wb}/spec returned HTTP #{fetched['code']} — cannot count controls"
      end
    end
    if n_controls == 0
      puts '[OK] gate 7b: workbook has no controls — nothing to flip-test'
    elsif n_controls.nil?
      # Live path could not even count controls (lib not vendored / spec fetch
      # failed) — same fail-closed fallback as the offline paths: recorded
      # evidence passes, otherwise the marker-or-waiver demand fires (the
      # pre-PR-13 behavior silently passed here).
      flip_fallback.call('the live spec could not be fetched to count controls')
    else
      out = File.join(opts[:tab], 'probe-controls')
      results_path = File.join(out, 'probe-results.json')
      # ── #7d recorded-RAW-evidence acceptance ─────────────────────────────
      # A gate RE-RUN against an UNCHANGED workbook used to re-flip every
      # control (a full serial export cycle per control, 2–3x per migration:
      # builder → finalize → verifier). Accept the PRIOR probe's RAW results
      # instead when — and only when — the ledger-recorded evidence is still
      # identity-bound: same workbook, same latestDocumentVersion (any control
      # fix means a PUT means a new version), younger than 30 min, and the
      # probe-results.json bytes still hash to the recorded sha. The verdict
      # is then RECOMPUTED from those raw rows through the same FlipGate
      # decision the live path uses — the reconciled #7 red line: recorded
      # verdicts are never consumed, recorded raw measurements are. Ambiguous
      # recorded outcomes (advisory/error) fall through to a live re-probe.
      probe_rc = nil
      results = nil
      recorded_note = nil
      if EV_LEDGER_LOADED && ev_identity['ver'] && File.exist?(results_path)
        # Anchor the freshness window on the ORIGINAL collection entry, never
        # on a reuse re-append: every acceptance run below re-records its
        # recomputed verdict with recorded_reuse=true and at:=now, so taking
        # the latest entry unfiltered would let re-runs <30 min apart each
        # reset the B4 age bound and extend one probe's evidence indefinitely
        # under an unchanged doc version (live-warehouse drift laundering —
        # the chaining hole). Reuse entries stay in the ledger as audit
        # records; they are just never the age anchor.
        _rec = EvidenceLedger.latest(opts[:tab], gate: '7b', evidence_kind: 'probe-results') do |e|
          !(e['detail'].is_a?(Hash) && e['detail']['recorded_reuse'])
        end
        # A leak-check run demands leak-checked evidence — a plain prior probe
        # cannot stand in for it (different measurement, not just staler).
        _rec = nil if _rec && opts[:flip_check_leaks] && !(_rec['detail'].is_a?(Hash) && _rec['detail']['check_leaks'])
        if _rec && EvidenceLedger.fresh?(_rec, evidence_key: ev_key.call, workdir: opts[:tab])
          _rec_results = (JSON.parse(File.read(results_path)) rescue nil)
          # A6 (wave-1 review): rc is DERIVED from the sha-verified raw rows
          # (FlipGate.derive_rc mirrors probe-controls.rb's exit logic), never
          # read from the ledger detail — `detail['probe_rc']` was the one
          # non-sha-bound datum this acceptance consumed. The recorded rc
          # stays in the ledger as audit metadata only.
          if _rec_results.is_a?(Array) && _rec_results.any?
            _rec_rc = FlipGate.derive_rc(_rec_results)
            _d, = FlipGate.decide(_rec_rc, _rec_results)
            if %i[ok fail].include?(_d)
              probe_rc = _rec_rc
              results = _rec_results
              recorded_note = "recorded RAW probe evidence accepted (#{_rec['at']}, doc v#{ev_identity['ver']}, " \
                              'sha-verified; verdict recomputed — not reused)'
              puts "[NOTE] gate 7b: #{recorded_note}"
            end
          end
        end
      end
      if results.nil?
        cmd = [RbConfig.ruby, probe, '--workbook-id', flip_wb, '--out', out]
        cmd << '--check-out-of-closure' if opts[:flip_check_leaks]
        system(*cmd) # inherits stdout — the operator sees the per-control PASS/FAIL/SKIP table
        probe_rc = $?.exitstatus
        results = (JSON.parse(File.read(results_path)) rescue nil)
      end
      decision, info = FlipGate.decide(probe_rc, results)
      # E3.1: the flip verdict + its raw-evidence binding land in the ledger —
      # the record the next re-run's acceptance check above reads.
      ev_append.call('7b', decision.to_s,
                     'probe-results', 'probe-controls/probe-results.json', ev_key.call,
                     (EV_LEDGER_LOADED ? EvidenceLedger.sha256_file(results_path) : nil),
                     { 'probe_rc' => probe_rc, 'check_leaks' => opts[:flip_check_leaks] ? true : false,
                       'recorded_reuse' => !recorded_note.nil? })
      case decision
      when :ok
        puts "[OK] gate 7b: #{info[:passes].length} control(s) proven live (in-closure export changes when flipped)" \
             "#{info[:skips].any? ? "; #{info[:skips].length} un-probeable type(s) skipped" : ''}"
      when :fail
        warn "[FAIL] gate 7b: #{info[:fails].length} control(s) wired but INERT on live workbook #{flip_wb}:"
        info[:fails].each { |cid, note| warn "         - #{cid}: #{note}" }
        warn '       The control passed the static lint (gate 7) but does not actually filter its'
        warn '       targets — a builder-level listen->column mis-mapping. Re-check the tile `listen`'
        warn '       mapping in build_workbook.py, re-PUT the spec, then re-run.'
        warn "       Reproduce: ruby scripts/probe-controls.rb --workbook-id #{flip_wb}"
        warn '       Escape hatch: --skip-control-flip "<reason>" (counts against the waiver budget).'
        exit 21
      when :advisory
        warn "[WARN] gate 7b: no control could be auto-flipped (#{info[:skips].length} date-range / slider / " \
             'unlabeled control(s) need an explicit flip value) — runtime wiring is UNVERIFIED.'
        info[:skips].each { |cid, note| warn "         - #{cid}: #{note}" }
        marker = File.join(opts[:tab], 'control-flip-unverified.json')
        File.write(marker, JSON.pretty_generate('workbookId' => flip_wb,
                                                'unprobed' => info[:skips].map { |c, n| { 'control' => c, 'note' => n } })) rescue nil
        warn "       Recorded to #{marker}. Prove them with: ruby scripts/probe-controls.rb --workbook-id " \
             "#{flip_wb} --value <controlId>=<value>  (or waive with --skip-control-flip \"<reason>\")."
      when :error
        warn "[FAIL] gate 7b: probe-controls.rb could not verify the wiring (exit #{probe_rc}) on workbook #{flip_wb}."
        warn '       An opted-in gate that could not run must not pass silently. Re-run once the export'
        warn "       API is reachable: ruby scripts/probe-controls.rb --workbook-id #{flip_wb}"
        warn '       Escape hatch: --skip-control-flip "<reason>" (counts against the waiver budget).'
        exit 21
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
# Validated render PNG from gate 8 — reused by gate 14 (visual-similarity
# floor). nil when gate 8 was waived or no render resolved.
render_png = nil
if opts[:skip_visual]
  # BISECT-EVIDENCE demand (field-caught, twice): both rounds of a live test
  # produced a "render outage / persistent 500" waiver that an evaluator's
  # 6-probe bisect refuted in minutes — the poison was the run's OWN content
  # (an unbounded pivot column dimension) and the waiver silently absorbed
  # FOUR visual gates. A 500/timeout reason is only acceptable WITH bisect
  # evidence: the reason must name the playbook's step-1/step-2 probes.
  if opts[:skip_visual] =~ /500|timeout|timed?\s*out|hang|render.*(fail|outage|error)/i &&
     opts[:skip_visual] !~ /bisect|probe/i
    warn '[FAIL] gate 8: --skip-visual-gate cites a render failure but names NO bisect evidence.'
    warn '       A render 500/timeout is usually YOUR workbook content, not the service (an'
    warn '       unbounded pivot dimension has caused this in two independent field runs).'
    warn '       Run the bisect playbook (refs/layout-visual-qa.md "Render 500 / export-timeout'
    warn '       bisect") and re-waive ONLY if step 1 (another workbook fails too) or step 2'
    warn "       (a minimal probe on your DM fails) holds — include e.g. 'bisect: other-workbook"
    warn "       probe also 500s' or 'bisect: isolated to element <id>, verified product limit'"
    warn '       in the reason string.'
    exit 10
  end
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
  elsif opts[:sigma_render].nil?
    # The v4 pipeline's own full-page renders: phase 5b visual QA
    # (<workdir>/visual-qa/<dash>.sigma.png) and the phase 5g RCF loop
    # (<workdir>/rcf-pass-N.png). Both ARE live sigma-export-png renders —
    # this gate predates those paths and used to fail runs that had rendered
    # (and compared) the page several times over. Newest first.
    ok_png = (Dir[File.join(opts[:tab], 'visual-qa', '*.sigma.png')] +
              Dir[File.join(opts[:tab], 'rcf-pass-*.png')])
             .select { |p| valid_png.call(p) }.max_by { |p| File.mtime(p) }
  end
  if ok_png.nil? && opts[:sigma_render].nil? && File.exist?(manifest_path)
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
    warn '       then re-run this gate. See SKILL.md Phase 6f.'
    warn '       Export returning HTTP 500 / timing out? That is usually YOUR workbook content'
    warn '       (e.g. an unbounded pivot dimension from a dropped source rank filter), not the'
    warn '       service — run the bisect playbook in refs/layout-visual-qa.md ("Render 500 /'
    warn '       export-timeout bisect") BEFORE reaching for the escape hatch. Escape hatch'
    warn '       (only with other-workbook probe evidence): --skip-visual-gate "<reason>".'
    exit 10
  end
  size_kb = (File.size(ok_png) / 1024.0).round
  render_png = ok_png
  puts "[OK] gate 8: Phase 6f visual render present (#{ok_png}, #{size_kb} KB) — " \
       'valid PNG produced for source-vs-target comparison'
  # gate 8b — the comparison itself can't be fully mechanized, but we CAN require
  # that a VERDICT was recorded (record-visual-check.rb stamps visual_checked into
  # parity-final.json after the agent reads the rendered page against the source).
  # ENFORCED BY DEFAULT (was opt-in via --require-visual-comparison): a structurally
  # clean workbook can still ship visually empty/wrong (0 error columns, but stacked
  # slivers / missing tiles). "Can't verify" must not equal "passes", so a missing
  # verdict hard-fails unless explicitly waived with a named reason.
  #
  # VISION PRECONDITION (§D5): record-visual-check.rb stamps agent_vision; when the
  # driving agent could not READ the render (agent_vision=false, or the explicit
  # visual_verdict="not-executable"), any recorded verdict — even one carrying a
  # screenshot_path — is a blind attestation, and the gate fails with a NAMED
  # degradation instead of passing on it.
  s = File.exist?(summary_path) ? (JSON.parse(File.read(summary_path)) rescue {}) : {}
  # A recorded `divergent` verdict IS a recorded comparison — gate 8b accepts
  # it as RECORDED, but the acknowledged gaps are budget-counted (the
  # `visual-divergent` census injection above; exit-19 doctrine).
  recorded = s['visual_checked'] || s['screenshot_path'] || s['visual_verdict'].to_s == 'divergent'
  vision_blocked = (s.key?('agent_vision') && s['agent_vision'] == false) ||
                   s['visual_verdict'].to_s == 'not-executable'
  if vision_blocked
    if opts[:skip_visual_cmp]
      puts "[SKIP] gate 8b: visual gate NOT EXECUTABLE (agent_vision=#{s['agent_vision'].inspect}, " \
           "verdict=#{s['visual_verdict'].inspect}) — WAIVED via --skip-visual-comparison (#{opts[:skip_visual_cmp]})."
      puts '       This waiver MUST be named in the migration report — the render was NEVER read by a vision-capable agent.'
    else
      warn '[FAIL] gate 8b: visual gate not executable — vision-capable agent required.'
      warn "       parity-final.json records agent_vision=#{s['agent_vision'].inspect}" \
           "#{s['visual_verdict'] ? " / visual_verdict=#{s['visual_verdict'].inspect}" : ''}: the driving"
      warn '       agent lacks image input, so it cannot READ the render — any verdict it records is a'
      warn '       blind attestation, never a pass. Re-run the RCF/visual loop from a vision-capable'
      warn '       session (Claude Code with image input), then record the verdict:'
      warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass --notes "..."'
      warn '       Escape hatch (knowingly shipping an unverified render): --skip-visual-comparison "<reason>"'
      warn '       (name it in your migration report).'
      exit 13
    end
  elsif recorded
    # v5.3.1: a PASS verdict must carry the per-dimension STYLE CHECKLIST
    # (round-5: gestalt self-passes shipped renders an exacting owner
    # rejected on all six runs). record-visual-check.rb refuses new passes
    # without one; this catches hand-edited parity-final.json + stale verdicts.
    cl_keys = %w[element_titles_hidden palette_match composition_match
                 chart_shapes_match labels_legible numbers_formatted]
    if s['visual_verdict'].to_s == 'pass' && !opts[:skip_visual_cmp]
      cl = s['style_checklist']
      cl_missing = cl.is_a?(Hash) ? (cl_keys - cl.keys) : cl_keys
      cl_fails = cl.is_a?(Hash) ? cl.select { |k, v2| cl_keys.include?(k) && v2 == 'fail' }.keys : []
      unless cl_missing.empty? && cl_fails.empty?
        warn '[FAIL] gate 8b: visual PASS recorded WITHOUT a complete clean style checklist —'
        warn "       missing: #{cl_missing.join(', ')}" if cl_missing.any?
        warn "       failing: #{cl_fails.join(', ')}" if cl_fails.any?
        warn '       Re-judge the render against the SOURCE image per dimension (layout-visual-qa.md section 1b), then:'
        warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass \\'
        warn "           --checklist \"#{cl_keys.map { |k| "#{k}=pass" }.join(',')}\""
        warn '       (fail on any dimension means the verdict is divergent — fix it first).'
        exit 13
      end
      # PR-9: a visual PASS must be countersigned by a CONTEXT-FREE blind grade
      # (or carry the recorded no-vision waiver). A self-attested pass — the
      # builder grading its own render — is exactly how a field run shipped
      # 6/6 PASS on visuals the customer rejected. The stamped metadata is
      # re-verified SHA-BOUND here so a hand-edited parity-final.json (or an
      # image swapped after grading) cannot launder a pass.
      bg = s['blind_grade']
      bgw = s['blind_grade_waiver']
      if bgw.is_a?(Hash) && !bgw['reason'].to_s.strip.empty?
        puts '[OK] gate 8b: visual PASS accepted under the recorded NO-VISION-GRADER waiver ' \
             "(#{bgw['reason']}) — SELF-graded, no context-free blind grade backs it. Counted against " \
             'the waiver budget; MUST be named in the migration report.'
      else
        bg_fail = lambda do |why|
          warn "[FAIL] gate 8b: visual PASS is not blind-graded — #{why}"
          warn '       The verdict must come from a CONTEXT-FREE grader (PLAN-v3 PR-9): spawn a FRESH'
          warn '       subagent with refs/blind-grader-brief.md as its prompt, giving it ONLY the source'
          warn '       dashboard PNG path, the Sigma render PNG path, and the rubric — NO wb-spec, NO run'
          warn '       history, NO builder context. It writes blind-grade.json; then re-record:'
          warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass \\'
          warn '           --checklist "<six dimensions>" --blind-grade <dir>/blind-grade.json'
          warn '       Sessions that cannot spawn a vision-capable grader: record-visual-check.rb'
          warn '       --no-vision-waiver "<reason>" (counted against the waiver budget, never silent).'
          exit 13
        end
        _hex = /\A[0-9a-f]{64}\z/i
        if !bg.is_a?(Hash)
          bg_fail.call('parity-final.json carries NO blind_grade metadata (self-attested pass).')
        elsif bg['verdict'].to_s != 'pass' || bg['source_sha256'].to_s !~ _hex || bg['target_sha256'].to_s !~ _hex
          bg_fail.call('the stamped blind_grade metadata is invalid (verdict must be pass, sha256s must be 64-hex).')
        else
          _bg_file = File.expand_path((bg['path'] || 'blind-grade.json').to_s, opts[:tab])
          _bg_doc = File.file?(_bg_file) ? (JSON.parse(File.read(_bg_file)) rescue nil) : nil
          if _bg_doc.nil?
            bg_fail.call("the blind grade evidence file is missing/unreadable (#{_bg_file}) — the hash-bound grade must stay on disk.")
          elsif _bg_doc['source_sha256'].to_s.downcase != bg['source_sha256'].to_s.downcase ||
                _bg_doc['target_sha256'].to_s.downcase != bg['target_sha256'].to_s.downcase ||
                _bg_doc['verdict'].to_s != 'pass'
            bg_fail.call('blind-grade.json does not match the stamped metadata (sha/verdict drift — re-run the grader).')
          else
            _cl_keys2 = %w[element_titles_hidden palette_match composition_match
                           chart_shapes_match labels_legible numbers_formatted]
            _dims = _bg_doc['dimensions'].is_a?(Hash) ? _bg_doc['dimensions'] : {}
            _bad_dims = _cl_keys2.reject { |k| _dims[k].is_a?(Hash) && _dims[k]['verdict'].to_s == 'pass' }
            _src_img = _bg_doc['source_png'].to_s.empty? ? nil : File.expand_path(_bg_doc['source_png'].to_s, opts[:tab])
            _tgt_img = _bg_doc['target_png'].to_s.empty? ? nil : File.expand_path(_bg_doc['target_png'].to_s, opts[:tab])
            if _bad_dims.any?
              bg_fail.call("blind grade dimension(s) missing or not passing: #{_bad_dims.join(', ')}.")
            elsif _src_img.nil? || _tgt_img.nil? || !File.file?(_src_img) || !File.file?(_tgt_img)
              bg_fail.call('the graded image files are missing from disk (blind-grade.json source_png/target_png) — the sha binding cannot be verified.')
            elsif Digest::SHA256.file(_src_img).hexdigest != bg['source_sha256'].to_s.downcase
              bg_fail.call("the SOURCE image changed since grading (sha256 of #{_src_img} no longer matches) — re-run the grader.")
            elsif Digest::SHA256.file(_tgt_img).hexdigest != bg['target_sha256'].to_s.downcase
              bg_fail.call("the RENDER changed since grading (sha256 of #{_tgt_img} no longer matches) — re-render, re-grade, re-record.")
            else
              # Anti-gaming (belt-and-braces to record-visual-check's check): the
              # grade's per-tile target families must not contradict the built
              # workbook's mechanical kind census on more than 1 tile.
              _fam_map = { 'bar-chart' => 'bar', 'column' => 'bar', 'column-chart' => 'bar',
                           'line-chart' => 'line', 'sparkline' => 'line', 'area-chart' => 'area',
                           'combo-chart' => 'combo', 'dual-axis' => 'combo', 'scatter-chart' => 'scatter',
                           'bubble' => 'scatter', 'pie-chart' => 'pie', 'donut' => 'pie',
                           'donut-chart' => 'pie', 'kpi-chart' => 'kpi', 'single-value' => 'kpi',
                           'big-number' => 'kpi', 'region-map' => 'map', 'point-map' => 'map',
                           'pivot-table' => 'table', 'pivot' => 'table', 'crosstab' => 'table',
                           'text-table' => 'table', 'grid' => 'table' }
              _chartf = %w[bar line area combo scatter pie kpi map table other]
              _fam = lambda do |k|
                k2 = k.to_s.strip.downcase
                _fam_map[k2] || (%w[bar line area combo scatter pie kpi map table
                                    text control image container divider missing].include?(k2) ? k2 : 'other')
              end
              _rb = File.join(opts[:tab], 'wb-readback.json')
              _census = nil
              if File.file?(_rb)
                _rb_doc = (JSON.parse(File.read(_rb)) rescue nil)
                if _rb_doc.is_a?(Hash)
                  _els = CODE_REP_LOADED ? Sigma::CodeRep.workbook_elements(_rb_doc) :
                                           Array(_rb_doc['elements'])
                  _census = _els.select { |el| el.is_a?(Hash) && el['visibleAsSource'] != false }
                                .map { |el| _fam.call(el['kind']) }
                                .select { |f| _chartf.include?(f) }
                end
              end
              if _census.is_a?(Array) && _census.any?
                _blind = Array(_bg_doc['per_tile']).map { |t| _fam.call(t.is_a?(Hash) ? t['target_family'] : nil) }
                                                   .select { |f| _chartf.include?(f) }
                _bc = _blind.each_with_object(Hash.new(0)) { |f, h| h[f] += 1 }
                _cc = _census.each_with_object(Hash.new(0)) { |f, h| h[f] += 1 }
                _matched = _cc.map { |f, n| [n, _bc[f]].min }.reduce(0, :+)
                _mm = [_blind.length, _census.length].max - _matched
                if _mm > 1
                  bg_fail.call("blind grade INCONSISTENT with the mechanical kind census — target_family readings contradict wb-readback.json on #{_mm} tile(s) (blind: #{_bc.sort.map { |f, n| "#{n}x#{f}" }.join(', ')}; census: #{_cc.sort.map { |f, n| "#{n}x#{f}" }.join(', ')}) — fabricated or stale grade.")
                end
              end
              puts "[OK] gate 8b: blind grade verified — context-free PASS, sha-bound to the images on disk " \
                   "(src=#{bg['source_sha256'][0, 12]}…, tgt=#{bg['target_sha256'][0, 12]}…)."
            end
          end
        end
      end
    end
    v = s['visual_verdict'] ? " (#{s['visual_verdict']})" : ''
    av = s.key?('agent_vision') ? ", agent_vision=#{s['agent_vision']}" : ''
    cls = if s['style_checklist'].is_a?(Hash)
            counts = s['style_checklist'].values.each_with_object(Hash.new(0)) { |v2, h| h[v2] += 1 }
            ", style_checklist=#{counts.map { |k, n| "#{n}x#{k}" }.join('/')}"
          else
            ''
          end
    if s['visual_verdict'].to_s == 'divergent'
      puts "[OK] gate 8b: source-vs-target visual comparison recorded (divergent)#{av}#{cls} — RECORDED, not clean:"
      puts '     the acknowledged visual gaps are BUDGET-COUNTED (census: visual-divergent; exit-19 doctrine).'
      puts '     GREEN requires the budget to hold — fix the gaps, re-render, re-record --verdict pass, or'
      puts "     accept YELLOW#{s['visual_notes'] ? " (recorded gaps: #{s['visual_notes'].to_s[0, 160]})" : ''}."
      puts '     (Full verdict-capping — divergent caps the run at PARTIAL — is PLAN-v3 PR-14, not built yet.)'
    else
      puts "[OK] gate 8b: source-vs-target visual comparison recorded#{v}#{av}#{cls}."
    end
  elsif opts[:skip_visual_cmp]
    puts "[SKIP] gate 8b: source-vs-target visual comparison WAIVED via --skip-visual-comparison (#{opts[:skip_visual_cmp]})."
  else
    warn '[FAIL] gate 8b: parity-final.json records no visual_checked/screenshot_path verdict —'
    warn '       a valid render exists, but nobody confirmed it matches the source dashboard.'
    warn '       Enforced by default: a structurally-clean workbook can still be visually empty/wrong.'
    warn '       Read each rendered page against the source PNG, then run:'
    warn '         ruby scripts/record-visual-check.rb --workdir <dir> --agent-vision true --verdict pass|divergent --notes "..." \\'
    warn '           --checklist "<six style dimensions - layout-visual-qa.md section 1b>"'
    warn '       then re-run. If the source image is genuinely unobtainable, waive with'
    warn '       --skip-visual-comparison "<reason>" and name it in your migration report.'
    exit 13
  end
end

# ---------------------------------------------------------------------------
# Gate 4b — layout-phase SENTINEL (exit 30; PLAN-v3 PR-11). The artifact gates
# (4 live layout, 8c fill census) prove layout OUTPUTS when they exist; this
# proves the layout PHASE was ever entered. Field failure: a session's layout
# phase never ran at all — no census, no dashboard-layout evidence in a shape
# 8c could condition on — and the run still handed over a workbook URL. The
# orchestrator stamps every phase it walks into run-state.json (lib/run_state);
# when that ledger is tracked, the tool's layout-phase key MUST carry a stamp:
# "done" passes, "skip" is honored as a RECORDED waiver (injected into the
# census above as layout-phase-skip, budget-counted), and NO stamp is the
# silent shortcut this gate makes unreachable. Not tracked (manual path) or an
# unregistered tool → stated SKIP, never a silent pass. No escape flag.
# ---------------------------------------------------------------------------
if run_state_doc.nil?
  puts '[SKIP] gate 4b: no run-state.json — layout-phase sentinel N/A (hand-driven path; ' \
       'gates 4/8c still police the layout artifacts)'
elsif layout_phase_key.nil?
  puts "[SKIP] gate 4b: run-state tool #{run_state_doc['tool'].inspect} has no registered " \
       'layout-phase key — sentinel N/A'
elsif layout_phase_stamp.nil?
  warn "[FAIL] gate 4b: run-state.json is tracked but the layout phase (#{layout_phase_key}) was " \
       'NEVER ENTERED — the run took a silent shortcut past the layout build.'
  warn '       A workbook without its layout phase ships as an unarranged stack no matter what the'
  warn '       other gates say. Re-run the layout phase (the orchestrator stamps it):'
  warn "         ruby scripts/build-dashboard-layout.rb --layout #{File.join(opts[:tab], 'dashboard-layout.json')} \\"
  warn "           --wb-ids #{File.join(opts[:tab], 'wb-ids.json')} --out #{File.join(opts[:tab], 'layout.xml')}"
  warn "         ruby scripts/put-layout.rb --workbook <id> --layout #{File.join(opts[:tab], 'layout.xml')}"
  warn '       or drive the run through scripts/migrate-tableau.rb. A deliberate no-layout decision'
  warn '       must be stamped: RunState.skip(workdir, phase, "<reason>") — recorded, budget-counted,'
  warn '       never silent. There is no escape flag for this sentinel.'
  exit 30
elsif layout_phase_stamp['status'] == 'skip'
  record_waiver.call('layout-phase-skip', "gate 4b (layout phase #{layout_phase_key})",
                     layout_phase_stamp['note'])
else
  puts "[OK] gate 4b: layout phase entered — #{layout_phase_key} stamped " \
       "#{layout_phase_stamp['status'].inspect} at #{layout_phase_stamp['ts'] || '?'}"
end

# ---------------------------------------------------------------------------
# Gate 8c — layout fill / grid coverage (#259 item 1). A workbook can pass
# every structural + visual gate above and still ship a page that is mostly
# empty: tiles silently dropped, or a sparse default stack. build-dashboard-
# layout.rb emits <workdir>/layout-census.json (one record per page: zones /
# placed / dropped / grid_fill_pct / unplaced_elements). This gate hard-fails
# when any page dropped a tile (placed < zones), its grid is under-filled
# (grid_fill_pct < --min-grid-fill, default 0.45), OR the builder reported
# ORPHAN elements (unplaced_elements non-empty: an element in the built page
# that no layout band references — Sigma auto-flows it as a stray white card).
#
# Absent census: CONDITIONAL fail. If a dashboard layout was built
# (dashboard-layout.json present, or a tile_census landed in parity-final.json)
# but no fill census exists, the gate couldn't run on a page it should have ⇒
# FAIL. When no dashboard layout was built at all — a non-dashboard migration
# or a converter that doesn't emit a census — the gate is N/A ⇒ SKIP (stated,
# never a silent pass).
# ---------------------------------------------------------------------------
census_fill_path = File.join(opts[:tab], 'layout-census.json')
if opts[:skip_layout_fill]
  record_waiver.call('--skip-layout-fill', 'gate 8c (layout fill / grid coverage)', opts[:skip_layout_fill])
elsif File.exist?(census_fill_path)
  doc = JSON.parse(File.read(census_fill_path)) rescue nil
  pages = doc.is_a?(Hash) ? Array(doc['pages']) : (doc.is_a?(Array) ? doc : nil)
  if pages.nil?
    warn "[FAIL] gate 8c: #{census_fill_path} is malformed (expected {\"pages\":[{page,zones,placed,grid_fill_pct}...]})."
    exit 14
  end
  min_fill = opts[:min_grid_fill]
  bad = pages.select do |p|
    p['placed'].to_i < p['zones'].to_i || p['grid_fill_pct'].to_f < min_fill ||
      Array(p['unplaced_elements']).any?
  end
  # Reconcile against the LIVE layout (gate 4 fetched its positioned-element
  # count). A HAND-AUTHORED workbook layout uses element ids the zone-derived
  # census can't match, so build-dashboard-layout.rb reports placed=0/N even
  # though the shipped layout positions every tile. If the live layout has at
  # least as many positioned <Element> tags as there are source zones,
  # trust it — the census is stale, not the layout. Conservative: only relaxes
  # when the live layout demonstrably covers every zone; never masks a genuine
  # drop when the live layout is actually short.
  total_zones = pages.sum { |p| p['zones'].to_i }
  if bad.any? && live_layout_positioned && total_zones.positive? && live_layout_positioned >= total_zones
    total_placed = pages.sum { |p| p['placed'].to_i }
    puts "[OK] gate 8c: layout-census.json is stale (placed #{total_placed}/#{total_zones}), but the LIVE " \
         "workbook layout positions #{live_layout_positioned} element(s) >= #{total_zones} source zone(s) — " \
         'hand-authored layout reconciled (the zone-derived census could not match its element ids).'
    bad = []
  end
  if bad.any?
    warn "[FAIL] gate 8c: layout fill/coverage — #{bad.length} page(s) dropped tiles or ship under-filled:"
    bad.each do |p|
      reasons = []
      if p['placed'].to_i < p['zones'].to_i
        reasons << "#{p['zones'].to_i - p['placed'].to_i} dropped tile(s) (placed #{p['placed']}/#{p['zones']})"
      end
      reasons << "grid fill #{(p['grid_fill_pct'].to_f * 100).round}% < #{(min_fill * 100).round}%" if p['grid_fill_pct'].to_f < min_fill
      orphans = Array(p['unplaced_elements'])
      reasons << "#{orphans.length} orphan element(s) no layout band references (auto-flowed as stray cards): #{orphans.join(', ')}" if orphans.any?
      warn "         - #{p['page'].inspect}: #{reasons.join('; ')}"
    end
    warn '       A dropped tile means a source zone never made it into the Sigma layout (empty'
    warn '       view CSV, unhandled rename); an under-filled grid means the page ships mostly'
    warn '       empty; an orphan element means the built page carries an element the layout'
    warn '       never places (Sigma auto-flows it as a stray white card, bottom-left).'
    warn '       Check build-dashboard-layout.rb WARN lines for dropped/unmatched zones,'
    warn '       rebuild the layout, re-PUT, and re-render. Tune with --min-grid-fill F.'
    warn '       Escape hatch (intentionally sparse page): --skip-layout-fill "<reason>" (name it in your report).'
    exit 14
  end
  puts "[OK] gate 8c: layout fill — #{pages.length} page(s), all tiles placed (no drops), grid fill >= #{(min_fill * 100).round}%"
else
  dash_built = File.exist?(File.join(opts[:tab], 'dashboard-layout.json')) ||
               (defined?(summary) && summary.is_a?(Hash) && summary['tile_census'])
  if dash_built
    warn "[FAIL] gate 8c: a dashboard layout was built but #{census_fill_path} is missing —"
    warn '       the layout fill/coverage gate could not run on a page it should have.'
    warn '       Re-run build-dashboard-layout.rb (it emits layout-census.json beside layout.xml),'
    warn '       then re-run this gate. Escape hatch: --skip-layout-fill "<reason>".'
    exit 14
  else
    puts "[SKIP] gate 8c: no layout-census.json and no dashboard layout built — fill gate N/A"
  end
end

# ---------------------------------------------------------------------------
# Gate 8d — RCF fidelity ledger (#Phase 5g; DEFAULT-ON per PR-11 — see the
# enforcement-resolution block above: --require-fidelity-ledger, or
# migrate-state.json rcf_passes > 0, turns it on; --skip-fidelity-gate /
# rcf_passes == 0 waives it BY NAME).
# Structural + value + visual-render + recorded-verdict all passing still leaves
# the composition gap the render-compare-fix loop closes: a workbook can be
# faithful in data yet visibly off-brand (generic palette, wrong chart kind, KPI
# format drift). The loop records each delta into fidelity-ledger.json classified
# spec-fixable | ui-only | sigma-capability | data; only UNRESOLVED spec-fixable
# entries block. Converters that never stage the loop skip this gate (soft)
# until they adopt it. Logic mirrors FidelityLoop
# .unresolved_specfixable — inlined here so the shared gate has no cross-plugin dep.
# ---------------------------------------------------------------------------
fl_path = opts[:fidelity_ledger] || File.join(opts[:tab], 'fidelity-ledger.json')
accepted = Array(opts[:accept_residuals]).map(&:to_s)
if opts[:skip_fidelity]
  record_waiver.call('--skip-fidelity-gate', 'gate 8d (RCF fidelity ledger)', opts[:skip_fidelity])
  # (data-class residuals below still block whenever a ledger exists — the
  # waiver covers the LOOP requirement, never wrong numbers.)
elsif opts[:fidelity_auto]
  puts "[NOTE] gate 8d required by DEFAULT — #{opts[:fidelity_auto]} (the RCF loop was staged; " \
       'opt out only via --rcf-passes 0 at pass 1, which records the --skip-fidelity-gate waiver).'
end
if opts[:require_fidelity] && !opts[:skip_fidelity] && !File.exist?(fl_path)
  warn "[FAIL] gate 8d: --require-fidelity-ledger set but #{fl_path} is missing."
  warn '       Run the Phase 5g render-compare-fix loop (scripts/fidelity-loop.rb init/render/record/'
  warn '       apply-patch) to convergence, then re-run. See SKILL.md Phase 5g + refs/fidelity-rubric.md.'
  exit 15
end
ledger = nil
if File.exist?(fl_path)
  ledger = (JSON.parse(File.read(fl_path)) rescue nil)
  if ledger.nil?
    warn "[FAIL] gate 8d: #{fl_path} is malformed JSON."
    exit 15
  end
end
if ledger
  entries = ledger['entries'] || []
  # DATA-CLASS residuals block GREEN whenever a ledger EXISTS — with or
  # without --require-fidelity-ledger, and --accept-residuals does NOT apply.
  # A `data` delta means the rendered VALUES diverge from the source; every
  # other gate can pass while the numbers are wrong (the field failure).
  data_block = entries.each_with_index.select { |e, _i| e['cls'] == 'data' && !e['resolved'] }
  if data_block.any?
    accepted_data = data_block.select { |e, i| accepted.include?(i.to_s) || accepted.include?(e['id'].to_s) }
    warn "[FAIL] gate 8d: #{data_block.length} unresolved data-class RCF delta(s) in #{fl_path}:"
    data_block.each { |e, _i| warn "         #{e['id']} [#{e['dimension']}] #{e['delta']}" }
    if accepted_data.any?
      warn "       --accept-residuals named #{accepted_data.map { |e, _i| e['id'] }.join(', ')} — REJECTED for data-class ids."
    end
    warn '       data-class residuals can never be waved through — the numbers are wrong; fix or'
    warn '       reclassify with evidence. Either fix the spec/data and mark the entry resolved'
    warn '       (fidelity-loop.rb resolve), or — only after PROVING the values actually match the'
    warn '       source — re-record it under its true class with the evidence in the entry. There is'
    warn '       no escape flag for data-class.'
    exit 15
  end
  if opts[:require_fidelity] && !opts[:skip_fidelity]
    blocking = entries.each_with_index.select do |e, i|
      e['cls'] == 'spec-fixable' && !e['resolved'] &&
        !accepted.include?(i.to_s) && !accepted.include?(e['id'].to_s)
    end
    if blocking.any?
      warn "[FAIL] gate 8d: #{blocking.length} unresolved spec-fixable RCF delta(s) in #{fl_path}:"
      blocking.each do |e, _i|
        warn "         #{e['id']} [#{e['dimension']}] #{e['delta']} (fix: #{e['fix'] || 'see refs/fidelity-recipes.md'})"
      end
      warn '       Apply the recipe fix (fidelity-loop.rb apply-patch) and re-render, or waive named'
      warn '       residuals with --accept-residuals id,id (name them in your migration report;'
      warn '       data-class ids are never accepted).'
      exit 15
    end
    resid = entries.reject { |e| e['cls'] == 'spec-fixable' && !e['resolved'] }
                   .select { |e| %w[ui-only sigma-capability data].include?(e['cls']) }
    puts "[OK] gate 8d: RCF fidelity ledger clean — #{entries.length} delta(s) over #{ledger['pass']} pass(es), " \
         "0 unresolved spec-fixable, 0 unresolved data-class" \
         "#{resid.any? ? " (#{resid.length} recorded residual(s) → report)" : ''}"
  end
end

# ---------------------------------------------------------------------------
# Gate 8e — layout-ARRANGEMENT parity (exit 29; PLAN-v3 PR-11). Gate 8c proves
# every tile is PLACED and the grid is filled; nothing proved the tiles are
# arranged the way the SOURCE arranges them (field failures: controls shipped
# in a sidebar where the source had a top shelf; two charts shipped with their
# stacking inverted). build-dashboard-layout.rb compares normalized source
# zone bboxes against the built grid (ordering + quadrant + controls-shelf
# class, NO pixel IoU) and emits <workdir>/layout-arrangement.json. WARN-level
# first release: violations print as advisory WARNs by default; the gate hook
# is --require-arrangement (blocking) so the next release can flip it.
# ---------------------------------------------------------------------------
arr_path = opts[:arrangement_report] || File.join(opts[:tab], 'layout-arrangement.json')
arr_doc = File.exist?(arr_path) ? (JSON.parse(File.read(arr_path)) rescue nil) : nil
arr_viols = arr_doc.is_a?(Hash) ? Array(arr_doc['pages']).flat_map { |p| Array(p['violations']).map { |v| [p['page'], v] } } : []
if opts[:require_arrangement]
  if arr_doc.nil?
    dash_built_8e = File.exist?(File.join(opts[:tab], 'dashboard-layout.json')) || File.exist?(census_fill_path)
    if dash_built_8e
      warn "[FAIL] gate 8e: --require-arrangement set but #{arr_path} is missing/malformed while a"
      warn '       dashboard layout was built — the arrangement comparison never ran. Rebuild the'
      warn '       layout with a current build-dashboard-layout.rb (it emits layout-arrangement.json'
      warn '       beside the fill census), re-PUT, then re-run this gate.'
      exit 29
    else
      puts '[SKIP] gate 8e: no dashboard layout built — arrangement parity N/A'
    end
  elsif arr_viols.any?
    warn "[FAIL] gate 8e: #{arr_viols.length} layout-arrangement violation(s) — the built grid does not"
    warn '       arrange the tiles the way the source dashboard does:'
    arr_viols.each { |pg, v| warn "         - #{pg.inspect}: #{v}" }
    warn '       Rebuild the layout to mirror the source arrangement (band order, within-band order,'
    warn '       controls shelf), re-PUT, re-render, then re-run. No pixel matching is required —'
    warn '       only ordering/quadrant/shelf-class agreement.'
    exit 29
  else
    puts "[OK] gate 8e: layout arrangement matches the source — #{Array(arr_doc['pages']).length} page(s), 0 violations"
  end
elsif arr_viols.any?
  puts "[WARN] gate 8e (advisory this release): #{arr_viols.length} layout-arrangement violation(s) — " \
       'the built grid diverges from the source arrangement:'
  arr_viols.each { |pg, v| puts "         - #{pg.inspect}: #{v}" }
  puts '       Not blocking yet (WARN-level first release; --require-arrangement makes it a hard gate).'
  puts '       Fix the arrangement before handoff and name any residual divergence in your report.'
elsif arr_doc
  puts "[OK] gate 8e (advisory): layout arrangement matches the source — #{Array(arr_doc['pages']).length} page(s), 0 violations"
else
  puts '[SKIP] gate 8e: no layout-arrangement.json — arrangement parity not measured (advisory; ' \
       'emitted by build-dashboard-layout.rb since PR-11)'
end

# ---------------------------------------------------------------------------
# Gate 13 — source-anchor value verification (exit 18). The MEASURED value bar.
# A run can pass CSV parity plumbing, render a PNG, and record a visual "pass"
# while the NUMBERS are wrong (different ranked members, 10x-off magnitudes,
# collapsed buckets — the two-field-failure class). Judgment gates are
# attestations; this one is arithmetic: every printed value the agent
# transcribed from the SOURCE dashboard image at Phase 1d (source-anchors.json,
# >= 5 anchors, EXACTLY as printed) must appear in the LIVE workbook's element
# exports at the printed precision (scripts/verify-anchors.rb →
# anchors-verdict.json). Fires whenever the workdir carries a source dashboard
# PNG (the 1d artifact); no source PNG at all → stated SKIP.
# ---------------------------------------------------------------------------
MIN_ANCHORS = 5
find_source_png = lambda do
  cands = []
  pr = File.join(opts[:tab], 'png-read.json')
  if File.exist?(pr)
    sp = (JSON.parse(File.read(pr))['source_png'] rescue nil).to_s
    unless sp.empty?
      cands << sp << File.join(opts[:tab], sp) << File.join(opts[:tab], 'views', File.basename(sp))
    end
  end
  if File.exist?(fl_path)
    si = ((ledger || {})['source_image'] rescue nil).to_s
    cands << si << File.join(opts[:tab], si) unless si.empty?
  end
  cands += Dir.glob(File.join(opts[:tab], 'views', '*.png')).sort
  cands += Dir.glob(File.join(opts[:tab], 'dashboards', '*.png')).sort
  cands.find { |p| p.downcase.end_with?('.png') && File.file?(p) }
end
source_png = find_source_png.call

if opts[:skip_anchors]
  record_waiver.call('--skip-anchors-gate', 'gate 13 (source-anchor value verification)', opts[:skip_anchors])
elsif source_png.nil?
  puts '[SKIP] gate 13: no source dashboard PNG in the workdir (no Phase 1d image artifact) — anchors gate N/A'
else
  sa_path = File.join(opts[:tab], 'source-anchors.json')
  av_path = File.join(opts[:tab], 'anchors-verdict.json')
  sa = File.exist?(sa_path) ? (JSON.parse(File.read(sa_path)) rescue nil) : nil
  n_anchors = sa.is_a?(Hash) ? Array(sa['anchors']).length : 0
  if n_anchors < MIN_ANCHORS
    warn "[FAIL] gate 13: source dashboard PNG present (#{source_png}) but " \
         "#{sa.nil? ? "#{sa_path} is missing/malformed" : "source-anchors.json has only #{n_anchors} anchor(s) (>= #{MIN_ANCHORS} required)"}."
    warn '       While READING the source image at Phase 1d, transcribe its printed values EXACTLY as'
    warn '       printed (raw string kept: "12,345B", not 12345) — every KPI value, the top 3 values of'
    warn '       every ranked list/table, and one representative bucket value per chart. Schema:'
    warn '       SKILL.md Phase 1d / refs/source-anchors.md. Then verify them against the live workbook:'
    warn "         ruby scripts/verify-anchors.rb --workdir #{opts[:tab]} --workbook-id #{opts[:wb] || '<id>'}"
    warn '       Escape hatch (values genuinely untranscribable): --skip-anchors-gate "<reason>".'
    exit 18
  end
  av = File.exist?(av_path) ? (JSON.parse(File.read(av_path)) rescue nil) : nil
  if av.nil?
    warn "[FAIL] gate 13: #{n_anchors} anchor(s) transcribed but #{av_path} is missing/malformed —"
    warn '       the anchors were never verified against the live workbook. Run:'
    warn "         ruby scripts/verify-anchors.rb --workdir #{opts[:tab]} --workbook-id #{opts[:wb] || '<id>'}"
    exit 18
  elsif av['checked'].to_i < n_anchors
    warn "[FAIL] gate 13: anchors-verdict.json is STALE — it checked #{av['checked'].to_i} anchor(s) but " \
         "source-anchors.json now has #{n_anchors}. Re-run verify-anchors.rb."
    exit 18
  elsif av['pass'] != true
    misses = Array(av['missing'])
    warn "[FAIL] gate 13: #{misses.length}/#{av['checked']} source anchor value(s) MISSING from the live workbook exports:"
    misses.first(10).each do |m|
      bc = m['best_candidate']
      warn "         #{m['id']} #{m['label'].inspect} raw=#{m['raw'].inspect}" \
           "#{bc.is_a?(Hash) ? " — closest candidate #{bc['value']} in #{bc['element'].inspect}" : ''}"
    end
    warn '       A printed source value that appears NOWHERE in the workbook exports is the loudest'
    warn '       possible signal the data is wrong (wrong aggregate, wrong unit/10x, missing filter,'
    warn '       collapsed buckets). Fix the workbook — or correct a mistranscribed anchor — then'
    warn '       re-run verify-anchors.rb and this gate. There is no per-anchor waiver.'
    exit 18
  elsif av.key?('tiles_all_nonempty') && av['tiles_all_nonempty'] != true && opts[:allow_empty_tiles].nil?
    # W1.1 general path: anchors matched, but a DISPLAYED tile renders no data.
    # Anchor matches can land entirely in the raw unfiltered feeder table (the
    # field-workbook false-GREEN); a displayed tile that exports 0 data rows is a
    # broken data path regardless of anchor arithmetic. Unwaivable except via the
    # source-PNG-citing --allow-empty-tiles budget waiver.
    empty = Array(av['dashboard_tiles_empty'])
    warn "[FAIL] gate 13: anchors matched, but #{empty.length} displayed dashboard tile(s) export ZERO data rows —"
    warn '       the charts render "No data". A displayed tile with 0 rows is a broken data path even when'
    warn '       every anchor "matched" (they can match only in the raw, unfiltered feeder table).'
    empty.first(10).each { |t| warn "         EMPTY  #{t['id']} #{t['name'].inspect} [#{t['kind']}]" }
    warn '       Common causes: a control/filter literal that matches no rows (e.g. "Region A & B"'
    warn '       vs a calc emitting "Region A and B"), or a calc comparing a NUMBER column to a'
    warn '       string literal (compiles clean, renders NULL). Fix the workbook, re-run verify-anchors.rb,'
    warn '       then re-run this gate. If a chart is GENUINELY empty on the SOURCE dashboard, waive with'
    warn '       --allow-empty-tiles "<reason citing the source PNG>".'
    exit 18
  else
    if opts[:allow_empty_tiles] && av['tiles_all_nonempty'] != true
      record_waiver.call('--allow-empty-tiles', 'gate 13 (empty displayed tiles)', opts[:allow_empty_tiles])
    end
    if av.key?('tiles_all_nonempty')
      tnote = av['tiles_all_nonempty'] ? '; all displayed tiles return data' : '; EMPTY tiles ACCEPTED via --allow-empty-tiles'
    else
      # A verdict that predates the tile-emptiness measurement (no field) is a
      # stale cross-version artifact — a fresh this-branch verify-anchors always
      # writes it. Pass (it is a valid anchors verdict) but WARN so the gap is not
      # silent; the all-embedded oracle path (above) independently fails closed on
      # the absent field, and re-running verify-anchors measures emptiness.
      tnote = ''
      warn '[WARN] gate 13: anchors-verdict.json predates the tile-emptiness measurement (no'
      warn '       tiles_all_nonempty field) — re-run verify-anchors.rb to measure displayed-tile'
      warn '       emptiness (a stale verdict cannot confirm the charts render data).'
    end
    _tol13 = anchors_tol_note.call(av)
    puts "[OK] gate 13: source anchors verified — #{av['matched']}/#{av['checked']} printed source values " \
         "found in the live workbook exports#{_tol13.empty? ? ' at printed precision' : ''}#{tnote}#{_tol13}"
    # G10 (general path — ADVISORY ONLY): per-displayed-tile anchor coverage.
    # With real chart-by-chart parity in force (charts_total > 0), uncovered
    # tiles are still parity-verified — so this is a WARN, not a failure. The
    # charts_total==0 anchors-ORACLE substitution above is where coverage is a
    # hard floor (the oracle is the ONLY value evidence there).
    _cov13 = av['anchor_coverage']
    if _cov13.is_a?(Hash)
      _wv13 = Array((sa.is_a?(Hash) ? sa['coverage_waivers'] : nil))
              .map { |w| w.is_a?(Hash) ? w['tile'].to_s.downcase.strip : nil }.compact.reject(&:empty?)
      _unc13 = Array(_cov13['uncovered']).map(&:to_s).reject { |t| _wv13.include?(t.downcase.strip) }
      if _unc13.any?
        warn "[WARN] gate 13: #{_unc13.length} displayed tile(s) have ZERO anchor coverage: #{_unc13.first(8).join(', ')} —"
        warn '       an anchor only vouches for the tile it lands in. Add anchors for these tiles, or name'
        warn '       each in source-anchors.json coverage_waivers [{tile, reason}] (Phase 1d). Advisory on'
        warn '       this path; the charts_total==0 anchors-ORACLE substitution REQUIRES full coverage.'
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Gate 14 — visual-similarity floor (exit 20). A MEASURED companion to the
# recorded visual verdict (gate 8b): scripts/visual-similarity.py (ships
# separately; gate is invisible until the script exists) scores the source
# dashboard PNG against the Sigma render and writes visual-similarity.json;
# its `pass` field is the verdict. CLI contract (fixed):
#   python3 scripts/visual-similarity.py --source <src> --render <render> \
#     --json-out <workdir>/visual-similarity.json
# VISUAL_SIMILARITY_SCRIPT env overrides the script path (tests).
# ---------------------------------------------------------------------------
vsim_script = ENV['VISUAL_SIMILARITY_SCRIPT'] || File.join(__dir__, 'visual-similarity.py')
if opts[:skip_vsim]
  record_waiver.call('--skip-visual-similarity', 'gate 14 (visual-similarity floor)', opts[:skip_vsim])
elsif File.exist?(vsim_script)
  if source_png.nil? || render_png.nil?
    puts "[SKIP] gate 14: visual-similarity floor N/A — #{source_png.nil? ? 'no source dashboard PNG' : 'no validated Sigma render'} to compare"
  else
    vs_out = File.join(opts[:tab], 'visual-similarity.json')
    # SIGMA_PYTHON honors the env's resolved interpreter (venv / py -3 shim) —
    # bare python3 missed the deps-bearing venv (v5.5 e2e field-caught; the
    # deferred gap from v5.4.15).
    _vsim_py = ENV['SIGMA_PYTHON'].to_s.strip
    _vsim_py = 'python3' if _vsim_py.empty?
    # W1.7 wiring: when the build produced a dashboard layout (zone geometry),
    # pass it as --tiles so the per-tile blank detector arms — a majority-blank
    # render then FAILS the floor instead of passing on global similarity alone.
    # Without the file the invocation is byte-identical to the no-tiles contract.
    _vsim_cmd = [_vsim_py, vsim_script, '--source', source_png, '--render', render_png, '--json-out', vs_out]
    _vsim_tiles = File.join(opts[:tab], 'dashboard-layout.json')
    _vsim_cmd += ['--tiles', _vsim_tiles] if File.exist?(_vsim_tiles)
    system(*_vsim_cmd)
    vsim_status = $? ? $?.exitstatus : 'not-run'
    vs = File.exist?(vs_out) ? (JSON.parse(File.read(vs_out)) rescue nil) : nil
    if vs.nil?
      warn "[WARN] gate 14: visual-similarity.py exited #{vsim_status} with no readable #{vs_out} — floor NOT" \
           ' measured (deps missing / unreadable input; NOT a pass — stated, never silent).'
    elsif vs['pass'] == true
      _tn = vs['tiles_measured'] ? " — #{vs['tiles_measured']} tile(s) measured, #{Array(vs['tiles_blank']).length} blank" : ''
      puts "[OK] gate 14: visual-similarity floor passed#{vs['score'] ? " (score=#{vs['score']})" : ''}#{_tn}"
    else
      warn "[FAIL] gate 14: measured visual similarity below the floor#{vs['score'] ? " (score=#{vs['score']})" : ''} —"
      warn "       the render does not look like the source (#{source_png} vs #{render_png})."
      if Array(vs['tiles_blank']).any?
        warn "       render-side blank tile detector (--tiles): #{Array(vs['tiles_blank']).length} blank tile(s): " \
             "#{Array(vs['tiles_blank']).first(8).join(', ')}"
      end
      warn '       Re-enter the Phase 5g RCF loop (fidelity-loop.rb) and fix layout/kind/palette deltas,'
      warn '       then re-render and re-run. Escape hatch: --skip-visual-similarity "<reason>"'
      warn '       (counted against the waiver budget; name it in your migration report).'
      exit 20
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
    # W1.4 contradiction guard: a tile attested visual_verified=true whose LIVE
    # element export returns ZERO data rows is a false attestation — the exact
    # 2026-07 bulk python one-liner that set visual_verified=true over "No data"
    # tiles without reading the render. Cross-check the manifest against
    # verify-anchors' measured per-element emptiness.
    _av9 = (JSON.parse(File.read(File.join(opts[:tab], 'anchors-verdict.json'))) rescue nil)
    if _av9.is_a?(Hash) && _av9['tiles'].is_a?(Array) && opts[:allow_empty_tiles].nil?
      rows_by_id = _av9['tiles'].each_with_object({}) { |t, h| h[t['id'].to_s] = t['data_rows'] }
      attested_empty = man.select { |m| m['visual_verified'] == true && rows_by_id[m['element_id'].to_s] == 0 }
      if attested_empty.any?
        warn "[FAIL] gate 9: #{attested_empty.size} tile(s) attested visual_verified=true but their live element"
        warn '       export returns ZERO data rows — a false attestation over a "No data" render:'
        attested_empty.first(8).each { |m| warn "         #{m['element_id']} #{m['worksheet'].inspect}" }
        warn '       Fix the data path, re-run verify-anchors.rb, re-render, and re-verify honestly. A genuinely'
        warn '       empty source chart is waived with --allow-empty-tiles "<reason citing the source PNG>".'
        exit 11
      end
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
    # Gate 9b — SHAPE IDENTITY (field-caught: a run marked reshaped tiles
    # "verified" because their DATA matched — a ranked bar-table shipped as a
    # wall of grouped bars, annotated strip panels shipped as generic bars, and
    # the owner immediately judged the result "furthest from desired" while
    # every gate was green). visual_verified attests values/trends;
    # shape_match attests the tile is RECOGNIZABLY THE SAME VISUALIZATION.
    # Manifests written by current verify-visual-tiles.rb always carry the
    # field; legacy manifests (no shape_match key anywhere) are grandfathered.
    if man.any? { |m| m.key?('shape_match') }
      reshaped = man.select { |m| m['shape_match'] != true }
      if reshaped.any?
        warn "[FAIL] gate 9b: #{reshaped.size}/#{man.size} tile(s) verified for DATA but not for SHAPE: " \
             "#{reshaped.map { |m| "#{m['worksheet']}#{m['expected_kind'] ? " (source: #{m['expected_kind']})" : ''}" }.join(', ')}."
        warn '       Right data rendered as a DIFFERENT visualization is not fidelity — rebuild each'
        warn '       tile to the source shape (refs/fidelity-recipes.md; e.g. ranked bar-table →'
        warn '       pivot + dataBars, strip panel → per-panel chart + refMarks), re-render, then set'
        warn '       "shape_match": true in visual-verify/manifest.json. Escape hatch (only for a'
        warn '       VERIFIED product limitation, evidence in your report): --skip-visual-tiles "<reason>".'
        exit 11
      end
    end
    puts "[OK] gate 9: #{man.size} build-from-signals tile(s) image-verified (values + shape identity)"
  end
end

# ---------------------------------------------------------------------------
# Gate 11 — post-publish interactivity guide (exit 16). Dashboard ACTIONS
# (filter / highlight / navigate / set-action / parameter-action / URL) are the
# one interactivity class workbooks-as-code cannot port — the customer wires
# cross-element filtering in the Sigma UI after publish. Every workbook in the
# 10-conversion live run that carried actions needed a hand-written handoff
# note; this gate makes the guide (POSTPUBLISH_GUIDE.md, generated by
# scripts/build-postpublish-guide.rb) mandatory whenever the source recorded
# actions. Action census sources, broadest wins:
#   - <workdir>/dashboard-layout-meta.json — parse-twb-layout.rb marks each
#     action-driven worksheet filter with is_action:true / kind:"action"
#   - <workdir>/*-gaps-report.json — scan-workbook-gaps.rb's "Dashboard filter /
#     highlight / nav actions" feature (command='tsc:tsl-*' matches; also covers
#     highlight/nav actions that never materialize as worksheet filters)
# Neither file present → census unavailable → stated SKIP (never a silent pass).
# ---------------------------------------------------------------------------
if opts[:skip_postpublish]
  record_waiver.call('--skip-postpublish-guide', 'gate 11 (post-publish interactivity guide)', opts[:skip_postpublish])
else
  meta_actions = 0
  gaps_actions = 0
  census_sources = []
  meta_path = File.join(opts[:tab], 'dashboard-layout-meta.json')
  if File.exist?(meta_path)
    meta = JSON.parse(File.read(meta_path)) rescue nil
    if meta.is_a?(Hash) && meta['worksheets'].is_a?(Hash)
      meta_actions = meta['worksheets'].values.sum do |ws|
        next 0 unless ws.is_a?(Hash)
        Array(ws['filters']).count { |f| f.is_a?(Hash) && (f['is_action'] == true || f['kind'] == 'action') }
      end
      census_sources << meta_path
    end
  end
  Dir.glob(File.join(opts[:tab], '*-gaps-report.json')).sort.each do |gp|
    gj = JSON.parse(File.read(gp)) rescue nil
    next unless gj.is_a?(Hash)
    feat = Array(gj['detected_features']).find do |f|
      f.is_a?(Hash) && (f['pat'].to_s.include?('tsc:tsl-') || f['name'].to_s =~ %r{filter\s*/\s*highlight\s*/\s*nav actions}i)
    end
    next unless feat
    gaps_actions = [gaps_actions, feat['count'].to_i].max
    census_sources << gp
  end
  n_actions = [meta_actions, gaps_actions].max
  guide_path = File.join(opts[:tab], 'POSTPUBLISH_GUIDE.md')
  if census_sources.empty?
    puts '[SKIP] gate 11: no dashboard-layout-meta.json / *-gaps-report.json in the workdir — dashboard-action census unavailable'
  elsif n_actions.zero?
    puts '[OK] gate 11: source recorded no dashboard filter/highlight/nav actions — post-publish guide not required'
  elsif File.exist?(guide_path)
    puts "[OK] gate 11: #{n_actions} source dashboard action(s) detected; POSTPUBLISH_GUIDE.md present (#{guide_path})"
  else
    warn "[FAIL] gate 11: source dashboards carry #{n_actions} interactive actions that workbooks-as-code"
    warn '       cannot port — run scripts/build-postpublish-guide.rb to generate the user handoff guide.'
    warn "       (census: #{census_sources.join(', ')})"
    warn "       The guide must land at #{guide_path} — it tells the customer which"
    warn '       cross-element filter/highlight/nav wirings to add in the Sigma UI after publish.'
    warn '       Escape hatch: --skip-postpublish-guide "<reason>" (name it in your migration report).'
    exit 16
  end
end

# ---------------------------------------------------------------------------
# Gate 12 — deferred DM elements (exit 17). post-and-readback.rb
# --quarantine-on-failure saves a DM POST killed by one broken element by
# moving the offender(s) to <workdir>/deferred-elements.json and re-POSTing the
# rest (hackathon Rec5). That DM is PARTIAL by construction — declaring GREEN
# on it would silently ship a data model missing elements. Non-empty file →
# hard FAIL until the elements are fixed + re-POSTed (then delete the file).
# No file / empty deferred list → OK. Escape: --accept-deferred-elements
# "<reason>" (recorded as a waiver; name it + the dropped elements in the report).
# ---------------------------------------------------------------------------
deferred_path = File.join(opts[:tab], 'deferred-elements.json')
if opts[:accept_deferred]
  record_waiver.call('--accept-deferred-elements', 'gate 12 (deferred/quarantined DM elements)', opts[:accept_deferred])
elsif File.exist?(deferred_path)
  ddoc = JSON.parse(File.read(deferred_path)) rescue nil
  deferred = ddoc.is_a?(Hash) ? Array(ddoc['deferred']) : (ddoc.is_a?(Array) ? ddoc : nil)
  if deferred.nil?
    warn "[FAIL] gate 12: #{deferred_path} is malformed (expected {\"deferred\":[...]} or a bare array)."
    warn '       Fix or delete the file (delete ONLY if every quarantined element was restored + re-POSTed).'
    exit 17
  elsif deferred.any?
    names = deferred.map { |d| d.is_a?(Hash) ? (d.dig('element', 'name') || d.dig('element', 'id') || '(unnamed)') : d.to_s }
    warn "[FAIL] gate 12: #{deferred.size} DM element(s) still deferred (quarantined at POST time) — the live"
    warn '       data model is PARTIAL. Resolve the deferred elements and re-POST:'
    names.each { |n| warn "         - #{n}" }
    warn "       Fix each element spec in #{deferred_path}, restore it into the DM spec,"
    warn '       PUT it back (ruby scripts/post-and-readback.rb --type datamodel --update-id <dmId> ...),'
    warn '       then delete the file and re-run this gate.'
    warn '       Escape hatch (knowingly shipping a partial DM): --accept-deferred-elements "<reason>"'
    warn '       (name it AND the dropped elements in your migration report).'
    exit 17
  else
    puts "[OK] gate 12: deferred-elements.json present but empty — all quarantined elements resolved"
  end
else
  puts '[OK] gate 12: no deferred-elements.json — no DM elements were quarantined'
end

# ---------------------------------------------------------------------------
# Gate 15 — manual custom-SQL residues (exit 22; G6). Phase 1e routes the
# STAYS-MANUAL window/table-calc family (requires_custom_sql) to the Custom SQL
# path correctly, but nothing used to bind the routed measure to the tile that
# plots it: the build silently shipped a magnitude proxy and the divergence
# surfaced only at Phase 6 (~2h later; the single gap that kept run 2 YELLOW).
# Converters that emit <workdir>/manual-residues.json declare, per residue, the
# tile that plots it + status: "unbuilt" | "built". Any 'unbuilt' entry blocks
# GREEN — the tile's numbers are wrong until the Custom SQL element exists and
# the tile measure is repointed. --accept-manual-residues "<calc,...>" waives
# ONLY the named residues (budget-counted). No ledger file → stated OK
# (back-compat: the converter declared no residues).
# ---------------------------------------------------------------------------
mr_path = File.join(opts[:tab], 'manual-residues.json')
if File.exist?(mr_path)
  mr_doc = JSON.parse(File.read(mr_path)) rescue nil
  mr_entries = mr_doc.is_a?(Hash) ? mr_doc['residues'] : mr_doc
  unless mr_entries.is_a?(Array)
    warn "[FAIL] gate 15: #{mr_path} is malformed (expected {\"residues\":[...]} or a bare array)."
    warn '       Fix the file (or delete it ONLY if no dashboard tile plots a requires_custom_sql calc).'
    exit 22
  end
  mr_accept = Array(opts[:accept_manual_residues]).map { |s| s.to_s.downcase.strip }
  mr_unbuilt = mr_entries.select { |e| e.is_a?(Hash) && e['status'].to_s == 'unbuilt' }
  mr_waived, mr_blocking = mr_unbuilt.partition { |e| mr_accept.include?(e['calc'].to_s.downcase.strip) }
  if mr_waived.any?
    record_waiver.call('--accept-manual-residues', 'gate 15 (manual custom-SQL residues)',
                       "accepted unbuilt: #{mr_waived.map { |e| e['calc'] }.uniq.join(', ')}")
  end
  if mr_blocking.any?
    warn "[FAIL] gate 15: #{mr_blocking.length} manual custom-SQL residue(s) still 'unbuilt' in #{mr_path} —"
    warn '       each is a window/table-calc a dashboard tile PLOTS; the tile currently renders a'
    warn '       MAGNITUDE PROXY, i.e. its numbers diverge from the source:'
    mr_blocking.first(10).each { |e| warn "         - #{e['calc'].inspect} (tile #{e['tile'].inspect})" }
    warn '       For each: create the Custom SQL DM element (the ledger entry carries the Tableau formula'
    warn '       + an OVER() SQL skeleton), repoint the tile\'s measure column at it, then set'
    warn '       "status": "built" on the entry and re-run this gate.'
    warn '       Escape hatch (knowingly shipping the proxy): --accept-manual-residues "<calc,...>"'
    warn '       (budget-counted; name each residue in your migration report).'
    exit 22
  end
  mr_built = mr_entries.count { |e| e.is_a?(Hash) && e['status'].to_s == 'built' }
  puts "[OK] gate 15: manual custom-SQL residues resolved — #{mr_built} built" \
       "#{mr_waived.any? ? ", #{mr_waived.length} accepted-unbuilt (WAIVED)" : ''} of #{mr_entries.length}"
else
  puts '[OK] gate 15: no manual-residues.json — no unbound custom-SQL residues declared by the build'
end

# ---------------------------------------------------------------------------
# Gate 16 — join-cardinality ledger (exit 23; PR-4). Sigma's Lookup() returns
# ONE ARBITRARY match per key, so a synthesized Coalesce/Lookup (or a federated
# source join) whose right side is NOT unique at the key grain silently
# undercounts every aggregate over the looked-up column — zero errors anywhere
# (field failure: target at user×date×line-item grain, key at user×date).
# The DM build derives <workdir>/join-plan.json (lib/join_plan.rb): one entry
# per federated .twb join + per synthesized Lookup, status "unprobed".
# scripts/probe-join-keys.rb proves each grain assumption against the warehouse
# and records unique | non-unique (+ sample duplicate keys) | error; a
# non-unique entry blocks until a resolution {how: preaggregated|waived,
# reason} is recorded via --resolve. Belt-and-braces: a MISSING ledger on a run
# whose dm-spec.json contains `Lookup(` also fails — synthesis happened and
# nothing proved the grain. No escape flag — the recorded resolution is the
# only sanctioned waiver (it lives in the ledger as evidence, not in a CLI
# flag a re-run forgets).
#
# TWO LEDGER SHAPES (wave-2 pre-land for W2.18 — lane B lands this BEFORE the
# converter emits real joins, so emission can never hit a false-fail window):
#   shape 1 (shipped)  — Lookup/federated entries proven by probe:
#                        status unprobed -> unique | non-unique | error, with
#                        {how: preaggregated|waived} resolutions;
#   shape 2 (emitted)  — the converter emitted a REAL warehouse join
#                        (`"kind": "join"` in dm-spec.json) instead of
#                        synthesizing a Lookup: the derivation records the
#                        entry with status "emitted" (+ its join_type). A real
#                        join has no arbitrary-match grain assumption to
#                        prove, so an emitted entry is terminal — but ONLY
#                        while the dm-spec actually carries an emitted join: a
#                        hand-stamped "emitted" status over a Lookup-only spec
#                        still counts as UNPROVEN (the status is evidence-
#                        bound, never a skip token). The binding is PER-ENTRY:
#                        "emitted" is honored only on converter-written
#                        entries (kind "emitted-join" — the W2.18 emission
#                        shape, JOIN_ENTRY_EMITTED in the lane tests) and only
#                        while the count of such entries stays within the
#                        spec's own `"kind": "join"` occurrence count — one
#                        genuine emitted join must never become a universal
#                        skip token for OTHER ledger entries (a federated-join
#                        or lookup-synthesis entry hand-stamped "emitted"
#                        stays UNPROVEN whatever the spec carries).
# ---------------------------------------------------------------------------
jp_path = File.join(opts[:tab], 'join-plan.json')
jp_dm = File.join(opts[:tab], 'dm-spec.json')
# encoding: 'UTF-8' is NOT optional (F5 crash class, issue #752). This is the
# only RAW File.read in this file — every other read feeds JSON.parse, which
# tolerates locale-tagged bytes. A raw read inherits the locale's default
# external encoding, so under an unset/C locale a dm-spec.json carrying one
# em-dash makes the .scan below raise
# `invalid byte sequence in US-ASCII (ArgumentError)` and the gate exits 1
# instead of its real verdict. Reproduced on ruby 3.3.12, not just 2.6.
jp_dm_src = File.exist?(jp_dm) ? (File.read(jp_dm, encoding: 'UTF-8') rescue '') : ''
jp_dm_join_n = jp_dm_src.scan(/"kind"\s*:\s*"join"/).length
jp_dm_has_emitted_join = jp_dm_join_n.positive?
jp_resolved = lambda do |e|
  e['resolution'].is_a?(Hash) && %w[preaggregated waived].include?(e['resolution']['how'].to_s)
end
if File.exist?(jp_path)
  jp_doc = JSON.parse(File.read(jp_path)) rescue nil
  jp_entries = jp_doc.is_a?(Hash) ? jp_doc['entries'] : jp_doc
  unless jp_entries.is_a?(Array)
    warn "[FAIL] gate 16: #{jp_path} is malformed (expected {\"entries\":[...]} or a bare array)."
    warn '       Re-derive the ledger (the DM build emits it) — do not hand-edit it into shape.'
    exit 23
  end
  jp_entries = jp_entries.select { |e| e.is_a?(Hash) }
  # Per-entry evidence binding (see the shape-2 doc above): only converter-
  # written "emitted-join" entries can carry "emitted", and never more of them
  # than the spec has `"kind": "join"` occurrences.
  jp_emitted_claims = jp_entries.count { |e| e['kind'].to_s == 'emitted-join' && e['status'].to_s == 'emitted' }
  jp_emitted_bound = jp_dm_has_emitted_join && jp_emitted_claims <= jp_dm_join_n
  jp_emitted_ok = lambda do |e|
    e['kind'].to_s == 'emitted-join' && e['status'].to_s == 'emitted' && jp_emitted_bound
  end
  jp_unproven = jp_entries.reject { |e| e['status'].to_s == 'unique' || e['status'].to_s == 'non-unique' || jp_resolved.call(e) || jp_emitted_ok.call(e) }
  jp_blocking = jp_entries.select { |e| e['status'].to_s == 'non-unique' && !jp_resolved.call(e) }
  if jp_unproven.any? || jp_blocking.any?
    warn "[FAIL] gate 16: join-cardinality ledger unresolved (#{jp_path}) —"
    jp_unproven.first(10).each do |e|
      note = if e['status'].to_s != 'emitted'
               ''
             elsif e['kind'].to_s != 'emitted-join'
               ' [status "emitted" on a non-emitted entry — only converter-written kind "emitted-join" entries can carry it; evidence-bound, re-derive the ledger]'
             elsif !jp_dm_has_emitted_join
               ' [status "emitted" but dm-spec.json carries no "kind": "join" — evidence-bound, re-derive the ledger]'
             else
               ' [more "emitted" entries than "kind": "join" occurrences in dm-spec.json — evidence-bound, re-derive the ledger]'
             end
      warn "         - UNPROVEN (#{e['status'] || 'unprobed'}): #{e['kind']} #{e['left'].inspect} -> #{e['right'].inspect} on (#{Array(e['keys']).join(', ')})#{note}"
    end
    jp_blocking.first(10).each do |e|
      sample = Array(e['duplicates']).first
      kv = sample.is_a?(Hash) ? (sample['keys'] || {}).map { |k, v| "#{k}=#{v}" }.join('|') : nil
      warn "         - NON-UNIQUE: #{e['kind']} #{e['left'].inspect} -> #{e['right'].inspect} on (#{Array(e['keys']).join(', ')})" \
           "#{kv ? " e.g. #{kv} ×#{sample['count']}" : ''}"
    end
    warn '       Lookup() returns one ARBITRARY match per key — a non-unique right side silently'
    warn '       undercounts every aggregate over the looked-up column. Prove each entry with'
    warn '       scripts/probe-join-keys.rb; for non-unique entries either PRE-AGGREGATE the target'
    warn '       to the key grain (grouped helper element + repointed Lookup) or escalate to the'
    warn '       operator, and record the evidence: probe-join-keys.rb --resolve <i> --how <preaggregated|waived> --reason "..."'
    exit 23
  end
  jp_res_n = jp_entries.count { |e| jp_resolved.call(e) }
  jp_emit_n = jp_entries.count { |e| jp_emitted_ok.call(e) }
  puts "[OK] gate 16: join-cardinality ledger resolved — #{jp_entries.count { |e| e['status'].to_s == 'unique' }} unique" \
       "#{jp_res_n.positive? ? ", #{jp_res_n} resolved" : ''}" \
       "#{jp_emit_n.positive? ? ", #{jp_emit_n} emitted as real join(s) (no Lookup grain assumption)" : ''} of #{jp_entries.length} (join-plan.json)"
else
  # Belt-and-braces: no ledger, but the DM spec synthesized a Lookup OR emitted
  # a real join — either way the derivation was skipped and nothing recorded
  # the join surface (shape 2 keeps the same doctrine: emission without a
  # ledger is a silent join surface, exactly the false-PASS window the W2.18
  # pre-land closes).
  jp_has_lookup = jp_dm_src.include?('Lookup(')
  if jp_has_lookup || jp_dm_has_emitted_join
    what = jp_has_lookup ? 'contains synthesized Lookup() calls' : 'emits real join(s) ("kind": "join")'
    warn "[FAIL] gate 16: #{jp_dm} #{what} but no join-plan.json ledger exists —"
    warn '       the join-cardinality derivation never ran, so nothing recorded the join surface'
    warn "       #{jp_has_lookup ? '(the silent-undercount class for Lookup grain)' : '(emitted joins must be ledgered with status "emitted")'}. Re-run the DM build (it emits"
    warn '       the ledger), then probe any Lookup entries with scripts/probe-join-keys.rb.'
    exit 23
  end
  puts '[OK] gate 16: no join-plan.json, no Lookup( and no "kind": "join" in the dm-spec — no join grain assumptions (or emitted join surface) to prove'
end

# ---------------------------------------------------------------------------
# Gate 17 — LOD translation ledger (exit 24; #423). {FIXED/INCLUDE/EXCLUDE}
# calcs have no row-level Sigma equivalent; when the documented synthesis
# (grouped helper element / grouped Custom SQL / FIXED-relationship surfacing)
# does not fire, the calc's caption can collide with a look-alike RAW column
# (the emitted measure silently reads an unrelated physical column) or the
# calc vanishes from the build entirely — zero errors either way. The
# post-convert audit (tableau: audit-lod-calcs.rb / lib/lod_audit.rb) writes
# <workdir>/lod-audit.json: one entry per source LOD calc, classes lod-synth /
# manual-residue / reference-derived (resolved) vs suspect-alias /
# silently-dropped (UNRESOLVED — blocks until a resolution {how: manual|waived,
# reason} is recorded via the audit script's --resolve, or the calc is
# translated / declared in manual-residues.json and the audit re-run).
# Belt-and-braces: a MISSING ledger on a workdir whose calc-fields.json census
# carries an LOD calc also fails — LODs exist and nothing audited them. No
# ledger AND no census evidence → stated OK (back-compat / non-Tableau
# plugins). No escape flag — the recorded resolution is the only sanctioned
# waiver (it lives in the ledger as evidence, not in a CLI flag a re-run
# forgets).
# ---------------------------------------------------------------------------
la_path = File.join(opts[:tab], 'lod-audit.json')
la_unresolved_classes = %w[suspect-alias silently-dropped]
la_resolved = lambda do |e|
  return true unless la_unresolved_classes.include?(e['class'].to_s)
  e['resolution'].is_a?(Hash) && %w[manual waived].include?(e['resolution']['how'].to_s)
end
if File.exist?(la_path)
  la_doc = JSON.parse(File.read(la_path)) rescue nil
  la_entries = la_doc.is_a?(Hash) ? la_doc['entries'] : la_doc
  unless la_entries.is_a?(Array)
    warn "[FAIL] gate 17: #{la_path} is malformed (expected {\"entries\":[...]} or a bare array)."
    warn '       Re-derive the ledger (the LOD audit emits it) — do not hand-edit it into shape.'
    exit 24
  end
  la_entries = la_entries.select { |e| e.is_a?(Hash) }
  la_blocking = la_entries.reject { |e| la_resolved.call(e) }
  if la_blocking.any?
    warn "[FAIL] gate 17: LOD translation ledger unresolved (#{la_path}) —"
    la_blocking.first(10).each do |e|
      if e['class'].to_s == 'suspect-alias'
        warn "         - SUSPECT-ALIAS: #{e['calc'].inspect} ({#{e['lod_kind']}}) emitted as" \
             " #{e.dig('evidence', 'formula').inspect} — reads #{Array(e['suspect_refs']).join(', ')}," \
             " which is NOT in the LOD expression's own reference set (numbers silently WRONG)"
      else
        warn "         - SILENTLY-DROPPED: #{e['calc'].inspect} ({#{e['lod_kind']}}) has no emitted" \
             ' translation and no manual-residues.json declaration'
      end
    end
    warn '       The translator must not guess an LOD. Build the documented translation (grouped'
    warn '       helper element / grouped Custom SQL + relationship) or declare the calc in'
    warn '       manual-residues.json, then RE-RUN the LOD audit; hand-authored or operator-accepted'
    warn '       entries record evidence via: audit-lod-calcs.rb --resolve <i> --how <manual|waived> --reason "..."'
    exit 24
  end
  la_res_n = la_entries.count { |e| e['resolution'].is_a?(Hash) }
  puts "[OK] gate 17: LOD translation ledger resolved — " \
       "#{la_entries.count { |e| e['class'].to_s == 'lod-synth' }} synth, " \
       "#{la_entries.count { |e| e['class'].to_s == 'manual-residue' }} manual-residue, " \
       "#{la_entries.count { |e| e['class'].to_s == 'reference-derived' }} reference-derived" \
       "#{la_res_n.positive? ? ", #{la_res_n} resolved-by-hand" : ''} of #{la_entries.length} (lod-audit.json)"
else
  # Belt-and-braces: no ledger, but the calc census says LOD calcs exist — the
  # audit never ran and nothing checked their translations.
  la_cf = File.join(opts[:tab], 'calc-fields.json')
  la_has_lod = false
  if File.exist?(la_cf)
    begin
      la_cf_doc = JSON.parse(File.read(la_cf))
      la_has_lod = Array(la_cf_doc.is_a?(Hash) ? la_cf_doc['calcs'] : la_cf_doc).any? do |c|
        c.is_a?(Hash) && (c['is_lod'] == true || c['formula'].to_s =~ /\{\s*(?:FIXED|INCLUDE|EXCLUDE)\b/i)
      end
    rescue StandardError
      la_has_lod = false
    end
  end
  if la_has_lod
    warn "[FAIL] gate 17: #{la_cf} carries LOD ({FIXED/INCLUDE/EXCLUDE}) calc(s) but no lod-audit.json"
    warn '       ledger exists — the post-convert LOD audit never ran, so nothing verified those calcs'
    warn '       were translated (vs fuzzy-aliased to a look-alike raw column, or dropped silently).'
    warn '       Run the audit (tableau: ruby scripts/audit-lod-calcs.rb --workdir <W>), resolve any'
    warn '       blocking entries, then re-run this gate.'
    exit 24
  end
  puts '[OK] gate 17: no lod-audit.json and no LOD calcs in the census — no LOD translations to audit'
end

# ---------------------------------------------------------------------------
# Gate 18 — ground-truth numeric coverage (exit 25; PR-6). EVERY displayed
# tile must be numeric-verified by >=1 oracle:
#   - the warehouse-sql or vds GROUND TRUTH matched (verify-ground-truth.rb
#     stamped numeric_parity verdict "match" for the tile), OR
#   - VALUED anchors vouch for it (numeric anchors with provenance
#     view-csv|vds — never png-eyeball, never name-only roster labels — that
#     matched IN the tile; verify-ground-truth.rb stamps these as
#     oracle:"anchors" verdict:"match"), OR
#   - the tile carries a NAMED waiver in ground-truth-plan.json
#     coverage_waivers [{tile, reason}].
# anchor-only / unverifiable classifications WITHOUT valued-anchor coverage
# fail NAMING the tiles. A "diverge" or oracle-vs-anchors "conflict" stamp is
# NEVER waivable — the numbers are (or may be) wrong; investigate, don't ship.
# No skip flag — the ledger waiver is the only sanctioned escape (the same
# doctrine as gates 16/17: evidence lives in the ledger, not in a CLI flag a
# re-run forgets).
# ---------------------------------------------------------------------------
gt18_path = File.join(opts[:tab], 'ground-truth-plan.json')
if File.exist?(gt18_path)
  gt18_doc = JSON.parse(File.read(gt18_path)) rescue nil
  gt18_entries = gt18_doc.is_a?(Hash) ? gt18_doc['entries'] : nil
  unless gt18_entries.is_a?(Array)
    warn "[FAIL] gate 18: #{gt18_path} is malformed (expected {\"entries\":[...]})."
    warn '       Re-derive the ledger (ruby scripts/derive-ground-truth.rb) — do not hand-edit it into shape.'
    exit 25
  end
  gt18_entries = gt18_entries.select { |e| e.is_a?(Hash) }
  # numeric_parity stamps: parity-final.json first (verify-ground-truth.rb
  # extends it), the standalone numeric-parity.json as fallback.
  np18 = begin
    _pf18 = File.exist?(summary_path) ? JSON.parse(File.read(summary_path)) : nil
    _pf18.is_a?(Hash) ? _pf18['numeric_parity'] : nil
  rescue JSON::ParserError
    nil
  end
  np18 = (JSON.parse(File.read(File.join(opts[:tab], 'numeric-parity.json'))) rescue nil) unless np18.is_a?(Hash)
  np18_tiles = np18.is_a?(Hash) && np18['tiles'].is_a?(Hash) ? np18['tiles'] : nil
  if np18_tiles.nil?
    warn '[FAIL] gate 18: ground-truth-plan.json exists but the numeric comparison never ran — no'
    warn '       numeric_parity stamps in parity-final.json (and no numeric-parity.json). Run:'
    warn "         ruby scripts/run-ground-truth.rb --workdir #{opts[:tab]} --connection-id <id>"
    warn "         ruby scripts/verify-ground-truth.rb --workdir #{opts[:tab]}"
    exit 25
  end
  if np18['plan_generated_at'].to_s != gt18_doc['generated_at'].to_s
    warn "[FAIL] gate 18: numeric_parity stamps are STALE — compared against plan " \
         "#{np18['plan_generated_at'].inspect} but ground-truth-plan.json is #{gt18_doc['generated_at'].inspect}."
    warn '       Re-run scripts/run-ground-truth.rb and scripts/verify-ground-truth.rb.'
    exit 25
  end
  gt18_waived = Array(gt18_doc['coverage_waivers'])
                .map { |w| w.is_a?(Hash) ? w['tile'].to_s.downcase.strip : nil }.compact.reject(&:empty?)
  np18_by_key = np18_tiles.each_with_object({}) { |(k, v), h| h[k.to_s.downcase.strip] = v }
  gt18_diverged = []
  gt18_conflicted = []
  gt18_unverified = []
  gt18_waived_n = 0
  gt18_verified = Hash.new(0)
  gt18_entries.each do |e|
    tile = e['chart'].to_s
    s = np18_by_key[tile.downcase.strip]
    if s.is_a?(Hash) && s['verdict'] == 'diverge'
      gt18_diverged << [tile, s]
    elsif s.is_a?(Hash) && s['conflict']
      gt18_conflicted << [tile, s]
    elsif s.is_a?(Hash) && s['verdict'] == 'match'
      gt18_verified[s['oracle'].to_s] += 1
    elsif gt18_waived.include?(tile.downcase.strip)
      gt18_waived_n += 1
    else
      gt18_unverified << [tile, e, s]
    end
  end
  if gt18_diverged.any? || gt18_conflicted.any? || gt18_unverified.any?
    warn '[FAIL] gate 18: ground-truth numeric coverage — every displayed tile must be numeric-verified'
    warn '       by >=1 oracle (warehouse-sql/vds ground truth matched, or VALUED anchors) or carry a'
    warn '       named coverage_waivers entry in ground-truth-plan.json.'
    gt18_diverged.first(10).each do |tile, s|
      w = s['worst']
      warn "         - DIVERGED (#{s['oracle']}): #{tile.inspect} — #{s['reason']}" \
           "#{w.is_a?(Hash) ? " (#{w['measure'].inspect}: ground truth #{w['ground_truth'].inspect} vs Sigma #{w['sigma'].inspect})" : ''}"
    end
    gt18_conflicted.first(10).each do |tile, s|
      warn "         - CONFLICT (#{s.dig('conflict', 'type')}): #{tile.inspect} — the oracle and the anchors" \
           ' DISAGREE; FATAL-investigate (see verify-ground-truth.rb output), never auto-resolved'
    end
    gt18_unverified.first(10).each do |tile, e, s|
      warn "         - UNVERIFIED (#{e['classification'] || '?'}): #{tile.inspect} — " \
           "#{(s.is_a?(Hash) ? s['reason'] : nil) || e['reason'] || 'no numeric_parity stamp for this tile'}"
    end
    warn '       Diverged/conflicted tiles are NEVER waivable — the numbers are wrong (or contested):'
    warn '       fix the workbook / investigate the conflict, then re-run verify-ground-truth.rb.'
    warn '       For genuinely unverifiable tiles: transcribe VALUED anchors (numeric, provenance'
    warn '       view-csv|vds — re-read the source view CSV/VDS, not the PNG) so the tile is vouched'
    warn '       for, or name it in ground-truth-plan.json coverage_waivers [{"tile": "<chart>",'
    warn '       "reason": "<why no oracle can verify it>"}]. There is no skip flag.'
    exit 25
  end
  gt18_parts = gt18_verified.map { |k, v| "#{v} #{k}" }
  puts "[OK] gate 18: ground-truth numeric coverage — #{gt18_entries.length} tile(s) all verified" \
       " (#{gt18_parts.empty? ? 'none' : gt18_parts.join(', ')}" \
       "#{gt18_waived_n.positive? ? ", #{gt18_waived_n} coverage-waived in the ledger" : ''})"
else
  # Belt-and-braces: the workdir carries the derivation inputs (a source .twb +
  # a parity plan) but the coverage ledger was never derived — the numeric
  # oracle was skipped, not inapplicable.
  gt18_twb = Dir.glob(File.join(opts[:tab], '*.twb')).first
  if gt18_twb && File.exist?(File.join(opts[:tab], 'parity-plan.json'))
    # ── W2.1 (gate half): Tier-S GT-trio skip — rides THIS gate's own oracle
    # set (the comment block above), never the charts_total==0 ANCHORS-ORACLE
    # substitution (that doctrine is scoped to all-embedded workbooks and is
    # untouched). On a Tier-S run (migrate-state.json tier written by lane A;
    # fail-closed when absent) the orchestrator may skip the ground-truth trio
    # probe workbooks entirely; the gate then evaluates the VALUED-anchors
    # oracle DIRECTLY and can still fail: every displayed tile (parity-plan
    # charts — the same universe derive-ground-truth.rb would have ledgered)
    # must hold >= 1 VALUED anchor MATCHED IN it (numeric, provenance
    # view-csv|vds, never png-eyeball — anchors-verdict.json detail rows,
    # exactly the rows verify-ground-truth.rb stamps oracle:"anchors"
    # verdict:"match" from). 100% displayed-tile coverage, no waiver credit on
    # this path; anything less → exit 25 with the trio as the remedy. A
    # pre-PR-6 anchors-verdict without valued detail rows earns nothing
    # (fail-closed, same doctrine as verify-ground-truth.rb).
    if run_tier == 'S'
      gt18s_av = (JSON.parse(File.read(File.join(opts[:tab], 'anchors-verdict.json'))) rescue nil)
      gt18s_plan = (JSON.parse(File.read(File.join(opts[:tab], 'parity-plan.json'))) rescue nil)
      gt18s_charts = (gt18s_plan.is_a?(Hash) ? Array(gt18s_plan['charts']) : Array(gt18s_plan))
                     .select { |c| c.is_a?(Hash) }
                     .map { |c| (c['chart'] || c['name']).to_s }.reject(&:empty?)
      gt18s_av_ok = gt18s_av.is_a?(Hash) && gt18s_av['pass'] == true &&
                    gt18s_av['checked'].to_i >= 5 && gt18s_av['matched'] == gt18s_av['checked'] &&
                    gt18s_av['tiles_all_nonempty'] == true
      gt18s_valued_in = gt18s_av.is_a?(Hash) ? Array(gt18s_av['detail']) : []
      gt18s_valued_in = gt18s_valued_in.select { |d| d.is_a?(Hash) && d['valued'] == true }
                                       .map { |d| d['matched_in'].to_s.downcase.strip }.reject(&:empty?)
      gt18s_uncovered = gt18s_charts.reject { |n| gt18s_valued_in.include?(n.downcase.strip) }
      if gt18s_av_ok && gt18s_charts.any? && gt18s_uncovered.empty?
        puts "[OK] gate 18: Tier-S GT-trio skip — VALUED-anchors oracle covers 100% of displayed tiles: " \
             "#{gt18s_charts.length} tile(s) each vouched by >=1 valued anchor " \
             "(numeric, provenance view-csv|vds; #{gt18s_av['valued_matched'] || gt18s_valued_in.length} valued match(es), " \
             'anchors-verdict.json). Ground-truth trio not run — the gate evaluated the anchors oracle itself' \
             "#{run_tier_basis.to_s.empty? ? '' : " (tier basis: #{run_tier_basis})"}."
      else
        warn '[FAIL] gate 18: Tier-S GT-trio skip REFUSED — the VALUED-anchors oracle does not cover'
        warn '       every displayed tile (the skip needs 100% coverage; no waiver credit on this path):'
        warn "         - anchors-verdict.json: #{gt18s_av_ok ? 'pass, all matched, tiles non-empty' : 'missing/failing/stale (need pass, >=5 checked, all matched, tiles_all_nonempty — re-run scripts/verify-anchors.rb)'}"
        if gt18s_charts.empty?
          warn '         - parity-plan.json lists no charts — nothing to vouch for; derive the trio instead'
        else
          gt18s_uncovered.first(10).each do |t|
            warn "         - UNCOVERED: #{t.inspect} — no VALUED anchor (numeric, provenance view-csv|vds) matched IN this tile"
          end
        end
        warn '       Either transcribe VALUED anchors for each uncovered tile (re-read the source view'
        warn '       CSV/VDS, not the PNG) and re-run scripts/verify-anchors.rb, or run the full trio:'
        warn "         ruby scripts/derive-ground-truth.rb --workdir #{opts[:tab]}"
        warn "         ruby scripts/run-ground-truth.rb --workdir #{opts[:tab]} --connection-id <id>"
        warn "         ruby scripts/verify-ground-truth.rb --workdir #{opts[:tab]}"
        exit 25
      end
    else
      warn "[FAIL] gate 18: #{File.basename(gt18_twb)} + parity-plan.json present but no ground-truth-plan.json —"
      warn '       the per-tile ground-truth derivation never ran, so nothing proved the numbers against'
      warn '       the warehouse. Run:'
      warn "         ruby scripts/derive-ground-truth.rb --workdir #{opts[:tab]}"
      warn "         ruby scripts/run-ground-truth.rb --workdir #{opts[:tab]} --connection-id <id>"
      warn "         ruby scripts/verify-ground-truth.rb --workdir #{opts[:tab]}"
      exit 25
    end
  else
    puts '[OK] gate 18: no ground-truth-plan.json and no .twb derivation inputs — numeric-oracle coverage N/A (non-Tableau / pre-PR-6 workdir)'
  end
end

# ---------------------------------------------------------------------------
# Gate 19 — aggregation-semantics ledger (exit 26; PR-7). Additive aggregation
# over a PRE-AGGREGATED column compiles clean in every other gate and ships
# wrong-looking-right numbers: SUM over a {FIXED day: COUNTD} pre-aggregate at
# any coarser grain double-counts every entity appearing on more than one day
# (field twin: a 103.3% "% entities with value" KPI — three live runs proved
# nothing flagged it). The post-convert lint (tableau: audit-agg-semantics.rb /
# lib/agg_semantics_lint.rb) writes <workdir>/agg-semantics.json: one entry per
# hit, classes additive-over-preagg / countd-as-sum / preagg-ratio, ALL of
# severity WARN-WITH-REQUIRED-RESOLUTION — the entry blocks until a resolution
# {how: reaggregated|n/a|faithful-to-source, reason} is recorded via the lint
# script's --resolve. The n/a path is FIRST-CLASS (never force fabricated
# metadata); faithful-to-source is the documented-hazard path (the source
# itself mixes grains and the migration reproduces it faithfully).
# Belt-and-braces: a MISSING ledger on a workdir carrying pre-aggregate
# evidence (non-empty lod-audit.json, or a calc-fields.json census with a
# COUNTD formula) also fails — pre-aggregates exist and nothing linted their
# consumption. No ledger AND no evidence → stated OK (back-compat /
# non-Tableau plugins). No escape flag — the recorded resolution is the only
# sanctioned waiver (it lives in the ledger as evidence, not in a CLI flag a
# re-run forgets).
# ---------------------------------------------------------------------------
as_path = File.join(opts[:tab], 'agg-semantics.json')
as_hows = ['reaggregated', 'n/a', 'faithful-to-source']
as_resolved = lambda do |e|
  e['resolution'].is_a?(Hash) && as_hows.include?(e['resolution']['how'].to_s)
end
if File.exist?(as_path)
  as_doc = JSON.parse(File.read(as_path)) rescue nil
  as_entries = as_doc.is_a?(Hash) ? as_doc['entries'] : as_doc
  unless as_entries.is_a?(Array)
    warn "[FAIL] gate 19: #{as_path} is malformed (expected {\"entries\":[...]} or a bare array)."
    warn '       Re-derive the ledger (the aggregation-semantics lint emits it) — do not hand-edit it into shape.'
    exit 26
  end
  as_entries = as_entries.select { |e| e.is_a?(Hash) }
  as_blocking = as_entries.reject { |e| as_resolved.call(e) }
  if as_blocking.any?
    warn "[FAIL] gate 19: aggregation-semantics ledger unresolved (#{as_path}) —"
    as_blocking.first(10).each do |e|
      case e['class'].to_s
      when 'additive-over-preagg'
        warn "         - ADDITIVE-OVER-PREAGG: #{e['consumer'].inspect} applies Sum/Avg over" \
             " #{e['preagg'].inspect} (#{e['context']}) — a pre-aggregated column re-summed at a" \
             ' different grain double-counts (numbers silently WRONG)'
      when 'countd-as-sum'
        warn "         - COUNTD-AS-SUM: #{e['consumer'].inspect} (#{e['context']}) — COUNTD translated to /" \
             " consumed via Sum over #{e['preagg'].inspect}; a distinct count is not additive"
      else
        warn "         - PREAGG-RATIO: #{e['consumer'].inspect} (#{e['context']}) consumes the" \
             " pre-aggregate-named #{e['preagg'].inspect} as a KPI numerator/denominator"
      end
    end
    warn '       These compile clean and ship wrong-looking-right numbers (the 103.3%-KPI class).'
    warn '       REBUILD the consumer at the correct grain, or record why the hit does not apply, or'
    warn '       document the faithfully-reproduced source hazard:'
    warn '         audit-agg-semantics.rb --resolve <i> --how <reaggregated|n/a|faithful-to-source> --reason "..."'
    warn '       The n/a path is first-class — never fabricate metadata to satisfy the lint.'
    exit 26
  end
  as_by_how = Hash.new(0)
  as_entries.each { |e| as_by_how[e['resolution']['how'].to_s] += 1 if e['resolution'].is_a?(Hash) }
  puts "[OK] gate 19: aggregation-semantics ledger resolved — " \
       "#{as_by_how['reaggregated']} reaggregated, #{as_by_how['n/a']} n/a, " \
       "#{as_by_how['faithful-to-source']} faithful-to-source of #{as_entries.length} (agg-semantics.json)"
else
  # Belt-and-braces: no ledger, but pre-aggregate evidence exists — the lint
  # never ran and nothing checked how those columns are consumed.
  as_lod = begin
    _ld = JSON.parse(File.read(File.join(opts[:tab], 'lod-audit.json')))
    Array(_ld.is_a?(Hash) ? _ld['entries'] : _ld).any?
  rescue StandardError
    false
  end
  as_countd = begin
    _cf = JSON.parse(File.read(File.join(opts[:tab], 'calc-fields.json')))
    Array(_cf.is_a?(Hash) ? _cf['calcs'] : _cf).any? do |c|
      c.is_a?(Hash) && c['formula'].to_s =~ /\bCOUNTD\s*\(/i
    end
  rescue StandardError
    false
  end
  if as_lod || as_countd
    warn "[FAIL] gate 19: #{opts[:tab]} carries pre-aggregate evidence (#{as_lod ? 'LOD calcs in lod-audit.json' : 'COUNTD calc(s) in calc-fields.json'})"
    warn '       but no agg-semantics.json ledger exists — the aggregation-semantics lint never ran, so'
    warn '       nothing checked whether those pre-aggregates are consumed additively (the wrong-looking-'
    warn '       right-numbers class). Run the lint (tableau: ruby scripts/audit-agg-semantics.rb'
    warn '       --workdir <W>), resolve any hits, then re-run this gate.'
    exit 26
  end
  puts '[OK] gate 19: no agg-semantics.json and no pre-aggregate evidence — aggregation semantics N/A (back-compat / non-Tableau plugin)'
end

# ---------------------------------------------------------------------------
# Gate 20 — semantic-edit equivalence ledger (exit 27; PR-8). Any structural
# edit to source semantics (dropping a join, collapsing a table, rewriting a
# filter) is FORBIDDEN without a recorded equivalence proof: COUNT(*),
# COUNT(DISTINCT grain) and per-measure SUM checksums measured on BOTH sides
# through the same warehouse seam the other probes use
# (scripts/probe-equivalence.rb → <workdir>/semantic-edits.json). Field case:
# an agent deleted a LEFT JOIN as "provably no-op" on a non-unique flag key
# with zero verification — the join was fanning out rows, so eliding it
# changed every count downstream. A declared entry with no proof block
# (declared, never probed) or a proof with match:false blocks GREEN.
# HONESTY NOTE: nothing mechanical can detect an edit nobody DECLARED — this
# gate enforces that declared edits are proven; the operating-contract rule
# requires the declaration, and the join-plan (gate 16) + ground-truth
# (gate 18) oracles are the net for undeclared ones (ground-truth SQL derives
# from the SOURCE signals independently of the built spec, so a silently
# dropped join shifts the built numbers away from the derived truth). No
# escape flag and no waiver path: equivalence is measured, not negotiated —
# a mismatched edit never ships (revert or redesign; an intentionally-
# different rewrite is a user-initiated scope change, not an equivalence
# claim, and never belongs in this ledger).
# ---------------------------------------------------------------------------
se_path = File.join(opts[:tab], 'semantic-edits.json')
if File.exist?(se_path)
  se_doc = JSON.parse(File.read(se_path)) rescue nil
  se_entries = se_doc.is_a?(Hash) ? se_doc['entries'] : se_doc
  unless se_entries.is_a?(Array)
    warn "[FAIL] gate 20: #{se_path} is malformed (expected {\"entries\":[...]} or a bare array)."
    warn '       Re-record the proofs (scripts/probe-equivalence.rb writes the ledger) — do not hand-edit it into shape.'
    exit 27
  end
  se_entries = se_entries.select { |e| e.is_a?(Hash) }
  # WITHDRAWN entries (probe-equivalence.rb --withdraw): refuted edits that
  # were consequently NOT applied. They no longer block — the refuted proof
  # stays in the ledger as evidence — but they are reported, never silent.
  # HONESTY NOTE: a withdrawn edit whose SQL nonetheless shipped is not
  # detectable mechanically; withdrawal is the operator's attestation, and
  # gates 16/18 remain the numeric net for an edit that rode along anyway.
  se_withdrawn = (se_doc.is_a?(Hash) ? Array(se_doc['withdrawn']) : []).select { |e| e.is_a?(Hash) }
  if se_withdrawn.any?
    puts "[INFO] gate 20: #{se_withdrawn.length} withdrawn edit(s) — refuted and not applied " \
         '(refuted proofs preserved as evidence in semantic-edits.json withdrawn[]):'
    se_withdrawn.first(10).each do |e|
      puts "         - #{e['edit_description'].inspect} (reason: #{e['withdrawn_reason'] || 'NONE RECORDED'}; withdrawn_at: #{e['withdrawn_at'] || '?'})"
    end
    puts '       Withdrawal attests the edit was NOT applied — that attestation is not mechanically'
    puts '       verifiable; gates 16/18 are the numeric net if the SQL shipped anyway.'
  end
  se_blocking = se_entries.reject { |e| e['proof'].is_a?(Hash) && e['proof']['match'] == true }
  if se_blocking.any?
    warn "[FAIL] gate 20: semantic-edit equivalence ledger unproven (#{se_path}) —"
    se_blocking.first(10).each do |e|
      p20 = e['proof']
      if p20.is_a?(Hash)
        b20 = p20['before'].is_a?(Hash) ? p20['before'] : {}
        a20 = p20['after'].is_a?(Hash) ? p20['after'] : {}
        warn "         - MISMATCH: #{e['edit_description'].inspect} (claim: #{e['claim']}) — the sides are NOT equivalent:"
        warn "             TOTAL_ROWS #{b20['total'].inspect} -> #{a20['total'].inspect}; DISTINCT_GRAIN " \
             "#{b20['distinct_grain'].inspect} -> #{a20['distinct_grain'].inspect} (grain: #{Array(e['grain']).join(', ')})"
        Array(p20['mismatches']).each do |mm|
          next unless mm.is_a?(Hash) && mm['metric'].to_s.start_with?('SUM_')
          warn "             #{mm['metric']} #{mm['before'].inspect} -> #{mm['after'].inspect}"
        end
      else
        warn "         - UNPROVEN: #{e['edit_description'].inspect} (claim: #{e['claim']}) — declared but never probed" \
             "#{e['probe_error'] ? " (last probe errored: #{e['probe_error'].to_s[0, 120]})" : ''}"
      end
    end
    warn '       "Provably no-op" is proven by measurement, never asserted. Probe both sides:'
    warn '         ruby scripts/probe-equivalence.rb --workdir <W> --edit "<desc>" --claim "<claim>" --grain <col,col> \\'
    warn '           (--before-sql ... --after-sql ... | --before-element/--after-element ...) [--measures <col,col>] \\'
    warn '           (--connection-id <id> | --fixture DIR)'
    warn '       A MISMATCHED edit never ships: revert it and WITHDRAW the refuted entry'
    warn '         ruby scripts/probe-equivalence.rb --workdir <W> --withdraw "<edit_description>" --reason "<why>"'
    warn '       (moves it to the ledger\'s withdrawn[] with the refuted proof preserved as evidence —'
    warn '       never hand-edit the ledger), or redesign it until the probes agree, then re-probe.'
    warn '       An intentionally-different rewrite is a user-initiated scope change, not an equivalence'
    warn '       claim — it never belongs in this ledger. There is no skip flag and no waiver path for'
    warn '       an edit that SHIPPED; withdrawal only records a refuted edit that was NOT applied.'
    exit 27
  end
  puts "[OK] gate 20: semantic-edit equivalence ledger proven — #{se_entries.length} declared edit(s), every proof match:true (semantic-edits.json)"
else
  puts '[OK] gate 20: no semantic-edits.json — no structural semantic edits (join drop / table collapse / filter rewrite) declared.'
  puts '     (Only DECLARED edits are policeable here; the operating contract forbids undeclared ones, and gates 16/18 catch the numeric drift they cause.)'
end

# ---------------------------------------------------------------------------
# Gate 21 — chart-kind parity (exit 28; PR-10). The Phase 1d dashboard read
# (png-read.json) records the VERIFIED chart kind of every source tile, and
# the builder propagates it over shelf inference. This gate closes the loop
# MECHANICALLY against the LIVE workbook: each verified tile's readback
# element (wb-readback.json, matched by zone-census name normalization) must
# be in the SAME chart family — the blind-grader vocabulary (bar/line/area/
# combo/scatter/pie/kpi/map/table; kept in lockstep with the plugin's
# lib/blind_grade.rb FAMILY_SYNONYMS — shared/ cannot require a plugin lib,
# same doctrine as gate 8b's inline copy). Field failure: an operator
# corrected the kinds in a verified png-read.json, the build ignored them,
# and bars shipped where the source shows lines — with nothing mechanical
# comparing the two ever again. This census is also what the PR-9 blind
# grade's per_tile family readings are cross-checked against.
# Sanctioned waiver: png-read.json kind_waivers [{tile, reason}] — a fidelity
# decision recorded at read time (e.g. a Sigma capability substitution),
# ledger-named like coverage_waivers, NOT budget-counted. Tiles absent from
# png-read (unverified) or with no readback element by name are STATED,
# never failed here — the dashboard-read gate and the tile census (gate 5)
# own those. No png-read.json → stated OK (non-dashboard / non-Tableau
# workdir); draft read / no readback → stated OK (nothing verified to
# enforce / nothing live to compare).
# ---------------------------------------------------------------------------
kp21_path = File.join(opts[:tab], 'png-read.json')
kp21_rb_path = File.join(opts[:tab], 'wb-readback.json')
if File.exist?(kp21_path)
  kp21 = JSON.parse(File.read(kp21_path)) rescue nil
  # Family vocabulary (inline twin of lib/blind_grade.rb FAMILY_SYNONYMS —
  # keep in lockstep, same as gate 8b's copy).
  kp21_fam_map = { 'bar' => 'bar', 'bar-chart' => 'bar', 'column' => 'bar', 'column-chart' => 'bar',
                   'line' => 'line', 'line-chart' => 'line', 'sparkline' => 'line',
                   'area' => 'area', 'area-chart' => 'area',
                   'combo' => 'combo', 'combo-chart' => 'combo', 'dual-axis' => 'combo',
                   'scatter' => 'scatter', 'scatter-chart' => 'scatter', 'bubble' => 'scatter',
                   'pie' => 'pie', 'pie-chart' => 'pie', 'donut' => 'pie', 'donut-chart' => 'pie',
                   'kpi' => 'kpi', 'kpi-chart' => 'kpi', 'single-value' => 'kpi', 'big-number' => 'kpi',
                   'map' => 'map', 'region-map' => 'map', 'point-map' => 'map',
                   'table' => 'table', 'pivot-table' => 'table', 'pivot' => 'table',
                   'crosstab' => 'table', 'text-table' => 'table', 'grid' => 'table' }
  kp21_chartf = %w[bar line area combo scatter pie kpi map table].freeze
  kp21_fam = lambda do |k|
    k2 = k.to_s.strip.downcase
    kp21_fam_map[k2] || (%w[text control image container divider missing].include?(k2) ? k2 : 'other')
  end
  # Zone-census name normalization (inline twin of lib/zone_census.rb norm_name).
  kp21_norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
  if !kp21.is_a?(Hash) || !kp21['tiles'].is_a?(Array)
    warn "[FAIL] gate 21: #{kp21_path} is malformed (expected {\"tiles\":[{title,kind}...]} — the Phase 1d"
    warn '       dashboard-read artifact). Re-run the Phase 1d read (assert-dashboard-read.rb validates it);'
    warn '       do not hand-edit it into shape.'
    exit 28
  elsif kp21['verified'] == false
    puts '[OK] gate 21: png-read.json is an UNVERIFIED draft (verified:false) — no verified kinds to enforce;'
    puts '     kind parity N/A (the Phase 1d dashboard-read gate polices drafts).'
  elsif !File.exist?(kp21_rb_path)
    puts '[OK] gate 21: no wb-readback.json — kind parity N/A (no live readback to census; offline/pre-POST run).'
  else
    kp21_rb = JSON.parse(File.read(kp21_rb_path)) rescue nil
    kp21_els = {}      # normalized element name → [family, ...]
    kp21_el_kinds = {} # normalized element name → [raw kind, ...] (for the message)
    kp21_elements = if kp21_rb.is_a?(Hash)
                      CODE_REP_LOADED ? Sigma::CodeRep.workbook_elements(kp21_rb) :
                                        Array(kp21_rb['elements'])
                    else
                      []
                    end
    kp21_elements.each do |el|
        next unless el.is_a?(Hash) && el['visibleAsSource'] != false # hidden data-page masters
        f = kp21_fam.call(el['kind'])
        next unless kp21_chartf.include?(f) || f == 'other'
        # `name` can be a visibility hash on hidden-title elements (put-layout).
        en = el['name'].is_a?(Hash) ? el['name']['text'] : el['name']
        en = el['title'] || el['id'] if en.to_s.empty?
        k = kp21_norm.call(en)
        next if k.empty?
        (kp21_els[k] ||= []) << f
        (kp21_el_kinds[k] ||= []) << el['kind'].to_s
    end
    kp21_waivers = {} # normalized tile → reason
    Array(kp21['kind_waivers']).each do |w|
      next unless w.is_a?(Hash)
      k = kp21_norm.call(w['tile'])
      kp21_waivers[k] = w['reason'].to_s unless k.empty?
    end
    kp21_verified_keys = []
    kp21_matched = 0
    kp21_mismatch = [] # [title, expected_family, [actual families], [actual kinds]]
    kp21_waived = []   # [title, reason]
    kp21_absent = []   # verified png tiles with no readback element by name
    kp21['tiles'].each do |t|
      next unless t.is_a?(Hash)
      exp_f = kp21_fam.call(t['kind'] || t['chart_kind'])
      next unless kp21_chartf.include?(exp_f) # text/control/image/container zones are not chart tiles
      title = t['title'].to_s
      k = kp21_norm.call(title)
      next if k.empty?
      kp21_verified_keys << k
      fams = kp21_els[k]
      if fams.nil?
        kp21_waivers.key?(k) ? kp21_waived << [title, kp21_waivers[k]] : kp21_absent << title
      elsif fams.include?(exp_f)
        kp21_matched += 1
      elsif kp21_waivers.key?(k)
        kp21_waived << [title, kp21_waivers[k]]
      else
        kp21_mismatch << [title, exp_f, fams.uniq, Array(kp21_el_kinds[k]).uniq]
      end
    end
    kp21_unread = kp21_els.keys - kp21_verified_keys -
                  kp21['tiles'].select { |t| t.is_a?(Hash) }.map { |t| kp21_norm.call(t['title']) }
    # E5.11: the kind-parity result is CENSUS data — stamp the summary beside
    # the tile census in parity-final.json (when present) and land every
    # divergence in the evidence ledger, so the punch list names each tile
    # without re-deriving kinds (this gate stays the single comparator).
    kp21_stamp = lambda do |verdict|
      summary = { 'verdict' => verdict, 'matched' => kp21_matched,
                  'waived' => kp21_waived.length, 'absent' => kp21_absent.length }
      unless kp21_mismatch.empty?
        summary['mismatched'] = kp21_mismatch.map do |title, exp, act, kinds|
          { 'tile' => title, 'expected_family' => exp, 'built_family' => act, 'readback_kinds' => kinds }
        end
      end
      begin
        _pf_path = File.join(opts[:tab], 'parity-final.json')
        if File.exist?(_pf_path)
          _pf21 = JSON.parse(File.read(_pf_path))
          _pf21['kind_parity'] = summary
          File.write(_pf_path, JSON.pretty_generate(_pf21))
        end
      rescue StandardError
        nil # census stamping must never fail the gate
      end
      kp21_mismatch.each do |title, exp, act, kinds|
        ev_append.call('21', 'diverged', 'kind-parity', 'png-read.json', ev_key.call,
                       nil, { 'tile' => title, 'expected_family' => exp,
                              'built_family' => act, 'readback_kinds' => kinds })
      end
      ev_append.call('21', verdict, 'kind-parity', 'png-read.json', ev_key.call, nil,
                     summary.reject { |k, _| k == 'mismatched' })
    end
    if kp21_mismatch.any?
      kp21_stamp.call('fail')
      warn '[FAIL] gate 21: chart-kind parity — the built workbook contradicts the VERIFIED source read'
      warn '       (png-read.json, Phase 1d): the operator SAW these tiles in the source image.'
      kp21_mismatch.first(10).each do |title, exp, act, kinds|
        warn "         - #{title.inspect}: expected family '#{exp}' (png-read verified kind), " \
             "built '#{act.join('/')}' (readback kind: #{kinds.join('/')})"
      end
      warn '       Rebuild with build-charts-from-signals.rb (it propagates verified png-read kinds over'
      warn '       shelf inference — PR-10) or fix the element kind and re-POST + re-readback. If the'
      warn '       difference is a DELIBERATE substitution (a Sigma capability gap), record it AT READ TIME'
      warn '       in png-read.json:  "kind_waivers": [{ "tile": "<title>", "reason": "<why it differs>" }]'
      warn '       (ledger-named like coverage_waivers — a recorded fidelity decision, not a budget waiver).'
      exit 28
    end
    kp21_stamp.call('pass')
    kp21_parts = ["#{kp21_matched} matched"]
    kp21_parts << "#{kp21_waived.length} kind-waived in the ledger" if kp21_waived.any?
    puts "[OK] gate 21: chart-kind parity — #{kp21_parts.join(', ')} of #{kp21_verified_keys.length} " \
         'verified tile(s); readback families agree with png-read.json.'
    kp21_waived.first(10).each { |title, r| puts "     - WAIVED #{title.inspect}: #{r.empty? ? 'NO REASON RECORDED' : r}" }
    if kp21_absent.any?
      puts "     NOTE: #{kp21_absent.length} verified tile(s) have no readback element by name " \
           "(#{kp21_absent.first(6).map(&:inspect).join(', ')}) — kind unverifiable here; the tile census (gate 5) owns drops."
    end
    if kp21_unread.any?
      puts "     NOTE: #{kp21_unread.length} built chart element(s) not in png-read.json — UNVERIFIED at read " \
           "time (#{kp21_unread.first(6).join(', ')}); stated, not failed."
    end
  end
else
  puts '[OK] gate 21: no png-read.json — chart-kind parity N/A (non-dashboard / non-Tableau workdir;'
  puts '     the Phase 1d dashboard-read gate decides when a read is required).'
end

# ---------------------------------------------------------------------------
# Waiver budget cap (exit 19) — checked LAST so genuine gate failures surface
# first. Individually-arguable escapes stack into an unverified workbook (a
# field run passed one workbook purely by combining --skip-parity-gate with
# --allow-missing-tiles); more than WAIVER_BUDGET waivers means GREEN is
# unavailable regardless of what each escape was for. No escape flag exists
# for this cap — reduce the waiver count by fixing the underlying issues, or
# report the migration as YELLOW.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Degradation ledger + verdict (PLAN-v3 PR-14) — derived ONCE here, from the
# artifacts on disk (the census stamped above included), and written to
# <workdir>/degradation-ledger.json on every run that reaches this point, so
# the budget-fail path below and the success path share one derivation and
# verify-complete.rb can re-derive + cross-check offline.
# ---------------------------------------------------------------------------
deg_entries = nil
if DEG_LEDGER_LOADED
  begin
    deg_entries = DegradationLedger.derive(opts[:tab])
    DegradationLedger.write(opts[:tab], deg_entries)
  rescue StandardError => e
    warn "[WARN] degradation-ledger derivation failed (#{e.class}: #{e.message.lines.first.to_s.strip}) — verdict falls back to legacy print."
    deg_entries = nil
  end
end

if budget_flags.length > effective_waiver_budget
  warn "[FAIL] waiver budget exceeded — #{budget_flags.length} quality waiver/escape flag(s) on this run " \
       "(budget #{effective_waiver_budget}#{effective_waiver_budget < WAIVER_BUDGET ? ", Tier-#{run_tier} scaled from #{WAIVER_BUDGET}" : ''})."
  warn '       GREEN unavailable — too many waivers; the highest achievable result is YELLOW.'
  warn '       Each waiver hid a verification:'
  budget_flags.each { |f| warn "         - #{f}: #{WAIVER_HIDES[f] || 'a verification gate did not run'}" }
  warn '       Waivers are for impossibilities, not obstacles. Fix the underlying issues until'
  warn "       <= #{effective_waiver_budget} remain, or report this migration as YELLOW (never GREEN) and name"
  warn '       every waiver in the report. There is no escape flag for this cap.'
  if deg_entries
    v19 = DegradationLedger.verdict(deg_entries, budget_exceeded: true)
    warn "       VERDICT: #{v19} — degradation ledger (#{deg_entries.length} entr#{deg_entries.length == 1 ? 'y' : 'ies'}):"
    DegradationLedger.report_lines(deg_entries).each { |l| warn "       #{l}" }
  end
  exit 19
end

# Completion sentinel — stamp a run-scoped success marker keyed to the workbook
# and clear any PASS-1 pending marker. verify-complete.rb (the offline done-check
# the SKILL points agents at) reports GREEN only when this file exists for the
# workbook and no parity-pending.json remains. This makes "done" a token only the
# gate can mint, closing the "agent narrates success without the gate" hole.
# run_id scopes the marker to THIS run (see the at_exit stale-deletion above);
# the waiver census rides along so a report can quote the marker verbatim.
# The verdict (PR-14): all gates passed and the budget held, but GREEN belongs
# only to an EMPTY degradation ledger — any scope cut caps the run at PARTIAL,
# any other recorded degradation at YELLOW. The string rides in the success
# marker (verify-complete.rb quotes and cross-checks it).
final_verdict = deg_entries ? DegradationLedger.verdict(deg_entries) : nil
# ── W2.3: verdict attestation + the labeled factory verdict ─────────────────
# Countersignature evidence (orchestration.md O3): a verifier-recorded final
# pass (parity-final.json visual_notes prefixed 'VERIFIER:') or a PARSEABLE
# verification-result.json carrying the verifier's final verdict — a JSON hash
# whose 'verdict' is GREEN/YELLOW/RED (the verifier-brief.md deliverable; the
# orchestration.md artifacts row). Bare file EXISTENCE is NOT evidence: a
# `touch`ed, empty, or malformed file fails the parse and the read stays
# fail-closed to builder-self-attested — otherwise `touch
# verification-result.json` would mint the bare GREEN W2.3 forbids. Anything
# else is a builder
# self-attestation — stamped 'verdict_by' with the closed vocabulary from
# shared/lib/offramp.rb VERDICT_BY ('builder-self-attested' | 'verifier';
# literals here because non-offramp-vendored twins run this gate too — the
# vocab pin test asserts the strings match the constants). On a Tier-S
# FACTORY run (migrate-state.json tier 'S' — lane A writes it) a
# self-attested GREEN is REAL but must never print as the bare string
# 'GREEN': the ' (factory, self-attested)' suffix rides the verdict
# everywhere it lands (RESULT line, phase6-success.json, parity-final.json)
# so any report headline carries the attestation (orchestration.md O3/O4
# tier-S carve-out). Tier-M+/tierless strings are unchanged — the
# countersignature MUST stands for them. A verifier that later countersigns
# and re-runs this gate flips verdict_by to 'verifier' and the label off.
verdict_by = begin
  _pf_att = File.exist?(summary_path) ? (JSON.parse(File.read(summary_path)) rescue {}) : {}
  countersigned = _pf_att.is_a?(Hash) && _pf_att['visual_verdict'].to_s == 'pass' &&
                  _pf_att['visual_notes'].to_s.start_with?('VERIFIER:')
  unless countersigned
    _vr_att = (JSON.parse(File.read(File.join(opts[:tab], 'verification-result.json'))) rescue nil)
    countersigned = _vr_att.is_a?(Hash) && %w[GREEN YELLOW RED].include?(_vr_att['verdict'].to_s)
  end
  countersigned ? 'verifier' : 'builder-self-attested'
rescue StandardError
  'builder-self-attested'
end
factory_labeled = run_tier == 'S' && verdict_by == 'builder-self-attested' &&
                  final_verdict == 'GREEN'
final_verdict = 'GREEN (factory, self-attested)' if factory_labeled
begin
  _wd = opts[:tab]
  # chartCount from parity-final.json (gate 1 already required charts_total > 0 to
  # reach here) so verify-complete.rb has a uniform element count across plugins.
  _pf = (JSON.parse(File.read(File.join(_wd, 'parity-final.json'))) rescue {})
  _cc = (_pf['charts_total'] || _pf['charts_pass'] || 0).to_i
  _succ = { 'workbookId' => (opts[:wb] || ''),
            'chartCount' => _cc,
            'gates' => 'all-pass',
            'run_id' => current_run_id,
            'waivers' => waiver_flags,
            'generatedAt' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ') }
  _succ['verdict'] = final_verdict if final_verdict
  _succ['verdict_by'] = verdict_by if final_verdict
  File.write(File.join(_wd, 'phase6-success.json'), JSON.pretty_generate(_succ))
  _pend = File.join(_wd, 'parity-pending.json')
  File.delete(_pend) if File.exist?(_pend)
  # Flip the off-ramp telemetry field now that success is minted (P2), and
  # stamp the derived verdict beside the census so a report that quotes
  # parity-final.json carries it (verify-complete.rb cross-checks the claim).
  if File.exist?(File.join(_wd, 'parity-final.json'))
    begin
      _pf['success_sentinel'] = true
      _pf['verdict'] = final_verdict if final_verdict
      _pf['verdict_by'] = verdict_by if final_verdict
      File.write(File.join(_wd, 'parity-final.json'), JSON.pretty_generate(_pf))
    rescue StandardError
      nil
    end
  end
rescue StandardError
  # never fail the gate on sentinel bookkeeping
end

# E3.1: the terminal all-gates verdict is the ledger's run-summary line — the
# punch-list headline (every FAIL/WAIVE above already has its own entry).
ev_append.call('phase6-gates', final_verdict || 'all-pass', 'gate-summary',
               'parity-final.json', ev_key.call, nil,
               { 'waivers' => waiver_flags.length, 'budget_waivers' => budget_flags.length,
                 'degradations' => (deg_entries ? deg_entries.length : nil) }.compact)

if final_verdict.nil?
  # Legacy checkout without lib/degradation_ledger.rb — stated, never silent.
  puts "[OK] all gates pass — conversion may declare GREEN" \
       "#{waiver_flags.any? ? " (#{budget_flags.length}/#{waiver_flags.length} waiver(s) within budget — name them in the report: #{waiver_flags.join(', ')})" : ''}"
  puts '     (lib/degradation_ledger.rb not vendored — no PR-14 verdict derived; re-vendor to enable.)'
elsif factory_labeled
  puts '[OK] all gates pass — VERDICT: GREEN (factory, self-attested) (degradation ledger empty; Tier-S'
  puts '     factory run with no verifier countersignature — the label is part of the verdict string and'
  puts '     MUST ride every report headline verbatim (orchestration.md O3/O4 carve-out). Spawn the'
  puts '     verifier (scripts/verifier-brief.md) and re-run this gate for a countersigned bare GREEN.)'
elsif final_verdict == 'GREEN'
  puts "[OK] all gates pass — VERDICT: GREEN (degradation ledger empty — no scope cuts, no waivers, no residuals)"
else
  puts "[OK] all gates pass — VERDICT: #{final_verdict}" \
       "#{waiver_flags.any? ? " (#{budget_flags.length}/#{waiver_flags.length} waiver(s) within budget)" : ''}"
  puts "     GREEN requires an EMPTY degradation ledger; this run recorded #{deg_entries.length} degradation(s):"
  DegradationLedger.report_lines(deg_entries).each { |l| puts "     #{l}" }
  if final_verdict.start_with?('PARTIAL')
    puts '     PARTIAL: a scope cut shipped — the delivered workbook is a SUBSET of the source.'
    puts '     Report this migration as PARTIAL (never GREEN) and quote the ledger verbatim.'
  else
    puts '     Report this migration as YELLOW (never GREEN) and name every entry in the report.'
  end
end
exit 0
