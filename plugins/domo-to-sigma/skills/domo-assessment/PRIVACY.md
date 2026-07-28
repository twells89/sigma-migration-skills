# Domo Assessment — privacy disclosure

Share this with the customer's privacy / security reviewer before running the
skill against a live Domo instance.

## What this skill does

It issues **read-only** calls against Domo's public Governance/DomoStats
system datasets (`POST /v1/datasets/query/execute/{id}` — plain SQL `SELECT`
against Domo-owned metadata datasets) and, when a `DOMO_DEV_TOKEN` is
available (Tier A), read-only calls against the private card-definition API
to pull Beast Mode SQL text. It scores every card locally for migration
readiness and renders a Markdown readout. It **never** creates, edits,
schedules, or deletes anything in Domo, and it **never** touches Sigma — no
Sigma credentials are used or required anywhere in this skill.

## What crosses the LLM (Anthropic) API

Like every Claude Code skill, the content the agent reasons over is sent
through the Anthropic API to Claude so the assessment can be produced.

| Crosses the API | Stays local-only |
|---|---|
| Aggregate counts (dataset / page / card / user counts) | Raw governance-dataset rows fetched during discovery |
| Value / cost / score numbers and tags (`migrate-first`, `easy-win`, `moderate`, `needs-gap-scout`, `retire`) | Domo credentials (`DOMO_CLIENT_ID`, `DOMO_CLIENT_SECRET`, `DOMO_DEV_TOKEN`, `DOMO_ACCESS_TOKEN`) |
| Card/page/dataset names, owner, folder path, PDP/DataFlow structural flags | `/tmp/domo-assessment-<instance>/` JSON outputs (`inventory.json`, `usage.json`, `complexity.json`, `shortlist.json`, `migration-plan.json`) |
| Beast Mode SQL text (Tier A only — a card's calc formula, part of the spec) | Any underlying warehouse rows or card *result* data — never queried by this skill |
| The `readout.md` summary the agent reasons over and presents | Uploaded/attached files behind a card (not fetched by this skill) |

Beast Mode SQL (Tier A) can embed business logic and sometimes literal
threshold values (e.g. `WHERE region = 'West'`). It is part of the card
spec and does cross the API like any other calc expression this skill reads.
It never includes row-level warehouse data or card result sets.

## Auth handling

The skill authenticates to **Domo only** — obtained via
`../domo-to-sigma/scripts/get-domo-token.sh`, which exchanges
`DOMO_CLIENT_ID`/`DOMO_CLIENT_SECRET` for a short-lived
`DOMO_ACCESS_TOKEN` (public API) and, for Tier A, also reads a
user-supplied `DOMO_DEV_TOKEN` (private card-definition API). These
credentials/tokens are read from environment variables at run time, used
only as request headers, and are **never echoed to stdout, written to any
output file, or committed**. The skill uses no Sigma credentials at all —
it never authenticates to Sigma and never posts anything to it.

## Where outputs go

Every artifact — `probe.json`, `inventory.json`, `usage.json`,
`complexity.json`, `shortlist.json`, `migration-plan.json`, `readout.md` —
is written to a local directory, conventionally
`/tmp/domo-assessment-<instance>/`, and never into this repo. Nothing is
uploaded anywhere automatically. Sharing the readout with a Sigma rep is a
deliberate action taken by the user, not something this skill does on its
own.

## How to run it more privately

- Run in **offline mode** (`bash run-offline.sh`, or any pipeline script with
  `--from-fixtures <dir>`) against the committed fixture directories
  (`fixtures/tier-a`, `fixtures/tier-b`) — no network call and no Domo or
  Sigma credentials are used at all.
- Live, Tier B (public governance datasets only, no `DOMO_DEV_TOKEN`) never
  sees Beast Mode SQL text — only structural counts and flags cross the API.
- Scope discovery narrowly by pointing `--out` at a fresh directory per
  instance/engagement rather than reusing one across customers.
