# Cross-platform / Windows portability strategy (ADR)

**Status:** Proposed · **Date:** 2026-07-10 · **Scope:** `sigma-migration-skills`, `sigma-skills`, and the shared runtime.

This is the decision record for how we make the migration skills run on Windows (and stay
cross-platform), and why we are **not** rewriting them in Rust. It is the companion to the
day-to-day setup guide in [`environment.md`](./environment.md) — that doc tells a user how to
get running; this doc tells a contributor where we are headed and why.

---

## TL;DR

- **The languages are not the problem.** Ruby (419 files) and Python (201 files) here are
  ~99% standard library. There is no Gemfile; the only native gem (`nokogiri`) is optional with
  a stdlib REXML fallback. Python's only real deps (`msal`, `requests`, `truststore`, `PyYAML`)
  all ship Windows wheels. Native-compilation risk is ≈ zero.
- **The connective tissue is the problem:** bash-only shell scripts, hardcoded `/tmp`, and
  shell-outs to unix CLIs (`unzip`, `jq`, `curl`, `sips`, `aws`, `bash`), plus interpreter
  naming (`python3` vs the Windows Store `python.exe` stub) and CRLF/BOM.
- **Rust is rejected.** No performance case (this is I/O-bound REST orchestration), worst-case
  ergonomics for LLM-authored/edited scripts, a ~150k-LOC rewrite of gate-hardened code, and it
  does not fix a single one of the actual failures above.
- **Direction: converge on Node/TypeScript incrementally**, because the hard logic (the
  converters) already lives there (`sigma-data-model-mcp` → vendored `converter/*.mjs`), and Node
  is already a required runtime on every migration. Fewer runtimes + no required bash is the goal.
- **Customer compatibility lane: Python-led, no Ruby.** Skills may declare a
  certified `python` runtime profile (Python plus Node/shell where that skill
  needs them). The doctor may select it only after that skill's complete
  migration and hard-gate closure passes no-Ruby CI.
