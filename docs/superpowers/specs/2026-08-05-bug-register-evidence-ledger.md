# Evidence ledger — RSM migration bug register

Validated 2026-08-05 against `tableau-to-sigma` **v1.6.10** (register was compiled
against **v1.6.3**). Platform items probed live against a maintainer-owned
validation org; probe scripts and raw `requestId`s are in the local run
directory. All scratch objects were deleted (verified: 0 remaining).

Verdict key: `CONFIRMED-PLATFORM` · `CONFIRMED-SKILL` · `FIXED-SINCE` ·
`RECLASSIFIED` · `FALSE-POSITIVE` · `UNVERIFIABLE`

## A. Platform items

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| S1 | `/spec/verify` requires a `{document:…}` envelope | **CONFIRMED-PLATFORM** | Controlled A/B, bodies identical but for the wrapper: flat → HTTP 400 rooted at `0.document.*`; wrapped → `{"valid":true}` |
| S2 | DM cross-element refs compile but evaluate NULL | **CONFIRMED-PLATFORM (critical)** | 906-row export: bare `[Customer Dim/Region]` **0/906** non-null; `Lookup()` over the same relationship **872/906**. Both columns `type: text`, `error: nil` in `/columns` |
| S3 | Workbook elements cannot reference relationship-reachable columns | **CONFIRMED-PLATFORM** | `valid:false` — `Dependency not found: 'customer dim/region'` for a first-degree relationship |
| S4 | No single-value `date` controlType | **CONFIRMED-PLATFORM** | `date-range` → `valid:true`; `date` → 400 `Invalid kind: "control"` in all three shapes tried |
| S5a | Parenthetical-disambiguated refs don't resolve | **FALSE-POSITIVE** | Against a column that genuinely exists (`Net Revenue (Adj)`), `[Order Fact/Net Revenue (Adj)]` → `valid:true`. Register's failures were refs to names that were never real columns → folds into **K5** |
| S5b | Digit-adjacent auto display names don't resolve | **CONFIRMED-PLATFORM** | `AOS_6M` → `valid:true`; `Aos 6m` and `Aos 6M` → `Dependency not found`. Same for `PLAN_UNITS_V1`, `NO_ORDER_COUNT_L60D` |
| S6 | `DELETE /v2/workbooks/{id}` 404s | **CONFIRMED-PLATFORM** | `DELETE /v2/workbooks/{id}` → 404; `DELETE /v2/files/{id}` → 200 |
| S7 | `columns: []` accepted but contributes nothing | **CONFIRMED-PLATFORM** | Created workbook accepted; `/columns` → `{"entries":[],"total":0}` |
| S8 | Failed element queries export as empty downloads | **NOT REPRODUCED** | Deliberately broken calc returned a populated CSV with empty cells, not an empty file. The register's scenario needs a genuinely *erroring* query, which this repro did not produce — treat as unsettled, not refuted |
| S9 | `POST /v2/workbooks/spec` returns an empty success body | **FIXED-SINCE / NOT REPRODUCED** | Returns `{"success":true,"workbookId":"…"}` |
| S10a | Controls cannot target map elements | **FALSE-POSITIVE** | A `list` control filtering a correctly-shaped `region-map` → `valid:true`. The register's `Dependency not found: <mapElementId>` indicates a malformed map element, not a platform limit |
| S10b | Image elements reject `data:` URIs | **FALSE-POSITIVE → RECLASSIFIED** | With `source: {kind: url, url: …}`, **both** a hosted URL and a `data:` URI → `valid:true`. What now fails is the **flat `url:` shape** — for hosted URLs too. See N1/K7 |

### New findings (not in the register)

