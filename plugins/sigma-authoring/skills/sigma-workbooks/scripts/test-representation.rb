#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline round-trip regression for wb-rep and validate-spec.

require 'fileutils'
require 'open3'
require 'tmpdir'
require 'yaml'

ROOT = File.expand_path('..', __dir__)
WB_REP = File.join(__dir__, 'wb-rep.rb')
VALIDATOR = File.join(__dir__, 'validate-spec.sh')
failures = []

def check(failures, description)
  if yield
    puts "PASS — #{description}"
  else
    failures << description
    warn "FAIL — #{description}"
  end
end

layout = <<~XML
  <?xml version="1.0" encoding="utf-8"?>
  <Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-main">
    <Container elementId="container" type="grid" gridColumn="1 / 25" gridRow="1 / 5" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">
      <Element elementId="title" gridColumn="1 / 25" gridRow="1 / 5"/>
    </Container>
  </Page>
  <Overlay type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="overlay-detail">
    <Element elementId="detail" gridColumn="1 / 25" gridRow="1 / 8"/>
  </Overlay>
  <Panel type="grid" gridTemplateColumns="repeat(6, 1fr)" gridTemplateRows="auto" id="panel-filter">
    <Element elementId="filter-copy" gridColumn="1 / 6" gridRow="1 / 4"/>
  </Panel>
XML

spec = {
  'name' => 'Representation test',
  'folderId' => 'folder-test',
  'document' => {
    'schemaVersion' => 1,
    'kind' => 'workbook',
    'elements' => [
      { 'id' => 'container', 'kind' => 'container' },
      { 'id' => 'title', 'kind' => 'text', 'body' => 'Hello' },
      { 'id' => 'detail', 'kind' => 'text', 'body' => 'Detail' },
      { 'id' => 'filter-copy', 'kind' => 'control', 'controlId' => 'Region',
        'controlType' => 'synced' }
    ],
    'pages' => [
      { 'id' => 'page-main', 'name' => 'Main', 'backgroundColor' => '#F8FAFC' }
    ],
    'overlays' => [
      { 'id' => 'overlay-detail', 'name' => 'Detail', 'type' => 'modal' }
    ],
    'panels' => [
      { 'id' => 'panel-filter', 'name' => 'Filters' }
    ],
    'layout' => layout,
    'settings' => { 'navigation' => { 'pageHeader' => 'enabled' } }
  }
}

