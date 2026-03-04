function Install-NDT {
    <#
    .SYNOPSIS
        Installs and configures an NDT deployment share.

    .DESCRIPTION
        Bootstraps an NDT deployment share by downloading the repository ZIP from GitHub,
        extracting it directly into the target LocalPath (preserving the full folder
        structure), stamping the Deploy section of Control\CustomSettings.json with the
        supplied parameters, creating the Windows SMB share, and granting the deploy
        account the required permissions.

    .PARAMETER LocalPath
        Local filesystem path where the deployment share will be created.
        Default: C:\Deploy2026

    .PARAMETER ShareName
        Name of the Windows SMB share to create.
        Default: Deploy2026

    .PARAMETER ShareUNC
        Full UNC path used to access the deployment share (stored in CustomSettings.json).
        Default: \\<current hostname>\Deploy2026

    .PARAMETER DeployUsername
        Domain account used by clients to connect to the deployment share.
        Default: Corp\Deploy2026

    .PARAMETER DeployPassword
        Password for the deploy account as a SecureString. Stored in CustomSettings.json.
        Mandatory — you will be prompted if not supplied.

    .PARAMETER RepoZipUrl
        URL of the GitHub repository archive ZIP to download seed control files from.
        Default: https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit/archive/refs/heads/main.zip

    .EXAMPLE
        Install-NDT

    .EXAMPLE
        Install-NDT -LocalPath D:\Deploy2026 -ShareName Deploy2026 -DeployUsername "Corp\Deploy2026"

    .EXAMPLE
        Install-NDT -RepoZipUrl 'https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit/archive/refs/heads/dev.zip'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter()]
        [string]$ShareName = 'Deploy2026',
        [Parameter()]
        [string]$ShareUNC = "\\$($env:COMPUTERNAME)\Deploy2026",
        [Parameter()]
        [string]$DeployUsername = 'Corp\Deploy2026',
        [Parameter(Mandatory)]
        [SecureString]$DeployPassword,
        [Parameter()]
        [string]$RepoZipUrl = 'https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit/archive/refs/heads/main.zip'
    )

    #region ── Download and extract repository ZIP into LocalPath ────────────────
    $tempZip = Join-Path $env:TEMP 'ndt-repo.zip'
    $tempDir = Join-Path $env:TEMP 'ndt-repo'

    try {
        Write-Verbose "Downloading NDT repository ZIP from '$RepoZipUrl'..."
        if ($PSCmdlet.ShouldProcess($RepoZipUrl, 'Download repository ZIP')) {
            Invoke-WebRequest -Uri $RepoZipUrl -OutFile $tempZip -UseBasicParsing
            Write-Verbose "  Downloaded: $tempZip"
        }

        if ($PSCmdlet.ShouldProcess($tempDir, 'Extract repository ZIP')) {
            if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force
            Write-Verbose "  Extracted to: $tempDir"
        }

        # GitHub archive ZIPs always extract into a single top-level folder
        # (e.g. NDT-NextGenerationDeploymentToolkit-main). Find it.
        $repoRoot = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1 -ExpandProperty FullName
        if (-not $repoRoot) { throw 'Could not locate repository root in the downloaded ZIP.' }
        Write-Verbose "  Repository root: $repoRoot"

        if ($PSCmdlet.ShouldProcess($LocalPath, 'Copy repository content to LocalPath')) {
            if (-not (Test-Path $LocalPath)) { New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null }
            Copy-Item -Path (Join-Path $repoRoot '*') -Destination $LocalPath -Recurse -Force
            Write-Verbose "  Repository content copied to: $LocalPath"

            # Remove files/folders that belong only in the source repository and
            # must not exist on a live deployment share.
            $repoOnlyItems = @('.github', '.vscode', '.gitignore', 'README.md')
            foreach ($item in $repoOnlyItems) {
                $itemPath = Join-Path $LocalPath $item
                if (Test-Path $itemPath) {
                    Remove-Item -Path $itemPath -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Verbose "  Removed repo-only item: $item"
                }
            }
        }
    } finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    #endregion

    #region ── Stamp Deploy section of CustomSettings.json with parameters ────────
    $controlDir           = Join-Path $LocalPath 'Control'
    $customSettingsDest   = Join-Path $controlDir 'CustomSettings.json'

    if (-not (Test-Path $customSettingsDest)) {
        Write-Warning "CustomSettings.json not found at '$customSettingsDest' - skipping stamp."
    } else {
        if ($PSCmdlet.ShouldProcess($customSettingsDest, 'Stamp Deploy section')) {
            # Decode the SecureString to plain text only long enough to write the file.
            $bstr          = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($DeployPassword)
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

            $settings = Get-Content $customSettingsDest -Raw | ConvertFrom-Json
            $settings.Deploy.Share    = $ShareUNC
            $settings.Deploy.Username = $DeployUsername
            $settings.Deploy.Password = $plainPassword

            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $customSettingsDest -Encoding UTF8
            Write-Verbose 'Deploy section stamped in CustomSettings.json.'

            $plainPassword = $null
        }
    }
    #endregion

    #region ── SMB share ─────────────────────────────────────────────────────────
    $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue

    if ($existingShare) {
        Write-Verbose "SMB share '$ShareName' already exists - skipping creation."
    } else {
        if ($PSCmdlet.ShouldProcess($ShareName, "Create SMB share pointing to '$LocalPath'")) {
            New-SmbShare -Name $ShareName -Path $LocalPath -Description 'NDT Deployment Share' | Out-Null
            Write-Verbose "Created SMB share '$ShareName' -> '$LocalPath'."
        }
    }
    #endregion

    #region ── Share permissions ─────────────────────────────────────────────────
    # Grant the deploy account Full Access on the share.
    $existingAccess = Get-SmbShareAccess -Name $ShareName -ErrorAction SilentlyContinue |
        Where-Object { $_.AccountName -eq $DeployUsername }

    if (-not $existingAccess) {
        if ($PSCmdlet.ShouldProcess($DeployUsername, "Grant Full access to share '$ShareName'")) {
            Grant-SmbShareAccess -Name $ShareName -AccountName $DeployUsername `
                -AccessRight Full -Force | Out-Null
            Write-Verbose "Granted Full access on '$ShareName' to '$DeployUsername'."
        }
    } else {
        Write-Verbose "Access for '$DeployUsername' on '$ShareName' already configured."
    }

    # Revoke the built-in Everyone read access that New-SmbShare adds by default.
    $everyoneAccess = Get-SmbShareAccess -Name $ShareName -ErrorAction SilentlyContinue |
        Where-Object { $_.AccountName -eq 'Everyone' }

    if ($everyoneAccess) {
        if ($PSCmdlet.ShouldProcess('Everyone', "Revoke access from share '$ShareName'")) {
            Revoke-SmbShareAccess -Name $ShareName -AccountName 'Everyone' -Force | Out-Null
            Write-Verbose "Revoked Everyone access from '$ShareName'."
        }
    }
    #endregion

    Write-Host "NDT deployment share installed successfully." -ForegroundColor Green
    Write-Host "  Local path : $LocalPath"
    Write-Host "  Share      : \\$(hostname)\$ShareName"
    Write-Host "  UNC (ref)  : $ShareUNC"
    Write-Host "  Deploy user: $DeployUsername"
    Write-Host ""
    Write-Host "Edit Control\CustomSettings.json to match your environment before deploying." -ForegroundColor Cyan
}

function Build-NDTPEImage {
    <#
    .SYNOPSIS
        Builds the NDT WinPE boot WIM and optionally a bootable ISO.

    .DESCRIPTION
        Performs the full PE media build pipeline:
          1. Generates settings.json from the Deploy section of CustomSettings.json
             and writes it into the WindowsPE\Deploy folder.
          2. Creates a fresh WinPE staging tree from the ADK base using copype
             (always builds clean — never patches an existing WIM).
          3. Mounts the staging boot.wim with DISM.
          4. Adds required WinPE optional packages in dependency order:
             WinPE-WMI, WinPE-NetFx, WinPE-Scripting, WinPE-PowerShell,
             WinPE-StorageWMI, WinPE-DismCmdlets.
          5. Injects the Deploy folder (install.ps1 + settings.json) and
             Unattend.xml (wpeinit + install.ps1 autorun) into the mounted image.
          6. Commits the WIM and copies it to Boot\boot2026.wim.
          7. Updates the WDS boot image (unless -SkipWDS is specified).
          8. Creates a hybrid BIOS/EFI bootable ISO using MakeWinPEMedia
             (unless -SkipISO is specified).

        Requires the Windows ADK and WinPE Add-on:
          https://learn.microsoft.com/windows-hardware/get-started/adk-install

    .PARAMETER LocalPath
        Root of the NDT deployment share on this machine.
        Default: C:\Deploy2026

    .PARAMETER MountDir
        Temporary directory used to mount the WIM during the build.
        Default: C:\WinPE_Mount

    .PARAMETER IsoStagingDir
        Temporary directory used by copype when building the ISO media tree.
        Default: C:\WinPE_ISO_Staging

    .PARAMETER SkipWDS
        Skip the WDS boot-image update step (Step 7).

    .PARAMETER SkipISO
        Skip ISO creation (Step 8). Useful when only a WDS-served WIM is needed.

    .EXAMPLE
        Build-NDTPEImage

    .EXAMPLE
        Build-NDTPEImage -SkipISO -Verbose

    .EXAMPLE
        Build-NDTPEImage -LocalPath D:\Deploy2026 -SkipWDS
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',

        [Parameter()]
        [string]$MountDir = 'C:\WinPE_Mount',

        [Parameter()]
        [string]$IsoStagingDir = 'C:\WinPE_ISO_Staging',

        [Parameter()]
        [switch]$SkipWDS,

        [Parameter()]
        [switch]$SkipISO
    )

    # ── Verify Administrator ────────────────────────────────────────────────────
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Build-NDTPEImage must be run as Administrator.' }

    # ── Pre-flight: verify WDS is configured (skip if -SkipWDS) ────────────────
    if (-not $SkipWDS) {
        # Two-stage check:
        #   1. Service exists — the WDS role is installed.
        #   2. wdsutil /get-server exit code — 0 means WDS is initialized and configured;
        #      non-zero means the role is present but wdsutil /Initialize-Server has not
        #      been run yet (or the service is stopped/broken).
        # Note: the WdsInstallState registry value documented in older guides is not
        #       present on all Windows Server versions and cannot be relied upon.
        $wdsSvc = Get-Service -Name 'WDSServer' -ErrorAction SilentlyContinue
        $wdsReady = $false
        if ($wdsSvc) {
            wdsutil /get-server /show:config 2>&1 | Out-Null
            $wdsReady = ($LASTEXITCODE -eq 0)
        }

        if (-not $wdsReady) {
            Write-Warning @'
WDS (Windows Deployment Services) is not configured on this server.
The build will complete, but the WDS boot-image update (Step 7) will fail.

To configure WDS before running this command:
  1. Install the WDS role if not already present:
       Install-WindowsFeature WDS -IncludeManagementTools
  2. Configure it (replace paths/options as needed):
       wdsutil /Initialize-Server /RemInst:"C:\RemoteInstall"
  3. Then re-run: Build-NDTPEImage

To skip WDS and build the WIM only:
    Build-NDTPEImage -SkipWDS
'@
        }
    }

    # ── Resolve paths ───────────────────────────────────────────────────────────
    $wimFile            = Join-Path $LocalPath 'Boot\boot2026.wim'
    $isoFile            = Join-Path $LocalPath 'Boot\boot2026.iso'
    $customSettingsPath = Join-Path $LocalPath 'Control\CustomSettings.json'
    $winPEScriptDir     = Join-Path $LocalPath 'Scripts\unattend2026\WindowsPE'
    $deploySource       = Join-Path $winPEScriptDir 'Deploy'
    $unattendSource     = Join-Path $winPEScriptDir 'Unattend.xml'

    # ── Locate Windows ADK ──────────────────────────────────────────────────────
    $adkRoot    = $null
    $adkRegPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    if (Test-Path $adkRegPath) {
        $kitsRoot = (Get-ItemProperty -Path $adkRegPath -Name 'KitsRoot10' -ErrorAction SilentlyContinue).KitsRoot10
        if ($kitsRoot) { $adkRoot = Join-Path $kitsRoot 'Assessment and Deployment Kit' }
    }
    if (-not $adkRoot -or -not (Test-Path $adkRoot)) {
        $adkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    }

    $winPERoot = Join-Path $adkRoot 'Windows Preinstallation Environment'
    $copypeCmd = Join-Path $winPERoot 'copype.cmd'
    $winPEArch = Join-Path $winPERoot 'amd64'
    $winPEOCs  = Join-Path $winPERoot 'amd64\WinPE_OCs'

    # Set ADK environment variables required by copype / MakeWinPEMedia.
    # Normally injected by DandISetEnv.bat; must be set manually from a plain PS session.
    $env:WinPERoot   = $winPERoot
    $env:OSCDImgRoot = Join-Path $adkRoot 'Deployment Tools\amd64\Oscdimg'
    $env:DISMRoot    = Join-Path $adkRoot 'Deployment Tools\amd64\DISM'
    if ($env:PATH -notlike "*$($env:OSCDImgRoot)*") {
        $env:PATH = $env:OSCDImgRoot + ';' + $env:PATH
    }

    if (-not (Test-Path $copypeCmd)) {
        throw "copype.cmd not found at: $copypeCmd`nInstall the Windows ADK + WinPE Add-on: https://learn.microsoft.com/windows-hardware/get-started/adk-install"
    }
    if (-not (Test-Path $winPEArch)) {
        throw "WinPE amd64 files not found at: $winPEArch`nThe WinPE Add-on is a separate download from the ADK: https://learn.microsoft.com/windows-hardware/get-started/adk-install"
    }

    try {
        # ── Step 1: Generate settings.json ─────────────────────────────────────
        Write-Host 'Step 1: Generating settings.json...' -ForegroundColor Cyan

        if (-not (Test-Path $customSettingsPath)) {
            throw "CustomSettings.json not found at: $customSettingsPath"
        }

        $customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json
        if (-not $customSettings.Deploy) { throw 'Deploy section not found in CustomSettings.json.' }

        $deploySection = $customSettings.Deploy
        $settingsObj   = [ordered]@{
            Share    = $deploySection.Share
            Username = $deploySection.Username
            Password = $deploySection.Password
        }

        # settings.json is injected directly into the WIM in Step 5 — the source-folder
        # copy (Scripts\unattend2026\WindowsPE\Deploy\settings.json) is intentionally
        # NOT modified so it stays as a safe placeholder in source control.
        Write-Host '  [OK] settings.json prepared (will be written into WIM in Step 5)' -ForegroundColor Green
        Write-Verbose "  Share   : $($settingsObj.Share)"
        Write-Verbose "  Username: $($settingsObj.Username)"

        # ── Step 2: Create fresh WinPE staging tree with copype ─────────────────
        # Always build from the clean ADK base — never patch an existing WIM.
        Write-Host "`nStep 2: Creating fresh WinPE staging tree..." -ForegroundColor Cyan

        if ($PSCmdlet.ShouldProcess($IsoStagingDir, 'Run copype to create fresh ADK base')) {
            if (Test-Path $IsoStagingDir) {
                Write-Host '  Removing old staging directory...' -ForegroundColor Gray
                Remove-Item -Path $IsoStagingDir -Recurse -Force
            }
            cmd.exe /c "cd /d `"$winPERoot`" && copype.cmd amd64 `"$IsoStagingDir`""
            if ($LASTEXITCODE -ne 0) { throw "copype.cmd failed (exit $LASTEXITCODE)" }
            Write-Host "  [OK] Fresh staging tree created: $IsoStagingDir" -ForegroundColor Green
        }

        $stagingBootWim = Join-Path $IsoStagingDir 'media\sources\boot.wim'

        # ── Step 3: Mount the fresh base WIM ────────────────────────────────────
        Write-Host "`nStep 3: Mounting base WIM..." -ForegroundColor Cyan

        if (-not (Test-Path $MountDir)) {
            New-Item -Path $MountDir -ItemType Directory -Force | Out-Null
        }

        if ($PSCmdlet.ShouldProcess($MountDir, 'Mount staging boot.wim')) {
            dism /Mount-Wim /WimFile:"$stagingBootWim" /Index:1 /MountDir:"$MountDir"
            if ($LASTEXITCODE -ne 0) { throw "DISM mount failed (exit $LASTEXITCODE)" }
            Write-Host "  [OK] WIM mounted at: $MountDir" -ForegroundColor Green
        }

        # ── Step 4: Add required WinPE optional packages ─────────────────────────
        # WinPE-WMI        — WMI (prerequisite for PowerShell)
        # WinPE-NetFx      — .NET Framework (prerequisite for PowerShell)
        # WinPE-Scripting  — scripting support (prerequisite for PowerShell)
        # WinPE-PowerShell — powershell.exe in WinPE
        # WinPE-StorageWMI — storage management via WMI
        # WinPE-DismCmdlets— DISM PowerShell cmdlets
        Write-Host "`nStep 4: Adding WinPE optional packages..." -ForegroundColor Cyan

        $packages = @(
            'WinPE-WMI',
            'WinPE-NetFx',
            'WinPE-Scripting',
            'WinPE-PowerShell',
            'WinPE-StorageWMI',
            'WinPE-DismCmdlets'
        )

        if ($PSCmdlet.ShouldProcess($MountDir, 'Add WinPE optional packages')) {
            foreach ($pkg in $packages) {
                $cabPath = Join-Path $winPEOCs "$pkg.cab"
                if (-not (Test-Path $cabPath)) {
                    Write-Warning "  Package not found, skipping: $cabPath"
                    continue
                }
                Write-Host "  Adding $pkg ..." -ForegroundColor Gray
                dism /Image:"$MountDir" /Add-Package /PackagePath:"$cabPath"
                if ($LASTEXITCODE -ne 0) { throw "DISM Add-Package failed for ${pkg} (exit $LASTEXITCODE)" }
                Write-Host "  [OK] $pkg" -ForegroundColor Gray
            }
            Write-Host '  [OK] All optional packages added' -ForegroundColor Green
        }

        # ── Step 5: Inject Deploy folder and Unattend.xml ───────────────────────
        Write-Host "`nStep 5: Injecting Deploy folder into WIM..." -ForegroundColor Cyan

        if ($PSCmdlet.ShouldProcess($MountDir, 'Inject Deploy folder and Unattend.xml')) {
            $wimDeployDir = Join-Path $MountDir 'Deploy'
            if (-not (Test-Path $wimDeployDir)) {
                New-Item -Path $wimDeployDir -ItemType Directory -Force | Out-Null
            }

            foreach ($file in (Get-ChildItem -Path $deploySource -File)) {
                if ($file.Name -eq 'settings.json') {
                    # Skip — settings.json is written fresh from CustomSettings.json below
                    # to avoid baking hardcoded placeholder values into the WIM.
                    continue
                }
                Copy-Item -Path $file.FullName -Destination $wimDeployDir -Force
                Write-Host "  [OK] Copied: $($file.Name)" -ForegroundColor Gray
            }

            # Write settings.json directly from the Deploy section of CustomSettings.json.
            # This ensures the WIM always contains the correct share/credentials regardless
            # of what the on-disk source placeholder file contains.
            $settingsDestPath = Join-Path $wimDeployDir 'settings.json'
            $settingsObj | ConvertTo-Json | Set-Content -Path $settingsDestPath -Encoding UTF8
            Write-Host '  [OK] settings.json generated -> X:\Deploy\settings.json (from CustomSettings.json)' -ForegroundColor Gray

            # Generate StartDeploy.cmd directly into X:\Deploy\ inside the WIM.
            #
            # The MDT pattern: launch the deployment script in a NEW window with
            # 'start', so this cmd.exe window stays alive as a permanent debug shell.
            # The user gets two windows from the moment PE boots:
            #   Window 1 (this cmd) — free debug shell, Z: already mapped
            #   Window 2            — the running install.ps1
            # No F8 polling, no HTA, no bddrun.exe needed.
            $startDeployContent = @'
@echo off
wpeinit
wpeutil WaitForNetwork
start "NDT Deploy" powershell.exe -NoLogo -ExecutionPolicy Bypass -File X:\Deploy\install.ps1
echo.
echo *** NDT debug shell - deployment is running in the other window ***
echo Type EXIT to close this window (deployment will continue unaffected)
cmd.exe /k
'@
            $startDeployDest = Join-Path $wimDeployDir 'StartDeploy.cmd'
            Set-Content -Path $startDeployDest -Value $startDeployContent -Encoding ASCII
            Write-Host '  [OK] StartDeploy.cmd generated -> X:\Deploy\StartDeploy.cmd' -ForegroundColor Gray

            # Generate winpeshl.ini — controls what winpeshl.exe runs at PE boot.
            #
            # [LaunchApps] lists what to execute.  startnet.cmd is NOT run when
            # winpeshl.ini is present, so wpeinit must be called from StartDeploy.cmd
            # (which it is).
            #
            # Note: 'DebugShell=Yes' is MDT-specific (requires bddrun.exe) and is NOT
            # a standard WinPE winpeshl.ini option — do not add it here.
            $winpeshlContent = @'
[LaunchApps]
%SYSTEMDRIVE%\Deploy\StartDeploy.cmd
'@
            $winpeshlDest = Join-Path $MountDir 'Windows\System32\winpeshl.ini'
            Set-Content -Path $winpeshlDest -Value $winpeshlContent -Encoding ASCII
            Write-Host '  [OK] winpeshl.ini generated -> Windows\System32\winpeshl.ini' -ForegroundColor Gray

            # startnet.cmd fallback — only executed when winpeshl.ini is absent.
            # Write a minimal version so that if winpeshl.ini were ever missing the
            # machine still initialises the network; without this it would hang silently.
            $startnetContent = "@echo off`r`nwpeinit`r`n"
            $startnetDest    = Join-Path $MountDir 'Windows\System32\startnet.cmd'
            Set-Content -Path $startnetDest -Value $startnetContent -Encoding ASCII
            Write-Host '  [OK] startnet.cmd (fallback) -> Windows\System32\startnet.cmd' -ForegroundColor Gray

            # Unattend.xml at WIM root — display settings only.
            # RunSynchronous is NOT used here; winpeshl.ini is the launcher.
            $unattendDest = Join-Path $MountDir 'Unattend.xml'
            if (Test-Path $unattendSource) {
                Copy-Item -Path $unattendSource -Destination $unattendDest -Force
                Write-Host '  [OK] Unattend.xml -> X:\Unattend.xml (WIM root)' -ForegroundColor Gray
            } else {
                Write-Warning "Unattend.xml not found at: $unattendSource"
            }
        }

        # ── Step 6: Commit WIM and copy to Boot\boot2026.wim ────────────────────
        Write-Host "`nStep 6: Committing WIM..." -ForegroundColor Cyan

        if ($PSCmdlet.ShouldProcess($MountDir, 'Commit and unmount WIM')) {
            dism /Unmount-Wim /MountDir:"$MountDir" /Commit
            if ($LASTEXITCODE -ne 0) { throw "DISM unmount/commit failed (exit $LASTEXITCODE)" }
            Write-Host '  [OK] WIM committed and unmounted' -ForegroundColor Green

            $bootDir = Split-Path $wimFile -Parent
            if (-not (Test-Path $bootDir)) { New-Item -Path $bootDir -ItemType Directory -Force | Out-Null }
            Copy-Item -Path $stagingBootWim -Destination $wimFile -Force
            Write-Host "  [OK] boot2026.wim updated: $wimFile" -ForegroundColor Green
        }

        # ── Step 7: Update WDS ──────────────────────────────────────────────────
        if (-not $SkipWDS) {
            Write-Host "`nStep 7: Updating WDS..." -ForegroundColor Cyan

            if ($PSCmdlet.ShouldProcess('WDSServer', 'Stop service, replace boot image, start service')) {
                $wdsImageName = 'NDT PE Boot 2026'

                Write-Host '  Stopping WDS service...' -ForegroundColor Gray
                Stop-Service WDSServer -Force
                Write-Host '  [OK] WDS stopped' -ForegroundColor Gray

                Write-Host '  Removing old boot image...' -ForegroundColor Gray
                wdsutil /Remove-Image /Image:"$wdsImageName" /ImageType:Boot /Architecture:x64 2>&1 | Out-Null
                # Non-zero exit is expected on first run (image not yet registered) — not a failure.

                Write-Host '  Adding new boot image...' -ForegroundColor Gray
                $result = wdsutil /Verbose /Add-Image /ImageFile:"$wimFile" /ImageType:Boot /Name:"$wdsImageName" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "wdsutil Add-Image failed: $result" }
                Write-Host '  [OK] Boot image updated in WDS' -ForegroundColor Green

                Write-Host '  Starting WDS service...' -ForegroundColor Gray
                Start-Service WDSServer
                Write-Host '  [OK] WDS started' -ForegroundColor Green
            }
        } else {
            Write-Verbose 'Step 7: WDS update skipped (-SkipWDS).'
        }

        # ── Step 8: Create bootable ISO ─────────────────────────────────────────
        if (-not $SkipISO) {
            Write-Host "`nStep 8: Creating bootable ISO..." -ForegroundColor Cyan

            if ($PSCmdlet.ShouldProcess($isoFile, 'Build bootable ISO with MakeWinPEMedia')) {
                if (Test-Path $isoFile) { Remove-Item -Path $isoFile -Force }

                cmd.exe /c "cd /d `"$winPERoot`" && MakeWinPEMedia.cmd /iso `"$IsoStagingDir`" `"$isoFile`""
                if ($LASTEXITCODE -ne 0) { throw "MakeWinPEMedia.cmd failed (exit $LASTEXITCODE)" }
                Write-Host "  [OK] ISO created: $isoFile" -ForegroundColor Green

                Remove-Item -Path $IsoStagingDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host '  [OK] Staging directory cleaned up' -ForegroundColor Gray

                Write-Host ''
                Write-Host '  Mount this ISO to a Gen 1 VM DVD drive before booting:' -ForegroundColor Yellow
                Write-Host "    Set-VMDvdDrive -VMName '<vmname>' -Path '$isoFile'" -ForegroundColor Yellow
            }
        } else {
            Write-Verbose 'Step 8: ISO creation skipped (-SkipISO).'
        }

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host 'PE build complete!' -ForegroundColor Green
        Write-Host "========================================`n" -ForegroundColor Green

    } catch {
        Write-Error "Build-NDTPEImage failed: $_"

        # Attempt to discard a still-mounted WIM
        if (Test-Path $MountDir) {
            Write-Warning 'Attempting to discard WIM mount...'
            dism /Unmount-Wim /MountDir:"$MountDir" /Discard 2>&1 | Out-Null
        }

        throw
    }
}

