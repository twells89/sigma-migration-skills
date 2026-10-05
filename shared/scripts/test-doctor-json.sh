#!/usr/bin/env bash
# Credential-free doctor auth/JSON regression tests.
# Run: bash scripts/test-doctor-json.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() {
  if [ "$1" -eq 0 ]; then
    printf '  PASS  %s\n' "$2"
  else
    printf '  FAIL  %s\n' "$2"
    fails=$((fails+1))
  fi
}

COMMON=(SIGMA_SKIP_VERSION_CHECK=1 SIGMA_SKIP_CRED_SMOKE=1)
BASE=https://api.sigmacomputing.com

echo "Part A — missing auth fails closed and doctor.json remains secret-free"
mkdir -p "$TMP/home-missing"
env HOME="$TMP/home-missing" "${COMMON[@]}" \
  SIGMA_BASE_URL= SIGMA_API_TOKEN= SIGMA_CLIENT_ID= SIGMA_CLIENT_SECRET= \
  bash "$HERE/doctor.sh" --workdir "$TMP/missing" >"$TMP/missing.out" 2>&1
rc=$?
[ "$rc" -ne 0 ]; check $? "missing Sigma auth exits non-zero"
grep -q 'no usable Sigma authentication found (REQUIRED' "$TMP/missing.out"
check $? "failure names the usable-auth requirement"
grep -q 'browser-login.sh' "$TMP/missing.out"
check $? "remediation recommends explicit browser login"
grep -Eq 'setup\.(rb|py)|SIGMA_CLIENT_ID' "$TMP/missing.out"
check $? "remediation retains unattended client fallback"
python3 - "$TMP/missing/doctor.json" "$rc" <<'PY'
import datetime, json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rc = int(sys.argv[2])
required = {
    "os", "shell", "runtimes", "versions", "runtime_profile",
    "sandbox_hint", "cred_smoke", "sigma_auth_method",
    "hyperapi_present", "skill_sha", "behind_count", "days_since_commit",
    "agent_vision", "model_hint", "generated_at", "pass", "failures",
}
assert required <= set(d), required - set(d)
assert set(d["cred_smoke"]) == {"sigma", "tableau", "looker"}
assert d["cred_smoke"]["sigma"] == "skipped"
assert d["sigma_auth_method"] == "none"
assert d["pass"] == (rc == 0) == (not d["failures"])
assert "SIGMA_API_TOKEN" not in d and "SIGMA_CLIENT_SECRET" not in d
datetime.datetime.strptime(d["generated_at"], "%Y-%m-%dT%H:%M:%SZ")
PY
check $? "doctor.json records missing status/method without credential fields"

echo "Part B — client credentials, current tokens, and keychain-only sessions qualify"
env HOME="$TMP/home-missing" "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_CLIENT_ID=client-id SIGMA_CLIENT_SECRET=client-secret \
  bash "$HERE/doctor.sh" --workdir "$TMP/client" >"$TMP/client.out" 2>&1
python3 - "$TMP/client/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["cred_smoke"]["sigma"] == "skipped", d
assert d["sigma_auth_method"] == "client-credentials", d
assert not any("Sigma authentication" in value for value in d["failures"])
PY
check $? "client configuration records skipped/client-credentials"

mkdir -p "$TMP/token-keychain-probe"
cat > "$TMP/token-keychain-probe/secret-tool" <<SH
#!/bin/sh
printf probed > "$TMP/token-keychain-probed"
exit 1
SH
chmod +x "$TMP/token-keychain-probe/secret-tool"
env HOME="$TMP/home-missing" PATH="$TMP/token-keychain-probe:$PATH" \
  "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_API_TOKEN=current-secret-token SIGMA_CLIENT_ID= SIGMA_CLIENT_SECRET= \
  bash "$HERE/doctor.sh" --workdir "$TMP/token" >"$TMP/token.out" 2>&1
python3 - "$TMP/token/doctor.json" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
d = json.loads(raw)
assert d["cred_smoke"]["sigma"] == "skipped", d
assert d["sigma_auth_method"] == "api-token", d
assert "current-secret-token" not in raw
PY
check $? "current token records skipped/api-token without the token"
[ ! -e "$TMP/token-keychain-probed" ]
check $? "current token is accepted without probing the keychain"

