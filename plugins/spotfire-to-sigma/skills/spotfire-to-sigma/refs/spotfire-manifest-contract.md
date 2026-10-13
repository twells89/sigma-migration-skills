# Spotfire neutral manifest contract

`spotfire-manifest.schema.json` is the normative version 1.0 extraction
contract. It is deliberately neutral: it records source semantics and evidence,
not Sigma API payloads.

## Authority boundary

A conversion-grade manifest must have:

```json
{
  "manifest_type": "spotfire_neutral_manifest",
  "manifest_version": "1.0",
  "authority": {
    "authoritative": true,
    "api_surface": "Spotfire.Dxp.Application",
    "dxp_raw_used": false
  }
}
```

Only `scripts/export_spotfire_manifest.py`, run customer-side against the loaded
`Document`, satisfies that boundary. `inspect_dxp.py` emits a different
`spotfire_dxp_raw_inventory` type with `authoritative: false`; it cannot be
renamed, promoted, or used as conversion input.

## Required coverage

Version 1.0 records:

- exporter, Spotfire, and API versions, UTC export time, execution context, and
  the exact DXP file SHA-256 when `SourceDxpPath` is available;
- data tables, columns, Spotfire and neutral data types, calculated expressions,
  source-operation metadata, and relations;
- pages, visuals, axes, filters/filtering schemes, and numeric layout bounds
  when the installed public API exposes them;
- document properties with sensitive names redacted;
- script and data-function metadata and source hashes, but never source bodies;
- Mod metadata, bookmarks, and explicit security signals; and
- `unsupported` plus `export_errors` arrays on every addressable source object.

The contract does not include row data, cached values, credentials, access
tokens, script bodies, or executable objects.

## Object and error rules

Every addressable object has:

- `source_id`: stable Spotfire ID when exposed, otherwise a deterministic
  exporter-local index;
- `name`;
- `unsupported`: semantic gaps (`info`, `warning`, or `blocking`); and
- `export_errors`: property/API read failures with a `recoverable` flag.

An empty array means the exporter checked that category and found no item. It
does not mean that an inaccessible API category was empty: inaccessible
categories must produce an `unsupported` or `export_errors` record.

Never silently infer a missing expression, relation endpoint, filter, or layout.
Downstream conversion must stop on blocking items and route warnings to manual
review.

## Provenance and warehouse source map

`source.artifact_hash` is the SHA-256 of exact DXP file bytes, not a hash of the
manifest or loaded object graph. If Spotfire does not provide the local file
path, the exporter reports `status: "unavailable"` rather than inventing a
digest. Supply `SourceDxpPath` when provenance requires a byte-level binding.

The optional exporter evidence artifact follows
`spotfire-manifest-provenance.schema.json`. Each mapping
ties a manifest JSON pointer to a public API path and classifies evidence as a
public property, collection, read-only method, or a derivation from public
values. It contains no raw DXP paths or internal object-graph claims.

That provenance map is deliberately distinct from
`spotfire-source-map.schema.json`, the customer-authored warehouse landing map
consumed by `convert.py --source-map`. The warehouse map binds each Spotfire
table ID/name to a Sigma connection and `[database, schema, table]` path.

## Compatibility and validation

The major version changes when field meaning or required structure becomes
incompatible. Minor additive changes require a new schema/validator version;
consumers must reject unsupported versions rather than guessing.

Validate before conversion:

```bash
python3 scripts/validate_manifest.py export/spotfire-manifest.json \
  --provenance-map export/spotfire-manifest-provenance.json
```

The validator is Python-stdlib-only. In addition to structural checks, it
rejects raw-DXP authority claims, broken references, duplicate IDs, invalid
hashes, and common unredacted credential patterns.
