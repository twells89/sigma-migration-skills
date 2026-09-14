#!/usr/bin/env bash
# tools/derive-public.sh — turn a checkout of this PRIVATE dev repo into the
# PUBLIC-safe tree that ships to sigmacomputing/sigma-migration-skills.
#
#   bash tools/derive-public.sh <dest>
#
# <dest> must already be a git worktree of THIS repo checked out at (or based
# on) public/main — the script overlays public-only files via
# `git -C <dest> checkout public/main -- <path>`, so public/main must be a
# reachable ref from <dest>'s .git. Run from the dev checkout root (the
# directory containing this tools/ dir).
#
# What it does, in order (see docs in the task/PR that introduced this script
# for the full rationale):
#   1. rsync the dev tree into <dest> (dest becomes byte-identical to dev,
#      minus .git).
#   2. delete internal-only docs/handoff material.
#   3. overlay public-only OSS files from public/main (LICENSE, NOTICE,
#      SECURITY.md, CODE_OF_CONDUCT.md, CODEOWNERS, CHANGELOG.md,
#      ISSUE_TEMPLATE/, build.yml, dependabot.yml).
#   4. bespoke structural fixes: drop the private converter-repo coupling
#      (freshness/online CI gates, provenance source_repo/source_commit
#      fields, hosted-converter domain, escalate-gap.py routing, beads
#      integration) in the specific files that need surgical edits rather
#      than a blind find/replace.
#   5. a fleet-wide identity + internal-identifier scrub over every file that
#      still matches a prohibited pattern after step 4.
#   6. ruby tools/sync-shared.rb inside <dest> so shared/ copies match.
#
# Idempotent and safe to re-run: every step either fully regenerates its
# target or is a no-op when nothing matches.
set -euo pipefail

DEST="${1:?usage: bash tools/derive-public.sh <dest>}"
DEVROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$(cd "$DEST" && pwd)"

[ -d "$DEST/.git" ] || [ -f "$DEST/.git" ] || { echo "FATAL: $DEST is not a git worktree"; exit 1; }
git -C "$DEST" rev-parse --verify public/main >/dev/null 2>&1 || {
  echo "FATAL: public/main is not reachable from $DEST — fetch it first"; exit 1;
}

echo "=== derive-public.sh: $DEVROOT -> $DEST ==="

# ─────────────────────────────────────────────────────────────────────────
# STEP 1 — sync dev content into <dest>
# ─────────────────────────────────────────────────────────────────────────
echo "[1/6] rsync dev tree -> dest"
rsync -a --delete --exclude=.git "$DEVROOT"/ "$DEST"/

cd "$DEST"

# ─────────────────────────────────────────────────────────────────────────
# STEP 2 — delete internal docs (never ship publicly)
# ─────────────────────────────────────────────────────────────────────────
echo "[2/6] delete internal docs"
rm -rf \
  docs/handoff \
  docs/superpowers \
  docs/wave2 \
  docs/README.md \
  docs/PLAN-v3.md \
  docs/agent-entry.md \
  docs/migration-runtime-contract.md \
  docs/structure-roadmap.md \
  docs/tableau-to-sigma-phase1-composition-style.md \
  V5.5-FABLE-HANDOFF.md \
  V5.6-CONTROLS-AUDIT.md
rm -f docs/tableau-to-sigma-*HANDOFF*.md
# derive-public.sh itself never ships public; neither does the version stamper
# or SYNC.md (both name the private dev repo + the prohibited-pattern list).
rm -f tools/derive-public.sh tools/stamp-version.rb SYNC.md

# ─────────────────────────────────────────────────────────────────────────
# STEP 3 — overlay public-only OSS files from public/main
# ─────────────────────────────────────────────────────────────────────────
echo "[3/6] overlay public-only files from public/main"
PUBLIC_ONLY=(
  LICENSE
  NOTICE
  SECURITY.md
  CODE_OF_CONDUCT.md
  .github/CODEOWNERS
  CHANGELOG.md
  .github/workflows/build.yml
)
for f in "${PUBLIC_ONLY[@]}"; do
  git show "public/main:$f" > "/tmp/derive-public.$$" 2>/dev/null && {
    mkdir -p "$(dirname "$f")"
    mv "/tmp/derive-public.$$" "$f"
    echo "  overlaid $f (from public/main)"
  } || echo "  WARN: $f not found on public/main — skipping"
done
rm -f "/tmp/derive-public.$$" 2>/dev/null || true
# ISSUE_TEMPLATE/ is a directory — checkout handles it in one shot.
git checkout public/main -- .github/ISSUE_TEMPLATE 2>/dev/null \
  && echo "  overlaid .github/ISSUE_TEMPLATE/ (from public/main)" \
  || echo "  WARN: .github/ISSUE_TEMPLATE not found on public/main — skipping"
git checkout public/main -- .github/PULL_REQUEST_TEMPLATE.md 2>/dev/null \
  && echo "  overlaid .github/PULL_REQUEST_TEMPLATE.md (from public/main)" \
  || echo "  (dev's PULL_REQUEST_TEMPLATE.md kept — none on public/main)"
# dependabot.yml does not exist on public/main (that baseline predates it);
# the real config was authored on security/hardening-pre-public (also pushed
# to the public remote). Prefer public/main, fall back to that branch.
if git show "public/main:.github/dependabot.yml" > "/tmp/derive-public.dbot.$$" 2>/dev/null; then
  mv "/tmp/derive-public.dbot.$$" .github/dependabot.yml
  echo "  overlaid .github/dependabot.yml (from public/main)"
elif git show "security/hardening-pre-public:.github/dependabot.yml" > "/tmp/derive-public.dbot.$$" 2>/dev/null; then
  mv "/tmp/derive-public.dbot.$$" .github/dependabot.yml
  echo "  overlaid .github/dependabot.yml (from security/hardening-pre-public — not yet on public/main)"
else
  rm -f "/tmp/derive-public.dbot.$$" 2>/dev/null || true
  echo "  WARN: dependabot.yml not found on public/main or security/hardening-pre-public — skipping"
fi

# ─────────────────────────────────────────────────────────────────────────
# STEP 4 — bespoke structural fixes (private converter-repo decoupling)
# ─────────────────────────────────────────────────────────────────────────
echo "[4/6] bespoke structural fixes"

# --- 4a. hygiene.yml + test-converter-provenance.sh: drop the freshness/
#     online CI gate and its self-test. That gate references a private repo
#     public contributors cannot reach, is unsatisfiable in public CI (no way
#     to re-vendor there), and turns red on the calendar (>14d) on its own —
#     it is a maintenance reminder for the private dev repo, not a
#     public-repo gate. Marker-based (not a git-apply patch): <dest> was
#     populated by rsync in step 1, so its git index doesn't reflect the
#     working tree yet and a blob-based 3-way patch has nothing to merge
#     against.
echo "  4a. drop converter-freshness CI gate (hygiene.yml, test-converter-provenance.sh)"

python3 - <<'DERIVE_PY_EOF'
import re

# hygiene.yml: remove the whole "Converter-freshness guard" step (from its
# "- name:" line up to, but not including, the next "- name:" line), and
# trim the now-stale Part-E/F callout from the self-test step's comment.
path = ".github/workflows/hygiene.yml"
t = open(path, encoding="utf-8").read()
t = re.sub(
    r'[ \t]*- name: Converter-freshness guard.*?\n(?=[ \t]*- name:)',
    '',
    t,
    count=1,
    flags=re.DOTALL,
)
old_comment = (
    "        # names only). Also proves the --freshness staleness-by-age gate\n"
    "        # (Part E) fails a 40d-stale fixture and passes the same fixture\n"
    "        # dated today, reports an in-skill/cognos-shaped entry explicitly\n"
    "        # rather than silently, and surfaces the local_patches\n"
    "        # don't-re-vendor-blind note; plus --online's soft-pass when no local\n"
    "        # checkout is present (Part F).\n"
)
t = t.replace(old_comment, "        # names only).\n")
open(path, "w", encoding="utf-8").write(t)

