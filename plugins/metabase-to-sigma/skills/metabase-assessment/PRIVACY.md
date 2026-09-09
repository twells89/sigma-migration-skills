# Metabase Assessment — privacy disclosure

Share this with the customer's privacy / security reviewer before running the
skill against a live Metabase instance.

## What this skill does

It issues **read-only `GET` requests** to the Metabase REST API (`/api`) to
inventory the collection tree and fetch the definitions of models, questions
(cards), and dashboards, then scores them locally for migration readiness and
renders an HTML report. It **never** POSTs, modifies, runs, or deletes
anything in Metabase — it never executes a query against the warehouse
(`/api/card/{id}/query` and `/api/dataset` are never called) — and it never
touches Sigma.

## What enters the agent model context

When a coding agent reads the fetched artifacts, their content is sent to that
agent provider's model so the assessment can be produced:

| Crosses the API | Stays in Metabase / local only |
|---|---|
| Aggregate counts (model / question / dashboard / collection counts) | Warehouse rows — never queried |
| Object names, collection paths, types, `view_count` (v50+) | Database credentials (the endpoints used never return them) |
| Card JSON: MBQL trees, **native SQL text**, custom-expression trees, viz settings | The customer's actual query *results* / result sets |
| Dashboard JSON: grid layout, parameter definitions, click behaviors | Per-user activity history (not fetched) |
| Database **schema** metadata: table/field names + ids (required to resolve MBQL field refs) | — |

MBQL filters and **native SQL text** (which can embed business logic and
sometimes literal threshold values, e.g. `WHERE tier = 'enterprise'`) are part
of the definitions and do cross the API. They do not include row-level
warehouse data.

## Where outputs go

The skill writes to a local directory (`/tmp/metabase-assessment-<env>/` by
default): `inventory.json`, the fetched definitions under `specs/`, schema
metadata under `metadata/`, `coverage.json`, and `readout.html` (plus
`sandboxes.json` on Pro/EE instances with sandboxing policies). Nothing is
uploaded anywhere. Sharing the readout with a Sigma rep is a deliberate action
by the user, not automatic.

## Auth handling

The skill reads an API key (`MB_KEY`, sent as `x-api-key`) or a session token
(`MB_SESSION`, sent as `X-Metabase-Session`) from environment variables the
user sets. They are used only as request headers, are not stored, and are not
written to any output file.

## How to run it more privately

- Run in **offline mode** against card/dashboard JSON files already exported
  to disk — no live Metabase connection is made at all.
- Personal collections are **skipped by default** (only `--include-personal`
  pulls them in).
- Use a session token scoped to a low-privilege account if the assessment
  should only see a subset of collections — Metabase's own permission model
  bounds what the walk can read.
