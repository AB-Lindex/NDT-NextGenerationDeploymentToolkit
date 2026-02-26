function Install-NDT {
    <#
    .SYNOPSIS
        Installs and configures an NDT deployment share.

    .DESCRIPTION
        Creates the full NDT deployment share folder structure on the local machine,
        copies reference control files (CustomSettings.json, Deployment.json, OS.json)
        from the module's source folder, creates the Windows SMB share, and grants
        the deploy account the required permissions.

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
        Password for the deploy account. Stored in CustomSettings.json.
        Default: P@ssw0rd2026

    .EXAMPLE
        Install-NDT

    .EXAMPLE
        Install-NDT -LocalPath D:\Deploy2026 -ShareName Deploy2026 -DeployUsername "Corp\Deploy2026"
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
        [string]$DeployPassword = 'P@ssw0rd2026'
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

    #region ── Copy source reference files ──────────────────────────────────────
    $sourceDir  = Join-Path $PSScriptRoot 'source'
    $controlDir = Join-Path $LocalPath 'Control'

    $referenceFiles = @(
        'CustomSettings.json',
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
