# Copy and prepare install2026.ps1 with deployment credentials in separate settings file

# Get MAC address
$macAddress = & "Z:\Scripts\unattend2026\Get-MACAddress.ps1"

# Get Deploy settings
$customSettingsPath = "Z:\Control\CustomSettings.json"
$customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json
$deploySettings = $customSettings.Deploy

# Get machine configuration by MAC address for AutoLogon password
$machineConfig = $customSettings.$macAddress
if (-not $machineConfig) {
    Write-Error "No configuration found for MAC address: $macAddress"
    exit 1
}

# Ensure C:\temp exists
New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null

if ($deploySettings) {
    Write-Host "Configuring deployment share mapping for first boot..." -ForegroundColor Cyan
    Write-Host "  Share: $($deploySettings.Share)" -ForegroundColor Gray
    
    # Create settings.json with deployment credentials and autologon settings
    $settings = @{
        Deploy = @{
            Share = $deploySettings.Share
            Username = $deploySettings.Username
            Password = $deploySettings.Password
        }
        AutoLogon = @{
            Domain = "."
            Username = "Administrator"
            Password = $machineConfig.AdminPassword
        }
    }
    
    $settings | ConvertTo-Json -Depth 3 | Set-Content -Path "C:\temp\settings.json" -Encoding UTF8
    Write-Host "Created settings.json with deployment and autologon credentials" -ForegroundColor Green
    
    # Mask password - show first 3 characters
    $visibleChars = [Math]::Min(3, $settings.Deploy.Password.Length)
    $maskedPassword = $settings.Deploy.Password.Substring(0, $visibleChars) + ('*' * [Math]::Max(0, $settings.Deploy.Password.Length - $visibleChars))
    Write-Host "  Password: $maskedPassword" -ForegroundColor Gray
} else {
    Write-Warning "No deployment settings found in CustomSettings.json"
}

# Copy install2026.ps1 as-is (it will read settings.json)
Copy-Item "Z:\Scripts\Unattend2026\install2026.ps1" "C:\temp\install2026.ps1"
Write-Host "Copied install2026.ps1 to C:\temp" -ForegroundColor Green
