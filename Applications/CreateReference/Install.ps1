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

# Step 3: Configure automatic reboot into WinPE RAM disk
Write-Output ""
Write-Output "Step 3: Configuring one-time PXE boot..."
Write-Output "--------------------------------------"

$useReboot = $false

try {
    # Find the network/PXE boot entry in the UEFI firmware boot manager
    Write-Output "Scanning firmware boot entries for network boot option..."
    $fwEntries = bcdedit /enum "{fwbootmgr}" 2>&1
    Write-Output $fwEntries

    # Look for a network-related entry GUID in the displayorder
    $networkGuid = $null
    $guids = [regex]::Matches($fwEntries, '\{[0-9a-fA-F\-]+\}') | ForEach-Object { $_.Value }

    foreach ($guid in $guids) {
        $entry = bcdedit /enum $guid 2>&1
        if ($entry -match 'network|pxe|nic|ethernet' -or $entry -match 'description\s+Network') {
            $networkGuid = $guid
            Write-Output "  [OK] Found network boot entry: $guid"
            break
        }
    }

    if ($networkGuid) {
        # Set as one-time boot sequence - fires once then reverts
        $r = bcdedit /set "{fwbootmgr}" bootsequence $networkGuid 2>&1
        if ($LASTEXITCODE -ne 0) { throw "bootsequence failed: $r" }

        Write-Output "  [OK] One-time PXE boot configured"
        Write-Output "  System will PXE boot into WDS after sysprep reboot"
        $useReboot = $true
    } else {
        Write-Warning "No network boot entry found in firmware boot manager"
        Write-Warning "Ensure 'Enable network boot' is checked on the VM network adapter"
        Write-Output "Falling back to shutdown mode - configure PXE boot manually then start VM"
    }
} catch {
    Write-Warning "Failed to configure PXE boot sequence: $_"
    Write-Output "Falling back to shutdown mode"
}

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

if ($useReboot) {
    Write-Output "========================================"
    Write-Output "FULLY AUTOMATED CAPTURE - MDT Style!"
    Write-Output "========================================"
    Write-Output ""
    Write-Output "The system will:"
    Write-Output "  1. Generalize with sysprep"
    Write-Output "  2. Automatically reboot into WinPE (RAM disk)"
    Write-Output "  3. PE will detect DeployCapture.flag"
    Write-Output "  4. Capture script runs automatically"
    Write-Output "  5. Reference WIM is created"
    Write-Output ""
    Write-Output "NO MANUAL INTERVENTION REQUIRED!"
    Write-Output "Just wait for the process to complete."
} else {
    Write-Output "The system will be generalized and shut down."
    Write-Output ""
    Write-Output "MANUAL STEPS REQUIRED AFTER SHUTDOWN:"
    Write-Output "  1. Configure VM to PXE boot (Firmware settings)"
    Write-Output "  2. Start the VM"
    Write-Output "  3. PE will detect DeployCapture.flag and run capture"
}
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
