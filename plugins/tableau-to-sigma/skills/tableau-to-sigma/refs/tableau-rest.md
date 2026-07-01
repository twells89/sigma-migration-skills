# Tableau REST API mode (PAT fallback)

When the Tableau MCP tools (`mcp__tableau__*`) are missing in the session, the skill can
discover Tableau workbooks/datasources directly via the REST API using a Personal Access
Token. This doc covers the auth flow, endpoint inventory, response shapes, and the gotchas.

## When to use this mode

Pick MCP when it's available — it's simpler and the auth is already handled by the host.
Use PAT mode when:

- The agent runtime doesn't surface the Tableau MCP tools.
- You want to **download the workbook's `.twb` XML** for layout-hint extraction (the MCP
  doesn't expose this).
- The workbook uses an **embedded datasource** the MCP can't see (REST + `.twb` parsing can).
- You're on **self-hosted Tableau Server** (see below) — the hosted Tableau MCP targets Cloud.

## Tableau Server vs Cloud

The REST signin and the core endpoints (workbooks, views, view-data CSV, view-image PNG,
`.twb`/`.twbx` content) are **identical** on Cloud and self-hosted Server, so PAT mode works
on both. Four differences matter:

| | Tableau Cloud | Self-hosted Tableau Server |
|---|---|---|
| **REST API version** | always the latest | pinned to the installed release |
| **VDS** (`/api/v1/vizql-data-service`) | always on | needs **2024.2+** AND admin-enabled |
| **Metadata API** (`/api/metadata/graphql`) | always on | **OFF by default** (`tsm maintenance metadata-services enable`) |
| **Default site `contentUrl`** | n/a (always a named site) | the Default site uses an **empty** contentUrl |

Handled automatically:

