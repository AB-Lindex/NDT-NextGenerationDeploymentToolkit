# Build Windows PE WIM
# 1. Extracts credentials from CustomSettings.json into settings.json
# 2. Mounts boot2026.wim and injects the Deploy folder (install.ps1 + settings.json)
# 3. Unmounts and commits the WIM
# 4. Updates WDS with the new boot image

$ErrorActionPreference = "Stop"

# Paths
$scriptDir       = $PSScriptRoot
$wimFile         = "C:\Deploy2026\Boot\boot2026.wim"
$mountDir        = "C:\WinPE_Mount"
$deploySource    = Join-Path $scriptDir "Deploy"
$customSettingsPath = Join-Path $scriptDir "..\..\..\Control\CustomSettings.json"
$settingsOutput  = Join-Path $deploySource "settings.json"

# Verify running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

# Verify WIM exists
if (-not (Test-Path $wimFile)) {
    Write-Error "Boot WIM not found: $wimFile"
    exit 1
}

try {
    # -------------------------------------------------------
    # Step 1: Generate settings.json from CustomSettings.json
    # -------------------------------------------------------
    Write-Host "Step 1: Generating settings.json..." -ForegroundColor Cyan

    if (-not (Test-Path $customSettingsPath)) {
        throw "CustomSettings.json not found at: $customSettingsPath"
    }

    $customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json

    if (-not $customSettings.Deploy) {
        throw "Deploy section not found in CustomSettings.json"
    }

    $deploySettings = $customSettings.Deploy
    $settings = @{
        Share    = $deploySettings.Share
        Username = $deploySettings.Username
        Password = $deploySettings.Password
    }

    $settings | ConvertTo-Json | Set-Content -Path $settingsOutput -Encoding UTF8

    Write-Host "  [OK] settings.json written: $settingsOutput" -ForegroundColor Green
    Write-Host "  Share: $($settings.Share)" -ForegroundColor Gray
    Write-Host "  Username: $($settings.Username)" -ForegroundColor Gray

    # -------------------------------------------------------
    # Step 2: Mount the WIM
    # -------------------------------------------------------
    Write-Host "`nStep 2: Mounting WIM..." -ForegroundColor Cyan

    if (-not (Test-Path $mountDir)) {
        New-Item -Path $mountDir -ItemType Directory -Force | Out-Null
    }

    $result = dism /Mount-Wim /WimFile:"$wimFile" /Index:1 /MountDir:"$mountDir" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "DISM mount failed: $result" }
    Write-Host "  [OK] WIM mounted at: $mountDir" -ForegroundColor Green

    # -------------------------------------------------------
    # Step 3: Inject Deploy folder into WIM
    # -------------------------------------------------------
    Write-Host "`nStep 3: Injecting Deploy folder into WIM..." -ForegroundColor Cyan

    $wimDeployDir = Join-Path $mountDir "Deploy"
    if (-not (Test-Path $wimDeployDir)) {
        New-Item -Path $wimDeployDir -ItemType Directory -Force | Out-Null
    }

    # Copy all files from Deploy folder into WIM
    $files = Get-ChildItem -Path $deploySource -File
    foreach ($file in $files) {
        Copy-Item -Path $file.FullName -Destination $wimDeployDir -Force
        Write-Host "  [OK] Copied: $($file.Name)" -ForegroundColor Gray
    }

    # -------------------------------------------------------
    # Step 4: Unmount and commit WIM
    # -------------------------------------------------------
    Write-Host "`nStep 4: Committing and unmounting WIM..." -ForegroundColor Cyan

    $result = dism /Unmount-Wim /MountDir:"$mountDir" /Commit 2>&1
    if ($LASTEXITCODE -ne 0) { throw "DISM unmount/commit failed: $result" }
    Write-Host "  [OK] WIM committed and unmounted" -ForegroundColor Green

    # -------------------------------------------------------
    # Step 5: Update WDS
    # -------------------------------------------------------
    Write-Host "`nStep 5: Updating WDS..." -ForegroundColor Cyan

    Write-Host "  Stopping WDS service..." -ForegroundColor Gray
    Stop-Service WDSServer -Force
    Write-Host "  [OK] WDS stopped" -ForegroundColor Gray

    Write-Host "  Removing old boot image..." -ForegroundColor Gray
    wdsutil /Remove-Image /Image:"PE Boot 2026" /ImageType:Boot /Architecture:x64 /Filename:"boot2026.wim" 2>&1 | Out-Null

    Write-Host "  Adding new boot image..." -ForegroundColor Gray
    $result = wdsutil /Verbose /Add-Image /ImageFile:"$wimFile" /ImageType:Boot /Name:"PE Boot 2026" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "WDS add image failed: $result" }
    Write-Host "  [OK] Boot image updated in WDS" -ForegroundColor Green

    Write-Host "  Starting WDS service..." -ForegroundColor Gray
    Start-Service WDSServer
    Write-Host "  [OK] WDS started" -ForegroundColor Green

    # -------------------------------------------------------
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "PE build complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

} catch {
    Write-Error "Build failed: $_"

    # Attempt to discard mount if WIM is still mounted
    if (Test-Path $mountDir) {
        Write-Warning "Attempting to discard WIM mount..."
        dism /Unmount-Wim /MountDir:"$mountDir" /Discard 2>&1 | Out-Null
    }

    exit 1
}
