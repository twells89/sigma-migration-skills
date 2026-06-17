#!/usr/bin/env node
/**
 * render-report.mjs — branded standalone HTML readout for the cognos-assessment skill.
 *
 *   node render-report.mjs --out <dir>            # reads <dir>/coverage.json (+ inventory.json if present)
 *   node render-report.mjs --coverage <f> --out <f.html>
 *
 * Sigma-branded, print-friendly, ~6 sections, all-free framing. Zero deps.
 * CSS/palette lifted from the tableau-assessment render-readout-html.rb.
 */
import { readFileSync, existsSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
let outDir = null, coveragePath = null, outFile = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--out') outDir = args[++i];
  else if (args[i] === '--coverage') coveragePath = args[++i];
}
if (outDir && !coveragePath) coveragePath = join(outDir, 'coverage.json');
if (outDir && outDir.endsWith('.html')) { outFile = outDir; outDir = null; }
if (!coveragePath || !existsSync(coveragePath)) {
  console.error('coverage.json not found — pass --out <dir> (containing coverage.json) or --coverage <file>');
  process.exit(1);
}
if (!outFile) outFile = outDir ? join(outDir, 'readout.html') : 'readout.html';

const cov = JSON.parse(readFileSync(coveragePath, 'utf8'));
const invPath = outDir ? join(outDir, 'inventory.json') : null;
const inv = invPath && existsSync(invPath) ? JSON.parse(readFileSync(invPath, 'utf8')) : null;

const R = cov.rollup;
const arts = cov.artifacts;

