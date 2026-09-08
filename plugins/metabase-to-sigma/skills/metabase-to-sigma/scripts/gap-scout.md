# gap-scout subagent — guide for the main agent

When the Metabase converter can't translate an expression into a Sigma formula, it
**flags** it (never fakes it). For a flagged expression that you want to actually
resolve, spawn a separate subagent — the **gap scout** — to find a Sigma
translation that validates against the customer's real Sigma site, and persist it.

The scout writes successful rules to `~/.metabase-to-sigma/learned-rules.json` (the
customer's home dir, NOT the skill repo, so a `git pull` never clobbers them). The
converter CLI loads them via `loadLearnedRules()` and applies them *before* the
built-in translator (`applyLearnedRules` in `converter/metabase.ts`), so a customer's
discovered rule wins.

## When to spawn

After conversion emits a warning for an untranslated construct — typically:
- **cum-sum / cum-count / offset** aggregations (window/running calcs)
- **`["segment", id]` / legacy `["metric", id]`** refs (saved-filter/metric inlining)
- **binned breakouts** (`{"binning": …}` — numeric histogram buckets)
- **dimension-type field-filter** `{{tags}}` in native SQL cards
- any `unmapped: <op>` warning from `translateMbqlExpr`

Spawn ONE scout per distinct feature; run them in parallel where possible — they're
independent.

## How to spawn (from the main agent)

Use the Agent tool with `subagent_type: 'general-purpose'`. Self-contained prompt:

```
You are a translation scout. Your job: propose a Sigma formula that replaces a
Metabase expression, validate it against Sigma's API, and persist the rule if it works.

INPUTS
- Metabase feature: <e.g. "running-total">
- Sample expressions: <2-5 examples from the module/report>
- A real warehouse table on the customer's Sigma connection to test against:
  --connection <connectionId>  --table-path <DB.SCHEMA.TABLE>
- Sigma folder id: <folder-id>

PROCEDURE
1. Read refs/expression-dsl.md (the Metabase→Sigma mapping table) and
   refs/format-shapes.md. Note Sigma window funcs (SumOver/CountOver/…) silently
   error in data-model calc columns — prefer a non-window form or flag it.
2. Propose ONE candidate Sigma formula using a column that exists on --table-path.
3. Validate + persist:
   eval "$(scripts/get-token.sh)"
   node scripts/scout-validate-and-persist.mjs \
     --feature '<feature>' \
     --pattern '<Metabase regex, capture groups for column refs>' \
     --template '<Sigma template using $1,$2 for captures>' \
     --test-formula '<the candidate with a REAL column from --table-path>' \
     --connection <connectionId> --table-path <DB.SCHEMA.TABLE> \
     --folder <folder-id> --description '<one line>' --hint '<caveat>'
4. Parse the JSON result:
   - status=validated → success; rule is now in ~/.metabase-to-sigma/learned-rules.json
   - status=escalated → try a different candidate (≤3 attempts). The last result
     carries `escalation.dry_run_cmd`. Do NOT file anything yourself.

OUTPUT
One paragraph: feature, candidate, status (validated / escalated / abandoned-after-N),
and — if escalated — the `escalation.dry_run_cmd` so the main agent can offer the
user a tracking issue.
```

## Opt-in issue filing

If the scout escalates (no formula validated), it returns a ready-to-run
`scripts/escalate-gap.py … ` command (DRY-RUN by default). **Show it to the user and
ask** before filing — only run it with `--yes` on their go-ahead. It routes
converter gaps to the data-model repos (MCP + browser) with dedupe.
