# git-config-sync one-click installer / uninstaller (Windows PowerShell).
# Only requires git and curl.exe (both standard on Windows 10 1803+).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 C:\path\to\gitconfig
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall

param(
  [string]$Source = '',
  [switch]$Uninstall,
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$REPO_RAW_BASE = 'https://raw.githubusercontent.com/mesopix/git-config/main'
$TOOL_NAME = 'git-config-sync'

# Non-ASCII output glyphs are built at runtime so this file can stay pure
# ASCII (Windows PowerShell 5.1 reads .ps1 files without a UTF-8 BOM as ANSI).
$OK = [string][char]0x2713
$WARN = [string][char]0x26A0
$DASH = [string][char]0x2014
$COLOR = -not [bool]$env:NO_COLOR

# The install flow buffers its lines so a no-op run prints a single summary
# line rather than a multi-line report that reads like a failure.
$script:NOTICES = @()
function Notice-Ok([string]$Msg) { $script:NOTICES += "$OK $Msg" }
function Notice-Warn([string]$Msg) { $script:NOTICES += "$WARN $Msg" }
function Write-Ok([string]$Msg) { if ($COLOR) { Write-Host "$OK $Msg" -ForegroundColor Green } else { Write-Host "$OK $Msg" } }
function Write-Warn([string]$Msg) { if ($COLOR) { Write-Host "$WARN $Msg" -ForegroundColor Yellow } else { Write-Host "$WARN $Msg" } }
function Die([string]$Msg) {
  if ($COLOR) { Write-Host "Error: $Msg" -ForegroundColor Red } else { Write-Host "Error: $Msg" }
  if ($script:DOWNLOADED_SELF -and (Test-Path -LiteralPath $script:DOWNLOADED_SELF)) {
    Write-Host "(the installer was kept at $($script:DOWNLOADED_SELF); fix the problem and re-run: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1)"
  }
  exit 1
}

# A downloaded copy of this script ("curl.exe -o install.ps1 && ...") is
# removed after success — but never one inside a repo clone.
$script:DOWNLOADED_SELF = $null
if ($PSCommandPath) {
  $self = (Resolve-Path -LiteralPath $PSCommandPath).Path
  if ((Split-Path -Leaf $self) -eq 'install.ps1') {
    $dir = Split-Path -Parent $self
    if ($dir -eq (Get-Location).Path) {
      if (-not (Test-Path -LiteralPath (Join-Path $dir 'config\gitconfig')) -and
          -not (Test-Path -LiteralPath (Join-Path $dir '.git'))) {
        $script:DOWNLOADED_SELF = $self
      }
    }
  }
}

function Cleanup-DownloadedSelf {
  if ($script:DOWNLOADED_SELF -and (Test-Path -LiteralPath $script:DOWNLOADED_SELF)) {
    try {
      Remove-Item -LiteralPath $script:DOWNLOADED_SELF -Force
      Write-Ok "removed downloaded installer: $($script:DOWNLOADED_SELF)"
    } catch {
      Write-Host "  (you can delete the installer manually: $($script:DOWNLOADED_SELF))"
    }
  }
}

# ── Managed locations ───────────────────────────────────
if (-not $env:APPDATA) { Die 'Environment variable APPDATA is not set; cannot determine the user config directory' }
$script:MANAGED_DIR = Join-Path $env:APPDATA $TOOL_NAME
$script:MANAGED = Join-Path $script:MANAGED_DIR 'gitconfig'
# git stores include.path verbatim; forward slashes work on every platform.
$script:MANAGED_INCLUDE = $script:MANAGED -replace '\\', '/'

# ── git helpers ─────────────────────────────────────────
function Require-Git {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die 'git not found: sync and syntax validation both require it. Install from https://git-scm.com/downloads'
  }
}

function Invoke-Git([string[]]$GitArgs) {
  $out = (& git @GitArgs 2>&1 | Out-String).Trim()
  return [pscustomobject]@{ Status = $LASTEXITCODE; Output = $out }
}

# Existing include.path values (empty when the key is absent, exit code 1).
function Get-IncludePaths {
  $r = Invoke-Git @('config', '--global', '--get-all', 'include.path')
  if ($r.Status -ne 0) { return @() }
  if (-not $r.Output) { return @() }
  return @($r.Output -split "`r?`n")
}

function Same-Path([string]$Left, [string]$Right) {
  return (($Left -replace '\\', '/') -ieq ($Right -replace '\\', '/'))
}

# Remove only the entries pointing at the managed file; include.path values
# belonging to other tools are preserved.
function Unset-IncludeEntries([string[]]$Spellings) {
  foreach ($stored in $Spellings) {
    $pattern = '^' + [regex]::Escape($stored) + '$'
    $r = Invoke-Git @('config', '--global', '--unset-all', 'include.path', $pattern)
    if ($r.Status -ne 0 -and $r.Status -ne 5) {
      Die "unable to update global include.path: $($r.Output)"
    }
  }
}

# ── include.path management ─────────────────────────────
# Idempotent: nothing is written when exactly one matching entry already
# exists. Duplicate or differently-spelled matches collapse into one.
function Ensure-Include {
  $found = @(Get-IncludePaths | Where-Object { Same-Path $_ $script:MANAGED_INCLUDE })
  if ($found.Count -eq 1 -and $found[0] -eq $script:MANAGED_INCLUDE) {
    Notice-Ok "global include.path already set: $script:MANAGED_INCLUDE"
    return $false
  }
  if ($found.Count -gt 1) {
    Notice-Warn "found $($found.Count) duplicate include.path entries; merging into one"
  }
  if ($found.Count -gt 0) {
    Unset-IncludeEntries ($found | Select-Object -Unique)
  }
  $r = Invoke-Git @('config', '--global', '--add', 'include.path', $script:MANAGED_INCLUDE)
  if ($r.Status -ne 0) { Die "unable to write global include.path: $($r.Output)" }
  Notice-Ok "added include.path to global config: $script:MANAGED_INCLUDE"
  return $true
}

