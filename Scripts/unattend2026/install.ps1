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

# Get OS WIM path
$wimPath = & "Z:\Scripts\Unattend2026\Get-OS.ps1" -MACAddress $macAddress

Dism.exe /Apply-Image /ImageFile:"$wimPath" /Index:1 /ApplyDir:C:\

# Copy and prepare install2026.ps1 with deployment share mapping
& "Z:\Scripts\Unattend2026\Copy-Install.ps1"

& "Z:\Scripts\Unattend2026\Get-Settings.ps1" -MACAddress $macAddress

New-Item -ItemType Directory -Path "C:\Windows\Panther" -Force
Copy-Item "C:\temp\unattend.xml" "C:\Windows\Panther\unattend.xml"
Dism.exe /Image:C:\ /Apply-Unattend:"C:\Windows\Panther\unattend.xml"
remove-item "C:\temp\unattend.xml"

BCDBoot.exe C:\windows /l en-US
BCDEdit.exe /timeout 0

read-host "Installation complete. Press Enter to continue..."
