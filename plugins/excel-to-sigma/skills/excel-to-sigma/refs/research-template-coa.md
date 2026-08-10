# Template-family detection + chart-of-accounts (the ~850-file fleet)

A broker covers hundreds of companies off **one house model template** (a single sell-side desk can cover ~850). The
files are "similar but not identical" — same skeleton, different company / segments / periods /
row counts / (bilingual) labels. This is the *ideal* case: reverse-engineer the template ONCE,
then run `scripts/batch-convert.py` across the fleet with a triage report. Read this before a
fleet run; pair with `refs/research-recipes.md` (the per-file conversion).

## Once vs per-file

- **Template-once (curated, versioned):** `scripts/coa.json` — the canonical chart-of-accounts
  (`{id, section, aliases[] (EN+FR), shape}`), the expected sections/sheets, the fingerprint
  weights + thresholds. This is the *contract*.
- **Per-file (automated):** fingerprint, COA mapping, canonical-formula inference + parity
  (re-run per file — rows/years/overrides differ), triage, build.

The contract is a **prior, not a straitjacket**: a per-file formula that disagrees with a COA
`shape` is a *flag*, not an auto-reject (over-fit protection — we have few examples).

## Fingerprint (similarity, not equality)

`batch-convert.py::fingerprint` scores each file against the contract — NO absolute cell
addresses (we have too few examples to hard-code positions):
- **section-header set** overlap (weight 0.4) — the strongest, most stable signal,
- **sheet-name set** (0.15) — `FY results` + `Quarterly` (+ the `__FDSCACHE__` marker),
- **headline-label coverage** vs the COA (0.25) — fraction of non-ratio lines that map,
- **formula-shape presence** (0.2) — derived canonicals exist.
→ `SAME` (≥0.75) / `VARIANT` (≥0.45) / `UNKNOWN`. `UNKNOWN` is never guessed at → FAILED.

## Line → COA mapping (confidence tiers)

`coa_map` maps each line to a canonical account: **exact normalized alias** → **fuzzy token
overlap ≥0.6** (catches `= EBIT (Operating income)` → `ebit`, `Marge brute` → `gross_profit`).
- **Unmapped lines are CARRIED** (company-specific), never dropped. Ratio / `ow …` sub-items
  are *detail*, not COA accounts — expected to be unmapped and carried.
- Segments / geographies (the `Quarterly` bridge) are a **dynamic dimension**, carried as data,
  not fixed COA.

## Triage buckets (no silent truncation)

Per file → `AUTO_PARITY` / `NEEDS_REVIEW` / `FAILED`:
- **FAILED** — `UNKNOWN` fingerprint, or a broken invariant (no year axis, no anchor line
  resolved, <2 known sections). Nothing built.
- **AUTO_PARITY** — `SAME`, 0 inference review-flags, every headline stable-section line mapped.
- **NEEDS_REVIEW** — everything else that still converted (VARIANT, inference flags, or an
  unmapped headline line). Still builds; still 100% displayed parity — just wants eyes.

**No-silent-truncation invariants** (a bounded/dropped result is logged, never silent): year
axis detected, ≥1 anchor resolved, ≥2 known sections, FactSet cruft counts recorded
(`named_ranges`, `__FDSCACHE__`). A file that trips one → FAILED with the reason.

## The manifest + the calibration loop

`--out manifest.json` (+ `.csv`) records per file: bucket, fingerprint, periods, line counts,
`live`/`frozen`, anchors, mapped/unmapped, stripped-cruft counts, reasons — plus a rollup and
**the top unmapped headline labels across the batch**. That last list is the calibration signal:
add those labels as `aliases` in `coa.json` and re-run. Run the **first ~30–50 files report-only**,
grow the COA + tune thresholds, *then* commit builds.

## Scale reality (state it plainly)

Input-table data load / warehouse view / publish are **UI-only**. 850 *editable* models is
untenable, so the batch default is **READ-ONLY**: the data page is inline `VALUES` in the DM
(fully API, parity-preserving) — `--post` builds `POST /v2/dataModels/spec` + `/v2/workbooks/spec`
per file (~1,700 calls; throttle/retry/resume; one folder per sector; guard name collisions).
Editable entry is **opt-in per file**, routed to the input-table hand-off, and cheap only once
the bulk-seed API lands. Don't promise editable-at-scale today.

## Run

```bash
# report-only calibration over a tranche
python scripts/batch-convert.py /path/to/models/ --sheet="FY results" --out manifest.json
# after calibration: also build the clean ones (read-only DMs, fully API)
python scripts/batch-convert.py /path/to/models/ --sheet="FY results" --out manifest.json \
       --post --conn <writeConn> --folder <folderId> [--post-review]
```
