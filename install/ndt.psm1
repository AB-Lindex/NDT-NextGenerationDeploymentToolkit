function Install-NDT {
    <#
    .SYNOPSIS
        Installs and configures an NDT deployment share.

    .DESCRIPTION
        Creates the full NDT deployment share folder structure on the local machine,
        downloads the NDT repository ZIP from GitHub to obtain the seed control files
        (CustomSettings.json, Deployment.json, OS.json), stamps the Deploy section of
        CustomSettings.json with the supplied parameters, creates the Windows SMB share,
        and grants the deploy account the required permissions.

        No local 'source' folder is required — templates are always fetched fresh from
        the repository.

    .PARAMETER LocalPath
        Local filesystem path where the deployment share will be created.
        Default: C:\Deploy2026

    .PARAMETER ShareName
        Name of the Windows SMB share to create.
        Default: Deploy2026

    .PARAMETER ShareUNC
        Full UNC path used to access the deployment share (stored in CustomSettings.json).
        Default: \\dc01.corp.dev\Deploy2026

    .PARAMETER DeployUsername
        Domain account used by clients to connect to the deployment share.
        Default: Corp\Deploy2026

    .PARAMETER DeployPassword
        Password for the deploy account as a SecureString. Stored in CustomSettings.json.
        Default: the lab default converted to SecureString — replace for production use.

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
        [string]$ShareUNC = '\\dc01.corp.dev\Deploy2026',
        [Parameter()]
        [string]$DeployUsername = 'Corp\Deploy2026',
        [Parameter()]
        [SecureString]$DeployPassword, # Suggestion: P@ssw0rd2026
        [Parameter()]
        [string]$RepoZipUrl = 'https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit/archive/refs/heads/main.zip'
    )

    #region ── Folder structure ──────────────────────────────────────────────────
    $subFolders = @(
        'Applications',
        'Applications2026',
        'Boot',
        'Control',
        'MDT-Scripts',
        'Operating Systems',
        'Reference',
        'Scratch',
        'Scripts'
    )

    Write-Verbose "Creating deployment share folder structure under '$LocalPath'."
    foreach ($folder in $subFolders) {
        $target = Join-Path $LocalPath $folder
        if (-not (Test-Path $target)) {
            if ($PSCmdlet.ShouldProcess($target, 'Create directory')) {
                New-Item -ItemType Directory -Path $target -Force | Out-Null
                Write-Verbose "  Created: $target"
            }
        } else {
            Write-Verbose "  Exists:  $target"
        }
    }
    #endregion

    #region ── Download repo ZIP and extract seed control files ────────────────────
    $tempZip    = Join-Path $env:TEMP 'ndt-repo.zip'
    $tempDir    = Join-Path $env:TEMP 'ndt-repo'
    $sourceDir  = $null
    $controlDir = Join-Path $LocalPath 'Control'

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

        # Locate install\source inside the extracted archive.
        # Handles any branch/tag prefix (e.g. NDT-...-main\install\source).
        $sourceDir = Get-ChildItem -Path $tempDir -Recurse -Directory -Filter 'source' |
            Where-Object { $_.Parent.Name -eq 'install' } |
            Select-Object -First 1 -ExpandProperty FullName

        if (-not $sourceDir) {
            throw "Could not locate 'install\source' folder in the downloaded ZIP."
        }
        Write-Verbose "  Source files at: $sourceDir"
    } finally {
        # Remove the ZIP immediately; extracted dir is cleaned after files are copied.
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
    }
    #endregion

    #region ── Copy static reference files (Deployment.json, OS.json) ───────────
    $referenceFiles = @(
        'Deployment.json',
        'OS.json'
    )

    Write-Verbose "Copying reference control files from '$sourceDir' to '$controlDir'."
    foreach ($file in $referenceFiles) {
        $src  = Join-Path $sourceDir $file
        $dest = Join-Path $controlDir $file

        if (-not (Test-Path $src)) {
            Write-Warning "Source file not found, skipping: $src"
            continue
        }

        if ($PSCmdlet.ShouldProcess($dest, "Copy '$file'")) {
            Copy-Item -Path $src -Destination $dest -Force
            Write-Verbose "  Copied: $file"
        }
    }
    #endregion

    #region ── Generate CustomSettings.json from template + parameters ───────────
    $customSettingsSrc  = Join-Path $sourceDir  'CustomSettings.json'
    $customSettingsDest = Join-Path $controlDir 'CustomSettings.json'

    if (-not (Test-Path $customSettingsSrc)) {
        Write-Warning "Source CustomSettings.json not found at '$customSettingsSrc' — skipping."
    } else {
        if ($PSCmdlet.ShouldProcess($customSettingsDest, 'Generate CustomSettings.json')) {
            # Decode the SecureString to plain text only long enough to write the file.
            $bstr          = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($DeployPassword)
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

            # Load the template and overwrite the Deploy section with the supplied parameters.
            $settings = Get-Content $customSettingsSrc -Raw | ConvertFrom-Json

            $settings.Deploy.Share    = $ShareUNC
            $settings.Deploy.Username = $DeployUsername
            $settings.Deploy.Password = $plainPassword

            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $customSettingsDest -Encoding UTF8
            Write-Verbose "Generated CustomSettings.json with Deploy section stamped from parameters."

            # Wipe the plain-text copy from memory.
            $plainPassword = $null
        }
    }
    #endregion

    # Clean up the extracted repo temp directory.
    if ($null -ne $tempDir -and (Test-Path $tempDir)) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Verbose "  Cleaned up temp directory: $tempDir"
    }

    #region ── SMB share ─────────────────────────────────────────────────────────
    $existingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue

    if ($existingShare) {
        Write-Verbose "SMB share '$ShareName' already exists — skipping creation."
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

    # ── Resolve paths ───────────────────────────────────────────────────────────
    $wimFile            = Join-Path $LocalPath 'Boot\boot2026.wim'
    $isoFile            = Join-Path $LocalPath 'Boot\boot2026.iso'
    $customSettingsPath = Join-Path $LocalPath 'Control\CustomSettings.json'
    $winPEScriptDir     = Join-Path $LocalPath 'Scripts\unattend2026\WindowsPE'
    $deploySource       = Join-Path $winPEScriptDir 'Deploy'
    $unattendSource     = Join-Path $winPEScriptDir 'Unattend.xml'
    $settingsOutput     = Join-Path $deploySource  'settings.json'

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

        if (-not (Test-Path $deploySource)) {
            New-Item -Path $deploySource -ItemType Directory -Force | Out-Null
        }

        if ($PSCmdlet.ShouldProcess($settingsOutput, 'Write settings.json')) {
            $settingsObj | ConvertTo-Json | Set-Content -Path $settingsOutput -Encoding UTF8
            Write-Host '  [OK] settings.json written' -ForegroundColor Green
            Write-Verbose "  Share   : $($settingsObj.Share)"
            Write-Verbose "  Username: $($settingsObj.Username)"
        }

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
            $result = dism /Mount-Wim /WimFile:"$stagingBootWim" /Index:1 /MountDir:"$MountDir" 2>&1
            if ($LASTEXITCODE -ne 0) { throw "DISM mount failed: $result" }
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
                $result = dism /Image:"$MountDir" /Add-Package /PackagePath:"$cabPath" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "DISM Add-Package failed for ${pkg}: $result" }
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
                Copy-Item -Path $file.FullName -Destination $wimDeployDir -Force
                Write-Host "  [OK] Copied: $($file.Name)" -ForegroundColor Gray
            }

            # Inject startnet.cmd — contains only "wpeinit".
            # This is the fallback when NO winpeshl.ini is present, but we keep it
            # in place as a safety net.
            $startnetSource = Join-Path $winPEScriptDir 'startnet.cmd'
            $startnetDest   = Join-Path $MountDir 'Windows\System32\startnet.cmd'
            if (Test-Path $startnetSource) {
                Copy-Item -Path $startnetSource -Destination $startnetDest -Force
                Write-Host '  [OK] startnet.cmd -> Windows\System32\startnet.cmd' -ForegroundColor Gray
            } else {
                Write-Warning "startnet.cmd not found at: $startnetSource"
            }

            # Inject winpeshl.ini to Windows\System32\.
            # winpeshl.exe reads this and:
            #   - Intercepts F8 at startup -> drops to cmd.exe shell (debug)
            #   - Otherwise runs [LaunchApps] sequentially:
            #       1. wpeinit.exe  — DHCP, PnP (same role as MDT's bddrun.exe)
            #       2. StartDeploy.cmd — wpeutil WaitForNetwork -> install.ps1
            # MDT equivalent: bddrun.exe calls wpeinit internally then launches LiteTouch.wsf
            $winpeshlSource = Join-Path $winPEScriptDir 'winpeshl.ini'
            $winpeshlDest   = Join-Path $MountDir 'Windows\System32\winpeshl.ini'
            if (Test-Path $winpeshlSource) {
                Copy-Item -Path $winpeshlSource -Destination $winpeshlDest -Force
                Write-Host '  [OK] winpeshl.ini -> Windows\System32\winpeshl.ini' -ForegroundColor Gray
            } else {
                Write-Warning "winpeshl.ini not found at: $winpeshlSource"
            }

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
            $result = dism /Unmount-Wim /MountDir:"$MountDir" /Commit 2>&1
            if ($LASTEXITCODE -ne 0) { throw "DISM unmount/commit failed: $result" }
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
                Write-Host '  Stopping WDS service...' -ForegroundColor Gray
                Stop-Service WDSServer -Force
                Write-Host '  [OK] WDS stopped' -ForegroundColor Gray

                Write-Host '  Removing old boot image...' -ForegroundColor Gray
                wdsutil /Remove-Image /Image:"PE Boot 2026" /ImageType:Boot /Architecture:x64 /Filename:"boot2026.wim" 2>&1 | Out-Null

                Write-Host '  Adding new boot image...' -ForegroundColor Gray
                $result = wdsutil /Verbose /Add-Image /ImageFile:"$wimFile" /ImageType:Boot /Name:"PE Boot 2026" 2>&1
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
