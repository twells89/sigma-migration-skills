# doctor.ps1 — environment preflight for the migration skills on Windows.
# Run this FIRST in PowerShell: it reports what's installed, flags the known
# Windows footguns (the Python "Store stub" and a missing bash), and prints the
# exact fix for each — so neither you nor the agent has to trial-and-error setup.
#
#   powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
#
# Exits 0 when all REQUIRED tools are present; 1 when something required is
# missing. (macOS / Linux / Git-Bash users: run scripts/doctor.sh instead.)
#
# REQUIRED: ruby (*-to-sigma orchestrators), python (looker/thoughtspot/mstr/
# sisense + discovery), node (vendored converters/*.mjs), bash (get-token.sh).
#
#   -WorkDir <dir>  also drop doctor.json there (always also written to
#                   ~/.sigma-migration/doctor.json).
param([string]$WorkDir = "")
if (-not $WorkDir -and $env:DOCTOR_WORKDIR) { $WorkDir = $env:DOCTOR_WORKDIR }

$script:Pass = 0; $script:Fail = 0; $script:Warn = 0
$script:Failures = @()
function Ok([string]$m)        { Write-Host "  [OK] $m" -ForegroundColor Green;  $script:Pass++ }
function Bad([string]$m,$fix)  { Write-Host "  [X]  $m" -ForegroundColor Red;    Write-Host "       -> $fix" -ForegroundColor DarkGray; $script:Fail++; $script:Failures += $m }
function Warn([string]$m,$fix) { Write-Host "  [!]  $m" -ForegroundColor Yellow; Write-Host "       -> $fix" -ForegroundColor DarkGray; $script:Warn++ }

Write-Host "Environment doctor - host: windows (PowerShell)`n"

# --- ruby ------------------------------------------------------------------
$ruby = Get-Command ruby -ErrorAction SilentlyContinue
if ($ruby) { Ok "ruby - $((& ruby -e 'print RUBY_VERSION' 2>$null))" }
else { Bad "ruby not found" "Run the bootstrap: 'powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1' (user-scoped winget/scoop install, never admin; it re-runs this doctor when done)." }

# --- python (reject the Microsoft Store App-Execution-Alias stub) ----------
# Detect by PATH first: the stub lives under ...\WindowsApps\. We check py -3,
# then python / python3, and accept the first whose interpreter is NOT in
# WindowsApps. (We avoid invoking a WindowsApps stub, which can pop the Store.)
# KEEP IN LOCKSTEP with bootstrap.ps1's Test-RealPython: same probe body, same
# WindowsApps rejection, so bootstrap and doctor agree on what counts as "a
# real Python" (the tableau skill's test-bootstrap-lockstep.sh Part C diffs
# the two bodies, ignoring comments, and fails on drift).
function Test-RealPython($exe, $pre) {
  $cmd = Get-Command $exe -ErrorAction SilentlyContinue
  if (-not $cmd) { return $null }
  # `py` is the launcher (always real); for python/python3 inspect the source path.
  if ($exe -ne 'py' -and $cmd.Source -and $cmd.Source.ToLower().Contains('windowsapps')) { return $null }
  try {
    $argsv = @(); if ($pre) { $argsv += $pre }
    $ver = (& $exe @argsv --version 2>&1 | Out-String).Trim()
    if ($ver -notmatch 'Python\s+\d') { return $null }
    $where = (& $exe @argsv -c 'import sys;print(sys.executable)' 2>&1 | Out-String).Trim()
    if ($where.ToLower().Contains('windowsapps')) { return $null }
    return "$ver  ($where)"
  } catch { return $null }
}
$script:PyExe = $null; $script:PyPre = $null
$py = Test-RealPython 'py' '-3'
if ($py) { Ok "python - $py  [launcher: py -3]"; $script:PyExe = 'py'; $script:PyPre = '-3' }
else {
  $py = Test-RealPython 'python' $null
  if ($py) { $script:PyExe = 'python' }
  if (-not $py) { $py = Test-RealPython 'python3' $null; if ($py) { $script:PyExe = 'python3' } }
  if ($py) { Ok "python - $py" }
  else {
    Bad "no real Python (the 'python'/'python3' on PATH is likely the Microsoft Store alias stub)" `
        "Run the bootstrap: 'powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1' (installs a real user-scoped Python, never admin; the stub is rejected by its probe). Manual alternative: disable the stub under Settings > Apps > Advanced app settings > App execution aliases."
  }
}

# --- python TLS trust (P1.4) -----------------------------------------------
# Python's OpenSSL 3.x is stricter than curl/Ruby and rejects some valid server
# chains under the default CA bundle (CERTIFICATE_VERIFY_FAILED where curl/Ruby
# succeed). `truststore` (OS trust store) fixes it. WARN only when OpenSSL is
# 3.x AND truststore is absent.
if ($script:PyExe) {
  $pyArgs = @(); if ($script:PyPre) { $pyArgs += $script:PyPre }
  $probe = (& $script:PyExe @pyArgs -c "import ssl,importlib.util as iu; print('TRUSTWARN' if ssl.OPENSSL_VERSION.startswith('OpenSSL 3') and iu.find_spec('truststore') is None else '')" 2>$null | Out-String).Trim()
  if ($probe -eq 'TRUSTWARN') {
    $fix = "$script:PyExe"; if ($script:PyPre) { $fix = "$script:PyExe $script:PyPre" }
    Warn "python uses OpenSSL 3.x without 'truststore' - TLS verification may fail against some servers (e.g. Looker or Tableau Cloud) where curl/Ruby succeed" `
         "Run the bootstrap: 'powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1' - installs 'truststore' and wires pip to the OS trust store. Do NOT disable TLS verification."
  }
}

