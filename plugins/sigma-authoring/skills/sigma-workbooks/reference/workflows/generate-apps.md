# Generate an operational Sigma app

Use this workflow when the user asks to generate, build, or scaffold a Sigma
**app** — a planning model, approval queue, allocation grid, exception command
center, or an unspecified “app” — and they did **not** supply a target image.

The general spec workflow ([the rest of SKILL.md](../../SKILL.md)) still
applies. This document covers **only the intake steps** that come *before*
discovery and spec drafting: classify the app type, **interview** the user
(editable fields, approvals, Sigma Agent), record a local intake manifest,
state a build plan, and clone a best-practice **architecture** fixture.
Look is a later compose pass (`styling.md` as a library — not one house
recipe). The fixtures are the house standard to imitate; do not draft the
first spec from memory.

If the user supplied a screenshot, mockup, PDF, or design artifact, stop and
load `from-image.md` instead. Image-driven reproduction is a different path.

## Why this workflow exists

The four operational recipes (`planning-apps.md`, `allocation-apps.md`,
`approval-apps.md`, `exception-apps.md`) already define grain, writeback
architecture, and runtime gates. Without a single entry point, agents infer
the type from keywords, skip grain questions, and draft from memory. The
common bad first pass is a dashboard with an empty input table that is not
linked to a governed source, or a “planning app” whose scenarios share one
editable grid.

This workflow makes classification, grain, and the starting spec explicit.
It interviews **before** it clones: which fields users may edit, whether
the workflow needs approvals, and whether to add a workbook agent (with a
recommended purpose). Those answers become a short build plan for this
workbook and the person who will use it.

Do **not** invent a fifth operational type. Apps are still workbooks
(`POST /v2/workbooks/spec`). Architecture details live in the matching recipe,
not here.

## Workflow

### Step A — Classify (one question, forced choice)

Ask what users should **do** in the workbook. Offer the four documented
types plus two redirects. Do not ask an open-ended “what kind of app?”

| User intent | Route |
|---|---|
| Edit forecasts, scenarios, budgets, assumptions | `planning-apps.md` + `fixtures/planning-app.yaml` |
| Redistribute budget / quota / headcount / capacity across a dimension | `allocation-apps.md` + `fixtures/allocation-app.yaml` |
| Approve, reject, or counter existing records | `approval-apps.md` + `fixtures/approval-app.yaml` |
| Triage exceptions, apply overrides, log resolution | `exception-apps.md` + `fixtures/exception-app.yaml` |
| Read-only dashboard / KPI overview | stop; use `composition.md` |
| Pixel-perfect invoice / statement / PDF | stop; use the `sigma-reports` skill |

A classifier helper can suggest a type from the user's prose; still confirm
it before continuing:

```bash
ruby -r ./scripts/lib/app_intake.rb -e 'p AppIntake.classify(ARGV[0])' \
  "approve or reject pending deals"
```

If the ask is mixed (for example, “planning *and* approvals”), follow the
`from-image.md` boundary rule: **one workbook per app surface**. Confirm the
split, then run this intake twice.

### Step B — Interview before building

Keep these few and structural. Do not expand into an open-ended UX interview.
Load the matching recipe after classification so the answers map onto its
grain and gates. Show the type's recommended answer for each question;
confirm or override — do not invent a fifth operational type.

**Every operational type** — the five input-table facts from
`../specification/input-tables.md`:

1. desired row grain and expected row count;
2. whether rows already exist in a governed source;
3. whether users edit whole rows or sparse override columns;
4. one-time file load versus ongoing interactive entry;
5. whether UI loading or warehouse loading is acceptable.

Then the type-specific set:

**Planning** (`planning-apps.md`)

- Which mode: one working plan / scenario planning / variance-only / parity?
- Confirm grain: `Scenario × Period × Planning Line` (or the named columns).
- Filter propagation: Option A (complete grid, formula-scoped analytics) or
  Option B (filtered grid, independent all-scenario read path)?

