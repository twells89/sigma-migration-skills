#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for the step-0 fail-closed CREDENTIAL gate (2026-07-09).
#
# A harness that does not auto-load ~/.claude/settings.json (Coco, Cursor, plain
# shell) reaches the first Sigma call with no creds and dies with an opaque auth
# error a low-context agent improvises around. migrate-tableau.rb now resolves
# caller tokens, browser-keychain sessions, or client credentials at step 0 and
# STOPS with both browser and unattended remediation when none are present.
#
# This drives the orchestrator with HOME pointed at an empty tmp dir (so
# ~/.sigma-migration/env cannot resolve) and the cred env vars cleared, and
# asserts it aborts AT the gate (before any network) with the actionable message.
# The doctor gate is waived so the run reaches the cred gate deterministically.
#
# Usage: ruby scripts/test-cred-gate.rb

require 'tmpdir'
require 'fileutils'
DIR = __dir__
MT  = File.join(DIR, 'migrate-tableau.rb')
fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}" end

# Run with a hard timeout+kill: cases that PASS the cred gate proceed toward
# discovery (network) and must not hang the test — we only need the early output
# to confirm the cred abort did/didn't fire.
# NB: extra_env is a plain trailing positional hash (NOT a keyword param). A `timeout:`
# keyword here would make Ruby 3 route callers' inline `'KEY' => val` hashes to keywords
# → "unknown keyword" (green on Ruby 2.6's old coercion, red on CI's Ruby 3). Keep it
# positional so `run_no_creds(mt, home, work, 'K' => 'v')` works on both.
def run_no_creds(mt, home, work, extra_env = {})
  timeout = 20
  env = {
    'HOME' => home, 'SIGMA_SKIP_DOCTOR_GATE' => 'test',
    'SIGMA_BASE_URL' => nil, 'SIGMA_AUTH_MODE' => nil,
    'SIGMA_API_TOKEN' => nil, 'SIGMA_CLIENT_ID' => nil,
    'SIGMA_CLIENT_SECRET' => nil, 'SIGMA_TOKEN_MINTED_AT' => nil,
    'SIGMA_SKIP_CRED_GATE' => nil,
    # Clear Tableau creds too so cases abort at a gate (no network) and the
    # Tableau gate is exercised hermetically.
    'TABLEAU_PAT_NAME' => nil, 'TABLEAU_PAT_SECRET' => nil,
    'SIGMA_SKIP_TABLEAU_GATE' => nil, 'SIGMA_TABLEAU_VIA_MCP' => nil
  }.merge(extra_env)
  cmd = ['ruby', mt, '--workbook-id', 'wb-x', '--connection', 'conn-x', '--out', work]
  io = IO.popen(env, cmd, err: %i[child out])
  pid = io.pid
  out = +''
  begin
    reader = Thread.new { out << io.read.to_s }
    killed = reader.join(timeout).nil?
    if killed
      Process.kill('KILL', pid) rescue nil
      reader.join(2)
    end
    Process.wait(pid) rescue nil
  ensure
    io.close rescue nil
  end
  [$?&.exitstatus, out]
end

