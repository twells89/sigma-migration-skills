#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K7/N1: image elements must use the nested source shape.
#
# Live-probed 2026-08-05/06 against /v2/workbooks/spec/verify:
#   {kind:"image", url:"https://..."}                     -> 400 Invalid kind: "image"
#   {kind:"image", url:"data:image/png;base64,..."}       -> 400 Invalid kind: "image"
#   {kind:"image", source:{kind:"url", url:"https://..."}} -> valid:true
#   {kind:"image", source:{kind:"url", url:"data:..."}}    -> valid:true
#
# So the flat `url:` shape fails for EVERY image, hosted or data: URI — the
# original register had the diagnosis backwards (it blamed data: URIs).
# Deterministic + offline.

DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

src = File.read(File.join(DIR, 'build-charts-from-signals.rb'))

puts 'Part A — no flat url: image element is emitted'
# Image element literals: a hash containing 'kind' => 'image'. Reject any that
# carries a top-level 'url' instead of a 'source'.
# Line-based, NOT brace-balanced: the real literal contains \#{z['id']}
# interpolation, and a [^{}]* matcher silently misses it — that false-negative
# is exactly how this test first passed against unfixed code.
# Statement-aware: an emission literal may wrap across lines, so look at the
# matching line PLUS the next two before concluding there is no 'source'.
# (Line-only was a false POSITIVE once the fix wrapped the literal; brace-
# balanced was a false NEGATIVE because of \#{...} interpolation. Both failure
# modes were hit while writing this test.)
lines = src.lines
flat = lines.each_with_index.select { |l, _| l.match?(/'kind'\s*=>\s*'image'/) }
            .reject { |_, i| lines[i, 3].join.include?("'source'") }
            .map    { |l, i| "#{i + 1}: #{l.strip[0, 70]}" }
check(flat.empty?,
      "no flat {kind: image, url: ...} emission sites (found #{flat.size}: #{flat.inspect})", fails)

puts 'Part B — the nested source shape IS emitted'
check(src.match?(/'kind'\s*=>\s*'image'.*?'source'\s*=>\s*\{\s*'kind'\s*=>\s*'url'/m),
      'image elements carry source: {kind: url, url: ...}', fails)

puts 'Part C — the stale data-URI comment is corrected'
check(!src.include?('data URIs live-verified'),
      'stale "data URIs live-verified" comment removed (the SHAPE was the bug)', fails)

puts 'Part D — planted-defect guard: the matcher really does catch a flat shape'
# Both samples carry the same \#{...} interpolation the real emitter uses.
sample_flat   = %q({ 'id' => "img-#{z['id']}", 'kind' => 'image', 'url' => url })
sample_nested = %q({ 'id' => "img-#{z['id']}", 'kind' => 'image', 'source' => { 'kind' => 'url', 'url' => url } })
det = lambda do |txt|
  ls = txt.lines
  ls.each_with_index.select { |l, _| l.match?(/'kind'\s*=>\s*'image'/) }
    .reject { |_, i| ls[i, 3].join.include?("'source'") }
end
# A WRAPPED nested literal must not be flagged — the false positive this
# detector hit on its first pass.
sample_wrapped = %Q({ 'id' => "img-x", 'kind' => 'image',\n  'source' => { 'kind' => 'url', 'url' => url } })
check(det.call(sample_flat).size == 1,
      'PLANTED-DEFECT GUARD: a flat image literal is detected', fails)
check(det.call(sample_nested).empty?,
      'PLANTED-DEFECT GUARD: a nested image literal is NOT flagged', fails)
check(det.call(sample_wrapped).empty?,
      'PLANTED-DEFECT GUARD: a WRAPPED nested literal is NOT flagged', fails)

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
