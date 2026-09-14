#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Lint: every Sigma `/columns` endpoint read in this skill's scripts must be
# exhaustively paginated.
#
# THE RULE: every call site that issues an HTTP GET to `/columns` must have its
# exhaustive reader in the same local code window. Warehouse-catalog reads
# (`/v2/connections/tables/<inode>/columns`) must use
# `WarehouseColumnsPagination.list`; workbook/data-model reads use
# `Sigma.list_entries` or a local cursor loop. Sigma's server
# DEFAULT page size is 50, so a bare first-page GET silently truncates any
# table, workbook, or data model with more than 50 columns. Unpaginated
# single-page reads reached END OF SUPPORT on 2026-06-02 (see the
# `list_entries` doc comment in shared/lib/sigma_rest.rb) — a script that
# still reads only page one is relying on a shape Sigma no longer guarantees.
#
# WHY THIS LINT EXISTS: `Sigma.list_entries` has existed since 2026-06, and
# its own comment records this exact bug class, but the fix drifted to only
# two of eleven callers (migrate-tableau.rb and assert-wb-refs-resolve.rb).
# The other nine scripts in this directory independently grew their own
# first-page-only `/columns` GETs and silently truncated wide tables at the
# 50-column server default until PRs #560 and #565 routed all nine through
# `list_entries` (or, for assert-phase6-ran.rb, a local `nextPage` loop — see
# below). Nothing stopped a twelfth script from doing the same thing again
# except this lint.
#
# This is a bounded lexical check, not a full Ruby data-flow analyzer, but it
# judges each endpoint occurrence independently; an unrelated compliant call
# elsewhere in the same file can no longer hide a new first-page-only read.
#
# Usage: ruby scripts/test-no-unpaginated-column-reads.rb
#        (the directory scanned is derived from this file's own location, so
#        it works whether invoked from the skill directory or elsewhere)

SCRIPTS_DIR = File.expand_path(__dir__)

# In-scope path pattern: a REAL `/columns` request path, not a prose mention
# of the word "columns" (e.g. "rowsBy/columnsBy", "the /columns endpoint").
# Matches only where `/columns` is immediately followed by the closing quote
# of a string literal or a `?` opening a query string — i.e. `.../columns"`
# or `.../columns?...` — which is how every actual GET path in this
# directory is written.
COLUMNS_PATH_RE = %r{/columns["?]}.freeze

# Files exempt from this rule, keyed by basename, valued by the reason the
# exemption is justified.
#
# EXPECTED EMPTY. An entry here is only justified after tracing a flagged
# file's receiver and proving the `entries` it reads come from a local JSON
# ledger already written to disk by a prior phase — NOT a live REST
# response — i.e. the `/columns` text matched but no HTTP GET actually hits
# Sigma's API at that call site. An allowlist entry added for a genuine,
# un-paginated REST `/columns` read is not a decision — it is a silencer. It
# hides the exact defect this lint exists to catch.
ALLOWLIST = {}.freeze

files = Dir.glob(File.join(SCRIPTS_DIR, '*.rb')).sort
checked = 0
failures = []

files.each do |path|
  base = File.basename(path)
  next if base.start_with?('test-')
  next if ALLOWLIST.key?(base)

  src = File.read(path)
  lines = src.lines
  lines.each_with_index do |line, index|
    next unless line =~ COLUMNS_PATH_RE
    next if line.lstrip.start_with?('#')
    checked += 1
    from = [index - 20, 0].max
    window = lines[from, 41].join
    warehouse = line.include?('/v2/connections/tables/')
    ok = if warehouse
           window.include?('WarehouseColumnsPagination.list')
         else
           window.include?('list_entries') ||
             (window.match?(/limit=\d+/) &&
              window.match?(/\[['"]nextPage(?:Token)?['"]\]/))
         end
    failures << [base, index + 1, warehouse ? 'WarehouseColumnsPagination.list' : 'Sigma.list_entries/local cursor loop'] unless ok
  end
end

puts "test-no-unpaginated-column-reads.rb — every /columns read must paginate"
puts ''
puts "Allowlist (#{ALLOWLIST.length} entr#{ALLOWLIST.length == 1 ? 'y' : 'ies'}):"
if ALLOWLIST.empty?
  puts '  (none)'
else
  ALLOWLIST.each { |name, reason| puts "  #{name}: #{reason}" }
end
puts ''

if failures.any?
  failures.each do |base, line, expected|
    warn "[FAIL] #{base}: /columns call site at line #{line} is not locally paired with #{expected}"
  end
  warn ''
  warn "SUMMARY: #{checked} in-scope file(s) checked, #{ALLOWLIST.length} allowlisted, #{failures.length} failing."
  exit 1
end

puts "SUMMARY: #{checked} in-scope file(s) checked, #{ALLOWLIST.length} allowlisted, 0 failing."
exit 0
