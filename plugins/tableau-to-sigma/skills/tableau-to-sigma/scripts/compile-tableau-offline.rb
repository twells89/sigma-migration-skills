#!/usr/bin/env ruby
# frozen_string_literal: true

# Creds-free, write-free Tableau workbook compiler. It stages a corpus/source
# fixture into a workdir and runs the same parser, lowering planner, chart
# builder, workbook assembler, and layout builder used by the live orchestrator.

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'pathname'
require 'rbconfig'
require 'tmpdir'
require_relative 'lib/layout_apply'
require_relative 'lib/workbook_code'
require_relative 'lib/workbook_ir'
require_relative 'mechanical-specs'

options = { keep: false }
parser = OptionParser.new do |opts|
  opts.banner = 'usage: compile-tableau-offline.rb --case-dir DIR [--workdir DIR] [--compare GOLDEN]'
  opts.on('--case-dir DIR') { |v| options[:case_dir] = v }
  opts.on('--workdir DIR') { |v| options[:workdir] = v }
  opts.on('--out PATH', 'Final canonical workbook path') { |v| options[:out] = v }
  opts.on('--compare PATH', 'Byte-compare final workbook with golden') { |v| options[:compare] = v }
  opts.on('--record PATH', 'Write/rewrite a reviewed golden path') { |v| options[:record] = v }
  opts.on('--keep', 'Keep an auto-created temporary workdir') { options[:keep] = true }
end
parser.parse!
abort parser.to_s unless options[:case_dir]

case_dir = Pathname(options[:case_dir]).expand_path
abort "case directory not found: #{case_dir}" unless case_dir.directory?
config_path = case_dir.join('compiler-case.json')
config = config_path.file? ? JSON.parse(config_path.read(encoding: 'UTF-8')) : {}
required_inputs = %w[workbook-content.twb get-workbook.json master-columns.json]
missing = required_inputs.reject { |name| case_dir.join(name).file? }
abort "offline case missing: #{missing.join(', ')}" unless missing.empty?

auto_workdir = options[:workdir].nil?
workdir = Pathname(options[:workdir] || Dir.mktmpdir('tableau-offline-compile')).expand_path
FileUtils.mkdir_p(workdir)
required_inputs.each { |name| FileUtils.cp(case_dir.join(name), workdir.join(name)) }
if case_dir.join('views').directory?
  FileUtils.rm_rf(workdir.join('views'))
  FileUtils.cp_r(case_dir.join('views'), workdir.join('views'))
end

begin
HERE = Pathname(__dir__).freeze
RUBY = RbConfig.ruby

def run!(*command, env: {})
  stdout, stderr, status = Open3.capture3(env, *command)
  $stdout.write(stdout)
  $stderr.write(stderr)
  raise "command failed (#{status.exitstatus}): #{command.join(' ')}" unless status.success?
end

layout = workdir.join('dashboard-layout.json')
ir_path = workdir.join('workbook-ir.json')
compile_plan = workdir.join('workbook-compile-plan.json')
charts = workdir.join('chart-specs.json')
wb_spec_path = workdir.join('wb-spec.json')
wb_ids_path = workdir.join('wb-ids.json')
layout_xml = workdir.join('layout.xml')
internal_final_path = workdir.join('workbook.json')
final_path = Pathname(options[:out] || internal_final_path).expand_path

run!(RUBY, HERE.join('parse-twb-layout.rb').to_s, workdir.join('workbook-content.twb').to_s, layout.to_s)
run!(RUBY, HERE.join('emit-workbook-ir.rb').to_s, '--workdir', workdir.to_s, '--out', ir_path.to_s)
run!(RUBY, HERE.join('compile-workbook-ir.rb').to_s, '--ir', ir_path.to_s, '--out', compile_plan.to_s, '--strict')

chart_command = [
  RUBY, HERE.join('build-charts-from-signals.rb').to_s,
  '--ir', ir_path.to_s,
  '--master-element-id', 'master',
  '--skip-dashboard-read', 'offline synthetic corpus fixture',
  '--out', charts.to_s
]
page_mode = config.fetch('page_mode', 'page-per-dashboard')
chart_command << (page_mode == 'page-per-worksheet' ? '--page-per-worksheet' : '--page-per-dashboard')
chart_command.concat(['--title', config['title']]) if config['title']
run!(
  *chart_command,
  env: {
    'TABLEAU_TO_SIGMA_HOME' => workdir.join('.tableau-to-sigma').to_s,
    'SIGMA_SHADOW_COMPILE' => '1'
  }
)
run!(RUBY, HERE.join('compile-workbook-ir.rb').to_s, '--ir', ir_path.to_s, '--out', compile_plan.to_s, '--strict')

master_map = JSON.parse(workdir.join('master-columns.json').read(encoding: 'UTF-8'))
master_columns = master_map.values.select { |entry| entry.is_a?(Hash) }.uniq { |entry| entry['id'] }.map do |entry|
  name = entry.fetch('name')
  {
    'id' => entry.fetch('id'),
    'name' => name,
    'formula' => "[Offline Fact/#{name}]"
  }
