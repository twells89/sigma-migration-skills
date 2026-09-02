<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Phase 0 — scope: gap scan, destination, mode, cost -->

## Step 0.1 — front door: resolve the connection once (relocated from SKILL.md — E9 diet)

Resolve the Sigma warehouse connection a SINGLE time so no phase free-searches
`/v2/connections` (the token sink):

```bash
ruby scripts/intake.rb --workdir <WORK> --tool tableau-to-sigma --mode live \
  --source "<workbook name or LUID>" \
  [--connection <id>] [--name <connection-name-substring>] \
  [--plan <assessment>/migration-plan.json] [--triage-override "<who>: <why>"]
```

It caches `<WORK>/connection.json` (the orchestrator reads it when
`--connection` is omitted — point `--out` at the same `<WORK>`) and writes
`intake.json`. Precedence: explicit `--connection` → cached →
`SIGMA_CONNECTION_ID` env → list once; with multiple connections it asks — it
never guesses. **Many connections?** Pass `--rank-workbook-id <LUID>`: intake
fingerprints the workbook's warehouse (type+host, no `.twb` download) and a
unique match auto-resolves, else it writes ranked `connection-candidates.json`
and asks (`scripts/rank-connections.rb` standalone; `--rank-twb <path>`
db-name tie-break). Never grep the `.twb` by hand to guess among connections.
Credentials for hand-driven calls: `refs/environment.md` §Credentials.

**Front-door triage (always pass `--source` — it keys this).** When an
assessment `migration-plan.json` is present (`--plan PATH`, or auto-found at
`<WORK>/migration-plan.json`), intake looks this run's workbook up BEFORE any
API call burns:

- **retire-tagged** (zero usage) → **REFUSE, exit 7** — the fastest migration
  is the one you don't do. Convert anyway ONLY with an attributable
  `--triage-override "<who>: <why>"` (or `SIGMA_TRIAGE_OVERRIDE`); the
  override is recorded to `<WORK>/offramps.jsonl`, never a silent proceed.
- **ranked low / blocked / consolidation-member** → WARN with the plan's
  value/cost evidence, then proceed (no stop).
- **no plan anywhere** → one offer line, never a block. Malformed plan,
  missing or ambiguous `--source`, or an unassessed workbook → one note,
  triage skipped — the only stop in this guard is a matched retire tag
  (ratified ≤5% false-stop budget). Verdicts land on `intake.json` `triage`.

## Phase 0a — Scan the workbook for feature gaps (MANDATORY)

Run the gap scanner against the customer's `.twb` *before* anything else. It
inventories every workbook feature the skill currently handles vs. doesn't, so
the agent can plan around real translation gaps instead of discovering them
mid-conversion.

```bash
ruby scripts/scan-workbook-gaps.rb <WORK>/workbook-content.twb
# writes <name>-workbook-content-gaps-report.md + <name>-workbook-content-gaps.json
```

Categories emitted:
- **✅ Auto** — translated end-to-end without intervention
- **⚠️ Hint** — agent gets a copy-paste-ready Sigma formula in WARN lines
- **🛠 Manual** — customer wires up post-publish (action filters, ref-marks)
- **❌ Unhandled** — feature is used in the .twb but the skill does not yet
  cover it; the agent should escalate via the `gap-scout` subagent OR file
  an issue at github.com/twells89/sigma-skills-staging

Share the markdown report with the customer up front to set expectations.
Save the JSON for the subagent.

## Phase 0b — Choose where to build (MANDATORY when no destination given)

Never silently dump the migrated data model + workbook into an auto-picked
folder. If the user did **not** supply a destination (no `--folder <id>` on
`migrate-tableau.rb` and no `SIGMA_FOLDER_ID`), ASK first:

1. List candidates:
   ```bash
   ruby scripts/pick-destination.rb list
   # -> { "workspaces":[{id,name}], "folders":[{id,name,parentId,parentName}], "myDocuments": <id|null> }
   ```