mkdir -p "$TMP/home-browser/.sigma-migration" "$TMP/keychain-bin"
printf "export SIGMA_BASE_URL='%s'\n" "$BASE" > "$TMP/home-browser/.sigma-migration/env"
cat > "$TMP/keychain-bin/secret-tool" <<'SH'
#!/bin/sh
[ "$1" = lookup ] && [ "$2 $3 $4 $5" = "service sigma-api key refresh-token" ]
SH
chmod +x "$TMP/keychain-bin/secret-tool"
env HOME="$TMP/home-browser" PATH="$TMP/keychain-bin:$PATH" "${COMMON[@]}" \
  bash "$HERE/doctor.sh" --workdir "$TMP/browser" >"$TMP/browser.out" 2>&1
python3 - "$TMP/browser/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["cred_smoke"]["sigma"] == "skipped", d
assert d["sigma_auth_method"] == "browser", d
assert not any("Sigma authentication" in value for value in d["failures"])
PY
check $? "keychain-only session + base URL records skipped/browser"

echo "Part C — live smoke is GET /v2/whoami through sigma_rest"
mkdir -p "$TMP/fixture/scripts/lib" "$TMP/home-live"
cp "$HERE/doctor.sh" "$TMP/fixture/scripts/doctor.sh"
cat > "$TMP/fixture/scripts/lib/sigma_rest.rb" <<'RUBY'
module Sigma
  def self.request(method, path)
    File.write(ENV.fetch('SIGMA_DOCTOR_SMOKE_MARKER'), "#{method} #{path}")
    ENV['SIGMA_AUTH_METHOD'] = 'browser'
    {}
  end

  def self.refresh_token!
    raise 'doctor must verify through request, not direct mint'
  end
end
RUBY
env HOME="$TMP/home-live" SIGMA_SKIP_VERSION_CHECK=1 SIGMA_SKIP_CRED_SMOKE= \
  SIGMA_BASE_URL="$BASE" SIGMA_API_TOKEN=expired-secret-token \
  SIGMA_DOCTOR_SMOKE_MARKER="$TMP/smoke.marker" \
  bash "$TMP/fixture/scripts/doctor.sh" --workdir "$TMP/live" >"$TMP/live.out" 2>&1
rc=$?
[ "$rc" -eq 0 ]; check $? "fixture live smoke passes"
[ "$(cat "$TMP/smoke.marker" 2>/dev/null)" = "get /v2/whoami" ]
check $? "shared REST request receives GET /v2/whoami"
python3 - "$TMP/live/doctor.json" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
d = json.loads(raw)
assert d["cred_smoke"]["sigma"] == "pass", d
assert d["sigma_auth_method"] == "browser", d
assert "expired-secret-token" not in raw
PY
check $? "live doctor.json records pass/browser without the token"

echo "Part D — workdir variants and no-git installs keep the JSON contract"
env HOME="$TMP/home-missing" "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_API_TOKEN=current-token DOCTOR_WORKDIR="$TMP/env-workdir" \
  bash "$HERE/doctor.sh" >/dev/null 2>&1
python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' \
  "$TMP/env-workdir/doctor.json"
check $? "DOCTOR_WORKDIR writes valid doctor.json"

mkdir -p "$TMP/plain"
(cd "$TMP/plain" && env HOME="$TMP/home-missing" "${COMMON[@]}" \
  SIGMA_BASE_URL="$BASE" SIGMA_API_TOKEN=current-token \
  bash "$HERE/doctor.sh" >/dev/null 2>&1)
[ ! -e "$TMP/plain/doctor.json" ]
check $? "plain doctor run does not write doctor.json into the CWD"

mkdir -p "$TMP/nogit"
cp "$HERE/doctor.sh" "$TMP/nogit/doctor.sh"
env HOME="$TMP/home-missing" "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_API_TOKEN=current-token \
  bash "$TMP/nogit/doctor.sh" --workdir "$TMP/nogit-work" >/dev/null 2>&1
python3 - "$TMP/nogit-work/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["skill_sha"] == "unknown (no git — mirror/plugin install)", d
assert d["days_since_commit"] is None, d
PY
check $? "no-git install records the unknown-build fallback"

echo "Part E — an explicitly certified Python profile still waives Ruby"
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
env HOME="$TMP/home-missing" "${COMMON[@]}" SIGMA_BASE_URL="$BASE" \
  SIGMA_API_TOKEN=current-token \
  bash "$TMP/profile/scripts/doctor.sh" --runtime-profile python \
  --workdir "$TMP/profile-work" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ]; check $? "doctor accepts a certified Python profile"
python3 - "$TMP/profile-work/doctor.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
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
