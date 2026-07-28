require 'json'; require 'fileutils'; require_relative 'helper'

# Regression test (FINAL-REVIEW Finding 2): discover-domo.rb must tolerate a
# governance table whose top-level JSON isn't the expected {columns,rows}
# Hash (e.g. a bare array) instead of raising TypeError out of build_colidx /
# build_rows -- consistent with this script's "never crashes on a degraded
# read" promise (see its TOLERANT COLUMN ACCESS header comment). A malformed
# table should degrade to empty (no columns/rows recovered from it) and
# record one table-level `_shapeSuspect` warning, same mechanism as an
# absent/missing table.
out = Helper.tmp_out
malformed_fixtures = File.join(out, 'fixtures-malformed')
FileUtils.mkdir_p(malformed_fixtures)
Dir.glob(File.join(Helper.fixtures_dir('tier-b'), '*.json')).each do |f|
  next if File.basename(f) == 'pdp.json'
  FileUtils.cp(f, malformed_fixtures)
end
# pdp.json: a bare array instead of the expected {"columns"=>[...], "rows"=>[...]} Hash.
File.write(File.join(malformed_fixtures, 'pdp.json'), JSON.generate([1, 2, 3]))

ok = system("ruby #{Helper::ROOT}/scripts/discover-domo.rb --from-fixtures #{malformed_fixtures} --out #{out}")
Helper.assert(ok, 'discover-domo.rb exits 0 on a malformed (bare-array) governance table -- no crash')

inv = JSON.parse(File.read("#{out}/inventory.json"))
warning = inv['warnings'].find { |w| w['_shapeSuspect'] && w['table'] == 'pdp' }
Helper.assert(warning && warning['column'].nil?, 'malformed pdp table yields a table-level _shapeSuspect warning')
Helper.assert(inv['cards'].none? { |c| c['pdp'] }, 'malformed pdp table degrades to no cards flagged pdp (empty, not crashed)')
puts 'test-discover-malformed: PASS'
