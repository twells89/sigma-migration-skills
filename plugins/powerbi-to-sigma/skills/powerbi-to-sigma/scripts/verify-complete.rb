#!/usr/bin/env ruby
# frozen_string_literal: true
#
# verify-complete.rb — the single offline "is this migration actually done?" check.
#
# A Power BI→Sigma conversion produced a real, non-empty workbook ONLY when
# migrate-powerbi.rb finished and stamped <workdir>/phase6-success.json
# (workbookId + chartCount + gates) at exit 0. An EMPTY / placeholder workbook
# (pages but no elements — the classic failure where a blocked agent hand-builds
# a shell) never gets that marker, because the orchestrator refuses to green a
# 0-element build. So "built" is a fact on disk, not "the pages look right".
#
# IMPORTANT — what the marker does and does NOT prove: the one-shot orchestrator's
# gate is a RESOLUTION check (every column resolves + warehouse freshness matches),
# recorded as gates:'resolution-pass'. It does NOT diff the built aggregates against
# the source's DAX/SQL results. VALUE PARITY is a separate gate — assert-phase6-ran.rb
# / phase6-parity-pbi.rb, which writes parity-final.json — and this script reports its
# status separately so a green here is never mistaken for "numbers verified vs source".
# (Aligning powerbi/qlik to the assert-phase6-ran-stamped marker the other plugins use
# is tracked under the runtime-contract completion seam, bead p5y2.)
#
# Usage:  ruby scripts/verify-complete.rb --workdir <dir> [--workbook-id <id>]
#
# Exit codes:
#   0  DONE   — phase6-success.json present with chartCount > 0 (built + resolution-verified;
#              value-parity status reported separately from parity-final.json)
#   2  NOT DONE — no success marker (conversion didn't complete / was hand-built)
#   3  NOT DONE — marker present but 0 chart elements (empty workbook)
#   4  DONE-BUT-MISMATCH — success marker is for a different workbook than asked

require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR') { |v| opts[:wd] = v }
  p.on('--workbook-id ID') { |v| opts[:wb] = v }
end.parse!(ARGV)
abort 'FATAL: --workdir required' unless opts[:wd]

succ = File.join(opts[:wd], 'phase6-success.json')
unless File.exist?(succ)
  warn '⛔ NOT DONE — no phase6-success.json in the workdir.'
  warn '   The conversion did not complete a resolution-verified build. If pages exist but are empty,'
  warn '   they were NOT produced by a real migrate-powerbi.rb run — re-run the orchestrator'
  warn "   (never hand-author a workbook). Workdir checked: #{opts[:wd]}"
  exit 2
end

sj = begin
  JSON.parse(File.read(succ))
rescue StandardError
  {}
end

if sj['chartCount'].to_i <= 0
  warn '⛔ NOT DONE — success marker present but 0 chart elements (empty workbook).'
  exit 3
end
if opts[:wb] && !sj['workbookId'].to_s.empty? && sj['workbookId'] != opts[:wb]
  warn "⛔ DONE marker is for a DIFFERENT workbook (#{sj['workbookId']}) than --workbook-id #{opts[:wb]}."
  exit 4
end

# Report VALUE PARITY separately from the build/resolution marker. The value gate
# (assert-phase6-ran.rb / phase6-parity-pbi.rb) writes parity-final.json; surface its
# status honestly rather than implying the one-shot build already value-verified.
pf = File.join(opts[:wd], 'parity-final.json')
vparity = begin
  st = File.exist?(pf) ? JSON.parse(File.read(pf))['status'].to_s.upcase : nil
  st && (st == 'PASS' ? 'CONFIRMED (parity-final.json)' : "#{st} (parity-final.json)")
rescue StandardError
  nil
end

puts '✅ DONE — migrate-powerbi.rb built a resolution-verified workbook for this run.'
puts "   workbook     : #{sj['workbookId']}"
puts "   charts       : #{sj['chartCount']}"
puts "   gates        : #{sj['gates']} (columns resolve + freshness match)"
if vparity
  puts "   value parity : #{vparity}"
else
  puts '   value parity : NOT RUN in this path — the build resolved but its aggregates were'
  puts '                  NOT diffed vs the source. Run assert-phase6-ran.rb / phase6-parity-pbi.rb'
  puts '                  before reporting numeric parity with Power BI.'
end
puts "   stamped      : #{sj['generatedAt']}"
exit 0
