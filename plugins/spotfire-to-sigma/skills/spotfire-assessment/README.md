# spotfire-assessment

Offline-complete, read-only Spotfire → Sigma migration assessment.

```bash
bash run-offline.sh
```

The command runs full-manifest and Library-metadata fixtures plus unit tests.
No credentials or network are used.

Local customer exports:

```bash
python3 scripts/assess.py --manifest export.json --out /tmp/spotfire-assessment
python3 scripts/assess.py --inventory inventory.json --out /tmp/spotfire-assessment
```

Live Spotfire 14+ Library REST API v2 is implemented but **LIVE-UNVALIDATED**:

```bash
SPOTFIRE_BASE_URL=https://spotfire.example \
SPOTFIRE_ACCESS_TOKEN=... \
python3 scripts/assess.py --server-version 14.6 --out /tmp/spotfire-assessment
```

Read `SKILL.md` for the workflow, `refs/` for evidence/scoring/API contracts,
and `PRIVACY.md` before customer use.
