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

# Transcript + copies of the sysprep logs go to a folder in the C: root: Step 1 below wipes Windows\Temp
# (DeploymentLogs included), so nothing under Temp survives. The capture excludes this folder from the WIM.
$logDir = 'C:\NDT-ReferenceLogs'
$null = New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue
try { Start-Transcript -Path (Join-Path $logDir 'CreateReference-Install.log') -Append -Force | Out-Null } catch { Write-Warning "Could not start transcript: $_" }

function Save-SysprepLog {
    # .NET copy inside try/catch: once sysprep has removed the console host, Copy-Item throws a host error
    # that -ErrorAction SilentlyContinue does not suppress.
    $panther = "$env:SystemRoot\System32\Sysprep\Panther"
    foreach ($name in 'setupact.log', 'setuperr.log') {
        try { [System.IO.File]::Copy((Join-Path $panther $name), (Join-Path $logDir "sysprep-$name"), $true) } catch { }
    }
}

# File log that does not depend on the console: sysprep removes the Windows Terminal package, which can take
# the console (and with it the transcript and every Write-Output) down mid-run. Never throws.
$stepLog = Join-Path $logDir 'CreateReference-Steps.log'
function Write-RefLog {
    param([string]$Message)
    try { Add-Content -Path $stepLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message" -ErrorAction SilentlyContinue } catch { }
    try { Write-Output $Message } catch { }
}

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

# Step 2: Prepare the automation flag for PE capture
Write-Output ""
Write-Output "Step 2: Preparing automation flag..."
Write-Output "--------------------------------------"

# The flag file signals WinPE to run capture instead of deployment. It is only written right
# before the reboot (Step 7) so a failure in any earlier step cannot leave a stale flag behind
# that would hijack the next WinPE boot of this machine.
$captureFlagFile = "C:\DeployCapture.flag"
$captureFlagContent = @{
    Action = "Capture"
    CaptureScript = "Z:\Applications\CreateReference\Capture-ReferenceImage.ps1"
    CreatedDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    ImageName = "Windows Server 2025 Reference"
    OutputPath = "Z:\Reference\$($env:COMPUTERNAME.ToLower()).wim"
}

# Remove a stale flag from a previously failed run
Remove-Item -Path $captureFlagFile -Force -ErrorAction SilentlyContinue
Write-Output "  [OK] Capture flag prepared (written just before reboot)"

# Step 3: Extract WinPE files from ISO (done BEFORE sysprep so we can validate early)
# BCD is configured AFTER sysprep completes - sysprep's generalize pass resets custom
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
Write-Output "Step 5: Running Sysprep (/quit - no reboot yet)..."
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
Write-Output "FULLY AUTOMATED CAPTURE - MDT Style!"
Write-Output "========================================"
Write-Output ""
Write-Output "The system will:"
Write-Output "  1. Generalize with Sysprep (/quit - no reboot yet)"
Write-Output "  2. Configure BCD after sysprep so nothing can wipe it"
Write-Output "  3. Reboot - Windows Boot Manager boots WinPE from local disk"
Write-Output "  4. WinPE detects DeployCapture.flag and runs capture"
Write-Output "  5. Reference WIM is saved; BCD entry is removed"
Write-Output ""
Write-Output "NO MANUAL INTERVENTION REQUIRED."
Write-Output ""

Start-Sleep -Seconds 3

try {
    Write-RefLog "Starting sysprep..."
    # Start-Process does not set $LASTEXITCODE (it would hold a stale wevtutil/bcdedit value), so read the process exit code.
    # Not -Wait: while sysprep runs, its latest setupact.log line is logged every 15 s, so a stall shows where it stopped.
    $sysprepProc = Start-Process -FilePath $sysprepPath -ArgumentList $sysprepArgs -NoNewWindow -PassThru
    $null = $sysprepProc.Handle   # keeps ExitCode readable after exit
    $sysprepLog  = "$env:SystemRoot\System32\Sysprep\Panther\setupact.log"
    $lastLogLine = ''
    while (-not $sysprepProc.HasExited) {
        Start-Sleep -Seconds 15
        $tail = if (Test-Path $sysprepLog) { Get-Content -Path $sysprepLog -Tail 1 -ErrorAction SilentlyContinue }
        if ($tail -and $tail -ne $lastLogLine) {
            Write-RefLog "  [sysprep] $tail"
            $lastLogLine = $tail
        }
    }
    Save-SysprepLog
    Write-RefLog "  Sysprep exited with code $($sysprepProc.ExitCode)"
    if ($sysprepProc.ExitCode -ne 0) {
        Write-RefLog "Sysprep failed - see $logDir\sysprep-setuperr.log (copy of $env:SystemRoot\System32\Sysprep\Panther\setuperr.log)"
        exit 1
    }
    Write-RefLog "  [OK] Sysprep generalise complete (system NOT yet rebooted)"
} catch {
    Save-SysprepLog
    Write-RefLog "Sysprep failed: $_ - see $logDir\sysprep-setuperr.log"
    exit 1
}

# Step 6: Configure BCD now - AFTER sysprep has finished generalising
# Writing BCD here means sysprep can no longer touch it before the reboot.
# From here on only Write-RefLog is used (the console may be gone after sysprep).
Write-RefLog ""
Write-RefLog "Step 6: Configuring BCD for WinPE boot..."

# Always delete and recreate {ramdiskoptions} to avoid stale data from previous runs
& bcdedit /delete "{ramdiskoptions}" 2>&1 | Out-Null
$out = & bcdedit /create "{ramdiskoptions}" /d "Ramdisk Options" 2>&1 ; Write-RefLog "  create ramdiskoptions: $out"
$out = & bcdedit /set "{ramdiskoptions}" ramdisksdidevice "partition=$bootDrive" 2>&1 ; Write-RefLog "  set ramdisksdidevice : $out"
$out = & bcdedit /set "{ramdiskoptions}" ramdisksdipath  \Boot\boot.sdi 2>&1          ; Write-RefLog "  set ramdisksdipath   : $out"

$createOut = & bcdedit /create /d "WinPE Capture" /application OSLOADER 2>&1
Write-RefLog "  create OSLOADER      : $createOut"
$winpeGuid = [regex]::Match($createOut, '\{[0-9a-fA-F-]{36}\}').Value
if (-not $winpeGuid) {
    Write-RefLog "bcdedit /create failed: $createOut"
    exit 1
}

$out = & bcdedit /set $winpeGuid device     "ramdisk=[$bootDrive]\sources\boot.wim,{ramdiskoptions}" 2>&1 ; Write-RefLog "  set device    : $out"
$out = & bcdedit /set $winpeGuid path       \Windows\System32\winload.exe 2>&1                           ; Write-RefLog "  set path      : $out"
$out = & bcdedit /set $winpeGuid osdevice   "ramdisk=[$bootDrive]\sources\boot.wim,{ramdiskoptions}" 2>&1 ; Write-RefLog "  set osdevice  : $out"
$out = & bcdedit /set $winpeGuid systemroot \Windows 2>&1                                               ; Write-RefLog "  set systemroot: $out"
$out = & bcdedit /set $winpeGuid detecthal  Yes 2>&1                                                    ; Write-RefLog "  set detecthal : $out"
$out = & bcdedit /set $winpeGuid winpe      Yes 2>&1                                                    ; Write-RefLog "  set winpe     : $out"
$out = & bcdedit /set $winpeGuid nx         OptIn 2>&1                                                  ; Write-RefLog "  set nx        : $out"

$out = & bcdedit /displayorder $winpeGuid /addfirst 2>&1 ; Write-RefLog "  displayorder  : $out"
$out = & bcdedit /default      $winpeGuid 2>&1           ; Write-RefLog "  set default   : $out"
$out = & bcdedit /timeout      5 2>&1                    ; Write-RefLog "  set timeout   : $out"

Set-Content -Path $guidFile -Value $winpeGuid -Force
Write-RefLog "  [OK] BCD entry $winpeGuid set as default"
Write-RefLog "  [OK] GUID saved to $guidFile"
& bcdedit /enum all 2>&1 | Set-Content -Path (Join-Path $logDir 'bcdedit-enum-all.txt') -ErrorAction SilentlyContinue

# Step 7: Write the capture flag, then reboot - BCD is now set, nothing left to wipe it
Write-RefLog ""
Write-RefLog "Step 7: Writing capture flag and rebooting into WinPE..."

try {
    $captureFlagContent | ConvertTo-Json | Set-Content -Path $captureFlagFile -Force -ErrorAction Stop
    Write-RefLog "  [OK] Capture flag created: $captureFlagFile"
} catch {
    Write-RefLog "Could not create capture flag file: $_"
    exit 1
}
Write-RefLog "  Rebooting in 10 seconds. WinPE capture will run automatically."
Start-Sleep -Seconds 10
try { Stop-Transcript | Out-Null } catch { }
Restart-Computer -Force
