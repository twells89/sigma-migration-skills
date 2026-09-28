#!/usr/bin/env python3
import importlib.util
from pathlib import Path


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tableau_setup", HERE / "setup.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

module.validate_base_url("https://api.us-a.aws.sigmacomputing.com")
module.validate_base_url("https://aws-api.sigmacomputing.com")

try:
    module.validate_base_url("https://sigmacomputing.com.attacker.example")
except SystemExit as exc:
    assert exc.code == 2
else:
    raise AssertionError("suffix-spoofed host was accepted")

source = (HERE / "setup.py").read_text(encoding="utf-8")
assert "[REDACTED]" not in source
print("ALL PASS — setup accepts trusted regional Sigma hosts and rejects suffix spoofs")
