# Tableau deterministic compiler release contract

The deterministic workbook compiler remains a WIP second option. The existing
Tableau data-model converter, shared chart emitters, and Phase 6 gates remain
authoritative.

## Modes

- `--deterministic-compiler auto`: use the semantic plan when it has no blockers;
  otherwise retain the existing gated path.
- `required`: stop before writes on any blocker.
- `off`: bisect against the existing path.

## Offline release floor

- Semantic-plan and workbook output are byte-identical across two runs.
- Compile-plan reconciliation has no unmatched plan keys, unexplained builds,
  missing controls, or dropped coverage.
- At least four workbook shapes have full golden output: KPI/dashboard,
  crosstab/controls, window calculations, and pipeline reuse.
- Negative unsupported-viz and missing-binding cases stop before writes.

## Live panel

Panel definition: `benchmarks/tableau-compiler/panel.json`.

- Candidate outcome equals or beats baseline on at least 80% of live cases.
- At least 60% of live cases reach GREEN.
- Zero numeric regressions greater than one percentage point.
- Anchor cases have exact value parity, nonempty displayed tiles, zero dropped
  visuals, and visual-similarity floor PASS.
- Promotion requires two consecutive passing panel runs.

Evaluate captured A/B workdirs:

```bash
ruby tools/tableau-compiler-benchmark.rb \
  --panel benchmarks/tableau-compiler/panel.json \
  --results-root /tmp/tableau-compiler-results \
  --out /tmp/tableau-compiler-results/results.json
```

Do not change the default to `required` until every threshold passes.
