<#
.SYNOPSIS
    Captures a reference image from Windows PE
.DESCRIPTION
    This script should be run from Windows PE after sysprep has generalized the system.
    It will capture the Windows installation to a WIM file.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ImageName = "Windows Server 2025",
    
    [Parameter(Mandatory=$false)]
    [string]$ImageDescription = "Reference Image - Captured on $(Get-Date -Format 'yyyy-MM-dd')",
    
    [Parameter(Mandatory=$false)]
    [string]$TargetDrive = "C:",
    
    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "",

    # Scratch directory for DISM temp files. MUST be outside the WinPE RAM disk (X:).
    # Default points to the deployment share so WinPE RAM is not exhausted.
    # In WinPE the default DISM scratch dir is X:\Windows\Temp (32 MB) - far too small
    # for capturing a full OS, causing DISM to abort after just a few percent.
    [Parameter(Mandatory=$false)]
    [string]$ScratchDir = "Z:\Scratch",

    # Compression level. Use 'fast' in WinPE to avoid OOM with limited RAM.
    # 'max' (LZX) is extremely memory-intensive and will fail in low-memory WinPE environments.
    [Parameter(Mandatory=$false)]
    [ValidateSet("none","fast","max")]
    [string]$Compress = "fast"
)

Write-Output "========================================"
Write-Output "Reference Image Capture Script (WinPE)"
Write-Output "========================================"
Write-Output ""

# Derive output path from ImageName if not explicitly provided
if (-not $OutputPath) {
    $safeImageName = ($ImageName -replace '[^\w\-]', '').ToLower()
    $OutputPath = "Z:\Reference\$safeImageName.wim"
    Write-Output "OutputPath derived from ImageName: $OutputPath"
}

# Verify we're in WinPE.
# The registry key HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT is created
# exclusively by the WinPE kernel — it is absent on all full Windows installs.
# This is the same check MDT/ZTIUtility.vbs uses internally.
$inWinPE = Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT"
if (-not $inWinPE) {
    Write-Warning "This script is designed to run in Windows PE - continuing anyway"
}

# Ensure output directory exists
$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDir)) {
    Write-Output "Creating output directory: $outputDir"
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

# Ensure DISM scratch directory exists on the deployment share (NOT on WinPE X: RAM disk)
if (-not (Test-Path $ScratchDir)) {
    Write-Output "Creating DISM scratch directory: $ScratchDir"
    New-Item -Path $ScratchDir -ItemType Directory -Force | Out-Null
}
Write-Output "DISM scratch dir : $ScratchDir"
Write-Output "DISM compression : $Compress"

# Display capture parameters
Write-Output "Capture Parameters:"
Write-Output "  Source Drive: $TargetDrive"
Write-Output "  Output Path: $OutputPath"
Write-Output "  Image Name: $ImageName"
Write-Output "  Description: $ImageDescription"
Write-Output ""

# Remove existing WIM if present - DISM errors 80 (file exists) if output already exists
Write-Output "Checking for existing output file..."
if (Test-Path $OutputPath) {
    Write-Output "  Found existing file - removing: $OutputPath"
    Remove-Item -Path $OutputPath -Force
    Write-Output "  [OK] Removed"
} else {
    Write-Output "  [OK] No existing file found"
}
# Show what's in the output directory
Write-Output "Contents of output directory ($outputDir):"
Get-ChildItem -Path $outputDir -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output "    $($_.Name)  ($($_.Length) bytes)"
}
Write-Output ""

Write-Output "Starting image capture..."
Write-Output "This may take 20-60 minutes depending on system size."
Write-Output ""

# DISM log — persisted on the deployment share for post-mortem analysis
$dismLog = Join-Path $outputDir "dism-capture.log"

# Build DISM command
# IMPORTANT: /ScratchDir must point outside the WinPE RAM disk (X:) otherwise
# DISM hits ERROR_DISK_FULL (0x80070070) after only a few percent.
# /Compress:fast is chosen for reliability in low-memory WinPE environments;
# use /Compress:max only when running from a full Windows OS with plenty of RAM.
$dismArgs = @(
    "/Capture-Image"
    "/ImageFile:$OutputPath"
    "/CaptureDir:$TargetDrive\"
    "/Name:$ImageName"
    "/Description:$ImageDescription"
    "/Compress:$Compress"
    "/Verify"
    "/ScratchDir:$ScratchDir"
    "/LogPath:$dismLog"
)

