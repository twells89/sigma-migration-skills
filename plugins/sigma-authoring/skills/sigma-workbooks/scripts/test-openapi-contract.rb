#!/usr/bin/env ruby
# frozen_string_literal: true

# Validate the skill's assumptions against a freshly downloaded OpenAPI document:
#   ruby scripts/test-openapi-contract.rb /tmp/sigma-openapi.json

require 'json'
require 'open3'

EXTRACTOR = File.expand_path('extract-openapi-contract.rb', __dir__)
openapi_path = ARGV.fetch(0) do
  abort 'usage: ruby scripts/test-openapi-contract.rb OPENAPI_JSON'
end
stdout, stderr, status = Open3.capture3('ruby', EXTRACTOR, openapi_path)
abort "extractor failed: #{stderr.strip}" unless status.success?

contract = JSON.parse(stdout)
failures = []

def assert_contract(failures, description)
  failures << description unless yield
end

schemas = contract.fetch('schemas')
create = schemas.fetch('CreateWorkbookSpec')
create_doc = schemas.fetch('CreateWorkbookSpec.document')
update = schemas.fetch('UpdateWorkbookSpec')
read_doc = schemas.fetch('WorkbookSpec.document')
page = schemas.fetch('WorkbookPage')
actions = contract.fetch('actions')
effects = actions.fetch('effects')
union_shapes = actions.fetch('unionShapes').values

# ---- the 2026-08-26 action field rename -----------------------------------
# The old contract check covered CreateWorkbookSpec and the element/control
# discriminators but had ZERO Actions coverage. So when Sigma renamed every
# action identifier field to a *Id shape, this gate stayed green and four
# repos emitted dead keys. These assertions exist so the NEXT rename is a
# failing test rather than a field incident.
#
# `_renamed` pairs are asserted in BOTH directions: the new key must be pinned
# AND the old key must be gone. Only checking the new key would keep passing if
# the API ever accepted both.
{
  'insert-rows' => 'tableElementId',
  'update-rows' => 'tableElementId',
  'delete-rows' => 'tableElementId',
  'set-form-values' => 'formElementId',
  'select-tab' => 'tabbedContainerElementId',
  'open-document' => 'documentId',
  'custom-sort' => 'elementId',
  'run-python-element' => 'codeElementId',
  'clear-chat-element-messages' => 'chatElementId'
}.each do |effect, new_key|
  assert_contract(failures, "#{effect} requires #{new_key} (post-rename)") do
    effects.fetch(effect, {}).fetch('required', []).include?(new_key)
  end
end

{
  'insert-rows' => 'table', 'update-rows' => 'table', 'delete-rows' => 'table',
  'set-form-values' => 'form', 'select-tab' => 'tabbedContainer',
  'open-document' => 'document'
}.each do |effect, dead_key|
  assert_contract(failures, "#{effect} no longer exposes the dead `#{dead_key}` key") do
    !effects.fetch(effect, {}).fetch('properties', []).include?(dead_key)
  end
end

assert_contract(failures, 'trigger-plugin uses pluginElementId + pluginEffectId') do
  effects.fetch('trigger-plugin', {}).fetch('required', []).sort == %w[pluginEffectId pluginElementId]
end

# The rename is SELECTIVE. These three were probed and deliberately NOT renamed,
# so a future "cleanup" to *Id would be a live 400. Pin the bare names.
assert_contract(failures, 'set-control-value keeps the bare `control` key') do
  effects.fetch('set-control-value', {}).fetch('required', []).include?('control')
end
assert_contract(failures, 'a {type:page} union member with a bare `page` still exists (navigate target)') do
  union_shapes.any? { |shape| shape['type'] == 'page' && shape['properties'] == ['page'] }
end
assert_contract(failures, 'a {type:element} union member with a bare `element` still exists (refresh-element target)') do
  union_shapes.any? { |shape| shape['type'] == 'element' && shape['properties'] == ['element'] }
end
assert_contract(failures, 'a {type:control} union member with a bare `control` still exists (set-control-value)') do
  union_shapes.any? { |shape| shape['type'] == 'control' && shape['properties'] == ['control'] }
end

# ...while the SAME discriminators renamed under a clear-control scope.
assert_contract(failures, 'clear-control scope union renamed to pageId/controlId/containerElementId') do
  %w[pageId controlId containerElementId].all? do |key|
    union_shapes.any? { |shape| shape['properties'] == [key] }
  end
end