# test-converter-provenance.sh: drop the Part E/F header callouts and the
# Part E/F test bodies themselves.
path = "tools/test-converter-provenance.sh"
t = open(path, encoding="utf-8").read()
old_header = (
    "#   Part E — --freshness (staleness-by-age gate, 2026-07-31): a vendored\n"
    "#            PROVENANCE.json whose source_commit_date is older than\n"
    "#            CONVERTER_STALENESS_DAYS fails naming the module + re-vendor\n"
    "#            command; the same fixture with today's date passes; a\n"
    "#            source_repo entry missing source_commit/source_commit_date\n"
    "#            fails; a stale entry carrying local_patches gets the\n"
    "#            do-not-re-vendor-blind note; an in-skill (cognos-shaped, no\n"
    "#            source_repo) entry is reported explicitly as not-applicable,\n"
    "#            never silently dropped or miscounted as stale\n"
    "#   Part F — --online soft-pass: with no local sigma-data-model-mcp checkout\n"
    "#            present, --online exits 0 with a warning rather than failing —\n"
    "#            it is a human-driven convenience, never a hard CI requirement\n"
)
t = t.replace(old_header, "")
start = t.index('echo "Part E — --freshness')
end = t.index('\necho\n', start) + 1  # keep the blank "echo" line that follows
t = t[:start] + t[end:]
# The Part A/B/C fixtures used a "source_repo" field only to *represent* the
# vendored (non-in-skill) shape for the guard's discriminator; the guard now
# discriminates solely on the presence of a "source" key (see
# check-converter-provenance.sh's prov_kind()), so the field is unused by the
# test and safe to drop everywhere it's stamped into a fixture.
t = t.replace('  "source_repo": "example/fixture-converters",\n', "")
t = t.replace(
    '#   Part C — in-skill converters ("source" key, no "source_repo": the static',
    '#   Part C — in-skill converters ("source" key: the static',
)
open(path, "w", encoding="utf-8").write(t)
DERIVE_PY_EOF

echo "  4a done"

# --- 4b. full-content rewrites: files whose private-repo coupling is
#     structural (env-driven defaults, routing tables), not prose — a blind
#     find/replace would leave broken logic or an awkward sentence, so these
#     ship a complete, hand-verified replacement body instead.
echo "  4b. rewrite converter-source-coupled scripts (env-var driven, no baked-in private defaults)"

cat > tools/check-converter-provenance.sh <<'DERIVE_EOF'
#!/usr/bin/env bash
# tools/check-converter-provenance.sh — converter-provenance diff-pairing guard
# (the standing vendoring rule made mechanical, 2026-07-18).
#
#   bash tools/check-converter-provenance.sh <BASE> <HEAD>
#
# A vendored converter bundle (plugins/**/converter/*.mjs) is a GENERATED
# artifact, never hand-edited. This guard makes that rule mechanical: it fails
# (exit 1) when the BASE..HEAD range:
#   1) changes a vendored converter bundle (plugins/**/converter/*.mjs) without
#      its sibling PROVENANCE.json changing in the same range — a regeneration
#      records itself there; an in-place patch records itself in local_patches.
#      In-skill converters (PROVENANCE has a "source" key — a static body
#      their rebuild rewrites byte-identical, so it can never diff) may pair
#      the bundle with a changed converter/*.ts source instead.
#   2) changes a converter PROVENANCE.json that no longer parses as JSON, or
#      whose local_patches entries drop the commit/summary/upstream_pr schema.
#   3) deletes a converter PROVENANCE.json while its bundle remains at HEAD.
#
# Callers resolve the range (hygiene.yml derives it from the CI event); the
# check itself is range-parameterized so tools/test-converter-provenance.sh
# can drive it against throwaway fixture repos offline.
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "python3 missing — provenance guard cannot run"; exit 1; }

BASE="${1:?usage: check-converter-provenance.sh <BASE> <HEAD>}"
HEAD="${2:?usage: check-converter-provenance.sh <BASE> <HEAD>}"

# An unresolvable range must fail, not read as an empty (green) change list.
changed="$(git diff --name-only "$BASE" "$HEAD")" || { echo "git diff $BASE..$HEAD failed — cannot check provenance pairing"; exit 1; }
fail=0

# Subprocess-free membership test (#681): the old `printf ... | grep -qxF`
# form re-piped the full $changed list through grep on every lookup. grep -q
# exits the instant it finds a match, closing its end of the pipe; on a long
# list printf/the shell is often still mid-write when that happens, the next
# write() gets SIGPIPE, and `set -uo pipefail` (above) turns that signal into
# a false "not found" — non-deterministic, and it only fires once the list is
# long enough that the writer outlives the reader (latent on small diffs,
# firing on the large ranges #680's force-push bug produces). A case/glob
# match against the newline-delimited list needs no subprocess and can't race.
changed_has() {
  case $'\n'"$changed"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}
at_head() { git cat-file -e "$HEAD:$1" 2>/dev/null; }
prov_kind() { # reads the HEAD copy; anything unparsable counts as vendored
  git show "$HEAD:$1" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print("in-skill" if "source" in d else "vendored")
'
}

