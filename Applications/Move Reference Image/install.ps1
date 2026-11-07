# Moves captured reference WIMs (Reference\ref-<name>.wim) to Operating Systems\ref-<name>\<name>.wim
$DeployRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RefPath    = Join-Path $DeployRoot 'Reference'
$OSPath     = Join-Path $DeployRoot 'Operating Systems'

foreach ($wim in Get-ChildItem -Path $RefPath -Filter 'ref-*.wim' -File) {
    $osName  = $wim.BaseName                    # ref-w2025dcg
    $newName = ($osName -replace '^ref-', '') + '.wim'   # w2025dcg.wim
    $osDir   = Join-Path $OSPath $osName

    if (-not (Test-Path $osDir)) {
        Write-Output "Creating OS folder: $osDir"
        New-Item -Path $osDir -ItemType Directory -Force | Out-Null
    }

    $dest = Join-Path $osDir $newName
    Write-Output "Moving $($wim.FullName) -> $dest"
    Move-Item -Path $wim.FullName -Destination $dest -Force
}
