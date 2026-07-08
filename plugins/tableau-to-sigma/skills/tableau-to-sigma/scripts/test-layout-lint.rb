#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Offline regression tests for lib/layout_lint.rb (the shared layout-quality
# gate, vendored byte-identical across every migration plugin). Creds-free —
# runs in the corpus-check unit-tests job.
#
# Guards in particular the vertical-rail false-positive: a nested container
# declaring gridTemplateColumns="repeat(1, 1fr)" whose children fill its single
# column must read as 100% full, NOT 1/24. That bug hard-failed every dashboard
# with a left filter rail / sidebar (caught end-to-end against a real shipped
# workbook before this test existed).

require_relative 'lib/layout_lint'

$failures = 0
def check(name)
  v = yield
  if v
    puts "  ok  - #{name}"
  else
    puts "  FAIL- #{name}"
    $failures += 1
  end
end

def lint(spec)
  LayoutLint.lint(spec)
end

def has?(viol, frag)
  viol.any? { |x| x.include?(frag) }
end

# --- 1. vertical rail (repeat(1,1fr)) is CLEAN — the regression -------------
rail = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <GridContainer elementId="hero" type="grid" gridColumn="1 / 25" gridRow="1 / 5" gridTemplateColumns="repeat(24, 1fr)">
        <LayoutElement elementId="title" gridColumn="1 / 25" gridRow="1 / 5"/>
      </GridContainer>
      <GridContainer elementId="rail" type="grid" gridColumn="1 / 6" gridRow="5 / 30" gridTemplateColumns="repeat(1, 1fr)">
        <LayoutElement elementId="ctlA" gridColumn="1 / 2" gridRow="1 / 6"/>
        <LayoutElement elementId="ctlB" gridColumn="1 / 2" gridRow="6 / 11"/>
      </GridContainer>
      <GridContainer elementId="content" type="grid" gridColumn="6 / 25" gridRow="5 / 30" gridTemplateColumns="repeat(24, 1fr)">
        <LayoutElement elementId="t1" gridColumn="1 / 25" gridRow="1 / 25"/>
      </GridContainer>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'Partner Summary', 'elements' => [
    { 'id' => 'title', 'kind' => 'text', 'body' => '# enterprise Partner Bookings' },
    { 'id' => 'ctlA', 'kind' => 'control', 'name' => 'Region' },
    { 'id' => 'ctlB', 'kind' => 'control', 'name' => 'Channel' },
    { 'id' => 't1', 'kind' => 'pivot-table', 'name' => 'By Partner' }
  ] }]
}
rv = lint(rail)
check('vertical rail (repeat(1,1fr)) lints clean') { rv.empty? }

# --- 2. a genuinely under-filled 24-col band still FAILS --------------------
bad = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <GridContainer elementId="hdr" type="grid" gridColumn="1 / 25" gridRow="1 / 3" gridTemplateColumns="repeat(24, 1fr)">
        <LayoutElement elementId="hdrtext" gridColumn="1 / 25" gridRow="1 / 3"/>
      </GridContainer>
      <GridContainer elementId="band1" type="grid" gridColumn="1 / 25" gridRow="3 / 9" gridTemplateColumns="repeat(24, 1fr)">
        <LayoutElement elementId="smallbar" gridColumn="1 / 6" gridRow="1 / 6"/>
      </GridContainer>
      <LayoutElement elementId="loosectl" gridColumn="1 / 5" gridRow="20 / 22"/>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'Partner Summary', 'elements' => [
    { 'id' => 'hdrtext', 'kind' => 'text', 'body' => '# Page 1' },
    { 'id' => 'smallbar', 'kind' => 'bar-chart', 'name' => 'a1b2c3d4e5f6' },
    { 'id' => 'loosectl', 'kind' => 'control', 'name' => 'Region' }
  ] }]
}
bv = lint(bad)
check('under-filled 24-col band fails')      { has?(bv, 'band under-filled') }
check('raw-id display name flagged')         { has?(bv, 'raw-id display name') }
check('orphan control flagged')              { has?(bv, 'orphan control') }
check('generic header title flagged')        { has?(bv, 'generic header title') }
check('dead zone flagged')                   { has?(bv, 'dead zone') }

