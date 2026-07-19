@{
    # Module identity
    ModuleVersion     = '1.0.42'
    GUID              = 'a3f2c841-7d5e-4b1a-9e3f-0c2d8f6a1b4e'
    Author            = 'NDT'
    CompanyName       = 'NDT'
    Copyright         = '(c) 2026 NDT. All rights reserved.'
    Description       = 'NDT Deployment Toolkit — installs and configures an NDT deployment share.'

    # Minimum PowerShell version required
    PowerShellVersion = '5.1'

    # Root module
    RootModule        = 'ndt.psm1'

    # Functions to export
    FunctionsToExport = @(
        'Install-NDT',
        'Update-NDT',
        'Install-NDTMonitor',
        'New-NDTPEImage',
        'Get-NDTServer', 'Add-NDTServer', 'Set-NDTServer', 'Remove-NDTServer',
        'Get-NDTOs',     'Add-NDTOs',     'Set-NDTOs',     'Remove-NDTOs',
        'Move-NDTReferenceImage',
        'Test-NDTDeployment'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('Build-NDTPEImage')

    # Required modules (SmbShare is a built-in Windows module)
    RequiredModules   = @()

    # Private data / PSGallery metadata
    PrivateData = @{
        PSData = @{
            Tags        = @('NDT', 'Deployment', 'MDT', 'LiteTouch')
            ProjectUri  = 'https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit'
            ReleaseNotes = '1.0.42 - Adds Update-NDT (in-place upgrade that refreshes code while preserving Control config, credentials, WIMs, certificates, and logs; optional -UpdateMonitor and pre-upgrade backup). 1.0.41 - Adds Install-NDTMonitor (IIS HTTPS progress web service), Move-NDTReferenceImage, Test-NDTDeployment; Install-NDT gains -MonitorPort/-SkipMonitor.'
        }
    }
}