2. Present the options to the user and let them pick ONE:
   - a **workspace** (content lands in the workspace root — pass its `id` as the folder)
   - an existing **folder** (use its `id`; `parentName` shows its workspace)
   - **My Documents** (only when `myDocuments` is non-null — null for service-account tokens)
   - **create a new folder** (optionally inside a chosen workspace/folder):
     ```bash
     ruby scripts/pick-destination.rb create --name "<name>" [--parent <workspace-or-folder-id>]
     # -> { "id", "name", "parentId" }
     ```
3. Pass the chosen id to the migration as `--folder <id>` — it flows into both
   the DM and workbook POSTs.

`folderId` accepts a workspace id (lands in the root) **or** a folder id. If the
user already passed `--folder` / `SIGMA_FOLDER_ID`, honor it silently — do NOT ask.
For **My Documents**, use the authenticated member's `homeFolderId` from
`GET /v2/members/{memberId}` (the orchestrator resolves this automatically when
the user chooses the default). Do not copy the `/f/<urlId>` segment from a Sigma
browser URL: `urlId` and the API's inode/folder ID are different identifiers.
The data model and workbook create endpoints accept `homeFolderId` directly;
creating elsewhere and moving them afterward with `PATCH /v2/files/{inodeId}`
is unnecessary.

> **Data blending:** when the scanner writes `blend-plan.json`, route each
> blend BEFORE Phase 2 using its `route` field — (a) `same-warehouse-repoint`
> → one DM, both sources as elements + relationship on the linking fields
> (deep-walk `connectionId` incl. `joins[].left/right` when repointing);
> (b) `materialize-via-vds` → run the **tableau-vds-to-cdw** skill to land the
> secondary in the primary's warehouse first; (c) `flag-unreachable` → keep
> manual, report the linking fields. Full decision tree: `refs/blending.md`.

> **Story points:** when `parse-twb-layout.rb` writes `story-plan.json`
> (Phase 1d), plan one Sigma page per story point and run
> `scripts/build-story-pages.rb` in Phase 5 (spec pass) and Phase 5d (layout
> pass). Storyboard dashboards are flagged `is_story: true` in
> `dashboard-layout.json` — do NOT build a regular page from the flipboard
> chrome. See `refs/story-points.md`.

### Phase 0a-scout — spawn the gap-scout subagent for unhandled features

> **MANDATORY, parallelizable.** As soon as the gap scanner produces `gaps.json`,
> read the `detected_features` array and **spawn one `gap-scout` Agent per row
> whose `status` is `unhandled`** (and optionally for high-volume `hint` rows).
> Use `run_in_background: true` so the scout runs in parallel with the rest of
> conversion — by the time you reach Phase 5, the scout has either persisted a
> rule or escalated. Don't read the gap report and proceed without doing this.

