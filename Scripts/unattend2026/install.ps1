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

read-host "Installation complete. Press Enter to continue..."
