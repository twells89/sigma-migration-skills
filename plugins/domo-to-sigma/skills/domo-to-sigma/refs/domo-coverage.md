# Domo → Sigma — dashboard classifier coverage matrix

> **GENERATED — do not edit by hand.** Regenerate with `python3 scripts/gen-coverage-matrix.py --catalogs refs/catalogs --skill domo --out refs/domo-coverage.md`. The JSON catalogs in `refs/catalogs/` are the single source of truth; the classifier (`scripts/build_workbook.py` / `build-sigma-workbook.py`) LOADS them via `shared/lib/coverage_catalog.py`. A no-drift test asserts this file matches the catalogs.

Every documented source construct maps to a real, current Sigma target or a loud fallback — no silent wrong-defaults, no name-substring guessing (beads-sigma-kvza).

**`sigma_verified` legend:** ✅ y = the mapped Sigma target resolved at **query time** in a live migration (no `type=error` column) on the date shown; 🟡 n = target is documented but not yet query-verified.

**Coverage:** 39 documented constructs across 2 dimensions; 0 live-verified.

## Visualization / chart kind

_Exact Domo chartType tokens observed or creation-probed by this converter. Sigma kinds are emitted only for grounded tokens; approximations and missing native equivalents are loud. Workbook-as-code release features without a confirmed Domo token are kept in workbook-feature.json rather than guessed here._

Authoritative source: <https://knowledge.domo.com/Visualize/Adding_Cards_to_Domo/KPI_Cards/Chart_Properties>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `badge_vert_bar` | — | `bar-chart` | 🟡 n | warn+bar |
| | | | | _Vertical, unstacked._ |
| `badge_horiz_bar` | — | `bar-chart` | 🟡 n | warn+bar |
| | | | | _Horizontal orientation._ |
| `badge_vert_stackedbar` | — | `bar-chart` | 🟡 n | warn+bar |
| | | | | _stacking:stacked._ |
| `badge_vert_multibar` | — | `bar-chart` | 🟡 n | warn+bar |
| | | | | _Grouped bars._ |
| `badge_horiz_multibar` | — | `bar-chart` | 🟡 n | warn+bar |
| | | | | _Horizontal grouped bars._ |
| `badge_horiz_100pct` | — | `bar-chart` | 🟡 n | warn+bar |
| | | | | _Horizontal, stacking:normalized._ |
| `badge_vert_nestedbar` | — | `bar-chart` | 🟡 n | warn+flatten-groups |
| | | | | _Explicit approximation: Sigma has no two-level nested category shelf._ |
| `badge_symbolline` | — | `line-chart` | 🟡 n | warn+line |
| `badge_curved_symbolline` | — | `line-chart` | 🟡 n | warn+line |
| | | | | _Curve styling is not fabricated._ |
| `badge_trendline` | — | `line-chart` | 🟡 n | warn+line |
| `badge_two_trendline` | — | `line-chart` | 🟡 n | warn+line |
| `badge_xyscatterplot` | — | `scatter-chart` | 🟡 n | warn+table |
| `badge_bubble` | — | `scatter-chart` | 🟡 n | warn+scatter |
| | | | | _BUBBLESIZE maps to size when present._ |
| `badge_pie` | — | `pie-chart` | 🟡 n | warn+table |
| `badge_donut` | — | `donut-chart` | 🟡 n | warn+table |
| `badge_singlevalue` | — | `kpi-chart` | 🟡 n | warn+table |
| `badge_filledgauge` | — | `progress` | 🟡 n | warn+kpi |
| | | | | _Conditional: emit released ring progress only with explicit CURRENT and TARGET role mappings and no card-local filter/date window; otherwise retain a KPI and report the missing range/filter semantics._ |
| `badge_table` | — | `table` | 🟡 n | warn+table |
| `badge_map` | — | `region-map` | 🟡 n | warn+table |
| | | | | _Only when the geography column maps to a published regionType._ |
| `badge_line_bar` | — | `combo-chart` | 🟡 n | warn+bar |
| `badge_line_stackedbar` | — | `combo-chart` | 🟡 n | warn+bar |
| `badge_symbol_bar` | — | `combo-chart` | 🟡 n | warn+bar |
| `badge_treemap` | — | `bar-chart` | 🟡 n | warn+bar |
| | | | | _Explicit approximation; area hierarchy is lost._ |
| `badge_word_cloud` | — | `table` | 🟡 n | warn+table |
| | | | | _No native word-cloud surface._ |
| `badge_calendar` | — | `table` | 🟡 n | warn+table |
| | | | | _No native calendar-heatmap surface._ |
| `badge_pop_bar_line` | — | `combo-chart` | 🟡 n | warn+skip |
| | | | | _INTERVAL_OFFSET + periods OFFSET metadata is reconstructed as explicit measures over aligned hidden helpers; unresolved compare shapes are skipped rather than emitted as one series._ |
| `badge_vert_symbol_overlay` | — | `combo-chart` | 🟡 n | warn+combo |
| | | | | _Approximate bar plus scatter marker; no dial semantics are claimed._ |

