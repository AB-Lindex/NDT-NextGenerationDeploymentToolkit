<#
.SYNOPSIS
    iPXE Windows Deployment Environment - Full Setup Guide
    Target OS : Windows Server 2025
    Scope     : DHCP + WDS + IIS (HTTPS, static) + iPXE + WinPE + wimboot
    PKI       : Internal / own CA
    Author    : LeialmI
    Date      : 2026-03-05

.DESCRIPTION
    This script is an INTERACTIVE GUIDE. It is divided into clearly labeled
    sections. Run each section manually or use it as a reference checklist.
    Not all steps are fully automatable (e.g. cert issuance, iPXE build).
    Those steps are documented as comments with clear action items.

    SECTIONS
    --------
    1.  Prerequisites check
    2.  Windows Features installation  (minimal, no -IncludeAllSubFeature)
    3.  DHCP server configuration      (scope, options 66/67/60)
    4.  WDS initialisation
    5.  IIS HTTPS static site setup
    6.  TLS certificate binding        (internal PKI)
    7.  iPXE build guidance            (embed internal CA)
    8.  iPXE boot file placement
    9.  WinPE image preparation
    10. wimboot placement
    11. Sample iPXE boot scripts
    12. Firewall rules
    13. Validation checklist
#>

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# SECTION 1 – PREREQUISITES CHECK
# ============================================================
Write-Host "`n[1/13] Checking prerequisites..." -ForegroundColor Cyan

# Confirm OS
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -notmatch 'Windows Server 2025') {
    Write-Warning "This guide targets Windows Server 2025. Detected: $($os.Caption)"
} else {
    Write-Host "  OS OK: $($os.Caption)" -ForegroundColor Green
}

# Confirm running as Administrator (redundant with #Requires but explicit)
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please run this script as Administrator."
}

# Required variables – edit these before running
$ServerFQDN        = 'pxe.contoso.local'      # FQDN for IIS HTTPS binding & TLS cert SAN
$DHCPScopeID       = '192.168.1.0'            # DHCP scope network address
$DHCPScopeStart    = '192.168.1.100'          # DHCP range start
$DHCPScopeEnd      = '192.168.1.200'          # DHCP range end
$DHCPSubnetMask    = '255.255.255.0'          # Subnet mask
$DHCPGateway       = '192.168.1.1'            # Default gateway
$DHCPScopeName     = 'iPXE Deployment Scope'
$WDSRemInstPath    = 'D:\RemoteInstall'        # WDS remote install folder (dedicated drive recommended)
$IISSiteName       = 'iPXE'
$IISPhysicalPath   = 'D:\iPXE'                # Root folder for boot files served over HTTPS
$IISHttpsPort      = 443
$CertThumbprint    = ''                        # Fill in after cert is issued (Section 6)

Write-Host "  Variables loaded. Review values at the top of the script before proceeding." -ForegroundColor Yellow

# ============================================================
# SECTION 2 – WINDOWS FEATURES INSTALLATION
# ============================================================
# Only the subfeatures actually needed are installed.
# NO -IncludeAllSubFeature on Web-Server.
Write-Host "`n[2/13] Installing Windows Features..." -ForegroundColor Cyan

$features = @(
    # DHCP Server
    'DHCP',

    # Windows Deployment Services
    'WDS',
    'WDS-Deployment',
    'WDS-Transport',

    # IIS core
    'Web-Server',

    # IIS – static file serving (required for boot files)
    'Web-Static-Content',

    # IIS – HTTP to HTTPS redirect (optional, recommended)
    'Web-Http-Redirect',

    # IIS – Request Filtering (security baseline, keeps unwanted verbs/extensions blocked)
    'Web-Filtering',

    # IIS – HTTP Logging (useful for debugging iPXE fetches)
    'Web-Http-Logging',

    # IIS – Request Monitor (real-time request visibility)
    'Web-Request-Monitor',

    # IIS Management Tools (IIS Manager GUI + PowerShell module)
    'Web-Mgmt-Tools',
    'Web-Mgmt-Console',
    'Web-Scripting-Tools'
)

$result = Install-WindowsFeature -Name $features -IncludeManagementTools
if ($result.RestartNeeded -eq 'Yes') {
    Write-Warning "A restart is required. Restart now and re-run this script from Section 3 onward."
} else {
    Write-Host "  All features installed successfully." -ForegroundColor Green
}

# ============================================================
# SECTION 3 – DHCP SERVER CONFIGURATION
# ============================================================
Write-Host "`n[3/13] Configuring DHCP..." -ForegroundColor Cyan

