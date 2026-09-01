# Environment & Windows setup

**Run the bootstrap first — it is the ONLY sanctioned way to fix a missing
runtime.** One idempotent, non-interactive command takes a fresh machine to
doctor-green (resolve a supported runtime profile, install only its
dependencies, persist creds, run doctor, and write the bootstrap sentinel):

- macOS / Linux / **Git Bash**: `bash scripts/bootstrap.sh`
- **Windows PowerShell**: `powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1`
- Dry run (report what WOULD install, change nothing): `bash scripts/bootstrap.sh --check`
  / `bootstrap.ps1 -Check`

It never requires admin (user-scoped winget/scoop on Windows; brew/rbenv/fnm
version-manager activation elsewhere; `pip --user` for Python deps), never
prompts (no-TTY-safe), and never echoes credential values. Node is pinned to
22 LTS; the PATH it activates persists to `~/.sigma-migration/path.sh` (bash)
/ the USER PATH (Windows), so later shells inherit it. `intake.rb` and
`migrate-tableau.rb` and `migrate-tableau.py` refuse to start until the
bootstrap sentinel + a passing `doctor.json` exist.

To require the supported no-Ruby path, add `--runtime-profile python` on
macOS/Linux or `-RuntimeProfile python` in PowerShell. `auto` prefers Ruby when
available and falls back to Python when Ruby cannot be installed. The Python
profile requires Python 3 and Node, not Ruby or bash; PowerShell is the Windows
launcher. See `../PYTHON_RUNTIME.md`.

**Agents: NEVER hand-install a runtime.** Do not `brew install` / `apt-get` /
`winget install` / download binaries or edit PATH yourself — run the bootstrap
and show the user its output. If the bootstrap reports no admin-free route on
the host, that message is for the **user** to act on; surface it and stop.

**The doctor** (`bash scripts/doctor.sh` / `scripts\doctor.ps1`) is the
verify-only half: it reports what's installed and writes the `doctor.json`
fingerprint the orchestrator gates on. The bootstrap runs it as its final step.
Exit 0 = good to go; every ✗/[X] line's remediation is the bootstrap one-liner.

## Required runtimes
| Tool | Used by | Notes |
|---|---|---|
| **ruby** | the supported Tableau Ruby profile and other Ruby-based skills | not required by the Tableau Python profile |
| **python 3** | looker / thoughtspot / microstrategy / sisense entrypoints + all discovery scripts | **Windows: the Store-alias stub bites — see below** |
| **node 18+** | the vendored converters (`converter/*.mjs`) and `*.mjs` build steps | often installed-but-not-on-PATH (version managers) — bootstrap activates it |
| **bash** | hand-driven `get-token.sh` / `*-auth.sh` only — the orchestrator mints tokens in-process | **Windows: use the Python twins instead (see below)** |

## Windows footguns (what the bootstrap handles for you)

1. **Python "Store stub."** A bare `python` / `python3` on Windows usually resolves to
   the Microsoft Store *App Execution Alias* — a stub that silently does nothing when
   run non-interactively (commands "hang or exit with no output"). The doctor and
   bootstrap both detect and reject the stub (they probe `py -3` first and refuse any
   interpreter under `WindowsApps`); `bootstrap.ps1` installs a real user-scoped Python
   when none exists. The skills' scripts are already hardened: Ruby/Node spawns resolve
   a real Python (skipping the stub), and Python entrypoints re-spawn via
   `sys.executable` — so after bootstrap, use `py -3 scripts/<x>.py` for hand-driven calls.

2. **No `bash` (or a flaky Git Bash).** `bootstrap.ps1` installs Git for Windows
   (ships Git Bash) user-scoped when no bash is present. But **don't fight bash for
   tokens at all** — the orchestrated path needs no token step (minted in-process),
   and hand-driven calls have shell-neutral Python twins. See
   **"Windows: tokens, JSON files, and env vars"** below.

3. **CRLF line endings.** If `git config core.autocrlf` is `true`, checkout can rewrite
   the shipped `.sh`/`.rb`/`.py` to CRLF and break shebangs (`\r: command not found`).
   Set `git config --global core.autocrlf input` and re-checkout (the doctor flags this).

4. **Ruby not on PATH.** `bootstrap.ps1` activates an existing RubyInstaller/scoop ruby
   or installs one user-scoped (winget/scoop) — no admin, no manual PATH surgery.

5. **Node installed but invisible / no admin rights.** Version managers (fnm/nvm)
   activate via interactive-shell profile hooks an agent shell never sources — so node
   is often installed yet "not found" (field-caught twice on one machine). The bootstrap
   probes the standard version-manager dirs — including fnm's macOS default home,
   `~/Library/Application Support/fnm` — and activates the install (persisting the
   PATH prepend); when node is genuinely absent it installs user-scoped, **pinned to
   the 22 LTS line** (in maintenance until 2027-04-30; the 20 line reached end-of-life
   2026-04-30, so new installs never land it — and never a floating "latest"):
   winget/scoop `fnm` on Windows, `brew node@22` or the pinned portable tarball into
   `~/.local/node` elsewhere. Never admin.
   **Manual fallback for the USER (no winget, no bootstrap route — last resort):**
   download the **22 LTS** zip from nodejs.org, extract to `%USERPROFILE%\node`, and
   add it to PATH — pin the explicit LTS version, never "latest". A documented,
   deliberate user step, not something an agent improvises mid-run.

