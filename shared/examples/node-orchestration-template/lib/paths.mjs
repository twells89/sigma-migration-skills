// paths.mjs — cross-platform workdir/temp helpers. This is the replacement for the
// ~48 hardcoded `/tmp/...` literals across the Ruby/Python scripts (e.g.
// probe-controls.rb:81, pbi_exec.py:3, extract-pbir.py:37, build_workbook.py:339).
//
// `os.tmpdir()` resolves correctly on every OS (/tmp, /var/folders on macOS,
// %TEMP% on Windows) — never hardcode "/tmp".
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { mkdirSync } from 'node:fs';

// Resolve a working dir: explicit --workdir wins, else a namespaced temp dir.
export function resolveWorkdir(explicit, namespace = 'sigma-migration') {
  const dir = explicit || join(tmpdir(), namespace);
  mkdirSync(dir, { recursive: true });
  return dir;
}

export function workPath(workdir, ...parts) {
  return join(workdir, ...parts);
}
