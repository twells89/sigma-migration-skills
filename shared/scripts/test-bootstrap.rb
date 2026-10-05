#!/usr/bin/env ruby
# test-bootstrap.rb — offline unit test for bootstrap.sh (PLAN-v3 PR-15).
# Canonical in shared/scripts; vendored next to each plugin's copy. Ruby 2.6+.
#
# What it proves, entirely offline (no installs, no network):
#   1. --check on a COMPLETE (stubbed) environment → exit 0, "nothing to install".
#   2. --check on a SCRUBBED environment (empty HOME, no runtimes beyond the
#      stub shell utils) → exit 1, reports each missing piece WITHOUT installing.
#   3. full run on the complete stubbed env → runs the doctor, writes the
#      bootstrap sentinel (home + workdir) with doctor_pass:true; idempotent
#      on a second run (no actions).
#   4. the sentinel satisfies intake.rb's bootstrap gate.
#   5. token-only and browser-keychain auth configurations are accepted without
#      opening a browser; missing auth names browser login first and client flags
#      as the unattended fallback.
#   6. pip_user_install's TLS rung (the REAL bodies, driven via a pip shim):
#      the truststore retry runs ONLY inside pip's [22.2, 24.2) window and
#      never while installing truststore itself, and the retry can never
#      overwrite the original CERTIFICATE_VERIFY_FAILED diagnostic.
#
# Run: ruby scripts/test-bootstrap.rb
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'

HERE      = __dir__
BOOTSTRAP = File.join(HERE, 'bootstrap.sh')
INTAKE    = File.join(HERE, 'intake.rb')
RUBY      = RbConfig.ruby

if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/ && !system('bash -c true >/dev/null 2>&1')
  puts 'SKIP: no bash available (bootstrap.ps1 is exercised by the Windows CI job)'
  exit 0
end

$fail = 0
def ok(name, cond)
  puts((cond ? '  ok  ' : 'FAIL  ') + name)
  $fail += 1 unless cond
end

# A stub bin dir that makes bootstrap's probes see a "complete" runtime set
# without touching the real machine. The python3 stub answers --version and
# exits 0 for -c imports (so the dep probe reads "deps present").
def write_stub(dir, name, body)
  path = File.join(dir, name)
  File.write(path, "#!/bin/sh\n#{body}\n")
  File.chmod(0o755, path)
end

def stub_bin(dir)
  FileUtils.mkdir_p(dir)
  write_stub(dir, 'ruby',    'case "$1" in -e) printf 2.6.10;; *) exit 0;; esac')
  write_stub(dir, 'node',    'case "$1" in --version) echo v20.0.0;; *) exit 0;; esac')
  write_stub(dir, 'python3', <<~SH.rstrip)
    case "$1" in
      --version) echo "Python 3.12.0";;
      -c) case "$2" in *sys.executable*) echo /stub/python3;; *) :;; esac;;
      -m) exit 0;;
      *) exit 0;;
    esac
  SH
  dir
end

# Run bootstrap.sh with a controlled HOME + PATH. Returns [status, out+err].
def run_bootstrap(home, path_dirs, *args)
  env = { 'HOME' => home, 'USERPROFILE' => home, 'PATH' => path_dirs.join(':'),
          # keep the doctor's networked probes off — offline test
          'SIGMA_SKIP_CRED_SMOKE' => '1', 'SIGMA_SKIP_VERSION_CHECK' => '1' }
  # unsetenv_others: the parent's env (SIGMA_* creds on a dev machine) must
  # not leak into the child — the hash above IS the whole child environment.
  out, st = Open3.capture2e(env, '/bin/bash', BOOTSTRAP, *args, unsetenv_others: true)
  [st.exitstatus, out]
end

SYS = %w[/usr/bin /bin].freeze   # real coreutils (sed, grep, date, mkdir, uname)

