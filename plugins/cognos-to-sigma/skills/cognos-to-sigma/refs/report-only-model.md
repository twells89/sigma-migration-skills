# Report XML: Reuse Or Create The Model

A migration creates the semantic layer and the report. An existing Sigma model
is optional. Do not run the print converter with an invented `--dm`, or spend
repeated discovery rounds searching for a model that should be built.

## Verify the installed converter

The Cognos converter belongs to `twells89/sigma-migration-skills`, plugin
`cognos-to-sigma`. Updating the separate `sigma-skills` authoring repository
does not update this converter or its bundled scripts. Confirm the loaded
skill path, plugin version and `converter/PROVENANCE.json` before retrying a
previous failure. Install/update the Cognos plugin from the migration marketplace;
keep companion authoring skills installed too.

## Model inputs

Prefer a Cognos Data Module JSON or Framework Manager `model.xml` export: it
contains semantic-layer definitions that report XML does not. Convert it through
Phase 1, perform the reuse check once, and POST a new model if no valid reusable
model exists. No source login is needed when the required exports are already
available.

When only report XML/PDF is available, the following source-model builder makes
the missing-data requirement explicit and creates a new Sigma model once the
warehouse mapping is verified. It does not implement unsupported report-level
joined/aggregated queries or turn physical tables into an invented semantic model.

### 1. Inventory requirements (offline)

From the skill directory, write all outputs outside the repository:

```bash
node scripts/build-dm-from-report.mjs --report /private/report.xml \
  --out /private/source-map.json
```

Exit 10 means the mapping needs completion. The file lists exact three/four-part
logical subject references, their required fields, and report query dependencies.
Disabled filters and quoted string literals do not invent source fields. The PDF
is a layout/value reference, not a warehouse mapping.

### 2. Discover and fill physical mappings

Use the selected Sigma connection's warehouse lookup and column catalog (or the
source semantic-model export) to resolve each logical subject. Do not assume
`[Business].[Orders]` means a table named `ORDERS`. Ask the source owner when a
logical item is a calculation, subject is a join, or model-level security is
unknown. Example mapping (synthetic):

```json
{
  "modelName": "Order reporting",
  "sourceModelReviewed": true,
  "subjects": [{
    "ref": "[Business].[Orders]",
    "path": ["ANALYTICS", "REPORTING", "FACT_ORDERS"],
    "columns": {"Region": "REGION_NAME", "Revenue": "NET_AMOUNT"}
  }]
}
```

`sourceModelReviewed: true` is an explicit confirmation that these mappings
preserve the source model's calculations, joins and security, not a flag to set
merely to bypass a gate. If a direct-table mapping cannot preserve them, obtain
the Data Module/FM export or construct a reviewed native model with the companion
`sigma-data-models` skill. Never invent physical columns, flatten away joins or
ignore source security.

### 3. Build, then reuse or create

```bash
node scripts/build-dm-from-report.mjs --report /private/report.xml \
  --mapping /private/source-map.json --connection <connection-id> \
  --out /private/model.json
```

This verifies every physical table/column through Sigma before emitting a model.
It preserves Cognos subject/column display names for the report's formula bindings.
One bounded reuse check can compare this candidate to existing models. If none
matches, **create the new model**, rather than asking for an existing one:

```bash
node scripts/build-dm-from-report.mjs --report /private/report.xml \
  --mapping /private/source-map.json --connection <connection-id> \
  --out /private/model.json --create --folder <approved-folder-id>
```

The script POSTs the model and checks real element IDs and error-column readback.
Creation state is saved as `model.json.state.json` before readback; a repeated
create with that state path is refused to avoid duplicate models. A `.create-lock`
also prevents concurrent creates and remains after an indeterminate POST result.
On failure, inspect/repair the recorded model or confirm whether the POST created
one before clearing a lock; never blindly retry with a new output path.

For the workbook pipeline, use the generated spec instead:

```bash
node scripts/migrate-cognos.mjs --dm-spec /private/model.json \
  --report /private/report.xml --connection <connection-id> \
  --folder <approved-folder-id> --out /private/run
```

That path retains the normal reuse-or-create and verification phases. Do not
both manually create and then force creation again through the orchestrator.

### 4. Convert the native report

Use the returned dataModelId in `converter/cli.mjs --print --dm ...`, then
`scripts/remap-report-to-dm-ids.mjs` and the Report dry-run/readback/export gates.
Model creation success is not report completion: unresolved report queries,
scoped totals, nested records, prompts or page resets remain independent work.
If the print converter stops, identify the exact query/layout gap; do not embed
the PDF as an image or claim that finding/creating a model fixes the layout.