#region ── Server management (CustomSettings.json) ───────────────────────────

function Get-NDTServer {
    <#
    .SYNOPSIS
        Retrieves server entries from CustomSettings.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER MAC
        Return only the entry with this MAC address.
    .PARAMETER Computername
        Return only entries matching this computer name.
    .EXAMPLE
        Get-NDTServer
    .EXAMPLE
        Get-NDTServer -MAC '00:15:5D:02:56:01'
    .EXAMPLE
        Get-NDTServer -Computername srv02
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$MAC,
        [Parameter()]
        [string]$Computername
    )

    $path = Join-Path $LocalPath 'Control\CustomSettings.json'
    if (-not (Test-Path $path)) { throw "CustomSettings.json not found at: $path" }

    $settings   = Get-Content $path -Raw | ConvertFrom-Json
    $macPattern = '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'

    $entries = $settings.PSObject.Properties |
        Where-Object { $_.Name -match $macPattern } |
        ForEach-Object {
            $obj = [ordered]@{ MAC = $_.Name.ToUpper() }
            foreach ($prop in $_.Value.PSObject.Properties) { $obj[$prop.Name] = $prop.Value }
            [PSCustomObject]$obj
        }

    if ($MAC)          { $entries = $entries | Where-Object { $_.MAC -eq $MAC.ToUpper() } }
    if ($Computername) { $entries = $entries | Where-Object { $_.Computername -eq $Computername } }

    $entries
}

