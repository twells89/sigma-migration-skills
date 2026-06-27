#!/usr/bin/env python3
"""
Shared telemetry reporter for sigma-migration-skills.
Call at the end of a migration (success OR failure) after the user has been
asked for consent. Writes a marker file so the telemetry gate
(assert-telemetry-ran.rb) can confirm the step was not silently skipped.

Usage:
    # send (consent given):
    python3 scripts/report-telemetry.py --tool tableau-to-sigma --duration 312 --workdir /tmp/run --mode live
    # send, but the migration failed:
    python3 scripts/report-telemetry.py --tool tableau-to-sigma --duration 180 --workdir /tmp/run --failed
    # user declined the ping — record the decision without sending:
    python3 scripts/report-telemetry.py --tool tableau-to-sigma --workdir /tmp/run --declined

Reads SIGMA_BASE_URL and SIGMA_CLIENT_ID from environment (set by get-token.sh).
Prints what it sends; never raises; skips silently if endpoint unreachable.
See https://github.com/twells89/sigma-migration-telemetry/blob/main/TELEMETRY.md
"""

import argparse
import json
import os
import sys

# sigma_telemetry.py sits in a sibling/parent lib/ — its location differs by
# layout: shared/scripts -> ../lib, but once fanned into a plugin it lives at
# scripts/lib/. Add both candidates so the import works either way.
_here = os.path.dirname(os.path.abspath(__file__))
for _cand in (os.path.join(_here, 'lib'), os.path.join(_here, '..', 'lib')):
    if os.path.isdir(_cand):
        sys.path.insert(0, _cand)
from sigma_telemetry import report_migration

MARKER = 'telemetry-sent.json'


def _utc_now():
    # Local import keeps the module importable in sandboxes that stub datetime.
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()


def _write_marker(workdir, record):
    """Record that telemetry was handled (sent or declined). The gate checks
    only for the marker's presence + a valid status — never the network."""
    if not workdir:
        return
    try:
        os.makedirs(workdir, exist_ok=True)
        record['at'] = _utc_now()
        with open(os.path.join(workdir, MARKER), 'w') as f:
            json.dump(record, f, indent=2)
        print(f"  → telemetry marker written ({os.path.join(workdir, MARKER)})")
    except Exception as e:
        print(f"  → could not write telemetry marker: {e}")


parser = argparse.ArgumentParser()
parser.add_argument('--tool',     required=True, help='Migration skill name, e.g. tableau-to-sigma')
parser.add_argument('--duration', type=int, default=0, help='Elapsed seconds (auto-derived from intake.json run_start if omitted)')
parser.add_argument('--failed',   action='store_true', help='Pass if the migration did not reach GREEN')
parser.add_argument('--declined', action='store_true', help='User declined the ping: record the decision, send nothing')
parser.add_argument('--mode',     default='unknown', choices=['live', 'file', 'both', 'unknown'],
                    help='Input mode (auto-derived from intake.json if omitted): live, file, both, or unknown')
parser.add_argument('--failure-stage', default=None,
                    choices=['auth', 'convert', 'spec_post', 'query_validate', 'other'],
                    help='When --failed: coarse stage the migration broke at (no messages or stack traces)')
parser.add_argument('--workdir',  default=None, help='Run directory; the telemetry marker is written here for the gate')
args = parser.parse_args()


def _from_intake(workdir):
    """intake.rb (the front-door step) records run_start + input_mode in
    intake.json. If --duration / --mode were not passed explicitly, derive them
    from it so the agent doesn't have to track elapsed time by hand. Returns
    (duration_seconds_or_None, mode_or_None)."""
    if not workdir:
        return None, None
    try:
        from datetime import datetime, timezone
        intake = json.load(open(os.path.join(workdir, 'intake.json')))
        dur = None
        if intake.get('run_start'):
            started = datetime.fromisoformat(intake['run_start'])
            if started.tzinfo is None:
                started = started.replace(tzinfo=timezone.utc)
            dur = max(0, int((datetime.now(timezone.utc) - started).total_seconds()))
        return dur, intake.get('input_mode')
    except Exception:
        return None, None


_intake_dur, _intake_mode = _from_intake(args.workdir)
duration = args.duration if args.duration else (_intake_dur or 0)
mode = args.mode if args.mode != 'unknown' else (_intake_mode or 'unknown')

if args.declined:
    print("\nTelemetry declined by user — nothing sent.")
    _write_marker(args.workdir, {'status': 'declined', 'tool': args.tool})
    sys.exit(0)

sent = report_migration(
    tool=args.tool,
    sigma_base=os.environ.get('SIGMA_BASE_URL', 'https://aws-api.sigmacomputing.com'),
    client_id=os.environ.get('SIGMA_CLIENT_ID', ''),
    duration_seconds=duration,
    success=not args.failed,
    mode=mode,
    failure_stage=(args.failure_stage if args.failed else None),
)
# Honest marker (handoff FIX 3): "sent" ONLY when the POST actually landed (2xx);
# otherwise "skipped" so the audit record never claims a delivery that failed.
# The gate accepts sent|declined|skipped — telemetry must never block.
_write_marker(args.workdir, {
    'status': 'sent' if sent else 'skipped',
    'tool': args.tool,
    'success': not args.failed,
    'mode': mode,
})
