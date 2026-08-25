#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/migration_pair'

HERE = File.expand_path(__dir__)

def assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

assert(MigrationPair.canonical_name('Orders (from Tableau)') == 'orders', 'migration suffix canonicalization')
assert(MigrationPair.name_affinity('Orders Overview', 'Orders Overview — Tableau Parity') == 1.0, 'name affinity')

Dir.mktmpdir('migration-pair-test') do |dir|
  tableau_list = File.join(dir, 'tableau.json')
  sigma_list = File.join(dir, 'sigma.json')
  discovery_out = File.join(dir, 'discovery')
  File.write(tableau_list, JSON.generate(
    'pagination' => { 'totalAvailable' => 2 },
    'workbooks' => {
      'workbook' => [
        { 'id' => 'twb-orders', 'name' => 'Orders Overview', 'contentUrl' => 'OrdersOverview' },
        { 'id' => 'twb-other', 'name' => 'Unmatched Workbook', 'contentUrl' => 'UnmatchedWorkbook' }
      ]
    }
  ))
  File.write(sigma_list, JSON.generate(
    'entries' => [
      { 'id' => 'sigma-orders', 'name' => 'Orders Overview (from Tableau)', 'updatedAt' => '2026-08-20T10:00:00Z' },
      { 'id' => 'sigma-random', 'name' => 'Finance Planning' }
    ]
  ))

  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby,
    File.join(HERE, 'discover-migration-pairs.rb'),
    '--out', discovery_out,
    '--tableau-json', tableau_list,
    '--sigma-json', sigma_list
  )
  assert(status.success?, "offline discovery failed: #{stdout}\n#{stderr}")
  discovery = JSON.parse(File.read(File.join(discovery_out, 'pair-discovery.json')))
  assert(discovery['mode'] == 'read-only', 'discovery marks read-only mode')
  assert(discovery['pairs'].length == 1, 'one source/target pair')
  assert(discovery['pairs'][0]['tableau']['luid'] == 'twb-orders', 'Tableau side retained')
  assert(discovery['pairs'][0]['sigma']['workbook_id'] == 'sigma-orders', 'Sigma side retained')
  assert(discovery['unmatched_tableau'].any? { |entry| entry['luid'] == 'twb-other' }, 'unmatched source ledger')

  tableau_meta = File.join(dir, 'tableau-meta.json')
  tableau_twb = File.join(dir, 'source.twb')
  sigma_meta = File.join(dir, 'sigma-meta.json')
  sigma_spec = File.join(dir, 'sigma-spec.json')
  capture_out = File.join(dir, 'capture')
  File.write(tableau_meta, JSON.generate('id' => 'twb-orders', 'name' => 'Orders Overview'))
  File.write(
    tableau_twb,
    <<~XML
      <workbook>
        <datasources>
          <datasource>
            <connection server="customer.example" username="alice" password="dont-keep-me" dbname="PRIVATE_DB"/>
          </datasource>
        </datasources>
      </workbook>
    XML
  )
  File.write(sigma_meta, JSON.generate('id' => 'sigma-orders', 'name' => 'Orders Overview', 'token' => 'dont-keep-token'))
  File.write(
    sigma_spec,
    JSON.generate(
      'spec' => {
        'id' => 'sigma-orders',
        'document' => {
          'pages' => [{ 'id' => 'page-live', 'name' => 'Overview' }],
          'elements' => [{ 'id' => 'element-live', 'source' => { 'dataModelId' => 'dm-live' } }]
        }
      }
    )
  )

  stdout, stderr, status = Open3.capture3(
    RbConfig.ruby,
    File.join(HERE, 'capture-migration-pair.rb'),
    '--out', capture_out,
    '--tableau-metadata', tableau_meta,
    '--tableau-twb', tableau_twb,
    '--sigma-metadata', sigma_meta,
    '--sigma-spec', sigma_spec
  )
  assert(status.success?, "offline capture failed: #{stdout}\n#{stderr}")
  captured_twb = File.read(File.join(capture_out, 'tableau', 'workbook-content.twb'), encoding: 'UTF-8')
  assert(!captured_twb.include?('customer.example'), 'server scrubbed from TWB')
  assert(!captured_twb.include?('dont-keep-me'), 'password scrubbed from TWB')
  captured_meta = File.read(File.join(capture_out, 'sigma', 'workbook-meta.json'))
  assert(!captured_meta.include?('dont-keep-token'), 'token scrubbed from metadata')
  captured_spec = JSON.parse(File.read(File.join(capture_out, 'sigma', 'workbook-spec.json')))
  assert(captured_spec.dig('spec', 'id').start_with?('id-NORM'), 'spec ids normalized')
  manifest = JSON.parse(File.read(File.join(capture_out, 'MANIFEST.json')))
  assert(manifest['capture_mode'] == 'read-only', 'capture marks read-only mode')
  assert(manifest['redaction']['extract_included'] == false, 'extracts excluded')
  assert(manifest['redaction']['view_csv_included'] == false, 'row CSVs excluded')
  assert(manifest['hygiene_ready'] == false, 'capture requires review before promotion')
  assert(Dir.glob(File.join(capture_out, '**', '*.hyper')).empty?, 'no extract files captured')
end

puts 'PASS: migration pair discovery and capture'
