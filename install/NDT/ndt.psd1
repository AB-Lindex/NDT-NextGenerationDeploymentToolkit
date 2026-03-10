@{
    # Module identity
    ModuleVersion     = '1.0.2'
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
        'Build-NDTPEImage',
        'Get-NDTServer', 'Add-NDTServer', 'Set-NDTServer', 'Remove-NDTServer',
        'Get-NDTOs',     'Add-NDTOs',     'Set-NDTOs',     'Remove-NDTOs',
        'Move-NDTReferenceImage'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # Required modules (SmbShare is a built-in Windows module)
    RequiredModules   = @()

    # Private data / PSGallery metadata
    PrivateData = @{
        PSData = @{
            Tags        = @('NDT', 'Deployment', 'MDT', 'LiteTouch')
            ProjectUri  = 'https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit'
            ReleaseNotes = '1.0.0 — Initial release. Provides Install-NDT, Build-NDTPEImage.'
        }
    }
}