**Allocation** (`allocation-apps.md`)

- Period column and allocation dimension (Department, Team, Region, …)?
- Extra grain (Role, Product, Channel) only if uniqueness is proven?

**Approval** (`approval-apps.md`)

- Stable entity key column (Deal ID, Request ID, …)?
- Allowed decisions (Approve / Reject / Counter, …)?
- Counter-value column, or status-only?

**Exception** (`exception-apps.md`)

- Stable operational key (SKU, Account ID, Job ID, …)?
- One exception per entity, or a composite key (Exception Type / Observation Date)?
- User override, or recommendation-only?

Then the cross-cutting interview. These three questions apply to **every**
type, including approval apps (that type is still a decision queue; the
approvals question is whether to keep the submit / audit-log action).

**Who uses this app?** — one line. Pre-fill the type's recommended audience
(`FP&A planner` / `ops or finance owner` / `reviewer` / `ops owner`).
Override if they named a role. The workbook still lands in the
authenticated user's home folder (SKILL.md Step 0).

**Editable fields (all types)** — which columns on the linked grid may
users type into? Show the recommended `{ id, type }` list; they may subset
or add names. Key columns and formula columns stay non-editable.

| Type | Users edit (recommended) |
|---|---|
| planning | Method, Pct Change, Dollar Change, New Amount, Rationale |
| allocation | Added Hires, Cost Uplift %, Rationale |
| approval | Decision, Approved Discount, Reviewer, Decision Note |
| exception | Override Order Qty, Decision, Owner, Resolution Note |

```bash
ruby -r ./scripts/lib/app_intake.rb -e 'p AppIntake.editable_fields_for("planning")'
```

**Approvals (all types)** — one question. Show the recommended purpose;
do not reclassify the app.

- Does this workflow need approvals? (yes / no)

If **no**, keep the linked grid or queue and omit the fixture's submit /
log-insert button and any status-update `whichRows` path. If **yes**, keep
the recipe's approval/audit layer (planning: submit / approve / request
changes + scenario status;
allocation: request log; approval: audit log + one-row status update;
exception: resolution log).

| Type | Recommended approval action |
|---|---|
| planning | submit, approve, or request changes: decision-log row + `whichRows` update of that scenario's status |
| allocation | log a hiring or reallocation request (off the editable plan grid) |
| approval | record Approve / Reject / Counter: audit-log row + `whichRows` on the stable entity key |
| exception | log a resolution for the selected operational entity |

```bash
ruby -r ./scripts/lib/app_intake.rb -e 'puts AppIntake.approval_purpose_for("planning")'
```

**Sigma Agent (all types)** — first ask whether to add one. If **no**, set
`agent.include` false and omit `document.agents` and `chat`. If **yes**, do
not stop at “what should the AI do?” Confirm the four-part capability
contract below. Prefill it from
`AppIntake.agent_capabilities_for(<appType>)`; let the user remove or add
specific targets:

- Add a workbook agent? (yes / no)

1. **Analyze** — which table elements may it query?
2. **Configure** — which controls may it set, including multi-select `add`?
3. **Navigate** — which pages or tabbed-container tabs may it open?
4. **Act** — which direct record/log writes may it perform, always with
   `requiresApproval: true`?

This distinguishes a read-only analyst (Analyze only), UI orchestrator
(Analyze + Configure/Navigate), and operator (all four). For a multi-module
workbook, prefer one module specialist per work surface over one mega-agent.
Compose agents in Step D.5 — the interview records capabilities, not raw
`agents[]` JSON.

