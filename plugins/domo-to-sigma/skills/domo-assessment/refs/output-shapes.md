# Output shapes — domo-assessment

Six JSON files + one Markdown file land in `<out>/` (probe → discover → score
→ render). Shapes deliberately mirror `tableau-assessment` / `powerbi-assessment`
so a shared `dup-dashboards.py` and the same `value`/`cost`/`score`/`tag`
vocabulary carry across every `*-assessment` skill. This doc documents the
shapes the COMMITTED scripts actually emit — if it and a script's header
comment ever drift, the script is the source of truth.

## `probe.json` (`scripts/probe-governance.rb`)

```json
{
  "tier": "A | B",
  "public_reachable": true,
  "audit_scope": true,
  "governance_datasets": {
    "datasets": "<fixture path (offline) | live DataSet id>",
    "cards": "...", "pages": "...", "users": "...", "pdp": "...",
    "dataflows": "...", "activity-log": "...", "beast-modes": "... (Tier A only)"
  },
  "reasons": ["<human-readable trace of the tier/audit decision>", "..."]
}
```

`tier` is decided by fixture presence offline (`beast-modes.json` or
`card-defs.json` ⇒ `A`) / by dev-token + Beast-Modes-dataset reachability live.
`audit_scope` is `governance_datasets.key?('activity-log')`. Downstream scripts
(`discover-domo.rb`, `score-coverage.rb`) do NOT read `governance_datasets`'
values directly — they re-resolve each table themselves (see the "IMPORTANT"
note atop `discover-domo.rb`); `probe.json` is a decision record, not a handle.

## `inventory.json` (`scripts/discover-domo.rb`)

```json
{
  "instance": "<instance name, or 'fixtures:<dir>' offline>",
  "datasets": [{ "id": "", "name": "", "owner": "", "connector_type": "",
                 "row_count": 0, "last_updated": "", "update_schedule": "" }],
  "pages": [{ "id": "", "title": "", "owner": "", "parent_page_id": null,
              "card_count": 0 }],
  "cards": [{ "id": "", "title": "", "type": "", "page_id": "", "dataset_id": "",
              "views": 0,
              "beast_modes": [{ "id": "", "name": "", "sql": "" }],
              "pdp": false, "dataflow_sourced": false }],
  "users": [{ "id": "", "name": "", "email": "", "role": "", "last_login": "",
              "created": "" }],
  "warnings": [{ "_shapeSuspect": true, "table": "<logical table name>",
                 "column": "<name> | null", "reason": "<why>" }]
}
```

Notes:
- `cards[].beast_modes` is **only ever populated on Tier A** (parsed from the
  Tier-A-only "Beast Mode Refs" column); Tier B cards always have `[]`.
- `cards[].views` is pre-computed from the Activity Log here (if present) —
  `score-coverage.rb` still prefers `usage.json`'s per-card view count when
  both exist, falling back to this field.
- `warnings` records ONE entry per `(table, column)` the first time a column
  is missing from a governance table's schema (degrade-visibly, not
  silently-wrong) — see `col()` / `make_col()` in `discover-domo.rb`.
- No `dataflows` / `groups` / `pdp_policies` arrays are written to
  `inventory.json` in v1 — the DataFlow-output and PDP-policy tables are
  consumed internally (folded into `cards[].dataflow_sourced` / `cards[].pdp`)
  and not re-exposed as their own top-level arrays.

## `usage.json` (`scripts/discover-domo.rb`, written only when an Activity Log table is present)

```json
{ "by_card": { "<cardId>": { "views": 0, "distinct_viewers": 0 } } }
```

Absence of this file (not a `null`/empty value) is how downstream scripts
detect "no audit scope" — `score-coverage.rb`'s `AUDIT` flag and
`render-readout.rb`'s value-basis line both key off `File.exist?`.

## `complexity.json` (`scripts/score-coverage.rb`)

One row per Domo card (flat array, NOT keyed by id — unlike the equivalent
file in some other `*-assessment` skills).

