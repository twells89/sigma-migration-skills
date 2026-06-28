#!/usr/bin/env ruby
# Compose <out>/readout.md from inventory.json, complexity.json, shortlist.json.
#
# Usage:
#   ruby scripts/render-readout.rb --out /tmp/assessment-<site>
#
# Uses refs/readout-template.md (Mustache-ish tag syntax) but does its own
# replacement so we don't pull in a templating dep.

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

inv_path        = File.join(opts[:out], 'inventory.json')
complexity_path = File.join(opts[:out], 'complexity.json')
shortlist_path  = File.join(opts[:out], 'shortlist.json')
consol_path     = File.join(opts[:out], 'consolidation-candidates.json')

inventory  = JSON.parse(File.read(inv_path))
complexity = File.exist?(complexity_path) ? JSON.parse(File.read(complexity_path)) : nil
shortlist  = File.exist?(shortlist_path)  ? JSON.parse(File.read(shortlist_path))  : nil
consolidation = File.exist?(consol_path)  ? JSON.parse(File.read(consol_path))     : nil

has_shortlist = !shortlist.nil? && !shortlist.empty?
has_consolidation = has_shortlist && !consolidation.nil? && !(consolidation['groups'] || []).empty?
limited_mode  = inventory['licenses'].nil? && inventory['refresh_jobs'].nil?

# -------- helpers ------------------------------------------------------------

def md_cell(v)
  # Escape pipes inside cell content — they'd otherwise split the column.
  v.to_s.gsub('|', '\\|')
end

def md_table(headers, rows)
  out = '| ' + headers.map { |h| md_cell(h) }.join(' | ') + " |\n"
  out += '|' + headers.map { '---' }.join('|') + "|\n"
  rows.each do |r|
    out += '| ' + r.map { |c| md_cell(c) }.join(' | ') + " |\n"
  end
  out
end