Dir.mktmpdir do |home|
  Dir.mktmpdir do |work|
    # (1) No creds anywhere => abort at the gate with the remediation.
    code, out = run_no_creds(MT, home, work)
    check(code != 0, "no creds => nonzero exit (got #{code})", fails)
    check(out.include?('no usable Sigma authentication'), 'prints the fail-closed auth message', fails)
    check(out.include?('scripts/browser-login.sh'), 'names the preferred browser-login remediation', fails)
    check(out.include?('SIGMA_CLIENT_ID') && out.include?('scripts/setup.rb'),
          'names the unattended client-credential fallback', fails)

    # (2) Waiver env set => does NOT abort on creds (proceeds past the gate).
    code, out = run_no_creds(MT, home, work, 'SIGMA_SKIP_CRED_GATE' => 'offline-test')
    check(!out.include?('no usable Sigma authentication'),
          'SIGMA_SKIP_CRED_GATE waives the fail-closed abort', fails)

    # (3) Client creds present in env => passes the SIGMA cred gate (no Sigma abort).
    code, out = run_no_creds(MT, home, work,
                             'SIGMA_CLIENT_ID' => 'id-123', 'SIGMA_CLIENT_SECRET' => 'secret-456')
    check(!out.include?('no usable Sigma authentication'),
          'env client creds satisfy the Sigma gate', fails)

    # (4) Browser refresh state lives in the OS keychain, not the neutral env
    # file. A base URL + keychain-only session must pass the Sigma gate.
    keychain_bin = File.join(home, 'keychain-bin')
    FileUtils.mkdir_p(keychain_bin)
    secret_tool = File.join(keychain_bin, 'secret-tool')
    File.write(secret_tool, <<~SH)
      #!/bin/sh
      [ "$1 $2 $3 $4 $5" = "lookup service sigma-api key refresh-token" ]
    SH
    FileUtils.chmod(0o755, secret_tool)
    code, out = run_no_creds(
      MT, home, work,
      'PATH' => "#{keychain_bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}",
      'SIGMA_BASE_URL' => 'https://api.sigmacomputing.com'
    )
    check(!out.include?('no usable Sigma authentication'),
          'keychain-only browser session + base URL satisfy the Sigma gate', fails)
    check(out.include?('no Tableau credentials resolvable'),
          'browser-auth case reaches the separate Tableau credential gate', fails)

    # ---- Tableau gate (reached once the Sigma gate is satisfied) --------------
    sigma = { 'SIGMA_CLIENT_ID' => 'id-123', 'SIGMA_CLIENT_SECRET' => 'secret-456' }

    # (5) Sigma ok, Tableau absent, fresh discovery => Tableau abort + remediation.
    code, out = run_no_creds(MT, home, work, sigma)
    check(out.include?('no Tableau credentials resolvable'), 'Tableau gate fires when PAT absent', fails)
    check(out.include?('setup-tableau.rb'), 'names the setup-tableau.rb remediation', fails)

    # (6) SIGMA_TABLEAU_VIA_MCP=1 => Tableau gate skipped (MCP-driven discovery).
    code, out = run_no_creds(MT, home, work, sigma.merge('SIGMA_TABLEAU_VIA_MCP' => '1'))
    check(!out.include?('no Tableau credentials resolvable'), 'SIGMA_TABLEAU_VIA_MCP=1 skips the Tableau gate', fails)

    # (7) discovery-stamp present (reuse) => Tableau gate skipped.
    File.write(File.join(work, 'discovery-stamp.json'), '{}')
    code, out = run_no_creds(MT, home, work, sigma)
    check(!out.include?('no Tableau credentials resolvable'), 'reused discovery (stamp present) skips the Tableau gate', fails)
    stamp = File.join(work, 'discovery-stamp.json')
    File.delete(stamp) if File.exist?(stamp)

    # (8) Tableau PAT present in env => Tableau gate passes. SIGMA_SKIP_CRED_SMOKE
    #     bypasses the new live sign-in preflight so this stays a pure presence-gate test.
    code, out = run_no_creds(MT, home, work,
                             sigma.merge('TABLEAU_PAT_NAME' => 'pat', 'TABLEAU_PAT_SECRET' => 'sec',
                                         'SIGMA_SKIP_CRED_SMOKE' => 'offline-test'))
    check(!out.include?('no Tableau credentials resolvable'), 'env Tableau PAT satisfies the gate', fails)

    # (9) PAT present but NO server/site and NO skip => stale-PAT preflight fires and
    #     aborts. refresh_token! raises 'TABLEAU_SITE_CONTENT_URL not set' before any
    #     socket, so this is fully offline (no network, no lockout risk).
    code, out = run_no_creds(MT, home, work,
                             sigma.merge('TABLEAU_PAT_NAME' => 'pat', 'TABLEAU_PAT_SECRET' => 'sec'))
    check(out.include?('sign-in failed at preflight'),
          'misconfigured/stale PAT aborts at the single-attempt preflight (no retry)', fails)
  end
end

puts
if fails.empty?
  puts 'ALL PASS'
else
  puts "#{fails.size} FAILURE(S):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
