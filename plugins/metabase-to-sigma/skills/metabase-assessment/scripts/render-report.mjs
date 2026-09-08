#!/usr/bin/env node
/**
 * render-report.mjs — branded standalone HTML readout for the metabase-assessment skill.
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
const usage = !!R.usage_available;

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

// ---- waves (models sequenced before the questions/dashboards that use them) ----
const TYPE_ORDER = { model: 0, card: 1, metric: 1, dashboard: 2 };
const waveSort = (a, b) => (TYPE_ORDER[a.type] ?? 1) - (TYPE_ORDER[b.type] ?? 1) || b.score - a.score;
const wave1 = arts.filter((a) => a.tag === 'migrate-first' || a.tag === 'easy-win').sort(waveSort);
const wave2 = arts.filter((a) => a.tag === 'moderate').sort(waveSort);
const wave3 = arts.filter((a) => a.tag === 'needs-review').sort(waveSort);

// ---- hero finding ----
const nReview = wave3.length;
const heroFinding =
  R.pct_auto_migratable >= 85
    ? `Migration is largely automatic: ${R.pct_auto_migratable}% of detected features convert with the Metabase→Sigma tooling. ${nReview} of ${R.n_artifacts} artifact${nReview === 1 ? '' : 's'} contain a feature that warrants individual review.`
    : `${R.pct_auto_migratable}% of detected features convert automatically. ${nReview} artifact${nReview === 1 ? '' : 's'} need individual review before conversion.`;

// ---- KPI tiles ----
const env = inv?.environment;
const kpis = [
  ['Artifacts', R.n_artifacts, env?.version ? `Metabase ${env.version}` : 'scored'],
  ['Models', R.n_models, 'semantic layer'],
  ['Questions', R.n_cards, 'MBQL + native SQL'],
  ['Dashboards', R.n_dashboards, 'grids, tabs, filters'],
  ['Auto-migratable', R.pct_auto_migratable + '%', 'of detected features'],
  ['Needs review', nReview, 'human decision first'],
].map(([l, v, s]) => `<div class="kpi"><div class="kpi-v">${h(v)}</div><div class="kpi-l">${h(l)}</div><div class="kpi-sub">${h(s)}</div></div>`).join('');

// ---- inventory table ----
const maxFeat = Math.max(1, ...arts.map((a) => a.n_features));
const typeClass = (t) => t === 'model' ? 'ds-published' : t === 'dashboard' ? 'ds-dash' : 'ds-embedded';
const invRows = arts.map((a) => `<tr>
  <td>${h(a.name)}</td>
  <td><span class="ds-bucket ${typeClass(a.type)}">${h(a.type)}</span></td>
  <td>${bar(a.n_features, maxFeat)}</td>
  ${usage ? `<td class="al-right num">${a.view_count != null ? num(a.view_count) : '<span class="muted">—</span>'}</td>` : ''}
  <td><span class="risk-chip ${a.complexity === 'high' ? 'risk-red' : a.complexity === 'medium' ? 'risk-amber' : 'risk-clean'}"><span class="risk-dot"></span>${h(a.complexity)}</span></td>
  <td>${tagPill(a.tag)}</td>
</tr>`).join('');

// ---- coverage breakdown ----
const cb = R.totals;
const coverageBars = [
  ['Auto-convert', cb.n_auto, 'bar-blue', 'translated cleanly by the converter'],
  ['Review, no rebuild', cb.n_hint, 'bar-blue', 'nested cards, field-filter tags, joins — sequencing/fan-out check'],
  ['Manual setup', cb.n_manual, 'bar-blue', 'brief re-creation in Sigma (binning, segments/metrics, click behavior, snippets)'],
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
  .ds-dash { background:var(--go-soft); color:var(--go); }
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

const usageStep = usage
  ? `<li><strong>Confirm the usage ranking with the admin.</strong> This instance exposes <code>view_count</code> (v50+), so the shortlist is already ranked by real views. For richer signal — views over time, per-user reach — ask the admin for the Pro/EE <em>Usage analytics</em> collection export and merge it in before retiring anything.</li>`
  : `<li><strong>Request usage telemetry from your Metabase admin.</strong> This instance does not expose <code>view_count</code> on cards/dashboards (pre-v50), so the shortlist is ranked by conversion effort, not popularity. Ask for the Pro/EE <em>Usage analytics</em> export (or upgrade and re-run) to confirm which artifacts are actually used — and which to retire.</li>`;

const html = `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Metabase Migration Assessment</title>
<style>${CSS}</style></head>
<body><main>

<div class="brand-bar"><span class="brand-dot"></span><span class="brand-mark">sigma</span><span class="brand-tag">Migration Assessment</span></div>
<div class="doc-header">
  <div class="doc-eyebrow">Metabase → Sigma — Estate Readout</div>
  <h1 class="doc-title">Metabase Migration Assessment</h1>
  <div class="doc-meta">${env ? h(env.base) + ' · ' : ''}Generated ${h(fmtDate)} · ${R.n_artifacts} artifacts scored</div>
</div>

<div class="hero"><div class="hero-label">Headline finding</div><div class="hero-text">${h(heroFinding)}</div></div>

<section>
  <div class="section-head"><span class="section-num">01</span><h2 class="section-title">Executive summary</h2></div>
  <p class="section-lede">A read-only scan of the Metabase instance, scored against the exact coverage of the Metabase→Sigma converter. Every model, question, and dashboard below was classified by walking its MBQL/native definition and detecting the specific features the converter translates cleanly versus the ones it flags for a human. This is a fast, no-cost pre-scoping pass — like the equivalent Tableau assessment — to size the migration and pick a pilot.</p>
  <div class="kpi-grid">${kpis}</div>
</section>

<section>
  <div class="section-head"><span class="section-num">02</span><h2 class="section-title">Estate inventory</h2><span class="section-aside">${R.n_models} models · ${R.n_cards} questions · ${R.n_dashboards} dashboards</span></div>
  <p class="section-lede">Every scored artifact with its detected feature count${usage ? ', views' : ''}, conversion complexity, and recommendation. Complexity is <strong>low</strong> (converts cleanly), <strong>medium</strong> (brief manual setup), or <strong>high</strong> (contains a feature with no clean Sigma analog).</p>
  <table class="data"><thead><tr><th>Artifact</th><th>Type</th><th>Features</th>${usage ? '<th class="al-right">Views</th>' : ''}<th>Complexity</th><th>Recommendation</th></tr></thead><tbody>${invRows}</tbody></table>
</section>

<section>
  <div class="section-head"><span class="section-num">03</span><h2 class="section-title">Coverage &amp; auto-migration</h2><span class="section-aside">${R.pct_auto_migratable}% auto-migratable</span></div>
  <p class="section-lede">Of the ${num(R.totals.n_features)} features detected across the estate, this is how the converter handles them. "Auto-migratable" combines clean auto-conversion with review-only items (nested-card sequencing, field-filter control wiring, join fan-out checks) — work that doesn't require rebuilding logic.</p>
  <div class="stat-row">
    <div class="stat stat-go"><div class="stat-l">Auto-migratable</div><div class="stat-v go">${R.pct_auto_migratable}%</div><div class="stat-sub">${num(cb.n_auto + cb.n_hint)} of ${num(R.totals.n_features)} features</div></div>
    <div class="stat ${cb.n_manual ? 'stat-blue' : ''}"><div class="stat-l">Manual setup features</div><div class="stat-v">${num(cb.n_manual)}</div><div class="stat-sub">binning, segments/metrics, click behavior, snippets</div></div>
    <div class="stat ${cb.n_unhandled ? 'stat-warn' : ''}"><div class="stat-l">Needs-review features</div><div class="stat-v ${cb.n_unhandled ? 'warn' : ''}">${num(cb.n_unhandled)}</div><div class="stat-sub">cumulative/offset calcs, progress, unknown MBQL</div></div>
  </div>
  <table class="data"><thead><tr><th>Bucket</th><th>Features</th><th>What it means</th></tr></thead><tbody>${coverageRows}</tbody></table>
</section>

<section>
  <div class="section-head"><span class="section-num">04</span><h2 class="section-title">Gap analysis</h2><span class="section-aside">${R.gap_histogram.length} distinct gap type${R.gap_histogram.length === 1 ? '' : 's'}</span></div>
  <p class="section-lede">Every feature that needs a human — named to the artifact, with the specific reason and the remediation. Amber = brief manual setup in Sigma; red = no clean analog, needs a decision before conversion. Identifying these up front means no surprises mid-migration.</p>
  ${R.gap_histogram.length ? `<table class="data"><thead><tr><th>Gap</th><th class="al-right">Count</th><th>Artifacts</th><th>Remediation</th></tr></thead><tbody>${gapRows}</tbody></table>` : '<p class="note">No manual or needs-review gaps detected — the entire estate converts cleanly.</p>'}
</section>

<section>
  <div class="section-head"><span class="section-num">05</span><h2 class="section-title">Effort &amp; wave plan</h2><span class="section-aside">3 waves · models before dependent dashboards</span></div>
  <p class="section-lede">A risk-minimizing migration sequence. Wave 1 is the low-risk pilot; Wave 3 holds anything with a needs-review feature, each requiring a human decision first. Within every wave, convert models ahead of the questions and dashboards that source them (dashcards and <code>card__N</code> refs point at the migrated model's element).</p>
  <div class="stat-row">
    ${waveBlock(1, 'pilot', 'migrate-first / easy-win — no needs-review features; models first, then their dashboards', wave1, 'stat-go')}
    ${waveBlock(2, 'standard', 'medium complexity — convert with light review', wave2, 'stat-blue')}
    ${waveBlock(3, 'review-first', 'contains a cumulative/offset calc, progress/unknown viz, or sandboxing policy', wave3, 'stat-warn')}
  </div>
  ${cb.n_unhandled || R.n_sandboxes ? `<div class="callout"><strong>${nReview} artifact${nReview === 1 ? '' : 's'}</strong> include a feature with no clean Sigma analog (cumulative/offset window calcs, progress viz, or unknown MBQL${R.n_sandboxes ? `, plus ${R.n_sandboxes} EE sandboxing polic${R.n_sandboxes === 1 ? 'y' : 'ies'} at the instance level` : ''}). Plan a short design decision for each before converting — the converter emits a flagged placeholder rather than guessing.</div>` : ''}
</section>

<section>
  <div class="section-head"><span class="section-num">06</span><h2 class="section-title">Recommended next steps</h2></div>
  <ol class="next-steps">
    <li><strong>Pilot Wave 1 (${wave1.length} artifact${wave1.length === 1 ? '' : 's'}).</strong> These convert with no needs-review features — the lowest-risk way to demonstrate an end-to-end Metabase→Sigma migration. Convert the models first, then the dashboards (and questions) that source them.</li>
    ${cb.n_unhandled || R.n_sandboxes ? `<li><strong>Hold a design review for the needs-review items.</strong> Decide the Sigma equivalent for each cumulative/offset calc, progress viz, or unknown MBQL construct${R.n_sandboxes ? ', and sandboxing policy (these port to Sigma user attributes via the RLS engine — reviewed per policy)' : ''} up front (see the gap analysis above).</li>` : ''}
    ${usageStep}
    <li><strong>Request a durable API key from the admin</strong> (Admin → Settings → Authentication → API keys, in a group with view access) so the conversion phase doesn't depend on a 14-day session token${R.n_sandboxes ? ' — and, since this is a Pro/EE instance, the Usage analytics audit export' : ''}.</li>
    <li><strong>Hand the pilot to the <code>metabase-to-sigma</code> converter.</strong> The per-artifact card/dashboard JSON and the per-database <code>metadata/*.metadata.json</code> (the field-id map the converter requires) are already cached from this scan — the converter can skip re-discovery and go straight to building the Sigma data model + workbook.</li>
  </ol>
</section>

<footer>Read-only assessment · generated ${h(fmtDate)} · supporting <code>coverage.json</code>${inv ? ' + <code>inventory.json</code>' : ''} alongside in the same folder · all-free migration tooling</footer>

</main></body></html>`;

writeFileSync(outFile, html);
console.log(`wrote ${outFile} (${html.length} bytes)`);
