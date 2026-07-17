#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for #7a — MechanicalSpecs.derive_db_schema_from_twb.
#
# Field-caught on 2 live runs: a live-warehouse workbook whose db.schema the
# operator did not pin defaulted to the CSA.TJ placeholder, which 404'd on every
# Sigma catalog sync; the real db.schema was only recoverable by hand-reading the
# .twb. This derives it so all downstream consumers inherit the real path — while
# NEVER touching embedded-extract (CSA.TJ is the correct landing target there) or
# sqlproxy (hydrate resolves those) sources.
#
# Usage: ruby scripts/test-db-schema-propagation.rb
require 'tempfile'
require_relative 'mechanical-specs'

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def derive(xml)
  t = Tempfile.new(['t7a-', '.twb'])
  t.write(xml)
  t.close
  r = MechanicalSpecs.derive_db_schema_from_twb(t.path)
  t.unlink
  r
end

def twb(conn_attrs, table)
  <<~XML
    <?xml version='1.0'?>
    <workbook>
      <datasources>
        <datasource name='DS1'>
          <connection class='federated'>
            <named-connections>
              <named-connection>
                <connection #{conn_attrs}/>
              </named-connection>
            </named-connections>
            <relation type='table' table='#{table}'/>
          </connection>
        </datasource>
      </datasources>
    </workbook>
  XML
end

# Case A — 2-part table + conn dbname/schema
db, sch = derive(twb("class='snowflake' dbname='REALDB' schema='REALSCH'", '[REALSCH].[ORDER_FACT]'))
check([db, sch] == %w[REALDB REALSCH], "A: 2-part table + conn dbname → [REALDB, REALSCH] (got [#{db}, #{sch}])", fails)

# Case B — full 3-part table path wins over conn attrs
db, sch = derive(twb("class='snowflake' dbname='IGNORED' schema='IGNORED'", '[REALDB].[REALSCH].[ORDER_FACT]'))
check([db, sch] == %w[REALDB REALSCH], "B: 3-part table → [REALDB, REALSCH] (got [#{db}, #{sch}])", fails)

# Case C — embedded extract → NEVER derive (CSA.TJ landing is correct)
db, sch = derive(twb("class='hyper'", '[Extract].[ORDER_FACT]'))
check([db, sch] == [nil, nil], "C: embedded (hyper) → [nil, nil] so CSA.TJ default is preserved (got [#{db}, #{sch}])", fails)

# Case D — published/sqlproxy stub → NEVER derive (hydrate resolves it)
db, sch = derive(twb("class='sqlproxy'", '[sqlproxy]'))
check([db, sch] == [nil, nil], "D: sqlproxy stub → [nil, nil] (got [#{db}, #{sch}])", fails)

# Case E — 1-part table falls back to conn dbname/schema
db, sch = derive(twb("class='snowflake' dbname='REALDB' schema='REALSCH'", '[ORDER_FACT]'))
check([db, sch] == %w[REALDB REALSCH], "E: 1-part table → conn dbname/schema (got [#{db}, #{sch}])", fails)

# Case F — live warehouse but no resolvable db/schema → [nil, nil] (no fabrication)
db, sch = derive(twb("class='snowflake'", '[ORDER_FACT]'))
check([db, sch] == [nil, nil], "F: no db/schema anywhere → [nil, nil], never fabricated (got [#{db}, #{sch}])", fails)

# Case G — missing file → [nil, nil], no crash
check(MechanicalSpecs.derive_db_schema_from_twb('/nonexistent/x.twb') == [nil, nil], 'G: missing file → [nil, nil]', fails)

puts
if fails.empty?
  puts 'OK — db/schema propagation derives live-warehouse paths, skips embedded/sqlproxy, never fabricates'
  exit 0
else
  warn "FAIL — #{fails.size} check(s):"
  fails.each { |f| warn "  - #{f}" }
  exit 1
end
