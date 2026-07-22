# Modeling strategy: star fidelity vs. One-Big-Table on Sigma

Vendor-neutral guidance for every BI→Sigma converter. It answers a question source-tool
developers always ask when they land in Sigma: *should I rebuild my star schema, or flatten
everything into one big table (OBT)?* The short answer is **neither as a blanket rule** — and
the numbers below are ours, measured on Snowflake, not borrowed from a blog.

## Why Sigma modeling differs from the source tool

- **Compute runs in the warehouse, at query time.** Sigma has no in-memory engine (no VertiPaq,
  no imported model). Every join, filter, and aggregate is SQL executed by the CDW when a chart
  runs. A join you keep in the model is a join the warehouse pays for on each query.
- **Relationships are *potential* joins, not filter propagation.** A Sigma relationship does not
  auto-propagate filter context the way a Power BI / Tableau / LookML model relationship does. It
  is a join that only executes when an element or lookup activates it. (This is why cross-element
  references and cross-table metrics have their own rules — see the per-tool measure refs.)
- **Metrics are table-scoped.** A metric is evaluated within one element; referencing a dimension
  attribute from a metric requires the join to already be activated (a joined element / lookup).

None of this makes the star "wrong" — it changes *where* the cost lands and *when* flattening pays off.

## Default for a migration: reproduce the source model faithfully

**The converters do NOT auto-flatten, and this doc does not ask them to.** A migration's job is to
match the source dashboard's numbers — **parity is the gate.** The converter reproduces the source
model's relationships as query-time joins (Sigma "View" elements), sourced live from the warehouse.
That is the default and it is correct: it is verifiable against the source, and for most reports the
live-join cost is negligible.

Flattening is an **opt-in optimization the user chooses**, not a conversion default — because it
**changes grain** (a fact joined to its dimensions is a different physical shape) and must therefore
be **re-verified against the same parity oracle** before it ships. Never present OBT as something the
tool did automatically.

## What we measured (Snowflake, 2026-07-22)

Synthetic star — fact at 1M / 10M / 50M rows + 4 dimensions (product, customer ~100k, date, region)
— built three ways and run through 8 representative dashboard queries spanning 0–3 joins, result
cache off, on a fixed X-Small warehouse. Three arms: **A** = star with live query-time joins (what
the converter emits today), **B** = upstream OBT (a pre-joined flat table via CTAS), **C** =
Sigma-native materialization (a managed, scheduled-refresh flat table — Snowflake dynamic table).
All three returned **identical results** (flattening on unique dimension keys preserves every value).

Total warehouse compute across the 8 queries (median warm execution time, ms):

| scale | A star | B OBT | C materialized | star ÷ OBT |
|------:|-------:|------:|---------------:|-----------:|
| 1M    | 1330   | 525   | —              | **2.5×**   |
| 10M   | 2062   | 1714  | 1631           | **1.2×**   |
| 50M   | 6110   | 4518  | —              | **1.35×**  |

Findings:

1. **For queries that traverse joins, the flat table always won** — from ~1.04× (a single join on
   a distinct-count-dominated query at 50M) up to **4.4×** (a 3-join group-by at 1M). It never
   reversed in favor of the live-join star for a join-bearing query.
2. **The advantage is largest for many joins and small/mid data, and compresses as data grows.**
   The 3-join query went 4.37× → 1.85× → 1.57× across 1M → 10M → 50M: Snowflake's join execution
   scales well, so the fixed join overhead becomes a smaller fraction of a large scan. The win is
   real at every scale but it is not a constant multiplier.
3. **For join-*free* queries, the flat table is neutral-to-worse.** A pure fact aggregate (0 joins)
   was *faster* on the narrow star fact than on the wide OBT (star ~2× faster at 10M) — the extra
   columns cost scan time. **"Flatten everything" is wrong**; flatten where queries actually join.
4. **Sigma-native materialization ≈ upstream OBT at query time** (arm C total 1631ms vs arm B 1714ms
   at 10M, per-query within ±20%). You do **not** need to stand up an external pipeline to capture
   the flat-table speedup — Sigma's own materialization gets you there.

## The three options, and when to pick each

| Option | Query cost | Freshness / upkeep | Use when |
|---|---|---|---|
| **Live-join star** (default) | Pays the join every query | Always live; zero upkeep | Cold / infrequently-viewed reports; few joins; parity is the only concern |
| **Sigma-native materialization** | Flat-scan (fast) | Refreshes on a Sigma schedule; lags source; costs refresh compute | Hot, join-heavy dashboards where you want the speedup *without leaving Sigma* |
| **Upstream OBT** (CTAS / dbt / dynamic table) | Flat-scan (fast) | Managed by your pipeline; lags to its refresh | Hot dashboards already fed by a warehouse pipeline; one OBT serving many workbooks |

Guidance:
- **Default to the faithful star.** It's the parity artifact and it's free of upkeep.
- **Recommend materialization only for HOT + JOIN-HEAVY dashboards** — the ones queried often enough
  that repeated join compute matters. For those, prefer **Sigma-native materialization** first (no
  external pipeline); reach for an **upstream OBT** when a pipeline already exists or one OBT can
  serve a family of workbooks.
- **Do not flatten join-free / narrow-fact workloads** — it adds width and can slow them down.
- Whichever you pick, materialization/OBT **changes grain**: re-run the migration's parity oracle
  against the flattened variant before shipping. And weigh the **refresh cost + staleness** you take
  on against the per-query compute you save — the trade only pays for genuinely hot dashboards.

## The migration-time advisory

When a converted data model contains **≥ 2 activatable joins**, the orchestrator prints a one-line
MODELING ADVISORY pointing here. It is **informational only** — it never gates, never blocks parity,
and the converter never acts on it. Its job is to make the CDW join-cost tradeoff visible at the
moment the model is built, so the user can decide whether a hot dashboard warrants materialization.

## Provenance

Benchmark harness, raw results, and per-query numbers: tracked in beads-sigma-o175. Background
(SQLBI found star schemas superior for VertiPaq; Fivetran found OBTs superior on CDWs) framed the
question; the numbers above are our own measurement and supersede any general claim for the specific
purpose of Sigma modeling guidance. Re-run the harness if Sigma's query generation or warehouse
tier changes materially.
