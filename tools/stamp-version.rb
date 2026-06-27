#!/usr/bin/env ruby
# frozen_string_literal: true
#
# stamp-version.rb — write a VERSION file next to every telemetry client copy so
# the skill's `_skill_version()` resolves a real build id DOWNSTREAM, where the
# plugin-cache delivery path strips `.git` (git describe then fails → "unknown").
#
# Run this at vendor/release time, BEFORE copying plugins into the distribution
# (e.g. sigmacomputing/sigma-agent-skills-dev). In the dev checkout you don't need
# it — `_skill_version()` falls back to `git describe`.
#
#   ruby tools/stamp-version.rb                 # version = `git describe --tags --always --dirty`
#   ruby tools/stamp-version.rb v1.4.0          # explicit version string
#   ruby tools/stamp-version.rb --clean         # remove all stamped VERSION files
#
# VERSION files are git-ignored (generated, not committed) so the dev repo keeps
# using git describe and only vendored snapshots carry a frozen version.

require 'fileutils'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

# Every dir that actually holds a telemetry lib → drop VERSION beside it (lib dir
# is checked first by _skill_version). The canonical lib lives at shared/lib; the
# fanned-out (and downstream-delivered) copies live at plugins/*/skills/*/scripts/lib.
LIB_DIRS = (Dir.glob('shared/lib') + Dir.glob('plugins/*/skills/*/scripts/lib'))
           .select { |d| File.exist?(File.join(d, 'sigma_telemetry.py')) || File.exist?(File.join(d, 'sigma_telemetry.rb')) }
           .uniq
abort 'FATAL: found no telemetry lib dirs to stamp' if LIB_DIRS.empty?

if ARGV.include?('--clean')
  removed = LIB_DIRS.map { |d| File.join(d, 'VERSION') }.select { |f| File.exist?(f) }
  removed.each { |f| File.delete(f) }
  puts "Removed #{removed.size} VERSION file(s)."
  exit 0
end

version = ARGV.find { |a| !a.start_with?('--') }
if version.nil? || version.empty?
  version = `git describe --tags --always --dirty 2>/dev/null`.strip
  abort 'FATAL: could not derive a version (pass one explicitly: stamp-version.rb v1.4.0)' if version.empty?
end
version = version[0, 32]

LIB_DIRS.each { |d| File.write(File.join(d, 'VERSION'), "#{version}\n") }
puts "Stamped VERSION=#{version} into #{LIB_DIRS.size} lib dir(s)."