def section_block(tpl, key, keep)
  # Remove the OPPOSITE block first (including its body and both markers).
  # Then strip the KEPT block's markers, leaving its body in place.
  opposite_open = keep ? "{{^#{key}}}" : "{{##{key}}}"
  kept_open     = keep ? "{{##{key}}}" : "{{^#{key}}}"
  close         = "{{/#{key}}}"
  tpl = tpl.gsub(/#{Regexp.escape(opposite_open)}.*?#{Regexp.escape(close)}/m, '')
  tpl.gsub(/#{Regexp.escape(kept_open)}(.*?)#{Regexp.escape(close)}/m) { $1 }
end

# -------- gather replacement values ------------------------------------------

site = inventory['site'] || {}
env  = inventory['environment_overview'] || {}
vt   = inventory['view_type_breakdown'] || {}
ds   = inventory['datasource_types'] || {}

ds_published = ds.dig('summary', 'published_total') || 0
ds_embedded  = ds.dig('summary', 'embedded_total') || 0

# Section 2 — licenses
licenses_table = '_License data unavailable — Site Admin role required._'
pricing_rows = ''
has_pricing  = false
if inventory['licenses']
  rows = (inventory['licenses']['by_type'] || []).map do |b|
    [b['license'], b['site_role'], b['users'], format('%.1f', b['avg_days_since_login'] || 0)]
  end
  licenses_table = md_table(['License', 'Site Role', 'Users', 'Avg days since login'], rows)
  if inventory['licenses']['by_type'] && !inventory['licenses']['by_type'].empty?
    has_pricing = true
    pricing_rows = inventory['licenses']['by_type'].map do |b|
      # Placeholder list prices
      per_seat = { 'Creator' => 2100, 'Explorer' => 800, 'Viewer' => 240 }[b['license']] || 0
      sigma_seat = { 'Creator' => 1800, 'Explorer' => 600, 'Viewer' => 200 }[b['license']] || 0
      tab = per_seat * b['users']
      sig = sigma_seat * b['users']
      "| #{b['license']} | #{b['users']} | $#{tab} | $#{sig} | $#{tab - sig} |"
    end.join("\n")
  end
end

# Section 3 — ownership
ownership_table = '_Content ownership data unavailable._'
top_owner_pct = 0
top_owner_email = '—'
if inventory['content_ownership']
  rows = inventory['content_ownership'].sort_by { |o| -o['workbooks'].to_i }.map do |o|
    [o['owner'], o['workbooks'], o['datasources'], o['views'], o['flows']]
  end
  ownership_table = md_table(['Owner', 'Workbooks', 'Datasources', 'Views', 'Flows'], rows)
  total_wb = inventory['content_ownership'].sum { |o| o['workbooks'].to_i }
  if total_wb > 0
    top = inventory['content_ownership'].max_by { |o| o['workbooks'].to_i }
    top_owner_pct = (top['workbooks'].to_f / total_wb * 100).round
    top_owner_email = top['owner']
  end
end

# Section 4 — datasource patterns
ds_summary_table = '_Datasource-type data unavailable._'
n_published_extracts = ds.dig('summary', 'extract_total') || 0
n_embedded           = ds_embedded
if inventory['datasource_types']
  rows = []
  (ds['published_extract'] || []).each { |r| rows << ["Published — extract (#{r['db_type']})", r['n']] }
  (ds['published_live']    || []).each { |r| rows << ["Published — live (#{r['db_type']})", r['n']] }
  (ds['embedded']          || []).each { |r| rows << ["Embedded — #{r['db_type']}", r['n']] }
  ds_summary_table = md_table(['Bucket', 'Count'], rows)
end

# Section 5 — refresh
refresh_table = '_Refresh history unavailable._'
refresh_notes = ''
if inventory['refresh_jobs']
  rj = inventory['refresh_jobs']
  rows = (rj['by_type_result'] || []).map do |b|
    [b['job_type'], b['result'], b['n'], format('%.1fs', b['avg_duration_s'] || 0)]
  end
  refresh_table = md_table(['Job Type', 'Result', 'Jobs', 'Avg duration'], rows)
  refresh_notes = "_#{rj['notes']}_" if rj['notes']
end

# Section 6 — workbook usage ranking
usage_top_n = 10
usage_table = '_Workbook usage data unavailable._'
n_cold = 0
cold_names = '—'
# Fallback: derive workbook_usage from workbook_inventory if not set top-level
usage_source = inventory['workbook_usage']
if usage_source.nil? || usage_source.empty?
  usage_source = (inventory['workbook_inventory'] || [])
                   .select { |w| w['accesses'] || w['actors'] }
                   .map { |w| { 'name' => w['name'], 'accesses' => w['accesses'].to_i, 'actors' => w['actors'].to_i } }
  usage_source = nil if usage_source.empty?
end
if usage_source
  ranked = usage_source.sort_by { |w| -w['accesses'].to_i }
  inv_by_name = (inventory['workbook_inventory'] || []).each_with_object({}) { |w, h| h[w['name']] = w }
  rows = ranked.first(usage_top_n).each_with_index.map do |w, i|
    info = inv_by_name[w['name']] || {}
    project = info['project'] || '—'
    [i + 1, w['name'], project, info['owner'] || '—',
     format('%.2f', info['size_mb'] || 0), info['is_extract'] ? '✓' : 'live',
     w['accesses'], w['actors']]
  end
  usage_table = md_table(['#', 'Workbook', 'Project', 'Owner', 'Size MB', 'Extract?', 'Accesses', 'Distinct viewers'], rows)
  cold = (inventory['workbook_inventory'] || []).select { |w| w['last_accessed'].nil? }
  n_cold = cold.size
  cold_names = cold.map { |w| "`#{w['name']}`" }.join(', ') if cold.any?
end

# Section 7 — shortlist
shortlist_table = ''
shortlist_top_n = 0
shortlist_pct_usage = 0
shortlist_total_unhandled = 0
n_needs_scout = 0
n_retire = 0
recommended_pilot_n = 0
recommended_pilot_pct = 0
recommended_pilot_unhandled = 0
total_unhandled = 0
n_workbooks_with_unhandled = 0
n_workbooks_scanned = 0
complexity_table = ''
if has_shortlist
  rows = shortlist.first(15).map do |r|
    tag_md = case r['tag']
             when 'migrate-first'    then '**migrate-first**'
             when 'easy-win'         then 'easy-win'
             when 'needs-gap-scout'  then '⚠️ needs-gap-scout'
             when 'retire'           then '🗑 retire'
             else 'moderate'
             end
    parity_md = r['predicted_parity_pct'] ? "#{format('%.0f', r['predicted_parity_pct'])}% (#{r['parity_band']})" : '—'
    [r['name'], r['accesses'], r['actors'],
     "#{r['auto']} / #{r['hint']} / #{r['manual']} / #{r['unhandled']}",
     parity_md, format('%.1f', r['value']), format('%.2f', r['score']), tag_md]
  end
  shortlist_table = md_table(
    ['Workbook', 'Acc', 'Viewers', 'Auto/Hint/Man/Unh', 'Pred. parity', 'Value', 'Score', 'Tag'], rows
  )

  total_accesses = shortlist.sum { |r| r['accesses'].to_i }
  top5 = shortlist.first(5)
  shortlist_top_n = 5
  shortlist_pct_usage = total_accesses.zero? ? 0 : (top5.sum { |r| r['accesses'].to_i }.to_f / total_accesses * 100).round
  shortlist_total_unhandled = top5.sum { |r| r['unhandled'].to_i }

  n_needs_scout = shortlist.count { |r| r['tag'] == 'needs-gap-scout' }
  n_retire      = shortlist.count { |r| r['tag'] == 'retire' }
  recommended_pilot_n = top5.size
  recommended_pilot_pct = shortlist_pct_usage
  recommended_pilot_unhandled = shortlist_total_unhandled

  # Per-workbook complexity table
  if complexity
    n_workbooks_scanned = complexity.size
    crows = complexity.values.sort_by do |r|
      -(r['n_unhandled'] * 10 + r['n_manual'] * 3 + r['n_hint'])
    end.map do |r|
      parity_md = r['predicted_parity_pct'] ? "#{format('%.0f', r['predicted_parity_pct'])}% (#{r['parity_band']})" : '—'
      [r['name'], r['twb_size_kb'], r['n_features'], r['n_auto'], r['n_hint'], r['n_manual'],
       r['n_unhandled'].positive? ? "**#{r['n_unhandled']}**" : 0, parity_md]
    end
    complexity_table = md_table(
      ['Workbook', 'KB', 'Features', 'Auto', 'Hint', 'Manual', 'Unhandled', 'Pred. parity'], crows
    )
    total_unhandled = complexity.values.sum { |r| r['n_unhandled'].to_i }
    n_workbooks_with_unhandled = complexity.values.count { |r| r['n_unhandled'].positive? }
  end
end

# Section 8b — consolidation candidates
consolidation_table = ''
n_consol_groups = 0
n_consolidate = 0
n_consol_review = 0
conversions_avoidable = 0
if has_consolidation
  cs = consolidation['summary'] || {}
  n_consol_groups       = cs['groups_total'] || 0
  n_consolidate         = cs['consolidate'] || 0
  n_consol_review       = cs['review'] || 0
  conversions_avoidable = cs['conversions_avoidable'] || 0
  crows = (consolidation['groups'] || []).map do |g|
    members = g['workbooks'].map { |w| w['name'] }.join(' + ')
    controls = (g['proposed_controls'] || []).map { |c| "#{c['kind']} on `#{c['column']}`" }.join(', ')
    proposal = g['recommendation'] == 'consolidate' ? "#{g['workbooks'].size} → 1 workbook#{controls.empty? ? ' (keep primary)' : " + #{controls}"}" : '—'
    [g['group_id'], members, "#{g['field_overlap_pct']}%", proposal,
     g['recommendation'] == 'consolidate' ? '**consolidate**' : g['recommendation']]
  end
  consolidation_table = md_table(['Group', 'Workbook variants', 'Field overlap', 'Proposal', 'Recommendation'], crows)
end

# -------- apply template -----------------------------------------------------

out = tpl.dup
out = section_block(out, 'has_shortlist',         has_shortlist)
out = section_block(out, 'has_consolidation',     has_consolidation) if has_shortlist
out = section_block(out, 'limited_mode_banner',   limited_mode)
out = section_block(out, 'has_pricing',           has_pricing)

repl = {
  '{{site_name}}'                  => site['name']         || 'unknown',
  '{{site_url}}'                   => site['url']          || '—',
  '{{mode}}'                       => site['mode']         || 'MCP',
  '{{generated_at}}'               => site['generated_at'] || Time.now.strftime('%Y-%m-%d'),
  '{{workbooks}}'                  => env['workbooks'].to_s,
  '{{views}}'                      => env['views'].to_s,
  '{{dashboards}}'                 => vt['dashboard'].to_s,
  '{{sheets}}'                     => vt['view_sheet'].to_s,
  '{{stories}}'                    => vt['story'].to_s,
  '{{datasources}}'                => env['datasources'].to_s,
  '{{ds_published}}'               => ds_published.to_s,
  '{{ds_embedded}}'                => ds_embedded.to_s,
  '{{projects}}'                   => env['projects'].to_s,
  '{{flows}}'                      => env['flows'].to_s,
  '{{metrics}}'                    => env['metrics'].to_s,
  '{{metric_definitions}}'         => env['metric_definitions'].to_s,
  '{{licenses_table}}'             => licenses_table,
  '{{pricing_rows}}'               => pricing_rows,
  '{{ownership_table}}'            => ownership_table,
  '{{top_owner_pct}}'              => top_owner_pct.to_s,
  '{{top_owner_email}}'            => "`#{top_owner_email}`",
  '{{datasource_summary_table}}'   => ds_summary_table,
  '{{n_published_extracts}}'       => n_published_extracts.to_s,
  '{{n_embedded}}'                 => n_embedded.to_s,
  '{{refresh_table}}'               => refresh_table,
  '{{refresh_notes}}'               => refresh_notes,
  '{{top_n_usage}}'                 => usage_top_n.to_s,
  '{{usage_table}}'                 => usage_table,
  '{{n_cold}}'                      => n_cold.to_s,
  '{{cold_names}}'                  => cold_names,
  '{{shortlist_table}}'             => shortlist_table,
  '{{shortlist_top_n}}'             => shortlist_top_n.to_s,
  '{{shortlist_pct_usage}}'         => shortlist_pct_usage.to_s,
  '{{shortlist_total_unhandled}}'   => shortlist_total_unhandled.to_s,
  '{{complexity_table}}'            => complexity_table,
  '{{consolidation_table}}'         => consolidation_table,
  '{{n_consol_groups}}'             => n_consol_groups.to_s,
  '{{n_consolidate}}'               => n_consolidate.to_s,
  '{{n_consol_review}}'             => n_consol_review.to_s,
  '{{conversions_avoidable}}'       => conversions_avoidable.to_s,
  '{{total_unhandled}}'             => total_unhandled.to_s,
  '{{n_workbooks_with_unhandled}}'  => n_workbooks_with_unhandled.to_s,
  '{{n_workbooks_scanned}}'         => n_workbooks_scanned.to_s,
  '{{n_needs_scout}}'               => n_needs_scout.to_s,
  '{{n_retire}}'                    => n_retire.to_s,
  '{{recommended_pilot_n}}'         => recommended_pilot_n.to_s,
  '{{recommended_pilot_pct}}'       => recommended_pilot_pct.to_s,
  '{{recommended_pilot_unhandled}}' => recommended_pilot_unhandled.to_s
}
repl.each { |k, v| out.gsub!(k, v.to_s) }

readout_path = File.join(opts[:out], 'readout.md')
File.write(readout_path, out)
puts "wrote #{readout_path}"