# The nested half of the rename -- value sources, whichRows selectors, sort keys.
assert_contract(failures, 'column union members use columnId, never bare `column`') do
  cols = union_shapes.select { |shape| shape['type'] == 'column' }
  cols.any? && cols.none? { |shape| shape['properties'].include?('column') } &&
    cols.all? { |shape| shape['properties'].include?('columnId') }
end
assert_contract(failures, 'column-match uses columnId') do
  union_shapes.any? { |shape| shape['type'] == 'column-match' && shape['properties'] == ['columnId'] }
end
assert_contract(failures, 'column-range uses minColumnId/maxColumnId, not min/max') do
  ranges = union_shapes.select { |shape| shape['type'] == 'column-range' }
  ranges.any? && ranges.all? { |shape| shape['properties'].sort == %w[maxColumnId minColumnId] }
end

# Coverage floor: element actions currently expose 25 effects (was 22 before
# set-single-row-container / modify-element / send-embed-event landed) and
# automatedActions exposes only call-agent. A DROP means the pin lost coverage;
# a RISE means Sigma shipped an effect nobody has looked at yet.
assert_contract(failures, "element actions expose 25 effects (got #{effects.length})") do
  effects.length == 25
end
assert_contract(failures, 'automatedActions exposes call-agent (its own separate surface)') do
  actions.fetch('automatedActionEffects').key?('call-agent')
end
assert_contract(failures, 'actions pin on-select among released triggers') do
  actions.fetch('triggers').include?('on-select')
end
assert_contract(failures, 'set-single-row-container requires target + value') do
  effects.fetch('set-single-row-container', {}).fetch('required', []).sort == %w[target value]
end

element_kinds = contract.dig('releasedVariants', 'elements').map { |entry| entry.fetch('kind') }
control_types = contract.dig('releasedVariants', 'controls').map { |entry| entry.fetch('controlType') }
capabilities = contract.fetch('capabilities')
capability_kinds = capabilities.fetch('kinds')

assert_contract(failures, 'create envelope requires name, folderId, and document') do
  create.fetch('required') == %w[document folderId name]
end
assert_contract(failures, 'update requires document and now also accepts documentVersion') do
  # `documentVersion` appeared alongside `document` (optimistic concurrency on
  # PUT). It is OPTIONAL -- required is still exactly ['document'] -- so the old
  # `properties == ['document']` assertion was pinning its absence.
  update.fetch('required') == ['document'] &&
    update.fetch('properties').sort == %w[document documentVersion]
end
assert_contract(failures, 'document owns every released top-level collection') do
  %w[elements overlays pages panels settings agents layout].all? do |key|
    create_doc.fetch('properties').include?(key)
  end
end
assert_contract(failures, 'elements and pages are required document collections') do
  %w[elements pages].all? { |key| create_doc.fetch('required').include?(key) }
end
assert_contract(failures, 'pages are metadata-only and expose styling') do
  !page.fetch('properties').include?('elements') &&
    %w[backgroundColor backgroundImage].all? { |key| page.fetch('properties').include?(key) }
end
assert_contract(failures, 'layout is required on BOTH create and readback') do
  # It used to be required on readback but nullable on create, and this assertion
  # pinned that asymmetry. Create now requires it too (the 2026-08 layout
  # contract), so a spec POSTed without `layout` is rejected outright rather than
  # accepted and silently unplaced.
  read_doc.fetch('required').include?('layout') && create_doc.fetch('required').include?('layout')
end
assert_contract(failures, 'released element kinds are pinned') do
  %w[
    waterfall-chart navigation repeated-container single-row-container
    tabbed-container page-break progress table
  ].all? { |kind| element_kinds.include?(kind) }
end
assert_contract(failures, 'legend and drill controls are pinned') do
  %w[legend drill].all? { |control_type| control_types.include?(control_type) }
end
assert_contract(failures, 'box-chart is PUBLISHED (this assertion was inverted 2026-08-26)') do
  # This asserted box-chart stayed gated. It shipped: verified live against a real
  # org -- a box-chart with source/columns/yAxis returns {"valid": true} from
  # /v2/workbooks/spec/verify. `box-plot` was never a Sigma kind and stays out.
  element_kinds.include?('box-chart') && !element_kinds.include?('box-plot')
end
assert_contract(failures, 'the charts that shipped with box-chart are pinned too') do
  # All live-verified 2026-08-26 against a real org. treemap-chart and
  # sankey-chart matter most: converters were routing those to plugin fallbacks
  # or dropping them entirely on the belief that Sigma had no native equivalent.
  %w[treemap-chart sankey-chart funnel-chart gauge-chart pie-chart value-list code]
    .all? { |kind| element_kinds.include?(kind) }
