<#
    Install the Windows ADK + WinPE add-on (Deployment Tools + WinPE).

    NOTE: adksetup.exe / adkwinpesetup.exe in this folder are ONLINE bootstrappers
    (~1.5 MB) that download payload from Microsoft at runtime - internet access is
    required. This script installs the base ADK FIRST (it provides Deployment Tools,
    DISM, DandISetEnv, oscdimg and the KitsRoot10 registry value), checks the real
    exit code of each installer, writes logs, and verifies the result - so a failed
    ADK download can no longer be silently swallowed while the WinPE add-on succeeds.

    Targets the stable ADK 10.1.26100.2454 (Windows Server 2025 generation) - the
    26H1 Arm64 preview kit (10.1.28000.1) builds a WinPE that will not bind x64 NIC
    drivers. After install it applies the ADK servicing patch KB5101684 (CVE-2026-25166,
    WSIM) from the Windows_ADK_*Update*.zip in this folder, if present.
#>

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Set-Location $PSScriptRoot

$LocalPath = 'C:\temp\ADK'
$LogDir    = 'C:\temp\ADK-logs'   # kept outside $LocalPath so logs survive cleanup
# Official Microsoft aka.ms link for the ADK 26100.2454 servicing patch (KB5101684).
# Used only as a fallback when the zip is not staged in this folder.
$PatchZipUrl = 'https://aka.ms/Windows_ADK_10.1.26100.2454_Update_KB5101684.zip'
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

# 2.5 Apply the ADK servicing patch (KB5101684 / CVE-2026-25166). The patch ships as a
#     zip of .msp files; only patches for installed features apply. msiexec returns 1642
#     (ERROR_PATCH_TARGET_NOT_FOUND) for tools we do not install (WSIM, VAMT, OA3, AppMan)
#     - that is expected and skipped, not a failure.
$patchZip = Get-ChildItem $LocalPath -Filter 'Windows_ADK_*Update*.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $patchZip) {
    # Not staged locally - download it from Microsoft (requires internet).
    try {
        $dest = Join-Path $LocalPath 'Windows_ADK_10.1.26100.2454_Update_KB5101684.zip'
        Write-Host "ADK patch zip not found locally - downloading KB5101684 from Microsoft..." -ForegroundColor Cyan
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $PatchZipUrl -OutFile $dest -UseBasicParsing
        $patchZip = Get-Item $dest
    } catch {
        Write-Warning "Could not download ADK patch from $PatchZipUrl : $_"
    }
}
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
    Write-Warning "ADK servicing patch not available (not staged and download failed) - apply KB5101684+ manually for CVE-2026-25166."
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
