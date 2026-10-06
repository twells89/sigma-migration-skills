# Exception apps — operational triage and resolution

Entered via [`generate-apps.md`](generate-apps.md) when the user asked to generate an app.

Use this pattern when the source contains:

- a stable operational key (SKU, Account ID, Job ID, Ticket ID);
- exception/risk members or a threshold boolean;
- urgency, aging, coverage, variance, or severity measures;
- enough context to recommend an action.

Examples include inventory replenishment, data-quality exceptions, SLA
breaches, reconciliation breaks, and anomaly review.

## Grain

```text
one editable row per operational entity
```

If one entity can have multiple simultaneous exceptions, add Exception Type or
Observation Date to the composite key.

## Architecture

1. **Exception directory** — governed source context and source-derived flag.
2. **Linked action queue** — stable key/context plus editable Decision,
   Override, Owner, and Resolution Note.
3. **Recommended action** — deterministic formula from source policy.
4. **Final action** — user override or recommendation.
5. **Resolution log** — append-only action evidence. Generate-apps Step B
   asks whether this workflow needs that log action; if they declined,
   keep the action queue and omit the log-resolution button.

Inventory example:

```text
Suggested Order =
  If(Reorder Point - On Hand - On Order > 0,
     Reorder Point - On Hand - On Order,
     0)

Final Order = Coalesce(Override Order Qty, Suggested Order)
Order Value = Final Order × Unit Cost
```

Do not label a recommendation “AI” when it is a policy formula. The workbook
agent can explain and prioritize it; the calculation itself remains auditable.

## Row population

The source directory supplies the entity grain. Link the action queue to stable
keys and store only user-entered decisions or overrides. Actions append
resolution events; they do not initialize the queue. Unions and joins may
compose the read model but cannot populate the input table.

Cap a large exception directory before linking (severity, open flag, or SQL
`QUALIFY ROW_NUMBER() … <= N`). A `top-n` filter on the directory does not
flow through to the linked input table (`input-tables.md`). Probe `DISTINCT`
on flag columns — they may be text `"true"` / `"false"`, not booleans.

## Agent

Generate-apps Step B offers this agent and pre-fills the recommended
purpose; skip this section if they declined.

The agent should:

- rank unresolved exceptions by urgency and business impact;
- notice actions already recorded and avoid recommending them again;
- distinguish source risk from the user-entered resolution;
- require approval for action tools.

## Runtime gates

- action-queue row count and key uniqueness match the exception directory;
- recommendation ties to source fields;
- override replaces the recommendation;
- KPI changes by the exact override delta, even if display rounding hides it;
- resolution log persists with author and timestamp;
- already-resolved items are excluded or deprioritized by the agent;
- positive/negative or urgent/healthy formatting renders correctly.

Apply published-data-entry permission manually to both action queue and log.
