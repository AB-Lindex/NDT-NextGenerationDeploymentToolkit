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
        Write-Host "Executing capture script..." -ForegroundColor Green
        & $captureScriptPath -ImageName $captureConfig.ImageName -OutputPath $captureConfig.OutputPath -TargetDrive "${referenceDrive}:"
        Remove-Item "${referenceDrive}:\DeployCapture.flag" -Force -ErrorAction SilentlyContinue
        Write-Host "Capture complete!" -ForegroundColor Green
    } else {
        Write-Host "ERROR: Capture script not found at: $captureScriptPath" -ForegroundColor Red
    }
    exit 0
}

Write-Host "Running normal deployment..." -ForegroundColor Cyan
read-host "Press Enter to start deployment..."

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

# Get MAC address once
$macAddress = & "Z:\Scripts\Unattend2026\Get-MACAddress.ps1"

# Validate MAC address exists in CustomSettings.json
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
Write-Host "  OS: $($machineConfig.OS)" -ForegroundColor Cyan
Write-Host "  Computername: $($machineConfig.Computername)" -ForegroundColor Cyan

# Get OS WIM path
$wimPath = & "Z:\Scripts\Unattend2026\Get-OS.ps1" -MACAddress $macAddress

Dism.exe /Apply-Image /ImageFile:"$wimPath" /Index:1 /ApplyDir:C:\

# Copy and prepare install2026.ps1 with deployment share mapping
& "Z:\Scripts\Unattend2026\Copy-Install.ps1"

# Setup unattended.xml with settings from CustomSettings.json based on MAC address
& "Z:\Scripts\Unattend2026\Get-Settings.ps1" -MACAddress $macAddress

New-Item -ItemType Directory -Path "C:\Windows\Panther" -Force
Copy-Item "C:\temp\unattend.xml" "C:\Windows\Panther\unattend.xml"
Dism.exe /Image:C:\ /Apply-Unattend:"C:\Windows\Panther\unattend.xml"
remove-item "C:\temp\unattend.xml"

BCDBoot.exe C:\windows /l en-US
BCDEdit.exe /timeout 0
