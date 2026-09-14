# frozen_string_literal: true

require 'digest'
require 'json'

# Normalize and evaluate the Tableau converter's object-graph relationship
# ledger. A wired-but-partial edge is blocking: dropping one computed
# predicate makes the Sigma relationship wider than Tableau's even when the
# remaining physical key is unique.
module RelationshipCoverage
  module_function

  def snakeize(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), out|
        normalized = key.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase
        out[normalized] = snakeize(child)
      end
    when Array
      value.map { |child| snakeize(child) }
    else
      value
    end
  end

  def evaluate(metadata, source_text: nil, model: nil)
    coverage = metadata.is_a?(Hash) ? metadata['relationshipCoverage'] : nil
    object_graph = source_text.to_s.match?(/<(?:[^<>\s]*\.true\.\.\.)?object-graph[\s>\/]/)

    unless coverage.is_a?(Hash)
      blockers = object_graph ? [{
        'kind' => 'coverage-missing',
        'reason' => 'source contains an object-graph but converter metadata has no relationshipCoverage ledger'
      }] : []
      return {
        'schema_version' => 1,
        'applicable' => object_graph,
        'status' => blockers.empty? ? 'not-applicable' : 'fail',
        'serialized' => 0,
        'wired' => 0,
        'entries' => [],
        'blockers' => blockers
      }
    end

    normalized = snakeize(coverage)
    entries = normalized['entries']
    entries = [] unless entries.is_a?(Array)
    serialized = normalized['serialized'].to_i
    wired = normalized['wired'].to_i
    blockers = []

    if serialized.negative? || wired.negative? || wired > serialized
      blockers << {
        'kind' => 'invalid-counts',
        'reason' => "invalid relationship counts: serialized=#{serialized}, wired=#{wired}"
      }
    end
    if entries.length != serialized
      blockers << {
        'kind' => 'ledger-count-mismatch',
        'reason' => "relationship ledger has #{entries.length} entries for #{serialized} serialized relationships"
      }
    end
    if wired != entries.count { |entry| entry.is_a?(Hash) && entry['derived_via'].to_s != 'unwired' }
      blockers << {
        'kind' => 'wired-count-mismatch',
        'reason' => 'wired count disagrees with relationship entry dispositions'
      }
    end

    entries.each_with_index do |entry, index|
      unless entry.is_a?(Hash)
        blockers << {
          'kind' => 'malformed-entry', 'index' => index,
          'reason' => 'relationship entry is not an object'
        }
        next
      end
      disposition = entry['derived_via'].to_s
      dropped = entry['dropped_conditions'].to_i
      if disposition.empty?
        blockers << blocker(entry, index, 'missing-disposition',
                            'relationship entry has no derived_via disposition')
      elsif disposition == 'unwired'
        blockers << blocker(entry, index, 'unwired',
                            entry['reason'].to_s.empty? ? 'relationship was not wired' : entry['reason'])
      elsif entry['partial'] == true || dropped.positive?
        blockers << blocker(
          entry, index, 'partial',
          "relationship dropped #{[dropped, 1].max} source condition(s); a widened join cannot pass"
        )
      end
    end

    result = {
      'schema_version' => 1,
      'applicable' => true,
      'status' => blockers.empty? ? 'pass' : 'fail',
      'serialized' => serialized,
      'wired' => wired,
      'entries' => entries,
      'blockers' => blockers
    }
    add_model_checks(result, model)
    result
  end

  def from_files(metadata_path, source_path = nil, model_path = nil)
    raw = File.binread(metadata_path)
    metadata = JSON.parse(raw)
    source_text = source_path && File.file?(source_path) ? File.read(source_path, encoding: 'bom|utf-8') : nil
    coverage_source = JSON.generate(metadata.is_a?(Hash) ? metadata['relationshipCoverage'] : nil)
    model = model_path && File.file?(model_path) ? JSON.parse(File.read(model_path)) : nil
    evaluate(metadata, source_text: source_text, model: model).merge(
      'source' => File.basename(metadata_path),
      'source_sha256' => Digest::SHA256.hexdigest(coverage_source)
    )
  end

  def add_model_checks(result, model)
    return result unless model.is_a?(Hash)
    relationships = Array(model['pages']).flat_map do |page|
      Array(page['elements']).flat_map { |element| Array(element['relationships']) }
    end
    empty = relationships.count { |relationship| Array(relationship['keys']).empty? }
    result['model_relationships'] = relationships.length
    result['model_relationships_without_keys'] = empty
    if result['applicable'] && relationships.length != result['serialized']
      result['blockers'] << {
        'kind' => 'model-count-mismatch',
        'reason' => "data-model has #{relationships.length} relationships for " \
                    "#{result['serialized']} serialized Tableau relationships"
      }
    end
    if empty.positive?
      result['blockers'] << {
        'kind' => 'model-relationship-without-keys',
        'reason' => "#{empty} data-model relationship(s) have no keys"
      }
    end
    result['status'] = 'fail' unless result['blockers'].empty?
    result
  end

  def blocker(entry, index, kind, reason)
    {
      'kind' => kind,
      'index' => index,
      'left' => entry['left'],
      'right' => entry['right'],
      'derived_via' => entry['derived_via'],
      'reason' => reason,
      'collisions' => entry['collisions']
    }.reject { |_key, value| value.nil? }
  end
end
