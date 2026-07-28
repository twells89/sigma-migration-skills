#!/usr/bin/env ruby
# Phase 4 (final) render for domo-assessment: turn the JSON artifacts from
# discover-domo.rb / score-coverage.rb into a human-readable readout.md.
#
#   ruby scripts/render-readout.rb --in <dir> --out <dir>
#
# Reads --in for probe.json (best-effort), inventory.json (required),
# usage.json (optional -- its presence is how we tell audit mode apart from
# the complexity-only proxy), complexity.json (required) and shortlist.json /
# migration-plan.json (optional -- complexity.json alone is enough to render
# a degraded readout if score-coverage.rb somehow didn't finish those two).
#
# Uses refs/readout-template.md ({{placeholder}} + {{#key}}...{{/key}} /
# {{^key}}...{{/key}} conditional-block syntax) but does its own replacement
# -- no templating dependency. --in and --out may be the same directory
# (that's how the pipeline runs it).
#
# This assessment never posts to Sigma / calls Domo -- pure JSON+Markdown in,
# Markdown out. No HTML is emitted (the readout must render as plain Markdown
# wherever it's pasted).

require 'json'
require 'optparse'
require 'fileutils'
require 'time'

options = {}
OptionParser.new do |o|
  o.on('--in DIR', 'Directory with complexity.json/inventory.json(/shortlist.json/migration-plan.json/usage.json) (required)') { |v| options[:in] = v }
  o.on('--out DIR', 'Write readout.md here (required)') { |v| options[:out] = v }
  o.on('--template PATH', 'Override refs/readout-template.md') { |v| options[:template] = v }
end.parse!

abort('--in DIR is required') unless options[:in]
abort('--out DIR is required') unless options[:out]
abort("--in dir not found: #{options[:in]}") unless File.directory?(options[:in])
FileUtils.mkdir_p(options[:out])

def read_json(path, default = nil)
  File.exist?(path) ? JSON.parse(File.read(path)) : default
end

complexity_path = File.join(options[:in], 'complexity.json')
abort("complexity.json not found in #{options[:in]} -- run score-coverage.rb first") unless File.exist?(complexity_path)
complexity = JSON.parse(File.read(complexity_path))

inv_path = File.join(options[:in], 'inventory.json')
abort("inventory.json not found in #{options[:in]} -- run discover-domo.rb first") unless File.exist?(inv_path)
inventory = JSON.parse(File.read(inv_path))

shortlist = read_json(File.join(options[:in], 'shortlist.json'), { 'artifacts' => complexity['artifacts'] })
plan      = read_json(File.join(options[:in], 'migration-plan.json'), {})
audit     = File.exist?(File.join(options[:in], 'usage.json'))

template_path = options[:template] || File.expand_path('../refs/readout-template.md', __dir__)
tpl = File.read(template_path)

# ---- helpers (md_table/md_cell/section_block -- same pattern as the other
# *-assessment renderers, kept vendor-agnostic on purpose) --------------------

def md_cell(v)
  v.to_s.gsub('|', '\\|') # a bare pipe would otherwise split the column
end

def md_table(headers, rows)
  out = '| ' + headers.map { |h| md_cell(h) }.join(' | ') + " |\n"
  out += '|' + headers.map { '---' }.join('|') + "|\n"
  rows.each { |r| out += '| ' + r.map { |c| md_cell(c) }.join(' | ') + " |\n" }
  out
end

