# Remodeling a LookML estate for Sigma (not porting it)

**Read before scoping any LookML project above a few dozen views.**

A mature LookML model encodes Looker's constraints as much as the business's semantics.
Reproducing that shape in Sigma imports the constraints along with the content: the model comes
out larger than it needs to be, slower, and harder to govern — and much of the work is spent
rebuilding scaffolding Sigma does natively.

Faithful reproduction is still the DEFAULT for a single dashboard, and parity is still the gate
(`refs/modeling-strategy.md`). This file is about the other case: a large estate, where a 1:1
port is the wrong target and the conversation with the customer is part of the job.

The numbers below come from one production LookML model — 318 joins over 149 distinct physical
views, ~2,700 dimensions, ~1,970 measures, ~60,000 lines — and are included because the *shape*
recurs, not because the exact figures will.

---

## The tell: measure count grows combinatorially, not semantically

Count how many measures are period or comparison variants of another measure:

```bash
grep -rhoE '^\s*measure:\s*\w+' views/ | sed 's/.*measure: //' | \
  grep -icE '(_ty|_ly|ty_|ly_|yoy|mtd|qtd|ytd|wtd|dtd|rolling|ttm|variance|_diff|_chg)'
```

In the model above: **40% carried TY/LY markers, 28% variance/diff, 20% period-to-date, 10%
rolling/TTM.** Those are not 1,970 distinct business metrics. They are a smaller set of base
metrics crossed with a comparison grid, because Looker has no first-class period comparison in
the semantic layer.

Sigma metrics carry a `timeline` block — `dateColumnId`, `truncation`, and
`comparison: { comparisonPeriod, direction }` — so one metric plus a period control expresses
what Looker needed a family of measures for.

**Do not quote a reduction multiple from name analysis.** A conservative name-based collapse on
that model gave only ~1.5× (1,971 → 1,329 roots); the real reduction is larger but is not
measurable from names. Quote the percentages above and say usage data will size it.

---

## Scope by usage before scoping by structure

The single highest-leverage input on a large estate. Looker's **System Activity** (the
`i__looker` explores) reports field- and dashboard-level query history. Ask for an export of
fields queried in the last 90 days.

Porting the *used* subset rather than everything is usually the difference between a
multi-quarter program and a focused project, and it answers the role-playing question below for
free. Frame it to the customer as *"we don't want to carry a decade of dead fields into your new
platform"* — they get a clean model, we get tractable scope.

If they push back, offer to port the top N dashboards to parity and let usage decide the rest.

---

## Five shapes that should change on the way across

### 1. Role-playing explosion (`from:` aliasing)

One physical view joined many times under different aliases — commonly a date dimension, one
alias per date role (filled / sold / written / returned / expiration …). In the model above a
single `timeframes` view was joined **55 times**; 209 of 318 joins were `from:` aliases over 54
base views.

`scripts/check_input_completeness.py` resolves aliasing and reports both counts, so the ratio is
visible before conversion.

Target: one element per physical table in a shared dimension model, with a relationship per role
that is actually used. Usage data decides which roles survive — most estates use a handful.

### 2. A parameterized calendar UDF

Looker cannot express relative-period comparison in the semantic layer, so mature models push it
into a warehouse function called with request state. The pattern looks like a `derived_table`
selecting `FROM TABLE(some_fn(...))` where the arguments are `{% parameter %}`,
`{% date_start %}` / `{% date_end %}`, `{{ _user_attributes[...] }}`, and `{{ _filters[...] }}`
— returning a calendar plus TY/LY and MTD/QTD/YTD flags.

**Do not port this as a Sigma data-model custom SQL with `{{param}}` bindings.** A workbook
control bound only to a DM custom-SQL parameter is inert: it renders, and it filters nothing.

Target: bind the underlying fiscal-calendar table directly (these models usually already read it
somewhere — look for a sibling view selecting the plain date table), then rebuild period flags as
Sigma date logic and relative-date filters at the workbook layer.

Lead with this as a **simplification and a performance win** — it removes a per-query function
call — not as a gap.

### 3. Liquid-driven dynamic table switching

`sql_table_name:` containing `{% assign %}` + `{% if %}` that swaps the physical table based on a
user filter (current vs. archive, for example). Sigma has no per-query dynamic table source.

