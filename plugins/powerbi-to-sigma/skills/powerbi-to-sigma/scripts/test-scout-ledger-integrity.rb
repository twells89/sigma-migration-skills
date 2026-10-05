#!/usr/bin/env ruby
# frozen_string_literal: true
#
# test-scout-ledger-integrity.rb — the gap-scan gate's ScoutGate ledger must not
# trust a bare "validated" status (issue #458).
#
# Field failure: an agent blocked from the sanctioned --force path hand-wrote a
# {"status":"validated"} line into scout-ledger.jsonl for a gap it had only
# reasoned about — never probed against the live Sigma API. ScoutGate.classify
# accepted it and let the run proceed past the gate as if real verification had
# happened. This test proves the integrity fix, mirroring the resolution-EVIDENCE
# (join/lod/agg ledgers) + anchor-immutability-lock (verify-anchors W1.3) patterns:
#   (i)   a genuine scout record (live-probe evidence + signature) → :validated;
#   (ii)  a hand-written bare "validated" line (no evidence, no signature)
#         → NOT :validated (falls to :escalated → the gate still blocks);
#   (iii) an escalated row whose status is flipped to "validated" out of band
#         (signature no longer matches) → NOT :validated;
#   (iv)  a hand-written "validated" line with FORGED evidence but no valid
#         signature → NOT :validated;
#   (v)   a gap with no ledger row at all → :unscouted (unchanged);
#   (vi)  the genuine record round-trips through a JSON read → still :validated;
#   (vii) CROSS-LANGUAGE: in this converter the ledger WRITER is Python
#         (scout-validate.py → lib/scout_gate.py) but the GATE is Ruby
#         (migrate-*.rb → lib/scout_gate.rb#classify). A genuine Python-recorded
#         `validated` row (signed by scout_gate.py) MUST verify under the Ruby
#         gate — otherwise the fix would break the real scout flow.
#   (viii) the Python scout + RLS live transports delegate to sigma_rest.py,
#          preserving valid-token reuse, browser-only auth, proactive age
#          refresh, and exactly one retry after 401.
# Deterministic + offline (no Sigma creds / network).
#
# Usage: ruby scripts/test-scout-ledger-integrity.rb

require 'json'
require 'tmpdir'
require_relative 'lib/scout_gate'

FAILS = []
def check(cond, msg)
  FAILS << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# The evidence shape the genuine live probe records (scout-validate: the real
# workbook id the POST created + a hash of the columns-readback + a probe
# timestamp). Neutral, invented ids — no field/session data.
def genuine_evidence
  { 'workbook_id' => 'wb-abc123', 'response_sha256' => 'a' * 64,
    'phase' => 'columns', 'probed_at' => Time.now.utc.iso8601 }
end

puts 'test-scout-ledger-integrity:'

# (i) genuine scout record → validated -----------------------------------------
Dir.mktmpdir do |d|
  ScoutGate.record(d, gap_id: 'MEASURE_A', feature: 'MEASURE_A',
                      status: 'validated', evidence: genuine_evidence)
  b = ScoutGate.classify(d, ['MEASURE_A'])
  check(b[:validated] == ['MEASURE_A'] && b[:escalated].empty? && b[:unscouted].empty?,
        '(i) genuine scout record (evidence + signature) classifies as :validated')
  check(File.exist?(ScoutGate.key_path(d)), '(i) sanctioned record stamped the per-conversion signing key')
end

# (ii) hand-written bare "validated" line — no evidence, no signature -----------
Dir.mktmpdir do |d|
  File.open(ScoutGate.ledger_path(d), 'a') do |f|
    f.puts(JSON.generate('gap_id' => 'MEASURE_B', 'feature' => 'MEASURE_B',
                         'status' => 'validated', 'at' => Time.now.utc.iso8601))
  end
  b = ScoutGate.classify(d, ['MEASURE_B'])
  check(b[:validated].empty? && b[:escalated] == ['MEASURE_B'],
        '(ii) hand-written bare "validated" is NOT trusted → falls to :escalated (gate blocks)')
end

# (iii) an escalated row's status flipped to "validated" out of band -----------
Dir.mktmpdir do |d|
  ScoutGate.record(d, gap_id: 'MEASURE_C', feature: 'MEASURE_C', status: 'escalated')
  raw = File.read(ScoutGate.ledger_path(d))
  # Flip the SIGNED escalated row to validated (and bolt on plausible evidence);
  # the signature was computed over status 'escalated', so it no longer matches.
  row = JSON.parse(raw.lines.first)
  row['status'] = 'validated'
  row['evidence'] = genuine_evidence
  File.write(ScoutGate.ledger_path(d), JSON.generate(row) + "\n")
  b = ScoutGate.classify(d, ['MEASURE_C'])
  check(b[:validated].empty? && b[:escalated] == ['MEASURE_C'],
        '(iii) escalated→validated status flip breaks the signature → NOT :validated')
