function Remove-NDTBootstrapArtefact {
    # Private helper (not exported). NDT runs from the PSGallery module install,
    # never from the share, so the module copy and publish helper that ship inside
    # the repo ZIP are bootstrap-only artefacts - remove them from a live share.
    # install\NDTMonitor is intentionally KEPT (Install-NDTMonitor deploys its site
    # content from there).
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$LocalPath
    )

    $installDir = Join-Path $LocalPath 'install'
    foreach ($artefact in @((Join-Path $installDir 'NDT'), (Join-Path $installDir 'Publish-NDT.ps1'))) {
        if (Test-Path $artefact) {
            if ($PSCmdlet.ShouldProcess($artefact, 'Remove bootstrap-only artefact from share')) {
                Remove-Item -Path $artefact -Recurse -Force -ErrorAction SilentlyContinue
                Write-Verbose "  Removed bootstrap artefact: $artefact"
            }
        }
    }
}

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
        Default: \\<current hostname FQDN>\Deploy2026

    .PARAMETER DeployUsername
        Domain account used by clients to connect to the deployment share.
        Mandatory  -  you will be prompted if not supplied.

    .PARAMETER DeployPassword
        Password for the deploy account as a SecureString. Stored in CustomSettings.json.
        Mandatory  -  you will be prompted if not supplied.

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
        [string]$ShareUNC = "\\$([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName)\Deploy2026",
        [Parameter(Mandatory)]
        [string]$DeployUsername,
        [Parameter(Mandatory)]
        [SecureString]$DeployPassword,
        [Parameter()]
        [string]$RepoZipUrl = 'https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit/archive/refs/heads/main.zip',
        [Parameter()]
        [int]$MonitorPort = 443,
        [Parameter()]
        [string]$CertificatePath,
        [Parameter()]
        [SecureString]$CertificatePassword,
        [Parameter()]
        [switch]$SkipMonitor
    )
    #region -- Download and extract repository ZIP into LocalPath ----------------
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

            # Remove all .gitkeep placeholder files used to preserve empty folders in git
            Get-ChildItem -Path $LocalPath -Filter '.gitkeep' -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    Write-Verbose "  Removed .gitkeep: $($_.FullName)"
                }

            # Ensure mandatory share folders exist (git does not track empty directories)
            $mandatoryFolders = @('Operating Systems', 'Reference', 'Scratch')
            foreach ($folder in $mandatoryFolders) {
                $folderPath = Join-Path $LocalPath $folder
                if (-not (Test-Path $folderPath)) {
                    New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
                    Write-Verbose "  Created mandatory folder: $folder"
                }
            }
        }
    } finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    #endregion

    #region -- Stamp Deploy section of Sections.json with parameters -------------
    $controlDir   = Join-Path $LocalPath 'Control'
    $sectionsDest = Join-Path $controlDir 'Sections.json'

    if (-not (Test-Path $sectionsDest)) {
        Write-Warning "Sections.json not found at '$sectionsDest' - skipping stamp."
    } else {
        if ($PSCmdlet.ShouldProcess($sectionsDest, 'Stamp Deploy section')) {
            # Decode the SecureString to plain text only long enough to write the file.
            $bstr          = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($DeployPassword)
            $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

            $settings = Get-Content $sectionsDest -Raw | ConvertFrom-Json
            $settings.Deploy.Share    = $ShareUNC
            $settings.Deploy.Username = $DeployUsername
            $settings.Deploy.Password = $plainPassword

            # Derive the monitor URL from the share host so clients reach it the same
            # way they reach the share (e.g. \\ndt01\Deploy2026 -> https://ndt01:443).
            $shareHost = ($ShareUNC.TrimStart('\') -split '\\')[0]
            $monitorUrl = "https://${shareHost}:$MonitorPort"
            if ($settings.Deploy.PSObject.Properties.Name -contains 'MonitorUrl') {
                $settings.Deploy.MonitorUrl = $monitorUrl
            } else {
                $settings.Deploy | Add-Member -NotePropertyName MonitorUrl -NotePropertyValue $monitorUrl
            }

            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $sectionsDest -Encoding UTF8
            Write-Verbose 'Deploy section stamped in Sections.json.'

            $plainPassword = $null
        }
    }
    #endregion

    #region -- SMB share ---------------------------------------------------------
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

    #region -- Share permissions -------------------------------------------------
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

    #region -- NDT Monitor (IIS progress web service) ----------------------------
    if ($SkipMonitor) {
        Write-Verbose 'NDT Monitor installation skipped (-SkipMonitor).'
    } else {
        $monitorParams = @{ LocalPath = $LocalPath; Port = $MonitorPort }
        if ($PSBoundParameters.ContainsKey('CertificatePath'))   { $monitorParams['CertificatePath']   = $CertificatePath }
        if ($PSBoundParameters.ContainsKey('CertificatePassword')) { $monitorParams['CertificatePassword'] = $CertificatePassword }
        try {
            Install-NDTMonitor @monitorParams
        } catch {
            Write-Warning "NDT Monitor installation failed: $_"
            Write-Warning 'The deployment share is still usable. Re-run Install-NDTMonitor to retry.'
        }
    }
    #endregion

    #region -- Clean up bootstrap-only artefacts from the share ------------------
    Remove-NDTBootstrapArtefact -LocalPath $LocalPath
    #endregion

    Write-Host "NDT deployment share installed successfully." -ForegroundColor Green
    Write-Host "  Local path : $LocalPath"
    Write-Host "  Share      : \\$(hostname)\$ShareName"
    Write-Host "  UNC (ref)  : $ShareUNC"
    Write-Host "  Deploy user: $DeployUsername"
    Write-Host ""
    Write-Host "Edit Control\CustomSettings.json to match your environment before deploying." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Build the WinPE boot image (WIM and optionally ISO):" -ForegroundColor White
    Write-Host "       New-NDTPEImage" -ForegroundColor Gray
    Write-Host "     This requires the Windows ADK and WinPE Add-on to be installed." -ForegroundColor Gray
    Write-Host "     The resulting Boot\boot2026.wim is registered automatically in WDS." -ForegroundColor Gray
    Write-Host "     Use -SkipISO if you only need a WDS-served WIM (no ISO file)." -ForegroundColor Gray
    Write-Host "     Use -SkipWDS if WDS is not yet configured on this server." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Import operating system images (WIM files):" -ForegroundColor White
    Write-Host "       Add-NDTOs -Key WIN2025DCG -Path 'Operating Systems\<folder>\install.wim' -Index 1" -ForegroundColor Gray
    Write-Host "     Place WIM files under $LocalPath\Operating Systems\" -ForegroundColor Gray
    Write-Host "     Use Get-NDTOs to list registered entries and Set-NDTOs to update them." -ForegroundColor Gray
    Write-Host "     If you captured a reference image, use Move-NDTReferenceImage to move it" -ForegroundColor Gray
    Write-Host "     from the Reference\ folder into Operating Systems\ automatically." -ForegroundColor Gray
    Write-Host ""
    Write-Host "  NOTE: Certain files are not included in the repository and must be added" -ForegroundColor Yellow
    Write-Host "        manually to the deployment share after installation. Examples:" -ForegroundColor Yellow
    Write-Host "          - Certificate files (.pfx, .cer) used by application installers" -ForegroundColor Yellow
    Write-Host "          - WIM files for operating systems and reference images" -ForegroundColor Yellow
    Write-Host "          - Licensed or third-party application installers" -ForegroundColor Yellow
    Write-Host "          - Site-specific content under Applications2026\" -ForegroundColor Yellow
}

function Update-NDT {
    <#
    .SYNOPSIS
        Upgrades an existing NDT deployment share to the latest code without
        touching its live configuration or data.

    .DESCRIPTION
        Refreshes the code of an already-installed NDT deployment share by
        downloading the repository ZIP from GitHub and copying it over the
        existing LocalPath, while PRESERVING everything that is site-specific:

          * Control\*.json  -  per-machine settings, sections, and the stamped
            Deploy credentials are never overwritten. New control files that a
            newer version introduces are added, but existing files are left as-is.
          * Operating Systems\, Reference\, Scratch\, Applications2026\, Logs\,
            Boot\boot2026.wim, and all *.wim / *.pfx / *.cer files are gitignored
            and therefore absent from the repo ZIP, so they are preserved
            automatically.

        Unlike Install-NDT, this command does NOT re-stamp credentials, create
        the SMB share, or change share permissions  -  those already exist. It is
        the safe, repeatable way to roll out new script/module versions to a
        server that is already in production.

        A timestamped backup of Control\ and install\ is taken before any change
        (skip with -NoBackup).

    .PARAMETER LocalPath
        Root of the existing NDT deployment share to upgrade.
        Default: C:\Deploy2026

    .PARAMETER RepoZipUrl
        URL of the GitHub repository archive ZIP to upgrade from.
        Default: https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit/archive/refs/heads/main.zip

    .PARAMETER BackupPath
        Folder to write the pre-upgrade backup to.
        Default: <LocalPath>\Backup\ndt-upgrade-<timestamp>

    .PARAMETER NoBackup
        Skip the pre-upgrade backup of Control\ and install\.

    .PARAMETER UpdateMonitor
        Also re-deploy the NDT Monitor site code (runs Install-NDTMonitor). The
        monitor's PFX certificate and log data are preserved. Omit if you do not
        want to touch the running IIS site.

    .PARAMETER Preserve
        Additional top-level folder names to protect from being overwritten
        (e.g. 'Applications' if you keep site-customised installers there).
        Control is always preserved.

    .EXAMPLE
        Update-NDT

    .EXAMPLE
        Update-NDT -WhatIf

    .EXAMPLE
        Update-NDT -LocalPath D:\Deploy2026 -UpdateMonitor -Verbose

    .EXAMPLE
        Update-NDT -Preserve 'Applications' -RepoZipUrl 'https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit/archive/refs/heads/dev.zip'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter()]
        [string]$RepoZipUrl = 'https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit/archive/refs/heads/main.zip',
        [Parameter()]
        [string]$BackupPath,
        [Parameter()]
        [switch]$NoBackup,
        [Parameter()]
        [switch]$UpdateMonitor,
        [Parameter()]
        [string[]]$Preserve
    )

    #region -- Pre-flight: must be an existing NDT install -----------------------
    $controlDir   = Join-Path $LocalPath 'Control'
    $sectionsDest = Join-Path $controlDir 'Sections.json'
    if (-not (Test-Path $sectionsDest)) {
        throw "No existing NDT installation found at '$LocalPath' (Control\Sections.json is missing). Use Install-NDT for a fresh install."
    }

    # Top-level items that must never be overwritten. Control holds customised
    # JSON (per-machine settings, sections, and the stamped Deploy credentials).
    # Everything else that is site-specific is gitignored and thus not present in
    # the repo ZIP, so it is preserved automatically.
    $preserveItems = @('Control') + ($Preserve | Where-Object { $_ })
    #endregion

    #region -- Backup ------------------------------------------------------------
    if (-not $NoBackup) {
        if (-not $BackupPath) {
            $stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
            $BackupPath = Join-Path $LocalPath "Backup\ndt-upgrade-$stamp"
        }
        if ($PSCmdlet.ShouldProcess($BackupPath, 'Back up Control and install before upgrade')) {
            New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
            Copy-Item -Path $controlDir -Destination (Join-Path $BackupPath 'Control') -Recurse -Force
            $installDir = Join-Path $LocalPath 'install'
            if (Test-Path $installDir) {
                Copy-Item -Path $installDir -Destination (Join-Path $BackupPath 'install') -Recurse -Force
            }
            Write-Host "Backup created: $BackupPath" -ForegroundColor Green
        }
    }
    #endregion

    #region -- Download and extract repository ZIP -------------------------------
    $tempZip = Join-Path $env:TEMP 'ndt-repo-update.zip'
    $tempDir = Join-Path $env:TEMP 'ndt-repo-update'

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

        # GitHub archive ZIPs always extract into a single top-level folder.
        $repoRoot = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1 -ExpandProperty FullName
        if (-not $repoRoot) { throw 'Could not locate repository root in the downloaded ZIP.' }
        Write-Verbose "  Repository root: $repoRoot"

        if ($PSCmdlet.ShouldProcess($LocalPath, 'Apply upgrade (refresh code, preserve config)')) {
            # Artefacts that belong only in the source repo and must not land on a
            # live deployment share.
            $repoOnlyItems = @('.github', '.vscode', '.gitignore', 'README.md')

            foreach ($item in (Get-ChildItem -Path $repoRoot -Force)) {
                if ($repoOnlyItems -contains $item.Name) { continue }

                if ($preserveItems -contains $item.Name) {
                    # Preserve existing config. For a preserved folder, still copy in
                    # any NEW files a newer version introduced (add-only), but never
                    # overwrite files that already exist on the live share.
                    if ($item.PSIsContainer) {
                        $destSub = Join-Path $LocalPath $item.Name
                        foreach ($child in (Get-ChildItem -Path $item.FullName -Recurse -File -Force)) {
                            $rel       = $child.FullName.Substring($item.FullName.Length).TrimStart('\')
                            $destChild = Join-Path $destSub $rel
                            if (-not (Test-Path $destChild)) {
                                $destChildDir = Split-Path $destChild -Parent
                                if (-not (Test-Path $destChildDir)) {
                                    New-Item -ItemType Directory -Path $destChildDir -Force | Out-Null
                                }
                                Copy-Item -Path $child.FullName -Destination $destChild -Force
                                Write-Host "  [NEW] $($item.Name)\$rel (added; existing config preserved)" -ForegroundColor Green
                            }
                        }
                    }
                    Write-Verbose "  Preserved: $($item.Name)"
                    continue
                }

                # Code item: overwrite in place.
                Copy-Item -Path $item.FullName -Destination $LocalPath -Recurse -Force
                Write-Verbose "  Updated: $($item.Name)"
            }

            # Belt-and-braces: strip repo-only artefacts if any slipped in.
            foreach ($item in $repoOnlyItems) {
                $itemPath = Join-Path $LocalPath $item
                if (Test-Path $itemPath) {
                    Remove-Item -Path $itemPath -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Verbose "  Removed repo-only item: $item"
                }
            }

            # Remove .gitkeep placeholders that only exist to keep empty folders in git.
            Get-ChildItem -Path $LocalPath -Filter '.gitkeep' -Recurse -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    Write-Verbose "  Removed .gitkeep: $($_.FullName)"
                }

            Write-Host 'Code refreshed (Control configuration preserved).' -ForegroundColor Green
        }
    } finally {
        if (Test-Path $tempZip) { Remove-Item $tempZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    #endregion

    #region -- Optionally refresh the NDT Monitor site code ----------------------
    if ($UpdateMonitor) {
        Write-Host "`nRefreshing NDT Monitor site code..." -ForegroundColor Cyan
        try {
            Install-NDTMonitor -LocalPath $LocalPath
        } catch {
            Write-Warning "NDT Monitor refresh failed: $_"
            Write-Warning 'The upgraded share is still usable. Re-run Install-NDTMonitor to retry.'
        }
    }
    #endregion

    #region -- Clean up bootstrap-only artefacts from the share ------------------
    Remove-NDTBootstrapArtefact -LocalPath $LocalPath
    #endregion

    Write-Host "`nNDT upgrade complete." -ForegroundColor Green
    Write-Host "  Local path : $LocalPath"
    if (-not $NoBackup) { Write-Host "  Backup     : $BackupPath" }
    Write-Host ''
    Write-Host 'Post-upgrade notes:' -ForegroundColor Cyan
    Write-Host '  * The NDT module itself updates from PSGallery, not the share:' -ForegroundColor White
    Write-Host '      Update-Module NDT' -ForegroundColor Gray
    Write-Host '  * If WinPE scripts changed, rebuild the boot image:' -ForegroundColor White
    Write-Host '      New-NDTPEImage' -ForegroundColor Gray
    if (-not $UpdateMonitor) {
        Write-Host '  * To push updated NDT Monitor code to IIS, re-run with -UpdateMonitor' -ForegroundColor White
        Write-Host '    (or run Install-NDTMonitor). The certificate and logs are preserved.' -ForegroundColor Gray
    }
}

function Install-NDTMonitor {
    <#
    .SYNOPSIS
        Installs the NDT deployment-progress web service in IIS (idempotent).

    .DESCRIPTION
        Provisions an IIS-hosted REST endpoint that receives deployment progress
        updates from each deploying machine (WinPE phase and the post-image step
        engine) - the NDT equivalent of the MDT monitoring web service.

        The function is fully idempotent and performs the following steps:
          1. Installs the required IIS roles/features (Web-Server, ASP.NET 4.x,
             ISAPI, management + scripting tools). Install-WindowsFeature skips
             anything already present.
          2. Creates the progress-log folder.
          3. Deploys the site content (web.config, App_Code\ProgressHandler.cs,
             Default.htm dashboard) from install\NDTMonitor into the site path,
             stamping the real log-folder path into web.config.
          4. Resolves and imports the PFX certificate that matches this host's FQDN
             (by file name, subject CN, or SAN) into LocalMachine\My (idempotent
             by thumbprint). No self-signed certificate is ever generated.
          5. Creates / updates a dedicated application pool (.NET v4.0, Integrated).
          6. Removes the IIS Default Web Site, then creates / updates the monitor
             website: HTTPS on the requested port when a certificate was found,
             otherwise plain HTTP on port 80.
          7. Grants the app-pool identity Modify rights on the log folder.
          8. Opens the inbound firewall port.
          9. Starts the app pool and website.

        Endpoints (served on https://<host>:<Port>, or http://<host>:80 with no cert):
          POST /progress          receive a progress update (JSON body)
          GET  /progress          all machine states as a JSON array
          GET  /progress?mac=..   a single machine's latest state
          GET  /                  live HTML dashboard (Default.htm)

    .PARAMETER LocalPath
        Root of the NDT deployment share (source of the site content).
        Default: C:\Deploy2026

    .PARAMETER Port
        TCP port the monitor website listens on. Default: 443

    .PARAMETER SitePath
        Physical path for the IIS site. Default: C:\inetpub\ndtmonitor

    .PARAMETER LogRoot
        Folder where per-machine progress JSON is stored.
        Default: <LocalPath>\Logs\progress

    .PARAMETER SiteName
        IIS website name. Default: NDTMonitor

    .PARAMETER AppPoolName
        IIS application pool name. Default: NDTMonitor

    .PARAMETER CertificatePath
        Path to a PFX certificate file to bind to the HTTPS site. If omitted, a PFX
        matching this host's FQDN (by file name, subject CN, or SAN) is located in
        <LocalPath>\install\NDTMonitor. If none is found the site is published over
        plain HTTP on port 80 (no self-signed certificate is ever generated).

    .PARAMETER CertificatePassword
        Password for the PFX certificate as a SecureString.
        If not supplied, uses the standard NDT Monitor certificate password.

    .EXAMPLE
        Install-NDTMonitor

    .EXAMPLE
        Install-NDTMonitor -Port 8443 -Verbose
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter()]
        [int]$Port = 443,
        [Parameter()]
        [string]$SitePath = 'C:\inetpub\ndtmonitor',
        [Parameter()]
        [string]$LogRoot,
        [Parameter()]
        [string]$SiteName = 'NDTMonitor',
        [Parameter()]
        [string]$AppPoolName = 'NDTMonitor',
        [Parameter()]
        [string]$CertificatePath,
        [Parameter()]
        [SecureString]$CertificatePassword = (ConvertTo-SecureString '1q2w3e4r' -AsPlainText -Force)
    )

    # -- Verify Administrator ----------------------------------------------------
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Install-NDTMonitor must be run as Administrator.' }

    # -- Ensure Windows PowerShell 5.1 -------------------------------------------
    # The WebAdministration IIS: PSDrive provider does not work under PowerShell 7+.
    # When invoked from PS7 (e.g. by Install-NDT running in pwsh), relaunch this
    # command in Windows PowerShell 5.1 and return.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        Write-Host 'Install-NDTMonitor requires Windows PowerShell 5.1 (IIS provider) - relaunching under powershell.exe...' -ForegroundColor Yellow
        $ps5 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path $ps5)) { throw 'Windows PowerShell 5.1 (powershell.exe) not found - cannot install the IIS monitor.' }
        # Import the module from the location it is ACTUALLY loaded from ($PSScriptRoot -
        # the PSGallery install under Program Files\...\Modules\NDT). The module is never
        # required to live on the deployment share: the PS5 child imports it by full path,
        # so this works regardless of PSModulePath and whether the share holds any copy.
        $manifest = Join-Path $PSScriptRoot 'ndt.psd1'
        if (-not (Test-Path $manifest)) {
            throw "NDT module manifest not found at '$manifest'. Install the module from PSGallery (Install-Module NDT) and re-run."
        }

        $inner = "Import-Module '$manifest' -Force; Install-NDTMonitor -LocalPath '$LocalPath' -Port $Port -SitePath '$SitePath' -SiteName '$SiteName' -AppPoolName '$AppPoolName'"
        if ($PSBoundParameters.ContainsKey('LogRoot') -and $LogRoot) { $inner += " -LogRoot '$LogRoot'" }
        if ($CertificatePath) { $inner += " -CertificatePath '$CertificatePath'" }
        if ($CertificatePassword) {
            $bstr5 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($CertificatePassword)
            $plain5 = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr5)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr5)
            $inner += " -CertificatePassword (ConvertTo-SecureString '$plain5' -AsPlainText -Force)"
            $plain5 = $null
        }
        if ($VerbosePreference -eq 'Continue') { $inner += ' -Verbose' }

        & $ps5 -NoProfile -ExecutionPolicy Bypass -Command $inner
        if ($LASTEXITCODE -ne 0) { Write-Warning "Windows PowerShell 5.1 monitor install exited with code $LASTEXITCODE." }
        return
    }

    if (-not $LogRoot) { $LogRoot = Join-Path $LocalPath 'Logs\progress' }
    $sourceDir = Join-Path $LocalPath 'install\NDTMonitor'
    if (-not (Test-Path $sourceDir)) {
        throw "NDT Monitor source content not found at: $sourceDir"
    }

    # -- Resolve the certificate for THIS host -----------------------------------
    # Never generate a self-signed certificate (modern browsers reject them). When
    # no explicit -CertificatePath is supplied, locate a PFX that matches the local
    # FQDN: first the conventional <fqdn>.pfx, then any *.pfx whose subject CN or
    # SAN (Subject Alternative Name) covers the local FQDN. If none is found the
    # site is published over plain HTTP (port 80) instead of HTTPS.
    $localFqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    if (-not $CertificatePath) {
        $candidate = Join-Path $sourceDir "$localFqdn.pfx"
        if (Test-Path $candidate) {
            $CertificatePath = $candidate
        } else {
            foreach ($pfx in (Get-ChildItem -Path $sourceDir -Filter '*.pfx' -File -ErrorAction SilentlyContinue)) {
                try {
                    $probe = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                        $pfx.FullName, $CertificatePassword,
                        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
                } catch { continue }

                $certNames = @()
                if ($probe.Subject -match 'CN=([^,]+)') { $certNames += $Matches[1].Trim() }
                $sanExt = $probe.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
                if ($sanExt) {
                    foreach ($m in [regex]::Matches($sanExt.Format($false), 'DNS Name=([^,]+)')) {
                        $certNames += $m.Groups[1].Value.Trim()
                    }
                }
                $probe.Dispose()

                if ($certNames -contains $localFqdn) {
                    $CertificatePath = $pfx.FullName
                    Write-Verbose "Matched certificate '$($pfx.Name)' to local FQDN '$localFqdn' (subject/SAN)."
                    break
                }
            }
        }
    }

    if ($CertificatePath -and (Test-Path $CertificatePath)) {
        Write-Verbose "Using certificate: $CertificatePath"
    } else {
        Write-Warning "No certificate found for '$localFqdn' in $sourceDir - the monitor will be published over plain HTTP (port 80)."
        $CertificatePath = $null
    }

    Write-Host "`nInstalling NDT Monitor (IIS)..." -ForegroundColor Cyan

    # -- Step 1: Install IIS roles/features (idempotent) -------------------------
    Write-Host 'Step 1: Ensuring IIS roles and features...' -ForegroundColor Cyan
    $features = @(
        'Web-Server',
        'Web-Common-Http',
        'Web-Static-Content',
        'Web-Default-Doc',
        'Web-Http-Errors',
        'Web-Net-Ext45',
        'Web-Asp-Net45',
        'Web-ISAPI-Ext',
        'Web-ISAPI-Filter',
        'Web-Mgmt-Console',
        'Web-Scripting-Tools'
    )
    if ($PSCmdlet.ShouldProcess('IIS', "Install features: $($features -join ', ')")) {
        # Install-WindowsFeature is inherently idempotent - installed features are skipped.
        $result = Install-WindowsFeature -Name $features -IncludeManagementTools -ErrorAction Stop
        if ($result.RestartNeeded -eq 'Yes') {
            Write-Warning '  A restart is required to complete IIS feature installation.'
        }
        Write-Host '  [OK] IIS features present' -ForegroundColor Green
    }

    Import-Module WebAdministration -ErrorAction Stop

    # -- Step 2: Create the progress-log folder ----------------------------------
    Write-Host 'Step 2: Ensuring progress-log folder...' -ForegroundColor Cyan
    if (-not (Test-Path $LogRoot)) {
        New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
        Write-Host "  [OK] Created: $LogRoot" -ForegroundColor Green
    } else {
        Write-Host "  [OK] Exists: $LogRoot" -ForegroundColor Gray
    }

    # -- Step 3: Deploy site content ---------------------------------------------
    Write-Host 'Step 3: Deploying site content...' -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($SitePath, 'Deploy NDT Monitor site content')) {
        if (-not (Test-Path $SitePath)) { New-Item -ItemType Directory -Path $SitePath -Force | Out-Null }

        # Copy App_Code, Default.htm and web.config (overwrite = idempotent).
        Copy-Item -Path (Join-Path $sourceDir '*') -Destination $SitePath -Recurse -Force

        # Stamp the real LogRoot into the deployed web.config appSetting.
        $webConfig = Join-Path $SitePath 'web.config'
        $xml = [xml](Get-Content $webConfig -Raw)
        $node = $xml.configuration.appSettings.add | Where-Object { $_.key -eq 'LogRoot' }
        if ($node) {
            $node.value = $LogRoot
        } else {
            $add = $xml.CreateElement('add')
            $add.SetAttribute('key', 'LogRoot')
            $add.SetAttribute('value', $LogRoot)
            $xml.configuration.appSettings.AppendChild($add) | Out-Null
        }
        $xml.Save($webConfig)
        Write-Host "  [OK] Content deployed to $SitePath (LogRoot -> $LogRoot)" -ForegroundColor Green
    }

    # -- Step 4: Import SSL certificate ------------------------------------------
    Write-Host 'Step 4: Importing SSL certificate...' -ForegroundColor Cyan
    $thumbprint = $null
    if (-not $CertificatePath) {
        Write-Host '  [--] No certificate resolved - skipping (HTTP fallback)' -ForegroundColor Yellow
    } elseif ($PSCmdlet.ShouldProcess($CertificatePath, 'Import PFX certificate into LocalMachine\My store')) {
        # Read the thumbprint from the PFX without importing first so the import is idempotent.
        $certObj = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $CertificatePath,
            $CertificatePassword,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
        )
        $thumbprint = $certObj.Thumbprint
        $certObj.Dispose()

        $existingCert = Get-ChildItem Cert:\LocalMachine\My |
            Where-Object { $_.Thumbprint -eq $thumbprint } |
            Select-Object -First 1

        if ($existingCert) {
            Write-Host "  [OK] Certificate already in store (thumbprint: $thumbprint)" -ForegroundColor Gray
        } else {
            Import-PfxCertificate -FilePath $CertificatePath `
                -Password $CertificatePassword `
                -CertStoreLocation Cert:\LocalMachine\My | Out-Null
            Write-Host "  [OK] Certificate imported (thumbprint: $thumbprint)" -ForegroundColor Green
        }
    }

    # -- Step 5: Application pool -------------------------------------------------
    Write-Host 'Step 5: Configuring application pool...' -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($AppPoolName, 'Create/update IIS application pool')) {
        if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
            New-WebAppPool -Name $AppPoolName | Out-Null
            Write-Host "  [OK] Created app pool: $AppPoolName" -ForegroundColor Green
        } else {
            Write-Host "  [OK] App pool exists: $AppPoolName" -ForegroundColor Gray
        }
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name managedRuntimeVersion -Value 'v4.0'
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name managedPipelineMode  -Value 'Integrated'
        Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name startMode            -Value 'AlwaysRunning'
    }

    # -- Step 6: Website ----------------------------------------------------------
    # HTTPS on $Port when a certificate was resolved; otherwise plain HTTP on 80.
    if ($thumbprint) {
        $useHttps  = $true
        $sitePort  = $Port
        $siteProto = 'https'
    } else {
        $useHttps  = $false
        $sitePort  = 80
        $siteProto = 'http'
    }

    Write-Host "Step 6: Configuring website ($($siteProto.ToUpper()) port $sitePort)..." -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($SiteName, "Create/update website on port $sitePort ($($siteProto.ToUpper()))")) {
        # Stop the app pool before touching the site. On an idempotent redeploy
        # where the site was deleted but the pool left running, the old worker
        # process retains a mapping to the now-deleted site root and ASP.NET
        # throws "Failed to map the path '/'". Stopping it first (and recycling
        # in Step 9) forces a clean reload of the freshly-created site config.
        if ((Get-WebAppPoolState -Name $AppPoolName -ErrorAction SilentlyContinue).Value -eq 'Started') {
            Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
            Write-Host '  [OK] Stopped app pool for reconfiguration' -ForegroundColor Gray
        }

        # Always remove the IIS Default Web Site so it never shadows our bindings
        # (and never squats on port 80 when we fall back to HTTP).
        $defaultSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
        if ($defaultSite) {
            Remove-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
            Write-Host '  [OK] Removed IIS Default Web Site' -ForegroundColor Green
        }

        $existingSite = Get-Website -Name $SiteName -ErrorAction SilentlyContinue
        if (-not $existingSite) {
            New-Website -Name $SiteName -Port $sitePort -PhysicalPath $SitePath `
                -ApplicationPool $AppPoolName -Force | Out-Null
            Write-Host "  [OK] Created website: $SiteName" -ForegroundColor Green
        } else {
            Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath    -Value $SitePath
            Set-ItemProperty "IIS:\Sites\$SiteName" -Name applicationPool -Value $AppPoolName
            Write-Host "  [OK] Website updated: $SiteName" -ForegroundColor Green
        }

        # Reset bindings to exactly the one protocol/port we want (idempotent).
        Get-WebBinding -Name $SiteName -ErrorAction SilentlyContinue | Remove-WebBinding -ErrorAction SilentlyContinue

        if ($useHttps) {
            New-WebBinding -Name $SiteName -Protocol https -Port $sitePort -IPAddress '*' -SslFlags 0 | Out-Null
            Write-Host "  [OK] HTTPS binding added (port $sitePort)" -ForegroundColor Green

            # Bind the SSL certificate to the port (idempotent: replace only if it differs).
            $sslBind = Get-Item "IIS:\SslBindings\0.0.0.0!$sitePort" -ErrorAction SilentlyContinue
            if ($sslBind -and $sslBind.Thumbprint -eq $thumbprint) {
                Write-Host "  [OK] SSL certificate already bound (thumbprint: $thumbprint)" -ForegroundColor Gray
            } else {
                if ($sslBind) { Remove-Item "IIS:\SslBindings\0.0.0.0!$sitePort" -ErrorAction SilentlyContinue }
                $httpsWebBinding = Get-WebBinding -Name $SiteName -Protocol https |
                    Where-Object { $_.bindingInformation -like "*:${sitePort}:*" } |
                    Select-Object -First 1
                $httpsWebBinding.AddSslCertificate($thumbprint, 'MY')
                Write-Host "  [OK] SSL certificate bound (thumbprint: $thumbprint)" -ForegroundColor Green
            }
        } else {
            New-WebBinding -Name $SiteName -Protocol http -Port $sitePort -IPAddress '*' | Out-Null
            Write-Host "  [OK] HTTP binding added (port $sitePort) - no certificate available" -ForegroundColor Yellow
        }
    }

    # -- Step 7: Grant app-pool identity write access to the log folder ----------
    Write-Host 'Step 7: Granting log-folder permissions...' -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($LogRoot, "Grant Modify to IIS AppPool\$AppPoolName")) {
        # icacls re-grant is idempotent (updates the existing ACE).
        icacls $LogRoot /grant "IIS AppPool\${AppPoolName}:(OI)(CI)M" /T /C | Out-Null
        Write-Host "  [OK] Modify granted to 'IIS AppPool\$AppPoolName'" -ForegroundColor Green
    }

    # -- Step 8: Firewall rule (idempotent) --------------------------------------
    Write-Host 'Step 8: Ensuring firewall rule...' -ForegroundColor Cyan
    $ruleName = "NDT Monitor $sitePort"
    if ($PSCmdlet.ShouldProcess($ruleName, 'Create inbound firewall rule')) {
        $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if (-not $existingRule) {
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
                -Protocol TCP -LocalPort $sitePort | Out-Null
            Write-Host "  [OK] Firewall rule created: $ruleName" -ForegroundColor Green
        } else {
            Write-Host "  [OK] Firewall rule exists: $ruleName" -ForegroundColor Gray
        }
    }

    # -- Step 9: Start app pool + site -------------------------------------------
    Write-Host 'Step 9: Starting monitor...' -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($SiteName, 'Start app pool and website')) {
        # Recycle (never just "start if stopped") so the worker always loads the
        # current site config. This prevents a stale worker from a previously
        # deleted site causing "Failed to map the path '/'" on redeploy.
        if ((Get-WebAppPoolState -Name $AppPoolName).Value -eq 'Started') {
            Restart-WebAppPool -Name $AppPoolName
        } else {
            Start-WebAppPool -Name $AppPoolName
        }
        if ((Get-WebsiteState -Name $SiteName).Value -ne 'Started') {
            Start-Website -Name $SiteName
        }
        Write-Host '  [OK] Monitor started (app pool recycled)' -ForegroundColor Green
    }

    $hostName = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    Write-Host "`nNDT Monitor installed." -ForegroundColor Green
    Write-Host "  Dashboard : ${siteProto}://${hostName}:$sitePort/" -ForegroundColor White
    Write-Host "  Endpoint  : ${siteProto}://${hostName}:$sitePort/progress" -ForegroundColor White
    Write-Host "  Log folder: $LogRoot" -ForegroundColor Gray
}

function New-NDTPEImage {
    <#
    .SYNOPSIS
        Builds the NDT WinPE boot WIM and optionally a bootable ISO.

    .DESCRIPTION
        Performs the full PE media build pipeline:
          1. Generates settings.json from the Deploy section of CustomSettings.json
             and writes it into the WindowsPE\Deploy folder.
          2. Creates a fresh WinPE staging tree from the ADK base using copype
             (always builds clean  -  never patches an existing WIM).
          3. Mounts the staging boot.wim with DISM.
          4. Adds required WinPE optional packages in dependency order:
             WinPE-WMI, WinPE-NetFx, WinPE-Scripting, WinPE-PowerShell,
             WinPE-StorageWMI, WinPE-DismCmdlets.
          5. Injects the Deploy folder (install.ps1 + settings.json) and
             Unattend.xml (wpeinit + install.ps1 autorun) into the mounted image.
          6. Commits the WIM and copies it to Boot\boot2026.wim.
          7. Updates the WDS boot image (unless -SkipWDS is specified).
          8. Creates two bootable ISOs (unless -SkipISO is specified):
               - Boot\boot2026.iso      : hybrid BIOS/EFI via MakeWinPEMedia
                 (Gen 1 VMs and reference-image capture; press-any-key prompt).
               - Boot\boot2026-uefi.iso : UEFI-only, no-prompt via oscdimg with
                 efisys_noprompt.bin (Gen 2 VMs; boots unattended, no keypress).

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

    .PARAMETER RegisterOnly
        Skip the full PE build (Steps 1-6) and register the existing Boot\boot2026.wim
        directly in WDS. Implies -SkipISO. Use this when the WIM is already built and
        only the WDS boot-image registration needs to be refreshed.

    .PARAMETER DeploySection
        Name of the top-level key in Sections.json to read share credentials from.
        Default: Deploy. Use this when the NDT server being built uses an alternate
        deploy section (e.g. DeployDC01).

    .EXAMPLE
        New-NDTPEImage

    .EXAMPLE
        New-NDTPEImage -SkipISO -Verbose

    .EXAMPLE
        New-NDTPEImage -LocalPath D:\Deploy2026 -SkipWDS

    .EXAMPLE
        New-NDTPEImage -RegisterOnly
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
        [switch]$SkipISO,

        [Parameter()]
        [switch]$RegisterOnly,

        [Parameter()]
        [string]$DeploySection = 'Deploy'
    )

    # -- Verify Administrator ----------------------------------------------------
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'New-NDTPEImage must be run as Administrator.' }

    # -- Pre-flight: verify WDS is configured (skip if -SkipWDS) ----------------
    if (-not $SkipWDS) {
        # Two-stage check:
        #   1. Service exists  -  the WDS role is installed.
        #   2. wdsutil /get-server exit code  -  0 means WDS is initialized and configured;
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
  3. Then re-run: New-NDTPEImage

To skip WDS and build the WIM only:
    New-NDTPEImage -SkipWDS
'@
        }
    }

    # -- Resolve paths -----------------------------------------------------------
    $wimFile        = Join-Path $LocalPath 'Boot\boot2026.wim'
    $isoFile        = Join-Path $LocalPath 'Boot\boot2026.iso'
    $isoFileUefi    = Join-Path $LocalPath 'Boot\boot2026-uefi.iso'
    $sectionsPath   = Join-Path $LocalPath 'Control\Sections.json'
    $winPEScriptDir = Join-Path $LocalPath 'Scripts\unattend2026\WindowsPE'
    $deploySource       = Join-Path $winPEScriptDir 'Deploy'
    $unattendSource     = Join-Path $winPEScriptDir 'Unattend.xml'

    # -- Locate Windows ADK ------------------------------------------------------
    $adkRoot    = $null
    $adkRegPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots'
    if (Test-Path $adkRegPath) {
        $kitsRoot = (Get-ItemProperty -Path $adkRegPath -Name 'KitsRoot10' -ErrorAction SilentlyContinue).KitsRoot10
        if ($kitsRoot) { $adkRoot = Join-Path $kitsRoot 'Assessment and Deployment Kit' }
    }
    if (-not $adkRoot -or -not (Test-Path $adkRoot)) {
        $adkRoot = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit'
    }

    if (-not $RegisterOnly) {
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
    } else {
        if (-not (Test-Path $wimFile)) {
            throw "RegisterOnly: boot WIM not found at: $wimFile  -  run New-NDTPEImage first."
        }
        Write-Host 'RegisterOnly: skipping build (Steps 1-6), using existing boot2026.wim.' -ForegroundColor Yellow
    }

    try {
        if (-not $RegisterOnly) {
        # -- Pre-flight: exclude the mount + staging trees from Defender ---------
        # Microsoft Defender real-time scanning of the files DISM writes into the
        # mount tree is the usual cause of unmount error 0xc1420117 (open handle).
        # Add best-effort path exclusions; never fail the build if Defender is not
        # manageable on this host.
        foreach ($excl in @($MountDir, $IsoStagingDir)) {
            try { Add-MpPreference -ExclusionPath $excl -ErrorAction Stop }
            catch { Write-Verbose "  Could not add Defender exclusion for '$excl': $_" }
        }

        # -- Step 1: Generate settings.json -------------------------------------
        Write-Host 'Step 1: Generating settings.json...' -ForegroundColor Cyan

        if (-not (Test-Path $sectionsPath)) {
            throw "Sections.json not found at: $sectionsPath"
        }

        $sections = Get-Content -Path $sectionsPath -Raw | ConvertFrom-Json
        if (-not $sections.$DeploySection) { throw "Deploy section '$DeploySection' not found in Sections.json." }

        $deployCfg = $sections.$DeploySection
        $settingsObj = [ordered]@{
            Share    = $deployCfg.Share
            Username = $deployCfg.Username
            Password = $deployCfg.Password
        }

        # settings.json is injected directly into the WIM in Step 5  -  the source-folder
        # copy (Scripts\unattend2026\WindowsPE\Deploy\settings.json) is intentionally
        # NOT modified so it stays as a safe placeholder in source control.
        Write-Host '  [OK] settings.json prepared (will be written into WIM in Step 5)' -ForegroundColor Green
        Write-Host "  Deploy section : $DeploySection" -ForegroundColor Gray
        Write-Host "  Share          : $($settingsObj.Share)" -ForegroundColor Gray
        Write-Host "  Username       : $($settingsObj.Username)" -ForegroundColor Gray

        # -- Step 2: Create fresh WinPE staging tree with copype -----------------
        # Always build from the clean ADK base  -  never patch an existing WIM.
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

        # -- Step 3: Mount the fresh base WIM ------------------------------------
        Write-Host "`nStep 3: Mounting base WIM..." -ForegroundColor Cyan

        if (-not (Test-Path $MountDir)) {
            New-Item -Path $MountDir -ItemType Directory -Force | Out-Null
        }

        # Pre-flight cleanup: a previous run may have failed to unmount (0xc1420117)
        # and left a stale image mounted at $MountDir, which would make the mount
        # below fail. Clear any orphaned mount points, discard a mount still bound to
        # this dir, and ensure the directory is empty before mounting.
        dism /Cleanup-Mountpoints 2>&1 | Out-Null
        $stale = dism /Get-MountedWimInfo 2>&1 | Select-String -SimpleMatch $MountDir
        if ($stale) {
            Write-Warning "  Stale WIM mount found at $MountDir - discarding before remount..."
            dism /Unmount-Wim /MountDir:"$MountDir" /Discard 2>&1 | Out-Null
            dism /Cleanup-Mountpoints 2>&1 | Out-Null
        }
        if (Get-ChildItem -Path $MountDir -Force -ErrorAction SilentlyContinue) {
            Remove-Item -Path (Join-Path $MountDir '*') -Recurse -Force -ErrorAction SilentlyContinue
        }

        if ($PSCmdlet.ShouldProcess($MountDir, 'Mount staging boot.wim')) {
            dism /Mount-Wim /WimFile:"$stagingBootWim" /Index:1 /MountDir:"$MountDir"
            if ($LASTEXITCODE -ne 0) { throw "DISM mount failed (exit $LASTEXITCODE)" }
            Write-Host "  [OK] WIM mounted at: $MountDir" -ForegroundColor Green
        }

        # -- Step 4: Add required WinPE optional packages -------------------------
        # WinPE-WMI         -  WMI (prerequisite for PowerShell)
        # WinPE-NetFx       -  .NET Framework (prerequisite for PowerShell)
        # WinPE-Scripting   -  scripting support (prerequisite for PowerShell)
        # WinPE-PowerShell  -  powershell.exe in WinPE
        # WinPE-StorageWMI  -  storage management via WMI
        # WinPE-DismCmdlets -  DISM PowerShell cmdlets
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

        # -- Step 5: Inject Deploy folder and Unattend.xml -----------------------
        Write-Host "`nStep 5: Injecting Deploy folder into WIM..." -ForegroundColor Cyan

        if ($PSCmdlet.ShouldProcess($MountDir, 'Inject Deploy folder and Unattend.xml')) {
            $wimDeployDir = Join-Path $MountDir 'Deploy'
            if (-not (Test-Path $wimDeployDir)) {
                New-Item -Path $wimDeployDir -ItemType Directory -Force | Out-Null
            }

            foreach ($file in (Get-ChildItem -Path $deploySource -File)) {
                if ($file.Name -eq 'settings.json') {
                    # Skip  -  settings.json is written fresh from CustomSettings.json below
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
            #   Window 1 (this cmd)  -  free debug shell, Z: already mapped
            #   Window 2             -  the running install.ps1
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

            # Generate winpeshl.ini  -  controls what winpeshl.exe runs at PE boot.
            #
            # [LaunchApps] lists what to execute.  startnet.cmd is NOT run when
            # winpeshl.ini is present, so wpeinit must be called from StartDeploy.cmd
            # (which it is).
            #
            # Note: 'DebugShell=Yes' is MDT-specific (requires bddrun.exe) and is NOT
            # a standard WinPE winpeshl.ini option  -  do not add it here.
            $winpeshlContent = @'
[LaunchApps]
%SYSTEMDRIVE%\Deploy\StartDeploy.cmd
'@
            $winpeshlDest = Join-Path $MountDir 'Windows\System32\winpeshl.ini'
            Set-Content -Path $winpeshlDest -Value $winpeshlContent -Encoding ASCII
            Write-Host '  [OK] winpeshl.ini generated -> Windows\System32\winpeshl.ini' -ForegroundColor Gray

            # startnet.cmd fallback  -  only executed when winpeshl.ini is absent.
            # Write a minimal version so that if winpeshl.ini were ever missing the
            # machine still initialises the network; without this it would hang silently.
            $startnetContent = "@echo off`r`nwpeinit`r`n"
            $startnetDest    = Join-Path $MountDir 'Windows\System32\startnet.cmd'
            Set-Content -Path $startnetDest -Value $startnetContent -Encoding ASCII
            Write-Host '  [OK] startnet.cmd (fallback) -> Windows\System32\startnet.cmd' -ForegroundColor Gray

            # Unattend.xml at WIM root  -  display settings only.
            # RunSynchronous is NOT used here; winpeshl.ini is the launcher.
            $unattendDest = Join-Path $MountDir 'Unattend.xml'
            if (Test-Path $unattendSource) {
                Copy-Item -Path $unattendSource -Destination $unattendDest -Force
                Write-Host '  [OK] Unattend.xml -> X:\Unattend.xml (WIM root)' -ForegroundColor Gray
            } else {
                Write-Warning "Unattend.xml not found at: $unattendSource"
            }
        }

        # -- Step 6: Commit WIM and copy to Boot\boot2026.wim --------------------
        Write-Host "`nStep 6: Committing WIM..." -ForegroundColor Cyan

        if ($PSCmdlet.ShouldProcess($MountDir, 'Commit and unmount WIM')) {
            # DISM unmount fails with 0xc1420117 when any process still holds a handle
            # inside the mount directory (antivirus/Search indexer scanning the files
            # just written in Step 5, an open Explorer window, or a lingering .NET
            # file handle). Move the session's working directory out of the mount tree,
            # force a GC to release managed handles, then retry the commit a few times.
            if ((Get-Location).Path -like "$MountDir*") { Set-Location $LocalPath }
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()

            $maxAttempts   = 5
            $unmountCommit = $false
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                dism /Unmount-Wim /MountDir:"$MountDir" /Commit
                if ($LASTEXITCODE -eq 0) { $unmountCommit = $true; break }

                if ($attempt -lt $maxAttempts) {
                    Write-Warning "  Unmount attempt $attempt failed (exit $LASTEXITCODE, likely an open handle) - retrying in 10s..."
                    Start-Sleep -Seconds 10
                }
            }
            if (-not $unmountCommit) {
                throw "DISM unmount/commit failed after $maxAttempts attempts (exit $LASTEXITCODE). Close any Explorer window, antivirus scan, or process using '$MountDir' and re-run."
            }
            Write-Host '  [OK] WIM committed and unmounted' -ForegroundColor Green

            $bootDir = Split-Path $wimFile -Parent
            if (-not (Test-Path $bootDir)) { New-Item -Path $bootDir -ItemType Directory -Force | Out-Null }
            Copy-Item -Path $stagingBootWim -Destination $wimFile -Force
            Write-Host "  [OK] boot2026.wim updated: $wimFile" -ForegroundColor Green
        }
        } # end -not RegisterOnly

        # -- Step 7: Update WDS --------------------------------------------------
        if (-not $SkipWDS) {
            Write-Host "`nStep 7: Updating WDS..." -ForegroundColor Cyan

            if ($PSCmdlet.ShouldProcess('WDSServer', 'Stop service, replace boot image, start service')) {
                $wdsImageName = 'NDT PE Boot 2026'
                $wimLeaf      = Split-Path $wimFile -Leaf

                # -- Find existing image name via wdsutil output (service must be running) --
                # Get-WdsBootImage is unreliable for FileName matching; parse wdsutil text
                # output instead to get the exact registered display name.
                Write-Host '  Checking for existing boot image...' -ForegroundColor Gray
                $existingImageName = $null
                $wdsRawOutput = (wdsutil /Get-AllImages /ImageType:Boot 2>&1) -join "`n"
                # Each image block starts with "    Image Name:"; split on that boundary.
                foreach ($block in ($wdsRawOutput -split '(?m)(?=^ {4}Image Name:)')) {
                    if ($block -match '(?m)^ {4,}File Name:\s*(\S+)' -and $Matches[1].Trim() -eq $wimLeaf) {
                        if ($block -match '(?m)^ {4}Image Name:\s*(.+)') {
                            $existingImageName = $Matches[1].Trim()
                        }
                    }
                }

                if ($existingImageName) {
                    Write-Host "  Found existing boot image: '$existingImageName' - removing database entry..." -ForegroundColor Gray
                    wdsutil /Remove-Image /Image:"$existingImageName" /ImageType:Boot /Architecture:x64 2>&1 | Out-Null
                } else {
                    Write-Host '  No existing database entry found for this WIM.' -ForegroundColor Gray
                }

                Write-Host '  Stopping WDS service...' -ForegroundColor Gray
                Stop-Service WDSServer -Force
                Write-Host '  [OK] WDS stopped' -ForegroundColor Gray

                # -- Delete physical WIM from WDS image store --------------------------
                # wdsutil /Add-Image copies the WIM to RemoteInstall\Boot\x64\Images\.
                # If that file already exists (even after a Remove-Image) it fails 0x50.
                # Read the RemoteInstall path from the registry; fall back to the default.
                $wdsRoot = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\WDSServer\Parameters' `
                    -Name RootDirectory -ErrorAction SilentlyContinue).RootDirectory
                if (-not $wdsRoot) { $wdsRoot = 'C:\RemoteInstall' }
                $physicalWim = Join-Path $wdsRoot "Boot\x64\Images\$wimLeaf"
                if (Test-Path $physicalWim) {
                    Remove-Item $physicalWim -Force
                    Write-Host "  Deleted physical WIM from store: $physicalWim" -ForegroundColor Gray
                }

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

        # -- Step 8: Create bootable ISOs ----------------------------------------
        if (-not $SkipISO -and -not $RegisterOnly) {
            Write-Host "`nStep 8: Creating bootable ISOs..." -ForegroundColor Cyan

            if ($PSCmdlet.ShouldProcess($isoFile, 'Build Gen 1 hybrid and Gen 2 UEFI no-prompt ISOs')) {
                # -- 8a: Hybrid BIOS/EFI ISO (Gen 1 + reference-image capture) ----
                # MakeWinPEMedia builds a hybrid ISO whose EFI boot sector
                # (efisys.bin) prompts "Press any key to boot from CD". Fine for
                # interactive Gen 1 boots, but the keypress blocks Gen 2 automation.
                if (Test-Path $isoFile) { Remove-Item -Path $isoFile -Force }

                cmd.exe /c "cd /d `"$winPERoot`" && MakeWinPEMedia.cmd /iso `"$IsoStagingDir`" `"$isoFile`""
                if ($LASTEXITCODE -ne 0) { throw "MakeWinPEMedia.cmd failed (exit $LASTEXITCODE)" }
                Write-Host "  [OK] Gen 1 ISO created: $isoFile" -ForegroundColor Green

                # -- 8b: UEFI-only no-prompt ISO (Gen 2 automation) ---------------
                # Hyper-V Gen 2 is UEFI-only. efisys_noprompt.bin skips the
                # "Press any key to boot from CD" prompt so an unattended Gen 2 VM
                # boots straight into WinPE. Built with oscdimg because
                # MakeWinPEMedia always uses the prompting efisys.bin.
                if (Test-Path $isoFileUefi) { Remove-Item -Path $isoFileUefi -Force }

                $noPromptEfi = Join-Path $env:OSCDImgRoot 'efisys_noprompt.bin'
                if (-not (Test-Path $noPromptEfi)) {
                    throw "efisys_noprompt.bin not found at: $noPromptEfi"
                }
                $oscdimgExe = Join-Path $env:OSCDImgRoot 'oscdimg.exe'
                $mediaRoot  = Join-Path $IsoStagingDir 'media'
                & $oscdimgExe -m -o -u2 -udfver102 "-bootdata:1#pEF,e,b$noPromptEfi" "$mediaRoot" "$isoFileUefi"
                if ($LASTEXITCODE -ne 0) { throw "oscdimg (UEFI no-prompt ISO) failed (exit $LASTEXITCODE)" }
                Write-Host "  [OK] Gen 2 ISO created: $isoFileUefi" -ForegroundColor Green

                Remove-Item -Path $IsoStagingDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host '  [OK] Staging directory cleaned up' -ForegroundColor Gray

                Write-Host ''
                Write-Host '  Gen 1 VM (hybrid ISO, press-any-key prompt):' -ForegroundColor Yellow
                Write-Host "    Set-VMDvdDrive -VMName '<vmname>' -Path '$isoFile'" -ForegroundColor Yellow
                Write-Host '  Gen 2 VM (UEFI no-prompt ISO, unattended):' -ForegroundColor Yellow
                Write-Host "    Set-VMDvdDrive -VMName '<vmname>' -Path '$isoFileUefi'" -ForegroundColor Yellow
            }
        } else {
            Write-Verbose 'Step 8: ISO creation skipped (-SkipISO).'
        }

        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host 'PE build complete!' -ForegroundColor Green
        Write-Host "========================================`n" -ForegroundColor Green

    } catch {
        Write-Error "New-NDTPEImage failed: $_"

        # Attempt to discard a still-mounted WIM. Move out of the mount tree and
        # release managed handles first; if the discard is refused (open handle),
        # fall back to Cleanup-Mountpoints to clear the stale mount registration.
        if (Test-Path $MountDir) {
            if ((Get-Location).Path -like "$MountDir*") { Set-Location $LocalPath }
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()

            Write-Warning 'Attempting to discard WIM mount...'
            dism /Unmount-Wim /MountDir:"$MountDir" /Discard 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'Discard failed - clearing stale mount points (dism /Cleanup-Mountpoints)...'
                dism /Cleanup-Mountpoints 2>&1 | Out-Null
            }
        }

        throw
    }
}

