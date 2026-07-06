#!/usr/bin/env ruby
# Regression test: build-dashboard-layout.rb must never emit the same element id
# twice in one layout. The container-tree path used to append the dedicated
# header-title element (id "title-*") a SECOND time via the unplaced-elements
# safety net — Sigma rejects the whole layout PUT on a duplicate id ("Duplicate
# layout element id"), dropping the page to a stacked fallback (found in the
# #259 live E2E on "Orders Conversion Test"). Offline, creds-free.
# Run: ruby scripts/test-layout-dedup.rb
require 'json'
require 'tmpdir'

LAYOUT = File.join(__dir__, 'build-dashboard-layout.rb')
$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

def dup_ids(xml)
  ids = xml.scan(/elementId="([^"]+)"/).flatten
  ids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
end

def build(dl, wb)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'dl.json'), JSON.generate(dl))
    File.write(File.join(d, 'wb.json'), JSON.generate(wb))
    out = File.join(d, 'layout.xml')
    system(RbConfig.ruby, LAYOUT, '--layout', File.join(d, 'dl.json'),
           '--wb-ids', File.join(d, 'wb.json'), '--out', out,
           out: File::NULL, err: File::NULL)
    File.exist?(out) ? File.read(out) : nil
  end
end
require 'rbconfig'

# Tree path (a filter zone forces build_page_from_tree) with a title element in
# the workbook that has NO matching Tableau zone — exactly the case that used to
# double-place it (header band + bottom safety band).
DL = [{
  'dashboard' => 'Overview',
  'zones' => [
    { 'id' => 'z1', 'kind' => 'chart', 'caption' => 'Sales', 'x_pct' => 20, 'y_pct' => 10, 'w_pct' => 80, 'h_pct' => 80, 'measures' => ['Sales'] },
    { 'id' => 'zf', 'kind' => 'filter', 'caption' => 'Region', 'x_pct' => 0, 'y_pct' => 10, 'w_pct' => 20, 'h_pct' => 80 }
  ],
  'zone_tree' => [
    { 'id' => 'zf', 'kind' => 'filter', 'caption' => 'Region', 'x_pct' => 0, 'y_pct' => 10, 'w_pct' => 20, 'h_pct' => 80 },
    { 'id' => 'z1', 'kind' => 'chart', 'caption' => 'Sales', 'x_pct' => 20, 'y_pct' => 10, 'w_pct' => 80, 'h_pct' => 80 }
  ]
}]
WB = { 'pages' => [
  { 'name' => 'Data', 'id' => 'page-data', 'elements' => [{ 'id' => 'master-1', 'name' => 'M' }] },
  { 'name' => 'Overview', 'id' => 'page-ov', 'elements' => [
    { 'id' => 'title-overview', 'name' => 'title', 'kind' => 'text' },
    { 'id' => 'el-sales', 'name' => 'Sales', 'kind' => 'bar-chart' },
    { 'id' => 'ctl-region', 'name' => 'Region', 'kind' => 'control' }
  ] }
] }

xml = build(DL, WB)
ok('layout XML produced', !xml.nil?)
if xml
  dups = dup_ids(xml)
  ok("no duplicate element ids (dups: #{dups.inspect})", dups.empty?)
  title_count = xml.scan(/elementId="title-overview"/).length
  ok("title element placed exactly once (got #{title_count})", title_count == 1)
  ok('title element still present in the layout', title_count >= 1)
end

puts($fail.zero? ? "\nALL PASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
