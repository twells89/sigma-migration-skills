#!/usr/bin/env ruby
# Compose <out>/readout.md from inventory.json, complexity.json, shortlist.json.
#
# Adapted from powerbi-assessment/scripts/render-readout.rb — the section_block /
# md_table / md_cell helpers are reused verbatim (vendor-agnostic); the gather-
# and-fill body is QuickSight-specific (analysis visual mix, calc-field buckets,
# dataset source types, no license/cost section).
#
# Usage:  ruby scripts/render-readout.rb --out /tmp/qs-assessment-<acct>

require 'json'
require 'optparse'

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

shortlist_analyses = shortlist ? (shortlist['analyses'] || []) : []
has_usage = shortlist && shortlist['usage_available'] == true
limited_mode = !has_usage
account = inventory['account'] || {}
enterprise = account['enterprise'] != false

# -------- helpers (verbatim from powerbi/tableau-assessment) -----------------
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
eo = inventory['environment_overview'] || {}
analyses = inventory['analyses'] || []
datasets = inventory['datasets'] || []

mode = has_usage ? 'Usage + complexity' : 'Complexity-only'

# Section 3 — analysis complexity
total_calc = { 'a' => 0, 'b' => 0, 'c' => 0 }
analysis_rows = complexity.values.sort_by { |r| -(r['n_unhandled'].to_i * 10 + r['n_manual'].to_i * 3) }.map do |r|
  d = r['calc_buckets'] || {}
  %w[a b c].each { |k| total_calc[k] += d[k].to_i }
  [r['name'], r['sheets'], r['visuals'], r['calc_field_count'], r['window_calc_count'],
   r['parameter_count'], "#{d['a'].to_i}/#{d['b'].to_i}/#{d['c'].to_i}"]
end
analyses_table = analysis_rows.empty? ? '_No analyses scanned (definition API unavailable?)._' :
  md_table(['Analysis', 'Sheets', 'Visuals', 'CalcFields', 'Window', 'Params', 'Calc a/b/c'], analysis_rows)

# Section 3b — visual-kind histogram (account-wide)
vk = Hash.new(0)
complexity.each_value { |r| (r['visual_kinds'] || {}).each { |k, n| vk[k] += n } }
visual_rows = vk.sort_by { |_, n| -n }.map { |k, n| [k, n] }
visuals_table = visual_rows.empty? ? '_No visuals parsed._' : md_table(['Visual type', 'Count'], visual_rows)

# Section 4 — datasets / source types
src = Hash.new(0)
datasets.each { |d| (d['physical_kinds'] || []).each { |k| src[k] += 1 } }
source_rows = src.sort_by { |_, n| -n }.map { |k, n| [k, n] }
source_table = source_rows.empty? ? '_No dataset physical sources parsed._' :
  md_table(['Physical source kind', 'Datasets'], source_rows)
n_rls = datasets.count { |d| d['rls_enabled'] }
n_custom_sql = datasets.count { |d| d['has_custom_sql'] }

# Section 6 — priority
usage_basis = has_usage ? 'by view count' : 'by complexity proxy'
usage_rows = shortlist_analyses.first(15).map do |r|
  [r['name'], r['sheets'], r['visuals'],
   has_usage ? (r['views'] || 0) : '—',
   has_usage ? (r['users'] || 0) : '—']
end
usage_table = usage_rows.empty? ? '_No analyses._' :
  md_table(['Analysis', 'Sheets', 'Visuals', 'Views', 'Users'], usage_rows)
n_cold = has_usage ? shortlist_analyses.count { |r| r['views'].to_i.zero? } : 0

# Section 7 — shortlist
value_basis = shortlist ? shortlist['value_basis'] : 'n/a'
shortlist_rows = shortlist_analyses.first(15).map do |r|
  tag_md = case r['tag']
           when 'migrate-first'   then '**migrate-first**'
           when 'needs-gap-scout' then '⚠️ needs-gap-scout'
           when 'retire'          then '🗑 retire'
           else r['tag'] end
  d = r['calc_buckets'] || {}
  [r['name'], has_usage ? (r['views'] || 0) : '—',
   "#{d['a'].to_i}/#{d['b'].to_i}/#{d['c'].to_i}",
   "#{r['auto']}/#{r['hint']}/#{r['manual']}/#{r['unhandled']}",
   format('%.1f', r['value']), format('%.2f', r['score']), tag_md]
end
shortlist_table = shortlist_rows.empty? ? '_No shortlist._' :
  md_table(['Analysis', 'Views', 'Calc a/b/c', 'Auto/Hint/Man/Unh', 'Value', 'Score', 'Tag'], shortlist_rows)
