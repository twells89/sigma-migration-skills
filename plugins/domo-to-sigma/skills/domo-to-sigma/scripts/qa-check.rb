#!/usr/bin/env ruby
# Phase 5e — Domo-specific spec QA gate (runs on discovery/chart-specs.json BEFORE
# assembly/POST). Operationalizes refs/card-to-element.md's checklist so the fixes
# from the field feedback can't silently regress. Complements the reused
# assert-phase6-ran.rb (the Phase-6 hard gate); this is the pre-parity spec check.
#
#   ruby scripts/qa-check.rb            # reads discovery/chart-specs.json
#   ruby scripts/qa-check.rb --in <chart-specs.json>
#
# Exit 0 = clean; exit 1 = hard violations found.

require 'json'
require 'optparse'
require_relative 'lib/domo_sigma_util'
include DomoSigma

QA_AGGREGATE_FORMULA = /\b(?:Sum|Avg|Count|CountDistinct|Min|Max|Median|StdDev\w*|Var\w*)\s*\(/i

# Pull the column display name out of a [Master/Name] ref inside a formula.
def refs_in(formula)
  formula.to_s.scan(/\[Master\/([^\]]+)\]/).flatten
end

def check_filter_type_audit(audit)
  errors = []
  warns = []
  Array(audit && audit['filters']).each do |entry|
    label = "#{entry['cardId']}/#{entry['column']}"
    if entry['status'] == 'error'
      errors << "filter #{label} failed source-type coercion: #{entry['error']}"
    elsif %w[LONG DECIMAL DOUBLE INTEGER NUMBER].include?(entry['sourceType'].to_s.upcase) &&
          Array(entry['outputTypes']).include?('String')
      errors << "filter #{label} targets numeric #{entry['sourceType']} but still emits string values"
    elsif entry['status'] == 'untyped'
      warns << "filter #{label} has no source type; literal typing was not verified"
    end
  end
  [errors, warns]
end

def check(spec, scope: nil)
  errors = []
  warns  = []
  pages = spec['pages'] || []
  pages.each do |pg|
    els = pg['elements'] || []
    charts = els.reject { |e| e['kind'] == 'control' }
    controls = els.select { |e| e['kind'] == 'control' }

    els.each do |e|
      case e['kind']
      when 'kpi-chart'
        vcol = (e['columns'] || []).find { |c| c['id'] == e.dig('value', 'columnId') } || (e['columns'] || []).first
        f = vcol && vcol['formula']
        # #1: a KPI must not be Count/CountDistinct of a row-key/id column.
        if f =~ /\A\s*(Count|CountDistinct)\s*\(/i && refs_in(f).any? { |r| id_like?(r) }
          errors << "[#{pg['name']}] KPI '#{e['name']}' value is #{f} — counts a row-key/id (Domo table default). Use the authored measure (kpi-overrides.json)."
        end
        # KPI value must bind via columnId (not id).
        errors << "[#{pg['name']}] KPI '#{e['name']}' missing value.columnId." unless e.dig('value', 'columnId')
      when 'bar-chart', 'line-chart', 'area-chart', 'combo-chart', 'scatter-chart'
        # #8: gridlines should default off.
        %w[xAxis yAxis].each do |ax|
          next unless e[ax]
          marks = e.dig(ax, 'format', 'marks')
          warns << "[#{pg['name']}] '#{e['name']}' #{ax} gridlines not disabled (format.marks != none)." unless marks == 'none'
        end
        # #7: a chart must not be a table carrying dataBars.
        errors << "[#{pg['name']}] chart '#{e['name']}' has dataBars — a bar chart must be a bar-chart element, not a table." if e['conditionalFormats']
        color = e['color']
        if color.is_a?(Hash) && color['by'] == 'category'
          color_id = color['column'] || color['columnId']
          color_column = Array(e['columns']).find { |column| column['id'] == color_id }
          if color_column && color_column['formula'].to_s.match?(QA_AGGREGATE_FORMULA)
            errors << "[#{pg['name']}] chart '#{e['name']}' uses aggregate " \
                      "'#{color_column['name'] || color_id}' as a category color. This can create " \
                      'one series per numeric result and overload the browser; classify it as a ' \
                      'measure or omit the color channel.'
          end
        end
      when 'table'
        # #5: dimension (non-aggregated) columns should allow text wrap.
        dim_cols = (e['columns'] || []).reject { |c| c['formula'].to_s =~ /\A\s*(Sum|Avg|Count|CountDistinct|Min|Max)\s*\(/i }
        unwrapped = dim_cols.reject { |c| c.dig('style', 'textWrap') }
        warns << "[#{pg['name']}] table '#{e['name']}' has #{unwrapped.size} text column(s) without textWrap:wrap." unless unwrapped.empty?
      end
    end

    scope_by_id = Array(scope && scope['controls']).each_with_object({}) do |entry, out|
      out[entry['controlId']] = entry if entry.is_a?(Hash) && entry['controlId']
    end
    # Page controls fan out through master/every chart. A source-declared narrow
    # scope is valid when control-scope.json explicitly names the card-local
    # target; the shared control lint verifies transitive reach after assembly.
    controls.each do |c|
      targets = Array(c['filters']).map { |fl| fl.dig('source', 'elementId') }
      to_master = targets.include?('master')
      covers_all = charts.any? && (charts.map { |ch| ch['id'] } - targets).empty?
      declared_scope = scope_by_id.dig(c['controlId'], 'scope')
      narrow = declared_scope.is_a?(Array) && !declared_scope.empty?
      unless to_master || covers_all || narrow
        errors << "[#{pg['name']}] control '#{c['name']}' targets #{targets.inspect} — bind to 'master' (or every element) so the filter reaches all elements."
      end
    end
  end
  [errors, warns]
end

if $PROGRAM_NAME == __FILE__
  opts = {}
  OptionParser.new { |o| o.on('--in PATH') { |v| opts[:in] = v } }.parse!(ARGV)
  discovery_dir = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)
  path = opts[:in] || File.join(discovery_dir, 'chart-specs.json')
  spec = JSON.parse(File.read(path))
  run_root = ENV['DOMO_RUN_DIR'] || File.dirname(File.dirname(path))
  scope_path = File.join(run_root, 'control-scope.json')
  scope = JSON.parse(File.read(scope_path)) rescue nil
  errors, warns = check(spec, scope: scope)
  audit_path = File.join(File.dirname(path), 'filter-type-audit.json')
  if File.exist?(audit_path)
    audit_errors, audit_warns = check_filter_type_audit(JSON.parse(File.read(audit_path)))
    errors.concat(audit_errors)
    warns.concat(audit_warns)
  end
  warns.each  { |w| warn "  ⚠ #{w}" }
  errors.each { |e| warn "  ✗ #{e}" }
  if errors.empty?
    warn "\n  QA PASS#{warns.empty? ? '' : " (#{warns.size} warning(s))"}"
    exit 0
  else
    warn "\n  QA FAIL — #{errors.size} hard violation(s)"
    exit 1
  end
end
