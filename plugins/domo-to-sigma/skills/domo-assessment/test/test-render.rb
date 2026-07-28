require_relative 'helper'
out = Helper.tmp_out
%w[probe-governance discover-domo].each { |s| system("ruby #{Helper::ROOT}/scripts/#{s}.rb --from-fixtures #{Helper.fixtures_dir('tier-b')} --out #{out}") }
system("ruby #{Helper::ROOT}/scripts/score-coverage.rb --in #{out} --out #{out}")
system("ruby #{Helper::ROOT}/scripts/render-readout.rb --in #{out} --out #{out}") or abort 'render failed'
md = File.read("#{out}/readout.md")
Helper.assert(md.include?('Migration readiness'), 'has title')
Helper.assert(md.downcase.include?('retire') && md.include?('|'), 'shortlist table + retire row')
Helper.assert(md.downcase.include?('heuristic'), 'scoring disclaimer present')
puts 'test-render: PASS'