top5 = shortlist_analyses.first(5)
shortlist_top_n = top5.size
shortlist_total_unhandled = top5.sum { |r| r['unhandled'].to_i }
n_needs_scout = shortlist_analyses.count { |r| r['tag'] == 'needs-gap-scout' }
n_retire = shortlist_analyses.count { |r| r['tag'] == 'retire' }

# Section 8 — per-analysis complexity
crows = complexity.values.sort_by { |r| -(r['n_unhandled'].to_i * 10 + r['n_manual'].to_i * 3) }.map do |r|
  [r['name'], r['sheets'], r['visuals'], r['calc_field_count'], r['window_calc_count'],
   r['rls_role_count'], r['n_manual'], r['n_unhandled'].to_i.positive? ? "**#{r['n_unhandled']}**" : 0]
end
complexity_table = crows.empty? ? '_No complexity rows._' :
  md_table(['Analysis', 'Sheets', 'Visuals', 'CalcFields', 'Window', 'RLS', 'Manual', 'Unhandled'], crows)
total_unhandled = complexity.values.sum { |r| r['n_unhandled'].to_i }
n_with_unhandled = complexity.values.count { |r| r['n_unhandled'].to_i.positive? }
recommended_pilot_n = top5.size

# -------- apply --------------------------------------------------------------
out = tpl.dup
out = section_block(out, 'limited_mode_banner', limited_mode)
out = section_block(out, 'standard_edition_banner', !enterprise)
out = section_block(out, 'has_usage', has_usage)

repl = {
  '{{account_name}}'    => (account['account_id'] || File.basename(opts[:out]).sub(/^qs-assessment-/, '')).to_s,
  '{{region}}'          => account['region'].to_s,
  '{{edition}}'         => (account['edition'] || 'unknown').to_s,
  '{{mode}}'            => mode,
  '{{generated_at}}'    => account['generated_at'] || Time.now.strftime('%Y-%m-%d'),
  '{{analyses}}'        => eo['analyses'].to_s,
  '{{dashboards}}'      => eo['dashboards'].to_s,
  '{{datasets}}'        => eo['datasets'].to_s,
  '{{data_sources}}'    => eo['data_sources'].to_s,
  '{{analyses_table}}'  => analyses_table,
  '{{visuals_table}}'   => visuals_table,
  '{{total_calc_a}}'    => total_calc['a'].to_s,
  '{{total_calc_b}}'    => total_calc['b'].to_s,
  '{{total_calc_c}}'    => total_calc['c'].to_s,
  '{{source_table}}'    => source_table,
  '{{n_rls}}'           => n_rls.to_s,
  '{{n_custom_sql}}'    => n_custom_sql.to_s,
  '{{usage_basis}}'     => usage_basis,
  '{{usage_table}}'     => usage_table,
  '{{n_cold}}'          => n_cold.to_s,
  '{{value_basis}}'     => value_basis,
  '{{shortlist_table}}' => shortlist_table,
  '{{shortlist_top_n}}' => shortlist_top_n.to_s,
  '{{shortlist_total_unhandled}}' => shortlist_total_unhandled.to_s,
  '{{complexity_table}}' => complexity_table,
  '{{total_unhandled}}' => total_unhandled.to_s,
  '{{n_with_unhandled}}' => n_with_unhandled.to_s,
  '{{n_needs_scout}}'   => n_needs_scout.to_s,
  '{{n_retire}}'        => n_retire.to_s,
  '{{recommended_pilot_n}}' => recommended_pilot_n.to_s
}
repl.each { |k, v| out.gsub!(k, v.to_s) }

# Duplicate / consolidation candidates — append the shared detector's Markdown
# block when the inventory scan found overlapping analyses (flag-not-fake).
dup_doc = inventory['duplicate_dashboards']
dup_norm_path = File.join(opts[:out], 'dup-normalized.json')
if dup_doc && (dup_doc['summary'] || {})['duplicate_groups'].to_i.positive? && File.exist?(dup_norm_path)
  dd_script = File.join(__dir__, 'dup-dashboards.py')
  # --md writes the Markdown block to stderr (alongside a one-line summary, which
  # we drop). Capture stderr; discard stdout (the groups JSON, already on disk).
  md = `python3 #{dd_script.inspect} --in #{dup_norm_path.inspect} --out #{File.join(opts[:out], 'dup-groups.json').inspect} --md 2>&1 1>/dev/null`
  md = md.lines.reject { |l| l.start_with?('[dup-dashboards]') }.join
  out += "\n\n" + md unless md.strip.empty?
end

readout_path = File.join(opts[:out], 'readout.md')
File.write(readout_path, out)
puts "wrote #{readout_path}"
