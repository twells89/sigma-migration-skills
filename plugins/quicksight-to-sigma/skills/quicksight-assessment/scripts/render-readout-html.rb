#!/usr/bin/env ruby
# Render <out>/readout.html — a customer-facing, share-friendly HTML report for
# a QuickSight→Sigma migration assessment.
#
# Reads the same JSON inputs as render-readout.rb (inventory.json,
# complexity.json, shortlist.json). Customer-facing, so:
#   - leads with the actionable finding (migration shortlist)
#   - drops internal-skill jargon and methodology asides
#   - assumes Enterprise mode (complexity + shortlist sections present)
#
# Sigma-branded — the <style> block + helper methods are copied VERBATIM from
# tableau-assessment/scripts/render-readout-html.rb (the gold standard). Only the
# gather-and-fill body is QuickSight-specific (analysis/dashboard, sheet, visual,
# dataset, data source, calc field, SPICE vs DIRECT_QUERY).
#
# Usage: ruby scripts/render-readout-html.rb --out /tmp/qs-assessment-<acct>

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
abort("inventory.json not found in #{opts[:out]}") unless File.exist?(inv_path)

def load_json(path); File.exist?(path) ? JSON.parse(File.read(path)) : nil; end
inventory  = JSON.parse(File.read(inv_path))
complexity = load_json(complexity_path)
shortlist_doc = load_json(shortlist_path)

shortlist  = shortlist_doc ? (shortlist_doc['analyses'] || []) : nil
has_shortlist = !shortlist.nil? && !shortlist.empty?
has_usage     = shortlist_doc && shortlist_doc['usage_available'] == true

def h(s); CGI.escapeHTML(s.to_s); end
def num(n); n.to_i.to_s.reverse.scan(/.{1,3}/).join(',').reverse; end

# ---------- gather computed values ----------
account = inventory['account'] || {}
env     = inventory['environment_overview'] || {}
analyses = inventory['analyses'] || []
datasets = inventory['datasets'] || []
data_sources = inventory['data_sources'] || []

account_id   = account['account_id'] || File.basename(opts[:out]).sub(/^qs-assessment-/, '')
region       = account['region'] || ''
edition      = account['edition'] || 'unknown'
enterprise   = account['enterprise'] != false
generated_at = account['generated_at'] || Time.now.strftime('%Y-%m-%d')
formatted_date = Date.parse(generated_at).strftime('%B %d, %Y') rescue generated_at

# Sheet / visual totals (account-wide)
total_sheets  = analyses.sum { |a| a['sheet_count'].to_i }
total_visuals = analyses.sum { |a| a['visual_count'].to_i }

# Ingestion split (SPICE vs DIRECT_QUERY)
n_spice  = datasets.count { |d| d['import_mode'] == 'SPICE' }
n_direct = datasets.count { |d| d['import_mode'] == 'DIRECT_QUERY' }

# Value basis / usage proxy
value_basis = shortlist_doc ? (shortlist_doc['value_basis'] || 'complexity-only proxy') : 'n/a'

# Usage source (for section 02). When usage isn't available, fall back to the
# complexity-proxy value already computed in the shortlist.
usage_source =
  if has_shortlist
    shortlist.map do |r|
      {
        'name'    => r['name'],
        'id'      => r['id'],
        'sheets'  => r['sheets'].to_i,
        'visuals' => r['visuals'].to_i,
        'views'   => r['views'],
        'users'   => r['users'],
        'value'   => r['value'].to_f
      }
    end
  else
    []
  end
total_views = has_usage ? usage_source.sum { |w| w['views'].to_i } : 0
# "cold" = zero-view analyses (only meaningful when usage is available)
cold_analyses = has_usage ? usage_source.select { |w| w['views'].to_i.zero? } : []

