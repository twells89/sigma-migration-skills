// auth.mjs — SHELL-NEUTRAL Sigma credential load. No bash, no `eval`, no curl.
//
// This is the pattern that replaces `eval "$(get-token.sh)"` (bash-only) and the
// `spawnSync('bash', ['-c', 'eval "$(get-token.sh)" ...'])` shim still living in
// cognos-to-sigma/scripts/migrate-cognos.mjs:102. It works identically in bash,
// PowerShell, and cmd.
//
// Resolution order (same contract as shared/lib/sigma_rest.rb):
//   1. env SIGMA_API_TOKEN + SIGMA_BASE_URL           (already exported / CI secret)
//   2. <workdir>/auth.json written by `python scripts/get_token.py --workdir <W>`
//   3. fail with a cross-shell instruction (never a bash-only one)
//
// auth.json shape: { "token": "...", "baseUrl": "https://aws-api.sigmacomputing.com", ... }
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export function loadSigmaAuth(workdir) {
  let base = process.env.SIGMA_BASE_URL;
  let token = process.env.SIGMA_API_TOKEN;

  if (!token && workdir) {
    const authPath = join(workdir, 'auth.json');
    if (existsSync(authPath)) {
      const a = JSON.parse(readFileSync(authPath, 'utf8'));
      token = a.token || a.access_token || a.SIGMA_API_TOKEN;
      base = base || a.baseUrl || a.base_url || a.SIGMA_BASE_URL;
    }
  }

  if (!token || !base) {
    // Deliberately shell-neutral: this instruction runs verbatim on Windows.
    console.error(
      'Missing Sigma credentials. Run this first (identical in bash / PowerShell / cmd):\n' +
      '  python scripts/get_token.py --workdir <WORKDIR>\n' +
      'then re-run with --workdir <WORKDIR>. (Or export SIGMA_API_TOKEN + SIGMA_BASE_URL.)',
    );
    process.exit(2);
  }
  return { base: base.replace(/\/$/, ''), token };
}