const h = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const num = (n) => Number(n || 0).toLocaleString('en-US');
const fmtDate = (() => { try { return new Date(R.generated_at + 'T00:00:00').toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' }); } catch { return R.generated_at; } })();

const TAG_META = {
  'migrate-first': ['tag-go', 'Migrate first'],
  'easy-win': ['tag-blue', 'Easy win'],
  'moderate': ['tag-gray', 'Standard'],
  'needs-review': ['tag-warn', 'Needs review'],
};
const tagPill = (t) => { const [c, l] = TAG_META[t] || ['tag-gray', t]; return `<span class="tag ${c}">${h(l)}</span>`; };
const bar = (v, max, color = 'bar-blue') => {
  const pct = max ? Math.round((v / max) * 100) : 0;
  return `<div class="bar-cell"><div class="bar-track"><div class="bar-fill ${color}" style="width:${pct}%"></div></div><div class="bar-num">${num(v)}</div></div>`;
};

// ---- waves ----
const wave1 = arts.filter((a) => a.tag === 'migrate-first' || a.tag === 'easy-win');
const wave2 = arts.filter((a) => a.tag === 'moderate');
const wave3 = arts.filter((a) => a.tag === 'needs-review');

// ---- hero finding ----
const nReview = wave3.length;
const heroFinding =
  R.pct_auto_migratable >= 85
    ? `Migration is largely automatic: ${R.pct_auto_migratable}% of detected features convert with the Cognos→Sigma tooling. ${nReview} of ${R.n_artifacts} artifact${nReview === 1 ? '' : 's'} contain a feature that warrants individual review.`
    : `${R.pct_auto_migratable}% of detected features convert automatically. ${nReview} artifact${nReview === 1 ? '' : 's'} need individual review before conversion.`;

// ---- KPI tiles ----
const env = inv?.environment;
const kpis = [
  ['Artifacts', R.n_artifacts, env ? `${env.by_type ? Object.keys(env.by_type).length : ''} content types` : 'scored'],
  ['Data modules', R.n_modules, 'semantic layer'],
  ['Reports', R.n_reports, 'list / crosstab / chart'],
  ['Auto-migratable', R.pct_auto_migratable + '%', 'of detected features'],
  ['Needs review', nReview, 'human decision first'],
  ['Features detected', num(R.totals.n_features), 'across the estate'],
].map(([l, v, s]) => `<div class="kpi"><div class="kpi-v">${h(v)}</div><div class="kpi-l">${h(l)}</div><div class="kpi-sub">${h(s)}</div></div>`).join('');

// ---- inventory table ----
const maxFeat = Math.max(1, ...arts.map((a) => a.n_features));
const invRows = arts.map((a) => `<tr>
  <td>${h(a.name)}</td>
  <td><span class="ds-bucket ${a.type === 'module' ? 'ds-published' : 'ds-embedded'}">${h(a.type)}</span></td>
  <td>${bar(a.n_features, maxFeat)}</td>
  <td><span class="risk-chip ${a.complexity === 'high' ? 'risk-red' : a.complexity === 'medium' ? 'risk-amber' : 'risk-clean'}"><span class="risk-dot"></span>${h(a.complexity)}</span></td>
  <td>${tagPill(a.tag)}</td>
</tr>`).join('');

// ---- coverage breakdown ----
const cb = R.totals;
const coverageBars = [
  ['Auto-convert', cb.n_auto, 'bar-blue', 'translated cleanly by the converter'],
  ['One-time decision', cb.n_hint, 'bar-blue', 'file landing / layer dedupe — no rework'],
  ['Manual setup', cb.n_manual, 'bar-blue', 'brief re-creation in Sigma (filters, CASE, joins)'],
  ['Needs review', cb.n_unhandled, 'bar-blue', 'no clean analog — human decision'],
];
const maxCov = Math.max(1, ...coverageBars.map((b) => b[1]));
const coverageRows = coverageBars.map(([l, v, c, why]) => `<tr><td>${h(l)}</td><td>${bar(v, maxCov, c)}</td><td class="muted">${h(why)}</td></tr>`).join('');

// ---- gap analysis ----
const gapRows = R.gap_histogram.map((g) => {
  const arr = [...new Set(g.artifacts)];
  const named = arr.slice(0, 6).map((n) => `<code>${h(n)}</code>`).join(' ') + (arr.length > 6 ? ` +${arr.length - 6} more` : '');
  return `<tr>
    <td><span class="risk-chip ${g.bucket === 'unhandled' ? 'risk-red' : 'risk-amber'}"><span class="risk-dot"></span>${h(g.signal)}</span></td>
    <td class="al-right num">${g.count}</td>
    <td>${named}</td>
    <td class="muted">${h(g.remediation)}</td>
  </tr>`;
}).join('');

// ---- duplicate / consolidation candidates ----
// Built by score-coverage.mjs via the shared dup-dashboards.py detector. Render
// only when real groups exist; embed the detector's own HTML fragment so the
// section stays byte-consistent with the other assessments.
const dup = cov.duplicate_dashboards;
const dupGroups = dup?.groups || [];
const dupSummary = dup?.summary;
const dupSection = (dup && dupGroups.length)
  ? `<section>
  <div class="section-head"><span class="section-num">DUP</span><h2 class="section-title">Duplicate &amp; consolidation candidates</h2><span class="section-aside">${dupSummary.duplicate_groups} group${dupSummary.duplicate_groups === 1 ? '' : 's'} · avoids ${dupSummary.conversions_avoided} migration${dupSummary.conversions_avoided === 1 ? '' : 's'}</span></div>
  <p class="section-lede">Reports that look like the same report rebuilt — they share a data module and overlap in data items / chart kinds (and often a near-identical name). Migrate the most-used copy <strong>once</strong> and retire the rest, rather than converting all ${dupSummary.dashboards_in_groups} separately. Conservative: only genuine rebuilds are grouped, not coincidental name collisions.</p>
  ${dupGroups.map((grp, i) => {
    const d = grp.drivers;
    const cls = grp.recommendation === 'consolidate' ? 'risk-red' : 'risk-amber';
    const members = grp.members.map((m) => {
      const u = m.usage == null ? '' : ` <span class="muted">· ${num(m.usage)} views</span>`;
      return `<div class="cluster-member"><strong>${h(m.name)}</strong> <code>${h(String(m.id))}</code>${u}</div>`;
    }).join('');
    const shared = d.shared_sources && d.shared_sources.length ? d.shared_sources.map((s) => `<code>${h(s)}</code>`).join(' ') : '—';
    return `<div class="stat ${grp.recommendation === 'consolidate' ? 'stat-warn' : 'stat-blue'}" style="margin-bottom:12px;">
      <div class="stat-l"><span class="risk-chip ${cls}"><span class="risk-dot"></span>Group ${i + 1} — ${h(grp.recommendation)}</span></div>
      <div class="stat-sub" style="margin:6px 0 8px;">Field overlap ≥${Math.round((d.min_field_overlap || 0) * 100)}% · shared sources: ${shared} · avoids ${grp.conversions_avoided} migration${grp.conversions_avoided === 1 ? '' : 's'}</div>
      ${members}
    </div>`;
  }).join('')}
</section>`
  : '';

// ---- wave plan ----
const waveBlock = (n, title, desc, members, cls) => {
  if (!members.length) return '';
  const list = members.slice(0, 20).map((a) => `<div class="cluster-member"><strong>${h(a.name)}</strong> <span class="muted">· ${h(a.type)} · ${h(a.complexity)}</span></div>`).join('');
  return `<div class="stat ${cls}" style="grid-column: span 1;">
    <div class="stat-l">Wave ${n} — ${h(title)}</div>
    <div class="stat-v" style="font-size:24px;">${members.length}<span style="font-size:13px;color:var(--mute);font-weight:600;"> artifacts</span></div>
    <div class="stat-sub" style="margin-bottom:10px;">${h(desc)}</div>
    ${list}${members.length > 20 ? `<div class="muted" style="font-size:11px;margin-top:6px;">+${members.length - 20} more</div>` : ''}
  </div>`;
};

const CSS = `
  @import url('https://fonts.googleapis.com/css2?family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,600;9..40,700&family=DM+Mono:wght@400;500&display=swap');
  :root {
    --bg:#fafafa; --card:#ffffff; --ink:#292929; --ink-2:#3d3d3d;
    --line:#e5e5e5; --line-soft:#f5f5f5;
    --accent:#292929; --accent-soft:#f0f0f0;
    --go:#1f9d57; --go-soft:#e6fbef;
    --warn:#c2562a; --warn-soft:#fff1ea;
    --blue:#2b8ca6; --blue-soft:#eaf8fc;
    --mute:#6e7877; --mute-soft:#f0f0f0;
  }
  * { box-sizing: border-box; }
  html, body { margin:0; padding:0; background:var(--bg); color:var(--ink); }
  body { font-family:"DM Sans",ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; font-size:14px; line-height:1.55; -webkit-font-smoothing:antialiased; }
  main { max-width:1120px; margin:0 auto; padding:48px 48px 80px; }
  .brand-bar { display:flex; align-items:center; gap:10px; margin-bottom:28px; }
  .brand-mark { font-weight:700; font-size:21px; letter-spacing:-0.02em; color:var(--ink); }
  .brand-dot { width:9px; height:9px; border-radius:2px; background:var(--blue); -webkit-print-color-adjust:exact; print-color-adjust:exact; }
  .brand-tag { font-size:12px; color:var(--mute); font-weight:500; text-transform:uppercase; letter-spacing:0.08em; }
  .doc-header { margin-bottom:40px; }
  .doc-eyebrow { font-size:11px; font-weight:600; color:var(--accent); text-transform:uppercase; letter-spacing:0.08em; margin-bottom:8px; }
  .doc-title { font-size:36px; font-weight:700; letter-spacing:-0.02em; margin:0 0 8px; line-height:1.1; }
  .doc-meta { font-size:13px; color:var(--ink-2); }
  .hero { background:var(--accent-soft); border:1px solid var(--line); border-left:4px solid var(--blue); border-radius:8px; padding:18px 22px; margin-bottom:40px; display:flex; align-items:center; gap:16px; -webkit-print-color-adjust:exact; print-color-adjust:exact; }
  .hero-label { font-size:11px; font-weight:700; color:var(--accent); text-transform:uppercase; letter-spacing:0.08em; white-space:nowrap; padding-right:16px; border-right:1px solid var(--line); }
  .hero-text { font-size:15px; color:var(--ink); font-weight:500; line-height:1.4; }
  section { margin-bottom:56px; }
  .section-head { display:flex; align-items:baseline; justify-content:space-between; margin-bottom:16px; padding-bottom:12px; border-bottom:1px solid var(--line); }
  .section-num { font-size:12px; font-weight:600; color:var(--mute); letter-spacing:0.06em; }
  .section-title { font-size:22px; font-weight:600; letter-spacing:-0.01em; margin:0; flex:1; padding-left:14px; }
  .section-aside { font-size:12px; color:var(--mute); }
  .section-lede { font-size:14px; color:var(--ink-2); margin:-4px 0 16px; }
  .kpi-grid { display:grid; grid-template-columns:repeat(6,1fr); gap:12px; }
  .kpi { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:18px 16px; }
  .kpi-v { font-size:28px; font-weight:700; letter-spacing:-0.01em; line-height:1; }
  .kpi-l { font-size:11px; color:var(--mute); text-transform:uppercase; letter-spacing:0.06em; font-weight:600; margin-top:10px; }
  .kpi-sub { font-size:11px; color:var(--mute); margin-top:4px; line-height:1.4; }
  .stat-row { display:grid; grid-template-columns:repeat(3,1fr); gap:12px; margin-bottom:24px; align-items:start; }
  .stat { background:#fafafa; border:1px solid var(--line); border-left:3px solid var(--accent); border-radius:8px; padding:16px 18px; -webkit-print-color-adjust:exact; print-color-adjust:exact; }
  .stat.stat-go { border-left-color:var(--go); background:var(--go-soft); }
  .stat.stat-warn { border-left-color:var(--warn); background:var(--warn-soft); }
  .stat.stat-blue { border-left-color:var(--blue); background:var(--blue-soft); }
  .stat-l { font-size:10px; color:var(--mute); text-transform:uppercase; letter-spacing:0.06em; font-weight:700; margin-bottom:6px; }
  .stat-v { font-size:30px; font-weight:700; line-height:1; letter-spacing:-0.02em; }
  .stat-v.go { color:var(--go); } .stat-v.warn { color:var(--warn); }
  .stat-sub { font-size:12px; color:var(--mute); margin-top:6px; }
  table.data { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--line); border-radius:10px; overflow:hidden; font-size:13px; }
  table.data th { font-weight:600; font-size:11px; color:var(--mute); text-transform:uppercase; letter-spacing:0.06em; padding:12px 16px; background:#fafafa; border-bottom:1px solid var(--line); text-align:left; }
  table.data td { padding:12px 16px; border-bottom:1px solid var(--line-soft); vertical-align:middle; }
  table.data tbody tr:last-child td { border-bottom:0; }
  table.data tbody tr:hover td { background:#fafafa; }
  .al-right { text-align:right; }
  table.data td.al-right, table.data th.al-right, table.data td:has(.bar-cell) { width:1%; white-space:nowrap; }
  .num { font-variant-numeric:tabular-nums; } .muted { color:var(--mute); }
  .tag { display:inline-block; padding:3px 10px; border-radius:99px; font-size:11px; font-weight:600; white-space:nowrap; }
  .tag-go { background:var(--go-soft); color:var(--go); }
  .tag-blue { background:var(--blue-soft); color:var(--blue); }
  .tag-gray { background:#f5f5f5; color:var(--ink-2); }
  .tag-warn { background:var(--warn-soft); color:var(--warn); }
  .bar-cell { display:flex; align-items:center; gap:10px; }
  .bar-track { flex:none; width:84px; height:6px; background:#f5f5f5; border-radius:4px; overflow:hidden; }
  .bar-fill { height:100%; border-radius:4px; }
  .bar-blue { background:linear-gradient(90deg,#4cec8c,#2fb874); }
  .bar-num { font-variant-numeric:tabular-nums; font-weight:600; min-width:36px; text-align:right; }
  .ds-bucket { display:inline-block; padding:3px 10px; border-radius:6px; font-size:11px; font-weight:600; -webkit-print-color-adjust:exact; print-color-adjust:exact; }
  .ds-published { background:var(--blue-soft); color:var(--blue); }
  .ds-embedded { background:#f5f5f5; color:var(--ink-2); }
  .risk-chip { display:inline-flex; align-items:center; gap:6px; font-size:12px; font-variant-numeric:tabular-nums; }
  .risk-dot { width:8px; height:8px; border-radius:50%; -webkit-print-color-adjust:exact; print-color-adjust:exact; }
  .risk-clean .risk-dot { background:var(--go); } .risk-clean { color:var(--go); font-weight:600; }
  .risk-amber .risk-dot { background:#f59e0b; } .risk-amber { color:#a16207; font-weight:600; }
  .risk-red .risk-dot { background:var(--warn); } .risk-red { color:var(--warn); font-weight:700; }
  .cluster-member { padding:2px 0; font-size:12px; line-height:1.4; }
  .cluster-member + .cluster-member { border-top:1px dashed var(--line-soft); }
  .note { font-size:12px; color:var(--mute); font-style:italic; margin:12px 0 0; }
  .callout { background:var(--warn-soft); border-left:3px solid var(--warn); padding:12px 16px; border-radius:6px; margin-top:16px; font-size:13px; color:#7c2d12; }
  code { font-family:"DM Mono",ui-monospace,"SF Mono",Menlo,monospace; font-size:12.5px; background:var(--line-soft); padding:1px 6px; border-radius:4px; }
  ol.next-steps { margin:0; padding-left:0; counter-reset:step; list-style:none; }
  ol.next-steps li { counter-increment:step; padding:14px 0 14px 44px; position:relative; border-bottom:1px solid var(--line-soft); font-size:14px; }
  ol.next-steps li:last-child { border-bottom:0; }
  ol.next-steps li::before { content:counter(step); position:absolute; left:0; top:14px; width:28px; height:28px; border-radius:50%; background:var(--accent-soft); color:var(--accent); display:flex; align-items:center; justify-content:center; font-size:13px; font-weight:700; }
  footer { color:var(--mute); font-size:11px; text-align:center; margin-top:56px; padding-top:20px; border-top:1px solid var(--line); }
  @media print {
    @page { margin:0.6in 0.5in; size:letter portrait; }
    body { background:white; font-size:11.5px; } main { max-width:none; padding:0; }
    .doc-title { font-size:26px; } section { margin-bottom:24px; }
    .kpi-v { font-size:22px; } table.data { font-size:11px; } table.data thead { display:table-header-group; }
    .hero,.kpi,.stat,table.data,table.data th,.ds-bucket,.tag,.bar-track,.bar-fill,.risk-dot,.callout,ol.next-steps li::before { -webkit-print-color-adjust:exact !important; print-color-adjust:exact !important; }
    table.data tr { page-break-inside:avoid; } .section-head { page-break-after:avoid; }
  }
`;

const html = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Cognos Migration Assessment</title>
<style>${CSS}</style></head>
<body><main>

<div class="brand-bar"><span class="brand-dot"></span><span class="brand-mark">sigma</span><span class="brand-tag">Migration Assessment</span></div>
<div class="doc-header">
  <div class="doc-eyebrow">IBM Cognos Analytics → Sigma — Estate Readout</div>
  <h1 class="doc-title">Cognos Migration Assessment</h1>
  <div class="doc-meta">${env ? h(env.base) + ' · ' : ''}Generated ${h(fmtDate)} · ${R.n_artifacts} artifacts scored</div>
</div>

<div class="hero"><div class="hero-label">Headline finding</div><div class="hero-text">${h(heroFinding)}</div></div>

<section>
  <div class="section-head"><span class="section-num">01</span><h2 class="section-title">Executive summary</h2></div>
  <p class="section-lede">A read-only scan of the Cognos estate, scored against the exact coverage of the Cognos→Sigma converter. Every Data Module and report below was classified by detecting the specific features the converter translates cleanly versus the ones it flags for a human. This is a fast, no-cost pre-scoping pass — like the equivalent Tableau assessment — to size the migration and pick a pilot.</p>
  <div class="kpi-grid">${kpis}</div>
</section>

<section>
  <div class="section-head"><span class="section-num">02</span><h2 class="section-title">Estate inventory</h2><span class="section-aside">${R.n_modules} modules · ${R.n_reports} reports</span></div>
  <p class="section-lede">Every scored artifact with its detected feature count, conversion complexity, and recommendation. Complexity is <strong>low</strong> (converts cleanly), <strong>medium</strong> (brief manual setup), or <strong>high</strong> (contains a feature with no clean Sigma analog).</p>
  <table class="data"><thead><tr><th>Artifact</th><th>Type</th><th>Features</th><th>Complexity</th><th>Recommendation</th></tr></thead><tbody>${invRows}</tbody></table>
</section>

<section>
  <div class="section-head"><span class="section-num">03</span><h2 class="section-title">Coverage &amp; auto-migration</h2><span class="section-aside">${R.pct_auto_migratable}% auto-migratable</span></div>
  <p class="section-lede">Of the ${num(R.totals.n_features)} features detected across the estate, this is how the converter handles them. "Auto-migratable" combines clean auto-conversion with one-time decisions (e.g. landing an uploaded file in the warehouse) — work that doesn't require rebuilding logic.</p>
  <div class="stat-row">
    <div class="stat stat-go"><div class="stat-l">Auto-migratable</div><div class="stat-v go">${R.pct_auto_migratable}%</div><div class="stat-sub">${num(cb.n_auto + cb.n_hint)} of ${num(R.totals.n_features)} features</div></div>
    <div class="stat ${cb.n_manual ? 'stat-blue' : ''}"><div class="stat-l">Manual setup features</div><div class="stat-v">${num(cb.n_manual)}</div><div class="stat-sub">filters, CASE blocks, composite joins</div></div>
    <div class="stat ${cb.n_unhandled ? 'stat-warn' : ''}"><div class="stat-l">Needs-review features</div><div class="stat-v ${cb.n_unhandled ? 'warn' : ''}">${num(cb.n_unhandled)}</div><div class="stat-sub">macros, unsupported viz, window calcs</div></div>
  </div>
  <table class="data"><thead><tr><th>Bucket</th><th>Features</th><th>What it means</th></tr></thead><tbody>${coverageRows}</tbody></table>
</section>

<section>
  <div class="section-head"><span class="section-num">04</span><h2 class="section-title">Gap analysis</h2><span class="section-aside">${R.gap_histogram.length} distinct gap type${R.gap_histogram.length === 1 ? '' : 's'}</span></div>
  <p class="section-lede">Every feature that needs a human — named to the artifact, with the specific reason and the remediation. Amber = brief manual setup in Sigma; red = no clean analog, needs a decision before conversion. Identifying these up front means no surprises mid-migration.</p>
  ${R.gap_histogram.length ? `<table class="data"><thead><tr><th>Gap</th><th class="al-right">Count</th><th>Artifacts</th><th>Remediation</th></tr></thead><tbody>${gapRows}</tbody></table>` : '<p class="note">No manual or needs-review gaps detected — the entire estate converts cleanly.</p>'}
</section>

${dupSection}

<section>
  <div class="section-head"><span class="section-num">05</span><h2 class="section-title">Effort &amp; wave plan</h2><span class="section-aside">3 waves · modules before dependent reports</span></div>
  <p class="section-lede">A risk-minimizing migration sequence. Wave 1 is the low-risk pilot; Wave 3 holds anything with a needs-review feature, each requiring a human decision first. Convert Data Modules ahead of the reports that source them.</p>
  <div class="stat-row">
    ${waveBlock(1, 'pilot', 'migrate-first / easy-win — no needs-review features', wave1, 'stat-go')}
    ${waveBlock(2, 'standard', 'medium complexity — convert with light review', wave2, 'stat-blue')}
    ${waveBlock(3, 'review-first', 'contains a macro / unsupported viz / window calc', wave3, 'stat-warn')}
  </div>
  ${cb.n_unhandled ? `<div class="callout"><strong>${nReview} artifact${nReview === 1 ? '' : 's'}</strong> include a feature with no clean Sigma analog (runtime macros, treemap/network/word-cloud/packed-bubble viz, rank/window calcs, localization lookups). Plan a short design decision for each before converting — the converter emits a flagged placeholder rather than guessing.</div>` : ''}
</section>

<section>
  <div class="section-head"><span class="section-num">06</span><h2 class="section-title">Recommended next steps</h2></div>
  <ol class="next-steps">
    <li><strong>Pilot Wave 1 (${wave1.length} artifact${wave1.length === 1 ? '' : 's'}).</strong> These convert with no needs-review features — the lowest-risk way to demonstrate an end-to-end Cognos→Sigma migration. Convert the Data Modules first, then the reports that source them.</li>
    ${cb.n_unhandled ? `<li><strong>Hold a design review for the ${nReview} needs-review artifact${nReview === 1 ? '' : 's'}.</strong> Decide the Sigma equivalent for each macro / unsupported viz / window calc up front (see the gap analysis above).</li>` : ''}
    <li><strong>Request usage telemetry from your Cognos admin.</strong> CA does not expose per-report run/view counts via the REST surface this scan uses, so the shortlist is ranked by conversion effort, not popularity. The admin can pull run counts from the Audit database / Activity reports to confirm which artifacts are actually used (and which to retire).</li>
    <li><strong>Hand the pilot to the <code>cognos-to-sigma</code> converter.</strong> The per-artifact spec files are already cached from this scan — the converter can skip re-discovery and go straight to building the Sigma data model + workbook.</li>
  </ol>
</section>

<footer>Read-only assessment · generated ${h(fmtDate)} · supporting <code>coverage.json</code>${inv ? ' + <code>inventory.json</code>' : ''} alongside in the same folder · all-free migration tooling</footer>

</main></body></html>`;

writeFileSync(outFile, html);
console.log(`wrote ${outFile} (${html.length} bytes)`);
