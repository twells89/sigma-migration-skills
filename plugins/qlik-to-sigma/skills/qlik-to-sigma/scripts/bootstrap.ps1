# bootstrap.ps1 -- ONE command that takes a fresh Windows machine to
# doctor-green (Windows PowerShell 5.1-compatible; no pwsh-only syntax, and
# ASCII-only source -- a BOM-less em-dash mis-decodes into a ParserError on
# stock Windows PowerShell). PLAN-v3 PR-15: environment bootstrap burned
# ~25-30% of field tokens (hand-driven runtime installs, TTY/creds failures)
# -- this script replaces every "install X by hand" instruction on Windows.
#
#   powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 [-WorkDir DIR]
#   powershell -ExecutionPolicy Bypass -File scripts\bootstrap.ps1 -Check
#   Creds chaining (optional; passed through to setup.rb -- the single
#   credential writer; values are never echoed):
#     -ClientId ID -ClientSecret SECRET [-BaseUrl URL] [-ConnectionId ID]
#     -FromEnv    (persist from already-set env vars)
#
# Contract (same as bootstrap.sh):
#   * IDEMPOTENT and NON-INTERACTIVE (no prompts, no-TTY-safe).
#   * NEVER requires admin: installs are user-scoped only -- winget with
#     --scope user where the package supports it, scoop (itself a no-admin
#     user-dir install; self-installed from get.scoop.sh when neither manager
#     exists) as the portable route, fnm for node, pip --user for python
#     deps. It never elevates.
#   * PINNED -- new Node installs are pinned to the 22 LTS line (maintenance
#     until 2027-04-30; the 20 line reached EOL 2026-04-30, so a fresh 20.x
#     install would land an unsupported runtime; SIGMA_BOOTSTRAP_NODE_PIN
#     overrides). The Python render payload pins numpy>=2.3 and installs with
#     a TLS-proxy-safe pip chain (never verification off).
#   * DISCLOSED WRITES -- user-dir runtime installs, the USER PATH env var
#     (plus this session), creds via setup.rb in ~/.sigma-migration/env, and
#     the sentinel/doctor reports in ~/.sigma-migration. PIP_USE_FEATURE is
#     set for THIS SESSION only, never USER scope (a stale USER-scope value
#     an older bootstrap persisted is removed). Nothing machine-scope,
#     nothing in shell profiles.
#   * Creds flow runs when the cred flags above are given, or when
#     SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET (and Tableau PAT vars, where the
#     tableau scripts ship) are already set (setup.rb --from-env).
#   * Finishes by running scripts\doctor.ps1 (writes doctor.json -- the report
#     the orchestrator gates on) and writing the bootstrap SENTINEL
#     (~/.sigma-migration/bootstrap.json, + <WorkDir>\bootstrap.json).
#   * -Check = DRY RUN: report what WOULD install, change nothing, skip the
#     doctor (offline-safe). Exit 0 = complete, 1 = pieces missing.
#
# macOS / Linux / Git-Bash users: run scripts/bootstrap.sh instead.
param(
  [switch]$Check,
  [string]$WorkDir = "",
  [string]$ClientId = "",
  [string]$ClientSecret = "",
  [string]$BaseUrl = "",
  [string]$ConnectionId = "",
  [switch]$FromEnv,
  [ValidateSet("auto", "ruby", "python")][string]$RuntimeProfile = "",
  [switch]$AllowPreviewRuntime
)
if (-not $WorkDir -and $env:BOOTSTRAP_WORKDIR) { $WorkDir = $env:BOOTSTRAP_WORKDIR }
if (-not $RuntimeProfile) {
  $RuntimeProfile = if ($env:SIGMA_RUNTIME_PROFILE) { $env:SIGMA_RUNTIME_PROFILE } else { "auto" }
}

