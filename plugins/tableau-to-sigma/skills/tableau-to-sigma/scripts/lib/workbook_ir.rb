# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'

# Canonical, deterministic intermediate representation for the Tableau workbook
# layer. Existing parser/build artifacts remain independently inspectable, while
# this document gives every downstream compiler stage one stable entry point.
module WorkbookIR
  SCHEMA_VERSION = 1
  ARTIFACT_CANDIDATES = {
    'twb' => %w[workbook-content.twb],
    'layout' => %w[dashboard-layout.json],
    'meta' => %w[dashboard-layout-meta.json],
    'master_map' => %w[master-columns.json master-columns.yaml],
    'grain_plan' => %w[object-grain-plan.json],
    'chart_specs' => %w[chart-specs.json],
    'compile_plan' => %w[workbook-compile-plan.json],
    'chart_provenance' => %w[chart-provenance.json],
    'control_scope' => %w[control-scope.json],
    'coverage' => %w[coverage.json],
    'workbook_spec' => %w[wb-spec.json workbook.json],
    'workbook_ids' => %w[wb-ids.json],
    'layout_xml' => %w[layout.xml],
    'layout_elements' => %w[layout.xml.elements.json],
    'layout_census' => %w[layout-census.json],
    'layout_arrangement' => %w[layout-arrangement.json]
  }.freeze

  module_function

  def build(workdir, overrides: {})
    root = Pathname(workdir).expand_path
    artifacts = discover_artifacts(root).merge(stringify(overrides)).select do |_key, value|
      value && !value.to_s.empty?
    end
    artifacts = artifacts.transform_values { |value| artifact_reference(root, value) }
    artifacts = artifacts.sort.to_h
    layout = read_json(root, artifacts['layout'], [])
    meta = read_json(root, artifacts['meta'], {})
    provenance = read_json(root, artifacts['chart_provenance'], {})
    coverage = read_json(root, artifacts['coverage'], {})

    pages = Array(layout).each_with_index.map do |dashboard, index|
      zones = Array(dashboard['zones']).map { |zone| canonical_zone(zone) }
      {
        'name' => dashboard['dashboard'],
        'layout_index' => index,
        'emit_page' => dashboard.key?('emit_page') ? dashboard['emit_page'] : true,
        'is_story' => !!dashboard['is_story'],
        'canvas_px' => dashboard['canvas_px'],
        'zones' => zones,
        'zone_tree' => dashboard['zone_tree'],
        'style_rules' => dashboard['style_rules'],
        'brand_palette' => dashboard['brand_palette']
      }.compact
    end

    worksheets = (meta['worksheets'].is_a?(Hash) ? meta['worksheets'] : {}).sort.to_h
    bindings = build_bindings(pages, provenance)
    twb_path = artifacts['twb'] && resolve(root, artifacts['twb'])

    {
      'schemaVersion' => SCHEMA_VERSION,
      'kind' => 'tableau-workbook-ir',
      'source' => {
        'type' => 'tableau',
        'twb' => artifacts['twb'],
        'sha256' => twb_path&.file? ? Digest::SHA256.file(twb_path).hexdigest : nil
      }.compact,
      'artifacts' => artifacts,
      'workbook' => {
        'pages' => pages,
        'worksheets' => worksheets,
        'parameters' => Array(meta['parameters']),
        'shared_filters' => Array(meta['shared_filters']),
        'datasource_filters' => Array(meta['datasource_filters']),
        'column_aliases' => meta['column_aliases'] || {},
        'column_formats' => meta['column_formats'] || {},
        'stories' => Array(meta['stories'])
      },
      'bindings' => bindings,
      'unsupported' => Array(coverage['unresolved']),
      'phases' => infer_phases(artifacts)
    }
  end

  def emit(workdir, out: nil, overrides: {})
    root = Pathname(workdir).expand_path
    destination = out ? Pathname(out).expand_path : root.join('workbook-ir.json')
    document = build(root, overrides: overrides)
    errors = validate(document, root: root)
    raise ArgumentError, errors.join('; ') unless errors.empty?

    atomic_json(destination, document)
    document
  end

  def load(path)
    document = JSON.parse(File.read(path, encoding: 'UTF-8'))
    errors = validate(document, root: Pathname(path).expand_path.dirname)
    raise ArgumentError, errors.join('; ') unless errors.empty?

    document
  end

  def artifact_path(ir_path, key, required: false)
    document = load(ir_path)
    relative = document.dig('artifacts', key.to_s)
    if relative.nil? || relative.to_s.empty?
      raise ArgumentError, "workbook IR has no artifact #{key.inspect}" if required
      return nil
    end

    resolve(Pathname(ir_path).expand_path.dirname, relative).to_s
  end

  def validate(document, root: nil)
    errors = []
    errors << 'schemaVersion must be 1' unless document['schemaVersion'] == SCHEMA_VERSION
    errors << 'kind must be tableau-workbook-ir' unless document['kind'] == 'tableau-workbook-ir'
    errors << 'artifacts must be an object' unless document['artifacts'].is_a?(Hash)
    errors << 'workbook.pages must be an array' unless document.dig('workbook', 'pages').is_a?(Array)
    errors << 'workbook.worksheets must be an object' unless document.dig('workbook', 'worksheets').is_a?(Hash)
    errors << 'bindings must be an array' unless document['bindings'].is_a?(Array)
    errors << 'unsupported must be an array' unless document['unsupported'].is_a?(Array)

    page_names = Array(document.dig('workbook', 'pages')).filter_map { |page| page['name'] }
    Array(document['bindings']).each_with_index do |binding, index|
      errors << "bindings[#{index}].element_id is required" if binding['element_id'].to_s.empty?
      if binding['dashboard'] && !page_names.include?(binding['dashboard'])
        errors << "bindings[#{index}] references unknown dashboard #{binding['dashboard'].inspect}"
      end
    end

    if root
      %w[layout meta].each do |key|
        relative = document.dig('artifacts', key)
        next unless relative
        errors << "artifact #{key} does not exist: #{relative}" unless resolve(root, relative).file?
      end
    end
    errors
  end

  def discover_artifacts(root)
    ARTIFACT_CANDIDATES.each_with_object({}) do |(key, candidates), output|
      match = candidates.find { |name| root.join(name).file? }
      output[key] = match if match
    end
  end

  def canonical_zone(zone)
    {
      'id' => zone['id'],
      'kind' => zone['kind'],
      'caption' => zone['caption'],
      'worksheet' => zone['worksheet'] || zone['caption'],
      'chart_kind' => zone['chart_kind'],
      'mark_class' => zone['mark_class'],
      'geometry' => {
        'x_pct' => zone['x_pct'],
        'y_pct' => zone['y_pct'],
        'w_pct' => zone['w_pct'],
        'h_pct' => zone['h_pct']
      }.compact,
      'rows_shelf' => zone['rows_shelf'],
      'cols_shelf' => zone['cols_shelf'],
      'channels' => zone['channels'],
      'dimensions' => zone['dimensions'],
      'measures' => zone['measures'],
      'filters' => zone['filters'],
      'calculations' => zone['calculations'],
      'filter_column_caption' => zone['filter_column_caption'],
      'filter_column_datatype' => zone['filter_column_datatype'],
      'control_display' => zone['control_display'],
      'dual_axis' => zone['dual_axis'],
      'synchronized_axis' => zone['synchronized_axis'],
      'reference_lines' => zone['reference_lines'],
      'trend_lines' => zone['trend_lines'],
      'is_crosstab' => zone['is_crosstab'],
      'is_kpi' => zone['is_kpi'],
      'style' => zone['zone_style_fields'] || zone['style'],
      'button_intent' => zone['button_intent'],
      'button_nav_target' => zone['button_nav_target']
    }.compact
  end

  def build_bindings(pages, provenance)
    records = provenance.is_a?(Hash) && provenance['elements'].is_a?(Hash) ? provenance['elements'] : provenance
    return [] unless records.is_a?(Hash)

    zones = pages.flat_map do |page|
      Array(page['zones']).map { |zone| [page['name'], zone] }
    end
    records.sort_by { |element_id, _| element_id.to_s }.map do |element_id, record|
      worksheet = record.is_a?(Hash) ? (record['worksheet'] || record['source_worksheet']) : nil
      dashboard = record.is_a?(Hash) ? record['dashboard'] : nil
      zone_match = zones.find do |page_name, zone|
        next false if dashboard && page_name != dashboard
        [zone['worksheet'], zone['caption']].compact.any? { |name| name.to_s == worksheet.to_s }
      end
      {
        'dashboard' => dashboard || zone_match&.first,
        'zone_id' => zone_match&.last&.dig('id'),
        'worksheet' => worksheet,
        'element_id' => element_id,
        'source' => 'chart-provenance.json'
      }.compact
    end
  end

  def infer_phases(artifacts)
    {
      'parse' => artifacts.key?('layout'),
      'charts' => artifacts.key?('chart_specs'),
      'assemble' => artifacts.key?('workbook_spec'),
      'layout' => artifacts.key?('layout_xml')
    }
  end

  def read_json(root, relative, fallback)
    return fallback unless relative
    path = resolve(root, relative)
    return fallback unless path.file?
    JSON.parse(path.read(encoding: 'UTF-8'))
  rescue JSON::ParserError
    fallback
  end

  def resolve(root, value)
    path = Pathname(value)
    path.absolute? ? path : Pathname(root).join(path).cleanpath
  end

  def stringify(hash)
    hash.each_with_object({}) { |(key, value), output| output[key.to_s] = value }
  end

  def artifact_reference(root, value)
    path = Pathname(value)
    return value.to_s unless path.absolute?

    path.relative_path_from(Pathname(root)).to_s
  rescue ArgumentError
    value.to_s
  end

  def atomic_json(path, value)
    path = Pathname(path)
    path.dirname.mkpath
    temporary = Pathname("#{path}.tmp-#{Process.pid}")
    temporary.write("#{JSON.pretty_generate(value)}\n")
    temporary.rename(path)
  ensure
    temporary&.delete if temporary&.exist?
  end
end
