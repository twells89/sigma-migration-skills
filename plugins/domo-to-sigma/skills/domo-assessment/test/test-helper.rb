require_relative 'helper'
Helper.assert(File.directory?(Helper.fixtures_dir('tier-b')), 'tier-b fixtures dir exists')
out = Helper.tmp_out
Helper.assert(File.directory?(out), 'tmp out created')
puts 'test-helper: PASS'
