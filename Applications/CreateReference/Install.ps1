<#
.SYNOPSIS
    Creates a reference image by running sysprep and preparing for capture
.DESCRIPTION
    This script prepares a Windows installation as a reference image by:
    1. Running sysprep to generalize the system
    2. System will shutdown and boot into WinPE for capture
    3. (Capture will be performed from WinPE environment)
#>

[CmdletBinding()]
param(
    [string]$SysprepAnswerFile = "$PSScriptRoot\unattend-sysprep.xml",
    [string]$CaptureScriptPath = "Z:\Applications\CreateReference\Capture-ReferenceImage.ps1"
)

Write-Output "========================================"
Write-Output "Reference Image Creation Script"
Write-Output "========================================"
Write-Output ""

# Verify running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Display current system information
Write-Output "Current System Information:"
Write-Output "  Computer Name: $env:COMPUTERNAME"
Write-Output "  OS Version: $((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Output "  Build Number: $((Get-CimInstance Win32_OperatingSystem).BuildNumber)"
Write-Output ""

# Confirm before proceeding
Write-Warning "This script will generalize this system and shut it down."
Write-Warning "After shutdown, boot into Windows PE to capture the image."
Write-Output ""
$confirm = Read-Host "Are you ready to proceed? (yes/no)"
if ($confirm -ne "yes") {
    Write-Output "Operation cancelled by user."
    exit 0
}

# Step 1: Prepare for sysprep
Write-Output ""
Write-Output "Step 1: Preparing for Sysprep..."
Write-Output "--------------------------------------"

# Clean up temporary files
Write-Output "Cleaning temporary files..."
try {
    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "  [OK] Temporary files cleaned"
} catch {
    Write-Warning "  Some temporary files could not be removed: $_"
}

# Clear event logs (optional)
Write-Output "Clearing event logs..."
try {
    wevtutil el | ForEach-Object { wevtutil cl $_ } 2>$null
    Write-Output "  [OK] Event logs cleared"
} catch {
    Write-Warning "  Could not clear all event logs: $_"
}

# Step 2: Create automation flag for PE capture
Write-Output ""
Write-Output "Step 2: Creating automation flag..."
Write-Output "--------------------------------------"

# Create a flag file to signal PE environment to run capture instead of deployment
$captureFlagFile = "C:\DeployCapture.flag"
$captureFlagContent = @{
    Action = "Capture"
    CaptureScript = "Z:\Applications\CreateReference\Capture-ReferenceImage.ps1"
    CreatedDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    ImageName = "Windows Server 2025 Reference"
    OutputPath = "Z:\Reference\ref-image.wim"
}

try {
    $captureFlagContent | ConvertTo-Json | Set-Content -Path $captureFlagFile -Force
    Write-Output "  [OK] Capture flag created: $captureFlagFile"
    Write-Output "  PE environment will detect this file and run capture automatically"
} catch {
    Write-Warning "  Could not create flag file: $_"
}

# Step 3: Configure BCD to boot WinPE from the local disk (MDT-style, no ISO/DVD needed)
# This is exactly how MDT's LTIApply.wsf InstallPE() works:
#   1. Copy boot.sdi and the WinPE WIM to the boot partition
#   2. Add a RamDisk BCD entry pointing at the WIM
#   3. Set it as the default with a 30-second timeout
# On next reboot Windows Boot Manager boots WinPE automatically — zero manual interaction.
Write-Output ""
Write-Output "Step 3: Configuring BCD for automatic WinPE boot (MDT-style)..."
Write-Output "--------------------------------------"

$useReboot  = $true
$bootDrive  = $env:SystemDrive          # C:   (boot partition = OS partition on Gen 1)
$wimSrc     = "Z:\Boot\boot2026.wim"    # WinPE WIM on the deployment share
$wimDest    = "$bootDrive\sources\boot.wim"
$sdiDest    = "$bootDrive\Boot\boot.sdi"
$guidFile   = "$bootDrive\WinPE-BCD-GUID.txt"  # saved so Capture-ReferenceImage.ps1 can clean up

