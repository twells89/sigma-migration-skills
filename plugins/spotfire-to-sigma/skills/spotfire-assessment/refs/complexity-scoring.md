# Spotfire assessment complexity scoring

`../../spotfire-to-sigma/refs/catalogs/coverage-catalog.json` is the
machine-readable source of truth shared by this assessment and the converter.
Its status is `foundation-assumptions`: update classifications only with
converter or live evidence.

## Feature classification

Every observed feature is classified `auto`, `hint`, `manual`, or
`unhandled`. Unknown visual/script/data-function/mod types fall to
`unhandled`; unknown formula functions and security mechanisms fall to
`manual`. Conservative defaults prevent an unfamiliar feature from being
reported as automatically convertible.

### Core visuals

- **Auto:** table and basic bar/line/area/combo/pie/scatter/KPI/summary/box
  visuals.
- **Hint:** text area, image, and filter panel; the target element exists but
  layout semantics require review.
- **Manual:** map, treemap, heat map, waterfall, funnel, parallel-coordinate,
  graphical table, network, and Gantt.
- **Unhandled:** custom visual and embedded web content, plus unknown types.

### Formulas

Simple operators and cataloged core aggregate/string/date/math functions are
`auto`. Rank is `hint`. `OVER`, `THEN`, `INTERSECT`, period navigation,
statistical `SN`, and regex functions are `manual`. External methods,
IronPython, and TERR markers are `unhandled`. A function not in the catalog is
`manual`, not guessed.

### Security

Library ACLs, row-level security/data limiting, column security, Information
Link security, and personalized views are `manual`: they require a deliberate
Sigma role/user-attribute/data-model design. Custom auth/authorization and
impersonation are `unhandled` pending a design decision.

### Custom scripts, data functions, and mods

IronPython/JavaScript/custom scripts, Python/TERR/R-service/MATLAB/SAS data
functions, and Spotfire visualization/action mods are `unhandled`. They are
executable custom behavior, not expressions the foundation converter can
promise to translate.

## Cost, value, score

For each analysis:

```text
cost  = 10 × unhandled + 3 × manual + 1 × hint

value = views × sqrt(max(distinct_viewers, 1))       when view evidence exists
      = 10 × (1 + favorite_count)                    Library favorite proxy
      = 10 × (1 + counted_features / 4)              complexity proxy

score = value / (1 + cost)
```

`last_accessed` is retained as evidence but is not turned into a score, keeping
offline output deterministic and avoiding an arbitrary recency model.

Tags are evaluated in this order:

1. quantitative view evidence and `views == 0` → `retire`;
2. at least one unhandled feature → `needs-gap-scout`;
3. score ≥ 20 with no manual feature → `migrate-first`;
4. score ≥ 10 → `easy-win`;
5. otherwise → `moderate`.

The ranking order is `migrate-first`, `easy-win`, `moderate`,
`needs-gap-scout`, `retire`, then score descending within a tag. This is a
pre-scoping heuristic, not an effort estimate.

## Evidence degradation

- **Full manifest:** all six categories are eligible for scoring. An export
  can still be wrong; converter discovery must verify it.
- **Raw-DXP inventory:** only categories named in
  `evidence.available_categories` are complete. Missing categories are not
  zero; they are gaps.
- **Library metadata:** internal categories are unknown. ACL metadata can add
  manual cost, and favorites can provide a weak value proxy, but the score
  cannot represent DXP convertibility. `readout.md` calls this out loudly.

`pct_auto` is `(auto + hint) / all counted features`. It is zero when no
features were visible. At metadata tier this is a degraded observed-feature
ratio, not estate-wide auto-migratability.
