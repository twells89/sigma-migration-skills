# Extract landing — embedded extracts → warehouse (exact-parity mode)

## When this path fires

Phase 0/1 discovery finds that **every** datasource federates over an **embedded
payload** — connection classes `excel-direct`, `textscan`, `hyper`, or `ogrdirect`
(shapefiles) under a `federated` connection — and there is **no live warehouse
connection** behind the workbook. The Sigma data model has nothing to point at
until the frozen extract itself is landed. Do NOT abort, and do NOT fabricate
warehouse paths: land the extract. (This is the community/consultant-workbook
norm — a 2026-07 live migration event was 10/10 extract-backed.)

Preflight: `doctor.json` reports `hyperapi_present`. It is informational, not
required — but extract-backed workbooks cannot land without it:

```
pip install tableauhyperapi 'pandas>=2.0,<3' pyarrow snowflake-connector-python
```

Pin `pandas<3` and install `pyarrow` explicitly: the Snowflake connector's
`write_pandas` requires pyarrow and does not yet support pandas 3.x — an
unpinned `pip install pandas` grabs 3.x and the landing fails on
`write_pandas` import. Use an isolated venv on PEP-668 (Homebrew) Pythons.

## The command

Discovery **auto-detects** an extract-backed workbook (an `<extract>` block
or `hyper`/`textscan` connection class in the .twb), but the payload
re-download is **opt-in**: pass `--extract-refetch` to `tableau-discover.rb`
on extract-landing runs to re-download `workbook-content.twbx` **with** the
payload (`includeExtract=true`) — check the discovery log for "extract payload
landed". Without the flag, discovery logs "extract re-fetch SKIPPED" and the
.twbx stays thin (no `.hyper` inside). If the payload is missing (a
default-skip discovery run, or the re-fetch WARNed), verify with
`unzip -l <workdir>/workbook-content.twbx | grep -c '\.hyper'` and re-download
via `Tableau.download_workbook_content(<wb-luid>, include_extract: true)` before
landing — a 0-hyper .twbx makes `land-extracts.py` a silent no-op. Then:

```bash
python3 scripts/land-extracts.py \
  --twbx <workdir>/workbook-content.twbx \
  --db <DB> --schema <SCHEMA> --prefix <WB_PREFIX> \
  --account <acct> --user <svc-user> --key-path <rsa_key.p8> \
  --role <role> --warehouse <wh> \
  --sigma-connection-id <connection-uuid> \
  --manifest-out <workdir>/landing-manifest.json
```

`--twbx` also accepts a directory (of `.twbx` files, or of extracted workbook
dirs). `--dry-run` prints the naming/typing plan without touching Snowflake.
Names land as UPPER_SNAKE with `_<32-hex-GUID>` suffixes stripped; a generic
hyper table name (`Extract`, `Sheet1`, `Extract (Extract.Extract)`…) is named
after the datasource caption instead: `<PREFIX>_<CAPTION>`. Every table is
row-count-verified after landing (zero-loss gate: mismatch aborts the run).

## EXACT parity — drift tolerance must be REFUSED

The landed tables are **byte-identical to the frozen extract Tableau rendered
from**. SQL over them is a *true oracle* for every number visible in the source
renders. Consequence: Phase 6 parity runs in **exact mode** — do not offer, and
do not accept, drift tolerance (`--tolerance`, "data may have refreshed",
`--min-pass-rate` waivers) for extract-landed sources. A mismatch is a
conversion bug, full stop. (~620 exact checks held in a 10-workbook live migration.)

## 'None' vs NULL

Python `None` lands as SQL `NULL` — never the string `'None'`. But genuine
`'None'` **string category values are real data** and pass through
byte-identical (live evidence: `ER_HOSPITAL_ER.DEPARTMENT_REFERRAL` has 5,400
legitimate `'None'` rows = "no referral"; `ECOM_PRODUCTS.ECO_CERTIFICATION` has
22). `land-extracts.py` guarantees both at read time with per-column converters
keyed on the hyper type tag (DATE→`datetime.date`, TIMESTAMP→`datetime64`,
GEOGRAPHY→WKT text, everything else untouched). Never `astype(str)` a whole
column — that is the exact bug that cost 24 post-hoc column repairs in the live
run. Do not "clean up" `'None'` strings in landed tables downstream.

## Catalog sync (the /sync endpoint works)

`POST /v2/connections/{connectionId}/sync` with body
`{"path": ["DB", "SCHEMA", "TABLE"]}` makes a newly landed table visible to
Sigma **immediately** — no UI "refresh schema" needed. Verified 48/48 in the
live-migration run. `--sigma-connection-id` does this per landed table and reports
ok/fail counts. Catalog sync authenticates through `scripts/lib/sigma_rest.py`
(browser keychain first, client-credential fallback) and refreshes/retries once
on a 401. (This supersedes any older "no API can refresh the catalog" claims.)

If you re-sync **manually** (e.g. after renaming a landed table) via
`Sigma.request` / `sigma_rest.request`, the `body:` must be a **JSON string**,
not a hash/dict — the shared helper does not auto-serialize. Pass
`body: {path: [DB, SCHEMA, TABLE]}.to_json` (Ruby) / `body=json.dumps({"path": [...]})`
(Python). `land-extracts.py`'s own `--sigma-connection-id` sync serializes
correctly on its own; this note is only for a hand-rolled re-sync.

## The manifest (Phase 3 contract)

`landing-manifest.json` is an array of
`{slug, datasource, caption, hyper, hyper_table, sf_table, rows, columns:{orig: landed}}`
— Phase 3 consumes it automatically: `migrate-tableau.rb` calls
`MechanicalSpecs.remap_from_manifest!` right after the converter runs, matching
each generic "Extract" DM element to its manifest entry **by column-set overlap +
`.hyper` filename** (never by name — embedded extracts all collapse to the name
"Extract"), then repoints `source.path` onto the landed `sf_table`, rewrites the
`[EXTRACT/…]` formula prefixes, and threads the `columns` orig→landed map into
the phantom-filter so sanitized indicator names fold to their real warehouse
column. Keep the manifest in the workdir next to the discovery artifacts. For
landed extracts the manifest is authoritative — `--table-mapping` cannot
disambiguate two identically-named "Extract" relations.