# Keep the {{#key}}...{{/key}} body (stripped of its markers) when keep is
# true; keep the {{^key}}...{{/key}} body when keep is false. Either marker
# pair is optional -- a missing one is simply a no-op gsub.
def section_block(tpl, key, keep)
  opposite_open = keep ? "{{^#{key}}}" : "{{##{key}}}"
  kept_open     = keep ? "{{##{key}}}" : "{{^#{key}}}"
  close         = "{{/#{key}}}"
  tpl = tpl.gsub(/#{Regexp.escape(opposite_open)}.*?#{Regexp.escape(close)}/m, '')
  tpl.gsub(/#{Regexp.escape(kept_open)}(.*?)#{Regexp.escape(close)}/m) { $1 }
end

TAG_ORDER = %w[migrate-first easy-win moderate needs-gap-scout retire].freeze
TAG_LABEL = {
  'migrate-first'   => '**migrate-first**',
  'easy-win'        => 'easy-win',
  'moderate'        => 'moderate',
  'needs-gap-scout' => '⚠️ needs-gap-scout',
  'retire'          => '🗑 retire'
}.freeze

# ---- gather -------------------------------------------------------------------

tier     = complexity['tier'] || 'B'
tier_b   = tier == 'B'
tier_a   = tier == 'A'
instance = inventory['instance'] || 'unknown'

rollup = complexity['rollup'] || {}
by_tag = rollup['by_tag'] || {}
totals = rollup['totals'] || {}
pct_auto = (rollup['pct_auto'] || 0.0).to_f

value_basis = audit ? 'activity-log' : 'complexity-proxy'
value_formula =
  if audit
    'views × √(max(distinct_viewers, 1))  -- Activity Log installed'
  else
    '10 × (1 + beast_modes_on_card / 4.0)  -- no Activity Log, complexity proxy'
  end

n_datasets  = (inventory['datasets'] || []).size
n_pages     = (inventory['pages']    || []).size
n_users     = (inventory['users']    || []).size
n_artifacts = totals['n_artifacts'] || (complexity['artifacts'] || []).size

# Section 2 -- cards by tag
extra_tags = (by_tag.keys - TAG_ORDER)
tag_rows = (TAG_ORDER + extra_tags).map { |t| [t, (by_tag[t] || 0)] }
tag_table = md_table(['Tag', 'Cards'], tag_rows)

# Section 3 -- migration shortlist
artifacts = shortlist['artifacts'] || complexity['artifacts'] || []
shortlist_rows = artifacts.map do |a|
  tag = a['tag'].to_s
  [
    a['title'] || a['id'],
    TAG_LABEL[tag] || tag,
    format('%.2f', a['score'].to_f),
    a['views'].to_i,
    "#{a['n_manual'].to_i}m / #{a['n_unhandled'].to_i}u"
  ]
end
shortlist_table =
  if shortlist_rows.empty?
    '_No cards scored -- inventory.json had no cards._'
  else
    md_table(['Title', 'Tag', 'Score', 'Views', 'Gaps (manual/unhandled)'], shortlist_rows)
  end

retire_artifacts = artifacts.select { |a| a['tag'] == 'retire' }
n_retire = retire_artifacts.size
retire_titles = retire_artifacts.empty? ? '—' : retire_artifacts.map { |a| "`#{a['title'] || a['id']}`" }.join(', ')
n_needs_scout = artifacts.count { |a| a['tag'] == 'needs-gap-scout' }

# Section 4 -- migration plan rollup
clusters = plan['clusters'] || {}
cluster_rows = clusters.values.sort_by { |c| -c['card_count'].to_i }.map do |c|
  tags = (c['by_tag'] || {}).map { |t, n| "#{t}:#{n}" }.join(', ')
  [c['dataset_id'], c['card_count'], tags]
end
cluster_table = cluster_rows.empty? ? '_No dataset clusters (no cards)._' : md_table(['Dataset', 'Cards', 'Tags'], cluster_rows)

page_titles = {}
(inventory['pages'] || []).each { |p| page_titles[p['id']] = p['title'] }
pages_h = plan['pages'] || {}
page_rows = pages_h.values.sort_by { |p| p['page_id'].to_s }.map do |p|
  [page_titles[p['page_id']] || p['page_id'], (p['card_ids'] || []).size, p['recommended_path']]
end
page_table = page_rows.empty? ? '_No pages._' : md_table(['Page', 'Cards', 'Recommended path'], page_rows)

# Section 5 -- duplicate / consolidation candidates
dup = plan['duplicate_dashboards'] || {}
dup_groups = dup['groups'] || []
duplicate_note =
  if dup_groups.empty?
    '_None found -- no two cards look like the same report rebuilt._'
  else
    s = dup['summary'] || {}
    lines = []
    lines << "**#{s['duplicate_groups']} group(s)** spanning **#{s['dashboards_in_groups']}** card(s) -- " \
             "consolidating would avoid **#{s['conversions_avoided']}** redundant migration(s)."
    lines << ''
    dup_groups.each_with_index do |g, i|
      d = g['drivers'] || {}
      shared = (d['shared_sources'] || []).join(', ')
      lines << "**Group #{i + 1} -- #{g['recommendation'].to_s.upcase}** (shared sources: #{shared.empty? ? '—' : shared})"
      (g['members'] || []).each do |m|
        usage = m['usage'].nil? ? '' : " -- #{m['usage']} views"
        lines << "- #{m['name']} `#{m['id']}`#{usage}"
      end
      lines << ''
    end
    lines.join("\n")
  end

# ---- apply template -----------------------------------------------------------

out = tpl.dup
out = section_block(out, 'tier_b', tier_b)
out = section_block(out, 'tier_a', tier_a)

repl = {
  '{{instance}}'      => instance.to_s,
  '{{tier}}'          => tier.to_s,
  '{{value_basis}}'   => value_basis,
  '{{value_formula}}' => value_formula,
  '{{generated_at}}'  => Time.now.strftime('%Y-%m-%d'),
  '{{n_datasets}}'    => n_datasets.to_s,
  '{{n_pages}}'       => n_pages.to_s,
  '{{n_artifacts}}'   => n_artifacts.to_s,
  '{{n_users}}'       => n_users.to_s,
  '{{total_views}}'   => (totals['total_views'] || 0).to_s,
  '{{n_auto}}'        => (totals['n_auto'] || 0).to_s,
  '{{n_hint}}'        => (totals['n_hint'] || 0).to_s,
  '{{n_manual}}'      => (totals['n_manual'] || 0).to_s,
  '{{n_unhandled}}'   => (totals['n_unhandled'] || 0).to_s,
  '{{pct_auto}}'      => format('%.1f', pct_auto),
  '{{tag_table}}'     => tag_table,
  '{{shortlist_table}}' => shortlist_table,
  '{{n_retire}}'      => n_retire.to_s,
  '{{retire_titles}}' => retire_titles,
  '{{n_needs_scout}}' => n_needs_scout.to_s,
  '{{cluster_table}}' => cluster_table,
  '{{page_table}}'    => page_table,
  '{{duplicate_note}}' => duplicate_note
}
repl.each { |k, v| out.gsub!(k, v.to_s) }

readout_path = File.join(options[:out], 'readout.md')
File.write(readout_path, out)
warn "wrote #{readout_path} (tier=#{tier}, #{n_artifacts} cards, pct_auto=#{format('%.1f', pct_auto)})"
