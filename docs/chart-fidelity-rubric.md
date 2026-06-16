# Converter chart-fidelity rubric

A standing, re-runnable audit for every `*-to-sigma` workbook builder. Spec-shape
correctness (does it POST?) is necessary but **not sufficient** — a spec can POST
cleanly and still render wrong (collapsed scatter, default colors, empty
dropdowns, dropped target lines). This rubric audits builder **behavior**, which
is what drifts. Established from the qlik-to-sigma fidelity work (2026-06-15).

## How to run the audit

For each converter, point a read-only agent at its builder + discovery scripts
and score the 8 dimensions below as **HANDLED / PARTIAL / MISSING / N-A** with
`file:line` evidence and the specific gap. Run them in parallel (one agent per
converter) and synthesize into the status matrix. Re-run after any builder change.

## The 8 dimensions

1. **Scatter — no point collapse.** A scatter is measure-vs-measure with the
   dimension as the point identity. Sigma's scatter axis is a GROUPING axis, so an
   aggregate (`Sum(...)`) bound directly to `xAxis` on an **ungrouped** source makes
   every point collapse to one x — the spec POSTs but renders wrong.
   **Correct:** bind the scatter to a grouped source — `source.groupingId` pointing at
   a grouping (or a hidden grouped table, `visibleAsSource:false`) that groups by the
   point dimension and pre-computes the x/y(/size) aggregates — with raw-ref columns,
   `color:{by:category, column}` for the points, and `size:{id}` for bubble size.
   *Failure fingerprint:* `xAxis.columnId` = a `Sum()` column on an ungrouped master.

