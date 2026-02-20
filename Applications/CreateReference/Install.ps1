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
Write-Warning "This script will generalize this system and reboot it into WinPE automatically."
Write-Warning "WinPE will capture the image unattended. No manual interaction is required."
Write-Output ""

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

# Step 3: Extract WinPE files from ISO (done BEFORE sysprep so we can validate early)
# BCD is configured AFTER sysprep completes — sysprep's generalize pass resets custom
# BCD entries on Vista+, so writing BCD before sysprep would be wiped on reboot.
Write-Output ""
Write-Output "Step 3: Extracting WinPE files from ISO..."
Write-Output "--------------------------------------"

$bootDrive  = $env:SystemDrive          # C:
$wimDest    = "$bootDrive\sources\boot.wim"
$sdiDest    = "$bootDrive\Boot\boot.sdi"
$guidFile   = "$bootDrive\WinPE-BCD-GUID.txt"
$isoPath    = "Z:\Boot\boot2026.iso"

if (-not (Test-Path $isoPath)) {
    Write-Error "ISO not found at $isoPath"
    exit 1
}
try {
    $mount    = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    $isoDrive = ($mount | Get-Volume).DriveLetter + ":"

    $sdiSource = "$isoDrive\Boot\boot.sdi"
    $wimSource = "$isoDrive\sources\boot.wim"
    foreach ($f in @($sdiSource, $wimSource)) {
        if (-not (Test-Path $f)) {
            Write-Error "Expected file not found inside ISO: $f"
            Dismount-DiskImage -ImagePath $isoPath | Out-Null
            exit 1
        }
    }

    New-Item -ItemType Directory -Force -Path "$bootDrive\Boot"    | Out-Null
    New-Item -ItemType Directory -Force -Path "$bootDrive\sources" | Out-Null

    Copy-Item -Path $sdiSource -Destination $sdiDest -Force
    Write-Output "  [OK] boot.sdi copied to $sdiDest"

    Copy-Item -Path $wimSource -Destination $wimDest -Force
    Write-Output "  [OK] boot.wim copied to $wimDest ($([math]::Round((Get-Item $wimDest).Length/1MB)) MB)"

} catch {
    Write-Error "Failed to extract WinPE files from ISO: $_"
    exit 1
} finally {
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
}

# Step 4: Pre-flight checks
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
    exit 1
}

# Step 5: Run Sysprep with /quit
# /quit generalizes the OS (same as /reboot or /shutdown) but exits sysprep
# WITHOUT rebooting. This lets us configure the BCD AFTER generalize completes
# so sysprep cannot wipe our custom boot entry.
Write-Output ""
Write-Output "Step 5: Running Sysprep (/quit — no reboot yet)..."
Write-Output "--------------------------------------"

$sysprepPath = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
if (-not (Test-Path $sysprepPath)) {
    Write-Error "Sysprep not found at: $sysprepPath"
    exit 1
}

$sysprepArgs = @("/generalize", "/oobe", "/quit")

if (Test-Path $SysprepAnswerFile) {
    Write-Output "  Using sysprep answer file: $SysprepAnswerFile"
    $sysprepArgs += "/unattend:$SysprepAnswerFile"
} else {
    Write-Warning "  No sysprep answer file found at: $SysprepAnswerFile"
}

Write-Output "  Sysprep command: $sysprepPath $($sysprepArgs -join ' ')"
Write-Output ""

Write-Output "========================================"
Write-Output "FULLY AUTOMATED CAPTURE — MDT Style!"
Write-Output "========================================"
Write-Output ""
Write-Output "The system will:"
Write-Output "  1. Generalize with Sysprep (/quit — no reboot yet)"
Write-Output "  2. Configure BCD after sysprep so nothing can wipe it"
Write-Output "  3. Reboot — Windows Boot Manager boots WinPE from local disk"
Write-Output "  4. WinPE detects DeployCapture.flag and runs capture"
Write-Output "  5. Reference WIM is saved; BCD entry is removed"
Write-Output ""
Write-Output "NO MANUAL INTERVENTION REQUIRED."
Write-Output ""

