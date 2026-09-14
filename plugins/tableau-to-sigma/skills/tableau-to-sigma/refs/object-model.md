<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. Single-datasource relationship ("noodle" / object-model) workbooks → fact-anchored multi-element DM. -->

# Object-model ("noodle") datasources → fact-anchored DM

**Disposition: detected at Phase 0, auto-wired when keys are serialized,
refused into a named stop when they are not.** One Tableau datasource that is
a 2020.2+ *relationship (logical / object-model) graph* over N tables. This is
**not** a multi-datasource workbook (`refs/multi-datasource.md` — N sources,
nothing joins them) and **not** a blend (`refs/blending.md` — one worksheet
pulling 2+ sources on linking fields): the gaps report says `Datasources: 1`
for this shape, and the routing signal is the object-model row + the
`object-graph-plan.json` sidecar, not the datasource count.

## 1. What the wire actually says (and does not)

- The `.twb` serializes the graph as `<object-graph>` under the datasource
  (plain or `_.fcp.…`-wrapped): `<objects>` (one per logical table) +
  `<relationships>` whose per-edge key is an `<expression>` tree with two
  end-points.
- **Fact-ness is not on the wire.** `first-end-point` is the authoring-order
  BASE table — "the first table dragged to the canvas" — with no
  fact/dimension semantics. An author who started from a calendar table gives
  you a date-dim base. Electing "the first element carrying a relationship"
  elects the base, routinely a dimension.
- **There is no static join.** Tableau composes per-viz joins at query time.
  Any converter that materializes one fact-anchored `FROM` for LOD/Top-N/
  window helper SQL is approximating; anchoring it on the wrong element is
  the mass-`Dependency not found` field failure (`refs/troubleshooting.md`,
  wrong-fact row).
- Cardinality/referential-integrity are optional end-point hints
  (`unique-key` / `guaranteed-value`); absent means many-to-many +
  some-records-match. **Sigma stores no cardinality on a relationship**
  (fixed many-to-one/one-to-one LEFT join) — hints only ever produce verify
  warnings.

## 2. Safe vs degraded shapes (converter behavior matrix)

All names below are neutral stand-ins (`FACT_VISITS` / `DIM_DATES` /
`DIM_SITES` / `ENTITLEMENTS`).

| Shape | Converter behavior (current vendored bundle) | Signal you see | Operator action |
|---|---|---|---|
| Wired star, fact-first end-points | ✅ SAFE — fact elected by evidence, relationships on the fact, dims as targets | `ℹ Object-model fact election: elected "FACT_VISITS" …` + per-edge `ℹ … wired` | Verify the announced fact; proceed |
| Wired star, **dims as first-end-points** (authoring order) | ✅ SAFE now — election ignores document order (degree → measure columns → not-dim-like name → width; `options.tableRowCounts` tiebreak; `--fact-table` overrides) | Same announcement — the elected name is the thing to check | Verify; override with `--fact-table` if wrong |
| Concatenated dim names (`DIMSITES`-style, no word boundary) | ✅ dim-shaped names excluded from election by the shared `dim_like?` test | Election announcement | Verify |
| Snowflake chains (dim → sub-dim) | ✅ relationship carried by the nearer-the-fact side; fact reaches sub-dims via inherited relationships | Per-edge `ℹ` lines | Verify chain depth in the DM |
| Relationship with **no serialized key** (2020.2-era file) | 🛑 REFUSED — named gap, no guessing | Gap-scan ❌ `disconnected tables` row → orchestrator **exit 11**; `object-graph-plan.json` punch list | Wire each listed pair manually (LEFT from fact/many side), then re-enter (§3) |
| Computed-only key (`DATE([col])=`), non-equality/range key | 🛑 REFUSED — same named-gap class (previously silent inside AND trees) | Same ❌ row + per-pair reason | Add a calc key column or wire manually; re-enter (§3) |
| Mixed physical + unsupported computed conditions | 🛑 REFUSED when any condition would be dropped — the physical subset is a wider join, not a valid approximation | `relationship-coverage.json` entry has `partial:true` / `dropped_conditions`; strict gate stops before POST | Materialize the computed key/predicate or prove and author an exact equivalent; never accept the physical subset alone |
| End-point `object-id` resolving to no object | 🛑 REFUSED — named gap (previously a silent `continue`) | Same ❌ row | Fix/re-export the `.twb`, or wire manually |
| Isolated logical table (no edge touches it) | ⚠ flagged + gap entry | `untouched_objects` in the plan | Decide: relate it or drop it deliberately |
| Single object, zero relationships (legacy-migrated join model) | ✅ flat table, no noodle semantics | No object-model row | Nothing |
| Two facts sharing dims (multi-fact forest, 2024.2+) | ⚠ second forest rooted at its local hub with a multi-fact verify warning | `⚠ … disconnected forest … verify` | Verify both roots; consider splitting DMs |
| `unique-key` hints contradicting the oriented direction | ⚠ aggregated verify warning | `⚠ Tableau performance-option hints …` | Check for a genuinely one-to-many edge — that is not expressible as a Sigma relationship (flip it, use a join element, or refuse) |
| **Entitlement table noodled into the fact** (identity column + datasource filter) | 🔐 detected structurally → `kind:"rls-entitlement-table"` in `security[]` → the loud RLS Port/Customize/Skip checkpoint; **never auto-applied** | `🔐 Entitlement-table RLS pattern DETECTED …` + the RLS gate | Decide Port strategy A/B/C (`refs/security-rls.md`) — an undecided/skipped rule leaves an UNCONSTRAINED live join (restriction gone + fan-out risk) |
| Slash-named column on any table | ⚠ derived-element drop now warned; preflight N2 warns | `⚠ Column "Site /Region" contains "/" …` | Rename the column before wiring anything to it |

