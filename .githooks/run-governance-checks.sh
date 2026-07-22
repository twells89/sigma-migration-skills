#!/usr/bin/env bash
# Shared local gate run by the pre-commit and pre-push hooks. Runs the same
# creds-free governance checks CI runs (shared-lib drift + skill conformance),
# so violations are caught locally in ~1s instead of after a push. Bypass with
# `git commit --no-verify` / `git push --no-verify` if you must.
set -uo pipefail

# repo root (works from a normal clone or a linked worktree)
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
cd "$root" || exit 0

# Nothing to check if the governance tools aren't present (older checkout).
[ -f tools/check-shared.rb ] || exit 0

if ! command -v ruby >/dev/null 2>&1; then
  echo "governance hook: ruby not found — skipping local checks (CI still enforces)." >&2
  exit 0
fi

fail=0
ruby tools/check-shared.rb || fail=1
ruby tools/lint-skills.rb   || fail=1
[ -f tools/hygiene-sweep.sh ] && { bash tools/hygiene-sweep.sh || fail=1; }
[ -f tools/lint-esm-imports.rb ] && { ruby tools/lint-esm-imports.rb || fail=1; }
[ -f tools/lint-twb-encoding.rb ] && { ruby tools/lint-twb-encoding.rb || fail=1; }
[ -f tools/check-agent-variants.rb ] && { ruby tools/check-agent-variants.rb || fail=1; }
[ -f tools/check-cognos-bundle.rb ] && { ruby tools/check-cognos-bundle.rb || fail=1; }
if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "governance checks failed — fix above, or bypass with --no-verify (CI will still gate)." >&2
  exit 1
fi
