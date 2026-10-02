<#
    Install the Windows ADK + WinPE add-on (Deployment Tools + WinPE).

    NOTE: adksetup.exe / adkwinpesetup.exe in this folder are ONLINE bootstrappers
    (~1.5 MB) that download payload from Microsoft at runtime - internet access is
    required. This script installs the base ADK FIRST (it provides Deployment Tools,
    DISM, DandISetEnv, oscdimg and the KitsRoot10 registry value), checks the real
    exit code of each installer, writes logs, and verifies the result - so a failed
    ADK download can no longer be silently swallowed while the WinPE add-on succeeds.

    Targets ADK 10.1.26100.9457 (September 2026; replaces 2454, whose online payloads
    were re-signed and now fail hash verification with 0x80091007). Do not use the
    26H1 Arm64 kit (10.1.28000.1) - its WinPE will not bind x64 NIC drivers.
    After install it applies any ADK servicing patch staged in this folder as
    Windows_ADK_*Update*.zip (see learn.microsoft.com adk-servicing for the current KB).
#>

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-Location $PSScriptRoot

$LocalPath = 'C:\temp\ADK'
$LogDir    = 'C:\temp\ADK-logs'   # kept outside $LocalPath so logs survive cleanup
New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir    -Force | Out-Null

# Recurse in case a future offline layout ships an Installers\ payload folder.
Copy-Item -Path "$PSScriptRoot\*" -Destination $LocalPath -Recurse -Force

function Invoke-AdkSetup {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Features,
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][string]$Label
    )
    if (-not (Test-Path $Exe)) { throw "$Label installer not found: $Exe" }
    $argLine = "/quiet /norestart /features $Features /log `"$LogFile`""
    Write-Host "Installing $Label ..." -ForegroundColor Cyan
    $p = Start-Process -FilePath $Exe -ArgumentList $argLine -Wait -PassThru
    switch ($p.ExitCode) {
        0       { Write-Host "  $Label installed (exit 0)." -ForegroundColor Green }
        3010    { Write-Host "  $Label installed - reboot required (exit 3010)." -ForegroundColor Yellow }
        default { throw "$Label FAILED (exit $($p.ExitCode)). See log: $LogFile" }
    }
}

# 1. Base ADK first - Deployment Tools (DISM, DandISetEnv, oscdimg, KitsRoot10).
Invoke-AdkSetup -Exe "$LocalPath\adksetup.exe" `
    -Features 'OptionId.DeploymentTools' `
    -LogFile "$LogDir\adksetup.log" -Label 'Windows ADK (Deployment Tools)'

# 2. WinPE add-on second - depends on the base ADK; provides copype + WinPE OCs.
Invoke-AdkSetup -Exe "$LocalPath\adkwinpesetup.exe" `
    -Features 'OptionId.WindowsPreinstallationEnvironment' `
    -LogFile "$LogDir\adkwinpe.log" -Label 'Windows PE add-on'

# 2.5 Apply a staged ADK servicing patch, if any. The patch ships as a zip of .msp files;
#     only patches for installed features apply. msiexec returns 1642
#     (ERROR_PATCH_TARGET_NOT_FOUND) for tools we do not install (WSIM, VAMT, OA3, AppMan)
#     - that is expected and skipped, not a failure.
$patchZip = Get-ChildItem $LocalPath -Filter 'Windows_ADK_*Update*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($patchZip) {
    $patchDir = Join-Path $LocalPath 'PatchExpand'
    Remove-Item $patchDir -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $patchZip.FullName -DestinationPath $patchDir -Force
    $msps = @(Get-ChildItem $patchDir -Recurse -Filter *.msp)
    Write-Host "Applying ADK patch $($patchZip.BaseName) ($($msps.Count) .msp) ..." -ForegroundColor Cyan
    $applied = 0; $skipped = 0
    foreach ($msp in $msps) {
        $log = Join-Path $LogDir "msp-$($msp.BaseName).log"
        $p = Start-Process msiexec.exe -ArgumentList "/p `"$($msp.FullName)`" /qn /norestart /l* `"$log`"" -Wait -PassThru
        switch ($p.ExitCode) {
            0       { $applied++ }
            3010    { $applied++; Write-Host "  $($msp.Name): applied (reboot required)." -ForegroundColor Yellow }
            1642    { $skipped++ }   # target product not installed - expected
            default { throw "ADK patch '$($msp.Name)' FAILED (exit $($p.ExitCode)). See log: $log" }
        }
    }
    Write-Host "  ADK patch complete: $applied applied, $skipped skipped (not installed)." -ForegroundColor Green
} else {
    Write-Host "No ADK servicing patch staged (Windows_ADK_*Update*.zip) - skipping." -ForegroundColor Yellow
}

# 3. Verify the install actually landed (read KitsRoot10 defensively under StrictMode).
$kitsRoot = $null
foreach ($rk in @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots')) {
    $key = Get-Item $rk -ErrorAction SilentlyContinue
    if ($key) { $v = $key.GetValue('KitsRoot10'); if ($v) { $kitsRoot = $v; break } }
}
$copype = if ($kitsRoot) { Join-Path $kitsRoot 'Assessment and Deployment Kit\Windows Preinstallation Environment\copype.cmd' } else { $null }
if ($kitsRoot -and (Test-Path $copype)) {
    Write-Host "ADK + WinPE verified at: $kitsRoot" -ForegroundColor Green
} else {
    throw "ADK/WinPE verification failed (KitsRoot10 or copype.cmd missing). Check logs in $LogDir."
}

Remove-Item -Path $LocalPath -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Done. Installer logs retained in $LogDir." -ForegroundColor Cyan
