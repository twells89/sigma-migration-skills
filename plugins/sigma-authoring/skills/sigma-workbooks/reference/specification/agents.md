# Agents & chat — the workbook AI agent

A Sigma workbook can carry a **spec-authorable AI agent** that end users chat with
inside the workbook. It is easy to miss: it is **not a page element** — it's a
**`document.agents[]` array**, a sibling of `pages` / `layout` / `settings`.
The agent is surfaced by a flat `document.elements[]` `chat` entry that
references the agent id; layout places that chat on a page or panel.

> **Now fully in the public OpenAPI** (confirmed 2026-08-05 against the canonical
> asset — see `SKILL.md` → *Fetching the compiled asset*). `document.agents[]`,
> `dataSources`, `greeting`, all four `tools[]` kinds, and the `chat` element kind
> are schema-documented. An earlier revision of this file said they were absent and
> recovered only by live probing; that was true of the **stale** Fern docs asset,
> not of the current spec. Read the schema, and use a live readback as the tiebreaker.

## Shape

Note the `document` wrapper — `agents` is a sibling of `pages` / `layout` /
`settings`, **inside** `document` (see `schema.md`):

```yaml
name: My Workbook
folderId: <folderId>
document:
  schemaVersion: 1
  kind: workbook
  agents:
    - id: ag-analyst
      name: Analyst
      instructions: >-
        You are an analyst for this dataset. Answer questions about revenue,
        orders, and trends over time. Be concise and quantitative; cite the
        numbers you used.
      dataSources:
        - kind: table
          elementId: src
  elements:
    - id: src
      kind: table
      # ...
    - id: chat
      kind: chat
      agentId: ag-analyst
  pages:
    - id: pg
      name: Overview
  layout: |
    <?xml version="1.0" encoding="utf-8"?>
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="pg">
      <Element elementId="src" gridColumn="1 / 17" gridRow="1 / 20"/>
      <Element elementId="chat" gridColumn="17 / 25" gridRow="1 / 20"/>
    </Page>
```

| Field (agent entry) | Required | Notes |
|---|---|---|
| `id` | yes | The agent's handle — referenced by `chat.agentId`, not an element id. |
| `instructions` | yes | System-prompt-style guidance: role, scope, tone. Per the live OpenAPI the string also supports `@dataSource("elementId")` and `@tool("toolId")` reference syntax in addition to `{{formula}}` — pointing at a `dataSources`/`tools` entry declared on this same agent — not just plain text. |
| `name` | no | Display name shown in the chat UI. **Corrected 2026-08-08:** an earlier revision of this table marked `name` required; the live `CreateWorkbookSpec` schema's agent-entry `required` is exactly `[id, instructions]` — `name` (and `dataSources`, below) are schema-optional. Still worth always setting for a usable chat UI. |
| `dataSources` | no | Array of `{ kind: table, elementId: <id> }` — one entry per element (table/pivot/etc.) the agent may query. Maps 1:1 to the elements it can see; it cannot see elements not listed here. Schema-optional, but an agent with no `dataSources` has nothing to answer questions about — set it in practice. |
| `tools` | — | **Omit entirely for a read-only analyst** (see below). Present only on a write/action agent. Four `kind`s — see *Tool kinds* below. |
| `description` | — | Free-text description of the agent. |
| `greeting` | — | The chat's opening message. **An object, not a string** — see below. Omit for Sigma's default greeting. |

Several `chat` elements may reference the same `agents[]` entry by `agentId` — one agent, many chat surfaces (e.g. one on the main page, one in a modal).

### `greeting` — the chat's first message

`greeting` is a **two-variant object**. Passing a bare string is a 400
(`document.agents[0].greeting: Invalid value: string`):

```yaml
greeting:                        # fixed text
  mode: static
  message: Hi! Ask me anything about this quarter's pipeline.
```

```yaml
greeting:                        # the agent writes its own opener at open time
  mode: generated
  prompt: Greet the user and summarize the biggest change in the data.
```

Both `message` and `prompt` support `{{formula}}` references. **Live-verified
2026-08-05:** both variants pass `/verify` and round-trip; the `static` message
was additionally confirmed *rendering* in the chat element on a PNG export of the
created workbook.

The `chat` page element is minimal: `{ id, kind: "chat", agentId }` — no other
fields observed. Lay it out like any other element (`gridColumn`/`gridRow` via
`<Element>`), typically in a sidebar rail next to the dashboard body.

## Read-only analyst vs. write/action agent