For every `❌ Unhandled` row in the gap report (and for high-volume `⚠️ Hint`
rows worth automating), spawn a `gap-scout` subagent via the Agent tool. Each
scout takes ONE gap, proposes a Sigma translation, validates against the
customer's Sigma site via `scripts/validate-sigma-formula.rb`, and:
- on success → writes the rule to `~/.tableau-to-sigma/learned-rules.yaml`
  (the customer's home dir — `git pull` of the skill cannot clobber it).
  All future workbook conversions on this machine pick up the rule via
  `scripts/learned-rules.rb` automatically.
- on failure → writes to `~/.tableau-to-sigma/escalations/` and returns an
  **opt-in** `escalate-gap.py` command. Filing a tracking issue is never
  automatic: run the returned `escalation.dry_run_cmd` to draft the issue
  (shows target repo + dedupe), show the user, and only re-run with `--yes`
  if they accept. Calc-field gaps route to the converter repos
  (`sigma-data-model-manager` + `sigma-data-model-mcp`, mirrored) with a
  cross-linked bead. See "Opt-in issue filing" in `scripts/gap-scout.md`.

The build script (`build-charts-from-signals.rb`) loads learned rules at
startup; matching rules apply *before* the built-in translators, so customer-
discovered translations override defaults. See `scripts/gap-scout.md` for the
full subagent prompt + procedure.

Customer-local files always live under `~/.tableau-to-sigma/`:
- `learned-rules.yaml`   — accumulated translation rules
- `escalations/*.yaml`   — gaps the scout couldn't solve
- (override path for testing with `TABLEAU_TO_SIGMA_HOME` env var)

### Phase 0b — Pick the conversion mode (MANDATORY, ask the customer)

Before building anything, **ask the customer which mode they want**. There is
no good default — picking the wrong one wastes the whole conversion.

| Mode | When | Output |
|---|---|---|
| **Dashboard fidelity** (default for dashboard URLs like `/views/<WB>/<Dashboard>`) | Customer wants the source dashboard recreated 1:1 in Sigma | One Sigma page with all charts positioned in the same grid as Tableau; shared filters as page-level controls; layout XML mirrors the dashboard's zone tree |
| **Page-per-worksheet** (default for `/sheets/<Sheet>` URLs OR when the customer says "split it up") | Customer wants each worksheet adjustable independently, OR the dashboard is too dense to recreate cleanly | One Sigma page per Tableau worksheet; shared filters duplicated on each page |

When the customer's URL is a dashboard URL and they haven't explicitly said
"split into pages," the agent MUST ask: "Want me to recreate the dashboard
1:1 (all 6 tiles on one page) or break each worksheet into its own Sigma
page?" Don't assume.

For dashboard mode, `build-charts-from-signals.rb` is invoked WITHOUT
`--page-per-worksheet` — that emits the legacy flat-array output. Then a
separate layout script positions the chart elements in a grid matching the
Tableau dashboard's zone x/y/w/h percentages (parse-twb-layout already
extracts these).

For page-per-worksheet mode, pass `--page-per-worksheet`.

---

## Phase 0c — Scope/cost estimate + sign-off (PLAN-v3 PR-3)

Before any DM build the scope and rough agent cost go on record. **The
orchestrator (`migrate-tableau.rb`) runs this for you**: right after the
Phase-1 join (discovery metadata + gap scan on disk, nothing posted to Sigma
yet) it invokes

```bash
ruby scripts/estimate-cost.rb --workdir <WORK>   # writes <WORK>/cost-estimate.json
```

which reads whatever scoping artifacts exist (`get-workbook.json`,
`dashboard-layout.json`, `calc-fields.json`, `*-gaps-report.json`,
`custom-sql.json`) — each optional; missing inputs degrade the estimate and
are **named** in `inputs.missing`, never fatal. The orchestrator then prints a
`SCOPE / COST SIGN-OFF` block (tiles, calc count by class, gap classes,
❌-untranslatable classes, estimated turns/tokens/minutes) and records the
acknowledgment in `run-state.json`:

- `--yes`/`--answers` (unattended): `{cost_estimate_acknowledged: true, cost_estimate_provenance: "auto-yes"}`
- interactive: provenance `"stated"` (the operator saw the printed block)

A missing ack at the Phase 3 DM build is a **WARN this release** (hard-gating
waits for field calibration confidence).

Every estimate carries `confidence: "rough"`: coefficients are anchored on
three measured clean e2e runs (~60 turns/48 min/7 tiles, ~75/40/5, ~80/71/6)
plus the ~4 h heavy-failure field sessions (per-❌-unhandled-class penalty),
with stated tokens-per-turn assumptions — see the CALIBRATION block in
`scripts/estimate-cost.rb`. n=3: treat buckets (small/medium/large/very-large)
as directional, not quotes; re-fit at ~10 measured conversions.

Standalone pre-scoping (before any discovery) still works:

```bash
ruby scripts/estimate-cost.rb --workbook <WORK>/get-workbook.json \
  [--datasource <WORK>/ds-metadata.json]
```

(tile count proxied by the sheet count; same rough-marked output).

---