function Add-NDTServer {
    <#
    .SYNOPSIS
        Adds a new server entry to CustomSettings.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER MAC
        MAC address of the server (colon-separated, any case).
    .PARAMETER Computername
        Target computer name.
    .PARAMETER OS
        OS key from OS.json to deploy.
    .PARAMETER IPAddress
        Static IP in CIDR notation (e.g. 10.0.3.22/24), or 'DHCP'.
    .PARAMETER LocalAdmin
        Local administrator password (stored as plain text in CustomSettings.json).
    .PARAMETER Sections
        Hashtable of section references, e.g. @{ Locale = 'Sweden'; ADSettings = 'ADJoinCorp' }
    .PARAMETER DeploymentSteps
        Ordered array of deployment group names from Deployment.json.
    .PARAMETER Properties
        Hashtable of arbitrary extra key-value pairs to include in the entry.
    .EXAMPLE
        Add-NDTServer -MAC '00:15:5D:02:56:05' -Computername srv05 -OS WIN2025DCG `
            -IPAddress '10.0.3.25/24' -DeploymentSteps 'General Settings','SMC' `
            -Sections @{ Locale = 'Sweden'; NetworkSettings = 'NicAuto'; ADSettings = 'ADJoinCorp' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter(Mandatory)]
        [string]$MAC,
        [Parameter(Mandatory)]
        [string]$Computername,
        [Parameter(Mandatory)]
        [string]$OS,
        [Parameter()]
        [string]$IPAddress,
        [Parameter()]
        [string]$LocalAdmin,
        [Parameter()]
        [hashtable]$Sections,
        [Parameter()]
        [string[]]$DeploymentSteps,
        [Parameter()]
        [hashtable]$Properties
    )

    $path      = Join-Path $LocalPath 'Control\CustomSettings.json'
    if (-not (Test-Path $path)) { throw "CustomSettings.json not found at: $path" }

    $normalMAC = $MAC.ToUpper()
    $settings  = Get-Content $path -Raw | ConvertFrom-Json

    if ($settings.PSObject.Properties[$normalMAC]) {
        throw "Server '$normalMAC' already exists. Use Set-NDTServer to update it."
    }

    $entry = [ordered]@{ OS = $OS; Computername = $Computername }
    if ($PSBoundParameters.ContainsKey('IPAddress'))       { $entry.IPAddress       = $IPAddress }
    if ($PSBoundParameters.ContainsKey('LocalAdmin'))      { $entry.AdminPassword   = $LocalAdmin }
    if ($PSBoundParameters.ContainsKey('Sections'))        { $entry.Sections        = $Sections }
    if ($PSBoundParameters.ContainsKey('DeploymentSteps')) { $entry.DeploymentSteps = $DeploymentSteps }
    if ($PSBoundParameters.ContainsKey('Properties')) {
        foreach ($kv in $Properties.GetEnumerator()) { $entry[$kv.Key] = $kv.Value }
    }

    if ($PSCmdlet.ShouldProcess($normalMAC, 'Add server entry')) {
        $settings | Add-Member -MemberType NoteProperty -Name $normalMAC -Value ([PSCustomObject]$entry)
        $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        Write-Verbose "Added server '$normalMAC' ($Computername)."
    }
}

