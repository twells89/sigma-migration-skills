require 'json'; require_relative 'helper'
out = Helper.tmp_out
system("ruby #{Helper::ROOT}/scripts/probe-governance.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}")
system("ruby #{Helper::ROOT}/scripts/discover-domo.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}") or abort 'discover failed'
inv = JSON.parse(File.read("#{out}/inventory.json"))
Helper.assert(inv['cards'].any? { |c| c['views'] == 0 }, 'a zero-view card survives to inventory')
Helper.assert(inv['cards'].any? { |c| c['pdp'] }, 'a pdp-flagged card present')
usage = JSON.parse(File.read("#{out}/usage.json"))
Helper.assert(usage['by_card'].is_a?(Hash), 'usage by_card present')
puts 'test-discover: PASS'
