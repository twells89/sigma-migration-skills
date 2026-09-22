"""Pure decision logic for the runtime control-flip gate."""

from __future__ import annotations

from typing import Any


def decide(probe_rc: int, results: Any) -> tuple[str, dict[str, list[Any]]]:
    rows = results if isinstance(results, list) else []
    passes = [row for row in rows if row.get("result") == "PASS"]
    failures = [row for row in rows if row.get("result") == "FAIL"]
    skips = [row for row in rows if row.get("result") == "SKIP"]
    info = {
        "passes": [row.get("control") for row in passes],
        "fails": [(row.get("control"), row.get("note")) for row in failures],
        "skips": [(row.get("control"), row.get("note")) for row in skips],
    }
    if probe_rc == 1:
        return ("fail" if failures else "error"), info
    if probe_rc == 0:
        return ("ok" if passes else "advisory"), info
    if probe_rc == 2:
        return "advisory", info
    return "error", info


def derive_rc(results: Any) -> int:
    rows = results if isinstance(results, list) else []
    verdicts = [row.get("result") for row in rows]
    if "FAIL" in verdicts:
        return 1
    if "PASS" not in verdicts:
        return 2
    return 0