end

# (iv) forged evidence but no valid signature ----------------------------------
Dir.mktmpdir do |d|
  # A genuine record for a DIFFERENT gap creates the key file, so the tamperer
  # even has a key present — but cannot produce a matching signature for a row it
  # invents (Digest over the secret it does not sign with).
  ScoutGate.record(d, gap_id: 'OTHER', feature: 'OTHER',
                      status: 'validated', evidence: genuine_evidence)
  File.open(ScoutGate.ledger_path(d), 'a') do |f|
    f.puts(JSON.generate('gap_id' => 'FORGED', 'feature' => 'FORGED', 'status' => 'validated',
                         'at' => Time.now.utc.iso8601, 'evidence' => genuine_evidence,
                         'sig' => 'deadbeef' * 8))
  end
  b = ScoutGate.classify(d, %w[OTHER FORGED])
  check(b[:validated] == ['OTHER'] && b[:escalated] == ['FORGED'],
        '(iv) "validated" with forged evidence + bogus signature → NOT :validated')
end

# (v) no ledger row at all → unscouted (unchanged) -----------------------------
Dir.mktmpdir do |d|
  b = ScoutGate.classify(d, ['NEVER_RAN'])
  check(b[:unscouted] == ['NEVER_RAN'] && b[:validated].empty?,
        '(v) a gap the scout never ran for stays :unscouted')
end

# (vi) genuine record survives a JSON write→read round trip --------------------
Dir.mktmpdir do |d|
  ScoutGate.record(d, gap_id: 'MEASURE_D', feature: 'MEASURE_D',
                      status: 'validated', evidence: genuine_evidence)
  rows = File.readlines(ScoutGate.ledger_path(d)).map { |l| JSON.parse(l) }
  reordered = rows.map { |r| r.keys.sort.each_with_object({}) { |k, h| h[k] = r[k] } }
  File.write(ScoutGate.ledger_path(d), reordered.map { |r| JSON.generate(r) }.join("\n") + "\n")
  b = ScoutGate.classify(d, ['MEASURE_D'])
  check(b[:validated] == ['MEASURE_D'],
        '(vi) genuine validated row survives an honest JSON re-serialization')
end

# (vii) CROSS-LANGUAGE: a genuine Python-recorded validated row is honored by the
# Ruby gate. This converter writes the ledger from Python (scout-validate.py →
# lib/scout_gate.py) and reads it from Ruby (migrate → lib/scout_gate.rb#classify);
# the two sides sign identically, so a real Python-side probe must pass the gate.
PY = %w[python3 python].find { |c| system(c, '--version', out: File::NULL, err: File::NULL) }
if PY.nil?
  puts '  SKIP  (vii) cross-language check — no python3 interpreter found'
