# gap-scout subagent — guide for the main agent (Power BI → Sigma)

When `convert_powerbi_to_sigma` / the assessment flags a **DAX measure** with no clean
Sigma rewrite (a `bucket: b` restructure or `bucket: c` no-equivalent), spawn a separate
subagent — the "gap scout" — to find a Sigma translation that works against the live Sigma
site, then persist it so future conversions apply it automatically.

Validated translations go to `~/.powerbi-to-sigma/learned-rules.yaml` (customer HOME, not the
skill repo). `scripts/learned-rules.py` loads them; the build step applies them before
falling back to a WARN.

## When to spawn

For each DAX measure the converter buckets as **b** (restructure) or **c** (no-equivalent):

| DAX pattern | Bucket | Candidate Sigma approach to try |
|---|---|---|
| `TOTALYTD / DATESYTD / SAMEPERIODLASTYEAR / DATEADD` | a/b | `CumulativeSum(...)` / `DateLookback(...)` on a **date-grouped** workbook element (verified translatable — usually NOT the real (c) tail) |
| `RANKX(ALL(t), <m>)` | b | `Rank()` / `RankPercentile()` in a grouped element |
| `CALCULATE(<m>, ALL(...))` / `ALLEXCEPT` | b | an unfiltered total via a separate (ungrouped) element, or a `/` against a window total |
| `SUMMARIZE / ADDCOLUMNS / GROUPBY` | b | a pre-aggregated / grouped DM element feeding the workbook |
| `USERELATIONSHIP(...)` | b | a **parallel join element** built on the inactive relationship |
| `DIVIDE(a, b [,alt])` | a | `a / b` (or `If(b=0, alt, a/b)`) — mechanical |
| `PATH / PATHITEM / PATHCONTAINS` | c | parent-child hierarchy — usually no Sigma equivalent → escalate |
| dynamic-context `SELECTEDVALUE / HASONEVALUE` | b/c | control-driven; often a workbook control + `If` — scout or escalate |

Spawn ONE scout per distinct pattern; run them in parallel.

## How to spawn (from the main agent)

Use the Agent tool, `subagent_type: 'general-purpose'`. Self-contained prompt:

```
You are a translation scout for a Power BI→Sigma migration. Propose a Sigma formula that
replaces a DAX measure, validate it against the live Sigma API, and persist the rule.

INPUTS
- DAX feature/pattern: <e.g. "RANKX">
- Sample measures from the model (TMSL): <2-5 real DAX expressions>
- Sigma data-model id: <dm-id>
- Sigma master element id: <element-id>
- Sigma folder id: <folder-id>

PROCEDURE
1. Read refs/measure-patterns.md + the sibling sigma-workbooks spec (function context rules:
   window funcs error in grouping-table calc cols; CumulativeSum/DateLookback need a
   date-grouped element; etc.).
2. Propose ONE candidate Sigma formula referencing columns as [Master/<Display Name>].
3. Validate + persist:
     eval "$(scripts/get-token.sh)"   # SIGMA_API_TOKEN
     python3 scripts/scout-validate.py \
       --formula '<candidate with REAL [Master/Col] names>' \
       --feature '<feature>' --pattern '<DAX regex; capture column refs>' \
       --template '<Sigma template using \1, \2>' \
       --hint '<post-publish caveat, e.g. "needs a date-grouped element">' \
       --description '<one-line>' --example-from '<measure name>' \
       --data-model-id <dm-id> --element-id <element-id> --folder-id <folder-id> \
       --home ~/.powerbi-to-sigma   [--kind table]
4. Parse JSON: status=validated → done; status=error → retry (≤3). After the last
   failed attempt the result carries an `escalation.dry_run_cmd` / `escalation.file_cmd`
   and the gap is left as a WARN. Do NOT file anything yourself — see "Opt-in issue
   filing" below.

OUTPUT
One paragraph: feature, candidate, status, and — if escalated — the
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

Power BI DAX gaps are **converter** gaps, so they mirror to both converter repos
(`sigma-data-model-manager` + `sigma-data-model-mcp`) with a cross-link and a
bead as the authoritative tracker. See `scripts/escalate-gap.py`.

## What the scout depends on

- `scripts/scout-validate.py` — builds a throwaway test workbook (Master from the DM
  element + a column using the candidate), checks the column's resolved type via
  `/v2/workbooks/{id}/elements/{el}/columns`, persists on success, deletes the test workbook.
- `scripts/learned-rules.py` — loader (`load(home="~/.powerbi-to-sigma")` + `apply()`).
- `scripts/escalate-gap.py` — shared opt-in issue filer: category→repo routing, dedupe
  (open issues + beads), converter-repo mirroring, bead cross-link. Dry-run by default;
  files only with `--yes`. Identical copy across all migration skills.

## File locations (CRITICAL)

| File | Path | Why |
|---|---|---|
| Learned rules | `~/.powerbi-to-sigma/learned-rules.yaml` | Customer home; `git pull` can't clobber |
| Override (CI/sandbox) | `$POWERBI_TO_SIGMA_HOME` | points loader + validator elsewhere |

## Why a separate subagent

- **Context isolation** — verbose Sigma POST/readback stays out of the main conversion's context (matters for clustered multi-report migrations).
- **Bounded budget** — ≤3 attempts per gap; failures stay WARNs, never block the migration.
- **Compounds** — validated rules persist locally and auto-apply to the next report; strong ones can be promoted into the converter.
