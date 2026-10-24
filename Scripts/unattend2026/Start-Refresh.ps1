<#
.SYNOPSIS
    Re-images THIS machine in place (MDT "Refresh"-style, without user-state backup).
.DESCRIPTION
    Run from inside the running OS, elevated, straight from the deploy share:

        \\dc01.corp.dev\Deploy2026\Scripts\unattend2026\Start-Refresh.ps1

    1. Validates this machine against the share (MAC block in CustomSettings.json or
       Control\Projects, Install:NO guard, OS key -> OS.json -> WIM file exists, PE ISO exists).
    2. Asks you to type the computer name (skip with -Force).
    3. Copies boot.wim + boot.sdi from Boot\boot2026.iso to C:\NDT-PE and adds a
       ONE-SHOT ramdisk BCD entry (bcdedit /bootsequence) for WinPE.
    4. Reboots. WinPE then runs the normal NDT flow (install.ps1): validate MAC,
       partition disk 0, apply the WIM, unattend, first-boot step engine.

    Nothing on disk is wiped by this script; the disk is only touched by WinPE after
    its own pre-flight checks pass. If WinPE aborts before partitioning, the one-shot
    entry means the next boot returns to the current Windows. Re-running this script
    removes any leftover NDT-PE files and BCD entries from an earlier attempt.

    Must stay PS 5.1 compatible and ASCII-only.
.PARAMETER Force
    Skip the "type the computer name" confirmation.
.PARAMETER MacAddress
    Override MAC detection (colon- or dash-separated). Default: first IP-enabled adapter
    whose MAC has a block in CustomSettings.json or Control\Projects.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [string]$MacAddress
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * 38) -ForegroundColor Cyan
}

function Invoke-Bcd {
    param([string[]]$Arguments)
    $out = & bcdedit.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "bcdedit $($Arguments -join ' ') failed: $out" }
    return ($out | Out-String)
}

function Get-BcdGuid([string]$Text) {
    $m = [regex]::Match($Text, '\{[0-9a-fA-F-]{36}\}')
    if (-not $m.Success) { throw "No GUID found in bcdedit output: $Text" }
    return $m.Value
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error 'This script must be run as Administrator.'; exit 1 }

# This script lives at <share>\Scripts\unattend2026
$shareRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$isoPath   = Join-Path $shareRoot 'Boot\boot2026.iso'
$sysDrive  = $env:SystemDrive
$peDir     = Join-Path $sysDrive 'NDT-PE'
$stateFile = Join-Path $peDir 'bcd-guids.txt'

Write-Host '========================================'
Write-Host 'NDT Refresh - re-image this computer'
Write-Host '========================================'
Write-Host "Share root : $shareRoot"
Write-Host "Computer   : $env:COMPUTERNAME"

# ------------------------------------------------------------------
# STEP 1 - Validate against the deploy share (mirrors WinPE install.ps1 checks)
# ------------------------------------------------------------------
Write-Step 'Step 1: Validating configuration...'

$csPath = Join-Path $shareRoot 'Control\CustomSettings.json'
foreach ($f in @($csPath, (Join-Path $shareRoot 'Control\OS.json'), (Join-Path $shareRoot 'Control\Sections.json'))) {
    if (-not (Test-Path $f)) { Write-Error "Not found: $f (is this script being run from the deploy share?)"; exit 1 }
}

. (Join-Path $PSScriptRoot 'Import-NDTModule.ps1')
$machineSource = @{}
try { $cs = Get-NDTMachine -LocalPath $shareRoot -SourceMap $machineSource }
catch { Write-Error $_.Exception.Message; exit 1 }

if ($MacAddress) {
    $candidates = @($MacAddress.ToUpper().Replace('-', ':'))
} else {
    $candidates = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' | ForEach-Object { $_.MACAddress })
}
if ($candidates.Count -eq 0) { Write-Error 'No IP-enabled network adapter found.'; exit 1 }

$mac = $candidates | Where-Object { $_ -and $cs.PSObject.Properties[$_] } | Select-Object -First 1
if (-not $mac) {
    Write-Error "None of this machine's MAC addresses ($($candidates -join ', ')) has a block in CustomSettings.json or Control\Projects."
    exit 1
}
if ($mac -ne $candidates[0]) {
    # WinPE install.ps1 uses the first IP-enabled adapter; a different order there would fail the MAC lookup.
    Write-Warning "Matched MAC $mac is not the first IP-enabled adapter ($($candidates[0])). WinPE picks the first adapter it sees."
}

$machine = $cs.$mac
if (Test-NDTInstallDisabled -Machine $machine) {
    Write-Error "Install is set to NO for $mac ($($machine.Computername)). Deployment is disabled for this machine."
    exit 1
}

$osInfo = & (Join-Path $PSScriptRoot 'Get-OS.ps1') -MACAddress $mac -ShareRoot $shareRoot
if (-not $osInfo -or -not $osInfo.Path) { Write-Error "Could not resolve OS for $mac."; exit 1 }

$osKey   = $osInfo.OsKey
$wimPath = $osInfo.Path
if (-not (Test-Path $wimPath)) { Write-Error "WIM not found: $wimPath"; exit 1 }
if (-not (Test-Path $isoPath)) { Write-Error "WinPE ISO not found: $isoPath (build it with New-NDTPEImage)"; exit 1 }

$firmware = if ($env:firmware_type -eq 'UEFI') { 'UEFI' } else { 'BIOS' }

