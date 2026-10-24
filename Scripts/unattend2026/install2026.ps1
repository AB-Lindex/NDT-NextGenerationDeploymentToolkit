Param(
    # Pass -Resume when manually continuing after a Pause step (i.e. via the
    # desktop shortcut).  Without this switch the script exits immediately if
    # a pause.flag is present, preventing the spurious double-invocation that
    # the Windows shell causes after any RunOnce-triggered session.
    [switch]$Resume,

    # Rerun a finished deployment (re-run steps or run newly added ones): the passwords are blanked
    # in settings.json when deployment finishes, so supply them again here.
    # Passing either parameter while deploy-complete.flag exists starts the rerun.
    [string]$AdminPassword,
    [string]$DeployPassword
)

# This script lives in the deployment folder (created by install.ps1) and keeps everything NDT
# writes on the machine there - nothing in C:\temp. Other scripts get the folder from here.
$deployDir   = $PSScriptRoot
$LogPath     = Join-Path $deployDir 'install2026.log'
$winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$runOnceKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
$runOnceValue = 'Deploy2026'
$runOnceCmd   = "powershell.exe -executionpolicy bypass -File `"$PSCommandPath`""
$settingsPath            = Join-Path $deployDir 'settings.json'
$deployCompleteFlagPath  = Join-Path $deployDir 'deploy-complete.flag'
$pauseFlagPath           = Join-Path $deployDir 'pause.flag'
$rebootFlagPath          = Join-Path $deployDir 'reboot.flag'
$deployWallpaperPath     = Join-Path $deployDir 'deploy-wallpaper.bmp'

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

# Finished deployment: blank the passwords in settings.json (a rerun supplies them again as parameters).
function Clear-DeploymentPasswords {
    try {
        $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($s.AutoLogon) { $s.AutoLogon.Password = '' }
        if ($s.Deploy)    { $s.Deploy.Password    = '' }
        $s | ConvertTo-Json -Depth 4 | Set-Content -Path $settingsPath -Encoding UTF8
    } catch {
        Write-Log "Could not blank the passwords in ${settingsPath}: $($_.Exception.Message)" -Level WARN
    }
}

# ---------------------------------------------------------------------------
# Deployment UX helpers (best-effort - never block or fail deployment)
# ---------------------------------------------------------------------------
# The Phase 2 console is launched by RunOnce under the AutoLogon session. On
# Windows 11 the shell hides that window, and after every reboot step the bare
# desktop briefly appears before RunOnce re-launches us - both leave the local
# technician with no visible sign that deployment is still running. These helpers
# (1) paint a solid "Deployment in progress" wallpaper on the AutoLogon profile so
# the bare desktop always reads as deploying, and (2) bring the console forward.
function Initialize-DeployUI {
    if (-not ('DeployUI' -as [type])) {
        Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DeployUI {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@
    }
}

function Set-DeploymentWallpaper {
    param([string]$Path = $deployWallpaperPath)
    try {
        Initialize-DeployUI
        if (-not (Test-Path $Path)) {
            Add-Type -AssemblyName System.Drawing
            $bmp  = New-Object System.Drawing.Bitmap -ArgumentList 1920, 1080
            $g    = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear([System.Drawing.Color]::FromArgb(0, 78, 152))
            $font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 44, ([System.Drawing.FontStyle]::Bold)
            $sf   = New-Object System.Drawing.StringFormat
            $sf.Alignment     = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rect = New-Object System.Drawing.RectangleF -ArgumentList 0, 0, 1920, 1080
            $text = "Deployment in progress`r`nDo not turn off this computer"
            $g.DrawString($text, $font, [System.Drawing.Brushes]::White, $rect, $sf)
            $g.Dispose(); $font.Dispose()
            $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Bmp)
            $bmp.Dispose()
        }
        # Solid colour behind the wallpaper - renders instantly on the next AutoLogon
        # before the bitmap loads, so a reboot never flashes a plain default desktop.
        Set-ItemProperty 'HKCU:\Control Panel\Colors'  -Name Background     -Value '0 78 152' -Force
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallPaper      -Value $Path      -Force
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'       -Force  # stretch
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name TileWallpaper  -Value '0'        -Force
        [DeployUI]::SystemParametersInfo(0x0014, 0, $Path, 0x03) | Out-Null   # SPI_SETDESKWALLPAPER, update+broadcast
        Write-Log 'Deployment wallpaper applied'
    } catch {
        Write-Log "Could not apply deployment wallpaper: $($_.Exception.Message)" -Level WARN
    }
}

function Show-DeploymentConsole {
    try {
        Initialize-DeployUI
        $hwnd = [DeployUI]::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) {
            [DeployUI]::ShowWindow($hwnd, 9) | Out-Null            # SW_RESTORE
            [DeployUI]::SetForegroundWindow($hwnd) | Out-Null
        }
    } catch { }
}

function Clear-DeploymentWallpaper {
    try {
        Initialize-DeployUI
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallPaper -Value '' -Force
        [DeployUI]::SystemParametersInfo(0x0014, 0, '', 0x03) | Out-Null
        Remove-Item $deployWallpaperPath -Force -ErrorAction SilentlyContinue
        Write-Log 'Deployment wallpaper cleared'
    } catch { }
}

# MDT-style FinishAction: DESKTOP (default), PROMPT, REBOOT, SHUTDOWN, LOGOFF.
# On failure REBOOT/SHUTDOWN/LOGOFF downgrade to PROMPT - RunOnce + AutoLogon are still
# in place then, so acting on them would loop the failed deployment.
function Invoke-FinishAction {
    param(
        [bool]$Success,
        [string]$Detail
    )
    $action = if ($settings -and $settings.FinishAction) { ([string]$settings.FinishAction).ToUpper() } else { 'DESKTOP' }
    # MDT treats RESTART as an alias for REBOOT.
    if ($action -eq 'RESTART') { $action = 'REBOOT' }
    if ($action -notin 'DESKTOP', 'PROMPT', 'REBOOT', 'SHUTDOWN', 'LOGOFF') {
        Write-Log "Unknown FinishAction '$action' - using DESKTOP" -Level WARN
        $action = 'DESKTOP'
    }
    if (-not $Success -and $action -in 'REBOOT', 'SHUTDOWN', 'LOGOFF') {
        Write-Log "Deployment failed - FinishAction $action downgraded to PROMPT" -Level WARN
        $action = 'PROMPT'
    }
    Write-Log "FinishAction: $action"

    switch ($action) {
        'PROMPT' {
            $finished = Get-Date
            $duration = 'unknown'
            try {
                $start = [datetime]::ParseExact([string]$settings.DeployStart, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                $span  = $finished - $start
                if ($span.TotalSeconds -ge 0) {
                    $duration = '{0:00}:{1:00}:{2:00}' -f [math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
                }
            } catch { }

            $status = if ($Success) { 'Deployment completed successfully.' } else { 'Deployment did NOT complete successfully.' }
            $lines  = @(
                $status, '',
                "Computer : $env:COMPUTERNAME",
                "Finished : $($finished.ToString('yyyy-MM-dd HH:mm:ss'))",
                "Duration : $duration"
            )
            if ($Detail) { $lines += "Details  : $Detail" }
            $lines += '', "Log: $LogPath"

            $title = if ($Success) { 'NDT - Deployment finished' } else { 'NDT - Deployment failed' }
            # WScript.Shell.Popup works on both Desktop Experience and Server Core.
            # 64 = information icon, 48 = warning icon; +4096 = system modal (stays on top).
            $icon  = if ($Success) { 64 } else { 48 }
            try {
                (New-Object -ComObject WScript.Shell).Popup(($lines -join "`r`n"), 0, $title, $icon + 4096) | Out-Null
            } catch {
                Write-Log "Could not show finish prompt: $($_.Exception.Message)" -Level WARN
            }
        }
        'REBOOT'   { shutdown.exe /r /t 10 /c "NDT deployment finished" }
        'SHUTDOWN' { shutdown.exe /s /t 10 /c "NDT deployment finished" }
        'LOGOFF'   { shutdown.exe /l /f }
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
$rerunRequested = $PSBoundParameters.ContainsKey('AdminPassword') -or $PSBoundParameters.ContainsKey('DeployPassword')
if (Test-Path $deployCompleteFlagPath) {
    if (-not $rerunRequested) {
        Write-Log 'Deployment already completed (deploy-complete.flag present) - exiting. To rerun, pass -AdminPassword and -DeployPassword.' -ForegroundColor Yellow
        exit 0
    }

    # Rerun: settings.json has blank passwords, and the share cannot be mapped without one.
    if (-not $DeployPassword) {
        Write-Log 'ERROR: -DeployPassword is required to rerun a finished deployment (the share cannot be mapped without it)' -Level ERROR
        exit 1
    }
    Write-Log 'Rerunning a finished deployment - only steps not yet completed will run' -ForegroundColor Cyan
    Remove-Item $deployCompleteFlagPath -Force
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

# Make deployment progress visible to a local technician: paint the "in progress"
# wallpaper on the AutoLogon profile (covers the bare-desktop flash after each
# reboot) and bring the console to the foreground (Windows 11 hides it).
Set-DeploymentWallpaper
Show-DeploymentConsole

# If we're resuming from a Pause, the shortcut on the Public Desktop is no longer needed.
$pauseShortcut = 'C:\Users\Public\Desktop\Continue Deployment.lnk'
if (Test-Path $pauseShortcut) {
    Remove-Item $pauseShortcut -Force -ErrorAction SilentlyContinue
    Write-Log 'Removed "Continue Deployment" shortcut from Public Desktop'
}

# Map deployment share
if (-not (Test-Path $settingsPath)) {
    Write-Log 'ERROR: settings.json not found' -Level ERROR
    Remove-ItemProperty -Path $runOnceKey -Name $runOnceValue -ErrorAction SilentlyContinue
    Clear-DeploymentWallpaper
    exit 1
}
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json

# Passwords supplied as parameters override the stored ones (they are blank after a finished deployment).
if ($PSBoundParameters.ContainsKey('DeployPassword') -or $PSBoundParameters.ContainsKey('AdminPassword')) {
    if ($PSBoundParameters.ContainsKey('DeployPassword')) { $settings.Deploy.Password = $DeployPassword }
    if ($PSBoundParameters.ContainsKey('AdminPassword')) {
        # AutoLogon may have been switched to another account by an AutoLogon step; -AdminPassword is the local Administrator's.
        $settings.AutoLogon.Domain   = '.'
        $settings.AutoLogon.Username = 'Administrator'
        $settings.AutoLogon.Password = $AdminPassword
    } elseif ($rerunRequested) {
        Write-Log '-AdminPassword not supplied - a Reboot step will not be able to sign in automatically' -Level WARN
    }
    $settings | ConvertTo-Json -Depth 4 | Set-Content -Path $settingsPath -Encoding UTF8
    Write-Log "Passwords supplied as parameters stored in $settingsPath for this run"
}
if (-not $settings.Deploy.Password) {
    Write-Log 'ERROR: the Deploy password in settings.json is blank - run again with -DeployPassword' -Level ERROR
    exit 1
}

# Map the deployment share, waiting patiently for the network to come up.
# Physical NICs can take far longer than a VM to negotiate link + obtain a DHCP
# lease, so we poll for a usable IPv4 address and then retry the mapping until Z:
# is genuinely readable. Without this guard a slow NIC makes net use fail silently,
# Z: never maps, and pwsh -File 'Z:\...\Install-NDT.ps1' aborts with exit code 64
# before the deployment engine can even start.
$shareUnc      = $settings.Deploy.Share
# Total time to keep trying - overridable per-site via Deploy.MapTimeoutSec in settings.json.
$mapTimeoutSec = if ($settings.Deploy.MapTimeoutSec) { [int]$settings.Deploy.MapTimeoutSec } else { 120 }
$mapPollSec    = 5                                   # delay between attempts
$mapProbe      = 'Z:\Control\CustomSettings.json'    # proves the share is really readable
$deadline      = (Get-Date).AddSeconds($mapTimeoutSec)
$mapped        = $false

Write-Log "Mapping share: $shareUnc (waiting up to $mapTimeoutSec s for network)"
while ((Get-Date) -lt $deadline) {
    # Wait for a real IPv4 address - skip loopback, tunnels and APIPA (169.254.x.x).
    $ip = Get-NetIPAddress -AddressFamily IPv4 -Type Unicast -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback|Tunnel' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $ip) {
        Write-Log 'No usable IPv4 address yet - waiting for NIC/DHCP...' -ForegroundColor Yellow
        Start-Sleep -Seconds $mapPollSec
        continue
    }

    # Drop any stale/partial Z: from a failed prior attempt, then (re)map.
    net use Z: /delete /yes 2>$null | Out-Null
    net use Z: "$shareUnc" /user:"$($settings.Deploy.Username)" "$($settings.Deploy.Password)" /persistent:no 2>$null | Out-Null

    if (Test-Path $mapProbe) {
        Write-Log "Share mapped successfully (IP $ip)" -ForegroundColor Green
        $mapped = $true
        break
    }

    Write-Log "Share not reachable yet (IP $ip) - retrying in $mapPollSec s..." -ForegroundColor Yellow
    Start-Sleep -Seconds $mapPollSec
}

if (-not $mapped) {
    Write-Log "ERROR: Could not map $shareUnc within $mapTimeoutSec s - aborting" -Level ERROR
    net use Z: /delete /yes 2>$null | Out-Null
    Invoke-FinishAction -Success $false -Detail "Could not map $shareUnc within $mapTimeoutSec s"
    exit 1
}

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
        Invoke-FinishAction -Success $false -Detail 'PowerShell 7 installation failed'
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
& $pwshExe -ExecutionPolicy Bypass -File 'Z:\Scripts\unattend2026\Install-NDT.ps1' -DeployDir $deployDir
$ndtExitCode = $LASTEXITCODE
Write-Log "Install-NDT.ps1 exited with code $ndtExitCode"

if ($ndtExitCode -eq 3010) {
    # Reboot step - write reboot flag so the next logon knows a reboot was expected.
    # RunOnce\Deploy2026 remains registered; deployment resumes automatically after reboot.
    Write-Log 'Reboot pending - writing reboot flag and exiting' -ForegroundColor Yellow
    New-Item -Path $rebootFlagPath -ItemType File -Force | Out-Null
    net use Z: /delete /yes
    exit 0

} elseif ($ndtExitCode -eq 3011) {
    # Pause step - write pause.flag before removing RunOnce so that the spurious
    # second invocation (shell double-fire) exits at the early-exit guard above
    # instead of re-registering RunOnce and continuing deployment.
    Write-Log 'Deployment paused - writing pause.flag and removing RunOnce\Deploy2026' -ForegroundColor Yellow
    New-Item -Path $pauseFlagPath -ItemType File -Force | Out-Null
    Remove-ItemProperty -Path $runOnceKey -Name $runOnceValue -ErrorAction SilentlyContinue
    net use Z: /delete /yes
    exit 0

} elseif ($ndtExitCode -eq 0) {
    # All steps completed - run end-of-deployment cleanup.
    net use Z: /delete /yes
    Write-Log "Z: unmapped at $(Get-Date)"

    # Remove RunOnce and disable AutoLogon
    Remove-ItemProperty -Path $runOnceKey  -Name $runOnceValue       -ErrorAction SilentlyContinue
    Set-ItemProperty   -Path $winlogonKey -Name AutoAdminLogon -Value '0' -Type String -Force
    Remove-ItemProperty -Path $winlogonKey -Name DefaultPassword     -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $winlogonKey -Name DefaultDomainName   -ErrorAction SilentlyContinue

    # Deployment is finished - remove the "in progress" wallpaper.
    Clear-DeploymentWallpaper

    # Write sentinel so any duplicate invocations in the same logon session exit immediately.
    $flagLines = @(
        'NDT deployment is now FINISHED.',
        '',
        "Computer : $env:COMPUTERNAME",
        "Finished : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    )
    if ($settings -and $settings.DeployStart) { $flagLines += "Started  : $($settings.DeployStart)" }
    $flagLines += @(
        '',
        'This file is a sentinel: while it exists, install2026.ps1 will not run again.',
        '',
        "Everything NDT keeps on this machine is in ${deployDir}:",
        '  install.log      - Phase 1 (WinPE): config validation, disk partitioning, DISM image apply,',
        '                     unattend generation, BCDBoot. Copied here from X:\install.log once the',
        '                     image was applied.',
        '  install2026.log  - Phase 2 bootstrap (PS 5, install2026.ps1): network wait, share mapping,',
        '                     PowerShell 7 install, launching the step engine, reboot/pause handling,',
        '                     cleanup and FinishAction.',
        '  install-ndt.log  - Step engine (PS 7, Install-NDT.ps1): the ordered deployment steps from',
        '                     DeploymentGroups.json - per-step start/finish, script output, exit codes.',
        '  install-steps.json - Completed steps; a rerun only runs steps that are not in this list.',
        '  settings.json    - Deployment settings; the Administrator and Deploy passwords are blanked.',
        '',
        'To rerun the deployment (re-run failed steps or run newly added ones), run:',
        "  powershell.exe -ExecutionPolicy Bypass -File $PSCommandPath -AdminPassword <pw> -DeployPassword <pw>"
    )
    Set-Content -Path $deployCompleteFlagPath -Value $flagLines -Encoding ASCII -Force

    # Passwords must not stay on disk; a rerun supplies them again as parameters.
    Clear-DeploymentPasswords
    Write-Log "Deployment complete - cleanup done at $(Get-Date)" -ForegroundColor Green
    Invoke-FinishAction -Success $true

} else {
    # Unexpected exit code - unmap share and log, but do not create deploy-complete.flag.
    Write-Log "Unexpected exit code $ndtExitCode from Install-NDT.ps1 - deployment may be incomplete" -Level WARN
    net use Z: /delete /yes
    Invoke-FinishAction -Success $false -Detail "Install-NDT.ps1 exited with code $ndtExitCode"
    exit $ndtExitCode
}