else
  Dir.mktmpdir do |d|
    pylib = File.join(__dir__, 'lib')
    code = <<~PY
      import sys
      sys.path.insert(0, #{pylib.dump})
      import scout_gate
      ev = {"workbook_id": "wb-py777", "response_sha256": "e" * 64,
            "phase": "columns", "probed_at": "2026-01-01T00:00:00+00:00"}
      ok = scout_gate.record(#{d.dump}, "PY_MEASURE", "PY_MEASURE", "validated", ev)
      sys.exit(0 if ok else 1)
    PY
    wrote = system(PY, '-c', code)
    b = ScoutGate.classify(d, ['PY_MEASURE'])
    check(wrote && b[:validated] == ['PY_MEASURE'] && b[:escalated].empty?,
          '(vii) genuine Python-recorded (scout_gate.py) validated row is honored by the Ruby gate')
    # And the same Python writer cannot be defeated by a hand-written line either:
    File.open(ScoutGate.ledger_path(d), 'a') do |f|
      f.puts(JSON.generate('gap_id' => 'PY_FORGE', 'feature' => 'PY_FORGE',
                           'status' => 'validated', 'at' => Time.now.utc.iso8601,
                           'evidence' => genuine_evidence))
    end
    b2 = ScoutGate.classify(d, %w[PY_MEASURE PY_FORGE])
    check(b2[:validated] == ['PY_MEASURE'] && b2[:escalated] == ['PY_FORGE'],
          '(vii) a hand-written "validated" beside the Python row still falls to :escalated')
  end
end

# (viii) PYTHON SIGMA AUTH: no credentials or network --------------------------
if PY.nil?
  puts '  SKIP  (viii) Python Sigma auth check — no python3 interpreter found'
else
  scripts = __dir__
  code = <<~PY
    import importlib.util
    import json
    import os
    import sys
    import time

    scripts = #{scripts.dump}
    sys.path.insert(0, os.path.join(scripts, "lib"))
    import sigma_rest

    def load(name, filename):
        spec = importlib.util.spec_from_file_location(name, os.path.join(scripts, filename))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    scout = load("pbi_scout_auth_test", "scout-validate.py")
    rls = load("pbi_rls_auth_test", "apply_sigma_rls.py")
    env_keys = (
        "SIGMA_BASE_URL", "SIGMA_API_TOKEN", "SIGMA_TOKEN_MINTED_AT",
        "SIGMA_AUTH_METHOD", "SIGMA_CLIENT_ID", "SIGMA_CLIENT_SECRET",
        "SIGMA_WORKDIR", "SIGMA_ALLOW_INSECURE_BASE_URL",
    )
    sigma_rest.NEUTRAL_ENV = "/nonexistent/pbi-auth-test-env"
    calls = []
    queue = []
    provider_calls = 0

    def reset(extra=None):
        global calls, queue, provider_calls
        for key in env_keys:
            os.environ.pop(key, None)
        os.environ["SIGMA_BASE_URL"] = "https://api.sigmacomputing.com"
        os.environ.update(extra or {})
        sigma_rest._token_override = None
        sigma_rest._minted_at = None
        sigma_rest._refresh_inflight = False
        sigma_rest._validated_bases.clear()
        calls = []
        queue = []
        provider_calls = 0

    def send(method, url, headers, body, timeout):
        calls.append(dict(method=method, url=url, headers=dict(headers), body=body))
        status, payload = queue.pop(0)
        return sigma_rest._Resp(status, payload)

    def provider(token="browser-token"):
        global provider_calls
        provider_calls += 1
        return {
            "SIGMA_API_TOKEN": token,
            "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(time.time()),
            "SIGMA_AUTH_METHOD": "browser",
        }

    sigma_rest._send = send

    # A valid caller token is reused without invoking any provider.
    reset({"SIGMA_API_TOKEN": "caller-token"})
    queue[:] = [(200, '{"ok":true}')]
    sigma_rest.token_provider_result = lambda: (_ for _ in ()).throw(
        AssertionError("provider called for a valid token")
    )
    assert rls.api("GET", "/v2/test") == {"ok": True}
    assert calls[0]["headers"]["Authorization"] == "Bearer caller-token"

    # Browser-only auth works without client credentials.
    reset()
    queue[:] = [(200, '{"ok":true}')]
    sigma_rest.token_provider_result = provider
    status, body = scout.api("GET", "/v2/test")
    assert status == 200 and json.loads(body) == {"ok": True}
    assert calls[0]["headers"]["Authorization"] == "Bearer browser-token"
    assert provider_calls == 1 and "SIGMA_CLIENT_ID" not in os.environ

    # A known-old token refreshes before the request is sent.
    reset({
        "SIGMA_API_TOKEN": "known-old",
        "SIGMA_TOKEN_MINTED_AT": sigma_rest._iso_z(
            time.time() - sigma_rest.TOKEN_TTL_SECONDS - 1
        ),
    })
    queue[:] = [(200, '{"ok":true}')]
    sigma_rest.token_provider_result = lambda: provider("age-refreshed")
    assert rls.api("GET", "/v2/test") == {"ok": True}
    assert calls[0]["headers"]["Authorization"] == "Bearer age-refreshed"
    assert provider_calls == 1

    # One 401 refreshes through the browser provider and retries once.
    reset({"SIGMA_API_TOKEN": "expired-token"})
    queue[:] = [(401, "expired"), (200, '{"ok":true}')]
    sigma_rest.token_provider_result = lambda: provider("retry-token")
    status, body = scout.api("GET", "/v2/test")
    assert status == 200 and json.loads(body) == {"ok": True}
    assert [c["headers"]["Authorization"] for c in calls] == [
        "Bearer expired-token", "Bearer retry-token"
    ]
    assert provider_calls == 1

    # A second 401 is surfaced: no second refresh and no third request.
    reset({"SIGMA_API_TOKEN": "expired-token"})
    queue[:] = [(401, "expired"), (401, "still unauthorized")]
    sigma_rest.token_provider_result = lambda: provider("retry-token")
    status, body = scout.api("GET", "/v2/test")
    assert status == 401 and "still unauthorized" in body
    assert len(calls) == 2 and provider_calls == 1

    # Wiring guard: neither plugin-local Python live path owns a static bearer.
    for filename in ("scout-validate.py", "apply_sigma_rls.py"):
        source = open(os.path.join(scripts, filename), encoding="utf-8").read()
        assert "import sigma_rest" in source and "sigma_rest.request(" in source
        assert 'os.environ["SIGMA_API_TOKEN"]' not in source
        assert "urllib.request" not in source
        assert '"Authorization": "Bearer "' not in source
  PY
  auth_ok = system(PY, '-c', code)
  check(auth_ok,
        '(viii) Python scout/RLS transports reuse, age-refresh, browser-refresh, and retry one 401')
end

puts
if FAILS.empty?
  puts 'ALL PASS — a hand-written/forged "validated" cannot defeat the gap-scan gate'
  exit 0
else
  puts "#{FAILS.length} FAILED"
  exit 1
end
