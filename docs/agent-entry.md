# Agent entry contract

How any coding agent (Claude Code, Cursor, Cortex Code, Codex, …) should load
and run skills from this repo. Skills are agent-neutral; packaging differs.

## Two install shapes

| Shape | Who | What you have on disk |
|---|---|---|
| **Claude Code marketplace plugin** | `/plugin install <name>@sigma-migration-skills` | One plugin tree under the agent's plugin root (self-contained `skills/`) |
| **Full repo clone** | Cursor, Cortex, Codex, plain checkout | Whole monorepo; point the agent at skill folders via [`AGENTS.md`](../AGENTS.md) |

Both shapes share the same unit of work: a skill directory containing
`SKILL.md` + `scripts/` + `refs/`.

## Load sequence (every agent)

1. **Pick the skill** from the [`AGENTS.md`](../AGENTS.md) index (intent → path).
   Prefer a skill whose maturity is `live` or `gold` unless the user explicitly
   wants a scaffold.
2. **Install / open the companion `sigma-authoring` plugin** alongside any
   converter. Converters defer workbook/DM idioms to `sigma-workbooks` /
   `sigma-data-models`; they are not self-sufficient for authoring edge cases.
3. **Read that skill's `SKILL.md` in full** before running anything. Follow its
   mandatory pre-read block (at most a few `refs/` files).
4. **`cd` into the skill directory**, then run scripts with relative paths
   (`scripts/…`). Do not invent absolute paths into other plugins.
5. **Authenticate to Sigma** from that skill directory (see
   [`AGENTS.md`](../AGENTS.md) §Credentials). Prefer an explicit interactive
   `scripts/browser-login.sh` run; use OAuth client credentials for
   unattended/CI hosts. Source-tool authentication remains a separate,
   skill-specific step.

## Path rules (marketplace-safe)

Skills must keep working when installed as a **single plugin** (no monorepo
siblings on disk):

- **Do** reference `scripts/` and `refs/` inside the current skill.
- **Do** refer to companion skills by **skill name** (`sigma-workbooks`,
  `sigma-data-models`) and, when a filesystem path is required in a full clone,
  the stable monorepo path
  `plugins/sigma-authoring/skills/<skill>/…` (from repo root).
- **Do not** link with deep `../../../../docs/…` relatives from a `SKILL.md` —
  those break under marketplace install. Point at repo docs by name
  (`docs/phase-schema.md`) only as "when working from a full clone".
- **Do not** reference the legacy sibling repo path `sigma-skills/…` or
  `~/sigma-skills/…`. That tree is upstream of `sigma-authoring` only; runners
  of *this* marketplace never need it.

`tools/lint-skill-paths.rb` enforces the banned path patterns.

## Sigma authentication

The recommended interactive flow is terminal-initiated browser OAuth 2.1
authorization code + PKCE. From the selected skill directory:

```bash
export SIGMA_BASE_URL='https://<your-published-sigma-api-host>'
eval "$(bash scripts/browser-login.sh)"
```

The helper opens the system browser and returns a roughly one-hour access token
to the current shell. On a supported host it stores the refresh session only in
the native OS keychain: macOS Keychain (`security`) or Linux Secret Service
(`secret-tool`). Without a usable keychain, the current access token is still
returned but no refresh session is persisted. The helper never puts a refresh
token in a repo, run directory, `auth.json`, or `~/.sigma-migration/env`.

`scripts/bootstrap.sh` / `scripts/bootstrap.ps1` and doctor are noninteractive:
they reuse available auth but **never open a browser**. If no usable keychain is
available (common in containers, cloud agents, headless CI, and some Windows
shells), configure `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, and
`SIGMA_CLIENT_SECRET`. OAuth client credentials are the unattended fallback,
not the preferred human login.

The shared REST clients use this resolution order:

1. an explicit `SIGMA_API_TOKEN` in the current process;
2. `<SIGMA_WORKDIR>/auth.json`, then `./auth.json`;
3. the shared token provider, which in default `SIGMA_AUTH_MODE=auto` tries the
   browser keychain/cache and then client credentials.

Set `SIGMA_AUTH_MODE=browser` to require keychain auth or
`SIGMA_AUTH_MODE=client-credentials` to skip keychain lookup. The override
selects how a new token is minted; it does not discard an already-supplied
access token.

For shells that should not use `eval`, write a mode-0600 token handoff:

```bash
python3 scripts/get_token.py --workdir <workdir>
export SIGMA_WORKDIR=<workdir>
```

`auth.json` contains `SIGMA_API_TOKEN`, `SIGMA_BASE_URL`,
`SIGMA_TOKEN_MINTED_AT`, and `SIGMA_AUTH_METHOD`—never a client secret or
refresh token. Access tokens last about one hour. With mint metadata, the
shared Ruby/Python clients proactively refresh at 50 minutes; they also refresh
and retry exactly once on a 401, then surface a second 401.

`~/.sigma-migration/env` (mode 0600) is the agent-neutral place for base URL,
client fallback settings, and `SIGMA_AUTH_MODE`; existing process environment
values win. Claude Code may additionally load `~/.claude/settings.json`.
Sigma auth is independent of Tableau PATs, Power BI device login, and every
other source-tool credential described by a skill.

## MCP stance

| Server | Required? | Role |
|---|---|---|
| **None for the core pipeline** | — | Converters drive Sigma via REST (`scripts/get-token.sh`, `lib/sigma_rest.rb`, orchestrators). |
| **Sigma MCP** | Optional, recommended | Read/query workbooks during parity and exploratory checks. |
| **Source-tool MCP** (e.g. Tableau) | Optional | Discovery without PAT/CLI when available. |
| **Hosted data-model converter MCP** | Optional, opt-in | Fallback for formula translation; each skill bundles a **local** converter by default (no data egress). |

Do not block a run solely because an MCP server is missing if the skill
documents a REST/CLI path.

## Runtime bookends (target shape)

Every converter should eventually expose the same seams (see
[`migration-runtime-contract.md`](migration-runtime-contract.md)):

1. bootstrap / doctor
2. one orchestrator entrypoint
3. hard completion gate (`assert-phase6` / `verify-complete`)
4. telemetry on finalize
5. **opt-in Phase E (C10)** — after parity green, `--enhance` runs the shared
   scan → design interview (`enhance-select` / `enhance-app-plan`) →
   accept-only clone apply. Scripts are vendored into every converter; only
   tableau/powerbi wire the flags today. See
   [`phase-schema.md`](phase-schema.md) §Phase E adoption checklist and
   each skill's `refs/phase-e-enhance.md`.

Until a skill has the first four, follow its local `SKILL.md` phases exactly —
do not improvise a lighter path. Phase E stays opt-in even when the other
bookends exist.

## Maturity labels

Defined for the [`AGENTS.md`](../AGENTS.md) index:

| Label | Meaning |
|---|---|
| `gold` | Orchestrated end-to-end spine + hard completion gate; preferred default |
| `live` | Live-validated against a real Sigma org (parity and/or assessment readout) |
| `foundation` | End-to-end path exists; expect sharper edges / more agent judgment |
| `scaffold` | Skeleton only — do not run for customer work unless explicitly building the skill |
