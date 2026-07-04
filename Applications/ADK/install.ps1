<#
    Install the Windows ADK + WinPE add-on (Deployment Tools + WinPE).

    NOTE: adksetup.exe / adkwinpesetup.exe in this folder are ONLINE bootstrappers
    (~1.5 MB) that download payload from Microsoft at runtime - internet access is
    required. This script installs the base ADK FIRST (it provides Deployment Tools,
    DISM, DandISetEnv, oscdimg and the KitsRoot10 registry value), checks the real
    exit code of each installer, writes logs, and verifies the result - so a failed
    ADK download can no longer be silently swallowed while the WinPE add-on succeeds.
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
