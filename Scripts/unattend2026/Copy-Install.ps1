# Copy and prepare install2026.ps1 with deployment credentials in separate settings file
param(
    # Deployment folder on the target (defined once, in install.ps1)
    [Parameter(Mandatory)]
    [string]$DeployDir
)

# Get MAC address
$macAddress = & "Z:\Scripts\unattend2026\Get-MACAddress.ps1"

# Get Deploy settings
try { . "$PSScriptRoot\Import-NDTModule.ps1" }
catch { Write-Error $_.Exception.Message; exit 1 }
try { $customSettings = Get-NDTMachine -LocalPath 'Z:\' }
catch { Write-Error $_.Exception.Message; exit 1 }
$sectionsPath = "Z:\Control\Sections.json"
$sections = Get-Content -Path $sectionsPath -Raw | ConvertFrom-Json

# Get machine configuration by MAC address for AutoLogon password
$machineConfig = $customSettings.$macAddress
if (-not $machineConfig) {
    Write-Error "No configuration found for MAC address: $macAddress"
    exit 1
}

# The machine block may name its own deploy section in "Deploy"; otherwise the global 'Deploy' section is used.
$deployResolved = Resolve-NDTDeploySection -Machine $machineConfig -SectionCatalog $sections
$deploySectionName = $deployResolved.Name
$deploySettings = $deployResolved.Settings
Write-Host "Using deploy section: '$deploySectionName'" -ForegroundColor Gray

# Ensure the deployment folder exists
New-Item -ItemType Directory -Path $DeployDir -Force | Out-Null

if ($deploySettings) {
    Write-Host "Configuring deployment share mapping for first boot..." -ForegroundColor Cyan
    Write-Host "  Share: $($deploySettings.Share)" -ForegroundColor Gray
    
    # Create settings.json with deployment credentials and autologon settings.
    # Record the MAC detected in WinPE so later phases key off it - a VM's MAC
    # can change across reboots in a Hyper-V farm.
    $settings = @{
        MAC = $macAddress
        Deploy = @{
            Share = $deploySettings.Share
            Username = $deploySettings.Username
            Password = $deploySettings.Password
        }
        AutoLogon = @{
            Domain = "."
            Username = "Administrator"
            Password = $machineConfig.AdminPassword
        }
    }
    
    # Pass optional MonitorUrl through to settings.json so Install-NDT.ps1 can reach the monitor
    if ($deploySettings.MonitorUrl) {
        $settings.Deploy['MonitorUrl'] = $deploySettings.MonitorUrl
    }

    # Pass optional MapTimeoutSec through so install2026.ps1 can tune the share-map wait per site.
    if ($deploySettings.MapTimeoutSec) {
        $settings.Deploy['MapTimeoutSec'] = $deploySettings.MapTimeoutSec
    }

    # FinishAction: MAC block overrides the deploy section; absent = DESKTOP (handled by install2026.ps1).
    $finishAction = if ($machineConfig.FinishAction) { $machineConfig.FinishAction } else { $deploySettings.FinishAction }
    if ($finishAction) {
        $settings['FinishAction'] = ([string]$finishAction).ToUpper()
    }

    # Local wall-clock, no offset: WinPE and the installed OS both read the RTC as local time.
    $settings['DeployStart'] = if ($env:NDT_DEPLOY_START) { $env:NDT_DEPLOY_START } else { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }

    # Detect hardware (physical/virtual, vendor, model) and persist for later phases -
    # app installers query this (e.g. VMware Tools) after settings.json exists.
    $hardware = & "Z:\Scripts\unattend2026\Get-Hardware.ps1"
    if ($hardware) {
        $settings['Hardware'] = @{
            Make             = $hardware.Make
            Model            = $hardware.Model
            SerialNumber     = $hardware.SerialNumber
            BiosVersion      = $hardware.BiosVersion
            IsVM             = $hardware.IsVM
            Platform         = $hardware.Platform
            DetectionMethod  = $hardware.DetectionMethod
            IsLaptop         = $hardware.IsLaptop
            IsDesktop        = $hardware.IsDesktop
            IsServer         = $hardware.IsServer
        }
        Write-Host "Detected hardware: $($hardware.Platform) (IsVM=$($hardware.IsVM)) - $($hardware.Make) / $($hardware.Model)" -ForegroundColor Green
    }

    $settings | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $DeployDir 'settings.json') -Encoding UTF8
    Write-Host "Created settings.json with deployment and autologon credentials" -ForegroundColor Green
    
    # Mask password - show first 3 characters
    $visibleChars = [Math]::Min(3, $settings.Deploy.Password.Length)
    $maskedPassword = $settings.Deploy.Password.Substring(0, $visibleChars) + ('*' * [Math]::Max(0, $settings.Deploy.Password.Length - $visibleChars))
    Write-Host "  Password: $maskedPassword" -ForegroundColor Gray
} else {
    Write-Warning "No deployment settings found in CustomSettings.json"
}

# Copy install2026.ps1 as-is (it will read settings.json)
Copy-Item "Z:\Scripts\Unattend2026\install2026.ps1" (Join-Path $DeployDir 'install2026.ps1')
Write-Host "Copied install2026.ps1 to $DeployDir" -ForegroundColor Green