# Pass 1 — every changed bundle pairs with its provenance (or in-skill source).
while IFS= read -r f; do
  [ -n "$f" ] || continue
  dir="$(dirname "$f")"
  sib="$dir/PROVENANCE.json"
  if changed_has "$sib" && at_head "$sib"; then
    continue
  fi
  if at_head "$sib" && [ "$(prov_kind "$sib")" = "in-skill" ]; then
    ts_paired=0
    while IFS= read -r c; do
      case "$c" in "$dir"/*.ts) ts_paired=1 ;; esac
    done <<< "$changed"
    [ "$ts_paired" -eq 1 ] && continue
    echo "::error file=$f::in-skill converter bundle changed without its converter/*.ts source (or PROVENANCE.json) changing — rebuild via tools/vendor-converters.sh from the edited TS source so bundle and source land together"
    fail=1
    continue
  fi
  echo "::error file=$f::vendored converter changed without its sibling PROVENANCE.json — regenerate via tools/vendor-converters.sh or record the in-place patch in local_patches"
  fail=1
done < <(printf '%s\n' "$changed" | grep -E '^plugins/.+/converter/[^/]+\.mjs$' || true)

# Pass 2 — schema-pin every changed converter PROVENANCE.json at HEAD.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if ! at_head "$p"; then
    if git ls-tree --name-only "$HEAD" "$(dirname "$p")/" 2>/dev/null | grep -q '\.mjs$'; then
      echo "::error file=$p::converter PROVENANCE.json deleted while the vendored bundle remains — restore it (the bundle's origin must stay recorded)"
      fail=1
    fi
    continue
  fi
  err="$(git show "$HEAD:$p" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as exc:
    print("not valid JSON (%s)" % exc); sys.exit(0)
lp = d.get("local_patches")
if lp is None:
    sys.exit(0)
if not isinstance(lp, list):
    print("local_patches must be an array"); sys.exit(0)
for i, entry in enumerate(lp):
    if not isinstance(entry, dict):
        print("local_patches[%d] must be an object" % i); sys.exit(0)
    missing = [k for k in ("commit", "summary", "upstream_pr") if k not in entry]
    if missing:
        print("local_patches[%d] missing key(s): %s" % (i, ", ".join(missing))); sys.exit(0)
')"
  if [ -n "$err" ]; then
    echo "::error file=$p::provenance schema pin failed — $err (every local_patches entry records commit, summary, upstream_pr)"
    fail=1
  fi
done < <(printf '%s\n' "$changed" | grep -E '^plugins/.+/converter/PROVENANCE\.json$' || true)

if [ "$fail" -ne 0 ]; then
  echo "converter-provenance guard FAILED (pair every converter/*.mjs change with its PROVENANCE.json)."
  exit 1
fi
echo "converter-provenance guard OK ($BASE..$HEAD)"
DERIVE_EOF
chmod +x tools/check-converter-provenance.sh

cat > tools/vendor-converters.sh <<'DERIVE_EOF'
#!/usr/bin/env bash
# vendor-converters.sh — the ONE consistent way to refresh the committed,
# zero-config converters that ship inside every migration skill.
#
# Each converter (convert<Tool>ToSigma) is bundled by esbuild into a single
# self-contained ESM file committed at
#   plugins/<skill>/skills/<skill>/converter/<module>.mjs
# so conversion runs locally via `node` with NO clone, NO npm install, NO network,
# and NO MCP. The vendored bundle is the shipped, guaranteed floor; a maintainer
# regenerates it from a converter-source checkout with this tool.
#
#   SIGMA_CONVERTER_SRC=/path/to/converter-source tools/vendor-converters.sh [converter ...]
#   tools/vendor-converters.sh /path/to/converter-source [converter ...]
#
#   # all converters:
#   tools/vendor-converters.sh /path/to/converter-source
#   # a subset from an explicit checkout:
#   tools/vendor-converters.sh /path/to/converter-source lookml thoughtspot cognos
#
# Re-run after the converter source changes and commit the bundles. Requires a
# converter-source checkout with esbuild installed (its devDep).
# Portable to macOS bash 3.2 (no associative arrays).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-${SIGMA_CONVERTER_SRC:-}}"; [ $# -gt 0 ] && shift || true

# module (in build/) -> skill plugin dir under plugins/ that owns it.
skill_for() {
  case "$1" in
    tableau) echo tableau-to-sigma ;;
    lookml) echo looker-to-sigma ;;
    thoughtspot) echo thoughtspot-to-sigma ;;
    qlik) echo qlik-to-sigma ;;
    powerbi) echo powerbi-to-sigma ;;
    quicksight) echo quicksight-to-sigma ;;
    cognos|cognos-report) echo cognos-to-sigma ;;
    domo) echo domo-to-sigma ;;
    *) echo "" ;;
  esac
}

WANT=("$@"); [ ${#WANT[@]} -eq 0 ] && WANT=(tableau lookml thoughtspot qlik powerbi quicksight cognos domo)

[ -n "$SRC" ] || { echo "FATAL: no converter source — pass a checkout path or set SIGMA_CONVERTER_SRC"; exit 1; }
[ -d "$SRC" ] || { echo "FATAL: converter source not found: $SRC"; exit 1; }
ESBUILD="$SRC/node_modules/.bin/esbuild"
[ -x "$ESBUILD" ] || { echo "FATAL: esbuild not at $ESBUILD — run 'npm install' in $SRC"; exit 1; }

# build the converter repo if its artifacts are missing
if ! ls "$SRC"/build/*.js >/dev/null 2>&1; then
  echo "→ building converter repo (npm run build)"
  ( cd "$SRC" && { npm ci --silent || npm install --silent; } && npm run build --silent )
fi

STAMPED_DIRS=""

for mod in "${WANT[@]}"; do
  skill="$(skill_for "$mod")"
  [ -n "$skill" ] || { echo "WARN: unknown converter '$mod' — skipping"; continue; }
  dest="$ROOT/plugins/$skill/skills/$skill/converter"
  mkdir -p "$dest"

  # Cognos is special: its converter is vendored as TS source IN the skill
  # (converter/cli.ts → cognos.ts/cognos-report.ts), not from the converter
  # source repo. Bundle that pinned CLI into a self-contained converter/cli.mjs
  # (npm install in the skill's converter/ once for fast-xml-parser;
  # node_modules stays gitignored).
  if [ "$mod" = "cognos" ]; then
    entry="$dest/cli.ts"
    out="$dest/cli.mjs"
    [ -f "$entry" ] || { echo "FATAL: $entry missing (cognos vendors its own TS converter)"; exit 1; }
    [ -d "$dest/node_modules/fast-xml-parser" ] || ( cd "$dest" && npm install --silent )
    "$ESBUILD" "$entry" --bundle --format=esm --platform=node --outfile="$out" >/dev/null
    echo "✓ $skill/converter/cli.mjs  ($(du -h "$out" | cut -f1))  [bundled from in-skill cli.ts]"
    # cognos provenance tracks the in-repo TS source. Writing the source_sha256
    # here (single owner: tools/check-cognos-bundle.rb) is what lets that gate
    # detect a converter/*.ts edit that skipped this re-bundle.
    ruby "$ROOT/tools/check-cognos-bundle.rb" --write
    continue
  fi

  # Domo is a third flavor: same regenerate-from-source relationship as the
  # mainline 6, but its source module doesn't follow the convert<Tool>ToSigma
  # naming convention. It vendors formulas.ts, a shared low-level SQL-formula
  # toolkit already used internally by lookml/dbt/snowflake/tableau's own
  # converters — not a top-level converter — so the entry file and the export
  # sanity-check are both custom.
  if [ "$mod" = "domo" ]; then
    entry="$SRC/build/formulas.js"
    out="$dest/sql.mjs"
    [ -f "$entry" ] || { echo "FATAL: $entry missing (build the converter repo first)"; exit 1; }
    "$ESBUILD" "$entry" --bundle --format=esm --platform=node --outfile="$out" >/dev/null
    node --input-type=module -e "
      import * as m from '$out';
      const need = ['lookSqlToSigmaRules','lookConvertExpression','hasResidualCaseKeyword','hasResidualInfixOperator','lookUnknownFunctions'];
      const missing = need.filter(k => typeof m[k] !== 'function');
      if (missing.length) { console.error('FATAL: $out missing exports: ' + missing.join(', ')); process.exit(1); }
    "
    echo "✓ $skill/converter/sql.mjs  ($(du -h "$out" | cut -f1))  [vendored from formulas.ts, custom export check]"
    # Domo is NOT added to STAMPED_DIRS: the shared post-loop block below writes
    # a PROVENANCE.json whose vendored_modules basename ("sql") differs from the
    # bundled source name ("formulas"). Write domo's own PROVENANCE.json here.
    cat > "$dest/PROVENANCE.json" <<EOF
{
  "bundler": "esbuild --bundle --format=esm --platform=node",
  "vendored_modules": "sql.mjs",
  "note": "Self-contained generated bundle; not source — do not hand-edit."
}
EOF
    echo "✓ $skill/converter/PROVENANCE.json  [domo's own — vendored_modules=sql.mjs]"
    continue
  fi

  entry="$SRC/build/$mod.js"
  [ -f "$entry" ] || { echo "FATAL: $entry missing (build the converter repo first)"; exit 1; }
  out="$dest/$mod.mjs"
  "$ESBUILD" "$entry" --bundle --format=esm --platform=node --outfile="$out" >/dev/null
  # sanity: the bundle must export a convert<Tool>ToSigma symbol
  node --input-type=module -e "
    import * as m from '$out';
    const fn = Object.keys(m).find(k => /^convert.*ToSigma\$/.test(k));
    if (!fn) { console.error('FATAL: $out exports no convert*ToSigma'); process.exit(1); }
  "
  echo "✓ $skill/converter/$mod.mjs  ($(du -h "$out" | cut -f1))"
  case "$STAMPED_DIRS" in *"|$dest|"*) : ;; *) STAMPED_DIRS="$STAMPED_DIRS|$dest|" ;; esac
done

# one PROVENANCE.json per touched skill converter dir (generic shape — domo
# is deliberately never added to STAMPED_DIRS; it writes its own complete
# PROVENANCE.json above, right after its bundle is built). A domo-only run
# leaves STAMPED_DIRS empty — guard the pipeline so `grep -v '^$'` finding no
# lines (exit 1) doesn't abort the script under `set -euo pipefail`.
if [ -n "$STAMPED_DIRS" ]; then
  echo "$STAMPED_DIRS" | tr '|' '\n' | grep -v '^$' | sort -u | while read -r dest; do
    [ -d "$dest" ] || continue
    mods=$(ls "$dest"/*.mjs 2>/dev/null | xargs -n1 basename | paste -sd, -)
    cat > "$dest/PROVENANCE.json" <<EOF
{
  "bundler": "esbuild --bundle --format=esm --platform=node",
  "vendored_modules": "$mods",
  "note": "Self-contained generated bundle; not source — do not hand-edit."
}
EOF
  done
fi

echo "Done. Commit the converter/ diffs."
DERIVE_EOF
chmod +x tools/vendor-converters.sh

FETCH_CONVERTER=plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/dev/fetch-converter.sh
cat > "$FETCH_CONVERTER" <<'DERIVE_EOF'
#!/usr/bin/env bash
# fetch-converter.sh — get a LOCAL Tableau→Sigma converter build with one command,
# for the no-egress mechanical path when you don't already have the converter
# source checked out elsewhere.
#
# It clones (or updates) the converter repo into a GITIGNORED vendor/ dir under the
# skill and builds it. migrate-tableau.rb then auto-discovers vendor/converter-source/
# build/tableau.js (see the auto-discover block) — no TABLEAU_MCP_BUILD needed.
#
# This fetches the FRESH converter for DEVELOPERS. A committed, pinned snapshot also
# ships in the skill at converter/ (the zero-config floor everyone gets with no clone/
# network — see scripts/dev/vendor-converter.sh). Auto-discovery prefers this fresh
# build over the committed snapshot, so a dev always tests the latest; the snapshot
# only kicks in when no fresher build exists. Re-run this script to refresh the dev copy.
#
#   SIGMA_CONVERTER_REPO=<your converter-source git URL> ./scripts/dev/fetch-converter.sh
#   ./scripts/dev/fetch-converter.sh <ref>      # build a specific branch/tag/sha
#
# Requires: git + node/npm on PATH.
set -euo pipefail

REPO="${SIGMA_CONVERTER_REPO:-}"   # set to your converter build-source repo (no default — internal)
REF="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the skill's scripts/ dir
DEST="$HERE/vendor/converter-source"

command -v git  >/dev/null || { echo "FATAL: git not on PATH"; exit 1; }
command -v npm  >/dev/null || { echo "FATAL: npm/node not on PATH — the local converter needs Node"; exit 1; }

if [ -d "$DEST/.git" ]; then
  echo "→ updating existing checkout at $DEST"
  git -C "$DEST" fetch --quiet origin
  if [ -n "$REF" ]; then git -C "$DEST" checkout --quiet "$REF"; git -C "$DEST" pull --quiet --ff-only origin "$REF" 2>/dev/null || true
  else git -C "$DEST" pull --quiet --ff-only; fi
else
  [ -n "$REPO" ] || { echo "FATAL: no checkout at $DEST and SIGMA_CONVERTER_REPO is unset — point it at your converter build-source repo"; exit 1; }
  echo "→ cloning $REPO → $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone --quiet "$REPO" "$DEST"
  [ -n "$REF" ] && git -C "$DEST" checkout --quiet "$REF"
fi

echo "→ installing deps + building (npm ci && npm run build)"
( cd "$DEST" && { npm ci --silent || npm install --silent; } && npm run build --silent )

BUILD="$DEST/build/tableau.js"
if [ -f "$BUILD" ]; then
  echo ""
  echo "✓ local converter ready: $BUILD"
  echo "  migrate-tableau.rb will auto-discover it (no TABLEAU_MCP_BUILD needed)."
  echo "  built from $(git -C "$DEST" rev-parse --short HEAD) ($(git -C "$DEST" rev-parse --abbrev-ref HEAD))"
else
  echo "FATAL: build did not produce $BUILD — check the npm build output above"; exit 1
fi
DERIVE_EOF
chmod +x "$FETCH_CONVERTER"

VENDOR_CONVERTER=plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/dev/vendor-converter.sh
cat > "$VENDOR_CONVERTER" <<'DERIVE_EOF'
#!/usr/bin/env bash
# vendor-converter.sh — refresh the COMMITTED, zero-config Tableau→Sigma converter
# that ships inside this skill at converter/tableau.mjs.
#
# Unlike fetch-converter.sh (which clones+builds into a gitignored vendor/ dir for
# devs), this BUNDLES the built converter into a single self-contained ESM file and
# commits it, so local conversion works for everyone with NO clone, NO npm install,
# and NO network — the guaranteed local fallback migrate-tableau.rb auto-discovers
# last. A single bundled file (esbuild) means no node_modules to commit and no
# .gitignore fight; its only runtime requirement is `node` on PATH.
#
# The vendored snapshot can drift from the live converter. That is the accepted
# trade for a zero-setup, no-data-egress default; a dev's own local checkout (or
# TABLEAU_MCP_BUILD / SIGMA_CONVERTER_SRC / fetch-converter.sh) still WINS over the
# vendored copy, so the floor only kicks in when nothing fresher exists. Re-run this
# after the converter source changes and commit the result.
#
#   SIGMA_CONVERTER_SRC=/path/to/converter-source ./scripts/dev/vendor-converter.sh
#   ./scripts/dev/vendor-converter.sh /path/to/converter-source   # or pass it explicitly
#
# Requires: a converter-source checkout with esbuild installed (its devDep) +
# git for provenance stamping.
set -euo pipefail

SRC="${1:-${SIGMA_CONVERTER_SRC:-}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"   # skill root
DEST="$HERE/converter"
ENTRY="$SRC/build/tableau.js"
OUT="$DEST/tableau.mjs"

[ -n "$SRC" ] || { echo "FATAL: no converter source — pass a checkout path or set SIGMA_CONVERTER_SRC"; exit 1; }
[ -d "$SRC" ] || { echo "FATAL: converter source not found: $SRC (pass a path to a converter-source checkout)"; exit 1; }

# Build the converter if its entry artifact is missing.
if [ ! -f "$ENTRY" ]; then
  echo "→ $ENTRY missing — building (npm ci && npm run build)"
  ( cd "$SRC" && { npm ci --silent || npm install --silent; } && npm run build --silent )
fi
[ -f "$ENTRY" ] || { echo "FATAL: $ENTRY still missing after build"; exit 1; }

ESBUILD="$SRC/node_modules/.bin/esbuild"
[ -x "$ESBUILD" ] || { echo "FATAL: esbuild not found at $ESBUILD — run 'npm install' in $SRC first"; exit 1; }

echo "→ bundling converter closure into $OUT (single self-contained ESM file)"
mkdir -p "$DEST"
"$ESBUILD" "$ENTRY" --bundle --format=esm --platform=node --outfile="$OUT" >/dev/null

# Sanity: the bundle must export convertTableauToSigma and pull in NO external module.
node --input-type=module -e "import { convertTableauToSigma } from '$OUT'; if (typeof convertTableauToSigma !== 'function') { console.error('FATAL: bundle does not export convertTableauToSigma'); process.exit(1); }"

# Record provenance for the committed bundle (self-contained artifact, not source).
cat > "$DEST/PROVENANCE.json" <<EOF
{
  "bundler": "esbuild --bundle --format=esm --platform=node",
  "vendored_modules": "tableau.mjs",
  "note": "Self-contained generated bundle; not source — do not hand-edit."
}
EOF

echo "✓ vendored converter ready: $OUT"
echo "  migrate-tableau.rb auto-discovers it as the guaranteed local fallback — commit the diff."
DERIVE_EOF
chmod +x "$VENDOR_CONVERTER"

# --- 4c. escalate-gap.py (vendored identically into every plugin's scripts/):
#     route every gap category to the one public repo (the two private
#     converter-source repos it used to mirror to have no public equivalent),
#     and drop the beads (~/.beads-sigma) integration entirely — internal-only
#     tooling with zero value to a public contributor and no `bd` on their
#     machine anyway.
echo "  4c. rewrite escalate-gap.py (all vendored copies) — generic routing, no beads"
ESCALATE_COPIES=()
while IFS= read -r -d '' f; do ESCALATE_COPIES+=("$f"); done < <(find . -name "escalate-gap.py" -not -path "./.git/*" -print0)
for f in "${ESCALATE_COPIES[@]}"; do
cat > "$f" <<'DERIVE_EOF'
#!/usr/bin/env python3
"""escalate-gap — opt-in GitHub-issue filer for gap-scout escalations.

Shared across every migration skill (vendored identically into each plugin's
scripts/). When the gap scout can't find a working Sigma translation for a
source feature, the main agent offers the user the *option* to open a tracking
issue in the appropriate repo. This script is what turns that "yes" into filed
issues — with dedupe, repo routing, and cross-linked mirroring.

DESIGN: opt-in, never automatic.
  - Default (no --yes): DRY RUN. Prints the drafted issue(s), the target repo(s),
    and any existing open issues that already cover this gap. Files NOTHING.
    This is what the agent shows the user.
  - With --yes: actually files. Skips any repo where dedupe already found a match
    (unless --force).

ROUTING (category -> repos): every category files against this public repo —
converter/builder/skill gaps are all tracked here, distinguished by the
`category:<name>` label, so there is a single public place to look.
  converter  -> sigmacomputing/sigma-migration-skills   (a source expression the
                *converter* failed to translate)
  builder    -> sigmacomputing/sigma-migration-skills   (workbook/DM spec builder gap)
  skill      -> sigmacomputing/sigma-migration-skills   (skill-logic / discovery gap)

Usage (dry-run draft the agent shows the user):
  python3 scout/escalate-gap.py \
    --skill tableau-to-sigma --category converter \
    --feature WINDOW_AVG --description 'moving average over SUM' \
    --source-pattern 'WINDOW_AVG(SUM([...]))' \
    --template-attempted 'MovingAvg(Sum([Master/\\1]), -10, 10)' \
    --test-formula 'MovingAvg(Sum([Master/Sales]), -10, 10)' \
    --sigma-response '<failing column type / error json>' \
    --example-from 'Sales.twb line 412' \
    --escalation-yaml ~/.tableau-to-sigma/escalations/window_avg.yaml

Then, only if the user says yes, the agent re-runs the same command with --yes.

Requires `gh` on PATH and authed for the target repo.
Exit codes: 0 = ok (drafted or filed), 3 = nothing fileable / gh missing on --yes.
"""
import argparse
import json
import shutil
import subprocess
import sys

ROUTES = {
    "converter": ["sigmacomputing/sigma-migration-skills"],
    "builder":   ["sigmacomputing/sigma-migration-skills"],
    "skill":     ["sigmacomputing/sigma-migration-skills"],
}


def have(cmd):
    return shutil.which(cmd) is not None


def run(args, **kw):
    """Run a command, return (ok, stdout, stderr)."""
    try:
        p = subprocess.run(args, capture_output=True, text=True, **kw)
        return p.returncode == 0, p.stdout.strip(), p.stderr.strip()
    except Exception as e:  # noqa: BLE001
        return False, "", str(e)


def build_issue(a):
    title = f"{a.skill} gap: {a.feature}" + (f" ({a.description})" if a.description else "")
    body = []
    body.append(f"**Skill:** `{a.skill}`")
    body.append(f"**Gap category:** `{a.category}`")
    body.append(f"**Feature:** `{a.feature}`")
    if a.description:
        body.append(f"**Description:** {a.description}")
    if a.source_pattern:
        body.append(f"**Source pattern:** `{a.source_pattern}`")
    if a.template_attempted:
        body.append(f"**Sigma template attempted:** `{a.template_attempted}`")
    if a.test_formula:
        body.append(f"**Test formula POSTed:** `{a.test_formula}`")
    if a.sigma_response:
        body.append(f"**Sigma response:**\n```\n{a.sigma_response}\n```")
    body.append(f"**Example source:** {a.example_from or '(not provided)'}")
    if a.escalation_yaml:
        body.append(f"**Local escalation record:** `{a.escalation_yaml}`")
    body.append("\n_Filed via the gap-scout opt-in escalation flow (`escalate-gap.py`)._")
    return title, "\n\n".join(body)


def labels_for(a):
    return ["gap-scout-escalation", a.skill, f"category:{a.category}"]


def ensure_labels(repo, labels):
    """Best-effort: create labels so `gh issue create --label` won't fail."""
    for lab in labels:
        run(["gh", "label", "create", lab, "--repo", repo, "--force"])


def find_dupes(repo, feature, skill):
    """Return list of {number,title,url} open issues that look like this gap."""
    ok, out, _ = run([
        "gh", "issue", "list", "--repo", repo, "--state", "open",
        "--label", "gap-scout-escalation", "--search", feature,
        "--json", "number,title,url",
    ])
    if not ok or not out:
        return []
    try:
        items = json.loads(out)
    except Exception:  # noqa: BLE001
        return []
    feat = feature.lower()
    return [i for i in items if feat in (i.get("title", "").lower())]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skill", required=True)
    ap.add_argument("--feature", required=True)
    ap.add_argument("--category", default="converter", choices=list(ROUTES))
    ap.add_argument("--description", default="")
    ap.add_argument("--source-pattern", default="")
    ap.add_argument("--template-attempted", default="")
    ap.add_argument("--test-formula", default="")
    ap.add_argument("--sigma-response", default="")
    ap.add_argument("--example-from", default="")
    ap.add_argument("--escalation-yaml", default="")
    ap.add_argument("--extra-repo", action="append", default=[],
                    help="additional target repo(s), repeatable")
    ap.add_argument("--yes", action="store_true",
                    help="actually file. Without it: dry-run, prints the draft only.")
    ap.add_argument("--force", action="store_true",
                    help="file even if a matching open issue already exists")
    a = ap.parse_args()

    repos = list(dict.fromkeys(ROUTES[a.category] + a.extra_repo))
    title, body = build_issue(a)
    labels = labels_for(a)

    # Dedupe scan (read-only) up front so the agent can show it to the user.
    gh_ok = have("gh")
    dupes = {r: (find_dupes(r, a.feature, a.skill) if gh_ok else []) for r in repos}

    if not a.yes:
        # DRY RUN — this is what the agent presents to the user.
        out = {
            "mode": "draft",
            "would_file_in": repos,
            "labels": labels,
            "title": title,
            "body": body,
            "existing_issues": {r: d for r, d in dupes.items() if d},
            "gh_available": gh_ok,
            "next_step": "re-run with --yes to file (skips repos already covered)",
        }
        print(json.dumps(out, indent=2))
        return 0

    # --yes: actually file.
    if not gh_ok:
        print(json.dumps({"status": "error", "error": "gh not on PATH; cannot file"}))
        return 3

    issue_body = body

    filed, skipped = [], []
    for repo in repos:
        if dupes.get(repo) and not a.force:
            skipped.append({"repo": repo, "existing": dupes[repo]})
            continue
        ensure_labels(repo, labels)
        ok, out, err = run([
            "gh", "issue", "create", "--repo", repo,
            "--title", title, "--body", issue_body,
            "--label", ",".join(labels),
        ])
        if ok:
            filed.append({"repo": repo, "url": out.strip()})
        else:
            # retry once without labels (in case label creation was denied)
            ok2, out2, err2 = run([
                "gh", "issue", "create", "--repo", repo,
                "--title", title, "--body", issue_body,
            ])
            if ok2:
                filed.append({"repo": repo, "url": out2.strip(), "note": "filed without labels"})
            else:
                filed.append({"repo": repo, "error": err or err2})

    # Cross-link mirrored issues to each other.
    urls = [f["url"] for f in filed if f.get("url")]
    if len(urls) > 1:
        for f in filed:
            if not f.get("url"):
                continue
            others = [u for u in urls if u != f["url"]]
            num = f["url"].rstrip("/").split("/")[-1]
            link_body = issue_body + "\n\n**Mirrored to:** " + ", ".join(others)
            run(["gh", "issue", "edit", num, "--repo", f["repo"], "--body", link_body])

    print(json.dumps({
        "status": "filed",
        "filed": filed,
        "skipped_existing": skipped,
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
DERIVE_EOF
chmod +x "$f"
done
echo "    rewrote ${#ESCALATE_COPIES[@]} escalate-gap.py copies"

# --- 4d. mcp_convert.py (vendored into corpus/lib and the tableau skill):
#     the hosted-converter URL is opt-in-only and env-driven with NO baked-in
#     default — no private domain ships in the public repo.
echo "  4d. rewrite mcp_convert.py (all vendored copies) — env-driven hosted URL, no default"
MCP_CONVERT_COPIES=()
while IFS= read -r -d '' f; do MCP_CONVERT_COPIES+=("$f"); done < <(find . -name "mcp_convert.py" -not -path "./.git/*" -print0)
for f in "${MCP_CONVERT_COPIES[@]}"; do
cat > "$f" <<'DERIVE_EOF'
#!/usr/bin/env python3
"""Call a converter-source MCP tool over streamable HTTP.

Usage: mcp_convert.py <tool_name> <args_json_file> [out_file]
The args json file holds the tool arguments; values like {"@file": "path"}
are replaced with that file's content.

The hosted endpoint is never baked in — it is opt-in only, and only reachable
when SIGMA_MCP_CONVERTER_URL is explicitly set (no default, so no source data
can ever leave the machine without an explicit operator choice).
"""
import json
import os
import sys
import ssl
import urllib.request

try:
    import truststore
    truststore.inject_into_ssl()
    _CTX = None
except ImportError:
    # No truststore: fall back to a VERIFIED context, never unverified.
    _CTX = ssl.create_default_context()

URL = os.environ.get("SIGMA_MCP_CONVERTER_URL", "")


def post(payload, session=None):
    if not URL:
        print("FATAL: SIGMA_MCP_CONVERTER_URL is not set — no hosted converter "
              "endpoint configured (this path is opt-in only)", file=sys.stderr)
        sys.exit(1)
    req = urllib.request.Request(URL, data=json.dumps(payload).encode(),
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    if session:
        req.add_header("mcp-session-id", session)
    resp = urllib.request.urlopen(req, timeout=300, context=_CTX) if _CTX else urllib.request.urlopen(req, timeout=300)
    sid = resp.headers.get("mcp-session-id", session)
    body = resp.read().decode()
    ctype = resp.headers.get("Content-Type", "")
    if "text/event-stream" in ctype:
        data = None
        for line in body.splitlines():
            if line.startswith("data:"):
                data = line[5:].strip()
        return (json.loads(data) if data else None), sid
    return (json.loads(body) if body.strip() else None), sid


def main():
    tool, args_file = sys.argv[1], sys.argv[2]
    out_file = sys.argv[3] if len(sys.argv) > 3 else None
    args = json.load(open(args_file))

    def resolve(v):
        if isinstance(v, dict) and "@file" in v:
            return open(v["@file"], encoding="utf-8").read()
        if isinstance(v, list):
            return [resolve(x) for x in v]
        if isinstance(v, dict):
            return {k: resolve(x) for k, x in v.items()}
        return v

    args = resolve(args)

    init, sid = post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": {"protocolVersion": "2024-11-05",
                                 "capabilities": {},
                                 "clientInfo": {"name": "corpus", "version": "0"}}})
    if not sid:
        print("no session id; init response:", json.dumps(init)[:500], file=sys.stderr)
    post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    res, _ = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                   "params": {"name": tool, "arguments": args}}, sid)
    if res is None or "result" not in res:
        print("ERROR:", json.dumps(res)[:2000], file=sys.stderr)
        sys.exit(1)
    text = res["result"]["content"][0]["text"]
    if out_file:
        open(out_file, "w", encoding="utf-8").write(text)
        print("wrote", out_file, len(text), "bytes")
    else:
        print(text)


if __name__ == "__main__":
    main()
DERIVE_EOF
done
echo "    rewrote ${#MCP_CONVERT_COPIES[@]} mcp_convert.py copies"

# --- 4e. migrate-tableau.rb + mechanical-specs.rb: genericize the hosted
#     endpoint mentions in help/log text, and the vendor/ dir name in the
#     auto-discover block (must match fetch-converter.sh's new DEST above).
echo "  4e. genericize hosted-endpoint mentions + vendor dir name in tableau scripts"
MT=plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/migrate-tableau.rb
MS=plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/mechanical-specs.rb
python3 - "$MT" "$MS" <<'DERIVE_PY_EOF'
import sys
mt_path, ms_path = sys.argv[1], sys.argv[2]

def sub_all(path, pairs):
    try:
        t = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        return
    for old, new in pairs:
        t = t.replace(old, new)
    open(path, "w", encoding="utf-8").write(t)

sub_all(mt_path, [
    ("sigma-data-model-mcp.onrender.com", "the configured SIGMA_MCP_CONVERTER_URL endpoint"),
    ("vendor', 'sigma-data-model-mcp', 'build", "vendor', 'converter-source', 'build"),
])
sub_all(ms_path, [
    ("(https://sigma-data-model-mcp.onrender.com/mcp via lib/mcp_convert.py),",
     "(the endpoint at SIGMA_MCP_CONVERTER_URL, via lib/mcp_convert.py),"),
    ("hosted converter failed (sigma-data-model-mcp.onrender.com): ",
     "hosted converter failed (SIGMA_MCP_CONVERTER_URL=#{ENV['SIGMA_MCP_CONVERTER_URL'].inspect}): "),
])
DERIVE_PY_EOF
echo "    genericized $MT, $MS"

# --- 4f. PROVENANCE.json (7 vendored converters): strip private-repo lineage
#     fields. Every other key (bundler, vendored_modules, note, and — for
#     tableau — local_patches / _upstream_and_revendor_tasks) is untouched;
#     this is a targeted key deletion, not a rewrite, so tableau's ledger
#     structure and its load-bearing local_patches[0] tripwire survive.
echo "  4f. strip source_repo/source_commit/source_commit_date/source_file/vendor_arg from PROVENANCE.json"
python3 - <<'DERIVE_PY_EOF'
import glob, json

STRIP_KEYS = ("source_repo", "source_commit", "source_commit_date", "source_file", "vendor_arg")
n = 0
for path in sorted(glob.glob("plugins/*/skills/*/converter/PROVENANCE.json")):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    changed = False
    for k in STRIP_KEYS:
        if k in data:
            del data[k]
            changed = True
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            # ensure_ascii=False: tableau's ledger prose (local_patches summaries,
            # the _upstream_and_revendor_tasks block) uses em-dashes/curly quotes;
            # the default ensure_ascii=True would rewrite them to \uXXXX escapes,
            # corrupting the human-readable ledger and defeating the later text
            # scrub in 4g (which matches on the literal glyphs).
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.write("\n")
        n += 1
print(f"    stripped private lineage fields from {n} PROVENANCE.json file(s)")
DERIVE_PY_EOF

# --- 4g. tableau's local_patches ledger: neutralize the private-repo/internal
#     narrative (upstream_pr citations, internal integration-branch names,
#     bead id) while leaving the pinned local_patches[0] tripwire (commit
#     d8a049a) and the entry schema untouched — this is prose scrubbing, not
#     key deletion, so it runs as its own text pass over the same file.
echo "  4g. neutralize internal identifiers in tableau's converter provenance ledger"
TABLEAU_PROV=plugins/tableau-to-sigma/skills/tableau-to-sigma/converter/PROVENANCE.json
if [ -f "$TABLEAU_PROV" ]; then
python3 - "$TABLEAU_PROV" <<'DERIVE_PY_EOF'
import re, sys

path = sys.argv[1]
t = open(path, encoding="utf-8").read()

# PR citations against the private converter-source repo.
t = re.sub(r'(?:[\w.-]+/)?sigma-data-model-mcp#(\d+)', r'the upstream converter repo PR #\1', t)
t = re.sub(r'current (?:[\w.-]+/)?sigma-data-model-mcp main', 'current upstream converter repo main', t)
t = re.sub(r'a local (?:[\w.-]+/)?sigma-data-model-mcp checkout', 'a local converter-source checkout', t)
t = re.sub(r'(?:[\w.-]+/)?sigma-data-model-mcp', 'the upstream converter repo', t)

# The exact internal integration-merge attribution clause (identical across
# every wave-2 entry) — collapse it to a generic "later integration merge".
t = t.replace(
    "in the 2026-07-31 wave/2-integration merge of main 11f97abf "
    "(#574 re-vendor + #569 derivation ladder)",
    "in a later integration merge",
)
t = t.replace("wave/2-conv", "an internal integration branch")
t = t.replace("wave/2-objectmodel", "an internal integration branch")
t = t.replace("wave/2-integration", "an internal integration branch")
t = t.replace("wave-3 R3-1", "a later wave R3-1")

# Internal tracker id — the pinned entry schema/commit stays untouched; only
# the bead citation clause goes.
t = re.sub(r',?\s*bead\s+beads-sigma-[A-Za-z0-9_<>*]+', '', t)

open(path, "w", encoding="utf-8").write(t)
DERIVE_PY_EOF
  echo "    neutralized $TABLEAU_PROV"
fi

# --- 4h. every plugin.json ships MIT today; the repo license is Apache-2.0.
echo "  4h. plugin.json license MIT -> Apache-2.0"
perl -pi -e 's/"license": "MIT"/"license": "Apache-2.0"/' plugins/*/.claude-plugin/plugin.json

