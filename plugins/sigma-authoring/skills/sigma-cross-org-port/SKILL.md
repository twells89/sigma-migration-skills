---
name: sigma-cross-org-port
description: >-
  Copy a Sigma workbook from one Sigma org into another when the underlying data
  already exists in both (same warehouse tables, same column names) — e.g. moving
  a demo, template, or sample-data workbook out of a shared org into a personal or
  customer org. Pulls the source spec, remaps the org-scoped references
  (connections, image uploads), fixes the GET-to-POST asymmetries, POSTs, and
  verifies structure + compilation + render. Use when the user says "port/copy
  this workbook to my org", "move this workbook between orgs", or "recreate this
  Sigma workbook in another Sigma org". NOT for converting from another BI tool,
  and NOT a data migration — the target must already have the tables.
user-invocable: true
---

# Sigma → Sigma cross-org workbook port

A workbook spec is ~95% org-agnostic. Porting is not a rebuild: it is a
**reference-remapping** job over a spec you copy verbatim, plus a short list of
things that genuinely cannot cross an org boundary.

The whole difficulty is that the failures are asymmetric — some are loud 400s on
create, and some are silent (a `2xx` create whose elements render empty, or an
image that collapses to a strip). So this skill is audit-first and
verify-hard-after.

<!-- mandatory-pre-read -->
Read both before porting anything:

- `refs/non-portable-surface.md` — the complete list of what is org-scoped, what
  is safely portable (do not "fix" opaque ids), and what has no automated path.
- `refs/spec-asymmetries.md` — why `GET spec` is not a valid create body, the
  two silent write-time normalizations, and the error → cause table.
<!-- /mandatory-pre-read -->

## Scope

**In scope:** Sigma org A → Sigma org B, where the warehouse tables the workbook
reads already exist in B under the same path and column names.

**Out of scope:** converting from Tableau/Power BI/Looker/etc. (use the matching
`*-to-sigma` converter); landing data that B does not have; porting data models
(`/v2/dataModels/spec` is a separate surface — port the model first, then the
workbook that references it).

**Hard prerequisite — verify, do not assume.** The premise is that both orgs see
the same data. Prove it in Phase 2 before touching a spec. If the target lacks
the tables, this is a data migration wearing a port costume: stop and say so.

## Prerequisites

- API credentials for **both** orgs, and the right base URL for each cloud/region
  — they are frequently different (e.g. source on
  `https://api.us-a.aws.sigmacomputing.com`, target on
  `https://aws-api.sigmacomputing.com`). Get tokens via the `sigma-api` skill.
- `python3` with `pyyaml`. `poppler` (`pdfimages`) only if the workbook has image
  uploads; `pillow` only if those images need downscaling.

Keep the two tokens in separate shells or separate env files — the single most
common self-inflicted failure here is POSTing the target spec with the source
token, which 404s or silently writes to the wrong org.

## Phase 1 — Authenticate both orgs, confirm which is which

`/v2/whoami` returns a bare organization UUID with no name, so it cannot tell you
*which org* you are in. Use a `lookup` call's returned `url` (Phase 2) — it
carries the org **slug** — or check the workbook URL slug.

```bash
for side in src dst; do
  # exchange client credentials per the sigma-api skill, then:
  curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v2/whoami" \
    | jq '{userId, organizationId}'
done
```

Record the target's home folder for the create call:

```bash
USER_ID=$(curl -s -H "Authorization: Bearer $DST_TOKEN" "$DST_BASE/v2/whoami" | jq -r .userId)
curl -s -H "Authorization: Bearer $DST_TOKEN" "$DST_BASE/v2/members/$USER_ID" | jq -r .homeFolderId
```

## Phase 2 — Prove data parity (gate)

Pull the source spec, list its warehouse paths, and confirm each one resolves on
the target — same path **and** same column set.