```json
{
  "tier": "A | B",
  "artifacts": [
    {
      "id": "", "title": "", "page_id": "", "dataset_id": "",
      "n_auto": 0, "n_hint": 0, "n_manual": 0, "n_unhandled": 0,
      "views": 0, "distinct_viewers": 0,
      "value": 0.0, "cost": 0, "score": 0.0,
      "tag": "migrate-first | easy-win | moderate | needs-gap-scout | retire"
    }
  ],
  "rollup": {
    "by_tag": { "migrate-first": 0, "easy-win": 0, "moderate": 0,
                "needs-gap-scout": 0, "retire": 0 },
    "totals": { "n_artifacts": 0, "n_auto": 0, "n_hint": 0, "n_manual": 0,
                "n_unhandled": 0, "total_views": 0 },
    "pct_auto": 0.0
  }
}
```

- `n_hint` is always `0` for Domo (no `hint` tier — bucket-a Beast Modes are
  already mechanical; the field is kept only for cross-skill shortlist/render
  compatibility). See `refs/complexity-scoring.md` §1.
- On Tier B, `n_auto`/`n_manual`/`n_unhandled` come ONLY from the structural
  flags (`pdp` → `+1 manual`, `dataflow_sourced` → `+1 unhandled`) — Beast
  Mode buckets are forced to zero. `pct_auto` is computed the same formula on
  both tiers but reads near-zero on Tier B as a result; this is a **degraded
  signal**, not a real auto-migratability measurement (§4).
- There is no `value_basis` field on this file — whether `value` used the
  Activity Log or the complexity-only proxy is NOT persisted; a consumer
  infers it the same way `score-coverage.rb` decided it: `usage.json` present
  in the same directory.

## `shortlist.json` (`scripts/score-coverage.rb`)

Same artifact shape as `complexity.json`, re-sorted: `migrate-first` /
`easy-win` groups first, then by `score` descending within each tag group.

```json
{ "tier": "A | B", "artifacts": [ /* same shape as complexity.json's artifacts[] */ ] }
```

## `migration-plan.json` (`scripts/score-coverage.rb`)

The handoff contract to `domo-to-sigma`. `clusters` and `pages` are Hashes
keyed by id (not arrays).

```json
{
  "tier": "A | B",
  "clusters": {
    "<datasetId>": { "dataset_id": "", "card_ids": [""], "card_count": 0,
                      "by_tag": { "<tag>": 0 } }
  },
  "pages": {
    "<pageId>": { "page_id": "", "card_ids": [""],
                  "recommended_path": "convert | gap-scout | retire" }
  },
  "duplicate_dashboards": {
    "groups": [{
      "recommendation": "consolidate | review",
      "members": [{ "id": "", "name": "", "usage": 0 }],
      "size": 0,
      "drivers": { "max_pair_score": 0.0, "min_field_overlap": 0.0,
                   "min_source_overlap": 0.0, "shared_sources": [""] },
      "conversions_avoided": 0
    }],
    "summary": { "dashboards_scanned": 0, "duplicate_groups": 0,
                 "dashboards_in_groups": 0, "conversions_avoided": 0 }
  }
}
```

`pages[].recommended_path`: `retire` if every card on the page is tagged
`retire`; else `gap-scout` if any card is `needs-gap-scout`; else `convert`.

`duplicate_dashboards` is `scripts/dup-dashboards.py`'s output over the card
list (adapter: `id`/`name`/`sources: [dataset_id]`/`viz: [type]`/`usage: views`).
A Python failure there is swallowed — `duplicate_dashboards` degrades to
`{ "groups": [], "summary": {} }` rather than failing the run.

## `readout.md` (`scripts/render-readout.rb`)

Markdown only — no HTML. Reads `complexity.json` + `inventory.json`
(required), `shortlist.json` + `migration-plan.json` (optional, degrade to
`complexity.json`'s artifacts / empty rollups if missing), and checks whether
`usage.json` exists in `--in` to label the value basis. Sections: title +
heuristic-scoring disclaimer (+ a Tier-B "Beast Mode not visible" caveat when
`tier == 'B'`) → estate overview → cards-by-tag → migration shortlist table
(title | tag | score | views | gaps) + retire/gap-scout queues → dataset
cluster + page rollup → duplicate-consolidation note → method notes →
hand-off file listing → next steps. See `refs/readout-template.md` for the
exact section ordering and `{{placeholder}}` / `{{#key}}...{{/key}}` tokens;
composition is deterministic (JSON in, template fill, file out — no live
Domo/Sigma calls).
