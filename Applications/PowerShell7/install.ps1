$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Query the GitHub API for the latest PowerShell release
$latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }

$msiAsset = $latestRelease.assets | Where-Object { $_.name -match 'win-x64\.msi$' } | Select-Object -First 1
$zipAsset = $latestRelease.assets | Where-Object { $_.name -match 'win-x64\.zip$' } | Select-Object -First 1

if (-not (Test-Path $env:TEMP)) { New-Item -Path $env:TEMP -ItemType Directory -Force | Out-Null }

if ($msiAsset) {
    # Releases up to 7.6 ship an MSI
    $destination = Join-Path $env:TEMP $msiAsset.name
    Write-Host "Latest PowerShell MSI URL: $($msiAsset.browser_download_url)"
    Invoke-WebRequest -Uri $msiAsset.browser_download_url -OutFile $destination -UseBasicParsing
    Write-Host "Downloaded to $destination"
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$destination`" /passive /norestart" -Wait -PassThru
    Remove-Item -Path $destination -Force -ErrorAction SilentlyContinue
    if ($p.ExitCode -notin 0, 3010) { Write-Error "MSI install failed with exit code $($p.ExitCode)."; exit 1 }
}
elseif ($zipAsset) {
    # 7.7+ ships no MSI: extract the zip to the standard location (install2026.ps1 probes this path)
    $destination = Join-Path $env:TEMP $zipAsset.name
    $installDir  = Join-Path $env:ProgramFiles 'PowerShell\7'
    Write-Host "No MSI in $($latestRelease.tag_name); using zip: $($zipAsset.browser_download_url)"
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $destination -UseBasicParsing
    Write-Host "Downloaded to $destination"

    if (Test-Path $installDir) { Remove-Item -Path $installDir -Recurse -Force }
    New-Item -Path $installDir -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $destination -DestinationPath $installDir -Force
    Remove-Item -Path $destination -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path (Join-Path $installDir 'pwsh.exe'))) { Write-Error "pwsh.exe not found in $installDir after extraction."; exit 1 }

    # Add to machine PATH if missing
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($machinePath -split ';') -notcontains $installDir) {
        [Environment]::SetEnvironmentVariable('Path', ($machinePath.TrimEnd(';') + ';' + $installDir), 'Machine')
    }
    Write-Host "PowerShell extracted to $installDir"
}
else {
    Write-Error "Neither an MSI nor a win-x64 zip asset was found in the latest release ($($latestRelease.tag_name))."
    exit 1
}