# --- tableauhyperapi (informational - embedded-extract workbooks only) -----
# Embedded-extract (.twbx) workbooks land their frozen data via
# land-extracts.py, which needs the Hyper API. Not REQUIRED: warn-level only.
# The human check SELF-GATES on land-extracts.py existing next to this script,
# so this shared doctor stays byte-identical across plugins and only speaks up
# where the landing path exists (tableau). JSON field emitted everywhere.
$hyperapiPresent = $false
if ($script:PyExe) {
  $pyArgs = @(); if ($script:PyPre) { $pyArgs += $script:PyPre }
  $hp = (& $script:PyExe @pyArgs -c "import importlib.util as iu; print('HYPER_OK' if iu.find_spec('tableauhyperapi') else '')" 2>$null | Out-String).Trim()
  if ($hp -eq 'HYPER_OK') { $hyperapiPresent = $true }
}
if (Test-Path (Join-Path $PSScriptRoot 'land-extracts.py')) {
  if ($hyperapiPresent) {
    Ok "tableauhyperapi present - embedded-extract workbooks can land via scripts/land-extracts.py"
  } else {
    Warn "tableauhyperapi not installed (only needed for embedded-extract workbooks)" `
         "pip install tableauhyperapi pandas snowflake-connector-python - see refs/extract-landing.md"
  }
}

# --- node ------------------------------------------------------------------
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) { Ok "node - $((& node --version 2>$null))" }
else { Bad "node not found (required - the vendored converters/*.mjs run via node)" `
           "Run the bootstrap: 'powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1' - activates a version-manager Node when one exists (fnm/scoop dirs), else installs Node 22 LTS pinned via the winget-scoop fnm route (no admin, nothing unpinned). Details: refs/environment.md #5." }

# --- bash (REQUIRED for get-token.sh / *-auth.sh token minting) ------------
$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
  Ok "bash - $($bash.Source) (run the *.sh helpers like get-token.sh from Git Bash, or 'bash scripts/get-token.sh')"
} else {
  $wsl = Get-Command wsl -ErrorAction SilentlyContinue
  if ($wsl) { Warn "no native bash, but WSL is present" "Run the *.sh helpers via WSL, or run the bootstrap: 'powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1' (installs Git for Windows user-scoped - it ships Git Bash)." }
  else { Bad "no bash found - get-token.sh / *-auth.sh (Sigma token minting) cannot run" `
             "Run the bootstrap: 'powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1' (installs Git for Windows user-scoped - it ships Git Bash)." }
}

# --- git autocrlf (CRLF mangles shebangs + bash scripts) -------------------
$crlf = (& git config --get core.autocrlf 2>$null)
if ($crlf -eq 'true') {
  Warn "git core.autocrlf=true - may rewrite shipped .sh/.rb/.py to CRLF and break them under bash" `
       "git config --global core.autocrlf input  (then re-clone / re-checkout)."
} else { Ok "git core.autocrlf=$(if ($crlf) {$crlf} else {'unset'}) (won't CRLF-mangle scripts)" }

# --- Sigma credentials (REQUIRED - fail-closed) + live token-mint smoke ----
# Absent creds = [X] REQUIRED failure (a run would die at its first API call).
# When creds ARE present and the sibling Ruby lib exists (lib\sigma_rest.rb -
# the same in-process mint path the orchestrators use), a live token mint
# (bounded ~20s) proves they WORK: present-but-broken creds are [X] too.
# SIGMA_SKIP_CRED_SMOKE=1 skips the live probe. Recorded in doctor.json
# {cred_smoke:{sigma: pass|fail|skipped}}.
$script:SmokeSigma = "skipped"
$envFile = Join-Path $env:USERPROFILE ".sigma-migration\env"
# Content-based presence (the Tableau check's pattern below): bare
# file-existence would misread an env file holding only non-credential lines
# (anything a future writer persists there) as "credentials present".
$sigmaCreds = ((Test-Path $envFile) -and ((Get-Content $envFile -Raw -ErrorAction SilentlyContinue) -match 'SIGMA_(API_TOKEN|CLIENT_ID)')) -or $env:SIGMA_API_TOKEN -or $env:SIGMA_CLIENT_ID
$sigmaLib = Join-Path $PSScriptRoot "lib\sigma_rest.rb"
if (-not $sigmaCreds) {
  Bad "no Sigma credentials found (REQUIRED - the run would die at its first Sigma API call)" `
      "Run 'ruby scripts/setup.rb' once (writes ~/.sigma-migration/env), or set SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET (+ SIGMA_BASE_URL)."
} elseif ($env:SIGMA_SKIP_CRED_SMOKE) {
  Ok "Sigma credentials present (live token-mint smoke SKIPPED: SIGMA_SKIP_CRED_SMOKE)"
} elseif ((Test-Path $sigmaLib) -and (Get-Command ruby -ErrorAction SilentlyContinue)) {
  & ruby -e '$LOAD_PATH.unshift File.join(ARGV[0], "lib"); require "timeout"; require "sigma_rest"; Timeout.timeout(20) { Sigma.refresh_token! }' $PSScriptRoot 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) {
    Ok "Sigma credentials present + live token mint OK"
    $script:SmokeSigma = "pass"
  } else {
    Bad "Sigma credentials present but the live token mint FAILED (bad/stale client id/secret, or wrong SIGMA_BASE_URL)" `
        "Re-run 'ruby scripts/setup.rb' with fresh values (Sigma: Administration > APIs & Embed Secrets). Genuinely offline? Set SIGMA_SKIP_CRED_SMOKE=1 to skip this probe."
    $script:SmokeSigma = "fail"
  }
} else {
  Ok "Sigma credentials present (mint smoke skipped - no ruby lib next to this doctor)"
}

