# Dot-source from the deploy scripts: imports the NDT module that lives on the share
# (install\NDT), so WinPE, first boot and the step engine all use the same lookup code.
#
#   . "$PSScriptRoot\Import-NDTModule.ps1"
#
# Throws if the module is missing (run Update-NDT). PS 5.1 and PS 7 compatible.

$ndtModuleDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\install\NDT'))
$ndtManifest  = Join-Path $ndtModuleDir 'ndt.psd1'
if (-not (Test-Path -LiteralPath $ndtManifest)) {
    throw "NDT module not found on the share: $ndtManifest. Run Update-NDT."
}

# Re-import unless this exact module is loaded and its commands are visible in this scope.
$ndtLoaded = @(Get-Module -Name ndt | Where-Object { $_.ModuleBase -eq $ndtModuleDir }).Count -gt 0
if (-not ($ndtLoaded -and (Get-Command Get-NDTMachine -ErrorAction SilentlyContinue))) {
    Import-Module $ndtManifest -Force -DisableNameChecking
}
