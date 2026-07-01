# Looker → Sigma — Quickstart

End-to-end: a Looker LookML model + its dashboards (UDD or LookML-defined) → a Sigma data model
+ workbook(s), parity-verified against Looker AND the warehouse.

## 0. ONE COMMAND (preferred)
```bash
# env: SIGMA_CONNECTION_ID (full warehouse-connection UUID, NOT a short prefix)
# is required unless --reuse-dm — persist it via setup.rb (~/.sigma-migration/env,
# auto-sourced) or export it here:
export SIGMA_CONNECTION_ID=<full-connection-uuid>
# offline (fixtures work end-to-end):
python3 scripts/migrate-looker.py --lookml-dir fixtures/skilltest-orders \
    --dashboard fixtures/skilltest-orders/skilltest_orders.dashboard.lookml \
    [--name PREFIX] [--workdir /tmp/look-run]
# live: --dashboard-id <id> instead of --dashboard (needs ~/.looker/looker.ini)
```
> **Windows:** launch with the `py` launcher — `py -3 scripts/migrate-looker.py …` —
> not a bare `python3`. A bare `python`/`python3` on Windows often resolves to the
> Microsoft Store *App Execution Alias* stub, which silently does nothing. If you
> see the command exit instantly with no output, disable those aliases (Settings →
> Apps → Advanced app settings → App execution aliases) or use `py -3`. Child steps
> the orchestrator spawns already reuse the running interpreter (`sys.executable`),
> so only the first launch needs this.
Runs everything below — parse → RLS gate (exit 10 on findings unless `--yes`) →
convert (exit 3 + `--converted` resume when no local converter) → DM-reuse check
(candidates PRINTED; default build-new, reuse only via `--reuse-dm <id>`) →
`post_dm.py` + readback → `build_workbook.py` + POST (layout inline) → freshness
preflight → **scripted parity (`phase6-parity-looker.rb`) +
`assert-phase6-ran.rb` hard gate**. Exit 0 = GREEN; a failed gate fails the
command. Sigma token auto-minted from `~/.sigma-migration/env`. Steps 1–5 below
are the manual, per-phase path.

## 1. Authenticate

**Looker** (REST API 4.0). Put an API3 key in `~/.looker/looker.ini`:
```ini
[Looker]
base_url=https://<your-instance>.cloud.looker.com:19999
client_id=<API3 client_id>
client_secret=<API3 client_secret>
verify_ssl=True
```
Generate the key in Looker: **Admin → Users → (you) → Edit Keys → New API3 Key**. Test it:
```bash
python3 scripts/looker_api.py whoami        # HTTP 200 + your name/roles
```

**Sigma**: credentials via the `sigma-api` skill (`ruby scripts/setup.rb` once → `~/.sigma-migration/env`).
```bash
eval "$(scripts/get-token.sh)"              # sets SIGMA_API_TOKEN (~1h TTL)
export SIGMA_CONNECTION_ID=<full-connection-uuid>   # NOT a short prefix
```

## 2. Discover

```bash
python3 scripts/looker_api.py raw GET /lookml_models   # list models/explores
python3 scripts/looker_api.py raw GET /dashboards      # list dashboards (UDD + LookML)

# pull one dashboard into the normalized contract (works for UDD AND LookML)
python3 scripts/fetch_looker_dashboard.py <dashboard_id> /tmp/look/<dash>.contract.json
# offline (dev/test only — cannot see UDDs):
python3 scripts/parse_lookml_dashboard.py <file.dashboard.lookml> --out /tmp/look/<dash>.contract.json

# scan for row-level security (silent + exit 0 if none; if found → ONE decision gate before Phase 3)
python3 scripts/detect_rls.py /path/to/lookml
# reuse-first lookup of the matching Sigma user attribute (read-only, plan-only by default)
python3 scripts/apply_sigma_rls.py --attr <name>
```

If `detect_rls.py` reports RLS (`access_filter` / `sql_always_where` / `access_grant`), stop ONCE
before building: the whole port is scripted via `apply_sigma_rls.py` (Sigma user attributes are
API-supported). Reuse-first (`--attr <name>` → `GET /v2/user-attributes`, prints a match), pre-fill
the recommended mapping (`access_filter` → `CurrentUserAttributeText("<attr>") = [<Field>]` row
filter; `sql_always_where` → DM/element filter; `access_grant` → note), then confirm/edit/skip in a
single decision. On confirm, apply via the same script: `--create` (POST attribute), `--assign
--member-id --value` (POST assignment), `--apply --field --element-id --dm-id` (PATCH the row
filter into the DM element). It mutates only on those flags. Record ported/reused/skipped in the
summary (never silently drop RLS). Validated live with exact 3-way parity ($38,906.82 / 220 rows).

