#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for K2: page ids must contain only [a-z0-9-].
#
# The old slug replaced a hand-listed deny-list (/ ( ) % and space) and left
# every other punctuation mark intact, so a Tableau page named "How many weeks?"
# produced `page-how-many-weeks?`. Deny-lists rot; this pins an allow-list.
# Deterministic + offline.

DIR = __dir__
fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Mirror of the shipped op — keep in lock-step with build-workbook-spec.rb.
def page_slug(name)
  name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').sub(/\A-/, '').sub(/-\z/, '')[0..40].to_s
end

puts 'Part A — punctuation is stripped'
{
  'How many weeks?'      => 'how-many-weeks',
  'Sales (YTD) / Region' => 'sales-ytd-region',
  'Margin % & Growth!'   => 'margin-growth',
  'Q1 2026 — Overview'   => 'q1-2026-overview',
  'Trailing 30d #1'      => 'trailing-30d-1'
}.each do |input, want|
  got = page_slug(input)
  check(got == want, "#{input.inspect} -> #{got.inspect} (want #{want.inspect})", fails)
end

puts 'Part B — output charset is safe for every input'
['A?B', 'x' * 80, '///', 'Ünïcodé Pagé', '', '   '].each do |input|
  got = page_slug(input)
  check(got.match?(/\A[a-z0-9-]*\z/),
        "#{input.inspect} -> #{got.inspect} is [a-z0-9-] only", fails)
end

puts 'Part C — the shipped source uses the allow-list slug'
src = File.read(File.join(DIR, 'build-workbook-spec.rb'))
check(src.match?(/gsub\(\/\[\^a-z0-9\]\+\/, '-'\)/),
      'build-workbook-spec.rb uses an allow-list slug', fails)
check(!src.include?("%w[ / ( ) %].each"),
      'the hand-listed deny-list is gone', fails)

puts 'Part D — planted-defect guard: the OLD slug really did leak punctuation'
old_slug = lambda do |name|
  s = name.to_s.downcase
  %w[/ ( ) %].each { |ch| s = s.tr(ch, '-') }
  s.tr(' ', '-').gsub(/-+/, '-').sub(/^-/, '').sub(/-$/, '')[0..40]
end
check(old_slug.call('How many weeks?').include?('?'),
      'PLANTED-DEFECT GUARD: the old slug leaks "?"', fails)
check(!page_slug('How many weeks?').include?('?'),
      'PLANTED-DEFECT GUARD: the new slug does not', fails)

puts(fails.empty? ? "\nALL PASS" : "\n#{fails.size} FAILURE(S)")
exit(fails.empty? ? 0 : 1)
