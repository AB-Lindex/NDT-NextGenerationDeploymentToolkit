<#
.SYNOPSIS
    Configure a Windows Server 2025 box (WDS + ADK already installed) to serve
    iPXE. Chainloads the prebuilt iPXE binaries in this folder from the existing
    WDS/PXE server and boots the repo's WinPE (boot2026.wim) over HTTP via wimboot.

    NOTE: Run under Windows PowerShell 5.1 (powershell.exe). The WebAdministration
    IIS:\ provider and the ServerManager module are unreliable under PowerShell 7.

.DESCRIPTION
    Architecture (all choices are HTTP, no internal-PKI / HTTPS):

        firmware PXE --> WDS (TFTP) --> snponly.efi / ipxe.pxe   (chainload)
                                            |
                                            v   (loop broken by DHCP user-class "iPXE")
                                    http://<host>/boot/boot.ipxe
                                            |
                                            v   wimboot
                                    http://<host>/winpe/{BCD,boot.sdi,boot.wim}

    The script is idempotent - safe to re-run. It:

      1. Verifies prerequisites (Admin, WDS initialised, ADK present) and
         installs IIS if missing.
      2. Copies the prebuilt iPXE binaries from this folder into the WDS
         RemoteInstall\Boot tree.
      3. Points the WDS boot programs at iPXE (x64 UEFI = snponly.efi,
         BIOS = ipxe.pxe) and restarts WDS.
      4. Creates a dedicated IIS site (host-header bound, coexists with any
         Default Web Site) with the MIME types iPXE/wimboot need.
      5. Stages the payload: downloads wimboot, copies boot2026.wim, and
         extracts BCD + boot.sdi from the ADK WinPE media.
      6. Writes boot\boot.ipxe (menu that boots WinPE via wimboot).
      7. Breaks the PXE chainload loop: if the DHCP Server role is local, it
         auto-creates the "iPXE" user class + a policy that serves the HTTP
         boot script to iPXE clients only. If DHCP is remote, it prints the
         exact settings to apply there.
      8. Opens the firewall (TFTP 69/UDP + the HTTP port).

    WHY THESE BINARIES / WHY HTTP
    -----------------------------
    * snponly.efi uses the firmware's own SNP/UNDI NIC driver - the most
      compatible choice when chainloading from WDS (no iPXE driver conflicts).
    * ipxe.pxe covers legacy BIOS clients.
    * The prebuilt ipxe.efi / snponly.efi ship with Mozilla's public CA bundle,
      NOT your internal CA, so HTTPS to an internal PKI would fail TLS. HTTP is
      the correct transport for these stock binaries. To use HTTPS you must
      rebuild iPXE with TRUST=<your-ca-chain.pem> embedded.

    Target : Windows Server 2025  (WDS + Windows ADK + WinPE add-on installed)
    Author : LeialmI  (rewritten 2026-07-04)
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    # Hostname clients use in HTTP URLs. Must resolve on the deployment network.
    [string]$ServerHost = $env:COMPUTERNAME,

    # WDS remote install root.
    [string]$RemoteInstallPath = 'C:\RemoteInstall',

    # IIS site hosting the iPXE boot files.
    [string]$SiteName = 'iPXE',
    [string]$SitePath = 'C:\iPXE',
    [int]   $HttpPort = 80,

    # WinPE image to boot. Default resolves to <share-root>\Boot\boot2026.wim
    # relative to this script (works from any drive letter / UNC). Copied to
    # C:\iPXE\winpe\boot.wim - iPXE always requests boot.wim, so no rename needed.
    [string]$BootWim,

    # Direct download of the latest wimboot binary (official ipxe.org location).
    # Hybrid binary - works on BIOS and 64-bit UEFI (incl. Secure Boot).
    [string]$WimbootUrl = 'https://github.com/ipxe/wimboot/releases/latest/download/wimboot',

    # Skip the automatic DHCP user-class / policy configuration.
    [switch]$SkipDhcpPolicy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step  { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok    { param($m) Write-Host "    [ok]   $m" -ForegroundColor Green }
function Write-Info  { param($m) Write-Host "    [info] $m" -ForegroundColor DarkGray }
function Write-Todo  { param($m) Write-Host "    [TODO] $m" -ForegroundColor Yellow }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Default the WinPE source to <share-root>\Boot\boot2026.wim (this script lives in
# <share-root>\Applications\iPXE), so it resolves regardless of drive letter / UNC.
if (-not $BootWim) {
    $shareRoot = Split-Path (Split-Path $ScriptDir -Parent) -Parent
    $BootWim   = Join-Path $shareRoot 'Boot\boot2026.wim'
}

# Resolve an FQDN when possible (falls back to the short name / passed value).
try {
    if ($ServerHost -eq $env:COMPUTERNAME) {
        $ServerHost = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    }
} catch { Write-Info "Could not resolve FQDN; using '$ServerHost'." }

$BaseUrl        = "http://${ServerHost}:$HttpPort"
$BootScriptUrl  = "$BaseUrl/boot/boot.ipxe"

# ============================================================
# 1 - PREREQUISITES
# ============================================================
Write-Step '1/8  Checking prerequisites'

$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -notmatch 'Windows Server 2025') {
    Write-Warning "This script targets Windows Server 2025. Detected: $($os.Caption)"
} else {
    Write-Ok "OS: $($os.Caption)"
}

# WDS role + initialisation.
if (-not (Get-WindowsFeature -Name WDS).Installed) {
    throw "WDS role is not installed. Install it (see Applications\WDS\install.ps1) before running this script."
}
# 'wdsutil /get-server' returns non-zero when the role exists but was never initialised.
& wdsutil /get-server /show:config 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "WDS is installed but not initialised. Run: wdsutil /Initialize-Server /RemInst:`"$RemoteInstallPath`""
}
if (-not (Test-Path $RemoteInstallPath)) {
    throw "RemoteInstall path '$RemoteInstallPath' not found. Is WDS initialised at a different location?"
}
Write-Ok "WDS is installed and initialised ($RemoteInstallPath)."

# ADK / WinPE (needed to source BCD + boot.sdi for wimboot).
# Read the registry value defensively - Set-StrictMode makes a missing property throw,
# and the key lives under the WOW6432Node view on 64-bit installs.
$kitsRoot = $null
foreach ($rk in @(
        'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots')) {
    $key = Get-Item $rk -ErrorAction SilentlyContinue
    if ($key) {
        $val = $key.GetValue('KitsRoot10')
        if ($val) { $kitsRoot = $val; break }
    }
}
$copype   = if ($kitsRoot) { Join-Path $kitsRoot 'Assessment and Deployment Kit\Windows Preinstallation Environment\copype.cmd' } else { $null }
$dandiEnv = if ($kitsRoot) { Join-Path $kitsRoot 'Assessment and Deployment Kit\Deployment Tools\DandISetEnv.bat' } else { $null }
if ($copype -and (Test-Path $copype)) {
    Write-Ok "Windows ADK + WinPE add-on found."
} else {
    Write-Warning "ADK WinPE (copype.cmd) not found. BCD/boot.sdi extraction (step 5) will be skipped - supply them manually."
}

# IIS - install if missing.
if (-not (Get-WindowsFeature -Name Web-Server).Installed) {
    Write-Info "Installing IIS (static content + management tools)..."
    Install-WindowsFeature -Name Web-Server, Web-Static-Content, Web-Http-Logging,
        Web-Mgmt-Console, Web-Scripting-Tools -IncludeManagementTools | Out-Null
}
Import-Module WebAdministration -ErrorAction Stop
Write-Ok "IIS available."

# ============================================================
# 2 - COPY iPXE BINARIES INTO WDS
# ============================================================
Write-Step '2/8  Staging iPXE binaries into WDS'

$bootX64 = Join-Path $RemoteInstallPath 'Boot\x64'
$bootX86 = Join-Path $RemoteInstallPath 'Boot\x86'
foreach ($d in @($bootX64, $bootX86)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$binaries = @(
    @{ Src = 'snponly.efi'; Dst = (Join-Path $bootX64 'snponly.efi') },  # x64 UEFI chainload (preferred)
    @{ Src = 'ipxe.efi';    Dst = (Join-Path $bootX64 'ipxe.efi')    },  # x64 UEFI (full driver, fallback)
    @{ Src = 'ipxe.pxe';    Dst = (Join-Path $bootX86 'ipxe.pxe')    }   # legacy BIOS
)
foreach ($b in $binaries) {
    $src = Join-Path $ScriptDir $b.Src
    if (-not (Test-Path $src)) { Write-Warning "Missing binary '$($b.Src)' in $ScriptDir - skipped."; continue }
    Copy-Item $src $b.Dst -Force
    Write-Ok "Copied $($b.Src) -> $($b.Dst)"
}

# ============================================================
# 3 - POINT WDS BOOT PROGRAMS AT iPXE
# ============================================================
Write-Step '3/8  Configuring WDS boot programs'

function Set-WdsBootProgram {
    param([string]$Arch, [string]$Program)
    foreach ($opt in @('BootProgram', 'N12BootProgram')) {
        $out = & wdsutil "/Set-Server" "/$($opt):$Program" "/Architecture:$Arch" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "wdsutil /Set-Server /$opt for $Arch FAILED (exit $LASTEXITCODE): $out"
        }
    }
    Write-Ok "$Arch boot program -> $Program"
}

# x64 UEFI clients (DHCP arch 7/9) -> snponly.efi (firmware SNP/UNDI - best for chainload)
Set-WdsBootProgram -Arch 'x64uefi' -Program 'boot\x64\snponly.efi'

# Legacy BIOS clients (DHCP arch 0) -> ipxe.pxe
Set-WdsBootProgram -Arch 'x86' -Program 'boot\x86\ipxe.pxe'

Restart-Service -Name WDSServer -Force
Start-Sleep -Seconds 3
Write-Ok 'WDS service restarted.'

# Verify the UEFI boot program actually stuck (this was silently failing before).
$cfg = (& wdsutil /Get-Server /Show:Config 2>&1) -join "`n"
if ($cfg -match 'x64uefi\s*-\s*boot\\x64\\snponly\.efi') {
    Write-Ok 'Verified: x64uefi boot program = boot\x64\snponly.efi'
} else {
    Write-Warning 'Could not verify x64uefi boot program = snponly.efi. Check: wdsutil /Get-Server /Show:Config'
}

# ============================================================
# 4 - IIS SITE
# ============================================================
Write-Step '4/8  Creating IIS site for iPXE boot files'

foreach ($sub in @('', 'boot', 'wimboot', 'winpe', 'scripts')) {
    $p = if ($sub) { Join-Path $SitePath $sub } else { $SitePath }
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# App pool.
if (-not (Test-Path "IIS:\AppPools\$SiteName")) {
    New-WebAppPool -Name $SiteName | Out-Null
    Set-ItemProperty "IIS:\AppPools\$SiteName" -Name managedRuntimeVersion -Value ''  # no managed code
}

# Site (host-header bound so it coexists with Default Web Site on the same port).
if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
    New-Website -Name $SiteName -PhysicalPath $SitePath -ApplicationPool $SiteName `
        -Port $HttpPort -HostHeader $ServerHost -Force | Out-Null
}
# Also answer requests without a host header (e.g. clients using the bare IP).
if (-not (Get-WebBinding -Name $SiteName -Port $HttpPort -HostHeader '' -ErrorAction SilentlyContinue)) {
    New-WebBinding -Name $SiteName -Protocol http -Port $HttpPort -HostHeader '' -ErrorAction SilentlyContinue | Out-Null
}
Write-Ok "Site '$SiteName' bound to $BaseUrl (physical: $SitePath)."

# MIME types. iPXE/wimboot fetch several extensionless files (wimboot, BCD),
# so a '.' mapping is required for IIS to serve them.
$mime = @(
    @{ ext = '.';       type = 'application/octet-stream' },  # extensionless (wimboot, BCD)
    @{ ext = '.ipxe';   type = 'text/plain'               },
    @{ ext = '.efi';    type = 'application/octet-stream' },
    @{ ext = '.wim';    type = 'application/octet-stream' },
    @{ ext = '.sdi';    type = 'application/octet-stream' }
)
foreach ($m in $mime) {
    $f = "system.webServer/staticContent/mimeMap[@fileExtension='$($m.ext)']"
    if (Get-WebConfigurationProperty -PSPath "IIS:\Sites\$SiteName" -Filter $f -Name '.' -ErrorAction SilentlyContinue) {
        Remove-WebConfigurationProperty -PSPath "IIS:\Sites\$SiteName" -Filter 'system.webServer/staticContent' `
            -Name '.' -AtElement @{ fileExtension = $m.ext } -ErrorAction SilentlyContinue
    }
    Add-WebConfigurationProperty -PSPath "IIS:\Sites\$SiteName" -Filter 'system.webServer/staticContent' `
        -Name '.' -Value @{ fileExtension = $m.ext; mimeType = $m.type }
}
Write-Ok 'MIME types configured (including extensionless).'

# ============================================================
# 5 - STAGE THE BOOT PAYLOAD
# ============================================================
Write-Step '5/8  Staging wimboot + WinPE payload'

# 5a. wimboot
$wimbootDst = Join-Path $SitePath 'wimboot\wimboot'
try {
    Invoke-WebRequest -Uri $WimbootUrl -OutFile $wimbootDst -UseBasicParsing
    Write-Ok "Downloaded wimboot -> $wimbootDst"
} catch {
    Write-Todo "Could not download wimboot from $WimbootUrl ($($_.Exception.Message))."
    Write-Todo "Manually place the wimboot binary at: $wimbootDst"
}

# 5b. boot.wim (repo WinPE)
$bootWimDst = Join-Path $SitePath 'winpe\boot.wim'
if (Test-Path $BootWim) {
    Copy-Item $BootWim $bootWimDst -Force
    Write-Ok "Copied WinPE image -> $bootWimDst"
} else {
    Write-Todo "WinPE image not found at $BootWim - copy your boot.wim to $bootWimDst."
}

# 5c. BCD + boot.sdi from ADK WinPE media (via copype)
$bcdDst = Join-Path $SitePath 'winpe\BCD'
$sdiDst = Join-Path $SitePath 'winpe\boot.sdi'
if ((Test-Path $bcdDst) -and (Test-Path $sdiDst)) {
    Write-Ok 'BCD + boot.sdi already present.'
} elseif ($copype -and (Test-Path $copype) -and $dandiEnv -and (Test-Path $dandiEnv)) {
    $tmp = Join-Path $env:TEMP ("winpe_" + [guid]::NewGuid().ToString('N'))
    try {
        Write-Info 'Generating BCD + boot.sdi with copype...'
        $cmdLine = '"' + $dandiEnv + '" && copype amd64 "' + $tmp + '"'
        & cmd.exe /c $cmdLine | Out-Null
        Copy-Item (Join-Path $tmp 'media\Boot\BCD')      $bcdDst -Force
        Copy-Item (Join-Path $tmp 'media\Boot\boot.sdi') $sdiDst -Force
        Write-Ok 'Extracted BCD + boot.sdi from ADK WinPE media.'
    } catch {
        Write-Todo "copype failed ($($_.Exception.Message)). Copy BCD + boot.sdi manually to $($SitePath)\winpe\."
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
} else {
    Write-Todo "ADK not available - copy BCD + boot.sdi from a WinPE media build to $($SitePath)\winpe\."
}

# ============================================================
# 6 - iPXE BOOT SCRIPT
# ============================================================
Write-Step '6/8  Writing boot\boot.ipxe'

$bootIpxe = @"
#!ipxe
# ------------------------------------------------------------------
# NDT iPXE menu - served from $BaseUrl
# ------------------------------------------------------------------
:start
menu NDT Deployment - $ServerHost
item --gap --                 --- Deploy ---
item winpe   Boot WinPE (boot2026.wim) over HTTP
item --gap --                 --- Tools ---
item shell   iPXE shell
item reboot  Reboot
item exit    Exit / continue local boot
choose --default winpe --timeout 30000 target && goto `${target}

:winpe
echo Booting WinPE via wimboot from $BaseUrl ...
kernel $BaseUrl/wimboot/wimboot
initrd $BaseUrl/winpe/BCD       BCD
initrd $BaseUrl/winpe/boot.sdi  boot.sdi
initrd $BaseUrl/winpe/boot.wim  boot.wim
boot || goto failed

:shell
shell
goto start

:reboot
reboot

:exit
exit

:failed
echo Boot failed - press a key to return to the menu
prompt
goto start
"@
$bootScriptPath = Join-Path $SitePath 'boot\boot.ipxe'
# Write without BOM - iPXE requires the '#!ipxe' magic on the very first byte.
[System.IO.File]::WriteAllText($bootScriptPath, ($bootIpxe -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "Wrote $bootScriptPath"

# ============================================================
# 7 - LOOP BREAK (DHCP user-class "iPXE")
# ============================================================
Write-Step '7/8  Breaking the chainload loop'

<#
    WHY THIS IS NEEDED
    ------------------
    Firmware PXE boots snponly.efi/ipxe.pxe from WDS. Stock iPXE then re-runs
    DHCP; without a distinguisher it would be handed the SAME iPXE binary again
    -> infinite loop. iPXE identifies itself with DHCP user-class "iPXE", so we
    hand iPXE (and only iPXE) an HTTP boot-script URL via a DHCP policy.

    This runs automatically only when the DHCP Server role is on THIS machine.
    If DHCP lives elsewhere, apply the printed settings on that server, OR
    rebuild iPXE with an embedded script (EMBED=boot.ipxe) that chains
    the boot script URL directly (no DHCP policy needed).
#>

$dhcpLocal = (Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue).Installed `
             -and (Get-Service DHCPServer -ErrorAction SilentlyContinue)

if ($SkipDhcpPolicy) {
    Write-Info 'Skipping DHCP policy (-SkipDhcpPolicy).'
    Write-Todo "Ensure iPXE clients receive boot filename: $BootScriptUrl"
}
elseif ($dhcpLocal) {
    Import-Module DhcpServer -ErrorAction Stop

    # User class matching iPXE's DHCP option 77 value ("iPXE").
    if (-not (Get-DhcpServerv4Class -Name 'iPXE' -Type User -ErrorAction SilentlyContinue)) {
        Add-DhcpServerv4Class -Name 'iPXE' -Type User -Data 'iPXE' `
            -Description 'iPXE clients (chainload loop break)'
        Write-Ok 'Created DHCP user class "iPXE".'
    } else { Write-Ok 'DHCP user class "iPXE" already present.' }

    # Server-level policy: iPXE clients get the HTTP boot script as their bootfile.
    if (-not (Get-DhcpServerv4Policy -Name 'iPXE-HTTP' -ErrorAction SilentlyContinue)) {
        Add-DhcpServerv4Policy -Name 'iPXE-HTTP' -Condition OR -UserClass EQ, 'iPXE' `
            -Description 'Serve HTTP iPXE boot script to iPXE clients'
        Write-Ok 'Created DHCP policy "iPXE-HTTP".'
    } else { Write-Ok 'DHCP policy "iPXE-HTTP" already present.' }

    # Option 67 (bootfile) = the full HTTP URL; iPXE chainloads it directly.
    Set-DhcpServerv4OptionValue -PolicyName 'iPXE-HTTP' -OptionId 67 -Value $BootScriptUrl
    Write-Ok "Policy option 67 -> $BootScriptUrl"
}
else {
    Write-Todo 'DHCP Server role is not on this machine. On your DHCP server:'
    Write-Todo '  1. Define a User Class named "iPXE" with ASCII data "iPXE".'
    Write-Todo '  2. Add a policy matching that user class.'
    Write-Todo "  3. Set option 067 (Bootfile Name) = $BootScriptUrl for that policy."
    Write-Todo 'Alternatively, rebuild iPXE with EMBED=boot.ipxe chaining that URL.'
}

# ============================================================
# 8 - FIREWALL
# ============================================================
Write-Step '8/8  Firewall rules'

$rules = @(
    @{ Name = 'NDT iPXE - TFTP (WDS)';     Port = 69;        Proto = 'UDP' },
    @{ Name = "NDT iPXE - HTTP $HttpPort"; Port = $HttpPort; Proto = 'TCP' }
)
foreach ($r in $rules) {
    if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
            -Protocol $r.Proto -LocalPort $r.Port | Out-Null
        Write-Ok "Opened $($r.Proto)/$($r.Port)."
    } else { Write-Ok "Firewall rule already present: $($r.Name)." }
}

# ============================================================
# SUMMARY
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " iPXE server configured" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Boot script URL : $BootScriptUrl"
Write-Host "  IIS root        : $SitePath  ($BaseUrl)"
Write-Host "  WDS boot progs  : x64uefi=Boot\x64\snponly.efi  bios=Boot\x86\ipxe.pxe"
Write-Host ""
Write-Host "  Verify:" -ForegroundColor DarkGray
Write-Host "    Invoke-WebRequest $BootScriptUrl -UseBasicParsing | Select -Expand Content" -ForegroundColor DarkGray
Write-Host "    wdsutil /Get-Server /Show:Config" -ForegroundColor DarkGray
Write-Host "    netstat -a -n -p udp | findstr :69" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Then PXE-boot a test client: firmware -> WDS -> iPXE -> WinPE menu." -ForegroundColor DarkGray