#region -- Computer management (CustomSettings.json) -------------------------

function Get-NDTComputer {
    <#
    .SYNOPSIS
        Retrieves computer entries from CustomSettings.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER MAC
        Return only the entry with this MAC address.
    .PARAMETER Computername
        Return only entries matching this computer name.
    .EXAMPLE
        Get-NDTComputer
    .EXAMPLE
        Get-NDTComputer -MAC '00:15:5D:02:56:01'
    .EXAMPLE
        Get-NDTComputer -Computername srv02
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

function Add-NDTComputer {
    <#
    .SYNOPSIS
        Adds a new computer entry to CustomSettings.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER MAC
        MAC address of the computer (colon-separated, any case).
    .PARAMETER Computername
        Target computer name.
    .PARAMETER OS
        OS key from OS.json to deploy.
    .PARAMETER IPAddress
        Static IP in CIDR notation (e.g. 10.0.3.22/24), or 'DHCP'.
    .PARAMETER DefaultGateway
        Default gateway IP. Overrides any value from the NetworkSettings section.
    .PARAMETER DNSServers
        DNS server IP(s), comma- or semicolon-separated. Overrides the NetworkSettings section.
    .PARAMETER LocalAdmin
        Local administrator password (stored as plain text in CustomSettings.json).
    .PARAMETER Sections
        Hashtable of section references, e.g. @{ Locale = 'Sweden'; ADSettings = 'ADJoinCorp' }
    .PARAMETER DeploymentGroups
        Ordered array of deployment group names from DeploymentGroups.json.
    .PARAMETER Properties
        Hashtable of arbitrary extra key-value pairs to include in the entry.
    .PARAMETER InputObject
        An existing entry (as returned by Get-NDTComputer) to clone. All of its
        values are copied to the new entry; any explicitly supplied parameter
        (e.g. -MAC, -Computername, -IPAddress) overrides the cloned value.
    .EXAMPLE
        Add-NDTComputer -MAC '00:15:5D:02:56:05' -Computername srv05 -OS WIN2025DCG `
            -IPAddress '10.0.3.25/24' -DeploymentGroups 'General Settings','SMC' `
            -Sections @{ Locale = 'Sweden'; NetworkSettings = 'NicAuto'; ADSettings = 'ADJoinCorp' }
    .EXAMPLE
        Get-NDTComputer -MAC '00:15:5D:02:40:1C' |
            Add-NDTComputer -MAC '00:15:5D:02:40:99' -Computername NDT03 -IPAddress '10.0.3.99/24'
        Clones the NDT01 entry into a new machine, replacing only the unique fields.
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Manual')]
    param (
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter(Mandatory)]
        [string]$MAC,
        [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Clone')]
        [psobject]$InputObject,
        [Parameter(Mandatory, ParameterSetName = 'Manual')]
        [Parameter(ParameterSetName = 'Clone')]
        [string]$Computername,
        [Parameter(Mandatory, ParameterSetName = 'Manual')]
        [Parameter(ParameterSetName = 'Clone')]
        [string]$OS,
        [Parameter()]
        [string]$IPAddress,
        [Parameter()]
        [string]$DefaultGateway,
        [Parameter()]
        [string]$DNSServers,
        [Parameter()]
        [string]$LocalAdmin,
        [Parameter()]
        [hashtable]$Sections,
        [Parameter()]
        [string[]]$DeploymentGroups,
        [Parameter()]
        [hashtable]$Properties
    )

    process {
        $path = Join-Path $LocalPath 'Control\CustomSettings.json'
        if (-not (Test-Path $path)) { throw "CustomSettings.json not found at: $path" }

        $normalMAC = $MAC.ToUpper()
        $settings  = Get-Content $path -Raw | ConvertFrom-Json

        if ($settings.PSObject.Properties[$normalMAC]) {
            throw "Computer '$normalMAC' already exists. Use Set-NDTComputer to update it."
        }

        $entry = [ordered]@{}
        if ($InputObject) {
            foreach ($prop in $InputObject.PSObject.Properties) {
                if ($prop.Name -eq 'MAC') { continue }   # MAC is the key, never a value
                $entry[$prop.Name] = $prop.Value
            }
        }
        if ($PSBoundParameters.ContainsKey('OS'))              { $entry.OS              = $OS }
        if ($PSBoundParameters.ContainsKey('Computername'))    { $entry.Computername    = $Computername }
        if ($PSBoundParameters.ContainsKey('IPAddress'))       { $entry.IPAddress       = $IPAddress }
        if ($PSBoundParameters.ContainsKey('DefaultGateway'))  { $entry.DefaultGateway  = $DefaultGateway }
        if ($PSBoundParameters.ContainsKey('DNSServers'))      { $entry.DNSServers      = $DNSServers }
        if ($PSBoundParameters.ContainsKey('LocalAdmin'))      { $entry.AdminPassword   = $LocalAdmin }
        if ($PSBoundParameters.ContainsKey('Sections'))        { $entry.Sections        = $Sections }
        if ($PSBoundParameters.ContainsKey('DeploymentGroups')) { $entry.DeploymentGroups = $DeploymentGroups }
        if ($PSBoundParameters.ContainsKey('Properties')) {
            foreach ($kv in $Properties.GetEnumerator()) { $entry[$kv.Key] = $kv.Value }
        }

        if ($PSCmdlet.ShouldProcess($normalMAC, 'Add computer entry')) {
            $settings | Add-Member -MemberType NoteProperty -Name $normalMAC -Value ([PSCustomObject]$entry)
            $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
            Write-Verbose "Added computer '$normalMAC' ($($entry.Computername))."
            Get-NDTComputer -LocalPath $LocalPath -MAC $normalMAC
        }
    }
}

function Set-NDTComputer {
    <#
    .SYNOPSIS
        Updates an existing computer entry in CustomSettings.json.
        Only parameters that are explicitly supplied are changed.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER MAC
        MAC address of the computer entry to update.
    .PARAMETER IPAddress
        Static IP in CIDR notation (e.g. 10.0.3.22/24), or 'DHCP'.
    .PARAMETER DefaultGateway
        Default gateway IP. Overrides any value from the NetworkSettings section.
    .PARAMETER DNSServers
        DNS server IP(s), comma- or semicolon-separated. Overrides the NetworkSettings section.
    .PARAMETER Properties
        Hashtable of arbitrary extra key-value pairs to set or add.
    .EXAMPLE
        Set-NDTComputer -MAC '00:15:5D:02:56:01' -DeploymentGroups 'General Settings','SMC','SQL2025'
    .EXAMPLE
        Set-NDTComputer -MAC '00:15:5D:02:56:01' -Properties @{ SQLServer = 'SQL2026' }
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
        [string]$DefaultGateway,
        [Parameter()]
        [string]$DNSServers,
        [Parameter()]
        [string]$LocalAdmin,
        [Parameter()]
        [hashtable]$Sections,
        [Parameter()]
        [string[]]$DeploymentGroups,
        [Parameter()]
        [hashtable]$Properties
    )

    $path      = Join-Path $LocalPath 'Control\CustomSettings.json'
    if (-not (Test-Path $path)) { throw "CustomSettings.json not found at: $path" }

    $normalMAC = $MAC.ToUpper()
    $settings  = Get-Content $path -Raw | ConvertFrom-Json
    $entry     = $settings.PSObject.Properties[$normalMAC]

    if (-not $entry) { throw "Computer '$normalMAC' not found in CustomSettings.json." }

    if ($PSCmdlet.ShouldProcess($normalMAC, 'Update computer entry')) {
        if ($PSBoundParameters.ContainsKey('Computername'))   { $entry.Value.Computername   = $Computername }
        if ($PSBoundParameters.ContainsKey('OS'))             { $entry.Value.OS             = $OS }
        if ($PSBoundParameters.ContainsKey('IPAddress'))      { $entry.Value.IPAddress      = $IPAddress }
        if ($PSBoundParameters.ContainsKey('LocalAdmin'))     { $entry.Value.AdminPassword  = $LocalAdmin }
        if ($PSBoundParameters.ContainsKey('Sections'))       { $entry.Value.Sections       = $Sections }
        if ($PSBoundParameters.ContainsKey('DeploymentGroups')){ $entry.Value.DeploymentGroups = $DeploymentGroups }
        if ($PSBoundParameters.ContainsKey('DefaultGateway')) {
            if ($entry.Value.PSObject.Properties['DefaultGateway']) { $entry.Value.DefaultGateway = $DefaultGateway }
            else { $entry.Value | Add-Member -MemberType NoteProperty -Name 'DefaultGateway' -Value $DefaultGateway }
        }
        if ($PSBoundParameters.ContainsKey('DNSServers')) {
            if ($entry.Value.PSObject.Properties['DNSServers']) { $entry.Value.DNSServers = $DNSServers }
            else { $entry.Value | Add-Member -MemberType NoteProperty -Name 'DNSServers' -Value $DNSServers }
        }
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
        Write-Verbose "Updated computer '$normalMAC'."
        Get-NDTComputer -LocalPath $LocalPath -MAC $normalMAC
    }
}

