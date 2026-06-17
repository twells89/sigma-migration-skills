#!/usr/bin/env ruby
# test-build-oracle-sql.rb — unit smoke test for build-oracle-sql.rb (DAX→warehouse
# SQL oracle for offline Phase 6 parity). Pure, no network. Run:
#   ruby scripts/test-build-oracle-sql.rb
require_relative 'build-oracle-sql'

$fail = 0
def ok(name, cond); puts((cond ? '  ok  ' : 'FAIL  ') + name); $fail += 1 unless cond; end

# ---- transpile(): aggregate grammar ----
ok 'SUM',            OracleSql.transpile('SUM(Orders[Sales])') == 'SUM(SALES)'
ok 'AVERAGE->AVG',   OracleSql.transpile('AVERAGE(Orders[Discount])') == 'AVG(DISCOUNT)'
ok 'MIN',            OracleSql.transpile('MIN(Orders[Sales])') == 'MIN(SALES)'
ok 'DISTINCTCOUNT',  OracleSql.transpile('DISTINCTCOUNT(Orders[Order Id])') == 'COUNT(DISTINCT ORDER_ID)'
ok 'COUNTROWS->*',   OracleSql.transpile('COUNTROWS(Orders)') == 'COUNT(*)'
ok 'DIVIDE ratio',   OracleSql.transpile('DIVIDE(SUM(Orders[Profit]), SUM(Orders[Sales]))') == 'SUM(PROFIT) / NULLIF(SUM(SALES),0)'
ok 'quoted table',   OracleSql.transpile("SUM('Fact Orders'[Sales])") == 'SUM(SALES)'

# ---- transpile(): unsupported -> nil (forces online/waiver fallback) ----
ok 'RANKX nil',      OracleSql.transpile('RANKX(ALL(Orders[Region]), [Total Sales])').nil?
ok 'CALCULATE nil',  OracleSql.transpile('CALCULATE(SUM(Orders[Sales]), Orders[Region]="West")').nil?
ok 'SAMEPERIOD nil', OracleSql.transpile('CALCULATE(SUM(F[Net]), SAMEPERIODLASTYEAR(D[Date]))').nil?

# ---- explicit column_map wins over the heuristic (PromoteHeaders / renamed) ----
ok 'column_map honored', OracleSql.transpile('SUM(Cust[Customer Name])', { 'Customer Name' => 'C2' }) == 'SUM(C2)'
fb = []
OracleSql.transpile('SUM(Orders[Sales])', {}, fb)
ok 'fallback tracked',   fb == ['Sales']

# ---- chart_sql(): scalar + grouped + unsupported ----
sc = OracleSql.chart_sql('Total Sales', 'SUM(Orders[Sales])', 'DB.SCH.T')
ok 'scalar sql', sc['supported'] && sc['sql'] == 'SELECT SUM(SALES) AS "Total Sales" FROM DB.SCH.T' && sc['dim_col'].nil?

gr = OracleSql.chart_sql('Sales by Region', 'SUM(Orders[Sales])', 'DB.SCH.T', dim: 'Region')
ok 'grouped sql', gr['supported'] &&
   gr['sql'] == 'SELECT REGION AS "Region", SUM(SALES) AS "Sales by Region" FROM DB.SCH.T GROUP BY REGION ORDER BY 2 DESC' &&
   gr['dim_col'] == 'Region'

uns = OracleSql.chart_sql('Exotic', 'RANKX(ALL(Orders[Region]),[X])', 'DB.SCH.T')
ok 'unsupported flagged', uns['supported'] == false && uns['reason'].include?('unsupported DAX')

nofqn = OracleSql.chart_sql('NoFqn', 'SUM(Orders[Sales])', nil)
ok 'missing fqn flagged', nofqn['supported'] == false && nofqn['reason'].include?('no fqn')

puts(($fail.zero? ? 'ALL PASS' : "#{$fail} FAILED"))
exit($fail.zero? ? 0 : 1)
