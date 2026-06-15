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
| 1 Scatter no-collapse | ⚠️ no size | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| 2 Colors (by-measure) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 3 Reference lines | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 4 Dynamic titles | ✅ | ⚠️ | ⚠️ | ⚠️ | ❌ | ❌ | ❌ | ✅ |
| 5 Controls w/ source | ✅ | ✅ | ✅ | ❌ | ❌ | ⚠️ | ✅ | ✅ |
| 6 Visual-QA auto-gate | ✅ | ⚠️ | ✅ | ✅ | ⚠️ | ✅ | ⚠️ | ✅ |
| 7 Spec-shape | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 8 Layout fidelity | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ | ⚠️ | ✅ |

**Progress log:**
- **2026-06-15 — P2 scatter collapse fixed** in looker/quicksight/thoughtspot/cognos (grouped-source port; **looker live-proven** — 5 distinct points rendered), + `verify-parity` numeric-string coercion so scatters don't false-DIVERGE. Remaining: `+size` on tableau; scatter emission on mstr (roadmap).
- **2026-06-15 — P1 visual-QA gate wired** in tableau/looker/quicksight/cognos orchestrators (qlik already had it; **looker live-proven** — renders N/N). Remaining: powerbi/thoughtspot auto-invoke their existing gate; mstr.

**Reference implementation:** `qlik-to-sigma` (all 8) and `powerbi-to-sigma` (scatter,
controls, layout) are the patterns to port from.

**Priority:** P1 wire the visual-QA gate everywhere (catches the rest) → P2 fix scatter
collapse (looker/quicksight/thoughtspot/cognos; +size on tableau) → P3 reference lines →
P4 by-measure colors → P5 build controls in quicksight/thoughtspot.
