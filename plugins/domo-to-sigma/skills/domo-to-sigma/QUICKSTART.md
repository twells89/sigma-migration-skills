# Domo → Sigma — Quickstart

Run from this skill directory. Install/update both marketplace plugins, then
restart Claude Code before migrating so the session cannot keep an old cached
converter:

```text
/plugin marketplace update sigma-migration-skills
/plugin update domo-to-sigma@sigma-migration-skills
/plugin update sigma-authoring@sigma-migration-skills
```

```bash
eval "$(scripts/get-domo-token.sh)"
ruby scripts/migrate-domo.rb \
  --pages <DOMO_PAGE_ID> \
  --workbook-name "<NAME>" \
  --folder-id <SIGMA_SHARED_FOLDER_ID> \
  --source-dashboard-png /path/to/source.png \
  --out /path/to/run
```

`--folder-id` is required. Use a shared folder the customer can browse, not the
API/service account's `My Documents`. A successful run reports plugin version
`0.16.108`, canonical Sigma URL/path, strict parity, and the visual-grade result.
Exit 20 means it is waiting for the required blind visual grade, not complete.
Do not declare success from a workbook URL alone.

For a non-default Sigma app host, set `SIGMA_APP_URL`; the default is
`https://app.sigmacomputing.com`.

Do not paste credentials into the migration prompt. Configure them through the
environment/setup flow, and rotate any secret or developer token exposed in
chat, email, logs, or screenshots.
