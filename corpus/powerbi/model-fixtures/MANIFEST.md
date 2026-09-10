# powerbi / model-fixtures

The 8 TMSL `.bim` semantic-model fixtures that live in the powerbi-to-sigma
plugin (NOT duplicated here — referenced by relative path). All synthetic
workforce/DEMO_DB.DEMO demo models; per-fixture DAX → Sigma oracle tables are in the
plugin's own
[`fixtures/MANIFEST.md`](../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/MANIFEST.md).

| Fixture | Focus |
|---|---|
| fixture_01_mechanical | bucket (a) mechanical DAX rewrites, RELATED/LOOKUPVALUE calc cols |
| fixture_02_time_intelligence | TOTALYTD/MTD, SAMEPERIODLASTYEAR, DATEADD |
| fixture_03_filter_context | CALCULATE+ALL/ALLEXCEPT, FILTER |
| fixture_04_iterators_rank_var | RANKX, VAR/RETURN, nested iterators |
| fixture_05_relationships_hard | inactive rels, USERELATIONSHIP, calculated tables |
| fixture_06_kitchen_sink | everything at once |
| fixture_07_comp_distribution | percentiles/median distribution patterns |
| fixture_08_safety_absence_patterns | window/time DAX on safety data |
| fixture_10_retail_calendar | calculated retail calendar (Black Friday, Easter, Back to School, Christmas) |

## Converter

`mcp__sigma-data-model__convert_powerbi_to_sigma` with `model_json=<fixture>`,
empty connection/database/schema.

## Golden

`golden/fixture_01_mechanical.dm.json` — converter output for fixture_01
(representative regression anchor: covers measures→metrics, calc columns,
RELATED → derived-View element move, relationships, format strings, warning
text). Add goldens for the other fixtures the same way (`--reconvert`).

## Expectations

```json
{
  "artifacts": [
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/fixture_01_mechanical.bim", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/fixture_02_time_intelligence.bim", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/fixture_03_filter_context.bim", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/fixture_04_iterators_rank_var.bim", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/fixture_05_relationships_hard.bim", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/fixture_06_kitchen_sink.bim", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/fixture_07_comp_distribution.bim", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/fixture_08_safety_absence_patterns.bim", "format": "json"},
    {"path": "../../../plugins/powerbi-to-sigma/skills/powerbi-to-sigma/fixtures/fixture_10_retail_calendar.bim", "format": "json"}
  ],
  "goldens": {
    "fixture_01_mechanical.dm.json": {
      "pages": 1,
      "elements": 5,
      "columns": 56,
      "metrics": 15,
      "relationships": 2,
      "warnings": 8,
      "element_names": ["EMPLOYEES", "ABSENCE_RECORDS", "SAFETY_INCIDENTS", "ABSENCE_RECORDS View", "SAFETY_INCIDENTS View"]
    }
  }
}
```
