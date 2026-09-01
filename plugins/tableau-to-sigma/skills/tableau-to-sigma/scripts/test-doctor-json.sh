#!/usr/bin/env bash
# Offline test for doctor.sh's doctor.json emission (2026-07-08).
#
# Deterministic + offline-safe: doctor.sh's drift check tolerates no network
# (behind_count -> null) and GIT_TERMINAL_PROMPT=0 prevents credential hangs.
# Verifies:
#   Part A — --workdir writes <workdir>/doctor.json; valid JSON, full schema;
#            pass mirrors the exit code
#   Part B — DOCTOR_WORKDIR env variant works
#   Part C — a plain run (no workdir) writes no doctor.json into the CWD and
#            still runs the standard checks (hyperapi/drift print always —
#            upstream doctor design; the stable copy goes to ~/.sigma-migration)
#
# Usage:  bash scripts/test-doctor-json.sh
set -u

# Hermetic: never run the live token-mint smokes from the test (no network),
# and make cred presence deterministic per part via HOME/env overrides.
export SIGMA_SKIP_CRED_SMOKE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # rc message
  if [ "$1" -eq 0 ]; then printf '  PASS  %s\n' "$2"; else printf '  FAIL  %s\n' "$2"; fails=$((fails+1)); fi
}

echo "Part A — --workdir writes a valid, schema-complete doctor.json"
bash "$HERE/doctor.sh" --workdir "$TMP/w1" >"$TMP/w1.out" 2>&1
rc_a=$?
[ -f "$TMP/w1/doctor.json" ]; check $? "doctor.json exists under --workdir"
python3 - "$TMP/w1/doctor.json" "$rc_a" <<'PY'
import datetime, json, sys
d = json.load(open(sys.argv[1]))
rc = int(sys.argv[2])
req = ["os", "shell", "runtimes", "hyperapi_present", "skill_sha", "behind_count",
       "days_since_commit", "agent_vision", "model_hint", "pass", "failures",
       "generated_at", "cred_smoke", "runtime_profile"]
missing = [k for k in req if k not in d]
assert not missing, f"missing keys: {missing}"
assert d["days_since_commit"] is None or isinstance(d["days_since_commit"], int), d["days_since_commit"]
# This test runs from the git checkout, so the build stamp must be concrete:
# a real short SHA and a non-negative integer age.
import re
assert re.fullmatch(r"[0-9a-f]{7,}", d["skill_sha"]), d["skill_sha"]
assert isinstance(d["days_since_commit"], int) and d["days_since_commit"] >= 0, d["days_since_commit"]
assert d["shell"] == "bash", d["shell"]
for r in ("ruby", "python", "node", "bash"):
    assert r in d["runtimes"], f"runtimes missing {r}"
    assert isinstance(d["runtimes"][r], bool), d["runtimes"][r]
for r in ("ruby", "python", "node"):
    assert isinstance(d["versions"][r], str), d["versions"][r]
assert isinstance(d["hyperapi_present"], bool)
assert d["skill_sha"] is None or isinstance(d["skill_sha"], str)
assert d["behind_count"] is None or isinstance(d["behind_count"], int)
assert isinstance(d["agent_vision"], bool), \
    "agent_vision is caller-asserted via SIGMA_AGENT_VISION (default false)"
assert isinstance(d["model_hint"], str)
assert isinstance(d["sandbox_hint"], str)
assert set(d["cred_smoke"]) == {"sigma", "tableau", "looker"}, d["cred_smoke"]
assert all(v in ("pass", "fallback", "fail", "skipped") for v in d["cred_smoke"].values()), d["cred_smoke"]
assert isinstance(d["pass"], bool) and isinstance(d["failures"], list)
assert all(isinstance(f, str) for f in d["failures"])
rp = d["runtime_profile"]
assert set(rp) == {"requested", "selected", "required_runtimes", "fallback_reason"}, rp
assert rp["requested"] in ("auto", "ruby", "python")
assert isinstance(rp["selected"], str)
assert isinstance(rp["required_runtimes"], list)
assert isinstance(rp["fallback_reason"], str)
assert d["pass"] == (rc == 0), f"pass={d['pass']} but doctor exited {rc}"
assert d["pass"] == (len(d["failures"]) == 0)
datetime.datetime.strptime(d["generated_at"], "%Y-%m-%dT%H:%M:%SZ")
PY
check $? "doctor.json parses with the full schema; pass mirrors exit code $rc_a"

echo "Part B — DOCTOR_WORKDIR env variant"
DOCTOR_WORKDIR="$TMP/w2" bash "$HERE/doctor.sh" >/dev/null 2>&1
[ -f "$TMP/w2/doctor.json" ]; check $? "doctor.json written via DOCTOR_WORKDIR"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/w2/doctor.json" 2>/dev/null
check $? "DOCTOR_WORKDIR doctor.json is valid JSON"

