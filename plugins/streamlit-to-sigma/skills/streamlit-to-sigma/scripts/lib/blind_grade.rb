# frozen_string_literal: true
#
# blind_grade.rb — validation + anti-gaming cross-check for the PR-9 blind
# visual grade (blind-grade.json, written by a CONTEXT-FREE subagent driven by
# refs/blind-grader-brief.md).
#
# WHY. The field failure this closes: the builder agent self-graded its own
# workbook 6/6 PASS on visuals the customer rejected. The visual verdict must
# come from a grader with no run context — this module is the mechanical side
# of that contract:
#
#   * load_and_validate — the grade file parses, carries every checklist
#     dimension, and is HASH-BOUND: the sha256s it records must equal the
#     sha256s of the actual image files on disk (computed here, never trusted).
#     A grade whose hashes don't match the pixels graded is no evidence at all.
#   * cross_check — the grader's per-tile chart-family readings are compared
#     against the mechanical kind census (wb-readback.json for the target,
#     png-read.json for the source). A "grade" fabricated without reading the
#     images gets the families wrong; contradiction on more than
#     MAX_FAMILY_MISMATCHES tiles refuses the grade as inconsistent.
#
# Consumed by scripts/record-visual-check.rb (--blind-grade) and mirrored in
# spirit by assert-phase6-ran.rb gate 8b (shared canonical — it inlines the
# same checks because shared/ cannot require a plugin lib).

require 'json'
require 'digest'
require_relative 'code_rep'
# Ruby 2.6 floor (macOS system ruby): this file uses Enumerable#tally (2.7+).
# Polyfilled rather than rewritten -- see shared/lib/ruby_compat.rb.
require_relative 'ruby_compat'

