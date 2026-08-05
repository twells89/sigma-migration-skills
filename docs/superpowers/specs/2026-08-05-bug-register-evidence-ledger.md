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