echo "Part C — plain run writes no doctor.json into the CWD; standard checks still print"
mkdir -p "$TMP/plain" && cd "$TMP/plain"
bash "$HERE/doctor.sh" >"$TMP/plain.out" 2>&1
[ ! -e "$TMP/plain/doctor.json" ]; check $? "no doctor.json written into the CWD without a workdir"
grep -q 'tableauhyperapi' "$TMP/plain.out"
check $? "hyperapi check prints in plain mode (standard check, upstream doctor design)"
grep -q '^Summary: ' "$TMP/plain.out"; check $? "plain output still ends with the Summary line"

echo "Part D — fail-closed Sigma cred check (no creds anywhere => REQUIRED failure)"
mkdir -p "$TMP/nohome"
HOME="$TMP/nohome" SIGMA_API_TOKEN= SIGMA_CLIENT_ID= SIGMA_CLIENT_SECRET= \
  bash "$HERE/doctor.sh" --workdir "$TMP/w3" >"$TMP/w3.out" 2>&1
rc_d=$?
[ "$rc_d" -ne 0 ]; check $? "doctor exits non-zero when no Sigma creds resolve (got $rc_d)"
grep -q 'no Sigma credentials found (REQUIRED' "$TMP/w3.out"
check $? "cred failure names the REQUIRED promotion"
grep -Eq 'setup\.(rb|py)|Export SIGMA_CLIENT_ID' "$TMP/w3.out"
check $? "cred failure prints profile-appropriate credential remediation"
python3 - "$TMP/w3/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["pass"] is False
assert any("Sigma credentials" in f for f in d["failures"]), d["failures"]
assert d["cred_smoke"]["sigma"] == "skipped", d["cred_smoke"]
PY
check $? "doctor.json records the cred failure + cred_smoke.sigma=skipped"

echo "Part E — creds present + SIGMA_SKIP_CRED_SMOKE => ok, smoke recorded as skipped"
HOME="$TMP/nohome" SIGMA_CLIENT_ID=id-test SIGMA_CLIENT_SECRET=sec-test \
  bash "$HERE/doctor.sh" --workdir "$TMP/w4" >"$TMP/w4.out" 2>&1
grep -q 'live token-mint smoke SKIPPED' "$TMP/w4.out"
check $? "smoke-skip is printed when SIGMA_SKIP_CRED_SMOKE is set"
python3 - "$TMP/w4/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert not any("Sigma credentials" in f for f in d["failures"]), d["failures"]
assert d["cred_smoke"]["sigma"] == "skipped", d["cred_smoke"]
PY
check $? "no Sigma cred failure when env creds are present; cred_smoke.sigma=skipped"

echo "Part F — no-git install stamps the unknown build SHA (mirror/plugin fallback)"
mkdir -p "$TMP/nogit"
cp "$HERE/doctor.sh" "$TMP/nogit/doctor.sh"
HOME="$TMP/nohome" SIGMA_CLIENT_ID=id-test SIGMA_CLIENT_SECRET=sec-test \
  bash "$TMP/nogit/doctor.sh" --workdir "$TMP/w5" >"$TMP/w5.out" 2>&1
grep -q 'unknown (no git — mirror/plugin install)' "$TMP/w5.out"
check $? "no-git run WARNs with the unknown-build fallback"
python3 - "$TMP/w5/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["skill_sha"] == "unknown (no git — mirror/plugin install)", d["skill_sha"]
assert d["days_since_commit"] is None, d["days_since_commit"]
PY
check $? "doctor.json records the unknown skill_sha + null days_since_commit"

echo "Part G — an explicitly certified Python profile does not require Ruby"
mkdir -p "$TMP/profile/scripts"
cp "$HERE/doctor.sh" "$TMP/profile/scripts/doctor.sh"
cp "$HERE/runtime_profile.py" "$TMP/profile/scripts/runtime_profile.py"
: > "$TMP/profile/scripts/migrate.py"
cat > "$TMP/profile/runtime-capabilities.json" <<'JSON'
{
  "schemaVersion": 1,
  "skill": "doctor-profile-fixture",
  "profiles": {
    "ruby": {
      "status": "supported",
      "requiredRuntimes": ["ruby", "python", "node", "bash"],
      "entrypoint": ["ruby", "scripts/migrate.rb"]
    },
    "python": {
      "status": "supported",
      "requiredRuntimes": ["python", "node", "bash"],
      "entrypoint": ["python", "scripts/migrate.py"]
    }
  }
}
JSON
HOME="$TMP/nohome" SIGMA_CLIENT_ID=id-test SIGMA_CLIENT_SECRET=sec-test \
  bash "$TMP/profile/scripts/doctor.sh" --runtime-profile python \
  --workdir "$TMP/w6" >"$TMP/w6.out" 2>&1
rc_g=$?
check "$rc_g" "doctor accepts an explicitly certified Python profile"
python3 - "$TMP/w6/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rp = d["runtime_profile"]
assert rp["requested"] == "python", rp
assert rp["selected"] == "python", rp
assert "ruby" not in rp["required_runtimes"], rp
assert d["pass"] is True, d["failures"]
PY
check $? "doctor.json records Python selection without a Ruby requirement"

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails FAILURE(S)"
  exit 1
fi
echo "ALL PASS"
