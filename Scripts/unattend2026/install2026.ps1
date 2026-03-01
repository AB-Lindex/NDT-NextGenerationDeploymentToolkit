Param(
    # Pass -Resume when manually continuing after a Pause step (i.e. via the
    # desktop shortcut).  Without this switch the script exits immediately if
    # a pause.flag is present, preventing the spurious double-invocation that
    # the Windows shell causes after any RunOnce-triggered session.
    [switch]$Resume
)

$LogPath    = 'C:\temp\install2026.log'
$winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$runOnceKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$runOnceValue = 'Deploy2026'
$runOnceCmd   = 'powershell.exe -executionpolicy bypass -File c:\temp\install2026.ps1'
$deployCompleteFlagPath = 'C:\temp\deploy-complete.flag'
$pauseFlagPath           = 'C:\temp\pause.flag'

function Write-Log {
    param(
        [string]$Message,
        [string]$ForegroundColor = 'White',
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogPath -Value "$ts [$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message -ForegroundColor $ForegroundColor }
    }
}

try { $sysIP = (Get-NetIPAddress -AddressFamily IPv4 -Type Unicast | Where-Object { $_.InterfaceAlias -notmatch 'Loopback|Tunnel' } | Select-Object -First 1 -ExpandProperty IPAddress) } catch { $sysIP = 'unknown' }
Write-Log "install2026.ps1 started" -ForegroundColor Cyan
Write-Log "-----------------------------------" -ForegroundColor Cyan
Write-Log "Hostname : $env:COMPUTERNAME"
Write-Log "User     : $(whoami)"
Write-Log "Domain   : $env:USERDOMAIN"
Write-Log "PS Ver   : $($PSVersionTable.PSVersion)"
Write-Log "IP       : $sysIP"
Write-Log "-----------------------------------" -ForegroundColor Cyan

# Guard against double-invocation. For sysprepped images both the specialize-pass
# RunOnce entry AND the oobeSystem FirstLogonCommands fire on the same logon session.
# The shell captures RunOnce values at session start, so even though install2026.ps1
# deletes the RunOnce key when it finishes, the shell fires it again ~4 seconds later.
# Writing a sentinel file on successful completion and exiting immediately when it is
# present prevents that spurious second run.
if (Test-Path $deployCompleteFlagPath) {
    Write-Log 'Deployment already completed (deploy-complete.flag present) - exiting' -ForegroundColor Yellow
    exit 0
}

# Guard against the spurious re-invocation that occurs after a Pause step.
# When Install-NDT.ps1 exits with 3011 the Windows shell can fire install2026.ps1
# a second time in the same logon session (same double-invocation problem as the
# deploy-complete.flag scenario above).  Writing pause.flag on 3011 and checking
# it here lets that second call exit before it re-registers RunOnce or removes
# the desktop shortcut.
# -Resume clears the flag and falls through so the operator's manual click works.
if (Test-Path $pauseFlagPath) {
    if ($Resume) {
        Remove-Item $pauseFlagPath -Force -ErrorAction SilentlyContinue
        Write-Log 'Resuming deployment after Pause (pause.flag removed)' -ForegroundColor Cyan
    } else {
        Write-Log 'Deployment is paused (pause.flag present) - exiting. Use the desktop shortcut to resume.' -ForegroundColor Yellow
        exit 0
    }
}

# Check for pending reboot flag. This flag is written when a deployment reboot is
# initiated. We compare its timestamp against the OS last boot time to distinguish
# between two scenarios:
#   Flag newer than last boot  = still in reboot countdown (re-logon loop) -> exit immediately
#   Flag older than last boot  = machine has actually rebooted -> delete flag and continue
$rebootFlagPath = 'C:\temp\reboot.flag'
if (Test-Path $rebootFlagPath) {
    $flagTime = (Get-Item $rebootFlagPath).LastWriteTime
    $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if ($flagTime -gt $bootTime) {
        Write-Log "Reboot flag is newer than last boot ($bootTime) - reboot countdown in progress, exiting cleanly" -ForegroundColor Yellow
        exit 0
    } else {
        Write-Log "Reboot flag is older than last boot ($bootTime) - reboot completed, continuing deployment" -ForegroundColor Cyan
        Remove-Item $rebootFlagPath -Force
    }
}

# Re-register RunOnce so deployment survives any reboot. Removed on completion.
Set-ItemProperty -Path $runOnceKey -Name $runOnceValue -Value $runOnceCmd -Force
Write-Log 'RunOnce\Deploy2026 registered'

# If we're resuming from a Pause, the shortcut on the Public Desktop is no longer needed.
$pauseShortcut = 'C:\Users\Public\Desktop\Continue Deployment.lnk'
if (Test-Path $pauseShortcut) {
    Remove-Item $pauseShortcut -Force -ErrorAction SilentlyContinue
    Write-Log 'Removed "Continue Deployment" shortcut from Public Desktop'
}