# Authorise DHCP in Active Directory (requires Domain Admin or delegation)
try {
    Add-DhcpServerInDC -DnsName $ServerFQDN
    Write-Host "  DHCP server authorised in AD." -ForegroundColor Green
} catch {
    Write-Warning "  DHCP authorisation failed (may already be authorised or no AD): $_"
}

# Create IPv4 scope
Add-DhcpServerv4Scope `
    -Name        $DHCPScopeName `
    -StartRange  $DHCPScopeStart `
    -EndRange    $DHCPScopeEnd `
    -SubnetMask  $DHCPSubnetMask `
    -State       Active

# Scope options
Set-DhcpServerv4OptionValue `
    -ScopeId    $DHCPScopeID `
    -Router     $DHCPGateway `
    -DnsServer  (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -eq 'Manual' } | Select-Object -First 1 -ExpandProperty IPAddress)

# Option 66 – TFTP/boot server (point to this server)
Set-DhcpServerv4OptionValue -ScopeId $DHCPScopeID -OptionId 66 -Value $ServerFQDN

# Option 67 – Boot file
# For UEFI x64, use a chainloading snponly.efi or ipxe.efi
# For legacy BIOS,  use undionly.kpxe
# WDS + iPXE together: use WDS PXE first, chain to iPXE, or serve iPXE directly.
# Uncomment the appropriate line:
# Set-DhcpServerv4OptionValue -ScopeId $DHCPScopeID -OptionId 67 -Value 'boot\x64\ipxe.efi'   # UEFI
# Set-DhcpServerv4OptionValue -ScopeId $DHCPScopeID -OptionId 67 -Value 'undionly.kpxe'        # BIOS

# Option 060 – Vendor class (PXEClient marker, required for some firmware)
Set-DhcpServerv4OptionValue -ScopeId $DHCPScopeID -OptionId 60 -Value 'PXEClient'

Write-Host "  DHCP scope and options configured." -ForegroundColor Green
Write-Host "  ACTION: Set Option 67 boot filename based on UEFI/BIOS client type." -ForegroundColor Yellow

# ============================================================
# SECTION 4 – WDS INITIALISATION
# ============================================================
Write-Host "`n[4/13] Initialising WDS..." -ForegroundColor Cyan

# Create RemoteInstall folder if it does not exist
if (-not (Test-Path $WDSRemInstPath)) {
    New-Item -Path $WDSRemInstPath -ItemType Directory | Out-Null
}

<#
    WDS cannot be fully configured via PowerShell on first run.
    Use the WDS MMC console or run the following from an elevated CMD:

    wdsutil /Initialize-Server /RemInst:"D:\RemoteInstall"

    Post-initialisation:
    - Open WDS console
    - Right-click server → Properties → Boot tab:
        * Set "Default boot program" for x64 UEFI to:  boot\x64\ipxe.efi
        * Set "Default boot program" for x86 BIOS to:  boot\x86\undionly.kpxe
    - PXE Response: "Respond to all client computers (known and unknown)"
    - Add your WinPE boot image (Section 9) via: Add Boot Image wizard
    - Add your install image (install.wim) via:   Add Install Image wizard
#>

Write-Host "  ACTION: Run 'wdsutil /Initialize-Server /RemInst:$WDSRemInstPath' if this is a first-time setup." -ForegroundColor Yellow
Write-Host "  ACTION: Configure WDS boot tab and add images via WDS MMC." -ForegroundColor Yellow

# ============================================================
# SECTION 5 – IIS HTTPS STATIC SITE SETUP
# ============================================================
Write-Host "`n[5/13] Configuring IIS static site for iPXE..." -ForegroundColor Cyan

Import-Module WebAdministration -ErrorAction Stop

# Create physical path
if (-not (Test-Path $IISPhysicalPath)) {
    New-Item -Path $IISPhysicalPath -ItemType Directory | Out-Null
}

# Remove default site if present (avoid port conflicts)
if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) {
    Remove-Website -Name 'Default Web Site'
    Write-Host "  Removed Default Web Site." -ForegroundColor DarkGray
}

# Create application pool
if (-not (Get-WebConfiguration -Filter "system.applicationHost/applicationPools/add[@name='$IISSiteName']")) {
    New-WebAppPool -Name $IISSiteName
    Set-ItemProperty -Path "IIS:\AppPools\$IISSiteName" -Name processModel.identityType -Value NetworkService
}

