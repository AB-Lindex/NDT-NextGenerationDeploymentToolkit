# Moves ONE captured reference WIM (Reference\ref-<name>.wim) to Operating Systems\ref-<name>\<name>.wim
# Only the WIM named by -OutputPath is moved; other WIMs in Reference\ may still be captured right now.
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$DeployRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RefPath    = Join-Path $DeployRoot 'Reference'
$OSPath     = Join-Path $DeployRoot 'Operating Systems'

if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    Write-Error "Captured WIM not found: $OutputPath"
    exit 1
}

$wim = Get-Item -LiteralPath $OutputPath
if ($wim.DirectoryName.TrimEnd('\') -ne $RefPath.TrimEnd('\')) {
    Write-Error "Refusing to move $($wim.FullName): it is not directly in $RefPath"
    exit 1
}

$osName  = $wim.BaseName                             # ref-w2025dcg
$newName = ($osName -replace '^ref-', '') + '.wim'   # w2025dcg.wim
$osDir   = Join-Path $OSPath $osName

if (-not (Test-Path $osDir)) {
    Write-Output "Creating OS folder: $osDir"
    New-Item -Path $osDir -ItemType Directory -Force | Out-Null
}

$dest = Join-Path $osDir $newName
Write-Output "Moving $($wim.FullName) -> $dest"
Move-Item -LiteralPath $wim.FullName -Destination $dest -Force
