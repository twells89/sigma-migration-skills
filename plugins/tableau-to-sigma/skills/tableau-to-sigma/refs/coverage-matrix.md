# Tableau → Sigma coverage matrix

What the `convert_tableau_to_sigma` converter (MCP `src/tableau.ts` + `src/formulas.ts`, mirrored in the browser tool) actually does with each Tableau construct. This is a **static, converter-wide reference**; for a *per-workbook* readout of which features your specific `.twb` uses, run `scripts/scan-workbook-gaps.rb` (Phase 0a) — it emits `gaps-report.md` against this same vocabulary.

Sourced from the translator code, not aspiration. Last reconciled 2026-06-15.

## Status legend

| | Meaning |
|---|---|
| ✅ **Spec** | Translated automatically into the data-model spec. |
| 🧩 **Workbook pattern** | Produced as a ready Sigma formula but **reported, not injected** — it only works in a grouped/chart element (window math silently errors in DM calc columns). Place it on the chart per the conversion note. |
| 🔐 **Reported** | Detected and reported with provisioning guidance; **not injected** (Sigma can't provision user attributes/teams from a converter). |
| 🟡 **Verify** | Emitted, but flagged to confirm (arg-order rewrite or an approximation). |
| ❌ **Flagged** | Loud warning + placeholder comment; needs manual recreation (no faithful Sigma equivalent). |
| ⛔ **Silent gap** | Currently passes through **unchanged with no warning** and will error in Sigma at query/render time. Known gap — do not assume it works. |

> Why ⛔ exists: anything not in the converter's function map and not specially rewritten is emitted verbatim. These are the dangerous cases because the POST succeeds — only a column-level `type: error` (or a render failure) surfaces them. Always run the post-create check: `GET /v2/dataModels/{id}/columns` → scan for `type.type === "error"`.

---

## 1. Data model structure

| Tableau | Sigma output | Status | Notes |
|---|---|---|---|
| Physical table / `.tds` relation | warehouse-table element | ✅ | path via `extractPath` (db/schema/table, hex-hash + UUID segments stripped) |
| Physical joins (pre-2020.2) | relationships or physical joins | ✅ | Join Strategy dropdown: Auto routes `many_to_one`→relationship, else physical join |
| Relationship model 2020.2+ ("noodles") | Sigma relationships on the fact | ✅ | both resolve grain at query time; cardinality preserved when present, default `N:1` |
| Virtual connection (`type=collection`) | relationship model w/ role-playing dims | ✅ | columns read from `metadata-records`; GUID refs resolved to captions |
| Custom SQL (`relation type=text`) | `kind:sql` element | ✅ | SQL passed through as-is; element name omitted, bare `[Display]` col refs |
| **Data blend** (`<datasource-relationships>`) | **one merged model** | ✅ | secondary pre-grouped to link grain → `many_to_one` lookup; looked-up measure surfaced with `Max` (non-additive); cross-source `SUM(a)-SUM(b)`→`[Total a] op [b]`. See `refs/blending.md`. |
| Derived element (fact w/ relationships) | derived element w/ `[FACT/REL/Col]` refs | ✅ | surfaces own + related columns; relationship's own key column skipped |
| Multi-datasource (no blend link) | one model per datasource (`datasourceIndex`) | 🟡 | unrelated sources aren't merged; convert each separately |

## 2. Logical / conditional / null

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| `IF/THEN/ELSEIF/ELSE/END` | nested `If(...)` | ✅ | missing ELSE → `null` arm |
| `IIF(c,t,f)` | `If(c,t,f)` | ✅ | |
| `CASE WHEN` | nested `If(field = v, r, …)` | ✅ | |
| `ZN(x)` | `Coalesce(x, 0)` | ✅ | |
| `IFNULL(x,y)` / `IFERROR(x,y)` | `Coalesce(x, y)` | ✅ | |
| `ISNULL(x)` | `IsNull(x)` | ✅ | distinct from `= ''` |
| `ATTR(x)` | `x` (unwrapped) | ✅ | |
| Tableau set membership `IN [set]` | — | ⛔ | no `In()` rewrite on the Tableau path; Sigma has no `IsIn` — use `or` chains |

## 3. String functions

All via the function map (rename only — **no argument transformation**).

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| `LEFT` `RIGHT` `MID` | `Left` `Right` `Mid` | ✅ | args verbatim; both tools 1-based so safe |
| `LEN` `FIND` `CONTAINS` | `Len` `Find` `Contains` | ✅ | `Find` returns 0 when absent |
| `STARTSWITH` `ENDSWITH` | `StartsWith` `EndsWith` | ✅ | |
| `REPLACE` `TRIM` `LTRIM` `RTRIM` | `Replace` `Trim` `Ltrim` `Rtrim` | ✅ | |
| `UPPER` `LOWER` `STR` | `Upper` `Lower` `Text` | ✅ | |
| `SPLIT(s,d,n)` | `SplitPart(s,d,n)` | ✅ | |

## 4. Math functions

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| `ABS` `ROUND` `CEILING` `FLOOR` `POWER` `SQRT` | `Abs` `Round` `Ceiling` `Floor` `Power` `Sqrt` | ✅ | |
| `INT` `FLOAT` | `Int` `Number` | ✅ | casts |
| `LN` `LOG` `EXP` `MOD` `SIGN` `PI` | `Ln` `Log` `Exp` `Mod` `Sign` `Pi` | ✅ | Sigma `Log` defaults to base 10 (matches Tableau `LOG`), verified 2026-06-15 |

## 5. Date functions

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| `DATEPART('unit',d)` | `Year(d)`/`Month(d)`/… | ✅ | unit consumed → named extractor |
| `DATENAME('month',d)` | `MonthName(d)` | ✅ | weekday→`WeekdayName`; numeric units → `Text(Year(d))` etc. |
| `DATETRUNC` `DATEADD` `DATEDIFF` | `DateTrunc` `DateAdd` `DateDiff` | ✅ | unit single→double-quoted; arg order preserved |
| `DATEPARSE('fmt',str)` | `DateParse(str,"%Y…")` | ✅ | resolves to datetime (verified 2026-06-15); **arg order reversed** + Java tokens→strftime — a verify warning is emitted |
| `MAKEDATE` `DATE` `DATETIME` | `MakeDate` `Date` `Datetime` | ✅ | |
| `TODAY` `NOW` | `Today` `Now` | ✅ | |
| `YEAR/MONTH/DAY/HOUR/MINUTE/SECOND/WEEK/QUARTER` | same-named | ✅ | |

## 6. Aggregates

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| `SUM` `AVG` `MIN` `MAX` `MEDIAN` | `Sum` `Avg` `Min` `Max` `Median` | ✅ | routed to a metric when the calc is purely aggregate |
| `COUNT(x)` | `CountIf(IsNotNull(x))` | ✅ | matches Tableau non-null COUNT |
| `COUNTD(x)` | `CountDistinct(x)` | ✅ | |
| `STDEV` `VAR` `VARP` | `StdDev` `Variance` `VariancePop` | ✅ | |
| `STDEVP(x)` | `Sqrt(VariancePop(x))` | ✅ | no native pop-stddev |
| `PERCENTILE` | `PercentileCont` | ✅ | |

## 7. Statistical / regex

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| `REGEXP_EXTRACT` `REGEXP_REPLACE` `REGEXP_MATCH` | `RegexpExtract` `RegexpReplace` `RegexpMatch` | ✅ | arg order preserved |
| `CORR(x,y)` | `Corr(x,y)` | ✅ | routed to a metric (aggregate); verified 2026-06-15 |
| `COVAR` `COVARP` | — | ❌ | no Sigma covariance function — flagged with a warning, not emitted |

## 8. LOD expressions

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| `{FIXED [d]: agg}` | `kind:sql` helper element + relationship | ✅ | one helper per unique GROUP BY; multiple LODs sharing a grouping share a helper |
| `{INCLUDE …}` / `{EXCLUDE …}` | `kind:sql` helper | ✅ | view context derived from worksheet rows/cols shelves |
| LOD with no worksheet context | — | ❌ | can't derive view dims → skipped with a warning; place the calc on a sheet |
| Nested LOD / double-aggregation (`AVG({FIXED …: COUNT})`) | grouped child + parent agg | 🟡 | the correct Sigma shape is a grouped helper then non-window aggregate (not `*Over`); confirm grain |

## 9. Window / table calculations

All 🧩 forms are **chart-context only** — place in a grouped workbook element; they error as DM calc columns. The converter never emits `*Over` functions.

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| `RUNNING_SUM/AVG/MIN/MAX/COUNT(agg)` | `Cumulative*(agg)` | 🧩 | follows xAxis sort |
| `WINDOW_SUM/AVG/MIN/MAX/STDEV(agg,-n,0)` | `Moving*(agg,n)` | 🧩 | window must span current row; `(-n,m)`→`(agg,n,m)` |
| `agg / WINDOW_SUM(agg)` | `PercentOfTotal(agg,"grand_total")` | 🧩 | |
| `RUNNING_SUM(agg)/TOTAL(agg)` | `CumulativeSum(PercentOfTotal(…))` | 🧩 | pareto |
| `RANK / RANK_DENSE / RANK_PERCENTILE` | `Rank / RankDense / RankPercentile(agg,"desc")` | 🧩 | default direction forced to `desc` (Tableau default) |
| `RANK_UNIQUE(expr)` | `RowNumber()` (**operand dropped**) | 🟡 | sort-dependent: correct only if the tile is sorted by `expr`. For `RANK_UNIQUE(expr)<=N` Top-N, prefer a real Sigma Top-N filter — see `window-functions.md` Complex composites |
| `INDEX()` | `RowNumber()` | 🧩 | also the basis for `INDEX()<=N` / `RANK_UNIQUE(...)<=N` Top-N idioms — see Complex composites |
| `LOOKUP(agg,±n)` | `Lag/Lead(agg,n)` | 🧩 | `LOOKUP(agg,0)`→identity |
| `WINDOW_SUM(agg)` unbounded (no offsets) | `GrandTotal(Sum(...))` | ✅ | the one DM-safe table calc |
| shifted `WINDOW_*` (first>0 / last<0) | — | ❌ | falls to placeholder comment |
| `WINDOW_MEDIAN/PERCENTILE/CORR/COVAR/VAR/STDEVP` | — | ❌ | no equivalent; loud warning |
| `PREVIOUS_VALUE()` `SIZE()` | — | ❌ | recursive / pane-aware; no equivalent |
| `FIRST()` `LAST()` `TOTAL(agg)` standalone | — | ❌ | placeholder comment + warning (standalone `TOTAL` → grouped helper is built by `build-charts`, not the formula path) |
| table calc embedded in a larger expression | token left in place | ❌ | only whole-formula table calcs are matched; embedded ones warn |

## 10. Sets, parameters, bins

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| Member / condition set | boolean calc column in a "Sets" folder | ✅ | set referencing a related-element column is moved to the derived element + scrubbed from source folder |
| Top-N / Bottom-N set (incl. partitioned) | `kind:sql` RANK helper + relationship | ✅ | exposes `IS_TOP_N`; literal-N computed in SQL |
| Parameter-driven Top-N | Sigma calc `[Rank] <= [Control]` + number control | ✅ | control default = Tableau parameter default |
| Parameters | Sigma controls (list / date-range / number-range / text) | ✅ | |
| Bins | bucketed `Floor()` calc column | ✅ | |

## 11. RLS / security

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| `USERNAME()` | `CurrentUserEmail()` | ✅🔐 | translated **and** the identity calc is reported as RLS, not injected |
| `ISMEMBEROF('g')` | `CurrentUserInTeam("g")` | ✅🔐 | provision the team, then apply the boolean + element filter |
| `USERATTRIBUTE('a')` | `CurrentUserAttributeText("a")` | ✅🔐 | provision the user attribute |
| `ISUSERNAME('u')` | `CurrentUserEmail() = "u"` | ✅🔐 | |
| `FULLNAME()` `USERDOMAIN()` | — | ⛔🔐 | flagged as RLS but **not translated** — passes through |

## 12. Sources, extracts, viz

| Tableau | Sigma | Status | Notes |
|---|---|---|---|
| Warehouse-backed source | warehouse-table element | ✅ | |
| Extract-only fields / extract filters (`.hyper`) | — | ❌ | converter reads the logical model, not the physical extract |
| Non-warehouse source (Google Sheets, spatial/OGR, web data, Mapbox) | — | ❌ | can't repoint to a warehouse — should be surfaced in a "skipped sources" note |
| Worksheets / dashboards / viz layout | (skill build scripts) | — | the **converter** emits the data model; charts, layout, controls and parity are built by the skill's `scripts/*.rb` (see `refs/workbook-layout.md`), not the converter |

---

## Known follow-ups (beads)

- `beads-sigma-dnia` — ✅ scalar math/stat gaps closed 2026-06-15 (`LN/LOG/EXP/MOD/SIGN/PI`→Sigma equivs, `CORR`→`Corr` metric, `COVAR/COVARP` flagged; `ZN/ISNULL/IFNULL` were already fine; `DateParse` confirmed working). Remaining: the `INDEX()<=N`→Top-N idiom and Tableau set-membership `IN` rewrite on the Tableau path.
- `beads-sigma-hnx0` — nested-LOD / double-aggregation grouped-child shape.
- `beads-sigma-qtjz` — set parity edge cases (`%null%` members, `except`).
- `beads-sigma-w9o4` — partial-date coercion (bare year / `FY2016` → full date).
- `beads-sigma-3er3` — explicit skip-and-log list for non-warehouse sources.
