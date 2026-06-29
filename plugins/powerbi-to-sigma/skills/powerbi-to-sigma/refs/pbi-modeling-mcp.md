# Power BI Modeling MCP — a macOS-viable XMLA connector (optional alternative)

Validated 2026-06-29, tenant `sigmacomputing.com`, `Test` workspace (Fabric capacity).

Microsoft's [Power BI Modeling MCP](https://github.com/microsoft/powerbi-modeling-mcp)
(`@microsoft/powerbi-modeling-mcp`) is a local stdio MCP server that reaches a
semantic model over **XMLA** using a bundled cross-platform TOM/ADOMD client.
It is the reason `refs/connection.md`'s "XMLA is dead on macOS" caveat is no
longer absolute: where the model is on **PPU / Fabric capacity** (XMLA endpoint
enabled), this MCP reads it from macOS — no Windows ADOMD, no Entra app, no
secrets (interactive browser login).

## When to use it vs the default device-code path
The **default Phase 1/2 path stays `scripts/fabric-extract.py`** (device-code,
no codesign hassle, works tenant-wide incl. My-workspace, and is what `run.sh`
drives). Reach for the Modeling MCP only when one of these is true:
- The model is reachable by **XMLA but not by `getDefinition`/`executeQueries`** REST (some capacity/permission combos).
- You want **interactive, ad-hoc model exploration** (browse tables/measures/DAX, run scratch DAX) without writing a script.
- You have a **local `.pbix`/PBIP/TMDL** or Analysis Services instance (it can attach to those too).

It is NOT a tenant-inventory tool (that's `powerbi-assessment`) and NOT required
for the normal migration — treat it as a secondary connector.

## Setup (macOS, one-time) — the binary is unsigned
The published `darwin-arm64` native binary is unsigned; Apple Silicon SIGKILLs
it (silent `exit 137`, "Failed to connect"). Pin + ad-hoc sign + register the
signed binary directly (not `npx`, which re-pulls an unsigned copy):
```bash
npm install --prefix ~/.powerbi-mcp @microsoft/powerbi-modeling-mcp@0.5.0-beta.11
BIN=~/.powerbi-mcp/node_modules/@microsoft/powerbi-modeling-mcp-darwin-arm64/dist/powerbi-modeling-mcp
codesign --force -s - "$BIN"
claude mcp add powerbi-modeling -s user -- "$BIN" --start --readonly --authmode=interactive
```
Tools load on the NEXT Claude Code start (`--readonly` keeps it migration-safe).

## Connect — TWO stages (the part that trips everyone up)
`connection_operations` op `Connect`, `connectionString = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/<WORKSPACE>"`.
1. **Use the workspace DISPLAY NAME, not the GUID.** The `app.powerbi.com/groups/<guid>/` URL gives a GUID; the XMLA endpoint keys on the name (e.g. `.../myorg/Test`). First connection tool call pops an interactive browser login.
2. **Workspace-level connect (no `Initial Catalog`)** enumerates + reads metadata, but **DAX `Execute` fails** with *"CurrentCatalog XML/A property was not specified."* To run DAX, reconnect with the dataset appended: `Data Source=...;Initial Catalog=<DATASET NAME>`.

`ListLocalInstances` returns 0 on macOS (Power BI Desktop is Windows-only) — Fabric/PPU XMLA is the only mac path.

## Migration-read operations cheat-sheet
| Need | Call |
|---|---|
| List datasets in the workspace | `database_operations` `List` |
| Tables / columns | `table_operations` `List` / `GetSchema` |
| Relationships (incl. `isActive:false`) | `relationship_operations` `List` |
| Measures + **DAX expressions** | `measure_operations` `List` then `Get` (List omits expressions) |
| Full model as TOM JSON for the converter | `database_operations` `ExportTMSL` — **requires `databaseName` AND `tmslOperationType:"CreateOrReplace"`**; feed the inner `.createOrReplace.database` object to `convert_powerbi_to_sigma` |
| Golden values (Phase 6 oracle) | `dax_query_operations` `Execute` (needs the `Initial Catalog`-bound connection) |

## Phase 6 — using it as the online-DAX oracle
The skill's default online oracle is the Fabric REST `executeQueries`
(`phase6-parity-pbi.rb --emit-dax`). When that REST path is blocked but XMLA is
open, get the same golden values by running the measure via the MCP:
```
dax_query_operations Execute:
  EVALUATE SUMMARIZECOLUMNS(<DimTable>[<grain>], "M", [<Measure>])
```
then diff against the Sigma actuals exactly as the REST path does.

### Why this matters — a real catch (fixture_06 "Workforce KitchenSink")
Running `PY Incident Count` live via the MCP returned a **flat 286 for every
year**, because the measure's `SAFETY_INCIDENTS → DimDate` relationship is
**inactive** and the measure never activates it (no `USERELATIONSHIP`) — so
`SAMEPERIODLASTYEAR` has no date context to shift. The converter (correctly)
synthesizes the *intended* per-year prior-year off the fact's own date and now
emits a divergence warning for exactly this case. **Only the live DAX oracle
surfaces that the SOURCE measure is silently mis-modeled** — the canonical use
case for reaching into Power BI during a migration.