# --- 4i. README.md: de-link the hosted-converter-MCP mention (it pointed at
#     a private repo with no public equivalent — genericize instead of
#     leaving a 404), restate the License section for Apache 2.0, and drop
#     the now-dead docs/agent-entry.md / docs/README.md / structure-roadmap.md
#     links left dangling by step 2's deletions (across README/AGENTS/
#     CONTRIBUTING — de-link rather than guess a replacement target).
echo "  4i. README.md hosted-MCP link + License section; drop dead docs/ links"
python3 - <<'DERIVE_PY_EOF'
import re

if True:
    path = "README.md"
    t = open(path, encoding="utf-8").read()
    t = t.replace(
        "A [hosted converter MCP](https://github.com/twells89/sigma-data-model-mcp) is "
        "available as an **optional, opt-in fallback** that sends the source spec off-machine.",
        "A hosted converter MCP is available as an **optional, opt-in fallback** "
        "(set `SIGMA_MCP_CONVERTER_URL`) that sends the source spec off-machine.",
    )
    t = t.replace("## License\n\n[MIT](LICENSE).", "## License\n\n[Apache 2.0](LICENSE).")
    open(path, "w", encoding="utf-8").write(t)

# Dead-link cleanup: docs/agent-entry.md, docs/README.md, docs/structure-roadmap.md
# no longer exist post-step-2. De-link (drop the markdown hyperlink, keep the
# filename mention as plain text) rather than guessing a replacement target.
for path in ("README.md", "AGENTS.md", "CONTRIBUTING.md"):
    try:
        t = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        continue
    orig = t
    t = re.sub(
        r'\[`(docs/(?:agent-entry|README|structure-roadmap)\.md)`\]\(docs/(?:agent-entry|README|structure-roadmap)\.md\)',
        r'`\1`',
        t,
    )
    if t != orig:
        open(path, "w", encoding="utf-8").write(t)