2. **Chart colors reproduced.** Color-by-measure → `color:{by:scale, column, scheme}`
   (on a DUPLICATE measure column — a column can't be on both `yAxis` and `color`),
   honoring the source's scheme + reverse flag. Color-by-dimension → `color:{by:category}`.
   *Common gap:* only `by:category` handled; measure gradients dropped → default colors.

3. **Reference / target lines → `refMarks`.** `value` MUST be the wrapped object
   `{type: formula, formula: "<expr>"}` (a bare number 400s; a constant is a formula
   string, e.g. `"0.45"`); `label.visibility` must be `shown`. X-axis lines → `axis: axis`,
   measure/Y lines → `axis: series`.

4. **Dynamic / expression titles resolved.** A title that is a source expression must
   be resolved to a plain string (evaluated or translated) in discovery — never stored
   as a raw object that becomes the element name.

5. **Controls carry a value-list `source`.** A list control needs the double-nested
   `source: {kind: source, source: {kind: table, elementId}, columnId}` so the dropdown
   populates, plus `filters` for propagation. **Filters-only POSTs but the dropdown is
   empty.** (Converters that don't build interactive controls at all are a bigger gap.)

6. **Visual-QA gate auto-wired.** The orchestrator (not just SKILL.md prose) renders
   every content page to a full-page PNG via `sigma-export-png.py`, reading page ids
   from the **local** posted spec (the live `GET /spec` readback is flaky in-pipeline and
   returns YAML), passing `SIGMA_API_TOKEN` explicitly to the render child, and always
   printing the rendered N/total count (never a silent zero). The review is the gate.

7. **Spec-shape correctness.** `kpi-chart` uses `value.columnId`; `donut`/`pie` use
   `value.id` + `color.id` (NOT `value.columnId`); control value fields are FLAT
   top-level (not a nested `value` object); `refMarks` value is wrapped (see #3).
   Canonical reference: `sigma-workbooks/reference/specification/charts.md` + `controls.md`.

8. **Layout fidelity.** Uses the source's layout grid for proportional spans (taller
   zones get more rows — not equal heights), and emits a sheet/page **title header**
   element.

## Current status (updated 2026-06-15)

✅ HANDLED · ⚠️ PARTIAL · ❌ MISSING

| Dim | tableau | powerbi | looker | quicksight | thoughtspot | cognos | mstr | qlik |
|---|---|---|---|---|---|---|---|---|
| 1 Scatter no-collapse | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| 2 Colors (by-measure) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| 3 Reference lines | ✅ | ✅ | ✅ | ✅ | ⚠️ | ✅ | ❌ | ✅ |
| 4 Dynamic titles | ✅ | ⚠️ | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | ✅ |
| 5 Controls w/ source | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ✅ | ✅ |
| 6 Visual-QA auto-gate | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ✅ |
| 7 Spec-shape | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 8 Layout fidelity | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ✅ |

(thoughtspot dim 3 = ⚠️: refMark capture is coded + no-ops safely, but no real Liveboard
in team2 has a target line so it's unvalidated against real TML; controls/colors/gate are
live-validated against real Liveboards (PerfTracking/UserAdoption) + the migrated sample.)

**Progress log:**
- **2026-06-16 — thoughtspot kitchen-sink feature stress test.** Built TS content
  exercising every feature (24 chart types, 11 formula classes + RLS, all interactivity)
  and migrated each live. Found + FIXED 6 real gaps (all re-validated): (1) single-quote
  string literals corrupted `'Bulk'`→`[Bulk]` in EVERY `if`/`in` calc — `tsWrapColumnRefs`;
  (2) control on an un-surfaced column 400'd the whole workbook — `liveboard_controls`
  denorm-qualified ref; (3) `unique count(` space syntax hard-failed the DM POST; (4) 10
  exotic charts silently became bar — now flagged degrade-to-table; (5) window fns + (6)
  RLS rules silently dropped — now warn (+ `result.security[]`). Live proof: calc parity
  (Distinct Custs=26, Cat Flag Yes:10/No:15), interactive wb ab4d2020 (2 controls incl the
  fixed un-surfaced date filter). Full matrix: docs/thoughtspot-feature-coverage.md. dim-4
  dynamic-title interpolation remains the only TS ⚠️.
- **2026-06-15 — thoughtspot #119 MERGED + live-validated.** Fixed a crash in
  `parse_measure_color` (real TML `columnProperties` entries aren't always dicts) that
  would break migrating any CF Liveboard; verified clean parse on PerfTracking (10 vizzes)
  + UserAdoption (27). End-to-end proof: extracted the TS-native "(Sample) Retail - Apparel"
  worksheet (22,425 rows) via `searchdata` → `CSA.TJ.TS_APPAREL_FACT` → Sigma DM 953cd3c6 +
  workbook 9fd116fe — **exact parity, Total Sales $970,696,156.87**, 2 populated controls,
  renders cleanly (title/KPIs/bars/line). Path for Falcon-only TS data = searchdata→Snowflake.
- **2026-06-15 — P2 scatter collapse fixed** in looker/quicksight/thoughtspot/cognos (grouped-source port; **looker live-proven** — 5 distinct points rendered), `+size` on tableau, + `verify-parity` numeric-string coercion so scatters don't false-DIVERGE. Remaining: scatter emission on mstr (roadmap).
- **2026-06-15 — P1 visual-QA gate wired** in tableau/looker/quicksight/cognos/powerbi orchestrators (qlik already had it; **looker live-proven** — renders N/N). Remaining: mstr.
- **2026-06-15 — P3 reference lines + P4 by-measure colors** added to tableau/powerbi/looker/quicksight/cognos (refMarks wrapped value + label shown; color:{by:scale} on a duplicate measure column). **P5 interactive controls** built in quicksight (+ control-scope). thoughtspot's equivalents are in PR #119, **held** pending live-fixture validation (its TML capture keys are inferred, not doc'd; no-op safely on a miss).

**Reference implementation:** `qlik-to-sigma` (all 8) and `powerbi-to-sigma` (scatter,
controls, layout) are the patterns to port from.

**Priority:** P1 wire the visual-QA gate everywhere (catches the rest) → P2 fix scatter
collapse (looker/quicksight/thoughtspot/cognos; +size on tableau) → P3 reference lines →
P4 by-measure colors → P5 build controls in quicksight/thoughtspot.
