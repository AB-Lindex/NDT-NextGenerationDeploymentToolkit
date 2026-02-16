$LogPath = "C:\temp\install2026.log"
Add-Content -Path $LogPath -Value "Date: $(Get-Date) Installing unattend2026"
add-content -Path $LogPath -Value "OS Version: $($PSVersionTable.OS)"
add-content -Path $LogPath -Value "PS Version: $($PSVersionTable.PSVersion)"
Add-Content -Path $LogPath -Value "Architecture: $($PSVersionTable.Platform)"
Add-Content -Path $LogPath -Value "Host: $($PSVersionTable.PSEdition)"

Add-Content -Path $LogPath -Value "User: $(whoami)"

$UAC = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Content -Path $LogPath -Value "UAC: $UAC"

# Map deployment share using credentials from settings.json
$settingsPath = "C:\temp\settings.json"
if (Test-Path $settingsPath) {
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
    Write-Host "Mapping deployment share..." -ForegroundColor Cyan
    Add-Content -Path $LogPath -Value "Mapping deployment share: $($settings.Share)"
    net use Z: "$($settings.Share)" /user:"$($settings.Username)" "$($settings.Password)" /persistent:no
} else {
    Write-Error "Settings file not found: $settingsPath"
    Add-Content -Path $LogPath -Value "ERROR: Settings file not found"
    exit 1
}

# Execute deployment steps
& "Z:\Scripts\unattend2026\Install-NDT.ps1"

# Unmount deployment share
Write-Host "Unmounting deployment share Z:..." -ForegroundColor Yellow
net use Z: /delete /yes
Add-Content -Path $LogPath -Value "Z: drive unmounted at $(Get-Date)"

