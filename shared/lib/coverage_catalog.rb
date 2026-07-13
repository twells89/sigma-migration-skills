# frozen_string_literal: true
#
# coverage_catalog.rb — Ruby twin of shared/lib/coverage_catalog.py. Loads a
# documentation-grounded mapping catalog and resolves source constructs to Sigma
# targets, LOUDLY on a miss. Used by the Ruby dashboard classifiers
# (powerbi/quicksight build-workbook-from-*.rb) exactly as the Python loader is
# used by the Python builders (looker/qlik). The JSON catalog schema is
# language-neutral and identical across both — see the Python file's header.
#
#   require_relative 'lib/coverage_catalog'
#   viz = Coverage.load(Coverage.default_catalog_dir(__FILE__), 'viz-kind')
#   kind = viz.target(src)                 # cited Sigma target, or nil on a miss
#   row  = viz.resolve_or_warn(src, warns, context: title)  # nil + loud warn on miss
#
# Mirrors the beads-sigma-93ps contract: catalog = language-neutral data, this =
# the thin resolver. Stdlib only (json); Ruby 2.6-compatible.

require 'json'

module Coverage
  MISS = nil # resolve returns nil when a source key is absent

  class Catalog
    attr_reader :path, :filename, :dimension, :source_tool, :authoritative_doc,
                :on_unmapped_default, :rows

    def initialize(data, path)
      @path = path
      @filename = File.basename(path)
      @dimension = data['dimension'] || File.basename(path, '.json')
      @source_tool = data['source_tool'] || ''
      @authoritative_doc = data['authoritative_doc'] || ''
      @on_unmapped_default = data['on_unmapped_default'] || 'warn+skip'
      @rows = data['rows'] || []
      @by_source = {}
      @rows.each do |r|
        k = r['source']
        @by_source[norm(k)] = r unless k.nil?
      end
    end

    # Return the full catalog row for source_key, or nil on a miss.
    def resolve(source_key)
      return nil if source_key.nil?
      @by_source[norm(source_key)]
    end

    # Just the Sigma target string (row['sigma']), or nil on a miss.
    def target(source_key)
      r = resolve(source_key)
      r && r['sigma']
    end

    # Resolve; on a miss append a standardized LOUD warning to `warnings` and
    # return nil. The caller MUST then skip/placeholder — makes the loud
    # fallback mandatory and uniform.
    def resolve_or_warn(source_key, warnings, context: '')
      r = resolve(source_key)
      return r if r
      where = context.to_s.empty? ? '' : " (#{context})"
      tool = @source_tool.empty? ? 'source' : @source_tool
      warnings << "⚠ #{@dimension}: no documented #{tool} mapping for " \
                  "'#{source_key}'#{where} — #{@on_unmapped_default}. Add a cited " \
                  "row to refs/catalogs/#{@filename} if this is a real construct."
      nil
    end

    def sources
      @by_source.keys
    end

    # Rows whose Sigma target is not yet live-verified (sigma_verified.status != 'y').
    def unverified
      @rows.reject { |r| (r['sigma_verified'] || {})['status'] == 'y' }
    end

    private

    def norm(k)
      k.to_s.strip.downcase
    end
  end

  # Load <catalog_dir>/<dimension>.json. Fails LOUDLY if absent — a classifier
  # with no catalog must not silently guess.
  def self.load(catalog_dir, dimension)
    path = File.join(catalog_dir, "#{dimension}.json")
    unless File.exist?(path)
      raise "coverage catalog missing: #{path} — the classifier requires a " \
            "documentation-grounded catalog for '#{dimension}'; refusing to guess."
    end
    Catalog.new(JSON.parse(File.read(path)), path)
  end

  # Load every *.json catalog in catalog_dir, keyed by dimension name.
  def self.load_all(catalog_dir)
    raise "coverage catalog dir missing: #{catalog_dir}" unless File.directory?(catalog_dir)
    out = {}
    Dir[File.join(catalog_dir, '*.json')].sort.each do |p|
      d = File.basename(p, '.json')
      out[d] = load(catalog_dir, d)
    end
    out
  end

  # Given a builder's __FILE__ (in scripts/), return its sibling refs/catalogs dir.
  def self.default_catalog_dir(script_file)
    scripts_dir = File.dirname(File.expand_path(script_file))
    File.expand_path(File.join(scripts_dir, '..', 'refs', 'catalogs'))
  end
end
