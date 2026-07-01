#!/usr/bin/env ruby
# Regression test for Phase-1 composition/style extraction in parse-twb-layout.rb
# (gaps B2 container tints / E1 control display). Tableau stores a dashboard
# zone's fill + border on the zone's DIRECT <zone-style> child, and a
# quick-filter/parameter display mode on the zone `mode` attr:
#
#   <zone …><zone-style>
#     <format attr='background-color' value='#07b4a24e'/>   ← region-card tint (8-digit alpha)
#     <format attr='border-color' value='#07b4a2'/>
#   </zone-style></zone>
#   <zone type-v2='filter' mode='compact' …/>               ← dropdown (Sigma controlType:list)
#
# Asserts, end-to-end through the ACTUAL parse-twb-layout.rb (no Tableau/Sigma
# calls), that the parser now surfaces these signals (previously dropped):
#   1. flat `zones`: a tinted container carries fill_color (8-digit alpha, verbatim)
#      + border_color.
#   2. a fully-transparent fill (#00000000) is NOT emitted (no visible tint).
#   3. a filter zone with mode='compact' carries control_display='compact'.
#   4. the nested `zone_tree` container node also carries fill_color.
#
# Usage:  ruby scripts/test-zone-style-extraction.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Mirrors the "Job Loss from Mass Deportations" benchmark: a region column with a
# teal 8-digit-alpha tint + border, a chart zone with a transparent fill, and a
# compact (dropdown) filter control.
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[Region]' datatype='string' role='dimension' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Sales by Region'><table><view><datasource-dependencies datasource='federated.x' /></view></table></worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Regions'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' type-v2='layout-flow' param='vert' x='0' y='0' w='25000' h='100000'>
              <zone-style>
                <format attr='border-style' value='none' />
                <format attr='background-color' value='#07b4a24e' />
                <format attr='border-color' value='#07b4a2' />
              </zone-style>
              <zone id='3' type-v2='filter' param='[federated.x].[none:Region:nk]' mode='compact' x='0' y='0' w='25000' h='40000' />
            </zone>
            <zone id='5' name='Sales by Region' x='25000' y='0' w='75000' h='100000'>
              <zone-style>
                <format attr='background-color' value='#00000000' />
              </zone-style>
            </zone>
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

layout = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  layout = JSON.parse(File.read(lay))
end

dash  = (layout || []).find { |x| x['dashboard'] == 'Regions' }
zones = (dash && dash['zones']) || []

# ---- 1. tinted container: fill_color (8-digit alpha, verbatim) + border_color
z2 = zones.find { |z| z['id'] == '2' }
check(z2 && z2['fill_color'] == '#07b4a24e',
      "flat zones: tinted container keeps 8-digit-alpha fill_color (got #{z2 && z2['fill_color'].inspect})", fails)
check(z2 && z2['border_color'] == '#07b4a2',
      "flat zones: container border_color extracted (got #{z2 && z2['border_color'].inspect})", fails)

# ---- 2. transparent fill is NOT emitted ------------------------------------
z5 = zones.find { |z| z['id'] == '5' }
check(z5 && z5['fill_color'].nil?,
      "flat zones: fully-transparent (#00000000) fill is skipped (got #{z5 && z5['fill_color'].inspect})", fails)

# ---- 3. control display mode ------------------------------------------------
z3 = zones.find { |z| z['id'] == '3' }
check(z3 && z3['control_display'] == 'compact',
      "flat zones: filter mode='compact' → control_display (got #{z3 && z3['control_display'].inspect})", fails)

# ---- 4. nested zone_tree also carries the fill -----------------------------
tree = (dash && dash['zone_tree']) || []
def find_zone(nodes, id)
  nodes.each do |n|
    return n if n['id'] == id
    r = find_zone(n['children'] || [], id)
    return r if r
  end
  nil
end
t2 = find_zone(tree, '2')
check(t2 && t2['fill_color'] == '#07b4a24e',
      "zone_tree: nested container node carries fill_color (got #{t2 && t2['fill_color'].inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — Phase-1 zone-style extraction works'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