```bash
curl -s -H "Authorization: Bearer $SRC_TOKEN" \
  "$SRC_BASE/v2/workbooks/<SRC_WB_ID>/spec" > src-spec.yaml

grep -o 'connectionId: [0-9a-f-]\{36\}' src-spec.yaml | sort -u
python3 -c "import yaml,sys
d=yaml.safe_load(open('src-spec.yaml'))['document']
seen=set()
def w(o):
    if isinstance(o,dict):
        if o.get('kind')=='warehouse-table': seen.add(tuple(o['path']))
        [w(v) for v in o.values()]
    elif isinstance(o,list): [w(v) for v in o]
w(d); [print(list(p)) for p in sorted(seen)]"
```

For each path, on **both** orgs:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"path":["DB","SCHEMA","TABLE"]}' "$BASE/v2/connection/<CONN_ID>/lookup"
# -> {kind, inodeId, url}   ... url confirms the org slug

curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/v2/connections/tables/<inodeId>/columns?limit=200" \
  | jq -r '.entries[] | "\(.name)\t\(.dataType // .type)"' | sort
```

`diff` the two column lists. Identical name+type sets are the green light.
Differences are not automatically fatal — the workbook may not use the differing
columns — but they are a decision the user has to make, so surface them.

## Phase 3 — Audit before rewriting

```bash
python3 scripts/port_workbook.py --src-spec src-spec.yaml \
  --out /dev/null --report audit.json --audit-only
```

The report names every unresolved item and the exact flag that fixes it:

- `unmapped_connectionIds` → `--map-connection SRC=DST`
- `unmapped_image_uploads` → Phase 4
- `unrepaired_stale_write_columns` → `--map-column TBL:STALE=REAL`, with that
  table's valid column ids listed so you can choose deliberately
- `input_tables_needing_data` → Phase 7 (informational; no automated path)

Resolve every one. The tool exits non-zero while any remain, so a clean audit is
the gate into Phase 5.

### `warnings_inherited_from_source` — read this every time

**`GET spec` does not reliably return a workbook's full action surface.** Buttons
can come back as presentation-only — text, colour, alignment, and no `actions`
key at all. There is no stub and no marker; the logic is simply absent. Port it
and you get a workbook that looks perfect and does nothing.

You cannot detect this by diffing source against target — both agree, because
both are missing it. You detect it by looking for **declared structures nothing
reaches**, which is what this block reports:

- `overlays_never_opened` — a modal/drawer exists but no `open-overlay` targets
  it. A modal nothing opens is proof that something is missing.
- `input_tables_never_written` — an input table with no `insert-rows` /
  `update-rows` / `delete-rows` writer. Cross-check what *reads* it: a scoring
  or log table that is joined and aggregated but never written is conclusive.
- `buttons_with_no_actions` — expected for decorative buttons, suspicious for
  anything named Submit / Save / Enter.
- `effect_counts` — sanity-check the shape against the UI. Six question pages
  with one `insert-rows` between them is not a design choice.

Observed live: a 92-element quiz workbook returned 21 `navigate` + 6
`select-tab` + 1 `insert-rows`, with all 3 modals unopened, 5 of 6 input tables
unwritten, and all 6 answer-Submit buttons action-less — while its `Scoring`
element joined those unwritten tables to compute `Points`.

**This is not a port defect and it is not fixable by porting harder.** Report it
before the user finds it. The rebuild path is real, though — see below.

### Rebuilding lost actions

Conditional actions **are** authorable, so lost logic can be rewritten in code
once you know the intended behaviour. `trigger` takes either a bare string or
`{on, condition}`, with condition `type` of `column`, `constant`, or `formula`:

```yaml
actions:
  - id: q1Wrong
    trigger:
      on: on-click
      condition: {type: formula, formula: '[Store-Region] != "West"'}
    effects:
      - {effect: open-overlay, overlayId: UwRvau7UH-}
  - id: q1Right
    trigger:
      on: on-click
      condition: {type: formula, formula: '[Store-Region] = "West"'}
    effects:
      - effect: insert-rows
        table: cNFuPUr6pp
        values:
          SC1LNFY0UM: {type: constant, value: {type: number, value: 1}}
          0Z3GUSDJAC: {type: formula, formula: Now()}
      - {effect: navigate, target: {type: page, page: kSHcc1l5cg}}
```

Verified to save and read back. Note a condition references a control by
**`controlId`** (`[Store-Region]`), not by element id, and Sigma normalizes `<>`
to `!=` on write. All twelve effects are authorable: `clear-control`,
`close-overlay`, `delete-rows`, `insert-rows`, `navigate`, `open-document`,
`open-overlay`, `open-url`, `refresh-element`, `select-tab`, `set-control-value`,
`update-rows`.

Two effects are only partly authorable — check before promising a rebuild:

- **`open-url` cannot carry a destination.** Its schema requires `openTarget`
  (`_self` / `_blank` / `_parent`) and exposes **no `url` property**. A
  spec-authored open-url button therefore opens nothing; the destination is
  UI-only. Sending a `url` key fails the whole element with the unhelpful
  `document.elements[N]: Invalid kind: "button"`. Leave such buttons unwired and
  say so.
- **`open-document`** likewise carries only what its schema lists — verify the
  fields you need are there rather than assuming parity with the UI.

Rebuilding needs the *intended* behaviour, which the spec no longer carries —
answer keys, thresholds, routing. Ask; do not infer it from the data and hope.

And when you do reconstruct answers from data, **check them against the
workbook's own prose.** On the workbook that motivated this skill, the narrative
had drifted from the dataset: the text cited 148 orders where the data yields
156, implied three suspects where exactly one qualifies, and named a "nearest"
store that is neither nearest nor associated with the surviving suspect. Both
orgs returned byte-identical result sets, so this was upstream staleness, not a
port artifact — but it makes "correct" ambiguous, and that is the user's call to
make, not yours.

## Phase 4 — Recover image uploads (only if the audit lists any)

Upload keys are org-scoped and the spec API cannot create an upload, so the bytes
must be recovered and re-hosted. A PDF export embeds the originals losslessly.

```bash
python3 scripts/recover_images.py plan --spec src-spec.yaml
```

`plan` tells you which pages hold image elements, in export order, and which
pages a whole-workbook export **omits** — hidden pages and overlay/modal pages.
Export the workbook, plus each overlay page that holds an image:

```bash
# whole workbook
curl -s -X POST -H "Authorization: Bearer $SRC_TOKEN" -H "Content-Type: application/json" \
  -d '{"format":{"type":"pdf","layout":"portrait"}}' \
  "$SRC_BASE/v2/workbooks/<SRC_WB_ID>/export"          # -> {queryId}

# an overlay/modal page (this DOES work, and is the only way to reach one)
curl -s -X POST -H "Authorization: Bearer $SRC_TOKEN" -H "Content-Type: application/json" \
  -d '{"pageId":"<overlayPageId>","format":{"type":"pdf","layout":"portrait"}}' \
  "$SRC_BASE/v2/workbooks/<SRC_WB_ID>/export"

# poll until 200 (204 = still running)
curl -s -o out.pdf -w '%{http_code}\n' -H "Authorization: Bearer $SRC_TOKEN" \
  "$SRC_BASE/v2/query/<queryId>/download"
```

Then map, shrink, and **look at the files**:

```bash
python3 scripts/recover_images.py map --spec src-spec.yaml --pdf out.pdf \
  --images imgs --out images.tsv
python3 scripts/recover_images.py shrink --map images.tsv --out-dir web
```

`map` pairs rasters to upload keys positionally and flags what it cannot
determine (a page holding both a map and an image, a key it never saw). Charts
and maps embed their own rasters, so positional pairing is a strong hint, not
proof — open the images before trusting them. Add overlay-page images to the TSV
by hand.

`shrink` matters: data URIs inflate ~4/3 in base64. A real case went from 24 MB
of source PNG to ~2.4 MB of JPEG (~3.3 MB in-spec) with no visible loss at render
size.

If the user would rather keep native uploads than data URIs, port with the
images omitted and drag the recovered files onto the elements in the UI.

## Phase 5 — Port and create

```bash
python3 scripts/port_workbook.py --src-spec src-spec.yaml \
  --out dst-spec.yaml --report port.json \
  --folder-id <DST_HOME_FOLDER_ID> --name "<Name>" \
  --map-connection <SRC_CONN>=<DST_CONN> \
  --map-column <TBL>:<STALE>=<REAL> \
  --image-map web/images.tsv
```

What it rewrites, and why each is necessary, is in `refs/spec-asymmetries.md`:
`connectionId` remap; `groupingId: base` stripped; uploads inlined as data URIs;
stale write-columns repaired from your explicit mapping; container row-spans
pre-expanded with their siblings.

```bash
curl -s -X POST -H "Authorization: Bearer $DST_TOKEN" \
  -H "Content-Type: application/yaml" -H "Accept: application/json" \
  --data-binary @dst-spec.yaml "$DST_BASE/v2/workbooks/spec" | jq .
```

On a 400, read the message against the error table in
`refs/spec-asymmetries.md` — every one seen in practice maps to a known cause.
Fix the spec, re-run, retry. Do not start hand-editing the readback.

Iterate afterwards with `PUT /v2/workbooks/{id}/spec` and a body of
`{document: …}` **only**.

## Phase 6 — Verify (gate; a 2xx proves nothing)

Three checks, all required.

```bash
# 1. structure — offline, source vs live readback
curl -s -H "Authorization: Bearer $DST_TOKEN" \
  "$DST_BASE/v2/workbooks/<DST_WB_ID>/spec" > dst-readback.yaml
python3 scripts/verify_port.py structure --src-spec src-spec.yaml --dst-spec dst-readback.yaml

# 2. compile — every data element, live
python3 scripts/verify_port.py compile --base-url "$DST_BASE" --workbook-id <DST_WB_ID>

# 3. render — export both to PDF and LOOK at them
```

`structure` compares counts, element ids, kinds, layout placement and settings,
then field-diffs every element while ignoring the rewrites a port is supposed to
make. Expect a small number of flagged diffs: your `--map-column` repair, and
text bodies the API re-normalized. Anything else is a real regression.

`compile` catches the silent class — Sigma accepts unresolvable formulas and
bakes `'Unknown column "[X]"'` into the SQL as a literal, leaving the element
blank in the UI. On a failure, run the baseline before blaming the port:

```bash
python3 scripts/verify_port.py baseline --base-url "$SRC_BASE" --workbook-id <SRC_WB_ID>
```

Identical failures on identical element ids mean the port is faithful and the
defect is upstream. Report it as pre-existing; do not quietly repair someone
else's workbook.

**Render, and actually look.** Structure and compile both pass on a workbook
whose image collapsed to a strip. Export both workbooks to PDF, rasterize the
pages, and compare:

```bash
pdftoppm -r 55 -png src.pdf src_p && pdftoppm -r 55 -png dst.pdf dst_p
pdfimages -list dst.pdf   # image dimensions/aspect are a fast tell
```

## Phase 7 — Report the residuals honestly

Some things have no automated path. Name them concretely rather than implying a
complete port:

- **Input-table data.** Structure ports; rows do not. Say which tables need
  seed data (and what the source rows were), and which are runtime logs that
  *should* be empty in a fresh org.
- **Pre-existing source defects** the baseline confirmed.
- **Environment-level render diffs** — base theme, control labels. See the
  caveats in `refs/non-portable-surface.md`.
- **Version tags** are not spec content; re-tag if it matters.

## Failure modes worth naming

| Symptom | Cause |
|---|---|
| 404 on create | target token + source base URL (or vice versa) |
| Element renders empty, no error anywhere | unresolvable formula; only `compile` finds it |
| An image is a thin strip | container row-span expansion; a sibling kept the old span |
| `Grouping not found: 'base'` | you POSTed a GET spec unmodified |
| Everything works but looks slightly tighter | API collapsed 3+ newlines in text bodies |
| Buttons render but do nothing; modals never appear | `GET spec` omitted the action surface — inherited, not caused. See `warnings_inherited_from_source` |
