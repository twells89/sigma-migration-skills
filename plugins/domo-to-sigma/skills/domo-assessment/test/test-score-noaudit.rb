require 'json'; require 'fileutils'; require_relative 'helper'

# Regression test (FINAL-REVIEW Finding 1): `retire` must be gated on audit
# mode. score-coverage.rb's tag rule used to fire `views == 0 -> retire`
# unconditionally; per refs/complexity-scoring.md / refs/governance-datasets.md
# `retire` is an audit-mode-only disposition -- outside audit mode a 0-view
# card has no usage signal to justify retiring it and must fall through to
# the normal score-based tags instead.
#
# Build a tier-b-like fixture set with the activity-log table removed (no
# usage.json => AUDIT=false in score-coverage.rb, and every card reads as
# 0 views since there's no usage source at all) and assert NO card is
# tagged 'retire'. Before the fix this test fails (every 0-view card,
# i.e. all of them here, gets tagged 'retire'); after the fix it passes.
out = Helper.tmp_out
no_audit_fixtures = File.join(out, 'fixtures-no-audit')
FileUtils.mkdir_p(no_audit_fixtures)
Dir.glob(File.join(Helper.fixtures_dir('tier-b'), '*.json')).each do |f|
  next if File.basename(f) == 'activity-log.json'
  FileUtils.cp(f, no_audit_fixtures)
end

system("ruby #{Helper::ROOT}/scripts/probe-governance.rb --from-fixtures #{no_audit_fixtures} --out #{out}") or abort 'probe failed'
system("ruby #{Helper::ROOT}/scripts/discover-domo.rb --from-fixtures #{no_audit_fixtures} --out #{out}") or abort 'discover failed'
Helper.assert(!File.exist?("#{out}/usage.json"), 'no usage.json written when activity-log table is absent (no audit scope)')

inv = JSON.parse(File.read("#{out}/inventory.json"))
Helper.assert(inv['cards'].all? { |c| c['views'].zero? }, 'sanity: every card reads as 0 views with no usage source at all')

system("ruby #{Helper::ROOT}/scripts/score-coverage.rb --in #{out} --out #{out}") or abort 'score failed'
c = JSON.parse(File.read("#{out}/complexity.json"))
Helper.assert(c['artifacts'].none? { |a| a['tag'] == 'retire' }, 'no card tagged retire outside audit mode, even with 0 views')
puts 'test-score-noaudit: PASS'