end
abort 'master-columns.json produced no deterministic master columns' if master_columns.empty?

chart_document = JSON.parse(charts.read(encoding: 'UTF-8'))
grand_total_pivots = Array(config['pivot_grand_totals'])
unless grand_total_pivots.empty?
  chart_pages_for_totals = chart_document.is_a?(Hash) ? Array(chart_document['pages']) : []
  chart_pages_for_totals.flat_map { |page| Array(page['elements']) }.each do |element|
    next unless element['kind'] == 'pivot-table' && grand_total_pivots.include?(element['name'])
    # Absence uses Sigma's native grand-total behavior. The explicit "hidden"
    # shape is only correct when the source disables totals.
    element.delete('totals')
  end
end
chart_pages = chart_document.is_a?(Hash) && chart_document['pages'] ? chart_document['pages'] : chart_document
data_elements = chart_document.is_a?(Hash) ? Array(chart_document['data_elements']) : []
theme = chart_document.is_a?(Hash) ? chart_document['theme'] : nil
workbook = MechanicalSpecs.build_wb_spec(
  name: config.fetch('workbook_name', case_dir.basename.to_s),
  dm_id: 'offline-data-model',
  fact_eid: 'offline-fact',
  master_columns: master_columns,
  chart_elements: chart_pages,
  data_elements: data_elements,
  theme: theme,
  folder_id: 'offline-folder',
  canonical: true
)
errors = WorkbookCode.validate(workbook)
abort "offline workbook assembly invalid: #{errors.join('; ')}" unless errors.empty?
wb_spec_path.write("#{JSON.pretty_generate(workbook)}\n")
wb_ids_path.write("#{JSON.pretty_generate(workbook)}\n")

WorkbookIR.emit(
  workdir,
  out: ir_path,
  overrides: {
    'workbook_spec' => wb_spec_path.to_s,
    'workbook_ids' => wb_ids_path.to_s,
    'compile_plan' => compile_plan.to_s,
    'chart_specs' => charts.to_s
  }
)
run!(RUBY, HERE.join('build-dashboard-layout.rb').to_s, '--ir', ir_path.to_s, '--out', layout_xml.to_s)

final = LayoutApply.apply(
  workbook,
  layout_xml: layout_xml.read(encoding: 'UTF-8'),
  elements_sidecar: "#{layout_xml}.elements.json",
  prune_sidecar: "#{layout_xml}.prune-elements.json"
)
final_errors = WorkbookCode.validate(final)
abort "offline final workbook invalid: #{final_errors.join('; ')}" unless final_errors.empty?
internal_final_path.write("#{JSON.pretty_generate(final)}\n")
WorkbookIR.emit(
  workdir,
  out: ir_path,
  overrides: {
    'workbook_spec' => internal_final_path.to_s,
    'workbook_ids' => wb_ids_path.to_s,
    'compile_plan' => compile_plan.to_s,
    'chart_specs' => charts.to_s,
    'layout_xml' => layout_xml.to_s
  }
)
unless final_path == internal_final_path
  FileUtils.mkdir_p(final_path.dirname)
  FileUtils.cp(internal_final_path, final_path)
end

report = {
  'schema_version' => 1,
  'mode' => 'offline-shadow',
  'source_case' => case_dir.basename.to_s,
  'candidate_sha256' => Digest::SHA256.file(internal_final_path).hexdigest,
  'pages' => WorkbookCode.pages(final).length,
  'elements' => WorkbookCode.elements(final).length,
  'sigma_writes' => 0,
  'tableau_writes' => 0,
  'post_complete' => false,
  'parity_complete' => false
}

if options[:record]
  record_path = Pathname(options[:record]).expand_path
  FileUtils.mkdir_p(record_path.dirname)
  FileUtils.cp(internal_final_path, record_path)
  report['recorded'] = record_path.to_s
end

if options[:compare]
  baseline = Pathname(options[:compare]).expand_path
  abort "baseline not found: #{baseline}" unless baseline.file?
  report['baseline_sha256'] = Digest::SHA256.file(baseline).hexdigest
  report['identical'] = File.binread(baseline) == File.binread(internal_final_path)
end
WorkbookIR.atomic_json(workdir.join('offline-compile.json'), report)

puts "OFFLINE COMPILE: #{final_path}"
puts "  pages: #{report['pages']}  elements: #{report['elements']}"
puts '  sigma_writes: 0  tableau_writes: 0'
puts "  compare: #{report['identical'] ? 'IDENTICAL' : 'DRIFT'}" if report.key?('identical')

exit 2 if report.key?('identical') && !report['identical']
ensure
  FileUtils.remove_entry(workdir) if auto_workdir && !options[:keep] && workdir&.directory?
end
