# Design notes — Metabase → Sigma

## Status: LIVE-VALIDATED end to end (2026-06-11)

Full pipeline proven against a local Metabase **v0.61.3** (jar, OpenJDK) connected
to the same Snowflake warehouse as Sigma: 8 pilot cards + a 2-tab parameterized
dashboard → discovery → converter → DM POST (readback clean) → workbook POST
(readback clean) → **EXACT MCP-query parity** on every element (KPI total, 4
regions, 3 channels, 30 months, 15 category×channel cells, pivot cells, filtered
row counts). See §10 for the live-verified contracts that replaced the old
"known unknowns" and the validation-loop recipe.

## What maps to what

| Metabase | Sigma | Carrier |
|---|---|---|
| Database / table | DM `warehouse-table` element | `GET /api/database/{id}/metadata` (schema + field ids) |
| **Model** (curated dataset) | DM element (table / join / sql) | the model's own `dataset_query` |
| Question (MBQL) used by dashboards | DM element + metrics, or workbook element sourced from the DM | `dataset_query.query` |
| Question (native SQL) | DM **`sql` element** (Custom SQL) | `dataset_query.native.query`; `{{tags}}` → controls |
| MBQL `joins` | DM `join` source (left/right/inner/full) | join condition field pairs |
| FK metadata (`fk_target_field_id`) | DM **relationships** (+ derived view) | database metadata — Metabase's implicit-join graph |
| `expressions` (custom columns) | calc columns | `translateMbqlExpr` |
| `aggregation` (+ named wrappers) | element **metrics** | |
| Dashboard | workbook page(s) — one page per dashboard **tab** | `dashcards` grid → 24-col Sigma layout, 1:1 |
| Dashcard | chart/table/pivot/KPI/text element | `display` + `visualization_settings` |
| Dashboard `parameters` | workbook **controls** + targets | `parameter_mappings` name the filtered column per card |
| Collections | folder suggestion only (Sigma folder = POST `folderId`) | not auto-created |

## Decisions (and why)

1. **Field-id resolution is a hard prerequisite.** MBQL refs columns by integer
   id. The converter REQUIRES `--metadata metadata.json`
   (`GET /api/database/{id}/metadata`) and falls back to the card's
   `result_metadata` names when an id is missing — with a warning, because
   fallback names lose the table qualifier.
2. **Models become the DM; ad-hoc questions become workbook elements.** A
   Metabase model is the semantic-layer object — it maps to a DM element other
   elements source. Questions that only a dashboard uses convert as workbook
   elements wired to the DM element for their source table (keeps the DM small
   instead of one element per question — mirrors how the tableau/qlik
   converters treat sheet-level calcs).
3. **Nested questions (`source-table: "card__N"`)** convert to an element
   sourced from card N's element (`source: {kind:"table", elementId}`) when card
   N is in the input set; otherwise flagged with the card id so discovery can
   fetch it.
4. **Joins: MBQL explicit joins → DM join sources; FK metadata → DM
   relationships.** Two different Metabase features, two different Sigma
   carriers. The derived "join view" (`buildDerivedElements`) skips the
   relationship's own key column (cross-element passthrough of a join key
   compiles to type `error` — learned on qlik/oac, baked into `sigma-ids.ts`).
5. **Number formats**: `column_settings` (`number_style`, `decimals`, `suffix`)
   are the primary signal → Sigma d3 `formatString`; name/formula heuristics
   (`inferSigmaFormat`) only fill gaps. Mirrors the powerbi `format` lesson
   (beads-sigma-4q7k).
6. **Never faked**: cum-sum/offset/segment/metric refs, binning, click
   behaviors, and progress viz → loud warnings + readable placeholders.
   Funnel, gauge, waterfall, and sankey now map to their native Sigma kinds
   with required `columnId` channels. See `expression-dsl.md` for formulas.
