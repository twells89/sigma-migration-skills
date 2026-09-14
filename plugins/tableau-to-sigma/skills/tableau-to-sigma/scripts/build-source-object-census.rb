#!/usr/bin/env ruby
# frozen_string_literal: true

# Build a deterministic Tableau source-object inventory and account every
# object from evidence already present in a migration workdir.

require 'json'
require 'optparse'
require 'pathname'
require 'set'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'twb_xml'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'lib/ruby_compat'

class CensusError < StandardError; end

class SourceObjectCensus
  TERMINAL = %w[migrated approximated needs-review skipped not-applicable].freeze
  NEGATIVE_PRIORITY = {
    'skipped' => 30,
    'needs-review' => 20,
    'approximated' => 10
  }.freeze
  FURNITURE_KINDS = %w[
    container spacer title text image legend color size shape filter
    highlighter empty layoutbasic layoutflow
  ].freeze

  attr_reader :document

  def initialize(workdir, paths)
    @workdir = File.expand_path(workdir)
    @paths = paths
    @docs = {}
    @objects = []
    @object_keys = Set.new
    @layout_dashboards = Set.new
    @worksheet_dashboards = Hash.new { |h, k| h[k] = Set.new }
    @built_pages = Set.new
    @built_elements = Set.new
    @built_columns = Set.new
    @built_controls = Set.new
    @parity_pass = Set.new
    @parity_fail = Set.new
    @parity_green = false
    @explicit_scope_dashboards = Set.new
    load_inputs
  end

  def build
    parse_built_spec
    parse_parity
    inventory_twb
    inventory_layout
    inventory_stories
    inventory_calculations
    inventory_blends
    account_objects

    @objects.sort_by! { |object| [object['type'], object['id'], object['name']] }
    counts = TERMINAL.to_h { |status| [status, @objects.count { |object| object['status'] == status }] }
    @document = {
      'schema_version' => 1,
      'source' => 'tableau',
      'summary' => {
        'total' => @objects.length,
        'accounted' => @objects.length,
        'complete' => @objects.all? do |object|
          TERMINAL.include?(object['status']) && object['evidence'].is_a?(Array) && !object['evidence'].empty?
        end,
        'counts' => counts
      },
      'objects' => @objects.map { |object| public_object(object) },
      'inputs' => input_manifest
    }
  end

  private

  def load_inputs
    @paths.each do |kind, value|
      Array(value).compact.each do |path|
        next unless File.file?(path)
        @docs[[kind, path]] = read_json(path) unless kind == :twb
      end
    end
    twb = first_path(:twb)
    raise CensusError, 'no Tableau TWB found (pass --twb or place a .twb in --workdir)' unless twb
    @twb_path = twb
    xml = File.read(twb, encoding: 'bom|utf-8')
    @twb_doc = TwbXml.parse(xml)
    scope_path = File.join(@workdir, 'dashboard-scope.json')
    if File.file?(scope_path)
      scope = read_json(scope_path)
      if scope['mode'] == 'selected' && %w[stated cli].include?(scope['provenance'].to_s)
        Array(scope['dashboards']).each { |name| add_folded(@explicit_scope_dashboards, name) }
      end
    end
  rescue TwbXml::ParseError => e
    raise CensusError, "#{display_path(twb)}: #{e.message}"
  rescue Errno::ENOENT, Errno::EACCES => e
    raise CensusError, e.message
  end

  def read_json(path)
    JSON.parse(File.read(path, encoding: 'bom|utf-8'))
  rescue JSON::ParserError => e
    raise CensusError, "malformed JSON #{display_path(path)}: #{e.message}"
  rescue Errno::ENOENT, Errno::EACCES => e
    raise CensusError, e.message
  end

  def first_path(kind)
    Array(@paths[kind]).find { |path| File.file?(path) }
  end

  def docs(kind)
    @docs.select { |(key, _), _| key == kind }.sort_by { |(_, path), _| path }
  end

  def parse_built_spec
    candidates = docs(:wb_readback) + docs(:wb_spec)
    return if candidates.empty?

    (key, doc) = candidates.first
    kind, path = key
    root = document_root(doc)
    @built_artifact = display_path(path)
    @built_kind = kind
    Array(root['pages']).each do |page|
      next unless page.is_a?(Hash)
      add_folded(@built_pages, page['name'])
      collect_built_nodes(page)
    end
    Array(root['elements']).each { |element| collect_built_nodes(element) }
  end

  def document_root(doc)
    return {} unless doc.is_a?(Hash)
    root = doc['document']
    root.is_a?(Hash) ? root : doc
  end

  def collect_built_nodes(value)
    case value
    when Array
      value.each { |item| collect_built_nodes(item) }
    when Hash
      add_folded(@built_elements, value['name']) if value['kind'] || value['type'] || value['id']
      if value['kind'].to_s == 'control' || value.key?('controlId') || value.key?('controlType')
        add_folded(@built_controls, value['name'])
        add_folded(@built_controls, value['controlId'])
      end
      Array(value['columns']).each do |column|
        next unless column.is_a?(Hash)
        add_folded(@built_columns, column['name'])
      end
      value.each_value { |item| collect_built_nodes(item) if item.is_a?(Hash) || item.is_a?(Array) }
    end
  end

  def parse_parity
    pair = docs(:parity).first
    return unless pair
    (_, doc) = pair
    @parity_artifact = display_path(pair[0][1])
    return unless doc.is_a?(Hash)
    @parity_green = %w[pass passed green].include?(fold(doc['status'] || doc['verdict']))
    Array(doc['pass_names']).each { |name| add_folded(@parity_pass, name) }
    Array(doc['fail_names']).each { |name| add_folded(@parity_fail, name) }
  end

  def inventory_twb
    @twb_doc.elements.each('/workbook/dashboards/dashboard') do |dashboard|
      name = attr(dashboard, 'name')
      next if blank?(name)
      add_object('dashboard', stable_id('dashboard', name), name,
                 discovery_evidence("TWB dashboard #{name.inspect}"),
                 'dashboard_name' => name)
      dashboard.elements.each('.//zone') do |zone|
        zid = attr(zone, 'id')
        zone_name = attr(zone, 'name') || attr(zone, 'caption') || attr(zone, 'param') ||
                    attr(zone, 'type-v2') || "zone #{zid || '?'}"
        type = attr(zone, 'type-v2')
        add_object('dashboard-zone',
                   stable_id('dashboard-zone', name, zid || zone_name),
                   zone_name,
                   discovery_evidence("TWB dashboard zone #{name.inspect}/#{zid || zone_name}"),
                   'dashboard_name' => name, 'zone_id' => zid, 'zone_kind' => type,
                   'worksheet_name' => attr(zone, 'name'))
        @worksheet_dashboards[fold(attr(zone, 'name'))] << fold(name) unless blank?(attr(zone, 'name'))
      end
    end

    @twb_doc.elements.each('/workbook/worksheets/worksheet') do |worksheet|
      name = attr(worksheet, 'name')
      next if blank?(name)
      add_object('worksheet', stable_id('worksheet', name), name,
                 discovery_evidence("TWB worksheet #{name.inspect}"),
                 'worksheet_name' => name)
    end

    inventory_parameters
    inventory_sets
  end

  def inventory_parameters
    @twb_doc.elements.each('/workbook/datasources/datasource') do |datasource|
      ds_name = attr(datasource, 'caption') || attr(datasource, 'name')
      parameter_ds = ds_name.to_s.downcase.start_with?('parameter')
      datasource.elements.each('column') do |column|
        next unless parameter_ds || !blank?(attr(column, 'param-domain-type'))
        raw = attr(column, 'name')
        name = attr(column, 'caption') || unbracket(raw)
        next if blank?(name)
        add_object('parameter', stable_id('parameter', raw || name), name,
                   discovery_evidence("TWB parameter #{raw || name}"),
                   'raw_name' => raw)
      end
    end
  end

  def inventory_sets
    @twb_doc.elements.each('/workbook/datasources/datasource') do |datasource|
      ds_name = attr(datasource, 'caption') || attr(datasource, 'name') || 'datasource'
      datasource.elements.each('.//set') do |set_node|
        add_set(ds_name, set_node)
      end
      datasource.elements.each('group') do |group|
        is_set = group.elements.to_a('.//groupfilter').any? { |node| attr(node, 'function') == 'set' }
        add_set(ds_name, group) if is_set
      end
    end
  end

  def add_set(datasource, node)
    raw = attr(node, 'name')
    name = attr(node, 'caption') || unbracket(raw)
    return if blank?(name)
    add_object('set', stable_id('set', datasource, raw || name), name,
               discovery_evidence("TWB set #{raw || name} in #{datasource}"),
               'raw_name' => raw, 'datasource' => datasource)
  end

  def inventory_layout
    docs(:layout).each do |(_, layout)|
      rows = layout.is_a?(Array) ? layout : Array(layout.is_a?(Hash) ? layout['dashboards'] : nil)
      rows.each do |dashboard|
        next unless dashboard.is_a?(Hash)
        dashboard_name = dashboard['dashboard'] || dashboard['name']
        next if blank?(dashboard_name)
        @layout_dashboards << fold(dashboard_name)
        ensure_dashboard_from_layout(dashboard_name)
        Array(dashboard['zones']).each_with_index do |zone, index|
          next unless zone.is_a?(Hash)
          zone_name = zone['caption'] || zone['name'] || zone['kind'] || "zone #{zone['id'] || index}"
          object = find_object('dashboard-zone',
                               stable_id('dashboard-zone', dashboard_name, zone['id'] || zone_name))
          object ||= add_object('dashboard-zone',
                                stable_id('dashboard-zone', dashboard_name, zone['id'] || zone_name),
                                zone_name,
                                discovery_evidence("dashboard-layout zone #{dashboard_name.inspect}/#{zone['id'] || index}"),
                                'dashboard_name' => dashboard_name, 'zone_id' => zone['id'])
          object['zone_kind'] = zone['kind'] unless blank?(zone['kind'])
          object['worksheet_name'] = zone['caption'] if zone['kind'].to_s == 'chart'
          if zone['kind'].to_s == 'chart' && !blank?(zone['caption'])
            @worksheet_dashboards[fold(zone['caption'])] << fold(dashboard_name)
          end
        end
      end
    end
  end

  def ensure_dashboard_from_layout(name)
    return if @objects.any? { |object| object['type'] == 'dashboard' && fold(object['name']) == fold(name) }
    add_object('dashboard', stable_id('dashboard', name), name,
               discovery_evidence("dashboard-layout source dashboard #{name.inspect}"),
               'dashboard_name' => name)
  end

  def inventory_stories
    path = File.join(@workdir, 'story-plan.json')
    return unless File.file?(path)
    Array(read_json(path)).each do |story|
      next unless story.is_a?(Hash)
      Array(story['points']).each do |point|
        next unless point.is_a?(Hash) && !point['caption'].to_s.empty?
        add_object(
          'story-point',
          stable_id('story-point', story['story'], point['id'] || point['caption']),
          point['caption'],
          evidence(path, "Tableau story point #{story['story'].inspect}/#{point['caption'].inspect}"),
          'story_name' => story['story'],
          'captured_sheet' => point['captured_sheet']
        )
      end
    end
  end

  def inventory_calculations
    records = docs(:calcs).flat_map do |(_, doc)|
      doc.is_a?(Hash) ? Array(doc['calcs'] || doc['calculations']) : Array(doc)
    end.select { |record| record.is_a?(Hash) }

    # The TWB remains the source inventory. calc-fields.json enriches those
    # records and may add Metadata-API calculations not represented as top-level
    # datasource columns in unusual workbook shapes.
    @twb_doc.elements.each('/workbook/datasources/datasource') do |datasource|
      ds_name = attr(datasource, 'caption') || attr(datasource, 'name') || 'datasource'
      next if ds_name.downcase.start_with?('parameter')
      datasource.elements.each('column') do |column|
        calculation = column.elements['calculation']
        next unless calculation && attr(calculation, 'class').to_s == 'tableau'
        raw = attr(column, 'name')
        name = attr(column, 'caption') || unbracket(raw)
        next if blank?(name)
        enriched = records.find do |record|
          fold(record['internal_name']) == fold(raw) ||
            (fold(record['name']) == fold(name) && fold(record['datasource']) == fold(ds_name))
        end || {}
        add_calculation(enriched.merge('name' => name, 'internal_name' => raw,
                                       'datasource' => ds_name,
                                       'formula' => attr(calculation, 'formula') || enriched['formula']))
      end
    end
    records.each { |record| add_calculation(record) }
  end

  def add_calculation(record)
    name = record['name'] || record['caption'] || record['internal_name']
    return if blank?(name)
    datasource = record['datasource'] || 'datasource'
    raw = record['internal_name'] || name
    object = add_object('calculation', stable_id('calculation', datasource, raw), name,
                        evidence(first_path(:calcs) || @twb_path, "source calculation #{name.inspect}"),
                        'raw_name' => raw, 'datasource' => datasource)
    object['requires_custom_sql'] ||= record['requires_custom_sql'] == true
    object['formula'] ||= record['formula']
  end

  def inventory_blends
    docs(:blend).each do |(key, doc)|
      path = key[1]
      Array(doc.is_a?(Hash) ? doc['blends'] : doc).each do |blend|
        next unless blend.is_a?(Hash)
        worksheet = blend['worksheet'] || blend['name'] || 'blend'
        primary = blend['primary'] || blend['primary_caption'] || 'primary'
        secondary = blend['secondary'] || blend['secondary_caption'] || 'secondary'
        name = blend['name'] || "#{worksheet}: #{primary} + #{secondary}"
        add_object('blend', stable_id('blend', worksheet, primary, secondary), name,
                   evidence(path, "source blend on worksheet #{worksheet.inspect}"),
                   'worksheet_name' => worksheet, 'route' => blend['route'],
                   'record' => blend)
      end
    end
  end

  def account_objects
    @objects.each do |object|
      if not_applicable?(object)
        object['status'] = 'not-applicable'
        object['evidence'] << decision_evidence(not_applicable_reason(object))
        next
      end

      signals = audit_signals(object)
      signals.each { |signal| object['evidence'] << signal.reject { |key, _| key == 'status' } }
      not_applicable = signals.find { |signal| signal['status'] == 'not-applicable' }
      if not_applicable
        object['status'] = 'not-applicable'
        next
      end
      strongest = signals.max_by { |signal| NEGATIVE_PRIORITY.fetch(signal['status'], 0) }
      if strongest && NEGATIVE_PRIORITY.fetch(strongest['status'], 0).positive?
        object['status'] = strongest['status']
        next
      end

      built = built?(object)
      verified = parity_verified?(object)
      if object['type'] == 'set' && built
        object['status'] = 'approximated'
        object['evidence'] << decision_evidence('set has a built calculated/control representation; Tableau sets have no direct Sigma object')
      elsif built && verified
        object['status'] = 'migrated'
        object['evidence'] << built_evidence(object)
        object['evidence'] << parity_evidence(object)
      else
        object['status'] = 'needs-review'
        detail = if !built
                   'no matching built workbook page, element, control, or column was found'
                 else
                   'matching built object exists, but final parity does not prove this source object'
                 end
        object['evidence'] << decision_evidence(detail)
        object['evidence'] << built_evidence(object) if built
      end
      object['evidence'] = unique_sorted_evidence(object['evidence'])
    end
  end

  def not_applicable?(object)
    dashboard = fold(object['dashboard_name'])
    case object['type']
    when 'dashboard'
      !@explicit_scope_dashboards.empty? &&
        !@explicit_scope_dashboards.include?(fold(object['name']))
    when 'dashboard-zone'
      return true if !@explicit_scope_dashboards.empty? &&
                     !@explicit_scope_dashboards.include?(dashboard)
      furniture?(object)
    when 'worksheet'
      refs = @worksheet_dashboards[fold(object['name'])]
      refs.empty? || (!@explicit_scope_dashboards.empty? &&
                      (refs & @explicit_scope_dashboards).empty?)
    when 'story-point'
      !@explicit_scope_dashboards.empty? &&
        !@explicit_scope_dashboards.include?(fold(object['story_name']))
    else
      false
    end
  end

  def not_applicable_reason(object)
    case object['type']
    when 'worksheet'
      refs = @worksheet_dashboards[fold(object['name'])]
      refs.empty? ? 'worksheet is orphaned from every dashboard' :
                    'worksheet appears only on explicitly scoped-out dashboards'
    when 'dashboard-zone'
      furniture?(object) ? "non-data dashboard furniture (kind=#{object['zone_kind'] || 'unknown'})" :
                           'dashboard zone belongs to an out-of-scope dashboard'
    when 'story-point'
      'story point belongs to an explicitly scoped-out story'
    else
      'dashboard is outside the explicitly stated dashboard scope'
    end
  end

  def furniture?(object)
    kind = fold(object['zone_kind'])
    return true if FURNITURE_KINDS.include?(kind)
    return false if kind == 'chart'
    blank?(object['worksheet_name'])
  end

  def built?(object)
    names = candidate_names(object)
    case object['type']
    when 'dashboard'
      names.any? { |name| @built_pages.include?(fold(name)) }
    when 'story-point'
      names.any? { |name| @built_pages.include?(fold(name)) }
    when 'parameter'
      names.any? { |name| @built_controls.include?(fold(name)) }
    when 'calculation', 'set'
      names.any? { |name| @built_columns.include?(fold(name)) || @built_elements.include?(fold(name)) }
    when 'blend'
      names.any? { |name| @built_elements.include?(fold(name)) }
    else
      names.any? { |name| @built_elements.include?(fold(name)) }
    end
  end

  def candidate_names(object)
    [object['name'], object['worksheet_name'], object['raw_name'] && unbracket(object['raw_name'])]
      .compact.reject { |name| blank?(name) }.uniq
  end

  def parity_verified?(object)
    names = candidate_names(object).map { |name| fold(name) }
    return false if names.any? { |name| @parity_fail.include?(name) }
    return true if names.any? { |name| @parity_pass.include?(name) }
    @parity_green
  end

  def audit_signals(object)
    signals = []
    docs(:coverage).each do |(key, doc)|
      records_for(doc, %w[unresolved objects coverage detail items]).each do |record|
        next unless record_matches?(record, object)
        status = negative_status(record['terminal_status'] || record['status'] ||
                                 record['severity'] || record['outcome'])
        next unless status
        signals << evidence(key[1], record_detail(record), status)
      end
    end
    docs(:controls).each do |(key, doc)|
      records_for(doc, %w[detail controls objects records coverage unresolved]).each do |record|
        next unless record_matches?(record, object)
        status = negative_status(record['terminal_status'] || record['status'] ||
                                 record['severity'] || record['outcome'])
        if status
          signals << evidence(key[1], record_detail(record), status)
        elsif positive_status?(record['status'] || record['outcome'])
          object['evidence'] << evidence(key[1], record_detail(record))
        end
      end
    end
    formula_audit_docs.each do |path, doc|
      records_for(doc, %w[calculations formulas fields results records items unresolved]).each do |record|
        next unless record_matches?(record, object)
        status = negative_status(record['terminal_status'] || record['status'] ||
                                 record['severity'] || record['result'])
        if status
          signals << evidence(path, record_detail(record), status)
        elsif positive_status?(record['status'] || record['result'])
          object['evidence'] << evidence(path, record_detail(record))
        end
      end
      Array(doc['calculation_cycles']).each do |cycle|
        next unless object['type'] == 'calculation' && cycle.is_a?(Hash)
        next unless Array(cycle['calculations']).any? { |name| candidate_names(object).any? { |candidate| fold(candidate) == fold(name) } }
        signals << evidence(path, "calculation cycle: #{Array(cycle['calculations']).join(' ↔ ')}",
                            'needs-review')
      end
      Array(doc['orphan_internal_calculation_references']).each do |record|
        next unless object['type'] == 'calculation' && record_matches?(record, object)
        signals << evidence(path, record_detail(record), 'needs-review')
      end
      Array(doc['unused_calculations']).each do |record|
        next unless object['type'] == 'calculation' && record_matches?(record, object)
        signals << evidence(path, "unused source calculation #{record['calculation'] || record['name']}",
                            'not-applicable')
      end
    end
    docs(:gap).each do |(key, doc)|
      records_for(doc, %w[detected_features gaps features unresolved]).each do |record|
        next unless gap_matches?(record, object)
        status = negative_status(record['status'])
        signals << evidence(key[1], record_detail(record), status) if status
      end
    end
    if object['type'] == 'calculation' && object['requires_custom_sql'] && !built?(object)
      signals << decision_evidence('calculation requires Custom SQL and has no matching built column')
                 .merge('status' => 'needs-review')
    end
    if object['type'] == 'blend' && object['route'].to_s =~ /materialize|vds|manual|unsupported/i && !built?(object)
      signals << decision_evidence("blend route #{object['route'].inspect} is not evidenced in the built workbook")
                 .merge('status' => 'needs-review')
    end
    signals
  end

  def formula_audit_docs
    standalone = docs(:formula_audit).map { |key, doc| [key[1], doc] }
    embedded = docs(:gap).filter_map do |key, doc|
      audit = doc['formula_audit'] if doc.is_a?(Hash)
      audit.is_a?(Hash) ? [key[1], audit] : nil
    end
    standalone + embedded
  end

  def records_for(doc, keys)
    return doc.select { |item| item.is_a?(Hash) } if doc.is_a?(Array)
    return [] unless doc.is_a?(Hash)
    keys.flat_map do |key|
      value = doc[key]
      case value
      when Array then value.select { |item| item.is_a?(Hash) }
      when Hash
        value.map do |name, record|
          record.is_a?(Hash) ? record.merge('name' => record['name'] || name) : nil
        end.compact
      else []
      end
    end
  end

  def record_matches?(record, object)
    return false unless record.is_a?(Hash)
    names = candidate_names(object).map { |name| fold(name) }
    record_names = %w[name visual control calc calculation field worksheet sourceName source_name
                      source_signal object_name objectName internal_name id].filter_map { |key| record[key] }
    nested = record['source_object']
    record_names.concat(%w[name id].filter_map { |key| nested[key] }) if nested.is_a?(Hash)
    return true if record_names.any? { |name| names.include?(fold(unbracket(name))) }
    Array(record['worksheets']).any? { |name| names.include?(fold(name)) }
  end

  def gap_matches?(record, object)
    return true if record_matches?(record, object)
    feature = fold(record['name'])
    return true if object['type'] == 'set' && feature.include?('set')
    return true if object['type'] == 'parameter' && feature.include?('parameter') &&
                   Array(record['worksheets']).empty?
    false
  end

  def negative_status(value)
    word = fold(value).tr('_ ', '--').gsub(/-+/, '-')
    return 'skipped' if %w[dropped skipped omitted excluded not-emitted].include?(word)
    return 'approximated' if %w[approximated approximate substituted].include?(word)
    return 'needs-review' if %w[
      degraded needs-review review unresolved unhandled manual unsupported
      missing unbuilt fail failed failure error invalid pending not-converted unmapped
    ].include?(word)
    nil
  end

  def positive_status?(value)
    %w[pass passed green migrated built emitted resolved complete completed spec].include?(fold(value))
  end

  def record_detail(record)
    detail = record['detail'] || record['reason'] || record['message'] ||
             record['action'] || record['recommendation']
    label = record['name'] || record['visual'] || record['control'] || record['calc'] ||
            record['calculation']
    [label, detail].compact.map(&:to_s).reject(&:empty?).join(': ')
  end

  def built_evidence(object)
    source = @built_artifact || 'workdir'
    kind = @built_kind == :wb_readback ? 'workbook readback' : 'workbook spec'
    evidence(source, "matching #{kind} object for #{object['name'].inspect}")
  end

  def parity_evidence(object)
    evidence(@parity_artifact || 'parity-final.json',
             "parity proves #{candidate_names(object).join(' / ')}")
  end

  def discovery_evidence(detail)
    evidence(@twb_path, detail)
  end

  def decision_evidence(detail)
    { 'artifact' => 'source-object-census', 'detail' => detail }
  end

  def evidence(path, detail, status = nil)
    result = {
      'artifact' => path == 'source-object-census' ? path : display_path(path),
      'detail' => detail.to_s.empty? ? 'recorded' : detail.to_s
    }
    result['status'] = status if status
    result
  end

  def unique_sorted_evidence(rows)
    rows.map { |row| row.reject { |key, value| key == 'status' || value.nil? || value.to_s.empty? } }
        .uniq
        .sort_by { |row| [row['artifact'].to_s, row['detail'].to_s] }
  end

  def add_object(type, id, name, source_evidence, metadata = {})
    key = [type, id]
    existing = @objects.find { |object| [object['type'], object['id']] == key }
    if existing
      existing['evidence'] << source_evidence
      metadata.each { |meta_key, value| existing[meta_key] ||= value }
      return existing
    end
    # A malformed source with duplicate identities is safer to fail than to
    # silently collapse two source objects under one accounting row.
    raise CensusError, "duplicate source identity #{type}:#{id}" if @object_keys.include?(key)
    @object_keys << key
    object = {
      'type' => type,
      'id' => id,
      'name' => name.to_s,
      'evidence' => [source_evidence]
    }.merge(metadata)
    @objects << object
    object
  end

  def find_object(type, id)
    @objects.find { |object| object['type'] == type && object['id'] == id }
  end

  def public_object(object)
    {
      'type' => object['type'],
      'id' => object['id'],
      'name' => object['name'],
      'status' => object['status'],
      'evidence' => unique_sorted_evidence(object['evidence'])
    }
  end

  def stable_id(type, *parts)
    ([type] + parts.map { |part| part.to_s.strip.gsub(/\s+/, ' ') }).join(':')
  end

  def input_manifest
    @paths.keys.sort_by(&:to_s).flat_map do |kind|
      Array(@paths[kind]).compact.sort.map do |path|
        { 'kind' => kind.to_s.tr('_', '-'), 'path' => display_path(path), 'present' => File.file?(path) }
      end
    end
  end

  def display_path(path)
    return path if path == 'source-object-census'
    Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(@workdir)).to_s
  rescue ArgumentError
    File.expand_path(path)
  end

  def attr(node, name)
    value = node.attributes[name]
    blank?(value) ? nil : value.to_s
  end

  def unbracket(value)
    value.to_s.sub(/\A\[/, '').sub(/\]\z/, '')
  end

  def add_folded(set, value)
    set << fold(value) unless blank?(value)
  end

  def fold(value)
    value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, '')
  end

  def blank?(value)
    value.nil? || value.to_s.strip.empty?
  end
