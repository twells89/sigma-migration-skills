# frozen_string_literal: true

require 'json'
require 'set'
require_relative 'workbook_code'

# Derives a REVIEW-REQUIRED draft semantic map by comparing Tableau IR field
# requirements with an existing Sigma workbook's local data pipeline. It never
# silently applies guesses; exact matches are executable, aliases/unresolved
# fields are surfaced for the LLM/operator to review.
module DerivePipelineMap
  module_function

  CONTENT_KINDS = %w[
    bar-chart line-chart area-chart pie-chart scatter-chart combo-chart
    waterfall-chart point-map region-map pivot-table kpi-chart box-plot
  ].freeze

  def derive(ir:, generated_spec:, donor_spec:, template_workbook_id: nil)
    donor_elements = WorkbookCode.elements(donor_spec)
    donor_by_id = donor_elements.to_h { |element| [element['id'], element] }
    pipeline_ids = donor_elements.select { |element| pipeline_element?(element) }
                                 .filter_map { |element| element['id'] }.to_set
    donor_pages = pipeline_pages(donor_spec, pipeline_ids)
    target = WorkbookCode.legacy_view(WorkbookCode.canonicalize(generated_spec))
    target_elements = target['pages'].flat_map { |page| Array(page['elements']) }
    target_by_id = target_elements.to_h { |element| [element['id'], element] }
    page_requirements = required_fields(ir)
    review = []

    master_sources = {}
    content_pages(target).each do |page|
      master = page_master(page, target_by_id)
      next unless master
      required = page_requirements[page['name']] || Set.new
      root, coverage = best_root(required, donor_elements)
      unless root
        review << {
          'page' => page['name'], 'kind' => 'pipeline-root',
          'reason' => 'no donor table exposes any required Tableau fields'
        }
        next
      end
      fields = {}
      Array(master['columns']).each do |column|
        source_name = column['name'].to_s
        match = match_field(source_name, Array(root['columns']).filter_map { |entry| entry['name'] })
        if match && match[:confidence] == 'exact'
          fields[source_name] = "[#{root['name']}/#{match[:name]}]"
        elsif match
          fields[source_name] = {
            'formula' => "[#{root['name']}/#{match[:name]}]",
            'review_required' => true,
            'confidence' => match[:confidence]
          }
          review << {
            'page' => page['name'], 'field' => source_name, 'kind' => 'field-alias',
            'candidate' => match[:name], 'confidence' => match[:confidence]
          }
        else
          fields[source_name] = {
            'review_required' => true,
            'reason' => 'no donor output column matched; supply a source formula or constant'
          }
          review << {
            'page' => page['name'], 'field' => source_name, 'kind' => 'field-unresolved',
            'pipeline_root' => root['name']
          }
        end
      end
      master_sources[master['id']] = {
        'page' => page['name'],
        'source' => { 'kind' => 'table', 'elementId' => root['id'] },
        'coverage' => coverage,
        'fields' => fields
      }
    end

    data_page = target['pages'].find { |page| page['id'].to_s.downcase.include?('data') }
    move_target = donor_pages.last
    {
      'schema_version' => 1,
      'status' => review.empty? ? 'reviewed-ready' : 'draft-review-required',
      'template_workbook_id' => template_workbook_id,
      'pipeline_pages' => donor_pages,
      'move_existing_elements' =>
        if data_page && move_target
          [{
            'from_page' => data_page['id'],
            'to_page' => move_target['id'],
            'kind' => 'table',
            'name' => 'Master'
          }]
        else
          []
        end,
      'extensions' => {},
      'master_sources' => master_sources,
      'formula_rewrites' => {},
      'review_required' => review
    }
  end

  def pipeline_element?(element)
    return true if element['kind'] == 'input-table'
    return true if element['visibleAsSource'] == false
    source_kind = element.dig('source', 'kind')
    %w[join union].include?(source_kind)
  end

  def pipeline_pages(donor_spec, pipeline_ids)
    WorkbookCode.pages(donor_spec).filter_map do |page|
      ids = WorkbookCode.elements_for_page(donor_spec, page).filter_map { |element| element['id'] }
      selected = ids.select { |id| pipeline_ids.include?(id) }
      next if selected.empty?
      {
        'id' => page['id'],
        'name' => page['name'] || page['id'],
        'visibility' => 'hidden',
        'retain_existing' => false,
        'element_ids' => selected
      }
    end
  end

  def content_pages(spec)
    Array(spec['pages']).reject do |page|
      page['visibility'] == 'hidden' || page['name'].to_s.match?(/\A(?:Data|Model|Derived|Inputs?)/i)
    end
  end

  def page_master(page, elements)
    refs = []
    collect_refs(page['elements'], refs)
    refs.uniq.filter_map { |id| elements[id] }.find do |element|
      element['kind'] == 'table' && element['name'].to_s.casecmp?('Master')
    end
  end

  def collect_refs(node, output)
    case node
    when Hash
      node.each do |key, value|
        output << value if key == 'elementId' && value.is_a?(String)
        collect_refs(value, output)
      end
    when Array
      node.each { |value| collect_refs(value, output) }
    end
  end

  def required_fields(ir)
    Array(ir.dig('workbook', 'pages')).each_with_object({}) do |page, output|
      fields = Set.new
      Array(page['zones']).each do |zone|
        %w[rows_shelf cols_shelf].each do |shelf_key|
          Array(zone.dig(shelf_key, 'fields')).each do |field|
            fields << field_name(field) unless field_name(field).empty?
          end
        end
        Array(zone['measures']).each { |field| fields << field_name(field) unless field_name(field).empty? }
        Array(zone['filters']).each do |filter|
          name = filter['column_caption'] || filter['caption'] || filter['column']
          fields << name.to_s unless name.to_s.empty?
        end
      end
      output[page['name']] = fields
    end
  end

  def best_root(required, elements)
    candidates = elements.select { |element| element['kind'] == 'table' && Array(element['columns']).any? }
    scored = candidates.map do |element|
      columns = Array(element['columns']).filter_map { |column| column['name'] }
      matched = required.count { |field| match_field(field, columns) }
      [element, required.empty? ? 0.0 : matched.to_f / required.length]
    end
    scored.max_by { |element, score| [score, Array(element['columns']).length, element['name'].to_s] }
  end

  def match_field(field, candidates)
    wanted = normalize(field)
    exact = candidates.find { |candidate| normalize(candidate) == wanted }
    return { name: exact, confidence: 'exact' } if exact
    tokens = field.to_s.downcase.scan(/[a-z0-9]+/).reject { |token| token.length < 3 }.to_set
    matches = candidates.map do |candidate|
      candidate_tokens = candidate.to_s.downcase.scan(/[a-z0-9]+/).reject { |token| token.length < 3 }.to_set
      overlap = (tokens & candidate_tokens).length
      [candidate, overlap, candidate_tokens.length]
    end.select { |_candidate, overlap, _size| overlap.positive? }
    matches.sort_by! { |candidate, overlap, size| [-overlap, size, candidate] }
    return nil if matches.empty? || (matches.length > 1 && matches[0][1] == matches[1][1])
    { name: matches.first[0], confidence: 'token-overlap' }
  end

  def field_name(field)
    return field.to_s unless field.is_a?(Hash)
    (field['caption'] || field['column_caption'] || field['name'] ||
      field['guid'] || field['column']).to_s.gsub(/\A\[|\]\z/, '')
  end

  def normalize(value)
    value.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end
end
