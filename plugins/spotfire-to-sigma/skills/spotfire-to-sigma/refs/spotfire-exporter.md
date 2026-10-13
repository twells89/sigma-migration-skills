# Customer-side Spotfire manifest exporter

Use `scripts/export_spotfire_manifest.py` inside the customer's Spotfire
environment. It reads the loaded analysis through public Application API
objects rooted at the injected `Document` global.

## Safety properties

The exporter is read-only with respect to Spotfire. It does not call refresh,
save, execute, apply-layout, filter mutation, or data-function APIs. The only
method calls are metadata enumeration/read methods such as
`GenerateSourceView`, `DataOperation.Inputs`, `GetScripts`, and
`BookmarkManager.GetBookmarks`.

It never executes embedded source. Script, transformation-script, and
data-function bodies are read only to calculate SHA-256 and length, then
discarded. It never emits row data. Connection-style text and sensitive
document-property names are redacted. Review the output before moving it
outside the customer boundary.

## Analyst setup

1. Open the target DXP in Spotfire Analyst.
2. Create an IronPython script and paste the complete exporter file.
3. Add an `OutputPath` string parameter pointing to a customer-approved local
   JSON path.
4. Optionally add:
   - `SourceDxpPath`: local path to the exact DXP file. This binds the manifest
     to the file's byte-level SHA-256. Omit it when no approved local path is
     available; the manifest will say the hash is unavailable.
   - `ProvenancePath`: output path for the optional manifest provenance map.
   - `ExecutionContext`: `analyst` or `automation`.
5. Run the script with the target analysis loaded. Do not refresh or edit the
   analysis merely to make export fields appear.

`OutputPath` can instead be supplied as `SPOTFIRE_MANIFEST_PATH` where the host
exposes environment variables to IronPython. A missing output path is a hard
error; the exporter does not fall back to the console because manifests may
contain customer metadata.

## Automation context

Use a supported Spotfire Automation Services script action that supplies the
same loaded `Document` global. Pass customer-controlled output parameters and
set `ExecutionContext` to `automation`. File paths must be writable/readable by
the Automation Services identity. Exact action availability and filesystem
policy vary by Spotfire deployment; do not substitute raw DXP parsing when a
server action cannot expose `Document`.

## Validate and review

Copy the JSON outputs to a machine with Python 3 and run:

```bash
python3 scripts/validate_manifest.py /path/to/spotfire-manifest.json \
  --provenance-map /path/to/spotfire-manifest-provenance.json
```

Then review:

- every `blocking` unsupported item and every `export_errors` entry;
- missing layout bounds or source operations caused by API-version differences;
- unresolved relation endpoints;
- all security signals, especially library ACL, row-level security, and
  column-level security; and
- an unavailable source artifact hash.

The export is authoritative evidence of what the public API exposed, not proof
that source-system grants or Spotfire Library ACLs are complete. Preserve those
as separate customer evidence.

## Version support

The exporter records both product and loaded API assembly versions because
public properties differ across Spotfire releases. Optional-property failures
are reported in-object rather than hidden. If a supported public property has a
new shape, add a compatibility reader and a focused fixture/test; do not inspect
or deserialize private DXP internals.
