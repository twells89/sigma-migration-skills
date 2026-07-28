# DomoStats / Governance datasets — the inventory source

Domo ships two admin connectors that materialize **system datasets** describing
the instance. They are ordinary DataSets, so they're queryable via the documented
public endpoint `POST /v1/datasets/query/execute/{datasetId}` with MySQL SQL —
this is Domo's analog of Tableau Admin Insights' published datasources. No
private-API scraping required for inventory.

> Prerequisite: the customer admin must have installed the **DomoStats** and/or
> **Domo Governance Datasets** connectors (one-click in the AppStore). Confirm in
> Phase 0 by listing `/v1/datasets` and matching names below.
>
> ⚠️ Dataset **names** are stable but the **column schemas below are
> reconstructed from docs/community — CONFIRM exact column names on first contact**
> (Open question #1 in the research doc). Query `GET /v1/datasets/{id}` to read the
> real schema before writing the inventory SQL.

Docs: [Governance Datasets connector](https://domo-support.domo.com/s/article/360056318074) ·
[DomoStats connector](https://domohelp.domo.com/hc/en-us/articles/360043433813) ·
[Activity Log](https://www.domo.com/docs/s/article/360042934574).

---

## Datasets we care about (and their assessment role)

| Governance dataset | Powers readout section | Key columns (CONFIRM) |
|---|---|---|
| **DataSets** | §1 env, §3 patterns, §5 refresh | dataset id, name, owner, connector/datasource type, row count, last updated, update schedule |
| **DataFlows** | §1 env, §4 lineage | dataflow id, name, type (Magic ETL / SQL / Adrenaline), input datasets, output datasets, last run, run status |
| **Pages** | §1 env, §6 priority | page id, title, owner, parent page, card count, collection structure |
| **Cards** | §1 env, §6 priority, §8 complexity | card id, title, type (chart kind), page id(s), dataset id, owner, last modified |
| **Users** | §2 licenses | user id, name, email, role (Admin/Privileged/Participant/Social), last login, created |
| **Groups** | §2 | group id, name, member count |
| **PDP Policies** | §8 complexity (RLS) | policy id, dataset id, name, filter columns/predicates, applied users/groups |
| **Activity Log** | §6 usage / value | event time, user id, object type (CARD/PAGE/DATASET), object id, action (VIEWED/EXPORTED/…) |
| **Beast Modes** *(if present)* | §8 complexity | beast mode id, name, SQL text, dataset/card id — **if this exists, Tier A is reachable on the PUBLIC API** (Open question #3) |

---

## Query pattern

```ruby
require_relative 'lib/domo_rest'
# 1. find the governance dataset id by name
cards_ds = Domo.list_datasets(limit: 200).find { |d| d['name'] =~ /^Domo.*Cards$/i }
# 2. query it with SQL (table alias is always `table`)
rows = Domo.query_dataset(cards_ds['id'], <<~SQL)
  SELECT `Card ID`, `Card Title`, `Card Type`, `Page ID`, `DataSet ID`, `Owner Name`
  FROM table
SQL
```

Notes:
- The SQL `FROM` target is the literal alias **`table`** in Domo's query-execute endpoint.
- Identifiers with spaces use **backticks** (MySQL), e.g. `` `Card Title` ``.
- MySQL dialect — same as Beast Mode.

---

## Activity Log → usage/value

Rolling ~1-year window, near-real-time. Aggregate to per-object usage:

```sql
SELECT `Object ID`        AS object_id,
       `Object Type`      AS object_type,        -- CARD / PAGE
       COUNT(*)           AS views,
       COUNT(DISTINCT `User ID`) AS distinct_viewers
FROM table
WHERE `Action Type` = 'VIEWED'
  AND `Object Type` IN ('CARD','PAGE')
GROUP BY 1, 2
```

Open question #2: confirm the log records **per-card** views, not only per-page —
it determines whether the shortlist ranks cards or only pages.

---

## Offline / fixture mode

`scripts/probe-governance.rb --from-fixtures <dir>` and the downstream discovery
script look for these same governance tables by **filename**, each holding the
`{ "columns": [...], "rows": [[...], ...] }` shape above:
`datasets.json`, `dataflows.json`, `pages.json`, `cards.json`, `users.json`,
`pdp.json`, `activity-log.json`, and — Tier A only — `beast-modes.json` (plus
`card-defs.json`, which models the private per-card-definition API rather than
a governance dataset). No `groups.json` fixture ships yet; a missing table
degrades exactly like an uninstalled connector would live.

## Degradation
- Governance datasets **not installed** → fall back to the thin public endpoints
  (`/v1/datasets`, `/v1/pages`, `/v1/users`) for a reduced §1/§2/§3 inventory; no
  usage, no DataFlow lineage. Flag the readout accordingly.
- No `audit` scope → no Activity Log → shortlist uses the complexity-only value proxy.
