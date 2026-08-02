<#
    install-custom.ps1

    Complement to install.ps1 - run it AFTER install.ps1 has completed.

    install.ps1 (via Install-NDT) refreshes LocalPath from the public GitHub ZIP,
    which does not contain the local-only artefacts needed for a complete dev
    environment. This script copies those in from the local working copy:
      - the untracked Applications2026\ folder (site-specific installers)
      - every .pfx certificate present in the local working copy

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

# Applications2026 : site-specific installers
$app2026Src = Join-Path $RepoRoot 'Applications2026'
if (Test-Path $app2026Src) {
    $app2026Dst = Join-Path $LocalPathFull 'Applications2026'
    if ($app2026Dst -ne (Resolve-Path $app2026Src).Path) {
        Write-Host "Copying Applications2026 -> $app2026Dst" -ForegroundColor Cyan
        Copy-Item -Path $app2026Src -Destination $LocalPathFull -Recurse -Force
    }
    else {
        Write-Host 'Applications2026 already in place (local repo is the deploy path).' -ForegroundColor DarkGray
    }
}
else {
    Write-Warning "Applications2026 not found at '$app2026Src' - skipping."
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
