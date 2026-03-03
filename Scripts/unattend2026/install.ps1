# NDT  - Next Deployment Tool for 2026 Unattended Deployment.
# This script runs in Windows PE after PXE boot (or ISO boot), and performs the following steps:
# 1. Maps the deployment share using credentials from settings file
# 2. Checks for capture mode (if DeployCapture.flag exists on any drive) and runs capture script if in capture mode
# 3. Partitions and formats the disk using diskpart script
# 4. Validates MAC address against CustomSettings.json and retrieves machine configuration
# 5. Applies the OS image to C: drive using Dism
# 6. Copies install2026.ps1 to C:\ and prepares unattend.xml based on machine configuration
# 7. Applies unattend.xml to the offline image
# Check if this is a capture operation (reference image creation)
# Must be checked BEFORE diskpart to avoid wiping the reference system
Write-Host "Checking for capture mode..." -ForegroundColor Cyan
$captureMode = $false
$captureConfig = $null
$referenceDrive = $null

$volumes = Get-Volume | Where-Object {$_.DriveLetter -and $_.FileSystemLabel -ne "System Reserved"}
foreach ($vol in $volumes) {
    $flagFile = "$($vol.DriveLetter):\DeployCapture.flag"
    if (Test-Path $flagFile) {
        Write-Host "Capture mode detected on drive $($vol.DriveLetter):" -ForegroundColor Yellow
        $captureConfig = Get-Content $flagFile -Raw | ConvertFrom-Json
        $referenceDrive = $vol.DriveLetter
        $captureMode = $true
        break
    }
}

if ($captureMode) {
    Write-Host "Running in CAPTURE mode - creating reference image" -ForegroundColor Green
    Write-Host "Reference Drive: $referenceDrive" -ForegroundColor Cyan
    Write-Host "Image Name: $($captureConfig.ImageName)" -ForegroundColor Cyan
    Write-Host "Output Path: $($captureConfig.OutputPath)" -ForegroundColor Cyan
    Write-Host ""

    $captureScriptPath = "Z:\Applications\CreateReference\Capture-ReferenceImage.ps1"

    if (Test-Path $captureScriptPath) {
        # Remove the capture flag before capturing so it is not baked into the WIM.
        # If left in place, any future deployment using this image would incorrectly
        # enter capture mode again.
        Write-Host "Removing DeployCapture.flag from reference drive..." -ForegroundColor Yellow
        Remove-Item "${referenceDrive}:\DeployCapture.flag" -Force -ErrorAction SilentlyContinue

        # Clean C:\temp on the reference drive so deployment logs are not appended
        # when the WIM is applied to a new machine.
        $tempPath = "${referenceDrive}:\temp"
        if (Test-Path $tempPath) {
            Write-Host "Cleaning $tempPath before capture..." -ForegroundColor Yellow
            Remove-Item -Path "$tempPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Executing capture script..." -ForegroundColor Green
        & $captureScriptPath -ImageName $captureConfig.ImageName -OutputPath $captureConfig.OutputPath -TargetDrive "${referenceDrive}:"
        Write-Host "Capture complete!" -ForegroundColor Green
    } else {
        Write-Host "ERROR: Capture script not found at: $captureScriptPath" -ForegroundColor Red
    }
    exit 0
}

Write-Host "Running normal deployment..." -ForegroundColor Cyan
# read-host "Press Enter to start deployment..."

# Detect firmware type: 1 = BIOS (Gen 1), 2 = UEFI (Gen 2)
# Done early so we can report it, but disk is NOT touched until all validations pass.
$firmwareType = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "PEFirmwareType" -ErrorAction SilentlyContinue).PEFirmwareType
$isUEFI = ($firmwareType -eq 2)
Write-Host "Firmware type: $(if ($isUEFI) { 'UEFI (Gen 2)' } else { 'BIOS (Gen 1)' })" -ForegroundColor Cyan

# ------------------------------------------------------------------
# STEP 1 - Validate MAC address
# ------------------------------------------------------------------
$macAddress = & "Z:\Scripts\Unattend2026\Get-MACAddress.ps1"

$customSettingsPath = "Z:\Control\CustomSettings.json"
$customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json

if (-not $customSettings.$macAddress) {
    Write-Host "ERROR: MAC address '$macAddress' not found in CustomSettings.json" -ForegroundColor Red
    Write-Host "Available MAC addresses in configuration:" -ForegroundColor Yellow
    $customSettings.PSObject.Properties | Where-Object { $_.Name -match '^[0-9A-F:]+$' } | ForEach-Object {
        Write-Host "  $($_.Name)" -ForegroundColor Gray
    }
    Read-Host "Press Enter to exit"
    exit 1
}

