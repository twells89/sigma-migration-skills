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

Set `SIGMA_BASE_URL`, `SIGMA_CLIENT_ID`, and `SIGMA_CLIENT_SECRET` or store them
in `~/.sigma-migration/env`.

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
