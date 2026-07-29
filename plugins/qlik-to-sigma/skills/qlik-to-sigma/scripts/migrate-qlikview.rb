#!/usr/bin/env ruby
# frozen_string_literal: true
#
# migrate-qlikview.rb — QlikView (.qvw) → Sigma data model, via the "-prj" folder.
#
# QlikView .qvw binaries have no parser and QlikView has no Cloud/REST API, so the
# Qlik Sense pipeline (migrate-qlik.rb — discovery, sheets, chart rebuild, engine
# snapshot, Qlik-vs-warehouse parity) does NOT apply. The developer-opt-in project
# folder is the migration surface: enable "Create project folder" in QlikView
# Desktop and pass the resulting <name>-prj/ folder here.
#
# This runs the LOCAL vendored converter (converter/qlik.mjs :: convertQvwPrjToSigma)
# — no MCP, no network for the conversion, no data egress — over LoadScript.txt
# (tables/fields incl. AS renames) + CH*.xml (expression measures), producing a
# directly-POST-able Sigma data-model spec. It then POSTs the model and reads the
# columns back to confirm none resolved to an error type.
#
# What QlikView delivers vs. Qlik Sense (be honest about scope):
#   • Data model — tables, fields, relationships (by SHARED FIELD NAME only; a -prj
#     folder carries no row counts, so join directions should be reviewed), and the
#     translated expression measures (Set Analysis / Range / Dual / Class, etc.).
#   • NO sheet/chart fidelity and NO Qlik-side parity — there are no sheets or a live
#     engine to read. Build the workbook on top of the model with the sigma-workbooks
#     skill or in the Sigma UI.
#
# Usage:
#   ruby scripts/migrate-qlikview.rb \
#     --prj <path/to/Name-prj> --connection <SIGMA_CONNECTION_ID> \
#     [--database DB] [--schema SCHEMA] [--folder <SIGMA_FOLDER_ID>] \
#     [--name '<prefix for the DM name>'] [--out DIR] [--dry-run]
#
# Env: SIGMA_BASE_URL, SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET (see scripts/vendor/get-token.sh).
#
# Exit codes: 0 = model built, 0 error columns; 3 = model built but has error-typed
# columns (fidelity issue — inspect the listed columns); other = error.

require 'json'
require 'optparse'
require 'fileutils'
require 'open3'

HERE = __dir__
VENDORED_QLIK = File.expand_path('../converter/qlik.mjs', __dir__)

opts = { database: 'DEMO_DB', schema: 'DEMO' }
OptionParser.new do |o|
  o.banner = 'Usage: migrate-qlikview.rb --prj DIR --connection ID [options]'
  o.on('--prj DIR')       { |v| opts[:prj]      = File.expand_path(v) }
  o.on('--connection ID') { |v| opts[:conn]     = v }
  o.on('--database DB')   { |v| opts[:database] = v }
  o.on('--schema S')      { |v| opts[:schema]   = v }
  o.on('--folder ID')     { |v| opts[:folder]   = v }
  o.on('--name PREFIX')   { |v| opts[:name]     = v }
  o.on('--out DIR')       { |v| opts[:out]      = File.expand_path(v) }
  o.on('--dry-run')       {     opts[:dry_run]  = true }
end.parse!

abort 'FATAL: missing --prj DIR (the QlikView <name>-prj project folder)' unless opts[:prj]
abort "FATAL: --prj dir not found: #{opts[:prj]}" unless File.directory?(opts[:prj])
abort 'FATAL: missing --connection <SIGMA_CONNECTION_ID>' unless opts[:conn] || opts[:dry_run]

