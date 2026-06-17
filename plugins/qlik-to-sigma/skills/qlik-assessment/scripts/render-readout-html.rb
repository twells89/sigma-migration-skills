#!/usr/bin/env ruby
# Render <out>/readout.html — a customer-facing, share-friendly HTML report for a
# Qlik Cloud → Sigma migration assessment.
#
# Consumes <out>/inventory.json written by qlik-inventory.py (apps + per-app
# complexity + shortlist + ownership + data-connection + reload rollups). The
# Sigma-branded theme is copied verbatim from tableau-assessment's
# render-readout-html.rb so the look is byte-identical across the assessment
# family; only the vocabulary (app / sheet / master measure / space / data
# connection / Section Access / DirectQuery / reload task) is Qlik-specific.
#
# Usage: ruby scripts/render-readout-html.rb --out /tmp/assessment-<tenant>

require 'json'
require 'optparse'
require 'cgi'
require 'set'
require 'date'

opts = {}
OptionParser.new do |p|
  p.on('--out DIR') { |v| opts[:out] = v }
end.parse!
abort('--out required') unless opts[:out]

inv_path = File.join(opts[:out], 'inventory.json')
abort("inventory.json not found in #{opts[:out]}") unless File.exist?(inv_path)
inventory = JSON.parse(File.read(inv_path))

def h(s); CGI.escapeHTML(s.to_s); end
def num(n); n.to_i.to_s.reverse.scan(/.{1,3}/).join(',').reverse; end

# ---------- gather computed values ----------
tenant = inventory['tenant'] || {}
env    = inventory['environment_overview'] || {}
dsrc   = inventory['data_sources'] || {}
reload = inventory['reload_activity'] || {}
ownership = inventory['ownership'] || []
dups   = inventory['duplicate_dashboards'] || {}
shortlist = inventory['shortlist'] || []

tenant_name = tenant['name'] || inventory['tenant'].is_a?(String) ? (tenant['name'] || inventory['tenant']) : 'unknown'
tenant_name = 'unknown' if tenant_name.nil? || tenant_name.to_s.empty?
tenant_url  = tenant['url'] || ''
generated_at = tenant['generated_at'] || Time.now.strftime('%Y-%m-%d')
formatted_date = Date.parse(generated_at).strftime('%B %d, %Y') rescue generated_at

has_shortlist = !shortlist.empty?
dup_summary = dups['summary'] || {}
dup_groups  = dups['groups'] || []
has_dups    = !dup_groups.empty?
has_complexity = shortlist.any? { |r| (r['n_auto'].to_i + r['n_manual'].to_i + r['n_unhandled'].to_i) > 0 || (r['measure_buckets'] || {}).any? }

# Usage
total_views = shortlist.sum { |r| r['views'].to_i }
cold_apps   = shortlist.select { |r| r['views'].to_i.zero? }

# Shortlist rollups
sl_top5_views     = shortlist.first(5).sum { |r| r['views'].to_i }
sl_top5_unhandled = shortlist.first(5).sum { |r| r['n_unhandled'].to_i }
sl_total_unhandled = shortlist.sum { |r| r['n_unhandled'].to_i }
sl_needs_scout    = shortlist.count { |r| r['tag'] == 'needs-gap-scout' }
sl_retire         = shortlist.count { |r| r['tag'] == 'retire' }
sl_migrate_first  = shortlist.count { |r| r['tag'] == 'migrate-first' }
n_with_unhandled  = shortlist.count { |r| r['n_unhandled'].to_i.positive? }
top5_pct = total_views.zero? ? 0 : (sl_top5_views.to_f / total_views * 100).round

# Top owner concentration
top_owner_pct = 0
top_owner_name = '—'
total_owner_apps = ownership.sum { |o| o['apps'].to_i }
if total_owner_apps > 0
  top = ownership.max_by { |o| o['apps'].to_i }
  top_owner_pct = (top['apps'].to_f / total_owner_apps * 100).round
  top_owner_name = top['owner']
end

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