# Shortlist roll-ups
sl_top5_unhandled = 0
sl_total_unhandled = 0
sl_needs_scout = 0
sl_retire = 0
sl_migrate_first = 0
sl_easy_win = 0
sl_top5_value = 0.0
sl_total_value = 0.0
if has_shortlist
  top5 = shortlist.first(5)
  sl_top5_unhandled  = top5.sum { |r| r['unhandled'].to_i }
  sl_total_unhandled = shortlist.sum { |r| r['unhandled'].to_i }
  sl_needs_scout = shortlist.count { |r| r['tag'] == 'needs-gap-scout' }
  sl_retire      = shortlist.count { |r| r['tag'] == 'retire' }
  sl_migrate_first = shortlist.count { |r| r['tag'] == 'migrate-first' }
  sl_easy_win      = shortlist.count { |r| r['tag'] == 'easy-win' }
  sl_top5_value  = top5.sum { |r| r['value'].to_f }
  sl_total_value = shortlist.sum { |r| r['value'].to_f }
end
top5_pct = sl_total_value.zero? ? 0 : (sl_top5_value / sl_total_value * 100).round

# Dataset reuse / concentration (the QuickSight analog of ownership concentration).
# Which datasets back the most analyses — the DM-cluster signal.
ds_name_by_id = datasets.each_with_object({}) { |d, m| m[d['id']] = d['name'] }
dataset_fanout = Hash.new { |hsh, k| hsh[k] = { 'analyses' => 0, 'name' => k } }
analyses.each do |a|
  (a['dataset_ids'] || []).uniq.each do |dsid|
    dataset_fanout[dsid]['analyses'] += 1
    dataset_fanout[dsid]['name'] = ds_name_by_id[dsid] || dsid
  end
end
top_dataset_pct = 0
top_dataset_name = 'unknown'
unless dataset_fanout.empty?
  total_refs = dataset_fanout.values.sum { |d| d['analyses'] }
  if total_refs > 0
    top = dataset_fanout.values.max_by { |d| d['analyses'] }
    top_dataset_pct = (top['analyses'].to_f / total_refs * 100).round
    top_dataset_name = top['name']
  end
end

# Complexity roll-ups
n_scanned = complexity ? complexity.size : 0
n_with_unhandled = complexity ? complexity.values.count { |r| r['n_unhandled'].to_i.positive? } : 0
total_calc = { 'a' => 0, 'b' => 0, 'c' => 0 }
(complexity || {}).each_value do |r|
  (r['calc_buckets'] || {}).each { |k, v| total_calc[k] += v.to_i }
end

# ---------- HTML helpers (copied verbatim from tableau-assessment) ----------
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

# Generic data table renderer (verbatim from tableau-assessment).
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

# ---------- section content ----------

# Hero: headline finding
hero_finding =
  if has_shortlist
    if sl_top5_unhandled.zero? && (sl_migrate_first.positive? || sl_easy_win.positive?)
      'Pilot migration is low-risk: the top analyses contain no unsupported QuickSight features.'
    elsif sl_total_unhandled.positive?
      "The top-5 pilot is feasible. #{n_with_unhandled} analys#{n_with_unhandled == 1 ? 'is' : 'es'} elsewhere include feature#{n_with_unhandled == 1 ? '' : 's'} (window/table calcs, exotic visuals, or free-form layout) that warrant individual review when planning their conversion."
    else
      'Migration shortlist ranked by value and conversion complexity.'
    end
  else
    'Environment scan complete.'
  end

# Section 1: KPI tiles
kpi_html = [
  kpi('Analyses',     env['analyses']),
  kpi('Dashboards',   env['dashboards']),
  kpi('Datasets',     env['datasets'], "#{n_spice} SPICE · #{n_direct} direct query"),
  kpi('Data sources', env['data_sources']),
  kpi('Sheets',       total_sheets),
  kpi('Visuals',      total_visuals)
].join

