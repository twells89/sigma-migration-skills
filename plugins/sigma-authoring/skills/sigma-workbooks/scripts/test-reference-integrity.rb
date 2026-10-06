#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline reference-integrity regression for wb-rep's `lint` command.
#
# Why this exists: Sigma's POST /v2/workbooks/spec/verify does NOT validate a
# control's wiring `filters[].columnId`. Measured 2026-08-20 — a control whose
# filter points at a nonexistent column returns valid:true with zero errors,
# saves with the bogus id intact, and compiles with zero errors. The control
# simply stops filtering. These cases close that gap offline.

require 'open3'
require 'tmpdir'
require 'yaml'

WB_REP = File.join(__dir__, 'wb-rep.rb')
failures = []

def check(failures, description)
  if yield
    puts "PASS — #{description}"
  else
    failures << description
    warn "FAIL — #{description}"
  end
end

# Synthetic spec: hub table + derived table + control wired to both.
# Deliberately NOT a real workbook — no org data.
def base_spec
  {
    'name' => 'refint fixture',
    'folderId' => '00000000-0000-0000-0000-000000000000',
    'document' => {
      'schemaVersion' => 1,
      'kind' => 'workbook',
      'elements' => [
        { 'id' => 'hub', 'kind' => 'table',
          'source' => { 'kind' => 'data-model', 'dataModelId' => 'dm-1', 'elementId' => 'dm-el' },
          'columns' => [{ 'id' => 'c-region', 'formula' => '[Model/Region]' },
                        { 'id' => 'c-amount', 'formula' => '[Model/Amount]' }] },
        { 'id' => 'derived', 'kind' => 'table',
          'source' => { 'kind' => 'table', 'elementId' => 'hub' },
          'columns' => [{ 'id' => 'd-region', 'formula' => '[Region]' }] },
        { 'id' => 'ctl', 'kind' => 'control', 'controlId' => 'region',
          'controlType' => 'list', 'source' => { 'kind' => 'manual', 'valueType' => 'text', 'values' => ['x'] },
          'filters' => [{ 'source' => { 'kind' => 'table', 'elementId' => 'hub' }, 'columnId' => 'c-region' },
                        { 'source' => { 'kind' => 'table', 'elementId' => 'derived' }, 'columnId' => 'd-region' }] }
      ],
      'pages' => [{ 'id' => 'p1', 'name' => 'Page 1' }],
      'layout' => <<~XML
        <?xml version="1.0" encoding="utf-8"?>
        <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="p1">
          <Element elementId="hub" gridColumn="1 / 25" gridRow="1 / 5"/>
          <Element elementId="derived" gridColumn="1 / 13" gridRow="5 / 9"/>
          <Element elementId="ctl" gridColumn="13 / 25" gridRow="5 / 7"/>
        </Page>
      XML
    }
  }
end

def lint(spec)
  Dir.mktmpdir('refint') do |tmp|
    path = File.join(tmp, 'spec.yaml')
    File.write(path, YAML.dump(spec))
    out, status = Open3.capture2e('ruby', WB_REP, 'lint', path)
    [out, status.success?]
  end
end

def el(spec, id)
  spec['document']['elements'].find { |e| e['id'] == id }
end

# A real lint rejection: non-zero exit, a lint message, and NOT a usage error.
# Without this guard every negative assertion passes vacuously whenever the
# `lint` command is missing or crashes.
def rejected?(out, ok, *must_mention)
  return false if ok
  return false if out.include?('usage:')
  return false unless out.match?(/lint|validation|reference/i)
  must_mention.all? { |m| out.include?(m) }
end

# --- 1. clean spec passes ---
clean_out, clean_ok = lint(base_spec)
check(failures, 'clean spec passes lint') { clean_ok }
warn clean_out unless clean_ok

# --- 2. THE MEASURED HOLE: control wiring -> nonexistent column ---
spec = base_spec
el(spec, 'ctl')['filters'][0]['columnId'] = 'GONE-COL'
out, ok = lint(spec)
check(failures, 'control wiring filter on a nonexistent columnId is rejected') do
  rejected?(out, ok, 'GONE-COL', 'hub')
end

# --- 3. control wiring -> column that exists, but on the WRONG element ---
spec = base_spec
el(spec, 'ctl')['filters'][0]['columnId'] = 'd-region' # belongs to `derived`, not `hub`
out, ok = lint(spec)
check(failures, "control wiring using another element's columnId is rejected") do
  rejected?(out, ok, 'd-region')
end

# --- 4. control wiring -> unknown target element ---
spec = base_spec
el(spec, 'ctl')['filters'][1]['source']['elementId'] = 'GONE-ELEM'
out, ok = lint(spec)
check(failures, 'control wiring targeting an unknown element is rejected') do
  rejected?(out, ok, 'GONE-ELEM')
end

# --- 5. element-predicate filter -> nonexistent column on its own element ---
spec = base_spec
el(spec, 'hub')['filters'] = [{ 'id' => 'f1', 'columnId' => 'GONE-COL',
                                'kind' => 'list', 'mode' => 'include', 'values' => ['x'] }]
out, ok = lint(spec)
check(failures, 'element-predicate filter on a nonexistent columnId is rejected') do
  rejected?(out, ok, 'GONE-COL')
end

# --- 6. element-predicate filter is scoped to its OWN element (no cross-element lookup) ---
spec = base_spec
el(spec, 'hub')['filters'] = [{ 'id' => 'f1', 'columnId' => 'd-region',
                                'kind' => 'list', 'mode' => 'include', 'values' => ['x'] }]
out, ok = lint(spec)
check(failures, "element-predicate filter using another element's columnId is rejected") do
  rejected?(out, ok, 'd-region')
end

# --- 7. valid element-predicate filter still passes (no false positive) ---
spec = base_spec
el(spec, 'hub')['filters'] = [{ 'id' => 'f1', 'columnId' => 'c-region',
                                'kind' => 'list', 'mode' => 'include', 'values' => ['x'] }]
out, ok = lint(spec)
check(failures, 'valid element-predicate filter passes') { ok }
warn out unless ok

# --- 8. lint still enforces the existing layout contract ---
spec = base_spec
spec['document']['elements'] << { 'id' => 'orphan', 'kind' => 'table',
                                  'source' => { 'kind' => 'table', 'elementId' => 'hub' },
                                  'columns' => [] }
out, ok = lint(spec)
check(failures, 'lint still rejects an element missing from the layout') do
  rejected?(out, ok, 'orphan')
end

if failures.empty?
  puts "\nAll reference-integrity checks passed."
else
  warn "\n#{failures.length} failure(s):"
  failures.each { |f| warn "  - #{f}" }
  exit 1
end
