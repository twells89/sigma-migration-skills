#!/usr/bin/env ruby
# Render <out>/readout.html — a customer-facing, share-friendly HTML report for a
# Looker -> Sigma migration assessment.
#
# Consumes <out>/inventory.json written by looker-inventory.py (environment counts +
# connections + System Activity usage + per-dashboard complexity + shortlist +
# ownership). The Sigma-branded theme is copied verbatim from qlik-assessment /
# tableau-assessment's render-readout-html.rb so the look is byte-identical across
# the assessment family; only the vocabulary (dashboard / tile / explore / model /
# connection / dialect / Look / dashboard run) is Looker-specific.
#
# Usage: ruby scripts/render-readout-html.rb --out /tmp/assessment-<host>

require 'json'
require 'optparse'
require 'cgi'
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
inst   = inventory['instance'] || {}
env    = inventory['environment_overview'] || {}
conns  = inventory['connections'] || {}
act    = inventory['activity'] || {}
feats  = inventory['feature_usage'] || {}
vizmix = inventory['viz_mix'] || []
ownership = inventory['ownership'] || []
shortlist = inventory['shortlist'] || []

inst_name = inst['name'] || 'unknown'
inst_url  = inst['url'] || ''
days      = inst['usage_window_days'] || 90
generated_at = inst['generated_at'] || Time.now.strftime('%Y-%m-%d')
formatted_date = Date.parse(generated_at).strftime('%B %d, %Y') rescue generated_at

has_shortlist = !shortlist.empty?
has_complexity = shortlist.any? { |r| r['tiles'].to_i.positive? }

# Duplicate / consolidation candidates (computed by the shared dup-dashboards.py
# detector in looker-inventory.py; this just renders the result it left behind).
dups        = inventory['duplicate_dashboards'] || {}
dup_groups  = dups['groups'] || []
dup_summary = dups['summary'] || {}
has_dups    = !dup_groups.empty?

# Usage
total_runs = shortlist.sum { |r| r['runs'].to_i }
cold_dash  = shortlist.select { |r| r['runs'].to_i.zero? && r['queries'].to_i.zero? }

# Shortlist rollups
sl_top5_runs      = shortlist.first(5).sum { |r| r['runs'].to_i }
sl_top5_unhandled = shortlist.first(5).sum { |r| r['n_unhandled'].to_i }
sl_total_unhandled = shortlist.sum { |r| r['n_unhandled'].to_i }
sl_needs_scout    = shortlist.count { |r| r['tag'] == 'needs-gap-scout' }
sl_retire         = shortlist.count { |r| r['tag'] == 'retire' }
sl_migrate_first  = shortlist.count { |r| r['tag'] == 'migrate-first' }
n_with_unhandled  = shortlist.count { |r| r['n_unhandled'].to_i.positive? }
top5_pct = total_runs.zero? ? 0 : (sl_top5_runs.to_f / total_runs * 100).round

# Top owner concentration
top_owner_pct = 0
top_owner_name = '—'
total_owner_dash = ownership.sum { |o| o['dashboards'].to_i }
if total_owner_dash > 0
  top = ownership.max_by { |o| o['dashboards'].to_i }
  top_owner_pct = (top['dashboards'].to_f / total_owner_dash * 100).round
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

