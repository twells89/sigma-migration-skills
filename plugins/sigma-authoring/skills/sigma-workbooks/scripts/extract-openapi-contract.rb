#!/usr/bin/env ruby
# frozen_string_literal: true

# Extract the workbook-as-code contract needed by the live regression checks.
# Usage:
#   ruby scripts/extract-openapi-contract.rb /path/to/sigma-openapi.json

require 'json'

def merged_required(schema)
  return [] unless schema.is_a?(Hash)

  values = Array(schema['required'])
  Array(schema['allOf']).each { |part| values.concat(merged_required(part)) }
  values.uniq.sort
end

def merged_properties(schema)
  return [] unless schema.is_a?(Hash)

  values = schema.fetch('properties', {}).keys
  Array(schema['allOf']).each { |part| values.concat(merged_properties(part)) }
  values.uniq.sort
end

def property(schema, name)
  return unless schema.is_a?(Hash)
  return schema.dig('properties', name) if schema.dig('properties', name)

  Array(schema['allOf']).each do |part|
    found = property(part, name)
    return found if found
  end
  nil
end

def shape(schema)
  {
    'required' => merged_required(schema),
    'properties' => merged_properties(schema)
  }
end

# Resolve a discriminator's enum, descending oneOf/anyOf as well as allOf.
#
# `property` deliberately descends ONLY allOf, because for shape() it would be
# unsound to lift a property out of one oneOf branch and present it as the
# schema's own. For a DISCRIMINATOR that reasoning inverts: every branch of a
# variant union declares the same discriminator value, so reading it from a
# branch is correct.
#
# This exists because `list` was silently missing from the controls pin. Control
# variants are normally `{title, properties:{controlType}}`, but "List values" is
# itself a oneOf of two untitled allOf branches, so its controlType sits a level
# deeper than `property` reaches AND the branches carry no title to attribute it
# to. The result was a 17-of-18 pin that looked complete. (This predates the
# asset question -- `list` was dropped on the old asset too, which is part of why
# the historical pin said 16.)
def discriminator_value(schema, discriminator)
  return nil unless schema.is_a?(Hash)

  direct = property(schema, discriminator)
  found = direct&.fetch('enum', nil)
  return found if found

  %w[oneOf anyOf].each do |combinator|
    Array(schema[combinator]).each do |part|
      nested = discriminator_value(part, discriminator)
      return nested if nested
    end
  end
  nil
end

def collect_discriminators(schema, discriminator, out = [])
  return out unless schema.is_a?(Hash)

  values = discriminator_value(schema, discriminator)
  if schema['title'] && values&.one?
    out << { 'title' => schema['title'], discriminator => values.first }
  end
  Array(schema['oneOf']).each { |part| collect_discriminators(part, discriminator, out) }
  Array(schema['anyOf']).each { |part| collect_discriminators(part, discriminator, out) }
  Array(schema['allOf']).each { |part| collect_discriminators(part, discriminator, out) }
  out.uniq { |entry| entry[discriminator] }.sort_by { |entry| entry[discriminator] }
end

# ---- Actions coverage (issue: the 2026-08-26 action field rename) -----------
#
# The old check covered CreateWorkbookSpec and the element/control
# discriminators but had ZERO Actions coverage -- no `effect`, no insert-rows,
# nothing. So when Sigma renamed every action identifier field to a *Id shape
# (table -> tableElementId, and eight more), this gate stayed green while four
# repos emitted dead keys. It would not have caught the next one either.
#
# Effects are NOT a named schema; they hang off
# Actions.items.allOf[].properties.effects.items as a oneOf discriminated by
# `effect`. Pin each member's merged property + required sets so a rename,
# an added effect, or a newly-required field all show up as a fixture diff.
def effects_schema(actions)
  Array(actions['items'] && actions['items']['allOf']).each do |part|
    effects = property(part, 'effects')
    return effects['items'] if effects.is_a?(Hash) && effects['items']
  end
  nil
end