Dir.mktmpdir do |t|
  stub = stub_bin(File.join(t, 'stubbin'))

  # ── 1. --check on a complete env ─────────────────────────────────────────
  home1 = File.join(t, 'home1')
  FileUtils.mkdir_p(File.join(home1, '.sigma-migration'))
  File.write(File.join(home1, '.sigma-migration', 'env'),
             "export SIGMA_BASE_URL='https://api.sigmacomputing.com'\n" \
             "export SIGMA_CLIENT_ID='x'\nexport SIGMA_CLIENT_SECRET='y'\n" \
             "export TABLEAU_PAT_SECRET='z'\n")
  st, out = run_bootstrap(home1, [stub] + SYS, '--check')
  ok('--check complete env → exit 0', st == 0)
  ok('--check complete env says nothing to install', out.include?('nothing to install'))
  ok('--check complete env saw all runtimes', out.include?('ruby 2.6.10') && out =~ /node v20/ && out =~ /python/)
  ok('--check never wrote a sentinel', !File.exist?(File.join(home1, '.sigma-migration', 'bootstrap.json')))

  # ── 2. --check on a scrubbed env (no runtimes, empty HOME) ───────────────
  home2 = File.join(t, 'home2')
  FileUtils.mkdir_p(home2)
  st, out = run_bootstrap(home2, SYS, '--check')
  ok('--check scrubbed env → exit 1', st == 1)
  # /usr/bin:/bin never carries node: it must be reported as either genuinely
  # missing or installed-but-not-on-PATH (host-dependent — e.g. a homebrew keg).
  # Creds MUST be reported missing on every host (HOME is empty).
  ok('--check scrubbed env reports node missing/inactive',
     out =~ /node not found/ || out =~ /node installed but not on PATH/)
  ok('--check scrubbed env reports auth missing', out =~ /Sigma authentication MISSING/)
  ok('--check missing auth recommends one-time browser login first',
     out.include?('browser-login.sh') && out.index('browser-login.sh') < out.index('--client-id'))
  ok('--check missing auth retains unattended client-flag fallback',
     out.include?('--client-id ID --client-secret SECRET'))
  ok('--check scrubbed env proposes, never installs (WOULD lines)', out.include?('WOULD:'))
  ok('--check scrubbed env wrote no bootstrap state to HOME',
     !File.exist?(File.join(home2, '.sigma-migration')))

  # ── 3. full run on the complete stubbed env → doctor + sentinel ──────────
  work = File.join(t, 'work'); FileUtils.mkdir_p(work)
  st, out = run_bootstrap(home1, [stub] + SYS, '--workdir', work)
  ok('full run on complete env → exit 0', st == 0)
  ok('full run ran the doctor', out.include?('Running the environment doctor'))
  home_sentinel = File.join(home1, '.sigma-migration', 'bootstrap.json')
  work_sentinel = File.join(work, 'bootstrap.json')
  ok('sentinel written to HOME state dir', File.exist?(home_sentinel))
  ok('sentinel written to workdir', File.exist?(work_sentinel))
  sj = (JSON.parse(File.read(home_sentinel)) rescue nil)
  ok('sentinel parses + doctor_pass:true', sj.is_a?(Hash) && sj['doctor_pass'] == true)
  ok('sentinel records mode + timestamp', sj && sj['mode'] == 'full' && !sj['completed_at'].to_s.empty?)
  ok('doctor.json written to workdir', File.exist?(File.join(work, 'doctor.json')))
  dj = (JSON.parse(File.read(File.join(work, 'doctor.json'))) rescue nil)
  ok('doctor.json records skipped status + non-secret auth method',
     dj && dj.dig('cred_smoke', 'sigma') == 'skipped' &&
       dj['sigma_auth_method'] == 'client-credentials' &&
       !dj.key?('SIGMA_API_TOKEN') && !dj.key?('SIGMA_CLIENT_SECRET'))

  # idempotency: second run takes no actions and stays green
  st2, = run_bootstrap(home1, [stub] + SYS, '--workdir', work)
  sj2 = (JSON.parse(File.read(home_sentinel)) rescue nil)
  ok('second run idempotent → exit 0', st2 == 0)
  ok('second run took no install actions', sj2 && Array(sj2['actions']).none? { |a| a.to_s.start_with?('install:') })

  # ── 4. the sentinel opens intake.rb's bootstrap gate ─────────────────────
  if File.exist?(INTAKE)
    env = { 'HOME' => home1, 'USERPROFILE' => home1, 'SIGMA_CONNECTION_ID' => nil,
            'SIGMA_SKIP_BOOTSTRAP_GATE' => nil }
    system(env, RUBY, INTAKE, '--workdir', work, '--connection',
           '11111111-2222-3333-4444-555555555555', out: File::NULL, err: File::NULL)
    ok('intake gate opens on the real sentinel', $?.exitstatus == 0)
  end

  # ── 5. token/browser auth are recognized without browser launch ──────────
  token_home = File.join(t, 'token-home')
  FileUtils.mkdir_p(File.join(token_home, '.sigma-migration'))
  File.write(File.join(token_home, '.sigma-migration', 'env'),
             "export SIGMA_BASE_URL='https://api.sigmacomputing.com'\n" \
             "export SIGMA_API_TOKEN='current-token'\n")
  keychain_probe = File.join(t, 'keychain-probe-bin')
  keychain_mark = File.join(t, 'keychain-probed')
  FileUtils.mkdir_p(keychain_probe)
  write_stub(keychain_probe, 'secret-tool', "printf probed > #{keychain_mark.inspect}; exit 1")
  st, out = run_bootstrap(token_home, [keychain_probe, stub] + SYS, '--check')
  ok('--check accepts current token + base URL', st == 0 && out.include?('current API token'))
  ok('--check does not touch the keychain when a current token is configured',
     !File.exist?(keychain_mark))

  browser_home = File.join(t, 'browser-home')
  FileUtils.mkdir_p(File.join(browser_home, '.sigma-migration'))
  File.write(File.join(browser_home, '.sigma-migration', 'env'),
             "export SIGMA_BASE_URL='https://api.sigmacomputing.com'\n")
  keychain_stub = File.join(t, 'keychain-bin')
  FileUtils.mkdir_p(keychain_stub)
  write_stub(keychain_stub, 'secret-tool',
             '[ "$1" = lookup ] && [ "$2 $3 $4 $5" = "service sigma-api key refresh-token" ]')
  st, out = run_bootstrap(browser_home, [keychain_stub, stub] + SYS, '--check')
  ok('--check accepts keychain-only browser session + base URL',
     st == 0 && out.include?('browser refresh session present'))
  ok('bootstrap does not invoke browser-login', !out.include?('Opening your browser'))

  # ── 6. pip_user_install TLS rung: gated retry, diagnostics never clobbered ─
  # Drives the REAL pip_user_install/pip_truststore_window bodies extracted
  # from bootstrap.sh (not a copy) against a pip shim. The shim fails every
  # install with a real CERTIFICATE_VERIFY_FAILED and, under PIPVER=21.2.4
  # (macOS CLT python's pip), rejects --use-feature=truststore at parse time —
  # the exact config where an unguarded rung 3 ERASED the TLS error it exists
  # to surface. SHIM_MARK proves whether --use-feature ever reached pip.
  src = File.read(BOOTSTRAP)
  pui = src[/^pip_user_install\(\) \{.*?^\}/m]
  ptw = src[/^pip_truststore_window\(\) \{.*?^\}/m]
  ok('pip rung: both function bodies extracted from bootstrap.sh', !pui.nil? && !ptw.nil?)
  shim = File.join(t, 'pipshim')
  File.write(shim, <<~'SH')
    #!/bin/sh
    # args: -m pip <subcommand...>
    shift 2 2>/dev/null || true
    if [ "${1:-}" = "--version" ]; then echo "pip ${PIPVER:-21.2.4} from /stub/pip (python 3.9)"; exit 0; fi
    for a in "$@"; do
      if [ "$a" = "--use-feature=truststore" ]; then
        [ -n "${SHIM_MARK:-}" ] && : > "$SHIM_MARK"
        if [ "${PIPVER:-21.2.4}" = "21.2.4" ]; then
          echo "Usage:   pip install [options] <requirement specifier> [package-index-options] ..." >&2
          echo "" >&2
          echo "pip: option --use-feature: invalid choice: 'truststore' (choose from '2020-resolver', 'fast-deps', 'in-tree-build')" >&2
          exit 2
        fi
        # In-window retry: fail with text DISTINCT from (and free of) the
        # original CERTIFICATE_VERIFY_FAILED line, so case C can prove the
        # ORIGINAL diagnostic — not this retry text — is what survives the
        # cp into the side log. Identical texts would mask a silent cp failure.
        echo "ERROR: RETRY_MARK truststore retry still failed: connection reset by corporate proxy" >&2
        exit 1
      fi
    done
    echo "WARNING: Retrying (Retry(total=4)) after connection broken by 'SSLError(SSLCertVerificationError(1, [SSL: CERTIFICATE_VERIFY_FAILED]))'" >&2
    echo "ERROR: Could not install packages due to an OSError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to get local issuer certificate" >&2
    exit 1
  SH
  File.chmod(0o755, shim)
  drv = File.join(t, 'pipdrv.sh')
  File.write(drv, <<~SH)
    #!/bin/bash
    set -u
    note() { printf '    %s\\n' "$1"; }
    PY_RUN="#{shim}"
    #{ptw}
    #{pui}
    pip_user_install "$@"
    echo "RETURN=$?"
  SH
  pip_case = lambda do |pipver, trust_ok, mark|
    env = { 'PIPVER' => pipver, 'TRUSTSTORE_OK' => trust_ok, 'SHIM_MARK' => mark }
    out, = Open3.capture2e(env, '/bin/bash', drv, 'truststore')
    out
  end

  # A: pip 21.2.4 — OUTSIDE the window. Unguarded, the retry's parse error
  # overwrote the shared log (rc=2, TLS error gone).
  mark_a = File.join(t, 'mark_a')
  out = pip_case.call('21.2.4', 'true', mark_a)
  ok('pip21: original CERTIFICATE_VERIFY_FAILED surfaced, not clobbered', out.include?('CERTIFICATE_VERIFY_FAILED'))
  ok('pip21: parse-time "invalid choice" never printed', !out.include?('invalid choice'))
  ok('pip21: skip names the window + PIP_CERT remediation', out.include?('outside the [22.2, 24.2) window'))
  ok('pip21: rc is the real pip rc', out.include?('RETURN=1'))
  ok('pip21: --use-feature never reached pip', !File.exist?(mark_a))

  # B: pip 23.1 (in-window) but truststore not importable — the chicken-and-egg
  # shape of the `pip_user_install truststore` call itself.
  mark_b = File.join(t, 'mark_b')
  out = pip_case.call('23.1', 'false', mark_b)
  ok('egg: rung skipped while truststore is not importable', out.include?('not importable yet'))
  ok('egg: original TLS error surfaced', out.include?('CERTIFICATE_VERIFY_FAILED'))
  ok('egg: --use-feature never reached pip', !File.exist?(mark_b))

  # C: pip 23.1 + truststore importable — the rung RUNS and, when the retry
  # also fails, BOTH diagnostics are surfaced.
  mark_c = File.join(t, 'mark_c')
  out = pip_case.call('23.1', 'true', mark_c)
  ok('window: truststore retry actually ran', File.exist?(mark_c))
  ok('window: original TLS error preserved beside the retry log', out.include?('the ORIGINAL TLS error was'))
  after_note = out.split('the ORIGINAL TLS error was').last
  ok('window: ORIGINAL text (not the retry text) follows the note', after_note.include?('CERTIFICATE_VERIFY_FAILED'))
  ok('window: distinguishable retry error surfaced from the retry log', after_note.include?('RETRY_MARK'))
  ok('window: rc is the real pip rc', out.include?('RETURN=1'))
end

puts $fail.zero? ? "\nall bootstrap tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