$machineConfig = $customSettings.$macAddress
if (-not $machineConfig.OS) {
    Write-Host "ERROR: OS field not found in configuration for MAC address: $macAddress" -ForegroundColor Red
    Write-Host "Machine configuration:" -ForegroundColor Yellow
    $machineConfig | ConvertTo-Json | Write-Host -ForegroundColor Gray
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Configuration validated for MAC: $macAddress" -ForegroundColor Green
Write-Host "  OS          : $($machineConfig.OS)" -ForegroundColor Cyan
Write-Host "  Computername: $($machineConfig.Computername)" -ForegroundColor Cyan

# ------------------------------------------------------------------
# STEP 2 - Resolve and validate OS / WIM
# ------------------------------------------------------------------
$osInfo = & "Z:\Scripts\Unattend2026\Get-OS.ps1" -MACAddress $macAddress

if (-not $osInfo -or -not $osInfo.Path -or -not $osInfo.Index) {
    Write-Host "ERROR: Get-OS.ps1 returned no result for OS key '$($machineConfig.OS)'" -ForegroundColor Red
    Write-Host "Check that '$($machineConfig.OS)' exists in Z:\Control\OS.json" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

$wimPath  = $osInfo.Path
$wimIndex = $osInfo.Index

if (-not (Test-Path $wimPath)) {
    Write-Host "ERROR: WIM file not found at: $wimPath" -ForegroundColor Red
    Write-Host "  OS key   : $($machineConfig.OS)" -ForegroundColor Yellow
    Write-Host "  Path     : $wimPath" -ForegroundColor Yellow
    Write-Host "  Index    : $wimIndex" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "  WIM Path : $wimPath" -ForegroundColor Cyan
Write-Host "  WIM Index: $wimIndex" -ForegroundColor Cyan

# ------------------------------------------------------------------
# STEP 3 - All validations passed - safe to wipe and partition disk
# ------------------------------------------------------------------
Write-Host "All pre-flight checks passed - partitioning disk 0..." -ForegroundColor Green

if ($isUEFI) {
    $diskpartScript = @"
select disk 0
clean
convert gpt
create partition efi size=100
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
format quick fs=ntfs label="Windows"
assign letter=C
exit
"@
} else {
    # Gen 1 / BIOS: MBR with single active primary partition
    $diskpartScript = @"
select disk 0
clean
convert mbr
create partition primary
format quick fs=ntfs label="Windows"
assign letter=C
active
exit
"@
}

$diskpartScript | diskpart

<# this gave some errors so I switched to diskpart cmdlets, but keeping this here for reference
#$disk = Get-Disk -Number 0

Clear-Disk -Number 0 -RemoveData -Confirm:$false
Initialize-Disk -Number 0 -PartitionStyle GPT

$efiPartition = New-Partition -DiskNumber 0 -Size 100MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
Format-Volume -Partition $efiPartition -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false
Set-Partition -DiskNumber 0 -PartitionNumber $efiPartition.PartitionNumber -NewDriveLetter S

New-Partition -DiskNumber 0 -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

$windowsPartition = New-Partition -DiskNumber 0 -UseMaximumSize -AssignDriveLetter
Format-Volume -DriveLetter $windowsPartition.DriveLetter -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
Set-Partition -DriveLetter $windowsPartition.DriveLetter -NewDriveLetter C
#>

# ------------------------------------------------------------------
# STEP 4 - Apply OS image
# ------------------------------------------------------------------
Dism.exe /Apply-Image /ImageFile:"$wimPath" /Index:$wimIndex /ApplyDir:C:\
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: DISM /Apply-Image failed with exit code $LASTEXITCODE" -ForegroundColor Red
    Write-Host "  WIM Path : $wimPath" -ForegroundColor Yellow
    Write-Host "  WIM Index: $wimIndex" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit $LASTEXITCODE
}

# Copy and prepare install2026.ps1 with deployment share mapping
& "Z:\Scripts\Unattend2026\Copy-Install.ps1"

# Setup unattended.xml with settings from CustomSettings.json based on MAC address
& "Z:\Scripts\Unattend2026\Get-Settings.ps1" -MACAddress $macAddress

New-Item -ItemType Directory -Path "C:\Windows\Panther" -Force
Copy-Item "C:\temp\unattend.xml" "C:\Windows\Panther\unattend.xml"
Dism.exe /Image:C:\ /Apply-Unattend:"C:\Windows\Panther\unattend.xml"
remove-item "C:\temp\unattend.xml"

if ($isUEFI) {
    BCDBoot.exe C:\windows /l en-US /s S: /f UEFI
} else {
    # Gen 1 / BIOS: boot store goes on the Windows partition
    BCDBoot.exe C:\windows /l en-US /s C: /f BIOS
}
BCDEdit.exe /timeout 0

Write-Host "Rebooting..." -ForegroundColor Green
wpeutil Reboot
