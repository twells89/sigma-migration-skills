# Looker → Sigma

Convert a **Looker instance** — its **LookML semantic model** and its **dashboards** —
into a governed **Sigma data model** and matching **Sigma workbook(s)**. Discovery via the
Looker REST API 4.0 (or the Looker MCP server, or offline `.lkml`), LookML → data-model
conversion via the `convert_lookml_to_sigma` converter, dashboard → workbook conversion from
the Looker Dashboard API JSON, build via the Sigma REST API, and **3-way parity
verification** (Looker vs Sigma vs the source warehouse). The agent supplies the judgment
(which explore, which join strategy, which tile kind, which layout); the `scripts/*` do the
mechanical work.

> **Validated end-to-end (2026-06-10)** against a live `example.cloud.looker.com` Looker
> instance pointed at the same `DEMO_DB.DEMO` Snowflake as Sigma: 2 dashboards (Orders Overview +
> Orders Deep Dive) migrated clean with **no hand-edits**, DM = 7 elements / 161 cols / 24
> metrics / 5 relationships, and **3-way parity to the cent** on region revenue and the ratio
> metrics (AOV / margin / return). See `skills/looker-to-sigma/refs/` for the coverage matrix.

This plugin ships one skill (`looker-to-sigma`); a `looker-assessment` sibling is handled
separately.

---

## Two artifacts, two pipelines

Looker has two independent layers; convert them separately.

| Layer | Source (production = API-first) | Converter | Sigma output |
|---|---|---|---|
| **Semantic model** | LookML views + model — via the Looker API / Looker MCP, or files offline | `convert_lookml_to_sigma` (Sigma data-model converter, MCP) | data model |
| **Dashboards** | `GET /dashboards/{id}` JSON — covers **user-defined (UDD) AND LookML dashboards** | `fetch_looker_dashboard.py` → contract → `build_workbook.py` | workbook |

**Critical:** most real Looker dashboards are **user-defined (UDD)** — built in the UI, not
in any LookML file. They are reachable only via the Looker API, which returns UDD and LookML
dashboards as the **same** `Dashboard` JSON. So the dashboard converter keys off that API JSON
(source-agnostic); the offline `.dashboard.lookml` parse normalizes into the same contract.
**UDD is the primary path.**

---

## Phases & tools

| Phase | What it does | Tools / scripts |
|---|---|---|
| **0 — Assess** | Scope the Looker estate (inventory, complexity, shortlist). Defer to the `looker-assessment` sibling skill. | *(separate skill)* |
| **1 — Discover** | List explores + dashboards; pull a dashboard into the normalized contract (UDD or LookML), or parse `.dashboard.lookml` offline | `looker_api.py`, `fetch_looker_dashboard.py`, `parse_lookml_dashboard.py` · **Looker REST API 4.0 / Looker MCP** |
| **2 — Convert semantic model** | LookML views+model → Sigma DM spec; POST + register + verify | `convert_lookml_to_sigma` (MCP) · `convert_dm.mjs`, `post_dm.py` · **Sigma REST** (`/v2/dataModels/spec`) |
| **3 — Convert dashboards** | Each Looker dashboard's tiles → Sigma elements, filters → controls, newspaper layout → 24-col grid | `fetch_looker_dashboard.py`, `build_workbook.py` · **Sigma REST** (`/v2/workbooks/spec`) |
| **4 — Parity** | 3-way compare: Looker `run_inline_query` vs Sigma `query` vs warehouse | **Sigma MCP (sigma-mcp-v2)** + Looker API |
| **5 — Enhance** | Wire UI-only features post-publish (cross-filtering, tooltips, 2nd-KPI comparisons) | *(judgment)* |

The phase structure mirrors `tableau-to-sigma` (Assess → Discover → Convert → Build → Verify →
Enhance); see `skills/looker-to-sigma/SKILL.md` for the full per-phase reference and gotchas.

---

## Test-fixture builders

`scripts/build_looker_dashboard.py` and `build_looker_dashboard2.py` are **test-fixture
builders**, not part of a customer migration. They author UDD dashboards on a Looker instance
via the API ("Orders Overview" and "Orders Deep Dive" on the `demo_thelook` model) so you have
known migration targets to convert and check parity against. Use them to stand up demo content;
never run them against a customer's Looker.

---

## Toolchain

- **Looker REST API 4.0** — `~/.looker/looker.ini` (API3 client_id/secret, admin role, base_url
  on `:19999`). `looker_api.py` is a no-SDK client; `fetch_looker_dashboard.py` is self-contained.
- **Looker MCP server** *(preview)* — list models, find Looks/dashboards, get schema, query.
  Admin enables tools (off by default). Preferred for live discovery when wired in.
- **Sigma data-model converter** — `convert_lookml_to_sigma` (MCP): LookML views+model → Sigma DM
  spec, resolving measure `${dim}`/`${measure}` refs and wiring snowflake (multi-hop) joins.
- **Sigma REST API** (valid bearer → browser-keychain refresh → client fallback,
  with proactive aging and one 401 retry) — `/v2/dataModels/spec`,
  `/v2/workbooks/spec`, `/v2/files`. Run `scripts/browser-login.sh` once for the
  preferred interactive setup; migration scripts self-authenticate afterward.
- **Sigma MCP** (`sigma-mcp-v2`) — live parity queries in Phase 4.
- **Warehouse** — reached through the Sigma connection (warehouse-agnostic). Looker needs its
  **own** direct warehouse auth (a Looker connection), separate from Sigma's connection.

---

## Quickstart

```bash
# Looker: ~/.looker/looker.ini with API3 client_id/secret (base_url on :19999, admin)
# Sigma:  ruby scripts/setup.rb once (writes ~/.sigma-migration/env) — see the sigma-api skill
```

Then invoke the **`looker-to-sigma`** skill with a Looker dashboard ID (or an explore name)
and it runs the phases above. See `skills/looker-to-sigma/QUICKSTART.md` for a runnable
walkthrough and `skills/looker-to-sigma/SKILL.md` for the full phase reference. Read the
`refs/` first: `dashboard-contract.md`, `looker-dashboard-layout.md`.

> **Canonical workbook/data-model spec shape** (element kinds, controls, formulas, formatting)
> lives in the companion **`sigma-workbooks`** / **`sigma-data-models`** skills — this skill
> restates only the Looker-conversion-specific patterns.
