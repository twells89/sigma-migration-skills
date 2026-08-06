# Tableau Bug-Register Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the `tableau-to-sigma` skill defects that survived validation against v1.6.10, and correct the authoring docs that describe API behavior which no longer exists.

**Architecture:** Each task is an independent fix to one script, guarded by a deterministic offline `test-*.rb` regression test following the repo's existing convention (`ruby scripts/test-<name>.rb`, PASS/FAIL lines, non-zero exit on failure). Tasks are ordered cheapest-and-most-certain first. Two tasks (9, 10) are scoped as spec-first because they are behavioral and cannot be closed by static reasoning.

**Tech Stack:** Ruby (stdlib only — no gems), the packaged plugin layout `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/`, shared libs under `shared/lib/` synced by `tools/sync-shared.rb`.

## Global Constraints

- **Source of truth is `twells89/sigma-migration-skills`.** Edit the packaged layout `plugins/<tool>-to-sigma/skills/<skill>/scripts/`, never a flat legacy tree.
- **Work in an isolated git worktree.** Other sessions hold ~10 worktrees on this repo; `.git/HEAD` is shared.
- **Stage explicitly.** Never `git add -A` / `git commit -a` — other sessions' WIP is usually present.
- **Branch + PR for every change.** Do not push to `main`.
- **One PR touches either one plugin or `shared/`, never both** (shared-file governance).
- **Any change under `plugins/<x>/` requires a semver bump** in that plugin's `.claude-plugin/plugin.json`, or a `Skip-Version-Bump:` trailer.
- **A shared-file edit must be mirrored to every plugin copy** via `tools/sync-shared.rb`; the pre-commit hook fails otherwise. Check whether a script is shared **before** planning an edit to it — several phase-6 gate scripts exist in `shared/scripts/` and are vendored, so the plugin copy is not the place to change them.
- **Every gate must be proven to FAIL on a planted defect before it counts.** A gate that has never been seen red is not a gate.
- **A gate change that turns a `[SKIP]` into an `[OK]` is a defect until proven otherwise.** The output reads better than an honest abstention, so nothing prompts a second look.
- **`parity-final.json`'s `tile_census` key is reserved** for Tableau's dashboard-zone census (`zones_total`, `charts_built`, `zones_unmatched`, `unmatched_zone_names`). Any other shape under that key makes shared gate 5 report a vacuous `[OK]` over data it never measured. Before adding **any** field to `parity-final.json`, grep the shared gate for that key name — it reads far more of that document than the gate-1 contract.
- **A fix for one converter must not change behavior for the other twelve.** Most converters have no dashboard zone tree; their gate-5 `[SKIP]` is correct.
- **No real customer or test-org identifiers** in code, tests, fixtures, commit messages, or PR bodies. The pre-commit hygiene sweep enforces this and will reject tenant slugs and warehouse paths.
- Ruby is the system Ruby — **no endless-method syntax** (`def f(x) = …`); it fails to parse.

**Evidence base:** `docs/superpowers/specs/2026-08-05-bug-register-evidence-ledger.md`. Do not re-litigate verdicts; if a task's premise looks wrong, stop and flag it.

**Explicitly out of scope:**
- **K14** (`/spec/verify` bare body) — fix already exists in **unmerged PR #609**. Do not re-fix. Track that PR.
- **K1** — fixed in PR #598. **K13** — unverifiable, closed.
- All platform items (S-series) — those go to Sigma engineering, not here.

---

## Task 1: K11 — scrub subprocess output in the Phase-5b render threads

The Phase-5b visual-QA render calls `String#strip` and `each_line` on raw `Open3.capture2e` output. On Windows that output is not UTF-8, and `strip` raises `Encoding::CompatibilityError`, killing the render thread. The file already has the correct idiom at two other sites (`:1191`, `:2105`) — this site was missed.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/migrate-tableau.rb:5283-5285`
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-phase5b-encoding-scrub.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Write the failing test**

Create `test-phase5b-encoding-scrub.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K11: the Phase-5b visual-QA render threads must scrub
# non-UTF-8 subprocess output before calling String#strip / each_line.
# Deterministic + offline.

require 'json'
DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'Part A — source contract: the 5b render site scrubs before strip'
src  = File.read(File.join(DIR, 'migrate-tableau.rb'))
# The 5b block is identified by its unique export script + the strip call.
block = src[/sigma-export-png\.py.*?end\.each\(&:join\)/m].to_s
check(!block.empty?, 'located the Phase-5b render block', fails)
check(block.include?('force_encoding'),
      'Phase-5b block force_encodings subprocess output', fails)
check(block.match?(/\.scrub/),
      'Phase-5b block scrubs subprocess output', fails)
check(!block.match?(/(?<!scrub\()\bo\.strip\b/) || block.match?(/o\s*=\s*o\.force_encoding/),
      'no bare o.strip on unscrubbed output', fails)

puts 'Part B — behavioral: the shipped idiom survives invalid UTF-8'
raw = "ok\xFF\xFE bad\n".dup.force_encoding(Encoding::ASCII_8BIT)
scrubbed = raw.force_encoding(Encoding::UTF_8)
scrubbed = scrubbed.scrub('?') unless scrubbed.valid_encoding?
begin
  scrubbed.strip
  scrubbed.each_line { |l| l.rstrip }
  check(true, 'scrubbed output survives strip + each_line', fails)
rescue Encoding::CompatibilityError => e
  check(false, "scrubbed output still raises: #{e.class}", fails)
end

# Guard: prove the test would catch the defect — unscrubbed input MUST raise.
begin
  raw.force_encoding(Encoding::UTF_8).strip =~ / /
  check(false, 'PLANTED-DEFECT GUARD: unscrubbed input should have raised', fails)
rescue ArgumentError, Encoding::CompatibilityError
  check(true, 'PLANTED-DEFECT GUARD: unscrubbed input raises as expected', fails)
end

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-phase5b-encoding-scrub.rb
```

Expected: FAIL on "Phase-5b block force_encodings subprocess output" and "Phase-5b block scrubs subprocess output". This is the planted-defect proof for this gate — record the red output.

- [ ] **Step 3: Apply the fix**

In `migrate-tableau.rb`, replace lines 5283-5285:

```ruby
      vqa_mx.synchronize do
        o.each_line { |l| puts "   #{l.rstrip}" } unless o.strip.empty?
```

with:

```ruby
      o = o.force_encoding(Encoding::UTF_8)
      o = o.scrub('?') unless o.valid_encoding?
      vqa_mx.synchronize do
        o.each_line { |l| puts "   #{l.rstrip}" } unless o.strip.empty?
```

- [ ] **Step 4: Run test to verify it passes**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-phase5b-encoding-scrub.rb
```

Expected: `ALL PASS`.

- [ ] **Step 5: Bump version and commit**

Bump `plugins/tableau-to-sigma/.claude-plugin/plugin.json` to `1.6.11`.

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/migrate-tableau.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-phase5b-encoding-scrub.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): scrub non-UTF-8 subprocess output in Phase-5b render threads (K11)"
```

---

## Task 2: K3 — text element ids collide across pages

`seen_el_ids` namespacing (`build-charts-from-signals.rb:8382`) rewrites duplicate element ids, but the page is assembled as `page_extras + els` (`:8415`) and only `els` passes through it. Styled text elements are appended to `page_extras` at `:8336` with ids of the form `text-<tableau zone id>`. Tableau zone ids are unique per dashboard, not globally, so the same id ships on multiple pages and the POST fails on duplicate ids.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb:8378-8415`
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-page-extras-id-namespacing.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

Create `test-page-extras-id-namespacing.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K3: element ids in page_extras (styled text, title text,
# images) must go through the same cross-page namespacing as `els`, or a
# Tableau zone id reused on a second dashboard ships a duplicate Sigma id.

require 'json'
DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'Part A — source contract'
src = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
check(src.match?(/namespace_ids\.call\(page_extras/),
      'page_extras is passed through the namespacing helper', fails)
check(!src.match?(/'elements' => page_extras \+ els\b(?!.*namespace)/m),
      'page assembly no longer concatenates un-namespaced page_extras', fails)

puts 'Part B — behavioral: replicate the shipped op across two pages'
seen = {}
namespace_ids = lambda do |list, slug|
  list.map do |el|
    stem = el['id']
    if stem && seen[stem]
      JSON.parse(el.to_json.gsub(stem, "#{stem}-#{slug}"))
    else
      seen[stem] = true if stem
      el
    end
  end
end

page1 = namespace_ids.call([{ 'id' => 'text-550', 'kind' => 'text', 'body' => 'A' }], 'dash-one')
page2 = namespace_ids.call([{ 'id' => 'text-550', 'kind' => 'text', 'body' => 'B' }], 'dash-two')

check(page1[0]['id'] == 'text-550', 'first occurrence keeps its id', fails)
check(page2[0]['id'] == 'text-550-dash-two', 'second occurrence is namespaced', fails)
all_ids = (page1 + page2).map { |e| e['id'] }
check(all_ids.uniq.size == all_ids.size, 'ids are globally unique across pages', fails)

# Planted-defect guard: without namespacing the ids MUST collide.
naive = [{ 'id' => 'text-550' }, { 'id' => 'text-550' }].map { |e| e['id'] }
check(naive.uniq.size != naive.size,
      'PLANTED-DEFECT GUARD: un-namespaced ids do collide', fails)

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-page-extras-id-namespacing.rb
```

