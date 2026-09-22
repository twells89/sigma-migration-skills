# Performance — wall-clock budgets, re-entry caches, and the slow-phase playbook

A single-dashboard migration should take **~30–45 minutes end-to-end** (v5.2
target; the round-4 GREEN reference was 57 min before the v5.2 speed wave),
most of it agent review time (visual QA, RCF loop, decisions) — **not** script
wall-clock. If the orchestrator itself is eating hours, something specific is
wedged; this file tells you what to check, per phase, before you touch anything.

## v5.2 speed wave — what no longer costs a round-trip

Round-4 timeline forensics (all three model runs) showed the wall-clock was
dominated by MODEL-SERIAL work between script invocations, not script time
(orchestrator phases totalled ~10s per re-entry). The following round-trips
are now absorbed:

- **Extract landing (exit 17) auto-runs.** When discovery already fetched the
  `.twbx` WITH the extract payload and `--connection` is set, the orchestrator
  runs `land-extracts.py` itself (prefix = workdir/name slug). `--no-auto-land`
  keeps the manual gate; failures fall through to the original exit-17 text.
- **Tableau signin 401s retry in-process** (2 attempts, 3s/6s backoff) — they
  are routinely transient on Tableau Online; round 4 burned a full re-entry on
  one that succeeded seconds later.
- **Hidden calc-filter resolutions SURVIVE plan regeneration.** auto-parity-plan
  carries `translated`/`waived` statuses forward (keyed tile+calc_ref) — the
  round-4 runs burned three identical Phase-6 FATALs because every re-entry
  wiped the waive they had just recorded. Waive ONCE; re-runs keep it.
- **Visual renders are pooled.** Visual-QA page exports, the per-tile
  verify-visual-tiles renders (pool 3), and the two Phase-6f visual stages run
  concurrently — each Sigma export is a 30–90s server-side render that used to
  be paid serially.
- **The exit-4 workbook handoff should now be RARE.** Round 4's 14–18 min
  hand-authored workbook layer was triggered by window-share/rank/pcto shapes
  the mechanical path could not translate — v5.1.x mechanized those. If you
  hit exit 4, the untranslatable fields are named: translate THOSE (usually a
  `--master-col`), don't hand-author the whole spec.

## The cardinal rule

> **NEVER restart the orchestrator "from scratch" to fix slowness.**
> Re-running `migrate-tableau.rb` with the SAME `--workbook`/`--out` **is** the
> fast path: the resume machinery skips every green phase (discovery stamp,
> sha-stamped parse/calc/custom-SQL, dm-match signature cache, `cols-*.json`,
> `migrate-state.json` for `--finalize`). Deleting the workdir, changing
> `--out`, or "starting clean" throws all of that away and re-pays the full
> cold cost — the exact anti-pattern behind multi-hour field runs.

The designed loop is: run → hit a STOP (exit 10/11/12/13/4/17/18/19) → do the
one thing the stop asks → **re-run the same command**. Each re-entry should be
dramatically cheaper than the first run. If a re-entry re-pays a phase listed
as cached below, that's a bug — check the cache-invalidation notes first
(did the `.twb` actually change?), then report it.

## Single-invocation wave (speed review #2) — fewer stops, same gates

Three control-flow changes remove the guaranteed re-invocations without
changing any gate's semantics:

- **Phase-1d is a WAIT-GATE, not an abort.** At the DM-POST barrier the
  orchestrator now **waits** for a verified `png-read.json` (poll every 2s,
  30s heartbeats, bound `SIGMA_PNG_READ_TIMEOUT_S`, default 480s; `0` = fail
  immediately) — do the dashboard-PNG read **while it waits** and the run
  continues in-process. Deadline passed → **exit 18** with a banner naming
  exactly what is missing (absent / `verified: false` / stale). **No
  stale-seed reuse:** a `png-read.json` older than this run's discovery fetch
  is set aside as `png-read.stale.json` and must be re-verified against the
  fresh PNG.
