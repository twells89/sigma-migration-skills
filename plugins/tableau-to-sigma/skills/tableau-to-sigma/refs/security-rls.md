<!-- Part of the tableau-to-sigma workflow — spine: ../SKILL.md. RLS/CLS — full detection + provisioning flow (relocated verbatim from SKILL.md, PLAN-v3 PR-15 diet). -->

# Security: Row- & Column-Level Security (RLS/CLS)

Row/column security is **never silently dropped and never silently ported** — and it is handled by the **skill**, not baked into the converted model. The converter (`convert_tableau_to_sigma`) only **detects and reports** security in `result.security[]`; it does **not** inject it into the data-model spec (a stateless converter can't create Sigma user attributes or assign members, so an injected `CurrentUserAttributeText` filter would fail-closed to 0 rows). This skill provisions + applies it after the model is posted.

**What is detected for Tableau:** calculated fields using `USERNAME()`/`ISMEMBEROF('group')`/`USERATTRIBUTE('attr')` (translated to `CurrentUserEmail()` / `CurrentUserInTeam("group")` / `CurrentUserAttributeText("attr")`). Cross-element (dim-attribute) RLS is reported with a warning to apply on the owning element/derived view. Datasource-level `<filter>` elements are scanned too: a pure expression filter carrying a user function emits a fact-local `kind:"rls"` rule (or an explicit verify-formula rule when it does not auto-translate). And the **table-based entitlement pattern** below is detected **structurally** as `kind:"rls-entitlement-table"`.

## Entitlement-table pattern (`kind:"rls-entitlement-table"`)

Tableau's documented RLS best practice joins an **entitlement table** (one row per user per entitlement, carrying a user-identity column that matches Tableau usernames) into the fact, restricted by a datasource filter (`USERNAME() = [user_email]` kept `True`, or a manual user filter). Detection fires on the **documented structural shape** — a related/joined table carrying a user-identity column, **plus** a user-function datasource filter referencing it, a user-function term inside the relationship expression, or a datasource filter tied to that table. A name match (`RLS`/`ENTITLE`-like) only colors the report text — it can neither fire nor suppress detection on its own, and an identity-shaped column alone (e.g. a customer dim with an email column) never trips.

**Why this checkpoint is blocking:** the converter still wires the entitlement table as an ordinary relationship — until you decide, that edge is an **unconstrained live join**: the Tableau restriction is gone and a multi-entitlement user **fans out** fact rows. Worse than dropping the table. Never ship the model with the rule undecided.

**Port strategies** (Sigma has no first-class entitlement-table object — compose from documented primitives; the rule's `entitlement.strategies` carries the same list):

| | Strategy | Shape | Bounds |
|---|---|---|---|
| A | Materialized gate | Email-mode RLS on the entitlement element (`[identity] = CurrentUserEmail()` + include-`True` filter), then a **join-source element**: fact `inner`-joined to the filtered entitlements | Fail-closed (no rows → no fact rows). Probe `(identity, key)` uniqueness first — a non-unique pair fans out; de-dupe with a distinct projection |
| B | Row-preserving gate | On entitlements: `[Is Me] = ([identity] = CurrentUserEmail())`; on the fact: `Lookup(Sum(If([Is Me], 1, 0)), [key], [key]) > 0` + include-`True` filter; hide both helpers | Fail-closed (null → excluded); no fan-out by construction; one external element per Lookup; large entitlement tables are slow |
| C | De-entitle | Map entitlements onto **user attributes** (single-valued only — refuse multi-valued; no documented delimited-list pattern) or **teams** (group-shaped entitlements + `CurrentUserInTeam`) | Membership sync becomes an ongoing operational obligation |

`apply_sigma_rls.py` **plans** these rules (`--print-plan`, and the batch plan under `--apply`) but **never auto-applies them** — the strategy choice is a design decision. Author the chosen strategy (see the sigma-data-models skill for join-source spec shapes), record the decision in `mission.json`, then re-validate. **Skip stays loud**: skipping leaves the unconstrained join in place — remove the entitlement element/relationship or confirm the exposure explicitly.

**Flow (only runs when `result.security` is non-empty — zero overhead otherwise):**
1. **Convert + post** the data model as usual. Capture the `dataModelId` and the converter's `result.security[]` (write it to `security.json`).
2. **Gate (opt-in/out, default _Port_).** Show a plain-English summary of each detected rule + recommended Sigma mapping, then ask: **Port** (recommended) / **Customize** (review per-rule attribute/team mapping + username-to-email reconciliation) / **Skip** (migrated model shows ALL rows to everyone). Reuse-first: existing Sigma user attributes/teams are matched before creating new ones.
3. **Provision + apply** with the shared engine:
   ```bash
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId>            # plan only (default)
   python3 scripts/apply_sigma_rls.py --from-security security.json --dm-id <dataModelId> --provision --apply
   ```
   The live path uses `scripts/lib/sigma_rest.py`: browser-keychain auth first,
   client-credential fallback, and one refresh/retry on a 401.
   `--provision` creates missing user attributes / teams; `--apply` PATCHes the boolean RLS calc column + fail-closed `filters` entry and the `columnSecurities` (CLS) onto the matching element.
4. **Assign membership.** Assign per-user attribute values / team membership from the source tool's group/role membership (the converter reports the attribute/team names; the values come from the source's user mapping).

**Skip is loud:** opting out leaves the migrated model with NO RLS — all rows visible to everyone. Confirm before skipping.
