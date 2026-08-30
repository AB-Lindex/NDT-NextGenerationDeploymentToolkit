# VMware Tools install step.
# Runs in Phase 2 (step engine). Only proceeds on VMware guests - detected hardware
# is read from C:\temp\settings.json (written by Copy-Install.ps1); falls back to a
# live Get-Hardware.ps1 query if the share is mapped and the block is missing.
# NOTE: the actual setup.exe invocation is intentionally NOT wired up yet - see below.

[CmdletBinding()]
param()

# Resolve detected platform: prefer the persisted value, fall back to a live query.
$platform = $null
$settingsPath = 'C:\temp\settings.json'
if (Test-Path $settingsPath) {
    try {
        $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
        if ($settings.Hardware) { $platform = $settings.Hardware.Platform }
    } catch {
        Write-Warning "Could not read Hardware block from settings.json: $_"
    }
}
if (-not $platform) {
    $getHardware = 'Z:\Scripts\unattend2026\Get-Hardware.ps1'
    if (Test-Path $getHardware) { $platform = (& $getHardware).Platform }
}

Write-Host "Detected platform: $platform" -ForegroundColor Cyan

if ($platform -ne 'VMware') {
    Write-Host "Not a VMware guest - skipping VMware Tools." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# VMware Tools setup
# ---------------------------------------------------------------------------
# TODO: not installing yet - only resolving the installer path for now.
$setup = Join-Path $PSScriptRoot 'setup.exe'
if (-not (Test-Path $setup)) {
    Write-Warning "VMware Tools setup.exe not found at: $setup"
    exit 0
}

Write-Host "VMware Tools setup located: $setup" -ForegroundColor Green
# $process = Start-Process -FilePath $setup `
#     -ArgumentList '/S', '/v', '/qn REBOOT=R' `
#     -Wait -PassThru
# if ($process.ExitCode -notin 0, 3010) {
#     Write-Error "VMware Tools installation failed with exit code $($process.ExitCode)"
#     exit $process.ExitCode
# }
# exit $process.ExitCode

exit 0