DERIVE_PY_EOF

# --- 4j. CONTRIBUTING.md: the "claim work" step used the private beads
#     tracker (~/.beads-sigma, `bd update`/`bd ready`) — no public contributor
#     has that tool. Public equivalent: claim via a GitHub issue.
echo "  4j. CONTRIBUTING.md — claim-work step: beads -> GitHub issue"
python3 - <<'DERIVE_PY_EOF'
path = "CONTRIBUTING.md"
try:
    t = open(path, encoding="utf-8").read()
except FileNotFoundError:
    t = None
if t is not None:
    old = (
        "1. **Claim work in beads** (`~/.beads-sigma`) at **plugin granularity** before\n"
        "   touching it: `bd update <id> --status in_progress --owner <you>`. Other\n"
        "   sessions see it via `bd ready`. One bead ≈ one plugin ≈ one PR."
    )
    new = (
        "1. **Claim work up front** at **plugin granularity** — open (or comment on) a\n"
        "   GitHub issue for the plugin before touching it, so contributors don't collide.\n"
        "   One issue ≈ one plugin ≈ one PR."
    )
    if old in t:
        t = t.replace(old, new)
        open(path, "w", encoding="utf-8").write(t)
DERIVE_PY_EOF

# --- 4k. reintroduced phone-home telemetry (defense-in-depth). Telemetry was
#     removed from dev main permanently, but a NEW plugin can copy an old
#     template back in (metabase-to-sigma did: sigma_telemetry.py +
#     report-telemetry.mjs + a "send an anonymous usage ping" SKILL.md block).
#     The fleet-wide scrub only neutralizes the endpoint STRING, not the files
#     or the wiring — so delete the client/reporter/gate files fleet-wide (glob,
#     not a hardcoded list) and strip the consent+invocation block from any
#     SKILL.md/orchestrator that runs them. NOTE: refs/usage-telemetry.md docs
#     are about the SOURCE tool's usage analytics (Metabase view_count, Cognos
#     audit) — legitimate migration content, NOT our phone-home — and are kept.
echo "  4k. remove reintroduced phone-home telemetry (files + wiring)"
while IFS= read -r -d '' f; do
  rm -f "$f"; echo "    deleted telemetry file: $f"
