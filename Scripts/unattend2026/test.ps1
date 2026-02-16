# Get MAC address once
$macAddress = & "Z:\Scripts\Unattend2026\Get-MACAddress.ps1"

# Copy and prepare install2026.ps1 with deployment share mapping
& "Z:\Scripts\Unattend2026\Copy-Install.ps1"

# Setup unattended.xml with settings from CustomSettings.json based on MAC address
& "Z:\Scripts\Unattend2026\Get-Settings.ps1" -MACAddress $macAddress

New-Item -ItemType Directory -Path "C:\Windows\Panther" -Force
Copy-Item "C:\temp\unattend.xml" "C:\Windows\Panther\unattend.xml"
Dism.exe /Image:C:\ /Apply-Unattend:"C:\Windows\Panther\unattend.xml"
remove-item "C:\temp\unattend.xml"