def kpi(label, value, sub = nil)
  s = sub ? %(<div class="kpi-sub">#{h(sub)}</div>) : ''
  %(<div class="kpi"><div class="kpi-v">#{h(value)}</div><div class="kpi-l">#{h(label)}</div>#{s}</div>)
end

# ---------- section rendering ----------

# Hero: headline finding
hero_finding =
  if has_shortlist
    if sl_top5_unhandled.zero? && sl_migrate_first.positive?
      'Pilot migration is low-risk: the top 5 most-used apps contain no unsupported Qlik features.'
    elsif sl_total_unhandled.positive?
      "The top-5 pilot is feasible. #{n_with_unhandled} app#{n_with_unhandled == 1 ? '' : 's'} elsewhere on the tenant include feature#{n_with_unhandled == 1 ? '' : 's'} (Set Analysis, Aggr(), alternate states) that warrant individual review when planning their conversion."
    else
      'Migration shortlist ranked by usage and conversion complexity.'
    end
  else
    'Environment scan complete.'
  end

# Section 1: KPI tiles
kpi_html = [
  kpi('Apps',            env['apps']),
  kpi('Sheets',          env['sheets']),
  kpi('Master measures', env['master_measures']),
  kpi('Spaces',          env['spaces']),
  kpi('Data connections', env['data_connections']),
  kpi('Total app views', num(total_views), '28-day rolling window')
].join

# Section 2: App priority & usage
usage_html = ''
unless shortlist.empty?
  ranked = shortlist.sort_by { |r| -r['views'].to_i }
  max_v = ranked.first['views'].to_i
  rows = ranked.first(10).each_with_index.map do |r, i|
    flags = []
    flags << 'Section Access' if r['sectionAccess']
    flags << 'DirectQuery'    if r['directQuery']
    flag_cell = flags.empty? ? '<span class="muted">—</span>' : flags.map { |f| %(<span class="inline-pill">#{h(f)}</span>) }.join(' ')
    %(<tr>
      <td class="rank">#{i + 1}</td>
      <td>#{h(r['name'])}</td>
      <td class="muted">#{h((r['owner'] || '—').to_s.sub(/@.*/, ''))}</td>
      <td>#{bar_cell(r['views'], max_v)}</td>
      <td>#{flag_cell}</td>
    </tr>)
  end.join
  usage_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th class="al-right">#</th>
          <th>App</th>
          <th>Owner</th>
          <th>Views</th>
          <th>Flags</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 3: Ownership & concentration
ownership_html = ''
unless ownership.empty?
  rows_data = ownership.sort_by { |o| -o['apps'].to_i }
  max_apps = rows_data.first['apps'].to_i
  rows = rows_data.first(15).map do |o|
    %(<tr>
      <td>#{h((o['owner'] || '—').to_s.sub(/@.*/, ''))}</td>
      <td>#{bar_cell(o['apps'], max_apps)}</td>
      <td class="al-right num muted">#{num(o['views'])}</td>
      <td class="al-right num muted">#{num(o['measures'])}</td>
    </tr>)
  end.join
  ownership_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Owner</th>
          <th>Apps</th>
          <th class="al-right">Views</th>
          <th class="al-right">Master measures</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 4: Data-source / load-script patterns
ds_html = ''
conn_rows = (dsrc['connection_types'] || [])
unless conn_rows.empty?
  max_n = conn_rows.map { |r| r['n'].to_i }.max || 1
  rows = conn_rows.sort_by { |r| -r['n'].to_i }.map do |r|
    file_like = r['type'].to_s.match?(/qvd|csv|xls|txt|file|folder/i)
    badge = file_like ? '<span class="ds-bucket ds-embedded">file-based</span>' : '<span class="ds-bucket ds-published">warehouse / live</span>'
    %(<tr>
      <td><code>#{h(r['type'])}</code></td>
      <td>#{badge}</td>
      <td>#{bar_cell(r['n'], max_n)}</td>
    </tr>)
  end.join
  ds_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Connection type</th>
          <th>Class</th>
          <th>Count</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 5: Reload activity
reload_html = ''
rl_rows = (reload['by_status'] || [])
unless rl_rows.empty?
  rows = rl_rows.map do |b|
    ok = b['status'].to_s.match?(/succ|ok|done/i)
    result_cls = ok ? 'tag-go' : (b['status'].to_s.match?(/fail|error/i) ? 'tag-warn' : 'tag-gray')
    %(<tr>
      <td><span class="tag #{result_cls}">#{h(b['status'])}</span></td>
      <td class="al-right num">#{num(b['n'])}</td>
    </tr>)
  end.join
  reload_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Reload status</th>
          <th class="al-right">Apps</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# ---------- estimated migration effort (token model) ----------
effort_html = ''
token_model_path = File.join(__dir__, '..', 'refs', 'token-model.json')
if has_shortlist && File.exist?(token_model_path)
  tm = JSON.parse(File.read(token_model_path)) rescue nil
  if tm
    bucket  = 'mechanical'
    n_dash  = shortlist.size
    n_rev   = n_with_unhandled
    pd      = (tm['per_dashboard'] || {})[bucket] || {}
    pr      = tm['per_review_item'] || {}
    cal     = tm['calibration'] || {}
    est = lambda { |m| (pd["#{m}_usd"].to_f * n_dash) + (pr["#{m}_usd"].to_f * n_rev) }
    opus_usd   = est.call('opus')
    sonnet_usd = est.call('sonnet')
    fmt = lambda { |v| '$' + format('%.2f', v) }
    effort_html = <<~HTML
      <section>
        <div class="section-head">
          <span class="section-num">07</span>
          <h2 class="section-title">Estimated migration effort (tokens / $)</h2>
          <span class="section-aside">one-shot orchestrator path</span>
        </div>
        <p class="section-lede">A planning estimate of the LLM cost to migrate the shortlisted apps via the <code>qlik-to-sigma</code> one-shot orchestrator. The mechanical model converter is deterministic, so per-app cost is flat; each app flagged for review adds one human-decision round.</p>
        <div class="stat-row">
          <div class="stat stat-go">
            <div class="stat-l">Estimated cost · Opus</div>
            <div class="stat-v go">#{fmt.call(opus_usd)}</div>
            <div class="stat-sub">#{n_dash} apps + #{n_rev} review</div>
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
            <tr><td>#{n_dash} apps × per-dashboard</td><td class="al-right num">#{fmt.call(pd['opus_usd'].to_f * n_dash)}</td><td class="al-right num">#{fmt.call(pd['sonnet_usd'].to_f * n_dash)}</td></tr>
            <tr><td>+ #{n_rev} item#{n_rev == 1 ? '' : 's'} need review</td><td class="al-right num">#{fmt.call(pr['opus_usd'].to_f * n_rev)}</td><td class="al-right num">#{fmt.call(pr['sonnet_usd'].to_f * n_rev)}</td></tr>
            <tr><td><strong>Total estimated</strong></td><td class="al-right num"><strong>#{fmt.call(opus_usd)}</strong></td><td class="al-right num"><strong>#{fmt.call(sonnet_usd)}</strong></td></tr>
          </tbody>
        </table>
        <p class="note">Calibrated #{h(cal['date'])}, one-shot orchestrator path — LLM cost only; rescale $ by your coding agent's pricing. A naive agent-driven migration is ~12–20× more expensive.</p>
      </section>
    HTML
  end
end

# ---------- HTML ----------
html = <<~HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Qlik Cloud Environment Report — #{h(tenant_name)}</title>
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
  <div class="doc-eyebrow">Qlik Cloud Environment Report</div>
  <h1 class="doc-title">#{h(tenant_name)}</h1>
  <div class="doc-meta">
    #{tenant_url.empty? ? '' : %(<a href="#{h(tenant_url)}" target="_blank" rel="noopener">#{h(tenant_url)}</a> · )}
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
    <h2 class="section-title">App priority &amp; usage</h2>
    <span class="section-aside">Top 10 of #{env['apps']} apps · #{num(total_views)} total views</span>
  </div>
  <p class="section-lede">Most-used apps across the tenant, ranked by view count. This is the foundation of any migration or consolidation plan — focus effort where audience attention already is.</p>
  #{usage_html}
  <p class="note">Qlik's <code>itemViews</code> is a <strong>28-day rolling window</strong>, not all-time — an app with zero views here is cold over the last month, which is still the right retirement signal.</p>
  #{cold_apps.any? ? %(<p class="note"><strong>#{cold_apps.size} app#{cold_apps.size == 1 ? '' : 's'}</strong> have no views in the last 28 days: ) + cold_apps.first(20).map { |w| %(<code>#{h(w['name'])}</code>) }.join(', ') + ' — strong candidates for retirement.</p>' : ''}
</section>

<section>
  <div class="section-head">
    <span class="section-num">03</span>
    <h2 class="section-title">Ownership &amp; concentration</h2>
    <span class="section-aside">#{ownership.size} owners across #{env['apps']} apps</span>
  </div>
  <p class="section-lede">App ownership concentration across the tenant. High concentration in one or two owners is a governance signal — what happens to those apps if that person leaves?</p>
  #{ownership_html}
  <p class="note">Top-owner concentration: <strong>#{top_owner_pct}%</strong> of apps owned by <code>#{h((top_owner_name || '—').to_s.sub(/@.*/, ''))}</code>.</p>
</section>

<section>
  <div class="section-head">
    <span class="section-num">04</span>
    <h2 class="section-title">Data sources &amp; load-script patterns</h2>
    <span class="section-aside">#{dsrc['n_connections']} connections · #{dsrc['n_directquery_apps']} DirectQuery · #{dsrc['n_inmemory_apps']} in-memory</span>
  </div>
  <p class="section-lede">How data flows into your Qlik apps. <strong>DirectQuery</strong> apps already query a live warehouse — they map cleanly to a Sigma warehouse connection. <strong>In-memory</strong> apps reload into the Qlik engine from QVDs, files, or warehouse extracts; the load script's source is what Sigma re-points to. File-based sources (QVD/CSV/Excel) must be landed in a warehouse first.</p>

  <div class="stat-row">
    <div class="stat #{dsrc['n_directquery_apps'].to_i.positive? ? 'stat-go' : ''}">
      <div class="stat-l">DirectQuery apps</div>
      <div class="stat-v #{dsrc['n_directquery_apps'].to_i.positive? ? 'go' : ''}">#{dsrc['n_directquery_apps'] || 0}</div>
      <div class="stat-sub">already live-query — drop-in to a Sigma connection</div>
    </div>
    <div class="stat">
      <div class="stat-l">In-memory apps</div>
      <div class="stat-v">#{dsrc['n_inmemory_apps'] || 0}</div>
      <div class="stat-sub">reload from QVD / file / warehouse extract</div>
    </div>
    <div class="stat #{dsrc['n_file_based_connections'].to_i.positive? ? 'stat-warn' : ''}">
      <div class="stat-l">File-based connections</div>
      <div class="stat-v #{dsrc['n_file_based_connections'].to_i.positive? ? 'warn' : ''}">#{dsrc['n_file_based_connections'] || 0}</div>
      <div class="stat-sub">QVD / CSV / Excel — land in warehouse first</div>
    </div>
  </div>

  #{ds_html}
  #{dsrc['n_section_access_apps'].to_i.positive? ? %(<div class="callout"><strong>#{dsrc['n_section_access_apps']} app#{dsrc['n_section_access_apps'] == 1 ? '' : 's'}</strong> use <strong>Section Access</strong> (row-level security in the load script). These translate to Sigma's column/row-level security on the data model — plan to re-author the access rules rather than auto-convert them.</div>) : ''}
</section>

<section>
  <div class="section-head">
    <span class="section-num">05</span>
    <h2 class="section-title">Reload activity</h2>
    #{reload['avg_duration_s'] ? %(<span class="section-aside">avg #{reload['avg_duration_s']}s · max #{reload['max_duration_s']}s · #{reload['n_with_duration']} timed</span>) : ''}
  </div>
  <p class="section-lede">Reload-task health across apps. In-memory Qlik apps depend on a scheduled reload to stay fresh; failing or long-running reloads are migration motivation, since Sigma queries the warehouse live and removes the reload step entirely.</p>
  #{reload_html}
  #{reload['avg_duration_s'] ? %(<p class="note">Average last-reload duration <strong>#{reload['avg_duration_s']}s</strong> (max <strong>#{reload['max_duration_s']}s</strong>) across #{reload['n_with_duration']} app#{reload['n_with_duration'] == 1 ? '' : 's'} reporting a duration.</p>) : ''}
</section>

HTML

# Section 6: Migration shortlist + per-app complexity
if has_shortlist
  max_v = shortlist.map { |r| r['views'].to_i }.max || 1
  sl_rows = shortlist.first(15).map do |r|
    risk_cls, risk_txt =
      if r['n_unhandled'].to_i.positive?
        ['risk-red',   "#{r['n_unhandled']} to review"]
      elsif r['n_manual'].to_i.positive?
        ['risk-amber', "#{r['n_manual']} setup"]
      elsif r['n_hint'].to_i.positive?
        ['risk-green', "#{r['n_hint']} suggested"]
      else
        ['risk-clean', 'No issues']
      end
    %(<tr>
      <td>#{h(r['name'])}</td>
      <td>#{bar_cell(r['views'], max_v)}</td>
      <td><span class="risk-chip #{risk_cls}"><span class="risk-dot"></span>#{h(risk_txt)}</span></td>
      <td class="al-right num">#{format('%.1f', r['score'].to_f)}</td>
      <td>#{tag_pill(r['tag'])}</td>
    </tr>)
  end.join
  shortlist_table = <<~HTML
    <table class="data shortlist">
      <thead>
        <tr>
          <th>App</th>
          <th>Views</th>
          <th>Conversion risk</th>
          <th class="al-right">Score</th>
          <th>Recommendation</th>
        </tr>
      </thead>
      <tbody>#{sl_rows}</tbody>
    </table>
    <p class="note">Conversion risk legend: <strong>No issues</strong> = converts automatically · <strong>N setup</strong> = brief post-conversion setup in Sigma (Set Analysis → <code>SumIf</code>, binning, Section Access, DirectQuery) · <strong>N to review</strong> = uses a Qlik feature with no direct Sigma equivalent (Aggr(), Dual(), selection-state, alternate states) that warrants individual evaluation when planning the conversion.</p>
  HTML

  # Per-app complexity table
  complexity_table = ''
  if has_complexity
    crows = shortlist.sort_by { |r| -(r['n_unhandled'].to_i * 10 + r['n_manual'].to_i * 3 + r['n_hint'].to_i) }.map do |r|
      mb = r['measure_buckets'] || {}
      n_viz = (r['viz_types'] || {}).values.sum
      unh_cell = r['n_unhandled'].to_i.positive? ? %(<span class="warn-num">#{r['n_unhandled']}</span>) : '<span class="muted">0</span>'
      %(<tr>
        <td>#{h(r['name'])}</td>
        <td class="al-right num muted">#{r['measures'] || (mb.values.sum)}</td>
        <td class="al-right num muted">#{n_viz}</td>
        <td class="al-right num muted">#{r['n_auto']}</td>
        <td class="al-right num">#{r['n_manual']}</td>
        <td class="al-right">#{unh_cell}</td>
      </tr>)
    end.join
    complexity_table = <<~HTML
      <h3>Per-app complexity</h3>
      <p class="section-lede" style="margin-top:0;">Master-measure expressions and chart viz types bucketed against Sigma coverage. <strong>Auto</strong> converts mechanically; <strong>Setup</strong> = Set Analysis / binning / Section Access / DirectQuery (brief manual step); <strong>Review</strong> = Aggr() / Dual() / selection-state / alternate states (no direct Sigma equivalent).</p>
      <table class="data">
        <thead>
          <tr>
            <th>App</th>
            <th class="al-right">Master measures</th>
            <th class="al-right">Charts</th>
            <th class="al-right">Auto</th>
            <th class="al-right">Setup</th>
            <th class="al-right">Review</th>
          </tr>
        </thead>
        <tbody>#{crows}</tbody>
      </table>
    HTML
  end

  html += <<~HTML
  <section>
    <div class="section-head">
      <span class="section-num">06</span>
      <h2 class="section-title">Migration to Sigma — recommended sequence</h2>
      <span class="section-aside">Sigma-specific recommendations</span>
    </div>
    <p class="section-lede">If you choose to migrate to Sigma, this is the order that minimizes risk while covering the most user impact. Apps are ranked by usage value relative to conversion complexity. The top of the list is the recommended starting point for a pilot.</p>

    <div class="stat-row">
      <div class="stat">
        <div class="stat-l">Top-5 tenant usage share</div>
        <div class="stat-v">#{top5_pct}<span style="font-size: 16px; color: var(--mute); font-weight: 600;">%</span></div>
        <div class="stat-sub">of #{num(total_views)} total views</div>
      </div>
      <div class="stat stat-#{sl_top5_unhandled.zero? ? 'go' : 'warn'}">
        <div class="stat-l">Top-5 conversion complexity</div>
        <div class="stat-v #{sl_top5_unhandled.zero? ? 'go' : 'warn'}">#{sl_top5_unhandled}</div>
        <div class="stat-sub">advanced features to review across pilot</div>
      </div>
      <div class="stat">
        <div class="stat-l">Needs review · Retire</div>
        <div class="stat-v">#{sl_needs_scout}<span style="font-size: 16px; color: var(--mute); font-weight: 600;"> · #{sl_retire}</span></div>
        <div class="stat-sub">apps of #{shortlist.size} total</div>
      </div>
    </div>

    #{shortlist_table}

    #{sl_total_unhandled.positive? ?
      %(<div class="callout"><strong>#{n_with_unhandled} app#{n_with_unhandled == 1 ? '' : 's'}</strong> include features that warrant individual review when planning their conversion — typically Set Analysis nested in <code>Aggr()</code>, dynamic selection-state expressions, or alternate states, where the right Sigma equivalent depends on how the app actually uses them. Identifying these up-front means no surprises mid-migration.</div>) : ''}

    #{complexity_table}
  </section>

  HTML
  html += effort_html
end

# Section: Duplicate / consolidation candidates (always shown — name + viz +
# usage based; the shared dup-dashboards detector populated inventory.json).
dup_num = has_shortlist ? '08' : '06'
if has_dups
  group_blocks = dup_groups.each_with_index.map do |grp, i|
    drv = grp['drivers'] || {}
    rec = (grp['recommendation'] || 'review').to_s
    rec_cls = rec == 'consolidate' ? 'tag-warn' : 'tag-blue'
    shared = (drv['shared_sources'] || [])
    shared_txt = shared.empty? ? '—' : shared.join(', ')
    members = (grp['members'] || []).map do |m|
      u = m['usage'].nil? ? '' : %( <span class="muted">· #{num(m['usage'])} views</span>)
      %(<li>#{h(m['name'])} <code>#{h(m['id'].to_s)}</code>#{u}</li>)
    end.join
    %(<div class="dup-group">
        <div class="dup-group-head">
          <span class="tag #{rec_cls}">#{rec.upcase}</span>
          <span class="muted">Group #{i + 1} · name overlap-pooled · field overlap ≥#{((drv['min_field_overlap'] || 0).to_f * 100).round}% · shared sources: #{h(shared_txt)} · avoids #{grp['conversions_avoided']} migration#{grp['conversions_avoided'] == 1 ? '' : 's'}</span>
        </div>
        <ul class="dup-members">#{members}</ul>
      </div>)
  end.join
  html += <<~HTML
  <section>
    <div class="section-head">
      <span class="section-num">#{dup_num}</span>
      <h2 class="section-title">Duplicate &amp; consolidation candidates</h2>
      <span class="section-aside">#{dup_summary['duplicate_groups']} group#{dup_summary['duplicate_groups'] == 1 ? '' : 's'} · avoids #{dup_summary['conversions_avoided']} migration#{dup_summary['conversions_avoided'] == 1 ? '' : 's'}</span>
    </div>
    <p class="section-lede">Apps that look like the same report rebuilt — near-identical names plus an overlapping chart set. Each group is one report to migrate <strong>once</strong> (keep the most-used app as the survivor) instead of N times. Detection uses app name and, where <code>--deep</code> ran, chart-type overlap; per-app data sources and field names are not enumerated by this scan, so they don't factor in.</p>
    <div class="callout"><strong>#{dup_summary['duplicate_groups']} group#{dup_summary['duplicate_groups'] == 1 ? '' : 's'}</strong> spanning <strong>#{dup_summary['dashboards_in_groups']} app#{dup_summary['dashboards_in_groups'] == 1 ? '' : 's'}</strong> — consolidating before you migrate avoids <strong>#{dup_summary['conversions_avoided']}</strong> redundant conversion#{dup_summary['conversions_avoided'] == 1 ? '' : 's'}.</div>
    #{group_blocks}
  </section>

  <style>
    .dup-group { margin: 14px 0; padding: 12px 16px; border-left: 3px solid var(--mute); background: rgba(0,0,0,0.015); border-radius: 4px; }
    .dup-group-head { display: flex; align-items: baseline; gap: 10px; flex-wrap: wrap; font-size: 13px; }
    .dup-members { margin: 8px 0 0 0; padding-left: 18px; font-size: 14px; }
    .dup-members li { margin: 2px 0; }
    .dup-members code { font-size: 12px; color: var(--mute); }
  </style>

  HTML
end

# Privacy + next steps
priv_num = has_shortlist ? (has_dups ? '09' : '08') : (has_dups ? '07' : '06')
next_num = has_shortlist ? (has_dups ? '10' : '09') : (has_dups ? '08' : '07')

html += <<~HTML
<section class="section-tight">
  <div class="section-head">
    <span class="section-num">#{priv_num}</span>
    <h2 class="section-title">Data handling</h2>
  </div>
  <p class="section-lede">This report was generated by an LLM-driven scan of your Qlik Cloud tenant. What that means for the data that left your environment:</p>
  <div class="priv-grid">
    <div class="priv-col crossed">
      <h3>Read by the scanner</h3>
      <ul>
        <li>Aggregate counts (app, sheet, master-measure, space, data-connection, reload totals)</li>
        <li>App names, owner names, space IDs</li>
        <li>Reload status / duration and <code>itemViews</code> usage counts</li>
HTML

if has_shortlist
  html += "        <li>Master-measure expressions and chart object definitions for #{shortlist.size} apps (to bucket conversion complexity)</li>\n"
end

html += <<~HTML
      </ul>
    </div>
    <div class="priv-col local">
      <h3>Never left your environment</h3>
      <ul>
        <li>Underlying warehouse rows — the scan never queries source data</li>
        <li>QVD / in-memory data extracts — never read</li>
        <li>Database / connection credentials</li>
        <li>Section Access security rules — flagged by count, never exported verbatim</li>
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
    <li><strong>Pilot the top #{[5, shortlist.size].min} apps.</strong> They represent #{top5_pct}% of total tenant views with #{sl_top5_unhandled} feature#{sl_top5_unhandled == 1 ? '' : 's'} flagged for review between them — the lowest-risk way to demonstrate end-to-end migration with the <code>qlik-to-sigma</code> skill.</li>
  HTML
  if sl_needs_scout.positive?
    html += "    <li><strong>Plan individual review time for #{sl_needs_scout} app#{sl_needs_scout == 1 ? '' : 's'}.</strong> Each contains an advanced Qlik capability (Aggr(), Dual(), selection-state, alternate states) that benefits from a tailored conversion approach.</li>\n"
  end
  if sl_retire.positive?
    html += "    <li><strong>Retire #{sl_retire} app#{sl_retire == 1 ? '' : 's'}</strong> with no views in the last 28 days. No migration value, and dropping them simplifies the cutover.</li>\n"
  end
  html += "    <li><strong>Hand off to <code>qlik-to-sigma</code></strong> with the pilot apps — feed the converter the Qlik <em>model</em> (not the warehouse) so master measures and the load-script lineage carry over.</li>\n"
else
  html += <<~HTML
    <li><strong>Re-run with <code>--deep</code></strong> to add per-app complexity (master-measure expression buckets, chart-type coverage) and unlock the migration shortlist.</li>
    <li><strong>Hand off to <code>qlik-to-sigma</code></strong> to convert the apps you choose to migrate.</li>
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
