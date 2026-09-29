#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline unit test for scripts/lib/sql_ident_check.rb + the check-sql-idents.rb
# CLI (hackathon F2 guard: unquoted upper-snake identifiers vs spaced/mixed-case
# live Snowflake columns). Deterministic — no network, no creds.
#
# Usage:  ruby scripts/test-sql-ident-check.rb

require 'json'
require 'tmpdir'
require 'open3'
require 'rbconfig'
require_relative 'lib/sql_ident_check'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

S = SqlIdentCheck

# Live catalog: spaced/mixed-case names (the field-report class) + upper-snake.
CATALOG = {
  'DEAL_FACTS' => ['Customer Ref ID', 'Region View', 'Deal Value', 'STAGE_NAME'],
  'ACCOUNT_DIM' => ['Account Name', 'ACCOUNT_ID']
}.freeze

puts 'Part A — the F2 bug shape: unquoted upper-snake vs spaced live columns'
bug_sql = 'SELECT CUSTOMER_REF_ID, COUNT(CASE WHEN REGION_VIEW=\'West\' AND DEAL_VALUE<>0 THEN 1 END) AS N ' \
          'FROM ANALYTICS.SALES.DEAL_FACTS GROUP BY 1'
res = S.check(bug_sql, CATALOG)
check(!res[:ok], 'bug SQL flagged not-ok', fails)
names = res[:unknown].map { |u| u[:identifier] }
check(names.include?('CUSTOMER_REF_ID'), 'CUSTOMER_REF_ID reported unknown', fails)
check(names.include?('REGION_VIEW') && names.include?('DEAL_VALUE'), 'REGION_VIEW + DEAL_VALUE reported', fails)
sug = res[:unknown].to_h { |u| [u[:identifier], u[:suggestion]] }
check(sug['CUSTOMER_REF_ID'] == '"Customer Ref ID"', 'quoted-fix suggestion CUSTOMER_REF_ID → "Customer Ref ID"', fails)
check(sug['REGION_VIEW'] == '"Region View"', 'quoted-fix suggestion REGION_VIEW → "Region View"', fails)

puts 'Part B — the FIXED emission passes clean'
good_sql = %{SELECT "Customer Ref ID" AS CUSTOMER_REF_ID, COUNT(CASE WHEN "Region View"='West' AND "Deal Value"<>0 THEN 1 END) AS MAX_WEST } +
           'FROM ANALYTICS.SALES.DEAL_FACTS GROUP BY 1'
res = S.check(good_sql, CATALOG)
check(res[:ok], "correctly-quoted LOD helper SQL is clean (got #{res[:unknown].inspect})", fails)
check(S.check('SELECT STAGE_NAME AS STAGE_NAME FROM DEAL_FACTS', CATALOG)[:ok],
      'bare upper-snake identifier matching a real upper-snake column is clean', fails)

puts 'Part C — quoted identifiers are case-EXACT'
res = S.check('SELECT "CUSTOMER REF ID" FROM DEAL_FACTS', CATALOG)
check(!res[:ok], 'quoted wrong-case identifier flagged', fails)
check(res[:unknown].first[:suggestion] == '"Customer Ref ID"',
      'case-exact fix suggested for wrong-case quoted ident', fails)
check(S.check('SELECT "Customer Ref ID" FROM DEAL_FACTS', CATALOG)[:ok], 'exact-case quoted ident clean', fails)

puts 'Part D — self-aliased bug shape must not self-whitelist'
res = S.check('SELECT CUSTOMER_REF_ID AS CUSTOMER_REF_ID FROM DEAL_FACTS', CATALOG)
check(!res[:ok], 'CUSTOMER_REF_ID AS CUSTOMER_REF_ID still flagged (source position)', fails)

puts 'Part E — output aliases / CTEs / derived tables are not false-positives'
wrapped = %{SELECT "Customer Ref ID" AS CUSTOMER_REF_ID, SUM("Deal Value") AS TOTAL_VALUE FROM (
SELECT d."Customer Ref ID", d."Deal Value" FROM ANALYTICS.SALES.DEAL_FACTS d
) __base GROUP BY 1}
check(S.check(wrapped, CATALOG)[:ok], 'subquery wrap + derived alias __base clean', fails)
cte = 'WITH base AS (SELECT "Region View" AS RV, SUM("Deal Value") AS DV FROM DEAL_FACTS GROUP BY 1) ' \
      'SELECT RV, DV, SUM(DV) OVER (PARTITION BY RV) AS W FROM base'
