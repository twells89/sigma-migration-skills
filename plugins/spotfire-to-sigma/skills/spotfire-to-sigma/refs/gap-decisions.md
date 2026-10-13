# Gap decision ledger

`completion-gaps.json` is the source of truth. It merges discovery findings
from `gap-report.json` with emitted-spec findings from
`conversion-gaps.json`. Before a live run can complete, copy each gap's exact
identifiers into one ledger entry:

```json
{
  "decisions": [
    {
      "object_type": "visual",
      "object_id": "visual:forecast-mod",
      "warning_id": "SPOTFIRE-MOD-UNSUPPORTED",
      "decision": "accepted",
      "reason": "Customer approved rebuilding this Mod as a separate Sigma app."
    }
  ]
}
```

Allowed decisions are:

- `resolved` — the source or generated artifact was changed and revalidated;
- `accepted` — the named residual is an explicit customer-approved redesign or
  omission.

Every entry requires a reason. The orchestrator rejects missing, duplicate, or
extra tuples so an old ledger cannot silently approve a changed conversion.
Security findings use the same mechanism; accepting one documents the decision
but does not provision Sigma RLS or CLS.

An exporter finding whose severity is `blocking` cannot enter the live POST
path and cannot be accepted in this ledger. Fix the source/API extraction and
produce a new validated manifest first.
