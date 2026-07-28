# Domo complexity scoring rubric

Same framework as `tableau-assessment` / `powerbi-assessment` — features classed
**auto / hint / manual / unhandled**, then:

```
cost  = 10*n_unhandled + 3*n_manual + 1*n_hint
value = views * sqrt(max(distinct_viewers, 1))          # audit (Activity Log) mode
      = 10 * (1 + n_beast_modes_on_this_card / 4.0)      # complexity-only proxy
score = value / (1.0 + cost)
```

`audit` mode = a `usage.json` was written (an Activity Log governance table was
reachable) — this is orthogonal to Tier A/B; a Tier-B instance can still have
Activity Log installed, in which case usage drives `value` even though
complexity is degraded (see §4).

Tags (identical vocabulary to the other assessments), evaluated **in this
order** — first match wins:
- `views == 0` (audit mode) → **retire**
- `n_unhandled >= 1` → **needs-gap-scout**
- `score >= 20 and (n_manual + n_unhandled) == 0` → **migrate-first**
- `score >= 10` → **easy-win**
- else → **moderate**

What's Domo-specific is the **signals** that produce the feature counts. Three
inputs: Beast Mode buckets, card-type coverage, and structural flags (PDP / DataFlow / DDX).

---

## 1. Beast Mode buckets → tiers

Beast Mode is MySQL SQL routed through `convert_sql_to_sigma_formula`, so **most
Beast Modes are bucket-a (auto)** — convertibility is far flatter than Power BI DAX.
Bucket each Beast Mode using
`../../domo-to-sigma/refs/beast-mode-to-sigma.md`:

| Bucket | Tier | Examples |
|---|---|---|
| **a — auto** | `auto` | `SUM/AVG/COUNT/COUNT(DISTINCT)/CASE/IFNULL/COALESCE/NULLIF/CONCAT/SUBSTRING/LEFT/RIGHT/LENGTH/UPPER/LOWER/TRIM/REPLACE/INSTR`, most date funcs (`YEAR/MONTH/DAY/DATE_ADD/DATE_SUB/DATEDIFF/DATE_FORMAT/STR_TO_DATE`), `ABS/MOD/POWER/ROUND/RAND` |
| **b — restructure** | `manual` | aggregate `CEILING`/`FLOOR` (rounded MAX/MIN trap); `col IN (...)` (→ `or` chains, no `IsIn`); period-over-period (`PERIOD_ADD`/`PERIOD_DIFF` on `YYYYMM`); `WEEK`/`YEARWEEK` modes; "fixed"/partition Beast Modes → `*Over` window funcs (mind `feedback_sigma_window_functions`); HLL sketch funcs → collapse to `CountDistinct` |
| **c — no equivalent** | `unhandled` | legacy unsupported funcs if present (`SQRT`, `CONVERT_TZ`, `MICROSECOND`); genuinely inexpressible logic (rare) |

(No `hint` tier — like Power BI, bucket-a is already mechanical; `n_hint` stays
`0` for every Beast Mode–derived count and is only kept in the artifact shape
for renderer/shortlist compatibility with the other `*-assessment` skills.)

`scripts/score-coverage.rb` implements this bucketing with a small regex
classifier (unhandled-function check, then manual-signal check, else auto) —
it does not call the live `convert_sql_to_sigma_formula` tool; that happens
later, during the actual `domo-to-sigma` conversion. The assessment only needs
to know *which bucket*, not the translated formula.

---

## 2. Card type → element coverage

| Tier | Domo card types |
|---|---|
| `auto` | table, bar, line, pie/donut, stacked bar, grouped bar, area, single-value/KPI, combo (bar+line) |
| `manual` | pivot table (needs `rowsBy`+`columnsBy`, see `feedback_sigma_pivot_rowsby_columnsby`), gauge, funnel, waterfall, map/geo, sankey, period-over-period card, bubble |
| `unhandled` | DDX brick / custom app, Domo-proprietary viz with no Sigma analog |

Card-type coverage is a **future refinement** — `score-coverage.rb`'s v1 signal
set is Beast Mode buckets + structural flags only (§1, §3); card type is
recorded on every artifact (`inventory.json`'s `cards[].type`) so a later pass
can fold in a per-type histogram without changing the artifact shape.

---

## 3. Structural flags (added to feature counts)

These are the signals `discover-domo.rb` already resolves per card
(`inventory.json`'s `cards[].pdp` / `cards[].dataflow_sourced`), and
`score-coverage.rb` folds them straight into the counts — on **every** tier,
since they don't require Beast Mode / card-definition visibility:

| Signal | Adds |
|---|---|
| Card's DataSet has a **PDP policy** | +1 `manual` (row-level security to recreate in the DM) |
| Card sits on a heavily-transformed **DataFlow output** | +1 `unhandled` (DataFlow migration is v1-out-of-scope for this assessment; flag for a gap-scout rather than assume it converts) |

(Card-level filter/drill-path/link and DDX-brick flags are Tier-A-only signals
sourced from the private card-definition API — see `card-defs.json` in
`../fixtures/tier-a/`; `discover-domo.rb` doesn't parse them yet, so they are
not folded into `n_manual`/`n_unhandled` in v1. Beast Mode buckets and the two
structural flags above are the complete v1 signal set.)

---

## 4. Tier degradation (Domo-specific, critical)

- **Tier A** — dev token reaches `/api/content/v1/cards` (or a `Beast Modes`
  Governance dataset exists). Every card's Beast Modes are bucketed per §1 in
  addition to the §3 structural flags.
- **Tier B** — public API only, no Beast Mode / card-config text. There is
  **no separate proxy formula** — `score-coverage.rb` runs the *same*
  `cost`/`value`/`score` math for both tiers (spec §5 is deliberately tier-
  agnostic); what actually degrades is the **signal set**: every card's
  Beast-Mode bucket counts (`n_auto`/`n_manual`/`n_unhandled` from §1) are
  forced to zero, so `cost`/`score` are driven **only** by the §3 structural
  flags (PDP / DataFlow) plus, in non-audit mode, the raw (unbucketed)
  `beast_modes` count on the card. In audit mode (Activity Log installed) the
  usage-driven `value` term is identical on both tiers.

  `complexity.json.tier` carries `"A"`/`"B"` through to `shortlist.json` and
  `migration-plan.json` unchanged, and the readout should surface "Tier B:
  Beast Mode complexity not visible — shortlist ranks on usage + structural
  signals only" in its caveats section. The shortlist is directional, not
  precise, in Tier B.

---

## 5. Output

`scripts/score-coverage.rb` writes three files (see also
`../scripts/score-coverage.rb`'s header comment, which is the executable
source of truth if this doc and the code ever drift):

- **`complexity.json`** — `{ tier, artifacts:[{id, title, page_id, dataset_id,
  n_auto, n_hint, n_manual, n_unhandled, views, distinct_viewers, value, cost,
  score, tag}], rollup:{by_tag, totals, pct_auto} }`. One artifact per Domo
  card.
- **`shortlist.json`** — the same artifacts, re-sorted: `migrate-first` /
  `easy-win` first, then by `score` descending within each tag group.
- **`migration-plan.json`** — `{ tier, clusters, pages, duplicate_dashboards }`.
  `clusters` groups cards sharing a `dataset_id` (migrate the dataset once,
  multiple cards benefit); `pages` rolls each page up to a single
  `recommended_path` (`convert` | `gap-scout` | `retire`) from its cards' tags;
  `duplicate_dashboards` is `scripts/dup-dashboards.py`'s output over the card
  list (folded in — a Python failure there is swallowed, never fails the run).
