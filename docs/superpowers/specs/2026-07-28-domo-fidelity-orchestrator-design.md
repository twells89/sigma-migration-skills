# Design: domo-to-sigma fidelity pass — orchestrator + layout + format + image element (PR1)

**Date:** 2026-07-28
**Status:** Proposed design — pending review, then plan → execute
**Author:** TJ Wells (with Claude)
**Target repo:** `twells89/sigma-migration-skills` (worktree `~/wt-domo-fidelity`, branch `feat/domo-fidelity`, off `origin/main`)
**Beads:** orchestrator (new), `beads-sigma-8t8x` (layout), `beads-sigma-l817` (format), `beads-sigma-jgkj` (KPI ref — prevented), `beads-sigma-px3h` (image, v1)
**Source of the work:** a partner field migration (2026-07-28, plugin v0.1.1). All identifiers scrubbed.

## Context

A partner migrated a Domo "Command Center" dashboard: **data parity was perfect, but visual fidelity was ~0** — a rich 2D grid of KPI+logo pairs under section headers came out as a flat single-column stack with text placeholders where images should be. Two root-cause probes established that **the deterministic scripts are mostly correct** (`build_kpi` already emits `[Master/…]`; `sigma_format` emits a d3 `formatString`, not the Excel `#,##0` the operator hit). The real cause: **there is no orchestrator** — SKILL.md tells the operating agent to hand-chain ~8 vendored scripts across Phases 4–6, and the agent went off-script (hand-assembled the spec, wrote its own POST, and skipped the layout chain → Sigma's layout-less default is a vertical stack).

## Goals

1. **`migrate-domo.rb` orchestrator** — a single, deterministic, Windows-safe, idempotent Phase 1→6 driver (mirroring `migrate-tableau.rb`) so migrations don't depend on an agent hand-chaining scripts.
2. **Fold card geometry into `domo-discover`** so `cards.json` carries `x/y/w/h` (today only the optional `domo-capture-visuals.rb` extracts it, into a separate file nothing requires).
3. **Reproduce the 2D grid** — the orchestrator always runs the geometry→layout→`put-layout` chain; fix the `'kpi'` vs `'kpi-chart'` tag mismatch (`lib/layout.rb:388`) that disables KPI-row detection.
4. **Gate Phase 5 on geometry presence** (warn, not silent) so a layout-less POST can't slip through offline.
5. **`sigma_format` → the field-proven shape** — `{kind:"number", decimalPlaces:N}` (+ Sigma's currency/percent kinds) instead of the unverified d3 `formatString`.
6. **Image element** — add a `{kind:"image", url:…}` builder; extract image-card PNGs (`render_card_png`, Tier A) into a staging dir and emit the element with a host-URL slot + a precise Phase-5e instruction.

## Non-goals (deferred / honest ceilings)

- **Live visual validation** (does it *render* as a 2D grid in Sigma) — needs a live Domo+Sigma run; **offline validation proves the produced spec's layout XML is a 2D grid, not a stack**, but the visual confirmation is deferred and **not claimed**.
- **`Date(y,m,d)`→`MakeDate` (`9777`)** — lives in the separate `convert_sql_to_sigma_formula` MCP/converter repo; its own PR (PR2).
- **True inline image auto-embed** — **blocked by Sigma's API** (no asset upload; data-URI WAF-blocked; external-URL only). v1 stages the bytes + emits the element with a host-URL slot; auto-hosting *customer* logos on a public URL is a governance no-go. Not a converter defect — a platform ceiling; documented.
- **Tier-B image extraction** — no Domo render endpoint on Tier B; manual export stays the documented fallback.

## Decisions locked

| Decision | Choice |
|---|---|
| Orchestrator language | Ruby (`migrate-domo.rb`), no fragile inline bash (Windows Git-Bash safe); reuse `get_token`/doctor for creds |
| Idempotency | Re-runnable; each phase writes/reads `discovery/*` + `run-state.json`; skip-if-present with `--force` to redo |
| Geometry | Fold `domo-capture-visuals`'s `normalize_layout` into `domo-discover` so `cards.json` carries `x/y/w/h`; capture-visuals still handles PNGs |
| Format shape | `{kind:number, decimalPlaces:N}` (proven); currency/percent via Sigma's format kind; drop d3 `formatString` |
| Image v1 | element + staged PNG + host-URL slot + warning; NO public auto-host of customer assets |
| Validation | Offline, fixture-driven, asserting a 2D-grid layout (not a stack); live render deferred |
| PR scope | One domo-plugin PR; version bump (0.2.0 → 0.3.0, new orchestrator = feature) |

## Design

### 1. `scripts/migrate-domo.rb` (orchestrator)
Chains, with a clear phase log + `run-state.json` + fail-fast:
`domo-discover` → `domo-capture-visuals` → `convert-beast-modes` (+ the MCP formula fill) → `build-workbook` → `build-workbook-spec` → `post-and-readback` → `build-domo-layout` → `build-dashboard-layout` → `put-layout` → `verify-parity` → `assert-phase6-ran`.
Windows-safe (pure Ruby; creds via `get_token.py`/env, never inline-bash export chains). `--from <workdir>` resumable; `--offline`/`--dry-run` runs the non-live phases over fixtures for tests. Tier A/B aware (skips render/private-API phases on Tier B with a warning).

### 2. Geometry into `domo-discover`
Fold `domo-capture-visuals.rb:79-103` `normalize_layout` card-geometry extraction into `domo-discover.rb`'s `--pages` path so each `cards.json` record carries `x/y/w/h`. `build-domo-layout.rb` already consumes coords — it just needs them present. (Keep `domo-capture-visuals` for the PNG capture.)

### 3. Tag fix + Phase-5 gate
`lib/layout.rb:388` `kpi_like_zone?` accepts `'kpi-chart'` (not only `'kpi'`). `build-workbook.rb`/`qa-check.rb` emit a loud warning (same pattern as the existing KPI-count warning) when a page's cards lack matching geometry — so a stack can't ship silently offline.

### 4. `sigma_format` (lib/domo_sigma_util.rb:41-57)
Return `{ 'kind'=>'number', 'decimalPlaces'=>prec }`; currency → Sigma currency format kind, percent → percent kind. Remove the d3 `formatString` (unverified grammar; the field run proved `decimalPlaces` POSTs cleanly). Keep the passthrough-columns-carry-no-format rule.

### 5. Image element
`refs/card-to-element.md`: add an `image` row. `build-workbook.rb`: `build_image(card)` → `{id, kind:'image', url: <slot>}` for image/logo/drawing cards (chartType substring + PNG fallback). Extract the PNG via `domo_rest.render_card_png` (Tier A) into `discovery/png/cards/<id>.png`; emit the element with the staged path noted + a Phase-5e warning: "host these N images and set each element's `url`." Layout already places the element beside its KPI once it exists.

### 6. Offline validation (what "done" means here)
A fixture-driven `test/test-migrate-domo.rb`: run the orchestrator `--offline` over a synthetic Domo estate fixture (scrubbed) with card geometry + a KPI + an image card, and assert: (a) the emitted workbook spec's layout is a **multi-zone 2D grid** (KPI row detected, section-header zone, image beside KPI) — **not** a single-column stack; (b) KPI formula `= <Agg>([Master/…])`; (c) format `= {kind:number, decimalPlaces:…}`; (d) an `image` element emitted; (e) `assert-phase6-ran.rb`'s layout gate passes on the produced spec. Plus the existing offline suites stay green.

## Governance

No customer identifiers or assets anywhere (scrubbed synthetic fixtures; no public asset hosting). One-plugin PR; plugin version bump; `Skip-Version-Bump` N/A (feature → real bump). Live visual parity **not claimed** — offline structure only.

## Decomposition (for the plan)

1. Fold geometry into `domo-discover` + test.
2. `sigma_format` → decimalPlaces + test.
3. `'kpi-chart'` tag fix + Phase-5 geometry gate + test.
4. Image element (`build_image` + extract/stage + ref row) + test.
5. `migrate-domo.rb` orchestrator + `--offline` fixture E2E test (the 2D-grid assertion) + CI allow-list.
6. SKILL.md: replace the hand-chain prose with the orchestrator as the one-command path; version bump; docs.

## Risks

- **Live render unverified offline** — mitigated by asserting layout *structure*; flagged as deferred, not claimed.
- **`build-dashboard-layout` fidelity on real Domo coord ranges** — the fixture uses representative coords; a real estate may need tuning (surface, don't silently degrade).
- **Image host step is manual** — honest platform ceiling; documented, not hidden.
