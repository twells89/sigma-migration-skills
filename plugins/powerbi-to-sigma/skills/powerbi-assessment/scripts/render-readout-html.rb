#!/usr/bin/env ruby
# Render <out>/readout.html — a customer-facing, share-friendly HTML report
# for a Power BI / Fabric assessment.
#
# Sibling of tableau-assessment/scripts/render-readout-html.rb: the entire
# <style> block, the h/num/kpi/table/bar_cell/tag_pill helpers, the
# TAG_LABELS/TAG_CLASSES vocabulary, the risk chips, and the section scaffolding
# are copied verbatim so the look is byte-identical. Only the gather-body and
# the Power-BI vocabulary (report/semantic model/dataset/workspace/measure-DAX/
# import-vs-DirectQuery/dataflow) differ.
#
# Reads: inventory.json (required), complexity.json, shortlist.json,
#        usage.json (optional, Fabric-admin only).
#
# Usage: ruby scripts/render-readout-html.rb --out /tmp/pbi-assessment-<tenant>

require 'json'
require 'optparse'
require 'cgi'
require 'date'
require 'set'
require 'open3'

opts = {}
OptionParser.new do |p|
  p.on('--out DIR') { |v| opts[:out] = v }
end.parse!
abort('--out required') unless opts[:out]

inv_path        = File.join(opts[:out], 'inventory.json')
complexity_path = File.join(opts[:out], 'complexity.json')
shortlist_path  = File.join(opts[:out], 'shortlist.json')
usage_path      = File.join(opts[:out], 'usage.json')
abort("inventory.json not found in #{opts[:out]}") unless File.exist?(inv_path)

def load_json(path); File.exist?(path) ? JSON.parse(File.read(path)) : nil; end
inventory  = JSON.parse(File.read(inv_path))
complexity = load_json(complexity_path)
shortlist  = load_json(shortlist_path)
usage      = load_json(usage_path)

shortlist_reports = shortlist ? (shortlist['reports'] || []) : []
has_shortlist = !shortlist_reports.empty?
has_usage     = (shortlist && shortlist['usage_available'] == true) ||
                (usage && usage['available'] == true)

def h(s); CGI.escapeHTML(s.to_s); end
def num(n); n.to_i.to_s.reverse.scan(/.{1,3}/).join(',').reverse; end

# ---------- gather computed values ----------
tenant = inventory['tenant'] || {}
env    = inventory['environment_overview'] || {}
models = inventory['semantic_models'] || []
reports = inventory['reports'] || []

tenant_name = File.basename(opts[:out]).sub(/^pbi-assessment-/, '')
tenant_name = 'Power BI tenant' if tenant_name.nil? || tenant_name.empty?
generated_at = tenant['generated_at'] || Time.now.strftime('%Y-%m-%d')
formatted_date = Date.parse(generated_at).strftime('%B %d, %Y') rescue generated_at

mode_label = has_usage ? 'Fabric Admin (usage + complexity)' : 'User-delegated (complexity-only)'

# DAX totals across all models
total_dax = { 'a' => 0, 'b' => 0, 'c' => 0 }
models.each { |m| (m['dax_buckets'] || {}).each { |k, n| total_dax[k] += n.to_i if total_dax.key?(k) } }

# Usage / value
total_views = has_usage ? shortlist_reports.sum { |r| r['views'].to_i } : 0
cold_reports = has_usage ? shortlist_reports.select { |r| r['views'].to_i.zero? } : []

# Shortlist rollups
sl_top5_views     = 0
sl_top5_unhandled = 0
sl_total_unhandled = 0
sl_needs_scout    = 0
sl_retire         = 0
sl_migrate_first  = 0
if has_shortlist
  top5 = shortlist_reports.first(5)
  sl_top5_views     = top5.sum { |r| r['views'].to_i }
  sl_top5_unhandled = top5.sum { |r| r['unhandled'].to_i }
  sl_total_unhandled = shortlist_reports.sum { |r| r['unhandled'].to_i }
  sl_needs_scout = shortlist_reports.count { |r| r['tag'] == 'needs-gap-scout' }
  sl_retire      = shortlist_reports.count { |r| r['tag'] == 'retire' }
  sl_migrate_first = shortlist_reports.count { |r| r['tag'] == 'migrate-first' }
