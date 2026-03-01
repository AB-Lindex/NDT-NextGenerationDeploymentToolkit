<#
.SYNOPSIS
    Publishes the NDT module to the PowerShell Gallery (or another NuGet repository).

.DESCRIPTION
    Validates the module manifest, then calls Publish-Module to push the NDT
    PowerShell module to PSGallery.

    The NuGet API key (your PSGallery API key or PAT) must be supplied via
    -ApiKey. Treat it as a secret — never commit it to source control.

    Requires PowerShellGet 2.x or later:
        Install-Module PowerShellGet -Force -AllowClobber

.PARAMETER ApiKey
    NuGet API key for the target repository (your PSGallery API key).
    Obtain it from: https://www.powershellgallery.com/account/apikeys

.PARAMETER ModulePath
    Path to the NDT module folder (must contain ndt.psd1 and ndt.psm1).
    Default: install\NDT\ (next to this script).

.PARAMETER Repository
    Name of the registered PSRepository to publish to.
    Default: PSGallery

.PARAMETER WhatIf
    Show what would be published without actually publishing.

.EXAMPLE
    .\Publish-NDT.ps1 -ApiKey 'oy2a...<your key>...'

.EXAMPLE
    .\Publish-NDT.ps1 -ApiKey $env:PSGALLERY_APIKEY -WhatIf

.EXAMPLE
    # Publish to an internal feed registered as 'CorpFeed'
    .\Publish-NDT.ps1 -ApiKey '<feed-pat>' -Repository CorpFeed
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory, HelpMessage = 'PSGallery NuGet API key. Get it from https://www.powershellgallery.com/account/apikeys')]
    [string]$ApiKey,

    [Parameter()]
    [string]$ModulePath = (Join-Path $PSScriptRoot 'NDT'),

    [Parameter()]
    [string]$Repository = 'PSGallery'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Pre-flight ──────────────────────────────────────────────────────────────

Write-Host 'NDT — PSGallery publish script' -ForegroundColor Cyan
Write-Host '─────────────────────────────────────────────────────────────────'

# 1. Validate the module manifest.
$manifestPath = Join-Path $ModulePath 'ndt.psd1'
if (-not (Test-Path $manifestPath)) {
    throw "Module manifest not found: $manifestPath"
}

Write-Host "Validating manifest: $manifestPath"
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
Write-Host "  Module  : $($manifest.Name)"
Write-Host "  Version : $($manifest.Version)"
Write-Host "  GUID    : $($manifest.Guid)"

# 2. Verify the required PSGallery metadata is filled in.
$psd1 = Import-PowerShellDataFile -Path $manifestPath
$psData = $psd1.PrivateData.PSData
if ([string]::IsNullOrWhiteSpace($psData.ProjectUri)) {
    Write-Warning 'PrivateData.PSData.ProjectUri is empty — PSGallery strongly recommends a project URL.'
}

# 3. Ensure PowerShellGet is available (v2+ recommended; v3/PSResourceGet also works).
$psGet = Get-Module -ListAvailable -Name PowerShellGet |
            Sort-Object Version -Descending |
            Select-Object -First 1
if (-not $psGet) {
    throw 'PowerShellGet is not installed. Run: Install-Module PowerShellGet -Force -AllowClobber'
}
Write-Host "  PowerShellGet: $($psGet.Version)"

# 4. Verify the target repository is registered.
$repo = Get-PSRepository -Name $Repository -ErrorAction SilentlyContinue
if (-not $repo) {
    throw "Repository '$Repository' is not registered. Run: Register-PSRepository or use -Repository PSGallery."
}
if ($repo.InstallationPolicy -ne 'Trusted') {
    Write-Warning "Repository '$Repository' is not trusted. You may be prompted during install by consumers."
}
Write-Host "  Repository: $($repo.Name)  ($($repo.PublishLocation))"

Write-Host '─────────────────────────────────────────────────────────────────'

# ── Publish ─────────────────────────────────────────────────────────────────

if ($PSCmdlet.ShouldProcess("$($manifest.Name) v$($manifest.Version)", "Publish to $Repository")) {
    Write-Host "Publishing $($manifest.Name) v$($manifest.Version) to $Repository ..." -ForegroundColor Yellow

    Publish-Module `
        -Path        $ModulePath `
        -Repository  $Repository `
        -NuGetApiKey $ApiKey `
        -Verbose:($VerbosePreference -eq 'Continue')

    Write-Host ''
    Write-Host 'Published successfully!' -ForegroundColor Green
    Write-Host "  https://www.powershellgallery.com/packages/$($manifest.Name)/$($manifest.Version)"
} else {
    Write-Host ''
    Write-Host "WhatIf: would publish $($manifest.Name) v$($manifest.Version) to $Repository." -ForegroundColor DarkYellow
}