function Remove-NDTComputer {
    <#
    .SYNOPSIS
        Removes a computer entry from CustomSettings.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .PARAMETER MAC
        MAC address of the computer entry to remove.
    .EXAMPLE
        Remove-NDTComputer -MAC '00:15:5D:02:56:01'
    .EXAMPLE
        Get-NDTComputer -Computername srv02 | Remove-NDTComputer
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
        throw "Computer '$normalMAC' not found in CustomSettings.json."
    }

    if ($PSCmdlet.ShouldProcess($normalMAC, 'Remove computer entry')) {
        $settings.PSObject.Properties.Remove($normalMAC)
        $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
        Write-Verbose "Removed computer '$normalMAC'."
    }
}

#endregion

#region -- OS management (OS.json) -------------------------------------------

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
        Get-NDTOs -LocalPath $LocalPath -Key $Key
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
        Get-NDTOs -LocalPath $LocalPath -Key $Key
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

#region -- Reference image management ----------------------------------------

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
            Write-Host "  Status : destination exists  -  overwriting" -ForegroundColor Yellow
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

#region -- Deployment validation ---------------------------------------------

function Test-NDTDeployment {
    <#
    .SYNOPSIS
        Validates the entire deployment configuration for a given MAC address.
    .DESCRIPTION
        Performs a dry-run check of all configuration references for a specific machine:
          - MAC entry exists in CustomSettings.json
          - Required fields are present (Computername, OS, DeploymentGroups)
          - Each referenced section exists as a top-level key in CustomSettings.json
          - OS key exists in OS.json
          - WIM file exists on disk
          - Each DeploymentGroups group exists in DeploymentGroups.json
          - Each step's Reference key exists in DeploymentActions.json
          - Each script file referenced in DeploymentActions.json exists on disk
        No changes are made  -  this is a read-only validation.
        Returns \$true if all checks passed, \$false if any check failed.
    .PARAMETER MAC
        MAC address of the machine to validate (colon-separated, any case).
    .PARAMETER LocalPath
        Root of the NDT deployment share. Default: C:\Deploy2026
    .EXAMPLE
        Test-NDTDeployment -MAC '00:15:5D:03:9C:11'
    .EXAMPLE
        Test-NDTDeployment -MAC '00:15:5D:03:9C:11' -LocalPath D:\Deploy2026
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$MAC,
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026'
    )

    $script:checkErrors   = 0
    $script:checkWarnings = 0

    function Write-Check {
        param(
            [string]$Label,
            [bool]$Pass,
            [string]$Detail = '',
            [switch]$IsWarning
        )
        if ($Pass) {
            Write-Host "  [PASS] $Label" -ForegroundColor Green
            if ($Detail) { Write-Host "         $Detail" -ForegroundColor DarkGreen }
        } elseif ($IsWarning) {
            Write-Host "  [WARN] $Label" -ForegroundColor Yellow
            if ($Detail) { Write-Host "         $Detail" -ForegroundColor Yellow }
            $script:checkWarnings++
        } else {
            Write-Host "  [FAIL] $Label" -ForegroundColor Red
            if ($Detail) { Write-Host "         $Detail" -ForegroundColor Red }
            $script:checkErrors++
        }
    }

    $normalMAC = $MAC.ToUpper()
    Write-Host "`nNDT Deployment Validation: $normalMAC" -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor DarkGray

    # -- Control file paths ------------------------------------------------------
    $csPath = Join-Path $LocalPath 'Control\CustomSettings.json'
    $snPath = Join-Path $LocalPath 'Control\Sections.json'
    $djPath = Join-Path $LocalPath 'Control\DeploymentActions.json'
    $dgPath = Join-Path $LocalPath 'Control\DeploymentGroups.json'
    $osPath = Join-Path $LocalPath 'Control\OS.json'

    # -- [1] Control files -------------------------------------------------------
    Write-Host "`n[1] Control files" -ForegroundColor White
    $csOk = Test-Path $csPath; Write-Check 'CustomSettings.json'   $csOk $csPath
    $snOk = Test-Path $snPath; Write-Check 'Sections.json'         $snOk $snPath
    $djOk = Test-Path $djPath; Write-Check 'DeploymentActions.json'  $djOk $djPath
    $dgOk = Test-Path $dgPath; Write-Check 'DeploymentGroups.json'   $dgOk $dgPath
    $osOk = Test-Path $osPath; Write-Check 'OS.json'               $osOk $osPath

    if (-not ($csOk -and $snOk -and $djOk -and $dgOk -and $osOk)) {
        Write-Host "`n  One or more control files missing  -  cannot continue." -ForegroundColor Red
        Write-Host "`nResult: $($script:checkErrors) error(s), $($script:checkWarnings) warning(s)`n" -ForegroundColor Red
        return $false
    }

    $settings        = Get-Content $csPath -Raw | ConvertFrom-Json
    $sectionsCatalog = Get-Content $snPath -Raw | ConvertFrom-Json
    $deployment      = Get-Content $djPath -Raw | ConvertFrom-Json
    $groups          = Get-Content $dgPath -Raw | ConvertFrom-Json
    $osCatalog       = Get-Content $osPath -Raw | ConvertFrom-Json

    # -- [2] MAC entry -----------------------------------------------------------
    Write-Host "`n[2] Machine entry" -ForegroundColor White
    $machineEntry = $settings.PSObject.Properties[$normalMAC]
    Write-Check "MAC $normalMAC in CustomSettings.json" ([bool]$machineEntry)

    if (-not $machineEntry) {
        Write-Host "`n  MAC not found  -  cannot continue." -ForegroundColor Red
        Write-Host "`nResult: $($script:checkErrors) error(s), $($script:checkWarnings) warning(s)`n" -ForegroundColor Red
        return $false
    }

    $machine = $machineEntry.Value

    # -- [3] Required fields -----------------------------------------------------
    Write-Host "`n[3] Required fields" -ForegroundColor White
    Write-Check 'Computername'    ([bool]$machine.Computername)    $machine.Computername
    Write-Check 'OS'              ([bool]$machine.OS)               $machine.OS
    Write-Check 'AdminPassword'   ([bool]$machine.AdminPassword)   '(set)'
    Write-Check 'DeploymentGroups' ([bool]$machine.DeploymentGroups) ($machine.DeploymentGroups -join ', ')

    # -- [4] Sections ------------------------------------------------------------
    if ($machine.Sections) {
        Write-Host "`n[4] Sections" -ForegroundColor White
        foreach ($sectionProp in $machine.Sections.PSObject.Properties) {
            $sectionName = $sectionProp.Value
            $exists = [bool]$sectionsCatalog.PSObject.Properties[$sectionName]
            Write-Check "[$($sectionProp.Name)] '$sectionName'" $exists
        }
    }

    # -- [5] Operating system ----------------------------------------------------
    Write-Host "`n[5] Operating system" -ForegroundColor White
    $osKey = $machine.OS
    if ($osKey) {
        $osEntry = $osCatalog.PSObject.Properties[$osKey]
        Write-Check "Key '$osKey' in OS.json" ([bool]$osEntry)

        if ($osEntry) {
            $wimRelPath = $osEntry.Value.Path
            $wimIndex   = $osEntry.Value.Index
            $wimAbsPath = Join-Path $LocalPath $wimRelPath.TrimStart('\')
            Write-Check 'WIM file exists on disk' (Test-Path $wimAbsPath) "$wimRelPath  (index $wimIndex)"
        }
    }

    # -- [6] Deployment groups ---------------------------------------------------
    if ($machine.DeploymentGroups) {
        Write-Host "`n[6] Deployment groups" -ForegroundColor White
        $resolvedRefs = [System.Collections.Generic.List[string]]::new()

        foreach ($groupName in $machine.DeploymentGroups) {
            $groupEntry = $groups.PSObject.Properties[$groupName]
            Write-Check "Group '$groupName'" ([bool]$groupEntry)

            if ($groupEntry) {
                foreach ($stepProp in $groupEntry.Value.PSObject.Properties) {
                    $ref = $stepProp.Value.Reference
                    if ($ref -and -not $resolvedRefs.Contains($ref)) {
                        $resolvedRefs.Add($ref)
                    }
                }
            }
        }

        # -- [7] Action references -----------------------------------------------
        Write-Host "`n[7] Deployment action references" -ForegroundColor White
        foreach ($ref in $resolvedRefs) {
            $actionEntry = $deployment.PSObject.Properties[$ref]
            Write-Check "'$ref'" ([bool]$actionEntry)
        }

        # -- [8] Script files ----------------------------------------------------
        Write-Host "`n[8] Script files" -ForegroundColor White
        $anyScripts = $false
        foreach ($ref in $resolvedRefs) {
            $action = $deployment.PSObject.Properties[$ref]
            if (-not $action) { continue }
            $scriptRel = $action.Value.Script
            if (-not $scriptRel) { continue }
            $anyScripts = $true
            $scriptAbs  = Join-Path $LocalPath $scriptRel.TrimStart('\')
            Write-Check "'$ref'" (Test-Path $scriptAbs) $scriptRel
        }
        if (-not $anyScripts) {
            Write-Host '  (no Script actions in this machine-s steps)' -ForegroundColor DarkGray
        }
    }

    # -- Summary -----------------------------------------------------------------
    Write-Host "`n$('-' * 60)" -ForegroundColor DarkGray
    if ($script:checkErrors -eq 0 -and $script:checkWarnings -eq 0) {
        Write-Host 'Result: ALL CHECKS PASSED' -ForegroundColor Green
    } elseif ($script:checkErrors -eq 0) {
        Write-Host "Result: PASSED with $($script:checkWarnings) warning(s)" -ForegroundColor Yellow
    } else {
        Write-Host "Result: $($script:checkErrors) error(s), $($script:checkWarnings) warning(s)" -ForegroundColor Red
    }
    Write-Host ''

    return ($script:checkErrors -eq 0)
}

#endregion

#region -- Deployment monitoring ---------------------------------------------

function Watch-NDTDeployment {
    <#
    .SYNOPSIS
        Watches a machine's deployment progress via the NDT Monitor and waits
        until it reports 100% / Done.
    .DESCRIPTION
        Polls the NDT Monitor HTTP service (GET /progress?mac=..) for a single
        machine and renders a live progress bar plus a status line each time the
        state changes. Blocks until the machine reports Status 'Done' (or 100%),
        the optional timeout elapses, or you press Ctrl+C.

        The same progress data is written by install.ps1 (Phase 'WinPE') and
        Install-NDT.ps1 (Phase 'Windows') during deployment.

        Returns \$true when the deployment completes, \$false on timeout.
    .PARAMETER MAC
        MAC address of the machine to watch (colon- or dash-separated, any case).
    .PARAMETER MonitorUrl
        Base URL of the NDT Monitor (e.g. https://ndt01:443). If omitted, it is
        resolved from the Deploy section (MonitorUrl) of Control\Sections.json.
    .PARAMETER LocalPath
        Root of the NDT deployment share, used to locate Sections.json when
        MonitorUrl is not supplied. Default: C:\Deploy2026
    .PARAMETER PollSeconds
        Seconds between polls. Default: 5
    .PARAMETER TimeoutMinutes
        Give up after this many minutes. 0 (default) waits indefinitely.
    .PARAMETER SkipCertificateCheck
        Ignore TLS certificate validation (internal CA / self-signed monitor).
        Works on both Windows PowerShell 5.1 and PowerShell 7.
    .EXAMPLE
        Watch-NDTDeployment -MAC '00:15:5D:02:56:01'
    .EXAMPLE
        Watch-NDTDeployment -MAC '00:15:5D:02:56:01' -TimeoutMinutes 90 -SkipCertificateCheck
    .EXAMPLE
        Get-NDTComputer -Computername srv02 | Watch-NDTDeployment
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string]$MAC,
        [Parameter()]
        [string]$MonitorUrl,
        [Parameter()]
        [string]$LocalPath = 'C:\Deploy2026',
        [Parameter()]
        [int]$PollSeconds = 5,
        [Parameter()]
        [int]$TimeoutMinutes = 0,
        [Parameter()]
        [switch]$SkipCertificateCheck
    )

    process {
        $normalMAC = $MAC.ToUpper().Replace('-', ':')

        # Resolve MonitorUrl from the Deploy section of Sections.json if not supplied.
        if (-not $MonitorUrl) {
            $sectionsPath = Join-Path $LocalPath 'Control\Sections.json'
            if (Test-Path $sectionsPath) {
                try {
                    $sections = Get-Content $sectionsPath -Raw | ConvertFrom-Json
                    if ($sections.Deploy -and $sections.Deploy.MonitorUrl) {
                        $MonitorUrl = $sections.Deploy.MonitorUrl
                    }
                } catch {
                    # Fall through to the throw below.
                }
            }
        }
        if (-not $MonitorUrl) {
            throw "MonitorUrl not supplied and could not be resolved from Sections.json (Deploy.MonitorUrl)."
        }
        $MonitorUrl = $MonitorUrl.TrimEnd('/')

        # Windows PowerShell 5.1 Invoke-RestMethod has no -SkipCertificateCheck;
        # fall back to a per-process certificate validation callback there.
        $irmArgs      = @{}
        $prevCallback = $null
        $usedCallback = $false
        if ($SkipCertificateCheck) {
            if ($PSVersionTable.PSEdition -eq 'Core') {
                $irmArgs['SkipCertificateCheck'] = $true
            } else {
                $prevCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
                $usedCallback = $true
            }
        }

        $uri      = "$MonitorUrl/progress?mac=$normalMAC"
        $activity = "NDT deployment $normalMAC"
        Write-Host "Watching deployment: $normalMAC" -ForegroundColor Cyan
        Write-Host "Monitor: $uri" -ForegroundColor DarkGray

        $deadline = if ($TimeoutMinutes -gt 0) { (Get-Date).AddMinutes($TimeoutMinutes) } else { $null }
        $lastKey  = ''
        $final    = $null

        try {
            while ($true) {
                if ($deadline -and (Get-Date) -gt $deadline) {
                    Write-Progress -Activity $activity -Completed
                    Write-Warning "Timed out after $TimeoutMinutes minute(s) waiting for deployment to finish."
                    return $false
                }

                try {
                    $state = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10 -ErrorAction Stop @irmArgs
                } catch {
                    # 404 (no report yet) or transient network error - keep waiting.
                    $state = $null
                }

                if (-not $state -or -not $state.Status) {
                    Write-Progress -Activity $activity -Status 'Waiting for first progress report...' -PercentComplete 0
                } else {
                    $pct    = [int]$state.Percent
                    $status = [string]$state.Status
                    $phase  = [string]$state.Phase
                    $desc   = [string]$state.Description
                    $group  = [string]$state.Group

                    $line = "[$phase/$status] $pct%"
                    if ($group) { $line += "  $group" }
                    if ($desc)  { $line += " - $desc" }

                    $name = if ($state.Computername) { " ($($state.Computername))" } else { '' }
                    Write-Progress -Activity "$activity$name" -Status $line `
                        -PercentComplete ([Math]::Min(100, [Math]::Max(0, $pct)))

                    # Log to the console only when the state changes.
                    $key = "$status|$pct|$group|$desc"
                    if ($key -ne $lastKey) {
                        $color = switch ($status) {
                            'Done'      { 'Green' }
                            'Completed' { 'Green' }
                            'Failed'    { 'Red' }
                            'Paused'    { 'Yellow' }
                            'Rebooting' { 'Yellow' }
                            default     { 'Gray' }
                        }
                        Write-Host "  $(Get-Date -Format 'HH:mm:ss')  $line" -ForegroundColor $color
                        $lastKey = $key
                    }

                    if ($status -eq 'Done' -or $pct -ge 100) {
                        $final = $state
                        break
                    }
                }

                Start-Sleep -Seconds $PollSeconds
            }
        } finally {
            Write-Progress -Activity $activity -Completed
            if ($usedCallback) {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCallback
            }
        }

        $doneName = if ($final.Computername) { " ($($final.Computername))" } else { '' }
        Write-Host "`nDeployment complete: $normalMAC$doneName - 100%" -ForegroundColor Green
        return $true
    }
}

#endregion

# Backward-compatible alias for the former command name (Build- is not an
# approved verb under Windows PowerShell 5.1). Exported via ndt.psd1.
New-Alias -Name Build-NDTPEImage -Value New-NDTPEImage -Force -ErrorAction SilentlyContinue
