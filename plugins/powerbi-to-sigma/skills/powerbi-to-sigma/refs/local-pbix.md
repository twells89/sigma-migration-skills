# Fully-local `.pbix` → Sigma (no Fabric, no tenant)

When the user has only a local `.pbix` file on disk — not published to Power BI
Service / Fabric — you do **not** need the device-code CONNECT/EXTRACT flow. The
orchestrator extracts both halves locally:

```
ruby scripts/migrate-powerbi.rb --pbix <file.pbix> \
  --connection <SIGMA_CONN_UUID> --database <DB> --schema <SCHEMA> \
  --ref-dm <referenceDataModelId> --out <WORK>
```

`--pbix` runs a **Phase 0** that produces the same two artifacts the Fabric path
does, then the normal convert → build → verify pipeline runs unchanged:

| Half | Script | Source inside the `.pbix` |
| --- | --- | --- |
| Model (`model.bim`, TMSL) | `extract-model-pbix.py` | the binary VertiPaq `DataModel` blob (via **pbixray**) |
| Report (`signals.json`) | `extract-report-classic.py --pbix` | the `Report/Layout` member (a single **UTF-16LE** classic `sections[]` doc) — **stdlib only** |

You can also run either extractor standalone:

```
python3 scripts/extract-model-pbix.py   --pbix <file.pbix> --out model.bim [--name "Sales"]
python3 scripts/extract-report-classic.py --pbix <file.pbix> --out signals.json
# or, from an already-extracted Report/Layout file (UTF-16LE or UTF-8):
python3 scripts/extract-report-classic.py --report-layout <Layout> --out signals.json
```

## Import-mode `.pbix` with no live warehouse

A local `.pbix` is usually **import mode** — a frozen snapshot with no warehouse to
point Sigma at. Land the frozen data into a warehouse first (see the Import-mode →
Snowflake data-landing skill), then pass that landing's connection/db/schema as
`--connection/--database/--schema`. The M queries pbixray recovers are carried into
`model.bim` partitions, so a `.pbix` that DID read from a warehouse keeps its table
names and the converter just repoints db/schema to your `--database/--schema`.

## Composite / live-connected reports (why the local `.pbix` wins)

A **composite** report (local tables + a reference to a shared/remote dataset) or a
report **live-connected** to a shared dataset does NOT yield a complete model from
Fabric `getDefinition` — you get the report's bound model, which is missing the
report-local measures/calc tables (composite) or isn't resolvable standalone
(thin-live). Power BI also **blocks export-to-`.pbix`** for live-connected reports,
so device-auth can't just download it. The COMPLETE composite model lives in the
author's local `.pbix`, so prefer `--pbix`.

Detection:
- **Fabric path (`--tmsl`):** the orchestrator scans the extracted TMSL for
  DirectQuery partitions, `entity` partitions bound to a remote model, or M
  expressions naming the AnalysisServices / Power BI dataset connector. On a hit it
  STOPS (exit 10) with an OPEN QUESTION asking for the local `.pbix` (override:
  `--allow-incomplete-model`). Import-mode models never trip it.
- **Offline (`.pbix`):** `extract-model-pbix.py --detect-composite --pbix <file>`
  prints `{"composite":bool,"remoteArtifacts":[…]}` — the tell is the zip's
  `Connections` member listing `RemoteArtifacts` ([{DatasetId, ReportId}]) or a
  connection string pointing at a remote PBI model (`pbiazure` /
  `PbiModelDatabaseName`). Pure/stdlib — no pbixray. Unit-tested in
  `tests/test-extract-model-pbix.py`.

## pbixray install (the one fragile dependency)

Only the **model** half needs pbixray. It is intentionally **not** in
`scripts/requirements.txt` (so the default `run.sh` venv bootstrap stays CI-robust):
pbixray depends on `xpress9` and `xmhuffman`, whose **PyPI sdists are broken** and
must be built **from source**. Install once, into the interpreter you pass as
`--python` (or the skill's `<work>/.venv`):

```
pip install apsw pandas xpress8 \
  "git+https://github.com/Hugoberry/xpress9-python@main" \
  "git+https://github.com/Hugoberry/xmhuffman-cython@main" \
  pbixray
```

Notes / caveats:
- `xpress8` ships a working wheel; `xpress9` + `xmhuffman` are the from-source builds
  (they need a C/Cython toolchain — Xcode CLT on macOS, `build-essential` on Linux).
- Verified working on CPython **3.13** (macOS arm64): `xpress9` built to 0.3.8,
  `xmhuffman` to 0.3.0, `pbixray` 0.15.2, `apsw`, `pandas`.
- Without pbixray, `extract-model-pbix.py` / `migrate-powerbi.rb --pbix` exit with a
  clear **"pbixray required for local model extraction"** message pointing here. The
  **report** front door (`extract-report-classic.py --pbix`) and the Fabric `--tmsl`
  path do **not** need pbixray.

## How the model maps (pbixray → TMSL)

`extract-model-pbix.py` reads these pbixray DataFrames and assembles a TMSL
`{ "name", "model": { "tables": […], "relationships": […] } }`:

| pbixray | → TMSL |
| --- | --- |
| `schema` (`TableName`,`ColumnName`,`PandasDataType`) | `table.columns[].{name,dataType,sourceColumn}` (pandas dtype → `int64`/`double`/`dateTime`/`boolean`/`binary`/`string`) |
| `dax_measures` (`TableName`,`Name`,`Expression`) | `table.measures[].{name,expression}` |
| `dax_columns` (`TableName`,`ColumnName`,`Expression`) | `table.columns[]` marked `type:"calculated"` |
| `dax_tables` (`TableName`,`Expression`) | `table.partitions[].source` marked `type:"calculated"`; output columns marked `type:"calculatedTableColumn"` |
| `power_query` (`TableName`,`Expression`) | regular-table `partitions[].source` (M passthrough → warehouse FQN; tables with neither M nor calculated-table DAX get an honest placeholder partition) |
| `relationships` (`From*`,`To*`,`IsActive`,`CrossFilteringBehavior`) | `model.relationships[].{name,fromTable,fromColumn,toTable,toColumn,crossFilteringBehavior,isActive}` |

The assembly (`assemble_tmsl` / `build_model_from_pbixray`) is a pure function of
those DataFrames — unit-tested with mocked dataframes in
`tests/test-extract-model-pbix.py` (no pbixray needed), which also asserts the
emitted `model.bim` converts cleanly through the vendored converter.