# --- Tableau credentials (self-gated: tableau skill only) --------------------
# Only speaks up where the sibling Tableau scripts exist (setup-tableau.rb +
# lib\tableau_rest.rb). ABSENT Tableau creds stay a WARN (Sigma-only skills
# share this doctor); PRESENT-but-broken creds are [X] via a live PAT signin
# smoke (bounded ~20s). SIGMA_SKIP_CRED_SMOKE=1 skips. Recorded in doctor.json
# {cred_smoke:{tableau: pass|fail|skipped}}.
$script:SmokeTableau = "skipped"
$tabSetup = Join-Path $PSScriptRoot "setup-tableau.rb"
$tabLib = Join-Path $PSScriptRoot "lib\tableau_rest.rb"
if ((Test-Path $tabSetup) -and (Test-Path $tabLib)) {
  $tabCreds = ($env:TABLEAU_PAT_NAME -and $env:TABLEAU_PAT_SECRET) -or `
              ((Test-Path $envFile) -and ((Get-Content $envFile -Raw -ErrorAction SilentlyContinue) -match 'TABLEAU_PAT_SECRET'))
  if (-not $tabCreds) {
    Warn "no Tableau credentials found (needed for Tableau discovery)" `
         "Run 'ruby scripts/setup-tableau.rb' once (PAT), or set TABLEAU_PAT_NAME / TABLEAU_PAT_SECRET / TABLEAU_SITE_CONTENT_URL (+ TABLEAU_SERVER_URL)."
  } elseif ($env:SIGMA_SKIP_CRED_SMOKE) {
    Ok "Tableau credentials present (live PAT signin smoke SKIPPED: SIGMA_SKIP_CRED_SMOKE)"
  } elseif (Get-Command ruby -ErrorAction SilentlyContinue) {
    & ruby -e '$LOAD_PATH.unshift File.join(ARGV[0], "lib"); require "timeout"; require "tableau_rest"; Timeout.timeout(20) { Tableau.refresh_token! }' $PSScriptRoot 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Ok "Tableau credentials present + live PAT signin OK"
      $script:SmokeTableau = "pass"
    } else {
      Bad "Tableau credentials present but the live PAT signin FAILED (expired/revoked PAT, wrong site or server URL)" `
          "Re-run 'ruby scripts/setup-tableau.rb' with a fresh PAT. Genuinely offline? Set SIGMA_SKIP_CRED_SMOKE=1 to skip this probe."
      $script:SmokeTableau = "fail"
    }
  }
}

# --- Looker API reachability (self-gated: looker skills only) ----------------
# Plugin-aware like the Tableau checks: only where looker_api.py + ~/.looker/
# looker.ini exist. Modern Google-hosted Looker serves the API on 443; the
# legacy :19999 is often unreachable. looker_api self-heals to 443, but flag a
# stale ini. Uses the UNAUTHENTICATED /api/4.0/versions via Invoke-WebRequest
# (Windows cert store - isolates the PORT question from the TLS one above).
$script:LookerProbe = "skipped"
$lkIni = Join-Path $env:USERPROFILE ".looker\looker.ini"
$lkApi = Join-Path $PSScriptRoot "looker_api.py"
if ((Test-Path $lkApi) -and (Test-Path $lkIni)) {
  $lkMatch = Select-String -Path $lkIni -Pattern '^\s*base_url\s*=\s*(.+?)\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1
  $lkBase = if ($lkMatch) { $lkMatch.Matches.Groups[1].Value.TrimEnd('/') } else { "" }
  if ($lkBase) {
    $lkNoPort = ($lkBase -replace '^(https?://[^/:]+)(:\d+)?.*$', '$1')
    $reach = { param($u) try { Invoke-WebRequest -Uri "$u/api/4.0/versions" -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop | Out-Null; $true } catch { $false } }
    if (& $reach $lkBase) {
      Ok "Looker API reachable at $lkBase"; $script:LookerProbe = "pass"
    } elseif (($lkNoPort -ne $lkBase) -and (& $reach $lkNoPort)) {
      Warn "Looker base_url ($lkBase) is unreachable but $lkNoPort (443) answers - looker_api will self-heal to 443 at run time" `
           "Update base_url in ~/.looker/looker.ini to '$lkNoPort' (drop the legacy :19999 API port), or set LOOKER_BASE_URL."
      $script:LookerProbe = "fallback"
    } else {
      Warn "Looker API not reachable at $lkBase (network / VPN / instance URL?)" `
           "Confirm the Looker instance URL and that this host can reach its API 4.0 endpoint."
      $script:LookerProbe = "fail"
    }
  }
}

# --- skill version drift (v3 §2.1) -----------------------------------------
# A pinned plugin install never self-updates; a stale SHA silently ships
# pre-fidelity-layer output. Record {skill_sha, behind_count}; the orchestrator
# preflight FAILs above a threshold. Bounded, best-effort fetch; skip with
# SIGMA_SKIP_VERSION_CHECK=1.
$skillSha = ""; $behindCount = $null
$here = $PSScriptRoot
if ($here -and (Get-Command git -ErrorAction SilentlyContinue)) {
  $isRepo = (& git -C $here rev-parse --git-dir 2>$null)
  if ($isRepo) {
    $skillSha = (& git -C $here rev-parse --short HEAD 2>$null)
    # Skip on a SHALLOW clone (CI checkout, some installs): rev-list against a
    # grafted origin/main returns a bogus count (a false "hundreds behind").
    $shallow = (& git -C $here rev-parse --is-shallow-repository 2>$null)
    if ($shallow -ne 'true' -and -not $env:SIGMA_SKIP_VERSION_CHECK) {
      & git -C $here -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=6 fetch --quiet origin 2>$null
      $bc = (& git -C $here rev-list --count HEAD..origin/main 2>$null)
      if ($bc -match '^\d+$') { $behindCount = [int]$bc }
    }
    if ($null -eq $behindCount) {
      if ($skillSha) { Ok "skill version $skillSha (drift check skipped/offline)" }
    } elseif ($behindCount -gt 0) {
      Warn "skill is $behindCount commit(s) behind origin/main (installed $skillSha) - you may be missing fidelity-layer fixes" `
           "Update: 'git -C ""$here"" pull' (or reinstall the plugin). SIGMA_SKIP_VERSION_CHECK=1 skips this probe."
    } else {
      Ok "skill version $skillSha (current with origin/main)"
    }
  }
}

