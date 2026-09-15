#!/usr/bin/env ruby
# frozen_string_literal: true
#
# emit-relationship-coverage.rb — translate and evaluate the converter's
# relationshipCoverage report into <workdir>/relationship-coverage.json.
#
# WHY: converter/tableau.mjs now infers a join key by column name when Tableau
# serialized none for a 2020.2+ logical (object-graph) relationship, and it
# records EVERY relationship it considered — wired or not — in a top-level
# `relationshipCoverage: { serialized, wired, entries: [...] }` object
# (camelCase: derivedVia, keyCount, droppedConditions — the converter's native
# JS convention). scripts/lib/join_plan.rb (this same task) already threads a
# WIRED relationship's derivedVia/partial/droppedConditions into
# join-plan.json, so gate 16's warehouse probe validates an inferred key's
# uniqueness. That is a DIFFERENT question from what this script answers:
# gate 16 only ever sees relationships that got wired (nothing to probe
# otherwise) — it has no way to notice a relationship the converter recorded
# but never wired at all (a star quietly going disconnected again). This
# script keeps that full count around, coverage="every relationship
# considered", not just the wired subset.
#
# With --strict, any unwired relationship, partial relationship, dropped
# condition, malformed ledger, or count mismatch exits nonzero. This is
# plugin-local instead of modifying the shared assert-phase6-ran.rb.
#
# NAMING CONVENTION: Ruby/JSON-on-disk artifacts in
# this skill use snake_case (join-plan.json already has key_pairs, probe_keys,
# grain_assumption); the converter's JS output is camelCase. This script is
# the translation point — it walks relationshipCoverage and renames every
# camelCase KEY to snake_case (derivedVia -> derived_via, keyCount ->
# key_count, droppedConditions -> dropped_conditions, ...). It does NOT
# invent, normalize, or default any field the converter did not compute: a
# non-partial wired entry has no dropped_conditions key here either, exactly
# as the converter never set droppedConditions on it (see
# converter/tableau.mjs's conditional `...skippedComputed > 0 ? {...} : {}`
# spread) — this script renames keys, it does not reshape values.
#
# MISSING relationshipCoverage (no object-graph datasource in this workbook —
# a legitimate, common case: classic joins and Custom-SQL-only sources never
# set it): this script still WRITES relationship-coverage.json, as
# status:not-applicable rather than writing nothing. If --source contains an
# object-graph, missing converter coverage is itself a blocker.
#
# Usage:
#   ruby scripts/emit-relationship-coverage.rb --converter-out <PATH> --out <PATH>
#
# --converter-out reads any JSON document with a top-level "relationshipCoverage"
# key — both the shape test-relationship-derivation.rb's node shim writes
# ({model, relationshipCoverage, warnings}) and the converter's own raw return
# value (relationshipCoverage alongside whatever key the model itself is
# nested under) satisfy that, so no separate unwrapping convention is needed.
#
# Exit codes: 0 = written (and strict-clean); 2 = bad input; 3 = strict blockers.

require 'json'
require 'optparse'
require_relative 'lib/relationship_coverage'

opts = {}
OptionParser.new do |p|
  p.on('--converter-out PATH') { |v| opts[:converter_out] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
  p.on('--source PATH', 'source TWB; detects an object-graph when converter coverage is missing') { |v| opts[:source] = v }
  p.on('--dm-spec PATH', 'data-model spec/readback; count and key census must match source') { |v| opts[:dm_spec] = v }
  p.on('--strict', 'exit nonzero when any relationship is unwired or partial') { opts[:strict] = true }
end.parse!
unless opts[:converter_out] && opts[:out]
  warn 'usage: emit-relationship-coverage.rb --converter-out <PATH> --out <PATH>'
  exit 2
end

unless File.exist?(opts[:converter_out])
  warn "FATAL: required input missing: #{opts[:converter_out]}"
  exit 2
end

result = begin
  RelationshipCoverage.from_files(opts[:converter_out], opts[:source], opts[:dm_spec])
rescue JSON::ParserError => e
  warn "FATAL: #{opts[:converter_out]} is malformed JSON: #{e.message.lines.first.to_s.strip[0, 120]}"
  exit 2
rescue SystemCallError => e
  warn "FATAL: relationship coverage could not be read: #{e.message}"
  exit 2
end

File.write(opts[:out], "#{JSON.pretty_generate(result)}\n")
puts "emit-relationship-coverage: #{result['status'].upcase} — #{result['serialized']} serialized, " \
     "#{result['wired']} wired, #{result['blockers'].size} blocker(s) -> #{opts[:out]}"
if opts[:strict] && result['status'] == 'fail'
  result['blockers'].each do |blocker|
    pair = [blocker['left'], blocker['right']].compact.join(' ↔ ')
    warn "  - #{pair.empty? ? blocker['kind'] : pair}: #{blocker['reason']}"
  end
  exit 3
end
exit 0
