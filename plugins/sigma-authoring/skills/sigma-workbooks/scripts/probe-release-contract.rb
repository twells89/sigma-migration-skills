#!/usr/bin/env ruby
# frozen_string_literal: true

# Live workbook-as-code release probe. Creates one temporary workbook, validates
# readback and compiled SQL, and always deletes it.
#
# Required: SIGMA_BASE_URL, SIGMA_API_TOKEN
# Optional: SIGMA_PROBE_CONNECTION_ID, SIGMA_PROBE_TABLE_PATH (comma-separated)

require 'json'
require 'net/http'
require 'time'
require 'uri'

BASE_URL = ENV.fetch('SIGMA_BASE_URL').sub(%r{/$}, '')
TOKEN = ENV.fetch('SIGMA_API_TOKEN')
CONNECTION_ID = ENV.fetch(
  'SIGMA_PROBE_CONNECTION_ID',
  '362d859b-f432-4657-8e58-efc8535aa354'
)
TABLE_PATH = ENV.fetch(
  'SIGMA_PROBE_TABLE_PATH',
  'RETAIL,PLUGS_ELECTRONICS,F_POINT_OF_SALE'
).split(',').map(&:strip).freeze
REPEATER_DATA_MODEL_ID = ENV.fetch(
  'SIGMA_PROBE_REPEATER_DATA_MODEL_ID',
  'a8f744bb-fcab-42d0-a997-07abff1eed8f'
)
REPEATER_ELEMENT_ID = ENV.fetch('SIGMA_PROBE_REPEATER_ELEMENT_ID', 'RKOGnJDCdT')

def request(method, path, body = nil, accept: 'application/json')
  uri = URI("#{BASE_URL}#{path}")
  klass = {
    get: Net::HTTP::Get,
    post: Net::HTTP::Post,
    delete: Net::HTTP::Delete
  }.fetch(method)
  req = klass.new(uri)
  req['Authorization'] = "Bearer #{TOKEN}"
  req['Accept'] = accept
  if body
    req['Content-Type'] = 'application/json'
    req.body = JSON.generate(body)
  end
  Net::HTTP.start(
    uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 120
  ) { |http| http.request(req) }
end

def json_request(method, path, body = nil)
  response = request(method, path, body)
  parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
  [response.code.to_i, parsed]
rescue JSON::ParserError
  [response.code.to_i, { 'raw' => response.body }]
end

def home_folder_id
  code, whoami = json_request(:get, '/v2/whoami')
  raise "GET /v2/whoami -> #{code}: #{whoami}" unless code.between?(200, 299)

  member_id = whoami['memberId'] || whoami['userId'] || whoami['id']
  return whoami['homeFolderId'] || whoami['homeFolder'] if !member_id

  member_code, member = json_request(:get, "/v2/members/#{member_id}")
  candidates = [whoami]
  candidates << member if member_code.between?(200, 299)
  candidates.map { |entry| entry['homeFolderId'] || entry['homeFolder'] }.compact.first
end