7. **Charts**: `display` + `graph.dimensions`/`graph.metrics` (names matched
   through `result_metadata`) drive the Sigma viz: bar/row→bar (row = horizontal
   — Sigma's only `orientation` enum value), line→line, area→area,
   combo→combo (`series_settings` per-series display → dual-axis string/object
   yAxis form), scatter→scatter, pie→pie, scalar/smartscalar→kpi-chart,
   pivot→pivot-table (`pivot_table.column_split` → rowsBy/columnsBy
   `{columnId}` objects + bare-string values), map→region-map/point-map
   (`map.type`), plus native funnel/gauge/waterfall/sankey.
8. **Workbook code representation is released-shape only**: outer metadata +
   `document`, flat `document.elements`, metadata-only pages, authoritative
   `document.layout`, canonical `<Page>`/`<Element>` tags, and `columnId`
   pointers. The data-model representation remains page-nested and unwrapped.
9. **Sandboxing (RLS) is EE-only and detect-only here**: `GET /api/mt/gtap`
   (sandboxes) + group memberships exist only on Pro/EE. When detected (or
   provided manually), the shared `apply_sigma_rls.py` engine ports it to Sigma
   user-attributes after the DM is posted — same opt-in/out gate as every
   sibling skill (never silent, never slow).

## Live-verified contracts (was "known unknowns" — resolved 2026-06-11, see §10)

- **Native SQL column refs**: bare `[Display Name]` POSTs 200 but resolves to
  type "error" at query time. The contract is `[Custom SQL/RAW_ALIAS]` (raw SQL
  output alias from `result_metadata.name`) + an explicit column `name`. The
  readback gate exists for exactly this failure class.
- **Join-source spec shape** (the manager's `on:[…]` contract was WRONG): each
  join is `{left, right, joinType, columns:[{left:'[Display Name]', right:…}],
  name}` — `columns` not `on`; refs are Sigma-PRETTIFIED display names (physical
  `[PRODUCT_KEY]` → 400 "Column reference not found"); `connectionId` is REQUIRED
  on each side's nested source; enum is `inner|left-outer|right-outer|full-outer|
  lookup` (bare `left` → 400). `source.name` + per-join `name` are the formula
  prefixes (`[NAME/Col]`) for head/right columns.
- **DM control elements**: each `controlType` variant has REQUIRED discriminant
  fields (text/number/date need `mode`); omitting them fails the union match and
  surfaces misleadingly as `Invalid kind: "control"`.
- **Sigma parses `{{…}}` inside SQL comments** — a neutralized field-filter
  comment must NOT contain the literal tag braces or the POST 400s on the
  missing control.
- **Text elements carry `body`**, not `text`.
- **100% stacking**: enum is `none|stacked|normalized` — Metabase's `normalized`
  passes through verbatim ('percent' is rejected).
- **Cross-document DM references** are `source.kind:'data-model'` (kind 'table'
  is same-workbook only → 400 "Dependency not found").
- **Display-name casing is AP-style**: first AND last words always capitalize;
  stopwords lowercase only mid-name (`IS_EMAIL_OPT_IN` → "Is Email Opt In",
  `DAYS_TO_SHIP` → "Days to Ship"). Cross-element refs are case-SENSITIVE;
  warehouse-table refs are case-insensitive — so a casing bug only breaks
  derived views/relationship refs.
- **Pivot result_metadata carries `field_ref: null`** (v0.61) — refs must be
  reconstructed from the MBQL by name (agg cols are named sum/count/avg/…);
  `pivot-grouping` is a Metabase-internal column to skip.
- **Sigma does NOT honor sql-element names** (all read back "Custom SQL") —
  remap-wb-to-dm-ids.mjs matches native-card placeholders by column-set
  fingerprint (smallest unique superset) and REPAIRS every workbook formula ref
  against the live DM columns ([Element Name/Actual Column Name]).

## Still open

- Exact `dashcards` field names on older self-hosted versions (`size_x` verified on v0.61).
- Conditional formatting: `single` rules pass through; `range` (gradient) rules
  are still flagged (Sigma backgroundScale shape not yet live-verified).
- Metabase progress cards still need an approved Sigma equivalent.

## 9. First production contact (2026-06, Metabase Cloud v1.61.4 — 7,023 cards / 1,548 dashboards)

Empirical findings folded back into the converter + assessment:

- **pMBQL is the wire format.** 100% of the estate's `dataset_query`s were
  `{"lib/type":"mbql/query","stages":[…]}`. `pmbql-normalize.mjs` (intake, both
  skills) converts to the legacy shape; `legacy_query` (server's own
  down-conversion, a JSON string, present on ~70% of cards) is preferred when
  parseable. Sniff `lib/type` per card — a list response may mix formats.
- **Template tags are the dominant feature** (45% of cards): text 5,629 ·
  date 2,364 · dimension 1,914 · number 1,002 · card 384 · boolean 47; 1,705
  cards use optional `[[…]]` blocks. See `template-tags.md` for the mapping.
- **Dashboard parameters target tags, not columns**: 13,474 of 14,600
  `parameter_mappings` targets were `["variable",["template-tag",…]]`; 1,057
  `dimension`; 69 `text-tag` (flagged). 53% of dashboards carry parameters;
  17% use tabs; 6,189 virtual (text/heading) dashcards.
- **Display histogram** (cards): table 2999 · bar 1604 · line 1176 · combo 449 ·
  scalar 259 · pie 135 · row 130 · funnel 83 · area 67 · pivot 39 · object 37 ·
  waterfall 15 · sankey 13 · gauge 11 · scatter 3 · progress 3.
- **Engines**: BigQuery was the warehouse — `project.dataset.table` refs and
  trailing-comma SELECTs pass straight through, because the converter emits
  native SQL **verbatim** into Sigma custom SQL (same-warehouse migrations are
  near-verbatim; cross-warehouse needs a transpile pass first).
- **Auth**: API keys send `x-api-key` (NOT a Bearer header). Scoped keys can
  403 on `/api/database/{id}/metadata`; `GET /api/field/{id}` still worked for
  restricted DBs — hence the field-resolution fallback chain.
- **Discovery at scale**: the per-item walk took >1hr; bulk `GET /api/card`
  (110MB, streamed + split locally) + parallel dashboard GETs ≈ 1 minute.

**Historical honesty note:** this production contact validated extraction, not
the write path. Section 10 records the subsequent end-to-end Sigma validation.
The later released workbook wrapper/flat-element uplift is covered offline and
must be rechecked through the normal live gates.

## 10. First live Sigma validation (2026-06-11, local Metabase v0.61.3 → a validation org)

The repeatable validation loop, no Docker required:

1. `brew install openjdk` + the Metabase jar (match the customer's major version;
   Java 24+ needs `--sun-misc-unsafe-memory-access=allow --add-opens=java.base/java.nio=ALL-UNNAMED`
   or the Snowflake JDBC driver's Arrow reader throws `ExceptionInInitializerError`).
2. Headless setup: `GET /api/session/properties` → `setup-token` → `POST /api/setup`.
3. Snowflake connection via key-pair: details `{use-password:false,
   private-key-options:'local', private-key-path:…}` — same warehouse Sigma reads,
   so native SQL migrates verbatim and parity is apples-to-apples.
4. Author pilot cards via `POST /api/card` mirroring the estate's dominant
   patterns (native SQL, template tags incl. field filters + `[[optional]]`,
   MBQL agg/breakout, explicit join, implicit FK breakout, scalar/pie/stacked-bar/
   pivot/cond-format displays), one 2-tab dashboard with `parameter_mappings`.
5. Execute every card (`POST /api/card/{id}/query`) and SAVE the rows — this is
   the parity baseline AND proves the card-results extraction path customers'
   scoped keys may lack (reference estate's key 403'd ALL THREE execution surfaces:
   card query, `/query/json` export, ad-hoc `/api/dataset` — plan engagements
   accordingly: parity needs either query perms or warehouse access).
6. Skill loop: discover → convert → post-and-readback (DM) → convert dashboard
   → remap (now also repairs refs) → post-and-readback (workbook) → MCP query
   each element vs the step-5 baseline.

Result: EXACT parity on all 8 cards (total 110,788.35; 633 filtered rows; all
dimension splits). OSS v0.61 serves pMBQL with `legacy_query: null` — the
pmbql-normalize path is mandatory, not a Cloud quirk.

Found-and-fixed during the gauntlet (each was a live 400 or an error-typed
column): join-source shape ×4, control `mode`, `{{tag}}`-in-comment, sql-element
`[Custom SQL/…]` refs, text `body`, `stacking:normalized`, `data-model` source
kind, AP-style last-word casing, pivot `field_ref:null`, implicit-FK dim-table
ensure, explicit-join cards sourcing their card-named element. Plus two script
bugs any first run would hit: six scripts committed without exec bits, and
`metabase-discover.sh` f-string escapes that crash python ≤3.11.

### §10b Gold round (same day): model + nested question + combo — EXACT parity

Second pilot wave on the local harness: a curated **model** (`type:"model"`,
ORDER_FACT ⟕ CUSTOMER_DIM + expression), a **nested question** (`card__N` on the
model, agg by joined-dim breakout — nested field refs are STRING form
`["field","NAME",{base-type}]`), and a **combo** chart (2 aggs, per-series
`series_settings` bar/line + right axis). All three POST clean and match
Metabase exactly (tiers 22,212.23/32,057.13/21,624.46/31,663.30; channels
62,316.78/842 · 31,964.18/411 · 16,507.39/228). Combo dual-axis persists via the
bare-string vs `{columnId, type:'line'}` yAxis form.

Two converter fixes from this round:
- **Nested-card DM elements need parent passthrough columns** — a table-sourced
  element starts EMPTY (zero queryable columns live-verified), so the element now
  copies `[Parent Name/Col]` passthroughs for every parent column.
- **`card__N` dashcards whose parent is NOT on the dashboard** now source the
  card's OWN DM element by card name (a `card__N` placeholder 400s at POST);
  passing `cardNameById` still routes to the parent model instead.

### §10c BigQuery readiness (Sigma side LIVE-verified; Metabase side fixture-shaped)

Same-warehouse BQ migrations need no new machinery — the differences are all
encoded and tested (`fixtures/bq-estate.card.json` + the `bq:` test block):

- **Paths are `[project, dataset, table]`**, case-preserved (BQ is case-sensitive,
  typically lowercase). The converter no longer uppercases table names anywhere —
  a no-op for Snowflake (whose metadata is already uppercase), required for BQ.
- **Project auto-derives** from `metadata.details['project-id']` when `--database`
  is omitted (Snowflake: `details.db`). **Per-table `schema` from metadata wins**
  over `--schema` — real estates span datasets.
- **Live-verified against a real BQ connection** (no Metabase-on-BQ needed — the
  Sigma side is what the converter POSTs): warehouse-table element with lowercase
  path + `[table_tail/Prettified Col]` refs, a join with lowercase source/join
  names + prettified `[Display Name]` condition refs, and a **verbatim BQ-dialect
  sql element (backticks + trailing comma)** all POST clean, read back 0 errors,
  and return correct rows. Cross-project tables (`bigquery-public-data.*`) appear
  in Sigma's catalog the same way.
- **First live Metabase-on-BQ run, verify only**: that `/api/database/{id}/metadata`
  `details` exposes `project-id` on the customer's auth flavor, and dataset-level
  `schema` population. Everything Sigma-side is already proven.
- **Cross-warehouse** (Metabase-on-BQ → Sigma-on-Snowflake) remains the one real
  gap: the 91%-native-SQL estate would need a transpile pass before passthrough —
  flag, don't fake.

### §10d Customer-feedback round (reference estate wave 0 — a source user, 2026-06-12)

Four reported issues, each reproduced on the customer's real dashboard (defs
from the estate cache) and fixed:

1. **Grain switchers** (`{{date_aggregation}}` driven by a static-list param) —
   parameters with `values_source_type: "static-list"` now become a Sigma
   **segmented control** (≤6 values; larger lists stay `list`) with a manual
   value source and the Metabase default carried over. The {{tag}} in SQL stays
   verbatim. Number defaults are coerced from Metabase's strings.
2. **Raw aliases as chart labels** (`x_axis_type`, `count(*)`) — column display
   names are now ALWAYS prettified (sigmaDisplayName is idempotent); formulas
   keep the raw alias ([Custom SQL/x_axis_type]). BQ's anonymous `f0_` becomes
   "F 0" — alias aggregates in SQL for a better label.
3. **Controls not driving anything** — remap gains `--dm-spec`: workbook
   controls whose controlId matches a DM {{tag}} control get
   `parameters: [{kind:'data-model', dataModelId, controlId}]` (the OpenAPI
   shape on BOTH spec paths). NOTE: live POST currently rejects the binding
   ("Invalid parameter on control") even type-matched and id-vs-controlId —
   likely the DM control must be UI-exposed as a parameter first.
   post-and-readback now strips the bindings and retries ONCE with a loud
   warning; sync each control in the UI (control → Sync with data source
   parameter). Re-probe occasionally — if the platform starts accepting it,
   the wiring is already emitted.
4. **Stacked layout** — `cli.ts --layout-out hints.json` exports the 1:1
   Metabase grid geometry; `apply-layout.mjs --hints hints.json` reproduces it
   exactly (24-col, ROWSCALE=2, controls in a top band, unhinted leftovers
   stacked below; element ids preserved on workbook CREATE so hints match).
   Without --hints the generic per-kind layout still applies.

Run order per dashboard: convert (--layout-out) → remap (--dm-spec) →
post-and-readback → apply-layout (--hints) → assert-parity.

## 11. Control-targeting standard + shared gate stack (2026-06-12 retrofit)

Brought to the cross-plugin contract uniform across sigma-migration-skills' 8
plugins. Vendored BYTE-IDENTICAL (md5 discipline): `scripts/lib/control_lint.rb`,
`scripts/lib/layout_lint.rb`, `scripts/probe-controls.rb`,
`scripts/assert-phase6-ran.rb`, `refs/control-parity.md`.

**What the audit found** (gate 7 run against the §10 live Pilot Ops workbook):
3 of 3 controls DEAD — Status (variable-tag: binding rejected by the org and
stripped → decorative), Region (field-filter tag whose column isn't in the
card's result set → never wired), Date Grain (parameter has zero
parameter_mappings → filters nothing in Metabase either). Layout lint: clean
(the §10d exact-grid round already passes; layouts unchanged by this retrofit).

**What changed (reconciled with the §10d customer round, not clobbering it):**
- Converter emits the `control-scope.json` sidecar (`--control-scope-out`):
  `sourceFilterSignals` = MAPPED parameters; per-control `scope`/`mustReach`
  from the declared `parameter_mappings` targets (Metabase targets are
  explicit, like MSTR selectors — unmapped same-page cards are by-design).
- ALL wirable mappings now wire as REAL control `filters` targets, replacing
  the boolean match column `[Col] = [slug]` entirely: a list-control reference
  inside a formula reads back as an error-typed column (live-caught by the
  new gates on the first fixture build), and range semantics never fit an
  equality anyway. Table dashcards are targeted directly; charts/KPIs/pivots
  re-root through a hidden base TABLE on a trailing `Data` page (id prefixed
  `data` — the layout-gate exemption convention), because control targets may
  only point at table elements. Date params become date-range controls (flat
  `mode:"between"` — datetime targets need it); list/segmented targets on
  numeric/datetime columns bind through a hidden `Text()` cast column (the
  silent-strip gotcha). remap-wb-to-dm-ids skips intra-workbook (base-table)
  sources AND leaves `[controlId]` tokens unrepaired (rewriting `[region]` to
  `[Customer Dim/Region]` made a filter always-true — also live-caught).
- Controls are placed AFTER the elements they target in spec order.
- Unmapped parameters and unwirable field-filters get NO control + a loud
  warning (flag, never furniture — they do nothing in Metabase either /
  cannot be honestly wired).
- Variable-tag controls keep the §10d behavior (emit + `--dm-spec` binding);
  NEW default when the org rejects the binding: post-and-readback DROPS those
  controls (and patches the sidecar) instead of shipping decorative ones —
  the customer's original complaint WAS "controls not driving anything".
  `--keep-rejected-bindings` restores the strip-and-keep behavior (gate 7
  will flag those dead until each is UI-synced to its DM parameter).
- Sentinels: post-and-readback writes `wb-ids.json` + `posted-workbooks.jsonl`;
  `assert-parity --check` writes `parity-final.json` (+ optional tile census);
  post-and-readback and apply-layout run the shared lints inline;
  `assert-phase6-ran.rb` (gates 1–7) is the GREEN gate.

**Known limitation (deferred, needs an upstream standard change):** when an org
ACCEPTS `control.parameters` DM bindings, the bound control is functional but
spec-invisible to control_lint (the binding lives on the control element, which
the lint doesn't treat as wiring) — gate 7 would false-positive it as dead.
a validation org currently rejects the binding, so this path is unexercised.

**Bonus live finding (same retrofit, blocked the first fixture DM POST):**
Sigma has NO `Or()`/`And()` FUNCTIONS — `Or(a, b)` is "Invalid formula" at
POST; `and`/`or` are infix operators only. The MBQL translator now emits
parenthesized infix chains (multi-value `=`, and/or/not nodes, is-empty/
not-empty, inside). `Not()`, `Between()`, `IsNull()` are functions and fine.