# Section 2: Analysis priority & usage
usage_html = ''
if !usage_source.empty?
  ranked = usage_source.sort_by { |w| -w['value'].to_f }
  max_val = ranked.first['value'].to_f
  max_val = 1.0 if max_val.zero?
  rows = ranked.first(10).each_with_index.map do |w, i|
    bar_basis = has_usage ? w['views'].to_i : w['value']
    bar_max   = has_usage ? (ranked.map { |r| r['views'].to_i }.max || 1) : max_val
    views_cell = has_usage ? w['views'].to_i : '—'
    users_cell = has_usage ? w['users'].to_i : '—'
    %(<tr>
      <td class="rank">#{i + 1}</td>
      <td>#{h(w['name'])}</td>
      <td class="al-right num muted">#{w['sheets']}</td>
      <td class="al-right num muted">#{w['visuals']}</td>
      <td>#{bar_cell(bar_basis, bar_max)}</td>
      <td class="al-right num muted">#{views_cell}</td>
      <td class="al-right num muted">#{users_cell}</td>
    </tr>)
  end.join
  usage_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th class="al-right">#</th>
          <th>Analysis / dashboard</th>
          <th class="al-right">Sheets</th>
          <th class="al-right">Visuals</th>
          <th>#{has_usage ? 'Views' : 'Value (proxy)'}</th>
          <th class="al-right">Views</th>
          <th class="al-right">Users</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 3: Dataset reuse & concentration
ownership_html = ''
unless dataset_fanout.empty?
  rows_data = dataset_fanout.values.sort_by { |d| -d['analyses'] }
  max_fan = rows_data.first['analyses']
  max_fan = 1 if max_fan.zero?
  rows = rows_data.map do |d|
    %(<tr>
      <td>#{h(d['name'])}</td>
      <td>#{bar_cell(d['analyses'], max_fan)}</td>
    </tr>)
  end.join
  ownership_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Dataset</th>
          <th>Analyses backed</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 4: Data-source patterns (SPICE/DIRECT_QUERY, source types, file/S3 flagged)
FILE_SOURCE_KINDS = %w[S3Source UploadedFile S3 File].freeze
FILE_DS_TYPES     = %w[S3 FILE UPLOAD].freeze

# Source-kind histogram across datasets (physical_kinds)
src_kind = Hash.new(0)
datasets.each { |d| (d['physical_kinds'] || []).each { |k| src_kind[k] += 1 } }
src_rows_data = src_kind.sort_by { |_, n| -n }
max_src = src_rows_data.empty? ? 1 : src_rows_data.first[1]
src_kind_html = ''
unless src_rows_data.empty?
  rows = src_rows_data.map do |kind, n|
    flagged = FILE_SOURCE_KINDS.include?(kind)
    badge = flagged ? %(<span class="ds-bucket ds-embedded">file-based</span>) : %(<span class="ds-bucket ds-published">warehouse</span>)
    %(<tr>
      <td><code>#{h(kind)}</code></td>
      <td>#{badge}</td>
      <td>#{bar_cell(n, max_src)}</td>
    </tr>)
  end.join
  src_kind_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Physical source kind</th>
          <th>Sigma readiness</th>
          <th>Datasets</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Connection (data-source) type table — the warehouse/engine each source points at
ds_type_html = ''
if !data_sources.empty?
  type_hist = Hash.new(0)
  data_sources.each { |s| type_hist[s['type'] || 'unknown'] += 1 }
  rows_data = type_hist.sort_by { |_, n| -n }
  max_t = rows_data.first[1]
  rows = rows_data.map do |t, n|
    flagged = FILE_DS_TYPES.include?(t.to_s.upcase)
    cls = flagged ? 'ds-embedded' : 'ds-published'
    label = flagged ? 'file / object store' : 'warehouse / engine'
    %(<tr>
      <td><code>#{h(t)}</code></td>
      <td><span class="ds-bucket #{cls}">#{label}</span></td>
      <td>#{bar_cell(n, max_t)}</td>
    </tr>)
  end.join
  ds_type_html = "<h3>Data-source connection types</h3>" + <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Connection type</th>
          <th>Sigma readiness</th>
          <th>Count</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# File-based / S3 flagged callout