**Read-only analyst — the common case.** The agent entry **omits the `tools` key
entirely** — not `tools: []`. An empty-but-present `tools` array is a different
(untested) shape; the verified read-only shape is the key's total absence. It can
only read the elements named in `dataSources` and answer questions about them.

**Write/action agent — adds `tools`.** Each tool gives the agent an action it can
invoke (function-calling style), described to the agent via `name`/`description`
so it knows when to call it:

```yaml
agents:
  - id: ag-planner
    name: Planner
    instructions: You help log review notes against this dataset.
    dataSources:
      - kind: table
        elementId: src
    tools:
      - toolId: log-note
        kind: action
        name: Log a review note
        description: >-
          Call this to record a review note from the conversation. Pass the
          note text as the `note` input.
        steps:
          - kind: effect
            effect: insert-rows
            tableElementId: annotations  # an input-table element id (see actions.md)
            values:
              an-note:
                type: agent-input
                inputName: note         # the agent supplies this at call time
```

`values: { <column-id>: { type: "agent-input", inputName } }` is the tool-call analog of the
`type: "control"` / `type: "constant"` value shapes an `insert-rows` effect takes
from a button (see `reference/workflows/actions.md`) — instead of pulling from a
control's current value or a hard-coded constant, the value comes from an argument
the agent fills in when it decides to call the tool, keyed by `inputName`.

## Agent as application control plane

For generate-app, define four independent capabilities rather than one vague
“assistant” purpose:

| Capability | Spec surface | Typical profile |
|---|---|---|
| **Analyze** | `dataSources[]` | read-only analyst |
| **Configure** | `set-control-value` action tools | UI orchestrator |
| **Navigate** | `navigate` / `select-tab` action tools | UI orchestrator |
| **Act** | direct row-write action tools | operator |

An agent may combine them, but grant only what the interview confirmed. In a
multi-module workbook, use a module specialist with a few relevant sources and
tools instead of one agent that sees and operates everything.

Granular Configure tool (the agent supplies a control value):

```yaml
- toolId: set-regions
  kind: action
  name: Set region filters
  description: Add each requested region to the cohort filter.
  steps:
    - kind: effect
      effect: set-control-value
      control: region
      selectionMode: add
      value: { type: agent-input, inputName: region }
```

Granular Navigate tool:

```yaml
- toolId: open-review
  kind: action
  name: Open review
  description: Navigate to Review only after the requested filters are set.
  steps:
    - kind: effect
      effect: navigate
      target: { type: page, page: pg-review }
```

For tabbed containers use `select-tab` with a 0-based index instead. Tool names
and descriptions are part of the control contract: state order constraints
(`set every provider, then open the provider tab`) rather than hoping the model
infers choreography from generic names.

`Richness.agent_action_tool` builds these direct-effect tools. It adds
`kind: effect`, defaults row writes to `requiresApproval: true`, rejects an
explicitly unapproved write, and rejects sequence steps. This keeps
spec-created agents inside the replayable surface.

### Post-action truth comes from the data

Include the write target or its audit/read path in `dataSources`. After an
approved write, the agent must query that source before claiming the row or
status exists. After a declined/skipped approval, it must query the same source
before claiming that nothing changed or counting prior events.

The approval card and tool result prove control flow, not warehouse state.
Never infer “two prior submissions remain” from conversation history. Verify
the authoritative log and report its actual row count/key. Runtime acceptance
must test one declined action (zero-row delta) and one approved action
(exactly-one-row delta).

### `requiresApproval` — gate a tool behind a confirmation

An `action` tool also accepts `requiresApproval: true`, which makes the agent ask
the user before executing. **Round-trips verified 2026-08-05.** Set it on anything
that writes: an agent that can silently `delete-rows` is a support ticket.

```yaml
tools:
  - toolId: log-note
    kind: action
    name: Log a review note
    description: Records a review note.
    requiresApproval: true
    steps: [ ... ]
```

## Tool kinds

`tools[]` has **four** `kind`s, not just `action`:

| `kind` | Fields | Status |
|---|---|---|
| `action` | `toolId`, `name`, `description`, `steps`, `requiresApproval?` | **Live-verified** (create + readback) |
| `mcp-connector` | `toolId`, `name`, `connectorId` | Shape accepted; needs a real connector — see below |
| `warehouse-agent` | `toolId`, `connectionId`, `path` (live readback; `description` optional) | Shape parses; `/verify` resolves the path against the host and can return `invocable inodes are not supported by this host` when the host lacks the registered agent. |
| `search-service` | `toolId`, `connectionId`, `path` (live-example shape; `description` optional) | Requires a registered search service; verify with a real path before shipping. |

