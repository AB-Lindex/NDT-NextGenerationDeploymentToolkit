#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Installs a private PowerShell Gallery (NuGet.Server on IIS).

.DESCRIPTION
    Deploys a self-hosted NuGet feed on IIS that acts as a private PS repository.

    SECTIONS
    --------
    1. IIS Windows features
    2. NuGet.Server web application
    3. File-system permissions
    4. IIS application pool and website
    5. Firewall rule and PSRepository registration

    PRE-STAGE (recommended for offline deployments)
    -----------------------------------------------
    Place nuget.exe alongside this script in the deploy share:
        nuget.exe   – https://dist.nuget.org/win-x86-commandline/latest/nuget.exe

    nuget.exe is always used to install NuGet.Server (it resolves all dependency
    DLLs automatically). The packages are downloaded from nuget.org at run time;
    for fully offline use, configure a local NuGet feed as the nuget.exe source.

    PUBLISH A MODULE AFTER INSTALLATION
    ------------------------------------
        Register-PSRepository -Name PSGallery2026 -SourceLocation https://<server>/nuget `
            -PublishLocation https://<server>/nuget -InstallationPolicy Trusted
        Publish-Module -Name <YourModule> -Repository PSGallery2026 -NuGetApiKey 'any-string'
#>

# ── Configuration ─────────────────────────────────────────────────────────────

$SiteName     = 'PSGallery2026'
$SitePath     = 'C:\inetpub\PSGallery2026'
$PackagesPath = "$SitePath\Packages"
$AppPool      = 'PSGallery2026'
$Hostname     = [System.Net.Dns]::GetHostEntry('').HostName   # FQDN used for HTTPS binding header

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 – IIS WINDOWS FEATURES
# NuGet.Server is an ASP.NET 4.x application; only needed sub-features installed.
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "`n[1/5] Installing IIS Windows features..." -ForegroundColor Cyan

$features = @(
    # IIS core
    'Web-Server',

    # Content serving
    'Web-Default-Doc',      # Default document (Default.aspx)
    'Web-Static-Content',   # Static files (Packages download)
    'Web-Http-Errors',      # Friendly HTTP error pages

    # ASP.NET / ISAPI — required for NuGet.Server (ASP.NET 4.x)
    'Web-Net-Ext45',        # .NET Extensibility 4.5
    'Web-Asp-Net45',        # ASP.NET 4.5
    'Web-ISAPI-Ext',        # ISAPI Extensions
    'Web-ISAPI-Filter',     # ISAPI Filters

    # Diagnostics (helpful for troubleshooting)
    'Web-Http-Logging',     # Request logging
    'Web-Request-Monitor',  # Real-time request visibility
    'Web-Filtering',        # Request Filtering (security baseline)

    # Management
    'Web-Mgmt-Console',     # IIS Manager GUI
    'Web-Scripting-Tools',  # WebAdministration PS module

    # .NET Framework activation
    'NET-Framework-45-Core',
    'NET-Framework-45-ASPNET',
    'NET-WCF-HTTP-Activation45'
)

$result = Install-WindowsFeature -Name $features
if ($result.RestartNeeded -eq 'Yes') {
    Write-Warning 'A restart is required after feature installation.'
    exit 3010
}
Write-Host '  IIS features installed.' -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 – NUGET.SERVER WEB APPLICATION
# Always uses 'nuget install' so all dependency DLLs are resolved.
# Pre-stage nuget.exe in $PSScriptRoot for offline deployments;
# the packages themselves are always fetched from nuget.org.
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "`n[2/5] Deploying NuGet.Server..." -ForegroundColor Cyan

$tempDir = "$env:TEMP\PSGalleryDeploy_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir | Out-Null

