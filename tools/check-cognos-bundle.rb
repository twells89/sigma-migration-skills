#!/usr/bin/env ruby
# frozen_string_literal: true
#
# check-cognos-bundle.rb — freshness gate for the cognos vendored converter bundle.
#
# Unlike the other converters (which vendor from sigma-data-model-mcp), cognos vendors
# its OWN TypeScript converter IN the skill: converter/cli.ts (+ cognos.ts /
# cognos-report.ts / sigma-ids.ts / metric-binding.ts) is bundled by esbuild into the
# committed, self-contained converter/cli.mjs — and PRODUCTION runs that bundle (plain
# `node`, no tsx). So a converter/*.ts edit that ships WITHOUT re-bundling cli.mjs
# silently ships the OLD behavior — the migrate run keeps using the stale bundle. That
# is exactly the "edited .ts, forgot to re-vendor" footgun.
#
# This gate closes it the same way tools/check-shared.rb closes shared-file drift: it
# records a SHA-256 over the BUNDLED converter sources in PROVENANCE.json (written by
# tools/vendor-converters.sh right after it bundles) and re-verifies it here. A byte
# compare of cli.mjs would be flaky — esbuild output varies by version — so we hash the
# source of truth, not the generated artifact.
#
#   ruby tools/check-cognos-bundle.rb            # CI/hook gate: fail if stale
#   ruby tools/check-cognos-bundle.rb --write    # (re)write PROVENANCE.json's source_sha256
#                                                #  — called by tools/vendor-converters.sh
#
# Scope note: hashes converter/*.ts EXCEPT the test file (test.ts / *.test.ts), which is
# not part of the bundle. A fast-xml-parser (node_modules) bump is out of scope — that
# dep is pinned in package.json; this gate targets the .ts-edit footgun the SKILL warns
# about.
require 'json'
require 'digest'

ROOT = File.expand_path('..', __dir__)
CONV = File.join(ROOT, 'plugins/cognos-to-sigma/skills/cognos-to-sigma/converter')
PROV = File.join(CONV, 'PROVENANCE.json')
BUNDLE = File.join(CONV, 'cli.mjs')

REVENDOR = 'tools/vendor-converters.sh <sigma-data-model-mcp> cognos'

def bundled_sources
  Dir[File.join(CONV, '*.ts')]
    .reject { |f| File.basename(f) == 'test.ts' || File.basename(f).end_with?('.test.ts') }
    .sort_by { |f| File.basename(f) }
end

# A stable manifest — "<basename>  <sha256(content)>" per bundled source, sorted — then
# a single SHA over that. Reproducible in one place (here); vendor-converters.sh invokes
# `--write` rather than re-implementing it, so bash/ruby can never drift.
def source_manifest
  bundled_sources.map { |f| "#{File.basename(f)}  #{Digest::SHA256.hexdigest(File.read(f))}" }
end

def source_sha
  Digest::SHA256.hexdigest(source_manifest.join("\n"))
end

def write_provenance
  prov = {
    'source' => "in-skill converter/cli.ts (#{bundled_sources.map { |f| File.basename(f) }.join(' + ')})",
    'bundler' => 'esbuild --bundle --format=esm --platform=node',
    'vendored_modules' => 'cli.mjs',
    'source_sha256' => source_sha,
    'sources' => bundled_sources.map { |f| File.basename(f) },
    'note' => 'cli.mjs is GENERATED from converter/*.ts — do not hand-edit. After editing ' \
              "any converter/*.ts, re-run #{REVENDOR} (rebuilds cli.mjs + refreshes " \
              'source_sha256). CI gate: tools/check-cognos-bundle.rb.'
  }
  File.write(PROV, "#{JSON.pretty_generate(prov)}\n")
  warn "wrote #{File.basename(PROV)} — source_sha256 #{prov['source_sha256'][0, 12]} over #{bundled_sources.size} TS source(s)"
end

def check
  abort "FATAL: #{BUNDLE} missing — the cognos converter bundle is not vendored. Run #{REVENDOR}." unless File.exist?(BUNDLE)
  abort "FATAL: #{PROV} missing — run #{REVENDOR} to generate it." unless File.exist?(PROV)
  want = (JSON.parse(File.read(PROV)) rescue {})['source_sha256']
  have = source_sha
  if want.nil? || want.empty?
    abort "cognos PROVENANCE.json has no source_sha256 (stale format) — run #{REVENDOR}."
  elsif want != have
    abort "cognos converter/cli.mjs is STALE vs converter/*.ts " \
          "(recorded source_sha256 #{want[0, 12]} != current #{have[0, 12]}).\n" \
          "  A converter/*.ts edit shipped without re-bundling cli.mjs — production runs the\n" \
          "  vendored bundle, so the change would NOT take effect. Fix:\n    #{REVENDOR}"
  end
  puts "OK: cognos cli.mjs is fresh vs converter/*.ts (#{bundled_sources.size} bundled TS source(s), source_sha256 #{have[0, 12]})"
end

if ARGV.include?('--write')
  write_provenance
else
  check
end
