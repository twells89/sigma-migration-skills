# Looker Assessment

A Claude Code skill that inventories a Looker instance and produces a
migration-readiness readout. Designed to be run by a customer (or a Sigma rep with
the customer present) before deciding which Looker dashboards to migrate to Sigma.

**READ-ONLY.** Only `GET` requests and System Activity inline queries — no object is
created, edited, or deleted in Looker, and no warehouse rows are ever read. The skill
never posts to Sigma.

## What it produces

A directory (`/tmp/assessment-<host>/` by default) with:

- `inventory.json` — environment counts (models, explores, projects, connections,
  Looks, dashboards split UDD vs LookML, users, groups, folders), connection dialects,
  System Activity usage, per-dashboard complexity buckets, an ownership rollup,
  feature/viz rollups, and the value/cost-ranked **migration shortlist**. The single
  file the renderer + `looker-to-sigma` consume.
- `readout.md` — a compact markdown summary, written by `looker-inventory.py`.
- `readout.html` — a customer-facing, Sigma-branded HTML report (the same theme as
  `tableau-assessment` / `qlik-assessment`), written by `render-readout-html.rb`.
  Open it in a browser or print to PDF to share.

Nothing in this directory is uploaded anywhere. To share, zip and send deliberately.

## Prerequisites

- Claude Code installed
- A `~/.looker/looker.ini` for the instance you want to assess:

  ```ini
  [Looker]
  base_url=https://<host>.cloud.looker.com
  client_id=...
  client_secret=...
  verify_ssl=true
  ```

  No port needed — modern Google-hosted Looker serves the API on 443. A legacy `:19999`
  base_url self-heals (retries on 443 with a warning). Confirm with
  `python3 scripts/looker_api.py whoami`.
- Python 3 (inventory script) and Ruby (HTML renderer)

For the **usage axis** (dashboard / Look runs, active users), the role needs access
to the `system__activity` model (`see_system_activity` — admin or equivalent). Without
it, usage degrades to a tile-count proxy and everything else still runs.

## How to run

In Claude Code:

```
/looker-assessment
```

Or directly:

```bash
python3 scripts/looker-inventory.py --out /tmp/assessment-<host> --usage-days 90
ruby   scripts/render-readout-html.rb --out /tmp/assessment-<host>
```

The skill will:

1. Probe auth + role (`looker_api.py whoami`)
2. Inventory models / explores / projects / connections / Looks / dashboards / users /
   groups / folders
3. Pull dashboard / Look usage + active users from the System Activity model
4. Open each dashboard to bucket tile vis-types and hard-to-migrate features (pivots,
   table calcs, merged results, custom viz, Liquid, filters)
5. Score `value / (1 + cost)` and tag each dashboard
6. Write `inventory.json` + `readout.md`, then render `readout.html`
7. Offer to hand off the shortlist to `looker-to-sigma`

Flags: `--out DIR`, `--usage-days N` (System Activity window, default 90),
`--no-deep` (skip the per-dashboard scan — counts + usage only), `--ini PATH`.

## The key idea

The same rules that drive `convert_lookml_to_sigma` + the dashboard builder also
**predict migration effort**: bucket each tile's vis-type and features against Sigma's
coverage. Pivots / table calcs / Liquid → `manual` (brief setup in Sigma); merged
results / custom viz → `unhandled` (review). Usage comes from Looker's System Activity
model. See `refs/complexity-scoring.md`.

## What this is NOT

- **Not** a write tool. It cannot and will not modify Looker content or post to Sigma.
- **Not** a complete instance audit. It covers the signals that matter for Sigma
  migration scoping (no folder/group ACL audit, no PDT/datagroup analysis).
- **Not** the converter. It scopes; `looker-to-sigma` converts. The `shortlist` in
  `inventory.json` is the hand-off between them.

## Privacy

This skill sends instance/dashboard metadata (not warehouse rows) through the
Anthropic API. See [`PRIVACY.md`](./PRIVACY.md) for the full disclosure to review with
your privacy/legal team before running.

## Sibling skills

- [`looker-to-sigma`](../looker-to-sigma/) — the conversion skill this feeds into.
- `tableau-assessment` / `qlik-assessment` — the analogs this skill mirrors (same
  scoring framework, same Sigma-branded readout theme).
