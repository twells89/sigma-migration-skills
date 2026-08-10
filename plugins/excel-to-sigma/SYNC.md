# excel-to-sigma — graduated from `twells89/excel-to-sigma`

This plugin was graduated from the staging repo
https://github.com/twells89/excel-to-sigma into
`plugins/excel-to-sigma/` so it can share the marketplace wiring, shared
`code_rep` adapter, and governance gates with the other converters.

- **Prior source of truth (staging):** `twells89/excel-to-sigma` (last synced
  from `main` @ a83d42d, 2026-07-22).
- **Current source of truth:** this directory in `sigma-migration-skills`.
- **code_rep:** `skills/excel-to-sigma/scripts/lib/code_rep.py` is vendored
  byte-identical from `shared/lib/code_rep.py` (see `shared/manifest.json`).
  Edit the canonical copy, then `ruby tools/sync-shared.rb`.
- Workbook builders call `scripts/lib/workbook_wire.py` at the POST / dry-run
  boundary so nested drafts become the released document envelope.
