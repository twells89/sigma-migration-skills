# domo-assessment (SP1b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flesh out the bare `domo-assessment` skill into an offline-shippable, read-only Domo estate assessment that inventories DomoStats/Governance datasets, scores each artifact against the converter's coverage, and emits a value/cost-ranked Markdown readout.

**Architecture:** Graduate the existing design from `~/domo-sigma-migration` into the plugin. Four Ruby scripts form a pipeline — `probe-governance.rb` (Tier A/B) → `discover-domo.rb` (governance inventory) → `score-coverage.rb` (scoring + tags + rollup) → `render-readout.rb` (JSON → Markdown) — each runnable offline against synthetic fixtures via `--from-fixtures`. The Domo auth/query surface is reused from the sibling converter by `require_relative`; nothing posts to Sigma.

**Tech Stack:** Ruby 2.6 (stdlib only: `json`, `uri`, `optparse`), Python 3 (existing `dup-dashboards.py`), bash (offline driver). No new dependencies.

**Design spec:** `docs/superpowers/specs/2026-07-28-domo-assessment-design.md` (approved).
**Source to port:** `~/domo-sigma-migration/` — `research/domo-assessment.md` + `domo-assessment/{refs,scripts}`. Files/design only; read them, port + adapt. **Do not copy any customer/org/user identifiers.**

## Global Constraints

_Every task's requirements implicitly include this section._

- **Ruby 2.6-safe** — NO endless method defs (`def f = ...`); no `Array#filter_map` only where 2.6 lacks it (use `map{}.compact`). Verify each script with `ruby -c`.
- **No customer/org/user identifiers** in ANY tracked file (scripts, refs, fixtures, SKILL/README, this plan) — the repo's `hygiene-sweep` pre-commit + CI gate blocks the commit otherwise. Fixtures use a fabricated instance (e.g. `acme-analytics.example`, users `user-001`, dashboards `Sales Overview`-style generics).
- **Reuse, don't duplicate:** Domo auth/query comes from the sibling converter via `require_relative '../../domo-to-sigma/scripts/lib/domo_rest.rb'`; the Domo token from `../../domo-to-sigma/scripts/get-domo-token.sh`. Never re-vendor these, never symlink.
- **Read-only / no Sigma:** the assessment never posts to Sigma and needs no Sigma credentials. Do not `require` `sigma_rest.rb` or call `get_token.py`.
- **Outputs** go under `/tmp/domo-assessment-<instance>/`; scripts never write into the repo tree.
- **Scoring formula + tags are verbatim** from spec §5 — do not invent thresholds.
- **One-plugin PR** on `feat/domo-assessment`, rebased onto `main` after #516 (the `sigma_rest.rb` sync + version bump 0.1.1) merges. The base plugin version is therefore `0.1.1`.
- **Plugin-version-bump gate:** any change under `plugins/domo-to-sigma/**` must increase `plugin.json` `version` (Task 11 does the minor bump 0.1.1 → 0.2.0 — new skill = feature).

## File Structure

```
plugins/domo-to-sigma/skills/domo-assessment/
  SKILL.md            Task 9   full phased skill (replaces the 17-line TODO stub)
  PRIVACY.md          Task 10  crosses-API vs local-only table
  README.md           Task 10  offline-run quickstart + fixture pointer
  refs/
    governance-datasets.md   Task 3  DomoStats/Governance dataset table + query patterns
    complexity-scoring.md    Task 5  value/(1+cost), 5 tags, Beast-Mode buckets, signals
    output-shapes.md         Task 6  JSON artifact schemas
    readout-template.md      Task 6  Markdown skeleton render-readout.rb fills
  scripts/
    probe-governance.rb Task 3  Tier A/B probe = the real preflight
    discover-domo.rb    Task 4  governance inventory; --from-fixtures for offline
    score-coverage.rb   Task 5  scoring + tags + rollup; shells dup-dashboards.py
    render-readout.rb   Task 6  JSON artifacts -> readout.md
    dup-dashboards.py   (present, shared/in-sync) — Task 5 wires a caller
    bootstrap.sh/.ps1   Task 8  vendored from shared/ (+ manifest targets); optional-live-only
    doctor.sh/.ps1      Task 8  vendored from shared/ (+ manifest targets); optional-live-only
  test/
    test-probe.rb       Task 3
    test-discover.rb    Task 4
    test-score.rb       Task 5
    test-render.rb      Task 7
  fixtures/
    tier-b/*.json       Task 2  synthetic governance rows (public-only)
    tier-a/*.json       Task 2  + private card-defs / Beast Modes dataset
  run-offline.sh        Task 7  deterministic probe->discover->score->render + assertions
```

