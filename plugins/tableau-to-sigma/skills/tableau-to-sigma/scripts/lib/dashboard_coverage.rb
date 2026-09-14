# frozen_string_literal: true

require 'digest'
require 'json'
require_relative 'twb_xml'
require_relative 'workbook_code'

module DashboardCoverage
  module_function

  def source_dashboards(twb_path)
    xml = File.read(twb_path, encoding: 'bom|utf-8')
    doc = TwbXml.parse(xml)
    dashboards = []
    doc.elements.each('/workbook/dashboards/dashboard') do |dashboard|
      name = dashboard.attributes['name'].to_s
      next if name.empty?
      # A truly empty dashboard is migration debris, not a rendered tab.
      next if dashboard.elements.to_a('.//zone').empty?
      dashboards << name
    end
    visible_windows = []
    doc.elements.each('/workbook/windows/window') do |window|
      next unless window.attributes['class'].to_s == 'dashboard'
      next if window.attributes['hidden'].to_s.casecmp?('true')
      name = window.attributes['name'].to_s
      visible_windows << name unless name.empty?
    end
    visible = if visible_windows.empty?
                dashboards
              else
                dashboards.select { |name| visible_windows.any? { |visible_name| visible_name.casecmp?(name) } }
              end
    [visible.uniq, Digest::SHA256.hexdigest(xml)]
  rescue TwbXml::ParseError => e
    raise ArgumentError, "source TWB parse failed: #{e.message}"
  end

  def evaluate(twb_path:, spec_path:, scope:)
    visible, source_sha = source_dashboards(twb_path)
    spec_raw = File.binread(spec_path)
    spec = JSON.parse(spec_raw)
    built_pages = WorkbookCode.pages(spec).map { |page| page['name'].to_s }
    built_pages.reject! { |name| name.empty? || name.casecmp?('Data') }

    scope = {} unless scope.is_a?(Hash)
    mode = scope['mode'].to_s.empty? ? 'full' : scope['mode'].to_s
    requested = Array(scope['dashboards']).map(&:to_s).reject(&:empty?).uniq
    provenance = scope['provenance'].to_s
    blockers = []
    if mode == 'selected' && !%w[stated cli].include?(provenance)
      blockers << {
        'kind' => 'unstated-scope',
        'reason' => "selected dashboard scope has provenance #{provenance.inspect}, not stated/cli"
      }
    end

    expected =
      if mode == 'selected'
        requested.each_with_object([]) do |asked, selected|
          match = visible.find { |name| name.casecmp?(asked) }
          unless match
            blockers << {
              'kind' => 'scope-mismatch', 'dashboard' => asked,
              'reason' => 'selected dashboard is not a visible source dashboard'
            }
          end
          selected << match if match
        end
      else
        visible
      end
    missing = expected.reject { |name| built_pages.any? { |built| built.casecmp?(name) } }
    missing.each do |name|
      blockers << {
        'kind' => 'missing-dashboard', 'dashboard' => name,
        'reason' => 'visible in Tableau and in stated scope, but no Sigma workbook page was built'
      }
    end

    {
      'schema_version' => 1,
      'status' => blockers.empty? ? 'pass' : 'fail',
      'mode' => mode,
      'provenance' => provenance.empty? ? (mode == 'full' ? 'full-workbook' : '') : provenance,
      'visible_source_dashboards' => visible,
      'expected_dashboards' => expected,
      'built_pages' => built_pages,
      'scope_excluded_dashboards' => visible - expected,
      'missing_dashboards' => missing,
      'blockers' => blockers,
      'source_sha256' => source_sha,
      'page_names_sha256' => Digest::SHA256.hexdigest(JSON.generate(built_pages))
    }
  end
end
