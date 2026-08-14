# GET → POST asymmetries, and the error catalog

`GET /v2/workbooks/{id}/spec` is **not** a valid create body. Three classes of
difference bite, in this order: envelope, emitted-but-rejected fields, and
normalizations the API applies on write. Then there is a fourth class that has
nothing to do with the API — latent defects the source org tolerates and
create-validation does not.

## 1. Envelope

`GET` returns response-only metadata alongside the document:

```
workbookId, name, url, documentVersion, latestDocumentVersion, ownerId,
folderId, createdBy, updatedBy, createdAt, updatedAt, description, document
```

- **CREATE** takes `{name, folderId, description?, document}`. Drop everything
  else — `ownerId`/`createdBy`/`updatedBy` are source-org user ids and must not
  be carried over.
- **UPDATE** takes `{document}` **only**. Sending the outer `name`/`folderId`
  alongside it 400s.

## 2. Emitted by GET, rejected by POST

### `groupingId: "base"`
GET writes the implicit ungrouped root explicitly on join legs and
`primarySource`. Create rejects it:

```
elements[9].source.primarySource.groupingId: Grouping not found: 'base'
```

The schema settles it: *"The identifier of a grouping on the source element to
read data at. **Omit to read ungrouped (base) data.**"* So delete any
`groupingId` whose value is exactly `base`, at every depth. It reappears on the
next readback — that is expected, and is why a naive GET → PUT round-trip of an
unmodified spec can fail.

## 3. Applied by the API on write

Both are silent. Neither is an error; both can change what you see.

### Container row-span expansion
A `<Container>` whose declared `gridRow` end is **smaller** than its children's
extent gets expanded to cover them. It is never shrunk when oversized.

```xml
<!-- POSTed -->
<Container elementId="c1" gridRow="1 / 3">   <!-- children reach row 11 -->
<!-- read back -->
<Container elementId="c1" gridRow="1 / 11">
```

The failure mode is a **sibling**: an element that shared the container's
original `1 / 3` now occupies 2 rows of an 11-row page and renders as a strip.
Observed live: a full-height image next to a text column collapsed to a
1400×154 sliver (source: 1210×1024).

`port_workbook.py` pre-applies the expansion and carries matching siblings with
it, so the POSTed layout is already self-consistent and the API changes nothing.

### Text body normalization
Runs of 3+ newlines in a `text` element's `body` collapse to 2. Cosmetic on its
own; it shortens text blocks, and auto-sized grid rows around them redistribute.
Not preventable — document it rather than fighting it.

## 4. Latent source-side defects that create-validation rejects

The source org's runtime tolerates dangling references that a fresh create will
not. These are **not** port bugs; the port is just the first thing to type-check
the workbook in years.

```
sheet: uAThHZWbNF(internal), bad column: TOBPY9LMOJ
```

An action effect (`insert-rows` / `update-rows`) whose `values` key is not a
column of its target table. The element id in the message is an internal sheet
id you will not find in `document.elements` — ignore it and search for the
**column** id instead. Audit every write action against its table's real column
ids (`port_workbook.py --audit-only` does this and prints the valid ids), then
repair explicitly with `--map-column TABLE:STALE=REAL`.

Repair deliberately, not by inference: the tool refuses to guess. In the
observed case the target table had 3 columns, 2 matched, the stale key carried
`{type: number, value: 1}`, and the single unmatched column was the numeric
`Question` — enough to be confident. When it is not that clear-cut, ask.

Similarly, a formula referencing `[Missing node/<id>]` is Sigma's own marker for
a deleted source element. It survives a port (it is just a string) and keeps
failing at query time. Confirm with `verify_port.py baseline` that the source
fails identically, then report it as pre-existing rather than silently fixing
someone else's workbook.

## Error catalog

| Message | Cause | Fix |
|---|---|---|
| `Grouping not found: 'base'` | GET-emitted `groupingId: base` | delete the key |
| `Image upload does not belong to this organization: '<key>'` | org-scoped upload key | recover bytes, re-host as `kind: url` |
| `sheet: <id>(internal), bad column: <colId>` | action writes to a non-existent column | `--map-column` |
| `Dependency not found: '<conn>/<DB>/<SCHEMA>/<TABLE>'` | a control sourced from a warehouse table with no corresponding table element in the workbook, or the path genuinely is not on that connection | verify with `/v2/connection/<id>/lookup`; keep the table element |
| `'Unknown column "[X]"'` **inside compiled SQL** | formula ref that does not resolve. Not an HTTP error — the create succeeds and the element renders empty | `verify_port.py compile`, then `baseline` to see whether it is pre-existing |

The last row is the one that quietly ruins ports. A `2xx` on create means the
shape was valid, not that the workbook works. Always run the compile probe.

## Why a naive round-trip "works" in the same org

Within one org, GET → POST usually survives, because `groupingId: base` is the
only hard blocker and the org's own upload keys and connection ids still
resolve. That is exactly why cross-org porting surfaces problems nobody has hit
before — treat same-org success as no evidence at all.