| Type | Analyze (`dataSources`) | Act (`tools`) |
|---|---|---|
| planning | plan grid, plan ledger (actuals vs plan), scenario directory, decision log — actual vs baseline vs selected plan | read-only unless they asked the agent to submit or log; any write tool sets `requiresApproval: true` |
| allocation | allocation grid, working allocation, variance, request log — over/under, baseline vs added units, tradeoffs | read-only unless they asked the agent to log a request; any write tool sets `requiresApproval: true` |
| approval | entity directory, review queue, decision log — prioritize by policy breach, value at risk, and age | do not record a decision unless they asked for that tool; any write tool sets `requiresApproval: true` |
| exception | exception directory and action queue — rank unresolved items, skip already-logged resolutions | log-resolution (or equivalent) with `requiresApproval: true` |

A helper prints the same purpose and capability plan the manifest pre-fills:

```bash
ruby -r ./scripts/lib/app_intake.rb -e 'puts AppIntake.agent_purpose_for("exception")'
ruby -r ./scripts/lib/app_intake.rb -e 'p AppIntake.agent_capabilities_for("exception")'
```

**Look (one optional question, all types)** — skip if they already named a
brand, theme, or reference workbook. Do not turn this into a UX interview.

- Any existing workbook look to match, org theme, or brand colors?

If none, compose from the type table in Step D.4 and the org's most-used
theme (GET a live workbook, or the theme registry). Prefer **Light or an
org theme**. Do **not** default to Dark on a page with text/list entry
controls, and do **not** fall back to the `styling.md` exec-dashboard
example.

**Composition (one forced choice, all types)** — load
[`app-compositions.md`](app-compositions.md). App type is the semantic
architecture; composition is the visual work mode:

- `workbench` — context beside a wider editable grid;
- `queue-rail` — a wide queue beside narrow filters/detail/guidance;
- `builder-preview` — compact input rail beside a wider live result.

Recommend one from the user's job, then confirm or use it as an explicit
default. This does **not** create a fifth app type. Write the selected work
surface, primary action, supporting context, density, visual tone, and
above-fold elements to `/tmp/app-design-manifest.yaml`.

The intake helper exposes page-level recommendations for the fixture shells:

```bash
ruby -r ./scripts/lib/app_intake.rb \
  -e 'p AppIntake.composition_pattern_for("planning", "pg-build")'
# => :builder_preview
```

Do **not** proceed to spec draft until classification, grain keys, a
write-enabled connection, which fields users may edit, whether the
workflow needs approvals, and whether to include a workbook agent are
answered — or the user explicitly says to use the fixture defaults.

Restate the answers as a **build plan** before cloning, then wait for
confirmation:

```text
Build plan
- App: <type> for <audience>
- Grain: <keys>
- Users edit: <editableFields>
- Approvals: yes/no — <purpose>
- Agent: yes/no — <purpose>
- Composition: <workbench | queue-rail | builder-preview>
- Work surface: <element> — primary action: <action>
- Fixture: <fixture>
```

### Step C — Record a local intake manifest

Write the answers outside the skill tree before drafting. Conventional path
is `/tmp/app-intake.json`.

```bash
ruby scripts/lib/app_intake.rb init /tmp/app-intake.json planning
# fill answers, audience, editableFields, sources, approvals, agent,
# grain.expectedRows from Step B
ruby scripts/lib/app_intake.rb validate /tmp/app-intake.json
```

`init` refuses to overwrite. Allowed `appType` values are `planning`,
`allocation`, `approval`, and `exception`. The helper checks that `recipe`
and `fixture` match the type, that `grain.keys` includes the required keys
for that type, that `editableFields`, `approvals`, and `agent` are present,
and that the fixture file exists on disk.

Use `--strict` only when sources are bound (write connection, source
connection, table path, expected row count):

```bash
ruby scripts/lib/app_intake.rb validate --strict /tmp/app-intake.json
```

The manifest is local run state. Do not commit customer table paths,
connection IDs, folder IDs, or workbook IDs into this skill.

### Step D — Clone the fixture, then the normal build loop

1. Copy the fixture named in the manifest (under
   `reference/workflows/fixtures/`) to a working spec, e.g.
   `/tmp/workbook-spec.yaml`.