n_file_datasets = datasets.count { |d| (d['physical_kinds'] || []).any? { |k| FILE_SOURCE_KINDS.include?(k) } }
n_custom_sql    = datasets.count { |d| d['has_custom_sql'] }
n_rls           = datasets.count { |d| d['rls_enabled'] }
ds_callout = ''
if n_file_datasets.positive?
  ds_callout = %(<div class="callout"><strong>#{n_file_datasets} dataset#{n_file_datasets == 1 ? '' : 's'}</strong> source from S3 / uploaded files. Sigma reads from a cloud warehouse, not directly from S3 objects — these need to land in your warehouse first (the <code>quicksight-to-sigma</code> converter flags them as a gap). Warehouse-backed datasets (Snowflake, Redshift, Athena, BigQuery, Databricks, Postgres) are drop-in: Sigma reads the same tables directly.</div>)
end

# Section 5: Refresh / ingestion activity (SPICE vs DIRECT_QUERY)
ingestion_html = ''
unless datasets.empty?
  rows = datasets.sort_by { |d| d['import_mode'] == 'SPICE' ? 0 : 1 }.map do |d|
    mode = d['import_mode'] || '—'
    mode_cls = mode == 'SPICE' ? 'tag-blue' : 'tag-go'
    rls_chip = d['rls_enabled'] ? %(<span class="risk-chip risk-amber"><span class="risk-dot"></span>RLS</span>) : '<span class="muted">—</span>'
    %(<tr>
      <td>#{h(d['name'])}</td>
      <td><span class="tag #{mode_cls}">#{h(mode)}</span></td>
      <td class="al-right num muted">#{d['column_count']}</td>
      <td class="al-right num muted">#{d['transform_count']}</td>
      <td>#{rls_chip}</td>
    </tr>)
  end.join
  ingestion_html = <<~HTML
    <table class="data">
      <thead>
        <tr>
          <th>Dataset</th>
          <th>Ingestion</th>
          <th class="al-right">Columns</th>
          <th class="al-right">Transforms</th>
          <th>Security</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
  HTML
end

# Section 6: Migration shortlist (HERO table)
shortlist_html = ''
if has_shortlist
  max_val = shortlist.map { |r| r['value'].to_f }.max || 1.0
  max_val = 1.0 if max_val.zero?
  rows = shortlist.first(15).map do |r|
    risk_cls, risk_txt =
      if r['unhandled'].to_i.positive?
        ['risk-red',   "#{r['unhandled']} to review"]
      elsif r['manual'].to_i.positive?
        ['risk-amber', "#{r['manual']} setup"]
      else
        ['risk-clean', 'No issues']
      end
    cb = r['calc_buckets'] || {}
    %(<tr>
      <td>#{h(r['name'])}</td>
      <td>#{bar_cell(r['value'].round, max_val.round)}</td>
      <td class="al-right num muted">#{cb['a'].to_i}/#{cb['b'].to_i}/#{cb['c'].to_i}</td>
      <td><span class="risk-chip #{risk_cls}"><span class="risk-dot"></span>#{h(risk_txt)}</span></td>
      <td class="al-right num">#{format('%.1f', r['score'])}</td>
      <td>#{tag_pill(r['tag'])}</td>
    </tr>)
  end.join
  shortlist_html = <<~HTML
    <table class="data shortlist">
      <thead>
        <tr>
          <th>Analysis</th>
          <th>#{has_usage ? 'Usage value' : 'Value (proxy)'}</th>
          <th class="al-right">Calc a/b/c</th>
          <th>Conversion risk</th>
          <th class="al-right">Score</th>
          <th>Recommendation</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
    <p class="note">Conversion risk legend: <strong>No issues</strong> = converts automatically · <strong>N setup</strong> = brief post-conversion setup in Sigma (dataset joins, parameters, RLS) · <strong>N to review</strong> = uses a QuickSight feature that warrants individual evaluation (window/table calcs, exotic visuals, free-form layout) when planning the conversion. Calc a/b/c = mechanical / restructuring / no-Sigma-equivalent calc fields.</p>
  HTML
end

# Per-analysis complexity table
complexity_html = ''
if complexity
  rows = complexity.values.sort_by do |r|
    -(r['n_unhandled'].to_i * 10 + r['n_manual'].to_i * 3 + r['n_hint'].to_i)
  end.map do |r|
    unh_cell = r['n_unhandled'].to_i.positive? ? %(<span class="warn-num">#{r['n_unhandled']}</span>) : '<span class="muted">0</span>'
    cb = r['calc_buckets'] || {}
    %(<tr>
      <td>#{h(r['name'])}</td>
      <td class="al-right num muted">#{r['sheets']}</td>
      <td class="al-right num">#{r['visuals']}</td>
      <td class="al-right num muted">#{cb['a'].to_i}/#{cb['b'].to_i}/#{cb['c'].to_i}</td>
      <td class="al-right num muted">#{r['window_calc_count']}</td>
      <td class="al-right num">#{r['n_manual']}</td>
      <td class="al-right">#{unh_cell}</td>
    </tr>)
  end.join
  complexity_html = <<~HTML
    <h3>Per-analysis conversion profile</h3>
    <table class="data">
      <thead>
        <tr>
          <th>Analysis</th>
          <th class="al-right">Sheets</th>
          <th class="al-right">Visuals</th>
          <th class="al-right">Calc a/b/c</th>
          <th class="al-right">Window calcs</th>
          <th class="al-right">Setup</th>
          <th class="al-right">Review</th>
        </tr>
      </thead>
      <tbody>#{rows}</tbody>
    </table>
    <p class="note">Window/table-calc functions (the "c" calc bucket — <code>sumOver</code>, <code>runningSum</code>, <code>rank</code>, <code>percentOfTotal</code>, …) have no clean Sigma equivalent and convert to a <code>/* TODO */</code> placeholder. Across all scanned analyses: <strong>#{total_calc['a']} mechanical / #{total_calc['b']} restructuring / #{total_calc['c']} no-equivalent</strong> calc fields.</p>
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
        <p class="section-lede">A planning estimate of the LLM cost to migrate the shortlisted analyses via the <code>quicksight-to-sigma</code> one-shot orchestrator. The mechanical model converter is deterministic, so per-dashboard cost is flat; each analysis flagged for review adds one human-decision round.</p>
        <div class="stat-row">
          <div class="stat stat-go">
            <div class="stat-l">Estimated cost · Opus</div>
            <div class="stat-v go">#{fmt.call(opus_usd)}</div>
            <div class="stat-sub">#{n_dash} analyses + #{n_rev} review</div>
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
            <tr><td>#{n_dash} analyses × per-dashboard</td><td class="al-right num">#{fmt.call(pd['opus_usd'].to_f * n_dash)}</td><td class="al-right num">#{fmt.call(pd['sonnet_usd'].to_f * n_dash)}</td></tr>
            <tr><td>+ #{n_rev} item#{n_rev == 1 ? '' : 's'} need review</td><td class="al-right num">#{fmt.call(pr['opus_usd'].to_f * n_rev)}</td><td class="al-right num">#{fmt.call(pr['sonnet_usd'].to_f * n_rev)}</td></tr>
            <tr><td><strong>Total estimated</strong></td><td class="al-right num"><strong>#{fmt.call(opus_usd)}</strong></td><td class="al-right num"><strong>#{fmt.call(sonnet_usd)}</strong></td></tr>
          </tbody>
        </table>
        <p class="note">Calibrated #{h(cal['date'])}, one-shot orchestrator path — LLM cost only; rescale $ by your coding agent's pricing. A naive agent-driven migration is ~12–20× more expensive.</p>
      </section>
    HTML
  end
end

# ---------- duplicate / consolidation candidates ----------
# Shell out to the shared, tool-neutral detector for the HTML fragment. Prefer
# the normalized list written by quicksight-inventory.py; embed only if the scan
# actually found overlapping analyses (flag-not-fake).
dup_html = ''
dup_doc = inventory['duplicate_dashboards']
dup_norm_path = File.join(opts[:out], 'dup-normalized.json')
if dup_doc && (dup_doc['summary'] || {})['duplicate_groups'].to_i.positive? && File.exist?(dup_norm_path)
  dd_script = File.join(__dir__, 'dup-dashboards.py')
  frag_path = File.join(opts[:out], 'dup-frag.html')
  system('python3', dd_script, '--in', dup_norm_path,
         '--out', File.join(opts[:out], 'dup-groups.json'), '--html', frag_path)
  if File.exist?(frag_path)
    frag = File.read(frag_path)
    dup_html = <<~HTML
      <section>
        <div class="section-head">
          <span class="section-num">DUP</span>
          <h2 class="section-title">Duplicate / consolidation candidates</h2>
          <span class="section-aside">migrate once, not N times</span>
        </div>
        <p class="section-lede">These analyses look like the same report rebuilt — shared datasets, overlapping visuals, near-identical names. Consolidating them before migration means you build each in Sigma once and retire the redundant copies.</p>
        #{frag}
      </section>
    HTML
  end
end

# ---------- assemble HTML ----------
html = <<~HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>QuickSight Environment Report — #{h(account_id)}</title>
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
  <div class="doc-eyebrow">QuickSight Environment Report</div>
  <h1 class="doc-title">#{h(account_id)}</h1>
  <div class="doc-meta">
    Account #{h(account_id)} · #{h(region)} · #{h(edition)} edition · Generated #{h(formatted_date)}
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
    <h2 class="section-title">Analysis &amp; dashboard priority</h2>
    <span class="section-aside">Top 10 of #{env['analyses']} analyses · ranked #{has_usage ? "by #{num(total_views)} total views" : 'by complexity proxy'}</span>
  </div>
  <p class="section-lede">#{has_usage ? 'Most-used analyses across the account, ranked by all-time view count. This is the foundation of any migration plan — focus effort where audience attention already is.' : 'QuickSight has no per-analysis view-count API on the standard surface, so analyses are ranked by a complexity proxy (sheets + visuals/4) rather than real usage. Supply a CloudTrail/CloudWatch-derived <code>usage.json</code> to add the usage axis.'}</p>
  #{usage_html}
  #{cold_analyses.any? ? %(<p class="note"><strong>#{cold_analyses.size} analys#{cold_analyses.size == 1 ? 'is has' : 'es have'}</strong> never been viewed: ) + cold_analyses.map { |w| %(<code>#{h(w['name'])}</code>) }.join(', ') + ' — strong candidates for retirement.</p>' : ''}
</section>

<section>
  <div class="section-head">
    <span class="section-num">03</span>
    <h2 class="section-title">Dataset reuse &amp; concentration</h2>
    <span class="section-aside">#{datasets.size} datasets</span>
  </div>
  <p class="section-lede">QuickSight has no per-analysis owner surface, so concentration here is measured by <strong>dataset reuse</strong>: how many analyses each dataset backs. Datasets shared across multiple analyses become a single Sigma data model by construction — the migration plan groups analyses into DM clusters on exactly this signal.</p>
  #{ownership_html}
  #{dataset_fanout.empty? ? '' : %(<p class="note">Most-reused dataset: <strong>#{top_dataset_pct}%</strong> of dataset references point at <code>#{h(top_dataset_name)}</code>. High reuse is a <em>good</em> migration signal — those analyses collapse into one shared Sigma data model.</p>)}
</section>

<section>
  <div class="section-head">
    <span class="section-num">04</span>
    <h2 class="section-title">Data sources &amp; patterns</h2>
    <span class="section-aside">#{datasets.size} datasets · #{n_spice} SPICE · #{n_direct} direct query</span>
  </div>
  <p class="section-lede">How data flows into your QuickSight analyses. Datasets backed by a cloud warehouse Sigma already supports (Snowflake, Redshift, Athena, BigQuery, Databricks, Postgres) are drop-in. File-based sources (S3, uploaded files) must land in a warehouse first.</p>
  #{src_kind_html}
  #{ds_type_html}
  <p class="note"><strong>#{n_custom_sql} dataset#{n_custom_sql == 1 ? '' : 's'}</strong> use Custom SQL (converted via the <code>[Custom SQL/&lt;ALIAS&gt;]</code> fixup) · <strong>#{n_rls} dataset#{n_rls == 1 ? '' : 's'}</strong> have row-level security enabled.</p>
  #{ds_callout}
</section>

<section>
  <div class="section-head">
    <span class="section-num">05</span>
    <h2 class="section-title">Ingestion &amp; refresh activity</h2>
    <span class="section-aside">#{n_spice} SPICE · #{n_direct} direct query</span>
  </div>
  <p class="section-lede">QuickSight datasets either pre-ingest into SPICE (its in-memory cache, refreshed on a schedule) or query the warehouse live (DIRECT_QUERY). SPICE datasets carry a refresh schedule that becomes a Sigma data-model materialization; direct-query datasets read live and need no ingestion plan.</p>
  #{ingestion_html}
</section>

HTML

if has_shortlist
  html += <<~HTML
  <section>
    <div class="section-head">
      <span class="section-num">06</span>
      <h2 class="section-title">Migration to Sigma — recommended sequence</h2>
      <span class="section-aside">#{value_basis}</span>
    </div>
    <p class="section-lede">If you choose to migrate to Sigma, this is the order that minimizes risk while covering the most value. Analyses are ranked by <code>value / (1 + cost)</code>, where <code>cost = 10·unhandled + 3·manual</code>. The top of the list is the recommended starting point for a pilot.</p>

    <div class="stat-row">
      <div class="stat">
        <div class="stat-l">Top-5 #{has_usage ? 'usage' : 'value'} share</div>
        <div class="stat-v">#{top5_pct}<span style="font-size: 16px; color: var(--mute); font-weight: 600;">%</span></div>
        <div class="stat-sub">of total #{has_usage ? 'usage value' : 'value (proxy)'} across #{shortlist.size} analyses</div>
      </div>
      <div class="stat stat-#{sl_top5_unhandled.zero? ? 'go' : 'warn'}">
        <div class="stat-l">Top-5 conversion complexity</div>
        <div class="stat-v #{sl_top5_unhandled.zero? ? 'go' : 'warn'}">#{sl_top5_unhandled}</div>
        <div class="stat-sub">advanced features to review across pilot</div>
      </div>
      <div class="stat">
        <div class="stat-l">Needs review · Retire</div>
        <div class="stat-v">#{sl_needs_scout}<span style="font-size: 16px; color: var(--mute); font-weight: 600;"> · #{sl_retire}</span></div>
        <div class="stat-sub">analyses of #{shortlist.size} total</div>
      </div>
    </div>

    #{shortlist_html}

    #{complexity_html}

    #{sl_total_unhandled.positive? ?
      %(<div class="callout"><strong>#{n_with_unhandled} analys#{n_with_unhandled == 1 ? 'is' : 'es'}</strong> include features that warrant individual review when planning their conversion — typically window/table-calc functions (no clean Sigma equivalent), exotic visuals (maps, sankey, insight ML), or free-form / section-based layout. Identifying these up-front means no surprises mid-migration.</div>) : ''}
  </section>

  HTML
  html += effort_html
end

html += dup_html

priv_num = has_shortlist ? '08' : '06'
next_num = has_shortlist ? '09' : '07'

html += <<~HTML
<section class="section-tight">
  <div class="section-head">
    <span class="section-num">#{priv_num}</span>
    <h2 class="section-title">Data handling</h2>
  </div>
  <p class="section-lede">This report was generated by an LLM-driven scan of your QuickSight account via the AWS CLI. What that means for the data that left your environment:</p>
  <div class="priv-grid">
    <div class="priv-col crossed">
      <h3>Read by the scanner</h3>
      <ul>
        <li>Aggregate counts (analysis, dashboard, dataset, data-source totals)</li>
        <li>Analysis, dataset, and data-source names</li>
        <li>Analysis definitions — visual configuration and <strong>calc-field expressions</strong></li>
        <li>Dataset metadata — physical source kinds, custom-SQL presence, RLS/CLS flags</li>
      </ul>
    </div>
    <div class="priv-col local">
      <h3>Never left your environment</h3>
      <ul>
        <li>Underlying warehouse rows — the scan never queries source data</li>
        <li>SPICE in-memory rows — never read</li>
        <li>AWS credentials (held by the AWS CLI, not surfaced to the agent)</li>
        <li>Actual visual cell values</li>
      </ul>
    </div>
  </div>
  <p class="note">If your calc-field expressions encode business-sensitive logic, that text crossed the Anthropic API. See <code>PRIVACY.md</code> for the full disclosure to review with your privacy / legal team.</p>
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
    <li><strong>Pilot the top #{[5, shortlist.size].min} analyses.</strong> They represent #{top5_pct}% of total #{has_usage ? 'usage value' : 'value (proxy)'} with #{sl_top5_unhandled} feature#{sl_top5_unhandled == 1 ? '' : 's'} flagged for review between them — the lowest-risk way to demonstrate end-to-end migration. The <code>quicksight-to-sigma</code> skill converts them, grouped into DM clusters that share a Sigma data model by shared dataset.</li>
  HTML
  if sl_needs_scout.positive?
    html += "    <li><strong>Plan individual review time for #{sl_needs_scout} analys#{sl_needs_scout == 1 ? 'is' : 'es'}.</strong> Each contains a window/table-calc function, an exotic visual, or free-form layout that benefits from a tailored conversion approach — identifying them up-front prevents surprises mid-migration.</li>\n"
  end
  if sl_retire.positive?
    html += "    <li><strong>Retire #{sl_retire} analys#{sl_retire == 1 ? 'is' : 'es'}</strong> with zero views. No migration value, and dropping them simplifies the cutover.</li>\n"
  end
  unless has_usage
    html += "    <li><strong>Supply usage data</strong> (CloudTrail / CloudWatch-derived <code>usage.json</code>) to upgrade the shortlist from a complexity-only proxy to a usage-weighted ranking and unlock cold-analysis detection.</li>\n"
  end
  html += "    <li><strong>Land any file-based datasets in your warehouse</strong> before converting. S3 / uploaded-file sources are a converter gap — Sigma reads from a warehouse, not directly from S3 objects.</li>\n"
else
  html += <<~HTML
    <li><strong>Enable per-analysis conversion analysis</strong> by running against an Enterprise-edition account. The <code>describe-analysis-definition</code> / <code>describe-data-set</code> APIs are Enterprise-only; on Standard the readout degrades to counts-only.</li>
    <li><strong>Supply usage data</strong> (CloudTrail / CloudWatch) to add a usage-weighted shortlist.</li>
  HTML
end

html += <<~HTML
  </ol>
</section>

<footer>
  Report generated #{h(formatted_date)} · supporting JSON files alongside in the same folder · value basis: #{h(value_basis)}
</footer>

</main>
</body>
</html>
HTML

out_path = File.join(opts[:out], 'readout.html')
File.write(out_path, html)
puts "wrote #{out_path} (#{File.size(out_path)} bytes)"
