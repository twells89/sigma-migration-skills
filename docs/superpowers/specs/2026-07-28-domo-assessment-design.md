# Design: Implement `domo-assessment` to offline-shippable quality (SP1b)

**Date:** 2026-07-28
**Status:** Approved design — pending spec review, then implementation plan
**Author:** TJ Wells (with Claude)
**Bead:** `beads-sigma-4dmq` (P1) · external `gh-513`
**Target repo:** `twells89/sigma-migration-skills` (worktree `~/wt-domo-assessment`, branch `feat/domo-assessment`, off `origin/main` `c25cee04`)
**Source of design:** `twells89/domo-sigma-migration` (`~/domo-sigma-migration`, `main`) — `research/domo-assessment.md` + `domo-assessment/{refs,scripts}`; files/design only, git history does **not** travel.
**Predecessor:** `2026-07-27-domo-to-sigma-graduation-design.md` (SP1a graduated the converter in #513/#514; this spec supersedes that doc's §6 SP1b *sketch* where they differ — see Decisions locked).

## Context

SP1a graduated the Domo→Sigma **converter** into `sigma-migration-skills` (#513, hardened in #514). The companion **`domo-assessment`** skill was left in-tree as a bare scaffold: a 17-line all-TODO `SKILL.md` and one real file (`scripts/dup-dashboards.py`, a shared lib already kept in sync via `shared/manifest.json`). SP1b fleshes it out to offline-shippable quality by **graduating the assessment design that already exists** in the `domo-sigma-migration` research repo, conforming it to every repo protocol, and proving it green offline against synthetic fixtures — with no live Domo instance required.

The value proposition mirrors the other `*-assessment` skills: a read-only, all-free, ~90-second pre-scoping inventory of a Domo estate that produces a value/cost-ranked migration shortlist, scored against the converter's actual coverage. It complements (does not replace) a deeper paid engagement.

## Goals

1. Replace the scaffold with a full, phased `domo-assessment` skill mirroring the leaner sibling shape (`looker-assessment`).
2. Deterministic inventory over DomoStats / Domo Governance system datasets via the **public** `query/execute` API — no scraping, no private API required for the baseline (Tier B).
3. `value/(1+cost)` scoring + the five disposition tags (`retire` / `needs-gap-scout` / `migrate-first` / `easy-win` / `moderate`), scored against the converter's Beast-Mode / card-type / structural coverage signals.
4. Tier A / Tier B degradation (A adds private card-defs or a `Beast Modes` governance dataset; B is public-only, unmapped signals default to `manual`).
5. Fixture-driven **offline** tests: synthetic governance rows → probe → discover → score → readout, asserting tags / tier / rollup deterministically.
6. `PRIVACY.md` (what crosses the Anthropic API vs stays local) + `README.md` (offline-run quickstart).
7. Registration: flip plugin.json / marketplace.json descriptions ("ships later" → ships now) and add the AGENTS.md skill-index row.
8. Offline-green on every applicable CI gate.

## Non-goals (explicitly deferred)

- **Live governance-dataset field-path confirmation** — the exact column schemas / nesting of the DomoStats & Governance datasets are only knowable against a real instance. v1 parses **tolerantly** against synthetic fixtures; live tightening is bead `beads-sigma-tkcu`'s sibling concern, deferred to first live governance access. **Not claimed as validated.**
- **HTML readout** (`render-report.mjs`-style) — v1 emits JSON artifacts + a generated **Markdown** readout (user scope decision 2026-07-28).
- **Effort/wave-plan *narrative phase*** (cognos-assessment Phase-3-style wave sequencing prose) and **Sigma hand-off phase** (post-to-Sigma) — both deferred. The `migration-plan.json` clustering *artifact* stays in scope (user scope decision); only the extra narrative phase and the hand-off are cut. Because there is no hand-off, the assessment **never posts to Sigma** and needs no Sigma credentials.
- **DataFlow lineage modeling** beyond a per-dataset complexity signal — DataFlows are out of converter v1 scope.

## Decisions locked

| Decision | Choice | Note vs SP1a §6 sketch |
|---|---|---|
| v1 scope | Bead-scope + Markdown readout; graduate research design as-is; Ruby; reuse converter `domo_rest.rb` | user pick 2026-07-28 |
| Structural template | `looker-assessment` (leaner single-flow; its tag vocab incl. `retire` matches the Domo research) | SP1a said "qlik-assessment" — either works; looker is closer |
| `domo_rest.rb` reuse | **`require_relative`** from the sibling converter (`../../domo-to-sigma/scripts/lib/domo_rest.rb`) | **supersedes** SP1a "duplicated" — a relative require kills the fragile symlink *without* duplicating auth logic (no silent drift) and is Windows-safe; both skills always co-ship in the one plugin |
| Domo auth | reuse `get-domo-token.sh` (Domo token) from the sibling converter | **corrects** SP1a "adopts get_token" — that is the *Sigma* minter; the assessment never touches Sigma |
| `doctor` / `bootstrap` | vendor byte-identical from `shared/scripts/` + add 4 `shared/manifest.json` targets, **but non-functional in the flow** (preflight is `probe-governance.rb`) | matches cognos/looker, whose SKILLs never invoke doctor; readies a future hand-off; the shared doctor's Sigma-fail-closed check never fires because the flow never calls it |
| `dup-dashboards.py` | already a synced shared target — keep; wire a real caller | — |
| refs | `governance-datasets.md`, `complexity-scoring.md`, `output-shapes.md`, `readout-template.md` | drop SP1a's `token-model.json` — fold the model into `complexity-scoring.md` (YAGNI) |
| Fixtures location | `fixtures/` (assessment-sibling convention), **not** a `test/` dir | Explore-confirmed |

## Design

### 1. Target layout

```
plugins/domo-to-sigma/skills/domo-assessment/
  SKILL.md                       # full phased skill (replaces the TODO stub)
  PRIVACY.md                     # crosses-API vs local-only table
  README.md                      # offline-run quickstart + fixture pointer
  refs/
    governance-datasets.md       # ported: DomoStats/Governance dataset table + query patterns
    complexity-scoring.md        # ported: value/(1+cost), 5 tags, Beast-Mode buckets, card-type + structural signals
    output-shapes.md             # ported: JSON artifact schemas
    readout-template.md          # NEW: the Markdown skeleton render-readout.rb fills
  scripts/
    probe-governance.rb          # ported: Tier A/B probe = the real preflight
    discover-domo.rb             # NEW: governance inventory via query/execute; --from-fixtures for offline
    score-coverage.rb            # NEW: scoring + tags + rollup; shells dup-dashboards.py
    render-readout.rb            # NEW: JSON artifacts -> readout.md
    dup-dashboards.py            # present (shared, in-sync)
    bootstrap.sh / bootstrap.ps1 # vendored from shared/ (+ manifest targets); optional-live-only
    doctor.sh / doctor.ps1       # vendored from shared/ (+ manifest targets); optional-live-only
  fixtures/
    tier-b/  *.json              # synthetic governance-dataset rows (public-only)
    tier-a/  *.json              # + private card-defs / Beast Modes dataset
    run-offline.sh               # deterministic probe->discover->score->render driver + assertions
```

`domo_rest.rb`, `get-domo-token.sh` are **reused from the sibling converter by relative path** (not re-vendored). The only cross-skill dependency; both skills ship together in `plugins/domo-to-sigma/`, so co-presence is guaranteed.

### 2. Modes & phases (SKILL.md)

Two modes, both feeding one scorer + renderer (mirrors cognos/looker):
- **Live** — public REST against `api.domo.com` (+ optional private API for Tier A).
- **Offline** — point discover at `fixtures/` (or a caller-supplied governance dump); no auth.

Phases: **Phase 0 Connect / probe** (`probe-governance.rb`) → **Phase 1 Discover the estate** (`discover-domo.rb`) → **Phase 2 Score converter coverage** (`score-coverage.rb`, "the differentiator") → **Phase 3 Render readout** (`render-readout.rb`) → Scripts table → Refs table → Troubleshooting. Privacy posture + "When to use / Not for" up top.

### 3. Governance datasets & tolerant extraction

Public `Domo.query_dataset(id, sql)` (→ `POST /v1/datasets/query/execute/{id}`, MySQL dialect, literal `table` alias, backtick identifiers) against the system datasets matched by name regex: `DataSets`, `DataFlows`, `Pages`, `Cards`, `Users`, `Groups`, `PDP Policies`, `Activity Log`, and — if present — `Beast Modes` (its presence is a Tier-A signal on the public API). Column access is **defensive**: a missing/renamed column degrades that signal to `manual`/unknown and never crashes the run (same tolerant posture as the converter's C9 permission reader). Exact column field-paths are the deferred live check.

### 4. Scripts & I/O contracts (Ruby 2.6-safe — no endless method defs)

- **`probe-governance.rb`** → checks public-API reachability, matches the governance datasets against the `WANTED` table, checks `audit` scope (Activity Log present), decides Tier A (dev token reaches `/api/content/v1/cards` **or** a `Beast Modes` governance dataset exists) vs Tier B. Emits `probe.json`.
- **`discover-domo.rb`** `--out <dir>` (live) | `--from-fixtures <dir>` (offline) → `inventory.json` (datasets/pages/cards/users/pdp/dataflows) + `usage.json` (Activity Log; audit mode only).
- **`score-coverage.rb`** `--in <dir> --out <dir>` → classifies Beast-Mode buckets (a/auto, b/manual-restructure, c/unhandled via the converter's `beast-mode-to-sigma.md`), card-type histogram, and structural flags (PDP → +manual; DataFlow-sourced → +manual/unhandled; filters/drill/DDX → +manual/unhandled); emits `complexity.json`, `shortlist.json`, `migration-plan.json` (clusters keyed on `shared_dataset_id`, per-page `recommended_path: convert|gap-scout|retire`). Shells `dup-dashboards.py`, swallowing python errors so it never fails the run.
- **`render-readout.rb`** → fills `readout-template.md` from the JSON artifacts → `readout.md`.

All outputs under `/tmp/domo-assessment-<instance>/`.

### 5. Scoring & tags (ported verbatim from the research repo)

```
cost  = 10*n_unhandled + 3*n_manual + 1*n_hint
value = views * sqrt(distinct_viewers)      # audit / Tier-A
      = 10*(cards + beast_modes/4)           # Tier-B complexity proxy
score = value / (1 + cost)
```
Tags: `views==0 → retire` · `n_unhandled>=1 → needs-gap-scout` · `score>=20 and (manual+unhandled)==0 → migrate-first` · `score>=10 → easy-win` · else `moderate`.

### 6. Offline tests & fixtures — what "offline-shippable" means

`fixtures/{tier-a,tier-b}/*.json` are **synthetic** governance-dataset rows for a fabricated instance — **no real customer/org/user identifiers** anywhere (hard rule; enforced by `hygiene-sweep`). `run-offline.sh` runs probe → discover `--from-fixtures` → score → render and asserts on `complexity.json` / `shortlist.json`: correct tag assignment (incl. `retire` on zero-views, `needs-gap-scout` on an unhandled Beast Mode), Tier-B vs Tier-A degradation, and rollup totals. Assertions pin to **value substrings**, never tautologies (the SP1a review caught a tautological gate — avoid the repeat).

### 7. Registration & gates (offline-green bar)

Registration touchpoints (all in this PR):
- `plugins/domo-to-sigma/.claude-plugin/plugin.json` — description: replace "A read-only domo-assessment skill is scaffolded and ships in a later release." with shipped wording.
- `.claude-plugin/marketplace.json` — same description flip for the `domo-to-sigma` entry.
- `AGENTS.md` — add skill-index row: `| Scope/assess a Domo instance | domo-assessment | plugins/domo-to-sigma/skills/domo-assessment/ |` (the converter row at L46 stays; there is no assessment row yet).
- root `README.md` — verify/add the marketplace-table mention if the family lists assessments there.
- `shared/manifest.json` — add 4 targets (`bootstrap.sh`, `bootstrap.ps1`, `doctor.sh`, `doctor.ps1` → `domo-assessment/scripts/*`), then `ruby tools/sync-shared.rb`.

Skill is **auto-registered** by the plugin's `"skills": "./skills/"` directory glob — no marketplace *skill* array edit.

Offline-green bar (no live Domo, no Sigma):
- `ruby tools/lint-skills.rb` — `-assessment` is classified and **exempt** from converter gates (C3/C5/C7/C8/C9, phase-schema); needs only the assessment shape.
- `ruby tools/check-shared.rb` — green after the 4 new targets sync byte-identical; `dup-dashboards.py` already synced.
- `bash tools/hygiene-sweep.sh` — green; **no customer identifiers in any tracked file, including this spec and the plan** (describe scrub targets by file+kind, never quote literals — hygiene blocked the SP1a docs twice for exactly this).
- `bash fixtures/run-offline.sh` — exits 0 with correct tags/tiers/rollup.
- Ruby 2.6 syntax check on all `.rb`.
- Assessment scoring is **not** corpus-gated anywhere in the repo (no `corpus/` entry needed).

## Its own cycle

Per the bead: this brainstorm → this spec → a TDD implementation plan (`writing-plans`) → subagent execution (Sonnet implementers, Opus final review, per model tiering), in this fresh-`main` worktree, PR-flow (branch → PR, no direct main push), one-plugin PR.

## Governance constraints honored

- **No customer info** in any destination artifact (§6, §7).
- **Worktree isolation + branch/PR flow**, fresh `origin/main` base; `main` is actively moving (other PRs merging) so rebase before PR.
- **One PR = one plugin** (domo-to-sigma only).
- **Validate-don't-overstate**: offline green is claimed; live parity / live field-paths are not.

## Risks & open items

- **Tolerant-parse vs real shapes** — synthetic fixtures encode our *best guess* at governance-dataset columns; the live field-path check (deferred) may require tightening `discover-domo.rb`. Mitigation: defensive column access + `_shapeSuspect` flags, never silent.
- **`require_relative` cross-skill coupling** — if the converter skill's `lib/` path ever moves, the assessment breaks. Mitigation: a single `require_relative` with a clear failure message; both skills co-ship so this is a same-plugin invariant. Fallback if undesirable: promote `domo_rest.rb` to a `shared/lib` target vendored into both (bigger governance change; deferred).
- **Vendored Sigma-oriented `doctor`/`bootstrap` in a Domo tool** — a pre-existing family wart (looker/cognos have it too); kept non-functional and documented as optional-live-only so nobody wires the Sigma-fail-closed check into a Domo run.
- **Scoring thresholds** (`score>=20`/`>=10`, `beast_modes/4`) are ported heuristics, unvalidated against a real estate — fine for pre-scoping; surface as "heuristic" in the readout.
