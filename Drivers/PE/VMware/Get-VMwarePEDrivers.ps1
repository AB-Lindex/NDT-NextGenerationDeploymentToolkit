<#
    Get-VMwarePEDrivers.ps1

    Stage VMware PE drivers (VMXNET3 NIC + PVSCSI storage) into this folder for
    New-NDTPEImage Step 4c. The driver binaries are VMware/Broadcom proprietary and are
    NOT shipped in this repo - this script extracts them from YOUR licensed VMware Tools
    media into the expected layout.

    -Source options:
      * A folder produced by 7-Zip-extracting VMware Tools setup.exe (contains
        VMXNet3.cab / PVSCSI.cab), or any folder/drive holding those .cab files.
      * VMware Tools setup.exe itself (requires 7-Zip: 7z.exe on PATH or in Program Files).

    Examples:
      .\Get-VMwarePEDrivers.ps1 -Source C:\temp\vmtools-extracted
      .\Get-VMwarePEDrivers.ps1 -Source C:\temp\VMware-tools\setup.exe
      .\Get-VMwarePEDrivers.ps1 -Source D:\ -VmxnetFlavor Win10 -PvscsiFlavor Win10
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Source,
    [string]$Destination = $PSScriptRoot,
    [ValidateSet('Win7','Win8','Win10','Win11')][string]$VmxnetFlavor = 'Win11',
    [ValidateSet('Win7','Win8','Win10','Win11')][string]$PvscsiFlavor = 'Win10'
)
$ErrorActionPreference = 'Stop'

function Resolve-VMwareCabSource {
    param([string]$Src)
    # setup.exe -> extract with 7-Zip into a temp folder first.
    if ((Test-Path $Src -PathType Leaf) -and ($Src -like '*setup.exe')) {
        $sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
        if (-not $sevenZip) {
            $candidate = Join-Path $env:ProgramFiles '7-Zip\7z.exe'
            if (Test-Path $candidate) { $sevenZip = $candidate }
        }
        if (-not $sevenZip) {
            throw "7z.exe not found (PATH or Program Files\7-Zip). Install 7-Zip, or pass a folder that already contains VMXNet3.cab / PVSCSI.cab."
        }
        $tmp = Join-Path $env:TEMP ('vmtools-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Write-Host "Extracting setup.exe with 7-Zip..." -ForegroundColor Cyan
        & $sevenZip x "$Src" "-o$tmp" -y | Out-Null
        return $tmp
    }
    if (Test-Path $Src -PathType Container) { return $Src }
    throw "Source not found or unsupported (expected a folder or setup.exe): $Src"
}

function Expand-VMwareDriverCab {
    param(
        [string]$SearchRoot,
        [string]$CabName,   # e.g. VMXNet3.cab
        [string]$Flavor,    # Win7 / Win8 / Win10 / Win11
        [string]$OutDir,
        [string]$Label
    )
    $cab = Get-ChildItem $SearchRoot -Recurse -Filter $CabName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cab) { Write-Warning "$Label`: $CabName not found under $SearchRoot - skipping."; return }

    $tmp = Join-Path $env:TEMP ('cab-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        expand.exe "$($cab.FullName)" -F:* "$tmp" | Out-Null

        # Files are MSI-mangled: <base>_<Flavor>.<GUID>  (e.g. vmxnet3.inf_Win11.<GUID>).
        $hits = @(Get-ChildItem $tmp -File | Where-Object { $_.Name -match "_$Flavor\." })
        if ($hits.Count -eq 0) {
            $avail = ((Get-ChildItem $tmp -File | ForEach-Object { if ($_.Name -match '_(Win\d+)\.') { $Matches[1] } }) | Sort-Object -Unique) -join ', '
            Write-Warning "$Label`: flavor '$Flavor' not in $CabName. Available: $avail"
            return
        }

        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
        Get-ChildItem $OutDir -File -ErrorAction SilentlyContinue | Remove-Item -Force
        foreach ($f in $hits) {
            $base = ($f.Name -replace "_$Flavor\..*$", '')   # recover real file name
            Copy-Item $f.FullName (Join-Path $OutDir $base) -Force
        }
        $n = @(Get-ChildItem $OutDir -File).Count
        Write-Host "  [OK] $Label ($Flavor): $n file(s) -> $OutDir" -ForegroundColor Green
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$searchRoot = Resolve-VMwareCabSource -Src $Source
Write-Host "Staging VMware PE drivers into: $Destination" -ForegroundColor Cyan

Expand-VMwareDriverCab -SearchRoot $searchRoot -CabName 'VMXNet3.cab' -Flavor $VmxnetFlavor `
    -OutDir (Join-Path $Destination "vmxnet3\$VmxnetFlavor") -Label 'VMXNET3 (NIC)'

Expand-VMwareDriverCab -SearchRoot $searchRoot -CabName 'PVSCSI.cab' -Flavor $PvscsiFlavor `
    -OutDir (Join-Path $Destination 'pvscsi') -Label 'PVSCSI (storage)'

Write-Host "Done. Rebuild the PE with: New-NDTPEImage" -ForegroundColor Cyan