# Merged shape per `effect` value. Uses the same merged_* helpers as everything
# else here so allOf-split members (discriminator in one branch, properties in
# another -- which is how column-range hides minColumnId/maxColumnId) are seen.
def collect_effects(effects_items)
  out = {}
  walk = lambda do |node|
    next unless node.is_a?(Hash)
    props = merged_properties(node)
    names = props.is_a?(Hash) ? props.keys : Array(props)
    effect_prop = property(node, 'effect')
    values = effect_prop && (effect_prop['enum'] || (effect_prop['const'] ? [effect_prop['const']] : nil))
    if values
      values.each do |value|
        next unless value.is_a?(String)
        out[value] = {
          'required' => (merged_required(node) - ['effect']).sort,
          'properties' => (names - ['effect']).sort
        }
      end
    end
    Array(node['oneOf']).each { |part| walk.call(part) }
    Array(node['anyOf']).each { |part| walk.call(part) }
    Array(node['allOf']).each { |part| walk.call(part) }
  end
  walk.call(effects_items)
  out.sort.to_h
end

# The union members reached from inside an effect: value sources
# ({type: column} -> columnId), whichRows selectors, clear-control scopes,
# navigate/refresh targets. These are where the rename's NESTED half landed and
# where nothing was pinned at all. Keyed by "type" so `control` appearing with
# BOTH `control` (set-control-value, NOT renamed) and `controlId` (clear-control
# scope, renamed) is visible as two distinct shapes rather than collapsed.
def collect_union_shapes(node, out = {}, seen = {})
  return out unless node.is_a?(Hash)
  return out if seen[node.object_id]
  seen[node.object_id] = true

  type_prop = property(node, 'type')
  values = type_prop && (type_prop['enum'] || (type_prop['const'] ? [type_prop['const']] : nil))
  if values && values.length == 1 && values.first.is_a?(String)
    props = merged_properties(node)
    names = ((props.is_a?(Hash) ? props.keys : Array(props)) - ['type']).sort
    unless names.empty?
      key = "#{values.first}(#{names.join(',')})"
      out[key] = { 'type' => values.first, 'properties' => names,
                   'required' => (merged_required(node) - ['type']).sort }
    end
  end
  %w[oneOf anyOf allOf].each { |comb| Array(node[comb]).each { |part| collect_union_shapes(part, out, seen) } }
  node.each_value { |val| collect_union_shapes(val, out, seen) if val.is_a?(Hash) }
  out
end

# `automatedActions` hangs off document, not off the Actions schema.
def automated_actions_effects(document)
  aa = property(document, 'automatedActions')
  return nil unless aa.is_a?(Hash) && aa['items']
  Array(aa['items']['allOf']).each do |part|
    effects = property(part, 'effects')
    return effects['items'] if effects.is_a?(Hash) && effects['items']
  end
  nil
end

# Trigger string enums hang off Actions.items (sibling of effects), including
# `on-select` used by table/chart → detail routing.
def collect_triggers(actions)
  out = []
  seen = {}
  walk = lambda do |node|
    next unless node.is_a?(Hash)
    next if seen[node.object_id]

    seen[node.object_id] = true
    trigger = property(node, 'trigger')
    out.concat(collect_string_enums(trigger)) if trigger.is_a?(Hash)
    %w[oneOf anyOf allOf].each { |comb| Array(node[comb]).each { |part| walk.call(part) } }
    # Descend `items` / nested object values — Actions is `{type, items:{allOf}}`
    # and property() only walks allOf, so the top-level Actions node itself has
    # no `trigger` field to lift.
    node.each_value do |val|
      walk.call(val) if val.is_a?(Hash)
      Array(val).each { |part| walk.call(part) } if val.is_a?(Array)
    end
  end
  walk.call(actions)
  out.select { |value| value.is_a?(String) }.uniq.sort
end

