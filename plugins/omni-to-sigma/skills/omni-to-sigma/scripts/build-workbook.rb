#!/usr/bin/env ruby
# frozen_string_literal: true
# Normalized Omni dashboard export → Sigma workbook spec.
#
#   ruby scripts/build-workbook.rb --export dashboard.json --out wb.json \
#     --dm-id <id> --dm-element-id el-topic-orders --dm-element-name Orders
#
# Layout XML is attached as the LAST write, after element ids are final.
# A later spec PUT that omits layout wipes it — re-send this layout.
#
# Creds-free. Unknown chart types are skipped into chart-gaps.json.

require 'json'
require 'optparse'
require_relative 'lib/omni_export'
require_relative 'lib/omni_chart_map'
require_relative 'lib/omni_model'
require_relative 'lib/omni_formula'
require_relative 'lib/layout_lint'
require_relative 'lib/control_lint'
require_relative 'lib/code_rep'

GRID = 24

def field_parts(ref)
  m = ref.to_s.match(/\A([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)(?:\[([A-Za-z0-9_]+)\])?\z/)
  return nil unless m
  { 'view' => m[1], 'field' => m[2], 'frame' => m[3] }
end

def column_for_field(ref, dm_name, displays)
  parts = field_parts(ref)
  return nil unless parts
  base = displays[[parts['view'], parts['field']]] || OmniFormula.display_name(parts['field'])
  if parts['frame']
    name = "#{base} #{parts['frame'].capitalize}"
    formula = %[DateTrunc("#{parts['frame']}", [#{dm_name}/#{base}])]
  else
    name = base
    formula = "[#{dm_name}/#{base}]"
  end
  { 'name' => name, 'formula' => formula, 'id' => "fld-#{parts['view']}-#{parts['field']}-#{parts['frame'] || 'raw'}" }
end

def layout_xml(page_id, rows)
  body = rows.map do |row|
    %(  <Element elementId="#{row['id']}" gridColumn="#{row['c0']} / #{row['c1']}" gridRow="#{row['r0']} / #{row['r1']}"/>)
  end
  ["<Page type=\"grid\" gridTemplateColumns=\"repeat(#{GRID}, 1fr)\" gridTemplateRows=\"auto\" id=\"#{page_id}\">",
   *body, '</Page>'].join("\n")
end

if __FILE__ == $PROGRAM_NAME
  opts = {
    dm_id: 'fixture-dm',
    dm_element_id: 'el-topic-orders',
    dm_element_name: 'Orders'
  }
  OptionParser.new do |o|
    o.on('--export PATH') { |v| opts[:export] = v }
    o.on('--model-dir DIR') { |v| opts[:model_dir] = v }
    o.on('--topic NAME') { |v| opts[:topic] = v }
    o.on('--dm-id ID') { |v| opts[:dm_id] = v }
    o.on('--dm-element-id ID') { |v| opts[:dm_element_id] = v }
    o.on('--dm-element-name NAME') { |v| opts[:dm_element_name] = v }
    o.on('--folder-id ID') { |v| opts[:folder_id] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
  end.parse!(ARGV)
  { export: '--export', out: '--out' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end

  board = OmniExport.load(opts[:export])
  displays = {}
  if opts[:model_dir]
    model = OmniModel.load(opts[:model_dir])
    model['views'].each do |view_name, view|
      (view['dimensions'] || {}).each do |field, spec|
        spec = {} unless spec.is_a?(Hash)
        displays[[view_name, field.to_s]] = OmniFormula.display_name(field, spec['label'])
      end
      (view['measures'] || {}).each do |field, spec|
        spec = {} unless spec.is_a?(Hash)
        displays[[view_name, field.to_s]] = OmniFormula.display_name(field, spec['label'])
      end
    end
  end

  warnings = []
  gaps = []
  data_columns = {}
  chart_elements = []
  board['tiles'].each do |tile|
    kind = OmniChartMap.kind_for(tile['chartType'])
    if kind.nil?
      gaps << { 'tile' => tile['id'], 'name' => tile['name'], 'chartType' => tile['chartType'],
                'reason' => 'no Sigma kind (custom/markdown/unknown)' }
      warnings << "tile #{tile['id']} (#{tile['chartType'].inspect}) skipped — no Sigma chart kind"
      next
    end
    cols = []
    tile['fields'].each do |ref|
      col = column_for_field(ref, opts[:dm_element_name], displays)
      unless col
        warnings << "tile #{tile['id']} field #{ref} skipped — not view.field"
        next
      end
      data_columns[col['id']] ||= {
        'id' => col['id'],
        'name' => col['name'],
        'formula' => col['formula']
      }
      cols << {
        'id' => "chart-#{tile['id']}-#{col['id']}",
        'name' => col['name'],
        'formula' => "[Orders Data/#{col['name']}]"
      }
    end
    chart_elements << {
      'id' => "chart-#{tile['id']}",
      'kind' => kind,
      'name' => tile['name'],
      'source' => { 'kind' => 'table', 'elementId' => 'data-orders' },
      'columns' => cols
    }
  end

  data_el = {
    'id' => 'data-orders',
    'kind' => 'table',
    'name' => 'Orders Data',
    'source' => {
      'kind' => 'data-model',
      'dataModelId' => opts[:dm_id],
      'elementId' => opts[:dm_element_id]
    },
    'columns' => data_columns.values
  }

  # Dashboard filters. Omni requires every control id on every tile; a `false`
  # entry means "do not filter this tile". Shared-source controls cannot
  # express that exclusion, so any false entry suppresses control emission.
  exclusions = []
  board['tileFilterMap'].each do |tile_id, binding|
    next unless binding.is_a?(Hash)
    binding.each do |fid, target|
      exclusions << { 'tile' => tile_id.to_s, 'filter' => fid.to_s } if target == false
    end
  end
  controls = []
  if exclusions.empty? && !board['filters'].empty?
    board['filters'].each do |flt|
      parts = field_parts(flt['field'])
      col_key = parts ? "fld-#{parts['view']}-#{parts['field']}-raw" : nil
      unless col_key && data_columns[col_key]
        # Date controls often target the raw field while tiles use a frame.
        raw_name = parts ? (displays[[parts['view'], parts['field']]] || OmniFormula.display_name(parts['field'])) : nil
        if parts && raw_name
          data_columns[col_key] = {
            'id' => col_key,
            'name' => raw_name,
            'formula' => "[#{opts[:dm_element_name]}/#{raw_name}]"
          }
          data_el['columns'] = data_columns.values
        end
      end
      unless col_key && data_columns[col_key]
        warnings << "filter #{flt['id']} skipped — field #{flt['field']} is not on the data element"
        next
      end
      controls << {
        'id' => "ctl-#{flt['id']}",
        'kind' => 'control',
        'controlId' => "ctl-#{flt['id']}",
        'name' => flt['label'],
        'controlType' => flt['type'] == 'date' ? 'date-range' : 'list',
        'filters' => [{
          'source' => { 'kind' => 'table', 'elementId' => 'data-orders' },
          'columnId' => col_key
        }],
        'source' => {
          'kind' => 'source',
          'source' => { 'kind' => 'table', 'elementId' => 'data-orders' },
          'columnId' => col_key
        },
        'values' => []
      }
    end
  elsif !exclusions.empty?
    warnings << 'tileFilterMap excludes at least one tile — controls not emitted (shared source cannot express per-tile exclusion)'
  end

  scale = OmniExport.column_scale(board['layout'])
  by_id = {}
  board['layout'].each { |item| by_id[item['i'].to_s] = item }
  control_rows = controls.each_with_index.map do |ctl, i|
    { 'id' => ctl['id'], 'c0' => 1, 'c1' => GRID + 1, 'r0' => 1 + (i * 2), 'r1' => 3 + (i * 2) }
  end
  y_shift = controls.empty? ? 0 : (controls.length * 2)
  chart_rows = []
  chart_elements.each do |el|
    tile_id = el['id'].sub(/\Achart-/, '')
    item = by_id[tile_id] || { 'x' => 0, 'y' => chart_rows.length * 8, 'w' => 12, 'h' => 8 }
    c0, c1 = OmniExport.grid_span(item, scale)
    height = [item['h'].to_i * (scale == 2 ? 1 : 1), LayoutLint.min_rows_for(el['kind'])].max
    # h on a 12-col board is already in row units; don't double it.
    r0 = item['y'].to_i + 1 + y_shift
    r1 = r0 + height
    chart_rows << { 'id' => el['id'], 'c0' => c0, 'c1' => c1, 'r0' => r0, 'r1' => r1 }
  end
  data_height = [LayoutLint.min_rows_for('table'), 10].max
  data_rows = [{ 'id' => 'data-orders', 'c0' => 1, 'c1' => GRID + 1, 'r0' => 1, 'r1' => 1 + data_height }]

  pages = [
    { 'id' => 'page-data', 'name' => 'Data', 'hidden' => true },
    { 'id' => 'page-dashboard', 'name' => board['name'] }
  ]
  spec = {
    'name' => board['name'],
    'schemaVersion' => 1,
    'kind' => 'workbook',
    'pages' => [
      pages[0].merge('elements' => [data_el]),
      pages[1].merge('elements' => controls + chart_elements)
    ]
  }
  spec['folderId'] = opts[:folder_id] if opts[:folder_id]
  # LAST write: layout after every element id is final.
  spec['layout'] = %(<?xml version="1.0" encoding="utf-8"?>\n) +
                   layout_xml('page-data', data_rows) + "\n" +
                   layout_xml('page-dashboard', control_rows + chart_rows)

  violations = LayoutLint.lint(spec) + ControlLint.lint(spec)
  unless violations.empty?
    warn "lint violations:\n#{violations.join("\n")}"
    exit 9
  end

  metadata = {}
  metadata['name'] = spec['name']
  metadata['folderId'] = spec['folderId'] if spec['folderId']
  document = spec.reject { |k, _| metadata.key?(k) }
  wrapped = Sigma::CodeRep.wrap(document, extra: metadata)
  envelope = {
    'workbook' => wrapped,
    'stats' => {
      'tiles' => chart_elements.length,
      'controls' => controls.length,
      'gaps' => gaps.length
    },
    'warnings' => warnings
  }
  File.write(opts[:out], JSON.pretty_generate(envelope) + "\n")
  out_dir = File.dirname(opts[:out])
  File.write(File.join(out_dir, 'chart-gaps.json'), JSON.pretty_generate(gaps) + "\n")
  File.write(File.join(out_dir, 'filter-gaps.json'), JSON.pretty_generate(exclusions) + "\n")
  parity = chart_elements.map do |el|
    tile = board['tiles'].find { |t| "chart-#{t['id']}" == el['id'] }
    {
      'chart_element_id' => el['id'],
      'chart_name' => el['name'],
      'query' => tile && tile['query']
    }
  end
  File.write(File.join(out_dir, 'parity-plan.json'), JSON.pretty_generate(parity) + "\n")
  warn "wrote #{opts[:out]} (#{chart_elements.length} charts, #{controls.length} controls, #{gaps.length} gaps)"
end
