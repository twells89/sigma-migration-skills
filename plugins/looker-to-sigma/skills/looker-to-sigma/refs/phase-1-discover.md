<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. Phase 1 — discover Looker content; transports, contract fetch, offline path, RLS scan. -->

# Phase 1 — Discover the Looker content

Three transports, in order of preference: **Looker MCP** (when wired in) → **Looker REST API
4.0** (the default here) → **offline `.lkml`** (dev/test, can't see UDDs).

### 1a. Smoke-test + list

```bash
python3 scripts/looker_api.py whoami                 # confirm auth + admin
python3 scripts/looker_api.py raw GET /lookml_models  # list models
python3 scripts/looker_api.py raw GET /dashboards     # list dashboards (UDD + LookML)
```

For a specific explore's field graph:
`python3 scripts/looker_api.py raw GET /lookml_models/<model>/explores/<explore>`.

### 1b. Pull each dashboard into the normalized contract (live)

```bash
python3 scripts/fetch_looker_dashboard.py <dashboard_id> /tmp/<name>/<dash>.contract.json
```

> **Discovery speed: already sub-second.** A dashboard pull is one login (cached
> per process) + one `GET /dashboards/{id}` — there is no estate walk to optimize.
> For many-call sessions (parity, inventory) `looker_api.py`'s per-process token
> cache removes the per-call login round-trip (~150ms each).

This hits `GET /dashboards/{id}` and normalizes into `refs/dashboard-contract.md`. It works
for UDD **and** LookML dashboards (the API returns both identically). Key extraction details
(already handled by the script):
- **`tileType` comes from `query.vis_config.type`**, not `element.type` (which is always
  `"vis"` for chart tiles, `"text"` for text tiles).
- **`listen`** (which dashboard filters a tile obeys) comes from
  `result_maker.filterables[].listen`.
- **layout** comes from the **active** layout's `dashboard_layout_components[]`
  (`row`/`column`/`width`/`height`); ignore mobile variants.
- **`dynamic_fields`** (table calcs / client-side custom measures) arrives as a **JSON string**
  — the script `json.loads` it.

### 1c. Offline path (dev/test only)

```bash
python3 scripts/parse_lookml_dashboard.py <file.dashboard.lookml> --out /tmp/<name>/<dash>.contract.json
```

Same contract shape. Cannot see UDD dashboards; LookML dashboards may also lag the live UI
state (a `.dashboard.lookml` reflects source-of-truth, the API reflects edits). **Prefer the
API.** Note: a deployed LookML dashboard does NOT auto-index for `import_lookml_dashboard`
(Looker reindexes lazily, 404 until then) — just build/discover the UDD directly.

> **No live instance?** A GCP free-trial account CANNOT provision Looker (instance quota is
> `isFixed` = 0, Sales-gated). Build/test from sample LookML + the offline path. The validated
> end-to-end run used a real `example.cloud.looker.com` instance pointed at `DEMO_DB.DEMO`.

### 1d. Scan for row-level security (RLS) — cheap, silent if none

Looker enforces row-level security in LookML, and **security is the one place a silent default
is dangerous in both directions** — silently dropping RLS exposes data; silently porting a wrong
mapping over- or under-restricts it. So scan for it during discovery, but stay out of the way
when there's nothing to decide.

```bash
python3 scripts/detect_rls.py /path/to/lookml          # the project dir (and/or a model JSON)
```

- **Zero overhead on the happy path.** `detect_rls.py` is a cheap regex scan; **if it finds no
  RLS it prints nothing and exits 0** — no prompt, no extra phase, the migration proceeds
  straight to Phase 2 unchanged.
- **If it finds RLS, it lists every finding** (construct, explore, field, `user_attribute`,
  expression) plus the recommended Sigma mapping — that output feeds the **single** RLS decision
  gate below (do NOT prompt per rule). The constructs it detects, and their Sigma targets:

  | Looker RLS construct | What it does | Sigma target |
  |---|---|---|
  | `access_filter` (explore) | maps a `user_attribute` → a field; restricts rows to the caller's allowed values | a Sigma **user attribute** + a row filter using `LookupUserAttributeText(...)` / `CurrentUserAttributeText(...)` on that field |
  | `sql_always_where` (explore) | a hardcoded SQL row filter always ANDed onto the explore | a Sigma **data-model / element filter** (if the expression references a `user_attribute` / `{{ _user_attributes[...] }}`, make it a user-attribute row filter, not a static one) |
  | `access_grant` (model) | gates explores/fields/joins by a `user_attribute`'s allowed values | **note / review** — no 1:1 analog; map to Sigma **permissions** or a user-attribute filter |
  | `user_attribute` reference | any other `_user_attributes[...]` / `user_attribute:` use | **provision** the matching Sigma user attribute (reuse if it already exists) |

> The `convert_lookml_to_sigma` converter ALSO detects `access_filter` and emits an RLS note (and
> a `CurrentUserAttributeText()` row-filter stub) in the DM spec. `detect_rls.py` is the
> discovery-time, project-wide view that drives the **decision gate** — the converter handles the
> per-spec emission once you've decided to port.