Dir.mktmpdir('wb-rep-roundtrip') do |tmp|
  source = File.join(tmp, 'source.yaml')
  rep = File.join(tmp, 'rep')
  assembled_path = File.join(tmp, 'assembled.yaml')
  File.write(source, YAML.dump(spec))

  import_out, import_status = Open3.capture2e('ruby', WB_REP, 'import', source, rep)
  check(failures, 'import succeeds') { import_status.success? && import_out.include?('imported') }
  check(failures, 'elements are top-level files') do
    Dir[File.join(rep, 'elements', '*.yaml')].length == spec.dig('document', 'elements').length
  end
  check(failures, 'page/overlay/panel directories contain metadata and layout only') do
    %w[pages overlays panels].all? do |collection|
      Dir[File.join(rep, collection, '*', '*.yaml')].all? do |path|
        File.basename(path).start_with?('_')
      end
    end
  end

  assemble_out, assemble_status = Open3.capture2e(
    'ruby', WB_REP, 'assemble', rep, '-o', assembled_path
  )
  assembled = YAML.load_file(assembled_path) if File.exist?(assembled_path)
  check(failures, 'assemble succeeds') do
    assemble_status.success? && assemble_out.include?('wrote') && assembled
  end
  check(failures, 'import/assemble round-trip preserves the canonical document') do
    assembled == spec
  end

  validate_out, validate_status = Open3.capture2e('bash', VALIDATOR, assembled_path)
  check(failures, 'validator accepts fully placed flat elements') do
    validate_status.success? && validate_out.include?('OK:')
  end

  raw_warehouse = Marshal.load(Marshal.dump(spec))
  raw_warehouse['document']['elements'] << {
    'id' => 'warehouse', 'kind' => 'table',
    'source' => {
      'kind' => 'warehouse-table', 'connectionId' => 'connection-test',
      'path' => %w[DB SCHEMA ORDERS]
    },
    'columns' => [
      { 'id' => 'warehouse-amount', 'name' => 'Sales Amount',
        'formula' => '[SALES_AMOUNT]' }
    ]
  }
  raw_warehouse['document']['layout'] = raw_warehouse['document']['layout'].sub(
    '</Page>',
    '  <Element elementId="warehouse" gridColumn="1 / 25" gridRow="5 / 15"/>' \
    "\n</Page>"
  )
  raw_warehouse_path = File.join(tmp, 'raw-warehouse.yaml')
  File.write(raw_warehouse_path, YAML.dump(raw_warehouse))
  raw_out, raw_status = Open3.capture2e('bash', VALIDATOR, raw_warehouse_path)
  check(failures, 'validator accepts raw bare columns on warehouse-table sources') do
    raw_status.success? && raw_out.include?('OK:')
  end

  derived_bare = Marshal.load(Marshal.dump(raw_warehouse))
  derived_bare['document']['elements'].last['source'] = {
    'kind' => 'table', 'elementId' => 'detail'
  }
  derived_bare_path = File.join(tmp, 'derived-bare.yaml')
  File.write(derived_bare_path, YAML.dump(derived_bare))
  derived_out, derived_status = Open3.capture2e('bash', VALIDATOR, derived_bare_path)
  check(failures, 'validator still rejects unresolved bare refs on derived sources') do
    !derived_status.success? && derived_out.include?('Unresolved bare refs: SALES_AMOUNT')
  end

  invalid = Marshal.load(Marshal.dump(spec))
  invalid['document']['pages'][0]['elements'] = [{ 'id' => 'nested', 'kind' => 'text' }]
  invalid['document']['layout'] = invalid['document']['layout'].sub(
    '</Page>',
    '  <Element elementId="title" gridColumn="1 / 25" gridRow="5 / 8"/>' \
    "\n</Page>"
  )
  invalid_path = File.join(tmp, 'invalid.yaml')
  File.write(invalid_path, YAML.dump(invalid))
  invalid_out, invalid_status = Open3.capture2e('bash', VALIDATOR, invalid_path)
  invalid_ok = !invalid_status.success? &&
               invalid_out.include?('forbidden nested elements') &&
               invalid_out.include?('placed more than once')
  warn invalid_out unless invalid_ok
  check(failures, 'validator rejects nested elements and duplicate placement') do
    invalid_ok
  end

  contract_invalid = Marshal.load(Marshal.dump(spec))
  contract_invalid['document']['elements'][0]['style'] = { 'padding' => 'small' }
  contract_invalid['document']['elements'] << {
    'id' => 'bad-break', 'kind' => 'page-break'
  }
  contract_invalid['document']['layout'] = contract_invalid['document']['layout']
    .sub('<Element elementId="detail"', '<LayoutElement elementId="detail"')
    .sub(
      '</Page>',
      '  <Element elementId="bad-break" gridColumn="1 / 25" gridRow="5 / 7"/>' \
      "\n</Page>"
    )
  contract_invalid_path = File.join(tmp, 'contract-invalid.yaml')
  File.write(contract_invalid_path, YAML.dump(contract_invalid))
  contract_out, contract_status = Open3.capture2e(
    'bash', VALIDATOR, contract_invalid_path
  )
  contract_ok = !contract_status.success? &&
                contract_out.include?('emit <Element>') &&
                contract_out.include?('style.padding must be none or omitted') &&
                contract_out.include?('must span exactly one grid row')
  warn contract_out unless contract_ok
  check(failures, 'validator rejects legacy emission, bad container padding, and tall page breaks') do
    contract_ok
  end
end

exit(failures.empty? ? 0 : 1)