Write-Host "  MAC          : $mac"
Write-Host "  Config file  : Control\$($machineSource[$mac.ToUpper()])"
Write-Host "  Target name  : $($machine.Computername)"
Write-Host "  OS           : $osKey"
Write-Host "  WIM          : $wimPath (index $($osInfo.Index))"
Write-Host "  Firmware     : $firmware"
Write-Host "  PE ISO       : $isoPath"

# ------------------------------------------------------------------
# STEP 2 - Confirm
# ------------------------------------------------------------------
if (-not $Force) {
    Write-Host ''
    Write-Warning 'ALL DATA on disk 0 of this computer will be erased and the OS re-installed.'
    $typed = Read-Host "Type this computer's name ($env:COMPUTERNAME) to continue"
    if ($typed -ne $env:COMPUTERNAME) { Write-Host 'Name did not match. Aborted - nothing changed.' -ForegroundColor Yellow; exit 1 }
}

# ------------------------------------------------------------------
# STEP 3 - Stage WinPE locally (clean up any earlier attempt first)
# ------------------------------------------------------------------
Write-Step 'Step 2: Staging WinPE on the local disk...'

if (Test-Path $stateFile) {
    foreach ($g in (Get-Content $stateFile)) {
        if ($g -match '^\{[0-9a-fA-F-]{36}\}$') { & bcdedit.exe /delete $g /cleanup 2>&1 | Out-Null }
    }
}
if (Test-Path $peDir) { Remove-Item $peDir -Recurse -Force }
New-Item -ItemType Directory -Path $peDir -Force | Out-Null

# Mount-DiskImage does not work reliably on UNC paths, so mount a local copy.
$localIso = Join-Path $peDir 'boot2026.iso'
Copy-Item $isoPath $localIso -Force
try {
    $mount    = Mount-DiskImage -ImagePath $localIso -PassThru
    $isoDrive = ($mount | Get-Volume).DriveLetter + ':'
    foreach ($f in @('Boot\boot.sdi', 'sources\boot.wim')) {
        if (-not (Test-Path (Join-Path $isoDrive $f))) { throw "Expected file not found inside ISO: $f" }
    }
    Copy-Item (Join-Path $isoDrive 'Boot\boot.sdi')      (Join-Path $peDir 'boot.sdi') -Force
    Copy-Item (Join-Path $isoDrive 'sources\boot.wim')   (Join-Path $peDir 'boot.wim') -Force
} finally {
    Dismount-DiskImage -ImagePath $localIso -ErrorAction SilentlyContinue | Out-Null
    Remove-Item $localIso -Force -ErrorAction SilentlyContinue
}
Write-Host "  [OK] boot.wim + boot.sdi staged in $peDir"

# ------------------------------------------------------------------
# STEP 4 - One-shot ramdisk BCD entry (own ramdisk-options object; {ramdiskoptions} is left alone)
# ------------------------------------------------------------------
Write-Step 'Step 3: Adding one-shot WinPE boot entry...'

$rdGuid = Get-BcdGuid (Invoke-Bcd @('/create', '/d', 'NDT Ramdisk Options', '/device'))
Invoke-Bcd @('/set', $rdGuid, 'ramdisksdidevice', "partition=$sysDrive") | Out-Null
Invoke-Bcd @('/set', $rdGuid, 'ramdisksdipath', '\NDT-PE\boot.sdi') | Out-Null

$peGuid = Get-BcdGuid (Invoke-Bcd @('/create', '/d', 'NDT Refresh WinPE', '/application', 'OSLOADER'))
Set-Content -Path $stateFile -Value @($peGuid, $rdGuid) -Encoding ASCII

$ramdisk = "ramdisk=[$sysDrive]\NDT-PE\boot.wim,$rdGuid"
$winload = if ($firmware -eq 'UEFI') { '\windows\system32\boot\winload.efi' } else { '\windows\system32\boot\winload.exe' }
Invoke-Bcd @('/set', $peGuid, 'device', $ramdisk) | Out-Null
Invoke-Bcd @('/set', $peGuid, 'osdevice', $ramdisk) | Out-Null
Invoke-Bcd @('/set', $peGuid, 'path', $winload) | Out-Null
Invoke-Bcd @('/set', $peGuid, 'systemroot', '\windows') | Out-Null
Invoke-Bcd @('/set', $peGuid, 'detecthal', 'yes') | Out-Null
Invoke-Bcd @('/set', $peGuid, 'winpe', 'yes') | Out-Null
Invoke-Bcd @('/displayorder', $peGuid, '/addlast') | Out-Null
# One-shot: the next boot goes to WinPE, every later boot uses the normal default.
Invoke-Bcd @('/bootsequence', $peGuid) | Out-Null
Write-Host "  [OK] WinPE entry $peGuid set as one-time boot"

# BCD change + reading the ramdisk from C: would otherwise trigger a BitLocker recovery prompt. Best-effort.
# manage-bde.exe is absent when the BitLocker feature is not installed (e.g. Server).
if (Get-Command manage-bde.exe -ErrorAction SilentlyContinue) {
    & manage-bde.exe -protectors -disable $sysDrive -RebootCount 1 2>&1 | Out-Null
}

# ------------------------------------------------------------------
# STEP 5 - Reboot into WinPE
# ------------------------------------------------------------------
Write-Step 'Step 4: Rebooting into WinPE...'
Write-Host '  WinPE will run the NDT deployment unattended. To cancel: shutdown /a (within 15 seconds).'
& shutdown.exe /r /t 15 /c 'NDT Refresh: rebooting into WinPE to re-image this computer'
