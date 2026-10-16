#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Regression: phase6-parity.rb --finalize crashed with "invalid byte sequence in
# US-ASCII" (out.scan on the verifier's captured output) whenever LANG/LC_ALL
# were unset and a chart name carried a non-ASCII character. Runs the real
# finalize in a scratch workdir with an EMPTY locale and an accented chart name.
# The child verify-parity.rb is covered too: json >= 2.7 (the CI runner's gem)
# raises InvalidByteSequenceError parsing a US-ASCII-tagged plan.
#
# Usage:  ruby scripts/test-phase6-parity-utf8.rb
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

SCRIPT = File.join(__dir__, 'phase6-parity.rb')
NAME = 'Résumé – Net Revenue'

fails = []
check = lambda do |cond, msg|
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

puts 'test-phase6-parity-utf8:'
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'parity-plan.json'), JSON.generate(
    'charts' => [{ 'chart' => NAME, 'tableau_view' => NAME, 'sigma_columns' => %w[Region Revenue],
                   'expected' => [['East', 100.0], ['West', 200.0]] }]
  ))
  File.write(File.join(dir, 'actuals.json'), JSON.generate(NAME => [['East', 100.0], ['West', 200.0]]))
  env = { 'LANG' => '', 'LC_ALL' => '', 'LC_CTYPE' => '', 'SIGMA_BASE_URL' => 'https://sigma.invalid', 'SIGMA_API_TOKEN' => 'unused' }
  out, err, st = Open3.capture3(env, RbConfig.ruby, SCRIPT, '--tableau', dir,
                                '--finalize', '--actuals', File.join(dir, 'actuals.json'))
  # This harness may itself run under an unset locale: retag before matching.
  out, err = [out, err].map { |s| s.dup.force_encoding(Encoding::UTF_8).scrub }
  check.call(!(out + err).match?(/invalid byte sequence|InvalidByteSequenceError/),
             "finalize survives an unset locale + non-ASCII chart name (exit #{st.exitstatus}: #{err.lines.last.to_s.strip})")
  pf = File.join(dir, 'parity-final.json')
  summary = File.exist?(pf) ? JSON.parse(File.read(pf, encoding: 'UTF-8')) : {}
  check.call(summary['pass_names'] == [NAME], "the accented chart name round-trips into parity-final.json pass_names (#{summary['pass_names'].inspect})")
  check.call(summary['status'] == 'PASS', "status PASS (#{summary['status'].inspect})")
  unless fails.empty?
    warn '--- phase6-parity stdout ---', out, '--- phase6-parity stderr ---', err
    txt = File.join(dir, 'parity-final.txt')
    warn '--- parity-final.txt ---', File.read(txt) if File.exist?(txt)
  end
end

puts
if fails.empty?
  puts 'OK — phase6-parity UTF-8 test passed'
  exit 0
end
warn "FAIL — #{fails.size} check(s) failed:"
fails.each { |f| warn "  - #{f}" }
exit 1