**Test convention:** tests live in a `test/` dir as `test-*.rb` (self-contained, creds-free, `ruby test/test-*.rb`) so the repo's creds-free unit-test CI job runs them — this refines the spec §6 "fixtures/ not test/" note: the synthetic data still lives in `fixtures/`, but the *assertions* live in `test/` so CI exercises them (the sibling skills have no such tests; the bead explicitly asks for "fixture-driven offline **tests**"). Each test reads `fixtures/` and asserts on emitted JSON.

---

### Task 1: Skeleton + minimal test runner

**Files:**
- Create: `plugins/domo-to-sigma/skills/domo-assessment/scripts/.keep`, `refs/.keep`, `test/.keep`, `fixtures/.keep`
- Create: `plugins/domo-to-sigma/skills/domo-assessment/test/helper.rb`

**Interfaces:**
- Produces: `Helper.fixtures_dir(tier)` → absolute path to `fixtures/<tier>`; `Helper.tmp_out` → a fresh `/tmp/domo-assessment-test-<pid>` dir; `Helper.assert(cond, msg)` (prints `ok`/raises).

- [ ] **Step 1: Write the failing test** — `test/test-helper.rb`:
```ruby
require_relative 'helper'
Helper.assert(File.directory?(Helper.fixtures_dir('tier-b')), 'tier-b fixtures dir exists')
out = Helper.tmp_out
Helper.assert(File.directory?(out), 'tmp out created')
puts 'test-helper: PASS'
```
- [ ] **Step 2: Run to verify it fails** — `ruby test/test-helper.rb` → fails (`helper.rb` missing / fixtures dir missing).
- [ ] **Step 3: Implement `helper.rb`** (Ruby 2.6-safe):
```ruby
require 'fileutils'
module Helper
  ROOT = File.expand_path('..', __dir__)
  def self.fixtures_dir(tier); File.join(ROOT, 'fixtures', tier); end
  def self.tmp_out
    d = "/tmp/domo-assessment-test-#{Process.pid}"
    FileUtils.mkdir_p(d); d
  end
  def self.assert(cond, msg)
    raise "FAIL: #{msg}" unless cond
    puts "  ok: #{msg}"
  end
end
```
  Also `mkdir -p fixtures/tier-b fixtures/tier-a` (Task 2 fills them; create empty now so the assert can pass — put a `.keep` in each).
- [ ] **Step 4: Run to verify it passes** — `ruby test/test-helper.rb` → `test-helper: PASS`.
- [ ] **Step 5: Commit** — `git add plugins/domo-to-sigma/skills/domo-assessment && git commit -m "feat(domo-assessment): test helper + skeleton dirs"`

---

### Task 2: Synthetic governance fixtures

**Files:**
- Create: `fixtures/tier-b/{datasets,pages,cards,users,pdp,dataflows}.json`, `fixtures/tier-b/activity-log.json`
- Create: `fixtures/tier-a/{card-defs.json,beast-modes.json}` (+ symlink or copy the tier-b files it shares — copy, keep each tier self-contained)

**Interfaces:**
- Produces: JSON files whose row shapes match `refs/governance-datasets.md` (Task 3). Each file is `{ "columns": [...], "rows": [[...], ...] }` mirroring Domo `query/execute` output (a `rows` array of arrays + a `columns` header), so `discover-domo.rb` parses the same shape live and offline.

