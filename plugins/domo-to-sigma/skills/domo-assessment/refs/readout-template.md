# Migration readiness — {{instance}} (Tier {{tier}})

**Instance:** `{{instance}}` | **Tier:** {{tier}} | **Value basis:** {{value_basis}} | **Generated:** {{generated_at}}

> Lightweight, read-only pre-scoping readout produced by the `domo-assessment`
> skill. Nothing was written back to Domo and nothing was posted to Sigma —
> this directory is JSON in, Markdown out. The migration plan below hands off
> directly to the `domo-to-sigma` conversion skill.

> **Heuristic scoring** — every `value` / `cost` / `score` / `tag` below comes
> from a fixed pre-scoping formula (`cost = 10·unhandled + 3·manual + 1·hint`,
> `score = value / (1 + cost)`), not a hands-on project estimate. Treat it as a
> directional starting order for triage, not a quote — see
> `refs/complexity-scoring.md`.

{{#tier_b}}
> ⚠️ **Tier B — Beast Mode complexity not visible.** Only the public Domo API
> was reachable (no dev token, no `Beast Modes` governance dataset), so no
> Beast Mode SQL text could be bucketed into auto/manual/unhandled — those
> buckets are forced to zero for every card. **`{{pct_auto}}%` auto-migratable
> below reflects that degraded signal set — it does NOT mean nothing on this
> estate is auto-migratable.** Cost/score here are driven only by the
> structural flags (PDP, DataFlow-sourced) plus raw Beast Mode counts; the
> shortlist is directional, not precise. Re-run with `DOMO_DEV_TOKEN` set (or
> ask an admin to install the `Beast Modes` governance dataset) for real
> per-card complexity. See `refs/complexity-scoring.md` §4.
{{/tier_b}}

---

## 1. Estate overview

| | |
|---|---|
| Datasets | **{{n_datasets}}** |
| Pages | **{{n_pages}}** |
| Cards | **{{n_artifacts}}** |
| Users | {{n_users}} |
| Total card views | {{total_views}} |
| Auto / Hint / Manual / Unhandled (feature counts) | {{n_auto}} / {{n_hint}} / {{n_manual}} / {{n_unhandled}} |
| Auto-migratable (auto+hint ÷ all counted features) | **{{pct_auto}}%** |

---

## 2. Cards by tag

{{tag_table}}

---

## 3. Migration shortlist

`value` = {{value_formula}}. `cost = 10·unhandled + 3·manual + 1·hint`. `score
= value / (1 + cost)` — higher score = better first-migration candidate.
Ordered `migrate-first` / `easy-win` first, then by score within each tag
(same order as `shortlist.json`).

{{shortlist_table}}

**Retire queue:** {{n_retire}} card(s) tagged `retire` (zero views, no
migration value) — {{retire_titles}}.

**Gap-scout queue:** {{n_needs_scout}} card(s) tagged `needs-gap-scout` — at
least one unhandled feature; each gets a gap-scout pass before conversion.

---

## 4. Migration plan rollup

Cards sharing a dataset cluster onto one Sigma data model; pages roll up to a
single recommended path from their cards' tags.

**Dataset clusters:**

{{cluster_table}}

**Pages:**

{{page_table}}

---

## 5. Duplicate / consolidation candidates

{{duplicate_note}}

---

## 6. What this readout is based on

**Every tier:**
- Environment counts (datasets, pages, cards, users) from the Governance/DomoStats system datasets
- Per-card views + distinct viewers (when an Activity Log dataset is installed)
- Structural flags folded into cost on every card: PDP policy on the card's dataset (`+1 manual`), DataFlow-sourced dataset (`+1 unhandled`)
- Duplicate-card detection (`dup-dashboards.py`) over card title/dataset/type

{{#tier_a}}
**Added by Tier A (dev token or a public `Beast Modes` dataset):**
- Per-card Beast Mode SQL bucketed into auto / manual / unhandled (see `refs/complexity-scoring.md` §1)
{{/tier_a}}

**Not gathered (v1 scope):**
- Card-type coverage histogram (recorded per-card but not yet folded into cost — see `refs/complexity-scoring.md` §2)
- Card-level filter/drill-path/link and DDX-brick flags (Tier-A-only, not yet parsed by `discover-domo.rb`)
- DataFlow transform depth (flagged as `unhandled`, not measured)

---

## 7. Hand-off package

This directory contains:

- `readout.md` — this report
- `probe.json` — tier decision + which governance datasets were reachable
- `inventory.json` — raw datasets/pages/cards/users
- `usage.json` — per-card views/distinct-viewers (only when Activity Log was installed)
- `complexity.json` — every card scored (`value`/`cost`/`score`/`tag`)
- `shortlist.json` — the same cards, re-sorted for migration order
- `migration-plan.json` — dataset clusters + per-page recommended path + duplicate-card groups — the handoff contract to `domo-to-sigma`

Nothing is uploaded automatically. To share with a Sigma rep, zip the
directory and send it manually.

---

## 8. Next steps

1. **Pilot the `migrate-first` / `easy-win` cards** with the `domo-to-sigma`
   skill — `migration-plan.json`'s clusters group them by shared dataset so
   one Sigma data model serves several cards.
2. **Triage the gap-scout queue** ({{n_needs_scout}} card(s)): each has at
   least one unhandled feature and needs a design decision before conversion.
3. **Retire the retire queue** ({{n_retire}} card(s)): zero views, no
   migration value.
{{#tier_b}}
4. **Re-run as Tier A** (dev token, or install the `Beast Modes` governance
   dataset) to replace the degraded proxy above with real Beast Mode
   complexity scoring.
{{/tier_b}}