function Set-NDTServer {
    <#
    .SYNOPSIS
        Updates an existing server entry in CustomSettings.json.
        Only parameters that are explicitly supplied are changed.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER MAC
        MAC address of the server entry to update.
    .PARAMETER Properties
        Hashtable of arbitrary extra key-value pairs to set or add.
    .EXAMPLE
        Set-NDTServer -MAC '00:15:5D:02:56:01' -DeploymentSteps 'General Settings','SMC','SQL2025'
    .EXAMPLE
        Set-NDTServer -MAC '00:15:5D:02:56:01' -Properties @{ SQLServer = 'SQL2026' }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$MAC,
        [Parameter()]
        [string]$Computername,
        [Parameter()]
        [string]$OS,
        [Parameter()]
        [string]$IPAddress,
        [Parameter()]
        [string]$LocalAdmin,
        [Parameter()]
        [hashtable]$Sections,
        [Parameter()]
        [string[]]$DeploymentSteps,
        [Parameter()]
        [hashtable]$Properties
    )

    $path      = Join-Path $LocalPath 'Control\CustomSettings.json'
    if (-not (Test-Path $path)) { throw "CustomSettings.json not found at: $path" }

    $normalMAC = $MAC.ToUpper()
    $settings  = Get-Content $path -Raw | ConvertFrom-Json
    $entry     = $settings.PSObject.Properties[$normalMAC]

    if (-not $entry) { throw "Server '$normalMAC' not found in CustomSettings.json." }

    if ($PSCmdlet.ShouldProcess($normalMAC, 'Update server entry')) {
        if ($PSBoundParameters.ContainsKey('Computername'))   { $entry.Value.Computername   = $Computername }
        if ($PSBoundParameters.ContainsKey('OS'))             { $entry.Value.OS             = $OS }
        if ($PSBoundParameters.ContainsKey('IPAddress'))      { $entry.Value.IPAddress      = $IPAddress }
        if ($PSBoundParameters.ContainsKey('LocalAdmin'))     { $entry.Value.AdminPassword  = $LocalAdmin }
        if ($PSBoundParameters.ContainsKey('Sections'))       { $entry.Value.Sections       = $Sections }
        if ($PSBoundParameters.ContainsKey('DeploymentSteps')){ $entry.Value.DeploymentSteps = $DeploymentSteps }
        if ($PSBoundParameters.ContainsKey('Properties')) {
            foreach ($kv in $Properties.GetEnumerator()) {
                if ($entry.Value.PSObject.Properties[$kv.Key]) {
                    $entry.Value.PSObject.Properties[$kv.Key].Value = $kv.Value
                } else {
                    $entry.Value | Add-Member -MemberType NoteProperty -Name $kv.Key -Value $kv.Value
                }
            }
        }
        $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        Write-Verbose "Updated server '$normalMAC'."
    }
}

