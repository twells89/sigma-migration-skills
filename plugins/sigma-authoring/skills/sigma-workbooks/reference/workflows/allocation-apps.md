# Allocation and capacity apps

Entered via [`generate-apps.md`](generate-apps.md) when the user asked to generate an app.

Use this pattern when the source contains:

- Budget / Target / Quota / Capacity measures;
- Actual / Current / Baseline measures;
- a dimension across which values can be allocated (Department, Team, Region,
  Territory, Channel, Role);
- usually a period grain.

Examples include workforce planning, marketing budget allocation, quota and
territory planning, and capacity assignment.

## Grain

The typical editable grain is:

```text
Period × Allocation Dimension
```

Add Scenario if multiple plans coexist. Add Role, Product, or Channel only when
users need to edit at that lower grain and uniqueness is proven.

## Architecture

1. **Baseline** — actual/current capacity and governed budget or target.
2. **Linked allocation grid** — baseline context as stable keys; editable
   units, uplift, override, and rationale.
3. **Working allocation** — calculated result and variance.
4. **Optional request queue** — hiring or reallocation requests.
5. **Decision log** — approvals separated from the editable plan.
   Generate-apps Step B asks whether this workflow needs that layer; if
   they declined, keep the allocation grid and omit the request-log
   button.

Workforce example:

```text
Plan Headcount = Baseline Headcount + Added Hires

Plan Cost =
  Baseline Loaded Cost × (1 + Cost Uplift %)
  + Added Hires × Monthly Loaded Cost per Hire

Vs Budget = Plan Cost - Budget
```

Use precise labels: a row-level percentage is an uplift to that row, not a
compounding growth driver.

## Row population

Do not seed this grid with an `insert-rows` button. Build the governed
`Period × Allocation Dimension` baseline, then link editable columns to its
stable keys.

If the warehouse is not already at that grain — for example one row per
employee — derive it in the workbook: group to the allocation dimension,
Period as a constant formula if there is no period column, headcount/cost as
`Count`/`Sum` over a probed status value (`DISTINCT` first), budget or hire
cost as formulas off real columns. Do not invent `[Source/Budget]` or
`[Source/Period]`. Do not rename formula columns to labels that contain `$`
(`Plan $` / `Loaded $` compile as `Unknown column`).

## Scope

Keep the editable all-dimension grid complete. If a dashboard control filters
that grid, every descendant KPI inherits the filter. Scope selected views by
formula or provide an independent all-scope lineage for comparisons.

## Agent

Generate-apps Step B offers this agent and pre-fills the recommended
purpose; skip this section if they declined.

The agent should explain:

- which dimension has highest plan cost or capacity;
- whether variance comes from baseline underfunding or added units;
- concentration and timing;
- tradeoffs of a proposed allocation.

## Runtime gates

- no-edit plan equals baseline;
- expected grid rows equal periods × allocation members;
- added units affect quantity by the exact amount;
- uplift and unit additions both contribute correctly;
- variance equals plan minus budget or target;
- year-end KPI sums the target month across dimensions, not `Max` of one
  dimension;
- approval/log action persists;
- agent separates structural baseline variance from new allocation changes.

Enable published data entry on every input table in the UI before handoff.
