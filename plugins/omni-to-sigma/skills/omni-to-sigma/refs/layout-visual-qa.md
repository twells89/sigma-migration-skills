# Visual QA (Omni)

After the workbook POST, render the dashboard page with
`scripts/sigma-export-png.py` and compare it to the Omni document. Check:

- KPI tiles are tall enough to show the title (layout lint enforces the minimum).
- The date control sits above the charts, not over them.
- Skipped tiles listed in `chart-gaps.json` are absent on purpose.
- Currency metrics still show a currency format, not a bare number.

Record the verdict with `scripts/record-visual-check.rb` when that script is
vendored for the run. A numeric parity pass does not replace this look.