function Remove-NDTServer {
    <#
    .SYNOPSIS
        Removes a server entry from CustomSettings.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER MAC
        MAC address of the server entry to remove.
    .EXAMPLE
        Remove-NDTServer -MAC '00:15:5D:02:56:01'
    .EXAMPLE
        Get-NDTServer -Computername srv02 | Remove-NDTServer
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$MAC
    )

    $path      = Join-Path $LocalPath 'Control\CustomSettings.json'
    if (-not (Test-Path $path)) { throw "CustomSettings.json not found at: $path" }

    $normalMAC = $MAC.ToUpper()
    $settings  = Get-Content $path -Raw | ConvertFrom-Json

    if (-not $settings.PSObject.Properties[$normalMAC]) {
        throw "Server '$normalMAC' not found in CustomSettings.json."
    }

    if ($PSCmdlet.ShouldProcess($normalMAC, 'Remove server entry')) {
        $settings.PSObject.Properties.Remove($normalMAC)
        $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        Write-Verbose "Removed server '$normalMAC'."
    }
}

#endregion

#region ── OS management (OS.json) ───────────────────────────────────────────

function Get-NDTOs {
    <#
    .SYNOPSIS
        Retrieves OS entries from OS.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER Key
        Return only the entry with this key.
    .EXAMPLE
        Get-NDTOs
    .EXAMPLE
        Get-NDTOs -Key WIN2025DCG
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Key
    )

    $path = Join-Path $LocalPath 'Control\OS.json'
    if (-not (Test-Path $path)) { throw "OS.json not found at: $path" }

    $catalog = Get-Content $path -Raw | ConvertFrom-Json

    $entries = $catalog.PSObject.Properties | ForEach-Object {
        [PSCustomObject]@{
            Key   = $_.Name
            Path  = $_.Value.Path
            Index = $_.Value.Index
        }
    }

    if ($Key) { $entries = $entries | Where-Object { $_.Key -eq $Key } }

    $entries
}

