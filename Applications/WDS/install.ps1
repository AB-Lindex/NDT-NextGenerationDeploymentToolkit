"Install WDS role"
Install-WindowsFeature -Name WDS -IncludeManagementTools -Verbose

"Initialize WDS"
wdsutil.exe /Verbose /Progress /Initialize-Server /RemInst:"C:\RemoteInstall" /Standalone

"Configure WDS"
# PXE: respond to all clients (known and unknown)
wdsutil.exe /Set-Server /AnswerClients:All

# Boot: auto-continue PXE boot without prompt for both known and unknown clients
wdsutil.exe /Set-Server /PxePromptPolicy /Known:NoPrompt /New:NoPrompt

# DHCP: do not listen on port 67, do not set DHCP option 60 (only needed when DHCP is co-located)
if (Get-Service -Name DHCPServer -ErrorAction SilentlyContinue) {
    wdsutil.exe /Set-Server /UseDHCPPorts:No /DHCPOption60:No
} else {
    "DHCP Server service not found on this machine — skipping DHCP coexistence settings (expected when DHCP is on a separate server)"
}

# TFTP block size: 1024 bytes (requires service restart to take effect)
wdsutil.exe /Set-Server /Transport /TftpMaximumBlockSize:1024

"Restart WDS service to apply all settings"
Restart-Service -Name WDSServer -Force
