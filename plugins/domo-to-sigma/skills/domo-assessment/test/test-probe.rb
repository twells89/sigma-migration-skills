require 'json'; require_relative 'helper'
out = Helper.tmp_out
system("ruby #{Helper::ROOT}/scripts/probe-governance.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}") or abort 'probe run failed'
p = JSON.parse(File.read("#{out}/probe.json"))
Helper.assert(p['tier'] == 'B', 'tier-b fixtures => Tier B')
Helper.assert(p['governance_datasets'].key?('cards'), 'cards dataset matched')
out2 = Helper.tmp_out
system("ruby #{Helper::ROOT}/scripts/probe-governance.rb --from-fixtures #{Helper.fixtures_dir('tier-a')} --out #{out2}")
Helper.assert(JSON.parse(File.read("#{out2}/probe.json"))['tier'] == 'A', 'tier-a fixtures => Tier A')
puts 'test-probe: PASS'