try {
    # Run DISM directly — do NOT capture to a variable.
    # Capturing with $out = & dism.exe ... 2>&1 buffers all output until DISM exits,
    # making progress invisible and hiding the failure reason until the very end.
    Write-Output "Calling: dism.exe $($dismArgs -join ' ')"
    Write-Output ""
    & dism.exe $dismArgs
    $dismExitCode = $LASTEXITCODE
    
    if ($dismExitCode -eq 0) {
        Write-Output ""
        Write-Output "========================================"
        Write-Output "Image capture completed successfully!"
        Write-Output "========================================"
        Write-Output "Image location: $OutputPath"
        Write-Output "DISM log      : $dismLog"
        
        # Display WIM file info
        if (Test-Path $OutputPath) {
            $wimSize = (Get-Item $OutputPath).Length / 1GB
            Write-Output "Image size: $([math]::Round($wimSize, 2)) GB"
        }

        # ---------------------------------------------------------------
        # BCD cleanup (mirrors MDT post-capture behaviour)
        # Install.ps1 saved the WinPE BCD GUID to C:\WinPE-BCD-GUID.txt
        # before sysprep.  Remove that entry so the next reboot goes back
        # to the original Windows boot entry automatically.
        # ---------------------------------------------------------------
        $guidFile = "$TargetDrive\WinPE-BCD-GUID.txt"
        if (Test-Path $guidFile) {
            $winpeGuid = (Get-Content $guidFile -Raw).Trim()
            if ($winpeGuid -match '^\{[0-9a-fA-F-]{36}\}$') {
                Write-Output ""
                Write-Output "Removing WinPE BCD boot entry ($winpeGuid)..."
                & bcdedit /displayorder $winpeGuid /remove 2>&1 | Out-Null
                & bcdedit /delete       $winpeGuid /cleanup  2>&1 | Out-Null
                # Restore timeout to 0 so the remaining OS entry boots without a menu
                & bcdedit /timeout 0 2>&1 | Out-Null
                Remove-Item $guidFile -Force -ErrorAction SilentlyContinue
                Write-Output "  [OK] WinPE BCD entry removed \u2014 normal boot restored"
            } else {
                Write-Warning "  GUID file contained unexpected content: $winpeGuid"
            }
        } else {
            Write-Warning "  WinPE-BCD-GUID.txt not found at $guidFile \u2014 skipping BCD cleanup"
        }

        # Remove the WinPE WIM from the boot partition (no longer needed)
        $wimOnBoot = "$TargetDrive\sources\boot.wim"
        if (Test-Path $wimOnBoot) {
            Remove-Item $wimOnBoot -Force -ErrorAction SilentlyContinue
            Write-Output "  [OK] Removed temporary $wimOnBoot"
        }

        # ---------------------------------------------------------------
        # Weekly build: wipe disk 0 and shutdown
        # We are running in WinPE from the RAM disk (X:) so disk 0 is
        # not in use and can be safely wiped.  On next power-on the VM
        # boots from the DVD/ISO, WinPE finds no DeployCapture.flag,
        # deploys the OS fresh, and the cycle repeats automatically.
        # ---------------------------------------------------------------
        Write-Output ""
        Write-Output "========================================"
        Write-Output "  Wiping disk and shutting down..."
        Write-Output "========================================"
        Write-Output "  Disk 0 will be wiped in 10 seconds."
        Write-Output "  Next boot from DVD/ISO will deploy a fresh OS."

        Write-Output "  Running diskpart clean on disk 0..."
        $diskpartScript = "select disk 0`nclean`nexit"
        $diskpartScript | diskpart
        Write-Output "  [OK] Disk 0 wiped"

        Write-Output "  Shutting down..."
        wpeutil shutdown

    } else {
        Write-Error "DISM capture failed with exit code: $dismExitCode"
        Write-Error "Review DISM log for details: $dismLog"
        exit $dismExitCode
    }
} catch {
    Write-Error "Error during image capture: $_"
    exit 1
}

Write-Output ""
Write-Output "If you reach this line, wpeutil shutdown did not exit the script."
