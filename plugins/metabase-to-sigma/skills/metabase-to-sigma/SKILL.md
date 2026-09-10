---
name: metabase-to-sigma
description: >-
  Migrate Metabase content to Sigma. Use when the user has Metabase questions,
  models, or dashboards and wants to recreate them in Sigma. Converts MBQL
  cards/models (+ database metadata) → Sigma data model and dashboards → Sigma
  workbooks, translating MBQL expressions/aggregations and flagging constructs
  with no clean Sigma analog. Discovery via the Metabase REST API (API key or
  session token) — works on open-source and Pro/EE alike.
user-invocable: true
---

# Metabase → Sigma migration

Convert Metabase **models + questions** into a Sigma **data model**, then convert the
**dashboards** that sit on them into matching Sigma **workbooks**. Translate what maps
cleanly; **flag what doesn't** (cum-sum/offset windows, saved segment refs,
progress viz, click behaviors) instead of emitting wrong logic.

> **Status: live-validated end to end.** Extraction was proven against a live
> 7k-card / 1.5k-dashboard Metabase Cloud estate (v1.61.4 — 100% pMBQL); the
> Sigma build path was validated with exact query parity, including models,
> nested questions, combo charts, controls, and exact-grid layout
> (`refs/design-notes.md` §9–§10d). The released wrapped/flat workbook code
> representation is covered by offline tests and corpus goldens; repeat the
> live POST/readback/PNG gate before extending the historical live claim to
> that payload.

> **This skill is customizable in plain language.** Read
> `~/.metabase-to-sigma/preferences.md` if it exists at the start of every run,
> restate the active preferences briefly, and honor them throughout (they may
> override any default EXCEPT the verification gates). When the user corrects an
> output or states a preference mid-run, OFFER to persist it — see
> `refs/customization.md` for the three tiers (preferences / learned formula
> rules / converter changes).

<!-- mandatory-pre-read -->
> Before a run, read `refs/design-notes.md`, `refs/rest-api.md`, and
> `refs/control-parity.md`.
<!-- /mandatory-pre-read -->
> Load `refs/mbql-shapes.md`, `refs/expression-dsl.md`, or
> `refs/template-tags.md` only when that phase needs the detail. For canonical
> Sigma shapes, defer to `sigma-data-models` and `sigma-workbooks`.

---

## Prerequisites

