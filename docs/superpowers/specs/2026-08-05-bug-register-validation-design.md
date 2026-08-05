# Design — validating the RSM migration bug register

Date: 2026-08-05
Status: approved

## Problem

A live Tableau→Sigma migration produced a 32-item bug register (`BUGS.md`,
compiled 2026-08-05) split by its author into three sections: **S1–S10** Sigma
platform/API, **K1–K18** `tableau-to-sigma` skill, **C1–C4** `sigma-authoring`
doc corrections. Nothing has been filed anywhere.

Two problems with consuming it as-is:

1. **The register is stale.** It was compiled against `tableau-to-sigma`
   v1.6.3. The live plugin is v1.6.10. At least one item (K1) already has a
   merged fix; others may too. Filing the register unchanged would waste
   engineering time on closed bugs.
2. **The A/B split is an assertion, not a finding.** It reflects where the
   migrating agent believed each fault lived. A skill bug misread as a platform
   bug wastes Sigma engineering's time; a platform bug misread as a skill bug
   gets "fixed" with a workaround that hides a real product defect.

The register also declares its own filing split as "K1–K14", silently omitting
**K15–K18**.

## Goals

- A defensible verdict for all 32 items, each backed by cited evidence.
- The platform/skill boundary re-derived from evidence, not inherited.
- An engineering write-up covering only bugs that are real *today*.
- An executable remediation plan for the skill-side bugs that are real *today*.

## Non-goals

- Fixing anything. This effort produces verdicts and a plan, not patches.
- Re-running the source migration.
- Duplicating the in-flight workbook `document`-wrapper migration
  (PRs #609 / #610 / #626). Items that belong to it are cross-referenced.

## Taxonomy

Every item resolves to exactly one verdict:

| Verdict | Meaning | Destination |
|---|---|---|
| `CONFIRMED-PLATFORM` | Real; reproduces today; Sigma's to fix | Engineering write-up |
| `CONFIRMED-SKILL` | Real; present in v1.6.10 source | Remediation plan |
| `FIXED-SINCE` | Was real; fixed between v1.6.3 and v1.6.10 | Dropped; PR cited |
| `RECLASSIFIED` | Filed on the wrong side of the split | Moves bucket |
| `FALSE-POSITIVE` | Misdiagnosed or not reproducible | Dropped; reason given |
| `UNVERIFIABLE` | Requires state that cannot be reconstructed | Stated as such |

`UNVERIFIABLE` is a real verdict, not a failure. An item that cannot be settled
is reported as unsettled rather than guessed.

## Method

### Skill items (K1–K18)

Static validation against v1.6.10, plus `git log v1.6.3..HEAD`.

The controlling rule: **validate the reported behavior, not the reported line
number.** Line numbers drift, and a keyword grep produces false "fixed"
verdicts. K11 is the worked example — the register reports an
`Encoding::CompatibilityError` from `String#strip` on non-UTF-8 subprocess
output at `migrate-tableau.rb:5283`. Grepping for `force_encoding` finds hits at
lines 1191, 2105 and suggests the bug is fixed. It is not: the Phase-5b render
thread at the actual failure site still calls `.strip` on unscrubbed `Open3`
output.

A verdict requires either a `file:line` citation in current source or a merge
commit that demonstrably covers the reported site.

### Platform items (S1–S10)

Live probes against a maintainer-owned validation org (recorded in the local
evidence ledger, not here). The source
migration ran in a different tenant; these bugs are asserted to be
org-independent, and reproducing them in a second org strengthens rather than
weakens that claim. Any item that fails to reproduce here is investigated for
org-specific causes before being called a false positive.

### Doc items (C1–C4)

Checked against the vendored `sigma-authoring` text and its upstream in
`sigma-skills`. Each C verdict derives from its parent S verdict — C1 asserts
the docs recommend a pattern that S2 says silently corrupts data, so C1 is only
actionable if S2 confirms. Fixes land upstream then re-vendor per `SYNC.md`.

## Probe harness

One scratch data model and one scratch workbook in the validation org, prefixed
`zz-coderep-probe-2026-08-05`, built on an existing warehouse schema.
Implemented as a single re-runnable script so engineering can reproduce the
findings rather than take them on trust. Every probe records its `requestId`.

| Probe | Settles | Mutating |
|---|---|---|
| P1 | S1 — flat vs `{document:…}` body on `/v2/workbooks/spec/verify` | no |
| P2 | S9 — empty success body on create | creates workbook |
| P3 | S2 — bare cross-element ref vs `Lookup()`, non-null row counts | creates DM; queries |
| P4 | S3 — workbook element referencing a related element's column | no |
| P5 | S5 — parenthetical and digit-adjacent ref-name resolution | no |
| P6 | S7 — element with `columns: []` | updates workbook |
| P7 | S4 — single-value `date` in the live controlType union | no |
| P8 | S10 — control targeting a map; image `data:` URI | updates workbook |
| P9 | S8 — element whose query errors, exported | export |
| P10 | S6 — `DELETE /v2/workbooks/{id}` vs `/v2/files/{id}` | cleanup |

Execution is strictly sequential — the org permits one warehouse-hungry
workstream at a time, and P3 queries the warehouse.

P8 carries extra weight: the skill source at
`build-charts-from-signals.rb:6603` asserts data URIs are "live-verified"
working, while S10 asserts Sigma rejects them. One of the two is wrong, and
which one decides whether K7 is a skill bug or a platform regression.

## Deliverables

`sigma-migration-skills` is a **public** repository. Placement follows from
that:

| Artifact | Location | Customer identifiers |
|---|---|---|
| This design | repo, `docs/superpowers/specs/` | scrubbed |
| Evidence ledger (32 items) | repo, scrubbed; full copy local | scrubbed in repo |
| Engineering write-up | **local only**, `~/` | tenant retained; tile/field names stripped |
| Remediation plan | repo, `docs/superpowers/plans/` | scrubbed |

The engineering write-up stays off the public repo because its audience is
internal Sigma engineering and its value depends on naming the affected tenant.

## Verification discipline

- A probe verdict is what the probe measured. A clean HTTP 200 is not evidence
  that the underlying behavior is correct — P3 exists precisely because S2
  describes a call that returns 200 and wrong data.
- Every gate proposed by the remediation plan must be demonstrated to **fail on
  a planted defect** before it is treated as a gate.
- Scratch objects are cleaned up. Anything that cannot be cleaned up is
  reported, not omitted.

## Risks

- **`main`'s workbook write path is currently broken** against the live API
  (the `document` wrapper is unmerged). Some K-items cannot be reproduced
  end-to-end until #609 lands; those resolve to `UNVERIFIABLE` with the
  blocking reason named.
- **Concurrent sessions.** The wrapper migration holds ~10 worktrees in this
  repo. All work here happens in an isolated worktree with explicit staging.
- **Second-org reproduction.** A platform bug that depends on tenant
  configuration could fail to reproduce here; that is treated as a finding to
  investigate, not as a refutation.