done < <(find . -path ./.git -prune -o -type f \( \
      -name 'sigma_telemetry.py'    -o -name 'sigma_telemetry.mjs' \
   -o -name 'report-telemetry.py'   -o -name 'report-telemetry.mjs' -o -name 'report-telemetry.rb' \
   -o -name 'report_telemetry.py' \
   -o -name 'assert-telemetry-ran.rb' -o -name 'test-telemetry-gate.rb' \) -print0 2>/dev/null)

python3 - <<'DERIVE_PY_EOF'
import re, glob
TELE = re.compile(r'report[-_]telemetry|sigma_telemetry|report_migration')
CODEBLOCK = (r'```(?:bash|sh)\n(?:(?!```)[\s\S])*?'
             r'(?:report[-_]telemetry|sigma_telemetry|report_migration)'
             r'(?:(?!```)[\s\S])*?```\n')
n = 0
for path in glob.glob('plugins/**/*.md', recursive=True) + glob.glob('shared/**/*.md', recursive=True):
    try:
        t = open(path, encoding='utf-8').read()
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        continue
    if not TELE.search(t):
        continue
    orig = t
    # 1) consent block: an intro line telling the user about an anonymous usage
    #    ping, an optional blockquote + "If the user ..." lead-in, through the
    #    fenced block that runs the (now-deleted) reporter.
    t = re.sub(
        r'\n\*\*[^\n]*(?:tell the user[^\n]*conversation|usage ping)[^\n]*\*\*\n\n'
        r'(?:>[^\n]*\n\n)?(?:If the user[^\n]*\n\n)?' + CODEBLOCK,
        '\n', t)
    # 2) backstop: any remaining fenced block that invokes the reporter.
    t = re.sub(CODEBLOCK, '', t)
    # 3) drop dangling links/mentions of the telemetry repo left in prose.
    t = re.sub(r'\s*\(?\[?[^\n\]]*sigma-migration-telemetry[^\n)]*\)?\]?', '', t)
    if t != orig:
        open(path, 'w', encoding='utf-8').write(t)
        print('    scrubbed telemetry wiring: ' + path)
        n += 1