end
assert_contract(failures, 'the list + file-upload control types are pinned') do
  # `file-upload` is genuinely new; `list` was always there but was dropped by the
  # extractor's discriminator lookup (see discriminator_value) -- which is why the
  # historical pin said 16 controls and not 18.
  %w[list file-upload].all? { |type| control_types.include?(type) }
end

# ---- strengthen-workbook-authoring capability pin -----------------------------
# These assertions gate the chart-selection / Ledger / theme guidance against the
# published code-rep surface. A missing field here means the plan must adapt
# before docs claim the recipe is authorable.
assert_contract(failures, 'capabilities pin chart/map/container kinds as present') do
  %w[
    bar-chart line-chart donut-chart pivot-table waterfall-chart
    geography-map point-map region-map table text
    repeated-container single-row-container
  ].all? { |kind| capability_kinds.fetch(kind, {})['present'] == true }
end
assert_contract(failures, 'heatmap-chart remains absent from the OpenAPI') do
  capabilities.fetch('absentKinds').include?('heatmap-chart') &&
    !element_kinds.include?('heatmap-chart')
end
assert_contract(failures, 'bar-chart pins horizontal orientation + stacking enums') do
  bar = capability_kinds.fetch('bar-chart')
  bar.fetch('orientation') == ['horizontal'] &&
    bar.fetch('stacking').sort == %w[none normalized stacked]
end
assert_contract(failures, 'line-chart exposes xAxis + yAxis') do
  capability_kinds.fetch('line-chart').fetch('axisFields').sort == %w[xAxis yAxis]
end
assert_contract(failures, 'donut-chart exposes value + color') do
  %w[value color].all? { |field| capability_kinds.fetch('donut-chart').fetch('valueFields').include?(field) }
end
assert_contract(failures, 'pivot-table conditionalFormats include backgroundScale') do
  capability_kinds.fetch('pivot-table').fetch('conditionalFormatTypes').include?('backgroundScale')
end
assert_contract(failures, 'waterfall-chart keeps startPoint/splitBy/waterfallShape') do
  %w[startPoint splitBy waterfallShape xAxis yAxis].all? do |field|
    capability_kinds.fetch('waterfall-chart').fetch('waterfallFields').include?(field)
  end
end
assert_contract(failures, 'geography-map requires geography.columnId') do
  capability_kinds.fetch('geography-map').dig('geography', 'required') == ['columnId']
end
assert_contract(failures, 'point-map requires latitude/longitude columnId') do
  point = capability_kinds.fetch('point-map')
  point.dig('latitude', 'required') == ['columnId'] &&
    point.dig('longitude', 'required') == ['columnId']
end
assert_contract(failures, 'region-map requires columnId + regionType') do
  region = capability_kinds.fetch('region-map').fetch('region')
  %w[columnId regionType].all? { |field| region.fetch('required').include?(field) } &&
    region.fetch('regionTypes').include?('us-state')
end
assert_contract(failures, 'document layout is required grid XML') do
  doc_caps = capabilities.fetch('document')
  doc_caps['layoutRequired'] == true &&
    doc_caps.dig('layout', 'type') == 'string' &&
    doc_caps.dig('layout', 'description').to_s.match?(/grid layout as xml/i)
end
assert_contract(failures, 'workbook theme overrides are pinned') do
  overrides = capabilities.dig('document', 'themeOverrideProperties')
  %w[categoricalScheme colors hasCards fonts space].all? { |key| overrides.include?(key) }
end
assert_contract(failures, 'text body documents {{formula}} support') do
  capability_kinds.fetch('text')['bodySupportsFormula'] == true
end
assert_contract(failures, 'table columns support hidden + backgroundScale CF') do
  table = capability_kinds.fetch('table')
  table.fetch('columnProperties').include?('hidden') &&
    table.fetch('conditionalFormatTypes').include?('backgroundScale')
end
assert_contract(failures, 'repeated-container arrangement includes list') do
  capability_kinds.fetch('repeated-container').fetch('arrangement').include?('list')
end
assert_contract(failures, 'single-row-container exposes keyColumnId/keyColumnValue/source') do
  %w[keyColumnId keyColumnValue source].all? do |field|
    capability_kinds.fetch('single-row-container').fetch('keyFields').include?(field)
  end
end
assert_contract(failures, 'text control mode includes contains') do
  capabilities.dig('controls', 'text', 'mode').to_a.include?('contains')
end

if failures.empty?
  puts "PASS — workbook OpenAPI contract (#{element_kinds.length} elements, #{control_types.length} controls)"
  exit 0
end

failures.each { |failure| warn "FAIL — #{failure}" }
exit 1
