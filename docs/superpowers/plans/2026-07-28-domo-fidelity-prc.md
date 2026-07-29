# domo-to-sigma fidelity (PR-C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a domo→sigma migration turnkey and visually faithful — a single `migrate-domo.rb` run reproduces the source's 2D grid (KPI+logo pairs, section headers), embeds logos inline, and emits correct number formats — instead of a hand-chained pipeline that drifts into a single-column stack.

**Architecture:** Fold card geometry into discovery so it always reaches the (already 2D-capable) layout builder; fix the two small bugs that defeat it (`kpi`/`kpi-chart` tag, missing image element, d3-formatString); add a deterministic orchestrator that always runs the full chain; prove it offline with a fixture E2E that asserts a 2D-grid layout, not a stack.

**Tech Stack:** Ruby 2.6 (stdlib `json`/`base64`/`fileutils`/`optparse`), the vendored layout engine (`lib/layout.rb`, `build-dashboard-layout.rb`, `put-layout.rb`), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-07-28-domo-fidelity-orchestrator-design.md` (+ its Revision addendum).

## Global Constraints

- **Ruby 2.6-safe** — no endless method defs; verify `ruby -c`.
- **No customer/org/user identifiers** anywhere (scrubbed synthetic fixtures; hygiene-sweep gated).
- **Images = INLINE PNG data-URI** — `{kind:"image", url:"data:image/png;base64,#{Base64.strict_encode64(bytes)}"}` (tableau's `build-charts-from-signals.rb:6655` pattern). No hosting. SVG would be WAF-blocked; Domo logos are raster PNG. Render path is field-probe-verified, **not** CI-backed — tests assert element *shape*, not a live render.
- **Number format = `{kind:"number", decimalPlaces:N}`** (field-proven); currency/percent via Sigma's format kind. Drop the d3 `formatString`.
- **Orchestrator = pure Ruby, Windows-safe** (no fragile inline-bash export chains), idempotent, Tier A/B aware.
- **EXCLUDE formula-vendoring** (PR-B) — this PR calls `convert-beast-modes.rb` as-is.
- **One-plugin PR**; bump `plugin.json` 0.2.0 → 0.3.0 (feature). Live visual parity **not claimed**.

## File Structure

```
plugins/domo-to-sigma/skills/domo-to-sigma/
  scripts/domo-discover.rb        T1  fold geometry (x/y/w/h) into cards.json
  scripts/lib/domo_sigma_util.rb  T2  sigma_format -> decimalPlaces
  scripts/lib/layout.rb           T3  kpi_like_zone? accept 'kpi-chart'
  scripts/build-workbook.rb       T3/T4  Phase-5 geometry warn + build_image (data-URI)
  refs/card-to-element.md         T4  image row
  scripts/migrate-domo.rb         T5  NEW orchestrator (Phase 1->6)
  test/test-geometry-discover.rb  T1
  test/test-sigma-format.rb       T2
  test/test-layout-tag.rb         T3
  test/test-build-image.rb        T4
  test/test-migrate-domo.rb       T5  offline E2E: assert 2D-grid layout
  test/fixtures/domo-estate/*     T1/T5  scrubbed synthetic estate w/ geometry + KPI + image card
  SKILL.md                        T6  turnkey orchestrator prose
  .claude-plugin/plugin.json      T6  0.2.0 -> 0.3.0
.github/workflows/corpus-check.yml T5  add the 5 new test paths to unit-tests allow-list
```

---

### Task 1: Fold card geometry into `domo-discover`

**Files:** Modify `scripts/domo-discover.rb` (`normalize_card` ~98-152; `--pages` path ~322-324). Create `test/test-geometry-discover.rb` + `test/fixtures/domo-estate/pages-raw.json` (scrubbed).

**Interfaces:** Produces — each `discovery/cards.json` record gains `'x','y','w','h'` (integers) when the page layout provides them; absent → the keys are omitted (not zero).

- [ ] **Step 1: Failing test** — `test/test-geometry-discover.rb`: feed a synthetic page-layout blob (cards at distinct x/y/w/h) through the discover geometry-merge and assert the emitted card records carry matching `x/y/w/h`.
```ruby
require 'json'; require_relative 'helper' rescue nil
# minimal: load the geometry-merge helper and assert it copies coords
require_relative '../scripts/lib/domo_sigma_util'
layout = {'cards'=>[{'id'=>'c1','x'=>0,'y'=>0,'w'=>3,'h'=>2},{'id'=>'c2','x'=>3,'y'=>0,'w'=>3,'h'=>2}]}
cards  = [{'id'=>'c1','title'=>'A'},{'id'=>'c2','title'=>'B'}]
merged = DomoSigma.merge_geometry(cards, layout)   # new helper
raise 'no geom' unless merged[0]['x']==0 && merged[1]['x']==3 && merged[0]['w']==3
puts 'test-geometry-discover: PASS'
```
- [ ] **Step 2: Run → fails** (`DomoSigma.merge_geometry` undefined).
- [ ] **Step 3: Implement** — add `DomoSigma.merge_geometry(cards, page_layout)` to `lib/domo_sigma_util.rb` porting `domo-capture-visuals.rb:79-103` `normalize_layout`'s coordinate extraction (`x = geom['x']||geom['col']||geom['gridX']`, same for y/w/h), keyed by card id. In `domo-discover.rb`'s `--pages` branch (~322), after fetching `page_layout`, call `merge_geometry` so each card written to `cards.json` carries coords (replace the dead `page['_layout']=layout` stash at :322-324). Ruby 2.6-safe.
- [ ] **Step 4: Run → PASS**; `ruby -c`.
- [ ] **Step 5: Commit** — `git commit -m "feat(domo): fold card grid geometry into domo-discover (cards.json carries x/y/w/h)"`

---

### Task 2: `sigma_format` → `decimalPlaces`

**Files:** Modify `scripts/lib/domo_sigma_util.rb:41-57`. Create `test/test-sigma-format.rb`.

**Interfaces:** Produces — `sigma_format(domo_fmt, name)` returns `{ 'kind'=>'number', 'decimalPlaces'=>Integer }` (or a currency/percent kind), never a d3 `formatString`.

- [ ] **Step 1: Failing test** — `test/test-sigma-format.rb`:
```ruby
require_relative '../scripts/lib/domo_sigma_util'
include DomoSigma
f = sigma_format({'type'=>'NUMBER','precision'=>0}, 'Days Using')
raise "got #{f.inspect}" unless f == {'kind'=>'number','decimalPlaces'=>0}
f2 = sigma_format({'type'=>'DECIMAL','decimals'=>2}, 'Years in Domo')
raise "got #{f2.inspect}" unless f2['decimalPlaces']==2
raise 'formatString leaked' if [f,f2].any? { |x| x.key?('formatString') }
puts 'test-sigma-format: PASS'
```
- [ ] **Step 2: Run → fails** (current returns `{kind:number, formatString:',.0f'}`).
- [ ] **Step 3: Implement** — rewrite `sigma_format` to return `{'kind'=>'number','decimalPlaces'=>prec}` for number/decimal/long/double; currency → Sigma currency format kind; percent → percent kind (keep `prec` from `precision`/`decimals`, default 0). Remove the d3 `fs` string. Keep the name-heuristic ONLY to pick currency-vs-percent-vs-number kind, not to build a format string.
- [ ] **Step 4: Run → PASS**; `ruby -c`. Also re-run the existing suite (build_kpi/measure_col consume this).
- [ ] **Step 5: Commit** — `git commit -m "fix(domo): sigma_format emits decimalPlaces (proven) not a d3 formatString"`

---

### Task 3: `kpi-chart` tag fix + Phase-5 geometry gate

**Files:** Modify `scripts/lib/layout.rb:388` (`kpi_like_zone?`); `scripts/build-workbook.rb` (add a geometry warning near the existing warns ~80-83). Create `test/test-layout-tag.rb`.

**Interfaces:** Consumes — cards carrying `x/y/w/h` (T1). Produces — `kpi_like_zone?` true for `chart_kind=='kpi-chart'`; a `$warnings` entry when a page's cards lack geometry.

- [ ] **Step 1: Failing test** — `test/test-layout-tag.rb`:
```ruby
require_relative '../scripts/lib/layout'
z = {'chart_kind'=>'kpi-chart','w'=>2,'h'=>1}
raise 'kpi-chart not detected as KPI-like' unless Layout.kpi_like_zone?(z)
puts 'test-layout-tag: PASS'
```
(If `kpi_like_zone?` is private, test via the smallest public entry that routes through it; adjust the call accordingly.)
- [ ] **Step 2: Run → fails** (`:388` checks `== 'kpi'`).
- [ ] **Step 3: Implement** — `lib/layout.rb:388`: accept both (`%w[kpi kpi-chart].include?(z['chart_kind'].to_s)`). In `build-workbook.rb`, after grouping cards by page, emit `warn_card(page-representative, "no grid geometry for page '<name>' — layout will fall back to a stack; ensure domo-discover captured x/y/w/h")` when a page's cards have no `x`/`y`. Ruby 2.6-safe.
- [ ] **Step 4: Run → PASS**; `ruby -c` both files.
- [ ] **Step 5: Commit** — `git commit -m "fix(domo): kpi-chart tag detected for KPI rows + warn on missing layout geometry"`

---

### Task 4: Inline data-URI image element

**Files:** Modify `scripts/build-workbook.rb` (add `build_image` + route image cards to it); `refs/card-to-element.md` (add an `image` row). Create `test/test-build-image.rb` + a tiny scrubbed PNG fixture `test/fixtures/domo-estate/logo.png`.

**Interfaces:** Consumes — an image card with a staged PNG path (`discovery/png/cards/<id>.png`, produced by capture-visuals via `render_card_png`). Produces — `build_image(card)` → `{ 'id'=>eid(card), 'kind'=>'image', 'url'=>"data:image/png;base64,<b64>" }`.

- [ ] **Step 1: Failing test** — `test/test-build-image.rb`:
```ruby
require 'base64'; require_relative '../scripts/build-workbook' rescue nil
png = File.join(__dir__,'fixtures','domo-estate','logo.png')
el = build_image({'id'=>'c9','title'=>'Logo','_pngPath'=>png})
raise 'not image kind' unless el['kind']=='image'
raise 'not data-uri png' unless el['url'].start_with?('data:image/png;base64,')
raise 'bytes mismatch' unless el['url'].sub('data:image/png;base64,','') == Base64.strict_encode64(File.binread(png))
puts 'test-build-image: PASS'
```
- [ ] **Step 2: Run → fails** (`build_image` undefined).
- [ ] **Step 3: Implement** — `build_image(card)` in `build-workbook.rb` mirroring tableau `build-charts-from-signals.rb:6655`: read `card['_pngPath']` (set by discover for image cards from the staged capture), `Base64.strict_encode64(File.binread(path))`, emit `{id,kind:'image',url:"data:image/png;base64,#{b64}"}`. Route cards whose `chartType` hints image/logo/drawing (substring) — or that have a staged PNG and no data columns — to `build_image` instead of the text fallback. Add the `image` row to `refs/card-to-element.md`'s card-type table. Ruby 2.6-safe.
- [ ] **Step 4: Run → PASS**; `ruby -c`.
- [ ] **Step 5: Commit** — `git commit -m "feat(domo): inline data-URI image element for image/logo cards (tableau pattern)"`

---

### Task 5: `migrate-domo.rb` orchestrator + offline 2D-grid E2E

**Files:** Create `scripts/migrate-domo.rb`, `test/test-migrate-domo.rb`, `test/fixtures/domo-estate/` (a scrubbed synthetic estate: pages w/ geometry, a KPI card, an image card, under a section header). Modify `.github/workflows/corpus-check.yml` (unit-tests allow-list).

**Interfaces:** Consumes — all prior tasks. Produces — a one-command Phase 1→6 driver; `--offline <fixtureDir>` runs the non-live phases (discover-from-fixture → build-workbook → build-workbook-spec → build-domo-layout → build-dashboard-layout → put-layout) and writes the final spec for assertion.

- [ ] **Step 1: Failing test** — `test/test-migrate-domo.rb`:
```ruby
require 'json'; require_relative 'helper' rescue nil
out = "/tmp/migrate-domo-#{Process.pid}"
system("ruby #{__dir__}/../scripts/migrate-domo.rb --offline #{__dir__}/fixtures/domo-estate --out #{out}") or abort 'orchestrator failed'
spec = JSON.parse(File.read("#{out}/workbook-spec.json"))
lay  = spec['layout'] || spec.dig('pages',0,'layout')
raise 'no layout (would stack)' if lay.nil? || lay.to_s.empty?
# 2D-grid, not a stack: the layout must express >1 column in at least one row
raise 'layout looks like a single-column stack' unless File.read("#{out}/layout-2d.flag") == 'grid'
# image element embedded inline
els = spec.dig('pages',1,'elements') || spec['pages'].flat_map{|p| p['elements']}
raise 'no inline image' unless els.any? { |e| e['kind']=='image' && e['url'].to_s.start_with?('data:image/png;base64,') }
puts 'test-migrate-domo: PASS'
```
(The orchestrator writes `layout-2d.flag` = `'grid'`/`'stack'` from `build-dashboard-layout`'s zone census — a cheap, deterministic 2D-vs-stack signal to assert on. Adjust the exact spec paths to what `build-workbook-spec.rb`/`put-layout.rb` actually emit.)
- [ ] **Step 2: Run → fails** (orchestrator missing).
- [ ] **Step 3: Implement** — `migrate-domo.rb` modeled on `migrate-tableau.rb`: OptionParser (`--offline DIR`/`--from DIR`/`--out DIR`/`--force`), a phase list run in order with a clear log + `run-state.json`, fail-fast. `--offline` skips live/private-API phases (reads the fixture as discovery output) and runs build→layout→put-layout locally, writing `workbook-spec.json` + `layout-2d.flag`. Live mode chains the full set incl. `post-and-readback`/`verify-parity`/`assert-phase6-ran` with creds via `get_token`. Pure Ruby, Windows-safe, idempotent (skip-if-present unless `--force`).
- [ ] **Step 4: Run → PASS** — the fixture yields a 2D-grid layout + an inline image. `ruby -c`.
- [ ] **Step 5: Wire CI** — add the 5 new `test/test-*.rb` paths to the `unit-tests` allow-list in `.github/workflows/corpus-check.yml`; `ruby -ryaml` parse-check.
- [ ] **Step 6: Commit** — `git commit -m "feat(domo): migrate-domo.rb turnkey orchestrator + offline 2D-grid E2E test + CI"`

---

### Task 6: SKILL.md turnkey rewrite + version bump

**Files:** Modify `SKILL.md` (Phase 4–6 prose), `.claude-plugin/plugin.json` (version).

- [ ] **Step 1: Check** — grep confirms SKILL.md still tells the agent to hand-chain `build-workbook-spec`/`put-layout` etc.; plugin.json version is `0.2.0`.
- [ ] **Step 2: Implement** — rewrite SKILL.md Phase 4–6 to lead with **`ruby scripts/migrate-domo.rb`** as the one-command turnkey path (the hand-chained scripts documented as its internals, not the operator's job); note the offline mode + the geometry/image/format guarantees. Bump `plugin.json` `0.2.0` → `0.3.0`.
- [ ] **Step 3: Verify** — `ruby tools/lint-skills.rb` green; grep shows the orchestrator is the documented entry.
- [ ] **Step 4: Commit** — `git commit -m "docs(domo): SKILL.md turnkey migrate-domo.rb path + bump plugin 0.2.0 -> 0.3.0"`

---

### Task 7: Final green-bar + PR

- [ ] `ruby tools/check-shared.rb` · `ruby tools/lint-skills.rb` · `bash tools/hygiene-sweep.sh` · `./corpus/run-corpus.sh --check` — all green.
- [ ] All new `test/test-*.rb` pass; `ruby -c` every changed `.rb`.
- [ ] Rebase onto latest `origin/main`; re-run green-bar.
- [ ] Push; open one-plugin PR. Body: turnkey orchestrator + 2D-grid layout + inline images + decimalPlaces; **offline-validated, live render deferred/not-claimed**; beads orchestrator/8t8x/l817/px3h; note PR-A (Date, mcp repo) + PR-B (vendor) follow.

## Self-Review

**Spec coverage:** geometry→discover (T1) ✓ · sigma_format→decimalPlaces (T2, l817) ✓ · kpi-chart tag + Phase-5 gate (T3, 8t8x) ✓ · inline data-URI image (T4, px3h) ✓ · orchestrator + offline 2D-grid E2E + CI (T5, orchestrator bead) ✓ · SKILL turnkey + bump (T6) ✓. Formula-vendoring correctly EXCLUDED (PR-B). Live render deferred (T7 PR note). No spec item unmapped.

**Placeholder scan:** each step has concrete code/commands + exact file:line anchors; the two "adjust to actual emitted spec paths" notes are calibration-against-real-output instructions (the implementer runs the scripts to see the shapes), not vague placeholders. Clean.

**Type consistency:** `merge_geometry` (T1), `sigma_format`→`{kind,decimalPlaces}` (T2), `kpi_like_zone?` (T3), `build_image`→`{id,kind:image,url:data-uri}` (T4), and the orchestrator's `workbook-spec.json`/`layout-2d.flag` outputs (T5) are referenced consistently across tasks. `_pngPath` (set in T1/T4 discovery, read in T4) is named identically.