check(S.check(cte, CATALOG)[:ok], 'window-helper CTE: inner aliases referenced outside are clean', fails)
cte_spec = {
  'pages' => [{ 'elements' => [{
    'source' => { 'kind' => 'sql', 'statement' => cte }
  }] }]
}
check(S.referenced_tables(cte_spec) == ['DEAL_FACTS'],
      'referenced_tables excludes CTE names and returns only physical tables', fails)

puts 'Part F — table-alias prefixes resolve per-table'
joined = 'SELECT __f."Customer Ref ID" AS CUSTOMER_REF_ID, __d0."Account Name" AS ACCOUNT_NAME ' \
         'FROM ANALYTICS.SALES.DEAL_FACTS __f LEFT JOIN ANALYTICS.SALES.ACCOUNT_DIM __d0 ' \
         'ON __f.STAGE_NAME = __d0.ACCOUNT_ID GROUP BY 1, 2'
check(S.check(joined, CATALOG)[:ok], 'alias-qualified refs check against the right table', fails)
wrong = 'SELECT __d0."Customer Ref ID" FROM ANALYTICS.SALES.ACCOUNT_DIM __d0'
res = S.check(wrong, CATALOG)
check(!res[:ok], 'a column qualified to the WRONG table is flagged', fails)
check(res[:unknown].first[:table] == 'ACCOUNT_DIM', 'wrong-table finding names the scoped table', fails)

puts 'Part G — misc: literals, functions, comments, no-catalog scope'
check(S.check("SELECT DATE_TRUNC('month', \"Deal Value\") AS M FROM DEAL_FACTS -- CUSTOMER_REF_ID\n", CATALOG)[:ok],
      'string literals, function names and comments are ignored', fails)
check(S.check('SELECT ANYTHING FROM T', {})[:ok],
      'empty catalog → cannot judge → clean (caller must supply columns)', fails)

puts 'Part H — spec helpers'
spec = { 'pages' => [{ 'name' => 'Page 1', 'elements' => [
  { 'id' => 'el1', 'name' => 'LOD Helper', 'kind' => 'table',
    'source' => { 'kind' => 'sql', 'statement' => bug_sql } },
  { 'id' => 'el2', 'name' => 'Base', 'kind' => 'table',
    'source' => { 'kind' => 'warehouse-table', 'path' => %w[ANALYTICS SALES DEAL_FACTS] } }
] }] }
els = S.sql_elements(spec)
check(els.size == 1 && els.first['name'] == 'LOD Helper', 'sql_elements picks only kind:"sql"', fails)
check(S.referenced_tables(spec) == ['DEAL_FACTS'], "referenced_tables → DEAL_FACTS (got #{S.referenced_tables(spec).inspect})", fails)

puts 'Part J — W2.9 emission-legality oracle (the single authority for live-SQL identifiers)'
# Admit, byte-identical: a legal bare identifier emits EXACTLY as recorded
# (the no-false-trip pin — plain ORDER_KEY probes must not change a byte).
%w[ORDER_KEY ENTITY_ID _private Col$1 ANALYTICS].each do |ok|
  check(S.legal_bare?(ok), "legal_bare? admits #{ok}", fails)
  check(S.sql_ident(ok) == ok, "sql_ident(#{ok}) is byte-identical (got #{S.sql_ident(ok).inspect})", fails)
  check(S.illegal_reason(ok).nil?, "illegal_reason(#{ok}) is nil", fails)