| # | Finding | Verdict |
|---|---|---|
| N1 | `sigma-workbooks` `content-elements.md` documents the image element as flat `kind: image` + `url:`. That shape is rejected outright by the live API (`Invalid kind: "image"`); the working shape is `source: {kind: url, url: …}`. The doc also says "hosted only — no uploads", which is now wrong — `data:` URIs validate | **CONFIRMED — doc bug** |
| N2 | `POST /v2/connection/{id}/lookup` takes `path` as a plain string array. `crud.md` shows no shape, and the `pathIdentifiers` object form 400s | **CONFIRMED — doc gap** |
| N3 | `GET /v2/workbooks/{id}/spec` returns an empty body without an explicit `Accept: application/json` header | **CONFIRMED — undocumented** |

## B. Skill items

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| K1 | `doctor.ps1` PowerShell quoting → false cred failure | **FIXED-SINCE** | PR #598; probes now ride `-I`/`-r` flags (`doctor.ps1:154`) |
| K2 | controlId sanitization misses `?` | **RECLASSIFIED (partial)** | Every `controlId` path in v1.6.10 uses `.downcase.gsub(/\W+/,'-')`, which strips `?`. The same gap **does** survive in the page-id slug: `build-workbook-spec.rb:172-173` replaces only `/ ( ) %` and space |
| K3 | Duplicate text element ids across pages | **CONFIRMED-SKILL** | Styled text is appended to `page_extras` (`build-charts-from-signals.rb:8336`), and the page assembly is `page_extras + els` (:8415) — only `els` passes through the `seen_el_ids` namespacing (:8382). Text ids are `text-<tableau zone id>`, which repeat across dashboards |
| K4 | Published-datasource collapse; object-graph plan ignored | **CONFIRMED-SKILL** | `object-graph-plan` appears only in `scan-workbook-gaps.rb` and `test-object-model-gap.rb` — no DM builder consumes it |
| K5 | Master refs in the fact namespace; unresolvable "(Element)" labels | **CONFIRMED-SKILL** | Absorbs S5a: the platform resolves parenthetical names correctly, so these refs failed because the skill emitted names that were never real columns |
| K6 | Two dashboard tiles silently dropped | **CONFIRMED-SKILL (gate is soft)** | A `tile_census` gate exists in `assert-phase6-ran.rb` but is "Skipped (with a note) when the converter doesn't emit a census" (:26) — it cannot fail closed |
| K7 | Logo images emitted as `data:` URIs | **RECLASSIFIED** | Real bug, wrong cause. `data:` URIs are fine (S10b); the defect is that `build-charts-from-signals.rb:6592`/`:8422` emit the **stale flat `url:` shape**, which the API now rejects for every image |
| K8 | Avg-order panels use a string dimension as the y-axis measure | **NEEDS LIVE RUN** | No explicit dimension-on-measure-axis guard found |
| K9 | Boolean calc-filters emitted with string `"true"` | **PARTIAL** | `lint-typed-literals.rb` exists; whether it is wired as a blocking gate on this path is unconfirmed |
| K10 | Page-level date filter never applied to KPI tiles; wrong Store Count aggregate | **NEEDS LIVE RUN** | Behavioral; not statically decidable |
| K11 | `Encoding::CompatibilityError` kills Phase-5b render threads | **CONFIRMED-SKILL** | Scrub exists at `migrate-tableau.rb:1191`/`:2105` but **not** at the reported site: the Phase-5b thread calls `o.strip` / `o.each_line` on raw `Open3.capture2e` output (`migrate-tableau.rb:5283-5285`) |
| K12 | `probe-join-keys.rb` poll/sqlproxy/re-entry/identifier issues | **CONFIRMED-SKILL (partial)** | No 180s poll landed — the only sleep is `sleep(i.zero? ? 0.5 : 1)` (:215). Sub-claims (b)–(d) need a live run |
| K13 | Discovery omitted `hasExtracts` | **UNVERIFIABLE** | `tableau-discover.rb:318` persists the Tableau API response verbatim; no drop logic exists in the skill |
| K14 | `/spec/verify` preflight sends the bare body | **CONFIRMED-SKILL** | `post-and-readback.rb:232` still posts unwrapped on `main`. Fix exists but is **unmerged** (PR #609). Do not re-fix — track that PR |
| K15 | Signals-built tiles mis-pick a parameter-switched measure | **NEEDS LIVE RUN** | Param-switch handling is extensive (38 sites); correctness not statically decidable |
| K16 | Header text carries white font without the banner background | **NEEDS LIVE RUN** | Synthetic title banner logic exists in `build-dashboard-layout.rb`; the colour pairing is not statically decidable |
| K17 | Dual-measure bar panels emitted with the dimension only | **NEEDS LIVE RUN** | Same family as K8 |
| K18 | Filter rail materialized 2 controls vs ~15 in source | **NEEDS LIVE RUN** | `control-scope.json` is consumed by the phase-6 gate; coverage shortfall is behavioral |

## C. Doc items

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| C1 | `calc-columns.md` documents cross-element refs as supported | **CONFIRMED — actively dangerous** | `calc-columns.md:20` states the form with no warning; S2 proves it silently returns NULL. Should mandate `Lookup()` |
| C2 | `controls.md` documents `parameters` with no item shape | **CONFIRMED** | Field is listed at `controls.md:28` with no shape |
| C3 | `controls.md` lists single-value `date` as a controlType | **CONFIRMED** | `controls.md:288` names `date` a single-value control; S4 shows it is not in the live union |
| C4 | `tables.md` `groupings` marked verified 2026-06-15, unconfirmed since | **CONFIRMED (stale marker)** | Date marker is accurate as a staleness claim; not re-validated here |

## Disposition

- **Engineering write-up (platform):** S1, S2, S3, S4, S5b, S6, S7 — plus S8 flagged
  as unsettled. Drop S5a, S9, S10a, S10b.
- **Remediation plan (skill):** K2, K3, K4, K5, K6, K7, K9, K11, K12, plus the
  behavioral group K8/K10/K15/K16/K17/K18 behind a reproduction harness. K14 is
  tracked to PR #609, not re-fixed. K1 is closed. K13 is closed as unverifiable.
- **Doc fixes:** C1 (urgent — data-integrity advice), C2, C3, C4, N1, N2, N3.
  These live in `sigma-skills` upstream and must be re-vendored per `SYNC.md`.

---

# Round 2 — 2026-08-06

Everything below **supersedes** the corresponding rows above where they conflict.
The Disposition section here replaces the earlier one.

## Verdict key (replaces line 8-9)

Verdict key: `CONFIRMED-PLATFORM` · `CONFIRMED-SKILL` · `FIXED-SINCE` ·
`RECLASSIFIED` · `FALSE-POSITIVE` · `UNVERIFIABLE` · `NEEDS LIVE RUN` ·
`NOT REPRODUCED` (a repro attempt failed to trigger the claimed symptom — this narrows the
scope of the original report, it does not clear it) · `SUPERSEDED-IN-REVERSE` (a later,
better-controlled measurement reversed an earlier reversal; the ORIGINAL verdict stands and
the intervening "correction" is the thing that is wrong)

---

## A. Platform items — S4 evidence amended, S11/S12/S13 added

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| S4 | No single-value `date` controlType | **REFUTED (live, 2026-08-06)** | A single-value `date` control **exists and validates**. Its `mode` is a **comparator** enum (`=`, `>=`, `<=`) — different vocabulary from `date-range`'s `last`/`between`/`on`. Every earlier rejection (the register's and round-1's) used the date-range vocabulary or omitted `mode`. Measured: `date`+`mode:"="`+fixed value PASS; `>=`/`<=` PASS; relative `{op:"now-minus",unit:"day",value:7}` PASS; `mode` alone PASS; **`value` without `mode` 400s**. The compiled asset's 15-branch control union already listed `date`. S4's FIRST claim is refuted. S4's SECOND claim (binding a date-range control to a single-date DM parameter) remains untested. |
| S11 | `kind:"list"` filters reject boolean-typed columns ("Invalid filter", blank tile) and `/export` returns unfiltered rows | **SUPERSEDED-IN-REVERSE — see the VALUE-TYPE POLARITY row** | Two clean-room constructions — a genuine boolean-typed calc column + `values:[true]`, and the converter's exact emission (`IsNotNull(...)` + `kind:list` + `values:[true]`, no `includeNulls`) — both rendered normally on a grouped table AND a bar chart; the `/export`-hides-it claim measured false. A separate, better-controlled A/B then settled the underlying question (below). This row does **not** say the customer's incident was imagined: 46 real instances existed on a real workbook, and the specific error on that screenshot ("Invalid Argument / Request format or values are invalid") is still unreproduced. What it does say is that "boolean list filters are rejected" is not the mechanism. |
| S11b | **VALUE-TYPE POLARITY** — which literal type filters a boolean column | **MEASURED, rendered, 2026-08-06 — this is the settled fact** | One identical boolean warehouse column (`/columns` → `type: boolean`), four tiles, only the `values` array varying, all four accepted by `spec/verify`: `[true]` → **13 rows, correct**; `["true"]` → **0 rows "No data"**; `["True"]` → **0 rows**; `[1]` → **0 rows**. Consequences: K9's original diagnosis AND its original fix (JSON booleans) were **correct**; the K20/S11 supersession that called JSON booleans wrong does **not** reproduce; `Text(col)` + `["true"]` works only because *both* halves are applied, and applying the string half alone reintroduces the original silent-zero-rows bug. Nothing upstream catches the wrong typing — `spec/verify` passes and the tile just renders empty. |
| S12 | Grouped-table sort cannot reference an inner level's aggregate | **CONFIRMED-PLATFORM (with wrinkle)** | Outer-level sort by an inner level's calculation is rejected — but surfaces as a generic 500-class incident (`An error has occurred… incident-id=…`), **not** the `Sort column not found` message the docs and the skill describe, so a caller grepping logs for that string finds nothing. The dedicated-hidden-aggregate-per-level workaround IS accepted and persists on readback, including a `sort[]` array nested **inside** a `groupings[]` item. That nested per-level shape is already documented in the vendored `sigma-workbooks/reference/specification/tables.md` (`groupings` example) and is already emitted by the tableau converter (`build-charts-from-signals.rb:5607`; confirmed offline in a build), but it is **absent from the compiled OpenAPI asset**, whose `groupings[].items` schema is exactly `{id, groupBy, calculations}`. Two engineering notes: the mismatched error class, and the undocumented (in the compiled spec) per-level `sort`. |
| S13 | `kind:"top-n"` element filters cap rows but do **not** sort | **CONFIRMED-PLATFORM (measured)** | `{id, columnId, kind:"top-n", rankingFunction:"rank", mode:"top-n", rowCount:N}` caps rows on flat AND grouped tables (25→5). `columnId` = a measure → correct top-5 by that measure. `columnId` = a **dimension** → top-5 by the dimension's own key ordering, i.e. arbitrary rows — "a Top 10 that does nothing", with no error at verify or POST. **top-n never sorts its own output**; a tile must carry an explicit `sort` alongside it. Converter status: no defect found — both tableau emission sites bind `columnId` to a translated aggregate (`build-charts-from-signals.rb` ~`:5934`, ~`:5994`), the path that could hand it a bare dimension fails closed to a STAYS-MANUAL warning, and `test-native-topn-quickfilter.rb` already asserts both the aggregate binding and the accompanying `xAxis.sort`. No new tableau task; the risk is cross-converter — audit the other 10 converters that emit `kind:"top-n"`. |

### New findings (not in the register) — N4, N5, N6 added; N4/N5 scoped tightly

| # | Finding | Verdict |
|---|---|---|
| N4 | The **compiled S3 OpenAPI JSON asset** now documents the workbook code-representation surface (`POST /v2/workbooks/spec`, `POST /v2/workbooks/spec/verify`, `GET|PUT /v2/workbooks/{workbookId}/spec` — previously absent entirely), but its `CreateWorkbookSpec` request body is **flat**: `allOf[{name, folderId}, allOf[allOf[{schemaVersion},{kind},{pages}], {themeName, themeOverrides}, {agents}, {layout}], {description}]`, with **no `document` wrapper** anywhere (its only 36 `document` keys are inside an unrelated open-document action *effect*). The live API rejects exactly that flat body on both endpoints (S1). **Scope this precisely:** the rendered `help.sigmacomputing.com` reference page is **correct** — its embedded example is `{name, folderId, document:{schemaVersion, kind, pages}}`. Do NOT file this as "Sigma documents the wrong shape." The only defensible finding is that this one compiled artifact is out of sync with both the live API and the rendered reference | **CONFIRMED — stale compiled artifact only (NOT a public-docs bug)** |
| N5 | `themeName`/`themeOverrides` vs a nested `settings.theme.name` | **UNVERIFIED — do not report either way.** The compiled asset models flat top-level `themeName`/`themeOverrides` as a sibling group alongside `pages`. Given that same asset is demonstrably stale on the envelope, that alone proves nothing. An earlier draft of this ledger claimed the rendered Fern reference has zero `themeName` occurrences and instead documents `document.settings.theme.name`/`.overrides`; **that claim is withdrawn — it could not be corroborated, and `grep -rn "document.settings"` over this repo returns zero hits.** The only *measured* evidence available is the vendored `sigma-workbooks/reference/specification/styling.md`, which documents flat top-level `themeName`/`themeOverrides` and records a live POST→GET round-trip with 0 dropped fields plus a PNG showing the override applied (2026-06-26); two shipped converters build on that shape (`domo-to-sigma/.../build-workbook-spec.rb:322`, `powerbi-to-sigma/refs/style-fidelity.md:22`). Settling this needs one live round-trip. **Do not change any doc or converter on this.** |
| N6 | The compiled OpenAPI asset's `groupings[].items` schema is `{id, groupBy, calculations}` — it does **not** model the per-level `sort[]` that the live API accepts and persists (S12), that `tables.md` already documents, and that the tableau converter already emits. Whether the *rendered* reference documents it was **not checked** (no live fetch was made) | **CONFIRMED for the compiled asset; rendered-reference status UNCHECKED** |

---

## B. Skill items — K9 replaced; K19-K22 added

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| K9 | Boolean calc-filters emitted with string `"true"` | **CONFIRMED-SKILL — original diagnosis and original fix both stand** | The VALUE-TYPE POLARITY measurement (S11b) settles the direction: a boolean-typed column requires JSON boolean values; strings and numerics silently return zero rows. The intervening K20/S11 "supersession" that reversed this is the thing that is wrong. **Two real gaps remain, both statically confirmed:** (1) `lib/typed_literal_lint.rb`'s `type_category` has **no boolean case** at all (`grep -i bool` → 0 hits), so the lint silently skips every boolean column — a gate written against it today would be a **false pass**; (2) the lint is wired (`migrate-tableau.rb:4271`) but only over `dm-spec.json` — the workbook-element filters this item is about have never been linted. Fixed by Task 7 (advisory, matching the existing corpus-safety policy). The converter's three JSON-boolean emission sites are **correct and must not change**. |
| K19 | Map/geography worksheets emit nonsense axes; no latitude handling | **CONFIRMED-SKILL — with the register's mechanism corrected** | Zero occurrences of `latitude` in `build-charts-from-signals.rb`. `SIGMA_KIND` declares `map-region`→`region-map` / `map-point`→`point-map` (`:236-237`) and those strings never appear again. Map worksheets do **not** hit the scatter fast path (gated `kind == 'scatter-chart'`, which a map kind never satisfies) — they fall through to the **generic chart builder** (`:5371`). Measured offline on a synthetic lat/long worksheet: `{"kind":"point-map", columns:[{"formula":"[Master/Longitude (generated)]"},{"formula":"Sum([Master/Latitude (generated)])"}], xAxis:{…}, yAxis:{…}}` — right kind, no `latitude`/`longitude` keys, one coordinate SUMMED. A filled worksheet emits `kind:"region-map"` with **no `region` key**, which the spec requires. Correct shapes confirmed against the OpenAPI `CommonElement` map branches (point-map requires `[id,kind,source,columns,latitude,longitude]`, all single `{id}` objects; region-map requires `region:{id, regionType}`) and corroborated by the vendored `maps.md`. Fixed by Task 8.5 (point-map built; region-map fails closed, because the Tableau-semantic-role → `regionType` mapping is unverified). **Open conflict, unresolved:** `LESSONS-LEARNED` R1 says a map sources by NAME; the compiled asset says `elementId`. Both unverified for maps — live-check before merging. |
| K20 | List filters emit JSON booleans at one site and STRINGs at another | **RECLASSIFIED — the observation is true, the defect reading is refuted** | The static fact is confirmed: three sites emit `values:[true]` on `IsNotNull(...)` helper columns (`build-charts-from-signals.rb` ~`:5325-5329`, ~`:5480-5486`, ~`:7385-7395`), two emit string values on top-N/wildcard helpers (`:6032-6037`, `:6155-6164`). But the two families sit on **different column types** — `IsNotNull(...)` is boolean, `If(…,"keep","cut")` / `If(…,"match","no-match")` is text — and per S11b the value type must match the column type. So both families are **type-correct**; the "disagreement" is not a defect and there is nothing here to converge. **No code change to any of the five sites.** One genuinely stale artifact: the comment at `:6030-6031` asserts a general rule ("live probes reject non-string list filter values, Text() casting rule") that is measured false — corrected (comment only) in Task 7. |
| K21 | Tableau sort directives not migrated | **PARTLY WRONG — narrow to `<alphabetic-sort>` only** | `<computed-sort>` IS migrated end to end: `parse-twb-layout.rb:760-766`, consumed by `sort_target_column_id` (`build-charts-from-signals.rb:971-981`) from three call sites (`:5607` table `groupings[0].sort`, `:5629` pie `color.sort`, `:5675` bar/line/area/combo `xAxis.sort`); verified working offline on a fixture. `<alphabetic-sort>` has zero occurrences in all three scripts — that alone is the gap. Do NOT describe this as "sorts are not migrated." **Trap for the implementer:** the vendored XSD (`schemas/twb_2026.2.0.xsd`, `Sort-Alphabetic-G`) declares `<alphabetic-sort>` with **no attributes at all**, and `sort_target_column_id`'s existing `return meas_col_id if token.empty?` means a naive wire-through sorts by the plotted MEASURE — measured on a fixture with only the parser half applied, all three consumers returned the measure column id. An explicit `alphabetic:` marker is required. The XSD reading is unverified against a real `.twb`. Fixed (narrowly) by Task 8.6. |
| K22 | `control_lint.rb`'s ghost-target check validates the ELEMENT, never the COLUMN | **CONFIRMED-SKILL** | `shared/lib/control_lint.rb` — `controls_report` (`:170-190`) builds targets from `source.elementId` and gates on `elems.key?` alone; it **never reads `columnId` at all**. `conflicting_default_violations` (`:257-260`) does read `cid = t['columnId']` but uses it only for alias grouping (`:261`) and gates on element existence too. Measured against the unpatched lib: a control targeting a real element with a nonexistent column yields `ControlLint.lint(spec) == []` — the literal "ghost-target: clean" false pass. Compounding: the dead-column target is folded into `live` → `reach`, so the separate dead-control check (`:339`) is also silenced. **SHARED** — 12 plugin fan-out for the lib, 2 for its test; shared-only PR. Fixed by Task 8.7. |

---

## C. Doc items — C3 and C4 evidence amended

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| C3 | `controls.md` lists single-value `date` as a controlType | **REFUTED — the doc is right** | Per S4's 2026-08-06 probe the `date` control is real. `controls.md:288` is correct to list it; do NOT delete it and do NOT add a 'live rejected it' caveat. The real, narrower gap: `controls.md` never documents that a `date` control requires `mode` from the comparator enum, which is what makes it valid. |
| C4 | `tables.md` `groupings` marked verified 2026-06-15, unconfirmed since | **CONFIRMED (stale marker) — now re-verifiable via S12** | S12 (live, 2026-08-06) exercised `groupings` including the per-level `sort` workaround with readback persistence. Move the marker to 2026-08-06 and add the two undocumented behaviors: the level-ownership constraint on `sort[].columnId` (and that violating it returns a 500-class incident, not `Sort column not found`), and the `nulls: "connection-default"` readback normalization. The per-level `sort` **shape itself is already documented** in the `groupings` example — do not "add" it. Do not fall back to "mark unverified." |

---

## Disposition (replaces the existing Disposition section)

- **Engineering write-up (platform):** S1, S2, S3, S5b, S6, S7, S12 (both wrinkles: the
  500-class incident vs. the documented `Sort column not found`, and the per-level `sort`
  nesting missing from the compiled spec), S13 (top-n caps but never sorts; ranking by a
  dimension is a silent no-op with no error at verify or POST). **S4 goes in with its schema
  contradiction attached and a request for the one missing probe.** S8 stays flagged as
  unsettled. **S11 goes in as SUPERSEDED-IN-REVERSE with S11b (the polarity measurement) as
  the operative finding** — file the polarity result, not the "boolean filters are rejected"
  claim; note separately that the customer's `Invalid Argument / Request format or values are
  invalid` render error is still unreproduced and needs the failing element JSON. Drop S5a,
  S9, S10a, S10b.
- **Remediation plan (skill):** K2, K3, K4, K5, K6, K7, K9 (→ Task 7), K11, K12, K19 (→ Task
  8.5), K21 scoped to `<alphabetic-sort>` only (→ Task 8.6), plus the behavioral group
  K8/K10/K15/K16/K17/K18 behind a reproduction harness. **K20 is disposed to NO code change** —
  the two emission families are type-correct for their own column types; only a stale comment
  is corrected, inside Task 7. K14 is tracked to PR #609, not re-fixed. K1 is closed. K13 is
  closed as unverifiable.
- **Shared-only PR, must not be bundled with anything above:** K22 (→ Task 8.7). Edit
  `shared/lib/control_lint.rb` + `shared/scripts/test-control-lint.rb`, run
  `ruby tools/sync-shared.rb`, commit the 12-lib + 2-test fan-out, and bump the version of
  every one of the 12 plugins the sync writes into (`tools/check-plugin-version-bump.sh` fails
  the PR otherwise; `Skip-Version-Bump` is not appropriate for a runtime behavior change).
- **Doc fixes:** C1 (urgent — data-integrity advice), C2, C3 (caveat, not deletion), C4 (now
  re-verifiable via S12), N1, N2, N3, N6. **N4 is a Sigma-side artifact bug, not a doc fix in
  this repo** — the rendered reference is already correct. **N5 is dropped from the doc-fix
  list entirely; it is UNVERIFIED and the only measured evidence supports the shape the
  vendored docs already use.** Repo-side doc fixes live in `sigma-skills` upstream and must be
  re-vendored per `SYNC.md`.
- **Cross-converter follow-up (not tableau):** audit every converter that emits
  `kind:"top-n"` for a `columnId` bound to a dimension (S13) — tableau is clean, the other 10
  are unaudited.
