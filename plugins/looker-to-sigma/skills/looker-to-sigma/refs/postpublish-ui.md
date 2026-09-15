<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. Phase 5 — post-publish, UI-only features with no spec-API analog. -->

# Phase 5 — Enhance (post-publish, UI-only features)

Some Looker features have no spec-API analog and must be wired in the Sigma UI after publish.
Set expectations up front (they appear as warnings from `build_workbook.py`):

- **Cross-filtering** (clicking a Looker bar filters siblings) → Sigma "Set as filter" actions —
  UI-only.
- **Trellis / small multiples** — `looker_donut_multiples` is now emitted NATIVELY: `build_workbook.py`
  builds ONE Sigma `donut-chart` with the element `trellis` facet (the row dimension → `columnsBy`,
  the pivot stays the slice), via the shared `TrellisEmit` (`scripts/lib/trellis_emit.py`). Not UI-only.
  Sigma silently strips `trellis` only on UNSUPPORTED kinds (donut IS supported), so the round-trip
  guard `verify-trellis-survived.rb` re-reads the readback and asserts the key survived, keyed off the
  `native-trellis-emitted.json` sidecar. Pivoted CARTESIAN charts stay color SERIES (Looker renders
  those pivots as series, not panels) — see `docs/sigma-trellis-chart-support.md`.
- **Tooltips / `note_text` / `subtitle_text`** → no spec slot; concatenate into the chart title
  or add an adjacent `text` element.
- **KPI comparison** (`show_comparison`) → add a 2nd KPI tile or a UI delta.
- **Pivot cross-tab** → rebuild the flattened table as a Sigma `pivot-table` in the UI.
- **Per-tile refresh intervals** → Sigma has workbook-level scheduled refresh only — drop + warn.
