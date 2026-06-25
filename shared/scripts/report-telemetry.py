#!/usr/bin/env python3
"""
Shared telemetry reporter for sigma-migration-skills.
Call at the end of a successful (or failed) migration after all gates pass.

Usage:
    python3 scripts/report-telemetry.py --tool tableau-to-sigma --duration 312
    python3 scripts/report-telemetry.py --tool tableau-to-sigma --duration 180 --failed

Reads SIGMA_BASE_URL and SIGMA_CLIENT_ID from environment (set by get-token.sh).
Prints what it sends; never raises; skips silently if endpoint unreachable.
See https://github.com/twells89/sigma-migration-telemetry/blob/main/TELEMETRY.md
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../lib'))
from sigma_telemetry import report_migration

parser = argparse.ArgumentParser()
parser.add_argument('--tool',     required=True, help='Migration skill name, e.g. tableau-to-sigma')
parser.add_argument('--duration', type=int, default=0, help='Elapsed seconds')
parser.add_argument('--failed',   action='store_true', help='Pass if the migration did not reach GREEN')
args = parser.parse_args()

report_migration(
    tool=args.tool,
    sigma_base=os.environ.get('SIGMA_BASE_URL', 'https://aws-api.sigmacomputing.com'),
    client_id=os.environ.get('SIGMA_CLIENT_ID', ''),
    duration_seconds=args.duration,
    success=not args.failed,
)
