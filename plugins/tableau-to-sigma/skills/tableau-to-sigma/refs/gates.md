<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. E9.1 single-ownership home: this file is the SOLE owner of orchestrator exit codes and final-gate semantics (relocated verbatim from SKILL.md — E9 diet, 2026-07-27). SKILL.md keeps one-line pointers; per-gate prose lives in refs/script-map.md + refs/phase-6-parity.md. -->

# Gates & exit codes — the one catalog

Read this when an orchestrator run stops with a nonzero exit, before finalize,
and whenever a waiver is on the table. Every code below is a **designed stop
with printed instructions** — a routing exit is the skill working, not failing.

> **An orchestrator STOP is an instruction to YOU (the agent), not a handoff to
> a human — keep going.** A routing exit (exit-4 workbook handoff, "CONVERTER
> STOP") authorizes you to do the next step yourself: author the spec it names
> and **re-enter the gated spine** (exit 4: `--reuse-dm <id> --wb-spec <path>`).
> "The DM is posted" is not a finish line. Do not report done or wait for a
> human at these STOPs; the only finish line is `verify-complete.rb` exit 0.
> *(Relocated verbatim from SKILL.md STEP 1 — E9 diet.)*

## Orchestrator (`migrate-tableau.rb`) exit codes

Exit codes:
`10` = OPEN QUESTIONS (re-run with `--yes`/`--answers`), `11` = ❌-unhandled
gap-scan features (gap-scout or `--force`), `12` = pass 1 done, parity PENDING
(collect mcp-v2 actuals, then `--finalize`), `16` = pass 1 built + POSTed but
`<workdir>/manual-residues.json` carries `unbuilt` window/table-calc residue(s)
a dashboard tile plots — build each from the printed checklist, set
`status:"built"`, then `--finalize` (the final gate refuses GREEN on `unbuilt`
residues, exit 22; waiver `--accept-manual-residues "<calc,...>"`,
budget-counted), `4` = DM posted but the workbook layer needs an agent-authored
spec — re-enter with `--reuse-dm <id> --wb-spec <path>` (never hand-POST),
`3` = a gate failed, `14` = migration GREEN + Phase E proposals pending,
`0` = ALL gates green (only reachable via `--finalize`),
`18` = the Phase-1d dashboard-read WAIT-GATE deadline passed — `png-read.json`
still missing/unverified/stale after `SIGMA_PNG_READ_TIMEOUT_S` (default 480s;
headless/CI callers with nobody to write the read: set it to `0` for the
fail-fast abort) at the DM-POST barrier: do the read (fetch the dashboard
PNG, Read it, write `<workdir>/png-read.json` with `"verified": true` —
schema in `refs/phase-1-discover.md`), then re-run the same command
(discovery is cached, the re-entry is cheap; genuinely no PNG access →
`--skip-dashboard-read "<reason>"`),
`19` = scope stop: a stated `--dashboard` / `mission.json` scope matched
NOTHING in this workbook (E9.6) — fix the scope from the banner's printed
dashboard list and re-run; a scoped mission never silently fans out to the
full workbook, and no Sigma objects were created.
DM-reuse is **reuse-first** (auto-reuses a covering DM, skipping the POST);
`--reuse-dm <id>` pins one, `--skip-reuse-scan` forces build-new. Optional
`--enhance [--enhance-accept <ids|all-low-risk>]` runs Phase E after all gates
are green. **Still manual by design** (pivot-grid parity actuals,
empty-view-CSV recovery, `--master-col` overrides, gap-scout escalations,
DM-reuse shape preflight): `refs/orchestration.md` §Still manual.

Exit `17` routes to `refs/extract-landing.md` (extract landing); exit `2` from
`resolve-project.rb` = STOP and ask the user with the printed candidates
(`refs/phase-1-discover.md` §Phase 1a).

### Exit-4 handoff discipline (relocated from SKILL.md — E9 diet)

> **At the exit-4 handoff, PATCH the auto-built `<WORK>/wb-spec.json` — do NOT
> rewrite it.** Edit ONLY the fields/tiles it names, keeping every other
> element **and every controlId** exactly as built, then re-enter with
> `--reuse-dm <id> --wb-spec <WORK>/wb-spec.json`. A from-scratch rewrite
> drifts controlIds from `control-scope.json` and fails control-lint wholesale
> (the #1 way this handoff spirals). For a master-level calc, prefer
> `--master-col` over hand-editing the tile.

## The final gate (`assert-phase6-ran.rb`) — exit-code table (load-bearing)

> **Same numerals, different processes.** Orchestrator exit codes (above) and
> this final-gate table are SEPARATE namespaces — e.g. orchestrator 18/19 =
> wait-gate deadline / scope stop, while final-gate 18/19 = anchors / waiver
> budget. Route by which process printed the exit, never by the number alone.

Exits 0 only when ALL pass. Full prose per gate: `refs/script-map.md` +
`refs/phase-6-parity.md`.

| Exit | Gate | Fails when / escape |
|---|---|---|
| 1 | parity sentinel | `parity-final.json` missing |
| 2 | parity | FAIL / extract-mode-without-flag / `charts_total==0` unbacked |
| 4 | orphans | uncleaned posted workbooks (`cleanup-orphan-workbooks.rb`) |
| 5 | live columns | any live `type=error` column |
| 6 | layout | no non-empty layout applied (`document.layout` — spec is `document`-wrapped, see `refs/phase-5-workbook.md`) |
| 7 | tile census | unexplained missing zones / `--allow-missing-tiles N` |
| 8 | layout lint | `lib/layout_lint.rb` / `--skip-layout-lint` |
| 9 | control lint | `lib/control_lint.rb`, `control-scope.json` / `--skip-control-lint` |
| 10 | visual render | no `sigma-render.png` or `screenshots/_manifest.json` / `--skip-visual-gate "<reason>"` |
| 13 | visual verdict | unrecorded or self-attested pass — needs sha-bound `blind_grade` (PR-9) or recorded `--no-vision-waiver` / `--skip-visual-comparison "<reason>"` |
| 14 | layout fill | `layout-census.json` dropped tile or `grid_fill_pct < --min-grid-fill` / `--skip-layout-fill "<reason>"` |
| 15 | 8d RCF ledger | unresolved spec-fixable deltas (`--require-fidelity-ledger`, default-on at `--finalize`); `--accept-residuals id,id` — data-class NEVER |
| 18 | 13 anchors | `source-anchors.json` <5 anchors or failing `anchors-verdict.json`; also `--skip-parity-gate` without passing anchors / `--skip-anchors-gate "<reason>"` |
| 19 | waiver budget | >2 quality waivers → YELLOW cap; no escape flag |
| 20 | 14 visual similarity | `visual-similarity.py` floor fail / `--skip-visual-similarity "<reason>"` |
| 21 | 7b control flip | control doesn't filter live (`probe-controls.rb`), or no evidence on an enforced run / `--skip-flip-test "<reason>"` → `--skip-control-flip` (budget-counted) |
| 22 | 15 manual residues | `manual-residues.json` still `unbuilt` / `--accept-manual-residues "<calc,...>"` (budget-counted) |
| 23 | 16 join cardinality | `join-plan.json` unprobed / non-unique Lookup target (`probe-join-keys.rb`, `--resolve <i> --how <preaggregated\|waived> --reason`); entries with status `emitted` (a REAL `"kind": "join"` in the dm-spec — wave-2 shape 2) are terminal, evidence-bound to the spec; no skip flag |
| 24 | 17 LOD ledger | `lod-audit.json` suspect-alias / silently-dropped unresolved (`audit-lod-calcs.rb`); no skip flag |
| 25 | 18 ground truth | displayed tile with no `numeric_parity` match and no `coverage_waivers` entry; `diverge`/`conflict` NEVER waivable; no skip flag |
| 26 | 19 agg semantics | `agg-semantics.json` unresolved additive-over-preagg / countd-as-sum / preagg-ratio (`audit-agg-semantics.rb --how <reaggregated\|n/a\|faithful-to-source>`); no skip flag |
| 27 | 20 semantic edits | `semantic-edits.json` unproven or `match:false` (`probe-equivalence.rb`); NO waiver — revert or redesign |
| 28 | 21 chart-kind parity | live element family ≠ verified `png-read.json` kind; substitutions recorded as `kind_waivers` at read time |
| 29 | 8e layout arrangement | `--require-arrangement` set + `layout-arrangement.json` missing/malformed after a layout build, or violations present; WARN-only without the flag |
| 30 | 4b layout ran | run-state shows the layout phase never entered |
| 31 | 7c controls census | source control never built, undeclared in `control-scope.json` and unnamed in `controls-waivers.json`; no skip flag |

On the all-embedded (`charts_total==0`) ANCHORS-ORACLE path, substitution also
requires per-displayed-tile anchor coverage (`anchor_coverage.covered ==
displayed`, or `coverage_waivers` naming each uncovered tile). Subagent flows
MUST call this gate as their final step.

### Tableau-local structural gates

These run alongside the shared final gate and are included in the
orchestrator's GREEN predicate:

| Gate | Artifact | Failure |
|---|---|---|
| Relationship completeness | `relationship-coverage.json` | Missing/stale coverage, count mismatch, unwired edge, `partial:true`, or dropped relationship condition. No waiver. |
| Visible dashboards | `dashboard-coverage.json` + `dashboard-scope.json` | Any non-empty visible Tableau dashboard lacks a Sigma page unless excluded by stated/CLI scope. No waiver. |
| SQL provenance | `sql-provenance.json` | A DM `source.kind:"sql"` element matches neither source Custom SQL nor a recognized generated helper, and has no reasoned override backed by `proof.match:true`. No waiver. |

All three run before the relevant Sigma POST and are re-derived at completion;
hand-editing their result files fails the stale-artifact check.

## 🚧 GATE convention

> **🚧 GATE convention.** A step marked **🚧 GATE** is backed by a script that
> *fails the run* if the step was skipped — not advisory. Every 🚧 GATE requires
> an **artifact** (a file on disk) and a downstream check that refuses to
> proceed without it. Current gates: **Phase 1d source dashboard-read**
> (`png-read.json` → `assert-dashboard-read.rb`, re-enforced inside
> `build-charts-from-signals.rb`), **Phase 6 source-parity** and **Phase 6f
> visual render** (`assert-phase6-ran.rb`).

## Waiver discipline (relocated from SKILL.md — E9 diet)

> **Waiver discipline — waivers are for impossibilities, not obstacles.** Every
> `--skip-*` / `--allow-*` / `--accept-*` / `--min-pass-rate <1` flag attests a
> verification could NOT run — not a lever to turn a red gate green. The gate
> stamps `waivers` + `waiver_count` into `parity-final.json`; **more than 2
> quality waivers caps the migration at YELLOW** (exit 19; the sanctioned
> builder→verifier `--skip-visual-comparison` is a policy exclusion), and
> **data-class fidelity residuals can never be waived**.
> Reaching for a third waiver means: stop and fix.

## Verdict model (PR-14) — GREEN / YELLOW / PARTIAL (relocated from SKILL.md — E9 diet)

> **Verdict model (PR-14) — GREEN / YELLOW / PARTIAL.** Every gate run derives
> `degradation-ledger.json` from the artifacts (`lib/degradation_ledger.rb` —
> mechanical, never self-reported) and prints ONE verdict with the ledger
> inline. **GREEN requires an EMPTY ledger.** Any non-scope-cut entry (or
> exceeded budget) → **YELLOW**. **Any scope cut caps at PARTIAL.** Stamped into
> `phase6-success.json` + `parity-final.json`; `verify-complete.rb` re-derives
> offline and **fails (exit 6) if your report contradicts it** — quote the
> ledger verbatim, never a verdict it doesn't support. **Wave-2 label (W2.3):**
> a Tier-S factory run with no verifier countersignature stamps
> `verdict_by: "builder-self-attested"` and its GREEN is the labeled string
> **`GREEN (factory, self-attested)`** — never bare; `verify-complete.rb`
> fails a claim that strips (or fabricates) the label. Tier-scaled budget
> (W2.1): Tier-S caps quality waivers at **1** (M/full keep 2).