end
top5_pct = (has_usage && total_views.positive?) ? (sl_top5_views.to_f / total_views * 100).round : 0

# Ownership / concentration — keyed on workspace (PBI has no per-report owner email in inventory)
ws_concentration = Hash.new { |hsh, k| hsh[k] = { reports: 0, models: 0 } }
reports.each { |r| ws_concentration[r['workspace']][:reports] += 1 }
models.each  { |m| ws_concentration[m['workspace']][:models] += 1 }
top_ws_pct = 0
top_ws_name = '—'
if reports.any?
  top = ws_concentration.max_by { |_, v| v[:reports] }
  if top
    top_ws_name = top[0]
    top_ws_pct = (top[1][:reports].to_f / reports.size * 100).round
  end
end

# Complexity
n_scanned = complexity ? complexity.size : 0
n_with_unhandled = complexity ? complexity.values.count { |r| r['n_unhandled'].to_i.positive? } : 0

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

def kpi(label, value, sub = nil)
  s = sub ? %(<div class="kpi-sub">#{h(sub)}</div>) : ''
  %(<div class="kpi"><div class="kpi-v">#{h(value)}</div><div class="kpi-l">#{h(label)}</div>#{s}</div>)
end

# Generic data table renderer.
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

# ---------- section rendering ----------

# Hero: headline finding
hero_finding =
  if has_shortlist
    if sl_top5_unhandled.zero? && sl_migrate_first.positive?
      'Pilot migration is low-risk: the top reports convert without any no-equivalent DAX or unsupported visuals.'
    elsif sl_total_unhandled.positive?
      "The top-5 pilot is feasible. #{n_with_unhandled} report#{n_with_unhandled == 1 ? '' : 's'} elsewhere in the tenant include feature#{n_with_unhandled == 1 ? '' : 's'} that warrant individual review when planning their conversion."
    else
      'Migration shortlist ranked by ' + (has_usage ? 'usage and conversion complexity.' : 'report richness and conversion complexity.')
    end
  else
    'Environment scan complete.'
  end

# Section 01: KPI tiles — Power BI vocabulary
kpi_html = [
  kpi('Reports',        env['reports'], "#{env['dashboards'] || 0} dashboards"),
  kpi('Semantic models', env['semantic_models']),
  kpi('Datasets',       env['semantic_models'], 'one per semantic model'),
  kpi('Workspaces',     env['workspaces'], "#{env['on_capacity_workspaces'] || 0} on Fabric capacity"),
  kpi('Dataflows',      env['dataflows']),
  kpi('DAX measures',   num(total_dax['a'] + total_dax['b'] + total_dax['c']),
      "#{total_dax['a']} mechanical · #{total_dax['b']} restructure · #{total_dax['c']} no-equiv")
].join

# Section 02: Report priority & usage
usage_html = ''
if has_shortlist
  ranked = shortlist_reports.sort_by { |r| -(has_usage ? r['views'].to_i : r['value'].to_f) }
  max_val = has_usage ? (ranked.map { |r| r['views'].to_i }.max || 1) : (ranked.map { |r| r['value'].to_f }.max || 1)
  rows = ranked.first(10).each_with_index.map do |r, i|
    val = has_usage ? r['views'].to_i : r['value']
    bar = has_usage ? bar_cell(r['views'].to_i, max_val) :
          bar_cell(r['value'].round, [max_val.round, 1].max)
    users_cell = has_usage ? (r['users'].nil? ? '<span class="muted">—</span>' : %(<span class="num">#{r['users']}</span>)) : '<span class="muted">—</span>'
    %(<tr>
      <td class="rank">#{i + 1}</td>
      <td>#{h(r['name'])}</td>
      <td class="muted">#{h(r['workspace'] || '—')}</td>
      <td class="muted">#{h(r['model_name'] || '—')}</td>
      <td>#{bar}</td>
      <td class="al-right">#{users_cell}</td>
    </tr>)
  end.join
  usage_col = has_usage ? 'Views' : 'Richness'
  usage_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th class="al-right">#</th>
          <th>Report</th>
          <th>Workspace</th>
          <th>Semantic model</th>
          <th>#{usage_col}</th>
          <th class="al-right">Distinct users</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 03: Ownership & concentration (by workspace)
ownership_html = ''
if reports.any?
  rows_data = ws_concentration.to_a.sort_by { |_, v| -v[:reports] }
  max_r = rows_data.first[1][:reports]
  rows = rows_data.map do |name, v|
    wsrec = (inventory['workspaces'] || []).find { |w| w['name'] == name }
    cap = wsrec && wsrec['on_capacity'] ?
      %(<span class="risk-chip risk-clean"><span class="risk-dot"></span>On capacity</span>) :
      %(<span class="risk-chip risk-mute"><span class="risk-dot"></span>My workspace / shared</span>)
    %(<tr>
      <td>#{h(name)}</td>
      <td>#{bar_cell(v[:reports], max_r)}</td>
      <td class="al-right num muted">#{num(v[:models])}</td>
      <td>#{cap}</td>
    </tr>)
  end.join
  ownership_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Workspace</th>
          <th>Reports</th>
          <th class="al-right">Semantic models</th>
          <th>Capacity</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 04: Data-source patterns (import/DirectQuery, warehouse sources, file flags)
ds_html = ''
import_models = models.count { |m| m['directquery_tables'].to_i.zero? && m['import_tables'].to_i.positive? }
dq_models     = models.count { |m| m['directquery_tables'].to_i.positive? }
wh = Hash.new(0)
file_sources = []
models.each do |m|
  (m['warehouse_sources'] || []).each do |s|
    wh[s] += 1
    kind = s.to_s.split(':').first
    file_sources << s if %w[Excel CSV File Folder Sheets Web SharePoint].include?(kind)
  end
end
if models.any?
  ds_stat_row = <<~ROW
    <div class="stat-row" style="grid-template-columns: repeat(4, 1fr);">
      <div class="stat #{import_models.positive? ? 'stat-go' : ''}">
        <div class="stat-l">Import models</div>
        <div class="stat-v #{import_models.positive? ? 'go' : ''}">#{import_models}</div>
        <div class="stat-sub">cached extract — Sigma re-points to the M source</div>
      </div>
      <div class="stat">
        <div class="stat-l">DirectQuery models</div>
        <div class="stat-v">#{dq_models}</div>
        <div class="stat-sub">live warehouse — drop-in for Sigma</div>
      </div>
      <div class="stat">
        <div class="stat-l">Distinct warehouse hosts</div>
        <div class="stat-v">#{wh.keys.size}</div>
        <div class="stat-sub">parsed from M (Power Query)</div>
      </div>
      <div class="stat #{file_sources.any? ? 'stat-warn' : ''}">
        <div class="stat-l">File-based sources</div>
        <div class="stat-v #{file_sources.any? ? 'warn' : ''}">#{file_sources.uniq.size}</div>
        <div class="stat-sub">need warehouse upload first</div>
      </div>
    </div>
  ROW

  if wh.any?
    max_n = wh.values.max
    wh_rows = wh.sort_by { |_, n| -n }.map do |src, n|
      kind = src.to_s.split(':').first
      host = src.to_s.split(':', 2)[1] || src
      is_file = %w[Excel CSV File Folder Sheets Web SharePoint].include?(kind)
      badge_cls = is_file ? 'ds-embedded' : 'ds-published'
      flag = is_file ? %( <span class="risk-chip risk-amber"><span class="risk-dot"></span>land in warehouse</span>) : ''
      %(<tr>
        <td><span class="ds-bucket #{badge_cls}">#{h(kind)}</span></td>
        <td><code>#{h(host)}</code>#{flag}</td>
        <td>#{bar_cell(n, max_n)}</td>
      </tr>)
    end.join
    wh_table = <<~HTML
      <table class="data">
        <thead>
          <tr>
            <th>Source type</th>
            <th>Host (from M)</th>
            <th>Models</th>
          </tr>
        </thead>
        <tbody>#{wh_rows}</tbody>
      </table>
    HTML
  else
    wh_table = %(<p class="note">No warehouse sources parsed from M — models may be pure-import with no live source exposed.</p>)
  end

  ds_html = ds_stat_row + wh_table
  ds_html += %(<p class="note">Models on a cloud warehouse Sigma supports (Snowflake, BigQuery, Databricks, Redshift, Synapse, Postgres) are <strong>drop-in</strong> — Sigma reads the same tables directly. Import-mode models hide the warehouse behind a cached extract; the M source above is what the <code>powerbi-to-sigma</code> converter re-points to.</p>) if wh.any?
  ds_html += %(<div class="callout"><strong>#{file_sources.uniq.size} file-based source#{file_sources.uniq.size == 1 ? '' : 's'}</strong> (Excel / CSV / SharePoint) must be landed in your warehouse before migration — Sigma reads from the warehouse, not from local files.</div>) if file_sources.any?
end

# Section 05: Refresh insights
refresh_html = ''
refresh_rows = []
models.each do |m|
  rh = m['refresh_history']
  next if rh.nil? || rh.empty?
  durs = rh.map do |r|
    if r['startTime'] && r['endTime']
      (Time.parse(r['endTime']) - Time.parse(r['startTime'])) rescue nil
    end
  end.compact
  avg_dur = durs.empty? ? nil : durs.sum / durs.size
  n_fail = rh.count { |r| r['status'].to_s.downcase != 'completed' && r['status'].to_s.downcase != 'succeeded' }
  last = rh.first
  refresh_rows << [m, last, avg_dur, rh.size, n_fail]
end
require 'time'
if refresh_rows.any?
  rows = refresh_rows.map do |m, last, avg_dur, n_jobs, n_fail|
    ok = (last['status'].to_s.downcase == 'completed' || last['status'].to_s.downcase == 'succeeded')
    result_cls = ok ? 'tag-go' : 'tag-warn'
    dur_txt = avg_dur ? format('%.1fs', avg_dur) : '—'
    %(<tr>
      <td>#{h(m['name'])}</td>
      <td><span class="tag #{result_cls}">#{h(last['status'])}</span></td>
      <td class="muted">#{h(last['refreshType'] || '—')}</td>
      <td class="al-right num">#{num(n_jobs)}</td>
      <td class="al-right num #{n_fail.positive? ? 'warn-num' : 'muted'}">#{n_fail}</td>
      <td class="al-right num muted">#{dur_txt}</td>
    </tr>)
  end.join
  refresh_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Semantic model</th>
          <th>Last result</th>
          <th>Type</th>
          <th class="al-right">Jobs</th>
          <th class="al-right">Failures</th>
          <th class="al-right">Avg duration</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
elsif !tenant['refresh_history_available']
  refresh_html = %(<p class="note">Refresh history unavailable — the Power BI REST token was not acquired. Re-run after a <code>powerbi-to-sigma</code> extract seeds the token cache.</p>)
else
  refresh_html = %(<p class="note">No refresh history rows — models may be DirectQuery (no scheduled refresh) or have never refreshed.</p>)
end

# Section 06: Migration shortlist (HERO table) + per-report complexity
shortlist_html = ''
if has_shortlist
  max_score = shortlist_reports.map { |r| r['score'].to_f }.max || 1
  rows = shortlist_reports.first(15).map do |r|
    risk_cls, risk_txt =
      if r['unhandled'].to_i.positive?
        ['risk-red',   "#{r['unhandled']} to review"]
      elsif r['manual'].to_i.positive?
        ['risk-amber', "#{r['manual']} restructure"]
      else
        ['risk-clean', 'No issues']
      end
    d = r['dax_buckets'] || {}
    dax_txt = "#{d['a'].to_i}/#{d['b'].to_i}/#{d['c'].to_i}"
    %(<tr>
      <td>#{h(r['name'])}</td>
      <td class="muted">#{h(r['model_name'] || '—')}</td>
      <td>#{bar_cell(r['value'].round, [max_score.round, 1].max)}</td>
      <td class="al-right num muted">#{dax_txt}</td>
      <td><span class="risk-chip #{risk_cls}"><span class="risk-dot"></span>#{h(risk_txt)}</span></td>
      <td class="al-right num">#{format('%.1f', r['score'])}</td>
      <td>#{tag_pill(r['tag'])}</td>
    </tr>)
  end.join
  shortlist_html = <<~HTML
    <table class="data shortlist">
      <thead>
        <tr>
          <th>Report</th>
          <th>Semantic model</th>
          <th>Value</th>
          <th class="al-right">DAX a/b/c</th>
          <th>Conversion risk</th>
          <th class="al-right">Score</th>
          <th>Recommendation</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
    <p class="note">DAX a/b/c = mechanical / restructuring / no-equivalent measure counts inherited from the report's semantic model. Conversion risk: <strong>No issues</strong> = converts automatically · <strong>N restructure</strong> = needs a grouped element, parallel join, or pre-aggregation in Sigma · <strong>N to review</strong> = uses DAX or a custom visual with no Sigma equivalent and warrants individual evaluation.</p>
  HTML
end

complexity_html = ''
if complexity
  rows = complexity.values.sort_by do |r|
    -(r['n_unhandled'].to_i * 10 + r['n_manual'].to_i * 3 + r['n_hint'].to_i)
  end.map do |r|
    d = r['dax_buckets'] || {}
    dax_txt = "#{d['a'].to_i}/#{d['b'].to_i}/#{d['c'].to_i}"
    unh_cell = r['n_unhandled'].to_i.positive? ? %(<span class="warn-num">#{r['n_unhandled']}</span>) : '<span class="muted">0</span>'
    rls_cell = r['rls_role_count'].to_i.positive? ? %(<span class="warn-num">#{r['rls_role_count']}</span>) : '<span class="muted">0</span>'
    %(<tr>
      <td>#{h(r['name'])}</td>
      <td class="al-right num muted">#{r['pages']}</td>
      <td class="al-right num">#{r['visuals']}</td>
      <td class="al-right num">#{r['measure_count']}</td>
      <td class="al-right num muted">#{dax_txt}</td>
      <td class="al-right num muted">#{r['calc_table_count']}</td>
      <td class="al-right">#{rls_cell}</td>
      <td class="al-right num">#{r['n_manual']}</td>
      <td class="al-right">#{unh_cell}</td>
    </tr>)
  end.join
  complexity_html = <<~HTML
    <h3>Per-report complexity</h3>
    <table class="data">
      <thead>
        <tr>
          <th>Report</th>
          <th class="al-right">Pages</th>
          <th class="al-right">Visuals</th>
          <th class="al-right">Measures</th>
          <th class="al-right">DAX a/b/c</th>
          <th class="al-right">Calc tables</th>
          <th class="al-right">RLS</th>
          <th class="al-right">Restructure</th>
          <th class="al-right">Review</th>
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
    n_dash  = shortlist_reports.size
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
        <p class="section-lede">A planning estimate of the LLM cost to migrate the shortlisted reports via the <code>powerbi-to-sigma</code> one-shot orchestrator. The mechanical model converter is deterministic, so per-report cost is flat; each report flagged for review adds one human-decision round.</p>
        <div class="stat-row">
          <div class="stat stat-go">
            <div class="stat-l">Estimated cost · Opus</div>
            <div class="stat-v go">#{fmt.call(opus_usd)}</div>
            <div class="stat-sub">#{n_dash} reports + #{n_rev} review</div>
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
            <tr><td>#{n_dash} reports × per-dashboard</td><td class="al-right num">#{fmt.call(pd['opus_usd'].to_f * n_dash)}</td><td class="al-right num">#{fmt.call(pd['sonnet_usd'].to_f * n_dash)}</td></tr>
            <tr><td>+ #{n_rev} item#{n_rev == 1 ? '' : 's'} need review</td><td class="al-right num">#{fmt.call(pr['opus_usd'].to_f * n_rev)}</td><td class="al-right num">#{fmt.call(pr['sonnet_usd'].to_f * n_rev)}</td></tr>
            <tr><td><strong>Total estimated</strong></td><td class="al-right num"><strong>#{fmt.call(opus_usd)}</strong></td><td class="al-right num"><strong>#{fmt.call(sonnet_usd)}</strong></td></tr>
          </tbody>
        </table>
        <p class="note">Calibrated #{h(cal['date'])}, one-shot orchestrator path — LLM cost only; rescale $ by your coding agent's pricing. A naive agent-driven migration is ~12–20× more expensive.</p>
      </section>
    HTML
  end
end

# ---------- Duplicate / consolidation candidates ----------
# The detector result is computed by fabric-inventory.py and stored in
# inventory.json. Render the HTML fragment via the shared (Python) detector so
# every assessment renders this section identically; degrade silently if it is
# absent (older inventory) or python3 is unavailable.
dup_html = ''
dup_summary = nil
if inventory['duplicate_dashboards']
  dup_summary = inventory['duplicate_dashboards']['summary']
  dd_script = File.join(__dir__, 'dup-dashboards.py')
  if File.exist?(dd_script)
    begin
      frag, status = Open3.capture2('python3', dd_script,
        '--render', '--html-stdout', '--in', inv_path)
      dup_html = frag if status.success? && !frag.to_s.strip.empty?
    rescue StandardError
      dup_html = ''
    end
  end
end

# ---------- HTML document ----------
html = <<~HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Power BI Environment Report — #{h(tenant_name)}</title>
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

  h3 { font-size: 15px; font-weight: 600; color: var(--ink); margin: 28px 0 12px; }

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
  <div class="doc-eyebrow">Power BI Environment Report</div>
  <h1 class="doc-title">#{h(tenant_name)}</h1>
  <div class="doc-meta">
    #{h(mode_label)} · Generated #{h(formatted_date)}
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
    <h2 class="section-title">Report priority &amp; usage</h2>
    <span class="section-aside">#{has_usage ? "Top 10 of #{env['reports']} reports · #{num(total_views)} total views" : "Top 10 of #{env['reports']} reports · complexity-ranked"}</span>
  </div>
  <p class="section-lede">#{has_usage ? 'Most-used reports across the tenant, ranked by view count from the Activity Events API. This is the foundation of any migration or consolidation plan — focus effort where audience attention already is.' : 'Without the Fabric Administrator role, view counts are unavailable. Reports below are ranked by a richness proxy (pages + visuals). Re-run as an admin to rank by real usage.'}</p>
  #{usage_html}
  #{cold_reports.any? ? %(<p class="note"><strong>#{cold_reports.size} report#{cold_reports.size == 1 ? '' : 's'}</strong> have zero views in the activity-event window: ) + cold_reports.map { |r| %(<code>#{h(r['name'])}</code>) }.join(', ') + ' — strong candidates for retirement.</p>' : ''}
  #{has_usage ? '<p class="note">Activity Events retains roughly a 30-day window — "views" reflect that period, not all-time.</p>' : ''}
</section>

<section>
  <div class="section-head">
    <span class="section-num">03</span>
    <h2 class="section-title">Ownership &amp; concentration</h2>
    <span class="section-aside">#{ws_concentration.size} workspace#{ws_concentration.size == 1 ? '' : 's'}</span>
  </div>
  <p class="section-lede">Power BI organizes content by workspace rather than per-report owner. Concentration in a single workspace (especially a personal "My workspace") is a governance signal — what happens to that content if its owner leaves?</p>
  #{ownership_html}
  <p class="note">Top-workspace concentration: <strong>#{top_ws_pct}%</strong> of reports live in <code>#{h(top_ws_name)}</code>. Content in <code>My workspace</code> is per-user and usually the first to consolidate.</p>
</section>

<section>
  <div class="section-head">
    <span class="section-num">04</span>
    <h2 class="section-title">Data-source patterns</h2>
    <span class="section-aside">#{import_models} import · #{dq_models} DirectQuery · #{wh.keys.size} hosts</span>
  </div>
  <p class="section-lede">How each semantic model gets its data — import (cached extract) vs. DirectQuery (live), the warehouse hosts parsed from each model's M (Power Query) expression, and any file-based sources that need to land in a warehouse before migration.</p>
  #{ds_html}
</section>

<section>
  <div class="section-head">
    <span class="section-num">05</span>
    <h2 class="section-title">Refresh insights</h2>
  </div>
  <p class="section-lede">Scheduled dataset-refresh activity per semantic model — last result, failure counts, and average duration. Import-mode models refresh on a schedule; DirectQuery models query live and rarely appear here.</p>
  #{refresh_html}
</section>
HTML

if has_shortlist
  html += <<~HTML

<section>
  <div class="section-head">
    <span class="section-num">06</span>
    <h2 class="section-title">Migration to Sigma — recommended sequence</h2>
    <span class="section-aside">#{shortlist['value_basis'] ? h(shortlist['value_basis']) : 'value / (1 + cost)'}</span>
  </div>
  <p class="section-lede">If you choose to migrate to Sigma, this is the order that minimizes risk while covering the most user impact. Reports are ranked by value relative to conversion complexity (<code>score = value / (1 + cost)</code>, where <code>cost = 10·unhandled + 3·manual</code>). The top of the list is the recommended starting point for a pilot.</p>

  <div class="stat-row">
    <div class="stat">
      <div class="stat-l">#{has_usage ? 'Top-5 view share' : 'Top-5 of shortlist'}</div>
      <div class="stat-v">#{has_usage ? "#{top5_pct}<span style=\"font-size: 16px; color: var(--mute); font-weight: 600;\">%</span>" : [5, shortlist_reports.size].min.to_s}</div>
      <div class="stat-sub">#{has_usage ? "of #{num(total_views)} total views" : "highest-value reports of #{shortlist_reports.size}"}</div>
    </div>
    <div class="stat stat-#{sl_top5_unhandled.zero? ? 'go' : 'warn'}">
      <div class="stat-l">Top-5 conversion complexity</div>
      <div class="stat-v #{sl_top5_unhandled.zero? ? 'go' : 'warn'}">#{sl_top5_unhandled}</div>
      <div class="stat-sub">no-equivalent features to review across pilot</div>
    </div>
    <div class="stat">
      <div class="stat-l">Needs review · Retire</div>
      <div class="stat-v">#{sl_needs_scout}<span style="font-size: 16px; color: var(--mute); font-weight: 600;"> · #{sl_retire}</span></div>
      <div class="stat-sub">reports of #{shortlist_reports.size} total</div>
    </div>
  </div>

  #{shortlist_html}

  #{complexity_html}

  #{sl_total_unhandled.positive? ?
    %(<div class="callout"><strong>#{n_with_unhandled} report#{n_with_unhandled == 1 ? '' : 's'}</strong> include DAX or custom visuals with no Sigma equivalent that warrant individual review when planning their conversion — typically PATH hierarchies, dynamic-context measures, or unsupported custom visuals where the right Sigma equivalent depends on how the report actually uses them. Identifying these up-front means no surprises mid-migration.</div>) : ''}
</section>
  HTML
  html += effort_html
end

# Duplicate / consolidation candidates — wrap the shared detector's fragment in
# the house section scaffold (strip its self-contained <section>/<h2> wrapper so
# headers aren't doubled and the numbered badge matches the rest of the readout).
dup_num = has_shortlist ? '08' : '06'
if !dup_html.empty? && dup_summary
  inner = dup_html.sub(%r{\A\s*<section[^>]*>}, '').sub(%r{</section>\s*\z}, '')
  inner = inner.sub(%r{<h2>[^<]*</h2>}, '')   # drop the fragment's own <h2>; the section-head supplies it
  groups = dup_summary['duplicate_groups'].to_i
  in_groups = dup_summary['dashboards_in_groups'].to_i
  avoided = dup_summary['conversions_avoided'].to_i
  aside = groups.positive? ? "#{groups} group#{groups == 1 ? '' : 's'} · avoids #{avoided} migration#{avoided == 1 ? '' : 's'}" : 'none found'
  lede = groups.positive? ?
    "These reports look like the same dashboard rebuilt — shared semantic model or warehouse source, overlapping visuals, near-identical names. Migrate the survivor once and retire the rest instead of converting each copy." :
    'No two reports overlap enough on data source, visuals, and name to be the same dashboard rebuilt — nothing to consolidate.'
  html += <<~HTML

<section>
  <div class="section-head">
    <span class="section-num">#{dup_num}</span>
    <h2 class="section-title">Duplicate &amp; consolidation candidates</h2>
    <span class="section-aside">#{h(aside)}</span>
  </div>
  <p class="section-lede">#{lede}</p>
  #{inner}
</section>
  HTML
end

priv_base = has_shortlist ? 9 : 7
priv_num = format('%02d', priv_base)
next_num = format('%02d', priv_base + 1)

html += <<~HTML

<section class="section-tight">
  <div class="section-head">
    <span class="section-num">#{priv_num}</span>
    <h2 class="section-title">Data handling</h2>
  </div>
  <p class="section-lede">This report was generated by an LLM-driven scan of your Power BI / Fabric tenant. Power BI exposes more than Tableau's <code>.twb</code> — TMSL carries DAX and RLS role definitions. What that means for the data that left your environment:</p>
  <div class="priv-grid">
    <div class="priv-col crossed">
      <h3>Read by the scanner</h3>
      <ul>
        <li>Aggregate counts (workspace, semantic-model, report, dataflow totals)</li>
        <li>Report names, semantic-model names, workspace names</li>
        <li>Full TMSL — DAX measure / calc-column expressions and <strong>RLS role definitions</strong></li>
        <li>PBIR — visual configuration and page structure</li>
        <li>Warehouse host names parsed from M (Power Query)</li>
        <li>Refresh job results</li>
      </ul>
    </div>
    <div class="priv-col local">
      <h3>Never left your environment</h3>
      <ul>
        <li>Underlying warehouse rows — the scan never queries source data</li>
        <li>The <code>.pbix</code> binary model blobs</li>
        <li>Power BI / Entra credentials</li>
        <li>Actual report cell values</li>
      </ul>
    </div>
  </div>
  <p class="note">If RLS roles or DAX encode business-sensitive logic, that text crossed the API. See <code>PRIVACY.md</code> for the full disclosure.</p>
</section>

<section class="section-tight">
  <div class="section-head">
    <span class="section-num">#{next_num}</span>
    <h2 class="section-title">Recommended next steps</h2>
  </div>
  <ol class="next-steps">
HTML

if has_shortlist
  pilot_n = [5, shortlist_reports.size].min
  html += "    <li><strong>Pilot the top #{pilot_n} report#{pilot_n == 1 ? '' : 's'}.</strong> "
  html += (has_usage ? "They represent #{top5_pct}% of total tenant views " : "They are the highest value-to-complexity reports ")
  html += "with #{sl_top5_unhandled} feature#{sl_top5_unhandled == 1 ? '' : 's'} flagged for review between them — the lowest-risk way to demonstrate an end-to-end Power BI to Sigma migration. Reports off the same semantic model share a Sigma data model, so migrate by cluster.</li>\n"
  if sl_needs_scout.positive?
    html += "    <li><strong>Plan individual review time for #{sl_needs_scout} report#{sl_needs_scout == 1 ? '' : 's'}.</strong> Each contains no-equivalent DAX or an unsupported custom visual that benefits from a tailored conversion approach — identifying them up-front prevents surprises mid-migration.</li>\n"
  end
  if sl_retire.positive?
    html += "    <li><strong>Retire #{sl_retire} report#{sl_retire == 1 ? '' : 's'}</strong> with zero views. No migration value, and dropping them simplifies the cutover.</li>\n"
  end
  unless has_usage
    html += "    <li><strong>Re-run as a Fabric Administrator</strong> to add the usage axis (view counts, distinct users from the Activity Events API). The current shortlist is complexity-only — it ranks by report richness, not by who actually uses each report.</li>\n"
  end
  html += "    <li><strong>Hand off to <code>powerbi-to-sigma</code></strong> using <code>migration-plan.json</code> in this folder. The decoded <code>raw-tmsl/</code> and <code>raw-pbir/</code> are the converter's Phase-0 input — it reuses them instead of re-extracting.</li>\n"
else
  html += <<~HTML
    <li><strong>Enable per-report conversion analysis</strong> by running the full inventory + complexity scan. This unlocks the migration shortlist and conversion-cost profile.</li>
    <li><strong>Re-run as a Fabric Administrator</strong> to add usage/adoption (views, distinct users) and tenant-wide sprawl via the Scanner API.</li>
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
