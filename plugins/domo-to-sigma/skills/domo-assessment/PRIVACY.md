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
schedules, or deletes anything in Domo. The assessment pipeline itself
(probe → discover → score → render) uses no Sigma credentials and never
posts to Sigma. (See the caveat about `doctor.sh`/`bootstrap.sh` under "Auth
handling" below — those two scripts are vendored into this skill folder for
family-consistency but are **not part of the assessment pipeline**.)

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

The assessment pipeline authenticates to **Domo only** — obtained via
`../domo-to-sigma/scripts/get-domo-token.sh`, which exchanges
`DOMO_CLIENT_ID`/`DOMO_CLIENT_SECRET` for a short-lived
`DOMO_ACCESS_TOKEN` (public API) and, for Tier A, also reads a
user-supplied `DOMO_DEV_TOKEN` (private card-definition API). These
credentials/tokens are read from environment variables at run time and used
only as request headers; they are never written to any output file or
committed. Following the standard `eval "$(...)"` shell idiom,
`get-domo-token.sh` does print `export DOMO_ACCESS_TOKEN=<token>` to stdout
so the calling shell can capture it — that's local-shell-to-local-shell
output, not logging or persistence: the token stays in the local shell's
environment, is not written to disk, not sent anywhere but Domo's own auth
endpoint, and is never committed.

This skill folder also vendors `scripts/doctor.sh`/`doctor.ps1` and
`scripts/bootstrap.sh`/`bootstrap.ps1` from the `*-to-sigma` skill family for
cross-skill consistency and a future Sigma hand-off. **These are not part of
the assessment pipeline** (probe → discover → score → render never calls
them). They check for `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` and, if a user
separately runs them with those set, will perform a live Sigma OAuth
token-mint smoke test — the only way this skill folder touches Sigma at all,
and only when a user deliberately invokes one of those two scripts outside
the normal flow. The assessment's real preflight is `probe-governance.rb`,
not `doctor.sh`.

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
