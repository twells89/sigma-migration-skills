# frozen_string_literal: true
# Normalize an Omni dashboard blob into tiles + layout + filters.
#
# Accepts:
#   * GET /unstable/documents/{id}/export (exportVersion 0.1) when tiles are
#     present as queryPresentations on dashboard, workbook, or top-level
#   * the v2 documents envelope (queryPresentations: {data, order})
#   * the skill fixture shape (dashboard.queryPresentations array + metadata.layouts)
#
# Layout items use react-grid-layout keys i/x/y/w/h. A 12-column board is
# scaled to Sigma's 24-column grid; a board that already spans 24 is kept.

require 'json'

module OmniExport
  module_function

  def load(path)
    normalize(JSON.parse(File.read(path)))
  end

  def normalize(doc)
    doc = {} unless doc.is_a?(Hash)
    tiles = extract_tiles(doc)
    layout = extract_layout(doc)
    filters = extract_filters(doc)
    tile_map = extract_tile_filter_map(doc)
    name = doc.dig('document', 'name') || doc.dig('dashboard', 'name') || doc['name'] || 'Omni dashboard'
    ident = doc.dig('document', 'identifier') || doc.dig('dashboard', 'identifier') || doc['identifier']
    {
      'name' => name,
      'identifier' => ident,
      'exportVersion' => doc['exportVersion'],
      'tiles' => tiles,
      'layout' => layout,
      'filters' => filters,
      'tileFilterMap' => tile_map,
      'workbookModel' => doc['workbookModel'] || {}
    }
  end

  def extract_tiles(doc)
    blobs = []
    dash = doc['dashboard'].is_a?(Hash) ? doc['dashboard'] : {}
    wb = doc['workbook'].is_a?(Hash) ? doc['workbook'] : {}
    [dash['queryPresentations'], dash.dig('metadata', 'queryPresentations'),
     wb['queryPresentations'], doc['queryPresentations']].each do |node|
      blobs.concat(presentation_list(node))
    end
    blobs.uniq { |t| t['id'] }
  end

  def presentation_list(node)
    return [] if node.nil?
    rows = if node.is_a?(Array)
             node
           elsif node.is_a?(Hash) && node['data'].is_a?(Hash)
             order = node['order'].is_a?(Array) ? node['order'].map(&:to_s) : node['data'].keys
             order.map { |k| node['data'][k] || node['data'][k.to_s] }.compact
           else
             []
           end
    rows.each_with_index.map { |row, i| tile_from(row, i) }.compact
  end

  def tile_from(row, index)
    return nil unless row.is_a?(Hash)
    query = row['query'].is_a?(Hash) ? row['query'] : {}
    vis = row['visConfig'].is_a?(Hash) ? row['visConfig'] : {}
    chart = vis['chartType'] || row['chartType']
    id = (row['id'] || row['key'] || (index + 1)).to_s
    {
      'id' => id,
      'name' => row['name'] || query['name'] || "Tile #{id}",
      'chartType' => chart,
      'visType' => vis['visType'],
      'fields' => Array(query['fields']).map(&:to_s),
      'query' => query,
      'topic' => query['join_paths_from_topic_name']
    }
  end

  def extract_layout(doc)
    dash = doc['dashboard'].is_a?(Hash) ? doc['dashboard'] : {}
    lg = dash.dig('metadata', 'layouts', 'lg') || dash.dig('layouts', 'lg') || []
    Array(lg).select { |item| item.is_a?(Hash) && item['i'] }
  end

  def extract_filters(doc)
    raw = doc['filterConfig'] || doc.dig('dashboard', 'filterConfig') || {}
    return [] unless raw.is_a?(Hash)
    raw.map do |fid, cfg|
      cfg = {} unless cfg.is_a?(Hash)
      {
        'id' => fid.to_s,
        'type' => (cfg['type'] || 'text').to_s,
        'label' => cfg['label'] || fid.to_s,
        'field' => (cfg['field'] || cfg['fieldName']).to_s
      }
    end
  end

  def extract_tile_filter_map(doc)
    dash = doc['dashboard'].is_a?(Hash) ? doc['dashboard'] : {}
    map = dash.dig('metadata', 'tileFilterMap') || doc['tileFilterMap'] || {}
    map.is_a?(Hash) ? map : {}
  end

  # Return [col_start, col_end) on a 24-col grid, 1-indexed exclusive end.
  def grid_span(item, scale)
    x = item['x'].to_i * scale
    w = item['w'].to_i * scale
    w = 24 if w <= 0
    start_col = x + 1
    end_col = start_col + w
    end_col = 25 if end_col > 25
    [start_col, end_col]
  end

  def column_scale(layout)
    return 1 if layout.empty?
    max_edge = layout.map { |item| item['x'].to_i + item['w'].to_i }.max
    max_edge <= 12 ? 2 : 1
  end
end
