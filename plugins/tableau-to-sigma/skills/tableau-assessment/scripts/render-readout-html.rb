#!/usr/bin/env ruby
# Render <out>/readout.html — a customer-facing, share-friendly HTML report.
#
# Reads the same JSON inputs as render-readout.rb. Customer-facing, so:
#   - leads with the actionable finding (migration shortlist)
#   - drops internal-skill jargon and methodology asides
#   - assumes PAT mode (complexity + shortlist sections present)
#
# Usage: ruby scripts/render-readout-html.rb --out /tmp/assessment-<site>

require 'json'
require 'optparse'
require 'cgi'
require 'set'

opts = {}
OptionParser.new do |p|
  p.on('--out DIR') { |v| opts[:out] = v }
end.parse!
abort('--out required') unless opts[:out]

inv_path        = File.join(opts[:out], 'inventory.json')
complexity_path = File.join(opts[:out], 'complexity.json')
shortlist_path  = File.join(opts[:out], 'shortlist.json')
ds_path         = File.join(opts[:out], 'data-sources.json')
users_path      = File.join(opts[:out], 'users.json')
views_path      = File.join(opts[:out], 'views.json')
perf_path       = File.join(opts[:out], 'performance.json')
ds_usage_path   = File.join(opts[:out], 'datasource-usage.json')
wb_users_path   = File.join(opts[:out], 'workbook-users.json')
abort("inventory.json not found in #{opts[:out]}") unless File.exist?(inv_path)

def load_json(path); File.exist?(path) ? JSON.parse(File.read(path)) : nil; end
inventory       = JSON.parse(File.read(inv_path))
complexity      = load_json(complexity_path)
shortlist       = load_json(shortlist_path)
ds_analysis     = load_json(ds_path)
users_analysis  = load_json(users_path)
views_analysis  = load_json(views_path)
perf_analysis   = load_json(perf_path)
ds_usage        = load_json(ds_usage_path)
workbook_users  = load_json(wb_users_path)
has_shortlist  = !shortlist.nil? && !shortlist.empty?
has_ds_deep    = !ds_analysis.nil?
has_users_deep = !users_analysis.nil?
has_views      = !views_analysis.nil?
has_perf       = !perf_analysis.nil? && !(perf_analysis['views'] || []).empty?

def h(s); CGI.escapeHTML(s.to_s); end
def num(n); n.to_i.to_s.reverse.scan(/.{1,3}/).join(',').reverse; end

# ---------- gather computed values ----------
site = inventory['site'] || {}
env  = inventory['environment_overview'] || {}
vt   = inventory['view_type_breakdown'] || {}
ds   = inventory['datasource_types'] || {}

site_name = site['name'] || 'unknown'
site_url  = site['url']  || ''
generated_at = site['generated_at'] || Time.now.strftime('%Y-%m-%d')
formatted_date = Date.parse(generated_at).strftime('%B %d, %Y') rescue generated_at

n_published_extracts = ds.dig('summary', 'extract_total') || 0
n_embedded           = ds.dig('summary', 'embedded_total') || 0
n_published          = ds.dig('summary', 'published_total') || 0

# Usage
usage_source = inventory['workbook_usage']
if usage_source.nil? || usage_source.empty?
  usage_source = (inventory['workbook_inventory'] || [])
                   .select { |w| w['accesses'] || w['actors'] }
                   .map { |w| { 'name' => w['name'], 'accesses' => w['accesses'].to_i, 'actors' => w['actors'].to_i } }
end
usage_source ||= []
inv_by_name = (inventory['workbook_inventory'] || []).each_with_object({}) { |w, h| h[w['name']] = w }
total_accesses = usage_source.sum { |w| w['accesses'].to_i }
cold_workbooks = (inventory['workbook_inventory'] || []).select { |w| w['last_accessed'].nil? }

# Shortlist
sl_top5_accesses  = 0
sl_top5_unhandled = 0
sl_total_unhandled = 0
sl_needs_scout    = 0
sl_retire         = 0
sl_migrate_first  = 0
sl_easy_win       = 0
if has_shortlist
  top5 = shortlist.first(5)
  sl_top5_accesses  = top5.sum { |r| r['accesses'].to_i }
  sl_top5_unhandled = top5.sum { |r| r['unhandled'].to_i }
  sl_total_unhandled = shortlist.sum { |r| r['unhandled'].to_i }
  sl_needs_scout = shortlist.count { |r| r['tag'] == 'needs-gap-scout' }
  sl_retire      = shortlist.count { |r| r['tag'] == 'retire' }
  sl_migrate_first = shortlist.count { |r| r['tag'] == 'migrate-first' }
  sl_easy_win      = shortlist.count { |r| r['tag'] == 'easy-win' }
end
top5_pct = total_accesses.zero? ? 0 : (sl_top5_accesses.to_f / total_accesses * 100).round

# Top owner
top_owner_pct = 0
top_owner_email = '—'
if inventory['content_ownership']
  total_wb = inventory['content_ownership'].sum { |o| o['workbooks'].to_i }
  if total_wb > 0
    top = inventory['content_ownership'].max_by { |o| o['workbooks'].to_i }
    top_owner_pct = (top['workbooks'].to_f / total_wb * 100).round
    top_owner_email = top['owner']
  end
end

# Complexity
n_scanned = complexity ? complexity.size : 0
n_with_unhandled = complexity ? complexity.values.count { |r| r['n_unhandled'].positive? } : 0

# ---------- HTML helpers ----------
TAG_LABELS = {
  'migrate-first'   => 'Migrate first',
  'easy-win'        => 'Easy win',
  'moderate'        => 'Standard',
  'needs-gap-scout' => 'Needs review',
  'retire'          => 'Retire'
}
TAG_CLASSES = {
  'migrate-first'   => 'tag-go',
  'easy-win'        => 'tag-blue',
  'moderate'        => 'tag-gray',
  'needs-gap-scout' => 'tag-warn',
  'retire'          => 'tag-mute'
}

