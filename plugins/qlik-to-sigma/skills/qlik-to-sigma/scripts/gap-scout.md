# gap-scout subagent — guide for the main agent (Qlik → Sigma)

When discovery / `convert_qlik_to_sigma` flags an **unhandled** Qlik expression (or a
high-volume one worth automating), spawn a separate subagent — the "gap scout" — to find
a Sigma translation that actually works against the customer's live Sigma site, then
persist it so future conversions apply it automatically.

The scout writes validated translations to `~/.qlik-to-sigma/learned-rules.yaml` (customer
HOME, **not** the skill repo, so `git pull` never clobbers them). `scripts/learned-rules.py`
loads them; the build step applies them before falling back to a WARN.

## When to spawn

After discovery, for each Qlik expression the converter omits/flags as unhandled — these
are the `qlikExprToSigma` warning cases:

**Auto-handled by the converter now (2026-06-05) — do NOT scout these:** simple Set
Analysis (`Sum({<F={v}>} X)`→`Sum(If([F]=v,[X]))`, `{1}`, `-=`, multi-value/flag,
`Count({<…>} DISTINCT X)`), row-wise multi-arg `Range*` (→`+`/`Greatest`/`Least`),
`Dual`, `Class`, `Count(DISTINCT)`. Scout only the genuinely-unhandled patterns below.

| Qlik pattern | Why flagged | Candidate Sigma translation to try |
|---|---|---|
| `Aggr(<agg>, <dim>)` | nested-aggregate, no 1:1 | a **grouped/level element** or a pre-aggregated DM element; sometimes `WindowSum`/`WindowAvg` over a partition |
| `Above/Below/Peek/Previous(...)` | inter-record (running total, MoM) | a workbook-level window fn (`*Over`) on a date-grouped element — NOT a DM calc col (those silently error); escalate to workbook build |
| `Rank/HRank(...)` | ranking | `Rank()` is a Sigma **window** fn — build it in a grouping table, not a DM metric |
| `Class(<field>, <size>, <label>)` w/ 3rd label arg | labeled binning | converter keeps the lower edge; add an `If()`-range label column if the text matters |
| `GetSelectedCount / GetFieldSelections / GetCurrentSelections` | selection state | no Sigma equivalent — usually a control-driven measure; escalate |
| Set Analysis with `$()`, `P()/E()`, search `"*x*"`, set operators `+/-/*` | too complex | hand-write `SumIf`/`CountIf`; for `$(=Max(YEAR))` use a date control or `Max` window |

Spawn ONE scout per distinct pattern; run them in parallel — they're independent.

## How to spawn (from the main agent)

Use the Agent tool, `subagent_type: 'general-purpose'`. Self-contained prompt:

```
You are a translation scout for a Qlik→Sigma migration. Propose a Sigma formula that
replaces a Qlik expression, validate it against the live Sigma API, and persist the rule.

INPUTS
- Qlik feature/pattern: <e.g. "RangeAvg">
- Sample expressions from the app: <2-5 real examples>
- Sigma data-model id: <dm-id>
- Sigma denormalized element id: <element-id>   (the master that holds all fields)
- Sigma folder id: <folder-id>

PROCEDURE
1. Read refs/sigma-build-gotchas.md (function context rules: *Over window fns error in
   grouping-table calc cols; tables aggregate via groupings; etc.).
2. Propose ONE candidate Sigma formula. Reference columns as [Master/<Display Name>].
   Prefer Sigma whitelist functions (SumIf/CountIf, Avg, WindowSum/WindowAvg, If, etc.).
3. Validate + persist in one call:
     eval "$(scripts/vendor/get-token.sh)"   # sets SIGMA_API_TOKEN
     python3 scripts/scout-validate.py \
       --formula '<candidate with REAL [Master/Col] names>' \
       --feature '<feature>' \
       --pattern '<Qlik regex; capture groups for column refs>' \
       --template '<Sigma template using \1, \2 for captures>' \
       --hint '<post-publish caveat>' \
       --description '<one-line>' --example-from '<app/measure>' \
       --data-model-id <dm-id> --element-id <element-id> --folder-id <folder-id> \
       --home ~/.qlik-to-sigma   [--kind table]   # default kpi-chart; use table for row-level/dimension formulas
4. Parse the JSON:
   - status=validated → rule is now in the local YAML; done.
   - status=error     → try a different candidate (≤3 attempts). After the last
                        failed attempt the result carries an `escalation.dry_run_cmd`
                        / `escalation.file_cmd` and the gap is left as a manual WARN.
                        Do NOT file anything yourself — see "Opt-in issue filing".

OUTPUT
One paragraph: feature, candidate, status, the test workbook is auto-deleted by the
validator, and — if escalated — the `escalation.dry_run_cmd` so the main agent can
offer the user a tracking issue.
```

## Opt-in issue filing (escalations)

Filing a GitHub issue is **opt-in and confirm-before-file** — never automatic.
When `scout-validate.py` returns `status=error`, its `escalation` block carries
ready-to-run commands for the shared `escalate-gap.py` filer. The main agent:

1. Runs `escalation.dry_run_cmd` — files NOTHING; prints the drafted issue, the
   target repo(s), and any existing open issues/beads that already cover the gap.
2. Shows the user that draft and asks whether to open the issue.
3. Only if the user says yes, runs `escalation.file_cmd` (the same command + `--yes`).

Qlik expression gaps are **converter** gaps, so they mirror to both converter repos
(`sigma-data-model-manager` + `sigma-data-model-mcp`) with a cross-link and a bead
as the authoritative tracker. See `scripts/escalate-gap.py`.

## What the scout depends on

- `scripts/scout-validate.py` — builds a throwaway test workbook (Master from the DM
  element + a column using the candidate), checks `/v2/workbooks/{id}/elements/{el}/columns`
  for `type=="error"`, persists to the local YAML on success, deletes the test workbook.
- `scripts/learned-rules.py` — the loader the build step uses (`load()` + `apply()`).
- `scripts/escalate-gap.py` — shared opt-in issue filer: category→repo routing, dedupe
  (open issues + beads), converter-repo mirroring, bead cross-link. Dry-run by default;
  files only with `--yes`. Identical copy across all migration skills.

## File locations (CRITICAL)

| File | Path | Why |
|---|---|---|
| Learned rules | `~/.qlik-to-sigma/learned-rules.yaml` | Customer home; `git pull` can't clobber |
| Override (CI/sandbox) | `$QLIK_TO_SIGMA_HOME` | points the loader + validator elsewhere |

Keep `.qlik-to-sigma/` out of the skill repo (`.gitignore`).

## Why a separate subagent

- **Context isolation** — each Sigma POST/readback is verbose; keep the validation loop out of the main conversion's context (matters for batch/tenant migrations).
- **Bounded budget** — ≤3 attempts per gap; a failure doesn't block the migration, it just stays a WARN for manual handling.
- **Compounds** — every validated rule persists locally and auto-applies to the next app; promising rules can later be promoted into the converter itself.