end

def discover_one(workdir, explicit, patterns)
  return File.expand_path(explicit, workdir) if explicit
  patterns.each do |pattern|
    path = Dir.glob(File.join(workdir, pattern)).select { |candidate| File.file?(candidate) }.sort.first
    return path if path
  end
  nil
end

def discover_many(workdir, explicit, patterns)
  return Array(explicit).map { |path| File.expand_path(path, workdir) }.uniq.sort unless Array(explicit).empty?
  patterns.flat_map { |pattern| Dir.glob(File.join(workdir, pattern)) }
          .select { |path| File.file?(path) }.uniq.sort
end

options = { controls: [] }
parser = OptionParser.new do |p|
  p.banner = 'Usage: build-source-object-census.rb --workdir DIR [artifact options]'
  p.on('--workdir DIR') { |value| options[:workdir] = value }
  p.on('--twb PATH') { |value| options[:twb] = value }
  p.on('--dashboard-layout PATH', '--layout PATH') { |value| options[:layout] = value }
  p.on('--dashboard-meta PATH', '--dashboard-layout-meta PATH', '--layout-meta PATH') { |value| options[:layout_meta] = value }
  p.on('--calc-fields PATH') { |value| options[:calcs] = value }
  p.on('--gap-audit PATH', '--gaps PATH') { |value| options[:gap] = value }
  p.on('--formula-audit PATH') { |value| options[:formula_audit] = value }
  p.on('--blend-plan PATH') { |value| options[:blend] = value }
  p.on('--coverage PATH') { |value| options[:coverage] = value }
  p.on('--controls-census PATH', '--control-census PATH') { |value| options[:controls] << value }
  p.on('--parity-final PATH', '--parity PATH') { |value| options[:parity] = value }
  p.on('--wb-spec PATH') { |value| options[:wb_spec] = value }
  p.on('--wb-readback PATH') { |value| options[:wb_readback] = value }
  p.on('--out PATH') { |value| options[:out] = value }