Expected: FAIL on both Part A checks (Part B passes — it tests the helper's logic, which is correct; the bug is that `page_extras` never reaches it). Record the red output.

- [ ] **Step 3: Extract the namespacing into a reusable lambda**

In `build-charts-from-signals.rb`, the existing block at `:8382` is `els.map! do |el| … end`. Replace that block's opening line and the page assembly so both lists share one helper. Immediately before `els.map! do |el|`, insert:

```ruby
    # K3: page_extras (styled text, title text, images) carry Tableau zone ids,
    # which are unique per dashboard but NOT globally. They must run through the
    # same namespacing as `els` or a zone id reused on a second dashboard ships
    # a duplicate Sigma element id and the POST hard-fails.
    namespace_ids = lambda do |list|
      list.map do |el|
        stem = el['id']
        next el unless stem
        if seen_el_ids[stem]
          ns = "#{stem}-#{d_slug[0..20]}"
          ($hidden_title_ns_ids ||= []) << ns if ($hidden_title_ids || []).include?(stem)
          if (pv = $chart_provenance[stem])
            $chart_provenance[ns] = pv.merge('dashboard' => dash_name)
          end
          JSON.parse(el.to_json.gsub(stem, ns))
        else
          seen_el_ids[stem] = true
          el
        end
      end
    end
```

- [ ] **Step 4: Route page_extras through it**

Replace line 8415:

```ruby
    page = { 'name' => dash_name, 'elements' => page_extras + els }
```

with:

```ruby
    page = { 'name' => dash_name, 'elements' => namespace_ids.call(page_extras) + els }
```

`els` keeps its existing `els.map!` block — that block already handles the `source.elementId` restoration that top-N helpers need, which `page_extras` elements never have.

- [ ] **Step 5: Run test to verify it passes**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-page-extras-id-namespacing.rb
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-element-id-namespacing.rb
```

Expected: both `ALL PASS`. The second is the pre-existing test — it must not regress.

- [ ] **Step 6: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-page-extras-id-namespacing.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): namespace page_extras element ids across pages (K3)"
```

---

## Task 3: K7 + N1 — emit the current image element shape

**Validated finding, and it inverts the original diagnosis.** `data:` URIs are *not* rejected — live probing shows both a hosted URL and a `data:` URI validate. What the API now rejects is the **flat `url:` shape**, for every image. The skill emits exactly that shape, so *all* image elements fail, not just logos.

Live evidence:

```
{kind: image, url: "https://…"}                    → 400 Invalid kind: "image"
{kind: image, source: {kind: url, url: "https://…"}} → valid:true
{kind: image, source: {kind: url, url: "data:image/png;base64,…"}} → valid:true
```

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb:6684`
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb:6603` (stale comment)
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-image-element-shape.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: image elements shaped `{id, kind: "image", source: {kind: "url", url: <string>}}`.

- [ ] **Step 1: Write the failing test**

Create `test-image-element-shape.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K7/N1: image elements must use the nested source shape.
# The flat {kind: image, url: ...} shape is rejected by the live API with
# `Invalid kind: "image"` for EVERY image, hosted or data: URI
# (live-probed 2026-08-05).

DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

src = File.read(File.join(DIR, 'build-charts-from-signals.rb'))

puts 'Part A — no flat url: image elements are emitted'
flat = src.scan(/\{[^{}]*'kind'\s*=>\s*'image'[^{}]*\}/m)
       .reject { |m| m.include?("'source'") }
       .reject { |m| m.include?('_test') }
check(flat.empty?,
      "no flat {kind: image, url: ...} emission sites (found #{flat.size})", fails)

puts 'Part B — the nested shape is emitted'
check(src.match?(/'kind'\s*=>\s*'image'.*?'source'\s*=>\s*\{\s*'kind'\s*=>\s*'url'/m),
      'image elements carry source: {kind: url, url: ...}', fails)

puts 'Part C — the stale "data URIs live-verified" comment is corrected'
check(!src.include?('data URIs live-verified'),
      'stale data-URI comment removed (the shape, not the URI scheme, was the bug)', fails)

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-image-element-shape.rb
```

Expected: FAIL on Part A (one flat site at `:6684`), Part B, and Part C. Record the red output.

- [ ] **Step 3: Fix the emission site**

Replace line 6684:

```ruby
        { 'id' => "img-#{z['id']}", 'kind' => 'image', 'url' => url, '_dashboard' => dash['dashboard'] }
```

with:

```ruby
        { 'id' => "img-#{z['id']}", 'kind' => 'image',
          'source' => { 'kind' => 'url', 'url' => url },
          '_dashboard' => dash['dashboard'] }
```

- [ ] **Step 4: Correct the stale comment**

Replace the comment at `:6602-6603`:

```ruby
# and emit {kind:"image", url:"data:image/…;base64,…"} (data URIs live-verified
# — refs/workbook-layout.md). Zones with a web-hosted `image_file_url` use the
```

with:

```ruby
# and emit {kind:"image", source:{kind:"url", url:"data:image/…;base64,…"}}.
# The URL may be a data: URI or a hosted URL — both validate (live-probed
# 2026-08-05). What the API rejects is the FLAT `url:` shape, for every image;
# the nested `source` wrapper is mandatory. Zones with a hosted `image_file_url` use the
```

- [ ] **Step 5: Run test to verify it passes**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-image-element-shape.rb
```

Expected: `ALL PASS`.

- [ ] **Step 6: Check the page-level backgroundImage sibling**

`page['backgroundImage']` at `:8423` uses `{ 'url' => …, 'style' => … }`. Per prior live findings, `backgroundImage` must be a **sibling of** `style`, not nested — and its own shape may have moved to `source.kind=url` alongside the image element. Verify against a live GET-back before changing it. If a live check is not available in this session, leave it and record the open question in the PR body. **Do not change it on inference.**

- [ ] **Step 7: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-image-element-shape.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): emit the nested image source shape; flat url: is rejected (K7/N1)"
```

---

## Task 4: K2 — page-id slug leaves punctuation intact

The `controlId` paths are clean — every one uses `.downcase.gsub(/\W+/, '-')`, which strips `?`. The same class of gap survives in the **page id** slug, which replaces only `/ ( ) %` and space. A Tableau page named `How many weeks?` yields `page-how-many-weeks?`.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-workbook-spec.rb:171-173`
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-page-id-slug.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: page ids matching `/\Apage-[a-z0-9-]*\z/`.

- [ ] **Step 1: Write the failing test**

Create `test-page-id-slug.rb`:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K2: page ids must contain only [a-z0-9-]. The old slug
# replaced a hand-listed set (/ ( ) %) and space, leaving ? ! # & etc. intact.

DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Mirror of the shipped slug op (keep in lock-step with build-workbook-spec.rb).
def page_slug(name)
  name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').sub(/\A-/, '').sub(/-\z/, '')[0..40].to_s
end

puts 'Part A — punctuation is stripped'
{
  'How many weeks?'          => 'how-many-weeks',
  'Sales (YTD) / Region'     => 'sales-ytd-region',
  'Margin % & Growth!'       => 'margin-growth',
  'Q1 2026 — Overview'       => 'q1-2026-overview',
  'Trailing 30d #1'          => 'trailing-30d-1'
}.each do |input, want|
  got = page_slug(input)
  check(got == want, "#{input.inspect} -> #{got.inspect} (want #{want.inspect})", fails)
end

puts 'Part B — output charset is safe for every input'
['A?B', 'x' * 80, '///', 'Ünïcodé Pagé'].each do |input|
  got = page_slug(input)
  check(got.match?(/\A[a-z0-9-]*\z/), "#{input.inspect} -> #{got.inspect} is [a-z0-9-] only", fails)
end

puts 'Part C — the shipped source uses the safe slug'
src = File.read(File.join(DIR, 'build-workbook-spec.rb'))
check(src.match?(/gsub\(\/\[\^a-z0-9\]\+\/, '-'\)/),
      'build-workbook-spec.rb uses an allow-list slug', fails)
check(!src.include?("%w[ / ( ) %].each"),
      'the hand-listed deny-list is gone', fails)

puts 'Part D — planted-defect guard'
old_slug = lambda do |name|
  s = name.to_s.downcase
  %w[/ ( ) %].each { |ch| s = s.tr(ch, '-') }
  s.tr(' ', '-').gsub(/-+/, '-').sub(/^-/, '').sub(/-$/, '')[0..40]
end
check(old_slug.call('How many weeks?').include?('?'),
      'PLANTED-DEFECT GUARD: the old slug does leak "?"', fails)

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-page-id-slug.rb
```

Expected: Part C FAILs. Part D must PASS — it proves the test discriminates. Record the red output.

- [ ] **Step 3: Apply the fix**

Replace lines 171-173:

```ruby
    slug = p['name'].to_s.downcase
    %w[ / ( ) %].each { |ch| slug = slug.tr(ch, '-') }
    slug = slug.tr(' ', '-').gsub(/-+/, '-').sub(/^-/, '').sub(/-$/, '')[0..40]
```

with:

```ruby
    # K2: allow-list, not deny-list. The old hand-listed set (/ ( ) %) plus
    # space left ? ! # & and every other punctuation mark in the id, which
    # Sigma rejects.
    slug = p['name'].to_s.downcase.gsub(/[^a-z0-9]+/, '-')
                    .sub(/\A-/, '').sub(/-\z/, '')[0..40].to_s
```

- [ ] **Step 4: Run test to verify it passes**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-page-id-slug.rb
```

Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-workbook-spec.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-page-id-slug.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): allow-list the page-id slug so punctuation cannot leak (K2)"
```

---

## Task 5: K6 — cap the phase-6 verdict when Tableau emits no tile census

K6 is the escape where two dashboard tiles were silently dropped and parity still reported PASS — every chart the plan knew about passed, it just didn't know about the dropped ones. Gate 5 exists to catch exactly that, and it currently `[SKIP]`s whenever `tile_census` is absent.

> **⚠️ READ THIS BEFORE TOUCHING THE GATE — two constraints that were wrong in the first draft of this plan.**
>
> **1. The gate is a SHARED file, not a plugin file.** The canonical copy is `shared/scripts/assert-phase6-ran.rb` (~254KB), vendored into all 13 plugins. Editing the plugin copy directly fails the shared-lib drift gate. Edit canonical → run `tools/sync-shared.rb` → **this PR touches `shared/` ONLY**, never `shared/` and a plugin together.
>
> **2. The SKIP is CORRECT for every converter except Tableau. Do not make it fail closed globally.** Gate 5 reads a Tableau *dashboard-zone* census. Domo, Looker, Power BI, Qlik and the rest have no zone tree, so their `[SKIP]` is an honest abstention — capping them would break 12 converters to fix one. The cap must be scoped to runs that genuinely can produce a zone census.
>
> **3. The `tile_census` key is RESERVED and its shape is load-bearing.** Gate 5 does `census = summary['tile_census']` and, whenever the key is present, reads `zones_total`, `charts_built`, `zones_unmatched`, `unmatched_zone_names`. Publish any other shape there and every field comes back `nil.to_i` → `0`, `unmatched(0) > allow_missing_tiles(0)` is false, and the gate prints `[OK] gate 5/7: tile census — 0 zones, 0 charts built, 0 unmatched` — a gate that was correctly abstaining now reports success it never measured. This exact mistake was made and caught in review on the Domo parity census (PR #631); the fix there was to publish under a separate key (`parity_tile_census`). **Do not widen, rename, or alias this shape.**
>
> **4. If your change turns a `[SKIP]` into an `[OK]`, treat it as a defect until proven otherwise.** The output reads *better* than the honest skip, so nothing prompts you to look.

Precedent to mirror: the gate-3 column audit in PR #595 (`a SKIPped gate-3 column audit is recorded and caps at YELLOW`). Follow it rather than inventing a parallel mechanism.

**Files:**
- Read first: `shared/scripts/assert-phase6-ran.rb:1627-1670` (gate 5) and the gate-3 skip/degradation-ledger handling from PR #595
- Modify: `shared/scripts/assert-phase6-ran.rb` — the gate-5 branch and its header comment at `:21-26`
- Modify: `shared/scripts/test-assert-phase6-gates.rb` (or the canonical test alongside it)
- Then: `ruby tools/sync-shared.rb` to fan out to all 13 plugin copies

**Interfaces:**
- Consumes: `parity-final.json`'s `tile_census`, whose reserved shape is
  `{zones_total:, charts_built:, zones_unmatched:, unmatched_zone_names:}` — unchanged by this task.
- Produces: for a Tableau run that could have emitted a census but didn't, a **capped** (never GREEN) verdict recorded in the degradation ledger. For every other converter, the existing honest `[SKIP]` is **unchanged**.

- [ ] **Step 1: Read both precedents**

```bash
sed -n '1627,1670p' shared/scripts/assert-phase6-ran.rb
git show 1f9d8b77 -- shared/scripts/assert-phase6-ran.rb
git show --stat 631 2>/dev/null || gh pr view 631
```

- [ ] **Step 2: Decide the Tableau-scoped predicate**

You need a signal for "this run could have produced a zone census." Do **not** invent a new sidecar. The gate already computes an equivalent signal near `:2440`/`:2501` — `dashboard-layout.json` present, or a `tile_census` landed. Reuse that, or the presence of the Tableau workdir markers the gate already reads. Whatever you pick, it must be false for a Domo/Looker/PBI run.

Write the predicate down in the PR body before coding it — if you can't state it in one sentence, it's wrong.

- [ ] **Step 3: Write the failing test — BOTH directions**

Add two cases to the gate test. Both are required; the first alone would let a global cap through.

1. **Tableau-shaped run, no `tile_census`** → verdict is capped (not GREEN) and the skip is recorded in the degradation ledger.
2. **Non-Tableau run, no `tile_census`** → still prints the honest `[SKIP] gate 5/7` and the verdict is **not** capped.

Add a third guard case that pins the reservation:

3. **A foreign shape published under `tile_census`** (e.g. `{"cards_total": 36}`) → the gate must **not** print `[OK] … 0 zones, 0 charts built, 0 unmatched`. This is the PR #631 regression; without it, the vacuous-OK path stays open.

Follow the file's existing fixture style — build the fixture inline, call the gate, assert on its output.

- [ ] **Step 4: Run tests to verify they fail**

```bash
ruby shared/scripts/test-assert-phase6-gates.rb
```

Expected: cases 1 and 3 FAIL; case 2 PASSES (it already behaves correctly — it is there to stop you from over-fixing). **Record the red output; this is the planted-defect proof for this gate.**

- [ ] **Step 5: Apply the fix**

Change only the `census.nil?` branch: when the Tableau-scoped predicate is true, record a skip in the degradation ledger and cap the verdict as gate 3 does; otherwise keep the existing `[SKIP]` line verbatim. Leave the `else` branch — the field reads at `:1636-1640` — untouched.

Update the header comment at `:21-26`: the current "Skipped (with a note) when the converter doesn't emit a census" becomes wrong for Tableau the moment this lands, and must state the reserved shape and the converter scoping.

- [ ] **Step 6: Run tests to verify they pass, then sync**

```bash
ruby shared/scripts/test-assert-phase6-gates.rb
ruby tools/sync-shared.rb
git status --short   # expect: shared/ + all 13 vendored copies, no plugin-only edits
```

Expected: `ALL PASS`, and the drift gate clean.

- [ ] **Step 7: Re-run the other converters' gate tests**

A shared-gate change is a 13-plugin change. Spot-check at least Domo and one other that legitimately has no zone tree, to confirm their `[SKIP]` is intact.

- [ ] **Step 8: Commit — shared only, all 13 copies, every plugin bumped**

Stage the canonical file, its test, and the synced copies. Per the version-bump gate, a change reaching all 13 plugins bumps **all 13** `plugin.json` versions.

```bash
git add shared/scripts/assert-phase6-ran.rb \
        shared/scripts/test-assert-phase6-gates.rb \
        plugins/*/skills/*/scripts/assert-phase6-ran.rb \
        plugins/*/skills/*/scripts/test-assert-phase6-gates.rb \
        plugins/*/.claude-plugin/plugin.json
git commit -m "fix(shared): a missing Tableau tile census caps the phase-6 verdict; other converters still SKIP honestly (K6)"
```

Do **not** fold any other task's plugin-only change into this commit — mixing `shared/` with a plugin fix breaks the one-PR-one-surface rule.

---

## Task 6: K12(a) — the join-key export poll is too short for a cold warehouse

`probe-join-keys.rb` polls with `sleep(i.zero? ? 0.5 : 1)` and no generous ceiling. A cold warehouse exceeds the budget and the probe reports failure for a query that would have succeeded. The register's operator hot-fixed this locally to 180s; that fix was never upstreamed.

Sub-claims K12(b) `sqlproxy` right_table, (c) re-entry wiping probe evidence, and (d) the identifier oracle refusing quoted mixed-case keys are **not** covered here — they need a live run and are folded into Task 9.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/probe-join-keys.rb:~215`
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-probe-join-keys-poll.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: an export poll bounded by `PROBE_EXPORT_TIMEOUT_S` (default 180), overridable by env.

- [ ] **Step 1: Read the current poll loop**

```bash
sed -n '200,235p' plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/probe-join-keys.rb
```

Identify the loop bound. The fix must make the **total wall-clock budget** explicit rather than relying on an iteration count.

- [ ] **Step 2: Write the failing test**

Create `test-probe-join-keys-poll.rb` asserting:
- the source defines `PROBE_EXPORT_TIMEOUT_S` with a default of `180`
- the default is honoured when the env var is unset
- the env var overrides it
- the loop is bounded by elapsed wall-clock, not a bare iteration count

Include a planted-defect guard: assert that a 30-second budget would expire before a simulated 60-second cold export, proving the test discriminates between the old and new bounds.

- [ ] **Step 3: Run test to verify it fails**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-probe-join-keys-poll.rb
```

Expected: FAIL — no such constant exists. Record the red output.

- [ ] **Step 4: Apply the fix**

Introduce near the top of `probe-join-keys.rb`:

```ruby
# K12(a): a cold warehouse routinely exceeds a short export poll. Bound the
# wait by wall-clock, not iteration count, and let an operator raise it.
PROBE_EXPORT_TIMEOUT_S = Integer(ENV.fetch('PROBE_EXPORT_TIMEOUT_S', '180'))
```

Rewrite the poll loop to exit on `Time.now - started > PROBE_EXPORT_TIMEOUT_S`, keeping the existing backoff. On timeout, emit a message naming the elapsed budget and the override env var, so the operator can tell a slow warehouse from a broken probe.

- [ ] **Step 5: Run test to verify it passes**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-probe-join-keys-poll.rb
```

Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/probe-join-keys.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-probe-join-keys-poll.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): bound the join-key export poll by wall-clock, default 180s (K12a)"
```

---

## Task 7: K9/K20/S11 — the supersession is backwards; teach the lint about booleans

**Read this before touching anything.** This item flip-flopped once and the flip was wrong.

`VERIFIED-FINDINGS-2026-08-06.md` §"THE K9 SUPERSESSION IS BACKWARDS" ran a controlled,
rendered A/B: one identical boolean-typed warehouse column (`/columns` → `type: boolean`),
four tiles, the ONLY difference being the `values` array of a `kind: list` element filter.

| Filter values | Rendered |
|---|---|
| `[true]` — JSON boolean | **13 rows, correct** |
| `["true"]` — string | **0 rows, "No data"** |
| `["True"]` — cased string | **0 rows, "No data"** |
| `[1]` — numeric | **0 rows, "No data"** |

All four passed `spec/verify`. So:

- **K9's original diagnosis was right** and **K9's original fix (JSON booleans) was correct.**
- **The K20/S11 supersession — "JSON booleans render 'Invalid filter' / blank the tile" — does
  NOT reproduce.** S11 also failed to reproduce independently, in two constructions including
  the converter's exact emission, and its companion claim that `/export` returns UNFILTERED
  rows on a bad filter measured false.
- `Text(col)` + `["true"]` also works, but only because BOTH halves are applied. It is *a*
  working combination, not *the* required one. The customer's 46-filter `Text()` rewrite is a
  working-but-unnecessary detour whose stated justification does not hold up.

**Therefore this task must NOT tell anyone to prefer string values, must NOT repeat the
supersession as fact, and must NOT change the three JSON-boolean emission sites** in
`build-charts-from-signals.rb` (`:5325-5329`, `:5480-5486`, `:7385-7395`) — those are
measured-correct. It must also not revert the customer-side rewrite.

**The two real, measured gaps** (both confirmed by reading the code, not inferred):

1. `lib/typed_literal_lint.rb`'s `type_category` returns only `:numeric`, `:temporal`, `:text`.
   There is **no `:boolean` case**, and `grep -i bool` over the file is empty — so the lint
   *silently skips every boolean column*. A gate written today would be a **false pass**, the
   exact defect class the standing rule forbids.
2. The lint IS wired (`migrate-tableau.rb:4271`) but only over **`dm_spec_path`** — the DATA
   MODEL spec. The boolean list filters in question live on **workbook elements**
   (`build-charts-from-signals.rb` output), which the lint has never once seen.

**Still unexplained (do NOT close this):** none of the four measured variants produced the
customer's screenshot error **"Invalid Argument / Request format or values are invalid"**.
That is a third, distinct failure class from both "Invalid filter" and "No data", and it
remains unreproduced. It needs the actual failing element JSON.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/typed_literal_lint.rb`
  (this is the module — `lint-typed-literals.rb` is only a CLI wrapper with no
  `__FILE__ == $PROGRAM_NAME` guard; `require_relative`-ing it from a test hard-`exit 2`s the
  test process, and its real signature is `TypedLiteralLint.lint(spec, types)`, two args)
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lint-typed-literals.rb`
  (final summary line only)
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/migrate-tableau.rb`
  (add the workbook-spec pass)
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb`
  (**comment only**, `:6030-6031`)
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-typed-literal-lint.rb`
- Read only, do NOT modify: the three boolean emission sites and the two string sites
  (`:6032-6037`, `:6155-6164`)

**Interfaces:**
- Consumes: unchanged — `TypedLiteralLint.lint(spec, types)`.
- Produces: findings on boolean-typed columns filtered with non-boolean literals, suggesting
  the coerced JSON-boolean array. Stays **ADVISORY** (WARN, never fatal), matching the
  existing documented corpus-safety policy at `migrate-tableau.rb:4232-4235`. Do not make it
  blocking in this task.

- [ ] **Step 1: Write the failing checks**

Insert into `test-typed-literal-lint.rb` immediately **before** the
`# --- CLI: exit codes 0 / 3 / 2 ---` block (the file ends in `exit 0`/`exit 1`; anything
appended after that is dead code):

```ruby
# --- BOOLEAN columns: only JSON booleans filter them (K9, measured 2026-08-06) --
# One identical boolean warehouse column, four rendered tiles, only the `values`
# array varying: [true] -> 13 rows correct; ["true"] / ["True"] / [1] -> 0 rows
# "No data". All four passed spec/verify, so nothing else catches this.
bool_types = { 'T' => { 'IS_ACTIVE' => 'BOOLEAN' } }
def bool_filter_spec(values)
  spec_with(
    'columns' => [{ 'id' => 'c-b', 'name' => 'Is Active' }],
    'filters' => [{ 'id' => 'flt-b', 'columnId' => 'c-b', 'kind' => 'list',
                    'mode' => 'include', 'values' => values }]
  )
end
f = TypedLiteralLint.lint(bool_filter_spec(['true']), bool_types)
check(f.length == 1 && f[0]['suggestion'] == 'values: [true]',
      "string \"true\" on a BOOLEAN column is flagged, suggestion is the JSON boolean " \
      "(got #{f.map { |x| x['suggestion'] }.inspect})", fails)
f = TypedLiteralLint.lint(bool_filter_spec(['True']), bool_types)
check(f.length == 1, 'cased string "True" on a BOOLEAN column is flagged too', fails)
f = TypedLiteralLint.lint(bool_filter_spec([1]), bool_types)
check(f.length == 1 && f[0]['suggestion'] == 'values: [true]',
      "numeric 1 on a BOOLEAN column is flagged (got #{f.inspect[0, 120]})", fails)
# PLANTED-DEFECT GUARD, both directions. This is the assertion that must never
# be inverted: the JSON boolean is the MEASURED-CORRECT shape. A future edit that
# "fixes" boolean filters back to string values makes the checks above pass for
# the wrong reason and this one fail.
f = TypedLiteralLint.lint(bool_filter_spec([true]), bool_types)
check(f.empty?, "JSON boolean [true] on a BOOLEAN column is CLEAN (got #{f.inspect[0, 160]})", fails)
f = TypedLiteralLint.lint(bool_filter_spec([true, false]), bool_types)
check(f.empty?, 'JSON booleans [true, false] are clean', fails)
# No false positives: a TEXT column keeps its string values (this is what the
# converter's own top-N/wildcard keep-flag columns emit, and it is type-correct).
f = TypedLiteralLint.lint(bool_filter_spec(['keep']), 'T' => { 'IS_ACTIVE' => 'varchar(8)' })
check(f.empty?, 'string values on a TEXT column are NOT flagged (top-N keep-flag shape)', fails)
# Unknown/unmapped type -> skipped, never guessed (anti-overfit rule).
f = TypedLiteralLint.lint(bool_filter_spec(['true']), {})
check(f.empty?, 'a column absent from the type map is skipped, not guessed', fails)

```

- [ ] **Step 2: Confirm RED**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-typed-literal-lint.rb
```

Expected, measured against the current tree: **3 FAILURES** — the three non-boolean-literal
cases report `got []`, i.e. the lint currently sees nothing at all on a boolean column. The
four "clean" checks pass *vacuously* before the fix; that is why the three positive checks
are the RED signal and must be recorded.

- [ ] **Step 3: Add the `:boolean` type category**

In `lib/typed_literal_lint.rb`, `type_category`:

```ruby
    when 'text', 'string', 'varchar', 'char', 'character', 'character varying'
      :text
    when 'boolean', 'bool'
      :boolean
    end
  end
```

- [ ] **Step 4: Add the boolean arm to `scan_element_filters`**

Append a `when :boolean` arm to the `case entry[:cat]` in `scan_element_filters`, after the
existing `when :temporal` block:

```ruby
      when :boolean
        # MEASURED 2026-08-06 (rendered; one identical boolean warehouse column,
        # only the `values` array varied): [true] -> 13 rows, correct;
        # ["true"] / ["True"] / [1] -> 0 rows, "No data". All four passed
        # spec/verify, so nothing upstream catches this — the tile just renders
        # empty. Only JSON booleans filter a boolean-typed column. The register
        # entry claiming the opposite (JSON booleans -> "Invalid filter") did
        # NOT reproduce; do not invert this rule without a new measurement.
        bad = vals.reject { |v| v == true || v == false || v.nil? }
        next if bad.empty?
        coerced = vals.map do |v|
          case v.to_s.strip.downcase
          when 'true', 't', '1'  then true
          when 'false', 'f', '0' then false
          else v
          end
        end
        bad.each do |lit|
          findings << finding(owner, cap("filter values: #{vals.inspect} on #{ref_tok}"),
                              entry, lit, "values: #{coerced.inspect}")
        end
```

Also extend the file-header DETECTION note so it stops claiming numeric/temporal are the only
flagged categories:

```
#   Flags: NUMERIC column vs quoted numeric string ("2014" → drop the quotes);
#   TEMPORAL column vs quoted BARE YEAR 1000–2999 ("2015" →
#   DatePart("year", [Date]) = 2015); BOOLEAN column vs any non-boolean list
#   value ("true"/"True"/1 → [true]) — measured 2026-08-06: string/numeric
#   values against a boolean column pass spec/verify and render ZERO rows.
```

- [ ] **Step 5: Correct the CLI summary line and one stale in-code comment**

`lint-typed-literals.rb`, final `warn` — the boolean class renders zero rows, not NULL:

```ruby
warn "typed-literal lint: #{findings.size} finding(s) — these comparisons compile clean and " \
     'render NULL for every affected measure (the 2026-07-13 blanking class), or silently ' \
     'filter to ZERO ROWS (boolean column vs a string/numeric literal, measured 2026-08-06)'
```

`build-charts-from-signals.rb:6030-6031` currently reads:

```ruby
          # Text (not boolean) keep flag: live probes reject non-string list
          # filter values (Text() casting rule, sigma ground truth §E.10).
```

The **conclusion** at that site is right (that column really is text — `If(..., "keep", "cut")`
— so string values are type-correct) but the stated **rule** is measured false and is exactly
what would mislead the next maintainer into "fixing" the boolean sites. Replace with:

```ruby
          # Text keep flag: this helper column IS text (If(...,"keep","cut")), so
          # its list-filter values are strings. NOTE: there is no general
          # "Sigma rejects non-string filter values" rule — measured 2026-08-06,
          # a BOOLEAN column requires JSON boolean values and silently returns
          # zero rows for ["true"]. Match the value type to the COLUMN type.
```

Leave `:7404`'s "sanctioned workaround" comment as-is; it is accurate.

- [ ] **Step 6: Run the lint over the WORKBOOK spec, not just the data model**

The boolean list filters this whole item is about are workbook-element filters and the lint
has never seen them. In `migrate-tableau.rb`, immediately after the `wb_spec_path` write block
(the `if MANUAL_JSON_SPECS … else File.write(wb_spec_path, …) end` at ~`:4820-4828`) and
before the validate/post calls at ~`:4917`, add a second pass that reuses the type map the DM
pass already wrote:

```ruby
# W2.2 second pass (K9): the DM pass above lints dm-spec.json only. Boolean/
# numeric list filters live on WORKBOOK elements (build-charts-from-signals),
# which the lint had never seen. Same conservative core, same ADVISORY policy —
# reuse the type map the DM pass wrote; skip silently if it does not exist.
begin
  _tl_types_path = File.join(WORK, 'typed-literal-types.json')
  if File.exist?(_tl_types_path)
    _tlw_out = File.join(WORK, 'typed-literal-findings-wb.json')
    _, _tlw_st = run!(['ruby', File.join(HERE, 'lint-typed-literals.rb'),
                       '--spec', wb_spec_path, '--types', _tl_types_path, '--out', _tlw_out],
                      allow_fail: true)
    if _tlw_st.exitstatus == 3
      _tlw_n = ((JSON.parse(File.read(_tlw_out)).length rescue nil) || '?')
      line "WARN: typed-literal lint (WORKBOOK spec): #{_tlw_n} finding(s) (printed above;"
      line "      #{_tlw_out}) — a boolean column filtered with string/numeric values passes"
      line '      spec/verify and renders ZERO rows (measured 2026-08-06). Fix per the printed'
      line '      suggestions before gate 13 measures the empty tiles they cause.'
    elsif _tlw_st.success?
      line 'typed-literal lint (WORKBOOK spec): clean (0 findings)'
    end
  end
rescue StandardError => e
  line "WARN: typed-literal workbook lint failed (#{e.class}: #{e.message.to_s[0, 80]}) — advisory"
end
```

- [ ] **Step 7: Confirm GREEN and no regressions**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-typed-literal-lint.rb
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-typed-literal-wiring.rb
```

Both must be `ALL PASS`. (Verified offline while drafting this task: with only the
`type_category` + `when :boolean` edits, the RED checks above go green and every pre-existing
assertion in `test-typed-literal-lint.rb` — including the CLI exit-code block — still passes.)

- [ ] **Step 8: Record what is STILL open, then commit**

In the PR body, state plainly:
- JSON boolean `[true]` is the measured-correct shape for a boolean-typed column; the
  register's contrary claim is unreproduced and `BUGS-global.md` K9/K20/S11 plus
  `LESSONS-LEARNED.md` §5's S11 row are stale (mark them superseded — do not delete them).
- The three JSON-boolean emission sites were deliberately NOT changed.
- **Known coverage limit:** the lint resolves a filter's column type only through a bare-ref
  formula or a formula-less column's name. The converter's own boolean filters sit on
  `IsNotNull(...)` **computed** columns, which the existing (deliberate) "computed column →
  skip, no guessing" rule excludes. So this gate protects passthrough boolean columns, not
  the converter's `IsNotNull` helpers. Extending it to trust the return type of `IsNotNull`/
  `IsNull` is a separate, scoped follow-up — do not fold it in here.
- The customer's **"Invalid Argument / Request format or values are invalid"** error remains
  unreproduced and needs the actual failing element JSON, recovered from before the 46-filter
  rewrite. Any such capture committed to this PUBLIC repo must be scrubbed of connection ids,
  warehouse/schema/table paths, the whole `source` block, real business-domain column names,
  workbook/DM ids, org slugs, and request ids. `tools/hygiene-sweep.sh` is a curated
  allowlist of *previously seen* identifiers — it will NOT catch a first-time-seen one.

```bash
# bump the patch version first (1.6.10 -> 1.6.11 at time of writing)
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/typed_literal_lint.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lint-typed-literals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/migrate-tableau.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-typed-literal-lint.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): typed-literal lint learns BOOLEAN columns and runs over the workbook spec (K9)"
```

---

## Task 8: K5 — stop emitting refs that were never real column names

The register reported workbook master refs emitted in the fact namespace for related-table fields, including Tableau `(Element)`-suffixed labels, plus `[Metrics/X]` refs with no such element in the spec.

**Validation reclassified the cause.** S5a is a false positive: Sigma resolves parenthetical names correctly when the column genuinely exists (`[Order Fact/Net Revenue (Adj)]` → `valid:true`). So these refs failed because **the skill invented names that were never columns** — not because Sigma cannot parse them. The fix belongs entirely here.

**Files:**
- Read: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lib/ref_label_repair.rb`
- Modify: the emitter that produces master refs for related-table fields
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-ref-label-emission.rb`

**Interfaces:**
- Consumes: the column census for the posted element.
- Produces: only refs whose target name exists in that census; anything else is dropped with a recorded warning rather than emitted.

- [ ] **Step 1: Establish the ground rule as a test**

Create `test-ref-label-emission.rb` asserting: for a given element census, every emitted `[Element/Column]` ref resolves to a name present in that census; a ref to an absent name is **not emitted** and is recorded as a warning. Include a fixture with a Tableau `(Element)`-suffixed label and a `[Metrics/X]` ref where no `Metrics` element exists — both must be dropped-with-warning, not emitted.

Include the positive control: a ref to a genuinely existing parenthetical name (`Net Revenue (Adj)`) **must** be emitted. Live probing proves that form is valid, so a fix that strips all parentheticals would be wrong.

- [ ] **Step 2: Run test to verify it fails**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-ref-label-emission.rb
```

Expected: FAIL. Record the red output.

- [ ] **Step 3: Implement validate-before-emit**

Add a census check at the emission site: resolve each candidate ref against the target element's column names before emitting. On miss, drop the ref and append a structured warning naming the ref and the element, so it surfaces in the coverage report instead of failing at POST.

- [ ] **Step 4: Run test to verify it passes**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-ref-label-emission.rb
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/assert-wb-refs-resolve.rb --help
```

Expected: the new test `ALL PASS`; the existing ref-resolution assertion still runs.

- [ ] **Step 5: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/ \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): validate refs against the column census before emitting (K5)"
```

---

## Task 8.5: K19 — geography worksheets emit valid map elements, never an aggregated coordinate

**Measured offline (not inferred).** Running the current v1.6.10 builder on a synthetic
lat/long worksheet produces:

```json
{"id":"el-store-map","kind":"point-map","name":"Store Map",
 "source":{"kind":"table","elementId":"master"},
 "columns":[{"id":"x-el-store-map","name":"Longitude (generated)","formula":"[Master/Longitude (generated)]"},
            {"id":"y-el-store-map","name":"Latitude (generated)","formula":"Sum([Master/Latitude (generated)])",
             "format":{"kind":"number","formatString":",.1%"}}],
 "xAxis":{"columnId":"x-el-store-map"},"yAxis":{"columnIds":["y-el-store-map"]}}
