# Usage telemetry on Metabase — an honest investigation

The universal weak spot of every BI migration assessment is **usage**: which
content is actually viewed, so you can rank a migration shortlist by audience
value and confidently retire dead content. Here is what Metabase does — and
does not — expose, and what to do about it.

## What the OSS REST surface gives you (it's thin)

1. **`view_count` (v50+).** Card and dashboard API responses carry a lifetime
   `view_count` integer. This is the best free signal and the scorer uses it
   directly: `value = 10 · view_count` when present. But it is a **lifetime
   counter** — no time series, no per-user breakdown, no "viewed this quarter".
   A dashboard viewed 5,000 times in 2022 and never since looks identical to a
   daily driver.
2. **`GET /api/activity/recents`.** The "recently viewed" list for the calling
   user — a handful of items, no counts, no history. Useful as a sniff test
   ("is anything here even touched?"), useless for ranking. The discovery
   script does not rank on it.
3. **Pre-v50 OSS: essentially nothing.** No `view_count`, no audit endpoints.
   The scorer falls back to `value = 10 · n_features` (a size proxy), and the
   readout says so plainly — the shortlist is ranked by conversion effort, not
   popularity.

## Where the rich usage data actually lives (Pro/EE)

Metabase Pro/EE ships **"Usage analytics"** — an instance-level analytics
collection (formerly "Audit tools") backed by the app DB's `view_log` /
`audit_log`: views **over time**, **per-user** activity, dashboard/question
usage rankings, unused-content reports. That is exactly the series a migration
ranking wants. It is:

- **Pro/EE only** — not available on OSS at any version.
- Accessed in-product (the Usage analytics collection) — an admin can export
  the relevant questions to CSV in a few clicks.
- Backed by application-DB tables (`view_log`, `audit_log`) that a
  self-hosting admin *can* query directly, but that's unsupported surface —
  prefer the in-product export.

## Recommendation (what the readout tells the user)

> **v50+ instance:** the shortlist is already ranked by `view_count`. Still
> ask the admin for the Pro/EE Usage analytics export (views over time,
> per-user reach) before retiring anything — a lifetime counter can't
> distinguish "popular once" from "popular now".
>
> **Pre-v50 / OSS without view counts:** request a usage export from the
> Metabase admin — either the Pro/EE Usage analytics CSVs, or (self-hosted) a
> read-only query against the app DB's `view_log`. Until then the shortlist is
> ranked by conversion effort, not popularity, and the readout says so.

If/when the admin provides a usage CSV (`item_id, item_type, views,
distinct_users, last_viewed`), the scorer's `value` term can be upgraded to
`views · sqrt(distinct_users)` — the same value formula the Tableau and Qlik
assessments use — without changing anything else in the pipeline.
