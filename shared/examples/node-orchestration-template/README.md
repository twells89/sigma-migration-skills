# Node orchestration template (bash-free, cross-platform)

A minimal, runnable reference for **Phase 1** of
[`../../refs/portability-strategy.md`](../../refs/portability-strategy.md): how a skill
orchestrator should be written so it runs **identically on macOS, Linux, and native Windows
PowerShell/cmd** — no bash, no `eval`, no `/tmp` literal, no `curl`, no `jq`, no `unzip` binary.

New skills (and any substantial rewrite of an existing one) should follow this shape. It is the
distilled version of the cognos-to-sigma Node orchestrator, with the one remaining bash dependency
removed.

## Run it

```
# proves the cross-platform primitives — NO Sigma credentials needed (safe in CI):
node orchestrate.mjs --self-test

# real run — shell-neutral auth then a live Sigma GET:
python scripts/get_token.py --workdir <WORKDIR>   # identical in bash / PowerShell / cmd
node orchestrate.mjs --workdir <WORKDIR>
```

Requires Node >= 18 (for global `fetch`). The zip helper additionally needs a real Python 3
(resolved Store-stub-safe via `py_resolve`).

## The patterns (and the anti-patterns they replace)

| Concern | Do this | Instead of | Old hit |
|---|---|---|---|
| **Auth** | `lib/auth.mjs`: env → `<workdir>/auth.json` → helpful cross-shell error | `eval "$(get-token.sh)"`; `spawnSync('bash', ['-c', ...])` | `migrate-cognos.mjs:102` |
| **Temp/work dir** | `lib/paths.mjs`: `os.tmpdir()` + `--workdir` | hardcoded `"/tmp/..."` | `pbi_exec.py:3`, `probe-controls.rb:81` |
| **HTTP** | global `fetch` (`lib/sigma-rest.mjs`) | `curl` | `wb-rep.rb:409`, `verify_parity.py:26` |
| **JSON** | native `JSON.parse` | `jq` | `wb-rep.rb:413-417` |
| **Unzip** | `lib/extract-zip.mjs` → Python stdlib `zipfile` (or `fflate`) | `unzip` binary | `tableau-discover.rb:196` |
| **Python interp** | `lib/py_resolve.mjs` (rejects the Windows Store stub) | bare `python3` | `test-telemetry-gate.rb:24` |

### On zip specifically

Node has **no** built-in zip-archive reader (`zlib` is gzip/deflate only). `lib/extract-zip.mjs`
uses **Python's stdlib `zipfile`** — cross-platform, and Python is already a required runtime. If
you are building a Node-only skill and want to drop the Python dependency, swap in a pure-JS lib
(`fflate` / `yauzl`) — both are dependency-light with no native compilation.

## Files

- `orchestrate.mjs` — the entry point; `--self-test` and a real `--workdir` run.
- `lib/auth.mjs` — shell-neutral credential load.
- `lib/sigma-rest.mjs` — `fetch`-based REST client + arg parser.
- `lib/paths.mjs` — cross-platform workdir/temp helpers.
- `lib/py_resolve.mjs` — Store-stub-safe Python resolver (sibling of `shared/lib/py_resolve.rb`).
- `lib/extract-zip.mjs` — cross-platform archive extraction.

## Not shown (intentionally)

This template is about the **portability seam**, not a full migration. Real converters are the
esbuild-bundled `converter/*.mjs` (source of truth: `sigma-data-model-mcp/src/*.ts`) — call those,
don't reimplement conversion here. Gates (`assert-doctor-ran.rb`, parity checks) still apply and
compose on top of this shape.
