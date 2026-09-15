<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. Phase 4 — 3-way parity (Looker vs Sigma vs warehouse), the scripted gate, visual QA. -->

# Phase 4 — Verify parity (3-way) — MANDATORY

A conversion is not complete until the numbers tie out. Compare at **two grains**: the model's
key metrics, and per-tile.

### 4-pre. The scripted gate (canonical — what migrate-looker.py runs)

```bash
ruby scripts/phase6-parity-looker.rb --workdir /tmp/<name> --workbook-id <wb>   # PASS 1: plan
# … fetch ACTUAL (Sigma CSV export / mcp__sigma-mcp-v2__query) + EXPECTED
#   (Looker POST /queries/run/json, or the warehouse re-aggregation offline) …
#   → write parity-expected.json + parity-actuals.json (shape: {"<chart>": [[dim,val],…]})
ruby scripts/phase6-parity-looker.rb --workdir /tmp/<name> --finalize           # PASS 2: sentinel
# MEASURED bars — Phase 4a must have authored source-anchors.json (>=5) + landed a source PNG on disk:
ruby scripts/verify-anchors.rb      --workdir /tmp/<name> --workbook-id <wb>    # -> anchors-verdict.json (gate 13)
python3 scripts/visual-similarity.py --source /tmp/<name>/dashboards/looker-<dash>.png --render /tmp/<name>/sigma-<dash>.png --json-out /tmp/<name>/visual-similarity.json  # gate 14
ruby scripts/assert-phase6-ran.rb   --workdir /tmp/<name> --workbook-id <wb>    # must exit 0
```

The finalize pass writes the **`parity-final.json` sentinel**; `assert-phase6-ran.rb`
(hard gate, vendored byte-identical across the 5 plugins) refuses GREEN unless
parity ran + PASSed, no orphan workbooks were left, the live workbook has no
`type=error` columns, a real layout is applied, the layout lint passes (gate 6),
the control lint passes (gate 7 — dead/ghost/partial controls; see
`refs/control-parity.md`), **the source-anchor values verify (gate 13** — needs
`source-anchors.json` ≥5 + a passing `anchors-verdict.json`; arms when a source
PNG is on disk; `--skip-anchors-gate "<reason>"`**)**, and **the visual-similarity
floor holds (gate 14** — `visual-similarity.json`; `--skip-visual-similarity "<reason>"`**)**;
no source PNG on disk → both self-SKIP (stated), never a silent pass. Optional runtime follow-up when controls exist:
`ruby scripts/probe-controls.rb --workbook-id <wb> --check-out-of-closure`
(flip test — in-closure export must change under a non-default control value,
out-of-closure must not). `migrate-looker.py` automates
both fetch sides and runs the gate for you. The manual 3-way checks below remain
the reference for what "parity" means.

1. **Looker** — `POST /queries/run/json` (or `run_inline_query`) for the model/explore, e.g.
   net revenue by region.
2. **Sigma** — `mcp__sigma-mcp-v2__query` against the DM element (raw aggregate, since
   `metric()` returns "Missing Metric") AND against each workbook chart element.
3. **Warehouse** — the source-of-truth `SELECT` (via the Sigma connection or `snow`).

GREEN only when all three match. The validated run produced **exact** parity to the cent —
region revenue (West 38906.82 / South 31650.98 / NE 21587.52 / MW 14966.20 / null 3231.23 =
$109,765.89) and the ratio metrics (AOV / margin / return) identical across Looker and Sigma.

### 4a. Visual QA — render BOTH dashboards to PNG and eyeball them side-by-side

Numbers tying out is necessary but not sufficient — a workbook can be GREEN on parity yet look
broken (hidden KPI titles, orphaned filters, overlapping tiles, the wrong chart kind, bare numbers
where Looker showed `$`/`%`). After POSTing, render **both** the Looker source dashboard and the
migrated Sigma workbook to PNG and inspect them side-by-side:

```bash
# (1) SOURCE — render the live Looker dashboard (reads ~/.looker/looker.ini).
#     Land it under dashboards/ (a gate-discovered path) so the anchors bar (gate 13) arms:
mkdir -p /tmp/<name>/dashboards
python3 scripts/looker-render-dashboard.py <dashboardId> /tmp/<name>/dashboards/looker-<dash>.png
#     Then READ that PNG and transcribe its printed values into /tmp/<name>/source-anchors.json
#     (>=5 anchors, EXACTLY as printed — every KPI, top-3 of each ranked list/table, one bucket
#     per chart; schema: refs/source-anchors.md). Verified in 4-pre (gate 13) + fed to gate 14.

# (2) MIGRATED — render the Sigma workbook page
bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/sigma-export-png.py \
  --workbook <workbookId> --page page-dash --out /tmp/<name>/sigma-<dash>.png'
```

Read both PNGs and compare tile-for-tile. Confirm: **KPI tile titles show** (the builder lays KPIs
≥ 6 rows tall — a `kpi-chart` hides its title below ~5 rows / ~150px; see
`feedback_sigma_kpi_label_height.md`), the **filters sit in a top control bar** (not orphaned at
the bottom), tiles are aligned with no large empty regions, each chart kind matches Looker, and
**number formats match** — if Looker shows `$176.85` the Sigma KPI must too (the builder carries
LookML `value_format_name` / `value_format` into the tile column `format`; see Phase 3). Iterate on
`build_workbook.py` + re-`PUT` the spec until the side-by-side render is clean.

**Visual QA is a mandatory gate — never skip, never declare done on HTTP 200.** A workbook that
POSTs cleanly and passes parity can still be visually broken (overlapping tiles, clipped KPI titles
below ~5 rows, dead zones, orphaned filters; Sigma's grid has no z-order). After rendering the
migrated pages with `sigma-export-png.py` (side-by-side vs `looker-render-dashboard.py`):
1. **Read each migrated PNG** and check it against `refs/layout-visual-qa.md` (no overlaps/stacking,
   no dead zones, controls placed in-band, no clipped KPI titles, even heights, right chart kind/format).
2. Fix any failure in the spec — for multi-page workbooks use
   the companion **sigma-workbooks** skill's `scripts/wb-rep.rb` (full-clone: `plugins/sigma-authoring/skills/sigma-workbooks/scripts/wb-rep.rb`; pull → edit → push) — then **re-render and re-read**.
3. Loop until the render passes inspection.

**Record the RLS outcome here.** If Phase 1d found RLS, the migration summary MUST list, per
finding, whether it was **ported / reused / skipped** (and the Sigma user attribute + filter used)
— so any skipped Looker restriction is visible to a reviewer, never silently dropped. (When RLS
is active, parity-check as a representative restricted user, not only as an admin who sees all
rows.)

> **If `mcp__sigma-mcp-v2__query` errors with an auth message mid-Phase-4**, the MCP session
> staled — re-call `mcp__sigma-mcp-v2__begin_session` and retry. Do not skip parity over a
> recoverable auth error.
