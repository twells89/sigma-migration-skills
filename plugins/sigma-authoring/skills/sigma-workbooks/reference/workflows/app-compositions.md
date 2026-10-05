# Operational app compositions

Load this after [`generate-apps.md`](generate-apps.md) classifies the workflow
and before styling. The app type answers **how data and writeback work**.
Composition answers **how the user does the job on screen**. Keep those choices
independent:

```text
planning / allocation / approval / exception    = semantic architecture
workbench / queue-rail / builder-preview         = visual composition
```

These patterns distill useful design grammar from live operational workbooks.
They are not copies: no source workbook's palette, logo, wording, imagery,
column names, organization ids, or full page sequence belongs here.

## Choose the composition

| Composition | Pick it when | Primary surface |
|---|---|---|
| `workbench` | Users compare context and edit a plan/allocation | editable grid, wider than its chart/context |
| `queue_rail` | Users prioritize records and take action | queue/table, with a narrow filter/detail/guidance rail |
| `builder_preview` | Users configure inputs and inspect generated results | preview/results, with a compact input rail |

These are defaults, not new app types. A planning app can use a workbench; an
exception app can use queue-rail; an allocation app can use builder-preview.
Use hand-authored layout when none fits. A launcher is allowed only as a door
to multiple real work surfaces; never count it as the operational surface.

## Design manifest — required before layout

Write this beside the intake manifest (for example
`/tmp/app-design-manifest.yaml`). It is local run state, not a fixture:

```yaml
composition: workbench
workSurface: plan-grid
primaryAction: submit-plan
supportingContext: actual-vs-plan
secondaryRail: null
density: compact
visualTone: operational
accentBasis: demand
aboveFold:
  - plan-grid
  - actual-vs-plan
  - submit-plan
```

Rules:

- `workSurface` is one concrete editable grid, queue, or preview — never
  “dashboard.”
- Put `primaryAction` in the normal reading path, adjacent to the surface it
  affects. Do not place a row action in a detached form with no selected key.
- `supportingContext` must help the decision (baseline, variance, risk, or
  preview). Decorative charts do not qualify.
- `aboveFold` must contain the work surface and primary action. An empty log,
  agent rail, or KPI row cannot displace them.
- Derive `accentBasis` from the domain or the org theme. Do not default every
  app to the same blue, mint, or navy.

## Application shell header

`app_header` is **not** permission to float one oversized report title above
the page. Most multi-page operational apps need a compact shell before the
page task:

```text
[app identity]       [page navigation / active state]       [utility context]
```

Examples of utility context are selected plan, queue count, user role, or one
global action. Put the smaller task title/subtitle inside the content below the
shell. A single-page app may use the reduced identity + utility variant.

Author the identity/navigation/utility as real `text`, `navigation`, or
`button` elements, then wrap their ids with the API-safe light shell helper:

```ruby
Styling.app_shell(
  id: 'app-shell',
  identity_id: 'app-identity',
  navigation_id: 'app-nav',
  utility_id: 'app-context'
)
```

The helper emits a square light container and 6/11/7 column split. It does not
fake navigation: use a real `kind: navigation` element when destinations are
available. Do not use `Styling.header` or `gradient_header` here — those are
dark dashboard/hero treatments, not app chrome.

## API-safe layout emitters

`scripts/lib/composition.rb` emits sibling `<Element>` nodes for all three
patterns. Wrap the result in the normal `<Page ...>` block under
`document.layout`. Roles are explicit — none of the operational roles are
inferred from element kind.

### `workbench`

```ruby
Composition.compose([
  { id: 'title', role: :app_header },
  { id: 'controls', role: :action_bar },
  { id: 'actual-vs-plan', role: :context },
  { id: 'plan-grid', role: :work_surface },
  { id: 'plan-units', role: :summary },
  { id: 'plan-change', role: :summary },
  { id: 'submit', role: :footer }
], pattern: :workbench)
```

Top to bottom:

| Role | Height | Width |
|---|---:|---:|
| `app_header` | 3 | full |
| `action_bar` | 3 | full |
| `context` | 18 | 8/24 |
| `work_surface` | 18 | 16/24 |
| `summary` | 8 | even split |
| `footer` | 4 | full |

The asymmetry is deliberate: context explains; the grid is where work happens.
If context is absent, the work surface takes full width. For a Submit/Review
workflow, use a second page with queue-rail rather than stacking review below a
long planning grid. The engine resolves this through the named
`:pair_8_16` split.