- **Metabase REST access** — an **API key** (v49+: Admin → Settings → Authentication →
  API keys; preferred, durable) or a username/password session. Capture either with
  `scripts/get-metabase-session.sh`. Open-source Metabase is fully sufficient — no
  Pro/EE features required (serialization export is EE-only; this skill doesn't use it).
- **Sigma** API credentials in `~/.sigma-migration/env` (or environment
  variables), minted with `scripts/get-token.sh`.
- **The same warehouse on both sides.** Sigma reads the warehouse live; parity only
  means something when the Sigma connection reaches the database Metabase queries.
  (Metabase's bundled H2 Sample Database is NOT reachable from Sigma — pick content
  on a real warehouse, or land the data first.)
- **Know your warehouse dialect.** The converter auto-detects it from the Sigma connection
  (`--connection <id>` triggers a `GET /v2/connections/<id>` lookup), or pass `--warehouse`
  explicitly: `bigquery` | `snowflake` | `databricks` | `redshift` | `postgres` | `athena`.
  Required for correct array-aggregation rewrites (BigQuery `ARRAY_AGG` → `array_to_string`,
  Snowflake → `LISTAGG`, Databricks `collect_list` → `array_join`, etc.). Without it,
  native SQL cards with array aggregations will render as blank cells in Sigma.
- **Node** for the converter (`converter/`: `npm ci` once).

---

## Phase 0 — Discover (Metabase REST)

```bash
export MB_BASE="https://<host>"        # + MB_KEY, or MB_USER/MB_PASS
eval "$(scripts/get-metabase-session.sh)"
scripts/metabase-discover.sh databases                  # find the warehouse connection
scripts/metabase-discover.sh metadata 2 > metadata.json # FIELD IDS — required by the converter
scripts/metabase-discover.sh collections                # folder tree
scripts/metabase-discover.sh items 5                    # cards/models/dashboards in a collection
scripts/metabase-discover.sh card 123      > orders-model.card.json
scripts/metabase-discover.sh dashboard 9   > exec.dashboard.json
```

- **Always fetch `metadata <dbId>` first** — MBQL references columns by integer field
  id; without the metadata map the converter falls back to per-card `result_metadata`
  names (lossy, warned).
- Models (`type: "model"`, or `dataset: true` pre-v50) are the semantic layer — fetch
  them even when no dashboard uses them directly; questions stack on them via
  `source-table: "card__N"`.
- For estate-wide inventory + a migration shortlist, run the `metabase-assessment`
  skill first — its `specs/` directory feeds this skill directly.

## Phase 1 — Convert models/cards → Sigma data model

```bash
cd converter && npm ci
node --import tsx/esm cli.ts ../bundle.json --metadata ../metadata.json \
  --connection <SIGMA_CONN> --database <DB> --schema <SCHEMA>
```

`bundle.json` is `{ "cards": [ <card JSONs> ] }` (or pass a single card file). Emits
the Sigma data-model JSON on stdout; stats + warnings on stderr. Read the warnings
aloud to the user — they are the parts that need manual authoring (cum-sum/offset
windows, segment/metric refs to inline, binned breakouts, field-filter SQL tags).

## Phase 1.5 — Reuse an existing DM? (avoid sprawl)

Before POSTing a NEW data model in Phase 2, check whether an existing Sigma DM already
covers the same warehouse tables (don't add a 4th near-identical DM for the same schema):

```bash
python3 scripts/metabase-dm-signature.py --dm-spec dm.json --out dm-signature.json
eval "$(scripts/get-token.sh)"
ruby scripts/find-or-pick-dm.rb --workbook-signature dm-signature.json \
  --out dm-match.json --auto-pick           # exit 0 = candidate ≥ min-score
```

- **Score ≥ 0.6** → **ASK the user** reuse-vs-new: surface the candidate name, matched
  cols (N/M), and the inherited-extras warning. If they reuse, run a **shape preflight**
  (read the candidate spec back; every column the dashboard references must resolve with
  no `type=error`), then **skip Phase 2** and run Phase 3 against the matched
  `recommended_dm_id`.
- **Score < 0.6** → POST new (Phase 2) and TELL the user no reusable DM was found.

## Phase 1.9 — Choose where to build (ask first when no destination given)

Don't pick the destination for the user. If they didn't supply a `--folder <id>`, ASK before the Phase 2 POST:

1. `node scripts/pick-destination.mjs list` → `{ workspaces, folders (editable, with parentName), myDocuments }`
2. Let the user pick ONE: a **workspace** (its `id` lands content in the workspace root), an existing **folder**, **My Documents** (when non-null — null for service tokens), or **create a new folder**: `node scripts/pick-destination.mjs create --name "<name>" [--parent <workspace-or-folder-id>]`
3. Pass the chosen id as `--folder <id>` to every `post-and-readback.mjs` call (DM + workbook). `folderId` accepts a workspace id or a folder id.

If a destination is already supplied, honor it silently — don't ask.

## Phase 2 — POST the data model + read back ids (hard gate)

```bash
eval "$(scripts/get-token.sh)"                 # SIGMA_BASE_URL + SIGMA_API_TOKEN
node scripts/post-and-readback.mjs --type datamodel --spec dm.json \
  --folder <folderId> --out dm-map.json
```

POSTs to `/v2/dataModels/spec`, reads the spec back, and **fails on any `type=error`
column** (a spec can POST 200 yet have formulas that don't resolve at query time — the
readback scan catches it, derived view included). `dm-map.json` carries the real
`dataModelId` + element ids (Sigma reassigns them on POST). Do not proceed past a
non-zero exit.

## Phase 3 — Convert the dashboard → Sigma workbook, wired to the DM

```bash
node --import tsx/esm cli.ts ../exec.dashboard.json --metadata ../metadata.json --dm <dataModelId> \
  --layout-out hints.json --control-scope-out control-scope.json > wb.json
node scripts/remap-wb-to-dm-ids.mjs --wb wb.json --dm-id <dataModelId> --dm-spec dm.json --out wb.remapped.json
ruby scripts/lib/preflight_lint.rb wb.remapped.json   # MANDATORY — fix all violations before POST
node scripts/post-and-readback.mjs --type workbook --spec wb.remapped.json --folder <folderId>
node scripts/apply-layout.mjs --workbook <workbookId> --hints hints.json
```

The workbook converter emits the released code representation: outer metadata
plus `document`, flat `document.elements`, metadata-only pages, and a complete
canonical `<Page>`/`<Element>` layout. The create write is therefore fully
placed. `apply-layout.mjs` GETs the current document and performs the final
layout-safe full-document PUT after any repair; never send a partial PUT.

**Preflight (mandatory):** `ruby scripts/lib/preflight_lint.rb wb.remapped.json` exits 1 with a precise message on the two migration-killer bugs — a `table` with aggregate columns + dimensions but **no `groupings`** (renders raw detail rows instead of an aggregated summary), and a malformed `control` (missing `id`/`controlId`/`controlType` or the flat list value fields `source`/`mode`/`selectionMode`/`values`). Fix every violation first; **never conclude a feature is "unsupported" from an `Invalid kind` error** — it means the inner fields are wrong. Verified shapes: `sigma-workbooks` `controls.md`/`tables.md`.

Each dashcard becomes the matching Sigma element sourced from the migrated DM element
(KPI/bar/line/area/pie/combo/scatter/table/pivot/map/funnel/gauge/waterfall/sankey;
text cards → text elements; progress → a flagged table). The converter emits each element's
`source.elementId` as the source card/table **name** (a placeholder) —
`remap-wb-to-dm-ids.mjs` rewrites those to real ids from Phase 2's readback (native
cards all read back "Custom SQL", so it falls back to column-set fingerprints and
repairs every formula ref against the live DM columns).

**Controls** (full contract: `refs/control-parity.md`). Metabase dashboard parameters
declare their card targets explicitly (`parameter_mappings`) — the converter wires
each mapping and emits the **`control-scope.json` sidecar** (`--control-scope-out`,
keep it next to the workbook spec: post-and-readback and gate 7 pick it up there):

- **scalar params** (string/number equality, incl. static-list → segmented grain
  switchers with values + defaults) → hidden boolean `[Col] = [slug]` + element filter;
- **range params** (`date/*` → date-range with flat `mode: "between"`,
  `number/between` → number-range) → REAL control `filters` targets, re-rooted
  through a hidden **base table** on a trailing `Data` page (control targets may
  only point at table elements; list/scalar targets on datetime columns are
  silently stripped — both verified cross-plugin gotchas);
- **variable-tag params** (drive `{{tags}}` in card SQL) → `--dm-spec` emits
  control→DM-parameter bindings; if the org rejects them, post-and-readback
  **drops those controls** (decorative controls are exactly what gate 7 blocks —
  the DM `{{tag}}` controls still carry the filter; sync a workbook control in
  the UI when the org enables DM-parameter targeting, or pass
  `--keep-rejected-bindings` to keep them and sync by hand);
- **unmapped params + unwirable field-filters** → NO control, loud warning
  (flag, never furniture).

post-and-readback (workbook) finishes by running the SHARED layout + control lints
on the readback spec — fix violations (repair recipes in `refs/control-parity.md`)
or annotate genuine narrow intent in `control-scope.json` before moving on.
Metabase's 24-col dashcard grid maps 1:1 onto Sigma's authoritative layout.
`apply-layout.mjs --hints` confirms the exact geometry survives readback and
re-runs the layout lint.

## Phase 4 — Verify parity + the seven gates (hard gate — the real proof)

```bash
node scripts/assert-parity.mjs --plan --type workbook --id <workbookId>   # emits per-element SQL
# run each through Sigma MCP or the Sigma query API; save totals to actual.json
node scripts/assert-parity.mjs --check --actual actual.json --expected metabase.json --tol 0.01 \
  --workdir <workdir>  --census '{"zones_total":N,"charts_built":M,"zones_unmatched":0,"unmatched_zone_names":[]}'
ruby scripts/assert-phase6-ran.rb --workdir <workdir> --workbook-id <workbookId>   # gates 1–7
```

**Expected values must be LIVE**: re-run the Metabase cards (`POST /api/card/{id}/query`)
at verification time — a baseline captured earlier drifts as warehouse rows land, and
the diff reads as a phantom parity failure.

`assert-parity --check` writes the `parity-final.json` sentinel into `--workdir`
(post-and-readback already wrote `wb-ids.json` + `posted-workbooks.jsonl` there);
derive the `--census` counts from the converter stats (dashcards converted vs
elements built — name any legitimately unbuildable zones). Then
**`assert-phase6-ran.rb` is the GREEN gate**: parity ran (1), no orphan workbooks
(2), no error-typed columns (3), layout applied (4), tile census (5), layout lint
(6), control lint honoring `control-scope.json` (7). Exit 0 or it isn't done.

**Flip test** (runtime control evidence — REQUIRED after any hand-repaired wiring,
recommended always; see `refs/control-parity.md` for why MCP cannot do this):

```bash
ruby scripts/probe-controls.rb --workbook-id <workbookId> --check-out-of-closure
# date-range / number-range controls need an explicit flip value:
#   --value <controlId>='min:2026-01-01,max:2026-03-31'
```

A mapped card's export must CHANGE under `parameters:{<controlId>: <value>}`; an
unmapped same-page card must NOT (no leak).

**Visual gate** (layout, control widgets, chart marks — things data queries can't see):
export each page as PNG and LOOK at it:

```bash
# POST /v2/workbooks/{id}/export {"pageId":"<pageId>","format":{"type":"png","pixelWidth":1400}}
# → {queryId} → poll GET /v2/query/{queryId}/download until 200 → PNG
```

Check: controls render as the right widget (segmented grain switcher, defaults filled),
elements sit at the Metabase grid positions (not stacked), charts show marks (an empty
chart with a title = a column/axis problem the readback scan can miss).

A migration is **GREEN only when** (a) `assert-parity --check` passes, (b)
`assert-phase6-ran.rb` exits 0 (all seven gates, control lint included), AND (c) the
workbook came back with a clean layout (`apply-layout.mjs` reported
`layoutOnReadback: true`) — never on a 200 POST alone. `metabase.json` = the numbers
from the Metabase cards (run each card via `POST /api/card/{id}/query` — the one
non-GET this skill may use, read-only in effect — or read them off the dashboard).
Mind caching: Metabase serves cached results by default; Sigma reads live. A delta
that matches rows landed since the cache filled is freshness, not a failure.

---

## What converts, what's flagged (never faked)

Converted coverage includes pMBQL normalization, MBQL joins/expressions/
aggregations/breakouts, FK relationships, nested questions, compatible native
SQL remodeling, Custom SQL fallback, template-tag controls, formats, and
dashboard tabs/layout. Native workbook kinds include table, pivot, KPI,
bar/line/area/combo/scatter/pie, maps, funnel, gauge, waterfall, and sankey.
Every shelf/channel pointer uses the current `columnId` contract.

Flagged coverage includes cumulative/offset windows, saved segment/legacy
metric references, binning, multi-stage queries, click behaviors, smart-scalar
comparisons, object detail views, gradient conditional formats, and Metabase
progress displays. The converter preserves reviewable data and emits a loud
warning rather than inventing semantics. Load `refs/expression-dsl.md`,
`refs/template-tags.md`, and `refs/design-notes.md` for the detailed contract.

## Security: Row-Level Security (sandboxing)

Row security is **never silently dropped and never silently ported** — and it is handled
by the **skill**, not baked into the converted model. Metabase **sandboxing is Pro/EE
only** (`GET /api/mt/gtap` lists sandboxes; group-based). The converter only **detects
and reports** (`security.json` + a loud `SECURITY:` line) when sandbox data is provided;
on OSS there is nothing to detect — but **ask the customer anyway** (RLS is sometimes
faked with per-group collections + duplicated filtered questions; inventory those by hand).

**Flow (only when security was detected or found manually — zero overhead otherwise):**
1. Convert + post the DM. Capture `dataModelId` + `security.json`
   (manual entries use the same shape: `[{ "type": "row-filter", "name": …, "expression": …, "groups": […] }]`).
2. **Gate (opt-in/out, default Port).** Plain-English summary of each rule + proposed
   Sigma user-attribute mapping → **Port** / **Customize** / **Skip**. Reuse existing
   Sigma user attributes/teams before creating new ones.
3. Provision + apply with the shared engine:
   ```bash
   eval "$(scripts/get-token.sh)"
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <id>            # plan only
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <id> --provision --apply
   ```
4. Assign per-user attribute values from Metabase group membership
   (`GET /api/permissions/group/{id}` lists members with emails — reconcile to Sigma members).

**Skip is loud:** opting out leaves the migrated model showing ALL rows to everyone. Confirm first.

## Gap scout — close a flagged expression

For a flagged construct you want to actually resolve (an offset window, a segment ref,
an unmapped op), spawn the **gap-scout subagent** (`scripts/gap-scout.md`): it proposes
a Sigma formula, validates it against the customer's live Sigma via
`scripts/scout-validate-and-persist.mjs`, and on success persists the rule to
`~/.metabase-to-sigma/learned-rules.json` — which the converter CLI auto-applies
*before* the built-in translator on the next run. If no formula validates, it returns
an opt-in `scripts/escalate-gap.py` command to file a tracking issue (ask first).

## Customizing the skill (your org, your rules)

Everything above is the default behavior — not the required one. Tell Claude what
you want different, in plain language, and ask it to remember:

- **Run preferences** (naming, folders, which tabs/cards, control widget choices,
  layout taste) → saved to `~/.metabase-to-sigma/preferences.md`, read at the start
  of every run.
- **Formula translations** specific to your SQL idioms → learned rules
  (`~/.metabase-to-sigma/learned-rules.json`), validated live before persisting.
- **Structural behavior** (chart mappings, DM shape) → converter changes with
  fixture tests; share fixes back via `scripts/escalate-gap.py` or a PR.

Both home-dir files survive `git pull`. Full guide + worked examples:
`refs/customization.md`.