# CommonElement $ref's untitled component schemas (notably `Table`). Those lose
# the title-gated discriminator pin above; recover kind entries via $ref walk.
def collect_ref_discriminators(schema, schemas, discriminator, out = [], seen = {})
  return out unless schema.is_a?(Hash)
  return out if seen[schema.object_id]

  seen[schema.object_id] = true
  if schema['$ref'].is_a?(String)
    name = schema['$ref'].sub(%r{\A#/components/schemas/}, '')
    target = schemas[name]
    if target.is_a?(Hash)
      values = discriminator_value(target, discriminator)
      if values&.one? && values.first.is_a?(String)
        out << { 'title' => target['title'] || name, discriminator => values.first }
      end
      collect_ref_discriminators(target, schemas, discriminator, out, seen)
    end
  end
  %w[oneOf anyOf allOf].each do |comb|
    Array(schema[comb]).each do |part|
      collect_ref_discriminators(part, schemas, discriminator, out, seen)
    end
  end
  out
end

def collect_string_enums(schema, out = [])
  return out unless schema.is_a?(Hash)

  out.concat(Array(schema['enum']).select { |value| value.is_a?(String) })
  out << schema['const'] if schema['const'].is_a?(String)
  %w[oneOf anyOf allOf].each do |comb|
    Array(schema[comb]).each { |part| collect_string_enums(part, out) }
  end
  out.uniq.sort
end

# Resolve a workbook element kind schema. Titled oneOf members (Bar Chart) and
# untitled allOf groups nested under a shared title (Donut/Pie Chart →
# donut-chart) both need to match; prefer the richest merged property set so
# orientation/stacking land on the parent allOf group rather than the
# discriminator leaf alone.
def kind_schema_match?(obj, kind)
  return false unless obj.is_a?(Hash)

  all_of = obj['allOf']
  allof_match = all_of.is_a?(Array) && all_of.any? do |part|
    part.is_a?(Hash) && part.dig('properties', 'kind', 'enum') == [kind]
  end
  allof_match || obj.dig('properties', 'kind', 'enum') == [kind]
end

def find_kind_schema(schemas, kind)
  matches = []
  walk = lambda do |node|
    next unless node.is_a?(Hash)

    matches << node if kind_schema_match?(node, kind)
    %w[oneOf anyOf allOf].each { |comb| Array(node[comb]).each { |part| walk.call(part) } }
  end
  walk.call(schemas['WorkbookElement'])
  walk.call(schemas['CommonElement'])
  return matches.max_by { |node| merged_properties(node).length } if matches.any?

  schemas.each_value do |schema|
    next unless schema.is_a?(Hash)
    return schema if kind_schema_match?(schema, kind)
  end
  nil
end

# Collect every concrete kind enum under WorkbookElement/CommonElement, even
# when the titled parent is a multi-kind union (Donut/Pie Chart). Without this,
# donut-chart is silently dropped while pie-chart inherits the parent title.
def collect_kind_entries(schemas)
  out = []
  seen = {}
  walk = lambda do |node|
    next unless node.is_a?(Hash)
    next if seen[node.object_id]

    seen[node.object_id] = true
    kind_enum = node.dig('properties', 'kind', 'enum')
    if kind_enum.nil?
      Array(node['allOf']).each do |part|
        next unless part.is_a?(Hash)

        kind_enum ||= part.dig('properties', 'kind', 'enum')
      end
    end
    if kind_enum&.one? && kind_enum.first.is_a?(String) && kind_schema_match?(node, kind_enum.first)
      props = merged_properties(node)
      # Skip tiny source-reference shapes (`{kind:table, elementId}`) — real
      # element variants declare `id`.
      if props.include?('id')
        out << { 'title' => node['title'] || kind_enum.first, 'kind' => kind_enum.first }
      end
    end
    %w[oneOf anyOf allOf].each { |comb| Array(node[comb]).each { |part| walk.call(part) } }
  end
  walk.call(schemas['WorkbookElement'])
  walk.call(schemas['CommonElement'])

  (
    collect_discriminators(schemas.fetch('WorkbookElement'), 'kind') +
    collect_discriminators(schemas.fetch('CommonElement'), 'kind') +
    collect_ref_discriminators(schemas.fetch('CommonElement'), schemas, 'kind') +
    collect_ref_discriminators(schemas.fetch('WorkbookElement'), schemas, 'kind') +
    out
  ).uniq { |entry| entry['kind'] }.sort_by { |entry| entry['kind'] }
end

def find_control_schema(schemas, control_type)
  found = []
  walk = lambda do |node|
    next unless node.is_a?(Hash)

    values = discriminator_value(node, 'controlType')
    found << node if node['title'] && values == [control_type]
    %w[oneOf anyOf allOf].each { |comb| Array(node[comb]).each { |part| walk.call(part) } }
  end
  walk.call(schemas['Control'])
  walk.call(schemas['CommonElement'])
  return found.first if found.any?

  matches = []
  walk_all = lambda do |node|
    next unless node.is_a?(Hash)

    direct = node.dig('properties', 'controlType', 'enum')
    allof = Array(node['allOf']).any? { |part| part.is_a?(Hash) && part.dig('properties', 'controlType', 'enum') == [control_type] }
    matches << node if direct == [control_type] || allof
    %w[oneOf anyOf allOf].each { |comb| Array(node[comb]).each { |part| walk_all.call(part) } }
  end
  walk_all.call(schemas['Control'])
  matches.max_by { |node| merged_properties(node).length }
end

def conditional_format_types(kind_schema)
  formats = property(kind_schema, 'conditionalFormats')
  return [] unless formats.is_a?(Hash)

  out = []
  walk = lambda do |node|
    next unless node.is_a?(Hash)

    type_prop = property(node, 'type')
    if type_prop.is_a?(Hash)
      out.concat(Array(type_prop['enum']))
      out << type_prop['const'] if type_prop['const']
    end
    %w[oneOf anyOf allOf].each { |comb| Array(node[comb]).each { |part| walk.call(part) } }
    node.each_value { |val| walk.call(val) if val.is_a?(Hash) || val.is_a?(Array) }
  end
  walk.call(formats)
  out.select { |value| value.is_a?(String) }.uniq.sort
end

def column_properties(kind_schema)
  columns = property(kind_schema, 'columns')
  return [] unless columns.is_a?(Hash) && columns['items']

  merged_properties(columns['items'])
end

# Focused capability pin for the strengthen-workbook-authoring plan: chart/map
# fields, layout/theme, text formulas, hidden columns, containers, and the
# on-select detail-routing surface. Presence here is necessary but not
# sufficient for opaque formula/XML strings — live verify remains the tiebreaker.
PINNED_CAPABILITY_KINDS = %w[
  bar-chart
  line-chart
  donut-chart
  pivot-table
  waterfall-chart
  geography-map
  point-map
  region-map
  table
  text
  repeated-container
  single-row-container
].freeze

def kind_capability(schemas, kind)
  schema = find_kind_schema(schemas, kind)
  return { 'present' => false } unless schema

  entry = shape(schema).merge('present' => true)
  case kind
  when 'bar-chart'
    entry['orientation'] = collect_string_enums(property(schema, 'orientation'))
    entry['stacking'] = collect_string_enums(property(schema, 'stacking'))
  when 'line-chart'
    entry['axisFields'] = %w[xAxis yAxis].select { |field| property(schema, field) }
  when 'donut-chart'
    entry['valueFields'] = %w[value color hole holeValue].select { |field| property(schema, field) }
  when 'pivot-table'
    entry['conditionalFormatTypes'] = conditional_format_types(schema)
  when 'waterfall-chart'
    entry['waterfallFields'] = %w[
      startPoint splitBy grouping waterfallColors waterfallShape xAxis yAxis
    ].select { |field| property(schema, field) }
  when 'geography-map'
    geography = property(schema, 'geography')
    entry['geography'] = shape(geography) if geography
  when 'point-map'
    entry['latitude'] = shape(property(schema, 'latitude'))
    entry['longitude'] = shape(property(schema, 'longitude'))
  when 'region-map'
    region = property(schema, 'region')
    entry['region'] = shape(region).merge(
      'regionTypes' => collect_string_enums(property(region, 'regionType'))
    ) if region
  when 'table'
    entry['columnProperties'] = column_properties(schema)
    entry['conditionalFormatTypes'] = conditional_format_types(schema)
  when 'text'
    body = property(schema, 'body')
    description = body.is_a?(Hash) ? body['description'].to_s : ''
    entry['bodySupportsFormula'] = description.include?('{{formula}}')
  when 'repeated-container'
    entry['arrangement'] = collect_string_enums(property(schema, 'arrangement'))
  when 'single-row-container'
    entry['keyFields'] = %w[keyColumnId keyColumnValue source].select { |field| property(schema, field) }
  end
  entry
end

def collect_capabilities(schemas, create_document)
  settings = property(create_document, 'settings')
  theme = property(settings, 'theme')
  overrides = property(theme, 'overrides')
  layout = property(create_document, 'layout')
  text_control = find_control_schema(schemas, 'text')

  {
    'kinds' => PINNED_CAPABILITY_KINDS.to_h { |kind| [kind, kind_capability(schemas, kind)] },
    'absentKinds' => %w[heatmap-chart].select { |kind| find_kind_schema(schemas, kind).nil? },
    'document' => {
      'layoutRequired' => merged_required(create_document).include?('layout'),
      'layout' => layout.is_a?(Hash) ? {
        'type' => layout['type'],
        'description' => layout['description']
      }.compact : nil,
      'themeOverrideProperties' => overrides ? merged_properties(overrides) : []
    },
    'controls' => {
      'text' => if text_control
                 shape(text_control).merge(
                   'mode' => collect_string_enums(property(text_control, 'mode'))
                 )
               end
    }.compact
  }
end

path = ARGV.fetch(0) { abort 'usage: extract-openapi-contract.rb OPENAPI_JSON' }
openapi = JSON.parse(File.read(path))
schemas = openapi.fetch('components').fetch('schemas')
create = schemas.fetch('CreateWorkbookSpec')
update = schemas.fetch('UpdateWorkbookSpec')
read = schemas.fetch('WorkbookSpec')
create_document = property(create, 'document')
update_document = property(update, 'document')
read_document = property(read, 'document')
pages = property(create_document, 'pages')
actions_schema = schemas.fetch('Actions')

contract = {
  'schemas' => {
    'CreateWorkbookSpec' => shape(create),
    'CreateWorkbookSpec.document' => shape(create_document),
    'UpdateWorkbookSpec' => shape(update),
    'UpdateWorkbookSpec.document' => shape(update_document),
    'WorkbookSpec' => shape(read),
    'WorkbookSpec.document' => shape(read_document),
    'WorkbookPage' => shape(pages.fetch('items'))
  },
  'releasedVariants' => {
    'elements' => collect_kind_entries(schemas),
    # Controls come from the dedicated `Control` schema, NOT CommonElement.
    # This read CommonElement and returned ZERO on the canonical asset, which
    # looked like "Sigma removed every control type" and was really the wrong
    # schema: `controlType` appears 218x in the asset and Control.oneOf has 18
    # members. Verified live 2026-08-26 -- `list` and `file-upload` (the two the
    # old 16-control check lacked) both verify valid:true against the API.
    # Kept CommonElement in the union so a future reshuffle back is still seen.
    'controls' => (
      collect_discriminators(schemas.fetch('Control'), 'controlType') +
      collect_discriminators(schemas.fetch('CommonElement'), 'controlType')
    ).uniq { |entry| entry['controlType'] }.sort_by { |entry| entry['controlType'] }
  },
  # Per-effect property/required sets + the nested union shapes they reference.
  # A rename on either level is now a failing assertion instead of a silent 400.
  'actions' => {
    # ELEMENT-level actions (the `Actions` schema). This is what a button /
    # on-select emits and what the converters generate.
    'triggers' => collect_triggers(actions_schema),
    'effects' => collect_effects(effects_schema(actions_schema)),
    'unionShapes' => collect_union_shapes(actions_schema).sort.to_h,
    # DOCUMENT-level `automatedActions` is a SEPARATE surface with its own effect
    # union -- `call-agent` exists only here. Checked so a rename on either
    # surface is a diff; note automatedActions is documented as UI-authorable
    # only, so this is contract-tracking, not an emit target.
    'automatedActionEffects' => collect_effects(automated_actions_effects(create_document))
  },
  'capabilities' => collect_capabilities(schemas, create_document)
}

puts JSON.pretty_generate(contract)
