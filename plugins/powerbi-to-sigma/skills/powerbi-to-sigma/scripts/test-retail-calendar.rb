#!/usr/bin/env ruby
# Converter regression for calculated retail date dimensions. Pure/offline:
# invokes the committed converter bundle against synthetic TMSL fixtures and
# inspects the returned Sigma model; no Sigma or Power BI credentials.
require 'json'
require 'open3'
require 'pathname'
require 'tempfile'

HERE = File.expand_path(__dir__)
SKILL = File.expand_path('..', HERE)
CONVERTER = File.join(SKILL, 'converter', 'powerbi.mjs')
FIXTURES = File.join(SKILL, 'fixtures')

$fail = 0
def ok(name, cond, detail = nil)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  warn("       #{detail}") if !cond && detail
  $fail += 1 unless cond
end

def convert(fixture)
  converter_url = Pathname.new(CONVERTER).realpath.to_s
  converter_url = "file://#{converter_url}" unless converter_url.start_with?('file:')
  js = <<~JS
    import { readFileSync } from 'node:fs';
    import { convertPowerBIToSigma } from #{converter_url.to_json};
    const model = JSON.parse(readFileSync(#{fixture.to_json}, 'utf8'));
    const result = convertPowerBIToSigma(model, {
      connectionId: '11111111-2222-3333-4444-555555555555',
      database: 'RETAIL_DB',
      schema: 'ANALYTICS'
    });
    process.stdout.write(JSON.stringify(result));
  JS
  out, err, status = Open3.capture3('node', '--input-type=module', '-e', js)
  raise "converter failed (#{status.exitstatus}): #{err}\n#{out}" unless status.success?
  JSON.parse(out)
end

unless File.exist?(CONVERTER)
  warn "FAIL  converter missing: #{CONVERTER}"
  exit 1
end

retail = convert(File.join(FIXTURES, 'fixture_10_retail_calendar.bim'))
elements = retail.dig('model', 'pages', 0, 'elements') || []
calendar = elements.find { |e| e.dig('source', 'kind') == 'sql' && e.dig('source', 'statement').to_s.include?('GENERATOR') }
ok 'retail calculated table becomes a SQL date spine', !calendar.nil?

if calendar
  statement = calendar.dig('source', 'statement').to_s
  columns = calendar['columns'] || []
  by_name = columns.each_with_object({}) { |c, h| h[c['name']] = c if c['name'] }
  formulas = columns.map { |c| c['formula'].to_s }

  ok 'all ten retail date columns survive', columns.size == 10, "got #{columns.size}"
  ok 'date spine has no placeholder', !statement.include?('_placeholder')
  ok 'date spine has no NULL-derived source column', statement !~ /\bNULL\s+AS\b/i
  ok 'Monday-based WEEKDAY is translated',
     by_name.dig('Weekday Mon', 'formula').to_s.include?('Mod(Weekday([Date]) + 5, 7) + 1'),
     by_name.dig('Weekday Mon', 'formula')
  ok 'EOMONTH is translated',
     by_name.dig('Month End', 'formula') == 'EndOfMonth(DateAdd("month", 0, [Date]))',
     by_name.dig('Month End', 'formula')
  ok 'EDATE is translated',
     by_name.dig('Next Month', 'formula') == 'DateAdd("month", 1, [Date])',
     by_name.dig('Next Month', 'formula')
  ok 'Black Friday VAR is inlined',
     by_name.dig('Is Black Friday', 'formula').to_s.include?('Month([Date]) = 11') &&
       !by_name.dig('Is Black Friday', 'formula').to_s.match?(/\bVAR\b|\bRETURN\b/i),
     by_name.dig('Is Black Friday', 'formula')
  ok 'Easter computus is translated',
     by_name.dig('Is Easter', 'formula').to_s.include?('MakeDate(') &&
       by_name.dig('Is Easter', 'formula').to_s.include?('Mod('),
     by_name.dig('Is Easter', 'formula')
  ok 'Back-to-school window is translated',
     by_name.dig('Is Back to School', 'formula').to_s.include?('Month([Date]) = 8'),
     by_name.dig('Is Back to School', 'formula')
  ok 'Christmas date is translated',
     by_name.dig('Is Christmas', 'formula').to_s.include?('MakeDate(Year([Date]), 12, 25)'),
     by_name.dig('Is Christmas', 'formula')
  ok 'retail SWITCH becomes nested If',
     by_name.dig('Retail Event', 'formula').to_s.start_with?('If('),
     by_name.dig('Retail Event', 'formula')
  residual = formulas.grep(/\b(?:WEEKDAY|EDATE|EOMONTH|DATE|VAR|RETURN|SWITCH)\s*\(/)
  ok 'no retail DAX-only function remains', residual.empty?, residual.join(' | ')
end

retail_warnings = retail['warnings'] || []
ok 'retail calendar has no dropped-column warning',
   retail_warnings.none? { |w| w.match?(/Calculated table .*dropped column/i) },
   retail_warnings.join(' | ')

generic = convert(File.join(FIXTURES, 'fixture_02_time_intelligence.bim'))
generic_calendar = (generic.dig('model', 'pages', 0, 'elements') || []).find do |e|
  e.dig('source', 'kind') == 'sql' && e.dig('source', 'statement').to_s.include?('GENERATOR')
end
ok 'existing generic calendar still converts', !generic_calendar.nil?
if generic_calendar
  ok 'generic calendar keeps every column', (generic_calendar['columns'] || []).size == 6
  ok 'generic Quarter label no longer becomes NULL',
     generic_calendar.dig('source', 'statement').to_s !~ /\bNULL\s+AS\b/i &&
       (generic_calendar['columns'] || []).any? { |c| c['name'] == 'Quarter' && c['formula'].to_s.include?('Quarter([Date])') }
end

puts($fail.zero? ? "\nPASS" : "\n#{$fail} FAILED")
exit($fail.zero? ? 0 : 1)
