# Load deployment credentials from settings.json
$settingsPath = "X:\Deploy\settings.json"

if (-not (Test-Path $settingsPath)) {
    Write-Error "Settings file not found: $settingsPath"
    Read-Host "Press Enter to exit"
    exit 1
}

$settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

# Map deployment share using credentials from settings
Write-Host "Mapping deployment share: $($settings.Share)" -ForegroundColor Cyan
net use Z: "$($settings.Share)" /user:"$($settings.Username)" "$($settings.Password)"

& "Z:\Scripts\Unattend2026\install.ps1"

read-host "press enter to reboot 1"

net use Z: /D /Y

read-host "press enter to reboot 2"
