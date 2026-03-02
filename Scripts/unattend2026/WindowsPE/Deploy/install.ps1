# Load deployment credentials from settings.json
$settingsPath = "X:\Deploy\settings.json"

if (-not (Test-Path $settingsPath)) {
    Write-Error "Settings file not found: $settingsPath"
    Read-Host "Press Enter to exit"
    exit 1
}

$settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

# Map deployment share using credentials from settings - retry loop
Write-Host "Mapping deployment share: $($settings.Share)" -ForegroundColor Cyan
$mapped = $false
while (-not $mapped) {
    net use Z: "$($settings.Share)" /user:"$($settings.Username)" "$($settings.Password)"
    if ($LASTEXITCODE -eq 0) {
        $mapped = $true
    } else {
        Write-Host ""
        Write-Host "ERROR: Failed to map Z: to $($settings.Share) (exit code $LASTEXITCODE)" -ForegroundColor Red
        Write-Host "Common causes:" -ForegroundColor Yellow
        Write-Host "  - Network not ready yet (wpeinit/DHCP still starting)" -ForegroundColor Yellow
        Write-Host "  - Wrong share path, username or password in settings.json" -ForegroundColor Yellow
        Write-Host "  - Server $($settings.Share) is unreachable from this network" -ForegroundColor Yellow
        Write-Host "  - The deploy share SMB service is down" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "settings.json values in use:" -ForegroundColor Cyan
        Write-Host "  Share   : $($settings.Share)" -ForegroundColor Cyan
        Write-Host "  Username: $($settings.Username)" -ForegroundColor Cyan
        Write-Host ""
        $choice = Read-Host "Press R to retry, or X to exit to debug shell"
        if ($choice -match '^[Xx]') {
            Write-Host "Exiting. Type 'exit' in this window when done." -ForegroundColor Yellow
            exit 1
        }
        # Clean up any partial mapping before retrying
        net use Z: /D /Y 2>&1 | Out-Null
    }
}

& "Z:\Scripts\Unattend2026\install.ps1"

# read-host "press enter to continue with unmapping deployment share..."

net use Z: /D /Y