- **Do the cheap thing first.** We are ~70% of the way to "works on Windows" already. Finish the
  shell-neutral hot path (self-scoped as "P1" in PR #299) before any rewrite of anything.

---

## Context

The skills are invoked by an agent that reads `SKILL.md`, runs `scripts/*`, and frequently
**edits those scripts mid-migration** to handle a given source. The runtime today is three
languages glued with bash:

| Layer | Language | Role |
|---|---|---|
| Converters (the hard logic) | **TypeScript** (`sigma-data-model-mcp`) | Parse Tableau/PBI/Qlik/etc. → Sigma spec. Vendored to skills as esbuild-bundled `converter/*.mjs`. Single source of truth. |
| Orchestration / build / verify | **Ruby** (~105k LOC) + **Python** (~43k LOC) | REST calls, spec assembly, layout, gates, parity. |
| Glue / auth / discovery | **bash** (57 `.sh`) | Token fetch, discovery lanes, env. |

Field reports from Windows users (RubyInstaller / no-admin setups) surface as failures in the
**glue**, not the language runtimes.

---

## What actually breaks on Windows

In priority order, with representative hits found in a full-tree inventory (2026-07-10):

1. **Bash as a *required* runtime.** 57 `.sh` scripts + bash-only idioms.
   - `eval "$(get-token.sh)"` — has no cmd/PowerShell equivalent.
   - Process substitution `< <(...)`, `paste -sd` — e.g. `sigma-skills` `verify-workbook.sh`.
   - Ruby/Python that shell to bash: `migrate-thoughtspot.py:104`, `migrate-looker.py:176`
     (`subprocess.run(["bash", "get-token.sh"])`).
   - **Even the "Node-first" cognos orchestrator still bashes for its token:**
     `cognos-to-sigma/.../migrate-cognos.mjs:102` runs `spawnSync('bash', ['-c', 'eval "$(get-token.sh)" ...'])`.
2. **Hardcoded `/tmp`.** ~30 literal Ruby defaults + 18 Python files. Windows has no `/tmp`.
   Examples: `probe-controls.rb:81`, `phase6-parity-pbi.rb:111` (`/tmp/pbiauth/cache.bin`),
   `pbi_exec.py:3`, `extract-pbir.py:37`, `build_workbook.py:339`. The portable pattern
   (`Dir.tmpdir` / `tempfile.gettempdir()`) is already used 160+ times elsewhere — these are the
   stragglers.
3. **Unix CLI shell-outs.**
   - `unzip` — `.twbx`/`.twb` extraction (`tableau-discover.rb:196`, `fetch-all-twbs.rb:223`).
   - `jq` — OpenAPI parsing (`sigma-workbooks/scripts/wb-rep.rb:413-417`, `validate-spec.sh`).
   - `curl` — `wb-rep.rb:409`, `verify_parity.py:26`, PBI auth.
   - `sips` — mac-only image scaling (2 sites); `aws` — QuickSight (works if AWS CLI v2 installed).
4. **Interpreter naming.** `python3` vs `python` vs the Microsoft Store `python.exe`
   App-Execution-Alias stub; POSIX venv layout `/tmp/pbiauth/bin/python` (Windows uses `Scripts\`).
5. **CRLF / BOM.** `git core.autocrlf` mangles shebangs; BOM breaks JSON reads.

None of these is a property of Ruby-vs-Python-vs-Rust. They are properties of *how the glue was
written*.

---

## What already exists (do not rebuild)

A large, coherent cross-platform layer is already in place (branch `feat/windows-env-doctor` →
PRs #224/#251/#284/**#299**/#303/#306/#310):

| Capability | Status | Where |
|---|---|---|
| OS-aware preflight **doctor** (bash + PowerShell), machine-readable `doctor.json`, enforced gate | Done; CI-smoke-tested on `windows-2022` | `shared/scripts/doctor.{sh,ps1}`, `assert-doctor-ran.rb` |
| Store-stub-proof Python resolution | Done in Ruby **and** Node | `py_resolve.rb`, `lib/py_resolve.mjs` |
| Shell-neutral token handoff (no `eval`) — the documented default | Done | `shared/scripts/get_token.py` → `auth.json` (0600); `sigma_rest.rb` reads env → `auth.json` → self-mint |
| Bash-free Sigma + Tableau write path (in-process token mint) | Done | `migrate-tableau.rb` |
| Windows footgun docs (Store stub, RubyInstaller, no-admin `fnm`, CRLF, truststore) | Done | [`environment.md`](./environment.md) |
| Cross-platform converter engine | Done | `sigma-data-model-mcp/src/*.ts` → `converter/*.mjs` via `tools/vendor-converters.sh` |

**Important nuance on "23 PowerShell files":** that is *one* file (`doctor.ps1`) mechanically
fanned out by `tools/sync-shared.rb`, not 23 hand-maintained scripts. The only hand-kept PS↔bash
pair is `doctor.{sh,ps1}`. **Do not** PowerShell-port the other 40 `.sh` files — that would create
the dual-maintenance burden we currently do not have. Retire bash; don't mirror it.

---

## Options considered

### A. "Add Windows helpers to every skill" (PowerShell twins everywhere)
Partly right, partly a trap. The *spine* (doctor, shell-neutral tokens) is correct and mostly
built. But porting every `.sh` to `.ps1` doubles maintenance forever and CI can only lint drift,
not correctness. The right version of A is **eliminate bash, don't port it**.

### B. Rewrite in Rust — **REJECTED**
- **No performance case.** Every script is I/O-bound REST orchestration + JSON/XML/YAML munging.
  There are zero CPU-bound hot paths. Rust's value proposition buys nothing here.
- **Worst-case ergonomics for *this* codebase.** These scripts are authored and edited by the
  agent mid-run (e.g. `build-charts-from-signals.rb` is 5,500 lines the model reasons over and
  patches). Rust is the hardest mainstream language for an LLM to emit correctly in one shot
  (lifetimes, borrow checker, strict types). We would trade a forgiving edit loop for a
  compile-and-fight loop.
- **~150k-LOC rewrite** (105k Ruby + 43k Python) of battle-tested, gate-hardened code —
  re-litigating every fidelity fix and silent-drop workaround. Enormous regression surface, zero
  user-visible benefit.
- **It fixes nothing.** The breakage is bash/`/tmp`/`jq`/`unzip`; a Rust rewrite touches none of
  it. Worse, it *regresses* our best current property — today there is **no** native compilation;
  a Rust stack makes *everything* a per-OS compiled binary to build, sign, and ship.

### C. Converge on Node/TypeScript incrementally — **CHOSEN**
- The hard logic (converters) is **already** TS in the MCP; Node is **already** required on every
  migration (the vendored `.mjs`).
- Node is natively cross-platform: `os.tmpdir()` (no `/tmp`), `fetch` (no `curl`), native JSON
  (no `jq`), one interpreter (no `python3`/Store-stub/venv-layout mess).
- It collapses three runtimes toward one, deleting the largest section of the doctor and an entire
  class of footguns — and it kills the **bilingual twin** maintenance we already carry
  (`sigma_rest.rb` *and* `sigma_rest.py`).
- It follows a trend already in the repo: cognos is already Node-first orchestration, and
  `py_resolve` already has a `.mjs` twin.

> **Accuracy note:** Node has **no** built-in zip-archive reader (`zlib` is gzip/deflate only).
> The honest cross-platform replacement for shelling `unzip` is **Python's stdlib `zipfile`**
> (already a required runtime, resolved via `py_resolve`) or a pure-JS lib (`fflate`/`yauzl`,
> no native compile) — not "Node built-in." See the template's `lib/extract-zip.mjs`.

### D. Add a certified Python-led, no-Ruby runtime — **CHOSEN compatibility lane**
This does not replace the Node/TypeScript convergence direction. It gives
customers who cannot install Ruby an executable path using the Python
orchestrators and the already-vendored Node converters. Support is declared per
skill in `runtime-capabilities.json`; missing metadata remains legacy
Ruby-required. `auto` may fall back to Python only when the profile is
`supported`, all required runtimes are present, and the entrypoint exists.
`preview` requires an explicit opt-in. Missing Ruby never waives migration
gates.

---

## Decision & phased plan

**No big-bang rewrite in any language.** Convergence happens by natural churn, cheapest wins first.

### Phase 0 — Finish "works on Windows" on the current stack (highest ROI; ~70% done)
This is the "P1" already scoped in PR #299. Tracked as beads under the portability epic
(`beads-sigma-*`, see the epic for the file:line backlog):
- Retire bash as a *required* runtime: replace the ~40 non-doctor `.sh` helpers and the
  `subprocess(["bash", …])` / `spawnSync('bash', …)` call sites with the `.py`/`.rb`/`.mjs` twin
  that is already the pattern for `get_token`.
- Sweep the ~48 `/tmp` literals → `Dir.tmpdir` / `tempfile.gettempdir()` / `os.tmpdir()`.
- Replace `jq` (native JSON), `curl` (`net/http` / `urllib` / `fetch`); replace `unzip` with
  Python `zipfile` (or `fflate`); make `sips` mac-only-optional or drop it.
- Apply `PyResolve` uniformly (e.g. some legacy test scripts still hardcode `python3`).
- Fix the POSIX venv assumption (`bin/` → `Scripts\` fallback) in the PowerBI path.

**Exit criterion:** the doctor's REQUIRED runtime list is Ruby + Python + Node — **not bash** —
and a clean-Windows migration of one representative skill passes end-to-end in CI.

### Phase 1 — Set direction: new work goes to Node/TS
Freeze net-new Ruby/Python *orchestrators*, except a Python entrypoint replacing
an existing Ruby path as part of a certified no-Ruby profile. New skills and
other substantial rewrites land in TS,
colocated with the converter engine, using **cognos as the template** (and the
[`node-orchestration-template`](../examples/node-orchestration-template/) in this repo as the
minimal, bash-free reference). This also retires bilingual-twin maintenance over time.

### Phase 2 — Opportunistic migration
Port the highest-churn Ruby orchestrators to TS only when they are being substantially reworked
anyway. Let churn do the heavy lifting; do not force a 150k-LOC event.

---

## Consequences

- **Positive:** Windows unblocked without a rewrite; fewer runtimes; no bilingual twins; the
  doctor shrinks; new work lands where the converters already are.
- **Negative / cost:** a long-lived mixed-language period (Ruby + Python + Node coexist for a
  while); Phase-1 discipline required to avoid adding new Ruby/Python orchestrators; contributors
  must know the cross-platform primitives (documented in the template).
- **Explicitly not chosen:** Rust (see B); PowerShell-porting every `.sh` (see A).

---

## The one-line summary

The wrong path was **three runtimes glued with bash**, not Ruby the language. The fix is **fewer
runtimes and no required bash**, converging on the Node/TS layer we already depend on — finish the
shell-neutral work first (near-done), then let Node absorb orchestration over time.

## References
- [`environment.md`](./environment.md) — user setup + Windows footguns.
- `shared/examples/node-orchestration-template/` — minimal bash-free Node orchestration reference.
- `shared/scripts/doctor.{sh,ps1}`, `assert-doctor-ran.rb` — the preflight gate.
- `shared/scripts/get_token.py`, `shared/lib/sigma_rest.rb` — shell-neutral auth.
- `sigma-data-model-mcp/src/*.ts` + `tools/vendor-converters.sh` — the converter engine.
- PR #299 — shell-neutral token + `doctor.json` gate + bash-free Sigma path (the P0 tier).