- **Version negotiation** — `get-tableau-token.sh` reads the server's max `restApiVersion`
  from `/api/2.4/serverinfo` (no auth, so it can't trip the 4-strike PAT lockout) and signs
  in against that. Set `TABLEAU_API_VERSION` to override.
- **Default site** — `setup-tableau.rb` accepts an empty contentUrl; leave it blank when
  prompted on Server.
- **Capability banner** — `tableau-discover.rb` prints product version, REST API version,
  and Metadata-API on/off up front. When VDS/Metadata are off, calc formulas come from the
  downloaded `.twb` XML instead of `ds-metadata.json`/`graphql-fields.json` — discovery
  degrades gracefully rather than failing, but the banner tells you which mode you're in so
  a thin `ds-metadata.json` isn't mistaken for a bug.

## One-time setup

```bash
ruby scripts/setup-tableau.rb
```

Prompts for:

| Value | Where to find it |
|---|---|
| Server URL | The hostname only — Cloud `https://10ay.online.tableau.com` or Server `https://tableau.mycompany.com`. No trailing slash needed. |
| Site contentUrl | The path segment after `/site/` in any Tableau URL — e.g. `dataflow`. **Leave blank** for a Tableau Server "Default" site. |
| PAT name | The label you typed when creating the token in **Account Settings → Personal Access Tokens**. Case-sensitive. |
| PAT secret | The string shown at creation time. Copy verbatim — Tableau secrets are formatted as `base64==:base64`, the colon is part of the secret. |

Stored in `~/.claude/settings.json` as `TABLEAU_SERVER_URL`, `TABLEAU_SITE_CONTENT_URL`,
`TABLEAU_PAT_NAME`, `TABLEAU_PAT_SECRET`. Open a new Claude Code session (or
`! source ~/.claude/settings.json`) so they're live.

## Signin per session

```bash
eval "$(scripts/get-tableau-token.sh)"
```

Sets `TABLEAU_AUTH_TOKEN` and `TABLEAU_SITE_ID` in the calling shell. The token is good for
the duration of the session (Tableau Cloud session timeout, typically a few hours).

> **The script makes exactly one signin attempt.** Do not wrap it in a retry loop. Tableau
> Cloud invalidates a PAT after **four consecutive failed signins**, after which even
> correct credentials return 401001 and the only fix is creating a fresh PAT.

## Endpoint inventory

All paths assume `$TABLEAU_BASE = $TABLEAU_SERVER_URL/api/$TABLEAU_API_VERSION/sites/$TABLEAU_SITE_ID`.

| Skill need | Endpoint | Notes |
|---|---|---|
| Find workbook by name | `GET $TABLEAU_BASE/workbooks?filter=name:eq:NAME` | URL-encode the filter. Response is paginated; the filter is exact-match. |
| Get workbook (with views) | `GET $TABLEAU_BASE/workbooks/WBID` | Returns `views.view[]` with `id` + `name`. |
| List datasources | `GET $TABLEAU_BASE/datasources?pageSize=N&pageNumber=P` | Same filter syntax. |
| Find datasource by name | `GET $TABLEAU_BASE/datasources?filter=name:eq:NAME` | Exact-match. |
| VDS read-metadata (field list + calc formulas) | `POST /api/v1/vizql-data-service/read-metadata` | Body `{"datasource":{"datasourceLuid":"..."}}`. Returns `data[]` with `fieldName`, `fieldCaption`, `dataType`, `columnClass`, `formula` (for `CALCULATION` fields). |
| Metadata GraphQL (cleaner formulas) | `POST /api/metadata/graphql` | Returns formulas with **display-name field refs** like `SUM([Net Revenue])` instead of GUIDs. |
| View data (CSV) | `GET $TABLEAU_BASE/views/VID/data` | Cheap. Fire all views in parallel. |
| View image (PNG) | `GET $TABLEAU_BASE/views/VID/image?vf_width=W&vf_height=H` | Fetch dashboard view only by default. Solo (no concurrent image calls) — VizQL session contention causes 401s otherwise. |
| Workbook content download | `GET $TABLEAU_BASE/workbooks/WBID/content[?includeExtract=false]` | Returns raw `.twb` XML for workbooks with published datasources, or `.twbx` zip bytes if there are embedded extracts. Detect by checking the first 4 bytes for the ZIP magic `PK\x03\x04`. |
| Logout (optional) | `POST $TABLEAU_BASE/auth/signout` | Frees the session token; signin doesn't count against site quotas. |

## CLI: one-call discovery

The `scripts/tableau-discover.rb` helper produces all Phase-1 artifacts in one go:

```bash
eval "$(scripts/get-tableau-token.sh)"
ruby scripts/tableau-discover.rb \
  --workbook-name "Orders Conversion Test" \
  --datasource-name "ORDER_FACT (CSA.ORDER_FACT)+ (New Virtual Connection)" \
  --out /tmp/orders
```

Writes:
- `get-workbook.json` — workbook metadata + views list
- `ds-metadata.json` — VDS field list
- `graphql-fields.json` — metadata API field list (cleaner formulas)
- `views/<viewId>.csv` — every view's data
- `views/<viewId>.png` — dashboard view image only (by default)
- `workbook-content.twb` or `.twbx` — raw workbook content

Flags: `--workbook-id ID` (skip search), `--skip-images`, `--all-view-images`, `--skip-content`.

The output layout matches what the MCP-driven Phase 1 produces, so the downstream Phase
2–6 scripts (`fetch-view-data.rb`, `extract-calc-fields.rb`, `validate-spec.rb`, etc.) work
unchanged.

## Gotchas

### PAT invalidation

Four consecutive failed signins kill the PAT permanently. The only fix is a fresh token
from the Tableau Cloud UI. Always test the credentials with **one** call, fix-on-fail, then
try again — never iterate-guess names.

### Secret format

Tableau Cloud PAT secrets contain a colon and look like `+pFEL...XmMg==:gzS1...eB7E`.
The colon is part of the secret, **not** a name/secret separator. Copy the full string.

### VDS field names vs display names

`read-metadata` returns `fieldName` and `fieldCaption`. For fields belonging to **joined
logical tables** in a virtual connection, `fieldName` is a GUID like
`66792cbd-306e-3a9b-882a-f08cd73bb433 (DATE_DIM (CSA.DATE_DIM)1)` — use `fieldCaption` for
the human-readable name. Calculations also have `fieldName == fieldCaption`, no GUID.

GraphQL's `name` field is always the display name — prefer GraphQL for calc-formula
extraction if you want references like `[Net Revenue]` instead of GUIDs.

### Workbook content: .twb vs .twbx

- Published-datasource workbooks: response is a raw `.twb` XML document. Parse directly.
- Embedded-extract workbooks: response is a `.twbx` zip — unzip and pull the `.twb` out.
- Detect by reading the first 4 bytes: `PK\x03\x04` → zip; otherwise XML.

The `.twb` XML contains a `<datasources>` block (with all calc formulas) and a
`<dashboards>/<dashboard>/<zones>` tree with x/y/w/h coordinates in units of 100000 (= 100%
of dashboard). The zone tree is the only way to get the Tableau dashboard's **layout**
structure programmatically — `get-view-image` only renders pixels.

### .twb calc formula GUIDs

Inside the `.twb` XML, `<calculation>` elements reference fields by GUID
(`[06db681d-04be-3a38-b324-85dc4732a408]`). To translate back to display names, walk the
sibling `<column>` elements in the same `<datasource>` and match `name="[guid]"` →
`caption="display name"`. For a one-shot read, prefer GraphQL or VDS read-metadata — both
return formulas with display-name refs.

### Image resolution

Default `get-view-image` returns 800x800. Pass `?vf_width=W&vf_height=H&resolution=high`
to get a usable dashboard screenshot. The MCP defaults to a similar size; this is just an
FYI for the REST path.

### Pagination

`workbooks` and `datasources` endpoints paginate. The helper functions in
`scripts/lib/tableau_rest.rb` fetch one page; if your site has many items, walk the pages
via `pageNumber` and `pageSize`. The skill rarely needs this — `filter=name:eq:NAME`
returns at most a few matches.

### MCP fallback decision

The skill prefers MCP when both are available. The discovery CLI is opt-in:

- If you want explicit PAT-mode (e.g., to use `.twb` layout-hint extraction), run
  `scripts/tableau-discover.rb` and skip the MCP discovery steps.
- If you're in MCP mode and need just one REST-only capability (typically `.twb`
  download), call `Tableau.download_workbook_content` from a small Ruby snippet — no need
  to redo the whole discovery via REST.
