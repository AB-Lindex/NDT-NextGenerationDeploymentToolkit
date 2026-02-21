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

# Check whether Install-NDT.ps1 scheduled a reboot during this run.
# A Reboot deployment step registers RunOnce\ContinueDeployment and calls shutdown.exe,
# then exits back here. If that key exists the machine is about to reboot - we must NOT
# clean up AutoLogon or RunOnce, because both need to survive the reboot so deployment
# can continue automatically on the next logon.
$pendingReboot = Get-ItemProperty -Path $runOnceKey -Name 'ContinueDeployment' -ErrorAction SilentlyContinue

if ($pendingReboot) {
    Add-Content -Path $LogPath -Value "Reboot pending (ContinueDeployment RunOnce found) - skipping cleanup at $(Get-Date)"
    Add-Content -Path $LogPath -Value "AutoLogon and RunOnce entries left intact for post-reboot continuation"
} else {
    # No reboot pending - deployment is complete. Remove RunOnce and AutoLogon.
    Remove-ItemProperty -Path $runOnceKey -Name $runOnceValue -ErrorAction SilentlyContinue
    Add-Content -Path $LogPath -Value "RunOnce removed - deployment complete at $(Get-Date)"

    # Remove the registry-based AutoLogon that was set during the specialize pass
    # (needed for both sysprepped and non-sysprepped deployment paths).
    $winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogonKey -Name AutoAdminLogon -Value '0' -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $winlogonKey -Name DefaultPassword -ErrorAction SilentlyContinue
    Add-Content -Path $LogPath -Value "AutoLogon disabled - deployment complete at $(Get-Date)"
}

