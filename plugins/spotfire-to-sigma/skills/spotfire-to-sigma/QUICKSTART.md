# Spotfire → Sigma — Quickstart

Run from this skill directory.

1. Export an authoritative manifest with
   `scripts/export_spotfire_manifest.py` inside Spotfire. Use
   `ProvenancePath` for the optional exporter evidence map.
2. Validate the export:

```bash
python3 scripts/validate_manifest.py /secure/export/spotfire-manifest.json \
  --provenance-map /secure/export/spotfire-manifest-provenance.json
```

3. Create `warehouse-source-map.json` from
   `refs/spotfire-source-map.example.json`. This is the customer warehouse
   landing map consumed by the converter; it is not the provenance map.
4. Generate and inspect local artifacts without network calls:

```bash
python3 scripts/migrate_spotfire.py \
  --manifest /secure/export/spotfire-manifest.json \
  --source-map warehouse-source-map.json \
  --workdir ./spotfire-migration \
  --dry-run
```

5. Authenticate and run live:

```bash
export SIGMA_BASE_URL='https://api.sigmacomputing.com'
eval "$(bash scripts/browser-login.sh)"  # preferred interactive OAuth

# For unattended automation instead:
# export SIGMA_CLIENT_ID='<client-id>'
# export SIGMA_CLIENT_SECRET='<client-secret>'

python3 scripts/migrate_spotfire.py \
  --manifest /secure/export/spotfire-manifest.json \
  --source-map warehouse-source-map.json \
  --folder-id <sigma-folder-id> \
  --workdir ./spotfire-migration
```

The expected first live result is exit `16`: the DM and workbook were
POSTed/read back and warehouse verification passed, but rendered Spotfire
visual evidence is still required. This is a checkpoint, not failure and not
source parity.

After capturing and comparing that exact workbook, resume without creating a
replacement. `live-binding.json` rejects changed manifests, warehouse maps,
generated specs, or object IDs:

```bash
python3 scripts/migrate_spotfire.py \
  --manifest /secure/export/spotfire-manifest.json \
  --source-map warehouse-source-map.json \
  --workdir ./spotfire-migration \
  --resume-live \
  --source-visual-evidence source-visual-evidence.json \
  --gap-decisions gap-decisions.json
```

If reuse scoring returns an ambiguous candidate, exit `15` records the choice
required in `dm-reuse-decision.json`. Rerun with `--reuse-dm <id>` or
`--force-new-dm`.

The live artifact `parity-final.json` is warehouse-only. Confirm
`verified_against=warehouse`; never describe it as Spotfire value parity.

After recording source visual evidence, resolve or explicitly accept every
entry in `completion-gaps.json` (the union of discovery and emitted-spec gaps)
with a per-item reason and pass the resulting ledger through
`--gap-decisions`. Exit `17` means that named decision gate is still open.
