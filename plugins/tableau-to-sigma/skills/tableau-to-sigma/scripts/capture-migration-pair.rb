#!/usr/bin/env ruby
# frozen_string_literal: true

# Capture a Tableau/Sigma migration pair using GET-only APIs. The output is
# sanitized for analysis, but remains local/confidential until separately
# reviewed and promoted into the corpus.

require 'fileutils'
require 'json'
require 'optparse'
require 'pathname'
require 'tempfile'
require 'time'
require_relative 'lib/migration_pair'
require_relative 'lib/zip_extract'

options = {
  include_twb: true,
  include_dashboard_pngs: false,
  normalize_ids: true
}

parser = OptionParser.new do |opts|
  opts.banner = 'usage: capture-migration-pair.rb --out DIR [--pair-ref FILE --pair-id ID | IDs]'
  opts.on('--out DIR', 'Capture directory (required)') { |v| options[:out] = v }
  opts.on('--pair-ref PATH', 'pair-discovery.json') { |v| options[:pair_ref] = v }
  opts.on('--pair-id ID', 'Pair id from discovery') { |v| options[:pair_id] = v }
  opts.on('--tableau-workbook-id ID') { |v| options[:tableau_id] = v }
  opts.on('--sigma-workbook-id ID') { |v| options[:sigma_id] = v }
  opts.on('--tableau-metadata PATH', 'Offline Tableau metadata JSON') { |v| options[:tableau_metadata] = v }
  opts.on('--tableau-twb PATH', 'Offline Tableau TWB/TWBX') { |v| options[:tableau_twb] = v }
  opts.on('--sigma-metadata PATH', 'Offline Sigma metadata JSON') { |v| options[:sigma_metadata] = v }
  opts.on('--sigma-spec PATH', 'Offline Sigma workbook spec JSON') { |v| options[:sigma_spec] = v }
  opts.on('--[no-]include-twb', 'Capture scrubbed TWB (default true)') { |v| options[:include_twb] = v }
  opts.on('--include-dashboard-pngs', 'Capture Tableau dashboard PNGs (confidential)') { options[:include_dashboard_pngs] = true }
  opts.on('--[no-]normalize-ids', 'Normalize API object ids (default true)') { |v| options[:normalize_ids] = v }
end
parser.parse!
abort parser.to_s unless options[:out]

if options[:pair_ref] || options[:pair_id]
  abort '--pair-ref and --pair-id must be used together' unless options[:pair_ref] && options[:pair_id]
  discovery = JSON.parse(File.read(options[:pair_ref]))
  pair = Array(discovery['pairs']).find { |entry| entry['pair_id'] == options[:pair_id] }
  abort "pair #{options[:pair_id].inspect} not found" unless pair
  abort "pair #{options[:pair_id]} is ambiguous; select explicit workbook ids" if pair['status'] == 'ambiguous'
  options[:tableau_id] ||= pair.dig('tableau', 'luid')
  options[:sigma_id] ||= pair.dig('sigma', 'workbook_id')
end

offline = options.values_at(:tableau_metadata, :sigma_metadata, :sigma_spec).any?
if offline
  missing = %i[tableau_metadata sigma_metadata sigma_spec].reject { |key| options[key] }
  abort "offline capture missing: #{missing.join(', ')}" unless missing.empty?
else
  abort 'live capture requires --tableau-workbook-id and --sigma-workbook-id' unless options[:tableau_id] && options[:sigma_id]
end

out = Pathname(options[:out]).expand_path
FileUtils.mkdir_p(out.join('tableau'))
FileUtils.mkdir_p(out.join('sigma', 'dm-specs'))
FileUtils.mkdir_p(out.join('sanitized'))

if offline
  tableau_metadata = JSON.parse(File.read(options[:tableau_metadata]))
  sigma_metadata = JSON.parse(File.read(options[:sigma_metadata]))
  sigma_spec = JSON.parse(File.read(options[:sigma_spec]))
else
  require_relative 'lib/tableau_rest'
  require_relative 'lib/sigma_rest'
  tableau_metadata = Tableau.get_workbook(options[:tableau_id])
  sigma_metadata = Sigma.request(:get, "/v2/workbooks/#{options[:sigma_id]}")
  sigma_spec = Sigma.request(:get, "/v2/workbooks/#{options[:sigma_id]}/spec")
end

def sanitized_json(document, normalize:)
  clean = MigrationPair.scrub_document(document)
  normalize ? MigrationPair.normalize_ids(clean) : clean
end

