# Tableau supported Python runtime

Tableau migrations can run without Ruby. The supported Python profile requires
Python 3 and Node (the vendored Tableau converter is JavaScript). Bootstrap uses
bash on macOS/Linux or PowerShell on Windows, but Ruby is neither installed nor
invoked when this profile is selected.

## Select the Python profile

macOS/Linux:

```bash
bash scripts/bootstrap.sh \
  --runtime-profile python \
  --workdir <WORK>
```

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 `
  -RuntimeProfile python -WorkDir <WORK>
```

`--runtime-profile auto` prefers Ruby when its supported profile is available.
If Ruby cannot be installed or resolved, doctor selects the supported Python
profile and records the reason. Explicit Python selection always skips Ruby
installation.

The resulting `doctor.json` includes:

```json
{
  "runtimes": {"ruby": false, "python": true, "node": true},
  "runtime_profile": {
    "requested": "python",
    "selected": "python",
    "required_runtimes": ["python", "node"]
  }
}
```

## Run

From this skill directory:

```bash
python3 scripts/migrate-tableau.py \
  --workbook "<Tableau name or /views/ share URL>" \
  --connection <SIGMA_CONNECTION_ID> \
  --folder <SIGMA_FOLDER_ID> \
  --db <DATABASE> --schema <SCHEMA> \
  --landing <DB.SCHEMA-or-n/a> \
  --out <WORK>
```

The orchestrator is re-entrant. It performs Tableau discovery, source
classification, published-datasource hydration, embedded-extract landing,
strict Sigma reuse discovery, conversion, workbook construction, readback,
source-object accounting, REST parity collection, rendering, and completion
gates.

Important options:

- `--reuse-mode auto|new|require`: uniquely reuse, always create, or require a
  compatible existing Sigma object.
- `--data-model-id` / `--sigma-workbook-id`: verify and reuse explicit objects.
- `--no-auto-land`: keep embedded extract landing as a manual gate.
- `--skip-extract-landing "<reason>"`: explicit, artifact-recorded off-ramp;
  it never claims frozen-extract parity.
- `--workbook-template <file>`: bind a complete customer-local template when
  the automatic builder reports an unsupported or ambiguous source shape.
- `--expected` / `--actuals`: validated backcompat overrides. By default the
  Python path creates both artifacts and collects Sigma actuals automatically.

## Fail-closed exits

- exit 4: conversion, workbook binding, or source-object repair is required;
- exit 11: an unhandled Tableau feature needs a proved resolution;
- exit 12: parity planning or actual collection is incomplete;
- exit 15: source security needs an explicit implementation decision;
- exit 16: source image, render, anchors, or fresh blind grade is incomplete;
- exit 17: an embedded extract is not safely landed;
- exit 0: readback, accounting, numeric parity, visual floor, blind grade, and
  completion checks all pass.

Automatic support includes the common chart families, tables/pivots, safe
scatter and maps, filters, parameters, hosted images, dynamic text, and exact
page navigation. Unsupported Tableau actions or ambiguous encodings remain
typed blocking residues; the Python profile never substitutes a reduced
fidelity chart or silently drops an object.

Customer-specific templates and evidence stay in the workdir. Do not add
customer names, formulas, URLs, credentials, or blind-grade artifacts to the
plugin.
