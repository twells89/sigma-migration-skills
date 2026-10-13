---
name: spotfire-assessment
description: >-
  Inventory a Spotfire estate from a full exported manifest, normalized raw-DXP
  inventory, or Spotfire 14+ Library REST API v2 metadata and produce a
  migration-readiness readout: analyses, content mix, feature coverage,
  evidence gaps, duplicates, and a value/cost-ranked shortlist. Use to scope a
  Spotfire-to-Sigma migration. Offline-complete, live-unvalidated, read-only;
  never writes to Spotfire or Sigma.
user-invocable: true
---

# Spotfire migration assessment

> **STATUS: foundation / offline-complete.** The full-manifest and Library-
> metadata tiers run hermetically with `bash run-offline.sh`. The Spotfire 14+
> Library REST API v2 transport follows the official public contract but is
> **LIVE-UNVALIDATED**. Never describe live inventory as validated until it has
> been checked against a real tenant.

<!-- mandatory-pre-read -->
Read before use:
- `refs/evidence-tiers.md` — input contracts, capability tiers, and degradation
- `refs/complexity-scoring.md` — coverage catalog, score, and tag rules
- `refs/library-rest-v2.md` — 14+ live transport, OAuth, pre-14 fallback, Cloud caveat
<!-- /mandatory-pre-read -->

## Safety contract

This skill is read-only. Offline modes read local JSON. Live mode issues only
`GET /info` and `GET /items` through Library REST API v2. If the script mints a
client-credentials token, the one `POST /spotfire/oauth2/token` is an
authentication exchange, not a content write. It never calls a Spotfire
create/update/delete endpoint, never downloads or introspects DXP content,
never uses Sigma credentials, and never posts to Sigma.

## Capability tiers

1. **Full exported manifest** (`--manifest`) — visuals, formulas, security,
   scripts, data functions, mods, sources, and optional usage. This is the only
   tier that can claim category-complete scoring when the export declares all
   categories.
2. **Library metadata only** (live v2 or a Library-items `--inventory`) —
   item/path/owner/timestamps/favorites/ACL metadata. DXP internals are unknown;
   the shortlist is an estate index, not converter coverage.
3. **Raw-DXP inventory** (`--inventory`) — normalized JSON produced by an
   authorized local exporter. Coverage is only as complete as its declared
   `evidence.available_categories`. Passing a `.dxp` binary is rejected because
   the public API documents downloaded content as opaque.

`--from-fixtures DIR` selects exactly one `manifest.json`,
`library-items.json`, or `inventory.json` in that directory.

## Phases

0. **Select evidence / probe.** Choose one input mode. The script writes
   `probe.json` with the tier, read-only boundary, version boundary, and gaps.
1. **Normalize inventory.** Normalize analyses, sources, feature categories,
   Library assets, and evidence declarations into `inventory.json`. Write
   `usage.json` only when views, viewers, favorites, or last-access evidence
   actually exists.
2. **Score coverage.** Classify core visuals, formulas, security, custom
   scripts, data functions, and mods with
   `../spotfire-to-sigma/refs/catalogs/coverage-catalog.json`. Unknowns
   degrade conservatively. Write
   `complexity.json`, `shortlist.json`, and `migration-plan.json`; duplicate
   detection is local and best-effort.
3. **Render.** Write `readout.md`, surfacing capability tier and every evidence
   gap. Treat scores as directional heuristics, never estimates.
4. **Hand off.** Give `migration-plan.json` to `spotfire-to-sigma`; the
   converter must reconfirm all evidence-limited classifications during
   discovery.

## Run offline

```bash
bash run-offline.sh
```

That one command runs both committed fixtures and the unit suite with no
network, Spotfire credentials, or Sigma credentials.

Run a specific local export:

```bash
python3 scripts/assess.py --manifest /path/export-manifest.json --out /tmp/spotfire-assessment
python3 scripts/assess.py --inventory /path/dxp-inventory.json --out /tmp/spotfire-assessment
```

## Run live (14+; LIVE-UNVALIDATED)

Prefer a pre-minted token carrying only `api.library.read`:

```bash
export SPOTFIRE_BASE_URL=https://spotfire.example
export SPOTFIRE_ACCESS_TOKEN=...
python3 scripts/assess.py --server-version 14.6 --out /tmp/spotfire-assessment
```

Or let the script use the official client-credentials token endpoint:

```bash
export SPOTFIRE_BASE_URL=https://spotfire.example
export SPOTFIRE_CLIENT_ID=...
export SPOTFIRE_CLIENT_SECRET=...
python3 scripts/assess.py --server-version 14.6 --out /tmp/spotfire-assessment
```

The registered client must allow `client_credentials` and
`api.library.read`. `SPOTFIRE_TOKEN_AUTH_METHOD=basic` is the default;
set `post` only when the client was registered for `client_secret_post`.
Spotfire releases before 14 do not have Library REST API v2: use an authorized
offline manifest/inventory. Spotfire Cloud availability and API-client
registration are deployment-dependent and unverified here.

## Deliverables

- `probe.json` — mode/tier decision, API boundary, and gaps
- `inventory.json` — normalized estate inventory
- `usage.json` — only when usage/metadata signals exist
- `complexity.json` — per-analysis feature classifications and rollups
- `shortlist.json` — fixed tag priority then score-descending
- `migration-plan.json` — source clusters, waves, duplicate groups, gaps
- `readout.md` — plain-Markdown migration-readiness summary

All files remain local until a human deliberately shares them. See
`PRIVACY.md` for data handling.