Target: push it into the warehouse as a view spanning both tables (or a single partitioned /
clustered table) and select that. It removes a BI-tool-specific hack, works for every consumer of
the data rather than just Looker, and deletes one of the harder conversion items outright.

### 4. Security threaded through join conditions

Watch for models that have *removed* their `access_filter:` blocks and instead hand-thread a
tenant predicate through every `sql_on` with `{% condition %}`. In the model above that pattern
accounted for most of **607** `{% condition %}` pairs. It is fragile — one missed join leaks —
and it protects only Looker.

Target, in order of preference:
1. **Warehouse row access policy** on the tenant key. Enforces for every consumer, not just BI.
2. Sigma RLS: one boolean calc column per secured element
   (`CurrentUserAttributeText("<attr>") = [<Key>]`) plus an element filter including only `true`.

Either way this is a **net deletion**, not a translation. Preserve any documented superuser
bypass (e.g. an attribute value containing `>` meaning "all tenants").

`scripts/detect_rls.py` finds the constructs; this is about where they should land.

### 5. Many-to-many joins

`relationship: many_to_many` maps to the closest Sigma type (`N:1`) with a warning, because
Sigma has no native M:N. Most M:M joins in practice are either a bridge/link table (a view whose
grain is exactly two foreign keys) or a detail table mislabelled as M:M.

Target: decompose through the bridge as N:1 → 1:N. Confirm the bridge's grain before relying on
it — that grain is what `uniqueKeys` must declare.

---

## Diagnosing where fan-out actually lives

`sql_distinct_key:` is Looker's symmetric-aggregate hint. Every measure carrying one is telling
you it must de-duplicate, and the columns in the key tell you **what it is de-duplicating
against**. That is a free map of the model's fan-out.

```bash
grep -rhoE '\$\{(\w+)\.\w+\}' views/*.lkml --include='*' | sort | uniq -c | sort -rn | head
```

Run it over `sql_distinct_key` values specifically and look at which *other* view dominates. In
the model above, 111 measures carried a distinct key and **every one referenced at least one
other view** — overwhelmingly the calendar view. That is not 111 independent problems; it is one
structural fan-out (the calendar join) reflected 111 times.

Two consequences:

- **`sql_distinct_key` cannot be mapped into `uniqueKeys`.** `uniqueKeys` lists columns on the
  element; a cross-view grain declared there is the *wrong* grain, and a wrong grain under
  semantic aggregates produces wrong numbers. The converter reports these instead. What maps
  cleanly is `primary_key: yes`.
- **Fix the fan-out at its source and the de-dup becomes unnecessary.** Remodel the calendar per
  §2 and a large share of those `sum_distinct` measures collapse to plain `Sum()`.

Also check coverage: a view with no `primary_key: yes` has undeclared grain, and the converter
now warns for each one. The most-joined views are the ones where this matters most, and they are
often the ones missing it.

---

## What not to carry across

High volume, low value, and Sigma provides the capability natively:

- `drill_fields:` — Sigma drills without per-field declaration.
- `set:` definitions and `fields:` allow/deny lists — re-curate deliberately instead; what
  business users should see is a decision worth making once, in the open.
- `html:` blocks — conditional formatting is native.
- `link:` deep-links — rebuild only the ones that are actually used.

Agree up front that none of this is in the parity contract. It removes a lot of noise from the
acceptance conversation.

---

## What to ask for

- The **complete LookML project**, ideally a git clone — all views, the `.model.lkml`, and the
  manifest. `scripts/check_input_completeness.py` will tell you if what you received is partial,
  and a partial export is the single most common cause of a migration being wrongly written off.
- The **System Activity usage export** (fields + dashboards, 90 days).
- Which explores **extend** any `extension: required` base explore, and whether other subject
  areas are in scope.
- The **unique key per table** for everything in scope.

## What not to promise

- Semantic aggregates (relationship cardinality + `uniqueKeys` driving fan-out-safe aggregation)
  is a **gated private beta**, reviewed case by case. It can be requested for a prospect; do not
  commit to a date.
- **M:M is not supported** in that beta. Decomposition through a bridge works, but it is modeling
  work, not a toggle.
- Do not make forward-looking statements about that feature's GA path without checking with the
  product team first.
