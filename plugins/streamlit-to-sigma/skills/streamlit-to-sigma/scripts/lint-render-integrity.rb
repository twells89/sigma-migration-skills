#!/usr/bin/env ruby
# Fail fast when a workbook code-representation contains a data element that
# has no usable data binding and is therefore likely to render blank.
#
# Library:
#   require_relative 'lint-render-integrity'
#   report = RenderIntegrity.lint(spec_hash, spec_path: '/tmp/wb-spec.json')
#   report = RenderIntegrity.lint_file('/tmp/wb-spec.json',
#                                      out_path: '/tmp/blank-risk-elements.json')
#
# CLI:
#   ruby scripts/lint-render-integrity.rb --spec /tmp/wb-spec.json [--out PATH]
#
# Exit 0 = clean, 1 = blank-risk data elements, 2 = invalid/unreadable input.

require 'json'
require 'optparse'

module RenderIntegrity
  SCHEMA_VERSION = 1
  STRUCTURAL_KEYS = %w[pages elements children].freeze
  BINDING_KEYS = %w[
    columns column
    xaxis yaxis
    color
    value values
    groupby
    row rows rowaxis rowaxes rowgroup rowgroups
    columnaxis columnaxes columngroup columngroups
    category categories
    series
    measure measures
    dimension dimensions
    size
    datasource datasources
    source sources
  ].freeze
  REFERENCE_KEYS = %w[
    column columnid columnids
    field fieldid fieldids
    elementid sourceid datasourceid datasetid tableid connectionid
    formula expression sql path url
    measure measureid dimension dimensionid
  ].freeze
  ID_CONTEXTS = %w[
    columns column xaxis yaxis color value values groupby
    row rows rowaxis rowaxes rowgroup rowgroups
    columnaxis columnaxes columngroup columngroups
    category categories series measure measures dimension dimensions size
    datasource datasources source sources
  ].freeze

  class InputError < StandardError; end

  module_function

  def lint(spec, spec_path: nil)
    document = unwrap_document(spec)
    risks = []
    checked = 0

    each_structural_node(document) do |element|
      next unless data_element?(element)

      checked += 1
      next if usable_data_binding?(element)

      risks << {
        'id' => scalar_text(element['id'] || element['elementId']),
        'name' => element_name(element),
        'kind' => element['kind'].to_s,
        'reasons' => ['no usable data bindings']
      }
    end

    risks.sort_by! { |entry| [entry['id'], entry['name'], entry['kind']] }
    {
      'schema_version' => SCHEMA_VERSION,
      'spec' => spec_path.to_s,
      'status' => risks.empty? ? 'PASS' : 'FAIL',
      'elements_checked' => checked,
      'blank_risk_count' => risks.length,
      'elements' => risks
    }
  end

  def lint_file(spec_path, out_path: nil)
    raise InputError, '--spec PATH is required' if spec_path.to_s.strip.empty?

    output_path = out_path || default_out_path(spec_path)
    spec = JSON.parse(File.read(spec_path))
    report = lint(spec, spec_path: spec_path)
    write_report(output_path, report)
    report
  rescue JSON::ParserError => e
    raise InputError, "invalid JSON in #{spec_path}: #{e.message}"
  rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
    raise InputError, "cannot read #{spec_path}: #{e.message}"
  end

  def error_report(spec_path, message)
    {
      'schema_version' => SCHEMA_VERSION,
      'spec' => spec_path.to_s,
      'status' => 'FAIL',
      'elements_checked' => 0,
      'blank_risk_count' => 0,
      'elements' => [],
      'error' => message.to_s
    }
  end

  def write_error_report(spec_path, out_path, message)
    report = error_report(spec_path, message)
    write_report(out_path || default_out_path(spec_path), report)
    report
  end

  def write_report(path, report)
    File.write(path, JSON.pretty_generate(report) + "\n")
  rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
    raise InputError, "cannot write #{path}: #{e.message}"
  end

  def default_out_path(spec_path)
    File.join(File.dirname(spec_path), 'blank-risk-elements.json')
  end

  def unwrap_document(spec)
    raise InputError, 'workbook spec must be a JSON object' unless spec.is_a?(Hash)

    return spec unless spec.key?('document')

    document = spec['document']
    raise InputError, 'workbook spec document wrapper must contain a JSON object' unless document.is_a?(Hash)

    document
  end

  # Traverse only workbook structural collections. This deliberately does not
  # walk every nested Hash: a source reference such as
  # {source:{kind:"table", elementId:"..."}} is not itself a table element.
  def each_structural_node(document, &block)
    visit = nil
    visit_collection = nil

    visit = lambda do |node|
      return unless node.is_a?(Hash)

      block.call(node)
      STRUCTURAL_KEYS.each do |key|
        visit_collection.call(node[key]) if node.key?(key)
      end
    end

    visit_collection = lambda do |collection|
      case collection
      when Array
        collection.each { |entry| visit.call(entry) }
      when Hash
        if collection.key?('kind') || STRUCTURAL_KEYS.any? { |key| collection.key?(key) }
          visit.call(collection)
        else
          # Some code-rep producers key pages/elements by id instead of using
          # an array. Preserve deterministic traversal by sorting those keys.
          collection.keys.map(&:to_s).sort.each do |key|
            actual_key = collection.keys.find { |candidate| candidate.to_s == key }
            visit.call(collection[actual_key])
          end
        end
      end
    end

    visit.call(document)
  end

  def data_element?(element)
    kind = normalize_key(element['kind'])
    return false if kind.empty? || kind.include?('control') || kind.include?('container')

    kind == 'chart' || kind == 'kpi' || kind.end_with?('chart') ||
      kind == 'table' || kind.end_with?('table') || kind.include?('pivot') ||
      kind.include?('crosstab')
  end

  def usable_data_binding?(element)
    kind = normalize_key(element['kind'])
    return usable_kpi_binding?(element) if kind.include?('kpi')
    return usable_chart_binding?(element) if kind == 'chart' || kind.end_with?('chart')

    any_binding?(element)
  end

  # A chart source or lone category can still POST successfully while rendering
  # no marks (the Azure Map -> bar downgrade regression). Require a value/mark
  # channel, or at least two usable projected columns for chart shapes whose
  # builders encode axes indirectly.
  def usable_chart_binding?(element)
    return true if any_named_binding?(element, %w[yaxis value values measure measures size])

    columns = binding_value(element, 'columns')
    columns.is_a?(Array) && columns.count { |entry| usable_binding_value?(entry, 'columns') } >= 2
  end

  def usable_kpi_binding?(element)
    return true if any_named_binding?(element, %w[value values yaxis measure measures])

    columns = binding_value(element, 'columns')
    columns.is_a?(Array) && columns.any? { |entry| usable_binding_value?(entry, 'columns') }
  end

  def any_binding?(element)
    element.any? do |key, value|
      normalized = normalize_key(key)
      BINDING_KEYS.include?(normalized) && usable_binding_value?(value, normalized)
    end
  end

  def any_named_binding?(element, names)
    names.any? do |name|
      value = binding_value(element, name)
      !value.nil? && usable_binding_value?(value, name)
    end
  end

  def binding_value(element, normalized_name)
    pair = element.find { |key, _value| normalize_key(key) == normalized_name }
    pair && pair[1]
  end

  def usable_binding_value?(value, context)
    case value
    when Array
      value.any? { |entry| usable_binding_value?(entry, context) }
    when Hash
      value.any? do |key, nested|
        normalized = normalize_key(key)
        if REFERENCE_KEYS.include?(normalized)
          usable_reference_value?(nested)
        elsif normalized == 'id' && ID_CONTEXTS.include?(context)
          usable_reference_value?(nested)
        elsif normalized == 'name' && %w[source sources datasource datasources].include?(context)
          usable_reference_value?(nested)
        elsif BINDING_KEYS.include?(normalized)
          usable_binding_value?(nested, normalized)
        else
          # Bindings often wrap a reference in shape-specific keys such as
          # "primary", "left", or "fields". Keep the original binding context
          # while descending, but only recognized reference leaves can pass.
          nested.is_a?(Hash) || nested.is_a?(Array) ? usable_binding_value?(nested, context) : false
        end
      end
    when String, Symbol
      text = value.to_s.strip
      return false if text.empty?
      return false if context == 'color' && literal_color?(text)

      true
    else
      false
    end
  end

  def usable_reference_value?(value)
    case value
    when Array
      value.any? { |entry| usable_reference_value?(entry) }
    when Hash
      value.any? { |_key, nested| usable_reference_value?(nested) }
    when String, Symbol
      !value.to_s.strip.empty?
    when Numeric
      true
    else
      false
    end
  end

  def literal_color?(text)
    text.match?(/\A#(?:[0-9a-f]{3,8})\z/i) ||
      text.match?(/\A(?:rgb|rgba|hsl|hsla)\s*\(/i) ||
      %w[black white red green blue gray grey transparent currentcolor].include?(text.downcase)
  end

  def normalize_key(value)
    value.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  def scalar_text(value)
    return '' if value.nil?
    return value.to_s unless value.is_a?(Hash)

    scalar_text(value['text'] || value['name'] || value['title'])
  end

  def element_name(element)
    scalar_text(element['name'] || element['title'])
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: lint-render-integrity.rb --spec PATH [--out PATH]'
    opts.on('--spec PATH', 'Sigma workbook code-rep JSON') { |value| options[:spec] = value }
    opts.on('--out PATH', 'output JSON (default: sibling blank-risk-elements.json)') { |value| options[:out] = value }
  end

  begin
    parser.parse!
    raise RenderIntegrity::InputError, '--spec PATH is required' if options[:spec].to_s.strip.empty?

    report = RenderIntegrity.lint_file(options[:spec], out_path: options[:out])
    puts "lint-render-integrity: #{report['status']} — #{report['elements_checked']} data element(s) checked, " \
         "#{report['blank_risk_count']} blank-risk element(s); " \
         "evidence: #{options[:out] || RenderIntegrity.default_out_path(options[:spec])}"
    exit(report['status'] == 'PASS' ? 0 : 1)
  rescue OptionParser::ParseError, RenderIntegrity::InputError => e
    begin
      RenderIntegrity.write_error_report(options[:spec], options[:out], e.message) unless options[:spec].to_s.strip.empty?
    rescue RenderIntegrity::InputError => write_error
      warn "lint-render-integrity: #{write_error.message}"
    end
    warn "lint-render-integrity: #{e.message}"
    warn parser
    exit 2
  end
end
