// Shell-neutral Sigma auth adapter. Valid caller tokens are preserved; missing,
// known-stale, and 401-rejected tokens refresh through the canonical
// browser-first get_token.py provider (browser keychain, then client credentials).
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

export const TOKEN_REFRESH_AGE_MS = 50 * 60 * 1000;
const HERE = dirname(fileURLToPath(import.meta.url));

function readAuthFile(workdir) {
  if (!workdir) return {};
  const path = join(workdir, 'auth.json');
  if (!existsSync(path)) return {};
  try {
    const value = JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''));
    return {
      base: value.SIGMA_BASE_URL || value.baseUrl || value.base_url,
      token: value.SIGMA_API_TOKEN || value.token || value.access_token,
      mintedAt: value.SIGMA_TOKEN_MINTED_AT || statSync(path).mtime.toISOString(),
      authMethod: value.SIGMA_AUTH_METHOD,
    };
  } catch {
    return {};
  }
}

function publish(auth) {
  process.env.SIGMA_BASE_URL = auth.base;
  process.env.SIGMA_API_TOKEN = auth.token;
  if (auth.mintedAt) process.env.SIGMA_TOKEN_MINTED_AT = auth.mintedAt;
  if (auth.authMethod) process.env.SIGMA_AUTH_METHOD = auth.authMethod;
  return auth;
}

export function tokenRefreshDue(mintedAt, now = Date.now()) {
  if (!mintedAt) return false;
  const minted = Date.parse(mintedAt);
  return Number.isFinite(minted) && now - minted > TOKEN_REFRESH_AGE_MS;
}

function providerPath() {
  const candidates = [
    process.env.SIGMA_TOKEN_PROVIDER,
    resolve(HERE, '../../../scripts/get_token.py'),
  ].filter(Boolean);
  return candidates.find((path) => existsSync(path));
}

function pythonCommands() {
  const commands = [];
  if (process.env.SIGMA_PYTHON) commands.push([process.env.SIGMA_PYTHON]);
  commands.push(['python3'], ['python'], ['py', '-3']);
  return commands;
}

export function refreshSigmaAuth(workdir) {
  if (!workdir) throw new Error('a workdir is required to refresh Sigma authentication');
  const provider = providerPath();
  if (!provider) throw new Error('Sigma get_token.py provider not found');

  let result;
  for (const [command, ...prefix] of pythonCommands()) {
    result = spawnSync(command, [...prefix, provider, '--workdir', workdir], {
      encoding: 'utf8',
      env: process.env,
    });
    if (!result.error || result.error.code !== 'ENOENT') break;
    result = null;
  }
  if (!result) throw new Error('Python is unavailable; cannot refresh the Sigma token');
  if (result.status !== 0) {
    throw new Error(`Sigma token provider failed${result.stderr?.trim() ? `: ${result.stderr.trim()}` : ''}`);
  }
  const auth = readAuthFile(workdir);
  if (!auth.base || !auth.token || !auth.mintedAt || !auth.authMethod) {
    throw new Error('Sigma token provider wrote incomplete auth.json');
  }
  return publish(auth);
}

export function loadSigmaAuth(workdir, options = {}) {
  const file = readAuthFile(workdir);
  const auth = {
    base: process.env.SIGMA_BASE_URL || file.base,
    token: process.env.SIGMA_API_TOKEN || file.token,
    mintedAt: process.env.SIGMA_TOKEN_MINTED_AT || file.mintedAt,
    authMethod: process.env.SIGMA_AUTH_METHOD || file.authMethod,
  };
  const refresh = options.refresh || refreshSigmaAuth;
  const now = options.now ?? Date.now();
  const resolved = (!auth.base || !auth.token || tokenRefreshDue(auth.mintedAt, now))
    ? refresh(workdir)
    : publish(auth);
  return { ...resolved, base: resolved.base.replace(/\/$/, '') };
}
