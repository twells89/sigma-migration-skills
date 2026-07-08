#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for detect_multi_datasource in scan-workbook-gaps.rb (Tier 1 #1,
# MSP-Dashboard failure 2026-07-08): a workbook whose worksheets have DIFFERENT
# primary datasources must be flagged ❌-unhandled (the local converter collapses
# to the primary and drops the others), while single-primary workbooks and pure
# blends must NOT be flagged.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'twb_xml'
# Requiring the script defines its functions without running main
# ($PROGRAM_NAME guard). Silence any load-time noise.
require_relative 'scan-workbook-gaps'

FAILS = []
def check(cond, msg)
  puts((cond ? '  ok  ' : '  FAIL ') + msg)
  FAILS << msg unless cond
end

def fires?(xml_str)
  feat, detail = detect_multi_datasource(TwbXml.parse(xml_str))
  [!feat.nil? && feat[:status] == :unhandled, detail]
end

# --- multi: two datasources, each the primary of a different worksheet -------
multi = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='sales' caption='Sales Funnel'><connection class='snowflake' server='x' dbname='EDNA'/></datasource>
    <datasource name='sku' caption='SKU Master GA'><connection class='snowflake' server='x' dbname='BBBS'/></datasource>
    <datasource name='Parameters'><connection class='sqlproxy'/></datasource>
  </datasources>
  <worksheet name='Funnel'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
  <worksheet name='SKUs'><table><view><datasources><datasource name='sku'/></datasources></view></table></worksheet>
  </workbook>
XML
fired, detail = fires?(multi)
check(fired, 'multi-datasource workbook is flagged unhandled')
check(detail && detail.length == 2, "detail lists both datasources (got #{detail&.length})")
check(detail && detail.map { |d| d['caption'] }.sort == ['SKU Master GA', 'Sales Funnel'],
      'detail carries datasource captions')
check(detail && detail.find { |d| d['caption'] == 'Sales Funnel' }['worksheets'] == ['Funnel'],
      'detail maps each datasource to its worksheet(s)')

# --- single primary (two sheets, same source): must NOT fire ----------------
single = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='sales' caption='Sales'><connection class='snowflake' server='x' dbname='EDNA'/></datasource>
  </datasources>
  <worksheet name='A'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
  <worksheet name='B'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
  </workbook>
XML
check(!fires?(single)[0], 'single-datasource workbook is NOT flagged')

# --- Parameters-only second source: must NOT fire ---------------------------
param = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='sales' caption='Sales'><connection class='snowflake' server='x' dbname='EDNA'/></datasource>
    <datasource name='Parameters'><connection class='sqlproxy'/></datasource>
  </datasources>
  <worksheet name='A'><table><view><datasources><datasource name='sales'/></datasources></view></table></worksheet>
  </workbook>
XML
check(!fires?(param)[0], 'Parameters synthetic source does not count as a second datasource')

# --- pure blend (both sources on ONE sheet → single primary): must NOT fire -
blend = <<~XML
  <?xml version='1.0'?>
  <workbook><datasources>
    <datasource name='sales' caption='Sales'><connection class='snowflake' server='x' dbname='EDNA'/></datasource>
    <datasource name='sku' caption='SKU'><connection class='snowflake' server='x' dbname='EDNA'/></datasource>
  </datasources>
  <worksheet name='Blended'><table><view><datasources>
    <datasource name='sales'/><datasource name='sku'/>
  </datasources></view></table></worksheet>
  </workbook>
XML
check(!fires?(blend)[0], 'single-sheet blend (one primary) is left to the blend detector, not flagged here')

puts(FAILS.empty? ? "\nall multi-datasource-gap tests passed" : "\n#{FAILS.length} FAILED")
exit(FAILS.empty? ? 0 : 1)
