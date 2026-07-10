// py_resolve.mjs — find a REAL Python interpreter, robust to the Windows Store
// "App Execution Alias" stub (a zero-op shim under ...\WindowsApps\ that silently
// does nothing when run non-interactively). JS sibling of shared/lib/py_resolve.rb.
//
//   import { pythonArgv } from './py_resolve.mjs';
//   const PY = pythonArgv();                 // e.g. ['python3'] or ['py','-3']
//   spawnSync(PY[0], [...PY.slice(1), script, ...args], opts);
//
// Returns an argv array (the Windows launcher is two tokens). Memoized per process.
// Override with SIGMA_PYTHON / PYTHON.
import { spawnSync } from 'node:child_process';

let _pyArgv;

export function pythonArgv() {
  if (_pyArgv) return _pyArgv;
  const isWin = process.platform === 'win32';
  const real = (cand) => {
    const v = spawnSync(cand[0], [...cand.slice(1), '--version'], { encoding: 'utf8' });
    if (v.status !== 0 || !/Python\s+\d/i.test(`${v.stdout || ''}${v.stderr || ''}`)) return false;
    if (isWin) { // reject an interpreter that lives under WindowsApps (the stub)
      const e = spawnSync(cand[0], [...cand.slice(1), '-c', 'import sys; print(sys.executable)'], { encoding: 'utf8' });
      if (e.status === 0 && /windowsapps/i.test(e.stdout || '')) return false;
    }
    return true;
  };
  for (const k of ['SIGMA_PYTHON', 'PYTHON']) {
    const v = (process.env[k] || '').trim();
    if (v && real(v.split(/\s+/))) return (_pyArgv = v.split(/\s+/));
  }
  const cands = isWin ? [['py', '-3'], ['python3'], ['python']] : [['python3'], ['python']];
  for (const c of cands) { if (real(c)) return (_pyArgv = c); }
  return (_pyArgv = isWin ? ['py', '-3'] : ['python3']); // let the caller's error path fire
}
