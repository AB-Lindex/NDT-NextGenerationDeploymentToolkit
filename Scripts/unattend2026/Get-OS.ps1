# Get OS WIM path based on MAC address configuration
param(
    [Parameter(Mandatory=$true)]
    [string]$MACAddress
)

$customSettingsPath = "Z:\Control\CustomSettings.json"
$osJsonPath = "Z:\Control\OS.json"

# Load JSON files
$customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json
$osConfig = Get-Content -Path $osJsonPath -Raw | ConvertFrom-Json

Write-Host "Using MAC Address: $MACAddress" -ForegroundColor Yellow

# Get machine configuration by MAC address
$machineConfig = $customSettings.$MACAddress
if (-not $machineConfig) {
    Write-Error "No configuration found for MAC address: $MACAddress"
    exit 1
}

# Get OS reference
$osName = $machineConfig.OS
if (-not $osName) {
    Write-Error "No OS specified in configuration for MAC address: $macAddress"
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

# Build full path with Z:\
$fullPath = "Z:\$wimPath"

Write-Host "WIM Path: $fullPath" -ForegroundColor Green

# Return the path
return $fullPath