# PS 5.1 on older Windows builds may exclude TLS 1.2 by default; every web
# download here (incl. scoop's installer) needs it.
try {
  [Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$script:Needed = 0
$script:InstallFailed = $false
$script:Actions = @()
$script:PathAdded = @()
$StateDir = Join-Path $env:USERPROFILE ".sigma-migration"
# 22 = the newest LTS line already in MAINTENANCE (until 2027-04-30). Node 20
# reached EOL 2026-04-30 -- never pin a default to an end-of-lifed line, and
# never float an "--lts" (it lands the next, untested even line). Bump
# deliberately via SIGMA_BOOTSTRAP_NODE_PIN -- only to a published release.
$NodePin = "22.14.0"
if ($env:SIGMA_BOOTSTRAP_NODE_PIN) { $NodePin = $env:SIGMA_BOOTSTRAP_NODE_PIN }
$NodePinMajor = $NodePin.Split('.')[0]

function Okay([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Plan([string]$piece, [string]$what) {
  $script:Needed++
  if ($Check) { Write-Host "  [X]  $piece" -ForegroundColor Red; Write-Host "       WOULD: $what" -ForegroundColor DarkGray }
  else        { Write-Host "  [X]  $piece" -ForegroundColor Red; Write-Host "       -> $what" -ForegroundColor DarkGray }
}
function Note([string]$m) { Write-Host "       $m" -ForegroundColor DarkGray }

function Activate-PathDir([string]$dir) {
  if (-not $dir -or -not (Test-Path $dir)) { return }
  if (($env:Path -split ';') -contains $dir) { return }
  $env:Path = "$dir;$env:Path"
  if ($Check) { return }
  # Persist USER-scope PATH (never machine scope -- no admin).
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not (($userPath -split ';') -contains $dir)) {
    [Environment]::SetEnvironmentVariable('Path', "$dir;$userPath", 'User')
  }
  $script:PathAdded += $dir
  $script:Actions += "path-activate: $dir"
}

function Have([string]$exe) { [bool](Get-Command $exe -ErrorAction SilentlyContinue) }
function HaveWinget { Have 'winget' }
function HaveScoop  { Have 'scoop' }

# user-scoped winget install; returns $true on success. --exact --source
# winget avoids msstore-source matches (which can prompt or mismatch ids).
function WingetUserInstall([string]$id) {
  & winget install --id $id --exact --source winget --scope user --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { return $true }
  # some packages reject --scope user; retry without (per-user default installers)
  & winget install --id $id -e --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-Null
  return ($LASTEXITCODE -eq 0)
}
function ScoopInstall([string]$pkg) {
  & scoop install $pkg 2>&1 | Out-Null
  return ($LASTEXITCODE -eq 0)
}
# Ensure-Scoop -- self-install scoop when absent (official user-dir installer,
# https://scoop.sh; no admin, no machine writes) so "no winget, no scoop"
# hosts are no longer a dead end. Full mode only -- callers gate on -Check.
function Ensure-Scoop {
  if (HaveScoop) { return $true }
  if ($Check) { return $false }
  try {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
    Invoke-RestMethod 'https://get.scoop.sh' | Invoke-Expression | Out-Null
    $script:Actions += 'install: scoop (official user-dir installer)'
  } catch {
    Note "scoop self-install FAILED: $($_.Exception.Message)"
  }
  return (HaveScoop)
}

# Test-RealPython -- KEEP IN LOCKSTEP with doctor.ps1.
function Test-RealPython($exe, $pre) {
  $cmd = Get-Command $exe -ErrorAction SilentlyContinue
  if (-not $cmd) { return $null }
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
if (Test-RealPython 'py' '-3')           { $script:PyExe = 'py'; $script:PyPre = '-3' }
elseif (Test-RealPython 'python' $null)  { $script:PyExe = 'python' }
elseif (Test-RealPython 'python3' $null) { $script:PyExe = 'python3' }

$script:RuntimeProfileSelected = ""
$script:RuntimeProfileRequired = @()
$script:RuntimeProfileFallbackReason = ""
$script:RuntimeProfilePass = $false
$profileHelper = Join-Path $PSScriptRoot "runtime_profile.py"
$capabilities = Join-Path (Split-Path -Parent $PSScriptRoot) "runtime-capabilities.json"
if ((Test-Path $profileHelper) -and $script:PyExe) {
  $profileArgs = @(); if ($script:PyPre) { $profileArgs += $script:PyPre }
  $profileArgs += @(
    $profileHelper,
    "--requested", $RuntimeProfile,
    "--format", "json",
    "--runtime", "ruby=$(([bool](Get-Command ruby -ErrorAction SilentlyContinue)).ToString().ToLower())",
    "--runtime", "python=true",
    "--runtime", "node=$(([bool](Get-Command node -ErrorAction SilentlyContinue)).ToString().ToLower())",
    "--runtime", "bash=$(([bool](Get-Command bash -ErrorAction SilentlyContinue)).ToString().ToLower())"
  )
  if (Test-Path $capabilities) { $profileArgs += @("--capabilities", $capabilities) }
  if ($AllowPreviewRuntime) { $profileArgs += "--allow-preview" }
  try {
    $profileJson = (& $script:PyExe @profileArgs 2>$null | Out-String).Trim()
    $profileResult = $profileJson | ConvertFrom-Json
    $script:RuntimeProfileSelected = if ($profileResult.selectedProfile) { "$($profileResult.selectedProfile)" } else { "" }
    $script:RuntimeProfileRequired = @($profileResult.requiredRuntimes)
    $script:RuntimeProfileFallbackReason = if ($profileResult.fallbackReason) { "$($profileResult.fallbackReason)" } else { "" }
    $script:RuntimeProfilePass = [bool]$profileResult.pass
  } catch { }
} elseif (-not (Test-Path $profileHelper)) {
  $script:RuntimeProfileSelected = "ruby"
  $script:RuntimeProfileRequired = @("ruby", "python", "node", "bash")
  $script:RuntimeProfilePass = $true
}
$skipRuby = ($RuntimeProfile -eq "python") -or ($script:RuntimeProfileSelected -eq "python")

Write-Host "Environment bootstrap - host: windows (PowerShell)  mode: $(if ($Check) {'check'} else {'full'})"
# Up-front write disclosure (both modes -- in -Check it is the complete list
# of what a full run WOULD touch outside the workdir; nothing else, ever):
Write-Host "Writes outside the workdir: user-dir runtime installs, the USER PATH env var, creds via setup.rb in $StateDir\env, and the $StateDir bootstrap.json/doctor.json reports (disclosed; nothing else -- pip wiring stays session-only).`n"

# --- ruby -------------------------------------------------------------------
if ($skipRuby) { Okay "runtime profile '$RuntimeProfile' selects the Python path - Ruby installation skipped" }
elseif (Have 'ruby') { Okay "ruby $((& ruby -e 'print RUBY_VERSION' 2>$null))" }
else {
  # scoop shims / RubyInstaller user dirs that just need PATH activation
  $rubyBin = @(
    (Join-Path $env:USERPROFILE 'scoop\apps\ruby\current\bin'),
    (Get-ChildItem -Path (Join-Path $env:SystemDrive 'Ruby*\bin') -ErrorAction SilentlyContinue | Select-Object -Last 1 -ExpandProperty FullName)
  ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'ruby.exe')) } | Select-Object -First 1
  if ($rubyBin) {
    Plan "ruby installed but not on PATH ($rubyBin)" "activate it (user-scope PATH prepend)"
    if (-not $Check) { Activate-PathDir $rubyBin; if (Have 'ruby') { Okay "ruby $((& ruby -e 'print RUBY_VERSION' 2>$null)) (activated)" } }
  } elseif (HaveWinget) {
    # winget FIRST for ruby (unlike python/git): it is the PINNED route.
    # 3.4 = the newest 3.x in NORMAL maintenance (3.3 is security-only until
    # ~2027-03; 4.0 is a major-line jump the orchestrators haven't been
    # gem-vetted for). Known skew: scoop's main-bucket 'ruby' floats at
    # current stable (4.x) -- scoop stays the best-effort fallback below.
    Plan "ruby not found" "winget install RubyInstallerTeam.Ruby.3.4 (pinned 3.4 line; user scope; no admin)"
    if (-not $Check) {
      if (WingetUserInstall 'RubyInstallerTeam.Ruby.3.4') { $script:Actions += 'install: ruby (winget RubyInstallerTeam.Ruby.3.4)'; if (-not (Have 'ruby')) { Note 'winget installed ruby -- a NEW shell may be needed for PATH; re-run bootstrap there' } else { Okay "ruby $((& ruby -e 'print RUBY_VERSION' 2>$null)) (winget, pinned 3.4)" } }
      elseif ((Ensure-Scoop) -and (ScoopInstall 'ruby')) { $script:Actions += 'install: ruby (scoop fallback; floats current stable)'; Activate-PathDir (Join-Path $env:USERPROFILE 'scoop\shims'); if (Have 'ruby') { Okay "ruby $((& ruby -e 'print RUBY_VERSION' 2>$null)) (scoop)" } else { Note 'scoop installed ruby but it is not resolvable -- open a new shell and re-run bootstrap' } }
      else { $script:InstallFailed = $true; Note 'winget install ruby FAILED (and the scoop fallback did not resolve) -- check network/proxy, then re-run bootstrap' }
    }
  } elseif (HaveScoop) {
    # No winget on this host. Note the skew: scoop's main-bucket 'ruby'
    # floats at current stable (4.x); winget is the pinned route.
    Plan "ruby not found" "scoop install ruby (portable, user-dir, no admin; floats current stable -- winget is the pinned route)"
    if (-not $Check) {
      if (ScoopInstall 'ruby') { $script:Actions += 'install: ruby (scoop)'; if (Have 'ruby') { Okay "ruby $((& ruby -e 'print RUBY_VERSION' 2>$null)) (scoop)" } else { $script:InstallFailed = $true; Note 'scoop installed ruby but it is not resolvable -- open a new shell and re-run bootstrap' } }
      else { $script:InstallFailed = $true; Note 'scoop install ruby FAILED' }
    }
  } else {
    Plan "ruby not found (no scoop, no winget)" "install scoop itself (official user-dir installer: irm get.scoop.sh | iex -- no admin), then scoop install ruby"
    if (-not $Check) {
      if ((Ensure-Scoop) -and (ScoopInstall 'ruby')) { $script:Actions += 'install: ruby (scoop, self-installed)'; Activate-PathDir (Join-Path $env:USERPROFILE 'scoop\shims'); if (Have 'ruby') { Okay "ruby $((& ruby -e 'print RUBY_VERSION' 2>$null)) (scoop)" } else { Note 'scoop installed ruby but it is not resolvable -- open a new shell and re-run bootstrap' } }
      else { $script:InstallFailed = $true; Note 'scoop self-install or scoop install ruby FAILED -- check network/proxy, then re-run bootstrap' }
    }
  }
}

# --- python (real interpreter, not the Store stub) --------------------------
if (-not $script:PyExe) {
  if (Test-RealPython 'py' '-3')           { $script:PyExe = 'py'; $script:PyPre = '-3' }
  elseif (Test-RealPython 'python' $null)  { $script:PyExe = 'python'; $script:PyPre = $null }
  elseif (Test-RealPython 'python3' $null) { $script:PyExe = 'python3'; $script:PyPre = $null }
}
if ($script:PyExe) {
  $pyArgs = @(); if ($script:PyPre) { $pyArgs += $script:PyPre }
  Okay "python $((& $script:PyExe @pyArgs --version 2>&1 | Out-String).Trim() -replace 'Python ','') [$script:PyExe $script:PyPre]"
} else {
  if (HaveScoop) {
    Plan "no real Python (Store stub or none)" "scoop install python (portable, user-dir, no admin)"
    if (-not $Check) {
      if (ScoopInstall 'python') { $script:Actions += 'install: python (scoop)'; if (Test-RealPython 'python' $null) { $script:PyExe = 'python'; Okay 'python (scoop)' } else { $script:InstallFailed = $true; Note 'scoop installed python but it is not resolvable -- open a new shell and re-run bootstrap' } }
      else { $script:InstallFailed = $true; Note 'scoop install python FAILED' }
    }
  } elseif (HaveWinget) {
    # 3.13: still in bugfix until 2026-10 (3.14 is the newest line; numpy
    # 2.3.2+ supports 3.11-3.14, so either works -- 3.13 is kept as the
    # longer-field-proven installer while it remains in bugfix).
    Plan "no real Python (Store stub or none)" "winget install Python.Python.3.13 (user scope; no admin; the Store alias stub is rejected by the probe)"
    if (-not $Check) {
      if (WingetUserInstall 'Python.Python.3.13') { $script:Actions += 'install: python (winget Python.Python.3.13)'; if (Test-RealPython 'py' '-3') { $script:PyExe = 'py'; $script:PyPre = '-3'; Okay 'python (winget, py -3)' } else { Note 'winget installed python -- a NEW shell may be needed for PATH; re-run bootstrap there' } }
      else { $script:InstallFailed = $true; Note 'winget install python FAILED' }
    }
  } else {
    Plan "no real Python (no scoop, no winget)" "install scoop itself (official user-dir installer: irm get.scoop.sh | iex -- no admin), then scoop install python"
    if (-not $Check) {
      if ((Ensure-Scoop) -and (ScoopInstall 'python')) { $script:Actions += 'install: python (scoop, self-installed)'; Activate-PathDir (Join-Path $env:USERPROFILE 'scoop\shims'); if (Test-RealPython 'python' $null) { $script:PyExe = 'python'; Okay 'python (scoop)' } else { Note 'scoop installed python but it is not resolvable -- open a new shell and re-run bootstrap' } }
      else { $script:InstallFailed = $true; Note 'scoop self-install or scoop install python FAILED -- check network/proxy, then re-run bootstrap' }
    }
  }
}

# pip --user install with escalating, NAMED fallbacks -- never verification
# off:
#   1) plain --user
#   2) PEP 668 "externally-managed-environment" -> retry with
#      --user --break-system-packages (says why first; rare on Windows, kept
#      for stray msys/pyenv-win pythons)
#   3) TLS-intercepting corporate proxy (the S2 field-failure class) -> retry
#      verifying against the OS trust store -- which carries the corporate CA
#      -- via pip's truststore feature, ACCUMULATING rung 2's flags. Honest
#      scope: the flag helps only pip 22.2-24.1 with truststore importable --
#      pip >= 24.2 uses the OS store by default, and a corporate CA absent
#      from the OS store needs PIP_CERT. NEVER --trusted-host.
#      The rung is GATED on exactly that scope (Get-PipVersionParts window +
#      truststore importable -- never while installing truststore itself);
#      outside it the helper prints the PIP_CERT remediation instead of a
#      retry that cannot work, and the original TLS error is saved before
#      the retry so it is never overwritten.
# On final failure the last 4 pip log lines are shown (the old helper
# swallowed all output, leaving TLS/proxy failures opaque).
function Invoke-PipUserInstall {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Pkgs)
  $a = @(); if ($script:PyPre) { $a += $script:PyPre }
  $log = Join-Path $env:TEMP ("bootstrap-pip-" + [IO.Path]::GetRandomFileName() + ".log")
  $extra = @()
  & $script:PyExe @a -m pip install --user --quiet @Pkgs 2>$log | Out-Null
  $rc = $LASTEXITCODE
  $err = ""
  if (($rc -ne 0) -and (Test-Path $log)) { $err = (Get-Content $log -Raw -ErrorAction SilentlyContinue) }
  if (($rc -ne 0) -and ($err -match '(?i)externally.managed')) {
    Note 'pip: externally-managed interpreter (PEP 668) -- retrying with --user --break-system-packages'
    $extra = @('--break-system-packages')
    & $script:PyExe @a -m pip install --user @extra --quiet @Pkgs 2>$log | Out-Null
    $rc = $LASTEXITCODE
    if (($rc -ne 0) -and (Test-Path $log)) { $err = (Get-Content $log -Raw -ErrorAction SilentlyContinue) }
  }
  if (($rc -ne 0) -and ($err -match '(?i)ssl|certificate')) {
    # Rung 3 is gated TWICE. (a) the [22.2, 24.2) window: below 22.2 pip
    # rejects --use-feature=truststore AT PARSE TIME, and because the retry
    # wrote to the same log it ERASED the real TLS error this helper exists
    # to surface. (b) $script:trustOk: rung 3 asks pip to use a feature
    # provided by the truststore package, so it is chicken-and-egg on the
    # very call that installs truststore. When either gate says no, print
    # the ACTIONABLE remediation instead of a retry that cannot work.
    $pv = Get-PipVersionParts
    $inWindow = $false
    if ($pv) {
      $ge222 = ($pv[0] -gt 22) -or (($pv[0] -eq 22) -and ($pv[1] -ge 2))
      $lt242 = ($pv[0] -lt 24) -or (($pv[0] -eq 24) -and ($pv[1] -lt 2))
      $inWindow = ($ge222 -and $lt242)
    }
    if (-not $inWindow) {
      Note 'pip: TLS failure -- NOT retrying with --use-feature=truststore: this pip is outside the [22.2, 24.2) window where that opt-in exists and is not already the default. Point pip at the corporate CA once instead: set PIP_CERT to the corp CA bundle path (never --trusted-host).'
    } elseif ($script:trustOk -ne $true) {
      Note 'pip: TLS failure -- NOT retrying with --use-feature=truststore: the truststore package is not importable yet (this install may BE truststore). Set PIP_CERT to the corp CA bundle path and re-run.'
    } else {
      Note 'pip: TLS failure -- retrying with --use-feature=truststore (OS trust store)'
      $tlsErr = $err   # NEVER clobber the rung-1/2 diagnostic
      & $script:PyExe @a -m pip install --user @extra --quiet --use-feature=truststore @Pkgs 2>$log | Out-Null
      $rc = $LASTEXITCODE
      if ($rc -ne 0) {
        Note 'pip: the truststore retry also failed; the ORIGINAL TLS error was:'
        ($tlsErr -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 4 | ForEach-Object { Note "pip: $_" }
      }
    }
  }
  if (($rc -ne 0) -and (Test-Path $log)) {
    Get-Content $log -ErrorAction SilentlyContinue | Select-Object -Last 4 | ForEach-Object { Note "pip: $_" }
  }
  Remove-Item $log -ErrorAction SilentlyContinue
  return ($rc -eq 0)
}
# Get-PipVersionParts -- @(major, minor) of the resolved python's pip, or
# $null. Used to wire pip's explicit truststore opt-in ONLY inside [22.2,
# 24.2): below 22.2 the option name kills every pip call at parse time; from
# 24.2 the OS store is pip's default and the wiring is redundant.
function Get-PipVersionParts {
  $a = @(); if ($script:PyPre) { $a += $script:PyPre }
  try {
    $out = (& $script:PyExe @a -m pip --version 2>$null | Out-String).Trim()
    if ($out -match '^pip\s+(\d+)\.(\d+)') { return @([int]$Matches[1], [int]$Matches[2]) }
  } catch { }
  return $null
}

# --- python payload (pinned render deps + truststore; TLS-proxy-safe pip) ---
if ($script:PyExe) {
  $pyArgs = @(); if ($script:PyPre) { $pyArgs += $script:PyPre }
  # Stale-wiring self-heal FIRST: an older bootstrap generation persisted
  # PIP_USE_FEATURE=truststore at USER scope, where any pip < 22.2 on the
  # machine (every venv has its own pip) rejects the option name at parse
  # time and dies. Clear the session value; wiring is session-only now (set
  # below only on proven success, inside the version window).
  if (Test-Path env:PIP_USE_FEATURE) { Remove-Item env:PIP_USE_FEATURE -ErrorAction SilentlyContinue }
  $staleUser = [Environment]::GetEnvironmentVariable('PIP_USE_FEATURE', 'User')
  if ($staleUser -eq 'truststore') {
    if ($Check) { Note 'a USER-scope PIP_USE_FEATURE=truststore from an older bootstrap is present; a full run removes it (wiring is session-only now)' }
    else {
      [Environment]::SetEnvironmentVariable('PIP_USE_FEATURE', $null, 'User')
      $script:Actions += 'self-heal: removed stale USER-scope PIP_USE_FEATURE wiring'
      Note 'removed the USER-scope PIP_USE_FEATURE=truststore an older bootstrap persisted (wiring is session-only now)'
    }
  }
  # Presence probes BEFORE the version floor (the IDEMPOTENT contract: probe
  # first, install only what is missing). The 3.11+ floor below is an INSTALL
  # prerequisite -- numpy>=2.3 has no wheels for older interpreters -- not a
  # runtime one: a host whose payload already imports is doctor-green and
  # must stay green here, not fail on interpreter age.
  $trustOk = $false
  & $script:PyExe @pyArgs -c "import truststore" 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $trustOk = $true }
  # Render payload SELF-GATES the way the doctor's render check does: only
  # where the render scripts exist next to this bootstrap (pillow/numpy feed
  # visual-similarity.py, requests feeds sigma-export-png.py) -- assessment
  # twins that ship neither script must not install a payload nothing uses.
  $needRender = (Test-Path (Join-Path $PSScriptRoot 'visual-similarity.py')) -or `
                (Test-Path (Join-Path $PSScriptRoot 'sigma-export-png.py'))
  $renderOk = $true
  if ($needRender) {
    & $script:PyExe @pyArgs -c "import PIL, numpy, requests" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $renderOk = $false }
  }
  $pyver = (& $script:PyExe @pyArgs -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>$null | Out-String).Trim()
  if (-not $pyver) { $pyver = '?.?' }
  # Payload floor -- enforced ONLY when the render payload actually needs a
  # pip install. On an older interpreter the pip step would die with a
  # misleading "No matching distribution found" that the TLS remediation
  # misdirects to proxy advice -- name the real cause instead.
  $floorOk = $true
  if (-not $renderOk) {
    & $script:PyExe @pyArgs -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { $floorOk = $false }
  }
  if (-not $floorOk) {
    Plan "python $pyver is too old for the pinned payload (numpy>=2.3 needs Python 3.11+; truststore needs 3.10+)" "no pip route on this interpreter -- the USER should install Python 3.11+ (winget install --id Python.Python.3.13 --scope user; py -3 then prefers it), then re-run bootstrap"
    if (-not $Check) { $script:InstallFailed = $true }
  } else {
    # truststore wherever a real python exists -- it is how the python HTTPS
    # path (pip included) trusts TLS-intercepting corporate proxies via the
    # OS store (pip >= 24.2 does this by default). Doctor warns, never gates.
    $trustFloorOk = $true
    if (-not $trustOk) {
      & $script:PyExe @pyArgs -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0) { $trustFloorOk = $false }
    }
    if ($trustOk) { Okay 'python truststore (OS trust store for TLS)' }
    elseif (-not $trustFloorOk) {
      # 3.10 floor -- honest skip, not a red [X]: the doctor does not gate on
      # truststore, so failing here would contradict a green doctor on a host
      # whose render payload already imports.
      Note "truststore skipped: python $pyver is below its 3.10 floor (TLS-proxy hosts: set PIP_CERT once, or install Python 3.11+ and re-run)"
    } else {
      Plan "python truststore missing (OpenSSL 3.x TLS vs Looker/Tableau Cloud)" "$script:PyExe $script:PyPre -m pip install --user truststore (TLS-proxy-safe chain; no admin)"
      if (-not $Check) {
        # Success keys off PROVEN importability (the re-probe), not pip's rc.
        $okt = Invoke-PipUserInstall truststore
        & $script:PyExe @pyArgs -c "import truststore" 2>$null | Out-Null
        if ($okt -and $LASTEXITCODE -eq 0) { $script:Actions += 'install: pip --user truststore'; Okay 'python truststore installed'; $trustOk = $true }
        else { Note 'pip --user install of truststore FAILED -- if a corporate proxy intercepts TLS, point pip at its CA once: set PIP_CERT to the corp CA bundle path -- do NOT disable TLS verification. (pip >= 24.2 uses the OS trust store by default; on older pips even this truststore install needs PIP_CERT when the corporate CA is missing from the OS store.)' }
      }
    }
    # Wire pip's explicit truststore opt-in for THIS SESSION only, and only
    # where it can work: truststore importable AND pip in [22.2, 24.2).
    # Never USER scope: that would reach every pip the user ever runs,
    # including venvs whose pip predates the feature.
    if ((-not $Check) -and $trustOk) {
      $pv = Get-PipVersionParts
      if ($pv) {
        $ge222 = ($pv[0] -gt 22) -or (($pv[0] -eq 22) -and ($pv[1] -ge 2))
        $lt242 = ($pv[0] -lt 24) -or (($pv[0] -eq 24) -and ($pv[1] -lt 2))
        if ($ge222 -and $lt242) { $env:PIP_USE_FEATURE = 'truststore' }
      }
    }
    if (-not $needRender) { Okay 'render payload not needed here (no render scripts adjacent) -- skipped' }
    elseif ($renderOk) { Okay 'python deps (Pillow + numpy + requests)' }
    else {
      Plan "python deps missing (Pillow/numpy>=2.3/requests -- renders + the gate-14 visual floor)" "$script:PyExe $script:PyPre -m pip install --user pillow numpy>=2.3 requests (pinned; user site-packages; no admin)"
      if (-not $Check) {
        $ok = Invoke-PipUserInstall pillow 'numpy>=2.3' requests
        & $script:PyExe @pyArgs -c "import PIL, numpy, requests" 2>$null | Out-Null
        if ($ok -and $LASTEXITCODE -eq 0) { $script:Actions += 'install: pip --user pillow numpy>=2.3 requests'; Okay 'python deps installed (pip --user; numpy pinned >=2.3)' }
        else { $script:InstallFailed = $true; Note 'pip --user install FAILED -- if PEP 668 (externally-managed) the --break-system-packages retry also failed; otherwise check network/proxy' }
      }
    }
  }
}

# --- node (new installs PINNED to the 22 LTS line) ---------------------------
# Install-FnmPinnedNode -- pinned install + default (BOTH verified: a failed
# `fnm default` leaves fnm-managed shells resolving a different node than the
# dir persisted below), real bin dir via `fnm exec ... process.execPath`
# (fnm's layout is versioned; guessing globs races the install), USER PATH
# persisted, then resolution VERIFIED -- otherwise we fail with the fnm-env
# remediation instead of repeating the same broken write on every re-run.
# Full mode only -- callers gate on -Check.
function Install-FnmPinnedNode {
  & fnm install $NodePinMajor 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { $script:InstallFailed = $true; Note "fnm install $NodePinMajor FAILED -- re-run bootstrap when the network allows"; return }
  & fnm default $NodePinMajor 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { $script:InstallFailed = $true; Note "fnm default $NodePinMajor FAILED -- run 'fnm install $NodePinMajor; fnm default $NodePinMajor' by hand, then re-run bootstrap"; return }
  $nodeDir = (& fnm exec --using $NodePinMajor node -p "require('path').dirname(process.execPath)" 2>$null | Out-String).Trim()
  if ($nodeDir) { Activate-PathDir $nodeDir }
  $script:Actions += "install: node $NodePinMajor LTS (fnm, pinned)"
  if (Have 'node') { Okay "node $((& node --version 2>$null)) (fnm, pinned to the $NodePinMajor line)" }
  else { $script:InstallFailed = $true; Note "fnm installed node $NodePinMajor but 'node' is not resolvable -- run 'fnm env' and add its node dir to the USER PATH, then re-run bootstrap" }
}
if (Have 'node') { Okay "node $((& node --version 2>$null))" }
else {
  $fnmNode = Get-ChildItem -Path (Join-Path $env:USERPROFILE '.fnm\node-versions\*\installation') -ErrorAction SilentlyContinue | Select-Object -Last 1 -ExpandProperty FullName
  if (-not $fnmNode) { $fnmNode = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'fnm\node-versions\*\installation') -ErrorAction SilentlyContinue | Select-Object -Last 1 -ExpandProperty FullName }
  $scoopNode = Join-Path $env:USERPROFILE 'scoop\apps\nodejs-lts\current'
  if ($fnmNode -and (Test-Path (Join-Path $fnmNode 'node.exe'))) {
    Plan "node installed (fnm) but not on PATH ($fnmNode)" "activate it (user-scope PATH prepend)"
    if (-not $Check) { Activate-PathDir $fnmNode; if (Have 'node') { Okay "node $((& node --version 2>$null)) (activated)" } }
  } elseif (Test-Path (Join-Path $scoopNode 'node.exe')) {
    Plan "node installed (scoop) but not on PATH ($scoopNode)" "activate it (user-scope PATH prepend)"
    if (-not $Check) { Activate-PathDir $scoopNode; if (Have 'node') { Okay "node $((& node --version 2>$null)) (activated)" } }
  } elseif (Have 'fnm') {
    Plan "node not found (fnm present)" "fnm install $NodePinMajor + fnm default $NodePinMajor (pinned 22 LTS; user-scoped; no admin)"
    if (-not $Check) { Install-FnmPinnedNode }
  } elseif (HaveWinget) {
    # winget before scoop here: it lands fnm, the PINNED node route; scoop's
    # nodejs-lts (below) is the unpinned last resort.
    Plan "node not found" "winget install Schniz.fnm, then fnm install $NodePinMajor (pinned 22 LTS; user-scoped; no admin)"
    if (-not $Check) {
      if (WingetUserInstall 'Schniz.fnm') {
        $script:Actions += 'install: fnm (winget)'
        if (Have 'fnm') { Install-FnmPinnedNode }
        else { Note 'fnm installed -- a NEW shell may be needed for PATH; re-run bootstrap there to finish node (pinned)' }
      } else { $script:InstallFailed = $true; Note 'winget install Schniz.fnm FAILED' }
    }
  } elseif (HaveScoop) {
    # Unpinned LAST RESORT (scoop's nodejs-lts floats the current LTS line;
    # the pinned route is fnm above -- see refs/environment.md #5).
    Plan "node not found" "scoop install nodejs-lts (portable, user-dir, no admin; floats the current LTS -- fnm is the pinned route)"
    if (-not $Check) {
      if (ScoopInstall 'nodejs-lts') { $script:Actions += 'install: node (scoop nodejs-lts, unpinned last resort)'; if (Have 'node') { Okay "node $((& node --version 2>$null)) (scoop)" } else { $script:InstallFailed = $true; Note 'scoop installed node but it is not resolvable -- open a new shell and re-run bootstrap' } }
      else { $script:InstallFailed = $true; Note 'scoop install nodejs-lts FAILED' }
    }
  } else {
    Plan "node not found (no fnm, no scoop, no winget)" "install scoop itself (official user-dir installer: irm get.scoop.sh | iex -- no admin), then scoop install nodejs-lts"
    if (-not $Check) {
      if ((Ensure-Scoop) -and (ScoopInstall 'nodejs-lts')) { $script:Actions += 'install: node (scoop nodejs-lts, self-installed scoop)'; Activate-PathDir (Join-Path $env:USERPROFILE 'scoop\shims'); if (Have 'node') { Okay "node $((& node --version 2>$null)) (scoop)" } else { Note 'scoop installed node but it is not resolvable -- open a new shell and re-run bootstrap' } }
      else { $script:InstallFailed = $true; Note 'scoop self-install or scoop install nodejs-lts FAILED -- check network/proxy, then re-run bootstrap' }
    }
  }
}

# --- bash (Git Bash -- get-token.sh / *-auth.sh token minting) ---------------
if (Have 'bash') { Okay "bash $((Get-Command bash).Source)" }
else {
  $gitBash = @((Join-Path $env:USERPROFILE 'scoop\apps\git\current\bin'),
               (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin')) |
             Where-Object { Test-Path (Join-Path $_ 'bash.exe') } | Select-Object -First 1
  if ($gitBash) {
    Plan "bash installed (Git for Windows) but not on PATH ($gitBash)" "activate it (user-scope PATH prepend)"
    if (-not $Check) { Activate-PathDir $gitBash; if (Have 'bash') { Okay 'bash (activated)' } }
  } elseif (HaveScoop) {
    Plan "no bash (get-token.sh cannot run)" "scoop install git (ships Git Bash; portable, user-dir, no admin)"
    if (-not $Check) {
      if (ScoopInstall 'git') { $script:Actions += 'install: git/bash (scoop)'; if (Have 'bash') { Okay 'bash (scoop git)' } else { Note 'scoop installed git - open a new shell and re-run bootstrap' } }
      else { $script:InstallFailed = $true; Note 'scoop install git FAILED' }
    }
  } elseif (HaveWinget) {
    Plan "no bash (get-token.sh cannot run)" "winget install Git.Git (user scope; ships Git Bash)"
    if (-not $Check) {
      if (WingetUserInstall 'Git.Git') { $script:Actions += 'install: git/bash (winget)'; if (-not (Have 'bash')) { Note 'winget installed git - a NEW shell may be needed for PATH; re-run bootstrap there' } else { Okay 'bash (winget git)' } }
      else { $script:InstallFailed = $true; Note 'winget install Git.Git FAILED' }
    }
  } else {
    Plan "no bash (no scoop, no winget)" "install scoop itself (official user-dir installer: irm get.scoop.sh | iex -- no admin), then scoop install git (ships Git Bash)"
    if (-not $Check) {
      if ((Ensure-Scoop) -and (ScoopInstall 'git')) { $script:Actions += 'install: git/bash (scoop, self-installed scoop)'; Activate-PathDir (Join-Path $env:USERPROFILE 'scoop\shims'); if (Have 'bash') { Okay 'bash (scoop git)' } else { Note 'scoop installed git -- open a new shell and re-run bootstrap' } }
      else { $script:InstallFailed = $true; Note 'scoop self-install or scoop install git FAILED -- check network/proxy, then re-run bootstrap' }
    }
  }
}

# --- credentials (non-interactive only; values never echoed) ----------------
$envFile = Join-Path $StateDir 'env'
$hasSigmaFile = (Test-Path $envFile) -and ((Get-Content $envFile -Raw -ErrorAction SilentlyContinue) -match 'SIGMA_CLIENT_ID')
$setupPy = Join-Path $PSScriptRoot 'setup.py'
$setupRb = Join-Path $PSScriptRoot 'setup.rb'
$setupLabel = if ($skipRuby) { 'python scripts/setup.py' } else { 'ruby scripts/setup.rb' }
function Invoke-SigmaSetup([object[]]$extraArgs) {
  if ($skipRuby -and $script:PyExe -and (Test-Path $setupPy)) {
    $a = @(); if ($script:PyPre) { $a += $script:PyPre }
    & $script:PyExe @a $setupPy @extraArgs 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
  }
  if ((Have 'ruby') -and (Test-Path $setupRb)) {
    & ruby $setupRb @extraArgs 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
  }
  return $false
}
# Flag form first: explicit cred flags beat auto-detection (they can rotate
# already-persisted creds). setup.rb stays the SINGLE credential writer;
# values are redacted everywhere (the plan line prints a token count only).
$credArgs = @()
if ($ClientId)     { $credArgs += @('--client-id', $ClientId) }
if ($ClientSecret) { $credArgs += @('--client-secret', $ClientSecret) }
if ($BaseUrl)      { $credArgs += @('--base-url', $BaseUrl) }
if ($ConnectionId) { $credArgs += @('--connection-id', $ConnectionId) }
if ($FromEnv)      { $credArgs += '--from-env' }
if ($credArgs.Count -gt 0) {
  Plan "Sigma credentials provided via flags" "$setupLabel <cred flags redacted: $($credArgs.Count) token(s)> (values never echoed)"
  if (-not $Check) {
    if (Invoke-SigmaSetup $credArgs) { $script:Actions += "creds: $setupLabel (flag form)"; Okay "Sigma credentials persisted via $setupLabel (flag form)" }
    else { $script:InstallFailed = $true; Note 'credential setup (flag form) FAILED -- check the values and selected runtime profile' }
  }
}
elseif ($hasSigmaFile) { Okay "Sigma credentials present ($envFile)" }
elseif ($env:SIGMA_CLIENT_ID -and $env:SIGMA_CLIENT_SECRET) {
  Plan "Sigma credentials not yet persisted (env vars ARE set)" "$setupLabel --from-env"
  if (-not $Check) {
    if (Invoke-SigmaSetup @('--from-env')) { $script:Actions += "creds: $setupLabel --from-env"; Okay 'Sigma credentials persisted from the environment' }
    else { $script:InstallFailed = $true; Note 'credential setup --from-env FAILED -- check SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET' }
  }
} else {
  Plan "Sigma credentials MISSING (no $envFile, no SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET)" "set SIGMA_CLIENT_ID + SIGMA_CLIENT_SECRET (+ SIGMA_BASE_URL) and re-run bootstrap - or run the selected profile's setup script once in a real terminal"
}
$tableauSetupRb = Join-Path $PSScriptRoot 'setup-tableau.rb'
$tableauSetupPy = Join-Path $PSScriptRoot 'setup-tableau.py'
if ((Test-Path $tableauSetupRb) -or (Test-Path $tableauSetupPy)) {
  $hasTabFile = (Test-Path $envFile) -and ((Get-Content $envFile -Raw -ErrorAction SilentlyContinue) -match 'TABLEAU_PAT_SECRET')
  if ($hasTabFile) { Okay "Tableau credentials present ($envFile)" }
  elseif ($env:TABLEAU_PAT_NAME -and $env:TABLEAU_PAT_SECRET) {
    $tableauSetupLabel = if ($skipRuby) { 'python scripts/setup-tableau.py' } else { 'ruby scripts/setup-tableau.rb' }
    Plan "Tableau PAT not yet persisted (env vars ARE set)" "$tableauSetupLabel --from-env"
    if (-not $Check) {
      if ($skipRuby -and $script:PyExe -and (Test-Path $tableauSetupPy)) {
        $a = @(); if ($script:PyPre) { $a += $script:PyPre }
        & $script:PyExe @a $tableauSetupPy --from-env 2>&1 | Out-Null
      } else {
        & ruby $tableauSetupRb --from-env 2>&1 | Out-Null
      }
      if ($LASTEXITCODE -eq 0) { $script:Actions += 'creds: setup-tableau.rb --from-env'; Okay 'Tableau credentials persisted from the environment' }
      else { $script:InstallFailed = $true; Note 'setup-tableau.rb --from-env FAILED -- check the TABLEAU_* exports' }
    }
  } else { Note '(Tableau PAT not configured -- WARN-level; set TABLEAU_PAT_NAME/TABLEAU_PAT_SECRET and re-run bootstrap to persist.)' }
}

# --- check mode stops here (no doctor, no writes -- offline-safe) ------------
if ($Check) {
  Write-Host ""
  if ($script:Needed -eq 0) {
    Write-Host "bootstrap -Check: environment COMPLETE - nothing to install. Run bootstrap.ps1 (no -Check) to (re)confirm doctor-green + write the sentinel."
    exit 0
  }
  Write-Host "bootstrap -Check: $($script:Needed) piece(s) missing (listed above). Run bootstrap.ps1 (no -Check) to fix them non-interactively."
  exit 1
}

# --- doctor (writes doctor.json -- the report the orchestrator gates on) -----
Write-Host "`nRunning the environment doctor..."
$doctorArgs = @('-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'doctor.ps1'))
if ($WorkDir) { $doctorArgs += @('-WorkDir', $WorkDir) }
$doctorArgs += @('-RuntimeProfile', $RuntimeProfile)
if ($AllowPreviewRuntime) { $doctorArgs += '-AllowPreviewRuntime' }
& powershell @doctorArgs
$doctorPass = ($LASTEXITCODE -eq 0)

# --- sentinel ---------------------------------------------------------------
$sentinel = [ordered]@{
  bootstrap_version = 1
  mode              = 'full'
  os                = 'windows'
  runtime_profile   = [ordered]@{
    requested = "$RuntimeProfile"
    selected = "$($script:RuntimeProfileSelected)"
    required_runtimes = @($script:RuntimeProfileRequired)
    fallback_reason = "$($script:RuntimeProfileFallbackReason)"
  }
  actions           = @($script:Actions)
  path_additions    = @($script:PathAdded)
  install_failed    = [bool]$script:InstallFailed
  doctor_pass       = $doctorPass
  completed_at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$json = $sentinel | ConvertTo-Json -Compress -Depth 4
function Write-Sentinel([string]$dest) {
  try {
    $dir = Split-Path -Parent $dest
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # BOM-less UTF-8 (Ruby's JSON.parse chokes on a BOM) -- same as doctor.ps1.
    [System.IO.File]::WriteAllText($dest, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}
Write-Sentinel (Join-Path $StateDir 'bootstrap.json')
if ($WorkDir) { Write-Sentinel (Join-Path $WorkDir 'bootstrap.json') }

Write-Host ""
if ($doctorPass -and -not $script:InstallFailed) {
  Write-Host "bootstrap: COMPLETE - doctor green; sentinel written to $(Join-Path $StateDir 'bootstrap.json')$(if ($WorkDir) { " and $(Join-Path $WorkDir 'bootstrap.json')" })."
  exit 0
}
Write-Host "bootstrap: INCOMPLETE - $(if ($script:InstallFailed) { 'an install step failed; ' })doctor $(if ($doctorPass) { 'green' } else { 'still red' }). Fix the [X] items above and re-run bootstrap.ps1."
exit 1