print('    telemetry-wiring scrub touched %d file(s)' % n)
DERIVE_PY_EOF

# ─────────────────────────────────────────────────────────────────────────
# STEP 5 — fleet-wide identity + internal-identifier scrub
# ─────────────────────────────────────────────────────────────────────────
# Everything bespoke-fixed in step 4 already has zero occurrences of every
# trigger pattern below, so re-running these ordered substitutions across the
# whole tree is a safe no-op there — it only changes the ~50-60 prose/refs/
# comment files step 4 didn't touch individually (SKILL.md, refs/*.md,
# migrate-*.{rb,py}, corpus/*, etc).
echo "[5/6] fleet-wide identity + internal-identifier scrub"

# Plain `grep` (portable, always present) — not `rg`: this script must run
# as a bare subprocess (a real user's shell, CI), where a bundled/wrapped rg
# is not guaranteed to be resolvable, only POSIX grep is. Scoped to the
# already-materialized <dest> tree (not the .git object store), so it is
# fast regardless.
SCRUB_FILES=()
while IFS= read -r -d '' f; do SCRUB_FILES+=("$f"); done < <(
  find . -path ./.git -prune -o -type f -print0 2>/dev/null \
    | xargs -0 grep -lE \
        -e 'sigma-data-model-mcp' -e 'onrender\.com' -e 'beads-sigma-' \
        -e '\bbd ready\b' -e '\.beads-sigma\b' -e 'wave/2-' -e 'wave-3 R3-1' \
        -e 'twells89' -e 'Thomas Wells' -e '@ycp\.edu' -e '/Users/tjwells' \
        2>/dev/null \
    | tr '\n' '\0'
)

