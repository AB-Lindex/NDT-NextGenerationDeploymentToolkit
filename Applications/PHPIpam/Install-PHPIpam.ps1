#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Provisions a complete phpIPAM server - operating system and all - as a
    Hyper-V virtual machine, fully unattended.

.DESCRIPTION
    This is a self-contained PowerShell solution. It does NOT depend on the NDT
    deploy share or control files; it can be run standalone on any Hyper-V host.

    What it does:
      1. Downloads an Ubuntu Server cloud image (qcow2).
      2. Converts it to a dynamic VHDX (via qemu-img) and grows it to -DiskSizeGB.
      3. Builds a NoCloud "seed" VHDX (FAT32, label CIDATA) containing cloud-init
         user-data / meta-data (and network-config for a static IP) - pure
         PowerShell, no ISO tooling required.
      4. Creates a Generation 2 VM, attaches both disks, and boots it.
      5. cloud-init then installs Apache + PHP + MariaDB and deploys phpIPAM,
         creating the database, importing the schema and writing config.php.

    When the VM has finished first boot, browse to http://<fqdn>/ and log in with
    the phpIPAM defaults (admin / ipamadmin) - you are forced to change the
    password on first login.

    Ubuntu cloud images are signed for Secure Boot with the Microsoft UEFI CA, so
    Secure Boot is left ON using the MicrosoftUEFICertificateAuthority template.

.PARAMETER VMName
    Name of the Hyper-V virtual machine. Default: IPAM01.

.PARAMETER Hostname
    Linux hostname (short). Default: derived from VMName (lower-case).

.PARAMETER DomainName
    DNS domain used to build the FQDN. Default: corp.dev.

.PARAMETER SwitchName
    Hyper-V virtual switch to connect the VM to. Default: first external switch,
    otherwise the first switch found.

.PARAMETER Vlan
    Optional access VLAN ID (1-4094) to tag the VM's network adapter with.
    Omit or use 0 for untagged (the switch default).

.PARAMETER PfxPath
    Mandatory. Path to the PKCS#12 (.pfx) file containing the server certificate
    and private key for HTTPS. The PFX holds only the leaf certificate (no chain).

.PARAMETER PfxClearPWD
    Mandatory. Clear-text password used to import the -PfxPath file.

.PARAMETER ChainCertPath
    Optional PEM file with the issuing/intermediate CA certificate(s) used to
    complete the TLS chain (the PFX has no chain). Defaults to 'eca01.cer' next
    to this script. If absent, HTTPS serves the leaf certificate only.

.PARAMETER ServerName
    Optional Apache ServerName / TLS hostname. Defaults to the certificate's
    subject (CN/SAN), e.g. ipam.corp.dev. Browse to this name for a valid chain;
    the machine FQDN (e.g. ipam01.corp.dev) is added as a ServerAlias.

.PARAMETER MemoryGB
    Startup memory in GB. Default: 2.

.PARAMETER CpuCount
    Virtual processor count. Default: 2.

.PARAMETER DiskSizeGB
    Final OS disk size in GB (the cloud image is grown to this). Default: 20.

.PARAMETER IPAddress
    Optional static address in CIDR form, e.g. 10.0.3.40/24. Omit for DHCP.

.PARAMETER Gateway
    Default gateway - required when -IPAddress is supplied.

.PARAMETER DnsServers
    One or more DNS server IPs (used with -IPAddress). Default: 10.0.3.11.

.PARAMETER AdminUser
    Local Linux sudo account created by cloud-init. Default: ipamadmin.

.PARAMETER AdminClearPWD
    Clear-text password for -AdminUser (console/SSH login). Default: Qantas-777.

.PARAMETER DbRootClearPWD
    MariaDB root password to set. Default: Qantas-777.

.PARAMETER DbName
    phpIPAM database name. Default: phpipam.

.PARAMETER DbUser
    phpIPAM database user. Default: phpipam.

.PARAMETER DbClearPWD
    Clear-text password for the phpIPAM database user. Default: Qantas-777.

.PARAMETER PhpIpamVersion
    Git tag of phpIPAM to deploy. Default: v1.7.3.

.PARAMETER ImageUrl
    Ubuntu cloud image URL (qcow2). Default: Ubuntu 24.04 (Noble) amd64.

.PARAMETER QemuImgUrl
    URL of a qemu-img Windows build (zip) used when qemu-img is not on PATH.

.PARAMETER WorkPath
    Working directory for downloads and generated disks.
    Default: C:\HyperV\phpipam.

.PARAMETER WaitForIP
    Wait for the VM to report an IPv4 address and print the phpIPAM URL.

