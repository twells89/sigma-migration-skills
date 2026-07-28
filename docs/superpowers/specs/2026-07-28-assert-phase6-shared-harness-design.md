# Design: Promote the assert-phase6 offline harness to a shared test (xdv7)

**Date:** 2026-07-28
**Status:** Approved design — proceeding to implementation plan (user delegated: "do what you think is best")
**Author:** TJ Wells (with Claude)
**Bead:** `beads-sigma-xdv7` (P3) · external `gh-514`
**Target repo:** `twells89/sigma-migration-skills` (worktree `~/wt-assert-phase6`, branch `feat/assert-phase6-shared-harness`, off `origin/main`)
**Type:** SHARED-LIB change → its own PR (not a plugin PR).

## Context

`assert-phase6-ran.rb` is a shared canonical (`shared/scripts/assert-phase6-ran.rb`) vendored byte-identical to 7 converter plugins. Only two of those have any offline test of it: tableau (a bespoke 1559-line harness) and domo (a clean 308-line, 30-scenario, exact-exit-code harness added in #514). The other five (looker, microstrategy, powerbi, quicksight, thoughtspot) have **zero** offline coverage — a change to the canonical could silently break their gate logic. This promotes domo's harness to a shared canonical test and fans it to the 6 non-tableau plugins, so a single edit-and-sync keeps every non-tableau copy covered.

## Goals

1. A generalized, plugin-agnostic shared canonical test at `shared/scripts/test-assert-phase6.rb`, derived from domo's `test/test-assert-phase6.rb`.
2. Fanned via `shared/manifest.json` to the **6 non-tableau** plugins that vendor `assert-phase6-ran.rb` (domo, looker, microstrategy, powerbi, quicksight, thoughtspot), each at `skills/<x>-to-sigma/test/test-assert-phase6.rb`.
3. Wired into CI so all 6 copies actually run (the `unit-tests` allow-list is explicit, not a glob).
4. Every fanned copy green in its own plugin context (proves the generalization + that each plugin's canonical is genuinely byte-identical in behavior).

## Non-goals (explicitly deferred)

- **Tableau** — keeps its existing bespoke 1559-line harness untouched (it already has coverage; replacing it risks a silent coverage regression — user decision). It is NOT a target of the shared canonical.
- **The live-endpoint gates** (3/4/6/7 — need live Sigma creds + a real workbook) and **delegate-script gates** (10 telemetry, 14 visual-similarity — those scripts aren't vendored in most plugins) stay uncovered by this OFFLINE harness, exactly as in domo today. This harness only contract-tests the file-driven / fail-closed gates.

## Decisions locked

| Decision | Choice |
|---|---|
| Fanout set | 6 non-tableau plugins (user pick 2026-07-28) |
| Canonical filename | `test-assert-phase6.rb` (matches domo's existing name → domo generalizes in place, no rename, its CI allow-list entry unchanged; controller call) |
| Per-plugin target path | `skills/<x>-to-sigma/test/test-assert-phase6.rb` (domo's `test/` convention; create `test/` dirs where absent) |
| Plugin-version-bump gate | `Skip-Version-Bump: <reason>` commit trailer — adding an offline test is non-user-facing (controller call), vs bumping 5 plugin versions |
| Tableau | untouched, excluded from the manifest targets |

## Design

### 1. Generalize the canonical

Copy domo's `test/test-assert-phase6.rb` → `shared/scripts/test-assert-phase6.rb`, making it plugin-agnostic:
- **Gate path — already self-locating:** `GATE = File.expand_path('../scripts/assert-phase6-ran.rb', __dir__)`. Because every target lives at `skills/<x>-to-sigma/test/`, `../scripts/assert-phase6-ran.rb` resolves to that plugin's copy. No change needed beyond confirming it.
- **`tool` parameterization:** the harness writes `run-state.json` with `tool="domo-to-sigma"`. Derive the tool slug from the test's own path (`__dir__` → the `<x>-to-sigma` segment) into a `TOOL` constant, so each fanned copy writes the matching tool. The exercised gates are the tool-agnostic fallback paths (per domo's harness comments), so this should not change exit codes — **but the implementer MUST prove it by running each of the 6 copies green** (this is the one real correctness risk).
- **Neutralize the domo-specific comments** (the `# domo-to-sigma workdirs never carry migrate-state.json` block, etc.) into plugin-neutral wording.

### 2. Fanout via manifest + sync

Add a `shared/manifest.json` entry: `{canonical: "shared/scripts/test-assert-phase6.rb", targets: [<the 6 plugins' skills/<x>-to-sigma/test/test-assert-phase6.rb>]}`. Run `ruby tools/sync-shared.rb` — copies canonical → all 6 (overwriting domo's existing copy with the generalized version). `check-shared` byte-gates them thereafter. Create `test/` dirs in the 5 plugins that lack one.

### 3. CI wiring

Add the 5 new plugins' `skills/<x>-to-sigma/test/test-assert-phase6.rb` paths to the `unit-tests` allow-list array in `.github/workflows/corpus-check.yml` (domo's path is already listed). The job runs `ruby "$t"` per path from repo root; the harness is CWD-independent (`__dir__`/`require`-free of CWD), so this works.

### 4. Version-bump-gate interaction

Adding a test file under 5 plugins' trees trips the #515 per-plugin version-bump guard. Use a `Skip-Version-Bump: harness fan-out — non-user-facing offline test infra` commit trailer on the fan-out commit(s). (Domo's copy also changes — same trailer covers it; the change is test-only, not user-facing.)

### 5. Verification (offline green-bar)

- Each of the 6 `skills/<x>-to-sigma/test/test-assert-phase6.rb` runs green **from repo root** (CI's CWD) — this is the key proof the generalization holds for every plugin.
- `ruby tools/check-shared.rb` green (canonical + 6 targets byte-identical).
- `ruby tools/lint-skills.rb` green.
- `ruby -c` on the canonical + each copy.

### 6. PR shape

One **shared** PR: `shared/scripts/test-assert-phase6.rb` (new canonical) + `shared/manifest.json` + the 6 fanned copies + 5 CI allow-list lines + this spec/plan. The sanctioned multi-plugin shared-change PR type (like #516 and the sibling shared tests). Own worktree off fresh `main`; `Skip-Version-Bump` trailer.

## Risks & open items

- **Generalization correctness (primary):** if a plugin's `assert-phase6-ran.rb` behavior diverges from domo's for an exercised gate, that copy's test fails. Mitigation: run all 6 green before PR. A genuine divergence surfacing here is a **feature** (it means that plugin's vendored copy has drifted or the gate isn't as generic as believed) — investigate, don't paper over.
- **`tool` slug derivation** must handle every plugin dir name; a wrong slug that makes a gate behave differently would fail that copy's run (caught by §5).
- **check-shared already confirms** all 7 `assert-phase6-ran.rb` copies are byte-identical today, so behavior parity across the 6 is the expected case.
- Tableau's bespoke harness remains a separate, unshared artifact — acceptable; a future bead could reconcile it.
