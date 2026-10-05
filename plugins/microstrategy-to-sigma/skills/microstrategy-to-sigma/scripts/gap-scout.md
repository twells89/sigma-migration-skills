# gap-scout — guide for the main agent (MicroStrategy → Sigma)

The MSTR converter (`convert.py` `metric_formula`) passes metric **function names**
through optimistically — it maps an MSTR function token straight to a Sigma function
name without checking that Sigma has an equivalent. So a metric using a function with
no clean Sigma mapping does NOT warn at convert time; it surfaces as a **type=error
column** when the workbook is read back after POST (Phase 4). The mechanical gate
`scripts/scout-gate-readback.py` STOPS on any such column until a gap-scout has tried
to translate it.

The scout writes validated rules to `~/.microstrategy-to-sigma/learned-rules.yaml`
(customer HOME, not the skill repo, so `git pull` never clobbers them).
`scripts/learned-rules.py` loads them; future conversions apply them before falling
back to the raw function name.

## What the converter already handles
Plain object refs (`[TABLE/Col]`), `Sum/Count/Avg/Min/Max`, `Count<Distinct=True>` →
`CountDistinct`, arithmetic (`+ - * /`), nested-metric inlining (workbook context),
metric→SQL for AE-emulation sql elements.

## Candidates to scout (MSTR metric function → Sigma)
| MSTR function | Why it errors | Candidate Sigma translation to validate |
|---|---|---|
| `RunningSum / RunningAvg / RunningMax` | window/running calc | `CumulativeSum([Orders/Col])` in a date-grouped element |
| `Rank / RankByValue` | window rank | `Rank([Orders/Col])` (grouped-element context) |
| `Lag / Lead / OffsetValue` | offset | `Lag([Orders/Col], n)` in a sorted/date-grouped element |
| `Median / Percentile / Mode` | distribution | `Median([Orders/Col])` / `Percentile([Orders/Col], p)` |
| `StdDev / Variance` | stats | `Stdev([Orders/Col])` / `Var([Orders/Col])` |
| `NTile / Quartile` | bucketing | derived bins or `Rank` + ratio; escalate if no 1:1 |
| `FirstInRange / LastInRange` | windowed first/last | `First`/`Last` in a sorted grouped element |
| MSTR-specific (`ApplySimple`, `BannerNumber`, …) | passthrough/raw SQL | translate via the warehouse SQL, else escalate |

Spawn ONE scout per distinct error column; run them in parallel (independent).

**Point the scout at the denormalized join element** and qualify columns with
that element's actual `name`. The converter default is `Orders`, so the default
form is `[Orders/<Display Name>]`. If conversion used
`--join-element-name <other-name>`, replace `Orders` in every candidate formula;
never use an element id or a generic `Master` prefix.

## How to spawn (Agent tool, subagent_type 'general-purpose')
```
You are a translation scout for a MicroStrategy→Sigma migration. Propose a Sigma
formula that replaces an MSTR metric function, validate it against the live Sigma
API, and persist the rule.

INPUTS
- Error column: <the type=error column's label + its formula from the gate output>
- Sample MSTR metric expression(s): <2-5 real examples>
- Sigma data-model id: <dm-id> ; denormalized element id: <denorm-elem-id> ; folder: <id>
- Gate id + workdir: <errcol:... and --workdir from scout-gate-readback.py's GAP-SCOUT REQUIRED block>

DO
1. Propose a Sigma formula (see the candidate table above).
2. Validate (`scout-validate.py` self-authenticates through the browser-first
   shared Sigma client):
   python3 scripts/scout-validate.py --formula '<sigma>' \
     --data-model-id <dm> --element-id <denorm> --folder-id <folder> \
     --feature '<fn>' --pattern '<regex>' --template '<sigma template>' \
     --description '<fn> -> Sigma' --home ~/.microstrategy-to-sigma \
     --gap-id '<errcol:... from the GAP-SCOUT REQUIRED list>' --workdir <migration workdir>
3. If status=validated it's persisted; report the rule. If error, try another form
   (≤4 attempts). After the last failed attempt the result carries an
   `escalation.dry_run_cmd` / `escalation.file_cmd`; report it as genuine-(c)
   needing redesign. Do NOT file anything yourself — see "Opt-in issue filing".
```
Validated rules auto-apply on the next migrate via `learned-rules.py`.

## Run-each-time gate (bead beads-sigma-5l5e) — why `--gap-id` + `--workdir` matter

`scout-gate-readback.py` reads the workbook back after POST, finds each type=error
column, and **STOPS** (exit 11) with a `GAP-SCOUT REQUIRED` block listing each
unscouted column's `--gap-id` (`errcol:<elementId>/<label>`) and the `--workdir`.

`scout-validate.py` appends its result (`validated` or `escalated`) to
`<workdir>/scout-ledger.jsonl` keyed by that exact `--gap-id` (via `lib/scout_gate.py`,
the shared JSONL contract). You MUST pass the `--gap-id` and `--workdir` the STOP block
printed — otherwise the ledger entry won't match the error column and re-running the
gate will STOP again. The gate cannot be skipped with `--yes`: an unscouted error
column always stops; once every error column is scouted (validated → translated and
persisted, or escalated → genuinely-hard and flagged) the gate passes. Flow: POST →
gate STOPS → scout each column → re-run the gate → proceed.

## Opt-in issue filing (escalations)

Filing a GitHub issue is **opt-in and confirm-before-file** — never automatic.
When `scout-validate.py` returns `status=error`, its `escalation` block carries
ready-to-run commands for the shared `escalate-gap.py` filer. The main agent:

1. Runs `escalation.dry_run_cmd` — files NOTHING; prints the drafted issue, the
   target repo(s), and any existing open issues/beads that already cover the gap.
2. Shows the user that draft and asks whether to open the issue.
3. Only if the user says yes, runs `escalation.file_cmd` (the same command + `--yes`).

MSTR metric gaps are **converter** gaps, so they mirror to both converter repos
(`sigma-data-model-manager` + `sigma-data-model-mcp`) with a cross-link and a bead as
the authoritative tracker. See `scripts/escalate-gap.py`.
