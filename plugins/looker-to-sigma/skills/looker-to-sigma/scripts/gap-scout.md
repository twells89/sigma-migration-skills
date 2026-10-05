# gap-scout subagent — guide for the main agent (Looker → Sigma)

When `convert_lookml_to_sigma` / `scout-validate.py` flags a **LookML construct** with no clean
Sigma rewrite (a measure the converter could only approximate or had to drop), spawn a separate
subagent — the "gap scout" — to find a Sigma translation that works against the live Sigma site,
then persist it so future conversions apply it automatically.

Validated translations go to `~/.looker-to-sigma/learned-rules.yaml` (customer HOME, not the
skill repo). `scripts/learned-rules.py` loads them; the build step applies them before falling
back to a WARN.

## When to spawn

For each LookML field the converter buckets as **restructure** or **no-equivalent** (the
`CONVERTER-FINDINGS.md` BUG3–BUG9 class — things that emit a literal `${...}`, a `0` where a
`1.0` belonged, a bogus `CountIf`, or a phantom column):

| LookML construct | Candidate Sigma approach to try |
|---|---|
| **ratio measure** (`type: number`, sql references other `${measure}`s, e.g. AOV = revenue/orders) | substitute each `${measure}` with its Sigma agg formula: `Sum([Master/Net Revenue]) / NullIf(CountDistinct([Master/Order Id]), 0)`; preserve `1.0 *` and `NULLIF`→`NullIf` |
| **filtered measure** (`type: sum`/`count` + `filters:`) | `SumIf([Master/Col], <cond>)` / `CountIf(<cond>)` built from the `filters:` block |
| `type: percentile` / `type: percentile_distinct` | `Percentile([Master/Col], p/100)` (NOT `CountIf`) |
| `type: median` | `Median([Master/Col])` |
| **Liquid `{% parameter %}` measure** | a workbook **control** + an `If`/`Switch` on the control value — usually a Phase 5 UI wiring; scout the static fallback |
| **`type: count` on a joined view** | `CountDistinct([Master/<that view's PK>])` (a plain `Count()` counts fact rows, not the joined entity) |
| **table calc** (`dynamic_fields`: `running_total`, `pct_of_total`, `offset`) | `CumulativeSum` / `GrandTotal` denominator / `Lag` in a date- or category-grouped element |
| **`sql_distance` / `sql` with warehouse-specific funcs** | translate the SQL via `convert_sql_to_sigma_formula`, else escalate |
| **`access_filter` / `sql_always_where` (RLS)** | a `CurrentUserAttributeText(...)` calc col + element filter (see Phase 1.5 / `apply_sigma_rls.py`) — usually handled there, escalate only if the predicate has no Sigma analog |

Spawn ONE scout per distinct construct; run them in parallel.

## How to spawn (from the main agent)

Use the Agent tool, `subagent_type: 'general-purpose'`. Self-contained prompt:

```
You are a translation scout for a Looker→Sigma migration. Propose a Sigma formula that
replaces a LookML measure/construct, validate it against the live Sigma API, and persist the rule.

INPUTS
- LookML construct/pattern: <e.g. "ratio_measure" or "percentile">
- Sample LookML from the view(s): <2-5 real measure blocks, with type:/sql:/filters:>
- Sigma data-model id: <dm-id>
- Sigma denorm element id: <element-id>   (the joined "Order Fact"-style element)
- Sigma folder id: <folder-id>

PROCEDURE
1. Read refs/dashboard-contract.md + the sibling sigma-workbooks spec (function-context rules:
   window funcs error in grouping-table calc cols; CumulativeSum/DateLookback need a
   date-grouped element; CountOver/SumOver fail in DM/master calc cols — see memory).
2. Propose ONE candidate Sigma formula referencing columns as [Master/<Display Name>]
   (joined-view cols carry the alias suffix, e.g. [Master/Region (customer_dim)]).
3. Validate + persist (`scout-validate.py` self-authenticates through the
   browser-first shared Sigma client):
     python3 scripts/scout-validate.py \
       --formula '<candidate with REAL [Master/Col] names>' \
       --feature '<construct>' --pattern '<LookML regex; capture field refs>' \
       --template '<Sigma template using \1, \2>' \
       --hint '<post-publish caveat, e.g. "needs a date-grouped element">' \
       --description '<one-line>' --example-from '<measure name>' \
       --data-model-id <dm-id> --element-id <element-id> --folder-id <folder-id> \
       --home ~/.looker-to-sigma   [--kind table]
4. Parse JSON: status=validated → done; status=error → retry (≤3). After the last
   failed attempt the result carries an `escalation.dry_run_cmd` / `escalation.file_cmd`
   and the gap is left as a WARN. Do NOT file anything yourself — see "Opt-in issue
   filing" below.

OUTPUT
One paragraph: construct, candidate, status, and — if escalated — the
`escalation.dry_run_cmd` so the main agent can offer the user a tracking issue.
The validator auto-deletes its test workbook.
```

## Opt-in issue filing (escalations)

Filing a GitHub issue is **opt-in and confirm-before-file** — never automatic.
When `scout-validate.py` returns `status=error`, its `escalation` block carries
ready-to-run commands for the shared `escalate-gap.py` filer. The main agent:

1. Runs `escalation.dry_run_cmd` — files NOTHING; prints the drafted issue, the
   target repo(s), and any existing open issues/beads that already cover the gap.
2. Shows the user that draft and asks whether to open the issue.
3. Only if the user says yes, runs `escalation.file_cmd` (the same command + `--yes`).

LookML construct gaps are **converter** gaps, so they mirror to both converter repos
(`sigma-data-model-manager` + `sigma-data-model-mcp`) with a cross-link and a bead as the
authoritative tracker. (A workbook-builder gap — e.g. a layout / format / tile-mapping miss in
`build_workbook.py` — uses `--category builder`, which routes to `sigma-migration-skills`.)
See `scripts/escalate-gap.py`.

## What the scout depends on

- `scripts/scout-validate.py` — builds a throwaway test workbook (Master from the DM element
  + a column using the candidate), checks the column's resolved type via
  `/v2/workbooks/{id}/elements/{el}/columns`, persists on success, deletes the test workbook.
- `scripts/learned-rules.py` — loader (`load(home="~/.looker-to-sigma")` + `apply()`).
- `scripts/escalate-gap.py` — shared opt-in issue filer: category→repo routing, dedupe
  (open issues + beads), converter-repo mirroring, bead cross-link. Dry-run by default;
  files only with `--yes`. Identical copy across all migration skills.

## File locations (CRITICAL)

| File | Path | Why |
|---|---|---|
| Learned rules | `~/.looker-to-sigma/learned-rules.yaml` | Customer home; `git pull` can't clobber |
| Override (CI/sandbox) | `$LOOKER_TO_SIGMA_HOME` | points loader + validator elsewhere |

## Why a separate subagent

- **Context isolation** — verbose Sigma POST/readback stays out of the main conversion's context (matters for clustered multi-dashboard migrations).
- **Bounded budget** — ≤3 attempts per gap; failures stay WARNs, never block the migration.
- **Compounds** — validated rules persist locally and auto-apply to the next dashboard; strong ones can be promoted into the converter (`src/lookml.ts`).
