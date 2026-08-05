# Sigma OpenAPI Spec Update (Aug 2026) — sigma-skills + sigma-migration-skills Implementation Plan

> ## ✅ COMPLETE (closed out 2026-08-05)
>
> Committed as the record of this wave. **All 12 tasks are done** — verified by inspection on 2026-08-05, not by trusting the checkboxes below (which were never ticked; the work landed through PRs instead):
>
> | Task | Landed |
> |---|---|
> | 2–6 (elements, charts, controls, sources, tables) | sigma-skills #28/#29 → vendored #615/#617 |
> | 7 (`/v2/workbooks/spec/verify` in `wb-rep.rb`) | present, `scripts/test-verify.rb` passes 7/7 |
> | 8 (re-vendor) | #615/#617, and again in #627 |
> | 9 (`columnSecurityRules` CRUD) | in `sigma-data-models/reference/column-level-security.md` |
> | 10 (`api-connectors`/`api-credentials`/`dbtArtifacts`) | in `sigma-data-models/reference/sources.md` |
> | 11 (plugin `devUrl`) | #615 |
> | 12 (`sigma-materialization-advisor`) | `632941c` — "Retract false 'no create-schedule endpoint' claim, add schedule CRUD" |
> | **1 (dead spec-download URL)** | **only real gap; fixed in sigma-skills #30 → vendored #627** |
>
> ### Why Task 1 outlived the rest — worth reading before re-deriving it
>
> Task 1 was attempted via sigma-skills #29, which pivoted the guidance to "lead with stable per-endpoint reference pages." That reads like a fix and isn't, for two reasons found on 2026-08-05:
>
> 1. **The per-endpoint pages don't cover workbook authoring.** The split `sigma-rest-api.json` has **zero** paths matching `spec` — no `/v2/workbooks/spec`, no `/v2/workbooks/spec/verify`, no `/v2/workbooks/{id}/spec`. The compiled asset is the *only* spec-side source for the workbook spec endpoint, so it can't be demoted to a "convenience."
> 2. **The 403 was misdiagnosed.** This plan (and the skill) attributed it to a rotated Fern content hash and prescribed "rediscover the current link." The hash never changed. The asset now requires **AWS presigned query params**, so no amount of hash-chasing helps — and the prescribed fallback, `help.sigmacomputing.com/openapi.json`, is now an HTML page that doesn't link the asset at all. `wb-rep.rb capabilities` was broken outright the whole time.
>
> Fix: discover the presigned URL at runtime from the docs site HTML (`X-Amz-Expires=604800`, so never pin one). See #30.
>
> **Consequence for this plan's own citation:** the "Source of new-spec evidence throughout this plan" URL in *Global Constraints* below is the bare S3 path, which **403s**. Anything re-checking this plan's evidence must use the runtime-discovery procedure in `sigma-workbooks/SKILL.md` → *Fetching the compiled asset*.
>
> ### Scope this plan did not cover
>
> #30/#627 also documented surface this plan never enumerated: 9 missing action effects (12 exist, not 3), page `type: drawer`, the `page-break` element, agent `greeting`/`requiresApproval` and all four `tools[]` kinds, and — the correctness headline — that **repeated containers are UI-only and silently dropped by GET-spec**, leaving formulas that reference elements declared nowhere. A captured spec containing them is not a faithful copy.
>
> Its "two confirmed non-findings — do not re-investigate" note (the `embed` element and `themeOverrides`) was re-confirmed still accurate.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `sigma-workbooks`, `sigma-data-models`, `sigma-plugin-authoring` (the Sigma authoring/converter-dependency skills, in `sigma-skills`/`sigma-migration-skills`), and the separate public `sigma-materialization-advisor` repo up to date with the additions in Sigma's Aug 2026 public OpenAPI spec, and fix one currently-broken doc reference (dead spec-download URL) that predates this update.