function Add-NDTOs {
    <#
    .SYNOPSIS
        Adds a new OS entry to OS.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER Key
        Unique key for this OS entry (e.g. WIN2025DCG).
    .PARAMETER Path
        Share-relative path to the WIM file (backslash-rooted).
    .PARAMETER Index
        WIM image index to apply.
    .EXAMPLE
        Add-NDTOs -Key WIN2025DCG -Path 'Operating Systems\ref-w2025dcg\w2025dcg.wim' -Index 1
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter(Mandatory)]
        [string]$Key,
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [int]$Index
    )

    $osPath = Join-Path $LocalPath 'Control\OS.json'
    if (-not (Test-Path $osPath)) { throw "OS.json not found at: $osPath" }

    $catalog = Get-Content $osPath -Raw | ConvertFrom-Json

    if ($catalog.PSObject.Properties[$Key]) {
        throw "OS key '$Key' already exists. Use Set-NDTOs to update it."
    }

    if ($PSCmdlet.ShouldProcess($Key, 'Add OS entry')) {
        $catalog | Add-Member -MemberType NoteProperty -Name $Key -Value ([PSCustomObject]@{ Path = $Path; Index = $Index })
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -Path $osPath -Encoding UTF8
        Write-Verbose "Added OS '$Key'."
    }
}

