require 'digest'
require 'json'

module DomoPluginIntegrity
  SCHEMA = 'domo-plugin-integrity/v1'.freeze
  CRITICAL_FILES = [
    '.claude-plugin/plugin.json',
    'skills/domo-to-sigma/SKILL.md',
    'skills/domo-to-sigma/scripts/migrate-domo.rb',
    'skills/domo-to-sigma/scripts/build-workbook.rb',
    'skills/domo-to-sigma/scripts/derive-presentation-overrides.rb',
    'skills/domo-to-sigma/scripts/check-plugin-integrity.rb',
    'skills/domo-to-sigma/scripts/lib/plugin_integrity.rb',
  ].freeze

  module_function

  def plugin_root(from = __dir__)
    File.expand_path('../../../../', from)
  end

  def manifest_path(root)
    File.join(root, '.claude-plugin', 'integrity.json')
  end

  def generate(root)
    plugin = JSON.parse(File.read(File.join(root, '.claude-plugin', 'plugin.json')))
    {
      'schema' => SCHEMA,
      'pluginVersion' => plugin.fetch('version'),
      'files' => CRITICAL_FILES.each_with_object({}) do |relative, out|
        path = File.join(root, relative)
        raise "critical plugin file missing: #{relative}" unless File.file?(path)
        out[relative] = Digest::SHA256.file(path).hexdigest
      end,
    }
  end

  def verify!(root)
    path = manifest_path(root)
    raise "integrity manifest missing: #{path}" unless File.file?(path)
    expected = JSON.parse(File.read(path))
    raise "invalid integrity schema: #{expected['schema'].inspect}" unless expected['schema'] == SCHEMA

    actual = generate(root)
    if expected['pluginVersion'] != actual['pluginVersion']
      raise "integrity version #{expected['pluginVersion'].inspect} does not match " \
            "plugin.json #{actual['pluginVersion'].inspect}"
    end
    missing = CRITICAL_FILES.reject { |relative| expected.dig('files', relative) }
    raise "integrity manifest omits: #{missing.join(', ')}" unless missing.empty?
    mismatched = CRITICAL_FILES.select {
      |relative| expected.dig('files', relative) != actual.dig('files', relative)
    }
    raise "plugin files do not match advertised release: #{mismatched.join(', ')}" unless mismatched.empty?

    {
      'schema' => SCHEMA,
      'pluginVersion' => actual['pluginVersion'],
      'manifestSha256' => Digest::SHA256.file(path).hexdigest,
      'files' => actual['files'],
    }
  rescue JSON::ParserError => e
    raise "integrity manifest is not valid JSON: #{e.message}"
  end
end
