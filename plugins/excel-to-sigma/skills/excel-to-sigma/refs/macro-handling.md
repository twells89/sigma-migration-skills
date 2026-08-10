# Macros (VBA) — detect, classify, route, gate

`.xlsm`/`.xlsb`/`.xls` carry VBA. **Macros are not one thing** — like cells, you
classify them by *intent* and route each class. Most FP&A macro logic maps to
things Sigma already has; only a slice truly needs the (forthcoming) **Actions**
primitive. The non-negotiable rule:

> **Never silent.** Every macro is surfaced with a disposition. A dropped
> "Commit Forecast" button the user assumes still works is the FP&A equivalent of
> silently dropping row-level security. Macros are a **STOP/flag gate**, not a
> quiet delete.

## Extraction

VBA lives in `xl/vbaProject.bin` (an OLE compound stream) — `openpyxl` only sees
*that it exists*, not the code. Use **`olevba`** (oletools) to pull module source:

```bash
pip install oletools          # stable; not in the org's last-3-days window
python scripts/macro-classify.py path/to/model.xlsm          # human report
python scripts/macro-classify.py --json path/to/model.xlsm   # machine contract
```

`macro-classify.py` accepts a binary office file (extracts via olevba) **or** a
raw VBA module (`.bas/.cls/.frm/.vba/.txt`) for testing. It strips comments before
classifying (comments must never drive a classification — they lie).

## The taxonomy → Sigma mapping

| Class | VBA signals | Sigma target | Status |
|---|---|---|---|
| **RECALC_REFRESH** | `RefreshAll`, `.Calculate(Full)`, `.Refresh`, `ScreenUpdating` | none — Sigma is always live | ✅ AUTO (drop) |
| **TRANSFORM_ROLLUP** | `For…To` loop + `Cells(..).Value =`, `WorksheetFunction`, in-code SUMIFS | data model element / calc columns | ✅ AUTO (result reproduced declaratively) |
| **NAVIGATION** | `.Activate`, `.Select`, `.Goto`, `.Visible =` | page navigation / visibility | ✅ AUTO (map or drop) |
| **FORMAT_COSMETIC** | `.Font`, `.Interior`, `.Borders`, `AutoFit`, `.NumberFormat` | conditional formatting / styling | ✅ AUTO (map or drop) |
| **WHATIF_SCENARIO** | `GoalSeek`, `Solver`, writes into assumption cells, `Select Case scenario` | controls / parameters / editable assumptions table | 🎛 CONTROL |
| **ACTION_WRITEBACK** | `PasteSpecial xlPasteValues`, `ListRows.Add`, `…End(xlUp).Row + 1` append, name verbs (Commit/Save/Submit/Post/Archive/Snapshot/Freeze) | **Sigma Action → append rows to an input table** | ⏳ ACTION (gated) |
| **EXTERNAL_IO** | `CreateObject("Outlook")`, `.Send`, `Shell`, `ExportAsFixedFormat`, `FileSystemObject`, `MSXML2/WinHttp`, file `Open…For` | scheduled delivery / external API job | 🚩 FLAG |
| **OPAQUE** | bespoke math writing cells (`Sin/Cos/Rnd/…`), `Do While`, `GoTo` | — | 🚩 FLAG (human review) |
| **event-handler** | name `Workbook_*` / `Worksheet_*` (e.g. `Workbook_Open`) | decompose into its called actions; the auto-run wrapper itself drops | (follows contents) |

**Precedence** (when a macro matches several): EXTERNAL_IO ▸ ACTION_WRITEBACK ▸
WHATIF_SCENARIO ▸ TRANSFORM_ROLLUP ▸ RECALC ▸ NAVIGATION ▸ FORMAT. Bespoke math
(`Sin/Rnd/…`) overrides a weak/AUTO primary → **OPAQUE** (only EXTERNAL_IO and
ACTION_WRITEBACK outrank it). Action verbs are matched on the **procedure name**
only, so a called helper like `PostToGrid` doesn't trip "Post".

## Status meanings

- **AUTO** — reproduced by the data/formula conversion, or safely dropped (Sigma is live). No user action.
- **CONTROL** — becomes controls / parameters / an editable input table (the driver story in `refs/forecast-recipes.md`).
- **ACTION** — becomes a Sigma **Action** (button-triggered). **Gated on the Actions primitive** shipping in the workbook spec. Until then: scaffold a placeholder (a labeled button/text element) + an inventory entry; do **not** silently omit.
- **FLAG** — must be reviewed by a human (external I/O or opaque logic). Surface before build; never auto-port.

## The Actions wiring (forthcoming primitive)

When `actions` lands in the workbook spec, a `build-actions` step consumes the
`--json` records with `status == "ACTION"`. Most resolve to **Action → insert rows
into an input table** — which is exactly the editable-table machinery the forecast
recipes already build, so the future work is the *trigger*, not the data path:

```
CommitForecast_Click  → Action(on button): insert current forecast rows → "Snapshots" input table (+ timestamp)
SaveScenario_Click    → Action(on button): insert current assumption rates → "Scenarios" input table
ApplyScenario(name)   → Action(on select): set assumption controls to the chosen scenario's values
```

The classifier output is the contract; the wiring drops in behind a feature flag
without re-running detection. (Same pattern as the Tableau-Actions follow-on.)

## Worked example (`scripts/Sample Macros.bas` — the FP&A model's VBA)

11 procedures → **AUTO 5, CONTROL 2, ACTION 2, FLAG 2**:

| Macro | Class | Status |
|---|---|---|
| `Workbook_Open` | RECALC + event | ✅ AUTO |
| `RefreshActuals_Click` | RECALC_REFRESH | ✅ AUTO |
| `RebuildPnL` | TRANSFORM_ROLLUP | ✅ AUTO |
| `GoToForecast_Click` | NAVIGATION | ✅ AUTO |
| `FormatStatement` | FORMAT_COSMETIC | ✅ AUTO |
| `ApplyScenario` | WHATIF_SCENARIO | 🎛 CONTROL |
| `SolveForTarget` (GoalSeek) | WHATIF_SCENARIO | 🎛 CONTROL |
| `CommitForecast_Click` | ACTION_WRITEBACK | ⏳ ACTION |
| `SaveScenario_Click` | ACTION_WRITEBACK | ⏳ ACTION |
| `EmailReport_Click` | EXTERNAL_IO | 🚩 FLAG |
| `AllocateOverheadByHeadcount` | OPAQUE | 🚩 FLAG |

Extraction validated end-to-end through olevba on a real `.xlsm`; classification
validated on the full taxonomy above (2026-06-17).
