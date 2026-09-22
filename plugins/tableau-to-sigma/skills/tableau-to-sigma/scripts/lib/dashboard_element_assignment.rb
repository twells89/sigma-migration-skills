# frozen_string_literal: true

# Reconcile document-global workbook elements with Tableau dashboard pages.
#
# Sigma workbook elements are global and page ownership lives only in layout
# XML. A stale/manual layout can therefore leave a valid chart assigned to the
# wrong page (or to no page). The dashboard layout builder must recover that
# chart by source worksheet provenance or an explicit rename before it rebuilds
# page XML; page-local lookup alone silently drops the source zone.
module DashboardElementAssignment
  module_function

  CHART_KINDS = %w[table pivot-table].freeze

  def norm(value)
    value.to_s.downcase.gsub(/[^a-z0-9]/, '')
  end

  def display_name(element)
    name = element['name']
    name.is_a?(Hash) ? name['text'].to_s : name.to_s
  end

  def chart_element?(element)
    return false unless element.is_a?(Hash)

    kind = element['kind'].to_s
    element['visibleAsSource'] != false &&
      (kind.end_with?('-chart') || CHART_KINDS.include?(kind))
  end

  def aliases_for(element, provenance)
    aliases = [display_name(element)]
    record = provenance[element['id'].to_s]
    if record.is_a?(Hash)
      aliases << record['worksheet']
      aliases << record['name']
    end
    aliases.map(&:to_s).map(&:strip).reject(&:empty?).uniq
  end

  def zone_names(zone, renames)
    caption = zone['caption'].to_s.strip
    display_title = zone['display_title'].to_s.strip
    explicit = renames[caption].to_s.strip
    # Provenance aliases are keyed by worksheet caption, so try the caption
    # before collision-prone display titles. Explicit reconstruction renames
    # are the fallback for hand-built elements with no provenance record.
    [caption, explicit, display_title].reject(&:empty?).uniq
  end

  # Mutates legacy_pages' nested `elements` arrays. Returns an audit record:
  #   moved      elements rehomed from another/no page
  #   retained   already on the intended page
  #   ambiguous  source zones matching multiple global elements
  #   conflicts  one global element requested by multiple dashboard pages
  #   unmatched  source chart zones with no global element
  def reconcile!(legacy_pages:, dashboards:, page_for_dashboard:, all_elements:,
                 provenance: {}, renames: {})
    exact = Hash.new { |hash, key| hash[key] = [] }
    normalized = Hash.new { |hash, key| hash[key] = [] }
    Array(all_elements).select { |element| chart_element?(element) }.each do |element|
      aliases_for(element, provenance).each do |name|
        exact[name] << element unless exact[name].include?(element)
        key = norm(name)
        normalized[key] << element unless key.empty? || normalized[key].include?(element)
      end
    end

    result = {
      'moved' => [],
      'retained' => [],
      'ambiguous' => [],
      'conflicts' => [],
      'unmatched' => []
    }
    claimed = {}

    Array(dashboards).each do |dashboard|
      page = page_for_dashboard[dashboard['dashboard']]
      next unless page

      Array(dashboard['zones']).each do |zone|
        next unless zone.is_a?(Hash) && zone['kind'].to_s == 'chart'
        next if zone['caption'].to_s.strip.empty?

        match = nil
        ambiguous = nil
        matched_name = nil
        zone_names(zone, renames).each do |name|
          candidates = exact[name].uniq
          candidates = normalized[norm(name)].uniq if candidates.empty?
          next if candidates.empty?
          if candidates.length > 1
            provenance_scoped = candidates.select do |candidate|
              record = provenance[candidate['id'].to_s]
              record.is_a?(Hash) &&
                record['dashboard'].to_s.strip.casecmp?(dashboard['dashboard'].to_s.strip)
            end
            candidates = provenance_scoped if provenance_scoped.any?
          end
          if candidates.length > 1
            currently_on_target = candidates.select do |candidate|
              Array(page['elements']).any? do |owned|
                owned['id'].to_s == candidate['id'].to_s
              end
            end
            candidates = currently_on_target if currently_on_target.any?
          end
          if candidates.length > 1
            ambiguous = candidates
          else
            match = candidates.first
          end
          matched_name = name
          break
        end

        if ambiguous
          result['ambiguous'] << {
            'dashboard' => dashboard['dashboard'],
            'zone' => zone['caption'],
            'matched_name' => matched_name,
            'element_ids' => ambiguous.map { |element| element['id'] }.sort
          }
          next
        end
        unless match
          result['unmatched'] << {
            'dashboard' => dashboard['dashboard'],
            'zone' => zone['caption'],
            'tried_names' => zone_names(zone, renames)
          }
          next
        end

        element_id = match['id'].to_s
        prior_claim = claimed[element_id]
        if prior_claim && prior_claim != page['id']
          result['conflicts'] << {
            'element_id' => element_id,
            'first_page_id' => prior_claim,
            'second_page_id' => page['id'],
            'zone' => zone['caption']
          }
          next
        end
        claimed[element_id] = page['id']

        owners = Array(legacy_pages).select do |candidate_page|
          Array(candidate_page['elements']).any? { |element| element['id'].to_s == element_id }
        end
        if owners.length == 1 && owners.first['id'].to_s == page['id'].to_s
          result['retained'] << {
            'element_id' => element_id,
            'page_id' => page['id'],
            'zone' => zone['caption'],
            'matched_name' => matched_name
          }
          next
        end

        Array(legacy_pages).each do |candidate_page|
          candidate_page['elements'] = Array(candidate_page['elements']).reject do |element|
            element['id'].to_s == element_id
          end
        end
        page['elements'] ||= []
        page['elements'] << match
        result['moved'] << {
          'element_id' => element_id,
          'from_page_ids' => owners.map { |owner| owner['id'] },
          'to_page_id' => page['id'],
          'zone' => zone['caption'],
          'matched_name' => matched_name
        }
      end
    end

    result.each_value(&:uniq!)
    result
  end
end
