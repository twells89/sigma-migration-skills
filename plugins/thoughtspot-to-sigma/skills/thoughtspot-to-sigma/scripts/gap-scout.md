# gap-scout — guide for the main agent (ThoughtSpot → Sigma)

When `convert_thoughtspot_to_sigma` flags an **unhandled** TML formula function (or a
high-volume one worth automating), spawn a "gap scout" subagent to find a Sigma
formula translation that validates against the customer's live Sigma site, then
persist it so future conversions apply it automatically.

The scout writes validated rules to `~/.thoughtspot-to-sigma/learned-rules.yaml`
(customer HOME, not the skill repo, so `git pull` never clobbers them).
`scripts/learned-rules.py` loads them; the build applies them before falling back to a WARN.

## What the converter already handles
`if (...) then ... else ...`, `<col> in {…}` → `In(...)`, `safe_divide(a,b)`,
aggregates `sum/count/count_distinct/average/avg/max/min/std_deviation/variance/cumulative_sum`,
`isnull`, `not`, `today`, `date_diff`. Plain `[TABLE::COL]` refs.

## Candidates to scout (TML function → Sigma)
| TML function | Why flagged | Candidate Sigma translation to validate |
|---|---|---|
| `add_days / add_months / add_years(d,n)` | date arithmetic | `DateAdd("day"/"month"/"year", n, [d])` |
| `diff_days / diff_months(a,b)` | date diff | `DateDiff("day"/"month", [a], [b])` |
| `start_of_week / start_of_month(d)` | period truncation | `DateTrunc("week"/"month", [d])` |
| `day_number_of_week / month_number / quarter_number(d)` | date parts | `DatePart("weekday"/"month"/"quarter", [d])` |
| `concat(a,b,…)` | string concat | `Concat([a],[b],…)` or `[a] & [b]` |
| `substr(s,i,n)` / `strlen(s)` | string | `Mid([s],i,n)` / `Length([s])` |
| `ifnull(x,y)` / `is_null(x)` | null handling | `Coalesce([x],[y])` / `IsNull([x])` |
| `pow(x,n)` / `log / exp / sqrt` | math | `Power([x],n)` / `Ln`/`Exp`/`Sqrt` |
| `group_aggregate / cumulative_*` over partitions | windowed agg | grouped element or `SumOver/RankOver` (note DM-calc-col window-fn limits) |
| `spotIQ / growth / rank` shortcuts | TS-specific | grouped element or `Rank()`; escalate if no 1:1 |

Spawn ONE scout per distinct function; run them in parallel (independent).

**Point the scout at a BASE element** (e.g. the fact table `Order Fact`), not the
denormalized `... View` — the view's display names are auto-suffixed `(TABLE)` and
differ from the spec names the scout reads, so refs won't resolve there.

## How to spawn (Agent tool, subagent_type 'general-purpose')
```
You are a translation scout for a ThoughtSpot→Sigma migration. Propose a Sigma
formula that replaces a TML function, validate it against the live Sigma API, and
persist the rule.

INPUTS
- TML function/pattern: <e.g. "add_days">
- Sample expressions: <2-5 real examples from the model's formulas>
- Sigma data-model id: <dm-id> ; denormalized element id: <denorm-elem-id> ; folder: <id>

DO
1. Propose a Sigma formula (see the candidate table in gap-scout.md).
2. Validate (eval get-token.sh first):
   python3 scripts/scout-validate.py --formula '<sigma>' \
     --data-model-id <dm> --element-id <denorm> --folder-id <folder> \
     --feature '<fn>' --pattern '<regex>' --template '<sigma template>' \
     --description '<fn> -> Sigma' --home ~/.thoughtspot-to-sigma
3. If status=validated it's persisted; report the rule. If error, try another form
   (≤4 attempts). After the last failed attempt the result carries an
   `escalation.dry_run_cmd` / `escalation.file_cmd`; report it as genuine-(c)
   needing redesign. Do NOT file anything yourself — see "Opt-in issue filing".
```
Validated rules auto-apply on the next migrate via `learned-rules.py`.

## Opt-in issue filing (escalations)

Filing a GitHub issue is **opt-in and confirm-before-file** — never automatic.
When `scout-validate.py` returns `status=error`, its `escalation` block carries
ready-to-run commands for the shared `escalate-gap.py` filer. The main agent:

1. Runs `escalation.dry_run_cmd` — files NOTHING; prints the drafted issue, the
   target repo(s), and any existing open issues/beads that already cover the gap.
2. Shows the user that draft and asks whether to open the issue.
3. Only if the user says yes, runs `escalation.file_cmd` (the same command + `--yes`).

ThoughtSpot formula gaps are **converter** gaps, so they mirror to both converter
repos (`sigma-data-model-manager` + `sigma-data-model-mcp`) with a cross-link and a
bead as the authoritative tracker. See `scripts/escalate-gap.py`.