end

begin
  parser.parse!(ARGV)
  raise CensusError, '--workdir is required' if options[:workdir].to_s.empty?
  workdir = File.expand_path(options[:workdir])
  raise CensusError, "--workdir is not a directory: #{workdir}" unless File.directory?(workdir)

  paths = {
    twb: discover_one(workdir, options[:twb], %w[workbook-content.twb *.twb]),
    layout: discover_one(workdir, options[:layout], %w[dashboard-layout.json]),
    layout_meta: discover_one(workdir, options[:layout_meta], %w[dashboard-layout-meta.json *layout-meta.json]),
    calcs: discover_one(workdir, options[:calcs], %w[calc-fields.json]),
    gap: discover_one(workdir, options[:gap], %w[*gaps-report.json *gaps*report*.json gaps.json *gaps*.json]),
    formula_audit: discover_one(workdir, options[:formula_audit], %w[formula-audit.json *formula*audit*.json]),
    blend: discover_one(workdir, options[:blend], %w[blend-plan.json]),
    coverage: discover_one(workdir, options[:coverage], %w[coverage.json]),
    controls: discover_many(workdir, options[:controls],
                            %w[*-controls-coverage.json controls-census.json control-census.json
                               control-field-census.json control-scope.json]),
    parity: discover_one(workdir, options[:parity], %w[parity-final.json]),
    wb_readback: discover_one(workdir, options[:wb_readback], %w[wb-readback.json]),
    wb_spec: discover_one(workdir, options[:wb_spec], %w[wb-spec.json wb-spec.resolved.json])
  }
  output = options[:out] ? File.expand_path(options[:out], workdir) :
                           File.join(workdir, 'source-object-census.json')
  result = SourceObjectCensus.new(workdir, paths).build
  raise CensusError, 'source census is incomplete' unless result.dig('summary', 'complete')
  temporary = "#{output}.tmp.#{$$}"
  File.write(temporary, JSON.pretty_generate(result) + "\n")
  File.rename(temporary, output)
  puts "source object census: #{result.dig('summary', 'total')} objects, " \
       "#{result.dig('summary', 'counts').map { |status, count| "#{status}=#{count}" }.join(', ')}"
rescue OptionParser::ParseError, CensusError, SystemCallError => e
  warn "build-source-object-census: #{e.message}"
  exit 2
ensure
  File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
end
