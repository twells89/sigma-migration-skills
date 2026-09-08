#!/usr/bin/env node
// report-telemetry.mjs — fire an anonymous usage ping after a successful migration.
//
// Usage (after get-token.sh has been eval'd):
//   node scripts/report-telemetry.mjs --duration <seconds> [--failed]
//
// What IS sent:  tool, sigma_region, org_id_hash (SHA256 of SIGMA_CLIENT_ID first 8 chars),
//               duration_seconds, success flag, skill_version
// What is NOT sent: workbook names/IDs, SQL, column names, dashboard titles, user email
// See https://github.com/twells89/sigma-migration-telemetry/blob/main/TELEMETRY.md

import { createHash } from 'node:crypto';
import { parseArgs } from './lib/sigma-rest.mjs';

const ENDPOINT = 'https://sigma-migration-telemetry.onrender.com/track';
const SKILL_VERSION = '1.0';

function regionFromBase(base = '') {
  if (base.includes('.au.')) return 'au';
  if (base.includes('.eu.')) return 'eu';
  if (base.includes('.uk.')) return 'uk';
  if (base.includes('.ca.')) return 'ca';
  return 'us';
}

function orgHash(clientId = '') {
  return createHash('sha256').update(clientId).digest('hex').slice(0, 8);
}

const args = parseArgs(process.argv.slice(2));
const success = !args.failed;
const duration = parseInt(args.duration ?? '0', 10);

const payload = {
  event:            'migration_complete',
  tool:             'metabase-to-sigma',
  sigma_region:     regionFromBase(process.env.SIGMA_BASE_URL),
  org_id_hash:      orgHash(process.env.SIGMA_CLIENT_ID),
  duration_seconds: duration,
  success,
  skill_version:    SKILL_VERSION,
};

console.log('\nReporting anonymous migration telemetry (no customer data sent):');
for (const [k, v] of Object.entries(payload)) {
  if (k !== 'event') console.log(`  ${k}: ${v}`);
}

try {
  const res = await fetch(ENDPOINT, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(5000),
  });
  console.log(`  → telemetry sent (${res.status})\n`);
} catch {
  console.log('  → telemetry unavailable (skipped)\n');
}
