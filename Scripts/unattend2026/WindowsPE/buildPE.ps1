# Build Windows PE WIM and ISO
# 1. Extracts credentials from CustomSettings.json into settings.json
# 2. Mounts boot2026.wim and injects the Deploy folder (install.ps1 + settings.json)
# 3. Unmounts and commits the WIM
# 4. Updates WDS with the new boot image
# 5. Creates a bootable ISO (for Hyper-V Gen 1 / BIOS DVD boot)

$ErrorActionPreference = "Stop"

# Paths
$scriptDir          = $PSScriptRoot
$wimFile            = "C:\Deploy2026\Boot\boot2026.wim"
$isoFile            = "C:\Deploy2026\Boot\boot2026.iso"
$mountDir           = "C:\WinPE_Mount"
$isoStagingDir      = "C:\WinPE_ISO_Staging"
$deploySource       = Join-Path $scriptDir "Deploy"
$customSettingsPath = Join-Path $scriptDir "..\..\..\Control\CustomSettings.json"
$settingsOutput     = Join-Path $deploySource "settings.json"

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
    # Step 6: Create bootable ISO for Hyper-V Gen 1 / BIOS DVD boot
    # -------------------------------------------------------
    Write-Host "`nStep 6: Creating bootable ISO..." -ForegroundColor Cyan

    # Locate Windows ADK — check registry first, fall back to default install path
    $adkRoot = $null
    $adkRegPath = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots"
    if (Test-Path $adkRegPath) {
        $kitsRoot = (Get-ItemProperty -Path $adkRegPath -Name "KitsRoot10" -ErrorAction SilentlyContinue).KitsRoot10
        if ($kitsRoot) { $adkRoot = Join-Path $kitsRoot "Assessment and Deployment Kit" }
    }
    if (-not $adkRoot -or -not (Test-Path $adkRoot)) {
        $adkRoot = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit"
    }

    $winPERoot    = Join-Path $adkRoot "Windows Preinstallation Environment"
    $copypeCmd    = Join-Path $winPERoot "copype.cmd"
    $makeMediaCmd = Join-Path $winPERoot "MakeWinPEMedia.cmd"
    $winPEArch    = Join-Path $winPERoot "amd64"   # only present when WinPE Add-on is installed

    if (-not (Test-Path $copypeCmd)) {
        Write-Warning "copype.cmd not found at: $copypeCmd"
        Write-Warning "The Windows ADK itself does not appear to be installed."
        Write-Warning "Install the ADK + WinPE Add-on:"
        Write-Warning "  https://learn.microsoft.com/windows-hardware/get-started/adk-install"
        Write-Warning "Skipping ISO creation — WDS boot image was still updated successfully."
    } elseif (-not (Test-Path $winPEArch)) {
        Write-Warning "WinPE amd64 architecture files not found at: $winPEArch"
        Write-Warning ""
        Write-Warning "The Windows PE Add-on for the ADK is NOT installed."
        Write-Warning "The ADK and WinPE Add-on are TWO separate downloads — both are required."
        Write-Warning ""
        Write-Warning "Install steps:"
        Write-Warning "  1. Open: https://learn.microsoft.com/windows-hardware/get-started/adk-install"
        Write-Warning "  2. Download and install 'Windows PE add-on for the Windows ADK'"
        Write-Warning "     (separate link on that page, below the main ADK download)"
        Write-Warning "  3. Re-run this script"
        Write-Warning ""
        Write-Warning "Skipping ISO creation — WDS boot image was still updated successfully."
    } else {
        # Clean up any leftover staging directory
        if (Test-Path $isoStagingDir) {
            Write-Host "  Removing old staging directory..." -ForegroundColor Gray
            Remove-Item -Path $isoStagingDir -Recurse -Force
        }

        # copype.cmd creates the standard PE media tree:
        #   media\sources\boot.wim  +  boot manager files (etfsboot, BCD, EFI, etc.)
        #
        # IMPORTANT: Push-Location alone is not sufficient — PowerShell's path stack does
        # not always update [System.Environment]::CurrentDirectory, which is what child
        # processes actually inherit as their working directory.
        # When cmd.exe inherits the wrong CWD, copype.cmd's %~dp0 resolves incorrectly
        # and it cannot locate its own amd64\ subfolder.
        # Fix: explicitly set the process-level CWD before spawning cmd.exe.
        Write-Host "  Running copype amd64 -> $isoStagingDir ..." -ForegroundColor Gray
        $savedDir = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $winPERoot
        try {
            cmd.exe /c "copype.cmd amd64 `"$isoStagingDir`""
            if ($LASTEXITCODE -ne 0) { throw "copype.cmd failed (exit $LASTEXITCODE)" }
        } finally {
            [System.Environment]::CurrentDirectory = $savedDir
        }
        Write-Host "  [OK] PE staging directory created" -ForegroundColor Green

        # Replace the stock boot.wim with our customised one (credentials + deploy scripts baked in)
        $stagingBootWim = Join-Path $isoStagingDir "media\sources\boot.wim"
        Write-Host "  Injecting custom boot2026.wim into media\sources\boot.wim ..." -ForegroundColor Gray
        Copy-Item -Path $wimFile -Destination $stagingBootWim -Force
        Write-Host "  [OK] Custom WIM injected" -ForegroundColor Green

        # Remove existing ISO so MakeWinPEMedia does not prompt
        if (Test-Path $isoFile) {
            Remove-Item -Path $isoFile -Force
        }

        # MakeWinPEMedia builds a bootable ISO with both BIOS (etfsboot) and EFI boot sectors.
        # The BIOS sector is required for Hyper-V Generation 1 VMs.
        Write-Host "  Running MakeWinPEMedia /iso ..." -ForegroundColor Gray
        $savedDir = [System.Environment]::CurrentDirectory
        [System.Environment]::CurrentDirectory = $winPERoot
        try {
            cmd.exe /c "MakeWinPEMedia.cmd /iso `"$isoStagingDir`" `"$isoFile`""
            if ($LASTEXITCODE -ne 0) { throw "MakeWinPEMedia.cmd failed (exit $LASTEXITCODE)" }
        } finally {
            [System.Environment]::CurrentDirectory = $savedDir
        }
        Write-Host "  [OK] ISO created: $isoFile" -ForegroundColor Green

        # Staging directory is no longer needed — the ISO is self-contained
        Remove-Item -Path $isoStagingDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Staging directory cleaned up" -ForegroundColor Gray

        Write-Host ""
        Write-Host "  Mount this ISO to the Gen 1 VM DVD drive before starting the VM:" -ForegroundColor Yellow
        Write-Host "    Set-VMDvdDrive -VMName '<vmname>' -Path '$isoFile'" -ForegroundColor Yellow
    }

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
