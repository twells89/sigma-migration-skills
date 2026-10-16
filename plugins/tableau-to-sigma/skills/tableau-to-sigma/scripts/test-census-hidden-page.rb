#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression: BlindGrade.census_from_readback must exclude elements placed on
# pages with `visibility: hidden`. `visibleAsSource` is data-model-only — the
# live workbook API 400s on it — so the existing exclusion never fired for
# workbooks; a hidden Data page's chart-kind elements inflated the tile census
# and made a correct blind grade read INCONSISTENT (field find: FP&A Executive
# Overview). The canonical copy is shared/lib/blind_grade.rb (vendored into
# every plugin); this exercises the vendored copy.
#
# Usage:  ruby scripts/test-census-hidden-page.rb
require 'json'
require 'tmpdir'
require_relative 'lib/blind_grade'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

def census(doc)
  Dir.mktmpdir do |d|
    path = File.join(d, 'wb-readback.json')
    File.write(path, JSON.generate(doc))
    BlindGrade.census_from_readback(path)
  end
end

def wb(pages:, elements:, layout:)
  { 'document' => { 'kind' => 'workbook', 'pages' => pages, 'elements' => elements, 'layout' => layout } }
end

ELS = [{ 'id' => 'k', 'kind' => 'kpi-chart' },
       { 'id' => 'l', 'kind' => 'line-chart' },
       { 'id' => 'h1', 'kind' => 'bar-chart' },
       { 'id' => 'h2', 'kind' => 'pivot-table' }].freeze

puts 'test-census-hidden-page:'

hidden = wb(pages: [{ 'id' => 'p1', 'name' => 'Overview' },
                    { 'id' => 'pd', 'name' => 'Staging', 'visibility' => 'hidden' }],
            elements: ELS,
            layout: '<Page id="p1"><Element elementId="k"/><Element elementId="l"/></Page>' \
                    '<Page id="pd"><Element elementId="h1"/><Element elementId="h2"/></Page>')
check(census(hidden) == %w[kpi line], 'elements on a hidden page are excluded from the census')

visible = wb(pages: [{ 'id' => 'p1', 'name' => 'Overview' }, { 'id' => 'pd', 'name' => 'Detail' }],
             elements: ELS,
             layout: '<Page id="p1"><Element elementId="k"/><Element elementId="l"/></Page>' \
                     '<Page id="pd"><Element elementId="h1"/><Element elementId="h2"/></Page>')
check(census(visible).sort == %w[bar kpi line table], 'the same elements on a visible page all count')

# visibility: visible (explicit) and an unrelated page name must not exclude.
explicit = wb(pages: [{ 'id' => 'p1', 'name' => 'Overview', 'visibility' => 'visible' }],
              elements: ELS.first(2),
              layout: '<Page id="p1"><Element elementId="k"/><Element elementId="l"/></Page>')
check(census(explicit) == %w[kpi line], 'visibility: visible pages are counted')

# An element in a container on the hidden page is excluded too.
nested = wb(pages: [{ 'id' => 'p1', 'name' => 'Overview' },
                    { 'id' => 'pd', 'name' => 'Staging', 'visibility' => 'hidden' }],
            elements: ELS,
            layout: '<Page id="p1"><Element elementId="k"/><Element elementId="l"/></Page>' \
                    '<Page id="pd"><Container id="c"><Element elementId="h1"/><Element elementId="h2"/></Container></Page>')
check(census(nested) == %w[kpi line], 'elements nested in a container on a hidden page are excluded')

# Legacy exclusions keep working.
data_page = wb(pages: [{ 'id' => 'p1', 'name' => 'Overview' }, { 'id' => 'pd', 'name' => 'Data' }],
               elements: ELS,
               layout: '<Page id="p1"><Element elementId="k"/><Element elementId="l"/></Page>' \
                       '<Page id="pd"><Element elementId="h1"/><Element elementId="h2"/></Page>')
check(census(data_page) == %w[kpi line], 'a page named "Data" is still excluded')

vas = wb(pages: [{ 'id' => 'p1', 'name' => 'Overview' }],
         elements: [{ 'id' => 'k', 'kind' => 'kpi-chart' },
                    { 'id' => 'm', 'kind' => 'bar-chart', 'visibleAsSource' => false }],
         layout: '<Page id="p1"><Element elementId="k"/><Element elementId="m"/></Page>')
check(census(vas) == %w[kpi], 'visibleAsSource:false is still excluded (data-model readbacks)')

puts
if FAILS.empty?
  puts 'OK — hidden-page census tests passed'
  exit 0
else
  warn "FAIL — #{FAILS.size} check(s) failed:"
  FAILS.each { |f| warn "  - #{f}" }
  exit 1
end
