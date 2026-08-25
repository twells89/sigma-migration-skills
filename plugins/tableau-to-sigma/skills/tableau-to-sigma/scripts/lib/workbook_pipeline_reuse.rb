# frozen_string_literal: true

require 'json'
require_relative 'workbook_code'

# Deterministically graft a proven workbook-local data pipeline onto a newly
# generated Tableau workbook. The LLM/agent authors a small, reviewable plan;
# this engine performs the merge without guessing and emits an evidence report.
module WorkbookPipelineReuse
  module_function

  def apply!(spec, donor_spec:, plan:)
    raise ArgumentError, 'pipeline reuse spec must be an object' unless spec.is_a?(Hash)
    raise ArgumentError, 'pipeline reuse plan must be an object' unless plan.is_a?(Hash)

    # The orchestrator calls this after per-page-master splitting while the spec
    # still carries explicit pages[].elements assignments. Preserve that view:
    # canonicalizing first can retain a stale pre-split layout and lose which
    # content page references which detached Data-page master.
    target =
      if Array(spec['pages']).any? { |page| page.is_a?(Hash) && page.key?('elements') }
        deep_copy(spec)
      else
        WorkbookCode.legacy_view(WorkbookCode.canonicalize(spec))
      end
    donor_elements = WorkbookCode.elements(donor_spec).each_with_object({}) do |element, index|
      index[element['id']] = deep_copy(element) if element['id']
    end

    requested_ids = Array(plan['pipeline_pages']).flat_map { |page| Array(page['element_ids']) }.uniq
    missing = requested_ids.reject { |id| donor_elements.key?(id) }
    raise ArgumentError, "donor workbook is missing pipeline element(s): #{missing.join(', ')}" unless missing.empty?

    # Remove stale copies before inserting the donor pipeline exactly once.
    target['pages'].each do |page|
      page['elements'] = Array(page['elements']).reject { |element| requested_ids.include?(element['id']) }
    end

    existing_pages_by_id = target['pages'].to_h { |page| [page['id'], page] }
    pipeline_pages = Array(plan['pipeline_pages']).map do |page_plan|
      donor_page_elements = Array(page_plan['element_ids']).map { |id| deep_copy(donor_elements.fetch(id)) }
      retained_elements =
        if page_plan.fetch('retain_existing', true)
          Array(existing_pages_by_id.dig(page_plan['id'], 'elements')).reject do |element|
            requested_ids.include?(element['id'])
          end
        else
          []
        end
      {
        'id' => page_plan.fetch('id'),
        'name' => page_plan.fetch('name'),
        'visibility' => page_plan.fetch('visibility', 'hidden'),
        'elements' => donor_page_elements + retained_elements
      }
    end
    pipeline_page_ids = pipeline_pages.map { |page| page['id'] }
    content_pages = target['pages'].reject { |page| pipeline_page_ids.include?(page['id']) }
    target['pages'] = pipeline_pages + content_pages
    apply_element_moves!(target['pages'], existing_pages_by_id, plan['move_existing_elements'] || [])

    by_id = target['pages'].flat_map { |page| Array(page['elements']) }
                  .each_with_object({}) { |element, index| index[element['id']] = element if element['id'] }

    apply_extensions!(by_id, plan['extensions'] || {})
    patched_master_ids = patch_masters!(target['pages'], by_id, plan['master_sources'] || {})
    rewrite_formulas!(target, plan['formula_rewrites'] || {})
    normalize_names!(target)

    {
      'spec' => target,
      'report' => {
        'schema_version' => 1,
        'template_workbook_id' => plan['template_workbook_id'],
        'pipeline_pages' => pipeline_pages.map do |page|
          { 'id' => page['id'], 'name' => page['name'],
            'element_ids' => page['elements'].map { |element| element['id'] } }
        end,
        'pipeline_elements_copied' => requested_ids.length,
        'masters_patched' => patched_master_ids.sort,
        'formula_rewrites' => plan['formula_rewrites'] || {}
      }
    }
  end

  def apply_extensions!(elements, extensions)
    extensions.each do |element_id, extension|
      element = elements[element_id] or raise ArgumentError, "pipeline extension target #{element_id.inspect} is missing"
      Array(extension['columns']).each do |column|
        next if Array(element['columns']).any? { |existing| existing['id'] == column['id'] }
        (element['columns'] ||= []) << deep_copy(column)
        (element['order'] ||= []) << column['id'] if column['id']
      end
      Array(extension['union_matches']).each do |match|
        source = element['source'] || {}
        raise ArgumentError, "#{element_id} is not a union source" unless source['kind'] == 'union'
        next if Array(source['matches']).any? { |existing| existing['outputColumnName'] == match['outputColumnName'] }
        (source['matches'] ||= []) << deep_copy(match)
      end
    end
  end

  def apply_element_moves!(pages, existing_pages, moves)
    Array(moves).each do |move|
      source = existing_pages[move.fetch('from_page')]
      target = pages.find { |page| page['id'] == move.fetch('to_page') }
      raise ArgumentError, "pipeline move target page #{move['to_page'].inspect} is missing" unless target
      selected = Array(source && source['elements']).select do |element|
        (!move['kind'] || element['kind'] == move['kind']) &&
          (!move['name'] || element['name'].to_s.casecmp?(move['name'].to_s))
      end
      raise ArgumentError, "pipeline move selected no elements from #{move['from_page'].inspect}" if selected.empty?
      selected_ids = selected.map { |element| element['id'] }
      pages.each do |page|
        page['elements'] = Array(page['elements']).reject { |element| selected_ids.include?(element['id']) }
      end
      target['elements'] = Array(target['elements']) + selected.map { |element| deep_copy(element) }
    end
  end

  def patch_masters!(pages, elements, master_sources)
    patched = []
    master_sources.each do |master_id, instructions|
      master = elements[master_id]
      unless master
        page_name = instructions['page']
        page = pages.find { |candidate| candidate['name'].to_s.casecmp?(page_name.to_s) } if page_name
        refs = []
        collect_element_refs!(page && page['elements'], refs)
        candidates = refs.uniq.filter_map { |id| elements[id] }.select do |element|
          element['kind'] == 'table' && element['name'].to_s.casecmp?('Master')
        end
        if candidates.empty? && page_name
          slug = page_name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').sub(/\A-/, '').sub(/-\z/, '')[0, 40]
          candidates = elements.values.select do |element|
            element['kind'] == 'table' && element['name'].to_s.casecmp?('Master') &&
              element['id'].to_s == "master-#{slug}"
          end
        end
        unless candidates.one?
          available = elements.values.select do |element|
            element['kind'] == 'table' && element['name'].to_s.casecmp?('Master')
          end.map { |element| element['id'] }
          raise ArgumentError, "generated workbook has no unique master #{master_id.inspect} on page #{page_name.inspect}; " \
                               "available masters: #{available.join(', ')}"
        end
        master = candidates.first
      end
      master['source'] = deep_copy(instructions.fetch('source'))
      fields = instructions['fields'] || {}
      Array(master['columns']).each do |column|
        rule = fields[column['name']]
        column['formula'] = rule['formula'] if rule.is_a?(Hash) && rule['formula']
        column['formula'] = rule if rule.is_a?(String)
      end
      patched << master['id']
    end
    patched
  end

  def collect_element_refs!(node, output)
    case node
    when Hash
      node.each do |key, value|
        output << value if key == 'elementId' && value.is_a?(String)
        collect_element_refs!(value, output)
      end
    when Array
      node.each { |value| collect_element_refs!(value, output) }
    end
  end

  def rewrite_formulas!(node, rewrites)
    case node
    when Hash
      node.each do |key, value|
        if key == 'formula' && value.is_a?(String) && rewrites.key?(value)
          node[key] = rewrites[value]
        else
          rewrite_formulas!(value, rewrites)
        end
      end
    when Array
      node.each { |value| rewrite_formulas!(value, rewrites) }
    end
  end

  def normalize_names!(node)
    case node
    when Hash
      if node['name'].is_a?(Hash)
        value = node['name']
        node['name'] = value['text'] || value['value'] || value.to_s
      end
      node.each_value { |value| normalize_names!(value) }
    when Array
      node.each { |value| normalize_names!(value) }
    end
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end
end
