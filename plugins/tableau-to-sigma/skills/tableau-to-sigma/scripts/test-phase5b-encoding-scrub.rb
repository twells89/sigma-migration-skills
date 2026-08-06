#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K11: the Phase-5b visual-QA render threads must scrub
# non-UTF-8 subprocess output before calling String#strip / each_line.
#
# On Windows the PNG-export subprocess emits console-codepage bytes. Ruby tags
# Open3 output UTF-8, so `o.strip` on invalid bytes raises
# Encoding::CompatibilityError and kills the render thread.
#
# The scrub idiom already exists at migrate-tableau.rb:1191 and :2105 — a keyword
# grep therefore reports this "fixed" when it is not. This test pins the ACTUAL
# failure site instead. Deterministic + offline.

DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'Part A — source contract: the Phase-5b render site scrubs before strip'
src = File.read(File.join(DIR, 'migrate-tableau.rb'))
# Anchor on the 5b thread's own Open3 capture — NOT on 'sigma-export-png.py',
# which also appears at :1412 inside a help string; anchoring there spans ~3900
# lines and swallows the unrelated scrub at :2105, making this test false-PASS.
block = src[/Open3\.capture2e\(\{ 'SIGMA_API_TOKEN' => vqa_tok \}.*?end\.each\(&:join\)/m].to_s
check(!block.empty?, 'located the Phase-5b render block', fails)
check(block.include?('force_encoding'),
      'Phase-5b block force_encodings the subprocess output', fails)
check(block.match?(/\.scrub/),
      'Phase-5b block scrubs the subprocess output', fails)
# The scrub must come BEFORE the first use of `o`.
if block.include?('force_encoding')
  scrub_at = block.index('force_encoding')
  use_at   = block.index('o.each_line') || block.index('o.strip')
  check(use_at.nil? || scrub_at < use_at,
        'the scrub precedes the first use of the captured output', fails)
end

puts 'Part B — behavioral: the shipped idiom survives invalid UTF-8'
raw = "ok\xFF\xFE bad\n".dup.force_encoding(Encoding::ASCII_8BIT)
scrubbed = raw.force_encoding(Encoding::UTF_8)
scrubbed = scrubbed.scrub('?') unless scrubbed.valid_encoding?
begin
  scrubbed.strip
  scrubbed.each_line(&:rstrip)
  check(true, 'scrubbed output survives strip + each_line', fails)
rescue StandardError => e
  check(false, "scrubbed output still raises: #{e.class}", fails)
end

puts 'Part C — planted-defect guard: UNSCRUBBED input must blow up'
# If this ever stops raising, Part B proves nothing and this test is vacuous.
begin
  bad = "ok\xFF\xFE bad\n".dup.force_encoding(Encoding::UTF_8)
  bad.strip
  bad =~ / /              # regex against invalid UTF-8 is the raising operation
  check(false, 'PLANTED-DEFECT GUARD: unscrubbed input should have raised', fails)
rescue ArgumentError, Encoding::CompatibilityError
  check(true, 'PLANTED-DEFECT GUARD: unscrubbed input raises as expected', fails)
end

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