### `queue_rail`

```ruby
Composition.compose([
  { id: 'title', role: :app_header },
  { id: 'filters', role: :action_bar },
  { id: 'review-queue', role: :queue },
  { id: 'decision-rail', role: :rail },
  { id: 'decision-actions', role: :footer }
], pattern: :queue_rail)
```

| Role | Height | Width |
|---|---:|---:|
| `app_header` | 3 | full |
| `action_bar` | 3 | full |
| `queue` | 22 | 17/24 |
| `rail` | 22 | 7/24 |
| `footer` | 4 | full |

The queue stays wide enough for readable identifiers and measures. The rail is
for filters, selected-record context, or read-only guidance — not a second
dashboard. If there is no rail, the queue takes full width.

Prefer a normal table/input-table queue while bound repeated-container children
remain rejected by POST (`layout.md`). A UI-authored case-card feed is visual
inspiration, not evidence that its GET document can be replayed. The engine
resolves queue/rail through the named `:pair_17_7` split.

### `builder_preview`

```ruby
Composition.compose([
  { id: 'title', role: :app_header },
  { id: 'reset-save', role: :action_bar },
  { id: 'assumptions', role: :builder },
  { id: 'impact-preview', role: :preview },
  { id: 'preview-total', role: :summary },
  { id: 'save-request', role: :footer }
], pattern: :builder_preview)
```

| Role | Height | Width |
|---|---:|---:|
| `app_header` | 3 | full |
| `action_bar` | 3 | full |
| `builder` | 24 | 7/24 |
| `preview` | 24 | 17/24 |
| `summary` | 8 | even split |
| `footer` | 4 | full |

The builder rail contains only controls or editable assumptions needed for the
current result. Put explanations in short labels, not another long text rail.
The preview must change when inputs change; otherwise this is a form beside an
unrelated dashboard. The engine resolves builder/preview through the named
`:pair_7_17` split.

## Visual language without copying

Preserve relationships, not paint:

- compact control/action bar before a comparison surface;
- asymmetric primary/supporting widths;
- submit and review as separate page jobs;
- semantic tint only for actual exception/approval state;
- status pills and one queue count in context, not a generic status KPI strip;
- selected-record context beside the queue;
- restrained section wells to group a task, not one pastel band per element.

Choose a domain palette from the org theme plus one semantic accent. Do not copy
logos, hero photos, exact colors, icon sets, or prose from a reference app.
Use `styling.md` for supported fields after composition is fixed.

## Three-pass build — do not stop after compile

1. **Functional:** POST/GET, compile, grain/cardinality, non-empty work surface,
   deterministic formulas, and writeback structure.
2. **Composition:** apply one manifest and one pattern; place the primary action
   beside the surface; keep source/audit plumbing hidden or compact.
3. **Polish:** export every visible page PNG at normal size, inspect it, revise,
   export again. Two PNG inspections are the minimum for an operational app.

The second render must specifically re-check the issues found in the first.
“POST succeeded” and “all elements compile” are not visual acceptance.

## PNG failure gate

Fail and revise when any visible page has:

- truncated headers or values in the primary work surface;
- fewer than roughly 6 useful rows visible in a queue/detail table;
- a form or action rail with no visible selected record/key;
- an empty audit/log table consuming a major above-fold region;
- large unexplained blank areas inside a grid or container;
- controls separated from the surface they affect;
- a primary action outside the normal top-to-bottom reading path;
- a default full-width raw table with no hierarchy or decision context;
- more than roughly ten visible queue columns when secondary fields could move
  into the selected-record detail rail;
- decorative charts that do not explain baseline, variance, risk, or preview;
- repeated lockup/title/card-label copy or two charts of the same measure at
  the same grain;
- identical pastel section bands or the same accent on every surface;
- no single visually dominant work surface;
- a large standalone page title with no app identity/navigation/context shell
  when the workbook has multiple visible work pages;
- any existing `generate-apps.md` failure (invisible entry controls, Dark
  data-entry default, generic 3-KPI status strip, empty work surface, or query
  error).

An append-only log may correctly have zero rows before first use. Keep it on a
hidden audit page, behind a tab, or in a compact below-fold region until it has
evidence to show; do not let “No data” become a focal panel.