# --- agent capability fingerprint (v3 §2.2) --------------------------------
# Vision is asserted by the caller (a vision-capable session sets
# SIGMA_AGENT_VISION=true); default false so the visual gate fails LOUDLY
# rather than accepting a blind attestation.
$agentVision = $false
if ($env:SIGMA_AGENT_VISION -in @('true', '1', 'yes', 'TRUE', 'True')) { $agentVision = $true }
$modelHint = if ($env:SIGMA_MODEL_HINT) { $env:SIGMA_MODEL_HINT } else { "" }

# --- machine-readable fingerprint (doctor.json) ----------------------------
# Same contract as doctor.sh: lets the preflight GATE refuse to proceed on a
# broken environment, and lets telemetry group failures by environment class.
# Human output above is unchanged. Always ~/.sigma-migration/doctor.json; also
# -WorkDir if given.
$rubyOk = [bool](Get-Command ruby -ErrorAction SilentlyContinue)
$rubyV  = if ($rubyOk) { (& ruby -e 'print RUBY_VERSION' 2>$null) } else { "" }
$nodeOk = [bool](Get-Command node -ErrorAction SilentlyContinue)
$nodeV  = if ($nodeOk) { (& node --version 2>$null) } else { "" }
$pyDesc = Test-RealPython 'py' '-3'
if (-not $pyDesc) { $pyDesc = Test-RealPython 'python' $null }
if (-not $pyDesc) { $pyDesc = Test-RealPython 'python3' $null }
$pyOk = [bool]$pyDesc
$pyV  = if ($pyOk) { ($pyDesc -split '  ')[0] } else { "" }

