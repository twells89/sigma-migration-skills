---
name: omni-to-sigma
description: Convert an Omni topic (YAML views, relationships) and a dashboard export into a Sigma data model and workbook. Offline fixture path plus optional read-only Omni query/run parity.
---

# Omni → Sigma

Foundation converter. One topic → one Sigma data model; one dashboard export →
one workbook. Query views, custom Vega, and spreadsheet uploads are skipped
with a warning, not guessed.

<!-- mandatory-pre-read -->
Read before converting:

- `refs/omni-source-contract.md`
- `refs/chart-map.md`
- `refs/security-rls.md`
<!-- /mandatory-pre-read -->

Auth (live only): `OMNI_BASE_URL`, `OMNI_API_TOKEN` (org key for YAML). Sigma:
`SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, `SIGMA_CLIENT_SECRET` via
`eval "$(scripts/get-token.sh)"`. Offline runs need neither.

## Phase 0 — Assess (C1)

Feature-gap scan is the assessment skill (`omni-assessment`). Do not start a
convert until the shortlist names one topic and one document.

## Phase 1 — Discover (C2)

Offline: a model directory plus `dashboard-export.json` (see the source
contract). Live: `GET /api/v1/models/{id}/yaml?mode=combined` and
`GET /api/unstable/documents/{id}/export`. Keep `exportVersion` `"0.1"`.

## Phase 1.5 — Reuse-check (C3)

`convert-dm.rb` writes `omni-signature.json` (warehouse tables, columns,
measures). Before creating a DM, score existing Sigma DMs and reuse on a
strong match:

```bash
ruby scripts/find-or-pick-dm.rb --workbook-signature omni-signature.json --auto-pick
```

## Phase 2 — Convert (C4)

```bash
ruby scripts/convert-dm.rb --model-dir <dir> --topic <name> \
  --connection-id <uuid> --folder-id <uuid> --out dm.json
```

Plain views only. The envelope is `{sigmaDataModel, stats, warnings}`.

## Phase 3 — Post the data model + read back (C5)

POST `sigmaDataModel` to `/v2/dataModels/spec`, then **read back**
`GET /v2/dataModels/{id}/spec` and pass the server element id to the workbook
(`--dm-id`, `--dm-element-id`). Never wire the workbook to the client ids in
`dm.json` after a live POST.

## Phase 4 — Build the workbook (C6)

```bash
ruby scripts/build-workbook.rb --export dashboard.json --model-dir <dir> \
  --dm-id <read-back-dm> --dm-element-id <read-back-element> \
  --dm-element-name Orders --folder-id <uuid> --out wb.json
```

Hidden data element plus one chart per mapped tile. Unknown `chartType`s land
in `chart-gaps.json`.

## Phase 5 — Layout (C7)

`build-workbook.rb` attaches layout XML as the **last write**, after element
ids are final. A later spec PUT that omits `layout` wipes it — resend the
layout (or `scripts/put-layout.rb` when that helper is on the skill). Then
visual-QA (`refs/layout-visual-qa.md`, `scripts/sigma-export-png.py`).

## Phase 6 — Verify parity (C8)

```bash
ruby scripts/omni-query-oracle.rb --export dashboard.json --out oracle-plan.json
ruby scripts/assert-phase6-ran.rb --workdir <dir>
```

Offline, the oracle writes the `POST /api/v1/query/run` bodies and exits 0.
Live, it runs those queries. Compare to Sigma (and the warehouse when the
connection is the same one Omni uses). A migration is not done until parity
is green.

## Security: RLS / CLS (C9)

```bash
ruby scripts/detect-rls.rb --model-dir <dir> --out rls.json
ruby scripts/apply-sigma-rls.rb --detect rls.json --out rls-plan.json
```

Detect always (`--strict` exits 2 when anything is present). Apply is opt-in
(`--apply --confirm` plus `SIGMA_API_TOKEN`) and still does not invent
attribute values. Details: `refs/security-rls.md`.

## Gaps

Unsupported source features → `python3 scripts/escalate-gap.py` (opt-in).
Never fake a feature. v0 gaps: query views, `omni_dimensionalize`, Mustache
attribute SQL, topic `fields:` curation, per-tile filter exclusion, custom
Vega, spreadsheet uploads.
