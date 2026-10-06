// Shell-neutral Sigma auth adapter for the Cognos Node stack. Preserve a
// usable caller token; refresh missing, known-stale, and 401-rejected tokens
// through the co-located browser-first provider.
import { existsSync, readFileSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { pythonArgv } from './py_resolve.mjs';

export const TOKEN_REFRESH_AGE_MS = 50 * 60 * 1000;
const HERE = dirname(fileURLToPath(import.meta.url));

export function resolveAuthWorkdir(workdir) {
  return resolve(workdir || process.env.SIGMA_WORKDIR ||
    join(tmpdir(), `sigma-cognos-auth-${process.pid}`));
}

function readAuthFile(workdir) {
  const path = join(resolveAuthWorkdir(workdir), 'auth.json');
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
    resolve(HERE, '../get_token.py'),
  ].filter(Boolean);
  return candidates.find((path) => existsSync(path));
}

export function refreshSigmaAuth(workdir) {
  const resolvedWorkdir = resolveAuthWorkdir(workdir);
  const provider = providerPath();
  if (!provider) throw new Error('Sigma get_token.py provider not found');

  const [command, ...prefix] = pythonArgv();
  const result = spawnSync(command, [...prefix, provider, '--workdir', resolvedWorkdir], {
    encoding: 'utf8',
    env: process.env,
  });
  if (result.error?.code === 'ENOENT') {
    throw new Error('Python is unavailable; cannot refresh the Sigma token');
  }
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || '').trim();
    throw new Error(`Sigma token provider failed${detail ? `: ${detail}` : ''}`);
  }

  const auth = readAuthFile(resolvedWorkdir);
  if (!auth.base || !auth.token || !auth.mintedAt || !auth.authMethod) {
    throw new Error('Sigma token provider wrote incomplete auth.json');
  }
  return publish(auth);
}

export function loadSigmaAuth(workdir, options = {}) {
  const file = readAuthFile(workdir);
  const envToken = process.env.SIGMA_API_TOKEN;
  const usesFileToken = !envToken || envToken === file.token;
  const auth = {
    base: process.env.SIGMA_BASE_URL || file.base,
    token: envToken || file.token,
    mintedAt: process.env.SIGMA_TOKEN_MINTED_AT ||
      (usesFileToken ? file.mintedAt : undefined),
    authMethod: process.env.SIGMA_AUTH_METHOD ||
      (usesFileToken ? file.authMethod : undefined),
  };
  const refresh = options.refresh || refreshSigmaAuth;
  const now = options.now ?? Date.now();
  const resolved = (!auth.base || !auth.token || tokenRefreshDue(auth.mintedAt, now))
    ? refresh(resolveAuthWorkdir(workdir))
    : publish(auth);
  return { ...resolved, base: resolved.base.replace(/\/$/, '') };
}