$sandbox = "none"
if ($env:CLAUDE_CODE_REMOTE -or $env:COWORK -or $env:CODESPACES) { $sandbox = "remote-sandbox" }

$doctor = [ordered]@{
  os           = "windows"
  shell        = "powershell"
  runtimes     = [ordered]@{ ruby = $rubyOk; python = $pyOk; node = $nodeOk; bash = [bool](Get-Command bash -ErrorAction SilentlyContinue) }
  versions     = [ordered]@{ ruby = "$rubyV"; python = "$pyV"; node = "$nodeV" }
  sandbox_hint = $sandbox
  cred_smoke   = [ordered]@{ sigma = $script:SmokeSigma; tableau = $script:SmokeTableau; looker = $script:LookerProbe }
  hyperapi_present = $hyperapiPresent
  skill_sha    = "$skillSha"
  behind_count = $behindCount
  agent_vision = $agentVision
  model_hint   = "$modelHint"
  generated_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  pass         = ($script:Fail -eq 0)
  failures     = @($script:Failures)
}
$json = $doctor | ConvertTo-Json -Compress -Depth 5
function Write-DoctorJson([string]$dest) {
  try {
    $dir = Split-Path -Parent $dest
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # UTF-8 WITHOUT BOM. Windows PowerShell 5.1's `Set-Content -Encoding UTF8`
    # prepends a BOM, which makes Ruby's JSON.parse (the gate reader) fail with
    # "unexpected token". Write via .NET so it's BOM-less on both 5.1 and 7.
    [System.IO.File]::WriteAllText($dest, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}
Write-DoctorJson (Join-Path $env:USERPROFILE ".sigma-migration\doctor.json")
if ($WorkDir) { Write-DoctorJson (Join-Path $WorkDir "doctor.json") }

Write-Host "`nSummary: $script:Pass ok, $script:Warn warning(s), $script:Fail missing/blocking."
if ($script:Fail -eq 0) { Write-Host "Environment looks good - proceed."; exit 0 }
Write-Host "Fix the [X] item(s) above - missing runtimes/payloads are one command: powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 - then re-run: powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1"
exit 1