# --- 3a: Get boot.sdi (required for the RAM disk) from the PE ISO ----------
Write-Output "  Extracting boot.sdi from boot2026.iso..."
$isoPath = "Z:\Boot\boot2026.iso"
if (-not (Test-Path $isoPath)) {
    Write-Error "ISO not found at $isoPath — cannot extract boot.sdi"
    exit 1
}
try {
    $mount      = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    $isoDrive   = ($mount | Get-Volume).DriveLetter + ":"
    $sdiSource  = "$isoDrive\Boot\boot.sdi"
    if (-not (Test-Path $sdiSource)) {
        Write-Error "boot.sdi not found inside ISO at $sdiSource"
        Dismount-DiskImage -ImagePath $isoPath | Out-Null
        exit 1
    }
    New-Item -ItemType Directory -Force -Path "$bootDrive\Boot" | Out-Null
    Copy-Item -Path $sdiSource -Destination $sdiDest -Force
    Write-Output "  [OK] boot.sdi copied to $sdiDest"
} catch {
    Write-Error "Failed to mount ISO or copy boot.sdi: $_"
    exit 1
} finally {
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
}

# --- 3b: Copy the WinPE WIM to C:\sources\ -----------------------------------
Write-Output "  Copying WinPE WIM to $wimDest..."
New-Item -ItemType Directory -Force -Path "$bootDrive\sources" | Out-Null
try {
    Copy-Item -Path $wimSrc -Destination $wimDest -Force -ErrorAction Stop
    Write-Output "  [OK] WinPE WIM copied ($([math]::Round((Get-Item $wimDest).Length/1MB)) MB)"
} catch {
    Write-Error "Failed to copy WinPE WIM: $_"
    exit 1
}

# --- 3c: Configure BCD (mirrors MDT LTIApply.wsf InstallPE / ZTIBCDUtility) -
Write-Output "  Configuring BCD..."

# Ensure {ramdiskoptions} entry exists
$enumRam = & bcdedit /enum "{ramdiskoptions}" 2>&1
if ($LASTEXITCODE -ne 0) {
    & bcdedit /create "{ramdiskoptions}" /d "Ramdisk Options" | Out-Null
}
& bcdedit /set "{ramdiskoptions}" ramdisksdidevice boot     | Out-Null
& bcdedit /set "{ramdiskoptions}" ramdisksdipath  \Boot\boot.sdi | Out-Null

# Create a new OSLOADER entry for WinPE
$createOut  = & bcdedit /create /d "WinPE Capture" /application OSLOADER 2>&1
$winpeGuid  = [regex]::Match($createOut, '\{[0-9a-fA-F-]{36}\}').Value
if (-not $winpeGuid) {
    Write-Error "bcdedit /create failed: $createOut"
    exit 1
}
Write-Output "  WinPE BCD entry: $winpeGuid"

& bcdedit /set $winpeGuid device    "ramdisk=[$bootDrive]\sources\boot.wim,{ramdiskoptions}" | Out-Null
& bcdedit /set $winpeGuid path      \Windows\System32\winload.exe                           | Out-Null
& bcdedit /set $winpeGuid osdevice  "ramdisk=[$bootDrive]\sources\boot.wim,{ramdiskoptions}" | Out-Null
& bcdedit /set $winpeGuid systemroot \Windows    | Out-Null
& bcdedit /set $winpeGuid detecthal Yes           | Out-Null
& bcdedit /set $winpeGuid winpe     Yes           | Out-Null
& bcdedit /set $winpeGuid nx        OptIn         | Out-Null

# Set as default boot entry; restore after 30 s if WinPE fails to start
& bcdedit /displayorder $winpeGuid /addfirst | Out-Null
& bcdedit /default      $winpeGuid           | Out-Null
& bcdedit /timeout      30                   | Out-Null