**Architecture:** This is a documentation/reference-content update, not application code. `sigma-skills` (`~/sigma-skills`) is the single upstream source of truth for `sigma-workbooks`, `sigma-data-models`, and `custom-sql-to-data-model`; `sigma-migration-skills` vendors copies of those three under `plugins/sigma-authoring/skills/*` via a scripted re-vendor (`plugins/sigma-authoring/SYNC.md`) — **never hand-edit the vendored copies**, edit upstream and re-vendor. `sigma-plugin-authoring` has no upstream equivalent and is edited directly in `sigma-migration-skills`. "Tests" for this kind of change are: (a) the repo's own convention of citing exact OpenAPI evidence (field/kind names, required-vs-optional) rather than prose guesses, and (b) **genuine live end-to-end verification, not schema-only dry-run** — a `POST /v2/workbooks/spec/verify` pass proves the JSON is well-formed, it does NOT prove the element renders or behaves as documented. **The bar for every task that documents a workbook-spec shape (elements, charts, controls, sources) is: create a real test workbook containing the new shape, `GET` it back to confirm the shape round-trips, and where feasible render/screenshot it to visually confirm it looks like what the doc describes — matching this repo's own existing convention of "live-verified <date>" stamps throughout its docs.** `/v2/workbooks/spec/verify` is a useful fast first pass (catches typos/schema errors before spending a real create call) but is never the last word — always follow it with an actual create+readback when the org/workspace permits. Clean up test workbooks after (delete or leave in an obviously-named scratch folder — don't litter the org with unnamed test objects). If a feature is gated off in the available test org/workspace (confirmed via a real 403/entitlement error, not assumed), document that fact plainly rather than skipping verification silently.

**Tech Stack:** Markdown reference docs, Ruby (`wb-rep.rb`, `register-plugin.rb`), `jq`, Sigma REST API (Beta endpoints noted throughout).

## Global Constraints

- **Edit upstream, re-vendor down.** `sigma-workbooks`, `sigma-data-models`, `custom-sql-to-data-model` content changes land in `~/sigma-skills` first; `~/sigma-migration-skills/plugins/sigma-authoring/skills/{sigma-workbooks,sigma-data-models,custom-sql-to-data-model}` are re-vendored from it per `plugins/sigma-authoring/SYNC.md` (`rm -rf` + `cp -R` + `ruby tools/sync-shared.rb` + `ruby tools/check-shared.rb`, must print `OK: N shared-file copies all match canonical`). `sigma-plugin-authoring` has no upstream in `sigma-skills` — edit it directly in `sigma-migration-skills`.
- **Do not hand-patch a vendored copy to "fix" it and move on.** `plugins/sigma-authoring/skills/sigma-workbooks/SKILL.md` already contains a fix (correct spec URL, split-spec explanation) that **does not exist upstream in `sigma-skills` main** — this is exactly the trap the SYNC.md warns about: the next blind re-vendor will silently revert it. Task 1 below ports that fix upstream *before* anything gets re-vendored.
- **Version bump gate:** any change under `plugins/sigma-authoring/**` in `sigma-migration-skills` requires a semver bump in `plugins/sigma-authoring/.claude-plugin/plugin.json` (currently `1.8.0`) or a `Skip-Version-Bump: <reason>` trailer on the commit.
- **Multi-session git:** `sigma-migration-skills` may have other concurrent sessions on the same working tree. Do all work in a `git worktree`, stage explicit paths (never `git add -A`/`-a`), and confirm before pushing to `main`. `sigma-skills` is single-session but still 13 commits behind `origin/main` locally — sync before editing.
- **Beta caveat:** every new endpoint referenced below (`/v2/workbooks/spec/verify`, `/v2/plugins`, `/v2/dataModels/.../columnSecurityRules`, `/v2/dataModels/.../materializationSchedules`, `/v2/workbooks/.../materializationSchedules`, `/v2/api-connectors`, `/v2/api-credentials`) is marked **Beta** in the spec — say so in every doc addition, don't present them as GA.
- **Live verification is required, not optional — with one narrower sign-off carve-out.** Creating and deleting real test *workbooks* (to prove documented element/chart/control/source shapes actually work — Tasks 2-6, and any workbook-spec-shape check in 9-10) is expected, cheap, and reversible: do it freely, no sign-off needed, clean up test objects after. The narrower exception is the three genuinely org-wide/persistent-beyond-a-test-workbook actions — `POST /v2/plugins` (registers an org-level plugin), `POST .../materializationSchedules` (creates a real recurring warehouse-cost cron schedule), `POST /v2/reports` — those still need explicit sign-off before each live call (Tasks 11 and 12 already gate on this in their steps); `/v2/workbooks/spec/verify` itself is always safe to call freely as a fast first pass, never a substitute for the real create+readback.
- Source of new-spec evidence throughout this plan: `https://fdr-prod-docs-files-public.s3.us-east-1.amazonaws.com/sigma.docs.buildwithfern.com/964b7dcf73aa353d3ab89b1550fa14ea8a4d0a6300aed16bcbe329d1bb4cfd9e/assets/openapi/sigma-computing-public-rest-api.json` (title "Sigma Computing Public REST API" v2.0.0, downloaded and structurally walked 2026-08-03; cached at `/private/tmp/claude-502/-Users-tjwells/1232ff52-a146-42c7-ac3e-2195ff9fc387/scratchpad/spec/new-spec.json` for this session only — re-fetch for a durable copy, the Fern hash rotates on redeploy).
- **Two confirmed non-findings — do not re-investigate:** the `embed` element (already fully documented, `content-elements.md`) and top-level `themeOverrides` (already fully documented, `styling.md`, "added 2026-06-25") both already match the new spec exactly.
- **A third repo is now in scope:** `~/code/sigma-materialization-advisor` (public, `github.com/twells89/sigma-materialization-advisor`, MIT, synthetic-example-only per `[[reference_sigma_materialization_advisor]]`) — the user confirmed Task 12 should be done as part of this same effort, not just flagged. `[[no-customer-info-in-public-artifacts]]` applies to anything new written there.

---

### Task 0: Sync both repos to `origin/main`, set up a worktree

**Files:** none (git only)

- [ ] **Step 1: Check and stash/commit local WIP in `sigma-skills`**
`~/sigma-skills` has an uncommitted change to `sigma-workbooks/reference/specification/layout.md` (top-level-`layout` warning callout + table-height heuristics section). Confirm with the user whether it's finished work to commit or WIP to stash — do not discard it.
```bash
cd ~/sigma-skills && git status --short
git stash push -u -m "WIP before openapi-spec-update sync"   # only if the user says it's not ready to commit
```

- [ ] **Step 2: Fast-forward both repos**
```bash
cd ~/sigma-skills && git fetch origin main && git pull --ff-only origin main   # 13 commits
cd ~/sigma-migration-skills && git fetch origin main && git pull --ff-only origin main   # 8 commits
```

- [ ] **Step 3: Restore stashed WIP (if stashed) and create worktrees for this effort**
Per the multi-session git protocol, don't edit the shared `sigma-migration-skills` working dir directly.
```bash
cd ~/sigma-skills && git stash pop   # if stashed in step 1
cd ~/sigma-migration-skills && git worktree add /tmp/sigma-openapi-update main
cd /tmp/sigma-openapi-update && git checkout -b feat/openapi-spec-update-2026-08
```
(`sigma-skills` is single-session — a plain feature branch off freshly-pulled `main` is fine, no worktree required there.)

- [ ] **Step 3b: Same for `sigma-materialization-advisor` (Task 12's repo)**
```bash
cd ~/code/sigma-materialization-advisor && git fetch origin main && git status --short --branch   # confirm clean, up to date (was, as of 2026-08-03)
git worktree add /tmp/sigma-materialization-advisor-update main
cd /tmp/sigma-materialization-advisor-update && git checkout -b feat/openapi-spec-update-2026-08
```

- [ ] **Step 4: Confirm the two "drift" findings from the audit are gone post-sync**
These were sourced from commits `sigma-skills` was behind on, not from the new OpenAPI content — confirm they resolved themselves:
```bash
grep -n "silently stripped" ~/sigma-skills/sigma-workbooks/reference/specification/charts.md   # should be GONE post-pull (superseded by native trellis rowsBy/columnsBy doc)
ls ~/sigma-skills/sigma-workbooks/reference/specification/agents.md   # should now EXIST
```
If either check fails, stop and re-diagnose before continuing — something in this plan's assumptions is wrong.

---

### Task 1: Fix the dead OpenAPI spec-download URL upstream (sigma-skills)

**Evidence:** `sigma-skills` `origin/main` (`sigma-workbooks/SKILL.md:26,36`, `sigma-data-models/reference/workflows/validate.md:24`) still hardcodes `https://help.sigmacomputing.com/openapi/sigma-computing-public-rest-api.json`, which **404s** (confirmed retired per `[[reference_sigma_openapi_docs_split]]`). `sigma-migration-skills`' vendored copy of `sigma-workbooks/SKILL.md` (lines 25-62) already carries a correct fix — split-spec index explanation, the (now also stale) Fern hash `006ce360...`, and 404-recovery guidance — but that fix was made **directly in the vendored copy**, never ported upstream. It will be silently destroyed by the next blind `rm -rf` + `cp -R` re-vendor.

**Files:**
- Modify: `~/sigma-skills/sigma-workbooks/SKILL.md` (lines ~24-60)
- Modify: `~/sigma-skills/sigma-workbooks/scripts/wb-rep.rb` (`OPENAPI_CACHE`/`OPENAPI_URL` constants, ~line 403-412 — migration-skills' copy already uses `Dir.tmpdir` instead of a hardcoded `/tmp` path for Windows portability; port that too while touching this)
- Modify: `~/sigma-skills/sigma-data-models/reference/workflows/validate.md` (line ~24)
- Do NOT touch `~/sigma-skills/sigma-workbooks/generated/**` by hand — those are generated variants (Step 4 regenerates them).

- [ ] **Step 1: Port the migration-skills fix upstream, updated to the current hash**
Copy the already-correct prose from `~/sigma-migration-skills/plugins/sigma-authoring/skills/sigma-workbooks/SKILL.md:25-62` into `~/sigma-skills/sigma-workbooks/SKILL.md`, replacing the dead-URL section, but swap the pinned Fern URL for the current one (the `006ce360...` hash is itself now stale — one more redeploy already happened):
```
https://fdr-prod-docs-files-public.s3.us-east-1.amazonaws.com/sigma.docs.buildwithfern.com/964b7dcf73aa353d3ab89b1550fa14ea8a4d0a6300aed16bcbe329d1bb4cfd9e/assets/openapi/sigma-computing-public-rest-api.json
```
Keep the existing "if this 404s, rediscover the current link from `help.sigmacomputing.com/openapi.json`" guidance verbatim — it's correct and this hash will rot again.

- [ ] **Step 2: Same fix in `wb-rep.rb`**
Update `OPENAPI_URL` to the same new hash; adopt migration-skills' `Dir.tmpdir`-based `OPENAPI_CACHE` (portability, unrelated to the URL bug but touching the same lines).

- [ ] **Step 3: Same fix in `sigma-data-models/reference/workflows/validate.md`**
Point at the code-representation split spec (`/v2/dataModels/spec` shapes), matching migration-skills' already-correct line 115 wording, not the retired monolith URL.

- [ ] **Step 4: Regenerate per-agent variants**
```bash
cd ~/sigma-skills && ruby scripts/gen-agent-variants.rb --all   # or wherever this repo's generator lives — confirm path, sigma-skills carries its own copy per [[migration_skill_gate_hardening]]
```
If `sigma-skills` has no such generator (it may only exist in `sigma-migration-skills`' `tools/gen-agent-variants.rb`), regenerate `sigma-skills/sigma-workbooks/generated/**` by hand-diffing the URL change into each of `cline`, `cursor`, `codex`, `continue` — confirm which applies before choosing.

- [ ] **Step 5: Verify the fix actually resolves**
```bash
curl -sfI https://fdr-prod-docs-files-public.s3.us-east-1.amazonaws.com/sigma.docs.buildwithfern.com/964b7dcf73aa353d3ab89b1550fa14ea8a4d0a6300aed16bcbe329d1bb4cfd9e/assets/openapi/sigma-computing-public-rest-api.json
```
Expect `HTTP/2 200`.

- [ ] **Step 6: Commit**
```bash
cd ~/sigma-skills
git add sigma-workbooks/SKILL.md sigma-workbooks/scripts/wb-rep.rb sigma-workbooks/generated sigma-data-models/reference/workflows/validate.md
git commit -m "fix(sigma-workbooks): repoint dead OpenAPI spec URL to current Fern asset"
```

---

### Task 2: Document three new native elements — `form`, `progress`, `navigation`

**Evidence (from new spec, `WorkbookElement` schema):**
- `form`: `{id, kind:"form", fields:[...], style}` — no dedicated title in the spec's own `oneOf`, so its `fields` sub-shape needs a live `jq`/verify pull rather than guessing.
- `progress`: `{id, kind:"progress", min, max, value, mode, shape, config}` — a native progress-bar/gauge element. **Cross-check:** `~/sigma-migration-skills/plugins/sigma-authoring/skills/sigma-plugin-authoring/plugins/gauge/README.md:6-8` claims "Sigma has no native chart kind" for value-vs-target gauges as its reason to exist — that claim is now stale if `progress`'s `mode`/`shape` cover the same use case. Read the plugin's README fully and note (don't necessarily deprecate) the overlap.
- `navigation`: two variants sharing `kind:"navigation"`, discriminated by `mode` — "Manual navigation" (`id, kind, mode, optionStyle, options, showIcons, style`) and "Auto navigation" (`id, kind, mode, optionStyle, pageLabels, style`) — an in-canvas page-nav element.

**Files:**
- Modify: `~/sigma-skills/sigma-workbooks/reference/specification/content-elements.md` — add `## form`, `## progress`, `## navigation` sections after the existing `## embed` section (line 182-190) and before `## plugin` (line 192), matching the file's established voice (required/optional field callout + one minimal YAML example, per the `## divider`/`## embed` pattern already there). Update the file's top `jq` swap-comment (line 123, `# swap k for image / divider / embed`) to also list `form`, `progress`, `navigation`.
- Modify: `~/sigma-skills/sigma-workbooks/reference/specification/content-elements.md` header line 117 (`# Content Elements (text, image, divider, embed)`) to include the new kinds.

- [ ] **Step 1: Pull the exact `fields` shape for `form` and full shape for `progress`/`navigation`**
```bash
curl -sf https://fdr-prod-docs-files-public.s3.us-east-1.amazonaws.com/sigma.docs.buildwithfern.com/964b7dcf73aa353d3ab89b1550fa14ea8a4d0a6300aed16bcbe329d1bb4cfd9e/assets/openapi/sigma-computing-public-rest-api.json -o /tmp/sigma-api.json
jq --arg k form 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
jq --arg k progress 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
jq --arg k navigation 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

- [ ] **Step 2: Write the three sections**
Example starting point for `progress` (fill in `fields`/`config` sub-shape from Step 1's pull before finalizing `form`):
```yaml
## progress

A native progress-bar/gauge element — shows a single value against a min/max range. Required `id`, `kind`, `min`, `max`, `value`; optional `mode` and `shape` control the visual treatment, plus a plugin-style `config` object (pull exact enum values for `mode`/`shape` from the spec — see command above).

\`\`\`yaml
id: capacity-gauge
kind: progress
min: 0
max: 100
value: 72
\`\`\`
```
Write `form` and `navigation` with the same structure once Step 1's pull confirms their sub-shapes. For `navigation`, show both the manual (`options: [...]`) and auto (`pageLabels`) variants since they're meaningfully different recipes, not just field-count differences.

- [ ] **Step 3: Verify via dry-run**
Build a minimal one-page workbook spec containing one of each new element and POST it to the new verify endpoint (safe, no persistence):
```bash
jq -n '{name:"verify-test", folderId:"<a real folderId>", schemaVersion:1, pages:[{name:"p1", elements:[{id:"g1",kind:"progress",min:0,max:100,value:50}]}]}' | \
curl -sf -X POST https://<org>.sigmacomputing.com/api/v2/workbooks/spec/verify -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d @-
```
Expect `{"valid": true}`. Repeat for `form` and `navigation` with their real shapes from Step 1. Fix the doc if the response disagrees with what you wrote.

- [ ] **Step 4: Commit**
```bash
cd ~/sigma-skills && git add sigma-workbooks/reference/specification/content-elements.md
git commit -m "docs(sigma-workbooks): document native form, progress, navigation elements"
```

---

### Task 3: Document `waterfall-chart` and `geography-map`'s missing `featureStyle`/`tooltipFormat`

**Evidence:**
- `waterfall-chart` is entirely absent from `charts.md`'s "Other chart kinds" list (sigma-skills `charts.md:326` lists only `area-chart, combo-chart, scatter-chart, pie-chart, pivot-table`). New spec props: `backgroundImage, color, columns, dataLabel, description, filters, grouping, id, kind, legend, name, noDataText, refMarks, source, splitBy, startPoint, style, tooltip, waterfallColors, waterfallShape, xAxis, yAxis`.
- `geography-map` itself IS documented in `maps.md` — only its `featureStyle` and `tooltipFormat` props are undocumented (zero hits repo-wide).

**Files:**
- Modify: `~/sigma-skills/sigma-workbooks/reference/specification/charts.md` (add `waterfall-chart` to the "Other chart kinds" list, ~line 326, with its distinctive fields `startPoint`, `splitBy`, `grouping`, `waterfallColors`, `waterfallShape` called out — this file already has a "gotcha per kind" style for other charts, follow it).
- Modify: `~/sigma-skills/sigma-workbooks/reference/specification/maps.md` (one line under the `geography-map` bullet: "optional `featureStyle` (per-GeoJSON-feature styling override) and `tooltipFormat`").

- [ ] **Step 1: Pull `waterfall-chart`'s full shape**
```bash
jq --arg k waterfall-chart 'first(.. | objects | select((.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]))' /tmp/sigma-api.json
```

- [ ] **Step 2: Write both doc additions** using the pulled shape for exact `startPoint`/`waterfallShape` enum values (don't guess — the spec's `enum` array is the only correct source).

- [ ] **Step 3: Verify** `waterfall-chart`'s minimal recipe via `POST /v2/workbooks/spec/verify` (same pattern as Task 2 Step 3).

- [ ] **Step 4: Commit**
```bash
cd ~/sigma-skills && git add sigma-workbooks/reference/specification/charts.md sigma-workbooks/reference/specification/maps.md
git commit -m "docs(sigma-workbooks): add waterfall-chart, geography-map featureStyle/tooltipFormat"
```

---

### Task 4: `controls.md` — add `Synced` controlType, expand `Hierarchy`

**Evidence (verified exact `controlType` enum values, not titles):** `checkbox, switch, text, text-area, number, number-range, date, date-range, top-n, segmented, hierarchy, slider, range-slider, synced`. `controls.md` covers all of these **except `synced`** (zero hits). `hierarchy` is name-dropped once (line 64: "`segmented` and `hierarchy` are the other list-style widgets") with no dedicated section, no example — thin enough to count as a gap. (`segmented` — not `segmented-control` — is confirmed **correct as already written**; no fix needed there.)

**Files:**
- Modify: `~/sigma-skills/sigma-workbooks/reference/specification/controls.md` — add a `## Synced` section (new) and expand the `Hierarchy` mention into its own short section with a value-shape example, following the file's existing per-type section pattern (see `## Sliders`, `## Top-N`).

- [ ] **Step 1: Pull `synced` and `hierarchy` controlType shapes**
```bash
jq --arg k synced 'first(.. | objects | select(.properties?.controlType?.enum==[$k]))' /tmp/sigma-api.json
jq --arg k hierarchy 'first(.. | objects | select(.properties?.controlType?.enum==[$k]))' /tmp/sigma-api.json
```
`synced` almost certainly means "this control's value is synced to another control's — check for a `source`/target-control reference field"; confirm the exact field name from the pull rather than assuming.

- [ ] **Step 2: Write both sections** with a minimal YAML example each, matching the file's voice.

- [ ] **Step 3: Verify** both via `/v2/workbooks/spec/verify` (control elements need a `source` — use a `warehouse-table` or `data-model` source stub in the test spec).

- [ ] **Step 4: Commit**
```bash
cd ~/sigma-skills && git add sigma-workbooks/reference/specification/controls.md
git commit -m "docs(sigma-workbooks): document Synced controlType, expand Hierarchy"
```

---

### Task 5: `sources.md` (sigma-workbooks) — add `metric-view`, `semantic-view`, and fix pre-existing `csv-table` gap

**Evidence:** `sources.md:3` enumerates `warehouse-table, sql, table, data-model, join, union, transpose` as the full source-kind set — **`csv-table`, `metric-view`, and `semantic-view` are all absent**, though `csv-table` is not new (it predates this spec update; `metric-view`/`semantic-view` are). All three appear only as workbook table-source kinds — **not** in `CreateDataModelSpec`'s source list (data models can't source from a metric-view/semantic-view/CSV directly; only workbooks can). New-spec props: `csv-table: {connectionId, inodeId, kind}`, `metric-view: {connectionId, kind, path}`, `semantic-view: {connectionId, kind, path}` (the latter two share `warehouse-table`'s `path`-array shape, suggesting they resolve through a connection's object hierarchy the same way).

**Files:**
- Modify: `~/sigma-skills/sigma-workbooks/reference/specification/sources.md` — update the line-3 enumeration to include all three, add a `## csv-table`, `## metric-view`, `## semantic-view` section each with a minimal example (same terse style as the existing `## Custom SQL` section).

- [ ] **Step 1: Pull all three shapes** (same `jq --arg k <kind> ...` pattern used throughout this plan).

- [ ] **Step 2: Write the three sections.** For `metric-view`/`semantic-view`, note plainly in the doc that these look like a governed semantic-layer object type distinct from a plain warehouse table — flag as something to confirm with a live example workbook if one exists on a test org, since the spec text alone doesn't say what populates a "Metric View" or "Semantic View" (e.g. whether it's authored via a separate REST resource not yet in this OpenAPI dump, or via the DM `metrics` block). Don't invent an authoring workflow that isn't evidenced.

- [ ] **Step 3: Verify** `csv-table`'s shape via dry-run (needs a real `inodeId` for a CSV file — use `GET /v2/files` to find one, or skip live-verify and cite spec evidence only if no CSV file is handy).

- [ ] **Step 4: Commit**
```bash
cd ~/sigma-skills && git add sigma-workbooks/reference/specification/sources.md
git commit -m "docs(sigma-workbooks): add csv-table, metric-view, semantic-view source kinds"
```

---

### Task 6: `tables.md` — cross-reference workbook-element-level `columnSecurities`

**Evidence:** `table` and `input-table` workbook elements both carry a `columnSecurities` array (criteria kinds `no-one-can-view`, `specific-users-and-teams`, `user-attribute` — identical shape to what `sigma-data-models/reference/column-level-security.md` already documents for data-model table elements). The workbooks skill has **zero** mention of this — a reader building a table element straight against a warehouse source (bypassing a data model) has no pointer to CLS at all.

**Files:**
- Modify: `~/sigma-skills/sigma-workbooks/reference/specification/tables.md` — add a short section (not a full re-document — cross-reference the existing sigma-data-models doc, since the shape is identical): "Column-level security on a table element uses the same `columnSecurities` criteria shapes as a data-model table element — see `sigma-data-models/reference/column-level-security.md`."

- [ ] **Step 1: Confirm the shape is byte-identical** between the workbook `table` element's `columnSecurities` and the data-model version (diff the two `jq` pulls) — if they've diverged even slightly, document the workbook version in full instead of just cross-referencing.

- [ ] **Step 2: Write the cross-reference (or full section if Step 1 found divergence).**

- [ ] **Step 3: Verify** a minimal table-element `columnSecurities` block via dry-run.

- [ ] **Step 4: Commit**
```bash
cd ~/sigma-skills && git add sigma-workbooks/reference/specification/tables.md
git commit -m "docs(sigma-workbooks): cross-reference column-level security on table elements"
```

---

### Task 7: Adopt `POST /v2/workbooks/spec/verify` in `wb-rep.rb` and the build workflow

**Evidence:** New endpoint, explicitly pitched by Sigma for "agentic workflows" and "automation/CI/migration tooling" — validates a workbook code representation with **zero persistence**. `sigma-data-models/reference/workflows/validate.md:39-56` (and the sigma-workbooks equivalent) currently documents the *opposite* reality: "there is no way to catch [a bad formula reference] from the spec text alone — only Sigma's compiler knows... " and instructs validating **after** a real create/PUT via `GET .../elements/<eid>/query`. This is the single highest-leverage change in this plan — every task above should ideally use this endpoint to self-check before landing, and this task makes that a first-class capability instead of ad hoc curl.

**Files:**
- Modify: `~/sigma-skills/sigma-workbooks/scripts/wb-rep.rb` — add a `verify` subcommand alongside the existing `capabilities`/create/update commands, POSTing the given spec file to `/v2/workbooks/spec/verify` and printing `valid: true` or the `errors` array.
- Modify: `~/sigma-skills/sigma-workbooks/reference/workflows/validate.md` (or wherever the create/update workflow lives) — add "dry-run first" as the new first step, keeping the existing post-create verification as a second-line check (the dry-run catches schema/reference errors; it can't catch things that only manifest against live data, per Sigma's own usage notes).
- Test: add a small offline test (this repo has an offline test suite pattern per `[[migration_skill_gate_hardening]]`'s "55/55 offline tests" — find and follow it, likely under `~/sigma-skills/scripts/` or a `test/` dir; confirm exact location before writing).

- [ ] **Step 1: Read the existing `wb-rep.rb` command dispatch** to match its style (likely a simple `case ARGV[0]` or subcommand table) before adding `verify`.

- [ ] **Step 2: Write the failing test** — pass a spec with a deliberately bad column reference (e.g. `[NoSuchTable/fake_col]`) through `wb-rep.rb verify` and assert it prints `valid: false` with an `errors` array; pass a known-good example spec (`sigma-workbooks/reference/specification/example-full.yaml` converted to JSON) and assert `valid: true`.

- [ ] **Step 3: Run it, confirm it fails** (command doesn't exist yet).

- [ ] **Step 4: Implement the `verify` subcommand** — POST to `/v2/workbooks/spec/verify` using this file's existing HTTP helper (reuse whatever `wb-rep.rb` already uses for the `create`/`update` calls — same auth header pattern), print the `valid`/`errors` response.

- [ ] **Step 5: Run the test, confirm it passes.**

- [ ] **Step 6: Update `validate.md`'s workflow** to lead with `wb-rep.rb verify <spec-file>` before the real create call.

- [ ] **Step 7: Commit**
```bash
cd ~/sigma-skills
git add sigma-workbooks/scripts/wb-rep.rb sigma-workbooks/reference/workflows/validate.md <test file>
git commit -m "feat(sigma-workbooks): add wb-rep.rb verify subcommand (dry-run spec validation)"
```

---

### Task 8: Re-vendor `sigma-skills` → `sigma-migration-skills`'s `sigma-authoring` plugin

**Do this only after Tasks 1-7 are committed on the `sigma-skills` feature branch and that branch is pushed to `origin`.** This does NOT require the `sigma-skills` PR to be merged to `main` first — vendor from the pushed feature branch's SHA (recorded below), not from `main`. Vendoring from a named, pushed branch keeps this task unblocked without needing a merge decision mid-plan; `SYNC.md`'s "Vendored at" line will record that branch+SHA until the `sigma-skills` PR merges, at which point it's a plain fast-forward, not a re-vendor.

**Files:**
- Modify: `~/sigma-migration-skills/plugins/sigma-authoring/skills/{sigma-workbooks,sigma-data-models,custom-sql-to-data-model}/**` (wholesale replace)
- Modify: `~/sigma-migration-skills/plugins/sigma-authoring/.claude-plugin/plugin.json` (version bump)
- Modify: `~/sigma-migration-skills/plugins/sigma-authoring/SYNC.md` ("Vendored at" SHA)

- [ ] **Step 1: Fresh clone `sigma-skills` at the pushed feature branch's HEAD** (don't vendor from the possibly-dirty local checkout, and don't assume `main` has it yet):
```bash
git clone --branch feat/openapi-spec-update-2026-08 https://github.com/twells89/sigma-skills.git /tmp/sigma-skills-fresh
```

- [ ] **Step 2: Run the SYNC.md recipe** (in the `/tmp/sigma-openapi-update` worktree from Task 0):
```bash
cd /tmp/sigma-openapi-update
SRC=/tmp/sigma-skills-fresh
for s in sigma-workbooks sigma-data-models custom-sql-to-data-model; do
  rm -rf "plugins/sigma-authoring/skills/$s"
  cp -R "$SRC/$s" "plugins/sigma-authoring/skills/$s"
done
ruby tools/sync-shared.rb
ruby tools/check-shared.rb   # MUST print "OK: N shared-file copies all match canonical"
```

- [ ] **Step 3: Regenerate agent variants** (this repo's own generator, per `[[migration_skill_gate_hardening]]`):
```bash
ruby tools/gen-agent-variants.rb --all
```

- [ ] **Step 4: Bump the plugin version and SYNC.md SHA**
Bump `plugins/sigma-authoring/.claude-plugin/plugin.json` (`1.8.0` → `1.9.0` — this is a genuine feature addition, not a patch) and update `SYNC.md`'s "Vendored at" line to the fresh clone's `HEAD` SHA.

- [ ] **Step 5: Confirm no CI-relevant drift**
```bash
ruby tools/check-plugin-version-bump.sh   # or however this repo's gate script is invoked — confirm exact name/path first
```

- [ ] **Step 6: Commit as ONE atomic commit** (per `[[shared_file_governance]]` — canonical fan-out + version bump together, never split):
```bash
git add plugins/sigma-authoring
git commit -m "chore(sigma-authoring): re-vendor from sigma-skills (Aug 2026 OpenAPI update)"
```

---

### Task 9: `column-level-security.md` — document `columnSecurityRules` REST CRUD

**Evidence:** New Beta endpoints `GET/POST /v2/dataModels/{dataModelId}/elements/{elementId}/columnSecurityRules`, `PUT/DELETE .../columnSecurityRules/{ruleId}`. Current doc covers **only** the spec-embedded `columnSecurities` array (identical criteria shapes: `no-one-can-view`, `specific-users-and-teams`, `user-attribute`). All 9 converter `apply_sigma_rls.py` scripts (tableau, powerbi, cognos, qlik, thoughtspot, sisense, quicksight, looker) apply CLS via the spec-embedded route exclusively — none use this REST CRUD surface.

**Files:**
- Modify: `~/sigma-skills/sigma-data-models/reference/column-level-security.md` — add a section explaining the REST CRUD surface exists as an alternative to spec-embedded `columnSecurities`, and give explicit guidance on which to use when: spec-embedded is right for "author the whole data model from code" (what every converter does today — don't change converter behavior), REST CRUD is right for "add/modify one rule on an existing, already-published data model without re-POSTing the whole spec" (a narrower, more surgical use case).

- [ ] **Step 1: Pull the full request/response shape** for `POST .../columnSecurityRules`:
```bash
jq '.paths."/v2/dataModels/{dataModelId}/elements/{elementId}/columnSecurityRules".post' /tmp/sigma-api.json
```

- [ ] **Step 2: Write the section** with a minimal `curl` example (this is a REST-CRUD doc, not a spec shape — no `/verify`-style dry run exists for it, cite the schema as evidence and note it's untested live).

- [ ] **Step 3: Commit**
```bash
cd ~/sigma-skills && git add sigma-data-models/reference/column-level-security.md
git commit -m "docs(sigma-data-models): document columnSecurityRules REST CRUD alongside spec-embedded CLS"
```

---

### Task 10: `sources.md` (sigma-data-models) — add `api-connectors`/`api-credentials`, note `dbtArtifacts` and connection `test`

**Evidence:** New Beta resources `GET/POST /v2/api-connectors`, `GET/PATCH/DELETE /v2/api-connectors/{id}`, `GET/POST /v2/api-credentials` — a first-class connection type for hitting external REST APIs as a Sigma data source, distinct from warehouse connections. Also new/unused: `POST /v2/connections/{connectionId}/dbtArtifacts` (pushes dbt-sourced metadata/lineage onto an existing connection) — zero mentions anywhere in either repo beyond dbt-as-a-migration-source language. Separately (minor, but a genuine zero-hit gap): `GET /v2/connections/{connectionId}/test` — a connection health-check endpoint — is never referenced anywhere as a troubleshooting step, even though every converter's "connection failed" path could point to it.

**Files:**
- Modify: `~/sigma-skills/sigma-data-models/reference/sources.md` — add a short "Connection kinds" note: warehouse connections are what every converter uses today; `api-connectors` is a new Beta kind for REST-API-backed sources (out of scope for the existing converters unless a future migration target needs it — don't wire this into any converter as part of this task, just document its existence).
- Modify same file (or a new short section) — one paragraph on `dbtArtifacts`: if a connection already has dbt-sourced column descriptions/lineage, this endpoint can push them onto the Sigma connection; note this as a potential enrichment step for future dbt-aware conversions, not something any current skill calls.
- Modify: `~/sigma-skills/sigma-data-models/reference/workflows/validate.md` — add one troubleshooting-table row: connection-related errors → `GET /v2/connections/{connectionId}/test` to confirm the connection itself is healthy before assuming the data-model spec is wrong.

- [ ] **Step 1: Pull all three shapes** (`api-connectors` create body, `dbtArtifacts` request body, `connections/{id}/test` response body).

- [ ] **Step 2: Write both `sources.md` notes**, explicitly scoped as "new capability, not yet used by any converter" so nobody mistakes this for an existing integration, plus the one-row `validate.md` troubleshooting addition.

- [ ] **Step 3: Commit**
```bash
cd ~/sigma-skills && git add sigma-data-models/reference/sources.md sigma-data-models/reference/workflows/validate.md
git commit -m "docs(sigma-data-models): note api-connectors source kind, dbtArtifacts, connection test endpoint"
```

---

### Task 11: `sigma-plugin-authoring` — wire `devUrl` into plugin registration, check the `type` field

**Evidence:** `plugin-lifecycle.md:13-19`/`SKILL.md:90-102` already register plugins via `POST /v2/plugins` (ahead of the framing in the original ask — this was NOT a manual-UI gap). Two real gaps: (1) the documented request body omits `devUrl` (new-spec create body: `name` required, `description`, `devUrl` defaulting to `http://localhost:5173`, `url`) even though `devUrl` is already known to exist (it shows up in the GET-list response shape documented in `sigma-workbooks/reference/specification/content-elements.md:97`) — the registration recipe should set it explicitly during dev-mode registration rather than relying on an undocumented default. (2) the documented body includes a `type` field that **does not appear in the create-plugin request schema at all** (`type` is response-only, hardcoded to `"element"` in every `GET /v2/plugins` entry) — confirm whether sending it is harmless (ignored) or actually rejected before deciding whether to drop it from the recipe.

**Files:**
- Modify: `~/sigma-migration-skills/plugins/sigma-authoring/skills/sigma-plugin-authoring/reference/plugin-lifecycle.md:13-19`
- Modify: `~/sigma-migration-skills/plugins/sigma-authoring/skills/sigma-plugin-authoring/scripts/register-plugin.rb` (or wherever the actual POST body is constructed)

- [ ] **Step 1: Test whether `type` in the POST body is rejected or silently ignored** — this needs one real (safe-ish, plugin registration is reversible/deletable) API call:
```bash
curl -s -X POST https://<org>.sigmacomputing.com/api/v2/plugins -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"__test-openapi-update-delete-me","type":"element"}'
```
**Get explicit user sign-off before running this** (Global Constraints: no side-effecting live calls without sign-off) — it creates a real plugin record. Delete it immediately after (`DELETE /v2/plugins/{pluginId}`) regardless of the outcome.

- [ ] **Step 2: Update `register-plugin.rb`'s request body** — drop `type` if Step 1 shows it's superfluous/rejected, add `devUrl` (defaulting to `http://localhost:5173` to match the API's own default, or reading it from whatever config `sigma-plugin-authoring` already uses for the dev server URL).

- [ ] **Step 3: Update `plugin-lifecycle.md`'s example** to match the corrected body.

- [ ] **Step 4: Commit**
```bash
cd ~/sigma-migration-skills   # in the Task 0 worktree
git add plugins/sigma-authoring/skills/sigma-plugin-authoring
git commit -m "fix(sigma-plugin-authoring): wire devUrl into plugin registration, drop unsupported type field"
```
(Covered by the same version bump as Task 8 if done in the same PR — confirm before double-bumping.)

---

### Task 12: `sigma-materialization-advisor` — retract the false "no create-schedule endpoint" claim, add schedule CRUD

**Repo:** `~/code/sigma-materialization-advisor` (public, MIT, synthetic-example-only — confirmed clean and up to date with `origin/main` as of 2026-08-03; worktree set up in Task 0 Step 3b). No test framework exists in this repo (no `test/` dir, no pytest config) — verification here is live read-only checks plus, for the one write path, an explicit-sign-off live create/delete cycle, same posture as Task 11.

**Evidence (fully re-verified against the new spec, not just the original audit pass):**
- `refs/materialization-playbook.md:36-37` states *"Create schedule: Sigma UI only … No create-schedule REST endpoint as of 2026-06."* — **false** as of this spec. `scripts/materialize.py:5-7`'s module docstring repeats it: *"It cannot CREATE a schedule — that one-time setup is done in the Sigma UI."*
- The new spec's actual endpoint shapes, confirmed by direct inspection (not the asymmetry the original audit guessed at — this is the real shape):
  - **Data-model elements** — fully nested, 4 verbs at the same path: `GET/POST/PATCH/DELETE /v2/dataModels/{dataModelId}/elements/{elementId}/materializationSchedules`. *Plus* a separate, already-in-use, still-valid unscoped list: `GET /v2/dataModels/{dataModelId}/materializationSchedules` (whole-data-model, no `elementId`).
  - **Workbook elements** — asymmetric: LIST stays unscoped/hyphenated exactly as `materialize.py:39` already calls it (`GET /v2/workbooks/{workbookId}/materialization-schedules` — **this existing call is correct, don't touch it**), but CREATE/UPDATE/DELETE are new and nested: `POST/PATCH/DELETE /v2/workbooks/{workbookId}/elements/{elementId}/materializationSchedules`.
  - **Create body, both element types — identical, and simpler than the doc currently implies:** `{"schedule": {"cronSpec": "<cron expression>", "timezone": "<IANA tz, optional>"}}`. Only `cronSpec` is required. There is **no destination/target field** — the UI's "pick element + destination + cadence" framing (`materialize.py:6-7`) overstates what the API needs; the API only sets cadence (materialization writes back to Sigma's own internal cache, not a user-chosen destination).
  - The one-off trigger (`POST /v2/dataModels/{id}:materialize`, `POST /v2/workbooks/{id}/materializations`) and monitor (`GET .../materializations/{id}`) endpoints `materialize.py` already uses are unchanged — don't rewrite those code paths, only add to them.

**Files:**
- Modify: `~/code/sigma-materialization-advisor/refs/materialization-playbook.md:35-43` ("Materialization mechanics" section)
- Modify: `~/code/sigma-materialization-advisor/scripts/materialize.py` (module docstring lines 3-8, plus new subcommands)

- [ ] **Step 1: Rewrite the playbook's "Materialization mechanics" section** to retract the false claim and document, for both data-model and workbook elements: create (cron + optional timezone, no destination field), update, delete, and the pre-existing list/trigger/monitor calls — noting the workbook-list-vs-element asymmetry explicitly so a future reader doesn't "fix" `materialize.py:39` into something wrong.

- [ ] **Step 2: Add `create`, `update`, `delete` subcommands to `materialize.py`**, parallel to the existing `list`/`run` subcommands (same `argparse` subparser + `api()` helper pattern already in the file). `create`/`update` take `--cron` (required) and `--timezone` (optional); `delete` takes just the element/workbook + data-model id already used by the other subcommands.

- [ ] **Step 3: Read-only live check** — run the existing (unchanged) `list` subcommand against a real org/workbook to confirm output is unaffected by the edit (regression check on code you're not supposed to have touched):
```bash
eval "$(~/.claude/skills/tableau-to-sigma/scripts/get-token.sh)"
python3 scripts/materialize.py list --workbook <a real workbookId>
```

- [ ] **Step 4: Live-verify the new `create`/`delete` path once, with explicit user sign-off first** (Global Constraints: no side-effecting calls without sign-off — this creates a real recurring schedule, however briefly):
```bash
python3 scripts/materialize.py create --workbook <id> --sheet <elementId> --cron "0 0 * * *"
python3 scripts/materialize.py list --workbook <id>          # confirm it shows up
python3 scripts/materialize.py delete --workbook <id> --sheet <elementId>   # clean up immediately
```
If sign-off isn't available in this session, document the new subcommands from spec evidence only and leave this step as an explicit follow-up for the user to run themselves — do not skip asking.

- [ ] **Step 5: Commit**
```bash
cd /tmp/sigma-materialization-advisor-update   # worktree from Task 0 Step 3b
git add refs/materialization-playbook.md scripts/materialize.py
git commit -m "fix: retract false 'no create-schedule endpoint' claim, add schedule CRUD"
```

---

## Self-Review Notes

- **Spec coverage:** all ~20 structurally-distinct additions found in the audit map to a task above, except the two confirmed non-findings (embed, themeOverrides — explicitly called out in Global Constraints so nobody re-does that work) and the Reports API / bookmarks-scoped `DashVariables`, both of which were confirmed to have **no actionable doc gap** — Reports has no code-representation endpoint to author against (UI/copy-built only) and isn't referenced as a target anywhere in either repo's converters, and `DashVariables` only backs scheduled-export variable overrides (a workflow this skill explicitly scopes out already, `SKILL.md:21,27`), not general workbook authoring.
- **Type consistency:** every task cites the exact `kind`/`controlType` string verified against the spec's `enum` array, not a guessed kebab-case form (this caught one near-miss: `segmented`, not `segmented-control`, is correct as already written — don't "fix" it).
- **No placeholders:** every doc-writing task cites required-vs-optional fields extracted from the actual schema; the two tasks with genuinely unresolved shape questions (`form.fields`, `synced` controlType's target-reference field) say so explicitly and specify the exact `jq` pull to resolve them rather than guessing prose.
