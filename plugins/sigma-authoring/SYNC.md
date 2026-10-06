# sigma-authoring — vendored from `twells89/sigma-skills`

The skills under `skills/` (`sigma-api`, `sigma-workbooks`, `sigma-data-models`,
`custom-sql-to-data-model`) are **vendored copies** of the canonical
`twells89/sigma-skills` repo. They live here so the migration converters'
hard dependency on `sigma-workbooks` (the canonical Sigma spec reference) ships
in the **same marketplace** — installing any converter, install this too.

- **Source of truth:** https://github.com/twells89/sigma-skills (edit there)
- **Vendored at:** sigma-skills `cursor/browser-oauth-provider-3e17` @ `12051b658dc2d97aba454f6e17ee696cf52fe40d` (2026-10-06)

## Refresh

Re-vendor when the canonical skills change:

```sh
SRC=/path/to/sigma-skills    # a fresh clone of twells89/sigma-skills
for s in sigma-api sigma-workbooks sigma-data-models custom-sql-to-data-model; do
  rm -rf "plugins/sigma-authoring/skills/$s"
  cp -R "$SRC/$s" "plugins/sigma-authoring/skills/$s"
done

# CLOBBER-SAFETY (required): the vendored skill dirs ALSO carry manifest-fanned
# shared files (scripts/doctor.{sh,ps1}, scripts/bootstrap.{sh,ps1},
# refs/environment.md, the token scripts, …) that do NOT exist upstream — the
# rm -rf above deletes them. Re-fan them from shared/manifest.json and verify,
# or the shared-lib drift gate (tools/check-shared.rb in CI) fails. In
# particular, retain this repo's canonical shared code_rep.{rb,py,mjs} copies:
# upstream's per-skill copies are not authoritative in this migration repo.
ruby tools/sync-shared.rb        # restore the fanned shared copies the cp -R dropped
ruby tools/check-shared.rb       # MUST be green before committing

# VARIANT-DRIFT SAFETY (required, and easy to miss): the two repos generate the
# generated/ agent variants with DIFFERENT tools, and upstream's copies can be
# stale relative to its own SKILL.md. A bare cp -R therefore imports variants
# that (a) carry upstream's header instead of this repo's, and (b) can be OLDER
# than the SKILL.md they sit beside — on the 2026-08-07 re-vendor that would
# have silently DELETED ~33 lines of Windows/shell-neutral token guidance from
# custom-sql-to-data-model's four variants. Regenerate from the canonical
# SKILL.md instead of shipping what upstream had:
ruby tools/gen-agent-variants.rb --all   # regenerate all 20 from SKILL.md
ruby tools/check-agent-variants.rb       # MUST be green (20/20, drift 0)

# EXECUTE THE VENDORED RUBY. Nothing else here does. sync-shared.rb and
# check-shared.rb compare SHA1s; gen-agent-variants.rb reads markdown; and
# .github/workflows/{corpus-check,hygiene}.yml never invoke these skills' own
# tests. So a vendored file can be byte-perfect against canonical and still be
# broken against its CALL SITES — which is exactly how a 4-key code_rep adapter
# that silently dropped `settings`/`agents` got this far.
for t in plugins/sigma-authoring/skills/sigma-workbooks/scripts/lib/test_*.rb; do
  ruby "$t" >/dev/null || echo "FAIL $t"
done
ruby -c plugins/sigma-authoring/skills/sigma-workbooks/scripts/wb-rep.rb

# Sanity check before committing: `git status` should show ONLY the files that
# genuinely changed upstream. If generated/ files appear in the diff after the
# regenerate step, something else moved — inspect it, don't wave it through.

# then update the "Vendored at" SHA above and commit
```

## Two things this recipe does NOT cover

**1. `sigma-plugin-authoring` is intentionally not in the loop above.** It exists
in both repos and has been re-vendored before (`81483db1`), but this repository's
copy integrates the migration-owned shared plugin emitter, registration helper,
Python twin, and coverage catalog. Upstream's standalone copy does not carry
those integrations. Reconcile it deliberately instead of replacing the tree.

**2. `cp -R` is only safe when upstream is a strict superset.** It is not always.
Before re-vendoring, check whether any vendored file has been edited DOWNSTREAM —
`git log --oneline -- plugins/sigma-authoring/skills/<skill>/<path>` — because
`cp -R` overwrites such an edit with no gate to catch it. `check-shared.rb` only
guards manifest-fanned files; everything else is unprotected.

This happened: `reference/specification/styling.md` was theme-corrected directly
downstream in sigma-migration-skills#653, violating the "do NOT edit these copies
directly" rule at the top of this file. The fix existed nowhere upstream, so the
next `cp -R` would have reverted it (1 legacy theme reference back to 14). It was
resolved by porting the change UP first (sigma-skills#34), which turned the
overwrite into a no-op. **Always fix upstream, then re-vendor.**

Do NOT edit these copies directly — changes belong upstream in `sigma-skills`,
then re-vendor here. (Native trellis shapes were back-ported upstream in
`twells89/sigma-skills` #19; re-vendor `sigma-workbooks` from the SoT once that
merges to pick them up — the marketplace copy already carries the identical
recipe, so this is a consistency refresh, not a functional change.)