- [ ] **Step 1: Write the failing test** — `test/test-fixtures.rb`:
```ruby
require 'json'; require_relative 'helper'
%w[datasets pages cards users pdp dataflows activity-log].each do |name|
  f = File.join(Helper.fixtures_dir('tier-b'), "#{name}.json")
  Helper.assert(File.exist?(f), "#{name}.json present")
  d = JSON.parse(File.read(f))
  Helper.assert(d.key?('columns') && d.key?('rows'), "#{name} has columns+rows")
end
# One card must have zero views (→ retire) and one must reference an unhandled Beast Mode (→ needs-gap-scout)
cards = JSON.parse(File.read(File.join(Helper.fixtures_dir('tier-b'),'cards.json')))
Helper.assert(cards['rows'].any?, 'cards non-empty')
puts 'test-fixtures: PASS'
```
- [ ] **Step 2: Run to verify it fails** — `ruby test/test-fixtures.rb` → fails (files missing).
- [ ] **Step 3: Create the fixtures.** Hand-author small (~5–8 row) synthetic tables. Requirements the later scoring tests depend on:
  - `cards.json`: ≥1 card with `views=0` (retire case), ≥1 card whose bound Beast Mode is in the `unhandled` bucket (gap-scout case), ≥1 clean card with high views + only auto Beast Modes (migrate-first case).
  - `activity-log.json`: view events for the non-retire cards; none for the retire card.
  - `pdp.json`: ≥1 policy on one dataset (adds a `manual` structural signal).
  - `dataflows.json`: ≥1 card sourced from a DataFlow (adds `manual`/`unhandled`).
  - **Fabricated identifiers only** — instance `acme-analytics.example`, generic titles/emails.
  - `tier-a/beast-modes.json`: a `Beast Modes` governance table (its presence flips Tier A); `tier-a/card-defs.json`: private card defs.
- [ ] **Step 4: Run to verify it passes** — `ruby test/test-fixtures.rb` → `PASS`.
- [ ] **Step 5: Commit** — `git commit -am "test(domo-assessment): synthetic tier-a/tier-b governance fixtures"`

---

### Task 3: `probe-governance.rb` (port) + `refs/governance-datasets.md`

**Files:**
- Create: `scripts/probe-governance.rb` (port from `~/domo-sigma-migration/domo-assessment/scripts/probe-governance.rb`)
- Create: `refs/governance-datasets.md` (port from `~/domo-sigma-migration/domo-assessment/refs/governance-datasets.md`)
- Test: `test/test-probe.rb`

**Interfaces:**
- Consumes: `require_relative '../../domo-to-sigma/scripts/lib/domo_rest.rb'` (live); `--from-fixtures <dir>` (offline).
- Produces: writes `probe.json` = `{ "tier": "A"|"B", "public_reachable": bool, "audit_scope": bool, "governance_datasets": {"cards": "<id>", ...}, "reasons": [...] }`. Offline mode derives `tier` from fixture presence (`beast-modes.json` OR `card-defs.json` ⇒ A).

- [ ] **Step 1: Write the failing test** — `test/test-probe.rb`:
```ruby
require 'json'; require_relative 'helper'
out = Helper.tmp_out
system("ruby #{Helper::ROOT}/scripts/probe-governance.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}") or abort 'probe run failed'
p = JSON.parse(File.read("#{out}/probe.json"))
Helper.assert(p['tier'] == 'B', 'tier-b fixtures => Tier B')
Helper.assert(p['governance_datasets'].key?('cards'), 'cards dataset matched')
out2 = Helper.tmp_out
system("ruby #{Helper::ROOT}/scripts/probe-governance.rb --from-fixtures #{Helper.fixtures_dir('tier-a')} --out #{out2}")
Helper.assert(JSON.parse(File.read("#{out2}/probe.json"))['tier'] == 'A', 'tier-a fixtures => Tier A')
puts 'test-probe: PASS'
```
- [ ] **Step 2: Run to verify it fails** — `ruby test/test-probe.rb` → fails (script missing).
- [ ] **Step 3: Port + adapt.** Read the research `probe-governance.rb`; adapt: (a) `require_relative` path to the sibling converter's `domo_rest.rb`; (b) add the `--from-fixtures`/`--out` OptionParser branch that decides tier by fixture presence instead of a live dev-token/`Beast Modes` probe; (c) the `WANTED` name-regex table matches the fixture filenames → dataset ids. Port `refs/governance-datasets.md` verbatim minus any identifiers. Ruby 2.6-safe.
- [ ] **Step 4: Run to verify it passes** — `ruby test/test-probe.rb` → `PASS`; `ruby -c scripts/probe-governance.rb`.
- [ ] **Step 5: Commit** — `git commit -am "feat(domo-assessment): probe-governance.rb (Tier A/B) + governance-datasets ref"`