MigrationPair.atomic_json(
  out.join('tableau', 'get-workbook.json'),
  sanitized_json(tableau_metadata, normalize: options[:normalize_ids])
)
MigrationPair.atomic_json(
  out.join('sigma', 'workbook-meta.json'),
  sanitized_json(sigma_metadata, normalize: options[:normalize_ids])
)
clean_sigma_spec = sanitized_json(sigma_spec, normalize: options[:normalize_ids])
MigrationPair.atomic_json(out.join('sigma', 'workbook-spec.json'), clean_sigma_spec)

if options[:include_twb]
  twb_bytes = if options[:tableau_twb]
                File.binread(options[:tableau_twb])
              else
                Tableau.download_workbook_content(options[:tableau_id], include_extract: false)
              end
  twb_xml = if twb_bytes.start_with?("PK\x03\x04".b)
              Tempfile.create(['pair-capture', '.twbx']) do |temp|
                temp.binmode
                temp.write(twb_bytes)
                temp.flush
                member = ZipExtract.entries(temp.path).find { |name| name.downcase.end_with?('.twb') }
                abort 'downloaded TWBX contains no .twb member' unless member
                ZipExtract.read(temp.path, member)
              end
            else
              twb_bytes
            end
  out.join('tableau', 'workbook-content.twb').binwrite(MigrationPair.scrub_twb(twb_xml))
end

linked_dm_ids = []
walk_ids = lambda do |node|
  case node
  when Hash
    linked_dm_ids << node['dataModelId'] if node['dataModelId']
    node.each_value { |value| walk_ids.call(value) }
  when Array
    node.each { |value| walk_ids.call(value) }
  end
end
walk_ids.call(sigma_spec)
unless offline
  linked_dm_ids.compact.uniq.sort.each_with_index do |dm_id, index|
    dm_spec = Sigma.request(:get, "/v2/dataModels/#{dm_id}/spec")
    MigrationPair.atomic_json(
      out.join('sigma', 'dm-specs', format('dm-%03d.json', index + 1)),
      sanitized_json(dm_spec, normalize: options[:normalize_ids])
    )
  end
end

if options[:include_dashboard_pngs]
  abort '--include-dashboard-pngs is only available in live mode' if offline
  views_response = Tableau.request(:get, "#{Tableau.base_path}/workbooks/#{options[:tableau_id]}/views")
  views = views_response.dig('views', 'view') || []
  views = [views] if views.is_a?(Hash)
  FileUtils.mkdir_p(out.join('tableau', 'dashboards'))
  views.sort_by { |view| [view['name'].to_s, view['id'].to_s] }.each_with_index do |view, index|
    safe_name = view['name'].to_s.gsub(/[^\w.-]+/, '_')
    filename = format('%03d-%s.png', index + 1, safe_name.empty? ? 'view' : safe_name)
    out.join('tableau', 'dashboards', filename).binwrite(Tableau.view_image(view['id']))
  end
end

artifacts = {}
Dir.glob(out.join('**', '*').to_s).sort.each do |path|
  next unless File.file?(path)
  relative = Pathname(path).relative_path_from(out).to_s
  next if relative == 'MANIFEST.json'
  artifacts[relative] = { 'sha256' => MigrationPair.sha256(path), 'bytes' => File.size(path) }
end

redaction_report = {
  'credentials_removed' => true,
  'ids_normalized' => options[:normalize_ids],
  'extract_included' => false,
  'view_csv_included' => false,
  'dashboard_pngs_included' => options[:include_dashboard_pngs],
  'review_required_before_commit' => true
}
MigrationPair.atomic_json(out.join('sanitized', 'redaction-report.json'), redaction_report)
artifacts['sanitized/redaction-report.json'] = {
  'sha256' => MigrationPair.sha256(out.join('sanitized', 'redaction-report.json')),
  'bytes' => File.size(out.join('sanitized', 'redaction-report.json'))
}

manifest = {
  'schema_version' => MigrationPair::SCHEMA_VERSION,
  'capture_mode' => 'read-only',
  'source' => offline ? 'offline-fixtures' : 'live-metadata',
  'captured_at' => Time.now.utc.iso8601,
  'tableau_workbook' => MigrationPair.normalize_ids(MigrationPair.compact_tableau(tableau_metadata)),
  'sigma_workbook' => MigrationPair.normalize_ids(MigrationPair.compact_sigma(sigma_metadata)),
  'redaction' => redaction_report,
  'hygiene_ready' => false,
  'artifacts' => artifacts.sort.to_h
}
MigrationPair.atomic_json(out.join('MANIFEST.json'), manifest)

puts 'PAIR CAPTURE: complete (read-only)'
puts "  output: #{out}"
puts "  files:  #{artifacts.length}"
puts '  hygiene_ready: false (review and neutralize before corpus promotion)'
