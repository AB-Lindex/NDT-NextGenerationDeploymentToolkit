# Copy and prepare install2026.ps1 with deployment share mapping

# Get Deploy settings
$customSettingsPath = "Z:\Control\CustomSettings.json"
$customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json
$deploySettings = $customSettings.Deploy

# Prepare install2026.ps1 with net use command prepended
New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null

if ($deploySettings) {
    $deployShare = $deploySettings.Share
    $deployUser = $deploySettings.Username
    $deployPassword = $deploySettings.Password
    
    Write-Host "Configuring deployment share mapping for first boot..." -ForegroundColor Cyan
    Write-Host "  Share: $deployShare" -ForegroundColor Gray
    
    # Read original install2026.ps1
    $originalScript = Get-Content -Path "Z:\Scripts\Unattend2026\install2026.ps1" -Raw
    
    # Prepend net use command
    $modifiedScript = @"
# Map deployment share
Write-Host "Mapping deployment share..." -ForegroundColor Cyan
net use Z: "$deployShare" /user:$deployUser "$deployPassword" /persistent:no

$originalScript
"@
    
    # Save modified script
    $modifiedScript | Set-Content -Path "C:\temp\install2026.ps1" -Encoding UTF8
    Write-Host "Deployment share mapping configured" -ForegroundColor Green
} else {
    # No deploy settings, just copy as-is
    Copy-Item "Z:\Scripts\Unattend2026\install2026.ps1" "C:\temp\install2026.ps1"
    Write-Host "Copied install2026.ps1 to C:\temp" -ForegroundColor Green
}