---

### Task 4: `discover-domo.rb`

**Files:**
- Create: `scripts/discover-domo.rb`
- Test: `test/test-discover.rb`

**Interfaces:**
- Consumes: `probe.json` (Task 3) for dataset ids; `--from-fixtures <dir> --out <dir>` (offline) or `--out <dir>` (live, via `domo_rest.rb`).
- Produces: `inventory.json` = `{ "instance": str, "datasets":[...], "pages":[...], "cards":[{id,title,type,page_id,dataset_id,views,beast_modes:[...],pdp:bool,dataflow_sourced:bool}], "users":[...] }` and `usage.json` = `{ "by_card": {card_id => {views:int, distinct_viewers:int}} }` (only when `activity-log` present). **Tolerant column access:** a missing column yields `nil`/`false` + a `_shapeSuspect` entry in `inventory.json["warnings"]`; never raises.

- [ ] **Step 1: Write the failing test** — `test/test-discover.rb`:
```ruby
require 'json'; require_relative 'helper'
out = Helper.tmp_out
system("ruby #{Helper::ROOT}/scripts/probe-governance.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}")
system("ruby #{Helper::ROOT}/scripts/discover-domo.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}") or abort 'discover failed'
inv = JSON.parse(File.read("#{out}/inventory.json"))
Helper.assert(inv['cards'].any? { |c| c['views'] == 0 }, 'a zero-view card survives to inventory')
Helper.assert(inv['cards'].any? { |c| c['pdp'] }, 'a pdp-flagged card present')
usage = JSON.parse(File.read("#{out}/usage.json"))
Helper.assert(usage['by_card'].is_a?(Hash), 'usage by_card present')
puts 'test-discover: PASS'
```
- [ ] **Step 2: Run to verify it fails** → script missing.
- [ ] **Step 3: Implement** `discover-domo.rb`: parse each governance table (`{columns,rows}` → array of hashes keyed by column name), join cards→pages→datasets→pdp→dataflows, fold activity-log into `usage.json`. Wrap every column lookup in a helper `col(row, name)` that returns `nil` + records a warning if absent. Live mode calls `DomoRest.query_dataset(id, sql)`; offline reads the fixture file for that logical name. Ruby 2.6-safe.
- [ ] **Step 4: Run to verify it passes** → `PASS`; `ruby -c`.
- [ ] **Step 5: Commit** — `git commit -am "feat(domo-assessment): discover-domo.rb governance inventory (tolerant parse)"`

---

### Task 5: `score-coverage.rb` + `refs/complexity-scoring.md` + dup-dashboards caller

**Files:**
- Create: `scripts/score-coverage.rb`
- Create: `refs/complexity-scoring.md` (port from research)
- Test: `test/test-score.rb`

**Interfaces:**
- Consumes: `inventory.json`, `usage.json`, `probe.json`; the converter's Beast-Mode buckets from `../../domo-to-sigma/refs/beast-mode-to-sigma.md` (classification a/auto, b/manual, c/unhandled).
- Produces: `complexity.json` = `{ "tier":"A"|"B", "artifacts":[{id,title,n_auto,n_hint,n_manual,n_unhandled,views,distinct_viewers,value,cost,score,tag}], "rollup":{by_tag:{...}, totals:{...}, pct_auto:float} }`; `shortlist.json` (artifacts sorted by score desc, tagged `migrate-first`/`easy-win` first); `migration-plan.json` (clusters keyed on `shared dataset_id`, per-page `recommended_path: convert|gap-scout|retire`). Calls `python3 scripts/dup-dashboards.py` with the card list, folding `duplicate_dashboards` into `migration-plan.json`; a python error is swallowed (never fails the run).

