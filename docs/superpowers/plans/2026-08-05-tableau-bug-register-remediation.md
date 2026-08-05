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
- **A shared-file edit must be mirrored to every plugin copy** via `tools/sync-shared.rb`; the pre-commit hook fails otherwise.
- **Every gate must be proven to FAIL on a planted defect before it counts.** A gate that has never been seen red is not a gate.
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

## Task 5: K6 — make the tile-census gate fail closed

`assert-phase6-ran.rb` documents the tile census as "Skipped (with a note) when the converter doesn't emit a census." A gate that passes when its input is absent cannot catch the escape it exists for — and K6 is exactly that escape: two dashboard tiles silently dropped, which "only the finalize tile census would have caught."

This is the same silent-bypass class already fixed once for the gate-3 column audit in PR #595 (`a SKIPped gate-3 column audit is recorded and caps at YELLOW`). Follow that precedent rather than inventing a new convention.

**Files:**
- Read first: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/assert-phase6-ran.rb` (the gate-3 skip/degradation-ledger handling added by PR #595)
- Modify: the tile-census branch of the same file
- Modify: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-assert-phase6-gates.rb`

**Interfaces:**
- Consumes: `parity-final.json`'s `tile_census` field.
- Produces: a verdict that is capped (never GREEN) when the census is absent, recorded in the degradation ledger.

- [ ] **Step 1: Read the gate-3 precedent**

```bash
git show 1f9d8b77 -- plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/assert-phase6-ran.rb
```

Mirror its skip-recording and verdict-capping mechanism exactly. Do not invent a parallel one.

- [ ] **Step 2: Write the failing test**

Add to `test-assert-phase6-gates.rb` a case that runs the gate against a `parity-final.json` with **no** `tile_census` key and asserts the verdict is capped (not GREEN) and the skip is recorded in the degradation ledger. Follow the file's existing fixture style — build the fixture inline, call the gate, assert on its output.

- [ ] **Step 3: Run test to verify it fails**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-assert-phase6-gates.rb
```

Expected: FAIL — the absent census currently yields a clean pass. **This is the planted-defect proof for this gate; record the red output before fixing.**

- [ ] **Step 4: Apply the fix**

Change the tile-census branch so an absent census records a skip in the degradation ledger and caps the verdict, exactly as gate 3 does. Update the header comment at `:21-26` to state the new behavior — the current text ("Skipped (with a note)") becomes wrong the moment this lands.

- [ ] **Step 5: Run test to verify it passes**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-assert-phase6-gates.rb
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-anchors-waiver-gates.rb
```

Expected: both `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/assert-phase6-ran.rb \
        plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-assert-phase6-gates.rb \
        plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): a missing tile census caps the phase-6 verdict instead of passing (K6)"
```

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

## Task 7: K9 — confirm the typed-literal lint is a blocking gate

`lint-typed-literals.rb` exists and documents exactly the failure the register hit: boolean columns filtered with the string `"true"`, yielding zero rows workbook-wide. The open question is whether it is **wired as a blocking gate** on the hidden-calc-filter path, or merely available.

This task is an investigation with a conditional fix — do not assume the answer.

**Files:**
- Read: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/lint-typed-literals.rb`
- Read: `plugins/tableau-to-sigma/skills/tableau-to-sigma/SKILL.md` (phase gates)
- Read: `plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/migrate-tableau.rb` (orchestrator invocation)

**Interfaces:**
- Produces: either a confirmation note, or a wiring change plus its regression test.

- [ ] **Step 1: Determine whether the lint runs unattended**

```bash
grep -rn "lint-typed-literals" plugins/tableau-to-sigma/skills/tableau-to-sigma/ | grep -v "^.*lint-typed-literals.rb:"
```

Three outcomes:
- **Invoked and blocking** → record that in the PR body; K9 is closed with no code change. Skip to Step 4.
- **Invoked, non-blocking** → make it blocking (Step 2).
- **Not invoked** → wire it into the phase that builds hidden calc filters (Step 2).

- [ ] **Step 2: Write the failing test (only if a change is needed)**

Create `test-typed-literal-gate.rb` that feeds the lint a spec containing a boolean column compared to the string `"true"` and asserts the process exits non-zero. Include the inverse case — a correctly typed boolean literal must exit zero — so the gate is proven to discriminate rather than to fail on everything.

- [ ] **Step 3: Run it, confirm red, then wire the gate and confirm green**

```bash
ruby plugins/tableau-to-sigma/skills/tableau-to-sigma/scripts/test-typed-literal-gate.rb
```

Record the red output before the fix and the green output after.

- [ ] **Step 4: Commit**

```bash
git add -u plugins/tableau-to-sigma/skills/tableau-to-sigma/
git add plugins/tableau-to-sigma/.claude-plugin/plugin.json
git commit -m "fix(tableau): make the typed-literal lint a blocking gate on calc filters (K9)"
```

If no change was needed, commit only the PR-body note — do not fabricate a change to look productive.

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

- [ ] **Step 2: C3 — remove the non-existent `date` controlType**

`controls.md:288` claims `number`, `date`, `checkbox`, and `switch` are single-value controls. `date` is not in the live union — `date-range` validates, `date` returns 400 in every shape tried. Remove `date` from that sentence and add a note that a single-date DM parameter currently has no spec-authorable control.

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