# Map deployment share
$settingsPath = 'C:\temp\settings.json'
if (-not (Test-Path $settingsPath)) {
    Write-Log 'ERROR: settings.json not found' -Level ERROR
    exit 1
}
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
Write-Log "Mapping share: $($settings.Deploy.Share)"
net use Z: "$($settings.Deploy.Share)" /user:"$($settings.Deploy.Username)" "$($settings.Deploy.Password)" /persistent:no

# Ensure PowerShell 7 is installed before invoking Install-NDT.ps1 with pwsh.exe.
# install2026.ps1 itself runs under powershell.exe (PS5 via RunOnce), so we use
# powershell.exe to run the installer if pwsh.exe is not yet present.
# NOTE: Get-Command is not used here because the PS5 process $PATH is frozen at
# launch and will not reflect the PS7 installer's PATH changes. We probe the known
# install path directly instead.
$pwshExe = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
if (-not (Test-Path $pwshExe)) {
    Write-Log "PowerShell 7 not found - installing at $(Get-Date)"
    powershell.exe -ExecutionPolicy Bypass -File 'Z:\Applications\PowerShell7\Install.ps1'
    Write-Log "PowerShell 7 install exited with code $LASTEXITCODE at $(Get-Date)"
    if (-not (Test-Path $pwshExe)) {
        Write-Log 'pwsh.exe still not found after install - aborting' -Level ERROR
        net use Z: /delete /yes
        exit 1
    }
    Write-Log 'PowerShell 7 installed successfully' -ForegroundColor Green
} else {
    Write-Log 'PowerShell 7 already installed - skipping'
}

# Run deployment steps via pwsh.exe (PowerShell 7) as a child process.
# Using a child process instead of & means exit inside Install-NDT.ps1 terminates
# only that child process; $LASTEXITCODE in this script reflects the exit code.
# Exit codes:
#   0    - all steps completed successfully, no reboot required
#   3010 - deployment reboot step; AutoLogon registry already written by Install-NDT.ps1
#   3011 - deployment paused (Pause step); RunOnce must be removed so reboot stays paused
# Use the full path - the PS5 process $PATH is stale and won't resolve pwsh.exe by name.
& $pwshExe -ExecutionPolicy Bypass -File 'Z:\Scripts\unattend2026\Install-NDT.ps1'
$ndtExitCode = $LASTEXITCODE
Write-Log "Install-NDT.ps1 exited with code $ndtExitCode"

if ($ndtExitCode -eq 3010) {
    # Reboot step — write reboot flag so the next logon knows a reboot was expected.
    # RunOnce\Deploy2026 remains registered; deployment resumes automatically after reboot.
    Write-Log 'Reboot pending - writing reboot flag and exiting' -ForegroundColor Yellow
    New-Item -Path $rebootFlagPath -ItemType File -Force | Out-Null
    net use Z: /delete /yes
    exit 0

} elseif ($ndtExitCode -eq 3011) {
    # Pause step — write pause.flag before removing RunOnce so that the spurious
    # second invocation (shell double-fire) exits at the early-exit guard above
    # instead of re-registering RunOnce and continuing deployment.
    Write-Log 'Deployment paused - writing pause.flag and removing RunOnce\Deploy2026' -ForegroundColor Yellow
    New-Item -Path $pauseFlagPath -ItemType File -Force | Out-Null
    Remove-ItemProperty -Path $runOnceKey -Name $runOnceValue -ErrorAction SilentlyContinue
    net use Z: /delete /yes
    exit 0

} elseif ($ndtExitCode -eq 0) {
    # All steps completed — run end-of-deployment cleanup.
    net use Z: /delete /yes
    Write-Log "Z: unmapped at $(Get-Date)"

    # Remove RunOnce and disable AutoLogon
    Remove-ItemProperty -Path $runOnceKey  -Name $runOnceValue       -ErrorAction SilentlyContinue
    Set-ItemProperty   -Path $winlogonKey -Name AutoAdminLogon -Value '0' -Type String -Force
    Remove-ItemProperty -Path $winlogonKey -Name DefaultPassword     -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $winlogonKey -Name DefaultDomainName   -ErrorAction SilentlyContinue

    # Write sentinel so any duplicate invocations in the same logon session exit immediately.
    New-Item -Path $deployCompleteFlagPath -ItemType File -Force | Out-Null

    # Remove sensitive/temporary deployment files from C:\temp.
    # Commented out for debugging purposes - enable in production.
    #Remove-Item -Path 'C:\temp\settings.json'    -Force -ErrorAction SilentlyContinue
    #Remove-Item -Path 'C:\temp\install2026.ps1'  -Force -ErrorAction SilentlyContinue

    Write-Log "Deployment complete - cleanup done at $(Get-Date)" -ForegroundColor Green

} else {
    # Unexpected exit code - unmap share and log, but do not create deploy-complete.flag.
    Write-Log "Unexpected exit code $ndtExitCode from Install-NDT.ps1 - deployment may be incomplete" -Level WARN
    net use Z: /delete /yes
    exit $ndtExitCode
}

