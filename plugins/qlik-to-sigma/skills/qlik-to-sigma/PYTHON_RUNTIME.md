# Qlik supported Python runtime

Qlik migrations can run with no Ruby installed. The supported Python profile
requires Python 3 and Node; Node is mandatory because the vendored
`converter/qlik.mjs` bundle runs locally. Bootstrap uses bash on macOS/Linux or
PowerShell on Windows, but it does not install or invoke Ruby for this profile.

## Select and verify the profile

From this skill directory, use the same workdir for bootstrap, doctor, token
output, and migration artifacts.

macOS/Linux/Git Bash:

```bash
bash scripts/bootstrap.sh --runtime-profile python --workdir <WORK>
bash scripts/doctor.sh --runtime-profile python --workdir <WORK>
```

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 `
  -RuntimeProfile python -WorkDir <WORK>
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1 `
  -RuntimeProfile python -WorkDir <WORK>
```

`--runtime-profile auto` prefers the supported Ruby profile when Ruby is
healthy. If Ruby is unavailable, it automatically selects Python. Explicit
`--runtime-profile python` skips Ruby installation. In both cases
`doctor.json` records `selected: "python"`, `required_runtimes:
["python","node"]`, and may truthfully record `runtimes.ruby: false`.

The Python front door hard-gates on both `<WORK>/doctor.json` and
`<WORK>/bootstrap.json`. Do not synthesize or edit those files during a real
migration; rerun bootstrap if the gate fails.

## Python setup, token, and destination commands

Persist Sigma credentials without Ruby:

```bash
python3 scripts/setup.py
# Non-interactive:
python3 scripts/setup.py --from-env
```

On Windows, replace `python3` with `py -3`. Both setup profiles write the same
`~/.sigma-migration/env` and `~/.claude/settings.json`.

The Python orchestrator mints and refreshes its token in process. To create a
shell-neutral token file for a manual REST helper:

```bash
python3 scripts/vendor/get_token.py --workdir <WORK>
# Bash-only export form, when needed:
eval "$(python3 scripts/vendor/get_token.py --print-export)"
```

Choose a destination before building when the user did not supply one:

```bash
python3 scripts/pick_destination.py list
python3 scripts/pick_destination.py create --name "<name>" \
  [--parent <workspace-or-folder-id>]
```

Pass the chosen workspace or folder id to `--folder`. The Python front door
never guesses among Sigma connections. Resolve and cache one before the build:

```bash
python3 scripts/intake.py --workdir <WORK> --tool qlik-to-sigma \
  --mode live [--connection <id>] [--name <name-substring>]
```

The orchestrator reads `<WORK>/connection.json`, so the live command may omit
`--connection` after intake.

## One-command live conversion

```bash
python3 scripts/migrate-qlik.py \
  --app <qlikAppId> --context <qlik-cli-context> \
  --connection <SIGMA_CONNECTION_ID> \
  --database <DB> --schema <SCHEMA> \
  --folder <SIGMA_FOLDER_ID> --out <WORK> --yes
```

For client-managed Qlik Sense, configure `QLIK_BIN` as documented in
`refs/connection-onprem.md`; the front-door command is otherwise unchanged.

## One-command offline conversions

A captured discovery fixture needs no Qlik tenant, Sigma org, credentials, or
network. Use the explicit offline doctor mode to create runtime evidence without
persisting fake credentials:

```bash
export SIGMA_OFFLINE_DRY_RUN=1
bash scripts/bootstrap.sh --runtime-profile python --workdir <WORK>
python3 scripts/migrate-qlik.py \
  --from-discovery fixtures/retail-orders \
  --connection 00000000-0000-0000-0000-000000000000 \
  --database DEMO_DB --schema DEMO \
  --dry-run --yes --out <WORK>
```

A standard corectl export uses the same Python entrypoint:

```bash
python3 scripts/migrate-qlik.py \
  --unbuild <app-unbuild-dir> \
  --connection 00000000-0000-0000-0000-000000000000 \
  --database <DB> --schema <SCHEMA> \
  --dry-run --yes --out <WORK>
```

Dry-run still runs source-coverage and spec gates and must emit meaningful data
model/workbook artifacts; it only suppresses Sigma writes. The Python path does
not silently drop a gate or fall back to the Ruby orchestrator. Unset
`SIGMA_OFFLINE_DRY_RUN` before any live build; the orchestrator rejects that
combination fail-closed.
