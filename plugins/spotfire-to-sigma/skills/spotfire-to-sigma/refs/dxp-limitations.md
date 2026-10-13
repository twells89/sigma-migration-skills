# DXP raw-inspection limitations

A `.dxp` is a ZIP container holding an undocumented, Spotfire-versioned object
graph. File names, XML tags, references, and serialization details are not a
public conversion contract. A parser that appears to work for one DXP can
silently omit or misread calculated columns, data transformations, relation
semantics, visualization configuration, filters, Mods, bookmarks, security
state, or objects introduced by another Spotfire release.

For that reason:

- raw DXP inspection is never conversion-grade or authoritative;
- raw XML must not be translated directly into a Sigma data model/workbook;
- internal IDs/tags must not be presented as public API semantics; and
- a raw inventory cannot be relabeled as a neutral manifest.

Use the customer-side Application API exporter for conversion. If that export
is blocked, stop and obtain customer-side evidence rather than deepening the
raw parser.

## `inspect_dxp.py` scope

The fallback inventory exists for triage only:

```bash
python3 scripts/inspect_dxp.py analysis.dxp -o dxp-inventory.json
```

It reports the archive hash and sizes, ZIP entry metadata, and counts of XML
element/tag and attribute names. It deliberately omits all XML text and
attribute values. Non-XML entries are listed but never opened. Output is marked:

```json
{
  "inventory_type": "spotfire_dxp_raw_inventory",
  "authoritative": false,
  "conversion_grade": false
}
```

The inspector:

- never extracts archive entries;
- never imports, evaluates, or executes archive content;
- never runs scripts, expressions, data functions, macros, or Mods;
- never uses pickle, .NET/BinaryFormatter, or application deserialization;
- blocks XML containing `DOCTYPE` or entity declarations;
- applies entry-count, expanded-size, per-XML-size, and compression-ratio
  limits; and
- redacts common credential patterns from emitted metadata/errors.

These controls reduce risk but do not make DXP internals stable or
authoritative. The inspector uses the Python standard library XML parser only
after blocking declarations; it does not resolve external entities.

## Handling guidance

Treat a DXP as untrusted customer input. Run the fallback in an isolated
workspace, retain the exact source SHA-256, do not extract entries manually,
and delete transient files according to customer policy. A successful exit
means only that bounded structural inventory completed. It says nothing about
semantic completeness or conversion readiness.