- **ONE consolidated pre-build checkpoint.** Gap-scan review (exit 11),
  decisions (exit 10), and the E9.4 cost **advisory**
  (WARN-only, ratified) batch into a single stop writing ONE artifact —
  `<WORK>/open-questions.json` — with a single re-entry
  (`--answers '<json>' [--force] | --yes`). Targeted answers
  (`"<id>:<slug>"`) win over bulk class-id answers; every tagged entry in
  `open-questions.json` embeds its computed key as `targeted_key` — copy it
  verbatim rather than re-deriving the slug (an unrecognized `--answers` key
  draws a WARN and is ignored, never a silent fallback). Resolved decisions
  are ledgered append-only in `<WORK>/decisions.jsonl` (E3.6 vocab half).
- **Empty agent-mediated actuals ⇒ finalize chains in-process.** When the
  pass-1 tail derives from the artifacts (strict predicate: every exportable
  plan chart machine-collected, no pivot grids, no render-verify/too-large
  markers, no per-tile visual sidecar) that there is NOTHING for the agent to
  collect, **and the agent-side gate obligations are already discharged** — a
  visual verdict is recorded on `parity-final.json` (gate 8b; `--fast` waives
  it) and the staged RCF ledger is resolved (gate 8d) — pass 1 execs
  `--finalize` in the same invocation instead of exit 12. A chain that would
  predictably stop at 8b/8d only burns the gate battery and pre-spends a
  `migrate-tableau:finalize` loop-log attempt. A gate can still stop with its
  usual banner. `SIGMA_NO_CHAIN_FINALIZE=1` restores the unconditional
  exit-12 stop (and disables the tail wait below).