- [ ] **Step 1: Write the failing test** — `test/test-score.rb` (this is the differentiator — assert on **values**, never tautologies):
```ruby
require 'json'; require_relative 'helper'
out = Helper.tmp_out
%w[probe-governance discover-domo].each { |s| system("ruby #{Helper::ROOT}/scripts/#{s}.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}") }
system("ruby #{Helper::ROOT}/scripts/score-coverage.rb --in #{out} --out #{out}") or abort 'score failed'
c = JSON.parse(File.read("#{out}/complexity.json"))
by_id = c['artifacts'].map { |a| [a['id'], a] }.to_h
# retire: the zero-view card
retire = c['artifacts'].select { |a| a['tag'] == 'retire' }
Helper.assert(retire.any? && retire.all? { |a| a['views'] == 0 }, 'retire tag <=> views==0')
# gap-scout: an artifact with an unhandled Beast Mode
Helper.assert(c['artifacts'].any? { |a| a['tag'] == 'needs-gap-scout' && a['n_unhandled'] >= 1 }, 'gap-scout <=> unhandled>=1')
# cost formula sanity on a known artifact
a = c['artifacts'].find { |x| x['n_unhandled'] == 1 && x['n_manual'] == 0 && x['n_hint'] == 0 }
Helper.assert(a && a['cost'] == 10, 'cost = 10*unhandled+3*manual+1*hint')
Helper.assert(c['tier'] == 'B', 'tier propagated')
puts 'test-score: PASS'
```
- [ ] **Step 2: Run to verify it fails** → script missing.
- [ ] **Step 3: Implement** using spec §5 verbatim:
  `cost = 10*n_unhandled + 3*n_manual + 1*n_hint`; `value = (audit ? views*Math.sqrt([distinct_viewers,1].max) : 10*(cards + beast_modes/4.0))`; `score = value/(1.0+cost)`.
  Tags in order: `views==0 → 'retire'`; `n_unhandled>=1 → 'needs-gap-scout'`; `score>=20 && (n_manual+n_unhandled)==0 → 'migrate-first'`; `score>=10 → 'easy-win'`; else `'moderate'`. Structural signals: `pdp → n_manual+=1`; `dataflow_sourced → n_unhandled+=1`. Port `refs/complexity-scoring.md`. Ruby 2.6-safe.
- [ ] **Step 4: Run to verify it passes** → `PASS`; `ruby -c`.
- [ ] **Step 5: Commit** — `git commit -am "feat(domo-assessment): score-coverage.rb (value/(1+cost) + 5 tags) + dup caller"`

---

### Task 7: `run-offline.sh` end-to-end driver

**Files:**
- Create: `run-offline.sh` (repo-root-relative to the skill dir)

**Interfaces:**
- Consumes: `fixtures/<tier>`. Produces: runs the full pipeline into a tmp dir and greps the emitted JSON for required tag/tier values; exits non-zero on any miss. This is the offline green-bar entrypoint a reviewer runs.

- [ ] **Step 1: Write the failing check** — add the assertion block; run `bash run-offline.sh` expecting failure first (driver not yet written; render-readout from Task 6 already exists).
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** — `set -euo pipefail`; for `tier in tier-b tier-a`: run probe→discover→score→render into `/tmp/domo-assessment-offline-$tier`; assert `complexity.json` contains a `retire` and a `needs-gap-scout` tag and the expected `tier`; print `OFFLINE GREEN: <tier>`.
- [ ] **Step 4: Run to verify it passes** — `bash run-offline.sh` → `OFFLINE GREEN: tier-b` / `tier-a`.
- [ ] **Step 5: Commit** — `git commit -am "test(domo-assessment): run-offline.sh end-to-end green-bar driver"`

---

### Task 6: `render-readout.rb` + `refs/readout-template.md` + `refs/output-shapes.md`

**Files:**
- Create: `scripts/render-readout.rb`, `refs/readout-template.md`, `refs/output-shapes.md`
- Test: `test/test-render.rb`

**Interfaces:**
- Consumes: `complexity.json`, `shortlist.json`, `migration-plan.json`, `inventory.json`.
- Produces: `readout.md` — sections: title + instance + tier + "heuristic" disclaimer; estate totals; a shortlist table (title | tag | score | views | gaps); per-tag counts; a duplicate-consolidation note if any. No HTML.

