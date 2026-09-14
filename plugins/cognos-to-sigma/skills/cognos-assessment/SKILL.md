---
name: cognos-assessment
description: Take inventory of an IBM Cognos Analytics estate and produce a migration-readiness readout — content-tree counts, per-artifact conversion complexity (scored against the Cognos→Sigma converter's exact coverage), an estate-wide auto-migration percentage, a named gap analysis, and an effort/wave plan. Use when a user wants to scope a Cognos→Sigma migration, audit Cognos sprawl, or pick which modules / reports to convert first. Read-only, all-free, ~Tableau-assessment-style pre-scoping that complements (does not replace) a deeper paid engagement.
user-invocable: true
---

# Cognos Assessment

Surveys an IBM Cognos Analytics (CA 11.x / 12.x / Cognos on Cloud) content estate
via the CA REST layer (`/bi/v1`) and produces a branded, share-friendly HTML
readout plus a JSON inventory. The differentiator versus a generic BI audit is
**converter-coverage scoring**: every Data Module and report is classified
auto-convert vs. flagged using the *same* rules the `cognos-to-sigma` converter
(`cognos.ts` + `cognos-report.ts` + `cognos-fm.ts`) actually applies — so the readout's
auto-migration % reflects what the tool will really do, not a hand-wave.

> **Read-only.** This skill only issues `GET`s against CA REST. It never POSTs,
> modifies, runs, or schedules anything in Cognos — and it never touches Sigma.
> It can also run fully offline against module/report files already on disk.

> **All free.** Everything here — inventory, scoring, the HTML readout — is part
> of the open migration tooling. There is no paid tier to upsell. For a deeper
> hands-on engagement (permissions audit, warehouse landing of file-backed
> modules, live parity testing), point the customer at a Sigma SE.

> **Tableau is the reference point.** This skill mirrors the structure and tone
> of the `tableau-assessment` skill (environment counts → coverage → effort →
> readout). If you've run that, this will feel familiar; the Cognos-specific
> work is all in the coverage scorer.

---

## Privacy posture (READ FIRST, surface to the customer)

**This skill reads content metadata and spec definitions, not warehouse data.**

| Crosses the LLM API | Stays in Cognos / local |
|---|---|
| Aggregate counts (module / report / dashboard / folder counts) | Warehouse rows (this skill never queries them) |
| Object names, owner / path, type | Database credentials |
| Data Module JSON (query subjects, items, calc expressions, joins) | The customer's actual report *values* |
| Report-spec XML (queries, data items, viz types, prompts, filters) | Uploaded source files (`.xlsx` / `.pq` — not re-downloadable via REST anyway) |

Like every Claude Code skill, what it reads is sent through the LLM API to
Claude. Tell the user this before running. Outputs are written to a local
`/tmp/cognos-assessment-<env>/` directory and uploaded nowhere — sharing is a
deliberate action, not automatic. See `PRIVACY.md` for the full disclosure.

---

## When to use this skill

- A Cognos customer wants a fast scoping view before committing to a migration.
- A Sigma SE preparing for a discovery call wants a pre-built conversion shortlist.
- A customer is deciding which Cognos reports/modules to retire vs. migrate.
- A `cognos-to-sigma` conversion needs a Phase 0 inventory of the source estate.

**Not for**: running or rendering live Cognos reports, extracting warehouse
data, or making any change to the Cognos environment.

---

## Modes

| Mode | Setup | Use when |
|---|---|---|
| **Live (REST)** | `COGNOS_BASE` + `COGNOS_COOKIE` + `COGNOS_XSRF` env (see below) | Real estate scan against a running CA server / Cognos on Cloud |
| **Offline (files)** | A directory of `*.module.json` + `*.report.xml` + a Framework Manager `model.xml` already on disk | No live access; scoring a sample set or an export the customer mailed you. FM projects only arrive this way — there is no CA REST endpoint for them |

Both modes feed the same scorer + renderer. The bundled samples in
`~/cognos-samples/` let you validate the whole pipeline offline.

---

## Phase 0 — Connect / probe access

Live mode needs a logged-in CA session's auth. Grab it from the browser
(DevTools → Network → any `bi/v1/...` request → copy the `Cookie` header and the
`X-XSRF-Token` header), then:

```bash
export COGNOS_BASE="https://<host>/bi/v1"     # NOTE: /bi/v1, not /api/v1
export COGNOS_COOKIE="<full Cookie header from a logged-in session>"
export COGNOS_XSRF="<X-XSRF-Token header value>"

# Cheap probe — list the content root (or a known folder id):
bash scripts/discover-cognos.sh --probe
```

If the probe 401/403s, the session expired — re-grab the cookie + XSRF (CA
sessions are short-lived). The discovery script surfaces a clear token-expiry
note rather than dumping a stack trace.

Offline mode needs no auth — skip straight to Phase 2 pointing the scorer at the
file directory.

---

## Phase 1 — Discover the estate (live mode)

```bash
bash scripts/discover-cognos.sh --root <folderId> --out /tmp/cognos-assessment-<env>
# or, if you don't have a folder id, start at the content store team-content root:
bash scripts/discover-cognos.sh --root .public_folders --out /tmp/cognos-assessment-<env>
```

`discover-cognos.sh` walks the content tree breadth-first
(`GET /bi/v1/objects/{id}/items?fields=defaultName,type,id`), recursing into
`folder` items, and records every `module` / `report` / `reportView` /
`exploration` / `dashboard` / `dataSet2` it finds. For each leaf it also fetches
the **spec** so the scorer can run offline afterward:

- module → `GET /bi/v1/metadata/modules/{id}` → `<out>/specs/<id>.module.json`
- report / reportView → `GET /bi/v1/objects/{id}?fields=specification` → `<out>/specs/<id>.report.xml`

It emits `<out>/inventory.json` = `{ environment: {...counts}, artifacts: [ {id,type,name,path,owner,lastRun,specFile} ] }`.

Notes baked into the script:
- **Pagination** — follows the `?skip=`/`top=` (or `next` link) on folders with
  many children; default page size 100.
- **Token expiry** — on a 401 it writes a `token_expired: true` flag into
  `inventory.json` and stops gracefully so you can re-auth and re-run (already
  fetched specs on disk are skipped — resumable).
- **`lastRun` / view stats** — recorded *only if* the object metadata exposes a
  run/modification timestamp. CA does **not** expose per-report run/view counts
  via this REST surface (see `refs/usage-telemetry.md`); treat usage as a known
  gap and request it from the Cognos admin (audit DB / Activity reports).

---

## Phase 2 — Score converter coverage (THE differentiator)

```bash
node scripts/score-coverage.mjs --in /tmp/cognos-assessment-<env>/specs --out /tmp/cognos-assessment-<env>
# offline against the bundled samples:
node scripts/score-coverage.mjs --in ~/cognos-samples --out /tmp/cognos-assessment-<env>
```

For every `*.module.json`, `*.report.xml` and Framework Manager `model.xml`, the
scorer classifies features
into four buckets — **auto / hint / manual / unhandled** — by detecting the
*exact* gap signals the converter flags. It does NOT re-implement the converter;
it detects the patterns the converter's `translateCognosExpr` / report parser
either translate cleanly or warn on. Each detected gap is recorded with a count
**and** the specific reason + remediation.

XML is dispatched by **root element**, not extension — an FM model and a report spec
are both `.xml`. Framework Manager is scored **whole-model** while the converter runs one
presentation subject area at a time, so its counts are an estate-size and gap profile
rather than one migration unit. Point `--in` at the directory holding `model.xml`; the
sibling `IDlog.xml` / `log.xml` are edit history and are ignored.

### Module signals (mirror `cognos.ts`)

| Bucket | Signal | Why |
|---|---|---|
| `auto` | query subject (`querySubject.ref` tail) → table; plain/measure items → cols/metrics; equi-join `link[].leftRef/rightRef` → DM relationship; calcs using `total/average[ for]`, `if/then/else`, `_add_days`/`_days_between`/`extract`, `substring/upper/lower/trim/substitute`, `||`, `cast(... as char)`, `coalesce` | translated cleanly by `translateCognosExpr` |
| `hint` | file-backed `useSpec.type:"file"` source; layered base+presentation subjects | converts, but needs a one-time decision (land the file in the warehouse first / dedupe layers) |
| `manual` | `case … when … end` (converter only does `if/then/else`); `… for …` window scope (→`*Over`, a window function that needs manual authoring in a DM element); composite / non-equi join (`link[]` length > 1, or an expression join with `and`/`or`/inequality) | converter passes through + warns |
| `unhandled` | `running-total`/`running-count`/`running-average`/`running-difference`/`moving-*`/`rank`/`percentile`/`quantile`/`tertile`; `GetResourceString(...)` (localization); a bareword `fn()` with no known Sigma mapping | converter warns "no clean Sigma analog — manual authoring" |

### Report signals (mirror `cognos-report.ts` + `format-shapes.md`)

| Bucket | Signal | Why |
|---|---|---|
| `auto` | `<list>` → table; `<crosstab>` → pivot; charts `bar/column/line/area/pie/donut/combo/scatter/bubble`; `tiledmap` → region-/point-map; `prompt('p')` → control; `Total(x)`/`Summary(x)` footers → `Sum`; supported DSL | converter emits clean elements |
| `manual` | detail / summary filters (re-create as Sigma element/page filters); drill-through (→ Sigma actions) | converter surfaces as a warning |
| `unhandled` | `# … prompt(...,'token') …#` runtime **macro** (swap-measure / dynamic column build); viz with no Sigma analog: `treemap`, `network`, `wordcloud`, `packedBubble`; `rank()` in a data item | converter emits a placeholder + loud warning |

### Output

`<out>/coverage.json` — per artifact:
`{ id, type, name, n_features, n_auto, n_hint, n_manual, n_unhandled, complexity, gaps:[{signal,count,bucket,reason,remediation}], value, cost, score, tag }`
plus an estate roll-up: `{ pct_auto_migratable, gap_histogram, by_complexity, by_tag, totals }`.

Scoring (same framework as every `*-assessment` skill):
`cost = 10·n_unhandled + 3·n_manual + 1·n_hint`;
`value = 10 × (n_features) ` (proxy — CA exposes no view counts; see usage-telemetry ref);
`score = value / (1 + cost)`.
Complexity: `n_unhandled>0 → high`; else `n_manual>0 → medium`; else `low`.
Tags: `n_unhandled≥1 → needs-review`; `(manual+unhandled)==0 → migrate-first`;
`score≥10 → easy-win`; else `moderate`.

---

## Phase 3 — Effort / wave plan

The scorer's roll-up feeds a simple wave plan (computed in `render-report.mjs`):

- **Wave 1 — migrate-first / easy-win.** Low-complexity modules + reports, no
  unhandled features. These are the pilot.
- **Wave 2 — moderate.** Medium complexity (manual setup, no unhandled) —
  convert with light review.
- **Wave 3 — needs-review.** Any artifact with an unhandled feature: a runtime
  macro, an unsupported viz, a window/rank calc. Each needs a human decision
  before conversion.

Modules generally migrate before the reports that source them (a report's table
elements point at the migrated DM element), so the plan sequences modules ahead
of their dependent reports where the dependency is detectable from the report's
`modelPath`.

---

## Phase 4 — Render the HTML readout

```bash
node scripts/render-report.mjs --out /tmp/cognos-assessment-<env>
# → writes /tmp/cognos-assessment-<env>/readout.html
```

Reads `inventory.json` (if present) + `coverage.json` and emits a standalone,
brand-styled `readout.html` (~6 sections, Sigma palette, print-friendly):

1. **Executive summary** — estate size, auto-migration %, headline finding.
2. **Estate inventory** — counts by type, artifact table.
3. **Coverage & auto-migration** — auto/hint/manual/unhandled breakdown, % auto.
4. **Gap analysis** — named artifacts + the specific gap + why + remediation.
5. **Effort / wave plan** — the 3 waves with member artifacts.
6. **Next steps** — pilot recommendation, what to request from the admin.

All-free framing throughout; no paid upsell.

---

## Phase 5 — Hand off (optional)

After the readout, you can hand the shortlist to the `cognos-to-sigma` converter
skill for the migrate-first artifacts. The coverage JSON's per-artifact `specFile`
points the converter straight at the spec it already fetched — no re-discovery.

> Do not auto-convert. Surface the shortlist and let the user choose.

---

## Scripts overview

| Script | Purpose |
|---|---|
| `scripts/discover-cognos.sh` | Walk the CA content tree via `/bi/v1`, fetch each module/report spec, emit `inventory.json`. Reuses the cookie+XSRF auth from the converter's `cognos-discover.sh`. Read-only, paginated, resumable, token-expiry aware. |
| `scripts/score-coverage.mjs` | Classify every spec auto/hint/manual/unhandled against the converter's exact gap signals; per-artifact complexity + estate roll-up. Zero-dependency (Node built-ins only). |
| `scripts/render-report.mjs` | Emit the branded standalone `readout.html`. Zero-dependency. |

## Refs

| Ref | Contents |
|---|---|
| `refs/ca-rest.md` | The CA REST endpoints this skill uses + auth shape. |
| `refs/scoring-rubric.md` | Every gap signal, what it means, which bucket, and the remediation text shown in the readout. |
| `refs/usage-telemetry.md` | Honest investigation of whether CA exposes run/view stats via REST (it largely doesn't) — the universal assessment weak spot, and how to request it from the admin. |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `discover-cognos.sh --probe` 401/403 | CA session expired | Re-grab `COGNOS_COOKIE` + `COGNOS_XSRF` from the browser |
| `inventory.json` has `token_expired: true` | Session died mid-walk | Re-auth, re-run — on-disk specs are skipped (resumable) |
| `score-coverage.mjs` finds 0 artifacts | `--in` points at the wrong dir | Point at the `specs/` dir (live) or `~/cognos-samples` (offline) |
| `metadata/modules/{id}` returns empty | Used `/modules/{id}` (wrong) | Must be `/metadata/modules/{id}` — the discovery script already uses the right one |
| Usage / run counts all blank | CA doesn't expose them via this REST surface | Expected — see `refs/usage-telemetry.md`; request from the Cognos admin |
