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
    [string]$OutputPath = "Z:\Reference\ref-image.wim"
)

Write-Output "========================================"
Write-Output "Reference Image Capture Script (WinPE)"
Write-Output "========================================"
Write-Output ""

# Verify we're in WinPE
if ($env:COMPUTERNAME -ne "MINWINPC") {
    Write-Warning "This script is designed to run in Windows PE - continuing anyway"
}

# Ensure output directory exists
$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDir)) {
    Write-Output "Creating output directory: $outputDir"
    New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
}

# Remove existing WIM if present (DISM errors with code 80 if file already exists)
if (Test-Path $OutputPath) {
    Write-Output "Removing existing WIM: $OutputPath"
    Remove-Item -Path $OutputPath -Force
    Write-Output "  [OK] Existing WIM removed"
}

# Display capture parameters
Write-Output "Capture Parameters:"
Write-Output "  Source Drive: $TargetDrive"
Write-Output "  Output Path: $OutputPath"
Write-Output "  Image Name: $ImageName"
Write-Output "  Description: $ImageDescription"
Write-Output ""

Write-Output ""
Write-Output "Starting image capture..."
Write-Output "This may take 20-60 minutes depending on system size."
Write-Output ""

# Build DISM command
$dismArgs = @(
    "/Capture-Image"
    "/ImageFile:$OutputPath"
    "/CaptureDir:$TargetDrive\"
    "/Name:$ImageName"
    "/Description:$ImageDescription"
    "/Compress:max"
    "/Verify"
)

try {
    # Run DISM capture
    $dismOutput = & dism.exe $dismArgs 2>&1
    $dismExitCode = $LASTEXITCODE
    
    # Display output
    $dismOutput | ForEach-Object { Write-Output $_ }
    
    if ($dismExitCode -eq 0) {
        Write-Output ""
        Write-Output "========================================"
        Write-Output "Image capture completed successfully!"
        Write-Output "========================================"
        Write-Output "Image location: $OutputPath"
        
        # Display WIM file info
        if (Test-Path $OutputPath) {
            $wimSize = (Get-Item $OutputPath).Length / 1GB
            Write-Output "Image size: $([math]::Round($wimSize, 2)) GB"
        }
    } else {
        Write-Error "DISM capture failed with exit code: $dismExitCode"
        exit $dismExitCode
    }
} catch {
    Write-Error "Error during image capture: $_"
    exit 1
}

Write-Output ""
Write-Output "Next steps:"
Write-Output "  1. Copy the WIM file to your deployment share"
Write-Output "  2. Update deployment configuration to use the new image"
Write-Output "  3. Test deployment on a target system"
Write-Output ""
