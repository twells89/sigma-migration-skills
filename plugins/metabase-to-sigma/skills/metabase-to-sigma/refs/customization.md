# Customizing this skill — make it yours

This skill is **agent-driven**: Claude reads these files and follows them. That means
you can fine-tune the migration **by telling Claude what you want, in plain language**
— no code required for most changes. Say it once, ask Claude to remember it, and every
future run applies it.

There are three tiers, from lightest to deepest:

## Tier 1 — Preferences file (plain language, no code)

`~/.metabase-to-sigma/preferences.md` — YOUR standing instructions, written in
natural language. The agent reads it at the start of every migration run (Phase 0)
and honors it throughout. It lives in your home directory, not the repo, so a
`git pull` never overwrites it.

How to create or extend it: just tell Claude. Examples of things customers have
asked for — phrase them however you like:

```markdown
# My metabase-to-sigma preferences

- Always alias bare aggregates in migrated SQL (count(*) AS n_orders) so chart
  labels are readable — never leave a BigQuery f0_ column.
- Use list controls (not segmented) even for small static value lists.
- Our dashboards' "AU" tabs are deprecated — skip them, migrate UK pages only.
- Name migrated workbooks "<Dashboard name> (migrated <date>)" and put
  everything under the "Metabase Migration" folder.
- Date controls should default to last 30 days when Metabase has no default.
- After every workbook posts, export the PNG and show it to me before parity.
```

**The agent's side of the contract** (Claude: this is an instruction to you):
- Read `~/.metabase-to-sigma/preferences.md` at the start of every run, restate the
  active preferences in one line, and apply them.
- Whenever the user corrects your output or expresses a preference mid-run
  ("actually, make the controls list-type", "don't migrate archived cards"),
  **offer to save it to the preferences file** so the next run gets it for free.
- A preference can override any default in SKILL.md EXCEPT the verification gates
  (post-and-readback, parity, visual check) — those are never skipped.

## Tier 2 — Learned formula rules (per-org translation overrides)

`~/.metabase-to-sigma/learned-rules.json` — regex → template rules applied BEFORE
the built-in MBQL translator. This is for **formula translations** specific to your
org (a custom function, a house SQL idiom, a wrapper the converter doesn't know).
The gap-scout flow (SKILL.md "Gaps") proposes these automatically when a card hits
an unmapped expression; you can also ask Claude to write one directly:

> "Whenever you see our `fiscal_quarter(x)` function, translate it to
> `DateTrunc(\"quarter\", DateAdd(\"month\", -1, x))` — save that as a learned rule."

Rules are validated (the scout round-trips them against live Sigma before
persisting) and survive skill updates.

## Tier 3 — Converter changes (code, tests, shared back)

For behavior that's structural — a new chart type, a different DM topology, an
element-naming scheme — ask Claude to change the converter itself:

> "Open converter/metabase-dashboard.ts and make funnel cards convert to a bar
> chart sorted descending instead of a flagged table. Add a fixture test."

Ground rules the agent follows:
- Every converter change gets a fixture + test in `converter/test.ts` (run
  `node --import tsx/esm test.ts` — must stay green).
- Live-verify against your Sigma org with `post-and-readback` before trusting it.
- If the change fixes something broken (not just org-specific taste), please
  share it back — `scripts/escalate-gap.py` opens a GitHub issue on the skill
  repo with the details pre-filled, or open a PR. Your fix becomes everyone's fix.

## What goes where (quick router)

| You want to change… | Tier |
|---|---|
| Naming, folders, which pages/cards to include, control widget choices, layout taste, run etiquette | 1 — preferences.md |
| How a specific formula/function/SQL idiom translates | 2 — learned-rules.json |
| Chart-type mappings, DM structure, new Metabase features, bug fixes | 3 — converter + tests |

When in doubt, just describe what you want — Claude picks the tier and tells you
where it saved it.
