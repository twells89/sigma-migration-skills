# Migration Runtime Contract

**Status:** proposed (rollout tracked in [`structure-roadmap.md`](structure-roadmap.md) §R1) · **Last updated:** 2026-10-05

## Problem

When customers run the migration skills themselves, behavior diverges at the **seams** —
how input comes in, how the Sigma connection is resolved, and how a run ends. The
conversion cores are well-tested; the seams are prose in each `SKILL.md`, so every
customer's agent improvises differently. Observed failures:

- **Inconsistent input.** Customers drop a raw export (`.twb`/`.pbix`) instead of using the
  live source API. The cold-discovery path assumes live source access and degrades badly.
- **Token waste on connection resolution.** The agent free-searches Sigma for the
  connection that should back the data model, burning tokens on every run.
- **Authentication drift.** Interactive agents are told to provision a client
  secret, bootstrap is mistaken for an interactive login, or a raw access token
  expires during a long phase without a consistent refresh/retry policy.
- **Silent completion.** Telemetry (`sigma_telemetry.py` → Render) is documented as an
  optional manual step, not wired into the orchestrators. PowerBI never fires it; a run can
  "finish" without the agent prompting to send the signal.

These are one root cause — unstandardized seams — not three bugs. Fix: a shared **runtime
contract** of three bookend components, rolled out like the gap-scout (PR #153) and
coverage (PR #177) gates.

## Current-state facts (grounding)

- **Telemetry already exists and works.** `shared/lib/sigma_telemetry.py` POSTs
  `migration_complete` to `https://sigma-migration-telemetry.onrender.com/track`
  (payload: `tool`, `sigma_region`, `org_id_hash` = SHA256(client_id)[:8], `duration_seconds`,
  `success`, `skill_version`). Fanned out to 9 plugins via `shared/manifest.json`. CLI wrapper:
  `shared/scripts/report-telemetry.py`. **Gap is wiring, not feature** — it's an optional
  agent step; `migrate-powerbi.rb` has zero telemetry calls.
- **Completion hard-gate already exists.** `shared/scripts/assert-phase6-ran.rb` (8 sub-gates)
  is the canonical end-of-run gate, fanned out to 6 plugins, auto-run on
  `migrate-tableau.rb --finalize`. Escape hatches require a named reason.
- **Two rollout patterns:** byte-identical via `shared/manifest.json` + `tools/sync-shared.rb`
  (CoverageGate), or per-plugin native-language variants (ScoutGate). Telemetry & the gate
  use the byte-identical pattern.
- **Fanout mismatch:** telemetry → 9 plugins; hard-gate → 6 (missing **qlik, cognos, gooddata**).
- **Dual-mode Sigma auth exists in shared runtime.** The token provider defaults
  to browser-keychain auth with OAuth client credentials as fallback;
  `sigma_rest.rb` / `sigma_rest.py` preserve mint metadata, refresh proactively
  at 50 minutes, and retry one 401. The remaining contract work is consistent
  entry-point behavior and documentation, not a new authentication protocol.

## The contract

### ① Intake front-door (shared)
Runs first in every migration skill.
- **Resolve Sigma authentication once.** All commands are invoked from the
  selected skill directory. For an interactive human, recommend the explicit
  OAuth 2.1 authorization-code/PKCE flow:

  ```bash
  export SIGMA_BASE_URL='https://<your-published-sigma-api-host>'
  eval "$(bash scripts/browser-login.sh)"
  ```

  When persisted, the browser refresh session lives only in the native OS
  keychain (macOS `security` or Linux `secret-tool`); without one, only the
  current access token is returned. Bootstrap and doctor may reuse a stored
  session but are noninteractive and never open a browser.
- **Use one deterministic auth resolution order.** Existing
  `SIGMA_API_TOKEN` → `<SIGMA_WORKDIR>/auth.json` → `./auth.json` → shared token
  provider. In default `SIGMA_AUTH_MODE=auto`, the provider tries browser
  keychain/cache first, then `SIGMA_CLIENT_ID` / `SIGMA_CLIENT_SECRET`.
  `browser` requires the first route; `client-credentials` skips keychain
  lookup. An existing access token still has precedence.
- **Make automation explicit.** OAuth client credentials are the unattended/CI
  fallback. Cloud, container, headless, locked-keychain, and unsupported
  keychain environments must fall back to client credentials in `auto` mode or
  select `SIGMA_AUTH_MODE=client-credentials`; they must not copy a browser
  refresh token into a file.
- **Preserve refresh metadata.** A shell-neutral
  `python3 scripts/get_token.py --workdir <workdir>` writes mode-0600
  `auth.json` with only `SIGMA_API_TOKEN`, `SIGMA_BASE_URL`,
  `SIGMA_TOKEN_MINTED_AT`, and `SIGMA_AUTH_METHOD`. Refresh tokens remain in
  the keychain. Access tokens last about one hour; known-age tokens refresh at
  50 minutes. A REST request may refresh and retry once on a 401; a second 401
  fails loudly.
- **Keep auth domains separate.** This contract governs Sigma API auth only.
  Tableau, Power BI, Qlik, and other source-tool credentials follow their
  skill-specific flows and never enter the Sigma auth resolution chain.
- **Detect input mode:** `live` (source API + creds) · `file` (raw export only) · `both`.
- **Resolve the Sigma connection ONCE.** Prompt the user or read config; list connections a
  single time; cache to `run-dir/connection.json`. All downstream steps read that file —
  no free-searching. Shared `resolve-connection` helper (all converters need it).
- **Record run-start timestamp** to `run-dir/intake.json` → feeds telemetry `duration_seconds`.
- **Print an expectations banner** per mode.

### ② Raw-mode = build + warehouse self-verify
When the **source tool** is unreachable but Sigma/warehouse is live (the common
"customer dropped a `.twb`" case):
- Build DM + workbook from the export file (the XML is rich: calcs, chart specs, filters, layout).
- **Repoint verification** to the live **Sigma warehouse** connection, not the source tool.
  Real numbers; no diff against the source's rendered output.
- Skip source-side PNG/CSV diff in Phase 6; keep the warehouse-side sanity check.
- Banner: *"verified against warehouse — NOT against live <SourceTool>."*
- `assert-phase6-ran.rb` learns a `mode` flag so it accepts warehouse-verified parity instead
  of hard-failing on missing source-side artifacts.

### ③ Completion gate (shared)
Wire the **existing** telemetry into the finalize path + enforce it.
- Fire `sigma_telemetry` in the orchestrator finalize path on **both success and failure**
  (so it cannot sit behind a passing parity gate).
- Add **Gate 9** to `assert-phase6-ran.rb`: verify a `run-dir/telemetry-sent.json` marker
  exists. Agent can't declare GREEN without it. Escape hatch `--skip-telemetry-gate <reason>`.
- Print the standardized handoff / next-steps.

## Rollout (3 PRs, each lands independently)

1. **Completion gate** — wire existing telemetry into every orchestrator finalize path +
   add Gate 9. Duration from run-dir mtimes until ① lands. Fixes the PowerBI miss. Smallest,
   lowest risk, proves the mechanic.
2. **Intake + `resolve-connection` cache** — biggest token + bad-conversion win; records
   run-start so duration tracking gets clean.
3. **Raw-mode warehouse-verify** — depends on ①'s mode detection; goes last.

## Resolved decisions (2026-06-26)

- **D1 — gate fanout → extend to all 9.** Add qlik/cognos/gooddata to the
  `assert-phase6-ran.rb` fanout so telemetry (Gate 9) is enforced on every plugin. No plugin
  can finish silently.
- **D2 — connection resolution → config-first, prompt on miss.** Intake reads
  `~/.sigma-migration/config` first; prompts only when no connection is cached/configured.
  Zero tokens on repeat runs.
- **D3 — telemetry payload → add `mode` enum.** Record `mode: live|file|both` (no PII) so we
  can measure how often customers run file-only — the path that degrades — and target
  investment.
