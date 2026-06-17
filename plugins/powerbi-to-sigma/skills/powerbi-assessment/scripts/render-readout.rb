#!/usr/bin/env ruby
# Compose <out>/readout.md from inventory.json, complexity.json, shortlist.json.
#
# Adapted from tableau-assessment/scripts/render-readout.rb — the Mustache-ish
# section_block / md_table / md_cell helpers are reused verbatim (vendor-
# agnostic); the gather-and-fill body is Power-BI-specific (semantic-model DAX
# complexity, warehouse sources from M, no license/cost section).
#
# Usage:  ruby scripts/render-readout.rb --out /tmp/pbi-assessment-<tenant>

require 'json'
require 'optparse'
require 'open3'

opts = {}
OptionParser.new do |p|
  p.on('--out DIR') { |v| opts[:out] = v }
  p.on('--template PATH') { |v| opts[:template] = v }
end.parse!
abort('--out required') unless opts[:out]

template_path = opts[:template] || File.expand_path('../refs/readout-template.md', __dir__)
tpl = File.read(template_path)

inventory  = JSON.parse(File.read(File.join(opts[:out], 'inventory.json')))
complexity_path = File.join(opts[:out], 'complexity.json')
shortlist_path  = File.join(opts[:out], 'shortlist.json')
complexity = File.exist?(complexity_path) ? JSON.parse(File.read(complexity_path)) : {}
shortlist  = File.exist?(shortlist_path)  ? JSON.parse(File.read(shortlist_path))  : nil

shortlist_reports = shortlist ? (shortlist['reports'] || []) : []
has_usage = shortlist && shortlist['usage_available'] == true
limited_mode = !has_usage

# -------- helpers (verbatim from tableau-assessment) -------------------------
def md_cell(v)
  v.to_s.gsub('|', '\\|')
end

def md_table(headers, rows)
  out = '| ' + headers.map { |h| md_cell(h) }.join(' | ') + " |\n"
  out += '|' + headers.map { '---' }.join('|') + "|\n"
  rows.each { |r| out += '| ' + r.map { |c| md_cell(c) }.join(' | ') + " |\n" }
  out
end

