# Spotfire assessment evidence tiers and input contracts

The assessment separates **missing evidence** from a real empty feature list.
This matters: a Library-only result with zero scripts does not prove an
analysis has no scripts; the Library API cannot see inside the DXP.

## 1. Full exported manifest

Invoke with `--manifest FILE`, or put `manifest.json` in a fixture directory.
The supported v1 shape is:

```json
{
  "instance": {"name": "Acme", "server_version": "14.6"},
  "data_sources": [{"id": "sales", "name": "Sales"}],
  "users": [{"id": "u1", "name": "Owner"}],
  "analyses": [{
    "id": "a1", "title": "Sales", "path": "/Team/Sales",
    "source_ids": ["sales"], "fields": ["Region", "Revenue"],
    "pages": [{"id": "p1", "title": "Overview"}],
    "visuals": [{"id": "v1", "type": "bar_chart", "fields": ["Region"]}],
    "formulas": [{"name": "Revenue", "expression": "Sum([Revenue])"}],
    "security": [{"type": "row_level_security"}],
    "scripts": [{"name": "Refresh", "language": "IronPython"}],
    "data_functions": [{"name": "Forecast", "language": "Python"}],
    "mods": [{"name": "Custom", "type": "spotfire_mod"}],
    "usage": {"views": 25, "distinct_viewers": 4}
  }]
}
```

The keys `visuals`, `formulas`, `security`, `scripts`, `data_functions`, and
`mods` are the category-completeness contract. A present empty array means
"exported and empty." The full-manifest mode assumes all six are part of the
export contract; the exporter, not this assessment, must prove that assertion.

## 2. Library metadata only

Live mode and `--inventory` over a Library response accept either:

```json
{"items": [{"id": "a1", "title": "Sales", "type": "spotfire.dxp"}]}
```

or the bare item array. Official v2 fields consumed when present are `id`,
`title`, `path`, `type`, `createdBy`, `created`, `modified`, `accessed`,
`favoriteCount`, `properties`, and `permissions`.

Only `spotfire.dxp` items become analyses. Other item types remain in
`inventory.json.library.item_type_counts`, including `spotfire.datafunction`,
`spotfire.dxpscript`, and `spotfire.visualizationmod`. The public metadata does
not establish which analysis uses those global assets, so the scorer does not
fabricate links.

## 3. Raw-DXP inventory

`--inventory FILE` accepts normalized JSON with the full-manifest shape plus an
optional per-analysis evidence declaration:

```json
"evidence": {
  "available_categories": ["visuals", "formulas", "security"]
}
```

Categories omitted from that list are written to
`evidence.missing_categories` and surfaced in every downstream artifact. If no
declaration exists, only feature keys actually present on that analysis count
as evidence.

This mode does **not** accept or unpack a `.dxp` binary. Spotfire's public
Library API documentation says downloaded item content is opaque unless it is
a publicly documented format. Use an approved local export mechanism and give
this skill only its normalized JSON inventory.

## Usage evidence

`usage.json` is omitted when no evidence exists. When written:

```json
{
  "evidence_kind": "exported-usage | library-metadata-signals",
  "quantitative_views": true,
  "by_analysis": {
    "a1": {
      "views": 25,
      "distinct_viewers": 4,
      "last_accessed": "2026-09-30T12:00:00Z",
      "favorite_count": 2
    }
  }
}
```

Only `views` is sufficient to tag a zero-use analysis `retire`.
`favorite_count` is a weaker value proxy. `last_accessed` is disclosed but not
converted into a time-dependent score.

## Output invariants

- `probe.json`, `inventory.json`, `complexity.json`, `shortlist.json`,
  `migration-plan.json`, and `readout.md` are always written after valid input.
- `usage.json` is conditional on evidence.
- `complexity.json.artifacts[]` contains `n_auto`, `n_hint`, `n_manual`,
  `n_unhandled`, category counts, feature details/reasons, score, tag, and
  evidence gaps.
- `migration-plan.json` clusters analyses by known sources, provides
  `convert`/`gap-scout`/`retire` waves, and embeds local duplicate detection.
- No output contains OAuth client secrets or access tokens.