module BlindGrade
  # The six checklist dimensions a visual verdict attests (kept in lockstep
  # with record-visual-check.rb CHECKLIST_KEYS / gate 8b).
  DIMENSION_KEYS = %w[element_titles_hidden palette_match composition_match
                      chart_shapes_match labels_legible numbers_formatted].freeze

  # Canonical chart families the grader may read off an image.
  CHART_FAMILIES = %w[bar line area combo scatter pie kpi map table].freeze
  NON_CHART_FAMILIES = %w[text control image container divider missing].freeze

  # Element/tile "kind" strings (Sigma element kinds, png-read kinds, or the
  # grader's own vocabulary) → canonical family. Unknown chart-ish strings
  # normalize to 'other' (which matches nothing — an honest mismatch).
  FAMILY_SYNONYMS = {
    'bar' => 'bar', 'bar-chart' => 'bar', 'column' => 'bar', 'column-chart' => 'bar',
    'line' => 'line', 'line-chart' => 'line', 'sparkline' => 'line',
    'area' => 'area', 'area-chart' => 'area',
    'combo' => 'combo', 'combo-chart' => 'combo', 'dual-axis' => 'combo',
    'scatter' => 'scatter', 'scatter-chart' => 'scatter', 'bubble' => 'scatter',
    'pie' => 'pie', 'pie-chart' => 'pie', 'donut' => 'pie', 'donut-chart' => 'pie',
    'kpi' => 'kpi', 'kpi-chart' => 'kpi', 'single-value' => 'kpi', 'big-number' => 'kpi',
    'map' => 'map', 'region-map' => 'map', 'point-map' => 'map',
    'table' => 'table', 'pivot-table' => 'table', 'pivot' => 'table',
    'crosstab' => 'table', 'text-table' => 'table', 'grid' => 'table',
    'text' => 'text', 'control' => 'control', 'image' => 'image',
    'container' => 'container', 'divider' => 'divider', 'missing' => 'missing'
  }.freeze

  # A blind grade may honestly disagree with the census on ONE tile (census
  # granularity vs visual reading, e.g. a combo read as line). Two or more
  # contradictions = the families were not read off the image → refuse.
  MAX_FAMILY_MISMATCHES = 1

  module_function

  def family(kind)
    k = kind.to_s.strip.downcase
    FAMILY_SYNONYMS[k] || (NON_CHART_FAMILIES.include?(k) ? k : 'other')
  end

  def chart_family?(fam)
    CHART_FAMILIES.include?(fam) || fam == 'other'
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def resolve(path, workdir)
    return nil if path.to_s.empty?
    File.expand_path(path.to_s, workdir)
  end

  # → { doc:, errors: [..], source_path:, target_path: }
  # errors empty ⇔ the grade parses, is complete, and is hash-bound to the
  # image files on disk. Does NOT judge pass/fail — the caller does.
  def load_and_validate(path, workdir:)
    errors = []
    unless File.file?(path.to_s)
      return { 'doc' => nil, 'errors' => ["blind grade file not found: #{path}"] }
    end
    doc = begin
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      return { 'doc' => nil, 'errors' => ["blind grade is not valid JSON: #{e.message}"] }
    end
    return { 'doc' => nil, 'errors' => ['blind grade must be a JSON object'] } unless doc.is_a?(Hash)

    src = resolve(doc['source_png'], workdir)
    tgt = resolve(doc['target_png'], workdir)
    errors << 'source_png missing from the grade (the grader must record both image paths)' if src.nil?
    errors << 'target_png missing from the grade (the grader must record both image paths)' if tgt.nil?
    %w[source_sha256 target_sha256].each do |k|
      errors << "#{k} missing/malformed (need 64-hex sha256)" unless doc[k].to_s =~ /\A[0-9a-f]{64}\z/i
    end

    if src && !File.file?(src)
      errors << "source image not on disk: #{src}"
    elsif src && doc['source_sha256'].to_s =~ /\A[0-9a-f]{64}\z/i && sha256(src) != doc['source_sha256'].to_s.downcase
      errors << "source_sha256 does NOT match #{src} — the grade is not bound to this image " \
                '(image changed since grading, or the hash was not computed from the file)'
    end
    if tgt && !File.file?(tgt)
      errors << "target image not on disk: #{tgt}"
    elsif tgt && doc['target_sha256'].to_s =~ /\A[0-9a-f]{64}\z/i && sha256(tgt) != doc['target_sha256'].to_s.downcase
      errors << "target_sha256 does NOT match #{tgt} — the grade is not bound to this image " \
                '(image changed since grading, or the hash was not computed from the file)'
    end

    dims = doc['dimensions']
    if dims.is_a?(Hash)
      missing = DIMENSION_KEYS.reject { |k| dims[k].is_a?(Hash) && %w[pass fail].include?(dims[k]['verdict'].to_s) }
      errors << "dimensions missing/invalid (need {verdict: pass|fail}): #{missing.join(', ')}" if missing.any?
    else
      errors << "dimensions missing — the grade must cover: #{DIMENSION_KEYS.join(', ')}"
    end

    pt = doc['per_tile']
    if !pt.is_a?(Array) || pt.empty? ||
       pt.any? { |t| !t.is_a?(Hash) || t['source_family'].to_s.empty? || t['target_family'].to_s.empty? }
      errors << 'per_tile missing/invalid — the grader must record {position, source_family, target_family} for every tile'
    end

    errors << "verdict must be pass|fail (got #{doc['verdict'].inspect})" unless %w[pass fail].include?(doc['verdict'].to_s)

    { 'doc' => doc, 'errors' => errors, 'source_path' => src, 'target_path' => tgt }
  end

  # Chart-family census of the BUILT workbook, from the wb-readback spec.
  # Workbook elements are the flat document.elements collection; data-model
  # pages[*].elements semantics are intentionally outside this workbook helper.
  # Returns an array of families (chart elements only), or nil when absent.
  def census_from_readback(path)
    return nil unless File.file?(path.to_s)
    doc = (JSON.parse(File.read(path)) rescue nil)
    return nil unless doc.is_a?(Hash)
    inner = Sigma::CodeRep.document(doc)
    return nil unless inner['elements'].is_a?(Array)
    fams = []
    Sigma::CodeRep.workbook_elements(inner).each do |el|
      next if el['visibleAsSource'] == false # hidden data-page master
      f = family(el['kind'])
      fams << f if chart_family?(f)
    end
    fams
  end

  # Chart-family census of the SOURCE dashboard, from the Phase 1d read
  # artifact (png-read.json tiles[].kind). Returns families or nil when absent.
  def census_from_png_read(path)
    return nil unless File.file?(path.to_s)
    doc = (JSON.parse(File.read(path)) rescue nil)
    tiles = doc.is_a?(Hash) ? Array(doc['tiles']) : nil
    return nil unless tiles
    fams = []
    tiles.each do |t|
      next unless t.is_a?(Hash)
      f = family(t['kind'])
      fams << f if chart_family?(f)
    end
    fams
  end

  # Compare the grader's per-tile family readings (one side) against a
  # mechanical census, as multisets: every census tile must find a matching
  # blind reading of the same family. → {mismatches:, blind:, census:}
  def cross_check(per_tile, census, side)
    blind = Array(per_tile).map { |t| family(t.is_a?(Hash) ? t["#{side}_family"] : nil) }
                           .select { |f| chart_family?(f) }
    b_counts = blind.tally
    c_counts = Array(census).tally
    matched = c_counts.sum { |f, n| [n, b_counts[f] || 0].min }
    mismatches = [blind.length, census.length].max - matched
    { 'mismatches' => mismatches, 'blind' => b_counts, 'census' => c_counts }
  end
end

# Ruby 2.6 back-compat: Enumerable#tally landed in 2.7.
unless [].respond_to?(:tally)
  module Enumerable
    def tally
      each_with_object(Hash.new(0)) { |x, h| h[x] += 1 }
    end
  end
end
