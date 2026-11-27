$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Install the newest PowerShell 7 release that ships an MSI. PowerShell 7.7+ is MSIX-only (per-user install, not
# visible to services or LocalSystem, no WinRM remoting), so /releases/latest is not usable: it points at 7.7.
$releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases?per_page=30' -Headers @{ "User-Agent" = "PowerShell" }

$candidate = $releases |
    Where-Object { -not $_.prerelease -and -not $_.draft -and ($_.assets | Where-Object { $_.name -match 'win-x64\.msi$' }) } |
    Sort-Object { [version]($_.tag_name -replace '^v', '') } -Descending |
    Select-Object -First 1
if (-not $candidate) {
    Write-Error "No stable PowerShell release with a win-x64 MSI was found in the latest 30 releases."
    exit 1
}
$msiAsset = $candidate.assets | Where-Object { $_.name -match 'win-x64\.msi$' } | Select-Object -First 1

if (-not (Test-Path $env:TEMP)) { New-Item -Path $env:TEMP -ItemType Directory -Force | Out-Null }

$destination = Join-Path $env:TEMP $msiAsset.name
Write-Host "Latest PowerShell release with an MSI: $($candidate.tag_name)"
Write-Host "MSI URL: $($msiAsset.browser_download_url)"
Invoke-WebRequest -Uri $msiAsset.browser_download_url -OutFile $destination -UseBasicParsing
Write-Host "Downloaded to $destination"
$p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$destination`" /passive /norestart" -Wait -PassThru
Remove-Item -Path $destination -Force -ErrorAction SilentlyContinue
if ($p.ExitCode -notin 0, 3010) { Write-Error "MSI install failed with exit code $($p.ExitCode)."; exit 1 }
Write-Host "PowerShell $($candidate.tag_name) installed (MSI)"