Degraded-mode invariants, regression-proven: independent multi-datasource
workbooks are still built MULTI-ELEMENT (never merged, nothing dropped), and
a fully-wired noodle must NOT stop (false-trip budget ≤5%) — both pinned by
`corpus/tableau/objectmodel-noodle` + `scripts/test-object-model-converter.rb`.

## 3. The recommended path when the election went wrong (partner-facing)

You ran the converter, the DM POSTed (or failed to), and the fact is wrong —
mass `Dependency not found`, helper SQL selecting fact measures FROM a dim.

**Patch-then-reenter. Never flatten.**

1. **Do not flatten the N tables into one warehouse view.** It creates a
   permanent warehouse artifact to work around a converter defect, discards
   the star schema Sigma models natively (relationships, lazy joins,
   inherited reachability), and hurts performance and downstream reuse. The
   DM is a one-time cost that amortizes across every dashboard on that
   datasource.
2. Re-run with the announced election corrected: `--fact-table <TRUE_FACT>`
   (the orchestrator threads it into the converter AND the Ruby master
   election). For most cases this alone produces the correct DM.
3. If you must hand-patch instead: patch the emitted `dm-spec.json` — re-point
   the fact element, carry every relationship on the fact (dims as targets,
   key ids swapped with the orientation), rebuild LOD/Top-N/window helper
   `FROM` clauses off the true fact — **keeping every element id and
   controlId the converter minted**.
4. Preflight before any POST: `validate-spec.rb --type datamodel`, and the
   sql-ident gate runs `check-sql-idents.rb` against the fetched warehouse
   catalogs (stop exit 20 on wrong-FROM identifiers; `--skip-sql-ident-gate
   "<reason>"` is a recorded quality waiver).
5. **Re-enter the gated spine**: `ruby scripts/migrate-tableau.rb …
   --reuse-dm <id> --wb-spec <path>`. Do not hand-POST — `--reuse-dm` is the
   documented exit-4 handoff and keeps every parity, anchor, and control gate
   in play.
6. Entitlement tables: handle the RLS decision explicitly (Port A/B/C in
   `refs/security-rls.md`); record the decision so it appears in the report.
   Skipping is loud by design.

## 4. Verification checklist (every object-model run)

- [ ] The `ℹ Object-model fact election` line names the true fact (the
      many-side of every edge, usually the widest/most-measured table).
- [ ] Every Sigma relationship sits ON the fact element (or on the dim for
      snowflake sub-chains) — `object-graph-plan.json` has the expected table.
- [ ] No `⚠ AMBIGUOUS` election warning left unresolved (ties are a
      stop-and-verify, not a guess).
- [ ] Gap-scan ❌ object-model row (if any) fully resolved before `--force`.
- [ ] `security[]` entitlement rules decided (Port/Customize/Skip), never
      silently ingested.
- [ ] Post-POST: the spec readback (`GET /v2/dataModels/{id}/spec`) shows the
      relationships (count, targets, keys) you expected — wrong-fact is
      detectable at migration time, not at the customer's first dashboard.
- [ ] `relationship-coverage.json` is `status:"pass"` with
      `wired == serialized`, no `derived_via:"unwired"`, no `partial:true`, and
      no dropped conditions. The orchestrator and completion gate enforce this;
      a warning-only partial edge is never shippable.