# Create the website (HTTP initially; HTTPS binding added in Section 6 after cert)
if (-not (Get-Website -Name $IISSiteName -ErrorAction SilentlyContinue)) {
    New-Website `
        -Name           $IISSiteName `
        -PhysicalPath   $IISPhysicalPath `
        -ApplicationPool $IISSiteName `
        -Port           80 `
        -Force
}

# Enable Directory Browsing (optional – helpful for iPXE scripting)
Set-WebConfigurationProperty -Filter 'system.webServer/directoryBrowse' `
    -Name 'enabled' -Value $true -PSPath "IIS:\Sites\$IISSiteName"

# Add MIME types required for iPXE / WinPE / wimboot
$mimeTypes = @(
    @{ Extension = '.ipxe'; MimeType = 'text/plain' },
    @{ Extension = '.efi';  MimeType = 'application/octet-stream' },
    @{ Extension = '.krn';  MimeType = 'application/octet-stream' },
    @{ Extension = '.0';    MimeType = 'application/octet-stream' },  # pxelinux.0 / wimboot
    @{ Extension = '.img';  MimeType = 'application/octet-stream' },
    @{ Extension = '.wim';  MimeType = 'application/octet-stream' },
    @{ Extension = '.sdi';  MimeType = 'application/octet-stream' },
    @{ Extension = '.cfg';  MimeType = 'text/plain' }
)

foreach ($mime in $mimeTypes) {
    $filter = "system.webServer/staticContent/mimeMap[@fileExtension='$($mime.Extension)']"
    if (-not (Get-WebConfigurationProperty -PSPath "IIS:\Sites\$IISSiteName" -Filter $filter -Name '.')) {
        Add-WebConfigurationProperty `
            -PSPath  "IIS:\Sites\$IISSiteName" `
            -Filter  'system.webServer/staticContent' `
            -Name    '.' `
            -Value   @{ fileExtension = $mime.Extension; mimeType = $mime.MimeType }
        Write-Host "  Added MIME type: $($mime.Extension) -> $($mime.MimeType)" -ForegroundColor DarkGray
    }
}

Write-Host "  IIS site '$IISSiteName' created on port 80 (HTTPS binding follows in Section 6)." -ForegroundColor Green

# ============================================================
# SECTION 6 – TLS CERTIFICATE BINDING (INTERNAL PKI)
# ============================================================
Write-Host "`n[6/13] TLS certificate binding..." -ForegroundColor Cyan

<#
    INTERNAL PKI REQUIREMENTS
    -------------------------
    1. On your CA (ADCS), issue a Web Server certificate with:
       - Subject / SAN: DNS = $ServerFQDN (e.g. pxe.contoso.local)
       - EKU: Server Authentication (1.3.6.1.5.5.7.3.1)
       - Key usage: Digital Signature, Key Encipherment
       - Include the full chain (server + intermediate) in the response

    2. Import the cert to the LOCAL MACHINE > Personal store on this server:
       Import-PfxCertificate -FilePath 'C:\certs\pxe-server.pfx' `
           -CertStoreLocation Cert:\LocalMachine\My `
           -Password (Read-Host -AsSecureString 'PFX Password')

    3. Copy the thumbprint (no spaces) into $CertThumbprint at the top of this script.

    4. Re-run this section.
#>

if ([string]::IsNullOrWhiteSpace($CertThumbprint)) {
    Write-Warning "  \$CertThumbprint is empty. Complete the cert import steps above, then set the thumbprint and re-run Section 6."
} else {
    # Remove any existing HTTP binding on port 80 redirect later; add HTTPS
    New-WebBinding -Name $IISSiteName -Protocol 'https' -Port $IISHttpsPort -HostHeader $ServerFQDN

    # Bind certificate to the HTTPS binding via http.sys
    $cert = Get-Item "Cert:\LocalMachine\My\$CertThumbprint"
    $guid = [System.Guid]::NewGuid().ToString('B')

    # Use netsh to bind the cert (most reliable cross-version approach)
    $ip = '0.0.0.0'
    netsh http add sslcert ipport="${ip}:${IISHttpsPort}" `
        certhash=$CertThumbprint `
        appid=$guid | Out-Null

    # Optional: redirect HTTP → HTTPS
    # Requires Web-Http-Redirect feature (installed in Section 2)
    Set-WebConfiguration -Filter 'system.webServer/httpRedirect' `
        -PSPath "IIS:\Sites\$IISSiteName" `
        -Value @{
            enabled         = $true
            destination     = "https://$ServerFQDN"
            exactDestination = $false
            httpResponseStatus = 'Permanent'
        }

    Write-Host "  HTTPS binding created and certificate bound." -ForegroundColor Green
    Write-Host "  ACTION: Verify in IIS Manager -> $IISSiteName -> Bindings." -ForegroundColor Yellow
}

# ============================================================
# SECTION 7 – iPXE BUILD GUIDANCE (EMBED INTERNAL CA)
# ============================================================
Write-Host "`n[7/13] iPXE build notes (internal PKI / HTTPS)..." -ForegroundColor Cyan

<#
    WHY YOU MUST EMBED YOUR CA
    --------------------------
    iPXE ships with Mozilla's public CA bundle. Your internal CA is NOT in it.
    Without embedding your root (and any intermediate) CA, iPXE HTTPS downloads
    will fail with a TLS certificate verification error.

    BUILD STEPS (Linux build host recommended)
    ------------------------------------------
    1. Install build dependencies:
       sudo apt-get install build-essential liblzma-dev isolinux git

    2. Clone iPXE:
       git clone https://github.com/ipxe/ipxe.git
       cd ipxe/src

    3. Export your internal Root CA and any intermediate CA(s) as PEM:
       # On Windows:
       certutil -ca.cert rootca.cer
       certutil -encode rootca.cer rootca.pem
       # Copy rootca.pem (and intermediates) to your Linux build host.

    4. Concatenate CA chain:
       cat rootca.pem intermediateca.pem > internal-ca-chain.pem

    5. Place the PEM in config/local/ and configure crypto:
       # In config/local/crypto.h  (create if missing):
       #define TRUSTED_CA  "internal-ca-chain.pem"

       Alternatively, pass it at make time via:
       EMBED=myscript.ipxe (see step 7)

    6. (Optional but recommended) Embed a boot script so iPXE auto-loads it:
       Create boot.ipxe (see Section 11 for sample), then:
       # in config/local/general.h:
       #define EMBED_SCRIPT "boot.ipxe"

    7. Build for UEFI x64 and/or legacy BIOS:
       # UEFI x64:
       make bin-x86_64-efi/ipxe.efi TRUST=internal-ca-chain.pem EMBED=boot.ipxe
       # Legacy BIOS (UNDI only, most compatible):
       make bin/undionly.kpxe        TRUST=internal-ca-chain.pem EMBED=boot.ipxe
       # BIOS full NIC driver:
       make bin/ipxe.pxe             TRUST=internal-ca-chain.pem EMBED=boot.ipxe

    8. Copy the built files to $WDSRemInstPath\Boot\:
       ipxe.efi       → D:\RemoteInstall\Boot\x64\ipxe.efi
       undionly.kpxe  → D:\RemoteInstall\Boot\x86\undionly.kpxe

    IMPORTANT: The TRUST= flag is the key – it replaces the built-in Mozilla CA
    bundle with ONLY your internal chain. Clients will reject public certs, so
    ensure all your download URLs use your internal CA-signed cert.
#>

Write-Host "  ACTION: Build iPXE with TRUST=<your-ca-chain.pem> on a Linux host." -ForegroundColor Yellow
Write-Host "  ACTION: Copy ipxe.efi and undionly.kpxe to $WDSRemInstPath\Boot\." -ForegroundColor Yellow

# ============================================================
# SECTION 8 – iPXE BOOT FILE PLACEMENT
# ============================================================
Write-Host "`n[8/13] Creating iPXE web root folder structure..." -ForegroundColor Cyan

$folders = @(
    "$IISPhysicalPath\boot",       # boot scripts
    "$IISPhysicalPath\wimboot",    # wimboot binary
    "$IISPhysicalPath\winpe",      # WinPE files (BCD, boot.sdi, boot.wim)
    "$IISPhysicalPath\drivers",    # optional injected drivers
    "$IISPhysicalPath\scripts"     # additional iPXE chain scripts
)

foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        New-Item -Path $folder -ItemType Directory | Out-Null
        Write-Host "  Created: $folder" -ForegroundColor DarkGray
    }
}

