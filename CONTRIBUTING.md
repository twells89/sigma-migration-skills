# Contributing to sigma-migration-skills

This repo grows fast (15+ converters/assessments) and is often worked by several
sessions at once. The rules below keep skills consistent and keep parallel PRs
from colliding. Most are enforced by CI (`.github/workflows/corpus-check.yml`) —
the goal is that "remember to…" is a failing check, not a hope.

## The arc every converter follows

The canonical Assess → Discover → Reuse-check → Convert → Post-DM gate → Build →
Layout → Parity → Security → Enhance arc (C1–C10) is in
[`docs/phase-schema.md`](docs/phase-schema.md), with each skill's local
phase-number mapping. **Never renumber a skill's phases** — scripts, gates, and
memory notes reference the local numbers. When you add a converter, add its
column to that table.

Mandatory gates (CI lints each converter SKILL.md for them — `tools/lint-skills.rb`):

- **C3 Reuse-check** — score existing Sigma DMs before creating one (`find-or-pick-dm.rb`).
- **C5 Post-DM gate** — POST the DM, **read back** real ids, wire the workbook to those.
- **C7 Layout** — apply layout as the **LAST write** (a bare spec PUT wipes it).
- **C8 Parity** — source vs Sigma (vs warehouse) — hard gate, never skip.
- **C9 Security** — detect RLS/CLS always; apply opt-in.

A genuinely-N/A gate goes in `tools/skill-lint-baseline.json` with a reason
(shows as a tracked WARN). Drive that file toward empty.

## Shared infrastructure — edit canonical, never a copy

Shared libs (`lib/sigma_rest.rb`, the lints, `escalate-gap.py`,
`find-or-pick-dm.rb`, `get-token.sh`, …) are **vendored byte-identical** into
every plugin so each plugin ships self-contained for the marketplace. The single
source of truth is [`shared/`](shared/); the fan-out is declared in
[`shared/manifest.json`](shared/manifest.json).

To change a shared file:

```bash
$EDITOR shared/scripts/find-or-pick-dm.rb   # edit the CANONICAL copy
ruby tools/sync-shared.rb                    # propagate to every plugin copy
git add shared/ plugins/                     # commit canonical + the fan-out
```

CI (`tools/check-shared.rb`) fails if any vendored copy drifts from canonical.
Intentional per-tool forks are allowlisted in `shared/manifest.json` (`exception`
+ reason). **Shared-lib changes go in their own PR**, merged before dependent
work — so concurrent feature PRs never both touch a copy.

## Per-agent instruction variants — edit SKILL.md, never a generated copy

Some skills ship non-Claude agent variants under `<skill>/generated/{cursor,codex,
cline,continue}/`. These are **generated from the skill's `SKILL.md`** so every
coding agent reads the SAME instructions. Never hand-edit a file under
`generated/` — edit `SKILL.md` and regenerate:

```bash
ruby tools/gen-agent-variants.rb --all   # regenerate every skill's variants
git add plugins/                         # commit SKILL.md + the regenerated variants
```

CI (`tools/check-agent-variants.rb`) fails if any committed variant drifts from
what `SKILL.md` would generate. Use the `<!-- agents:claude-only -->` /
`<!-- agents:non-claude … agents:end -->` markers in `SKILL.md` for the rare
content that must differ per agent.

## Adding a new converter

```bash
ruby tools/new-skill.rb <tool> "<Display Name>"
ruby tools/check-shared.rb && ruby tools/lint-skills.rb   # both green
```

The scaffolder stamps both skills with the mandatory gates documented, syncs +
registers the shared infra, and adds a `docs/phase-schema.md` stub. Then do the
printed human TODOs: marketplace entry, `AGENTS.md` row, a `corpus/` case, and
fill the SKILL.md prose.

## Local hooks (recommended — catch gate failures before you push)

Enable the repo's git hooks once per clone:

```bash
git config core.hooksPath .githooks
```

`pre-commit` and `pre-push` then run the same creds-free governance checks CI
runs (`tools/check-shared.rb` + `tools/lint-skills.rb`, ~1s) so shared-lib drift
or a missing gate is caught locally. Bypass with `--no-verify` if you must — CI
still enforces.

## Regression: the corpus

Changing a converter/builder? Run `./corpus/run-corpus.sh --check` and reconvert
the affected case (`--reconvert` / `--diff`). Every converter must have at least
one `corpus/<tool>/<case>/` fixture with a golden output. See `corpus/README.md`.

## Working in parallel (multiple sessions / PRs)

Sessions can't talk live, so coordinate through shared state:

1. **Claim work in beads** (`~/.beads-sigma`) at **plugin granularity** before
   touching it: `bd update <id> --status in_progress --owner <you>`. Other
   sessions see it via `bd ready`. One bead ≈ one plugin ≈ one PR.
2. **One PR = one plugin** (or one isolated shared-lib change). Don't mix plugins
   in a PR — it serializes review and invites merge conflicts.
3. **Use a git worktree per session** so parallel edits never stomp each other:
   `git worktree add ../sms-<tool> -b <tool>-work`.
4. **Shared-lib edits are their own PR**, merged first (see above).
5. Rebase on `main` before opening the PR; the CI gates catch drift introduced by
   another session that merged ahead of you.

## Before opening a PR

`ruby tools/check-shared.rb && ruby tools/lint-skills.rb && ./corpus/run-corpus.sh --check`
— all green. The PR template (`.github/PULL_REQUEST_TEMPLATE.md`) lists the rest.