.EXAMPLE
    .\Install-PHPIpam.ps1 -PfxPath .\ipam.corp.dev.pfx -PfxClearPWD 1q2w3e4r -WaitForIP

    Provision IPAM01 on DHCP with HTTPS and wait for its address.

.EXAMPLE
    .\Install-PHPIpam.ps1 -VMName ipam -Hostname ipam `
        -PfxPath .\ipam.corp.dev.pfx -PfxClearPWD 1q2w3e4r `
        -IPAddress 10.0.3.40/24 -Gateway 10.0.3.1 -DnsServers 10.0.3.11 `
        -SwitchName 'External' -WaitForIP

    Provision with a static address. Use -Hostname/-VMName so the FQDN matches the
    certificate subject (e.g. ipam.corp.dev).
#>

[CmdletBinding()]
param(
    [string]$VMName = 'IPAM01',
    [string]$Hostname,
    [string]$DomainName = 'corp.dev',
    [string]$SwitchName,
    [ValidateRange(0, 4094)]
    [int]$Vlan = 0,
    [int]$MemoryGB = 2,
    [int]$CpuCount = 2,
    [int]$DiskSizeGB = 20,

    [string]$IPAddress,
    [string]$Gateway,
    [string[]]$DnsServers = @('10.0.3.11'),

    [string]$AdminUser = 'ipamadmin',
    [string]$AdminClearPWD = 'Qantas-777',

    [string]$DbRootClearPWD = 'Qantas-777',
    [string]$DbName = 'phpipam',
    [string]$DbUser = 'phpipam',
    [string]$DbClearPWD = 'Qantas-777',

    [string]$PhpIpamVersion = 'v1.7.3',

    [Parameter(Mandatory)]
    [string]$PfxPath,
    [Parameter(Mandatory)]
    [string]$PfxClearPWD,
    [string]$ChainCertPath = (Join-Path $PSScriptRoot 'eca01.cer'),
    [string]$ServerName,

    [string]$ImageUrl = 'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img',
    [string]$QemuImgUrl = 'https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip',

    [string]$WorkPath = 'C:\HyperV\phpipam',

    [switch]$WaitForIP
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    if (Test-Path $OutFile) {
        Write-Host "  Using cached $OutFile" -ForegroundColor DarkGray
        return
    }
    Write-Host "  Downloading $Uri" -ForegroundColor Yellow
    $tmp = "$OutFile.part"
    $oldPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # dramatically faster IWR downloads
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $tmp -UseBasicParsing
        Move-Item -Path $tmp -Destination $OutFile -Force
    }
    finally {
        $ProgressPreference = $oldPref
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Resolve-QemuImg {
    param([string]$Url, [string]$WorkDir)

    $cmd = Get-Command qemu-img.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $local = Join-Path $WorkDir 'qemu-img\qemu-img.exe'
    if (Test-Path $local) { return $local }

    Write-Host '  qemu-img not found on PATH - downloading a portable build' -ForegroundColor Yellow
    $zip = Join-Path $WorkDir 'qemu-img.zip'
    Get-RemoteFile -Uri $Url -OutFile $zip
    $dest = Join-Path $WorkDir 'qemu-img'
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $dest -Force

    $found = Get-ChildItem -Path $dest -Filter 'qemu-img.exe' -Recurse |
        Select-Object -First 1
    if (-not $found) {
        throw "qemu-img.exe was not found after extracting $Url. Install qemu-img manually and re-run, or add it to PATH."
    }
    return $found.FullName
}

function Set-Tokens {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][hashtable]$Tokens
    )
    $text = Get-Content -Path $TemplatePath -Raw
    foreach ($key in $Tokens.Keys) {
        $text = $text.Replace($key, [string]$Tokens[$key])
    }
    # cloud-init requires LF line endings.
    return ($text -replace "`r`n", "`n")
}

function New-SeedDisk {
    <#
        Builds a NoCloud cloud-init seed as a small FAT32 VHDX labelled CIDATA.
        Pure PowerShell - no oscdimg / mkisofs needed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Files   # filename -> content
    )

    if (Test-Path $Path) { Remove-Item $Path -Force }

    New-VHD -Path $Path -SizeBytes 64MB -Dynamic | Out-Null
    $mounted = Mount-VHD -Path $Path -Passthru
    try {
        $disk = $mounted | Get-Disk
        Initialize-Disk -Number $disk.Number -PartitionStyle MBR -Confirm:$false | Out-Null
        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        Format-Volume -DriveLetter $part.DriveLetter -FileSystem FAT32 `
            -NewFileSystemLabel 'CIDATA' -Confirm:$false | Out-Null

        $root = "$($part.DriveLetter):\"
        foreach ($name in $Files.Keys) {
            # Write raw bytes with explicit LF endings.
            $content = ($Files[$name] -replace "`r`n", "`n")
            [System.IO.File]::WriteAllText(
                (Join-Path $root $name), $content,
                (New-Object System.Text.UTF8Encoding($false)))
        }
    }
    finally {
        Dismount-VHD -Path $Path
    }
}

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------

