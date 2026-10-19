# Get OS WIM path based on MAC address configuration
param(
    [Parameter(Mandatory=$true)]
    [string]$MACAddress,

    [string]$ShareRoot = 'Z:\'
)

. (Join-Path $PSScriptRoot 'Get-NDTMachine.ps1')
$sectionsPath = Join-Path $ShareRoot 'Control\Sections.json'
$osJsonPath = Join-Path $ShareRoot 'Control\OS.json'

# Load JSON files (machine config = CustomSettings.json merged with Control\Projects)
try { $customSettings = Get-NDTMachine -ControlPath (Join-Path $ShareRoot 'Control') }
catch { Write-Error $_.Exception.Message; exit 1 }$sections = Get-Content -Path $sectionsPath -Raw | ConvertFrom-Json
$osConfig = Get-Content -Path $osJsonPath -Raw | ConvertFrom-Json

Write-Host "Using MAC Address: $MACAddress" -ForegroundColor Yellow

# Get machine configuration by MAC address
$machineConfig = $customSettings.$MACAddress
if (-not $machineConfig) {
    Write-Error "No configuration found for MAC address: $MACAddress"
    exit 1
}

# Get OS reference - check MAC block first, then fall back to referenced sections
$osName = $machineConfig.OS
if (-not $osName -and $machineConfig.Sections) {
    foreach ($sectionRef in $machineConfig.Sections.PSObject.Properties.Value) {
        $sectionData = $sections.$sectionRef
        if ($sectionData -and $sectionData.OS) {
            $osName = $sectionData.OS
            Write-Host "OS resolved from section '$sectionRef': $osName" -ForegroundColor Cyan
            break
        }
    }
}
if (-not $osName) {
    Write-Error "No OS specified in configuration for MAC address: $MACAddress"
    exit 1
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