# ── Converter resolution ─────────────────────────────────────────────────────
# The pinned VENDORED bundle is the DEFAULT so a dev machine and a customer machine
# convert identically. A local sigma-data-model-mcp build is used ONLY when
# EXPLICITLY opted in via QLIK_MCP_DIR (no silent ~/… auto-discovery).
mcp_dir  = ENV['QLIK_MCP_DIR']
dev_build = (mcp_dir && File.exist?(File.join(mcp_dir, 'build', 'qlik.js'))) ? File.join(mcp_dir, 'build', 'qlik.js') : nil
conv_module = dev_build || (File.exist?(VENDORED_QLIK) ? VENDORED_QLIK : nil)
abort "FATAL: no Qlik converter available (vendored #{VENDORED_QLIK} missing and no QLIK_MCP_DIR build)" unless conv_module
if conv_module == VENDORED_QLIK
  prov = File.join(File.dirname(VENDORED_QLIK), 'PROVENANCE.json')
  commit = (JSON.parse(File.read(prov))['source_commit'] rescue nil)
  warn "converter: VENDORED #{File.basename(VENDORED_QLIK)}#{commit ? " (pinned #{commit})" : ''} — no data egress"
else
  warn "converter: DEV BUILD #{conv_module} (explicit opt-in via QLIK_MCP_DIR)"
end

# ── Gather the -prj folder ───────────────────────────────────────────────────
prj_files = Dir[File.join(opts[:prj], '**', '*')].select do |f|
  File.file?(f) && File.basename(f) =~ /\A(LoadScript\.txt|.+\.qvs|CH.*\.xml)\z/i
end
if prj_files.empty?
  abort "FATAL: no LoadScript.txt / *.qvs / CH*.xml found under #{opts[:prj]}\n" \
        '       Enable "Create project folder" in QlikView Desktop and pass the full <name>-prj/ folder.'
end
payload = prj_files.sort.map { |f| { 'name' => File.basename(f), 'content' => File.read(f) } }

name_slug = File.basename(opts[:prj]).sub(/-prj\z/i, '').gsub(/[^A-Za-z0-9_-]/, '-')
name_slug = 'qlikview-app' if name_slug.empty?
work = opts[:out] || File.expand_path("~/qlik-migration/#{name_slug}")
FileUtils.mkdir_p(work)
prj_json = File.join(work, 'prj-files.json')
File.write(prj_json, JSON.pretty_generate(payload))
puts "── QlikView -prj → Sigma ──"
puts "   -prj folder: #{payload.size} file(s) (#{payload.map { |x| x['name'] }.join(', ')})"

# ── Convert (local vendored bundle, via a node shim) ─────────────────────────
conv_out_path = File.join(work, 'converter-out.json')
# Node ESM on Windows rejects a bare drive-letter specifier (protocol 'c:'); make it
# a file:// URL there and leave the working POSIX path byte-identical.
import_specifier =
  if Gem.win_platform? && conv_module.to_s.match?(/\A[A-Za-z]:/)
    'file:///' + conv_module.gsub('\\', '/')
  else
    conv_module
  end
shim = File.join(work, '_convert-qvw.mjs')
File.write(shim, <<~JS)
  import { readFileSync, writeFileSync } from 'node:fs';
  import { convertQvwPrjToSigma } from #{import_specifier.to_json};
  const files = JSON.parse(readFileSync(#{prj_json.to_json}, 'utf8'));
  const result = convertQvwPrjToSigma(files, {
    connectionId: #{(opts[:conn] || '').to_json},
    database: #{opts[:database].to_json},
    schema: #{opts[:schema].to_json},
  });
  writeFileSync(#{conv_out_path.to_json}, JSON.stringify(result, null, 2));
JS
_out, c_err, c_st = Open3.capture3('node', shim)
abort "FATAL: converter failed:\n#{c_err}" unless c_st.success?

result = JSON.parse(File.read(conv_out_path))
model  = result['model'] or abort 'FATAL: converter returned no model'
stats  = result['stats'] || {}
warns  = result['warnings'] || []
puts "   converted: #{stats['elements']} element(s), #{stats['columns']} column(s), " \
     "#{stats['metrics']} metric(s), #{stats['relationships']} relationship(s); #{warns.size} warning(s)"
warns.each { |w| puts "     ⚠ #{w}" }

if opts[:dry_run]
  spec_out = File.join(work, 'dm-spec.json')
  File.write(spec_out, JSON.pretty_generate(model))
  puts "   --dry-run: no POST. Spec written to #{spec_out}"
  exit 0
end

# ── POST the data model + read columns back ──────────────────────────────────
$LOAD_PATH.unshift File.expand_path('lib', HERE)
require 'sigma_rest'

body = model.merge('name' => (opts[:name] ? "#{opts[:name]} #{name_slug}" : name_slug))
body['folderId'] = opts[:folder] if opts[:folder]
res = Sigma.request(:post, '/v2/dataModels/spec', body: JSON.generate(body))
dm_id = res.is_a?(Hash) ? (res['dataModelId'] || res['id']) : nil
# /v2/dataModels/spec can return YAML; fall back to a light scan for the id.
dm_id ||= (res.to_s[/dataModelId:\s*([0-9a-f-]{36})/, 1])
abort "FATAL: DM POST returned no id: #{res.to_s[0, 300]}" unless dm_id
puts "   ✓ data model POSTed: #{dm_id}"

cols = (Sigma.request(:get, "/v2/dataModels/#{dm_id}/columns")['entries'] rescue []) || []
error_cols = cols.select { |c| (t = c['type']).is_a?(Hash) && t['type'] == 'error' }
if error_cols.empty?
  puts "   ✓ column resolution: #{cols.size} column(s), 0 error-typed ✓"
  puts
  puts "NEXT: build a workbook on data model #{dm_id} with the sigma-workbooks skill or in the Sigma UI"
  puts "      (a QlikView -prj folder has no sheets to rebuild)."
  exit 0
else
  puts "   ⚠ column resolution: #{error_cols.size}/#{cols.size} column(s) resolved to an ERROR type:"
  error_cols.first(20).each { |c| puts "       - #{c['name'] || c['columnId']}" }
  puts "   Data model #{dm_id} was created but has unresolved columns — inspect the formulas above."
  exit 3
end
