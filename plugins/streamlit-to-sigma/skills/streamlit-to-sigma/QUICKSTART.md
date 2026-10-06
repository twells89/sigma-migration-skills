# Streamlit → Sigma — quickstart

Run from this skill directory.

## Offline

```bash
python3 scripts/streamlit-convert.py fixtures/simple-retail \
  --connection connection-placeholder \
  --folder folder-placeholder \
  --name "Retail Fixture" \
  --out-dir /tmp/streamlit-retail
```

Review:

```bash
python3 -m json.tool /tmp/streamlit-retail/streamlit-ir.json
python3 -m json.tool /tmp/streamlit-retail/gaps.json
python3 -m json.tool /tmp/streamlit-retail/wb-spec.json
```

## Live

Prefer a one-time browser login:

```bash
export SIGMA_BASE_URL='https://<your-published-sigma-api-host>'
eval "$(bash scripts/browser-login.sh)"
```

The refresh session stays in the OS keychain; later runs reuse it without
opening a browser. For unattended hosts, set `SIGMA_BASE_URL`,
`SIGMA_CLIENT_ID`, and `SIGMA_CLIENT_SECRET` (directly or in
`~/.sigma-migration/env`). A valid pre-minted `SIGMA_API_TOKEN` is also reused.
The live orchestrator proactively refreshes known-stale tokens and refreshes
once on a 401 before retrying the request.

Run the reuse check:

```bash
ruby scripts/find-or-pick-dm.rb \
  --workbook-signature /tmp/streamlit-retail/source-signature.json
```

Then post with an explicit decision:

```bash
python3 scripts/migrate-streamlit.py /path/to/project \
  --connection <connection-id> \
  --name "Retail Dashboard" \
  --reuse-decision custom-sql \
  --ack-security \
  --post \
  --out-dir /tmp/retail-live
```

The workbook remains incomplete until warehouse, control, and PNG parity
evidence turns `/tmp/retail-live/parity-final.json` GREEN.
