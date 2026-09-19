# frozen_string_literal: true
# Load an Omni shared-model checkout (git projection or yaml-get dump).
# File names follow Omni's IDE: *.view, *.topic, relationships.yaml, model.yaml.
# Query views (*.query.view) are recorded and skipped by the v0 DM converter.

require 'yaml'

module OmniModel
  module_function

  def load(dir)
    root = File.expand_path(dir)
    abort "model dir not found: #{dir}" unless File.directory?(root)
    model = {
      'root' => root,
      'views' => {},
      'topics' => {},
      'relationships' => [],
      'model' => {},
      'query_views' => []
    }
    Dir.glob(File.join(root, '**', '*')).sort.each do |path|
      next unless File.file?(path)
      rel = path.sub(%r{\A#{Regexp.escape(root)}/?}, '')
      base = File.basename(path)
      if relationship_file?(base)
        parsed = YAML.safe_load(File.read(path))
        model['relationships'] = Array(parsed)
      elsif model_file?(base)
        model['model'] = YAML.safe_load(File.read(path)) || {}
      elsif base.end_with?('.query.view')
        model['query_views'] << rel
      elsif view_file?(base)
        doc = YAML.safe_load(File.read(path)) || {}
        name = view_name(path, doc)
        model['views'][name] = doc.merge('_file' => rel, '_name' => name)
      elsif topic_file?(base)
        doc = YAML.safe_load(File.read(path)) || {}
        key = topic_key(base)
        model['topics'][key] = doc.merge('_file' => rel, '_key' => key)
      end
    end
    model
  end

  def relationship_file?(base)
    base == 'relationships' || base == 'relationships.yaml'
  end

  def model_file?(base)
    base == 'model' || base == 'model.yaml'
  end

  def view_file?(base)
    (base.end_with?('.view') || base.end_with?('.view.yaml')) && !base.end_with?('.query.view')
  end

  def topic_file?(base)
    base.end_with?('.topic') || base.end_with?('.topic.yaml')
  end

  def view_name(path, doc)
    text = File.read(path)
    commented = text[/Reference this view as ([A-Za-z0-9_]+)/, 1]
    return commented if commented
    explicit = doc['view_name'] || doc['name']
    return explicit.to_s if explicit.is_a?(String) && !explicit.empty?
    File.basename(path).sub(/\.view\.yaml\z/, '').sub(/\.view\z/, '')
  end

  def topic_key(base)
    base.sub(/\.yaml\z/, '').sub(/\.topic\z/, '')
  end

  def find_topic(model, name)
    return nil if name.nil? || name.empty?
    topics = model['topics']
    return topics[name] if topics[name]
    topics.each_value do |topic|
      label = topic['label'].to_s
      base = topic['base_view'].to_s
      return topic if label.casecmp(name).zero? || base == name || topic['_key'] == name
    end
    nil
  end

  # Topic joins are a nested map. Keys are view names included in the topic.
  def joined_views(topic)
    names = []
    walk = lambda do |node|
      return unless node.is_a?(Hash)
      node.each do |view, child|
        names << view.to_s
        walk.call(child)
      end
    end
    walk.call(topic['joins'] || {})
    names.uniq
  end
end