2. Load `discover.md`. Replace placeholders (`<FOLDER_ID>`,
   `<WRITE_CONNECTION_ID>`, `<SOURCE_CONNECTION_ID>`,
   `[Source/…]` column names) with values the API actually returned.
   **Never invent column names.** If the warehouse is not already at the
   recipe grain (for example people rows instead of Period × Department),
   derive grain with formulas and a grouping from columns that exist —
   a constant Period formula is fine. Probe `DISTINCT` before writing
   status/closed predicates (`discover.md`). Do not rename a formula
   column to a label that contains `$`; later `[Plan $]` refs compile as
   `Unknown column`.
3. Load the matching recipe and `../specification/input-tables.md`. Adjust
   grain columns and formulas to the answers; do not skip the recipe's
   non-negotiable layers. Keep the fixture's `tableElementId` on
   `insert-rows` / `update-rows` / `delete-rows` (live OpenAPI). A stale
   `table:` key fails every element oneOf and Sigma reports the masked
   `Invalid kind: "button"`. Keep `clear-control` as
   `scope: { type: page, pageId: <page id> }` — a stale `page:` key is
   dropped on GET and click fails with `No target page is selected`.
   Entry `text` / `text-area` controls in the fixtures already carry
   `mode` / `case` / `includeNulls` / `showOperators`. Copy that block
   onto any new entry control (`controls.md`); omit it and POST fails as
   `Invalid kind: "control"`.

   Apply the interview:

   - **Editable fields.** On the linked grid, keep only
     `editableFields` as `{ id, type }` columns. Key columns stay keys;
     formula columns stay formulas. If they named extra fields, add
     `{ id, type }` columns after discovery — do not invent source
     column names. If a formula referenced a dropped edit column,
     rewrite it (usually `Coalesce` to the baseline) rather than leaving
     a dangling `[Column]` ref.
   - **Approvals.** If `approvals.include` is false, omit the fixture's
     log-insert buttons and any status-update `whichRows` path. Keep the
     linked grid. On planning, keep the New Scenario overlay (that creates
     directory rows; it is not the approval path). Log-only controls go with
     the review buttons. The empty log table may stay on a hidden page. If
     `approvals.include` is true, keep the recipe's approval/audit layer and
     the allowed decisions from Step B.
