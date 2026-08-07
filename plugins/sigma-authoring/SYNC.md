# sigma-authoring — vendored from `twells89/sigma-skills`

The skills under `skills/` (`sigma-workbooks`, `sigma-data-models`,
`custom-sql-to-data-model`) are **vendored copies** of the canonical
`twells89/sigma-skills` repo. They live here so the migration converters'
hard dependency on `sigma-workbooks` (the canonical Sigma spec reference) ships
in the **same marketplace** — installing any converter, install this too.

- **Source of truth:** https://github.com/twells89/sigma-skills (edit there)
- **Vendored at:** sigma-skills `main` @ `6c8ce18` (2026-08-07)

## Refresh

Re-vendor when the canonical skills change:

```sh
SRC=/path/to/sigma-skills    # a fresh clone of twells89/sigma-skills
for s in sigma-workbooks sigma-data-models custom-sql-to-data-model; do
  rm -rf "plugins/sigma-authoring/skills/$s"
  cp -R "$SRC/$s" "plugins/sigma-authoring/skills/$s"
done

# CLOBBER-SAFETY (required): the vendored skill dirs ALSO carry manifest-fanned
# shared files (scripts/doctor.{sh,ps1}, scripts/bootstrap.{sh,ps1},
# refs/environment.md, the token scripts, …) that do NOT exist upstream — the
# rm -rf above deletes them. Re-fan them from shared/manifest.json and verify,
# or the shared-lib drift gate (tools/check-shared.rb in CI) fails:
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
ruby tools/gen-agent-variants.rb --all   # regenerate all 16 from SKILL.md
ruby tools/check-agent-variants.rb       # MUST be green (16/16, drift 0)

# Sanity check before committing: `git status` should show ONLY the files that
# genuinely changed upstream. If generated/ files appear in the diff after the
# regenerate step, something else moved — inspect it, don't wave it through.

# then update the "Vendored at" SHA above and commit
```

Do NOT edit these copies directly — changes belong upstream in `sigma-skills`,
then re-vendor here. (Native trellis shapes were back-ported upstream in
`twells89/sigma-skills` #19; re-vendor `sigma-workbooks` from the SoT once that
merges to pick them up — the marketplace copy already carries the identical
recipe, so this is a consistency refresh, not a functional change.)
