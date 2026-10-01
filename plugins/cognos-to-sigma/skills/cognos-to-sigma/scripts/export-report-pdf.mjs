#!/usr/bin/env node
// Export a created Sigma Report to PDF; publish edits before first export.
import { writeFileSync } from 'node:fs';
import { api, parseArgs, sigmaEnv } from './lib/sigma-rest.mjs';

const args = parseArgs(process.argv.slice(2));
if (!args.report || !args.out) {
  console.error('usage: node scripts/export-report-pdf.mjs --report <reportId> --out <pdf> [--layout portrait|landscape]');
  process.exit(2);
}
const layout = args.layout || 'portrait';
if (!['portrait', 'landscape'].includes(layout)) throw new Error('layout must be portrait or landscape');
const post = await api('POST', `/v2/reports/${args.report}/export`, { format: { type: 'pdf', layout } });
if (post.status === 204) throw new Error('PDF export returned HTTP 204 (no job). Confirm the report is published and contains renderable data.');
if (!post.ok || !post.json?.queryId) throw new Error(`PDF export failed (HTTP ${post.status}): ${post.text.slice(0, 500)}`);
const { base, token } = sigmaEnv();
const timeout = Date.now() + 240_000;
while (Date.now() < timeout) {
  const res = await fetch(`${base}/v2/query/${post.json.queryId}/download`, { headers: { Authorization: `Bearer ${token}` } });
  const file = Buffer.from(await res.arrayBuffer());
  if (res.ok && file.subarray(0, 5).toString() === '%PDF-') {
    writeFileSync(args.out, file);
    console.log(JSON.stringify({ reportId: args.report, pdf: args.out, bytes: file.length }));
    process.exit(0);
  }
  // The download endpoint can return 204 (empty) while the PDF is rendering.
  if (res.status !== 404 && res.status !== 202 && res.status !== 204) throw new Error(`PDF download failed (HTTP ${res.status}): ${file.toString('utf8', 0, 300)}`);
  await new Promise((r) => setTimeout(r, 2000));
}
throw new Error('timed out waiting for Sigma Report PDF export');