def section_block(tpl, key, keep)
  opposite_open = keep ? "{{^#{key}}}" : "{{##{key}}}"
  kept_open     = keep ? "{{##{key}}}" : "{{^#{key}}}"
  close         = "{{/#{key}}}"
  tpl = tpl.gsub(/#{Regexp.escape(opposite_open)}.*?#{Regexp.escape(close)}/m, '')
  tpl.gsub(/#{Regexp.escape(kept_open)}(.*?)#{Regexp.escape(close)}/m) { $1 }
end

# -------- gather -------------------------------------------------------------
tenant = inventory['tenant'] || {}
eo = inventory['environment_overview'] || {}
models = inventory['semantic_models'] || []
reports = inventory['reports'] || []

mode = if has_usage then 'Fabric Admin (usage + complexity)'
       else 'User-delegated (complexity-only)' end

# Section 2 — workspaces
ws_rows = (inventory['workspaces'] || []).map do |w|
  items = (w['item_type_counts'] || {}).map { |k, v| "#{k}:#{v}" }.join(', ')
  [w['name'], w['on_capacity'] ? '✓' : '—', items]
end
workspaces_table = ws_rows.empty? ? '_No workspaces visible._' :
  md_table(['Workspace', 'On capacity', 'Items'], ws_rows)

# Section 3 — model complexity
total_dax = { 'a' => 0, 'b' => 0, 'c' => 0 }
model_rows = models.map do |m|
  d = m['dax_buckets'] || {}
  %w[a b c].each { |k| total_dax[k] += d[k].to_i }
  [m['name'], m['workspace'], m['table_count'], m['measure_count'],
   m['calc_column_count'], m['calc_table_count'], m['rls_role_count'],
   m['directquery_tables'].to_i.positive? ? 'DQ' : 'import',
   "#{d['a'].to_i}/#{d['b'].to_i}/#{d['c'].to_i}"]
end
models_table = model_rows.empty? ? '_No semantic models scanned._' :
  md_table(['Model', 'Workspace', 'Tables', 'Measures', 'CalcCols', 'CalcTbls',
            'RLS', 'Mode', 'DAX a/b/c'], model_rows)

# Section 4 — warehouse sources
wh = Hash.new(0)
models.each { |m| (m['warehouse_sources'] || []).each { |s| wh[s] += 1 } }
warehouse_table = wh.empty? ? '_No warehouse sources parsed from M (models may be pure-import with no live source)._' :
  md_table(['Warehouse source (from M)', 'Models'], wh.sort_by { |_, n| -n })

# Section 5 — refresh
refresh_rows = []
models.each do |m|
  rh = m['refresh_history']
  next if rh.nil? || rh.empty?
  last = rh.first
  refresh_rows << [m['name'], last['status'], last['refreshType'], last['startTime']]
end
refresh_table =
  if !tenant['refresh_history_available']
    '_Refresh history unavailable — Power BI REST token not acquired._'
  elsif refresh_rows.empty?
    '_No refresh history rows (models may be DirectQuery or never refreshed)._'
  else
    md_table(['Model', 'Last status', 'Type', 'Started'], refresh_rows)
  end
refresh_notes = ''

# Section 6 — report usage / priority
usage_basis = has_usage ? 'by view count' : 'by complexity proxy'
n_cold = 0
usage_rows = shortlist_reports.first(15).map do |r|
  [r['name'], r['workspace'], r['pages'], r['visuals'],
   has_usage ? (r['views'] || 0) : '—',
   has_usage ? (r['users'] || 0) : '—']
end
usage_table = usage_rows.empty? ? '_No reports._' :
  md_table(['Report', 'Workspace', 'Pages', 'Visuals', 'Views', 'Users'], usage_rows)
n_cold = shortlist_reports.count { |r| has_usage && r['views'].to_i.zero? } if has_usage

# Section 7 — shortlist
value_basis = shortlist ? shortlist['value_basis'] : 'n/a'
shortlist_rows = shortlist_reports.first(15).map do |r|
  tag_md = case r['tag']
           when 'migrate-first'   then '**migrate-first**'
           when 'needs-gap-scout' then '⚠️ needs-gap-scout'
           when 'retire'          then '🗑 retire'
           else r['tag'] end
  d = r['dax_buckets'] || {}
  [r['name'], has_usage ? (r['views'] || 0) : '—',
   "#{d['a'].to_i}/#{d['b'].to_i}/#{d['c'].to_i}",
   "#{r['auto']}/#{r['hint']}/#{r['manual']}/#{r['unhandled']}",
   format('%.1f', r['value']), format('%.2f', r['score']), tag_md]
end
shortlist_table = shortlist_rows.empty? ? '_No shortlist._' :
  md_table(['Report', 'Views', 'DAX a/b/c', 'Auto/Hint/Man/Unh', 'Value', 'Score', 'Tag'], shortlist_rows)
top5 = shortlist_reports.first(5)
shortlist_top_n = top5.size
shortlist_total_unhandled = top5.sum { |r| r['unhandled'].to_i }
n_needs_scout = shortlist_reports.count { |r| r['tag'] == 'needs-gap-scout' }
n_retire = shortlist_reports.count { |r| r['tag'] == 'retire' }

# Section 8 — per-report complexity
crows = complexity.values.sort_by { |r| -(r['n_unhandled'].to_i * 10 + r['n_manual'].to_i * 3) }.map do |r|
  d = r['dax_buckets'] || {}
  [r['name'], r['pages'], r['visuals'], r['measure_count'], r['calc_table_count'],
   r['rls_role_count'], "#{d['a'].to_i}/#{d['b'].to_i}/#{d['c'].to_i}",
   r['n_manual'], r['n_unhandled'].to_i.positive? ? "**#{r['n_unhandled']}**" : 0]
end
complexity_table = crows.empty? ? '_No complexity rows._' :
  md_table(['Report', 'Pages', 'Visuals', 'Measures', 'CalcTbls', 'RLS', 'DAX a/b/c', 'Manual', 'Unhandled'], crows)
total_unhandled = complexity.values.sum { |r| r['n_unhandled'].to_i }
n_workbooks_with_unhandled = complexity.values.count { |r| r['n_unhandled'].to_i.positive? }
recommended_pilot_n = top5.size

# Duplicate / consolidation candidates — the detector result is computed by
# fabric-inventory.py and stored in inventory.json; render the Markdown block via
# the shared (Python) detector (--md-stdout prints the block to stdout). Degrade
# silently if absent or python3 missing.
dup_dashboards_md = ''
if inventory['duplicate_dashboards']
  dd_script = File.join(__dir__, 'dup-dashboards.py')
  if File.exist?(dd_script)
    begin
      md, status = Open3.capture2('python3', dd_script,
        '--render', '--md-stdout', '--in', File.join(opts[:out], 'inventory.json'))
      dup_dashboards_md = md.strip if status.success? && !md.to_s.strip.empty?
    rescue StandardError
      dup_dashboards_md = ''
    end
  end
end

# -------- apply --------------------------------------------------------------
out = tpl.dup
out = section_block(out, 'limited_mode_banner', limited_mode)
out = section_block(out, 'has_usage', has_usage)

repl = {
  '{{tenant_name}}'   => File.basename(opts[:out]).sub(/^pbi-assessment-/, ''),
  '{{mode}}'          => mode,
  '{{generated_at}}'  => tenant['generated_at'] || Time.now.strftime('%Y-%m-%d'),
  '{{workspaces}}'    => eo['workspaces'].to_s,
  '{{on_capacity}}'   => eo['on_capacity_workspaces'].to_s,
  '{{semantic_models}}' => eo['semantic_models'].to_s,
  '{{reports}}'       => eo['reports'].to_s,
  '{{dashboards}}'    => eo['dashboards'].to_s,
  '{{dataflows}}'     => eo['dataflows'].to_s,
  '{{lakehouses}}'    => eo['lakehouses'].to_s,
  '{{warehouses}}'    => eo['warehouses'].to_s,
  '{{notebooks}}'     => eo['notebooks'].to_s,
  '{{other_items}}'   => eo['other_items'].to_s,
  '{{workspaces_table}}' => workspaces_table,
  '{{models_table}}'  => models_table,
  '{{total_dax_a}}'   => total_dax['a'].to_s,
  '{{total_dax_b}}'   => total_dax['b'].to_s,
  '{{total_dax_c}}'   => total_dax['c'].to_s,
  '{{warehouse_table}}' => warehouse_table,
  '{{refresh_table}}' => refresh_table,
  '{{refresh_notes}}' => refresh_notes,
  '{{usage_basis}}'   => usage_basis,
  '{{usage_table}}'   => usage_table,
  '{{n_cold}}'        => n_cold.to_s,
  '{{value_basis}}'   => value_basis,
  '{{shortlist_table}}' => shortlist_table,
  '{{shortlist_top_n}}' => shortlist_top_n.to_s,
  '{{shortlist_total_unhandled}}' => shortlist_total_unhandled.to_s,
  '{{complexity_table}}' => complexity_table,
  '{{total_unhandled}}' => total_unhandled.to_s,
  '{{n_workbooks_with_unhandled}}' => n_workbooks_with_unhandled.to_s,
  '{{n_needs_scout}}' => n_needs_scout.to_s,
  '{{n_retire}}'      => n_retire.to_s,
  '{{recommended_pilot_n}}' => recommended_pilot_n.to_s,
  '{{dup_dashboards}}' => (dup_dashboards_md.empty? ? '### Duplicate / consolidation candidates' + "\n\n_Consolidation scan not available (older inventory)._" : dup_dashboards_md)
}
repl.each { |k, v| out.gsub!(k, v.to_s) }

readout_path = File.join(opts[:out], 'readout.md')
File.write(readout_path, out)
puts "wrote #{readout_path}"