## Windows: tokens, JSON files, and env vars

Three Windows-specific practices that prevent the most time-consuming failure loops
(each one was hit in a real Windows/Cortex-Code run):

1. **Tokens: the orchestrated path needs NO token step.** `migrate-tableau.rb`
   mints both the Sigma token (`lib/sigma_rest.rb`) and the Tableau PAT token
   (`lib/tableau_rest.rb`) **in-process** and injects them into child-script
   environments — no `eval "$(get-*-token.sh)"`, no bash, works identically under
   PowerShell / cmd / Git Bash. Do not bolt a token step onto the orchestrator.
   Only **hand-driven** REST calls need a token, and the shell-neutral Python twins
   cover Windows:

   ```powershell
   python scripts/get-tableau-token.py --print-token    # Tableau PAT signin (or: py -3 ...)
   python scripts/get_token.py --workdir <WORKDIR>      # Sigma token -> <WORKDIR>/auth.json
   ```

   These sidestep the Git Bash setups where the `.sh` twins' base64/curl plumbing
   fails. If you must hand-roll the Tableau signin yourself, the PAT signin body must
   be **XML** (JSON returns 400 "Payload malformed") — see the callout in
   refs/tableau-rest.md for the exact call.

2. **NEVER write workdir JSON with PowerShell `Set-Content -Encoding UTF8`.** On
   Windows PowerShell it prepends a **UTF-8 BOM**, and Ruby's `JSON.parse` rejects
   BOM'd files ("unexpected token") — so a hand-written `wb-spec.json` / `answers.json`
   / `parity-actuals.json` breaks the orchestrator in ways that look like a spec bug.
   Write BOM-less UTF-8 instead:

   ```powershell
   [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
   ```

   or write the file from Python (`open(path, "w", encoding="utf-8")` never emits a BOM).
   The orchestrator's reads of agent-authored specs are BOM-tolerant as a backstop, but
   other scripts' reads are not — don't rely on it.

3. **Expect per-invocation environment loss.** Agent runners on Windows often spawn a
   FRESH shell per command, so `eval "$(...)"`/`$env:X = ...` exports from one step are
   gone by the next. Use **file-based credentials** — the neutral cred file
   `~/.sigma-migration/env` written by `setup.rb` / `setup-tableau.rb` (every shared
   lib reads it at load, and the orchestrator's in-process token minting starts from
   it) and `<WORKDIR>/auth.json` (above) — rather than exported variables that
   silently evaporate between invocations.

## Managed-machine permission classifiers

Corporate-managed machines (and some agent harnesses) run **permission
classifiers** that can block two things a migration legitimately does:
executing "code from an external repository" and running credential-bearing
commands. Symptoms: script invocations denied with a generic policy message,
or every `ruby scripts/...` call stalling for approval. The fixes, in order:

1. **Install the skill as a PLUGIN** (marketplace install), not a bare `git
   clone` — plugin-installed script paths are recognized as part of the tool,
   where a clone under `~/src/...` reads as arbitrary external code.
2. **Apply the permissions allowlist** below (scoped to `scripts/*` — never a
   blanket `Bash(*)`), so the classifier sees a bounded, pre-approved surface.
3. **Never inline secrets into commands.** The scripts read credentials from
   the environment / `~/.sigma-migration/env` (written once by `setup.rb` /
   `setup-tableau.rb`) and mint tokens **in-process** — a command line should
   never contain a secret, and a secret-bearing `curl` is exactly what the
   classifier is right to block.

## Unattended runs & permission prompts

A conversion executes dozens of `ruby scripts/*.rb` / `python3 scripts/*.py`
commands. Under an agent harness with default permissions, every one of them
raises an approval prompt — and in an unattended session nobody is there to
answer. **Measured in a real field run: 258 of 376 minutes (69%) were lost
idle at unanswered permission prompts.** If a run will be unattended, have the
*user* pre-approve the skill's script surface first.

For Claude Code, a conservative allowlist in the project's
`.claude/settings.json` (other agents have equivalents):

```json
{
  "permissions": {
    "allow": [
      "Bash(ruby scripts/*)",
      "Bash(python3 scripts/*)",
      "Bash(bash scripts/bootstrap.sh*)",
      "Bash(bash scripts/doctor.sh*)",
      "Bash(node *)"
    ]
  }
}
```

Why each entry (and why nothing broader):

- `Bash(ruby scripts/*)` — the Ruby spine (orchestrator, discovery, gates,
  tests). Scoped to the skill's `scripts/` directory, **not** `ruby` in
  general.
