#!/usr/bin/env ruby
# Hard gate for Phase 5e (visual compare vs the SOURCE report). The agent MUST
# run this before Phase 6 parity sign-off. Blocks unless:
#   1. visual-compare.json exists in --dir
#   2. it has an entry for EVERY content page in --signals (Data page exempt)
#   3. every entry has verdict PASS or ACCEPTED (a delta the user explicitly
#      accepted, with a non-empty `deltas` list explaining what differs)
# Numbers-only verification shipped dashboards that LOOKED broken (customer QS
# feedback, 2026-06-12) — eyes on full pages are part of GREEN now.
require 'json'
require 'optparse'
opts = {}
OptionParser.new do |p|
  p.on('--dir D') { |v| opts[:dir] = v }
  p.on('--signals S') { |v| opts[:sig] = v }
end.parse!
abort('need --dir and --signals') unless opts[:dir] && opts[:sig]
path = File.join(opts[:dir], 'visual-compare.json')
abort("BLOCKED: #{path} missing — run Phase 5e (export source + Sigma pages, eyeball, write verdicts)") unless File.exist?(path)
vc = JSON.parse(File.read(path))
entries = vc.is_a?(Array) ? vc : (vc['pages'] || [])
by_page = entries.group_by { |e| e['page'] }
signals = JSON.parse(File.read(opts[:sig]))
missing = []
signals['pages'].each do |pg|
  next if (pg['visuals'] || []).empty?
  missing << pg['page_title'] unless by_page.key?(pg['page_title']) || by_page.key?(pg['page_id'])
end
abort("BLOCKED: no visual-compare entry for page(s): #{missing.join(', ')}") unless missing.empty?
bad = entries.reject { |e| %w[PASS ACCEPTED].include?(e['verdict'].to_s.upcase) }
abort("BLOCKED: non-passing verdict(s): #{bad.map { |e| "#{e['page']}=#{e['verdict']}" }.join(', ')}") unless bad.empty?
unexplained = entries.select { |e| e['verdict'].to_s.upcase == 'ACCEPTED' && Array(e['deltas']).empty? }
abort("BLOCKED: ACCEPTED verdict without deltas[] explaining what differs: #{unexplained.map { |e| e['page'] }.join(', ')}") unless unexplained.empty?
puts "visual-compare GREEN: #{entries.length} page(s) verified against the source render."