- [ ] **Step 1: Write the failing test** — `test/test-render.rb`:
```ruby
require_relative 'helper'
out = Helper.tmp_out
%w[probe-governance discover-domo].each { |s| system("ruby #{Helper::ROOT}/scripts/#{s}.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}") }
system("ruby #{Helper::ROOT}/scripts/score-coverage.rb --in #{out} --out #{out}")
system("ruby #{Helper::ROOT}/scripts/render-readout.rb --in #{out} --out #{out}") or abort 'render failed'
md = File.read("#{out}/readout.md")
Helper.assert(md.include?('Migration readiness'), 'has title')
Helper.assert(md.downcase.include?('retire') && md.include?('|'), 'shortlist table + retire row')
Helper.assert(md.downcase.include?('heuristic'), 'scoring disclaimer present')
puts 'test-render: PASS'
```
- [ ] **Step 2: Run to verify it fails.**
- [ ] **Step 3: Implement** — read the four JSONs, fill `readout-template.md` placeholders (`{{instance}}`, `{{tier}}`, `{{shortlist_rows}}`, ...). Ruby 2.6-safe. Port `output-shapes.md` documenting every emitted JSON.
- [ ] **Step 4: Run to verify it passes** → `PASS`; `ruby -c`.
- [ ] **Step 5: Commit** — `git commit -am "feat(domo-assessment): render-readout.rb Markdown readout + output-shapes/readout-template refs"`

---

### Task 8: Vendor `doctor`/`bootstrap` + register 4 shared-manifest targets

**Files:**
- Create: `scripts/{bootstrap.sh,bootstrap.ps1,doctor.sh,doctor.ps1}` (via `ruby tools/sync-shared.rb` after registering targets)
- Modify: `shared/manifest.json` (add 4 targets mirroring the sibling `*-assessment` entries)

**Interfaces:** none functional — these are vendored for family-consistency + a future Sigma hand-off; the assessment flow does not invoke them (SKILL documents this).

- [ ] **Step 1: Write the failing check** — `ruby tools/check-shared.rb` currently passes (no domo-assessment targets). Add the 4 targets to `shared/manifest.json` first → `check-shared` now reports the 4 as **missing** (the failing state).
- [ ] **Step 2: Run to verify it fails** — `ruby tools/check-shared.rb` → missing x4.
- [ ] **Step 3: Sync** — `ruby tools/sync-shared.rb` copies canonical → the 4 new targets (preserves exec bits).
- [ ] **Step 4: Run to verify it passes** — `ruby tools/check-shared.rb` → all match.
- [ ] **Step 5: Commit** — `git commit -am "chore(domo-assessment): vendor shared doctor/bootstrap + register manifest targets"`

---

### Task 9: `SKILL.md` (full phased skill)

**Files:** Modify: `SKILL.md` (replace the 17-line stub)

- [ ] **Step 1: Write the failing check** — `ruby tools/lint-skills.rb` on the stub (should pass as assessment-exempt, but the frontmatter/`description` must be real). Add a grep assertion in the test dir or run lint-skills and confirm it classifies `:assessment` and passes.
- [ ] **Step 2: Run** `ruby tools/lint-skills.rb 2>&1 | grep domo-assessment` — note current state.
- [ ] **Step 3: Write SKILL.md** modeled on `plugins/looker-to-sigma/skills/looker-assessment/SKILL.md`: frontmatter (name/description); Privacy posture; When to use / Not for; Modes (Live REST / Offline fixtures); Phase 0 probe (`probe-governance.rb`); Phase 1 discover (`discover-domo.rb`); Phase 2 score (`score-coverage.rb`, "the differentiator"); Phase 3 render (`render-readout.rb`); Scripts table; Refs table; Troubleshooting. State plainly: read-only, never posts to Sigma; `doctor`/`bootstrap` are optional-live-only and not part of the flow.
- [ ] **Step 4: Run to verify it passes** — `ruby tools/lint-skills.rb` green; skill classified `:assessment`.
- [ ] **Step 5: Commit** — `git commit -am "docs(domo-assessment): full phased SKILL.md"`

---

### Task 10: `PRIVACY.md` + `README.md`

**Files:** Create: `PRIVACY.md`, `README.md`

