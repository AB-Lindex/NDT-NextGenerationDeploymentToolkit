Install-WindowsFeature `
-Name DHCP, Web-Server, Web-Mgmt-Tools `
-IncludeManagementTools `
-IncludeAllSubFeature

$base = "C:\iPXE"
$dirs = @(
"$base\tftp", # iPXE binaries (served via TFTP)
"$base\scripts", # iPXE .ipxe script files
"$base\images\winpe", # WinPE boot files
"$base\images\win11", # Windows 11 WIM
"$base\logs" # Deployment logs
)
foreach ($dir in $dirs) {
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Write-Host "Created: $dir" -ForegroundColor Green
iPXE Windows Deployment Guide PowerShell Setup | Windows Server
iPXE Deployment Guide Page 3
}

$serverIP = (Get-NetIPAddress -AddressFamily IPv4 `
-InterfaceAlias Ethernet).IPAddress
Add-DhcpServerInDC -DnsName $env:COMPUTERNAME -IPAddress $serverIP

Add-DhcpServerv4Scope `
-Name "Deployment" `
-StartRange "10.0.3.70" `
-EndRange "10.0.3.79" `
-SubnetMask "255.255.255.0" `
-State Active
Set-DhcpServerv4OptionValue `
-ScopeId 10.0.3.0 `
-Router "10.0.3.1" `
-DnsServerIPAddress "10.0.3.11" `
-DnsDomain "corp.dev"


$tftpServer = "10.0.3.38" # This server's IP
$bootFile = "ipxe.pxe"
# Option 66 = Next Server
Set-DhcpServerv4OptionValue -ScopeId 10.0.3.0 -OptionId 66 -Value $tftpServer
# Option 67 = Boot Filename
Set-DhcpServerv4OptionValue -ScopeId 10.0.3.0 -OptionId 67 -Value $bootFile
Restart-Service DHCPServer

# UEFI vendor class
Add-DhcpServerv4Class -Name 'PXEClient-UEFI-x64' -Type Vendor `
-Data 'PXEClient:Arch:00007'
# Policy: UEFI clients get .efi binary
Add-DhcpServerv4Policy -Name 'UEFI Boot' -ScopeId 10.0.3.0 `
-Condition Or -VendorClass EQ,'PXEClient:Arch:00007*'
Set-DhcpServerv4OptionValue -ScopeId 10.0.3.0 `
-PolicyName 'UEFI Boot' -OptionId 67 -Value 'ipxe.efi'
iPXE Windows Deployment Guide PowerShell Setup | Windows Server
iPXE Deployment Guide Page 5
# Policy: BIOS clients get .pxe binary
Add-DhcpServerv4Policy -Name 'BIOS Boot' -ScopeId 10.0.3.0 `
-Condition Or -VendorClass EQ,'PXEClient:Arch:00000*'
Set-DhcpServerv4OptionValue -ScopeId 10.0.3.0 `
-PolicyName 'BIOS Boot' -OptionId 67 -Value 'ipxe.pxe'

# Initialise WDS in standalone mode
wdsutil /Initialize-Server /RemInst:C:\RemoteInstall /Standalone
Start-Service WDSServer
Set-Service WDSServer -StartupType Automatic
Get-Service WDSServer | Select-Object Status, DisplayName

$tftpRoot = "C:\RemoteInstall\Boot\x64"
$ipxeDir = "C:\iPXE\tftp"
Copy-Item "$ipxeDir\ipxe.pxe" -Destination $tftpRoot
Copy-Item "$ipxeDir\ipxe.efi" -Destination $tftpRoot
# Tell WDS to use iPXE as the boot program
wdsutil /Set-Server /BootProgram:Boot\x64\ipxe.pxe /Architecture:x86
wdsutil /Set-Server /BootProgram:Boot\x64\ipxe.efi /Architecture:x64uefi
# Allow unknown clients without pre-staging
wdsutil /Set-Server /PxepromptPolicy /New:NoPrompt
wdsutil /Set-Server /PxepromptPolicy /Known:NoPrompt

Import-Module WebAdministration
$siteName = "iPXE"
$sitePath = "C:\iPXE"
$sitePort = 8080
New-WebAppPool -Name $siteName
Set-ItemProperty "IIS:\AppPools\$siteName" managedRuntimeVersion ""
New-Website -Name $siteName -PhysicalPath $sitePath `
-Port $sitePort -ApplicationPool $siteName -Force
Start-Website -Name $siteName
Write-Host "IIS site running on port $sitePort" -ForegroundColor Cyan

$mimeTypes = @{
".ipxe" = "text/plain"
".efi" = "application/octet-stream"
".pxe" = "application/octet-stream"
".wim" = "application/octet-stream"
".iso" = "application/octet-stream"
}
foreach ($ext in $mimeTypes.Keys) {
Add-WebConfigurationProperty `
-Filter "system.webServer/staticContent" -PSPath "IIS:\" `
-Name "." -Value @{ fileExtension=$ext; mimeType=$mimeTypes[$ext] }
}

New-NetFirewallRule -DisplayName "iPXE HTTP" `
-Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
New-NetFirewallRule -DisplayName "TFTP" `
-Direction Inbound -Protocol UDP -LocalPort 69 -Action Allow
New-NetFirewallRule -DisplayName "WDS" `
-Direction Inbound -Protocol UDP -LocalPort 4011 -Action Allow

