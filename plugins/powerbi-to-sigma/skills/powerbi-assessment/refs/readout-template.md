# Power BI / Fabric Assessment — {{tenant_name}}

**Tenant:** `{{tenant_name}}` | **Mode:** {{mode}} | **Generated:** {{generated_at}}

> Lightweight pre-scoping readout produced by the `powerbi-assessment` skill.
> READ-ONLY — nothing was written to Power BI or posted to Sigma. The migration
> shortlist below feeds directly into the `powerbi-to-sigma` conversion skill.

---

## 1. Environment overview

| | |
|---|---|
| Workspaces | **{{workspaces}}** ({{on_capacity}} on Fabric capacity) |
| Semantic models | **{{semantic_models}}** |
| Reports | **{{reports}}** |
| Dashboards | {{dashboards}} |
| Dataflows | {{dataflows}} |
| Lakehouses / Warehouses | {{lakehouses}} / {{warehouses}} |
| Notebooks / other items | {{notebooks}} / {{other_items}} |

{{#limited_mode_banner}}
> ⚠️ Running WITHOUT the Fabric Administrator role — usage/adoption (views,
> distinct users) and tenant-wide sprawl (Scanner API) are unavailable. The
> shortlist below is **complexity-only**: it ranks reports by size/richness, not
> by who actually uses them. Re-run as a Fabric Administrator to add the usage
> axis. Everything else (per-model DAX complexity, per-report visuals) is
> independent of admin role and is accurate.
{{/limited_mode_banner}}

---

## 2. Workspaces

{{workspaces_table}}

On-capacity workspaces are writable via the Fabric API; "My workspace" content
is per-user and usually the first to consolidate.

---

## 3. Semantic-model complexity

Power BI's real conversion burden lives in the **semantic model** (DAX measures,
calculated columns, calculated tables, RLS roles, DirectQuery), not the report.
This is the richest signal in the assessment.

{{models_table}}

DAX-convertibility buckets (from `research/dax-to-sigma-coverage.md`, validated
against `powerbi-to-sigma/fixtures`):
- **a — mechanical** (~70% of typical measures): direct Sigma-formula rewrite.
- **b — restructuring**: needs a grouped element, a parallel join, or a
  pre-aggregated element (TOTALYTD, RANKX, USERELATIONSHIP, ALL/ALLEXCEPT).
- **c — no Sigma equivalent**: dynamic context the formula language can't
  express (PATH hierarchies). Rare.

Across all scanned models: **{{total_dax_a}} mechanical / {{total_dax_b}}
restructuring / {{total_dax_c}} no-equivalent** measures.

---

## 4. Warehouse sources

Parsed from each model's M (Power Query) expressions:

{{warehouse_table}}

Migration signal: models on a cloud warehouse Sigma already supports (Snowflake,
BigQuery, Databricks, Redshift, Synapse, Postgres) are **drop-in** — Sigma reads
the same tables directly, no extract relocation. Import-mode models hide the
warehouse behind a cached extract; the M source above is what Sigma re-points to.

---

## 5. Refresh insights

{{refresh_table}}

{{refresh_notes}}

---

## 6. Report priority — {{usage_basis}}

{{usage_table}}

{{#has_usage}}
**Cold (zero-view) reports:** {{n_cold}} — retire-don't-migrate candidates.
{{/has_usage}}
{{^has_usage}}
> Usage data unavailable (no Fabric Administrator role). Reports above are ranked
> by a complexity proxy (page + visual count), not real view counts.
{{/has_usage}}

---

## 7. Migration shortlist ({{value_basis}})

`cost = 10·unhandled + 3·manual + 1·hint`, ranked by `value / (1 + cost)`.
Higher score = better first-migration candidate. For Power BI, `manual` =
restructuring DAX + calculated tables + RLS roles; `unhandled` = no-equivalent
DAX + unsupported custom visuals.

{{shortlist_table}}

The top {{shortlist_top_n}} reports have **{{shortlist_total_unhandled}}
unhandled features between them**.

---

{{dup_dashboards}}

---

## 8. Per-report complexity

{{complexity_table}}

**Total unhandled features across the tenant: {{total_unhandled}}** spanning
{{n_workbooks_with_unhandled}} reports. Each gets a `gap-scout`-style triage at
conversion time.

---

## 9. What this skill found vs. what it didn't

**Found (independent of admin role, user-delegated token):**
- Environment counts (workspaces, models, reports, dashboards, dataflows, lakehouses)
- On-capacity flag per workspace
- Per-model: table / measure / calc-column / calc-table counts, RLS roles,
  import-vs-DirectQuery, warehouse sources (parsed from M)
- Per-model DAX-convertibility classification (a / b / c)
- Per-report: page count, visual count, visual-kind histogram, custom-visual usage
- Refresh history (when the Power BI REST token is available)

{{#has_usage}}
**Added by Fabric-admin mode:**
- Per-report view counts and distinct-user counts (Activity Events API)
- Usage-weighted migration shortlist
- Cold-report detection
{{/has_usage}}

**Not gathered (out of scope):**
- Per-visual field-level bindings (the converter re-derives these from PBIR at conversion time)
{{^has_usage}}
- Usage / adoption (views, distinct users) — needs the **Fabric Administrator**
  role for the Activity Events API. Re-run as admin to add it.
- Tenant-wide sprawl beyond the signed-in user's accessible workspaces — needs
  the **Scanner API** (also Fabric Administrator).
{{/has_usage}}

---

## 10. Privacy

What crossed Anthropic's API on its way through Claude during this assessment:

- Aggregate counts (workspace / model / report counts)
- Model and report names, workspace names, owner where available
- **Full TMSL** for each semantic model — this includes **DAX measure
  expressions and RLS role definitions** (richer and more sensitive than
  Tableau's `.twb`)
- **PBIR** report definitions — visual configuration
- Refresh job results (when available)

What did NOT cross:
- Warehouse rows (this skill never queries the underlying database)
- Power BI / Entra credentials (handled by the device-code cache, not surfaced)
- Actual report cell values

See `PRIVACY.md` for the full disclosure.

---

## 11. Hand-off package

This directory contains:

- `readout.md` — this report
- `inventory.json` — raw environment + per-model + per-report metadata
- `complexity.json` — per-report DAX / visual complexity scoring
- `shortlist.json` — value/cost-ranked migration shortlist
- `migration-plan.json` — per-report `recommended_path` + DM clusters
- `raw-tmsl/` — decoded TMSL per model (delete after review if you'd rather not retain DAX text)
- `raw-pbir/` — decoded PBIR per report

Nothing is uploaded automatically. To share, zip and send deliberately.

---

## 12. Next steps

1. **Pilot the top {{recommended_pilot_n}} reports** with the `powerbi-to-sigma`
   skill — the migration-plan groups them into DM clusters that share a Sigma
   data model.
2. **Triage the `needs-gap-scout` queue** ({{n_needs_scout}} reports): no-equivalent
   DAX or unsupported custom visuals that need a design decision first.
{{#has_usage}}
3. **Retire the `retire` queue** ({{n_retire}} reports): zero views, no migration value.
{{/has_usage}}
4. **Re-run as a Fabric Administrator** to add the usage axis if you want a
   usage-weighted (not complexity-only) shortlist.
