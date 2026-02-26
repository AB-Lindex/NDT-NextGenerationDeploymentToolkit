$LogPath    = 'C:\temp\install2026.log'
$winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$runOnceKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$runOnceValue = 'Deploy2026'
$runOnceCmd   = 'powershell.exe -executionpolicy bypass -File c:\temp\install2026.ps1'

Add-Content -Path $LogPath -Value "$(Get-Date) install2026.ps1 started | PS=$($PSVersionTable.PSVersion) | User=$(whoami)"

# Re-register RunOnce so deployment survives any reboot. Removed on completion.
Set-ItemProperty -Path $runOnceKey -Name $runOnceValue -Value $runOnceCmd -Force
Add-Content -Path $LogPath -Value 'RunOnce\Deploy2026 registered'

# Map deployment share
$settingsPath = 'C:\temp\settings.json'
if (-not (Test-Path $settingsPath)) {
    Add-Content -Path $LogPath -Value 'ERROR: settings.json not found'
    exit 1
}
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
Add-Content -Path $LogPath -Value "Mapping share: $($settings.Deploy.Share)"
net use Z: "$($settings.Deploy.Share)" /user:"$($settings.Deploy.Username)" "$($settings.Deploy.Password)" /persistent:no

# Run deployment steps via pwsh.exe (PowerShell 7) as a child process.
# Using a child process instead of & means exit inside Install-NDT.ps1 terminates
# only that child process; $LASTEXITCODE in this script reflects the exit code.
# Exit codes:
#   0    - all steps completed, no reboot required
#   3010 - reboot required; AutoLogon registry already written by Install-NDT.ps1
pwsh.exe -ExecutionPolicy Bypass -File 'Z:\Scripts\unattend2026\Install-NDT.ps1'

if ($LASTEXITCODE -eq 3010) {
    Add-Content -Path $LogPath -Value "Reboot pending at $(Get-Date) - skipping cleanup"
    net use Z: /delete /yes
    exit 0
}

# Only reached when ALL deployment steps complete with no reboot.
net use Z: /delete /yes
Add-Content -Path $LogPath -Value "Z: unmounted at $(Get-Date)"

# Deployment complete - remove RunOnce and disable AutoLogon
Remove-ItemProperty -Path $runOnceKey  -Name $runOnceValue       -ErrorAction SilentlyContinue
Set-ItemProperty   -Path $winlogonKey -Name AutoAdminLogon -Value '0' -Type String -Force
Remove-ItemProperty -Path $winlogonKey -Name DefaultPassword     -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $winlogonKey -Name DefaultDomainName   -ErrorAction SilentlyContinue
Add-Content -Path $LogPath -Value "Deployment complete - cleanup done at $(Get-Date)"

