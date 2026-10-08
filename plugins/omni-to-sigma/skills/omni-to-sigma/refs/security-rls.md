# Omni security → Sigma RLS / CLS

Detect always. Apply only with `--apply --confirm` and `SIGMA_API_TOKEN`,
and even then this skill does not invent user-attribute values.

| Omni | Where | Sigma |
|---|---|---|
| `access_filters` / `default_topic_access_filters` | topic or model YAML | User attribute + element filter on the named field. `values_for_unfiltered` is recorded, not turned into a default that opens every row. |
| `access_grants` + `required_access_grants` | model / topic / field | Column visibility. `|` / `&` grant expressions are not auto-applied. |
| `{{ omni_attributes.* }}` in field SQL | view | Fail-loud. The field is omitted from the DM. |

```bash
ruby scripts/detect-rls.rb --model-dir <dir> --out rls.json
ruby scripts/apply-sigma-rls.rb --detect rls.json --out rls-plan.json
```

`--strict` on detect exits 2 when any finding exists, so a run cannot claim
"no RLS" by skipping the scan. Blank attribute defaults in Omni are fail-closed;
do not copy a `values_for_unfiltered` value into the Sigma attribute default.
