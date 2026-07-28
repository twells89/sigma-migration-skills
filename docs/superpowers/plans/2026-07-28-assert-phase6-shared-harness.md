# assert-phase6 shared harness (xdv7) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Promote domo's assert-phase6 offline harness to a shared canonical test (`shared/scripts/test-assert-phase6.rb`) fanned to the 6 non-tableau plugins that vendor `assert-phase6-ran.rb`, wired into CI, each copy green in its own plugin context.

**Architecture:** Generalize domo's 30-scenario, exact-exit-code harness (parameterize the `tool` slug from the test's own path; the gate path is already self-locating), register it as a `shared/manifest.json` canonical with 6 targets, `sync-shared` to fan it out, and add the 5 new copies to the explicit `unit-tests` CI allow-list.

**Tech Stack:** Ruby 2.6 (stdlib `json`/`tmpdir`/`fileutils`), `shared/manifest.json` + `tools/sync-shared.rb` + `tools/check-shared.rb`, GitHub Actions (`.github/workflows/corpus-check.yml`).

**Design spec:** `docs/superpowers/specs/2026-07-28-assert-phase6-shared-harness-design.md`.
**Source to generalize:** `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-assert-phase6.rb` (308 lines, 30 scenarios).

## Global Constraints

- **Ruby 2.6-safe** — no endless method defs (`def f = ...`); verify `ruby -c`.
- **No customer/org/user identifiers** anywhere (hygiene-sweep gated).
- **Fanout set = 6 non-tableau plugins:** `domo`, `looker`, `microstrategy`, `powerbi`, `quicksight`, `thoughtspot` — each target at `plugins/<x>-to-sigma/skills/<x>-to-sigma/test/test-assert-phase6.rb`. **Tableau is EXCLUDED** (keeps its own harness).
- **Canonical:** `shared/scripts/test-assert-phase6.rb`. Shared files change via the canonical + `tools/sync-shared.rb`, never by hand-editing a copy.
- **Plugin-version-bump gate (#515):** any commit touching `plugins/<x>/**` (the fan-out) must carry a `Skip-Version-Bump: harness fan-out — non-user-facing offline test infra` trailer.
- **One shared PR**, rebased onto latest `origin/main` (which now includes #520) before opening.

## File Structure

```
shared/scripts/test-assert-phase6.rb            Task 1  NEW canonical (generalized from domo's)
shared/manifest.json                            Task 2  +1 canonical entry, 6 targets
plugins/domo-to-sigma/skills/domo-to-sigma/test/test-assert-phase6.rb         Task 2  overwritten by canonical (was domo's bespoke)
plugins/looker-to-sigma/skills/looker-to-sigma/test/test-assert-phase6.rb     Task 2  NEW (create test/)
plugins/microstrategy-to-sigma/skills/microstrategy-to-sigma/test/test-assert-phase6.rb  Task 2  NEW
plugins/powerbi-to-sigma/skills/powerbi-to-sigma/test/test-assert-phase6.rb   Task 2  NEW
plugins/quicksight-to-sigma/skills/quicksight-to-sigma/test/test-assert-phase6.rb  Task 2  NEW
plugins/thoughtspot-to-sigma/skills/thoughtspot-to-sigma/test/test-assert-phase6.rb  Task 2  NEW
.github/workflows/corpus-check.yml              Task 3  +5 unit-tests allow-list lines
```

---

### Task 1: Generalize domo's harness into the shared canonical

**Files:**
- Create: `shared/scripts/test-assert-phase6.rb` (from `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-assert-phase6.rb`)

**Interfaces:**
- Produces: a plugin-agnostic harness. `GATE = File.expand_path('../scripts/assert-phase6-ran.rb', __dir__)` (unchanged — self-locating). A new `TOOL` constant derived from `__dir__`: extract the `\w+-to-sigma` path segment if present, else default to `'assert-phase6'`. Every place the source hard-codes `tool` / `"domo-to-sigma"` in the fixtures it writes (e.g. `run-state.json`) uses `TOOL`.

- [ ] **Step 1: Copy + generalize.** `cp plugins/domo-to-sigma/skills/domo-to-sigma/test/test-assert-phase6.rb shared/scripts/test-assert-phase6.rb`. Then edit: add near the top
```ruby
TOOL = (__dir__[%r{(\w+-to-sigma)}, 1] || 'assert-phase6')
```
Replace every literal `'domo-to-sigma'` used as a `tool` value in fixture-writing with `TOOL`. Neutralize the domo-specific comment blocks (the `# domo-to-sigma workdirs never carry migrate-state.json` / `# domo-to-sigma run-state.json (tool="domo-to-sigma")` passages) into plugin-neutral wording (e.g. "an adopting converter's workdir"). Do NOT change any scenario, exit code, or fixture shape.
- [ ] **Step 2: Smoke-test the canonical in place.** From repo root: `ruby shared/scripts/test-assert-phase6.rb`. It resolves `GATE` to `shared/scripts/assert-phase6-ran.rb` (the canonical gate, byte-identical to every copy) and `TOOL` falls back to `'assert-phase6'`. Expected: all 30 scenarios pass (same output as domo's harness).
- [ ] **Step 3: Ruby 2.6 check.** `ruby -c shared/scripts/test-assert-phase6.rb` → `Syntax OK`.
- [ ] **Step 4: Commit** (shared-only, no version-bump trailer needed):
```bash
git add shared/scripts/test-assert-phase6.rb
git commit -m "feat(shared): generalized assert-phase6 canonical test harness"
```

---

### Task 2: Register manifest targets + fan out + prove all 6 green

**Files:**
- Modify: `shared/manifest.json` (add the canonical entry with 6 targets)
- Create (via sync): the 6 `plugins/<x>-to-sigma/skills/<x>-to-sigma/test/test-assert-phase6.rb`
- Create: `test/` dirs in the 5 plugins that lack one (looker/microstrategy/powerbi/quicksight/thoughtspot)

**Interfaces:**
- Consumes: `shared/scripts/test-assert-phase6.rb` from Task 1.
- Produces: 6 byte-identical fanned copies; `check-shared` green; each copy runnable from repo root.

- [ ] **Step 1: Add the manifest entry.** In `shared/manifest.json`, add a new entry mirroring the sibling shared-test entries (e.g. `test-verify-anchors.rb`):
```json
{ "canonical": "shared/scripts/test-assert-phase6.rb",
  "targets": [
    "plugins/domo-to-sigma/skills/domo-to-sigma/test/test-assert-phase6.rb",
    "plugins/looker-to-sigma/skills/looker-to-sigma/test/test-assert-phase6.rb",
    "plugins/microstrategy-to-sigma/skills/microstrategy-to-sigma/test/test-assert-phase6.rb",
    "plugins/powerbi-to-sigma/skills/powerbi-to-sigma/test/test-assert-phase6.rb",
    "plugins/quicksight-to-sigma/skills/quicksight-to-sigma/test/test-assert-phase6.rb",
    "plugins/thoughtspot-to-sigma/skills/thoughtspot-to-sigma/test/test-assert-phase6.rb"
  ] }
```
Keep JSON valid.
- [ ] **Step 2: Create the missing test/ dirs.** For each of looker/microstrategy/powerbi/quicksight/thoughtspot: `mkdir -p plugins/<x>-to-sigma/skills/<x>-to-sigma/test`. (domo already has one.)
- [ ] **Step 3: Run to verify check-shared FAILS (missing targets).** `ruby tools/check-shared.rb` → reports the 6 (or the 5 new) targets missing/drifted. This is the expected pre-sync red state.
- [ ] **Step 4: Fan out.** `ruby tools/sync-shared.rb` — copies canonical → all 6 targets (overwriting domo's bespoke copy with the generalized version).
- [ ] **Step 5: Verify check-shared green.** `ruby tools/check-shared.rb` → all copies match (count +6 vs the new-canonical baseline).
- [ ] **Step 6: THE correctness proof — run all 6 copies from repo root:**
```bash
for x in domo looker microstrategy powerbi quicksight thoughtspot; do
  echo "== $x =="; ruby plugins/$x-to-sigma/skills/$x-to-sigma/test/test-assert-phase6.rb || echo "FAILED: $x"
done
```
Expected: all 6 print their scenario results and exit 0. If ANY fails, STOP and investigate — it means that plugin's vendored `assert-phase6-ran.rb` genuinely diverges or the `TOOL` slug affects an exercised gate (spec Risk #1). Do not paper over; report it.
- [ ] **Step 7: Commit** (touches `plugins/**` → version-bump trailer required):
```bash
git add shared/manifest.json plugins/*/skills/*/test/test-assert-phase6.rb
git commit -m "chore(shared): fan assert-phase6 harness to the 6 non-tableau plugins

Skip-Version-Bump: harness fan-out — non-user-facing offline test infra"
```

---

### Task 3: Wire the 5 new copies into CI

**Files:**
- Modify: `.github/workflows/corpus-check.yml` (the `unit-tests` job's `tests=( ... )` allow-list array)

**Interfaces:**
- Consumes: the 5 new fanned copies from Task 2. (domo's path is ALREADY in the allow-list — same path `plugins/domo-to-sigma/skills/domo-to-sigma/test/test-assert-phase6.rb` — so it needs no new entry.)

- [ ] **Step 1: Confirm domo's entry already present.** `grep 'domo-to-sigma/skills/domo-to-sigma/test/test-assert-phase6.rb' .github/workflows/corpus-check.yml` → 1 hit. So only the 5 non-domo copies need adding.
- [ ] **Step 2: Add the 5 lines** into the `tests=( ... )` array (next to the existing assert-phase6 / plugin test entries), matching the array's indentation:
```
            plugins/looker-to-sigma/skills/looker-to-sigma/test/test-assert-phase6.rb
            plugins/microstrategy-to-sigma/skills/microstrategy-to-sigma/test/test-assert-phase6.rb
            plugins/powerbi-to-sigma/skills/powerbi-to-sigma/test/test-assert-phase6.rb
            plugins/quicksight-to-sigma/skills/quicksight-to-sigma/test/test-assert-phase6.rb
            plugins/thoughtspot-to-sigma/skills/thoughtspot-to-sigma/test/test-assert-phase6.rb
```
- [ ] **Step 3: Sanity-check the YAML + that the paths exist.** `ruby -ryaml -e 'YAML.load_file(".github/workflows/corpus-check.yml")'` (parses) and `for f in <the 5 paths>; do test -f "$f" || echo MISSING $f; done` (all present).
- [ ] **Step 4: Commit** (`.github/` only — no version-bump gate):
```bash
git add .github/workflows/corpus-check.yml
git commit -m "ci: run the fanned assert-phase6 harness for the 5 newly-covered plugins"
```

---

### Task 4: Final green-bar + PR

- [ ] **Step 1:** `ruby tools/check-shared.rb` → green (canonical + 6 targets identical).
- [ ] **Step 2:** `ruby tools/lint-skills.rb` → green.
- [ ] **Step 3:** re-run all 6 copies from repo root (Task 2 Step 6 block) → all exit 0.
- [ ] **Step 4:** `bash tools/hygiene-sweep.sh` → clean.
- [ ] **Step 5:** rebase onto latest `origin/main` (`git fetch origin && git rebase origin/main`); re-run Steps 1–3 post-rebase.
- [ ] **Step 6:** push, open ONE **shared** PR against `main`. Body: what/why + bead `beads-sigma-xdv7`; note 5 plugins go 0→covered, tableau excluded, `Skip-Version-Bump` rationale, and that the live-endpoint / delegate-script gates remain out of offline scope. Follow `.github/pull_request_template.md`.

## Self-Review

**Spec coverage:** generalized canonical (T1) ✓ · 6-target manifest + fan (T2) ✓ · create test/ dirs (T2) ✓ · CI allow-list for the 5 new (T3) ✓ · all-6-green correctness proof (T2 S6, T4 S3) ✓ · version-bump trailer (T2 commit) ✓ · tableau excluded (Global + T2 targets list) ✓ · shared PR + rebase (T4) ✓ · live/delegate gates out-of-scope (PR body) ✓. No spec requirement unmapped.

**Placeholder scan:** every step has concrete commands/paths/JSON; the one code insert (TOOL regex) is literal; no "TBD"/"handle edge cases". Clean.

**Type/name consistency:** `shared/scripts/test-assert-phase6.rb`, the 6 `skills/<x>-to-sigma/test/test-assert-phase6.rb` target paths, `TOOL`, and `GATE` are used identically across T1–T4. The 6-plugin slug list (domo/looker/microstrategy/powerbi/quicksight/thoughtspot) is identical in Global Constraints, the manifest entry (T2), the correctness-proof loop (T2/T4), and the CI list (T3, minus domo which is pre-listed).
