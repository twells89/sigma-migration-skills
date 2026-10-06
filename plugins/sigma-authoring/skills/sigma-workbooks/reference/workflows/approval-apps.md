# Approval apps — decision queue and audit workflow

Entered via [`generate-apps.md`](generate-apps.md) when the user asked to generate an app.

Use this pattern when the source contains:

- a stable entity key (Deal ID, Request ID, Case ID, Order ID);
- decision-state members such as Pending / Approved / Rejected;
- an aging, SLA, policy tier, threshold, or approval band;
- a reviewer, owner, or assignee dimension.

The source proves that an approval queue exists. The write path is an
enhancement, so ask what decisions users should be allowed to make.
Generate-apps Step B also asks whether to keep the submit / audit-log
action (the queue itself is still this type).

## Grain

```text
one editable row per entity key
```

Never key on mutable status, reviewer, or policy tier. Bind those as inherited
context if needed, but keep the entity key stable.

## Architecture

1. **Governed directory** — read-only source rows with entity, submitted value,
   policy context, current status, and age.
2. **Linked review input table** — entity key and submitted context plus
   editable Decision, Counter Value, Reviewer, and Decision Note.
3. **Computed outcome** — approved/counter value and business impact.
4. **Append-only decision log** — entity, decision, note, author, timestamp.
5. **Optional status update** — update the selected entity only.

Example counter calculation:

```text
Approved Net =
  List Amount × (1 - Coalesce(Approved Discount, Submitted Discount))

Revenue Impact = Approved Net - Submitted Net
```

## Row population

The governed entity directory supplies the queue grain. Link editable decision
fields to its stable key. Do not recreate source entities through one action
per row, and do not expect a union or join to write them into the input table.

A directory of every open entity is not a review queue. Cap before linking
(open stage, amount band, or SQL `QUALIFY ROW_NUMBER() … <= N`). Probe
`DISTINCT` on the closed flag — it may be text `"true"` / `"false"`, not a
boolean. A `top-n` filter on the directory did not flow through to the
linked input table in live generate-app verification; cap the warehouse or
SQL source (or a child table) *before* the linked queue.

## Action pattern

One click can perform two distinct writes:

```text
insert immutable audit row
+ update selected entity status
```

The `whichRows` formula must use the stable entity key:

```text
[Deal ID] = [dealControl]
```

Test that a second entity remains unchanged.

## Agent

Generate-apps Step B offers this agent and pre-fills the recommended
purpose; skip this section if they declined.

Give the agent the directory, editable review queue, and decision log. It
should prioritize by policy breach, value at risk, and age. It must not claim a
decision was written unless the user approved the action.

## Runtime gates

- queue row count and key uniqueness match the **capped** review set, not
  every open source row;
- published edit accepts a counter value;
- calculated outcome and impact tie arithmetically;
- KPI changes by the exact impact;
- log row includes entity, decision, comment, user, and timestamp;
- status update affects one entity only;
- agent names the correct highest-risk pending entity.

Apply the input-table published-data-entry permission manually before handoff.