## workbook-feature

_Domo composition and interaction semantics mapped to the Aug-2026 Sigma workbook-as-code release. The converter emits a target only when discovery carries equivalent source intent; released Sigma capabilities are not evidence that a Domo artifact used them._

Authoritative source: <https://knowledge.domo.com/Visualize/Adding_Cards_to_Domo>

| construct | doc ref | Sigma target | sigma_verified | on-unmapped |
|---|---|---|---|---|
| `waterfall-card` | — | — (no Sigma equivalent) | 🟡 n | warn+reviewed-fallback |
| | | | | _Sigma waterfall-chart is released, but this converter has no creation-probed or live-observed Domo chartType token and role payload for a waterfall. Do not substring-guess a token or emit waterfall-chart from PNG appearance alone._ |
| `card-legend-settings` | — | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Current normalized card discovery does not expose a grounded legend visibility/position path. Preserve the chart and Sigma default; do not invent element.legend or a standalone legend control._ |
| `allowTableDrill/drillPath` | — | — (no Sigma equivalent) | 🟡 n | warn+retain-base-chart |
| | | | | _Discovery records drill intent, but not a complete validated ordered hierarchy with target wiring. The converter reports the gap and never emits dead controlType:drill UI._ |
| `page-list` | [doc](https://knowledge.domo.com/Visualize/Managing_Domo_Pages) | `pages + navigation:auto` | 🟡 n | single content page |
| | | | | _Multiple discovered Domo pages become metadata-only document pages, one authoritative layout Page block each, auto navigation on every content page, and shown view-mode page tabs._ |
| `pageLayoutV4/PAGE_BREAK` | — | `page-break` | 🟡 n | explicit-gap |
| | | | | _Only an authored PAGE_BREAK entry in pageLayoutV4.standard.template is emitted. Geometry alone is never interpreted as print pagination._ |
| `badge_filledgauge CURRENT+TARGET` | — | `progress` | 🟡 n | warn+kpi |
| | | | | _Explicit CURRENT and TARGET role mappings ground value and maximum; the filled gauge maps to ring progress with zero minimum. Card-local filters/date windows force a loud KPI fallback because source-less progress cannot preserve them._ |
| `page-filter-bar-chrome` | — | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _pageAnalyzerSettings.showFilterBar proves chrome exists but does not provide exported filter definitions or a published panel binding. document.panels stays empty; no panel or control is fabricated._ |
| `literal-layout-palette/canvas` | — | `settings.theme.overrides` | 🟡 n | preserve-Sigma-default |
| | | | | _Only literal colors present in parsed layout signals map to backgroundCanvas/categoricalScheme. Dynamic CSS, card renderer internals, and inferred brand colors are not emitted._ |
| `pageLayoutV4/HEADER` | — | `text + authoritative layout` | 🟡 n | omit-empty-header |
| | | | | _An authored non-empty header becomes a text element at the captured geometry. Empty or unknown layout content types are not fabricated._ |
| `tabbed-card-container` | — | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _The normalized Domo artifacts do not expose grounded tab labels plus child membership. Top-level pages map to navigation, not tabbed-container._ |
| `data-bound-repeating-region` | — | — (no Sigma equivalent) | 🟡 n | explicit-gap |
| | | | | _Ordinary Domo cards and collections are static layout, not row-card repeat semantics. Never synthesize repeated-container from duplicated cards._ |
| `box-and-whisker-card` | — | — (no Sigma equivalent) | 🟡 n | warn+reviewed-fallback |
| | | | | _box-chart is workspace-gated. Domo box-plot source token/roles are also ungrounded here. Never emit box-chart until both source extraction and target entitlement/create-readback behavior are verified._ |

---
_Compositional constructs that do not serialize to a flat table (Set Analysis, filtered `*If`, ratio measures, TO_CHAR/Excel mask parsers, count-on-joined-view) stay as cited predicates in the classifier; this matrix covers the enumerable maps._
