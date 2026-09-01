# Tableau Python runtime preview

The Tableau converter has an explicit no-Ruby preview. It requires Python 3,
Node (for the vendored converter), and bash or PowerShell for environment
bootstrap. It is not a Python-only single-runtime distribution.

## Enable the preview

```bash
bash scripts/bootstrap.sh \
  --runtime-profile python \
  --allow-preview-runtime \
  --workdir <WORK>
```

PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 `
  -RuntimeProfile python -AllowPreviewRuntime -WorkDir <WORK>
```

The doctor records:

```json
{
  "runtimes": {"ruby": false, "python": true, "node": true, "bash": true},
  "runtime_profile": {
    "requested": "python",
    "selected": "python",
    "required_runtimes": ["python", "node", "bash"]
  }
}
```

## Run

```bash
python3 scripts/migrate-tableau.py \
  --workbook "<Tableau name or /views/ share URL>" \
  --connection <SIGMA_CONNECTION_ID> \
  --folder <SIGMA_FOLDER_ID> \
  --db <DATABASE> --schema <SCHEMA> \
  --landing <DB.SCHEMA-or-n/a> \
  --out <WORK>
```

The orchestrator is re-entrant and fail-closed:

- exit 4: converter repair or complete workbook template required;
- exit 12: source/Sigma parity actuals required;
- exit 15: source security decision or implementation required;
- exit 16: source image, render, or fresh blind grade required;
- exit 0: readback, numeric parity, machine visual floor, blind visual grade,
  and completion gate all pass.

Customer-specific workbook templates stay in the workdir. Bind them with
`build-workbook-template.py`; do not add customer names, formulas, URLs, or
credentials to the plugin.

## Why this is preview

The Python path preserves all gates, but automatic source-to-workbook building
is still being ported. Until it is corpus-proven across representative Tableau
workbook classes, `auto` will prefer Ruby and will not select this preview.
Explicit preview opt-in is required so a missing runtime never becomes a silent
fidelity waiver.