def bar_cell(value, max, color = 'bar-blue')
  pct = max.zero? ? 0 : (value.to_f / max * 100).round
  %(<div class="bar-cell"><div class="bar-track"><div class="bar-fill #{color}" style="width:#{pct}%"></div></div><div class="bar-num">#{num(value)}</div></div>)
end

def kpi(label, value, sub = nil)
  s = sub ? %(<div class="kpi-sub">#{h(sub)}</div>) : ''
  %(<div class="kpi"><div class="kpi-v">#{h(value)}</div><div class="kpi-l">#{h(label)}</div>#{s}</div>)
end

# ---------- section rendering ----------

hero_finding =
  if has_shortlist
    if sl_top5_unhandled.zero? && sl_migrate_first.positive?
      'Pilot migration is low-risk: the top 5 most-used dashboards contain no unsupported Looker features.'
    elsif sl_total_unhandled.positive?
      "The top-5 pilot is feasible. #{n_with_unhandled} dashboard#{n_with_unhandled == 1 ? '' : 's'} elsewhere include feature#{n_with_unhandled == 1 ? '' : 's'} (custom marketplace viz, merged results) that warrant individual review when planning their conversion."
    else
      'Migration shortlist ranked by usage and conversion complexity.'
    end
  else
    'Environment scan complete.'
  end

# Section 1: KPI tiles
kpi_html = [
  kpi('Models',      env['models']),
  kpi('Explores',    env['explores']),
  kpi('Dashboards',  env['dashboards'], "#{env['dashboards_udd']} UDD · #{env['dashboards_lookml']} LookML"),
  kpi('Looks',       env['looks']),
  kpi('Connections', env['connections']),
  kpi('Dashboard runs', num(act['dashboard_runs']), "last #{days} days · #{act['active_users']} active users")
].join

# Section 2: Dashboard priority & usage
usage_html = ''
unless shortlist.empty?
  ranked = shortlist.sort_by { |r| -r['runs'].to_i }
  max_v = [ranked.first['runs'].to_i, 1].max
  rows = ranked.first(10).each_with_index.map do |r, i|
    %(<tr>
      <td class="rank">#{i + 1}</td>
      <td>#{h(r['name'])}</td>
      <td><span class="inline-pill">#{h(r['kind'])}</span></td>
      <td class="muted">#{h((r['owner'] || '—').to_s.sub(/@.*/, ''))}</td>
      <td>#{bar_cell(r['runs'], max_v)}</td>
    </tr>)
  end.join
  usage_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th class="al-right">#</th>
          <th>Dashboard</th>
          <th>Kind</th>
          <th>Owner</th>
          <th>Runs</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 3: Ownership & concentration
ownership_html = ''
unless ownership.empty?
  rows_data = ownership.sort_by { |o| -o['dashboards'].to_i }
  max_d = [rows_data.first['dashboards'].to_i, 1].max
  rows = rows_data.first(15).map do |o|
    %(<tr>
      <td>#{h((o['owner'] || '—').to_s.sub(/@.*/, ''))}</td>
      <td>#{bar_cell(o['dashboards'], max_d)}</td>
      <td class="al-right num muted">#{num(o['runs'])}</td>
      <td class="al-right num muted">#{num(o['tiles'])}</td>
    </tr>)
  end.join
  ownership_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Owner</th>
          <th>Dashboards</th>
          <th class="al-right">Runs</th>
          <th class="al-right">Tiles</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 4: Connections & dialects
ds_html = ''
detail = (conns['detail'] || [])
unless detail.empty?
  rows = detail.map do |c|
    %(<tr>
      <td><code>#{h(c['name'])}</code></td>
      <td><span class="ds-bucket ds-published">#{h(c['dialect'] || 'unknown')}</span></td>
      <td class="muted">#{h(c['database'])}</td>
    </tr>)
  end.join
  ds_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Connection</th>
          <th>Dialect</th>
          <th>Database</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Feature-usage stat row (hard-to-migrate features across all dashboards)
feat_stats = ''
if has_complexity
  feat_stats = <<~HTML
    <div class="stat-row">
      <div class="stat #{feats['pivots'].to_i.positive? ? 'stat-warn' : ''}">
        <div class="stat-l">Pivots</div>
        <div class="stat-v #{feats['pivots'].to_i.positive? ? 'warn' : ''}">#{feats['pivots'] || 0}</div>
        <div class="stat-sub">tiles pivoted — Sigma pivot table</div>
      </div>
      <div class="stat #{feats['table_calcs'].to_i.positive? ? 'stat-warn' : ''}">
        <div class="stat-l">Table calcs</div>
        <div class="stat-v #{feats['table_calcs'].to_i.positive? ? 'warn' : ''}">#{feats['table_calcs'] || 0}</div>
        <div class="stat-sub">running totals / row-level calc → Sigma formulas</div>
      </div>
      <div class="stat #{(feats['merged_results'].to_i + feats['custom_viz'].to_i).positive? ? 'stat-warn' : ''}">
        <div class="stat-l">Merged results · Custom viz</div>
        <div class="stat-v #{(feats['merged_results'].to_i + feats['custom_viz'].to_i).positive? ? 'warn' : ''}">#{feats['merged_results'] || 0}<span style="font-size:16px;color:var(--mute);font-weight:600;"> · #{feats['custom_viz'] || 0}</span></div>
        <div class="stat-sub">merge → data-model join · marketplace viz → review</div>
      </div>
    </div>
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
        <p class="section-lede">A planning estimate of the LLM cost to migrate the shortlisted dashboards via the <code>looker-to-sigma</code> skill. The LookML→data-model converter and the dashboard builder are deterministic, so per-dashboard cost is flat; each dashboard flagged for review adds one human-decision round.</p>
        <div class="stat-row">
          <div class="stat stat-go">
            <div class="stat-l">Estimated cost · Opus</div>
            <div class="stat-v go">#{fmt.call(opus_usd)}</div>
            <div class="stat-sub">#{n_dash} dashboards + #{n_rev} review</div>
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
            <tr><td>#{n_dash} dashboards × per-dashboard</td><td class="al-right num">#{fmt.call(pd['opus_usd'].to_f * n_dash)}</td><td class="al-right num">#{fmt.call(pd['sonnet_usd'].to_f * n_dash)}</td></tr>
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
<title>Looker Environment Report — #{h(inst_name)}</title>
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
  table.data td.al-right, table.data th.al-right,
  table.data td:has(.bar-cell) { width: 1%; white-space: nowrap; }
  .num { font-variant-numeric: tabular-nums; }
  .muted { color: var(--mute); }
  .warn { color: var(--warn); }
  .warn-num { color: var(--warn); font-weight: 700; }
  .rank { font-variant-numeric: tabular-nums; color: var(--mute); font-weight: 600; width: 32px; }

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

  /* Risk chip — used in shortlist */
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

  /* Inline pill */
  .inline-pill { display: inline-block; padding: 1px 7px; border-radius: 99px;
                 font-size: 11px; background: #f1f5f9; color: var(--ink-2);
                 font-variant-numeric: tabular-nums; margin-right: 4px;
                 -webkit-print-color-adjust: exact; print-color-adjust: exact; }

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

  .dup-groups { display: flex; flex-direction: column; gap: 12px; margin-top: 16px; }
  .dup-group { border: 1px solid var(--mute-soft); border-left: 3px solid var(--warn);
               border-radius: 6px; padding: 12px 16px; }
  .dup-group-head { display: flex; align-items: center; flex-wrap: wrap; gap: 8px; }
  .dup-members { margin: 8px 0 0; padding-left: 20px; font-size: 13px; }
  .dup-members li { margin: 3px 0; }
  .dup-members code { background: rgba(0,0,0,0.05); padding: 1px 5px; border-radius: 3px; }

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
    .hero, .kpi, .stat, table.data, table.data th, .ds-bucket, .tag,
    .bar-track, .bar-fill, .risk-dot, .callout, ol.next-steps li::before {
      -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important;
    }
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
  <div class="doc-eyebrow">Looker Environment Report</div>
  <h1 class="doc-title">#{h(inst_name)}</h1>
  <div class="doc-meta">
    #{inst_url.empty? ? '' : %(<a href="#{h(inst_url)}" target="_blank" rel="noopener">#{h(inst_url)}</a> · )}
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
    <h2 class="section-title">Dashboard priority &amp; usage</h2>
    <span class="section-aside">Top 10 of #{env['dashboards']} dashboards · #{num(total_runs)} total runs</span>
  </div>
  <p class="section-lede">Most-used dashboards across the instance, ranked by run count from Looker's System Activity model. This is the foundation of any migration or consolidation plan — focus effort where audience attention already is. User-defined (UDD) and LookML dashboards convert through the same source-agnostic path.</p>
  #{usage_html}
  <p class="note">Run counts come from <code>system__activity</code> over the last #{days} days — a dashboard with zero runs here is cold over that window, which is the right retirement signal.</p>
  #{cold_dash.any? ? %(<p class="note"><strong>#{cold_dash.size} dashboard#{cold_dash.size == 1 ? '' : 's'}</strong> had no runs in the last #{days} days: ) + cold_dash.first(20).map { |w| %(<code>#{h(w['name'])}</code>) }.join(', ') + ' — candidates for retirement.</p>' : ''}
</section>

<section>
  <div class="section-head">
    <span class="section-num">03</span>
    <h2 class="section-title">Ownership &amp; concentration</h2>
    <span class="section-aside">#{ownership.size} owners across #{env['dashboards']} dashboards</span>
  </div>
  <p class="section-lede">Dashboard ownership concentration across the instance. High concentration in one or two owners is a governance signal — what happens to those dashboards if that person leaves?</p>
  #{ownership_html}
  <p class="note">Top-owner concentration: <strong>#{top_owner_pct}%</strong> of dashboards owned by <code>#{h((top_owner_name || '—').to_s.sub(/@.*/, ''))}</code>.</p>
</section>

<section>
  <div class="section-head">
    <span class="section-num">04</span>
    <h2 class="section-title">Connections &amp; dialects</h2>
    <span class="section-aside">#{conns['n_connections']} connection#{conns['n_connections'] == 1 ? '' : 's'} · #{(conns['dialects'] || []).map { |d| d['dialect'] }.join(', ')}</span>
  </div>
  <p class="section-lede">The warehouses Looker queries. Sigma reads from the same warehouses (Snowflake, BigQuery, Databricks, Redshift, Postgres, and more) — a Looker connection on a Sigma-supported dialect maps to a Sigma connection with no data movement, so the LookML semantic model can be re-pointed onto the existing tables.</p>
  #{ds_html}
</section>

HTML

# Section 5: Feature usage + per-dashboard complexity + shortlist
if has_shortlist
  max_v = [shortlist.map { |r| r['runs'].to_i }.max || 0, 1].max
  sl_rows = shortlist.first(15).map do |r|
    risk_cls, risk_txt =
      if r['n_unhandled'].to_i.positive?
        ['risk-red',   "#{r['n_unhandled']} to review"]
      elsif r['n_manual'].to_i.positive?
        ['risk-amber', "#{r['n_manual']} setup"]
      else
        ['risk-clean', 'No issues']
      end
    %(<tr>
      <td>#{h(r['name'])}</td>
      <td><span class="inline-pill">#{h(r['kind'])}</span></td>
      <td>#{bar_cell(r['runs'], max_v)}</td>
      <td><span class="risk-chip #{risk_cls}"><span class="risk-dot"></span>#{h(risk_txt)}</span></td>
      <td class="al-right num">#{format('%.1f', r['score'].to_f)}</td>
      <td>#{tag_pill(r['tag'])}</td>
    </tr>)
  end.join
  shortlist_table = <<~HTML
    <table class="data shortlist">
      <thead>
        <tr>
          <th>Dashboard</th>
          <th>Kind</th>
          <th>Runs</th>
          <th>Conversion risk</th>
          <th class="al-right">Score</th>
          <th>Recommendation</th>
        </tr>
      </thead>
      <tbody>#{sl_rows}</tbody>
    </table>
    <p class="note">Conversion risk legend: <strong>No issues</strong> = converts automatically · <strong>N setup</strong> = brief post-conversion step in Sigma (pivot → Sigma pivot table, table calc → Sigma formula, Liquid → re-author) · <strong>N to review</strong> = uses a Looker feature with no direct Sigma equivalent (merged results, marketplace / custom viz) that warrants individual evaluation when planning the conversion.</p>
  HTML

  complexity_table = ''
  if has_complexity
    crows = shortlist.sort_by { |r| -(r['n_unhandled'].to_i * 10 + r['n_manual'].to_i * 3) }.map do |r|
      n_viz = (r['viz_types'] || {}).values.sum
      unh_cell = r['n_unhandled'].to_i.positive? ? %(<span class="warn-num">#{r['n_unhandled']}</span>) : '<span class="muted">0</span>'
      %(<tr>
        <td>#{h(r['name'])}</td>
        <td class="al-right num muted">#{r['tiles']}</td>
        <td class="al-right num muted">#{r['filters']}</td>
        <td class="al-right num muted">#{n_viz}</td>
        <td class="al-right num muted">#{r['n_auto']}</td>
        <td class="al-right num">#{r['n_manual']}</td>
        <td class="al-right">#{unh_cell}</td>
      </tr>)
    end.join
    complexity_table = <<~HTML
      <h3>Per-dashboard complexity</h3>
      <p class="section-lede" style="margin-top:0;">Tile vis-types and hard-to-migrate features (pivots, table calcs, merged results, custom viz, Liquid) bucketed against Sigma coverage. <strong>Auto</strong> converts mechanically; <strong>Setup</strong> = pivot / table calc / Liquid (brief manual step); <strong>Review</strong> = merged results / marketplace viz (no direct Sigma equivalent).</p>
      <table class="data">
        <thead>
          <tr>
            <th>Dashboard</th>
            <th class="al-right">Tiles</th>
            <th class="al-right">Filters</th>
            <th class="al-right">Vis</th>
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
      <span class="section-num">05</span>
      <h2 class="section-title">Migration to Sigma — recommended sequence</h2>
      <span class="section-aside">Sigma-specific recommendations</span>
    </div>
    <p class="section-lede">If you choose to migrate to Sigma, this is the order that minimizes risk while covering the most user impact. Dashboards are ranked by usage value relative to conversion complexity. The top of the list is the recommended starting point for a pilot.</p>

    <div class="stat-row">
      <div class="stat">
        <div class="stat-l">Top-5 run share</div>
        <div class="stat-v">#{top5_pct}<span style="font-size: 16px; color: var(--mute); font-weight: 600;">%</span></div>
        <div class="stat-sub">of #{num(total_runs)} total runs</div>
      </div>
      <div class="stat stat-#{sl_top5_unhandled.zero? ? 'go' : 'warn'}">
        <div class="stat-l">Top-5 conversion complexity</div>
        <div class="stat-v #{sl_top5_unhandled.zero? ? 'go' : 'warn'}">#{sl_top5_unhandled}</div>
        <div class="stat-sub">features to review across pilot</div>
      </div>
      <div class="stat">
        <div class="stat-l">Needs review · Retire</div>
        <div class="stat-v">#{sl_needs_scout}<span style="font-size: 16px; color: var(--mute); font-weight: 600;"> · #{sl_retire}</span></div>
        <div class="stat-sub">dashboards of #{shortlist.size} total</div>
      </div>
    </div>

    #{feat_stats}

    #{shortlist_table}

    #{sl_total_unhandled.positive? ?
      %(<div class="callout"><strong>#{n_with_unhandled} dashboard#{n_with_unhandled == 1 ? '' : 's'}</strong> include features that warrant individual review when planning their conversion — typically merged results (multiple explores stitched in one tile) or marketplace / custom-viz extensions, where the right Sigma equivalent depends on how the dashboard actually uses them. Identifying these up-front means no surprises mid-migration.</div>) : ''}

    #{complexity_table}
  </section>

  HTML

  if has_dups
    dup_cards = dup_groups.each_with_index.map do |g, i|
      d = g['drivers'] || {}
      consolidate = g['recommendation'] == 'consolidate'
      rec_cls  = consolidate ? 'tag-warn' : 'tag-gray'
      rec_txt  = consolidate ? 'Consolidate' : 'Review'
      shared   = (d['shared_sources'] || [])
      members  = (g['members'] || []).map do |m|
        u = m['usage'].nil? ? '' : %( <span class="muted">· #{num(m['usage'])} runs</span>)
        %(<li>#{h(m['name'])} <code>#{h(m['id'])}</code>#{u}</li>)
      end.join
      %(<div class="dup-group">
        <div class="dup-group-head">
          <strong>Group #{i + 1}</strong>
          <span class="tag #{rec_cls}">#{rec_txt}</span>
          <span class="section-aside">field overlap ≥#{((d['min_field_overlap'] || 0).to_f * 100).round}% · avoids #{g['conversions_avoided']} migration#{g['conversions_avoided'] == 1 ? '' : 's'}#{shared.empty? ? '' : " · shared: #{h(shared.join(', '))}"}</span>
        </div>
        <ul class="dup-members">#{members}</ul>
      </div>)
    end.join

    html += <<~HTML
    <section>
      <div class="section-head">
        <span class="section-num">06</span>
        <h2 class="section-title">Duplicate &amp; consolidation candidates</h2>
        <span class="section-aside">#{dup_summary['duplicate_groups']} group#{dup_summary['duplicate_groups'] == 1 ? '' : 's'} · avoids #{dup_summary['conversions_avoided']} migration#{dup_summary['conversions_avoided'] == 1 ? '' : 's'}</span>
      </div>
      <p class="section-lede">These dashboards look like the same report rebuilt — they share an explore and overlap heavily on fields, vis types, and naming. Migrating each one separately recreates that redundancy in Sigma. Consolidating to a single Sigma workbook (the most-used member is the natural survivor) means you build it <strong>once</strong> and retire the rest, cutting #{dup_summary['conversions_avoided']} redundant conversion#{dup_summary['conversions_avoided'] == 1 ? '' : 's'} from the migration.</p>
      <div class="dup-groups">#{dup_cards}</div>
      <p class="note"><strong>Consolidate</strong> = near-identical fields and a shared source (a confident merge). <strong>Review</strong> = strong but partial overlap — confirm the variants are truly redundant before merging. Grouping is deliberately conservative: only dashboards sharing a data source or near-identical name are pooled, so coincidental field overlap across unrelated reports is not flagged.</p>
    </section>

    HTML
  end

  html += effort_html
end

# Privacy + next steps
priv_num = has_shortlist ? '08' : '05'
next_num = has_shortlist ? '09' : '06'

html += <<~HTML
<section class="section-tight">
  <div class="section-head">
    <span class="section-num">#{priv_num}</span>
    <h2 class="section-title">Data handling</h2>
  </div>
  <p class="section-lede">This report was generated by an LLM-driven, read-only scan of your Looker instance via the REST API 4.0. What that means for the data that left your environment:</p>
  <div class="priv-grid">
    <div class="priv-col crossed">
      <h3>Read by the scanner</h3>
      <ul>
        <li>Aggregate counts (models, explores, projects, connections, Looks, dashboards, users, groups, folders)</li>
        <li>Dashboard titles, owner names, folder names, connection names + dialects</li>
        <li>System Activity usage — dashboard / Look run counts and active-user counts</li>
HTML

if has_shortlist
  html += "        <li>Per-dashboard tile definitions (vis types, pivots, table calcs, filters) for #{shortlist.size} dashboards — to bucket conversion complexity</li>\n"
end

html += <<~HTML
      </ul>
    </div>
    <div class="priv-col local">
      <h3>Never left your environment</h3>
      <ul>
        <li>Underlying warehouse rows — the scan never runs a content query</li>
        <li>Database / connection credentials</li>
        <li>No writes of any kind — no objects created, edited, or deleted in Looker</li>
        <li>PDTs / cached results — never read</li>
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
    <li><strong>Pilot the top #{[5, shortlist.size].min} dashboards.</strong> They represent #{top5_pct}% of total runs with #{sl_top5_unhandled} feature#{sl_top5_unhandled == 1 ? '' : 's'} flagged for review between them — the lowest-risk way to demonstrate end-to-end migration with the <code>looker-to-sigma</code> skill.</li>
  HTML
  if sl_needs_scout.positive?
    html += "    <li><strong>Plan individual review time for #{sl_needs_scout} dashboard#{sl_needs_scout == 1 ? '' : 's'}.</strong> Each contains a Looker capability (merged results, marketplace / custom viz) that benefits from a tailored conversion approach.</li>\n"
  end
  if sl_retire.positive?
    html += "    <li><strong>Retire #{sl_retire} dashboard#{sl_retire == 1 ? '' : 's'}</strong> with no runs in the last #{days} days. No migration value, and dropping them simplifies the cutover.</li>\n"
  end
  html += "    <li><strong>Hand off to <code>looker-to-sigma</code></strong> with the pilot dashboards — it converts the LookML model via <code>convert_lookml_to_sigma</code> and rebuilds each dashboard from the Looker Dashboard API JSON.</li>\n"
else
  html += <<~HTML
    <li><strong>Re-run without <code>--no-deep</code></strong> to add per-dashboard complexity (tile vis-type buckets, pivots / table calcs / merged results) and unlock the migration shortlist.</li>
    <li><strong>Hand off to <code>looker-to-sigma</code></strong> to convert the dashboards you choose to migrate.</li>
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