try {
    # ── Locate or download nuget.exe ─────────────────────────────────────────
    $nugetExe = Join-Path $PSScriptRoot 'nuget.exe'
    if (-not (Test-Path $nugetExe)) {
        $nugetExe = "$tempDir\nuget.exe"
        Write-Host '  Downloading nuget.exe...' -ForegroundColor Yellow
        Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' `
            -OutFile $nugetExe -UseBasicParsing
    }

    # ── Install NuGet.Server and all its dependencies ─────────────────────────
    Write-Host '  Running nuget install NuGet.Server...' -ForegroundColor Yellow
    & $nugetExe install NuGet.Server `
        -OutputDirectory $tempDir `
        -ExcludeVersion `
        -NonInteractive `
        -NoHttpCache 2>&1 | Write-Host

    $webSource = "$tempDir\NuGet.Server\Content"
    if (-not (Test-Path $webSource)) {
        throw "NuGet.Server content not found at expected path: $webSource"
    }

    # ── Copy web app content to site path ────────────────────────────────────
    if (-not (Test-Path $SitePath)) {
        New-Item -ItemType Directory -Path $SitePath | Out-Null
    }
    Copy-Item -Path "$webSource\*" -Destination $SitePath -Recurse -Force
    Write-Host '  Web application content deployed.' -ForegroundColor Green

    # ── Collect all dependency DLLs into bin\ ────────────────────────────────
    # 'nuget install' places each package's DLLs under <pkg>\lib\net4*\.
    # Without this step the ASP.NET app fails to load and IIS returns 404.
    $binPath = "$SitePath\bin"
    if (-not (Test-Path $binPath)) { New-Item -ItemType Directory -Path $binPath | Out-Null }
    $dllCount = 0
    Get-ChildItem -Path $tempDir -Filter '*.dll' -Recurse |
        Where-Object { $_.FullName -match '\\lib\\net' -and $_.FullName -notmatch '\\Content\\' } |
        ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $binPath -Force
            $dllCount++
        }
    Write-Host "  Copied $dllCount dependency DLL(s) to bin\." -ForegroundColor Green

    # ── Ensure Packages folder exists ────────────────────────────────────────
    if (-not (Test-Path $PackagesPath)) {
        New-Item -ItemType Directory -Path $PackagesPath | Out-Null
    }

} finally {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 – FILE-SYSTEM PERMISSIONS
# The app pool must exist before its virtual account can be resolved by icacls.
# Create it here; Section 4 will configure its properties idempotently.
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "`n[3/5] Setting file-system permissions..." -ForegroundColor Cyan
Import-Module WebAdministration -ErrorAction Stop

if (-not (Get-WebConfiguration -Filter "system.applicationHost/applicationPools/add[@name='$AppPool']")) {
    New-WebAppPool -Name $AppPool | Out-Null
    Write-Host "  Created application pool: $AppPool" -ForegroundColor DarkGray
}

foreach ($folder in @($SitePath, $PackagesPath)) {
    # /grant:r replaces any existing ACE for this account instead of adding a duplicate
    icacls $folder /grant:r ("IIS AppPool\${AppPool}:(OI)(CI)M") /T /Q
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed for '$folder' (exit $LASTEXITCODE)."
    }
}
Write-Host '  Permissions set.' -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 – IIS APPLICATION POOL AND WEBSITE
# Application pool runs under .NET v4.0 Integrated pipeline.
# HTTPS/443 only — certificate *.corp.dev must exist in LocalMachine\My.
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "`n[4/5] Configuring IIS..." -ForegroundColor Cyan

# ── Locate *.corp.dev certificate ───────────────────────────────────────────
$cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' |
    Where-Object { $_.Subject -match '\*\.corp\.dev' -and $_.HasPrivateKey } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

if (-not $cert) {
    throw "Certificate '*.corp.dev' with private key not found in Cert:\LocalMachine\My."
}
Write-Host "  Using certificate: $($cert.Subject) [$($cert.Thumbprint)]" -ForegroundColor DarkGray

# ── Application pool (idempotent — may already exist from Section 3) ─────────
if (-not (Get-WebConfiguration -Filter "system.applicationHost/applicationPools/add[@name='$AppPool']")) {
    New-WebAppPool -Name $AppPool | Out-Null
    Write-Host "  Created application pool: $AppPool" -ForegroundColor DarkGray
}
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name managedRuntimeVersion     -Value 'v4.0'
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name managedPipelineMode       -Value 'Integrated'
Set-ItemProperty "IIS:\AppPools\$AppPool" -Name processModel.identityType -Value 4  # ApplicationPoolIdentity