- [ ] **Step 1: Write the failing check** — grep test: `PRIVACY.md` has a "crosses the LLM (Anthropic) API" table + a local-only column; `README.md` has an offline-run one-liner (`bash run-offline.sh`).
- [ ] **Step 2: Run** the grep → fails (files absent).
- [ ] **Step 3: Write** both, modeled on `cognos-assessment/{PRIVACY.md,README.md}`: PRIVACY = what crosses the API (aggregated counts/scores) vs stays local (raw governance rows, `/tmp/...` outputs); auth handling (Domo token, never echoed); README = offline quickstart pointing at `fixtures/`, live quickstart pointing at `get-domo-token.sh`.
- [ ] **Step 4: Run to verify it passes** — grep green.
- [ ] **Step 5: Commit** — `git commit -am "docs(domo-assessment): PRIVACY.md + README.md"`

---

### Task 11: Registration + version bump

**Files:**
- Modify: `plugins/domo-to-sigma/.claude-plugin/plugin.json` (version + description), `.claude-plugin/marketplace.json` (description), `AGENTS.md` (skill-index row)

- [ ] **Step 1: Write the failing check** — grep test: neither plugin.json nor marketplace.json still contains "scaffolded and ships in a later release"; `AGENTS.md` contains a `domo-assessment` row; `plugin.json` version is `0.2.0`.
- [ ] **Step 2: Run** the grep → fails.
- [ ] **Step 3: Edit:**
  - `plugin.json`: `"version": "0.1.1"` → `"0.2.0"`; description — replace "A read-only domo-assessment skill is scaffolded and ships in a later release." with "Bundles a read-only domo-assessment skill (governance-dataset inventory → value/cost-ranked migration shortlist)."
  - `marketplace.json`: same description flip for the `domo-to-sigma` entry.
  - `AGENTS.md`: add under the assessment rows: `| Scope/assess a Domo instance | domo-assessment | plugins/domo-to-sigma/skills/domo-assessment/ |`
- [ ] **Step 4: Run to verify it passes** — grep green; `ruby tools/lint-skills.rb` green.
- [ ] **Step 5: Commit** — `git commit -am "chore(domo-assessment): register skill + bump plugin 0.1.1 -> 0.2.0"`

---

### Task 12: Final offline green-bar + PR

- [ ] **Step 1:** `ruby tools/check-shared.rb` → 538/538 (534 + 4 new) match.
- [ ] **Step 2:** `ruby tools/lint-skills.rb` → green.
- [ ] **Step 3:** `bash tools/hygiene-sweep.sh` → clean (no identifiers).
- [ ] **Step 4:** every test: `for t in plugins/domo-to-sigma/skills/domo-assessment/test/test-*.rb; do ruby "$t" || exit 1; done` → all PASS; `bash plugins/domo-to-sigma/skills/domo-assessment/run-offline.sh` → OFFLINE GREEN.
- [ ] **Step 5:** `ruby -c` on every `.rb`; `bash -n run-offline.sh`.
- [ ] **Step 6:** rebase onto latest `origin/main` (post-#516), push, open one-plugin PR. Body: offline-green evidence; **live governance field-path check explicitly deferred, not validated** (spec Non-goals + bead tkcu).

## Self-Review

**Spec coverage:** inventory (T3/T4) ✓ · scoring+5 tags (T5) ✓ · Tier A/B (T3, propagated T5) ✓ · Markdown readout (T6) ✓ · fixture-driven offline tests (T1/T2 + per-script tests + run-offline T7) ✓ · PRIVACY.md (T10) ✓ · reuse domo_rest.rb via require_relative (Global + T3/T4) ✓ · doctor/bootstrap vendored non-functional (T8) ✓ · registration + description flip + AGENTS row (T11) ✓ · gates green (T12) ✓ · deferred live field-path (T4 tolerant parse + T12 PR note) ✓. No spec section unmapped.

**Placeholder scan:** every code step has real Ruby/bash; ported files name their exact research source + adaptation list; no "TBD"/"handle edge cases". Clean.

**Type consistency:** `probe.json`/`inventory.json`/`usage.json`/`complexity.json`/`shortlist.json`/`migration-plan.json`/`readout.md` names are identical across T3–T7; `--from-fixtures`/`--in`/`--out` flags consistent; `col(row,name)` tolerant helper referenced only where defined (T4). `n_auto/n_hint/n_manual/n_unhandled/value/cost/score/tag` field names match between T5 impl and T5/T7 tests.