Write-Step 'Checking prerequisites'

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'The Hyper-V PowerShell module is not available. Enable the Hyper-V role first.'
}
Import-Module Hyper-V -ErrorAction Stop

if ($IPAddress -and -not $Gateway) {
    throw '-Gateway is required when -IPAddress is specified.'
}

# Validate the TLS certificate up front (fail fast before any download).
if (-not (Test-Path $PfxPath)) { throw "PFX file not found: $PfxPath" }
$PfxPath = (Resolve-Path $PfxPath).Path
try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        $PfxPath, $PfxClearPWD)
    $certCn = $cert.GetNameInfo(
        [System.Security.Cryptography.X509Certificates.X509NameType]::DnsName, $false)
    $cert.Dispose()
}
catch {
    throw "Unable to open PFX '$PfxPath' with the supplied -PfxClearPWD: $($_.Exception.Message)"
}
if ($ServerName) { $certCn = $ServerName }
if ($ChainCertPath -and (Test-Path $ChainCertPath)) {
    $ChainCertPath = (Resolve-Path $ChainCertPath).Path
}
else {
    Write-Warning "Chain cert not found ($ChainCertPath) - HTTPS will serve the leaf certificate only (clients may report an incomplete chain)."
    $ChainCertPath = $null
}

if (-not $Hostname) { $Hostname = ($VMName.ToLower()) }
$fqdn = "$Hostname.$DomainName"

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "A VM named '$VMName' already exists. Remove it or choose another -VMName."
}

if (-not $SwitchName) {
    $sw = Get-VMSwitch | Where-Object SwitchType -eq 'External' | Select-Object -First 1
    if (-not $sw) { $sw = Get-VMSwitch | Select-Object -First 1 }
    if (-not $sw) { throw 'No Hyper-V virtual switch found. Create one and pass -SwitchName.' }
    $SwitchName = $sw.Name
}
Write-Host "  VM switch : $SwitchName" -ForegroundColor DarkGray
Write-Host "  FQDN      : $fqdn" -ForegroundColor DarkGray

$null = New-Item -ItemType Directory -Path $WorkPath -Force
$vmDir = Join-Path $WorkPath $VMName
$null = New-Item -ItemType Directory -Path $vmDir -Force

# ----------------------------------------------------------------------------
# 1. Download the cloud image
# ----------------------------------------------------------------------------

Write-Step 'Obtaining Ubuntu cloud image'
$imgFile = Join-Path $WorkPath ([System.IO.Path]::GetFileName($ImageUrl))
Get-RemoteFile -Uri $ImageUrl -OutFile $imgFile

# ----------------------------------------------------------------------------
# 2. Convert to VHDX and grow
# ----------------------------------------------------------------------------

Write-Step 'Converting cloud image to VHDX'
$qemuImg = Resolve-QemuImg -Url $QemuImgUrl -WorkDir $WorkPath
$osVhdx = Join-Path $vmDir "$VMName-os.vhdx"
if (Test-Path $osVhdx) { Remove-Item $osVhdx -Force }

Write-Host "  qemu-img: $qemuImg" -ForegroundColor DarkGray
& $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $imgFile $osVhdx
if ($LASTEXITCODE -ne 0) { throw "qemu-img convert failed (exit $LASTEXITCODE)." }

Write-Host "  Resizing OS disk to ${DiskSizeGB}GB" -ForegroundColor DarkGray
Resize-VHD -Path $osVhdx -SizeBytes ($DiskSizeGB * 1GB)

# ----------------------------------------------------------------------------
# 3. Build the cloud-init seed disk
# ----------------------------------------------------------------------------

Write-Step 'Building cloud-init seed disk'
$ciDir = Join-Path $PSScriptRoot 'cloud-init'

# TLS material for the seed: the PFX (base64) plus the optional chain (base64).
$pfxB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PfxPath))
if ($ChainCertPath) {
    $chainB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ChainCertPath))
    Write-Host "  TLS chain: $ChainCertPath" -ForegroundColor DarkGray
}
else {
    $chainB64 = 'Cg=='   # a single newline: yields an effectively empty chain file
}

