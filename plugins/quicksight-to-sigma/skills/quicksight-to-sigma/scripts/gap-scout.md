# gap-scout subagent — guide for the main agent

When the converter can't translate a QuickSight calculated-field expression (or
a high-volume analysis function) into a Sigma formula, spawn a separate subagent
— the "gap scout" — to find a Sigma translation that validates against the
customer's actual Sigma site.

The scout writes successful translations to
`~/.quicksight-to-sigma/learned-rules.yaml` (the customer's home dir, NOT the
skill repo, so `git pull` of the skill never clobbers them). The build script
(`build-charts-from-signals.rb`) loads these via `LearnedRules.load` and applies
them *before* the built-in translators, so a customer's discovered rule wins.

## When to spawn

After conversion flags an untranslated QuickSight expression. Spawn ONE scout
per distinct feature; run them in parallel where possible — they're independent.

## How to spawn (from the main agent)

Use the Agent tool with `subagent_type: 'general-purpose'`. Self-contained
prompt:

```
You are a translation scout. Your job: propose a Sigma formula that replaces a
QuickSight calculated-field expression, validate it against Sigma's API, and
persist the rule if it works.

INPUTS
- QuickSight feature: <function name, e.g. "runningSum">
- Sample expressions: <3-5 examples from the analysis definition>
- Sigma data-model id: <dm-id>
- Sigma denormalized element id: <element-id>
- Sigma folder id: <folder-id>

PROCEDURE
1. Read the relevant skill docs:
   - refs/ (translation notes for QuickSight functions)
   - scripts/lib/sigma_functions.rb (the whitelist — anything outside ALL_SET
     silently errors)
2. Propose ONE candidate Sigma formula. Prefer functions in the whitelist.
   For window/running/percentOfTotal functions, remember they silently error in
   workbook-master grouping-table calc cols AND in DM-element calc cols — route
   to a non-grouping context or a Custom SQL DM element with explicit OVER(...).
3. Run:
   ruby scripts/scout-validate-and-persist.rb \
     --feature '<feature>' \
     --pattern '<QuickSight regex, capture groups for column refs>' \
     --template '<Sigma template using \1, \2 for captures>' \
     --test-formula '<the candidate with REAL column names from this DM>' \
     --data-model-id <dm-id> \
     --master-element-id <element-id> \
     --folder-id <folder-id> \
     --description '<one-line>' \
     --hint '<post-publish caveat, e.g., "non-grouping context only">' \
     --example-from '<which analysis/field>'
4. Parse the JSON result.
   - status=validated → success; rule is now in the customer's local YAML
   - status=escalated → propose a different candidate (up to 3 attempts). After
                        the last attempt the result carries an
                        `escalation.dry_run_cmd` / `escalation.file_cmd`. Do NOT
                        file anything yourself — see "Opt-in issue filing" below.

OUTPUT
Return a one-paragraph summary: feature, candidate, status (validated /
escalated / abandoned-after-N-attempts), the workbook_id of the test spec for
cleanup later, and — if escalated — the `escalation.dry_run_cmd` so the main
agent can offer the user a tracking issue.
```

## Opt-in issue filing (escalations)

Filing a GitHub issue is **opt-in and confirm-before-file** — never automatic.
When `scout-validate-and-persist.rb` returns `status=escalated`, the main agent:

1. Runs the returned `escalation.dry_run_cmd` (the shared `escalate-gap.py` filer
   in dry-run mode). This files NOTHING — it prints the drafted issue, the
   **target repo(s)**, and any **existing open issues / beads** that already
   cover the gap (dedupe).
2. Shows the user that draft and asks whether to open the issue.
3. Only if the user says yes, re-runs with `--yes` (the `escalation.file_cmd`).

QuickSight calc-field gaps are **converter** gaps, so they mirror to both
converter repos (`sigma-data-model-manager` + `sigma-data-model-mcp`) with a
cross-link; a bead is created/linked as the authoritative tracker. Builder/spec
gaps would route to `sigma-migration-skills` instead (`--category builder`).
See `scripts/escalate-gap.py`.

## What the scout depends on

- `scripts/validate-sigma-formula.rb` — primitive that POSTs a minimal test
  workbook + runs the column-type guard. Returns JSON. Tool-agnostic.
- `scripts/scout-validate-and-persist.rb` — wraps validate-sigma-formula; on
  success appends to `~/.quicksight-to-sigma/learned-rules.yaml`; on failure
  writes a structured escalation to `~/.quicksight-to-sigma/escalations/` and
  returns the opt-in `escalate-gap.py` commands.
- `scripts/escalate-gap.py` — shared opt-in issue filer: category→repo routing,
  dedupe (open issues + beads), converter-repo mirroring, bead cross-link.
  Dry-run by default; files only with `--yes`. Identical copy across all
  migration skills.
- `scripts/learned-rules.rb` — the loader the build script uses. The customer
  never edits this; the scout writes it.

## File locations (CRITICAL)

| File | Path | Why |
|---|---|---|
| Learned rules | `~/.quicksight-to-sigma/learned-rules.yaml` | Customer home. `git pull` cannot clobber. |
| Escalations | `~/.quicksight-to-sigma/escalations/*.yaml` | Same — customer-local. |
| Override for testing | `$QUICKSIGHT_TO_SIGMA_HOME` env var | Points at a sandbox path for CI. |

## Why a separate subagent

- **Context isolation**: each Sigma POST response is verbose. Keeping the
  reasoning + validation loops out of the main conversion's context matters for
  large multi-dashboard migrations.
- **Bounded budget**: capped at N attempts per gap. Failure doesn't block the
  main conversion — failed gaps remain WARN lines for manual post-publish.
- **Compounds across customers**: every customer who runs the scout contributes
  to their local rules library; strong rules can be promoted into the converter.
