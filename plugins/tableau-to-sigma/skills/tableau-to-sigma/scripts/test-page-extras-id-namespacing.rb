#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K3: element ids in page_extras (styled text, title text,
# images) must go through the same cross-page namespacing as `els`.
#
# Tableau zone ids are unique per DASHBOARD, not globally. A styled-text element
# is emitted as id "text-<zone id>", so the same zone id reused on a second
# dashboard ships a duplicate Sigma element id and the POST hard-fails on
# "Duplicate id". The existing seen_el_ids pass only covered `els`; page_extras
# were concatenated in afterwards, bypassing it. Deterministic + offline.

require 'json'
DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'Part A — source contract'
src = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
check(src.match?(/namespace_ids\s*=\s*lambda/),
      'a shared namespace_ids lambda exists', fails)
check(src.match?(/'elements'\s*=>\s*namespace_ids\.call\(page_extras\)/),
      'page assembly routes page_extras through namespace_ids', fails)
# Scope this to the DASHBOARD emitter only. The page-per-worksheet emitter
# (`'name' => ws_name`, ~:8284) also concatenates page_extras, but it is already
# safe by construction and must NOT be "fixed": its title text is keyed on the
# worksheet name, and its duplicated controls suffix BOTH `id` and `controlId`
# with the ws_slug precisely because Sigma rejects duplicates. Only the dashboard
# emitter carries zone-id-keyed styled text, which is what collides.
dash_assembly = src[/page = \{ 'name' => dash_name.*/].to_s
check(!dash_assembly.empty?, 'located the dashboard page assembly', fails)
check(!dash_assembly.match?(/page_extras\s*\+\s*els/),
      'the dashboard assembly no longer concatenates raw page_extras', fails)
ws_assembly = src[/'name'\s*=>\s*ws_name,\s*\n\s*'elements'\s*=>\s*page_extras \+ els/m].to_s
check(!ws_assembly.empty?,
      'the page-per-worksheet emitter is left alone (already unique by construction)', fails)

puts 'Part B — behavioral: replicate the shipped op across two pages'
seen = {}
namespace_ids = lambda do |list, slug|
  list.map do |el|
    stem = el['id']
    next el unless stem

    if seen[stem]
      JSON.parse(el.to_json.gsub(stem, "#{stem}-#{slug}"))
    else
      seen[stem] = true
      el
    end
  end
end

page1 = namespace_ids.call([{ 'id' => 'text-550', 'kind' => 'text', 'body' => 'A' }], 'dash-one')
page2 = namespace_ids.call([{ 'id' => 'text-550', 'kind' => 'text', 'body' => 'B' }], 'dash-two')
check(page1[0]['id'] == 'text-550', 'first occurrence keeps its id', fails)
check(page2[0]['id'] == 'text-550-dash-two', 'second occurrence is namespaced', fails)
all = (page1 + page2).map { |e| e['id'] }
check(all.uniq.size == all.size, 'ids are globally unique across pages', fails)
check(page2[0]['body'] == 'B', 'namespacing preserves the element body', fails)

puts 'Part C — an element with no id is passed through untouched'
noid = namespace_ids.call([{ 'kind' => 'divider' }], 'dash-three')
check(noid[0] == { 'kind' => 'divider' }, 'id-less element survives unchanged', fails)

puts 'Part D — planted-defect guard: the OLD concat really did collide'
# If this ever stops colliding, Part B proves nothing.
naive = [{ 'id' => 'text-550' }, { 'id' => 'text-550' }].map { |e| e['id'] }
check(naive.uniq.size != naive.size,
      'PLANTED-DEFECT GUARD: un-namespaced ids do collide', fails)

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