4. Load [`app-compositions.md`](app-compositions.md), then
   `../specification/styling.md` as a **library**, not a stamp. Apply the
   selected design manifest and one operational composition before paint.
   A design pass is required — do not ship the fixture's default grid —
   but do **not** apply the five-pattern exec-dashboard stack (navy hero +
   three white KPI cards + `##` section headers) to every app. That stack
   is one composition in `styling.md`, for dashboards.

   Compose from:

   - the type's visual job (table below);
   - the org's existing theme (GET a live workbook's `settings.theme`, or
     the theme registry) rather than the sample Tailwind palette;
   - any branding the user stated in Step B;
   - the **anti-pattern list** in `styling.md` (no focal point, equal-width
     everything, flat type, accent sprayed on every card).

   `Styling.header` / `section_card` / `gradient_header` and
   `Composition.compose(pattern: :exec)` emit the **dashboard** composition.
   Do not call them as the generate-app default. Use
   `Composition.compose(pattern: :workbench | :queue_rail |
   :builder_preview)` or hand-compose layout when none fits. Keep the
   architecture fixture's element semantics; the composition only changes
   hierarchy and placement.

   For multiple visible work pages, `:app_header` means the compact
   identity/navigation/utility shell from `app-compositions.md`, not one
   oversized title floating above the page. Wrap caller-authored identity,
   navigation, and utility elements with `Styling.app_shell`; keep the
   page-task title/subtitle smaller inside the content. Single-page apps may
   use the identity + utility variant.

   | Type | The page is for | What has to be true (not chrome) |
   |---|---|---|
   | planning | building and reviewing a plan | Workspace may show a few **plan measures** (revenue, EBITDA, profit impact). The grid lives on Build the Plan and is the thing you can work in. Status counts are not a KPI strip. |
   | allocation | redistributing against a budget | The allocation grid is usable without scrolling past dashboard chrome. Variance is visible, not a 3-KPI strip. |
   | approval | reviewing rows and recording a decision | The queue is the page. The audit log is a trail, not a second dashboard. |
   | exception | triaging urgency | The exception queue is the page. Status belongs in the title line or a single chip — not a branded hero and not a 3-KPI strip. Red only if a value is actually critical. |

   Do **not** reuse a composition from `styling.md` as this type's look.
   Navy/slate hero + KPI strip (in or under the hero) + quiet uppercase
   QUEUE/LOG labels + Tailwind `#3B82F6` is skill chrome. It still reads
   as a template when you move the KPIs *into* the hero. Pick palette,
   density, and what opens the page from **this** domain and org (GET a
   live workbook's `settings.theme`, or none — most orgs are unthemed).

   Run all three passes from `app-compositions.md`: functional,
   composition, then polish. Export every visible page PNG and read it as a
   user of this app, then against the anti-pattern list. **Inspect at least two renders**;
   the second must re-check defects found in the first.
   Fail the pass if any of:

   - a default auto-arrange grid;
   - a clone of the `styling.md` exec-dashboard example;
   - recognizable skill chrome (dark hero, equal KPI strip, `#3B82F6` CTA,
     `##` / uppercase QUEUE/LOG labels);
   - **status as a 3-KPI strip** — queue/status counts belong in the title
     line or one chip. Planning Workspace **plan measures** (revenue,
     EBITDA, profit impact) are the model, not that fail;
   - **entry controls you cannot see** — white-on-white or Dark-on-dark
     text boxes. A tinted well behind controls on Light is one verified
     way to show field chrome; it is not a look to clone;
   - **`settings.theme.name: Dark` on a data-entry app** unless the user
     asked for dark;
   - **empty work surface** — Build the Plan / allocation grid / review
     queue showing `No data` when the governed source has rows. Planning:
     create one scenario before this pass (the spec cannot seed an empty
     input table). Approval: cap the queue; do not link every open entity;
   - **broken compile in the PNG** — `null` KPI, `Unknown column`, or
     `Invalid Query` on a measure the page is for.
   - **truncated primary headers/values**, fewer than roughly six useful
     queue rows, a row action detached from the selected key, or a large
     unexplained blank region;
   - **empty audit/log table as a focal panel** — an append-only log may
     correctly have zero rows before first use, but keep it hidden, tabbed,
     compact, or below fold;
   - controls far from the surface they affect, a decorative chart with no
     baseline/variance/risk/preview job, or no visually dominant work
     surface.
   - a large standalone report title instead of app identity/navigation/
     utility chrome on a workbook with multiple visible work pages.

   Name the design choices in the handoff summary (`composition.md`).
   Do not add a new composition to `styling.md` from a one-off app.
5. **Workbook agent.** Fixtures stay agent-free; compose after clone.
   If `agent.include` is false, omit `document.agents` and any `chat`
   element. If **true**:

   - Load `../specification/agents.md`. Confirm the org has workbook AI
     agents enabled. If it does not, degrade to that file's static
     sample-prompt text — never POST a cosmetic `chat` on a gated org.
   - Build with `Richness.agent` + `Richness.chat`
     (`scripts/lib/richness.rb`). `instructions` must encode the confirmed
     Analyze / Configure / Navigate / Act boundaries and any required tool
     order. `dataSources` are only confirmed Analyze targets that still
     exist on this spec:

     ```bash
     ruby -r ./scripts/lib/app_intake.rb -e 'p AppIntake.agent_data_sources_for("exception")'
     ```

   - **Analyze only:** omit `tools` entirely (not `tools: []`).
   - **Configure / Navigate:** add granular direct action tools — one named
     task per control group or destination. Use `set-control-value`
     (`selectionMode: add` for a multi-select), `navigate`, or `select-tab`.
     These UI-state tools normally do not need approval.
   - **Act:** inline direct `insert-rows` / `update-rows` / `delete-rows`
     effect steps and set `requiresApproval: true`. Build them with
     `Richness.agent_action_tool`, which refuses an unapproved write.
     Never emit `{kind: sequence, sequenceId: ...}` for a spec-created
     workbook: sequences can be referenced after a human creates one in the
     UI, but cannot be defined by the spec and a dangling id rejects POST.
   - Prefer several narrow tool descriptions (`Set region filters`, then
     `Open review tab`) over one generic “operate workbook” tool. State
     sequencing constraints in both agent instructions and tool descriptions.
     For unrelated page jobs, use separate module-specialist agents.
   - Include every Act target (or its authoritative audit/read path) in
     Analyze. After both approved and declined actions, instruct the agent to
     query that source before claiming current state or row counts. Acceptance
     is a zero-row delta after decline and exactly-one-row delta after one
     approved write — conversation history and a tool-success card are not
     data evidence.
   - Place `chat` as a **supporting rail**, not the focal work surface.
     On planning, replace `txt-agent-rail` on Review & Approve. The grid
     on Build the Plan keeps the wide columns from Step D.4. Several
     `chat` elements may share one `agents[]` id.
6. Continue from SKILL.md Step 5: validate (`./scripts/validate-spec.sh`),
   POST, GET the spec, `./scripts/verify-workbook.sh`, then the recipe's
   runtime gates in `runtime-verification.md`. Union `name` may not
   round-trip (`Ledger Union` → `Union of 2 Sources`); later PUTs use the
   GET prefix. `validate-spec.sh` can flag `[scenario]`-style control
   handles as unqualified refs — inspect before rewriting them.

Published data entry cannot be set from the spec. Before handoff, for every
input table: element kebab → Set data entry permission → Only in published
version. The setting is absent from `GET /spec`.

## Fixtures

The four files in `fixtures/` are **architecture** templates, not a visual
system. They encode grain, writeback, and layout membership. Shared rules
are in `fixtures/README.md`. Copy architecture from the matching fixture;
compose the look in Step D.4. Do not assemble an operational app from
`example-full.yaml` (that file is an analytical dashboard).

Fixtures stay **agent-free** (`document.agents` and `chat` are composed in
Step D.5 when `agent.include` is true). They **do** include the default
approval/log layer; Step D.3 drops it when `approvals.include` is false.
Planning is a **multi-page studio shell** (Workspace, Scenarios, Build the
Plan, Review & Approve, hidden Data, New Scenario overlay). The other
three types stay single-page architecture until they have a house example
as strong as that.

| Type | Fixture | Required layers |
|---|---|---|
| planning | `fixtures/planning-app.yaml` | actuals + plan base, empty scenario directory + create overlay, cross-join matrix, linked plan grid, union ledger, append-only decision log, submit/approve/request-changes with `whichRows` |
| allocation | `fixtures/allocation-app.yaml` | period × dimension baseline, linked allocation grid, working allocation + variance, request log |
| approval | `fixtures/approval-app.yaml` | governed entity directory, linked review queue, computed impact, append-only audit log, `whichRows` on the stable entity key |
| exception | `fixtures/exception-app.yaml` | exception directory, linked action queue, deterministic recommendation (not labeled “AI”), override coalesced into final action, resolution log |

## Out of scope here

- Recipe grain, override math, financial sign, and runtime-gate tables —
  those stay in the four `*-apps.md` files.
- Image-driven reproduction — `from-image.md`.
- Read-only dashboards — `composition.md`.
- Printable documents — `sigma-reports`.