## 3. Convert the semantic model

Feed the LookML **model** (not the warehouse tables) to the converter — it resolves the
explore's join graph. **This runs locally by default**: the skill ships a self-contained
vendored bundle (`converter/lookml.mjs`) and `scripts/convert_dm.mjs` runs it in-process via
`node` — no clone, no `npm install`, no network call, and your LookML never leaves the machine:
```bash
LOOKML_DIR=/path/to/lookml \
  node --import tsx/esm scripts/convert_dm.mjs <explore> /tmp/look/dm-spec.json
```
A dev's own checkout wins automatically when set — point `CONVERTER_SRC` at a patched
`sigma-data-model-mcp/src/lookml.ts` (the long-running MCP server only serves its *deployed*
build, so a source-tree fix needs this direct path to take effect):
```bash
LOOKML_DIR=/path/to/lookml \
CONVERTER_SRC=/path/to/sigma-data-model-mcp/src/lookml.ts \
  node --import tsx/esm scripts/convert_dm.mjs <explore> /tmp/look/dm-spec.json
```
The hosted **`convert_lookml_to_sigma`** MCP tool is a **manual fallback only** — reached when
neither the vendored bundle nor a local build is available. In that case
`scripts/migrate-looker.py` writes `convert-request.json` (the exact MCP arguments) and exits
`3`; call the tool by hand, save its JSON output, and resume with `--converted <file>`.

Read the printed warnings. Before POSTing, run the **DM-reuse check** (SKILL.md Phase 2.5):
`lookml-dm-signature.py` + `find-or-pick-dm.rb --auto-pick` score the org's existing data
models against the explore's tables/columns — on a strong match the skill asks reuse-vs-new
and the POST is skipped. Otherwise POST + register:
```bash
bash -c 'eval "$(scripts/get-token.sh)" && \
  SIGMA_CONNECTION_ID=$SIGMA_CONNECTION_ID python3 scripts/post_dm.py /tmp/look/dm-spec.json'
```
This POSTs to `/v2/dataModels/spec` (auto-finds a folder, swaps in the full connection UUID).
Verify with `mcp__sigma-mcp-v2__describe` (no `type=error` columns) + a raw-aggregate `query`.

## 4. Convert the dashboards (model → DM → its dashboards → layout)

```bash
python3 scripts/build_workbook.py /tmp/look/<dash>.contract.json \
  --views /path/to/lookml/views \
  --dm-id <dataModelId> --element-id <denorm-element-id> \
  --dm-element-name "<DM element display name>" \
  --folder-id <writable-folder-id> \
  --out /tmp/look/<dash>.workbook.json
```
Emits a `/v2/workbooks/spec` body: hidden Data page + master table, one element per tile,
controls from filters, newspaper→24-col layout XML. POST it to `/v2/workbooks/spec` (returns
YAML → record `workbookId`). **POST once; PUT every later edit** (re-POST leaves orphans).

## 5. Verify parity (3-way) — MANDATORY (scripted hard gate)

```bash
ruby scripts/phase6-parity-looker.rb --workdir /tmp/look --workbook-id <wb>   # PASS 1: plan
# … fetch ACTUAL (Sigma) + EXPECTED (Looker inline query / warehouse) …
ruby scripts/phase6-parity-looker.rb --workdir /tmp/look --finalize           # PASS 2: sentinel
ruby scripts/assert-phase6-ran.rb   --workdir /tmp/look --workbook-id <wb>    # must exit 0
```
(`migrate-looker.py` runs all of this automatically.) The reference comparison
is 3-way, at the metric grain and per tile:
- **Looker** — `POST /queries/run/json` for the explore.
- **Sigma** — `mcp__sigma-mcp-v2__query` (raw aggregate; `metric()` returns "Missing Metric").
- **Warehouse** — the source-of-truth `SELECT`.

GREEN only when all three match (the validated run tied out to the cent) AND
`assert-phase6-ran.rb` exits 0.

---

### Notes / gotchas

- **UDD is the primary path** — `GET /dashboards/{id}` returns user-defined and LookML dashboards
  identically; the converter is source-agnostic via the contract.
- **Spec endpoints return YAML** — never `json.load` / `jq` the response.
- **KPI `value.columnId`** vs **donut/pie `value.id`**; **control elements need their own `id`**.
- **Lossy + warned:** Liquid `{% %}` measures, manifest constants, `link:`/`html:` styling, pivot
  cross-tab (flattened → rebuild as Sigma pivot-table in UI), table-calc window grain, cross-
  filtering / trellis / tooltips (Sigma UI-only). Wire these in Phase 5 post-publish.
- **`build_looker_dashboard.py` / `build_looker_dashboard2.py` are test-fixture builders** — they
  author Looker dashboards (migration targets), not part of a customer migration.