- **W2.6 — the pass-1 tail WAITS for the visual verdict on cold runs.** The
  verdict records ONTO `parity-final.json` (written by the finalize leg), so a
  cold pass 1 could never satisfy the chain predicate — wave 1's chain fired
  only on re-entry workdirs. Now, when the predicate fails ONLY on
  agent-dischargeable obligations (no recorded verdict; staged RCF ledger
  missing/unresolved), the tail prints a banner (first line names
  `SIGMA_VISUAL_VERDICT_TIMEOUT_S`, default 480s, `0` = don't wait) with the
  exact discharge commands — `phase6-parity.rb --finalize` → read the staged
  6f pairs / resolve the RCF ledger → `record-visual-check.rb` — and polls the
  predicate every 5s. Discharged in time ⇒ the chain fires and a COLD run is
  single-invocation end-to-end. Deadline (or a recorded `not-executable`
  verdict — that is an answer, not a pending one) ⇒ the unchanged exit-12
  two-invocation contract, fail-open.
- **W2.5 — `--wait[=SECONDS]` is the default driving pattern.** One tool call
  (tool timeout ≥ 25 min): the run backgrounds itself into
  `<WORK>/migrate-full.log`, the wrapper returns the inner exit code VERBATIM
  within the budget (default 1500s), and **exit 26** = budget exhausted with
  the run STILL ALIVE (pid + log + state named; re-run the same command to
  re-attach — never treat 26 as a failure). Detached-agent cadence contract:
  poll the log only on a `migrate-state.json` phase transition, else every
  ≥90s — never tighter.
- **W2.1/W2.2/W2.4 — tier ratchet + factory flow.** At 0c the run resolves
  `tier`/`tier_basis` into `migrate-state.json` (`lib/tier.rb`, mechanical
  predicate over on-disk artifacts; fail-closed → `full`; `--tier` overrides,
  ledgered). Tier-S: RCF budget 5→1, clean-run checkpoint questions
  auto-answer their safe defaults (ledgered as `unattended-tier-default`;
  required/defaultless questions still stop), and the gate side scales
  budgets — **no gate is ever removed**. Factory default = one pass +
  measured parity + `<WORK>/PUNCHLIST.md` (one re-entry command per
  degradation-ledger line, rendered at every finalize terminal);
  `--certified` restores loop-to-green (RCF 5 + verifier contract).

## `--quiet` — machine stdout for background-log poll turns

Polling a background run's log re-ingests every ~60-line banner on every
read. `--quiet` keeps stdout machine-small; **default output (no flag) is
byte-identical to before**:

- stdout carries ONLY: one JSON event line per phase entry/completion
  (`{"ev":"phase"|"mark",...}`), stop/result/wait events
  (`{"ev":"stop","code":10,...}`, `{"ev":"result","status":"GREEN",...}`,
  `{"ev":"wait"|"waiting",...}` heartbeats), WARN/FATAL/error-shaped lines,
  and a terminal `{"ev":"exit","code":N,"full_log":...}` event.
- the FULL human output (banners, child output, stop instructions) streams to
  `<WORK>/migrate-full.log` — read it once at a stop instead of on every poll.
- `warn`/stderr is untouched (capture `2>&1` as usual).

Poll pattern: `tail -5` the stdout log for the latest `ev` lines; on an
`ev:stop`/`ev:exit`, read `migrate-full.log` (or the named artifact — e.g.
`open-questions.json`) once for the full instructions.

## Local phase metrics (`<WORK>/phase-metrics.jsonl`)

Every `mark()` boundary appends `{phase, wall_s, at}` via
`lib/phase_metrics.rb` (shared). Capture is LOCAL — the file is gitignored
run state, never sent off-box. Absent lib = silent no-op. Summarize with
`PhaseMetrics.summarize(<WORK>)`. This is the calibration source for
`estimate-cost.rb`'s coefficients (ratified: measure before optimizing).

Turn capture (W2.22): records may also carry `turn` (monotone per-invocation
mark ordinal) and `inv` (per-process token, numbers only);
`PhaseMetrics.run_stats(<WORK>)` derives `turn_events` / `invocations` /
`re_entries` / walls / tokens from them. Absence of a capture is `nil`,
never 0 — a rate is refused, not guessed, from pre-capture files.

## Measured calibration + the cold-run exit gate (W2.22/W2.24)

- `estimate-cost.rb --from-metrics <dir1,dir2,…>` re-fits the rate/phase
  coefficients from measured runs' `phase-metrics.jsonl`; every output then
  carries a PROVENANCE header (measured vs priors, n + range, refusals
  named). Standalone (no `--workdir`) it prints per-tier measured bands. A
  refit or published band needs **n ≥ 3 per tier** — below that it is
  refused BY NAME and only observations are stated (a single flattering
  minute is never a band).
- `measure-cold-run.rb run … -- <orchestrator args>` drives one protocol
  cold run: mechanical resume (exit 12 → `--finalize`, 26 → wait-continue),
  operator stops attributed by exit code, metrics read from artifacts, then
  the litter chain (sweep dry-run → `--delete` → cleanup-orphans → probe
  registry MUST read zero-open). `measure-cold-run.rb gate` applies the
  exit gate over TERMINAL runs only (the wall is intake→terminal; a stopped
  run's partial wall is excluded by name, exactly like a fidelity void):
  median wall ≤15 min ∧ ≤22 turns ∧ 1 invocation ∧ ≤1 stop ⇒
  band-adjacent-measured (≤10 min ⇒ in-band); a miss publishes the
  MEASURED band — the projection is never publishable. Fidelity is
  non-negotiable: a run whose parity baseline does not hold has its speed
  number VOIDED.
- Protocol state is never repo state: workdirs and results files stay
  /tmp-side (the harness refuses repo-side paths), run records carry
  numbers + neutral labels + phase names only (orchestrator argv VALUES are
  redacted to flag names), and the live runbook lives outside the repo.
  Sweep + eyeball any diff before a writeup.

## Expected durations (budgets)

Times for a SMALL workbook (≤5 views, 1 dashboard) and a MEDIUM one (~10
views, 1–2 dashboards, ~40 calcs). The orchestrator prints one loud warning
when a phase exceeds **~3× the medium budget** (`PHASE_BUDGET` in
`migrate-tableau.rb`) and repeats the offenders under `PHASE TIMINGS` at exit.
Large workbooks (10+ dashboards): use `--dashboard` scoping — the budgets then
apply per tab.

| Phase (`PHASE TIMINGS` key)                    | Small    | Medium     | Re-entry (cached) |
|------------------------------------------------|----------|------------|-------------------|
| `phase1-lane(bg)` — Tableau discovery fetch     | ~40–90s  | 2–4 min    | **<5s** (stamp)   |
| `join-wait` — foreground wait on the lane       | ≈ lane   | ≈ lane     | ~0s               |
| `phase1-foreground` — parse-twb-layout + converter | ~10–30s | ~30–150s | **<5s** (sha)     |
| `phase1.6-dm-scan` — DM-reuse scan              | ~5–20s   | ~10–45s    | **<1s** (signature) |
| `phase2-columns` — warehouse column discovery   | ~2–5s/table | ~15–90s | **<1s** (`cols-*.json`) |
| `phase1-join` — calc extraction + custom-SQL + gap parse | ~10–40s | ~30–120s | **<5s** (sha) |
| `decisions` — checkpoint assembly               | <5s      | <10s       | same              |
| `folder-resolve`                                | <10s     | <15s       | same              |
| `phase3-dm` — DM validate + POST + readback     | ~20–60s  | ~30–90s    | skipped on `--reuse-dm` |
| `phase4-workbook` — build-charts + validate + POST | ~30–90s | ~60–150s | re-runs (live ids) |
| `phase5-layout` — layout build + PUT            | ~10–30s  | ~15–45s    | re-runs           |
| `phase5b-visual-qa` — page PNG renders          | ~15s/page | ~15s/page | re-runs           |
| `phase5g-init` — RCF ledger init                | <5s      | <10s       | same              |
| `phase6-pass1` — structural + parity collection | ~1–2 min | 1–3 min    | re-runs (live data) |
| `phase6-finalize` (`--finalize` pass)           | ~1–2 min | ~1–3 min   | n/a               |
| `cleanup-orphans` / `assert-run-state` / `assert-phase6-ran` | <30s | <60s | n/a         |
| RCF render (`fidelity-loop.rb render`)          | ~15s/page/pass | ~15s/page/pass | n/a    |

**Rule of thumb:** any single bash invocation of the orchestrator that runs
>10 minutes without printing anything is wrong — every long phase has a 30s
heartbeat (`… discovery lane still running`) or per-task output. Silence means
wedged, not busy: investigate, don't wait.

## What is cached, and what invalidates it

| Artifact (in the workdir) | Reused when | Force a refresh |
|---|---|---|
| `discovery-stamp.json` + discovery artifacts | source revision probe matches (`workbook id` + `updatedAt`); on a FAILED probe, a complete stamped discovery is still reused with a WARN | delete `discovery-stamp.json` |
| `dashboard-layout.json` (parse-twb-layout) | `.twb` sha + `--dashboard/--page` scope unchanged (`phase-cache-stamps.json`) | delete `dashboard-layout.json` or the stamp file |
| `calc-fields.json` (extract-calc-fields) | `.twb` sha unchanged; only NON-EMPTY extractions are ever stamped | `extract-calc-fields.rb --refresh`, or delete the file |
| `custom-sql.json` (extract-custom-sql) | `.twb` sha unchanged; only successful scans stamped | delete `custom-sql.json` |
| `*-gaps-report.json` (scan-workbook-gaps) | cleared automatically when discovery re-fetches; re-scanned in the foreground if missing | delete the report |
| `dm-match.json` (find-or-pick-dm) | workbook-signature hash unchanged AND scan <24h old (the org's DM set is live state) | `find-or-pick-dm.rb --refresh` |
| `cols-<TABLE>.json` (discover-columns) | file exists, non-empty, same connection + table path | delete the file |
| `migrate-state.json` | drives `--finalize` (pass 2) — phases 1–5 are never re-run there | n/a (do not delete mid-run) |
| `~/.tableau-to-sigma/calc-cache.json` | per-formula translation memo, cross-run/cross-workbook | `--no-cache` on extract-calc-fields |
| `visual-qa/render-versions.json` + 5b page PNGs (W2.7) | `latestDocumentVersion` UNCHANGED since the 5b render — 6f stages the pairs from disk (0 fresh renders) and RCF pass 1 starts from the staged 6f render | any spec write bumps the doc version → fresh render, always (raw PNGs only; verdicts are never reused) |

Deliberate: phases that create or mutate **live Sigma objects** (DM POST,
workbook POST, layout PUT, renders, parity collection) are never cached — they
must observe the live org.

## Poll bounds

Every polling loop in `scripts/` has a **hard timeout** (audited): the export
pollers (`sigma-export-png.py` 60×3s, `export-chart-png.rb` 20×3s,
`collect-parity-actuals.rb` / `verify-warehouse.rb` / `probe-*.rb` /
`enhance-*.rb` deadline-bounded), the discovery-lane waits
(`lane_wait_for` 600s, join `TABLEAU_LANE_TIMEOUT` default 600s — a transient
render wedge under the old 1800s default silently burned 30 min; large sites
raise it via the env var — both with 30s heartbeats), the Phase-1d
dashboard-read WAIT-GATE (`SIGMA_PNG_READ_TIMEOUT_S` default 480s, 30s
heartbeats, exit 18 at the deadline), the pass-1-tail visual-verdict wait
(`SIGMA_VISUAL_VERDICT_TIMEOUT_S` default 480s, fail-open to exit 12 — W2.6),
the `--wait` wrapper budget (default 1500s, exit 26 with the run still alive —
W2.5), lane reaps (60s), and all REST retry loops (attempt-capped
with exponential backoff). If you ever observe a script spinning past its
documented bound, that's a bug — capture the command and file an issue.

## Slow-phase playbook

One section per `PHASE TIMINGS` key — the budget warning links here.

### slow-phase1-lane-bg
Cold Tableau fetch is 2–4 min (5-thread pool; per-task breakdown in
`timings.json`). If slower:
- **Token re-mint loop**: repeated `401 … re-minting token` in
  `phase1-discover.log` means the PAT is being invalidated (another session
  signing in with the same PAT kills this one). Use a dedicated PAT.
- **One wedged view export**: `timings.json` shows one `csv:` task consuming
  the whole window — that view is filter-gated or huge; re-run (transient) or
  accept the empty-CSV decision at the checkpoint.
- **Re-entry paying this again**: the stamp only blesses COMPLETE discoveries
  (all essential fetch tasks ok). Check the prior run's log for
  `discovery NOT stamped for reuse`.

### slow-join-wait
This is just the foreground waiting on the lane — diagnose via
`slow-phase1-lane-bg`. Heartbeats print every 30s; hard stop at
`TABLEAU_LANE_TIMEOUT` (default 600s; raise for large sites).

### slow-phase1-foreground
parse-twb-layout + the mechanical converter, both pure-local.
- A very large `.twb` (tens of MB) parses in ~1–2 min; anything beyond that,
  check available RAM / node startup.
- On re-entry this should print `parse-twb-layout REUSED` — if it re-parses,
  the `.twb` sha changed (discovery re-fetched a new revision) or the scope
  flags differ.

### slow-phase1-6-dm-scan
The picker lists DMs then fetches ≤25 specs in parallel (5 threads, 429
backoff).
- **429 storms**: many concurrent migrations against one org — the backoff
  handles it, but the scan stretches; re-runs reuse `dm-match.json`
  (signature cache) so it's paid once.
- Not needed at all? `--skip-reuse-scan`.
- Re-entry NOT printing `dm-match REUSED`: signature changed (converter output
  differs) or the cache is >24h old.

### slow-phase2-6-reuse-augment
Reads back the reuse candidate's live spec, plans which derived columns a
fresh build would have created (#691), and — only when at least one is
CLOSABLE — PUTs one augmented spec via `post-and-readback.rb --update-id`.
- No network beyond one GET + (at most) one PUT+readback; slow here almost
  always means the underlying Sigma API call is slow, not this gate's own
  logic.
- Skipped entirely (near-zero time) whenever `reuse_dm_id` is unset (fresh
  build) or the candidate already carries every field the workbook needs.
- An UNCLOSABLE gap aborts reuse and falls through to the normal fresh-build
  phases below — that time is charged to `phase3-dm`, not this phase.

### slow-phase2-columns
~2–5s per table via the Sigma catalog. Slow = catalog sync lag on the
connection; re-entries reuse `cols-*.json`. A 404 here is not slowness — see
the `/sync` hint in the output.

### slow-phase1-join
Calc extraction + custom-SQL scan + gap parse, after the lane joins.
- Calc extraction is Nokogiri-backed and sha-cached; a slow FIRST run on a
  calc-heavy workbook (100s of calcs) is normal once. `REUSED` thereafter.
- The custom-SQL GraphQL call can be slow on large sites — it's sha-cached
  after one success.

### slow-phase0c-cost
`estimate-cost.rb --workdir` is a pure-local read of the workdir scoping
artifacts plus one JSON write — seconds at most. Slow = a wedged filesystem or
an enormous workdir glob; the estimator runs `allow_fail`, so worst case the
run proceeds without a sign-off (Phase 3 WARNs).

### slow-decisions
Pure-local checkpoint assembly. If this blows its (tiny) budget, the machine
itself is unhealthy — check load/RAM before anything else.

### slow-folder-resolve
One `whoami` + one files listing. Slowness = Sigma API latency; everything
downstream will be slow too. Pass an explicit `--folder <id>` to skip the
resolution entirely.

### slow-phase5g-init
Local ledger init only — see `slow-decisions`.

### slow-assert-run-state
Local ledger audit only — see `slow-decisions`.

### slow-phase3-dm
Validate + POST + readback. A slow POST usually means the warehouse is
compiling heavy Custom SQL elements. If the POST *fails* repeatedly on SQL
compile errors, run the printed identifier preflight instead of retry-looping.
Reusing an existing model (`--reuse-dm`) skips this phase entirely.

### slow-phase4-workbook
build-charts + validate + ref-gate + POST. Dominated by the workbook POST on
wide specs. If you're iterating spec fixes, use the exit-4 FAST PATH
(`--reuse-dm <id> --wb-spec …`) — it skips discovery and the checkpoint
entirely; do not re-run the full pipeline per iteration.

### slow-phase5-layout
Layout build is local; the PUT is one call. Slow/failing PUTs degrade to the
stacked layout with a WARN — never retry-loop this; fix the layout after.

### slow-phase5b-visual-qa
~15s per page render via the export API. Renders are polled with hard
timeouts; a persistently-timing-out page usually has a heavy pivot — render it
solo and check the element.

### slow-phase6-pass1
Pooled actuals collection (1–3 min). The known platform bug (pivot CSV export
500/empty) degrades those tiles to render-verify instead of blocking — if the
whole phase crawls, check for VizQL/warehouse contention (another big
migration or extract refresh running against the same warehouse).

### slow-phase6-finalize
The verifier + census run over already-collected artifacts (local); only a
handful of API calls. Slowness here is API latency, not computation.

### slow-cleanup-orphans
Lists workbooks and deletes spec-iteration orphans — a few API calls. Many
orphans (a long retry session) legitimately stretch it once.

### slow-assert-phase6-ran
Local artifact checks + a few readbacks. Slowness here is API latency; the
gate logic itself is instant.

### slow-assert-reconstruction-integrity
Local checks over controls coverage, persisted layout renames, the verified
dashboard read, and workbook readback. No network calls; unusual slowness means
the local artifacts are pathologically large.

### slow-assert-datasource-filters
One GET of the posted workbook spec + local filter checks (#483 gate). SKIPs
cleanly offline / without a token, so slowness is pure Sigma API latency on a
single spec fetch.

### slow-assert-action-gates
Local checks only (built spec + action-ledger.json + POSTPUBLISH_GUIDE.md, all
already on disk by --finalize time) — no network call at all (Task 6). If this
is slow, something is wrong with the workdir (e.g. a pathologically large spec
JSON), not the API.

### slow-fastpath-route
DM readback only. If slow, the Sigma API is slow — everything else will be too.

### slow-phasee
Opt-in enhancement scan/apply clones the workbook and re-checks parity per
item; budget scales with accepted items. Accept fewer items per pass if it
drags.

### slow-pivot-totals-ship
One GET + one PUT to re-hide pivot grand totals as the final ship mutation
(`put-layout.rb --apply-pivot-totals`), after every gate is green. Slowness is
pure API latency on a single spec round-trip; the mutation itself is instant.
