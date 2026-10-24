# Get OS WIM path based on MAC address configuration
param(
    [Parameter(Mandatory=$true)]
    [string]$MACAddress,

    [string]$ShareRoot = 'Z:\'
)

try { . (Join-Path $PSScriptRoot 'Import-NDTModule.ps1') }
catch { Write-Error $_.Exception.Message; exit 1 }
$sectionsPath = Join-Path $ShareRoot 'Control\Sections.json'
$osJsonPath = Join-Path $ShareRoot 'Control\OS.json'

# Load JSON files (machine config = CustomSettings.json merged with Control\Projects)
try { $customSettings = Get-NDTMachine -LocalPath $ShareRoot }
catch { Write-Error $_.Exception.Message; exit 1 }
$sections = Get-Content -Path $sectionsPath -Raw | ConvertFrom-Json
$osConfig = Get-Content -Path $osJsonPath -Raw | ConvertFrom-Json

Write-Host "Using MAC Address: $MACAddress" -ForegroundColor Yellow

# Get machine configuration by MAC address
$machineConfig = $customSettings.$MACAddress
if (-not $machineConfig) {
    Write-Error "No configuration found for MAC address: $MACAddress"
    exit 1
}

# OS comes from the MAC block first, then from the first referenced section that sets one
$osResolved = Resolve-NDTMachineOS -Machine $machineConfig -SectionCatalog $sections
if (-not $osResolved) {
    Write-Error "No OS specified in configuration for MAC address: $MACAddress"
    exit 1
}
$osName = $osResolved.OsKey
if ($osResolved.Source -ne 'machine') {
    Write-Host "OS resolved from $($osResolved.Source): $osName" -ForegroundColor Cyan
}

Write-Host "OS Reference: $osName" -ForegroundColor Cyan

# Get OS path from OS.json
$osInfo = $osConfig.$osName
if (-not $osInfo) {
    Write-Error "No OS configuration found for: $osName"
    exit 1
}

$wimPath = $osInfo.Path
if (-not $wimPath) {
    Write-Error "No path specified for OS: $osName"
    exit 1
}

# Get index from OS config, default to 1 if not specified
$wimIndex = if ($osInfo.Index) { $osInfo.Index } else { 1 }

# Build full path under the share root (default Z:\)
$fullPath = Join-Path $ShareRoot $wimPath

Write-Host "WIM Path: $fullPath" -ForegroundColor Green
Write-Host "WIM Index: $wimIndex" -ForegroundColor Green

# Return path, index, and resolved OS key as object
return [PSCustomObject]@{
    OsKey = $osName
    Path  = $fullPath
    Index = $wimIndex
}