$userData = Set-Tokens -TemplatePath (Join-Path $ciDir 'user-data.template') -Tokens @{
    '__HOSTNAME__'       = $Hostname
    '__FQDN__'           = $fqdn
    '__ADMINUSER__'      = $AdminUser
    '__ADMINPASSWORD__'  = $AdminClearPWD
    '__DBROOTPASS__'     = $DbRootClearPWD
    '__DBNAME__'         = $DbName
    '__DBUSER__'         = $DbUser
    '__DBPASS__'         = $DbClearPWD
    '__PHPIPAMVERSION__' = $PhpIpamVersion
    '__PFX_B64__'        = $pfxB64
    '__PFX_PASSWORD__'   = $PfxClearPWD
    '__CHAIN_B64__'      = $chainB64
    '__CERT_CN__'        = $(if ($certCn) { $certCn } else { $fqdn })
}

$metaData = Set-Tokens -TemplatePath (Join-Path $ciDir 'meta-data.template') -Tokens @{
    '__INSTANCEID__' = "iid-$VMName-$(Get-Date -Format yyyyMMddHHmmss)"
    '__HOSTNAME__'   = $Hostname
}

$seedFiles = @{
    'user-data' = $userData
    'meta-data' = $metaData
}

if ($IPAddress) {
    $dns = ($DnsServers -join ', ')
    $netCfg = Set-Tokens -TemplatePath (Join-Path $ciDir 'network-config.static.template') -Tokens @{
        '__ADDRESSCIDR__' = $IPAddress
        '__GATEWAY__'     = $Gateway
        '__DNSSERVERS__'  = $dns
    }
    $seedFiles['network-config'] = $netCfg
    Write-Host "  Static IP: $IPAddress via $Gateway (DNS: $dns)" -ForegroundColor DarkGray
}
else {
    Write-Host '  Network: DHCP' -ForegroundColor DarkGray
}

$seedVhdx = Join-Path $vmDir "$VMName-seed.vhdx"
New-SeedDisk -Path $seedVhdx -Files $seedFiles

# ----------------------------------------------------------------------------
# 4. Create and configure the VM
# ----------------------------------------------------------------------------

Write-Step "Creating VM '$VMName'"
$vm = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) `
    -SwitchName $SwitchName -Path $WorkPath
Set-VM -VM $vm -ProcessorCount $CpuCount -AutomaticStartAction Start -CheckpointType Disabled

# Attach OS disk then the seed disk.
Add-VMHardDiskDrive -VMName $VMName -Path $osVhdx
Add-VMHardDiskDrive -VMName $VMName -Path $seedVhdx

# Tag the network adapter with an access VLAN when requested.
if ($Vlan -gt 0) {
    Set-VMNetworkAdapterVlan -VMName $VMName -Access -VlanId $Vlan
    Write-Host "  VLAN: access $Vlan" -ForegroundColor DarkGray
}

# Secure Boot with the Microsoft third-party UEFI CA (required for Linux shim).
Set-VMFirmware -VMName $VMName -EnableSecureBoot On `
    -SecureBootTemplate 'MicrosoftUEFICertificateAuthority'

# Boot from the OS disk.
$osDrive = Get-VMHardDiskDrive -VMName $VMName |
    Where-Object Path -eq $osVhdx
Set-VMFirmware -VMName $VMName -FirstBootDevice $osDrive

Write-Step "Starting VM '$VMName'"
Start-VM -Name $VMName

# ----------------------------------------------------------------------------
# 5. Optionally wait for the VM to come online
# ----------------------------------------------------------------------------

if ($WaitForIP) {
    Write-Step 'Waiting for the VM to obtain an IPv4 address (up to 5 minutes)'
    $deadline = (Get-Date).AddMinutes(5)
    $ip = $null
    while ((Get-Date) -lt $deadline) {
        $addresses = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
        if ($addresses) { $ip = $addresses | Select-Object -First 1; break }
        Start-Sleep -Seconds 10
    }
    if ($ip) {
        Write-Host "`n  VM address: $ip" -ForegroundColor Green
    }
    else {
        Write-Warning 'No IPv4 address reported yet (Integration Services may still be starting).'
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host " phpIPAM VM '$VMName' has been created and started." -ForegroundColor Green
Write-Host ' cloud-init is installing Apache + PHP + MariaDB + phpIPAM (HTTPS).' -ForegroundColor Green
Write-Host ' This takes a few minutes on first boot.' -ForegroundColor Green
Write-Host ''
Write-Host " Web UI : https://$(if ($certCn) { $certCn } else { $fqdn })/   (matches the certificate; HTTP redirects to HTTPS)" -ForegroundColor Green
Write-Host " Login  : admin / $AdminClearPWD"                           -ForegroundColor Green
Write-Host " SSH    : $AdminUser@$fqdn  (password: $AdminClearPWD)"      -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