# ── Website (HTTPS/443 only, no HTTP binding) ────────────────────────────────
if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) {
    # Remove any existing bindings and rebuild
    Get-WebBinding -Name $SiteName | Remove-WebBinding
    Write-Host "  Removed existing bindings on: $SiteName" -ForegroundColor DarkGray
} else {
    # Create site without a default binding; binding is added explicitly below
    New-Website -Name $SiteName `
        -PhysicalPath    $SitePath `
        -ApplicationPool $AppPool `
        -Force | Out-Null
    # Remove the default HTTP:80 binding that New-Website adds automatically
    Get-WebBinding -Name $SiteName | Remove-WebBinding
    Write-Host "  Created website: $SiteName" -ForegroundColor DarkGray
}

Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath    -Value $SitePath
Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $AppPool

# Add HTTPS/443 binding
New-WebBinding -Name $SiteName -Protocol https -Port 443 -HostHeader $Hostname -SslFlags 1

# Remove any existing SNI SSL entry for this hostname before (re-)binding the cert.
# Remove-WebBinding clears the IIS binding but leaves the central SSL store entry,
# which causes AddSslCertificate to fail with 'element already exists' on re-run.
$sslPath = "IIS:\SslBindings\!443!$Hostname"
if (Test-Path $sslPath) {
    Remove-Item $sslPath -Force
}

# Bind the certificate to the SNI slot (SslFlags=1)
$binding = Get-WebBinding -Name $SiteName -Protocol https
$binding.AddSslCertificate($cert.Thumbprint, 'My')

Start-Website -Name $SiteName -ErrorAction SilentlyContinue
Write-Host '  IIS configured (HTTPS/443).' -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 – FIREWALL RULE AND PSREPOSITORY REGISTRATION
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "`n[5/5] Firewall rule and PSRepository..." -ForegroundColor Cyan

$fwName = 'PSGallery2026-HTTPS-443'
if (-not (Get-NetFirewallRule -DisplayName $fwName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $fwName `
        -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow | Out-Null
    Write-Host '  Firewall rule created for port 443.' -ForegroundColor DarkGray
}

# Ensure NuGet package provider is present — Register-PSRepository throws
# "invalid Web Uri" if it is missing, before even attempting a connection.
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
    Write-Host '  NuGet package provider installed.' -ForegroundColor DarkGray
}

$feedUrl = "https://$Hostname/nuget"

# Probe the feed URL before registering — Register-PSRepository gives a
# confusing "invalid Web Uri" error when the URL returns anything other
# than a valid NuGet v2 OData response.
try {
    $probe = Invoke-WebRequest -Uri $feedUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Write-Host "  Feed reachable (HTTP $($probe.StatusCode))." -ForegroundColor DarkGray
} catch {
    throw "Feed URL '$feedUrl' is not reachable: $_`nVerify IIS is running and the NuGet.Server app is responding."
}
if (Get-PSRepository -Name $SiteName -ErrorAction SilentlyContinue) {
    Set-PSRepository -Name $SiteName `
        -SourceLocation    $feedUrl `
        -PublishLocation   $feedUrl `
        -InstallationPolicy Trusted
} else {
    Register-PSRepository -Name $SiteName `
        -SourceLocation             $feedUrl `
        -PublishLocation            $feedUrl `
        -PackageManagementProvider  NuGet `
        -InstallationPolicy         Trusted
}
Write-Host "  PSRepository registered: $feedUrl" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────

Write-Host "`nPSGallery ready." -ForegroundColor Green
Write-Host "  Feed URL        : $feedUrl" -ForegroundColor Green
Write-Host "  Packages folder : $PackagesPath" -ForegroundColor Green
Write-Host "  Publish module  : Publish-Module -Name <module> -Repository $SiteName -NuGetApiKey 'any'" -ForegroundColor DarkGray
Write-Host "  Install module  : Install-Module  -Name <module> -Repository $SiteName" -ForegroundColor DarkGray