# Persist the GUID so Capture-ReferenceImage.ps1 can remove the entry after capture
Set-Content -Path $guidFile -Value $winpeGuid -Force
Write-Output "  [OK] BCD configured — $winpeGuid is default (timeout 30 s)"
Write-Output "  [OK] GUID saved to $guidFile for post-capture cleanup"
Write-Output "--------------------------------------"
Write-Output ""
Write-Output "  Sysprep will reboot the VM. Windows Boot Manager will automatically"
Write-Output "  boot WinPE from the local disk — no DVD / boot-order change required."
Write-Output "--------------------------------------"

# Step 4: Run Sysprep
Write-Output ""
Write-Output "Step 4: Pre-flight checks..."
Write-Output "--------------------------------------"

# Verify capture flag exists
if (Test-Path $captureFlagFile) {
    Write-Output "  [OK] Capture flag file: $captureFlagFile"
} else {
    Write-Warning "  [WARN] Capture flag file not found!"
}

# Verify capture script exists
if (Test-Path $CaptureScriptPath) {
    Write-Output "  [OK] Capture script: $CaptureScriptPath"
} else {
    Write-Error "  [ERROR] Capture script not found!"
    Write-Error "  PE environment will not be able to run capture!"
    $proceed = Read-Host "Continue anyway? (yes/no)"
    if ($proceed -ne "yes") {
        exit 1
    }
}

# Step 5: Run Sysprep
Write-Output ""
Write-Output "Step 5: Running Sysprep..."
Write-Output "--------------------------------------"

$sysprepPath = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
if (-not (Test-Path $sysprepPath)) {
    Write-Error "Sysprep not found at: $sysprepPath"
    exit 1
}

# Build sysprep command - use /reboot if BCD configured, /shutdown otherwise
if ($useReboot) {
    $sysprepArgs = @("/generalize", "/oobe", "/reboot")
} else {
    $sysprepArgs = @("/generalize", "/oobe", "/shutdown")
}

# Use answer file if it exists
if (Test-Path $SysprepAnswerFile) {
    Write-Output "Using sysprep answer file: $SysprepAnswerFile"
    $sysprepArgs += "/unattend:$SysprepAnswerFile"
} else {
    Write-Warning "No sysprep answer file found at: $SysprepAnswerFile"
}

Write-Output ""
Write-Output "Sysprep command: $sysprepPath $($sysprepArgs -join ' ')"
Write-Output ""

Write-Output "========================================"
Write-Output "FULLY AUTOMATED CAPTURE — MDT Style!"
Write-Output "========================================"
Write-Output ""
Write-Output "The system will:"
Write-Output "  1. Generalize with Sysprep (/reboot)"
Write-Output "  2. Reboot — Windows Boot Manager picks WinPE (BCD default)"
Write-Output "  3. WinPE detects DeployCapture.flag"
Write-Output "  4. Capture script runs automatically"
Write-Output "  5. Reference WIM is saved; BCD entry is removed"
Write-Output ""
Write-Output "NO MANUAL INTERVENTION REQUIRED."
Write-Output "No ISO, no DVD boot order change — the BCD on the local disk does it all."
Write-Output ""

Start-Sleep -Seconds 5

try {
    Write-Output "Starting sysprep..."
    Start-Process -FilePath $sysprepPath -ArgumentList $sysprepArgs -Wait -NoNewWindow
    
    # If we reach here, sysprep completed but didn't shutdown (error condition)
    Write-Warning "Sysprep completed but system did not shut down."
    Write-Warning "Check sysprep logs: C:\Windows\System32\Sysprep\Panther\setuperr.log"
} catch {
    Write-Error "Sysprep failed: $_"
    Write-Error "Check sysprep logs: C:\Windows\System32\Sysprep\Panther\setuperr.log"
    exit 1
}
