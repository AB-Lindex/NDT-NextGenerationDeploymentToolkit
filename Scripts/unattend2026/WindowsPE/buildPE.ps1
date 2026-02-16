# Build Windows PE deployment settings
# Extracts credentials from CustomSettings.json and creates settings.json for PE environment

$ErrorActionPreference = "Stop"

# Paths - use script directory as base
$scriptDir = $PSScriptRoot
$customSettingsPath = Join-Path $scriptDir "..\..\..\Control\CustomSettings.json"
$outputPath = Join-Path $scriptDir "Deploy\settings.json"

try {
    Write-Host "Building Windows PE deployment settings..." -ForegroundColor Cyan
    
    # Load CustomSettings.json
    if (-not (Test-Path $customSettingsPath)) {
        throw "CustomSettings.json not found at: $customSettingsPath"
    }
    
    $customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json
    
    # Extract Deploy settings
    if (-not $customSettings.Deploy) {
        throw "Deploy section not found in CustomSettings.json"
    }
    
    $deploySettings = $customSettings.Deploy
    
    # Create settings object
    $settings = @{
        Share = $deploySettings.Share
        Username = $deploySettings.Username
        Password = $deploySettings.Password
    }
    
    # Ensure Deploy directory exists
    $deployDir = Split-Path -Path $outputPath -Parent
    if (-not (Test-Path $deployDir)) {
        New-Item -Path $deployDir -ItemType Directory -Force | Out-Null
    }
    
    # Write settings.json
    $settings | ConvertTo-Json | Set-Content -Path $outputPath -Encoding UTF8
    
    Write-Host "Settings extracted successfully:" -ForegroundColor Green
    Write-Host "  Share: $($settings.Share)" -ForegroundColor Gray
    Write-Host "  Username: $($settings.Username)" -ForegroundColor Gray
    
    # Mask password - show first 3 characters
    $visibleChars = [Math]::Min(3, $settings.Password.Length)
    $maskedPassword = $settings.Password.Substring(0, $visibleChars) + ('*' * [Math]::Max(0, $settings.Password.Length - $visibleChars))
    Write-Host "  Password: $maskedPassword" -ForegroundColor Gray
    
    Write-Host "`nOutput: $outputPath" -ForegroundColor Green
    
} catch {
    Write-Error "Failed to build PE settings: $_"
    exit 1
}
