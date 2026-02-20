$LogPath = "C:\temp\install2026.log"
Add-Content -Path $LogPath -Value "Date: $(Get-Date) Installing unattend2026"
add-content -Path $LogPath -Value "OS Version: $(if ($PSVersionTable.OS) { $PSVersionTable.OS } else { [System.Environment]::OSVersion.VersionString })"
add-content -Path $LogPath -Value "PS Version: $($PSVersionTable.PSVersion)"
Add-Content -Path $LogPath -Value "Architecture: $(if ($PSVersionTable.Platform) { $PSVersionTable.Platform } else { [System.Environment]::Is64BitOperatingSystem | ForEach-Object { if ($_) {'Win64'} else {'Win32'} } })"
Add-Content -Path $LogPath -Value "Host: $($PSVersionTable.PSEdition)"

# Re-launch with PS7 if available and not already running under it
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) {
        Add-Content -Path $LogPath -Value "PS7 found at $($pwsh.Source) - re-launching script under pwsh.exe"
        & $pwsh.Source -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
    Add-Content -Path $LogPath -Value "PS7 not found - continuing under powershell.exe $($PSVersionTable.PSVersion)"
}

Add-Content -Path $LogPath -Value "User: $(whoami)"

$UAC = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Content -Path $LogPath -Value "UAC: $UAC"

# Register RunOnce so the script automatically resumes after any reboot during deployment.
# Removed at the end of this script on successful completion.
$runOnceKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$runOnceValue = 'Deploy2026'
$runOnceCmd = 'powershell.exe -executionpolicy bypass -File c:\temp\install2026.ps1'
Set-ItemProperty -Path $runOnceKey -Name $runOnceValue -Value $runOnceCmd -Force
Add-Content -Path $LogPath -Value "RunOnce registered: $runOnceCmd"

# Map deployment share using credentials from settings.json
$settingsPath = "C:\temp\settings.json"
if (Test-Path $settingsPath) {
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
    Write-Host "Mapping deployment share..." -ForegroundColor Cyan
    Add-Content -Path $LogPath -Value "Mapping deployment share: $($settings.Deploy.Share)"
    net use Z: "$($settings.Deploy.Share)" /user:"$($settings.Deploy.Username)" "$($settings.Deploy.Password)" /persistent:no
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

# Deployment complete - remove RunOnce so the script does not run again on next boot
Remove-ItemProperty -Path $runOnceKey -Name $runOnceValue -ErrorAction SilentlyContinue
Add-Content -Path $LogPath -Value "RunOnce removed - deployment complete at $(Get-Date)"