# ── Managed file install (temp + rename, atomic) ────────
# Validate the source via git BEFORE replacing anything, so a broken file
# aborts with the previous install untouched.
function Install-Managed([string]$SourcePath) {
  if (Test-Path -LiteralPath $script:MANAGED) {
    $a = (Get-FileHash -LiteralPath $script:MANAGED -Algorithm MD5).Hash
    $b = (Get-FileHash -LiteralPath $SourcePath -Algorithm MD5).Hash
    if ($a -eq $b) {
      Notice-Ok "managed config is already up to date: $script:MANAGED"
      return $false
    }
    Notice-Warn "existing managed config differs from the source and will be overwritten $DASH local changes will be lost"
  }
  New-Item -ItemType Directory -Force -Path $script:MANAGED_DIR | Out-Null
  $temp = Join-Path $script:MANAGED_DIR ".gitconfig-$PID.tmp"
  Copy-Item -LiteralPath $SourcePath -Destination $temp -Force
  $r = Invoke-Git @('config', '--file', $temp, '--list')
  if ($r.Status -ne 0) {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    Die "invalid gitconfig source:`n$($r.Output)"
  }
  Move-Item -LiteralPath $temp -Destination $script:MANAGED -Force
  Notice-Ok "installed managed config: $script:MANAGED"
  return $true
}

# ── Source resolution ───────────────────────────────────
$script:SRC_TMP = $null
function Resolve-Source([string]$ExplicitPath) {
  if ($ExplicitPath) {
    if (-not (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) { Die "file not found: $ExplicitPath" }
    $p = (Resolve-Path -LiteralPath $ExplicitPath).Path
    Notice-Ok "using local source: $p"
    return $p
  }
  if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Die 'curl.exe not found: downloading config/gitconfig requires it (Windows 10 1803 or newer)'
  }
  $tmp = [IO.Path]::GetTempFileName()
  $url = "$REPO_RAW_BASE/config/gitconfig"
  $code = & curl.exe -sSL -o $tmp -w '%{http_code}' $url 2>$null
  if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Die "download failed: $url"
  }
  if ($code -ne '200') {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Die "download failed: HTTP $code ($url)"
  }
  Notice-Ok 'fetched config/gitconfig from GitHub'
  $script:SRC_TMP = $tmp
  return $tmp
}

# ── Install ─────────────────────────────────────────────
function Do-Install([string]$ExplicitPath) {
  Require-Git
  $src = Resolve-Source $ExplicitPath
  $fileChanged = Install-Managed $src
  $incChanged = Ensure-Include
  if ($script:SRC_TMP -and (Test-Path -LiteralPath $script:SRC_TMP)) {
    Remove-Item -LiteralPath $script:SRC_TMP -Force
  }

  # Tailor the closing output: a no-op run prints one affirmative line,
  # so it can't be mistaken for a failure.
  if (-not $fileChanged -and -not $incChanged) {
    if ($COLOR) { Write-Host "Already up to date $DASH nothing to do." -ForegroundColor Green }
    else { Write-Host "Already up to date $DASH nothing to do." }
  } else {
    $script:NOTICES | ForEach-Object { Write-Host $_ }
    if ($COLOR) { Write-Host 'Sync complete. Managed config overrides same-name global settings and takes effect immediately.' -ForegroundColor Green }
    else { Write-Host 'Sync complete. Managed config overrides same-name global settings and takes effect immediately.' }
  }
  Cleanup-DownloadedSelf
}

# ── Uninstall ───────────────────────────────────────────
function Do-Uninstall {
  Require-Git
  $changed = $false
  $found = @(Get-IncludePaths | Where-Object { Same-Path $_ $script:MANAGED_INCLUDE })
  if ($found.Count -gt 0) {
    Unset-IncludeEntries ($found | Select-Object -Unique)
    Write-Ok "removed include.path entry pointing to the managed file: $script:MANAGED_INCLUDE"
    $changed = $true
  }
  if (Test-Path -LiteralPath $script:MANAGED) {
    Remove-Item -LiteralPath $script:MANAGED -Force
    Write-Ok "deleted $script:MANAGED"
    try { Remove-Item -LiteralPath $script:MANAGED_DIR -Force -ErrorAction Stop } catch { }
    $changed = $true
  }
  if ($changed) {
    if ($COLOR) { Write-Host 'Uninstall complete. Other global config and include.path entries were not touched.' -ForegroundColor Green }
    else { Write-Host 'Uninstall complete. Other global config and include.path entries were not touched.' }
  } else {
    if ($COLOR) { Write-Host 'Nothing to uninstall.' -ForegroundColor Green }
    else { Write-Host 'Nothing to uninstall.' }
  }
  Cleanup-DownloadedSelf
}

# ── Main ────────────────────────────────────────────────
if ($Help) {
  Write-Host 'Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 C:\path\to\gitconfig
  powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Uninstall'
  exit 0
}
if ($Uninstall) { Do-Uninstall; exit 0 }
Do-Install $Source
