# What does NOT cross an org boundary

A workbook spec is mostly org-agnostic, but a handful of fields are org-scoped.
This is the complete list as observed on a live 92-element port (Sigma Public →
a personal org, AWS US-East → AWS US-West, 2026-08-13). Each entry says how to
detect it, whether it can be automated, and what the API does if you ignore it.

## Portable — leave alone

These look org-specific and are **not**. Rewriting them is wasted effort at best
and breakage at worst.

| Field | Why it's fine |
|---|---|
| `elements[].id`, `pages[].id`, `panels[].id`, `overlays[].id` | Preserved verbatim on create. `layout` `elementId` refs stay valid. |
| `columns[].id`, including `inode-<id>/COLUMN` forms | **Opaque strings.** The `inode-` prefix is *not* resolved against the target org's inodes. Verified: a spec carrying `inode-E7qt6FDjryJm6GTEx3liz/ORDER_NUMBER` created cleanly in a different org and compiled to `select ORDER_NUMBER "Order Number" from …`. Do not "fix" these. |
| `controlId` | A workbook-local name, not an org reference. |
| Formulas referencing `[SourceName/Column]` | Resolved by **name** against the element's source, not by id. |
| `settings.theme.overrides` | Copied as-is. Note the *base* theme is the target org's default (see caveats). |
| `path` on `warehouse-table` sources | Database/schema/table names. Portable **iff** the same path exists on the target connection — verify, don't assume. |

## Must be remapped — automatable

### `connectionId` (every occurrence)
Appears on `warehouse-table` sources, `input-table` `kind: empty` sources, and
nested inside control `source.source`. Find them all:

```bash
grep -o 'connectionId: [0-9a-f-]\{36\}' spec.yaml | sort -u
```

Resolve the target's equivalent by name, then confirm the table path really
exists there before porting:

```bash
curl -s -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  "$SIGMA_BASE_URL/v2/connections?limit=100" \
  | jq -r '.entries[] | "\(.connectionId)  \(.type)  \(.name)"'

curl -s -X POST -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"path":["DB","SCHEMA","TABLE"]}' \
  "$SIGMA_BASE_URL/v2/connection/<DST_CONNECTION_ID>/lookup" | jq .
```

`lookup` returns `{kind, inodeId, url}` on success. The `url` also confirms the
**org slug**, which is the only cheap way to be sure you are pointed at the org
you think you are — `/v2/whoami` returns a bare organization UUID with no name.

If the target connection is missing the path, this is not a port — it is a
migration that needs the data landed first. Stop and say so.

### Image uploads (`source.kind: upload`)
The key is `<sourceOrgId>/<uuid>.png`. POSTing a foreign key fails hard:

```
Image upload does not belong to this organization: '<orgId>/<uuid>.png'
```

The OpenAPI is explicit that this is reference-only — *"Opaque handle for an
image uploaded into Sigma (storage key). Emitted by GET and accepted by PUT; not
a fetchable URL"* and *"the spec cannot upload a new one"*. There is **no public
endpoint that uploads or serves one**, and guessing app URLs does not work (the
app serves them behind a session cookie; `/api/…` paths return the SPA shell).

Recovery path that does work — a PDF export embeds the original rasters
losslessly, so export and extract (`scripts/recover_images.py`), then re-host as
`kind: url`. A `data:` URI is accepted by the API and renders, which keeps the
images inside the spec with no external hosting. Caveats:

- Base64 inflates ~4/3. Full-resolution art can push a spec into megabytes;
  `recover_images.py shrink` downscales first (1400px/q82 took 24 MB of PNG to
  ~2.4 MB of JPEG, ~3.3 MB in-spec).
- **Overlay/modal pages are absent from a whole-workbook export.** Export each
  one separately with `{"pageId": "<overlayPageId>"}` — that does work.
- Hidden pages are absent too.
- Charts, point maps and region maps embed their own rasters. `recover_images.py`
  ignores sub-64px chrome and flags pages where a map and an image coexist, but
  the pairing is positional: **look at the files** before porting.

If you would rather keep native uploads than data URIs, port with placeholders
and drag the recovered files onto the image elements in the UI.

## Must be re-created by hand — NOT automatable

### Input-table *data*
The spec carries an input table's **structure** (columns, types, formulas) and
nothing else. `kind: empty` accepts only `connectionId`; there is no
initial-rows field, and no public REST endpoint writes input-table rows. On
create, the target gets a fresh, empty backing table
(`…ORG_S_<targetOrgId>."SIGDS_<new-uuid>"`).

Read the source rows so you know exactly what is missing:

```bash
curl -s -X POST -H "Authorization: Bearer $SIGMA_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"elementId":"<inputTableElementId>","format":{"type":"csv"}}' \
  "$SIGMA_BASE_URL/v2/workbooks/<SRC_WB>/export"
# then poll GET /v2/query/<queryId>/download
```

Then either type them in the UI, or replay the browser's internal
`POST /api/v2/db/datasheet/edits/apply` with a **browser** JWT (client
credentials cannot reach it). Distinguish the two cases before you bother the
user:

- **Seed data** the workbook needs to function (lookup rows, constants,
  scenario baselines) → must be re-entered or the workbook is broken.
- **Accumulated runtime data** (log tables, submissions, leaderboards) → empty
  is correct in a fresh org; say so and move on.

### Action logic the read drops
Worse than non-portable: **absent from the source spec in the first place**, so
neither the port nor a source/target diff can see it. `GET spec` can return a
button as presentation-only — no `actions` key, no stub. Observed on a live
92-element workbook: all 6 answer-Submit buttons, the registration Enter button,
and a help button came back with no actions; all 3 modals had no `open-overlay`
targeting them; 5 of 6 input tables had no writer, including the one the
`Scoring` element joins to compute points.

Detect it structurally, via `port_workbook.py --audit-only` →
`warnings_inherited_from_source`: overlays never opened, input tables never
written, buttons with no actions, and the effect-kind histogram. Declared
structures that nothing reaches are the tell.

Conditional actions are authorable (`trigger: {on, condition}`; condition `type`
`column` | `constant` | `formula`; conditions reference a control by
**`controlId`**), so the logic can be rebuilt in code — but rebuilding needs the
intended behaviour, which the spec no longer carries. Ask for it.

### Version tags
`tags` on the workbook (e.g. a `Public` release tag) are org-local publishing
state, not spec content. Re-tag in the target if it matters.

## Caveats — same spec, different render

Copied faithfully, but the target may still not look identical.

- **Base theme.** The spec carries `settings.theme.overrides` but no base theme
  name, so each org supplies its own default underneath. Observed effect on a
  real port: control elements rendered their `name` as a visible label in the
  source org and did not in the target, with the control element **byte-identical**
  and `settings`/`pages`/`panels`/`overlays` all identical. The control schema
  exposes no label-visibility field, so this is not spec-expressible — set it in
  the UI if you need it.
- **Markdown normalization.** The API collapses runs of 3+ newlines in `text`
  `body` to 2 on write. Harmless in itself, but it shortens text blocks, which
  can redistribute auto-sized grid rows around them.

Both are environment/API behaviour, not something the port dropped — prove it
the same way: diff the element with `verify_port.py structure`, which ignores
the legitimate rewrites and shows everything else.
