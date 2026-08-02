<#
    install-custom.ps1

    Complement to install.ps1 - run it AFTER install.ps1 has completed.

    install.ps1 (via Install-NDT) refreshes LocalPath from the public GitHub ZIP,
    which does not contain the local-only artefacts needed for a complete dev
    environment. This script copies those in from the local working copy:
      - the untracked Applications2026\ folder (site-specific installers)
      - every .pfx certificate present in the local working copy

    It then installs the NDT Monitor, which install.ps1 skips (-SkipMonitor)
    because the stock repo has no HTTPS certificate. The monitor's PFX is now in
    place from the copy step above, so the IIS progress web service can be built.

    Run this from your local repo (it copies from the folder this script ships in).
#>

[CmdletBinding()]
param(
    [string]$LocalPath = 'C:\Deploy2026'
)

$ErrorActionPreference = 'Stop'

# Root of the local working copy: ...\Deploy2026\Applications\NDT Setup\ -> ...\Deploy2026
$RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$LocalPathFull = (Resolve-Path $LocalPath).Path

# Only run for a custom dev setup. No Applications2026 folder means this is a
# stock NDT deploy - nothing custom to add, so exit.
$app2026Src = Join-Path $RepoRoot 'Applications2026'
if (-not (Test-Path $app2026Src)) {
    Write-Host "Applications2026 not found at '$app2026Src' - stock deploy, nothing to do." -ForegroundColor DarkGray
    return
}

# Applications2026 : site-specific installers
$app2026Dst = Join-Path $LocalPathFull 'Applications2026'
if ($app2026Dst -ne (Resolve-Path $app2026Src).Path) {
    Write-Host "Copying Applications2026 -> $app2026Dst" -ForegroundColor Cyan
    Copy-Item -Path $app2026Src -Destination $LocalPathFull -Recurse -Force
}
else {
    Write-Host 'Applications2026 already in place (local repo is the deploy path).' -ForegroundColor DarkGray
}

# .pfx certificates : preserve their relative folder layout under LocalPath
$pfxFiles = Get-ChildItem -Path $RepoRoot -Filter '*.pfx' -Recurse -File -ErrorAction SilentlyContinue
if ($pfxFiles) {
    foreach ($pfx in $pfxFiles) {
        $relative = $pfx.FullName.Substring($RepoRoot.Length).TrimStart('\')
        $dest     = Join-Path $LocalPathFull $relative
        if ($dest -eq $pfx.FullName) { continue }   # local repo is the deploy path
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Write-Host "Copying $relative" -ForegroundColor Cyan
        Copy-Item -Path $pfx.FullName -Destination $dest -Force
    }
}
else {
    Write-Warning "No .pfx files found under '$RepoRoot'."
}

# NDT Monitor : install.ps1 skips it (-SkipMonitor); the PFX is now in place, so build it here
Write-Host "`nInstalling NDT Monitor..." -ForegroundColor Cyan
Install-NDTMonitor -LocalPath $LocalPathFull