echo "  ${#SCRUB_FILES[@]} file(s) still match a prohibited pattern after bespoke fixes"

if [ "${#SCRUB_FILES[@]}" -gt 0 ]; then
  python3 - "${SCRUB_FILES[@]}" <<'DERIVE_PY_EOF'
import re, sys

# Ordered rules — each is (compiled pattern, replacement). Order matters:
# more specific / longer patterns must run before their bare fallbacks so a
# fallback doesn't leave a mangled partial match (e.g. an ".onrender.com"
# domain must be fully consumed before the bare "sigma-data-model-mcp"
# fallback would otherwise chew off just the repo-name portion).
RULES = [
    (re.compile(r'[A-Za-z0-9_.-]*sigma-data-model-mcp\.onrender\.com'),
     "the hosted-converter endpoint (SIGMA_MCP_CONVERTER_URL)"),
    (re.compile(r'(?:[\w.-]+/)?sigma-data-model-mcp#(\d+)'),
     r'the upstream converter repo PR #\1'),
    (re.compile(r'current (?:[\w.-]+/)?sigma-data-model-mcp main'),
     'current upstream converter repo main'),
    (re.compile(r'a local (?:[\w.-]+/)?sigma-data-model-mcp checkout'),
     'a local converter-source checkout'),
    (re.compile(r'~/(?:Desktop/)?(?:[\w.-]+/)?sigma-data-model-mcp'),
     '~/converter-source'),
    # Bare fallback — token-only (NO optional `[\w.-]+/` prefix). The prefix
    # form wrongly ate a path/var segment: `$converter/sigma-data-model-mcp/build`
    # (a shell path in corpus/converter-default-test.sh) collapsed to the invalid
    # `$converter-source/build` (bash then parsed `${converter-source}`). GitHub
    # `owner/repo` refs still scrub cleanly: `owner/` is left intact and any
    # prohibited owner (twells89) is neutralized by its own rule below, yielding
    # e.g. `sigmacomputing/converter-source` rather than a broken collapse.
    (re.compile(r'sigma-data-model-mcp'),
     'converter-source'),
    (re.compile(r'[A-Za-z0-9_.-]*\.onrender\.com'),
     'the hosted-converter endpoint'),
    (re.compile(r',?\s*\bbead\s+beads-sigma-[A-Za-z0-9_<>*]+'), ''),
    (re.compile(r'beads-sigma-[A-Za-z0-9_<>*]*'), '[bead]'),
    (re.compile(r'\bbd ready\b'), 'the shared tracker'),
    (re.compile(r'\.beads-sigma\b'), '.internal-tracker'),
    (re.compile(re.escape(
        "in the 2026-07-31 wave/2-integration merge of main 11f97abf "
        "(#574 re-vendor + #569 derivation ladder)")),
     'in a later integration merge'),
    (re.compile(r'wave/2-conv\b'), 'an internal integration branch'),
    (re.compile(r'wave/2-objectmodel\b'), 'an internal integration branch'),
    (re.compile(r'wave/2-integration\b'), 'an internal integration branch'),
    (re.compile(r'wave-3 R3-1'), 'a later wave R3-1'),
    (re.compile(r'\btwells89\b'), 'sigmacomputing'),
    (re.compile(r'Thomas Wells'), 'Sigma Computing'),
    (re.compile(r'[A-Za-z0-9._%+-]+@ycp\.edu'), 'oss-maintainers@sigmacomputing.com'),
    (re.compile(re.escape('/Users/tjwells')), '~'),
]

n = 0
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8") as f:
            t = f.read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    orig = t
    for pattern, repl in RULES:
        t = pattern.sub(repl, t)
    if t != orig:
        with open(path, "w", encoding="utf-8") as f:
            f.write(t)
        n += 1
print(f"  scrubbed {n} file(s)")
DERIVE_PY_EOF
fi

# The fleet-wide scrub above edits comments inside cognos's in-skill
# converter/*.ts sources too (that's where its beads-sigma- citations live).
# cognos's OWN freshness gate (tools/check-cognos-bundle.rb) pins those
# sources' sha256 into PROVENANCE.json; refresh the pin so it matches the
# now-scrubbed sources instead of tripping its own staleness gate.
if [ -f tools/check-cognos-bundle.rb ] && \
   [ -f plugins/cognos-to-sigma/skills/cognos-to-sigma/converter/cli.ts ]; then
  echo "  refresh cognos converter/*.ts source_sha256 pin (post-scrub)"
  ruby tools/check-cognos-bundle.rb --write || echo "  WARN: could not refresh cognos source_sha256 — review before shipping"
fi

# The fleet-wide scrub above also rewrites strings *inside* the tableau converter
# bundle (tableau.mjs carries `sigma-data-model-mcp` + a beads- id in comments).
# refs/functions.json + refs/coverage-manifest.json are DERIVED from that bundle
# by gen-translation-table.mjs, and the W2.13 determinism gate
# (scripts/test-translation-table.rb) byte-diffs them against a fresh
# regeneration — so a scrubbed bundle with stale derived tables fails CI.
# Regenerate them in place from the now-scrubbed bundle. Idempotent: if the
# bundle was untouched the regeneration is byte-identical (a no-op). node is the
# same runtime CI uses for this gate; skip with a warning if it is unavailable
# (the gate itself SKIPs without node, so a public contributor is not blocked).
TAB_SKILL=plugins/tableau-to-sigma/skills/tableau-to-sigma
TAB_GEN="$TAB_SKILL/scripts/dev/gen-translation-table.mjs"
if [ -f "$TAB_GEN" ] && [ -f "$TAB_SKILL/converter/tableau.mjs" ]; then
  NODE_BIN="${NODE_BIN:-$(command -v node 2>/dev/null || true)}"
  if [ -n "$NODE_BIN" ] && [ -x "$NODE_BIN" ]; then
    echo "  regenerate tableau refs/functions.json + coverage-manifest.json from scrubbed bundle (W2.13 determinism)"
    "$NODE_BIN" "$TAB_GEN" || echo "  WARN: gen-translation-table.mjs failed — refs/ tables may be stale vs the scrubbed bundle; review before shipping"
  else
    echo "  WARN: node unavailable — skipped tableau determinism-table regen; the scrubbed bundle may leave refs/functions.json stale (regenerate with: node $TAB_GEN)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────
# STEP 6 — re-sync canonical shared/ copies if any were touched above
# ─────────────────────────────────────────────────────────────────────────
echo "[6/6] ruby tools/sync-shared.rb"
if [ -f tools/sync-shared.rb ]; then
  ruby tools/sync-shared.rb || echo "  WARN: sync-shared.rb reported an issue — review before shipping"
else
  echo "  WARN: tools/sync-shared.rb not found in dest — skipping"
fi

echo "=== derive-public.sh done: $DEST is public-safe (pending the acceptance gate) ==="