<#
    Expected file layout under $IISPhysicalPath:
    ├── boot\
    │   └── boot.ipxe          ← main iPXE menu/script (see Section 11)
    ├── wimboot\
    │   └── wimboot             ← wimboot binary (https://git.ipxe.org/wimboot.git)
    ├── winpe\
    │   ├── BCD                 ← BCD from WinPE/ADK build
    │   ├── boot.sdi            ← boot.sdi from Windows ADK
    │   └── boot.wim            ← WinPE boot.wim (Section 9)
    ├── drivers\                ← optional: NIC/storage drivers for WinPE injection
    └── scripts\
        └── *.ipxe              ← per-model or per-task chain scripts
#>

Write-Host "  Folder structure ready under $IISPhysicalPath." -ForegroundColor Green
Write-Host "  ACTION: Place wimboot, WinPE files, and scripts per the layout above." -ForegroundColor Yellow

# ============================================================
# SECTION 9 – WinPE IMAGE PREPARATION
# ============================================================
Write-Host "`n[9/13] WinPE preparation notes..." -ForegroundColor Cyan

<#
    REQUIREMENTS: Windows ADK + WinPE Add-on for Windows 11/Server 2025
    Download from: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install

    STEPS
    -----
    1. Open "Deployment and Imaging Tools Environment" as Administrator.

    2. Create a WinPE working copy (x64):
       copype amd64 C:\WinPE_amd64

    3. Mount the WinPE image:
       Dism /Mount-Image /ImageFile:"C:\WinPE_amd64\media\sources\boot.wim" /index:1 /MountDir:"C:\WinPE_amd64\mount"

    4. (Optional) Add WinPE optional components:
       Dism /Add-Package /Image:"C:\WinPE_amd64\mount" /PackagePath:"%WinPERoot%\amd64\WinPE_OCs\WinPE-WMI.cab"
       Dism /Add-Package /Image:"C:\WinPE_amd64\mount" /PackagePath:"%WinPERoot%\amd64\WinPE_OCs\WinPE-NetFX.cab"
       Dism /Add-Package /Image:"C:\WinPE_amd64\mount" /PackagePath:"%WinPERoot%\amd64\WinPE_OCs\WinPE-Scripting.cab"
       Dism /Add-Package /Image:"C:\WinPE_amd64\mount" /PackagePath:"%WinPERoot%\amd64\WinPE_OCs\WinPE-PowerShell.cab"

    5. Import your internal Root CA so WinPE trusts HTTPS from your IIS server:
       $certPath = 'C:\certs\rootca.cer'
       Import-Certificate -FilePath $certPath `
           -CertStoreLocation "Cert:\LocalMachine\Root" `
           -ErrorAction Stop
       # OR use DISM offline:
       # certutil -addstore -f Root $certPath

    6. (Optional) Inject NIC/storage drivers:
       Dism /Add-Driver /Image:"C:\WinPE_amd64\mount" /Driver:"C:\Drivers\" /Recurse

    7. Commit and unmount:
       Dism /Unmount-Image /MountDir:"C:\WinPE_amd64\mount" /Commit

    8. Copy output files to IIS:
       Copy-Item "C:\WinPE_amd64\media\sources\boot.wim" "$IISPhysicalPath\winpe\boot.wim"
       Copy-Item "C:\WinPE_amd64\media\Boot\BCD"         "$IISPhysicalPath\winpe\BCD"
       Copy-Item "C:\WinPE_amd64\media\Boot\boot.sdi"    "$IISPhysicalPath\winpe\boot.sdi"
#>

Write-Host "  ACTION: Build WinPE with ADK, inject internal CA root cert, copy output to $IISPhysicalPath\winpe\." -ForegroundColor Yellow

# ============================================================
# SECTION 10 – wimboot PLACEMENT
# ============================================================
Write-Host "`n[10/13] wimboot notes..." -ForegroundColor Cyan

<#
    wimboot is a small bootloader that allows WinPE/Windows to boot directly
    from a WIM file over HTTP (via iPXE).

    Download latest release:
    https://github.com/ipxe/wimboot/releases

    Place the binary:
    Copy-Item 'wimboot' "$IISPhysicalPath\wimboot\wimboot"

    iPXE uses it as a kernel-like image (see Section 11 boot script).
#>

Write-Host "  ACTION: Download wimboot from https://github.com/ipxe/wimboot/releases" -ForegroundColor Yellow
Write-Host "  ACTION: Place at $IISPhysicalPath\wimboot\wimboot" -ForegroundColor Yellow

# ============================================================
# SECTION 11 – SAMPLE iPXE BOOT SCRIPTS
# ============================================================
Write-Host "`n[11/13] Writing sample iPXE boot scripts..." -ForegroundColor Cyan

# Main menu script
$bootIpxe = @"
#!ipxe

# -------------------------------------------------------
# iPXE Boot Menu – $ServerFQDN
# Internal PKI: CA must be embedded in iPXE binary
# -------------------------------------------------------

:start
menu iPXE Boot Menu
item --gap             -- Windows Deployment --
item winpe             Boot WinPE x64 (wimboot)
item --gap             -- Utilities --
item shell             iPXE Shell
item reboot            Reboot
choose --default winpe --timeout 30000 target && goto `${target}

:winpe
echo Booting WinPE via wimboot...
kernel https://$ServerFQDN/wimboot/wimboot
initrd https://$ServerFQDN/winpe/BCD         BCD
initrd https://$ServerFQDN/winpe/boot.sdi    boot.sdi
initrd https://$ServerFQDN/winpe/boot.wim    boot.wim
boot || goto failed

:shell
echo Dropping to iPXE shell...
shell

:reboot
reboot

:failed
echo Boot failed – press any key to return to menu
prompt
goto start
"@

$bootScriptPath = "$IISPhysicalPath\boot\boot.ipxe"
$bootIpxe | Set-Content -Path $bootScriptPath -Encoding UTF8
Write-Host "  Written: $bootScriptPath" -ForegroundColor Green

# ============================================================
# SECTION 12 – FIREWALL RULES
# ============================================================
Write-Host "`n[12/13] Configuring firewall rules..." -ForegroundColor Cyan

$firewallRules = @(
    @{ Name = 'iPXE-DHCP-In';    Port = 67;  Protocol = 'UDP'; Description = 'DHCP Server inbound' },
    @{ Name = 'iPXE-DHCP-Out';   Port = 68;  Protocol = 'UDP'; Description = 'DHCP Client outbound' },
    @{ Name = 'iPXE-TFTP-In';    Port = 69;  Protocol = 'UDP'; Description = 'TFTP (WDS PXE)' },
    @{ Name = 'iPXE-HTTP-In';    Port = 80;  Protocol = 'TCP'; Description = 'HTTP (redirect to HTTPS)' },
    @{ Name = 'iPXE-HTTPS-In';   Port = 443; Protocol = 'TCP'; Description = 'HTTPS (iPXE boot files)' },
    @{ Name = 'iPXE-WDS-RPC-In'; Port = 135; Protocol = 'TCP'; Description = 'WDS RPC endpoint mapper' }
)

foreach ($rule in $firewallRules) {
    if (-not (Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -DisplayName  $rule.Name `
            -Direction    Inbound `
            -Protocol     $rule.Protocol `
            -LocalPort    $rule.Port `
            -Action       Allow `
            -Description  $rule.Description | Out-Null
        Write-Host "  Firewall rule created: $($rule.Name)" -ForegroundColor DarkGray
    } else {
        Write-Host "  Firewall rule already exists: $($rule.Name)" -ForegroundColor DarkGray
    }
}

Write-Host "  Firewall rules configured." -ForegroundColor Green

# ============================================================
# SECTION 13 – VALIDATION CHECKLIST
# ============================================================
Write-Host "`n[13/13] Validation checklist..." -ForegroundColor Cyan

$checks = @(
    "DHCP scope is active and handing out leases",
    "Option 66 points to $ServerFQDN",
    "Option 67 set to correct boot filename (ipxe.efi or undionly.kpxe)",
    "WDS initialised and boot images added",
    "IIS site '$IISSiteName' running on port 443",
    "TLS cert bound (check: netsh http show sslcert)",
    "Cert SAN matches $ServerFQDN",
    "Internal CA embedded in iPXE binary (TRUST= flag at build)",
    "Internal CA imported into WinPE image (Section 9 step 5)",
    "wimboot placed at $IISPhysicalPath\wimboot\wimboot",
    "WinPE files (BCD, boot.sdi, boot.wim) placed at $IISPhysicalPath\winpe\",
    "boot.ipxe placed at $IISPhysicalPath\boot\boot.ipxe",
    "Test client PXE boots and reaches iPXE menu",
    "WinPE loads successfully over HTTPS"
)

Write-Host ""
$i = 1
foreach ($check in $checks) {
    Write-Host "  [ ] $i. $check" -ForegroundColor White
    $i++
}

Write-Host ""
Write-Host "Setup guide complete. Work through the checklist above to validate your environment." -ForegroundColor Cyan
Write-Host "For iPXE build help: https://ipxe.org/download" -ForegroundColor DarkGray
Write-Host "For wimboot:         https://github.com/ipxe/wimboot" -ForegroundColor DarkGray
Write-Host "For WinPE/ADK:       https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" -ForegroundColor DarkGray
