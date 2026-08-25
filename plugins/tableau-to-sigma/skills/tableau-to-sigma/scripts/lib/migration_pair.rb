# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'set'
require 'time'

# Pure helpers for discovering and capturing Tableau -> Sigma migration pairs.
# This module intentionally performs no network requests. The CLI wrappers own
# transport and use GET-only adapters.
module MigrationPair
  SCHEMA_VERSION = 1
  STOP_TOKENS = %w[
    AND COPY DATA DEMO DEV FINAL FOR FROM MIGRATED MIGRATION MODEL NEW OLD PROD
    PUBLIC SIGMA TABLE TABLEAU TEMP TEST THE TMP V1 V2 VIEW WORKBOOK
  ].to_set.freeze
  MIGRATION_SUFFIXES = [
    /\s*[\[(](?:from\s+tableau|tableau\s+(?:import|conversion|parity)|migrated)[\])]\s*/i,
    /\s*[—-]\s*(?:tableau\s+)?(?:migration|parity)\s*/i,
    /\s+(?:copy|final|new|v\d+)\s*\z/i
  ].freeze
  SENSITIVE_XML_ATTRIBUTES = %w[
    access-token authentication dbname directory oauth password
    port server serverAddress serverPort service username userName
  ].freeze
  ID_KEYS = %w[
    columnId controlId dataModelId elementId folderId id inodeId pageId
    sourceColumnId targetColumnId targetElementId workbookId
  ].freeze

  module_function

  def canonical_name(value)
    text = value.to_s.dup
    MIGRATION_SUFFIXES.each { |pattern| text.gsub!(pattern, ' ') }
    text.downcase.gsub(/[^a-z0-9]+/, ' ').strip.gsub(/\s+/, ' ')
  end

  def name_tokens(value)
    canonical_name(value).upcase.split(/[^A-Z0-9]+/).reject do |token|
      token.empty? || token.length < 3 || STOP_TOKENS.include?(token)
    end.to_set
  end

  def name_affinity(left, right)
    left_canonical = canonical_name(left)
    right_canonical = canonical_name(right)
    return 1.0 if !left_canonical.empty? && left_canonical == right_canonical

    left_tokens = name_tokens(left)
    right_tokens = name_tokens(right)
    return 0.0 if left_tokens.empty? || right_tokens.empty?

    intersection = (left_tokens & right_tokens).length.to_f
    union = (left_tokens | right_tokens).length.to_f
    intersection / union
  end

  def slug(value)
    canonical_name(value).delete(' ')
  end

  def score(tableau, sigma)
    name_score = name_affinity(tableau['name'], sigma['name'])
    content_slug = slug(tableau['contentUrl'] || tableau['content_url'])
    sigma_slug = slug(sigma['name'])
    slug_match = !content_slug.empty? && content_slug == sigma_slug

    # Name is deliberately dominant in shallow mode. A slug is independent
    # evidence because Tableau contentUrl often survives display-name changes.
    confidence = (0.85 * name_score) + (slug_match ? 0.15 : 0.0)
    {
      'confidence' => confidence.round(6),
      'signals' => {
        'name_affinity' => name_score.round(6),
        'content_url_slug_match' => slug_match
      }
    }
  end

  def discover(tableau_workbooks, sigma_workbooks, min_confidence: 0.55, ambiguity_window: 0.05)
    candidates = []
    matched_sigma = Set.new
    unmatched_tableau = []

    tableau_workbooks.sort_by { |entry| [entry['name'].to_s, entry['id'].to_s] }.each do |tableau|
      ranked = sigma_workbooks.map do |sigma|
        scored = score(tableau, sigma)
        [sigma, scored]
      end.select { |_sigma, scored| scored['confidence'] >= min_confidence }
        .sort_by do |sigma, scored|
          [-scored['confidence'], -(parse_time(sigma['updatedAt'] || sigma['updated_at'])), sigma['name'].to_s]
        end

      if ranked.empty?
        unmatched_tableau << compact_tableau(tableau).merge('reason' => 'no_sigma_match_above_threshold')
        next
      end

      top_score = ranked.first[1]['confidence']
      selected = ranked.take_while { |_sigma, scored| (top_score - scored['confidence']).abs <= ambiguity_window }
      status = selected.length > 1 ? 'ambiguous' : 'candidate'
      selected.each do |sigma, scored|
        sigma_id = sigma['id'] || sigma['workbookId'] || sigma['inodeId']
        tableau_id = tableau['id'] || tableau['luid']
        matched_sigma << sigma_id.to_s
        candidates << {
          'pair_id' => Digest::SHA256.hexdigest("#{tableau_id}\0#{sigma_id}")[0, 24],
          'status' => status,
          'confidence' => scored['confidence'],
          'signals' => scored['signals'],
          'tableau' => compact_tableau(tableau),
          'sigma' => compact_sigma(sigma)
        }
      end
    end

    unmatched_sigma = sigma_workbooks.reject do |entry|
      matched_sigma.include?((entry['id'] || entry['workbookId'] || entry['inodeId']).to_s)
    end.map { |entry| compact_sigma(entry).merge('reason' => 'no_tableau_match_above_threshold') }

    {
      'pairs' => candidates.sort_by { |pair| [-pair['confidence'], pair['tableau']['name'].to_s, pair['sigma']['name'].to_s] },
      'unmatched_tableau' => unmatched_tableau,
      'unmatched_sigma' => unmatched_sigma
    }
  end

  def compact_tableau(entry)
    {
      'luid' => entry['id'] || entry['luid'],
      'name' => entry['name'],
      'content_url' => entry['contentUrl'] || entry['content_url'],
      'project' => entry.dig('project', 'name') || entry['project'],
      'updated_at' => entry['updatedAt'] || entry['updated_at']
    }.compact
  end

  def compact_sigma(entry)
    {
      'workbook_id' => entry['id'] || entry['workbookId'] || entry['inodeId'],
      'name' => entry['name'],
      'folder_id' => entry['folderId'] || entry['folder_id'],
      'updated_at' => entry['updatedAt'] || entry['updated_at'],
      'url' => entry['url']
    }.compact
  end

  def parse_tableau_list(payload)
    root = payload.is_a?(Hash) ? payload : {}
    list = root.dig('workbooks', 'workbook') || root['entries'] || root['workbooks'] || []
    list = [list] if list.is_a?(Hash)
    Array(list)
  end

  def parse_sigma_list(payload)
    root = payload.is_a?(Hash) ? payload : {}
    list = root['entries'] || root['workbooks'] || root['results'] || []
    list = [list] if list.is_a?(Hash)
    Array(list)
  end

  def scrub_twb(xml)
    output = xml.to_s.dup
    SENSITIVE_XML_ATTRIBUTES.each do |attribute|
      output.gsub!(/(\b#{Regexp.escape(attribute)}\s*=\s*)(["'])((?:(?!\2).)*)\2/i) do
        %(#{Regexp.last_match(1)}#{Regexp.last_match(2)}<REDACTED>#{Regexp.last_match(2)})
      end
    end
    output.gsub!(%r{(<repository-location\b[^>]*\bpath\s*=\s*)(["'])((?:(?!\2).)*)\2}i) do
      %(#{Regexp.last_match(1)}#{Regexp.last_match(2)}<REDACTED>#{Regexp.last_match(2)})
    end
    output
  end

  def normalize_ids(document)
    counters = Hash.new(0)
    maps = Hash.new { |hash, key| hash[key] = {} }
    walk = lambda do |value|
      case value
      when Hash
        value.keys.sort.each_with_object({}) do |key, out|
          item = value[key]
          if ID_KEYS.include?(key.to_s) && scalar_id?(item)
            category = key.to_s
            maps[category][item.to_s] ||= begin
              counters[category] += 1
              "#{category}-NORM#{format('%04d', counters[category])}"
            end
            out[key] = maps[category][item.to_s]
          else
            out[key] = walk.call(item)
          end
        end
      when Array
        value.map { |item| walk.call(item) }
      else
        value
      end
    end
    walk.call(document)
  end

  def scrub_document(document)
    walk = lambda do |value|
      case value
      when Hash
        value.each_with_object({}) do |(key, item), out|
          if key.to_s.match?(/secret|token|password|credential|username|userName|serverAddress|hostname/i)
            out[key] = '<REDACTED>'
          else
            out[key] = walk.call(item)
          end
        end
      when Array
        value.map { |item| walk.call(item) }
      else
        value
      end
    end
    walk.call(document)
  end

  def scalar_id?(value)
    value.is_a?(String) || value.is_a?(Integer)
  end

  def atomic_json(path, value)
    destination = Pathname(path)
    destination.dirname.mkpath
    temporary = Pathname("#{destination}.tmp-#{Process.pid}")
    temporary.write("#{JSON.pretty_generate(value)}\n")
    temporary.rename(destination)
  ensure
    temporary&.delete if temporary&.exist?
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def parse_time(value)
    Time.parse(value.to_s).to_i
  rescue ArgumentError, TypeError
    0
  end
  private_class_method :parse_time
end