function Set-NDTOs {
    <#
    .SYNOPSIS
        Updates the Path and/or Index of an existing OS entry in OS.json.
        Only parameters that are explicitly supplied are changed.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER Key
        Key of the OS entry to update.
    .PARAMETER Path
        New share-relative WIM path.
    .PARAMETER Index
        New WIM image index.
    .EXAMPLE
        Set-NDTOs -Key WIN2025DCG -Index 2
    .EXAMPLE
        Get-NDTOs -Key WIN2025DCG | Set-NDTOs -Path 'Operating Systems\new\install.wim' -Index 1
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Key,
        [Parameter()]
        [string]$Path,
        [Parameter()]
        [int]$Index
    )

    $osPath = Join-Path $LocalPath 'Control\OS.json'
    if (-not (Test-Path $osPath)) { throw "OS.json not found at: $osPath" }

    $catalog = Get-Content $osPath -Raw | ConvertFrom-Json
    $entry   = $catalog.PSObject.Properties[$Key]

    if (-not $entry) { throw "OS key '$Key' not found in OS.json." }

    if ($PSCmdlet.ShouldProcess($Key, 'Update OS entry')) {
        if ($PSBoundParameters.ContainsKey('Path'))  { $entry.Value.Path  = $Path }
        if ($PSBoundParameters.ContainsKey('Index')) { $entry.Value.Index = $Index }
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -Path $osPath -Encoding UTF8
        Write-Verbose "Updated OS '$Key'."
    }
}

