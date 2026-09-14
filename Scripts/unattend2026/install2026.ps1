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
$deployWallpaperPath     = 'C:\temp\deploy-wallpaper.bmp'

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
$settingsPath = 'C:\temp\settings.json'
if (-not (Test-Path $settingsPath)) {
    Write-Log 'ERROR: settings.json not found' -Level ERROR
    exit 1
}
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json

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

    # Deployment is finished - remove the "in progress" wallpaper.
    Clear-DeploymentWallpaper

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