def tag_pill(t)
  %(<span class="tag #{TAG_CLASSES[t]}">#{h(TAG_LABELS[t] || t)}</span>)
end

# Horizontal bar cell — value normalized to max
def bar_cell(value, max, color = 'bar-blue')
  pct = max.zero? ? 0 : (value.to_f / max * 100).round
  %(<div class="bar-cell"><div class="bar-track"><div class="bar-fill #{color}" style="width:#{pct}%"></div></div><div class="bar-num">#{num(value)}</div></div>)
end

# ---------- section rendering ----------

# Hero: headline finding
hero_finding =
  if has_shortlist
    if sl_top5_unhandled.zero? && sl_migrate_first.positive?
      'Pilot migration is low-risk: the top 5 most-used workbooks contain no unsupported features.'
    elsif sl_total_unhandled.positive?
      "The top-5 pilot is feasible. #{n_with_unhandled} workbook#{n_with_unhandled == 1 ? '' : 's'} elsewhere on the site include feature#{n_with_unhandled == 1 ? '' : 's'} that warrant individual review when planning their conversion."
    else
      'Migration shortlist ranked by usage and conversion complexity.'
    end
  else
    'Environment scan complete.'
  end

# Section 1: KPI tiles
def kpi(label, value, sub = nil)
  s = sub ? %(<div class="kpi-sub">#{h(sub)}</div>) : ''
  %(<div class="kpi"><div class="kpi-v">#{h(value)}</div><div class="kpi-l">#{h(label)}</div>#{s}</div>)
end

# Generic data table renderer.
# headers: array of strings
# rows:    array of arrays of cell values (HTML-safe strings or numbers).
#          Strings starting with '<' are inserted raw; everything else is escaped.
# opts:    align: %w[left right center ...], class: extra CSS class on table
def table(headers, rows, opts = {})
  cls = opts[:class] || ''
  cols = headers.size
  align = opts[:align] || Array.new(cols, 'left')
  thead = "<thead><tr>" + headers.each_with_index.map { |c, i| %(<th class="al-#{align[i]}">#{h(c)}</th>) }.join + "</tr></thead>"
  tbody = "<tbody>" + rows.map do |r|
    "<tr>" + r.each_with_index.map { |c, i|
      cell = c.to_s
      content = cell.start_with?('<') ? cell : h(cell)
      %(<td class="al-#{align[i]}">#{content}</td>)
    }.join + "</tr>"
  end.join + "</tbody>"
  %(<table class="data #{cls}">#{thead}#{tbody}</table>)
end

kpi_html = [
  kpi('Workbooks',   env['workbooks']),
  kpi('Views',       env['views'], "#{vt['dashboard'] || 0} dashboards · #{vt['view_sheet'] || 0} sheets"),
  kpi('Data sources', env['datasources'], "#{n_published} published · #{n_embedded} embedded"),
  kpi('Projects',    env['projects']),
  kpi('Flows',       env['flows']),
  kpi('Total accesses', num(total_accesses), 'all-time')
].join

# Section 2: Migration shortlist (HERO)
shortlist_html = ''
if has_shortlist
  max_acc = shortlist.map { |r| r['accesses'].to_i }.max || 1
  rows = shortlist.first(15).map do |r|
    name_cell = h(r['name'])
    name_cell = %(<a href="#{h(r['url'])}" target="_blank" rel="noopener" class="workbook-link">#{name_cell}</a>) if r['url']

    # Risk indicator: green dot if clean, amber for manual-only, red for any unhandled
    risk_cls, risk_txt =
      if r['unhandled'].positive?
        ['risk-red',   "#{r['unhandled']} to review"]
      elsif r['manual'].positive?
        ['risk-amber', "#{r['manual']} setup"]
      elsif r['hint'].positive?
        ['risk-green', "#{r['hint']} suggested"]
      else
        ['risk-clean', 'No issues']
      end

    %(<tr>
      <td>#{name_cell}</td>
      <td>#{bar_cell(r['accesses'], max_acc)}</td>
      <td class="al-right num">#{r['actors']}</td>
      <td><span class="risk-chip #{risk_cls}"><span class="risk-dot"></span>#{h(risk_txt)}</span></td>
      <td class="al-right num">#{format('%.1f', r['score'])}</td>
      <td>#{tag_pill(r['tag'])}</td>
    </tr>)
  end.join
  shortlist_html = <<~HTML
    <table class="data shortlist">
      <thead>
        <tr>
          <th>Workbook</th>
          <th>Usage</th>
          <th class="al-right">Viewers</th>
          <th>Conversion risk</th>
          <th class="al-right">Score</th>
          <th>Recommendation</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
    <p class="note">Conversion risk legend: <strong>No issues</strong> = converts automatically · <strong>N suggested</strong> = converts automatically with a recommended adjustment · <strong>N setup</strong> = brief post-conversion setup in Sigma · <strong>N to review</strong> = uses a Tableau feature that warrants individual evaluation when planning the conversion.</p>
  HTML
end

# Section 3: Per-workbook complexity
complexity_html = ''
if complexity
  rows = complexity.values.sort_by do |r|
    -(r['n_unhandled'] * 10 + r['n_manual'] * 3 + r['n_hint'])
  end.map do |r|
    unh_cell = r['n_unhandled'].positive? ? %(<span class="warn-num">#{r['n_unhandled']}</span>) : '<span class="muted">0</span>'
    %(<tr>
      <td>#{h(r['name'])}</td>
      <td class="al-right num muted">#{num(r['twb_size_kb'])} KB</td>
      <td class="al-right num">#{r['n_features']}</td>
      <td class="al-right num muted">#{r['n_auto']}</td>
      <td class="al-right num muted">#{r['n_hint']}</td>
      <td class="al-right num">#{r['n_manual']}</td>
      <td class="al-right">#{unh_cell}</td>
    </tr>)
  end.join
  complexity_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Workbook</th>
          <th class="al-right">Size</th>
          <th class="al-right">Features</th>
          <th class="al-right">Auto</th>
          <th class="al-right">Suggested</th>
          <th class="al-right">Setup</th>
          <th class="al-right">Review</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 4: Most-used workbooks (with per-workbook top users + top views)
usage_html = ''
wb_users_by_name  = workbook_users ? (workbook_users['workbooks'] || []).each_with_object({}) { |w, h| h[w['workbook']] = w } : {}
views_by_workbook = views_analysis ? (views_analysis['by_workbook'] || []).each_with_object({}) { |v, h| h[v['workbook']] = v } : {}

if !usage_source.empty?
  ranked = usage_source.sort_by { |w| -w['accesses'].to_i }
  max_acc = ranked.first['accesses'].to_i
  rows = ranked.first(10).each_with_index.map do |w, i|
    info = inv_by_name[w['name']] || {}
    name_cell = info['url'] ? %(<a href="#{h(info['url'])}" target="_blank" rel="noopener" class="workbook-link">#{h(w['name'])}</a>) : h(w['name'])

    # Top users
    wu = wb_users_by_name[w['name']]
    top_users_cell =
      if wu && (wu['top_users'] || []).any?
        wu['top_users'].first(2).map { |u| %(<span class="inline-pill">#{h(u['user'].sub(/@.*/, ''))} <span class="muted">#{u['accesses']}</span></span>) }.join(' ')
      else
        '<span class="muted">—</span>'
      end

    # Top dashboard / sheet — concentration signal
    vinfo = views_by_workbook[w['name']]
    top_view_cell =
      if vinfo && (vinfo['top_views'] || []).any?
        top = vinfo['top_views'].first
        %(<div class="top-view-cell"><strong>#{h(top['view'])}</strong><div class="muted top-view-pct">#{vinfo['concentration_pct']}% of workbook traffic</div></div>)
      else
        '<span class="muted">—</span>'
      end

    %(<tr>
      <td class="rank">#{i + 1}</td>
      <td>#{name_cell}</td>
      <td class="muted">#{h((info['owner'] || '—').sub(/@.*/, ''))}</td>
      <td>#{bar_cell(w['accesses'], max_acc)}</td>
      <td>#{top_users_cell}</td>
      <td>#{top_view_cell}</td>
    </tr>)
  end.join
  usage_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th class="al-right">#</th>
          <th>Workbook</th>
          <th>Owner</th>
          <th>Accesses</th>
          <th>Top users</th>
          <th>Most-used view</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 5: Content ownership
ownership_html = ''
if inventory['content_ownership']
  rows_data = inventory['content_ownership'].sort_by { |o| -o['workbooks'].to_i }
  max_wb = rows_data.first['workbooks'].to_i
  rows = rows_data.map do |o|
    %(<tr>
      <td>#{h(o['owner'])}</td>
      <td>#{bar_cell(o['workbooks'], max_wb)}</td>
      <td class="al-right num muted">#{num(o['datasources'])}</td>
      <td class="al-right num muted">#{num(o['views'])}</td>
      <td class="al-right num muted">#{num(o['flows'])}</td>
    </tr>)
  end.join
  ownership_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Owner</th>
          <th>Workbooks</th>
          <th class="al-right">Data sources</th>
          <th class="al-right">Views</th>
          <th class="al-right">Flows</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 6: Data sources
ds_html = ''
if inventory['datasource_types']
  rows_data = []
  (ds['published_extract'] || []).each { |r| rows_data << ['Published — extract', r['db_type'], r['n'], 'ds-published'] }
  (ds['published_live']    || []).each { |r| rows_data << ['Published — live', r['db_type'], r['n'], 'ds-published'] }
  (ds['embedded']          || []).each { |r| rows_data << ['Embedded', r['db_type'], r['n'], 'ds-embedded'] }
  rows_data.sort_by! { |r| -r[2] }
  max_n = rows_data.first[2]
  rows = rows_data.map do |bucket, db, n, kind_cls|
    badge_cls = bucket.start_with?('Published') ? 'ds-published' : 'ds-embedded'
    %(<tr>
      <td><span class="ds-bucket #{badge_cls}">#{h(bucket)}</span></td>
      <td><code>#{h(db)}</code></td>
      <td>#{bar_cell(n, max_n)}</td>
    </tr>)
  end.join
  ds_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Type</th>
          <th>Connection class</th>
          <th>Count</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 7: Refresh activity
refresh_html = ''
if inventory['refresh_jobs']
  rj = inventory['refresh_jobs']
  rows = (rj['by_type_result'] || []).map do |b|
    result_cls = b['result'] == 'Succeeded' ? 'tag-go' : 'tag-warn'
    %(<tr>
      <td>#{h(b['job_type'])}</td>
      <td><span class="tag #{result_cls}">#{h(b['result'])}</span></td>
      <td class="al-right num">#{num(b['n'])}</td>
      <td class="al-right num muted">#{format('%.1fs', b['avg_duration_s'] || 0)}</td>
    </tr>)
  end.join
  refresh_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Job type</th>
          <th>Result</th>
          <th class="al-right">Jobs</th>
          <th class="al-right">Avg duration</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
  refresh_html += %(<p class="note">#{h(rj['notes'])}</p>) if rj['notes']
end

# ---------- HTML ----------
html = <<~HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Tableau Environment Report — #{h(site_name)}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,600;9..40,700&family=DM+Mono:wght@400;500&display=swap');
  :root {
    /* Sigma brand palette — Shadow/Nimbus/White neutrals, Insight (CTA only), brand accents */
    --bg:#fafafa; --card:#ffffff; --ink:#292929; --ink-2:#3d3d3d;
    --line:#e5e5e5; --line-soft:#f5f5f5;
    --accent:#292929; --accent-soft:#f0f0f0;
    --insight:#f0ff45;
    --go:#1f9d57; --go-soft:#e6fbef;
    --warn:#c2562a; --warn-soft:#fff1ea;
    --blue:#2b8ca6; --blue-soft:#eaf8fc;
    --mute:#6e7877; --mute-soft:#f0f0f0;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: var(--ink); }
  body {
    font-family: "DM Sans", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    font-size: 14px; line-height: 1.55; -webkit-font-smoothing: antialiased;
  }
  main { max-width: 1120px; margin: 0 auto; padding: 48px 48px 80px; }

  /* Brand masthead */
  .brand-bar { display: flex; align-items: center; gap: 10px; margin-bottom: 28px; }
  .brand-mark { font-weight: 700; font-size: 21px; letter-spacing: -0.02em; color: var(--ink); }
  .brand-dot  { width: 9px; height: 9px; border-radius: 2px; background: var(--blue);
                -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  .brand-tag  { font-size: 12px; color: var(--mute); font-weight: 500;
                text-transform: uppercase; letter-spacing: 0.08em; }

  /* Header */
  .doc-header { margin-bottom: 40px; }
  .doc-eyebrow { font-size: 11px; font-weight: 600; color: var(--accent);
                 text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 8px; }
  .doc-title { font-size: 36px; font-weight: 700; letter-spacing: -0.02em;
               margin: 0 0 8px; line-height: 1.1; color: var(--ink); }
  .doc-meta { font-size: 13px; color: var(--ink-2); }
  .doc-meta a { color: var(--ink-2); text-decoration: none; border-bottom: 1px dashed var(--line); }
  .doc-meta a:hover { color: var(--ink); }

  /* Hero finding banner */
  .hero {
    background: var(--accent-soft); border: 1px solid var(--line);
    border-left: 4px solid var(--blue);
    border-radius: 8px;
    padding: 18px 22px; margin-bottom: 40px;
    display: flex; align-items: center; gap: 16px;
    -webkit-print-color-adjust: exact; print-color-adjust: exact;
  }
  .hero-label { font-size: 11px; font-weight: 700; color: var(--accent);
                text-transform: uppercase; letter-spacing: 0.08em;
                white-space: nowrap; padding-right: 16px;
                border-right: 1px solid var(--line); }
  .hero-text { font-size: 15px; color: var(--ink); font-weight: 500; line-height: 1.4; }

  /* Section */
  section { margin-bottom: 56px; }
  section.section-tight { margin-bottom: 36px; }
  .section-head { display: flex; align-items: baseline; justify-content: space-between;
                  margin-bottom: 16px; padding-bottom: 12px;
                  border-bottom: 1px solid var(--line); }
  .section-num { font-size: 12px; font-weight: 600; color: var(--mute);
                 letter-spacing: 0.06em; }
  .section-title { font-size: 22px; font-weight: 600; letter-spacing: -0.01em;
                   margin: 0; flex: 1; padding-left: 14px; }
  .section-aside { font-size: 12px; color: var(--mute); }
  .section-lede { font-size: 14px; color: var(--ink-2); margin: -4px 0 16px; }

  /* KPIs */
  .kpi-grid { display: grid; grid-template-columns: repeat(6, 1fr); gap: 12px; }
  .kpi {
    background: var(--card); border: 1px solid var(--line); border-radius: 10px;
    padding: 18px 16px;
  }
  .kpi-v { font-size: 28px; font-weight: 700; letter-spacing: -0.01em;
           color: var(--ink); line-height: 1; }
  .kpi-l { font-size: 11px; color: var(--mute); text-transform: uppercase;
           letter-spacing: 0.06em; font-weight: 600; margin-top: 10px; }
  .kpi-sub { font-size: 11px; color: var(--mute); margin-top: 4px; line-height: 1.4; }

  /* Stat callouts */
  .stat-row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px;
              margin-bottom: 24px; }
  .stat {
    background: #fafafa;
    border: 1px solid var(--line); border-left: 3px solid var(--accent);
    border-radius: 8px;
    padding: 16px 18px;
    -webkit-print-color-adjust: exact; print-color-adjust: exact;
  }
  .stat.stat-go   { border-left-color: var(--go);   background: var(--go-soft); }
  .stat.stat-warn { border-left-color: var(--warn); background: var(--warn-soft); }
  .stat-l { font-size: 10px; color: var(--mute); text-transform: uppercase;
            letter-spacing: 0.06em; font-weight: 700; margin-bottom: 6px; }
  .stat-v { font-size: 30px; font-weight: 700; line-height: 1; letter-spacing: -0.02em;
            color: var(--ink); }
  .stat-v.go   { color: var(--go); }
  .stat-v.warn { color: var(--warn); }
  .stat-sub { font-size: 12px; color: var(--mute); margin-top: 6px; }

  /* Tables */
  table.data { width: 100%; border-collapse: collapse; background: var(--card);
               border: 1px solid var(--line); border-radius: 10px; overflow: hidden;
               font-size: 13px; }
  table.data th { font-weight: 600; font-size: 11px; color: var(--mute);
                  text-transform: uppercase; letter-spacing: 0.06em;
                  padding: 12px 16px; background: #fafafa;
                  border-bottom: 1px solid var(--line); text-align: left; }
  table.data td { padding: 12px 16px; border-bottom: 1px solid var(--line-soft);
                  vertical-align: middle; }
  table.data tbody tr:last-child td { border-bottom: 0; }
  table.data tbody tr:hover td { background: #fafafa; }
  .al-right { text-align: right; }
  .al-left  { text-align: left; }
  /* Pin numeric + bar columns to content width so the text column absorbs the
     slack — keeps a short value tight against its header instead of stranding it
     across an over-wide column. */
  table.data td.al-right, table.data th.al-right,
  table.data td:has(.bar-cell) { width: 1%; white-space: nowrap; }
  .num { font-variant-numeric: tabular-nums; }
  .muted { color: var(--mute); }
  .warn { color: var(--warn); }
  .warn-num { color: var(--warn); font-weight: 700; }
  .rank { font-variant-numeric: tabular-nums; color: var(--mute); font-weight: 600; width: 32px; }
  .workbook-link { color: var(--ink); text-decoration: none;
                   border-bottom: 1px solid var(--line); }
  .workbook-link:hover { color: var(--accent); border-bottom-color: var(--accent); }
  .breakdown { font-size: 12px; font-variant-numeric: tabular-nums; }
  .breakdown span { margin-right: 8px; }

  /* Tags */
  .tag { display: inline-block; padding: 3px 10px; border-radius: 99px;
         font-size: 11px; font-weight: 600; letter-spacing: 0.01em;
         white-space: nowrap; }
  .tag-go    { background: var(--go-soft);    color: var(--go); }
  .tag-blue  { background: var(--blue-soft);  color: var(--blue); }
  .tag-gray  { background: #f5f5f5;           color: var(--ink-2); }
  .tag-warn  { background: var(--warn-soft);  color: var(--warn); }
  .tag-mute  { background: var(--mute-soft);  color: var(--mute); }

  /* Bar cells (in tables) */
  .bar-cell { display: flex; align-items: center; gap: 10px;
              justify-content: flex-start; }
  .bar-track { flex: none; width: 84px; height: 6px; background: #f5f5f5; border-radius: 4px;
               overflow: hidden; }
  .bar-fill { height: 100%; border-radius: 4px; }
  .bar-blue { background: linear-gradient(90deg, #4cec8c, #2fb874); }
  .bar-num { font-variant-numeric: tabular-nums; font-weight: 600;
             min-width: 36px; text-align: right; }

  /* Data-source bucket badge */
  .ds-bucket { display: inline-block; padding: 3px 10px; border-radius: 6px;
               font-size: 11px; font-weight: 600;
               -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  .ds-published { background: var(--blue-soft); color: var(--blue); }
  .ds-embedded  { background: #f5f5f5; color: var(--ink-2); }

  /* Risk chip — used in shortlist + verdicts + coverage */
  .risk-chip { display: inline-flex; align-items: center; gap: 6px;
               font-size: 12px; font-variant-numeric: tabular-nums; }
  .risk-dot { width: 8px; height: 8px; border-radius: 50%;
              -webkit-print-color-adjust: exact; print-color-adjust: exact; }
  .risk-clean .risk-dot { background: var(--go); }
  .risk-clean             { color: var(--go); font-weight: 600; }
  .risk-green .risk-dot { background: #84cc16; }
  .risk-green             { color: var(--ink-2); }
  .risk-amber .risk-dot { background: #f59e0b; }
  .risk-amber             { color: #a16207; font-weight: 600; }
  .risk-red   .risk-dot { background: var(--warn); }
  .risk-red               { color: var(--warn); font-weight: 700; }
  .risk-mute  .risk-dot { background: var(--mute); }
  .risk-mute              { color: var(--mute); }

  /* Cluster member display */
  .cluster-member { padding: 2px 0; font-size: 12px; line-height: 1.4; }
  .cluster-member + .cluster-member { border-top: 1px dashed var(--line-soft); }

  /* Inline user pill (top-users cell) */
  .inline-pill { display: inline-block; padding: 1px 7px; border-radius: 99px;
                 font-size: 11px; background: #f1f5f9; color: var(--ink-2);
                 font-variant-numeric: tabular-nums; margin-right: 4px;
                 -webkit-print-color-adjust: exact; print-color-adjust: exact; }

  /* Top-view cell — most-used view per workbook */
  .top-view-cell { font-size: 12px; line-height: 1.3; }
  .top-view-pct  { font-size: 11px; margin-top: 2px; }

  /* Per-user top-workbook list (inside table cell) */
  .top-wb { font-size: 11px; line-height: 1.4; display: flex;
            justify-content: space-between; gap: 12px;
            padding: 1px 0; }
  .top-wb + .top-wb { border-top: 1px dotted var(--line-soft); padding-top: 3px; margin-top: 3px; }
  .top-wb span:first-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 220px; }

  /* Unique-to-user expander */
  details.unique-detail { font-size: 11px; }
  details.unique-detail summary { cursor: pointer; color: var(--accent); font-weight: 600;
                                  list-style: none; padding: 2px 0; }
  details.unique-detail summary::-webkit-details-marker { display: none; }
  details.unique-detail summary::before { content: '▸ '; color: var(--mute); }
  details.unique-detail[open] summary::before { content: '▾ '; }
  details.unique-detail div { padding-left: 12px; font-size: 11px; line-height: 1.4; }

  /* Notes + callouts */
  .note { font-size: 12px; color: var(--mute); font-style: italic;
          margin: 12px 0 0; }
  .callout {
    background: var(--warn-soft); border-left: 3px solid var(--warn);
    padding: 12px 16px; border-radius: 6px; margin-top: 16px;
    font-size: 13px; color: #7c2d12;
  }
  .callout strong { color: #7c2d12; }
  .callout code { background: rgba(0,0,0,0.06); padding: 1px 5px; border-radius: 3px;
                  font-size: 12px; }

  code { font-family: "DM Mono", ui-monospace, "SF Mono", Menlo, monospace; font-size: 12.5px;
         background: var(--line-soft); padding: 1px 6px; border-radius: 4px; }

  /* Next steps */
  ol.next-steps { margin: 0; padding-left: 0; counter-reset: step;
                  list-style: none; }
  ol.next-steps li { counter-increment: step; padding: 14px 0 14px 44px;
                     position: relative; border-bottom: 1px solid var(--line-soft);
                     font-size: 14px; }
  ol.next-steps li:last-child { border-bottom: 0; }
  ol.next-steps li::before {
    content: counter(step); position: absolute; left: 0; top: 14px;
    width: 28px; height: 28px; border-radius: 50%;
    background: var(--accent-soft); color: var(--accent);
    display: flex; align-items: center; justify-content: center;
    font-size: 13px; font-weight: 700; font-variant-numeric: tabular-nums;
  }
  ol.next-steps li strong { color: var(--ink); }

  /* Privacy two-column */
  .priv-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
  .priv-col h3 { font-size: 13px; font-weight: 600; color: var(--ink);
                 margin: 0 0 10px; text-transform: uppercase; letter-spacing: 0.04em; }
  .priv-col ul { margin: 0; padding-left: 0; list-style: none; }
  .priv-col li { padding: 6px 0 6px 22px; position: relative;
                 font-size: 13px; color: var(--ink-2); }
  .priv-col.crossed li::before {
    content: '→'; position: absolute; left: 0; color: var(--warn); font-weight: 700;
  }
  .priv-col.local li::before {
    content: '◊'; position: absolute; left: 0; color: var(--go); font-weight: 700;
  }

  footer { color: var(--mute); font-size: 11px; text-align: center;
           margin-top: 56px; padding-top: 20px; border-top: 1px solid var(--line); }

  @media print {
    @page { margin: 0.6in 0.5in 0.6in; size: letter portrait; }
    body { background: white; font-size: 11.5px; }
    main { max-width: none; padding: 0; }
    .doc-header { margin-bottom: 18px; }
    .doc-title { font-size: 26px; }
    .hero { margin-bottom: 24px; padding: 12px 16px; page-break-after: avoid; }
    .hero-text { font-size: 13px; }
    section { margin-bottom: 24px; page-break-inside: auto; }
    section.section-tight { margin-bottom: 18px; }
    .section-head { margin-bottom: 10px; padding-bottom: 8px; page-break-after: avoid; }
    .section-title { font-size: 16px; }
    .section-lede { font-size: 12px; margin: -2px 0 10px; }
    .kpi-grid { gap: 8px; }
    .kpi { padding: 12px; }
    .kpi-v { font-size: 22px; }
    .kpi-l { font-size: 10px; margin-top: 6px; }
    .kpi-sub { font-size: 10px; margin-top: 3px; }
    .stat-row { gap: 8px; margin-bottom: 14px; }
    .stat { padding: 12px 14px; }
    .stat-v { font-size: 24px; }
    table.data { font-size: 11px; page-break-inside: auto; }
    table.data thead { display: table-header-group; }
    table.data th { padding: 8px 10px; font-size: 10px; }
    table.data td { padding: 8px 10px; }
    table.data tr { page-break-inside: avoid; page-break-after: auto; }
    .tag, .ds-bucket { font-size: 10px; padding: 2px 8px; }
    .bar-track { max-width: 60px; height: 5px; }
    .note { font-size: 11px; }
    .callout { padding: 8px 12px; font-size: 11px; }
    ol.next-steps li { padding: 10px 0 10px 36px; font-size: 12px; }
    ol.next-steps li::before { width: 22px; height: 22px; font-size: 11px; top: 10px; }
    .priv-col li { font-size: 11px; padding: 4px 0 4px 18px; }
    footer { margin-top: 24px; padding-top: 12px; }
    /* Force backgrounds + colors to render */
    .hero, .kpi, .stat, table.data, table.data th, .ds-bucket, .tag,
    .bar-track, .bar-fill, .risk-dot, .callout, ol.next-steps li::before {
      -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important;
    }
    /* Avoid awkward page splits at section boundaries */
    section h2, .section-head { page-break-after: avoid; }
    .stat-row, .priv-grid { page-break-inside: avoid; }
  }
</style>
</head>
<body>
<main>

<div class="brand-bar">
  <span class="brand-dot"></span>
  <span class="brand-mark">sigma</span>
  <span class="brand-tag">Migration Assessment</span>
</div>
<div class="doc-header">
  <div class="doc-eyebrow">Tableau Environment Report</div>
  <h1 class="doc-title">#{h(site_name)}</h1>
  <div class="doc-meta">
    #{site_url.empty? ? '' : %(<a href="#{h(site_url)}" target="_blank" rel="noopener">#{h(site_url)}</a> · )}
    Generated #{h(formatted_date)}
  </div>
</div>

<div class="hero">
  <div class="hero-label">Headline finding</div>
  <div class="hero-text">#{h(hero_finding)}</div>
</div>

<section>
  <div class="section-head">
    <span class="section-num">01</span>
    <h2 class="section-title">Environment overview</h2>
  </div>
  <div class="kpi-grid">#{kpi_html}</div>
</section>

<section>
  <div class="section-head">
    <span class="section-num">02</span>
    <h2 class="section-title">Workbook priority &amp; usage</h2>
    <span class="section-aside">Top 10 of #{env['workbooks']} workbooks · #{num(total_accesses)} total accesses</span>
  </div>
  <p class="section-lede">Most-used workbooks across the site, ranked by all-time access count. This is the foundation of any migration or consolidation plan — focus effort where audience attention already is.</p>
  #{usage_html}
  #{cold_workbooks.any? ? %(<p class="note"><strong>#{cold_workbooks.size} workbook#{cold_workbooks.size == 1 ? '' : 's'}</strong> have never been accessed: ) + cold_workbooks.map { |w| %(<code>#{h(w['name'])}</code>) }.join(', ') + ' — strong candidates for retirement.</p>' : ''}
</section>

<section>
  <div class="section-head">
    <span class="section-num">03</span>
    <h2 class="section-title">User populations &amp; migration impact</h2>
    #{has_users_deep ? %(<span class="section-aside">#{users_analysis['summary']['users_total']} users · avg pilot coverage #{users_analysis['summary']['avg_pilot_coverage_pct']}%</span>) : ''}
  </div>
  <p class="section-lede">Most migrations succeed or fail on whether the people using Tableau today land smoothly on Sigma. This section combines ownership concentration with user segmentation and shows what share of each user's actual usage the recommended migration pilot covers.</p>

  #{ownership_html}
  <p class="note">Top-owner concentration: <strong>#{top_owner_pct}%</strong> of workbooks owned by <code>#{h(top_owner_email)}</code>. High concentration in one or two owners is a governance signal — what happens if that person leaves?</p>

HTML

if has_users_deep
  us = users_analysis['summary']
  seg_labels = us['segment_labels']
  seg_rows = us['by_segment'].select { |_, n| n.positive? }.sort_by { |_, n| -n }.map do |k, n|
    [seg_labels[k] || k, n]
  end
  segment_table = "<h3>User segments</h3>" + (seg_rows.empty? ? '' :
    table(['Segment', 'Users'], seg_rows, align: %w[left right]))

  cov = us['pilot_coverage']
  coverage_stat_row = <<~ROW
    <div class="stat-row">
      <div class="stat #{cov['users_fully_covered'].positive? ? 'stat-go' : ''}">
        <div class="stat-l">Fully covered</div>
        <div class="stat-v #{cov['users_fully_covered'].positive? ? 'go' : ''}">#{cov['users_fully_covered']}</div>
        <div class="stat-sub">users whose top usage is on pilot workbooks (≥90%)</div>
      </div>
      <div class="stat">
        <div class="stat-l">Partially covered</div>
        <div class="stat-v">#{cov['users_partially_covered']}</div>
        <div class="stat-sub">pilot covers some but not all of their usage</div>
      </div>
      <div class="stat #{cov['users_not_covered'].positive? ? 'stat-warn' : ''}">
        <div class="stat-l">Not covered</div>
        <div class="stat-v #{cov['users_not_covered'].positive? ? 'warn' : ''}">#{cov['users_not_covered']}</div>
        <div class="stat-sub">users with usage entirely outside pilot scope</div>
      </div>
    </div>
  ROW

  # Per-user table — with top workbooks + unique-to-user list
  user_rows = users_analysis['users'].sort_by { |u| -u['total_accesses'].to_i }.first(15).map do |u|
    cov_cls = case u['pilot_coverage_bucket']
              when 'fully_covered' then 'risk-clean'
              when 'partially_covered' then 'risk-amber'
              when 'not_covered' then 'risk-red'
              else 'risk-mute'
              end
    cov_txt =
      if u['pilot_coverage_bucket'] == 'no_activity'
        '— (no activity)'
      else
        "#{u['pilot_coverage_pct']}%"
      end

    # Top-3 workbooks for this user as a small inline list
    top_wbs = (u['top_workbook_accesses'] || []).first(3)
    top_wb_html =
      if top_wbs.any?
        top_wbs.map { |w| %(<div class="top-wb"><span>#{h(w['workbook'])}</span> <span class="muted">#{w['accesses']}</span></div>) }.join
      else
        '<span class="muted">—</span>'
      end

    # Unique-to-user workbooks: workbooks only this user uses
    uniq = u['unique_workbooks_accessed'] || []
    unique_html =
      if uniq.any?
        %(<details class="unique-detail"><summary>#{uniq.size} unique to user</summary>) +
        uniq.map { |w| %(<div class="muted">#{h(w)}</div>) }.join +
        %(</details>)
      else
        '<span class="muted">—</span>'
      end

    [
      h(u['email']),
      h(seg_labels[u['segment']] || u['segment']),
      u['total_accesses'],
      top_wb_html,
      unique_html,
      %(<span class="risk-chip #{cov_cls}"><span class="risk-dot"></span>#{cov_txt}</span>)
    ]
  end
  user_table = table(
    ['User', 'Segment', 'Total accesses', 'Top workbooks (by accesses)', 'Unique-to-user', 'Pilot coverage'],
    user_rows,
    align: %w[left left right left left left]
  )

  # ---- License decommission subsection -----------------------------------
  # Pilot / extended / needs-review workbook sets (used for badging inside the
  # minimal-coverage expander)
  pilot_names_set    = has_shortlist ? Set.new(shortlist.first(5).map  { |r| r['name'] }) : Set.new
  extended_names_set = has_shortlist ? Set.new(shortlist.first(15).map { |r| r['name'] }) : Set.new
  review_names_set   = has_shortlist ? Set.new(shortlist.select { |r| r['tag'] == 'needs-gap-scout' }.map { |r| r['name'] }) : Set.new

  decommission_html = ''
  if users_analysis['summary']['decommission']
    ds = users_analysis['summary']['decommission']
    tier_labels = ds['tier_labels'] || {}

    decommission_stats = <<~ROW
      <div class="stat-row">
        <div class="stat #{ds['seats_decommissionable_in_pilot'].to_i.positive? ? 'stat-go' : ''}">
          <div class="stat-l">Decommissionable in pilot</div>
          <div class="stat-v #{ds['seats_decommissionable_in_pilot'].to_i.positive? ? 'go' : ''}">#{ds['seats_decommissionable_in_pilot']}</div>
          <div class="stat-sub">seats whose content is fully in the top-5 migration set</div>
        </div>
        <div class="stat #{ds['seats_decommissionable_in_extended'].to_i.positive? ? 'stat-go' : ''}">
          <div class="stat-l">+ With extended pilot</div>
          <div class="stat-v #{ds['seats_decommissionable_in_extended'].to_i.positive? ? 'go' : ''}">#{ds['seats_decommissionable_in_extended']}</div>
          <div class="stat-sub">if migration extends to top 15 workbooks</div>
        </div>
        <div class="stat">
          <div class="stat-l">Narrow-audience workbooks</div>
          <div class="stat-v">#{ds['narrow_audience_workbook_count']}</div>
          <div class="stat-sub">≥70% of accesses by a single user — migrate them solo</div>
        </div>
      </div>
    ROW

    tier_chip_for = {
      'tier_1_pilot'        => ['risk-clean', 'Pilot'],
      'tier_2_extended'     => ['risk-green', 'Extended'],
      'tier_3_needs_review' => ['risk-amber', 'After review'],
      'tier_4_long_tail'    => ['risk-red',   'Long-tail'],
      'no_activity'         => ['risk-mute',  'No activity']
    }

    dc_rows = users_analysis['users'].sort_by { |u| -u['total_accesses'].to_i }.map do |u|
      tier_cls, tier_label = tier_chip_for[u['decommission_tier']] || ['risk-mute', u['decommission_tier']]
      min_set_cell =
        if u['minimal_coverage_workbooks'].any?
          %(<details class="unique-detail"><summary>#{u['minimal_coverage_count']} workbook#{u['minimal_coverage_count'] == 1 ? '' : 's'} (#{u['minimal_coverage_pct']}% coverage)</summary>) +
          u['minimal_coverage_workbooks'].map { |w|
            in_pilot = pilot_names_set.include?(w)
            in_extended = extended_names_set.include?(w)
            in_review = review_names_set.include?(w)
            badge =
              if in_review
                %(<span class="muted" style="color:var(--warn);"> · needs review</span>)
              elsif in_pilot
                %(<span class="muted"> · pilot</span>)
              elsif in_extended
                %(<span class="muted"> · extended</span>)
              else
                %(<span class="muted"> · outside shortlist</span>)
              end
            %(<div>#{h(w)}#{badge}</div>)
          }.join +
          %(</details>)
        else
          '<span class="muted">—</span>'
        end

      blocker_cell =
        if (u['blocked_by_review_workbooks'] || []).any?
          u['blocked_by_review_workbooks'].first(2).map { |w| %(<div class="muted">#{h(w)}</div>) }.join
        elsif (u['missing_from_extended'] || []).any?
          u['missing_from_extended'].first(2).map { |w| %(<div class="muted">#{h(w)}</div>) }.join
        else
          '<span class="muted">—</span>'
        end

      [
        h(u['email']),
        h(u['license_type'] || '—'),
        %(<span class="risk-chip #{tier_cls}"><span class="risk-dot"></span>#{h(tier_label)}</span>),
        min_set_cell,
        blocker_cell
      ]
    end

    decommission_table_html = table(
      ['User', 'License', 'Decommission tier', 'Smallest migration set', 'Blocker / missing'],
      dc_rows,
      align: %w[left left left left left]
    )

    # Narrow-audience workbooks
    narrow_wbs = users_analysis['narrow_audience_workbooks'] || []
    narrow_html = ''
    if narrow_wbs.any?
      nw_rows = narrow_wbs.first(15).map do |w|
        primary_user = (w['primary_user'] || '').sub(/@.*/, '')
        [
          h(w['workbook']),
          w['total_accesses'],
          w['distinct_users'],
          h(primary_user),
          "#{w['primary_user_share_pct']}%"
        ]
      end
      narrow_html = "<h3>High-value, narrow-audience workbooks</h3>" +
        %(<p class="note">Workbooks with meaningful absolute usage (≥5 accesses) where one user accounts for ≥70% of activity. These are migration "easy wins" — moving them affects very few people, and they often unlock specific user seat decommissioning.</p>) +
        table(['Workbook', 'Total accesses', 'Distinct users', 'Primary user', 'Their share'],
              nw_rows, align: %w[left right right left right])
    end

    decommission_html = "<h3>License decommissioning readiness</h3>" +
      %(<p class="section-lede" style="margin-top:0;">For each user, the smallest set of workbooks that covers ≥90% of their actual activity. If that set is fully inside the migration plan, the user's Tableau seat can be decommissioned as soon as they move to Sigma.</p>) +
      decommission_stats +
      decommission_table_html +
      narrow_html
  end

  user_section_html = segment_table + coverage_stat_row + "<h3>Per-user detail (top 15 by activity)</h3>" + user_table + decommission_html
else
  user_section_html = ''
end

html += user_section_html

# ----------------------------------------------------------------- DATA SOURCES
html += <<~HTML
</section>

HTML

if has_ds_deep
  s = ds_analysis['summary']
  v = s['by_verdict']

  ds_stat_row = <<~ROW
    <div class="stat-row" style="grid-template-columns: repeat(4, 1fr);">
      <div class="stat #{v['drop-in'].positive? ? 'stat-go' : ''}">
        <div class="stat-l">Drop-in</div>
        <div class="stat-v #{v['drop-in'].positive? ? 'go' : ''}">#{v['drop-in']}</div>
        <div class="stat-sub">native Sigma support, no prep</div>
      </div>
      <div class="stat">
        <div class="stat-l">Verify</div>
        <div class="stat-v">#{v['verify-network'] + v['verify-db'] + v['verify-modeling']}</div>
        <div class="stat-sub">network / connector / modeling review</div>
      </div>
      <div class="stat #{v['land-in-warehouse'].positive? ? 'stat-warn' : ''}">
        <div class="stat-l">Land in warehouse</div>
        <div class="stat-v #{v['land-in-warehouse'].positive? ? 'warn' : ''}">#{v['land-in-warehouse']}</div>
        <div class="stat-sub">file-based — needs warehouse upload</div>
      </div>
      <div class="stat">
        <div class="stat-l">Duplicate clusters</div>
        <div class="stat-v">#{s['duplicate_clusters']}</div>
        <div class="stat-sub">covering #{s['sources_in_clusters']} sources</div>
      </div>
    </div>
  ROW

  # Verdict-prescriptions table
  verdict_meta = {
    'drop-in'           => ['risk-clean', 'Drop-in',           'Connect Sigma directly. No migration prep required.'],
    'verify-network'    => ['risk-amber', 'Verify network',     'Confirm Sigma can reach the host with your IT team.'],
    'verify-db'         => ['risk-amber', 'Verify connector',   'Confirm Sigma supports this database; plan additional setup.'],
    'verify-modeling'   => ['risk-amber', 'Verify modeling',    'Federated cross-source join — review whether Sigma model relationships replicate it.'],
    'resolve-published' => ['risk-amber', 'Resolve published',  'References another published datasource — resolve recursively to the underlying connection.'],
    'land-in-warehouse' => ['risk-red',   'Land in warehouse',  'File-based. Land in your warehouse first. Use the <code>tableau-vds-to-cdw</code> skill to auto-generate warehouse DDL (Snowflake or Databricks) + Sigma data model from the .tds.'],
    'other'             => ['risk-mute',  'Inspect',            'Mixed or unrecognized connection types — review individually.'],
    'unknown'           => ['risk-mute',  'Inspect',            'No connection metadata exposed (often Tableau Virtual Connections or Admin Insights internals) — review individually.']
  }
  verdict_rows = []
  verdict_meta.each do |verdict, (cls, label, action)|
    n = v[verdict] || 0
    next if n.zero?
    verdict_rows << [
      %(<span class="risk-chip #{cls}"><span class="risk-dot"></span>#{h(label)}</span>),
      n,
      action
    ]
  end
  verdict_table_html = table(['Verdict', 'Count', 'Recommended action'], verdict_rows,
                              align: %w[left right left])

  # Red-flag / land-in-warehouse named list (top 12 by name)
  flagged = ds_analysis['sources'].select { |src| %w[land-in-warehouse verify-network verify-db].include?(src['verdict']) }
  red_flag_html = ''
  if flagged.any?
    rf_rows = flagged.first(15).map do |src|
      types = src['upstream_connections'].map { |c| c['connection_type'] }.uniq.compact.join(', ')
      host = src['upstream_connections'].find { |c| c['host'] }&.dig('host')
      [
        h(src['name']),
        h(src['kind']),
        h(types),
        host ? %(<code>#{h(host)}</code>) : '<span class="muted">—</span>',
        h(src['parent_workbook'] || (src['downstream_workbooks'] || []).first || '—')
      ]
    end
    red_flag_html = "<h3>Sources requiring action</h3>" +
      table(['Source', 'Type', 'Connection class', 'Host', 'Workbook'], rf_rows,
            align: %w[left left left left left])
    if flagged.size > 15
      red_flag_html += %(<p class="note">+ #{flagged.size - 15} additional flagged sources — see <code>data-sources.json</code> for the full list.</p>)
    end
  end

  # Duplicate clusters
  cluster_html = ''
  if ds_analysis['similarity_clusters'].any?
    cl_rows = ds_analysis['similarity_clusters'].map do |c|
      members_html = c['members'].map { |m| "<div class='cluster-member'><strong>#{h(m['name'])}</strong> <span class='muted'>in #{h(m['workbook'] || '—')}</span></div>" }.join
      [
        c['cluster_id'],
        c['size'],
        c['avg_field_count'],
        members_html
      ]
    end
    cluster_html = "<h3>Duplicate / near-duplicate data sources</h3>" +
      %(<p class="note">Data sources whose field-name sets overlap by ≥75% — strong candidates for consolidation into a single canonical source.</p>) +
      table(['Cluster', 'Members', 'Avg fields', 'Sources'], cl_rows,
            align: %w[left right right left])
  end

  # Custom SQL inventory
  csql = ds_analysis['custom_sql'] || []
  csql_html = ''
  if csql.any?
    cs_rows = csql.map do |c|
      [
        h(c['name']),
        h(c['connection_type'] || '—'),
        c['query_size_chars'].to_i,
        c['downstream_workbooks'].size,
        c['downstream_datasources'].size
      ]
    end
    csql_html = "<h3>Custom SQL inventory</h3>" +
      table(['Query name', 'Connection', 'Query size (chars)', 'Workbooks', 'Datasources'], cs_rows,
            align: %w[left left right right right]) +
      %(<p class="note">Custom SQL blocks need individual review — the SQL text translates to Sigma using either a data-model SQL element or a Sigma materialized view. The <code>tableau-to-sigma</code> skill's Phase 1f extractor surfaces these for conversion.</p>)
  end

  # Per-datasource actual usage (top consumed sources + zero-access)
  ds_usage_html = ''
  if ds_usage && (ds_usage['datasources'] || []).any?
    accessed_names = Set.new((ds_usage['datasources'] || []).map { |d| d['datasource'] })
    all_ds_names = Set.new((ds_analysis['sources'] || []).map { |s| s['name'] })
    unused = (all_ds_names - accessed_names).to_a
    top_used = ds_usage['datasources'].first(10)
    if top_used.any?
      max_n = top_used.first['total_accesses'].to_i
      du_rows = top_used.map do |d|
        top_user_list = (d['top_users'] || []).first(2).map { |u|
          %(<div class="top-wb"><span>#{h(u['user'].sub(/@.*/, ''))}</span> <span class="muted">#{u['accesses']}</span></div>)
        }.join
        [
          %(<span>#{h(d['datasource'])}</span>),
          d['distinct_users'],
          bar_cell(d['total_accesses'], max_n),
          top_user_list.empty? ? '<span class="muted">—</span>' : %(<div>#{top_user_list}</div>)
        ]
      end
      ds_usage_html += "<h3>Data sources by actual consumption</h3>" +
        %(<p class="note">Top 10 data sources by all-time access events. Sources that workbooks reference but nobody actually opens are migration-irrelevant — and #{unused.size} data source#{unused.size == 1 ? '' : 's'} on this site have zero accesses.</p>) +
        table(['Data source', 'Distinct users', 'Total accesses', 'Top users'], du_rows,
              align: %w[left right left left])
      if unused.any?
        ds_usage_html += %(<p class="note"><strong>Unused data sources (#{unused.size}):</strong> ) +
                         unused.first(20).map { |n| %(<code>#{h(n)}</code>) }.join(', ') +
                         (unused.size > 20 ? " + #{unused.size - 20} more" : '') + '.</p>'
      end
    end
  end

  html += <<~HTML
  <section>
    <div class="section-head">
      <span class="section-num">04</span>
      <h2 class="section-title">Data sources &amp; lineage</h2>
      <span class="section-aside">#{s['total']} sources · #{s['published_count']} published · #{s['embedded_count']} embedded</span>
    </div>
    <p class="section-lede">Every data source on the site classified by Sigma readiness, plus duplicate detection, custom SQL inventory, and connection-host inspection. This is the section that drives the most migration prep work, so it's also the most prescriptive.</p>

    #{ds_stat_row}
    #{verdict_table_html}
    #{red_flag_html}
    #{cluster_html}
    #{ds_usage_html}
    #{csql_html}
  </section>

  HTML
else
  # Fallback: keep the old summary
  html += <<~HTML
  <section>
    <div class="section-head">
      <span class="section-num">04</span>
      <h2 class="section-title">Data source types &amp; patterns</h2>
    </div>
    <p class="section-lede">How data flows into your Tableau workbooks. Published data sources can be governed centrally; embedded data sources live inside individual workbooks and are harder to maintain at scale.</p>
    #{ds_html}
    <p class="note"><strong>#{n_published_extracts} published extracts</strong> are the easy-to-relocate sources. <strong>#{n_embedded} embedded</strong> sources spread across individual workbooks signal sprawl.</p>
  </section>

  HTML
end

# ----------------------------------------------------------------- PREP FLOWS
if has_ds_deep && (ds_analysis['prep_flows'] || []).any?
  flows = ds_analysis['prep_flows']
  n_orphan = flows.count { |f| f['is_orphan'] }
  n_used   = flows.size - n_orphan
  flow_rows = flows.map do |f|
    status =
      if f['is_orphan']
        %(<span class="risk-chip risk-mute"><span class="risk-dot"></span>Orphan</span>)
      else
        %(<span class="risk-chip risk-clean"><span class="risk-dot"></span>Active</span>)
      end
    [
      h(f['name']),
      status,
      (f['downstream_datasources'] || []).size,
      (f['downstream_workbooks'] || []).size,
      h(f['upstream_connection_types'].uniq.join(', '))
    ]
  end
  flow_table_html = table(
    ['Flow', 'Status', 'Downstream datasources', 'Downstream workbooks', 'Upstream connection types'],
    flow_rows,
    align: %w[left left right right left]
  )

  html += <<~HTML
  <section>
    <div class="section-head">
      <span class="section-num">05</span>
      <h2 class="section-title">Tableau Prep flows</h2>
      <span class="section-aside">#{flows.size} flows · #{n_used} active · #{n_orphan} orphan</span>
    </div>
    <p class="section-lede">Tableau Prep workflows transform data before it lands in a workbook or published datasource. <strong>Tableau Prep is out of scope for the automated migration to Sigma</strong> — Sigma's data preparation paradigm is different (modeling in data models, not visual flow editors). Active flows need a separate migration plan; orphan flows are retirement candidates.</p>

    #{flow_table_html}

    #{n_used.positive? ?
      %(<div class="callout"><strong>#{n_used} active flow#{n_used == 1 ? '' : 's'}</strong> feed downstream content and will need a separate migration path. Recommended approach: re-implement the transformation logic in dbt, Snowflake stored procedures, or a Sigma data model — whichever fits your team's existing patterns.</div>) :
      '<p class="note">No active Prep flows — all flows present are orphans and can be retired.</p>'}
  </section>

  HTML
end

# ----------------------------------------------------------------- PERFORMANCE
if has_perf
  ps  = perf_analysis['summary'] || {}
  pvs = perf_analysis['views']   || []
  slow_rows = pvs.first(15).map do |v|
    sev_cls = case v['severity']
              when 'red'    then 'risk-red'
              when 'amber'  then 'risk-amber'
              when 'yellow' then 'risk-green'
              else 'risk-clean'
              end
    sev_label = { 'red' => '≥10s', 'amber' => '5–10s', 'yellow' => '2–5s', 'green' => '<2s' }[v['severity']] || v['severity']
    [
      h(v['view']),
      h(v['workbook']),
      %(<span class="risk-chip #{sev_cls}"><span class="risk-dot"></span>#{format('%.1fs', v['avg_load_s'])}</span>),
      format('%.1fs', v['max_load_s']),
      v['loads'],
      format('%.0fs', v['total_wait_s'])
    ]
  end
  slow_table = table(
    ['View', 'Workbook', 'Avg load', 'Max load', 'Loads', 'Total wait'],
    slow_rows,
    align: %w[left left left right right right]
  )

  perf_section_num = has_ds_deep ? '06' : '05'
  html += <<~HTML
  <section>
    <div class="section-head">
      <span class="section-num">#{perf_section_num}</span>
      <h2 class="section-title">Performance hotspots</h2>
      <span class="section-aside">#{ps['total_loads']} loads · avg #{ps['avg_load_s']}s</span>
    </div>
    <p class="section-lede">Per-view load durations from the Viz Load Times audit log, ranked by total wait time (avg load × number of loads). Slow, frequently-loaded views are high-impact migration candidates — moving them to Sigma is the easiest performance win you can show end users.</p>

    <div class="stat-row">
      <div class="stat #{ps['p_red'].to_i.positive? ? 'stat-warn' : ''}">
        <div class="stat-l">Slow views (≥10s avg)</div>
        <div class="stat-v #{ps['p_red'].to_i.positive? ? 'warn' : ''}">#{ps['p_red']}</div>
        <div class="stat-sub">migration would deliver visible speed-up</div>
      </div>
      <div class="stat">
        <div class="stat-l">Borderline (5–10s avg)</div>
        <div class="stat-v">#{ps['p_amber']}</div>
        <div class="stat-sub">noticeable lag for end users</div>
      </div>
      <div class="stat">
        <div class="stat-l">Site-wide avg load</div>
        <div class="stat-v">#{ps['avg_load_s']}<span style="font-size:16px;color:var(--mute);font-weight:600;">s</span></div>
        <div class="stat-sub">weighted by load count</div>
      </div>
    </div>

    #{slow_table}
  </section>

  HTML
end

# ----------------------------------------------------------------- REFRESH
# Section numbering reshuffles when new sections are present
sec = { ds_deep: has_ds_deep, prep: has_ds_deep && !(ds_analysis && (ds_analysis['prep_flows'] || []).empty?), perf: has_perf }
# Base offset: 03 (user pop) + 04 (data sources if ds_deep else simple) + 05 (prep if present) + 06 (perf if present) + refresh
next_sec = 4
next_sec += 1 if sec[:ds_deep]   # +1 for the DS deep dive (replaces simple v.s old layout, but always present in PAT mode)
next_sec += 1 if sec[:prep]
next_sec += 1 if sec[:perf]
refresh_section_num = format('%02d', next_sec)

html += <<~HTML
<section>
  <div class="section-head">
    <span class="section-num">#{refresh_section_num}</span>
    <h2 class="section-title">Dataset refresh insights</h2>
  </div>
  <p class="section-lede">Background job activity for extract refreshes, flow runs, and other scheduled tasks.</p>
  #{refresh_html}
</section>

HTML

next_sec += 1
migration_num = format('%02d', next_sec)
priv_num      = format('%02d', has_shortlist ? next_sec + 2 : next_sec)
next_num      = format('%02d', has_shortlist ? next_sec + 3 : next_sec + 1)

# ---------- estimated migration effort (token model) ----------
effort_html = ''
token_model_path = File.join(__dir__, '..', 'refs', 'token-model.json')
if has_shortlist && File.exist?(token_model_path)
  tm = JSON.parse(File.read(token_model_path)) rescue nil
  if tm
    bucket  = 'tableau'
    n_dash  = shortlist.size
    n_rev   = n_with_unhandled
    pd      = (tm['per_dashboard'] || {})[bucket] || {}
    pr      = tm['per_review_item'] || {}
    cal     = tm['calibration'] || {}
    est = lambda { |m| (pd["#{m}_usd"].to_f * n_dash) + (pr["#{m}_usd"].to_f * n_rev) }
    opus_usd   = est.call('opus')
    sonnet_usd = est.call('sonnet')
    fmt = lambda { |v| '$' + format('%.2f', v) }
    effort_num = format('%02d', next_sec + 1)
    effort_html = <<~HTML
      <section>
        <div class="section-head">
          <span class="section-num">#{effort_num}</span>
          <h2 class="section-title">Estimated migration effort (tokens / $)</h2>
          <span class="section-aside">one-shot orchestrator path</span>
        </div>
        <p class="section-lede">A planning estimate of the LLM cost to migrate the shortlisted workbooks via the <code>tableau-to-sigma</code> one-shot orchestrator. Tableau has no mechanical converter — the data-model and workbook specs are agent-authored — so per-workbook cost is higher and scales with calc / LOD / custom-SQL complexity. Each workbook flagged for review adds one human-decision round.</p>
        <div class="stat-row">
          <div class="stat stat-go">
            <div class="stat-l">Estimated cost · Opus</div>
            <div class="stat-v go">#{fmt.call(opus_usd)}</div>
            <div class="stat-sub">#{n_dash} workbooks + #{n_rev} review</div>
          </div>
          <div class="stat">
            <div class="stat-l">Estimated cost · Sonnet</div>
            <div class="stat-v">#{fmt.call(sonnet_usd)}</div>
            <div class="stat-sub">same scope, Sonnet pricing</div>
          </div>
          <div class="stat">
            <div class="stat-l">Basis</div>
            <div class="stat-v" style="font-size:20px;">#{n_dash}<span style="font-size:14px;color:var(--mute);font-weight:600;"> × per-dashboard</span></div>
            <div class="stat-sub">+ #{n_rev} item#{n_rev == 1 ? '' : 's'} need review</div>
          </div>
        </div>
        <table class="data">
          <thead>
            <tr><th>Component</th><th class="al-right">Opus</th><th class="al-right">Sonnet</th></tr>
          </thead>
          <tbody>
            <tr><td>#{n_dash} workbooks × per-dashboard</td><td class="al-right num">#{fmt.call(pd['opus_usd'].to_f * n_dash)}</td><td class="al-right num">#{fmt.call(pd['sonnet_usd'].to_f * n_dash)}</td></tr>
            <tr><td>+ #{n_rev} item#{n_rev == 1 ? '' : 's'} need review</td><td class="al-right num">#{fmt.call(pr['opus_usd'].to_f * n_rev)}</td><td class="al-right num">#{fmt.call(pr['sonnet_usd'].to_f * n_rev)}</td></tr>
            <tr><td><strong>Total estimated</strong></td><td class="al-right num"><strong>#{fmt.call(opus_usd)}</strong></td><td class="al-right num"><strong>#{fmt.call(sonnet_usd)}</strong></td></tr>
          </tbody>
        </table>
        <p class="note">Calibrated #{h(cal['date'])}, one-shot orchestrator path — LLM cost only; rescale $ by your coding agent's pricing. A naive agent-driven migration is ~12–20× more expensive. The Tableau number is an estimate (specs are agent-authored, not yet benchmarked on the orchestrator path).</p>
      </section>
    HTML
  end
end

if has_shortlist
  html += <<~HTML
  <section>
    <div class="section-head">
      <span class="section-num">#{migration_num}</span>
      <h2 class="section-title">Migration to Sigma — recommended sequence</h2>
      <span class="section-aside">Sigma-specific recommendations</span>
    </div>
    <p class="section-lede">If you choose to migrate to Sigma, this is the order that minimizes risk while covering the most user impact. Workbooks are ranked by usage value relative to conversion complexity. The top of the list is the recommended starting point for a pilot.</p>

    <div class="stat-row">
      <div class="stat">
        <div class="stat-l">Top-5 site usage share</div>
        <div class="stat-v">#{top5_pct}<span style="font-size: 16px; color: var(--mute); font-weight: 600;">%</span></div>
        <div class="stat-sub">of #{num(total_accesses)} total accesses</div>
      </div>
      <div class="stat stat-#{sl_top5_unhandled.zero? ? 'go' : 'warn'}">
        <div class="stat-l">Top-5 conversion complexity</div>
        <div class="stat-v #{sl_top5_unhandled.zero? ? 'go' : 'warn'}">#{sl_top5_unhandled}</div>
        <div class="stat-sub">advanced features to review across pilot</div>
      </div>
      <div class="stat">
        <div class="stat-l">Needs review · Retire</div>
        <div class="stat-v">#{sl_needs_scout}<span style="font-size: 16px; color: var(--mute); font-weight: 600;"> · #{sl_retire}</span></div>
        <div class="stat-sub">workbooks of #{shortlist.size} total</div>
      </div>
    </div>

    #{shortlist_html}

    #{sl_total_unhandled.positive? ?
      %(<div class="callout"><strong>#{n_with_unhandled} workbook#{n_with_unhandled == 1 ? '' : 's'}</strong> include features that warrant individual review when planning their conversion — typically advanced Tableau capabilities (custom marks, complex table calculations, level-of-detail expressions) where the right Sigma equivalent depends on how the workbook actually uses them. Identifying these up-front means no surprises mid-migration.</div>) : ''}
  </section>

  HTML
end

html += effort_html

html += <<~HTML
<section class="section-tight">
  <div class="section-head">
    <span class="section-num">#{priv_num}</span>
    <h2 class="section-title">Data handling</h2>
  </div>
  <p class="section-lede">This report was generated by an LLM-driven scan of your Tableau site. What that means for the data that left your environment:</p>
  <div class="priv-grid">
    <div class="priv-col crossed">
      <h3>Read by the scanner</h3>
      <ul>
        <li>Aggregate counts (workbook, user, data source, refresh job totals)</li>
        <li>Workbook names, owner emails, project names</li>
        <li>License-type counts and last-login dates</li>
HTML

if has_shortlist
  html += "<li>Workbook XML for #{n_scanned} workbooks (calculated-field definitions, custom SQL text, layout)</li>\n"
end

html += <<~HTML
      </ul>
    </div>
    <div class="priv-col local">
      <h3>Never left your environment</h3>
      <ul>
        <li>Underlying warehouse rows — the scan never queries source data</li>
        <li>Extract files (<code>.hyper</code>) — skipped during workbook downloads</li>
        <li>Database credentials</li>
        <li>View CSV contents — never fetched</li>
      </ul>
    </div>
  </div>
</section>

<section class="section-tight">
  <div class="section-head">
    <span class="section-num">#{next_num}</span>
    <h2 class="section-title">Recommended next steps</h2>
  </div>
  <ol class="next-steps">
HTML

if has_shortlist
  html += <<~HTML
    <li><strong>Pilot the top #{[5, shortlist.size].min} workbooks.</strong> They represent #{top5_pct}% of total site usage with #{sl_top5_unhandled} feature#{sl_top5_unhandled == 1 ? '' : 's'} flagged for review between them — the lowest-risk way to demonstrate end-to-end migration.</li>
  HTML
  if sl_needs_scout.positive?
    html += "    <li><strong>Plan individual review time for #{sl_needs_scout} workbook#{sl_needs_scout == 1 ? '' : 's'}.</strong> Each contains an advanced Tableau capability that benefits from a tailored conversion approach — identifying them up-front prevents surprises mid-migration.</li>\n"
  end
  if sl_retire.positive?
    html += "    <li><strong>Retire #{sl_retire} workbook#{sl_retire == 1 ? '' : 's'}</strong> with zero accesses. No migration value, and dropping them simplifies the cutover.</li>\n"
  end
  html += "    <li><strong>For a deeper assessment</strong>, install Hakkoda's Assessment App from the Snowflake Marketplace — it adds pricing scenarios, dataset similarity analysis, and a full permissions audit while keeping all data inside your Snowflake account.</li>\n"
else
  html += <<~HTML
    <li><strong>Enable per-workbook conversion analysis</strong> by configuring a Tableau Personal Access Token. This unlocks the migration shortlist and conversion-cost profile.</li>
    <li><strong>For a deeper assessment</strong>, install Hakkoda's Assessment App from the Snowflake Marketplace.</li>
  HTML
end

html += <<~HTML
  </ol>
</section>

<footer>
  Report generated #{h(formatted_date)} · supporting JSON files alongside in the same folder
</footer>

</main>
</body>
</html>
HTML

out_path = File.join(opts[:out], 'readout.html')
File.write(out_path, html)
puts "wrote #{out_path} (#{File.size(out_path)} bytes)"