- `Bash(python3 scripts/*)` — the Python twins (`get_token.py`,
  `land-extracts.py`, `visual-similarity.py`).
- `Bash(bash scripts/bootstrap.sh*)` — the mandatory Step-0 environment
  bootstrap (idempotent, user-scoped, never admin).
- `Bash(bash scripts/doctor.sh*)` — the environment doctor (read-only probe;
  bootstrap runs it as its final step).
- `Bash(node *)` — the vendored converter (`converter/tableau.mjs`) runs via
  `node`; tighten to `Bash(node converter/*)` if your harness matches the full
  command string.

Keep everything else behind a prompt **on purpose** — git mutations, package
installs, PATH edits, and raw `curl` are exactly the actions that should wait
for a human. This pairs with the token rule above: the scripts mint tokens
**in-process**, so an allowlisted `ruby scripts/...` command never needs a
secret-bearing `curl` (which permission classifiers on managed machines block
anyway — see the SKILL.md prerequisites rule).

> **Agents: never hand-install a runtime — the bootstrap is the ONLY sanctioned
> installer.** If the doctor reports a missing runtime, the fix is always the same
> one-liner: `bash scripts/bootstrap.sh` (PowerShell: `scripts\bootstrap.ps1`). It is
> deliberate where improvisation was the failure mode: user-scoped only, pinned
> installs, PATH activation persisted, never admin, never an unpinned download.
> Do not `brew install` / `winget install` / edit PATH on your own initiative.

> The converters themselves need **no clone, no `npm install`, no network, no MCP** —
> each skill ships a self-contained `converter/*.mjs` bundle run via `node`. So on
> Windows the only setup is: a real Python (`py -3`), Ruby on PATH, and Node. Tokens
> are minted in-process by the orchestrator (bash is only needed for hand-driven
> `.sh` helpers — and the Python twins cover those on Windows too).

## Credentials (relocated from SKILL.md — E9 diet)

> **⛔ NEVER hand-roll a signin `curl` — for Sigma OR Tableau.** Managed
> machines' permission classifiers block secret-bearing raw `curl`, and
> `curl -sf` hides the failure (a field session lost ~15 minutes to it). The
> scripts are the sanctioned AND classifier-friendly route: `setup.rb` /
> `setup-tableau.rb` once, in-process token minting everywhere, and
> `get_token.py` / `get-tableau-token.py` for hand-driven REST.

### Sigma credentials

`ruby scripts/setup.rb` once (bootstrap runs it `--from-env` when the vars are
exported). Writes `~/.claude/settings.json` (Claude Code auto-loads) and
`~/.sigma-migration/env` (neutral, auto-sourced by the scripts under any
agent). Required: `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, `SIGMA_CLIENT_SECRET`.
Tokens live ~1h — scripts auto-refresh; for hand-driven calls,
`python scripts/get_token.py --workdir <WORK>` (any shell). Shell footguns
(subshell `eval`, inline-python quoting): `refs/troubleshooting.md` §Shell.

> **Credentials are shell-neutral.** The Ruby/Python scripts mint Sigma tokens
> themselves from `SIGMA_CLIENT_ID`/`SIGMA_CLIENT_SECRET` (env or
> `~/.sigma-migration/env`) and auto-refresh — no `eval` step, any shell. For a
> hand-driven `curl`, mint explicitly: `python scripts/get_token.py --workdir
> <WORK>` writes `<WORK>/auth.json` (0600), read automatically by the scripts.
> (`eval "$(scripts/get-token.sh)"` still works in bash.)

### Tableau access — two modes

**Prefer the API/PAT path** — measured 61.8s serial → **13.7–18.9s** pooled on
the 7-view reference; the MCP is the **no-PAT fallback only** (each MCP fetch
is a separate agent turn).

| Mode | When | Setup |
|---|---|---|
| **PAT (REST)** — preferred | A Tableau PAT is available; only path to `.twb` content | `ruby scripts/setup-tableau.rb` once |
| **MCP** — fallback | No PAT, `mcp__tableau__*` tools loaded | None — host handles auth |

**PAT mode:** `migrate-tableau.rb` needs no token step (in-process mint, works
in PowerShell). Hand-driven only: `eval "$(scripts/get-tableau-token.sh)"`
(bash) or `python scripts/get-tableau-token.py --print-token`, then
`ruby scripts/tableau-discover.rb --workbook-id <luid> --out <WORK> [--pool N]`
→ same artifacts as MCP-driven Phase 1 in one run (workbook JSON, `.twb`,
`ds-metadata.json`, `graphql-fields.json`, `views/*.csv`, dashboard PNG,
`timings.json`). `--datasource-name`/`--datasource-luid` optional (auto-detect;
`--no-auto-ds` disables; LUID must be the full UUID). Pool mechanics + why 5:
`refs/tableau-rest.md` §fetch pool. Endpoint inventory: `refs/tableau-rest.md`.

> **One signin attempt only.** Tableau Cloud invalidates a PAT after 4 failed
> signins. `get-tableau-token.sh` runs exactly once; never wrap it in a retry loop.
