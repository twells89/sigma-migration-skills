#!/usr/bin/env ruby

require 'fileutils'
require 'json'
require_relative 'lib/plugin_integrity'

root = DomoPluginIntegrity.plugin_root
path = DomoPluginIntegrity.manifest_path(root)

begin
  if ARGV.delete('--write')
    payload = DomoPluginIntegrity.generate(root)
    temporary = "#{path}.tmp-#{Process.pid}"
    File.write(temporary, JSON.pretty_generate(payload) + "\n")
    File.rename(temporary, path)
    warn "wrote #{path}"
  else
    result = DomoPluginIntegrity.verify!(root)
    warn "plugin integrity OK: domo-to-sigma #{result['pluginVersion']} " \
         "(#{result['files'].size} critical files)"
  end
rescue StandardError => e
  FileUtils.rm_f(temporary) if defined?(temporary) && temporary
  abort "FATAL: #{e.message}"
end