def layout(element_ids = elements.map { |element| element.fetch('id') })
  ids = element_ids.to_h { |id| [id, true] }
  placed = {}
  rows = 1
  xml = [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-main">'
  ]

  if ids['header-container']
    xml << %(  <Container elementId="header-container" type="grid" gridColumn="1 / 25" gridRow="#{rows} / #{rows + 4}" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">)
    if ids['dynamic-text']
      xml << '    <Element elementId="dynamic-text" gridColumn="1 / 25" gridRow="1 / 4"/>'
      placed['dynamic-text'] = true
    end
    xml << '  </Container>'
    placed['header-container'] = true
    rows += 4
  end

  if ids['sales-repeater']
    xml << %(  <Container elementId="sales-repeater" type="grid" gridColumn="1 / 25" gridRow="#{rows} / #{rows + 10}" gridTemplateColumns="repeat(12, 1fr)" gridTemplateRows="auto">)
    if ids['repeater-text']
      xml << '    <Element elementId="repeater-text" gridColumn="1 / 13" gridRow="1 / 4"/>'
      placed['repeater-text'] = true
    end
    xml << '  </Container>'
    placed['sales-repeater'] = true
    rows += 10
  end

  if ids['record-detail']
    xml << %(  <Container elementId="record-detail" type="grid" gridColumn="1 / 25" gridRow="#{rows} / #{rows + 6}" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">)
    if ids['detail-text']
      xml << '    <Element elementId="detail-text" gridColumn="1 / 25" gridRow="1 / 4"/>'
      placed['detail-text'] = true
    end
    xml << '  </Container>'
    placed['record-detail'] = true
    rows += 6
  end

  if ids['details-tabs']
    xml << %(  <TabbedContainer elementId="details-tabs" type="tabbed-container" gridColumn="1 / 25" gridRow="#{rows} / #{rows + 10}">)
    %w[tab-summary tab-detail].each do |tab_id|
      xml << '    <Tab gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto">'
      if ids[tab_id]
        xml << %(      <Element elementId="#{tab_id}" gridColumn="1 / 25" gridRow="1 / 5"/>)
        placed[tab_id] = true
      end
      xml << '    </Tab>'
    end
    xml << '  </TabbedContainer>'
    placed['details-tabs'] = true
    rows += 10
  end

  element_ids.each do |element_id|
    next if placed[element_id]

    height = element_id == 'print-break' ? 1 : 4
    xml << %(  <Element elementId="#{element_id}" gridColumn="1 / 25" gridRow="#{rows} / #{rows + height}"/>)
    rows += height
  end
  xml << '</Page>'
  "#{xml.join("\n")}\n"
end

def warehouse_source
  {
    'kind' => 'warehouse-table', 'connectionId' => CONNECTION_ID,
    'path' => TABLE_PATH
  }
end

def elements(repeater_binding: false)
  [
    {
      'id' => 'probe-number', 'kind' => 'control', 'controlId' => 'ProbeNumber',
      'controlType' => 'number', 'name' => 'Probe number', 'mode' => '=',
      'value' => 7
    },
    {
      'id' => 'warehouse-table', 'kind' => 'table', 'name' => 'F_POINT_OF_SALE',
      'source' => warehouse_source,
      'columns' => [
        {
          'id' => 'raw-sales-amount', 'name' => 'Sales Amount',
          'formula' => '[F_POINT_OF_SALE/SALES_AMOUNT]'
        }
      ]
    },
    {
      'id' => 'sql-table', 'kind' => 'table', 'name' => 'Control SQL',
      'source' => {
        'kind' => 'sql', 'connectionId' => CONNECTION_ID,
        'statement' => 'SELECT {{ProbeNumber}} AS CONTROL_VALUE'
      },
      'columns' => [
        {
          'id' => 'control-value', 'name' => 'Control Value',
          'formula' => '[Custom SQL/CONTROL_VALUE]'
        }
      ]
    },
    {
      'id' => 'header-container', 'kind' => 'container',
      'style' => { 'backgroundColor' => '#EEF2F7' },
      'elementGap' => 'shown', 'spacing' => 'small'
    },
    {
      'id' => 'dynamic-text', 'kind' => 'text',
      'body' => 'Control value: {{[ProbeNumber]}}'
    },
    {
      'id' => 'repeater-source', 'kind' => 'table', 'name' => 'Star Events',
      'source' => {
        'kind' => 'data-model', 'dataModelId' => REPEATER_DATA_MODEL_ID,
        'elementId' => REPEATER_ELEMENT_ID
      },
      'columns' => [
        {
          'id' => 'repo-name', 'name' => 'Repo Name',
          'formula' => '[GITHUB_STAR_EVENTS/Repo Name]'
        }
      ]
    },
    {
      'id' => 'sales-repeater', 'kind' => 'repeated-container',
      'source' => { 'kind' => 'table', 'elementId' => 'repeater-source' },
      'arrangement' => 'list', 'cardSize' => 'small'
    },
    {
      'id' => 'repeater-text', 'kind' => 'text',
      # The plain child keeps the main release probe green while the strict
      # virtual-binding regression check below exercises the real derived name.
      'body' => repeater_binding ?
        '{{[Star Events repeated container/Repo Name]}}' :
        'Repeated row'
    },
    {
      'id' => 'details-tabs', 'kind' => 'tabbed-container',
      'tabs' => [{ 'name' => 'Summary' }, { 'name' => 'Detail' }],
      'tabBar' => { 'alignment' => 'left' }
    },
    { 'id' => 'tab-summary', 'kind' => 'text', 'body' => 'Summary tab' },
    { 'id' => 'tab-detail', 'kind' => 'text', 'body' => 'Detail tab' },
    {
      'id' => 'page-nav', 'kind' => 'navigation', 'mode' => 'manual',
      'options' => [
        {
          'label' => 'Main',
          'destination' => { 'type' => 'page', 'pageId' => 'page-main' }
        }
      ]
    },
    {
      'id' => 'progress-ring', 'kind' => 'progress', 'mode' => 'value',
      'min' => '0', 'max' => '10', 'value' => '7', 'shape' => 'ring'
    },
    { 'id' => 'print-break', 'kind' => 'page-break' }
  ]
end

# Non-persistent capability probes for the strengthen-workbook-authoring plan.
# Kept separate from the main create/readback workbook so a gated surface cannot
# fail the established release contract.
def capability_probe_elements
  search_source = {
    'id' => 'search-source', 'kind' => 'table', 'name' => 'Search Source',
    'source' => {
      'kind' => 'data-model', 'dataModelId' => REPEATER_DATA_MODEL_ID,
      'elementId' => REPEATER_ELEMENT_ID
    },
    'columns' => [
      {
        'id' => 'repo-name', 'name' => 'Repo Name',
        'formula' => '[GITHUB_STAR_EVENTS/Repo Name]'
      }
    ]
  }
  contains_search = {
    'id' => 'name-search', 'kind' => 'control', 'controlId' => 'NameSearch',
    'controlType' => 'text', 'name' => 'Search',
    'mode' => 'contains', 'case' => 'insensitive',
    'includeNulls' => 'when-no-value-is-selected',
    'showOperators' => false,
    'filters' => [
      {
        'source' => { 'kind' => 'table', 'elementId' => 'search-source' },
        'columnId' => 'repo-name'
      }
    ]
  }
  heatmap_table = {
    'id' => 'heatmap-table', 'kind' => 'table', 'name' => 'Heatmap Table',
    'source' => warehouse_source,
    'columns' => [
      {
        'id' => 'hm-product', 'name' => 'Product Key',
        'formula' => '[F_POINT_OF_SALE/PRODUCT_KEY]'
      },
      {
        'id' => 'hm-sales', 'name' => 'Sales Amount',
        'formula' => '[F_POINT_OF_SALE/SALES_AMOUNT]'
      }
    ],
    'conditionalFormats' => [
      {
        'type' => 'backgroundScale',
        'columnIds' => ['hm-sales'],
        'scheme' => ['#fef3c7', '#f59e0b', '#b45309']
      }
    ]
  }
  heatmap_pivot = {
    'id' => 'heatmap-pivot', 'kind' => 'pivot-table', 'name' => 'Heatmap Pivot',
    'source' => { 'kind' => 'table', 'elementId' => 'heatmap-table' },
    'columns' => [
      {
        'id' => 'pv-product', 'name' => 'Product Key',
        'formula' => '[Heatmap Table/Product Key]'
      },
      {
        'id' => 'pv-sales', 'name' => 'Sales Amount',
        'formula' => 'Sum([Heatmap Table/Sales Amount])'
      }
    ],
    'values' => ['pv-sales'],
    'rowsBy' => [{ 'columnId' => 'pv-product' }],
    'conditionalFormats' => [
      {
        'type' => 'backgroundScale',
        'columnIds' => ['pv-sales'],
        'scheme' => ['#eff6ff', '#2563eb']
      }
    ]
  }
  selected_key = {
    'id' => 'selected-product', 'kind' => 'control',
    'controlId' => 'SelectedProduct', 'controlType' => 'number',
    'name' => 'Selected product', 'mode' => '=', 'value' => 0
  }
  select_table = {
    'id' => 'select-table', 'kind' => 'table', 'name' => 'Select Table',
    'source' => warehouse_source,
    'columns' => [
      {
        'id' => 'sel-product', 'name' => 'Product Key',
        'formula' => '[F_POINT_OF_SALE/PRODUCT_KEY]'
      },
      {
        'id' => 'sel-sales', 'name' => 'Sales Amount',
        'formula' => '[F_POINT_OF_SALE/SALES_AMOUNT]',
        'hidden' => true
      }
    ],
    'actions' => [
      {
        'id' => 'select-record',
        'trigger' => 'on-select',
        'effects' => [
          {
            'effect' => 'set-control-value',
            'control' => 'SelectedProduct',
            'selectionMode' => 'replace',
            'value' => {
              'type' => 'formula',
              'formula' => '[Selection/Product Key]'
            }
          },
          {
            'effect' => 'set-single-row-container',
            'target' => {
              'type' => 'container',
              'containerElementId' => 'record-detail'
            },
            'value' => {
              'type' => 'formula',
              'formula' => '[Selection/Product Key]'
            }
          }
        ]
      }
    ]
  }
  record_detail = {
    'id' => 'record-detail', 'kind' => 'single-row-container',
    'source' => { 'kind' => 'table', 'elementId' => 'select-table' },
    'keyColumnId' => 'sel-product'
  }
  detail_text = {
    'id' => 'detail-text', 'kind' => 'text',
    'body' => 'Selected: {{[SelectedProduct]}}'
  }

  {
    'text contains search' => [search_source, contains_search],
    'table backgroundScale heatmap' => [heatmap_table],
    'pivot backgroundScale heatmap' => [heatmap_table, heatmap_pivot],
    'table on-select to control and single-row detail' => [
      selected_key, select_table, record_detail, detail_text
    ]
  }
end

def create_spec(folder_id, probe_elements: elements, probe_layout: :auto)
  if probe_layout == :auto
    probe_layout = layout(probe_elements.map { |element| element.fetch('id') })
  end
  {
    'name' => "WAC release probe #{Time.now.utc.iso8601}",
    'folderId' => folder_id,
    'description' => 'Temporary workbook; created and deleted by probe-release-contract.rb',
    'document' => {
      'schemaVersion' => 1,
      'kind' => 'workbook',
      'pages' => [
        {
          'id' => 'page-main', 'name' => 'Main',
          'backgroundColor' => '#F8FAFC'
        }
      ],
      'elements' => probe_elements,
      'layout' => probe_layout
    }
  }
end

def check!(description)
  raise "FAIL — #{description}" unless yield

  puts "PASS — #{description}"
end

def check_response!(description, code, result)
  return puts("PASS — #{description}") if yield

  raise "FAIL — #{description} (HTTP #{code}): #{JSON.generate(result)}"
end

def dependency_not_found?(result, target)
  JSON.generate(result).match?(
    /Dependency not found[^"]*#{Regexp.escape(target)}/i
  )
end

def expected_regression!(description, code, result)
  unless yield
    raise "FAIL — #{description} did not reproduce (HTTP #{code}): #{JSON.generate(result)}"
  end

  puts "EXPECTED REGRESSION — #{description} (HTTP #{code})"
end

folder_id = home_folder_id
abort 'could not resolve a home folder id' unless folder_id

unplaced = create_spec(
  folder_id,
  probe_elements: [{ 'id' => 'orphan', 'kind' => 'text', 'body' => 'orphan' }],
  probe_layout: nil
)
code, result = json_request(:post, '/v2/workbooks/spec/verify', unplaced)
check_response!(
  'verify rejects a non-empty document without layout placement', code, result
) do
  !code.between?(200, 299) || result['valid'] == false
end

legacy_layout = create_spec(
  folder_id,
  probe_elements: [{ 'id' => 'legacy-leaf', 'kind' => 'text', 'body' => 'legacy' }]
)
legacy_layout['document']['layout'] =
  legacy_layout.dig('document', 'layout').sub('<Element ', '<LayoutElement ')
code, result = json_request(:post, '/v2/workbooks/spec/verify', legacy_layout)
check_response!('verify rejects legacy <LayoutElement>', code, result) do
  rejected = code == 400 || (code.between?(200, 299) && result['valid'] == false)
  rejected && JSON.generate(result).include?('LayoutElement')
end

all_elements = elements(repeater_binding: false)
by_id = all_elements.to_h { |element| [element.fetch('id'), element] }
scenarios = {
  'number control' => %w[probe-number],
  'raw warehouse formula' => %w[warehouse-table],
  'Custom SQL control reference' => %w[probe-number sql-table],
  'dynamic-text control reference' => %w[probe-number header-container dynamic-text],
  'repeated container with an unbound child' => %w[repeater-source sales-repeater repeater-text],
  'tabbed container layout' => %w[details-tabs tab-summary tab-detail],
  'manual navigation' => %w[page-nav],
  'progress ring' => %w[progress-ring],
  'page break' => %w[print-break],
  'combined release contract' => all_elements.map { |element| element.fetch('id') }
}
failed_scenarios = []
scenarios.each do |description, ids|
  scenario_elements = ids.map { |id| by_id.fetch(id) }
  scenario_spec = create_spec(folder_id, probe_elements: scenario_elements)
  code, result = json_request(:post, '/v2/workbooks/spec/verify', scenario_spec)
  valid = code.between?(200, 299) && result['valid'] == true
  if valid
    puts "PASS — #{description} verifies"
  else
    warn "FAIL — #{description} verify response (HTTP #{code}): #{JSON.generate(result)}"
    failed_scenarios << description
  end
end

# Capability probes from the strengthen-workbook-authoring plan. Verify-only —
# never create — so they cannot pollute the main release workbook.
capability_probe_elements.each do |description, scenario_elements|
  scenario_spec = create_spec(folder_id, probe_elements: scenario_elements)
  code, result = json_request(:post, '/v2/workbooks/spec/verify', scenario_spec)
  valid = code.between?(200, 299) && result['valid'] == true
  if valid
    puts "PASS — #{description} verifies"
  else
    warn "FAIL — #{description} verify response (HTTP #{code}): #{JSON.generate(result)}"
    failed_scenarios << description
  end
end
raise "release verify scenarios failed: #{failed_scenarios.join(', ')}" unless failed_scenarios.empty?

# A correct binding exists in GET readbacks, but both verify and create reject
# the synthesized target as of 2026-08-08. Keep this strict and separate: the
# main create/readback must exercise the rest of the release contract.
binding_target = 'Star Events repeated container/Repo Name'
strict_ids = %w[repeater-source sales-repeater repeater-text]
strict_elements = elements(repeater_binding: true)
  .select { |element| strict_ids.include?(element.fetch('id')) }
strict_spec = create_spec(folder_id, probe_elements: strict_elements)
code, result = json_request(:post, '/v2/workbooks/spec/verify', strict_spec)
expected_regression!(
  "verify rejects correct repeater virtual binding #{binding_target.inspect}",
  code,
  result
) do
  result['valid'] == false && dependency_not_found?(result, binding_target)
end

strict_workbook_id = nil
begin
  code, result = json_request(:post, '/v2/workbooks/spec', strict_spec)
  strict_workbook_id = result['workbookId'] if code.between?(200, 299)
  expected_regression!(
    "create rejects correct repeater virtual binding #{binding_target.inspect}",
    code,
    result
  ) do
    !code.between?(200, 299) && dependency_not_found?(result, binding_target)
  end
ensure
  if strict_workbook_id
    json_request(:delete, "/v2/files/#{strict_workbook_id}")
  end
end

spec = create_spec(folder_id, probe_elements: all_elements)

workbook_id = nil
begin
  code, created = json_request(:post, '/v2/workbooks/spec', spec)
  raise "POST /v2/workbooks/spec -> #{code}: #{created}" unless code.between?(200, 299)

  workbook_id = created['workbookId']
  raise "create response had no workbookId: #{created}" unless workbook_id

  code, readback = json_request(:get, "/v2/workbooks/#{workbook_id}/spec")
  raise "GET workbook spec -> #{code}: #{readback}" unless code.between?(200, 299)

  document = readback.fetch('document')
  readback_elements = document.fetch('elements')
  by_id = readback_elements.to_h { |element| [element['id'], element] }
  expected_ids = all_elements.map { |element| element.fetch('id') }.sort

  check!('readback keeps elements flat and pages metadata-only') do
    readback_elements.map { |element| element['id'] }.sort == expected_ids &&
      document.fetch('pages').none? { |page| page.key?('elements') }
  end
  check!('layout readback preserves canonical grid, tab, and leaf tags only') do
    readback_layout = document.fetch('layout')
    ['<Container ', '<Element ', '<TabbedContainer ', '<Tab '].all? do |tag|
      readback_layout.include?(tag)
    end &&
      !readback_layout.match?(/<(?:GridContainer|LayoutElement)\b/)
  end
  check!('dynamic text uses controlId and survives readback') do
    by_id.dig('dynamic-text', 'body')&.include?('[ProbeNumber]')
  end
  check!('custom SQL uses controlId and survives readback') do
    by_id.dig('sql-table', 'source', 'statement')&.include?('{{ProbeNumber}}')
  end
  check!('raw warehouse column formula is accepted and read back (optionally canonicalized)') do
    !by_id.dig('warehouse-table', 'columns', 0, 'formula').to_s.empty?
  end
  check!('main probe keeps the repeated-container child intentionally unbound') do
    by_id.dig('repeater-text', 'body') == 'Repeated row'
  end
  check!('container padding is omitted rather than emitting an invalid value') do
    !by_id.dig('header-container', 'style').to_h.key?('padding')
  end
  check!('page-break readback placement spans exactly one row') do
    tag = document.fetch('layout')[/<Element\b[^>]*elementId="print-break"[^>]*>/]
    row = tag&.match(/gridRow="\s*(\d+)\s*\/\s*(\d+)"/)
    row && row[2].to_i - row[1].to_i == 1
  end

  %w[warehouse-table sql-table].each do |element_id|
    query = nil
    query_code = nil
    4.times do |attempt|
      query_code, query = json_request(
        :get, "/v2/workbooks/#{workbook_id}/elements/#{element_id}/query"
      )
      break if query_code.between?(200, 299) && query['sql']
      sleep(2**attempt)
    end
    check!("compiled SQL resolves for #{element_id}") do
      sql = query && query['sql'].to_s
      query_code&.between?(200, 299) && !sql.empty? &&
        sql !~ /Unknown column|Circular column reference|\{\{ProbeNumber\}\}/i
    end
  end
ensure
  if workbook_id
    code, response = json_request(:delete, "/v2/files/#{workbook_id}")
    warn "WARN — cleanup DELETE returned #{code}: #{response}" unless code.between?(200, 299)
  end
end
