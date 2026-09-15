<!-- Part of the looker-to-sigma workflow — spine: ../SKILL.md. Phase 1.5 — the RLS decision gate; detection, porting, and the loud-skip rule. -->

# Phase 1.5 — RLS decision gate

**Skip this phase entirely when `detect_rls.py` found nothing.** When it DID find RLS, stop ONCE,
here, before POSTing the data model in Phase 2 — make it one explicit, reviewed decision, never an
invisible default.

**The whole flow is scripted and API-driven** — Sigma user attributes are fully API-supported, so
reuse-first, provisioning, and the row filter itself are all done via `apply_sigma_rls.py` (no UI
step). Keep the framing intact (one consolidated gate, opt-in/out, never-silent); only the
mechanics are now concrete.

1. **Reuse-first — check what already exists in Sigma before creating anything (scripted).** The
   customer may have already set RLS up in Sigma; don't duplicate it.
   - **Existing Sigma user attributes** — list them via the API and match by name to the Looker
     `user_attribute`s in the findings. `apply_sigma_rls.py --attr <name>` does this:
     `GET /v2/user-attributes` (read-only, no flags) and prints a **REUSE:** line with the existing
     `userAttributeId` if one matches (case-insensitive), or "no existing attribute" otherwise.
     Reuse a matching attribute rather than creating a new one.

     ```bash
     bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/apply_sigma_rls.py --attr region'
     ```
   - **Existing data models with similar RLS logic** — if a Sigma DM already filters the same
     field by the same attribute (e.g. a previously-migrated explore on the same source), reuse it
     instead of re-implementing the filter.
2. **Pre-fill a recommended plan.** Using the mapping table above, draft the per-finding Sigma
   action (which user attribute, which field, `CurrentUserAttributeText` row filter vs DM/element
   filter vs note) — reusing the existing Sigma attributes/DMs found in step 1. Preview the exact
   row-filter spec for a finding with `apply_sigma_rls.py --attr <name> --field <DisplayName>
   --element-id <denorm-element-id>` (prints the calc-col + element-filter snippet; plan-only).
3. **One consolidated confirm / edit / skip.** Present the full plan and let the user, in a SINGLE
   decision: **confirm** it as drafted, **edit** any mapping (e.g. point at a different existing
   attribute, change a field), or **skip** porting RLS entirely (they may enforce it elsewhere in
   Sigma). No per-rule nagging. `apply_sigma_rls.py` is **plan-only by default** — it mutates ONLY
   when you pass `--create` / `--assign` / `--apply`, so running it through step 1–2 never changes
   anything before the user confirms.
4. **Always record the outcome.** For every finding, note **ported / reused / skipped** in the
   migration summary (Phase 4 output) so any skipped RLS is **visible, never silent** — a reviewer
   can see exactly which Looker restriction was carried over, reused, or deliberately dropped.

Then proceed to Phase 2 and apply the confirmed plan as part of the DM build, via the SAME script:

- **Provision the user attribute** (only if nothing reusable was found in step 1):
  ```bash
  bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/apply_sigma_rls.py \
    --attr region --value West --create'                       # POST /v2/user-attributes
  ```
- **Assign a value to the member(s)** who should be restricted (the value the user attribute
  resolves to per person — assign to the member that the parity query runs AS, or RLS returns 0
  rows):
  ```bash
  bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/apply_sigma_rls.py \
    --attr region --value West --member-id <memberId> --assign'  # POST /v2/user-attributes/{id}/users
  ```
- **Apply the row filter** to the DM element — the verified spec shape (a boolean calc column
  `CurrentUserAttributeText("<attr>") = [<Field>]` + an element `filters` entry
  `{kind:list, mode:include, values:[true]}`):
  ```bash
  bash -c 'eval "$(scripts/get-token.sh)" && python3 scripts/apply_sigma_rls.py \
    --attr region --field Region --element-id <denorm-element-id> \
    --dm-id <dataModelId> --apply'                              # GET → inject → PUT /v2/dataModels/{id}/spec
  ```

Mapping recap: `access_filter` and user-attribute `sql_always_where` → the
`CurrentUserAttributeText("<attr>") = [<Field>]` row filter above; static `sql_always_where` → a
plain DM/element filter; `access_grant` → the recorded note. (Team mode =
`CurrentUserInTeam([...])`; user-email mode = `[Email] = CurrentUserEmail()`.)

> **Proof:** this exact scripted flow was validated live end-to-end 2026-06-10 (a live Looker instance →
> Sigma the demo Sigma org, `demo_thelook` order_fact, `region`/West) with **exact 3-way parity** —
> Looker-restricted == Sigma-restricted == warehouse = **$38,906.82 / 220 rows**.