`mcp-connector` lets a workbook agent call an external MCP tool by `connectorId`.
A syntactically valid but fake `connectorId` is rejected with `invocable inodes are
not supported by this host: '<id>'` — i.e. the **shape parses** and the id is
resolved against real org inodes, so this needs an actual registered connector to
verify end to end. `warehouse-agent` and `search-service` both take a
`connectionId` + `path` pair (a warehouse-side agent/service), same as a
warehouse-table path. The compiled OpenAPI currently under-describes these live
fields, so use a live readback or `/verify` result as the tiebreaker rather than
omitting them.

For action-agent steps, `/verify` accepts `agent-input` values for
`set-control-value` and both `page` and `control` `clear-control` scopes. The
button-specific guidance in `reference/workflows/actions.md` is narrower because
only page-scoped `clear-control` has been proven to fire from a button; acceptance
of an agent step does not prove that an action will execute successfully at run
time.

### `steps[]` — `effect` or `sequence`

An `action` tool's `steps[]` accepts two kinds. `{ kind: effect, ... }` inlines any
of the effect shapes from `reference/workflows/actions.md` (plus an optional `name`
for display). The other is a **reference** to a saved workbook action sequence:

```yaml
steps:
  - kind: sequence
    sequenceId: <existing action sequence id>
    name: Run the reset sequence      # optional display name
```

> **You cannot define a sequence from spec — only reference one.** There is **no**
> top-level `sequences` array in the workbook spec (confirmed against the compiled
> OpenAPI: top-level keys are `name`, `folderId`, `schemaVersion`, `kind`, `pages`,
> `layout`, `settings`, `agents`; `name`/`folderId`/`description` sit outside `document`). A
> `sequenceId` that isn't already in the workbook is rejected at verify time:
> `agents[0].tools[0].steps[0].sequenceId: references unknown action sequence
> 'seq-1'`. So `kind: sequence` is only usable against a sequence created in the
> UI — for spec-authored workbooks, inline the effects with `kind: effect` instead.
> (This refines the blanket "action sequences are unsupported" claim: they are not
> *authorable*, but they are *referenceable*.)

> **Scope note:** the write/action agent shape and the listed effect-step shapes
> have been accepted by neutral `/verify` probes, including action tools targeting
> `inputMode: view` tables. This is not end-to-end execution: no automated test
> drives an agent into actually invoking a tool or proves a warehouse mutation.
> `Richness.agent`'s `tools:` parameter passes an already-shaped array through
> **verbatim** (never reshapes it) for exactly this reason: confirm any non-trivial
> tool/step shape against a live POST + readback before shipping it, same discipline
> as any other agent-input shape in this doc.

## Org-feature gate + graceful degrade

Sigma's AI-agent feature is an **org-level toggle**. On an org where it's off,
posting `agents:[]` + a `chat` element either renders nothing useful or fails —
there's no reliable single error signature to detect this from the spec alone.
**Don't gate on trial-and-error in a shared build.** The safe pattern:

1. If you know (from asking the user, or a prior probe on that org) that AI agents
   are enabled, use `agents[]` + `chat` as above.
2. If you don't know, or you know they're **off**, degrade to a **static text
   element** with a short list of sample prompts instead of a live chat — e.g.:

   ```yaml
   - id: chat-fallback
     kind: text
     body: |
       **Ask about this data** (AI agents aren't enabled on this org)

       Try asking your Sigma admin to enable workbook AI agents, then re-add a
       live chat panel here. Sample questions this dataset can answer:
       - "What was revenue last month vs. the month before?"
       - "Which region had the most orders?"
   ```

Never POST a `chat` element as a cosmetic stand-in when you haven't confirmed the
org supports it — that's the "faked surface" this skill's docs never do. The
fallback text element is the honest alternative, not a workaround to make the
gated feature look implemented.

## Cross-links

- `scripts/lib/richness.rb` — `Richness.agent(id:, instructions:, name: nil,
  data_source_ids: [], tools: [], description: nil, greeting: nil)` builds the
  `agents[]` entry (`data_source_ids` maps to `dataSources`; empty `tools:` is
  omitted from the emitted Hash, matching the read-only shape above).
  `Richness.chat(id:, agent_id:)` builds the page element. Both are gated behind
  `Richness::SURFACES[:agent]`; a NO-GO flip returns `{opt_in: true, id:}` rather
  than emitting an unverified shape.
- `reference/workflows/actions.md` — the `insert-rows`/`clear-control`/
  `set-control-value` effect shapes a write-agent's tool `steps[]` reuses, and
  the append-only-log input-table pattern a logging tool typically targets.
