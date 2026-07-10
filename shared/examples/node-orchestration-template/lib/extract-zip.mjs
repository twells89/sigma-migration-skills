// extract-zip.mjs — cross-platform archive extraction, the honest replacement for
// shelling `unzip` (tableau-discover.rb:196, fetch-all-twbs.rb:223) which does not
// exist on stock Windows.
//
// IMPORTANT: Node has NO built-in zip-archive reader (`zlib` is gzip/deflate only).
// So the portable choices are:
//   (a) Python's stdlib `zipfile` — cross-platform, and Python is already a required
//       runtime. We resolve a real interpreter via py_resolve (Store-stub-safe).  ← used here
//   (b) a pure-JS lib (`fflate` / `yauzl`) — no native compile, if you want to drop
//       the Python dependency for a Node-only skill.
//
// This uses (a): one stdlib Python one-liner, no `unzip` binary, no temp script file.
import { spawnSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { pythonArgv } from './py_resolve.mjs';

export function extractZip(zipPath, destDir) {
  mkdirSync(destDir, { recursive: true });
  const PY = pythonArgv();
  const code =
    'import sys,zipfile;' +
    'zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])';
  const r = spawnSync(PY[0], [...PY.slice(1), '-c', code, zipPath, destDir], { encoding: 'utf8' });
  if (r.status !== 0) {
    throw new Error(`extractZip failed (${zipPath} → ${destDir}): ${r.stderr || r.stdout || 'unknown error'}`);
  }
  return destDir;
}