Start-Sleep -Seconds 3

try {
    Write-Output "Starting sysprep..."
    Start-Process -FilePath $sysprepPath -ArgumentList $sysprepArgs -Wait -NoNewWindow
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Sysprep exited with code $LASTEXITCODE"
        Write-Error "Check: $env:SystemRoot\System32\Sysprep\Panther\setuperr.log"
        exit 1
    }
    Write-Output "  [OK] Sysprep generalise complete (system NOT yet rebooted)"
} catch {
    Write-Error "Sysprep failed: $_"
    Write-Error "Check: $env:SystemRoot\System32\Sysprep\Panther\setuperr.log"
    exit 1
}

# Step 6: Configure BCD now — AFTER sysprep has finished generalising
# Writing BCD here means sysprep can no longer touch it before the reboot.
Write-Output ""
Write-Output "Step 6: Configuring BCD for WinPE boot..."
Write-Output "--------------------------------------"

# Always delete and recreate {ramdiskoptions} to avoid stale data from previous runs
& bcdedit /delete "{ramdiskoptions}" 2>&1 | Out-Null
$out = & bcdedit /create "{ramdiskoptions}" /d "Ramdisk Options" 2>&1 ; Write-Output "  create ramdiskoptions: $out"
$out = & bcdedit /set "{ramdiskoptions}" ramdisksdidevice "partition=$bootDrive" 2>&1 ; Write-Output "  set ramdisksdidevice : $out"
$out = & bcdedit /set "{ramdiskoptions}" ramdisksdipath  \Boot\boot.sdi 2>&1          ; Write-Output "  set ramdisksdipath   : $out"

$createOut = & bcdedit /create /d "WinPE Capture" /application OSLOADER 2>&1
Write-Output "  create OSLOADER      : $createOut"
$winpeGuid = [regex]::Match($createOut, '\{[0-9a-fA-F-]{36}\}').Value
if (-not $winpeGuid) {
    Write-Error "bcdedit /create failed: $createOut"
    exit 1
}

$out = & bcdedit /set $winpeGuid device     "ramdisk=[$bootDrive]\sources\boot.wim,{ramdiskoptions}" 2>&1 ; Write-Output "  set device    : $out"
$out = & bcdedit /set $winpeGuid path       \Windows\System32\winload.exe 2>&1                           ; Write-Output "  set path      : $out"
$out = & bcdedit /set $winpeGuid osdevice   "ramdisk=[$bootDrive]\sources\boot.wim,{ramdiskoptions}" 2>&1 ; Write-Output "  set osdevice  : $out"
$out = & bcdedit /set $winpeGuid systemroot \Windows 2>&1                                               ; Write-Output "  set systemroot: $out"
$out = & bcdedit /set $winpeGuid detecthal  Yes 2>&1                                                    ; Write-Output "  set detecthal : $out"
$out = & bcdedit /set $winpeGuid winpe      Yes 2>&1                                                    ; Write-Output "  set winpe     : $out"
$out = & bcdedit /set $winpeGuid nx         OptIn 2>&1                                                  ; Write-Output "  set nx        : $out"

$out = & bcdedit /displayorder $winpeGuid /addfirst 2>&1 ; Write-Output "  displayorder  : $out"
$out = & bcdedit /default      $winpeGuid 2>&1           ; Write-Output "  set default   : $out"
$out = & bcdedit /timeout      30 2>&1                   ; Write-Output "  set timeout   : $out"

Set-Content -Path $guidFile -Value $winpeGuid -Force
Write-Output "  [OK] BCD entry $winpeGuid set as default"
Write-Output "  [OK] GUID saved to $guidFile"

# Step 7: Reboot — BCD is now set, nothing left to wipe it
Write-Output ""
Write-Output "Step 7: Rebooting into WinPE..."
Write-Output "--------------------------------------"
Write-Output "  Rebooting in 10 seconds. WinPE capture will run automatically."
Start-Sleep -Seconds 10
Restart-Computer -Force
