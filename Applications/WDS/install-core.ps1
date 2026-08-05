<#
    WDS install for Server Core (no Desktop Experience).

    WDS itself runs fine on Server Core — the caveat is management, not capability:
      - There is NO WDS MMC snap-in on Core. -IncludeManagementTools brings the
        wdsutil CLI + WDS PowerShell module only; the MMC is a Desktop Experience
        component. Manage locally with wdsutil (as NDT already does) or attach the
        WDS MMC remotely via RSAT from an admin workstation.
      - ADK / WinPE add-on is NOT installed here. This host only SERVES the finished
        boot2026.wim; build the WinPE image on the ADK host (ipxe01) and copy the WIM.
#>

"Verify this is Server Core (Desktop Experience not required)"
$installType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').InstallationType
"InstallationType: $installType"
if ($installType -eq 'Server') {
    "NOTE: this host has Desktop Experience — install.ps1 (with MMC) is the better fit, but this script still works."
}

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

# Disable TFTP variable window extension.
# The variable window causes intermittent 0xc0000001 boot failures on Hyper-V virtual networks
# (virtual switch drops/reorders the TFTP bursts). Disabling it forces simple stop-and-wait TFTP
# which is completely reliable. The throughput difference is negligible for a ~3 MB boot image.
wdsutil.exe /Set-Server /Transport /EnableTFTPVariableWindowExtension:No

"Restart WDS service to apply all settings"
Restart-Service -Name WDSServer -Force

<#
    NOTE: after adding the WinPE boot image via:
        wdsutil /Add-Image /ImageFile:"C:\Deploy2026\Boot\boot2026.wim" /ImageType:Boot /Name:"NDT PE Boot 2026"

    Set it as the default boot image for BOTH x64 (BIOS) and x64uefi (UEFI) clients.
    Without this, UEFI clients get 0xc0000001 "Windows failed to start" because WDS
    finds no default boot image for the x64uefi architecture and aborts the session.

    wdsutil /Set-Server /BootImage:boot2026.wim /Architecture:x64uefi
    wdsutil /Set-Server /BootImage:boot2026.wim /Architecture:x64
#>
