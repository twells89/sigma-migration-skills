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

$script:Pass = 0; $script:Fail = 0; $script:Warn = 0
function Ok([string]$m)        { Write-Host "  [OK] $m" -ForegroundColor Green;  $script:Pass++ }
function Bad([string]$m,$fix)  { Write-Host "  [X]  $m" -ForegroundColor Red;    Write-Host "       -> $fix" -ForegroundColor DarkGray; $script:Fail++ }
function Warn([string]$m,$fix) { Write-Host "  [!]  $m" -ForegroundColor Yellow; Write-Host "       -> $fix" -ForegroundColor DarkGray; $script:Warn++ }

Write-Host "Environment doctor - host: windows (PowerShell)`n"

# --- ruby ------------------------------------------------------------------
$ruby = Get-Command ruby -ErrorAction SilentlyContinue
if ($ruby) { Ok "ruby - $((& ruby -e 'print RUBY_VERSION' 2>$null))" }
else { Bad "ruby not found" "Install RubyInstaller (https://rubyinstaller.org), tick 'Add Ruby to PATH', reopen PowerShell." }

# --- python (reject the Microsoft Store App-Execution-Alias stub) ----------
# Detect by PATH first: the stub lives under ...\WindowsApps\. We check py -3,
# then python / python3, and accept the first whose interpreter is NOT in
# WindowsApps. (We avoid invoking a WindowsApps stub, which can pop the Store.)
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
$py = Test-RealPython 'py' '-3'
if ($py) { Ok "python - $py  [launcher: py -3]" }
else {
  $py = Test-RealPython 'python' $null
  if (-not $py) { $py = Test-RealPython 'python3' $null }
  if ($py) { Ok "python - $py" }
  else {
    Bad "no real Python (the 'python'/'python3' on PATH is likely the Microsoft Store alias stub)" `
        "Install Python from python.org (tick 'Add Python to PATH'), then use 'py -3'. OR disable the stub: Settings > Apps > Advanced app settings > App execution aliases > turn OFF python.exe / python3.exe. Re-run."
  }
}

# --- node ------------------------------------------------------------------
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) { Ok "node - $((& node --version 2>$null))" }
else { Bad "node not found (required - the vendored converters/*.mjs run via node)" `
           "Admin: install Node LTS from https://nodejs.org or 'winget install OpenJS.NodeJS.LTS'. NO admin: 'winget install Schniz.fnm' then 'fnm install --lts; fnm use --lts' (user-scoped, no admin). See refs/environment.md #5. Don't auto-download an unpinned Node - ask first." }

# --- bash (REQUIRED for get-token.sh / *-auth.sh token minting) ------------
$bash = Get-Command bash -ErrorAction SilentlyContinue
if ($bash) {
  Ok "bash - $($bash.Source) (run the *.sh helpers like get-token.sh from Git Bash, or 'bash scripts/get-token.sh')"
} else {
  $wsl = Get-Command wsl -ErrorAction SilentlyContinue
  if ($wsl) { Warn "no native bash, but WSL is present" "Run the *.sh helpers via WSL, or install Git for Windows (Git Bash) for a native bash." }
  else { Bad "no bash found - get-token.sh / *-auth.sh (Sigma token minting) cannot run" `
             "Install Git for Windows (https://git-scm.com/download/win) - it ships Git Bash - then run the *.sh helpers from Git Bash." }
}

# --- git autocrlf (CRLF mangles shebangs + bash scripts) -------------------
$crlf = (& git config --get core.autocrlf 2>$null)
if ($crlf -eq 'true') {
  Warn "git core.autocrlf=true - may rewrite shipped .sh/.rb/.py to CRLF and break them under bash" `
       "git config --global core.autocrlf input  (then re-clone / re-checkout)."
} else { Ok "git core.autocrlf=$(if ($crlf) {$crlf} else {'unset'}) (won't CRLF-mangle scripts)" }

# --- Sigma credentials (informational) -------------------------------------
$envFile = Join-Path $env:USERPROFILE ".sigma-migration\env"
if ((Test-Path $envFile) -or $env:SIGMA_API_TOKEN -or $env:SIGMA_CLIENT_ID) {
  Ok "Sigma credentials present (env or ~/.sigma-migration/env)"
} else {
  Warn "no Sigma credentials found" "Run 'ruby scripts/setup.rb' once, or set SIGMA_CLIENT_ID / SIGMA_CLIENT_SECRET."
}

Write-Host "`nSummary: $script:Pass ok, $script:Warn warning(s), $script:Fail missing/blocking."
if ($script:Fail -eq 0) { Write-Host "Environment looks good - proceed."; exit 0 }
Write-Host "Fix the [X] item(s) above, then re-run: powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1"
exit 1
