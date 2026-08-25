# frozen_string_literal: true

require 'json'
require_relative 'workbook_code'

# Pure local equivalent of the layout merge portion of put-layout.rb. It never
# loads Sigma REST and therefore cannot perform a live write.
module LayoutApply
  module_function

  def apply(spec, layout_xml:, elements_sidecar: nil, prune_sidecar: nil)
    document = WorkbookCode.document(spec).dup
    metadata = WorkbookCode.metadata(spec)
    elements = Array(document['elements']).map(&:dup)

    injected = parse_elements(elements_sidecar)
    by_id = elements.each_with_object({}) { |element, index| index[element['id']] = element if element.is_a?(Hash) }
    injected.each do |element|
      next unless element.is_a?(Hash) && element['id']
      by_id[element['id']] = element
    end

    prune_ids = parse_prunes(prune_sidecar)
    document['elements'] = by_id.values.reject { |element| prune_ids.include?(element['id']) }
    document['layout'] = layout_xml.to_s
    output = Sigma::CodeRep.wrap(document, extra: metadata)
    errors = WorkbookCode.validate(output)
    raise ArgumentError, "local layout merge invalid: #{errors.join('; ')}" unless errors.empty?
    output
  end

  def parse_elements(value)
    document = parse_document(value)
    return [] unless document
    return document.values.flatten if document.is_a?(Hash)
    Array(document)
  end

  def parse_prunes(value)
    document = parse_document(value)
    entries = document.is_a?(Hash) ? Array(document['elements']) : Array(document)
    entries.filter_map { |entry| entry.is_a?(Hash) ? entry['element_id'] : entry }.uniq
  end

  def parse_document(value)
    return nil if value.nil?
    return value if value.is_a?(Hash) || value.is_a?(Array)
    return nil unless File.exist?(value.to_s)
    JSON.parse(File.read(value.to_s, encoding: 'UTF-8'))
  end
end