```

and on a filled/region worksheet:

```json
{"id":"el-region-map","kind":"region-map", ... ,"xAxis":{...},"yAxis":{...}}   // no `region` key
```

**Correct the register's narrative before implementing:** these worksheets do **not** fall
into the scatter fast path — that branch is gated `if kind == 'scatter-chart' && headers.length >= 3`
and `SIGMA_KIND` already maps `map-point`/`map-region` to `point-map`/`region-map`
(`build-charts-from-signals.rb:236-237`), so `kind` is never `scatter-chart`. They fall through
to the **generic chart builder** (`:5371`), which binds `headers[0]` → `xAxis` and an
**aggregated** `headers[1]` → `yAxis`. That is why the element already carries the right
`kind` and why `latitude` has zero occurrences in the file. `Sum(<coordinate>)` is the
nonsense-axis symptom.

Per the OpenAPI `CommonElement` map branches (corroborated by the vendored
`sigma-workbooks/reference/specification/maps.md`):
- `point-map` requires `[id, kind, source, columns, latitude, longitude]`; `latitude`/
  `longitude`/`size` are **single `{id}` objects**, never arrays.
- `region-map` requires `region: {id, regionType}` with `regionType` ∈ `country | us-state |
  us-county | us-zipcode | us-cbsa | us-postal-place | ca-province`, and the region column's
  **values** must match the type. Tableau's semantic role (`z['geo_role']`, e.g.
  `[State].[Name]`) is the only available signal and its mapping to `regionType` is
  **unverified** — so region-maps must fail closed with a STAYS-MANUAL warning, not be guessed
  and not fall through (falling through emits an element the API requires `region` on).

**Plugin-local.** `build-charts-from-signals.rb` and `parse-twb-layout.rb` are absent from
`shared/manifest.json` — an ordinary `tableau-to-sigma`-only PR.

**Conflict RESOLVED by live probe, 2026-08-06 — use `elementId`.** `LESSONS-LEARNED.md` R1
says a map element references its source **by NAME**. That is **wrong at the spec layer**.
Measured against `/v2/workbooks/spec/verify` with an otherwise-valid `region-map`:

| `source` shape | Result |
|---|---|
| `{kind:"table", elementId:"helper"}` | **PASS** |
| `{kind:"table", name:"Geo Helper"}` | 400 `Invalid kind: "region-map"` |
| a direct `{kind:"warehouse-table", …}` | **PASS** |

So the compiled asset is right on this field, `elementId` is correct as written below, and
**no pre-merge live check is needed**. R1 may be describing UI-side behavior; it does not
hold for spec authoring, and R1 should be corrected when the migration docs are next touched.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb`
  — insert immediately **before** the `# Scatter fast path (bead z1d0, …` comment (~`:5226`)
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-map-emission.rb`

**Interfaces:**
- Consumes (all already in scope at the insertion point): `kind`, `headers`, `dim`, `dim_hdr`,
  `meas`, `meas_hdr`, `mmap`, `meta`, `z`, `cap`, `el_id`, `chart_source_eid`, `sigma_agg`,
  `elements`, `warnings`.
- Produces: a `point-map` with raw coordinate columns, or a STAYS-MANUAL warning and no
  element. Never a map element missing its required geography binding.

- [ ] **Step 1: Write the failing test**

Create `test-map-emission.rb` (follows `test-native-topn-quickfilter.rb`'s convention:
synthetic `.twb` → subprocess parser → subprocess builder → assert on emitted JSON; the
`T2S_BUILD` override exists so a planted defect can be driven against a scratch copy):

```ruby
#!/usr/bin/env ruby
# Regression test for K19: geography worksheets must not be built as generic
# xAxis/yAxis charts with an AGGREGATED coordinate.
#
# Measured baseline (offline, unpatched v1.6.10): a lat/long worksheet emits
#   {"kind":"point-map", columns:[{"formula":"[Master/Longitude (generated)]"},
#    {"formula":"Sum([Master/Latitude (generated)])"}], xAxis:{...}, yAxis:{...}}
# — right `kind`, but no latitude/longitude keys and one coordinate SUMMED. A
# filled/region worksheet emits kind:"region-map" with no `region` key at all,
# which the spec API requires.
#
# Deterministic + offline + creds-free; neutral fixture names only.
#
# Usage:  ruby scripts/test-map-emission.rb
require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = ENV['T2S_BUILD'] || File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Store' name='[STORE]' datatype='string' role='dimension' />
        <column caption='State' name='[STATE]' datatype='string' role='dimension' semantic-role='[State].[Name]' />
        <column caption='Latitude (generated)' name='[LAT_GEN]' datatype='real' role='measure' />
        <column caption='Longitude (generated)' name='[LON_GEN]' datatype='real' role='measure' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Store Map'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x'>
              <column caption='Latitude (generated)' name='[LAT_GEN]' datatype='real' role='measure' />
              <column caption='Longitude (generated)' name='[LON_GEN]' datatype='real' role='measure' />
            </datasource-dependencies>
          </view>
          <rows>[federated.x].[avg:LAT_GEN:qk]</rows>
          <cols>[federated.x].[avg:LON_GEN:qk]</cols>
          <pane><mark class='Automatic' /></pane>
        </table>
      </worksheet>
      <worksheet name='Region Map'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.x'>
              <column caption='State' name='[STATE]' datatype='string' role='dimension' semantic-role='[State].[Name]' />
              <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
            </datasource-dependencies>
          </view>
          <rows>[federated.x].[sum:TOTALREV:qk]</rows>
          <cols>[federated.x].[none:STATE:nk]</cols>
          <pane><mark class='Filled' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Store Map'  x='0'     y='0' w='50000' h='100000' />
          <zone id='2' name='Region Map' x='50000' y='0' w='50000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Store$'     => { 'id' => 'm-store', 'name' => 'Store' },
  '(?i)^State$'     => { 'id' => 'm-state', 'name' => 'State' },
  '(?i)^Latitude'   => { 'id' => 'm-lat',   'name' => 'Latitude (generated)' },
  '(?i)^Longitude'  => { 'id' => 'm-lon',   'name' => 'Longitude (generated)' },
  '(?i)^TOTALREV$|^Total Revenue$' => { 'id' => 'm-rev', 'name' => 'Total Revenue' }
}.freeze