end
# Admit, quoted: a spaced/mixed-case PHYSICAL name is legal only in quotes.
check(S.sql_ident('Order Key') == '"Order Key"', 'spaced name emits double-quoted', fails)
check(S.sql_ident('order key') == '"order key"', 'lower-case spaced name emits double-quoted', fails)
check(S.sql_ident('1STARTS_WITH_DIGIT') == '"1STARTS_WITH_DIGIT"', 'digit-leading name emits double-quoted', fails)
check(S.illegal_reason('Order Key').nil?, 'quoted-legal name has no illegal_reason', fails)
# Refuse (refuse-don't-guess): parenthesis residue of a role-disambiguation
# label, GUID-shaped field ids, quotes/control chars, empty — nil, with a
# named reason; the caller records a clean error, never guesses into SQL.
{
  'PRODUCT_KEY_(PRODUCT_DIM)'            => /parenthesis residue/,
  'PRODUCT_KEY_(PRODUCT_DIM_(EXTRACT))'  => /parenthesis residue/,
  'AB12CD34-0000-1111-2222-333344445555' => /GUID-shaped/,
  'ABCDEF0123456789-ABCDEF0123456789'    => /GUID-shaped/,
  %(BAD"NAME)                            => /double quote/,
  "TAB\tNAME"                            => /control characters/,
  ''                                     => /empty identifier/,
  '   '                                  => /empty identifier/
}.each do |bad, reason_re|
  check(S.sql_ident(bad).nil?, "sql_ident refuses #{bad.inspect}", fails)
  check(S.illegal_reason(bad).to_s =~ reason_re,
        "illegal_reason(#{bad.inspect}) names the class (got #{S.illegal_reason(bad).inspect})", fails)
end
# guid_shaped? is the one copy of the shape (join_plan.guid_like? delegates).
check(S.guid_shaped?('AB12CD34-0000-1111-2222-333344445555'), 'guid_shaped? canonical 8-4-4-4-12', fails)
check(!S.guid_shaped?('ENTITY_ID'), 'guid_shaped? rejects a plain identifier', fails)

puts 'Part I — CLI end-to-end (exit codes + fix list)'
Dir.mktmpdir do |dir|
  spec_path = File.join(dir, 'dm-spec.json')
  File.write(spec_path, JSON.pretty_generate(spec))
  cols_path = File.join(dir, 'columns-DEAL_FACTS.json')
  File.write(cols_path, JSON.pretty_generate(
    'path' => %w[ANALYTICS SALES DEAL_FACTS],
    'columns' => CATALOG['DEAL_FACTS'].map { |n| { 'name' => n, 'type' => 'text' } }))
  cli = File.join(__dir__, 'check-sql-idents.rb')

  out, _e, st = Open3.capture3(RbConfig.ruby, cli, '--dm-spec', spec_path, '--list-tables')
  check(st.success? && out.include?('DEAL_FACTS'), '--list-tables prints the referenced table', fails)

  out, _e, st = Open3.capture3(RbConfig.ruby, cli, '--dm-spec', spec_path, '--columns', "DEAL_FACTS=#{cols_path}")
  check(st.exitstatus == 1, 'bug spec → exit 1', fails)
  check(out.include?('CUSTOMER_REF_ID → "Customer Ref ID"'), 'CLI prints the quoted-fix line', fails)
  check(out.include?('LOD Helper'), 'CLI names the offending element', fails)

  fixed = JSON.parse(JSON.generate(spec))
  fixed['pages'][0]['elements'][0]['source']['statement'] = good_sql
  File.write(spec_path, JSON.pretty_generate(fixed))
  _o, _e, st = Open3.capture3(RbConfig.ruby, cli, '--dm-spec', spec_path, '--columns', "DEAL_FACTS=#{cols_path}")
  check(st.success?, 'fixed spec → exit 0', fails)

  no_sql = { 'pages' => [{ 'elements' => [spec['pages'][0]['elements'][1]] }] }
  File.write(spec_path, JSON.pretty_generate(no_sql))
  out, _e, st = Open3.capture3(RbConfig.ruby, cli, '--dm-spec', spec_path, '--columns', "DEAL_FACTS=#{cols_path}")
  check(st.success? && out.include?('nothing to preflight'), 'spec without sql elements → exit 0, stated', fails)

  # sql elements present but no --columns supplied → usage error with guidance
  File.write(spec_path, JSON.pretty_generate(spec))
  _o, e2, st = Open3.capture3(RbConfig.ruby, cli, '--dm-spec', spec_path)
  check(st.exitstatus == 2 && e2.include?('--list-tables'), 'sql elements but no --columns → exit 2 with guidance', fails)
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