function Remove-NDTOs {
    <#
    .SYNOPSIS
        Removes an OS entry from OS.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER Key
        Key of the OS entry to remove.
    .EXAMPLE
        Remove-NDTOs -Key WIN2025DCG
    .EXAMPLE
        Get-NDTOs | Where-Object Index -eq 3 | Remove-NDTOs
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$Key
    )

    $osPath = Join-Path $LocalPath 'Control\OS.json'
    if (-not (Test-Path $osPath)) { throw "OS.json not found at: $osPath" }

    $catalog = Get-Content $osPath -Raw | ConvertFrom-Json

    if (-not $catalog.PSObject.Properties[$Key]) {
        throw "OS key '$Key' not found in OS.json."
    }

    if ($PSCmdlet.ShouldProcess($Key, 'Remove OS entry')) {
        $catalog.PSObject.Properties.Remove($Key)
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -Path $osPath -Encoding UTF8
        Write-Verbose "Removed OS '$Key'."
    }
}

#endregion

#region ── Reference image management ────────────────────────────────────────

function Move-NDTReferenceImage {
    <#
    .SYNOPSIS
        Moves captured reference WIM files from \Reference into \Operating Systems\.

    .DESCRIPTION
        For every *.wim found directly inside the Reference folder the function:
          1. Derives the destination folder name from the WIM stem
             (e.g. 'ref-w2025dcg.wim' -> folder 'ref-w2025dcg').
          2. Strips the 'ref-' prefix from the stem to form the destination file name
             (e.g. 'ref-w2025dcg' -> 'w2025dcg.wim').
          3. Creates 'Operating Systems\<stem>\' if it does not exist.
          4. Moves the WIM to 'Operating Systems\<stem>\<name-without-prefix>.wim',
             removing it from the Reference folder.

        Example:
          Reference\ref-w2025dcg.wim
          -> Operating Systems\ref-w2025dcg\w2025dcg.wim

    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026

    .PARAMETER Force
        Overwrite the destination WIM if it already exists.

    .EXAMPLE
        Move-NDTReferenceImage

    .EXAMPLE
        Move-NDTReferenceImage -WhatIf

    .EXAMPLE
        Move-NDTReferenceImage -LocalPath D:\Deploy2026
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026'
    )

    $refDir = Join-Path $LocalPath 'Reference'
    $osDir  = Join-Path $LocalPath 'Operating Systems'

    if (-not (Test-Path $refDir)) {
        throw "Reference folder not found: $refDir"
    }

    $wims = Get-ChildItem -Path $refDir -Filter '*.wim' -File
    if (-not $wims) {
        Write-Warning "No WIM files found in: $refDir"
        return
    } else  {
        Write-Host "Found $($wims.Count) WIM(s) in Reference folder:" -ForegroundColor Cyan
        foreach ($wim in $wims) {
            Write-Host "  $($wim.Name)" -ForegroundColor Gray
        }
    }

    foreach ($wim in $wims) {
        $stem      = $wim.BaseName                          # e.g. ref-w2025dcg
        $destName  = $stem -replace '^ref-', ''             # e.g. w2025dcg
        $destDir   = Join-Path $osDir $stem                 # e.g. Operating Systems\ref-w2025dcg
        $destFile  = Join-Path $destDir "$destName.wim"     # e.g. ...\w2025dcg.wim

        $relDest = $destFile.Replace($LocalPath + '\', '')
        Write-Host "  Source : $($wim.FullName)" -ForegroundColor Gray
        Write-Host "  Dest   : $relDest" -ForegroundColor Gray
        if (Test-Path $destFile) {
            Write-Host "  Status : destination exists — overwriting" -ForegroundColor Yellow
        } else {
            Write-Host "  Status : new file" -ForegroundColor Gray
        }

        if ($PSCmdlet.ShouldProcess($destFile, "Move reference WIM '$($wim.Name)'")) {
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                Write-Host "  Created folder: $destDir" -ForegroundColor Gray
            }
            Move-Item -Path $wim.FullName -Destination $destFile -Force
            Write-Host "  [OK] $($wim.Name) -> $relDest (moved)" -ForegroundColor Green
        }
    }
}

#endregion