# --- 3. explicit multi-track template counts its own tracks -----------------
three = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <GridContainer elementId="b" type="grid" gridColumn="1 / 25" gridRow="1 / 6" gridTemplateColumns="1fr 1fr 1fr">
        <LayoutElement elementId="x" gridColumn="1 / 2" gridRow="1 / 6"/>
        <LayoutElement elementId="y" gridColumn="2 / 3" gridRow="1 / 6"/>
        <LayoutElement elementId="z" gridColumn="3 / 4" gridRow="1 / 6"/>
      </GridContainer>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [
    { 'id' => 'x', 'kind' => 'table', 'name' => 'X' },
    { 'id' => 'y', 'kind' => 'table', 'name' => 'Y' },
    { 'id' => 'z', 'kind' => 'table', 'name' => 'Z' }
  ] }]
}
check('explicit 3-track band (all filled) lints clean') { lint(three).none? { |x| x.include?('band under-filled') } }

# --- 4. per-kind minimum tile heights (rule f, E1) ---------------------------
# Sigma renders chart/KPI tiles BLANK under ~3-4 grid rows (page render AND
# PNG exports). A kpi-chart under 4 rows / chart under 8 / table under 10 must
# be rejected; tiles at or above their floor lint clean.
short = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <GridContainer elementId="band" type="grid" gridColumn="1 / 25" gridRow="1 / 30" gridTemplateColumns="repeat(24, 1fr)">
        <LayoutElement elementId="kpi1" gridColumn="1 / 13" gridRow="1 / 3"/>
        <LayoutElement elementId="bar1" gridColumn="13 / 25" gridRow="1 / 6"/>
        <LayoutElement elementId="tbl1" gridColumn="1 / 25" gridRow="6 / 12"/>
        <LayoutElement elementId="ok1"  gridColumn="1 / 25" gridRow="12 / 29"/>
      </GridContainer>
      <LayoutElement elementId="txt1" gridColumn="1 / 25" gridRow="30 / 31"/>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [
    { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Revenue' },
    { 'id' => 'bar1', 'kind' => 'bar-chart', 'name' => 'By Region' },
    { 'id' => 'tbl1', 'kind' => 'table', 'name' => 'Detail' },
    { 'id' => 'ok1', 'kind' => 'pivot-table', 'name' => 'Matrix' },
    { 'id' => 'txt1', 'kind' => 'text', 'body' => 'note' }
  ] }]
}
sv = lint(short)
check('kpi-chart under 4 rows flagged')  { sv.any? { |x| x.include?('kpi1') && x.include?('below minimum height') } }
check('bar-chart under 8 rows flagged')  { sv.any? { |x| x.include?('bar1') && x.include?('below minimum height') } }
check('table under 10 rows flagged')     { sv.any? { |x| x.include?('tbl1') && x.include?('below minimum height') } }
check('17-row pivot NOT flagged')        { sv.none? { |x| x.include?('ok1') && x.include?('below minimum height') } }
check('1-row text flagged (floor 2)')    { sv.any? { |x| x.include?('txt1') && x.include?('below minimum height') } }

tall = {
  'layout' => <<~XML,
    <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" id="p1">
      <GridContainer elementId="band" type="grid" gridColumn="1 / 25" gridRow="1 / 13" gridTemplateColumns="repeat(24, 1fr)">
        <LayoutElement elementId="kpi1" gridColumn="1 / 13" gridRow="1 / 5"/>
        <LayoutElement elementId="bar1" gridColumn="13 / 25" gridRow="1 / 13"/>
      </GridContainer>
    </Page>
  XML
  'pages' => [{ 'id' => 'p1', 'name' => 'P', 'elements' => [
    { 'id' => 'kpi1', 'kind' => 'kpi-chart', 'name' => 'Revenue' },
    { 'id' => 'bar1', 'kind' => 'bar-chart', 'name' => 'By Region' }
  ] }]
}
check('tiles at their floors lint clean (no min-height violations)') do
  lint(tall).none? { |x| x.include?('below minimum height') }
end

puts($failures.zero? ? "\nlayout-lint: all tests passed" : "\nlayout-lint: #{$failures} FAILED")
exit($failures.zero? ? 0 : 1)