layout = nil
build_out = nil
build_log = ''
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Store Map' },
                                               { 'id' => 'v2', 'name' => 'Region Map' }] }))
  Dir.mkdir(File.join(d, 'views'))
  %w[v1 v2].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') }
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  layout = JSON.parse(File.read(lay))
  out = File.join(d, 'specs.json')
  build_log = IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
                        '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
                        '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
                        '--auto-controls', '--title', 'Dash', '--out', out],
                       err: %i[child out], &:read).to_s.force_encoding('UTF-8')
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

# ---- Upstream classification (independent of the builder fix) ---------------
# NB: chart_kind lives on layout.json's dashboards[].zones[], NOT in the
# -meta.json sidecar (the per-worksheet meta hash has no chart_kind key).
zones = layout.flat_map { |dsh| dsh['zones'] || [] }
zk = ->(capn) { (zones.find { |z| z['caption'].to_s == capn } || {})['chart_kind'] }
check(zk.call('Store Map') == 'map-point',
      "lat/long worksheet classifies as map-point (got #{zk.call('Store Map').inspect})", fails)
check(zk.call('Region Map') == 'map-region',
      "filled worksheet classifies as map-region (got #{zk.call('Region Map').inspect})", fails)

els = build_out ? (build_out.is_a?(Array) ? build_out :
        (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []

# ---- point-map: RAW coordinates on latitude/longitude, no chart axes --------
pm = els.find { |e| e['name'].to_s.casecmp?('Store Map') }
check(pm && pm['kind'] == 'point-map', "point-map element emitted (got #{pm && pm['kind']})", fails)
check(pm && pm['latitude'].is_a?(Hash) && pm['latitude']['id'].is_a?(String),
      "latitude is a single {id} object (got #{pm && pm['latitude'].inspect})", fails)
check(pm && pm['longitude'].is_a?(Hash) && pm['longitude']['id'].is_a?(String),
      "longitude is a single {id} object (got #{pm && pm['longitude'].inspect})", fails)
check(pm && !pm.key?('xAxis') && !pm.key?('yAxis'),
      'point-map carries no xAxis/yAxis (it is not a cartesian chart)', fails)
col_of = ->(el, key) { el && (el['columns'] || []).find { |c| c['id'] == el.dig(key, 'id') } }
latc = col_of.call(pm, 'latitude')
lonc = col_of.call(pm, 'longitude')
check(latc && latc['formula'].to_s =~ /\A\[Master\/Latitude/i,
      "latitude column is a RAW ref, never aggregated (got #{latc && latc['formula'].inspect})", fails)
check(lonc && lonc['formula'].to_s =~ /\A\[Master\/Longitude/i,
      "longitude column is a RAW ref, never aggregated (got #{lonc && lonc['formula'].inspect})", fails)
# Planted-defect guard: the measured defect is Sum(<coordinate>). A test that
# only checked `kind` would pass on the UNPATCHED build, which ALREADY emits
# kind:"point-map" — with Sum([Master/Latitude ...]) bound to a yAxis.
check(pm && (pm['columns'] || []).none? { |c| c['formula'].to_s =~ /\b(Sum|Avg|Min|Max|Median)\s*\(\s*\[Master\/(Lat|Long)/i },
      'NO aggregate wraps either coordinate column', fails)

# ---- region-map: never emit an element missing the required `region` --------
rm = els.find { |e| e['name'].to_s.casecmp?('Region Map') }
check(rm.nil? || (rm['region'].is_a?(Hash) && rm['region']['id'] && rm['region']['regionType']),
      'region-map is either NOT emitted or carries the required region:{id, regionType} ' \
      "(got #{rm && rm.reject { |k, _| k == 'columns' }.inspect})", fails)
check(build_log =~ /Region Map.*STAYS-MANUAL/m || (rm && rm['region']),
      'a region/filled map that cannot be built is reported STAYS-MANUAL, not silently dropped', fails)

puts
if fails.empty?
  puts 'ALL PASS — geography worksheets emit valid map elements with raw coordinates'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
```

- [ ] **Step 2: Confirm RED**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-map-emission.rb
```

Expected, measured against the current tree: **8 FAILURES**. Both classification checks and
`point-map element emitted` PASS (the `kind` is already right — this is why a kind-only test
would have been a false pass); the latitude/longitude/no-axes/raw-ref/no-aggregate checks and
both region-map checks fail. Record that output.

- [ ] **Step 3: Insert the map fast path**

In `build-charts-from-signals.rb`, immediately before the `# Scatter fast path (bead z1d0, …`
comment:

```ruby
    # Map fast path (K19). A geography worksheet (parse-twb-layout chart_kind
    # map-point/map-region -> SIGMA_KIND point-map/region-map) reaches the
    # GENERIC chart builder below, which binds headers[0] -> xAxis and an
    # AGGREGATED headers[1] -> yAxis. MEASURED offline on a lat/long fixture:
    #   {"kind":"point-map", columns:[{"formula":"[Master/Longitude]"},
    #    {"formula":"Sum([Master/Latitude])"}], xAxis:{...}, yAxis:{...}}
    # i.e. the right `kind`, no `latitude`/`longitude` keys at all, and one
    # coordinate SUMMED (the nonsense-axis symptom). A point-map REQUIRES
    # [id, kind, source, columns, latitude, longitude], each of latitude/
    # longitude a single {id} object over a RAW (never aggregated) coordinate
    # ref; only `size` legitimately aggregates. Shape from the OpenAPI
    # CommonElement point-map branch, corroborated by sigma-workbooks
    # reference/specification/maps.md.
    if kind == 'point-map'
      # The generic binder fills the DIM slot from headers[0] and the MEASURE
      # slot from headers[1] regardless of role, so a lat/long-only worksheet
      # lands one coordinate in each -- scan BOTH slots (plus headers[2]).
      geo_cands = [[dim, dim_hdr], [meas, meas_hdr]]
      if headers.length >= 3
        h3 = headers[2].to_s.strip
        geo_cands << [map_column(h3, mmap) || { 'id' => "m-#{h3.downcase.gsub(/\W+/, '-')}", 'name' => h3 }, h3]
      end
      geo_cands = geo_cands.reject { |(o, h)| o.nil? || h.to_s.strip.empty? }
      geo_name = ->(pair) { (pair[0]['name'] || pair[1]).to_s }
      lat_pair = geo_cands.find { |p| "#{geo_name.call(p)} #{p[1]}" =~ /latitude/i }
      lon_pair = geo_cands.find { |p| "#{geo_name.call(p)} #{p[1]}" =~ /longitude/i }
      if lat_pair.nil? || lon_pair.nil?
        warnings << "'#{cap}' classified as point-map but Latitude AND Longitude did not both resolve " \
                    "from #{geo_cands.map { |p| geo_name.call(p) }.inspect} — STAYS-MANUAL, no element " \
                    'emitted for this zone (the Phase-6 tile census will report it unmatched). Build the ' \
                    'map by hand, or fix the coordinate column names on the master.'
        next
      end
      lat_id = "lat-#{el_id}"
      lon_id = "lon-#{el_id}"
      element = {
        'id'      => el_id,
        'kind'    => 'point-map',
        'name'    => tile_title(z, cap),
        'source'  => { 'kind' => 'table', 'elementId' => chart_source_eid },
        'columns' => [
          { 'id' => lat_id, 'name' => geo_name.call(lat_pair),
            'formula' => "[Master/#{geo_name.call(lat_pair)}]" },
          { 'id' => lon_id, 'name' => geo_name.call(lon_pair),
            'formula' => "[Master/#{geo_name.call(lon_pair)}]" }
        ],
        'latitude'  => { 'id' => lat_id },
        'longitude' => { 'id' => lon_id }
      }
      size_geo = color_measure_field(z.dig('channels', 'size'), meta, mmap)
      if size_geo
        element['columns'] << { 'id' => "sz-#{el_id}", 'name' => size_geo['name'],
                                'formula' => render_agg(sigma_agg, "[Master/#{size_geo['name']}]") }
        element['size'] = { 'id' => "sz-#{el_id}" }
      end
      element['_worksheet'] = cap
      element['_dashboard'] = dash['dashboard']
      elements << element
      warnings << "'#{cap}' geography worksheet -> point-map with RAW coordinate refs " \
                  "(latitude=#{geo_name.call(lat_pair)}, longitude=#{geo_name.call(lon_pair)}" \
                  "#{size_geo ? ", size=#{size_geo['name']}" : ''}); coordinates are never aggregated"
      next
    end
    if kind == 'region-map'
      # A region-map REQUIRES `region: {id, regionType}` with regionType in
      # country | us-state | us-county | us-zipcode | us-cbsa | us-postal-place
      # | ca-province, and the region column's VALUES must match that type.
      # Tableau's semantic role (z['geo_role']) is the only signal available and
      # its mapping to Sigma's regionType is UNVERIFIED, so do not guess: falling
      # through to the generic builder would emit kind:"region-map" with no
      # `region` key at all (a spec the API rejects, or a blank tile).
      warnings << "'#{cap}' is a filled/region MAP (Tableau geo role " \
                  "#{z['geo_role'].inspect}) — STAYS-MANUAL, no element emitted. Sigma needs " \
                  "region:{id, regionType} (country|us-state|us-county|us-zipcode|us-cbsa|" \
                  "us-postal-place|ca-province) and the region column's values must match the type; " \
                  'the Tableau-role -> regionType mapping is not implemented. Build this tile by hand.'
      next
    end

```

- [ ] **Step 4: Confirm GREEN**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-map-emission.rb
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-native-topn-quickfilter.rb
```

Both `ALL PASS`. (Verified offline while drafting: the K19 test goes 8-red → all-green with
exactly this patch, and the coordinate columns come back as
`[Master/Latitude (generated)]` / `[Master/Longitude (generated)]` with no aggregate wrapper.)

- [ ] **Step 5: Check the downstream census consumers**

`verify-visual-tiles.rb` and `scan-workbook-gaps.rb` already name `map-point`/`map-region` as
recognized kinds; they will now see real elements (point-map) and a STAYS-MANUAL zone
(region-map, which the tile census will report unmatched — correct and intentional, an honest
gap beats a broken element). Spot-check both outputs on the fixture and record.

- [ ] **Step 6: Commit** (bump `tableau-to-sigma` patch version — 1.6.10 at time of writing)

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-map-emission.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): geography worksheets emit point-map with raw coordinates; region-map fails closed (K19)"
```

---

## Task 8.6: K21 (narrowed) — implement `<alphabetic-sort>` only; do not touch `<computed-sort>`

`<computed-sort>` is already migrated end to end — extraction at `parse-twb-layout.rb:760-766`,
consumed by `sort_target_column_id` (`build-charts-from-signals.rb:971-981`) from three call
sites: `:5607` table `groupings[0].sort`, `:5629` pie/donut `color.sort`, `:5675`
bar/line/area/combo `xAxis.sort`. `grep -rn alphabetic-sort` over `parse-twb-layout.rb`,
`build-charts-from-signals.rb`, `scan-workbook-gaps.rb` returns **zero hits** — that, and only
that, is the gap. Do **not** describe this as "Tableau sorts are not migrated" (the register
overstates it) and do not re-touch the computed-sort path.

**The trap, measured — read before implementing.** The vendored XSD
(`schemas/twb_2026.2.0.xsd`, `Sort-Alphabetic-G`, lines 3034-3038) declares `<alphabetic-sort>`
with **no attributes at all** — no `column`, no `direction` — unlike its siblings which carry
`Sort-CommonAttributes-AG`. `sort_target_column_id`'s pre-existing
`return meas_col_id if token.empty?` therefore means a naive wire-through sorts the chart by
the **plotted measure**. Confirmed offline: with only the parser half applied, all three
consumers produced `by: y-<el>` (the measure) — inventing a ranking the source never had, on
every previously-unsorted chart. An explicit `alphabetic:` marker is required so the
empty-token case resolves to the dimension only for genuine alphabetic sorts.

The XSD reading (that `<alphabetic-sort>` really carries no attributes in the wild) is
**UNVERIFIED against a real failing `.twb`** — no sample was available. The parser below reads
`direction`/`column` defensively in case some exports do carry them. Flag this in the PR body.

**Plugin-local.** Neither file is in `shared/manifest.json`.

**Files:**
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/parse-twb-layout.rb`
  (insert immediately after the `<computed-sort>` block, after `:766`)
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb`
  (`sort_target_column_id`, `:971-981` — one arm; all three call sites inherit it)
- Create: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-alphabetic-sort.rb`

**Interfaces:**
- Consumes: nothing new — reuses the existing `sort_info` → `zones[].sort` → `z['sort']` thread.
- Produces: `sort_info` gains `alphabetic: true` (direction defaults to `ascending`, column
  `nil`); `sort_target_column_id` returns the dimension column id for that marker.

- [ ] **Step 1: Write the failing test**

Create `test-alphabetic-sort.rb`:

```ruby
#!/usr/bin/env ruby
# Regression test for K21 (NARROWED to <alphabetic-sort> only).
#
# <computed-sort> is already migrated end to end (parse-twb-layout.rb, then
# sort_target_column_id at build-charts-from-signals.rb) — this test locks that
# in and must never change it. <alphabetic-sort> had ZERO handling.
#
# The trap this guards: the vendored 2026.2.0 XSD declares <alphabetic-sort>
# with NO column/direction attributes (Sort-Alphabetic-G), and
# sort_target_column_id's pre-existing `return meas_col_id if token.empty?`
# means a naive wire-through sorts every such chart by the plotted MEASURE —
# inventing a ranking the source never had. Measured on this exact fixture with
# only the parser half applied: xAxis.sort.by == the MEASURE column id.
#
# Deterministic + offline + creds-free; neutral fixture names only.
#
# Usage:  ruby scripts/test-alphabetic-sort.rb
require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = ENV['T2S_PARSER'] || File.join(DIR, 'parse-twb-layout.rb')
BUILD  = ENV['T2S_BUILD']  || File.join(DIR, 'build-charts-from-signals.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def ws_sorted(name, mark, sort_xml)
  <<~XML
    <worksheet name='#{name}'>
      <table>
        <view>
          <datasource-dependencies datasource='federated.x' />
          #{sort_xml}
        </view>
        <rows>[federated.x].[sum:TOTALREV:qk]</rows>
        <cols>[federated.x].[none:REGION:nk]</cols>
        <pane><mark class='#{mark}' /></pane>
      </table>
    </worksheet>
  XML
end

ALPHA = '<alphabetic-sort />'
COMPUTED = "<computed-sort column='[federated.x].[sum:TOTALREV:qk]' direction='DESC' " \
           "using='[federated.x].[sum:TOTALREV:qk]' />"

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[REGION]' datatype='string' role='dimension' />
        <column caption='Total Revenue' name='[TOTALREV]' datatype='real' role='measure' />
      </datasource>
    </datasources>
    <worksheets>
      #{ws_sorted('Bar Sheet', 'Bar', ALPHA)}
      #{ws_sorted('Table Sheet', 'Text', ALPHA)}
      #{ws_sorted('Pie Sheet', 'Pie', ALPHA)}
      #{ws_sorted('Computed Sheet', 'Bar', COMPUTED)}
    </worksheets>
    <dashboards>
      <dashboard name='Dash'>
        <zones>
          <zone id='1' name='Bar Sheet'      x='0'     y='0' w='25000' h='100000' />
          <zone id='2' name='Table Sheet'    x='25000' y='0' w='25000' h='100000' />
          <zone id='3' name='Pie Sheet'      x='50000' y='0' w='25000' h='100000' />
          <zone id='4' name='Computed Sheet' x='75000' y='0' w='25000' h='100000' />
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Region$' => { 'id' => 'm-region', 'name' => 'Region' },
  '(?i)^TOTALREV$|^Total Revenue$' => { 'id' => 'm-rev', 'name' => 'Total Revenue' }
}.freeze

meta = nil
build_out = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [
               { 'id' => 'v1', 'name' => 'Bar Sheet' }, { 'id' => 'v2', 'name' => 'Table Sheet' },
               { 'id' => 'v3', 'name' => 'Pie Sheet' }, { 'id' => 'v4', 'name' => 'Computed Sheet' }
             ] }))
  Dir.mkdir(File.join(d, 'views'))
  %w[v1 v2 v3 v4].each { |v| File.write(File.join(d, 'views', "#{v}.csv"), '') }
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  meta = JSON.parse(File.read(lay.sub(/\.json$/, '-meta.json')))
  out = File.join(d, 'specs.json')
  IO.popen(['ruby', BUILD, '--tableau-dir', d, '--layout', lay,
            '--meta', lay.sub(/\.json$/, '-meta.json'), '--master-map', mm,
            '--master-element-id', 'master', '--skip-dashboard-read', 'unit-test',
            '--auto-controls', '--title', 'Dash', '--out', out], err: %i[child out], &:read)
  build_out = JSON.parse(File.read(out)) if File.exist?(out)
end

# ---- Parser half -----------------------------------------------------------
s = meta.dig('worksheets', 'Bar Sheet', 'sort')
check(s.is_a?(Hash) && s['alphabetic'] == true && s['direction'] == 'ascending' && s['column'].nil?,
      "<alphabetic-sort/> captured as {alphabetic:true, direction:ascending, column:nil} (got #{s.inspect})", fails)
cs = meta.dig('worksheets', 'Computed Sheet', 'sort')
check(cs.is_a?(Hash) && cs['direction'] == 'descending' && cs['using'].to_s.include?('TOTALREV') && cs['alphabetic'].nil?,
      "<computed-sort> capture is UNCHANGED (got #{cs.inspect})", fails)

els = build_out ? (build_out.is_a?(Array) ? build_out :
        (build_out['elements'] || (build_out['pages'] || []).flat_map { |p| p['elements'] || [] })) : []
el = ->(n) { els.find { |e| e['name'].to_s.casecmp?(n) } }
meas_id = ->(e) { (e['columns'] || []).find { |c| c['formula'].to_s =~ /Sum\(\[Master\/Total Revenue\]\)/i }&.dig('id') }
dim_id  = ->(e) { (e['columns'] || []).find { |c| c['formula'].to_s == '[Master/Region]' }&.dig('id') }

# ---- All three consumers target the DIMENSION ------------------------------
bar = el.call('Bar Sheet')
bs  = bar && bar.dig('xAxis', 'sort')
check(bs && bs['by'] == dim_id.call(bar) && bs['direction'] == 'ascending',
      "bar xAxis.sort targets the DIMENSION ascending (got #{bs.inspect}, dim=#{bar && dim_id.call(bar)})", fails)
# Planted-defect guard: drop the `alphabetic:` marker (or revert
# sort_target_column_id) and the empty-token default silently returns the
# MEASURE column — a plausible-looking but wrong sort on every such chart.
check(bs && bs['by'] != meas_id.call(bar),
      'bar xAxis.sort does NOT target the measure (the naive-fix regression)', fails)

tbl = el.call('Table Sheet')
ts  = tbl && tbl.dig('groupings', 0, 'sort', 0)
check(tbl && tbl['kind'] == 'table', "table worksheet built as a table element (got #{tbl && tbl['kind']})", fails)
check(ts && ts['columnId'] == dim_id.call(tbl),
      "table groupings[0].sort targets the DIMENSION (got #{ts.inspect})", fails)
check(ts && ts['columnId'] != meas_id.call(tbl), 'table sort does NOT target the measure', fails)

pie = el.call('Pie Sheet')
ps  = pie && pie.dig('color', 'sort')
check(ps && ps['by'] == dim_id.call(pie), "pie color.sort targets the DIMENSION (got #{ps.inspect})", fails)
check(ps && ps['by'] != meas_id.call(pie), 'pie sort does NOT target the measure', fails)

# ---- <computed-sort> path untouched ----------------------------------------
comp = el.call('Computed Sheet')
xs   = comp && comp.dig('xAxis', 'sort')
check(xs && xs['by'] == meas_id.call(comp) && xs['direction'] == 'descending',
      "computed-sort STILL sorts by the measure descending (got #{xs.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — <alphabetic-sort> reaches all 3 sort consumers and targets the dimension; computed-sort unchanged'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |x| puts "  - #{x}" }
  exit 1
end
```

- [ ] **Step 2: Confirm RED**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-alphabetic-sort.rb
```

Expected, measured against the current tree: **7 FAILURES**; the two checks that pass are
`table worksheet built as a table element` and `computed-sort STILL sorts by the measure
descending` (the baseline this must not break).

- [ ] **Step 3: Parser half**

In `parse-twb-layout.rb`, immediately after the `<computed-sort>` block:

```ruby
  # "Sort alphabetically" — <alphabetic-sort/>. In the vendored 2026.2.0 schema
  # (schemas/twb_2026.2.0.xsd, Sort-Alphabetic-G) this element declares NO
  # attributes at all: no `column`, no `direction`, unlike <sort>/<computed-sort>
  # which carry Sort-CommonAttributes-AG. Sort-G pairs it POSITIONALLY with its
  # shelf pill inside ViewSpecification-G, so nothing in the element names the
  # sorted field. Record it as an explicit `alphabetic: true` marker with an
  # ascending default, reading direction/column defensively in case some exports
  # do carry them. The MARKER (not a nil column) is what tells
  # sort_target_column_id to target the DIMENSION — its empty-column default is
  # "sort by the measure", which is backwards for an alphabetic sort.
  # UNVERIFIED against a real failing .twb (no sample was available) — re-check
  # the first time this fires in a live conversion.
  if sort_info.nil? && (als = ws.elements['.//alphabetic-sort'])
    sort_info = {
      direction:  (als.attributes['direction'].to_s =~ /desc/i ? 'descending' : 'ascending'),
      column:     als.attributes['column'],
      alphabetic: true
    }
  end
```

- [ ] **Step 4: Consumer half — one arm, three call sites**

In `build-charts-from-signals.rb:971-981`, change only the empty-token branch:

```ruby
  token = (inner.split(':')[1] || inner).downcase.gsub(/\W+/, '')
  # <alphabetic-sort/> names no column (see parse-twb-layout.rb) — its marker
  # means "sort the DIMENSION alphabetically". Without this arm the empty-token
  # default below sorts by the plotted MEASURE, which would invent a ranking the
  # source never had on every alphabetically-sorted chart. The measure default
  # is still correct for a <sort> whose column attribute genuinely didn't resolve.
  return dim_col_id if token.empty? && sort_info['alphabetic']
  return meas_col_id if token.empty?
```

- [ ] **Step 5: Confirm GREEN and no regressions**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-alphabetic-sort.rb
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-native-topn-quickfilter.rb
```

Both `ALL PASS`. (Verified offline while drafting: 7-red → all-green with exactly these two
edits, and the computed-sort assertion is unchanged in both runs.)

- [ ] **Step 6: Commit** (bump `tableau-to-sigma` patch version)

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/parse-twb-layout.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/build-charts-from-signals.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-alphabetic-sort.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): migrate <alphabetic-sort> to a dimension sort, not a measure sort (K21, narrowed)"
```

---

## Task 8.7: K22 — the ghost-target lint must validate the target COLUMN, not just the element

`controls_report` (`shared/lib/control_lint.rb:170-190`) builds `live` from
`t.dig('source','elementId')` and gates solely on `elems.key?(t)` — **it never reads
`columnId` at all**. (`conflicting_default_violations` at `:257-260` does read
`cid = t['columnId']`, but only for alias grouping at `:261`; it also gates on element
existence alone.) A control whose target element exists but whose `columnId` is stale is
reported clean. Worse: the dead-column target is folded into `live` → `reach`, so the
pre-existing "dead control" check (`r[:reach].empty?`, `:339`) also stays silent. Measured
against the unpatched lib, a control pointing at a real element with a nonexistent column
yields `ControlLint.lint(spec) == []` — the literal "ghost-target: clean" false pass.

**SHARED file — shared-only PR.** `shared/manifest.json` fans `shared/lib/control_lint.rb`
out to **12** plugins (looker, microstrategy, powerbi, qlik, quicksight, tableau, thoughtspot,
domo, gooddata, sisense, cognos, hex) and `shared/scripts/test-control-lint.rb` to **2**
(powerbi, tableau). Edit the canonical files, run `ruby tools/sync-shared.rb`, commit the
fan-out. Do **not** combine with any of Task 7 / 8.5 / 8.6 (those are `plugins/tableau-to-sigma/`
only) — one PR touches either one plugin or `shared/`, never both.

**Files:**
- Modify: `shared/lib/control_lint.rb` — `controls_report` (`:170-190`), a new `dead_column_target?`
  helper, the `lint` violation loop (after the `ghost_targets` loop at `:333-336`), and the
  `conflicting_default_violations` gate at `:260`
- Modify: `shared/scripts/test-control-lint.rb` — insert **before** its final
  `puts / if fails.empty? … exit` block (the file ends in `exit 0`/`exit 1`; appended code is
  unreachable)
- Run: `ruby tools/sync-shared.rb`

**Interfaces:**
- Consumes: `elements(spec)` (`:113-125`) already returns the raw `el`; its `columns` array is
  right there and currently unused for this check.
- Produces: a new `dead_column_targets:` key on each `controls_report` row and a new
  `"dead-column target: …"` violation class, distinct from `"ghost target: …"`. Dead-column
  targets are kept **out of** `live`/`reach`, so the existing dead-control check fires too.

- [ ] **Step 1: Write the failing checks**

Insert into `shared/scripts/test-control-lint.rb`, immediately **before** the closing
`puts` / `if fails.empty?` block:

```ruby
# --- dead-column target (K22): element resolves, columnId does not ----------
SPEC_DEAD_COL = { 'pages' => [{ 'name' => 'P1', 'elements' => [
  { 'id' => 'tbl-1', 'kind' => 'table', 'name' => 'T',
    'columns' => [{ 'id' => 'c-real', 'name' => 'Region', 'formula' => '[Region]' }] },
  { 'id' => 'el-c1', 'kind' => 'control', 'controlId' => 'ctl-region', 'name' => 'Region',
    'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'tbl-1' },
                    'columnId' => 'stale-region-id' }] }
] }] }.freeze
vk = ControlLint.lint(SPEC_DEAD_COL)
check(vk.any? { |x| x.include?('dead-column target') && x.include?('stale-region-id') },
      "dead-column target (element exists, column does not) is FLAGGED (got #{vk.inspect})", fails)
check(vk.any? { |x| x.include?('dead control') },
      'a control wired ONLY to a dead column has empty reach -> also flags dead control', fails)

SPEC_LIVE_COL = JSON.parse(JSON.generate(SPEC_DEAD_COL))
SPEC_LIVE_COL['pages'][0]['elements'][1]['filters'][0]['columnId'] = 'c-real'
vl = ControlLint.lint(SPEC_LIVE_COL)
check(vl.none? { |x| x.include?('dead-column target') },
      'real columnId on a real element -> no dead-column false positive', fails)
check(vl.none? { |x| x.include?('dead control') },
      'real columnId -> reach non-empty, no dead-control false positive', fails)

# Conservative-by-construction guard: an element that declares NO columns array
# (a control, a text tile, a shape this lint does not model) must be SKIPPED,
# never flagged. This is the false-positive budget for a 12-plugin shared gate.
SPEC_NO_COLS = JSON.parse(JSON.generate(SPEC_DEAD_COL))
SPEC_NO_COLS['pages'][0]['elements'][0].delete('columns')
vn = ControlLint.lint(SPEC_NO_COLS)
check(vn.none? { |x| x.include?('dead-column target') },
      'target element declares NO columns array -> skipped, never flagged', fails)
```

- [ ] **Step 2: Confirm RED — this is the planted-defect proof**

The canonical `shared/scripts/test-control-lint.rb` cannot be run in place (it does
`require_relative 'lib/control_lint'` and `shared/scripts/lib/` does not exist — the file's own
header says "run from a vendored plugin copy"). Run the vendored copy:

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-control-lint.rb
```

Expected, measured: **2 FAILURES** —
`dead-column target … is FLAGGED (got [])` and `a control wired ONLY to a dead column …`.
The three no-false-positive checks PASS before the fix (vacuously) — the empty `got []` is
the "ghost-target: clean" false pass this whole item is about. Record it.

- [ ] **Step 3: Fix `controls_report`**

Replace the body of `controls_report`'s per-control block (`:177-188`):

```ruby
      elem_ghosts = []
      col_ghosts  = []
      live        = []
      (el['filters'] || []).each do |t|
        next unless t.is_a?(Hash)
        tgt = t.dig('source', 'elementId')
        next unless tgt
        if !elems.key?(tgt)
          elem_ghosts << tgt
        elsif dead_column_target?(elems[tgt][:el], t['columnId'])
          col_ghosts << "#{tgt}/#{t['columnId']}"
        else
          live << tgt
        end
      end
      live        = live.uniq
      elem_ghosts = elem_ghosts.uniq
      col_ghosts  = col_ghosts.uniq
      frefs   = formula_refs(elems, cid)
      roots   = (live + frefs).uniq
      reach   = roots.empty? ? Set.new : closure(elems, roots)
      page_q  = elems.select do |qid, i|
        qid != eid && i[:page] == info[:page] && QUERYABLE.include?(i[:kind])
      end.keys
      rows << { control_element_id: eid, control_id: cid, name: info[:name],
                page: info[:page], control_type: el['controlType'],
                filter_targets: live, ghost_targets: elem_ghosts,
                dead_column_targets: col_ghosts,
                formula_refs: frefs, reach: reach, page_queryable: page_q,
                uncovered: page_q.reject { |q| reach.include?(q) } }
```

- [ ] **Step 4: Add the helper**

Immediately before `def resolve_ref(elems, ref)` (`:195`):

```ruby
  # K22 — a filter target whose ELEMENT resolves but whose columnId is not among
  # that element's declared column ids. CONSERVATIVE by construction, matching
  # this lint's no-false-positives contract: only a target element that declares
  # a NON-EMPTY `columns` array can produce a finding. An element with no
  # `columns` key (a control, a text tile, a spec shape this lint does not model)
  # is skipped, never flagged.
  def dead_column_target?(target_el, column_id)
    return false if column_id.nil? || column_id.to_s.empty?
    cols = target_el['columns']
    return false unless cols.is_a?(Array) && !cols.empty?
    ids = cols.map { |c| c.is_a?(Hash) ? c['id'] : nil }.compact
    return false if ids.empty?
    !ids.include?(column_id)
  end

```

- [ ] **Step 5: Emit the new violation class**

Immediately after the existing `r[:ghost_targets].each` loop (`:333-336`):

```ruby
      Array(r[:dead_column_targets]).each do |g|
        tgt_id, col = g.split('/', 2)
        violations << "dead-column target: #{ctl_label} lists filter target #{label(elems, tgt_id)} " \
                      "column #{col.inspect}, which is NOT among that element's declared column ids — " \
                      'the target ELEMENT resolves (the ghost-target check alone reports this clean) but ' \
                      'the COLUMN does not, so the filter matches nothing and the control silently does ' \
                      'nothing; fix the columnId or drop the target'
      end
```

- [ ] **Step 6: Same guard in `conflicting_default_violations`**

At `:260`, after the existing element gate:

```ruby
        next unless elems.key?(target) # ghost target — owned by check (a)
        next if dead_column_target?(elems[target][:el], cid) # dead column — owned by controls_report
```

- [ ] **Step 7: Confirm GREEN, then sync**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-control-lint.rb
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-conflicting-page-defaults.rb
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-per-page-masters.rb
ruby tools/sync-shared.rb
ruby plugins/powerbi-to-sigma/skills/powerbi-to-sigma/scripts/test-control-lint.rb
ruby plugins/powerbi-to-sigma/skills/powerbi-to-sigma/scripts/test-conflicting-page-defaults.rb
ruby tools/check-shared.rb
```

All `ALL PASS`, no drift. (Verified offline while drafting: 2-red → all-green with exactly
this patch, and every pre-existing assertion in `test-control-lint.rb` and
`test-conflicting-page-defaults.rb` still passes.) Note there are only **2** vendored copies of
`test-control-lint.rb` — powerbi and tableau; no other plugin carries it.

- [ ] **Step 8: Blast-radius check across the other 10 plugins**

This is a 12-plugin behavior change to a gate that runs in `post-and-readback.rb`,
`assert-phase6-ran.rb` gate 7, and `probe-controls.rb`. Before merging, run the lint over any
committed sample/fixture workbook specs each plugin ships and confirm zero new
`dead-column target` violations:

```bash
grep -rl '"kind"\s*:\s*"control"' plugins/*/skills/*/{examples,fixtures,test,refs} 2>/dev/null
```

If a plugin's own emitted spec trips the new check, that is either a real K22-class defect in
that converter (file it) or a spec shape this lint does not model (widen
`dead_column_target?`'s skip condition) — **do not** widen it silently to make a run green.

- [ ] **Step 9: Commit — shared canonical + fan-out + a version bump for every touched plugin**

`tools/check-plugin-version-bump.sh` fails any range touching `plugins/<name>/**` without that
plugin's `plugin.json` `version` strictly increasing. The sync writes into all 12 plugin
directories, so all 12 need a patch bump (current at time of writing: looker 1.2.6,
microstrategy 0.2.12, powerbi 1.8.6, qlik 1.3.4, quicksight 1.5.5, tableau 1.6.10,
thoughtspot 1.2.6, domo 0.14.1, gooddata 1.2.7, sisense 1.1.5, cognos 1.2.7, hex 0.2.1). This
is a runtime behavior change, so `Skip-Version-Bump` is **not** appropriate.

```bash
git add shared/lib/control_lint.rb shared/scripts/test-control-lint.rb \
        plugins/*/skills/*/scripts/lib/control_lint.rb \
        plugins/powerbi-to-sigma/skills/powerbi-to-sigma/scripts/test-control-lint.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-control-lint.rb \
        plugins/*/.claude-plugin/plugin.json
git commit -m "fix(shared): control_lint validates the target COLUMN, not just the target element (K22)"
```

---

## Amendment to the existing Task 10, Step 6 (C4) — replaces the current paragraph

> `tables.md` marks `groupings` "verified 2026-06-15". Round-2 live probing (S12, 2026-08-06)
> exercised `groupings` end to end and it still works, including the hidden-aggregate sort
> workaround with readback persistence. Update the marker's date to 2026-08-06 and add two
> things the doc does **not** currently say:
> (a) the **level-ownership constraint** — a `sort[].columnId` inside `groupings[i]` must be a
> calculation owned by *that* level; an outer level sorting by an inner level's calculation is
> rejected, and (measured) it surfaces as a generic 500-class
> `An error has occurred… (incident-id=…)`, **not** the `Sort column not found` message the
> caller would grep for. The dedicated-hidden-aggregate-per-level workaround is accepted.
> (b) readback normalizes each sort entry to include `nulls: "connection-default"`.
> Note that `tables.md`'s `groupings` example **already shows** the per-level
> `sort: [{ columnId, direction }]` shape (line ~52) — do not "add" it; only the constraint and
> the normalization are missing. Do not fall back to "mark unverified"; live evidence exists.

---

## Task 9: Reproduction harness for the behavioral group — SPEC FIRST

**Do not start coding this task.** K4, K8, K10, K12(b–d), K15, K16, K17, K18 are output-fidelity defects. None can be confirmed or fixed by reading source: each depends on what the converter produces from a specific `.twb`. Attempting them blind produces plausible changes with no evidence they fix anything — which is how the register's own "fixed" items became unreliable.

Additionally, K4 (object-model published-datasource collapse) is large on its own: `object-graph-plan` currently appears only in `scan-workbook-gaps.rb` and `test-object-model-gap.rb`, with no data-model builder consuming it. Teaching the DM builder to consume the object graph is a subsystem change, not a bug fix.

**Blocker to note:** `main`'s workbook write path does not currently work against the live API — the `document` wrapper fix is unmerged (PR #609). An end-to-end reproduction run needs #609 merged, or the harness must run on that branch.

- [ ] **Step 1: Land Tasks 1-8 first**

Those are independently valuable and unblocked. Do not hold them behind this task.

- [ ] **Step 2: Write a spec for the reproduction harness**

Use `superpowers:brainstorming`. The spec must answer:
- Which source `.twb` reproduces each of K8/K10/K15/K16/K17/K18? A sanitized fixture workbook is strongly preferred over the customer's — the customer workbook cannot be committed.
- What is the observable assertion per item? (e.g. K10: "the KPI tile's query carries the page-level date filter"; K17: "the bar panel's y-axis binds a measure, not a dimension".)
- Can each assertion run offline against emitted spec JSON, or does it need a live post + export?

- [ ] **Step 3: Write a separate spec for K4**

K4 gets its own spec and plan. Scope: fetch the datasource by luid rather than `contentUrl`, and have the DM builder consume `object-graph-plan.json` when present. `test-object-model-gap.rb` already exists and is the natural starting point for its gate.

- [ ] **Step 4: Only then write per-item plans**

Each behavioral item gets a task with a failing assertion **demonstrated against a real conversion** before any fix.

---

## Task 10: Documentation corrections — upstream repo

All four C-items validated, plus three findings the register did not have. These live in **`twells89/sigma-skills`** (upstream), then re-vendor into `plugins/sigma-authoring/` per `SYNC.md`. **Different repo — separate PR from Tasks 1-8.**

**Files (in `sigma-skills`):**
- Modify: `sigma-data-models/reference/calc-columns.md:20`
- Modify: `sigma-workbooks/reference/specification/controls.md:28,288`
- Modify: `sigma-workbooks/reference/specification/tables.md` (groupings marker)
- Modify: `sigma-workbooks/reference/specification/content-elements.md:46-55`
- Modify: `sigma-data-models/reference/workflows/crud.md` (lookup path shape)

- [ ] **Step 1: C1 — the urgent one**

`calc-columns.md:20` currently reads:

```markdown
- **Cross-element** — `[Element Name/Column Name]`. The element name is the source element's `name`.
```

Replace with:

```markdown
- **Cross-element** — **use `Lookup()`, not the bare form.** The bare
  `[Element Name/Column Name]` reference is accepted at PUT, reports a clean
  (non-error) type in `/columns`, and then returns **NULL for every row** at
  query time, with no error surfaced anywhere. Measured 2026-08-05: 0/906
  non-null via the bare form vs 872/906 via `Lookup()` over the same
  relationship, same model, same PUT. Always write:
  `Lookup([Other Element/Column], [This Key], [Other Element/Key])`.
```

This is the highest-value doc change in the plan: the current text recommends a pattern that silently corrupts data.

- [ ] **Step 2: C3 — `date` is REAL. Document the comparator `mode` it requires.**

> **Reversal — do not do what the previous two revisions of this step said.** The
> first said "remove the non-existent `date` controlType". The round-2 workflow
> softened that to "add a caveat". **Both are wrong.** A live probe on 2026-08-06
> settled it: a single-value `date` control **exists and validates**.
>
> The reason every earlier attempt failed is that a `date` control's `mode` is a
> **comparator** enum — `=`, `>=`, `<=` — which is entirely different vocabulary
> from `date-range`'s `last` / `between` / `on`. The register's probe and round-1's
> both used the date-range vocabulary, or omitted `mode`. Measured:
>
> | Shape | Result |
> |---|---|
> | `date` + `mode:"="` + `value:"2026-01-01"` | **PASS** |
> | `date` + `mode:">="` / `"<="` + fixed value | **PASS** |
> | `date` + `mode:"="` + `value:{op:"now-minus",unit:"day",value:7}` | **PASS** |
> | `date` + `mode` only, no value | **PASS** |
> | `date` + `value` only, **no `mode`** | 400 `Invalid kind: "control"` |

So `controls.md:288` is **correct** to list `date` among the single-value controls.
Do not delete it and do not add a "live rejected it" caveat.

The genuine gap is narrower: `controls.md` never says a `date` control needs `mode`
from the comparator enum, and `mode` is exactly what makes it valid. Add a short
`date` subsection documenting `mode` (`=` / `>=` / `<=`) and `value` (an ISO string,
or a relative `{op: "now-minus"|"now-plus", unit, value}` object), and state that
omitting `mode` yields the opaque `Invalid kind: "control"`.

**Knock-on, worth flagging in the PR body:** the migration `LESSONS-LEARNED` lists
"single-date parameter controls remain DM-level controls, absent from page rails"
as a permanent documented degradation. On this evidence that degradation is
unnecessary and should be retired.

- [ ] **Step 3: C2 — document the `parameters` item shape**

`controls.md:28` lists `parameters` with no item shape. Add the live shape:

```json
{ "kind": "data-model", "dataModelId": "<uuid>", "controlId": "<dm control>" }
```

- [ ] **Step 4: N1 — fix the image element shape**

`content-elements.md` documents the flat shape, which the live API rejects for **every** image:

```yaml
# currently documented — REJECTED (400 Invalid kind: "image")
kind: image
url: https://cdn.example.com/logo.png
```

Replace with the validated shape, and delete the "hosted only — no uploads" claim — `data:` URIs validate:

```yaml
kind: image
source:
  kind: url
  url: https://cdn.example.com/logo.png   # or a data:image/…;base64,… URI
```

- [ ] **Step 5: N2/N3 — two small gaps**

- `crud.md`: document that `POST /v2/connection/{id}/lookup` takes `path` as a plain string array (`["DB","SCHEMA","TABLE"]`); the `pathIdentifiers` object form returns 400. Note the endpoint is `/v2/connection/` (singular).
- Wherever `GET /v2/workbooks/{id}/spec` is documented: note it returns an **empty body** without an explicit `Accept: application/json` header.

- [ ] **Step 6: C4 — re-date or re-verify the groupings marker**

`tables.md` marks `groupings` "verified 2026-06-15". Either re-verify against the current API and update the date, or change the marker to state plainly that it is unverified since 2026-06. Do not leave a stale verification claim standing.

- [ ] **Step 7: Commit upstream, then re-vendor**

```bash
# in the sigma-skills checkout
git add sigma-data-models/reference/calc-columns.md \
        sigma-workbooks/reference/specification/controls.md \
        sigma-workbooks/reference/specification/content-elements.md \
        sigma-workbooks/reference/specification/tables.md \
        sigma-data-models/reference/workflows/crud.md
git commit -m "docs: correct cross-element refs, image shape, and the date controlType against live API behavior"
```

Open the `sigma-skills` PR. **Only after it merges**, re-vendor into `plugins/sigma-authoring/` per `SYNC.md` and bump `sigma-authoring` to `1.9.4` in a separate PR on `sigma-migration-skills`.

---

## Self-review

**Spec coverage.** Every ledger item dispositioned to the plan has a task: K2→4, K3→2, K4→9, K5→8, K6→5, K7→3, K9→7, K11→1, K12(a)→6, K12(b–d)→9, behavioral group→9, C1–C4 and N1–N3→10. K1/K13/K14 are out of scope with reasons stated. Platform items are excluded by design.

**Placeholders.** Tasks 1-4 carry complete before/after code. Tasks 5-8 specify exact files, the precedent to mirror, and the assertions required, but deliberately do not pre-write code that depends on reading the current implementation first — each names the read step explicitly. Task 9 is spec-first by design and says so. Task 10 carries verbatim replacement text.

**Type consistency.** The `namespace_ids` lambda in Task 2 takes one argument (`list`) and closes over `seen_el_ids`, `d_slug`, `dash_name`, and `$chart_provenance` — matching the existing block it is extracted from. `page_slug` in Task 4's test mirrors the shipped op and both are asserted against each other in Part C. The image shape `{id, kind, source: {kind, url}}` is used identically in Task 3's fix, its test, and Task 10's doc text.

**Known risk.** Task 3 Step 6 leaves `page['backgroundImage']` unchanged pending a live check. That is deliberate — changing it on inference is how the original register got its image diagnosis backwards.

**Correction applied 2026-08-05 (post-merge).** Task 5 originally said "make the tile-census gate fail closed" and pointed at the plugin copy of `assert-phase6-ran.rb`. Both were wrong:

- the gate's canonical home is `shared/scripts/`, vendored to 13 plugins — editing the plugin copy fails the drift gate;
- a blanket fail-closed would have broken the 12 converters with no dashboard zone tree, whose `[SKIP]` is an honest abstention, not a bypass;
- and `tile_census` is a **reserved key** whose shape gate 5 reads field-by-field, so widening or aliasing it produces a vacuous `[OK]` over unmeasured data (the PR #631 regression).

Task 5 is now scoped to Tableau, pinned to the reserved shape, and requires a test in **both** directions plus a foreign-shape guard. This is worth noting as a pattern: the first draft optimised for closing one converter's hole and would have silently degraded the rest.


---

# Round-2 residual risks and open questions

## Needs a live probe before anything downstream can be closed

1. **The customer's actual error is still unreproduced.** None of the four value-type variants
   produced `Invalid Argument / Request format or values are invalid`. That is a third,
   distinct failure class from both "Invalid filter" and "No data". Settling it needs the real
   failing element JSON from before the 46-filter rewrite (version history, a saved spec
   export, or a request-id-keyed log capture) — not a reconstruction. Until then K9 is fixed
   in *direction* but the field incident's mechanism is unknown. Anything committed here must
   be scrubbed of connection ids, warehouse/schema/table paths, the whole `source` block, real
   business-domain column names, workbook/DM ids, org slugs, and request ids;
   `tools/hygiene-sweep.sh` is a curated allowlist of previously-seen identifiers and will not
   catch a first-time-seen one.
2. ~~**`controlType: "date"`**~~ — **CLOSED 2026-08-06, and the answer reverses S4.**
   A single-value `date` control exists and validates; it requires `mode` from the
   comparator enum (`=` / `>=` / `<=`), not date-range's `last`/`between`/`on`. Every
   earlier rejection used the wrong `mode` vocabulary or omitted `mode` entirely.
   S4's first claim is REFUTED and C3 is REFUTED — see Task 10 Step 2. S4's *second*
   claim (date-range control bound to a single-date DM parameter) is still untested.
3. **`themeName` vs `settings.theme.name` (N5 / D2).** UNVERIFIED, and the earlier "the
   rendered Fern reference says `document.settings.theme.name`" claim is **withdrawn as
   uncorroborated**. The only measured datum is `styling.md`'s 2026-06-26 POST→GET round-trip
   showing flat top-level `themeName`. One live round-trip settles it. No doc or converter
   change until then.
4. ~~**Map element `source`: by NAME or by `elementId`?**~~ — **CLOSED 2026-08-06.**
   Live-probed: `source: {kind:"table", elementId:"helper"}` **PASSES**;
   `source: {kind:"table", name:"Geo Helper"}` returns 400 `Invalid kind: "region-map"`;
   a direct `warehouse-table` source also passes. So the compiled asset is right and
   `LESSONS-LEARNED` R1's "a map element references its source by NAME, not id" is
   **wrong at the spec layer**. Task 8.5's use of `elementId` is correct as written and
   needs no pre-merge live check.
5. **`<alphabetic-sort>`'s real serialization.** The vendored 2026.2.0 XSD declares it with no
   attributes; no real `.twb` containing one was available. If real exports do carry
   `column`/`direction`, the parser reads them defensively and the marker still resolves
   correctly — but the *direction default* (ascending) is a guess that only a real sample can
   confirm. Flagged in-code and in the PR body.
6. **Whether the rendered reference documents `groupings[].sort` (N6 / D4a).** Only the
   compiled asset was checked. Stated as unchecked rather than assumed.

## Risks in the changes themselves

7. **K22 is a 12-plugin behavior change to a gate that already runs in production paths**
   (`post-and-readback.rb`, `assert-phase6-ran.rb` gate 7, `probe-controls.rb`). The new check
   is deliberately conservative — it only fires when the target element declares a non-empty
   `columns` array and the `columnId` is absent from it — and a no-false-positive case for the
   no-`columns` shape is in the test. But **no plugin other than tableau and powerbi ships a
   control-lint test**, and I could not run the new check against real emitted specs for the
   other 10 converters. Task 8.7 Step 8 makes that audit a merge precondition. The specific
   failure mode to watch for: a converter that targets a chart element using a column id that
   lives on the chart's *source* rather than on the chart itself would now be flagged. That is
   probably a real defect, but discovering it via a suddenly-red shared gate across 10 plugins
   is the wrong way to find out.
8. **Task 8.5 region-maps now emit nothing.** That is deliberate — the previous behavior
   emitted `kind:"region-map"` with no `region` key, which the spec requires — but it changes
   a (broken) tile into a reported gap, so the Phase-6 tile census will count more unmatched
   zones on any workbook containing filled maps. An honest gap beats a broken element, but
   whoever runs the next migration should expect the census delta and not treat it as a
   regression.
9. **Task 7's lint stays ADVISORY.** Making it blocking was the merged Task 7's implied
   direction, but `migrate-tableau.rb:4232-4235` records a deliberate corpus-safety decision
   ("a new lint must not block existing migrations; gate 13's tile-emptiness measurement
   remains the hard backstop"). Overturning that is a separate decision with its own
   false-positive budget, not a side effect of adding a type category.
10. **Task 7's boolean gate does not cover the converter's own filters.** The lint resolves a
    column's type only through a bare-ref formula or a formula-less column's name; the
    converter's boolean filters sit on `IsNotNull(...)` **computed** columns, which the
    existing (deliberate) "computed column → skip, no guessing" rule excludes. So the gate
    protects passthrough boolean columns, not the three emission sites. Extending it to trust
    the return type of `IsNotNull`/`IsNull` is defensible — those signatures are unambiguous —
    but it is a separate scoped change with its own test, explicitly not folded in.

## Reviewer findings I could not fully resolve

11. **Whether `parse-twb-layout.rb`'s geo classifier actually fires for the field incident's
    worksheet.** `chart_kind_for`'s `has_lat`/`has_long` come from regexing `latitude`/
    `longitude` against `caption`/`name` on `<column>` elements found via `.//column` — i.e.
    the worksheet's `<datasource-dependencies>` block, not shelf `<column-instance>` refs. My
    fixture trips it correctly (`chart_kind == 'map-point'`, verified), but with no repro
    `.twb` I cannot say the real workbook's map worksheet does. **If it does not, Task 8.5's
    builder is never reached and K19 reproduces unchanged.** Task 8.5 Step 1's classification
    assertions catch that class of failure for the caption styles tested; a real-world caption
    that misses is a separate upstream bug, deliberately out of scope.
12. **S8 has no traceable round-2 evidence.** The ledger's S8 row previously carried a specific
    repro narrative ("deliberately broken calc returned a populated CSV with empty cells") that
    appears in none of the ground-truth inputs — `VERIFIED-FINDINGS-2026-08-06.md` says only
    "S8 unsettled". I have left S8 as **unsettled with no round-2 evidence** rather than keep
    an untraceable measurement. If that repro was actually run, it needs its run artifact
    cited before it goes back in.
13. ~~**Whether any other converter emits a `top-n` filter keyed on a dimension (S13).**~~
    **CLOSED 2026-08-06 by a full static audit — no exposure.** Six converters emit
    `kind:"top-n"` (not eleven): tableau, domo, looker, powerbi, sisense, thoughtspot.
    Every one binds `columnId` to a measure, and two of them fail closed rather than
    guess:
    - `domo-to-sigma/.../build-workbook.rb:691` — `mcols.first['id']`, guarded by
      `mcols.any?`; the comment states "No measure column -> nothing to rank by -> no
      filter emitted (never a columnId: nil filter)".
    - `looker-to-sigma/.../build_workbook.py:1400-1416` — `rank_cid` is resolved only
      through `is_measure()`, twice (first the sorted measure, then the first measure
      column), and the filter is skipped entirely if neither yields one.
    - `powerbi-to-sigma/.../build-workbook-from-pbir.rb:428-431` — additionally
      scope-aware ("a shared-master top-n caps everything") and handles bottom-N.
    - `sisense-to-sigma/.../convert.py:686` — `meas_ids[0]`, with the rule stated in
      the comment.
    - `thoughtspot-to-sigma/.../ts_common.py:784-788` — resolves `spec["measures"][0]`
      to a real column and emits only on a match.
    No follow-up task needed. Strike the cross-converter audit from the Disposition.
14. **K20's reclassification is an interpretation, not a measurement.** What was *measured* is
    that the two emission families use different value types and that value type must match
    column type. That the `IsNotNull(...)` columns are boolean-typed and the
    `If(…,"keep","cut")` columns are text-typed is read off the emitted formulas, not probed
    live. It is a strong reading — those are unambiguous function signatures — but if a live
    probe ever shows `IsNotNull()` resolving to something other than boolean in an element
    filter context, K20 reopens.

## Explicitly NOT carried forward

- The claim that the rendered Fern reference has 17 `controlType` branches including `legend`
  and `drill` (the compiled asset has 15). **Withdrawn** — unverifiable without a live fetch,
  and the compiled asset's 15 are what I could actually check.
- The claim that per-level `groupings[].sort` is "entirely undocumented". **Wrong** — the
  vendored `tables.md` `groupings` example already shows it. Only the compiled asset omits it,
  and only the level-ownership constraint and the error-class mismatch are genuinely
  undocumented.
- The claim that the public workbook-spec reference documents a flat request body.
  **Withdrawn per ground truth** — the rendered page is correct; only the compiled S3 asset is
  stale, and D1 is scoped to exactly that.
- A standalone top-n regression-lock task, and a K20 "inventory lint" task. Both dropped: the
  first duplicates assertions already in `test-native-topn-quickfilter.rb`; the second was
  built on the premise that the two emission families disagree defectively, which the polarity
  measurement refutes.
