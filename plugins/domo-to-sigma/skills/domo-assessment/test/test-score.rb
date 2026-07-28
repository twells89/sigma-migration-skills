require 'json'; require_relative 'helper'
out = Helper.tmp_out
%w[probe-governance discover-domo].each { |s| system("ruby #{Helper::ROOT}/scripts/#{s}.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}") }
system("ruby #{Helper::ROOT}/scripts/score-coverage.rb --in #{out} --out #{out}") or abort 'score failed'
c = JSON.parse(File.read("#{out}/complexity.json"))
by_id = c['artifacts'].map { |a| [a['id'], a] }.to_h
# retire: the zero-view card
retire = c['artifacts'].select { |a| a['tag'] == 'retire' }
Helper.assert(retire.any? && retire.all? { |a| a['views'] == 0 }, 'retire tag <=> views==0')
# gap-scout: an artifact with an unhandled Beast Mode
Helper.assert(c['artifacts'].any? { |a| a['tag'] == 'needs-gap-scout' && a['n_unhandled'] >= 1 }, 'gap-scout <=> unhandled>=1')
# cost formula sanity on a known artifact
a = c['artifacts'].find { |x| x['n_unhandled'] == 1 && x['n_manual'] == 0 && x['n_hint'] == 0 }
Helper.assert(a && a['cost'] == 10, 'cost = 10*unhandled+3*manual+1*hint')
Helper.assert(c['tier'] == 'B', 'tier propagated')
puts 'test-score: PASS'
