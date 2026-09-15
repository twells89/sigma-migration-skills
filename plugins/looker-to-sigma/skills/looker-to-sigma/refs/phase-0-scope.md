<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. Phase 0a/0b — destination, credentials-free readiness audit, estate scoping. -->

# Phase 0 — destination, readiness audit, estate scoping

## Phase 0a — Choose where to build (ask first when no destination given)
Don't silently land the migrated data model + workbook in an auto-picked folder.
If the user didn't supply a destination (no `--folder <id>` and no `SIGMA_FOLDER_ID`), ASK before building:

1. `python3 scripts/pick_destination.py list` → `{ workspaces, folders (editable, with parentName), myDocuments }`
2. Let the user pick ONE: a **workspace** (its `id` lands content in the workspace root),
   an existing **folder**, **My Documents** (when non-null — null for service tokens), or
   **create a new folder**: `python3 scripts/pick_destination.py create --name "<name>" [--parent <workspace-or-folder-id>]`
3. Pass the chosen id as `--folder <id>`. `folderId` accepts a workspace id or a folder id.

If a destination is already supplied, honor it silently — don't ask.

---

## Credentials-free readiness audit (mandatory, before migration)

Run the local audit against the complete LookML checkout before authenticating
to Sigma or POSTing anything. `migrate-looker.py` runs it automatically after
source parsing and before credential loading; it can also run standalone:

```bash
node scripts/audit-lookml-readiness.mjs \
  --lookml-dir /path/to/lookml --explore <explore> \
  --out /tmp/<name>/lookml-readiness.json \
  --field-census /tmp/<name>/lookml-field-census.json \
  --formula-mapping /tmp/<name>/formula-mapping.json
```

This uses the vendored converter and needs no Looker or Sigma credentials.
`lookml-readiness.json` records scoped files, explores, joins, derived tables,
extends, and classified warnings; `lookml-field-census.json` accounts for every
dimension, expanded dimension-group timeframe, and measure as exact,
approximate, or omitted; `formula-mapping.json` pairs source and Sigma formulas
with dependency depth and unresolved references. Exit 0 means clean/caveat,
exit 1 means blocked, and exit 2 means the audit itself failed. A blocked audit
is a hard pre-POST stop. Use `refs/open-items.md` for the durable gap/evidence
status; keep run-specific findings in the workdir.

The field/formula censuses do not replace final object accounting. Maintain
`<workdir>/source-object-census.json` for every in-scope model, explore, view,
dashboard/Look, tile, filter, and field/formula finding. Each must end as
`migrated`, `approximated`, `needs-review`, `skipped`, or `not-applicable`,
with evidence.

---

## Phase 0b — Assess the Looker estate

### 0b.1 — Is the input actually COMPLETE? (run this FIRST, always)

```bash
python3 scripts/check_input_completeness.py <lookml_dir>
```

**Do this before you form any opinion about convertibility.** A partial LookML export
converts "successfully" and looks catastrophic: every view an explore joins but that was not
exported becomes a `LOOKER_SCRATCH.<VIEW>` placeholder with its own loud warning, so a
project missing most of its views emits hundreds of warnings and reads as *"this tool cannot
convert our model."*

That is a **missing-input problem, not a capability problem**, and the two must never be
confused — one is fixed by asking for the rest of the repo, the other by engineering work.
Reporting the first as the second has already cost us credibility on a live migration.

The script is silent on a complete project (one all-clear line, exit 0) and never blocks.
When the input is partial it reports, in numbers: physical views referenced vs. supplied
(`from:` aliasing resolved first, so N aliases of one view count once), joins wirable vs.
not, whether a `.model.lkml` is present at all, and whether the target explore is
`extension: required` — an ABSTRACT base that nobody can run directly, whose concrete
extending explores live elsewhere.

If the input is incomplete, either ask for the complete project (ideally a git clone — all
views, the `.model.lkml`, and the manifest) or convert the resolvable subset **deliberately,
as a scoped slice**, and say so in the handoff.

### 0b.2 — Scope the estate

**Read `refs/lookml-remodeling.md` before scoping any project above a few dozen views.** A mature LookML model encodes Looker's constraints as much as the business's semantics, so a 1:1 port imports them. It covers scoping by System Activity usage, the five shapes that should change on the way across (role-playing explosion, parameterized calendar UDFs, Liquid table switching, security threaded through `sql_on`, M:M bridges), how to read `sql_distinct_key` as a map of where fan-out actually lives, and what not to promise about the semantic-aggregates beta.

Inventory models/explores/dashboards, score complexity, and rank a migration shortlist.
There is no `looker-assessment` sibling skill today (unlike Tableau) — until there is, do
this from the Looker API in Phase 1, and use **Looker System Activity** (`i__looker`) field-
and dashboard-usage history to scope by what is actually queried rather than by what exists.
On a large estate that single input is usually the difference between porting a few hundred
fields and porting a few thousand.
