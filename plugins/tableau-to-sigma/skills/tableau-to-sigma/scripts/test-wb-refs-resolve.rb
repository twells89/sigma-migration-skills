#!/usr/bin/env ruby
# frozen_string_literal: true
# Offline test for assert-wb-refs-resolve.rb (Tier 1 #2). Drives the gate as a
# subprocess against fixture wb-spec + dm-ids files. The a real multi-datasource workbook
# (2026-07-08): a multi-datasource collapse left workbook [Master/...] refs
# pointing at columns absent from the live DM; this gate must catch them BEFORE
# the POST that would otherwise return an opaque "Dependency not found".
require 'json'
require 'tmpdir'

GATE = File.join(__dir__, 'assert-wb-refs-resolve.rb')
FAILS = []
def check(cond, msg)
  puts((cond ? '  ok  ' : '  FAIL ') + msg)
  FAILS << msg unless cond
end

def run_gate(spec, dmids, *extra)
  Dir.mktmpdir do |d|
    File.write(File.join(d, 'wb.json'), JSON.generate(spec))
    File.write(File.join(d, 'dm.json'), JSON.generate(dmids))
    out = `ruby #{GATE} --wb-spec #{d}/wb.json --dm-ids #{d}/dm.json #{extra.join(' ')} 2>&1`
    [$?.exitstatus, out]
  end
end

DM = { 'dataModelId' => 'dm1', 'pages' => [{ 'elements' => [
  { 'id' => 'e1', 'name' => 'Master',
    'columnLabels' => ['Net Revenue', 'Region', 'Customer Id (CUSTOMER_DIM)'] }
] }] }

# all refs resolve (incl. suffix-normalized "Customer Id")
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => 'Sum([Master/Net Revenue])' },
  { 'formula' => '[Master/Customer Id]' }
] }] }] }, DM)
check(rc == 0, 'all-resolving spec passes (exit 0), suffix-normalized match works')

# dropped columns (multi-DS collapse) → fail with exit 1
rc, out = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [
  { 'formula' => 'Sum([Master/Net Revenue])' },
  { 'formula' => '[Master/Partner Name]' },
  { 'formula' => '[SKU Master/Product Code]' }
] }] }] }, DM)
check(rc == 1, 'dropped-column refs fail (exit 1)')
check(out.include?('Partner Name') && out.include?('Product Code'), 'names the unresolved columns')
check(out.downcase.include?('multi-datasource'), 'points at the multi-datasource cause')

# empty DM → fail
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [{ 'formula' => '[Master/X]' }] }] }] },
               { 'pages' => [{ 'elements' => [{ 'name' => 'Master', 'columnLabels' => [] }] }] })
check(rc == 1, 'empty DM fails (exit 1)')

# waiver → skip (exit 0)
rc, = run_gate({ 'pages' => [{ 'elements' => [{ 'columns' => [{ 'formula' => '[Master/Partner Name]' }] }] }] },
               DM, '--skip-ref-check', '"known, building manually"')
check(rc == 0, '--skip-ref-check waives (exit 0)')

puts(FAILS.empty? ? "\nall wb-refs-resolve tests passed" : "\n#{FAILS.length} FAILED")
exit(FAILS.empty? ? 0 : 1)
