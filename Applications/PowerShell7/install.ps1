# Query the GitHub API for the latest PowerShell release
$latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }

# Look for the asset that ends with "win-x64.msi"
$msiAsset = $latestRelease.assets | Where-Object { $_.name -match "win-x64.msi$" }

if ($msiAsset) {
    $downloadUrl = $msiAsset.browser_download_url
    Write-Host "Latest PowerShell MSI URL: $downloadUrl"
    
    # Optionally, download the MSI file:
    $destination = "C:\Temp\$($msiAsset.name)"
    Invoke-WebRequest -Uri $downloadUrl -OutFile $destination
    Write-Host "Downloaded to $destination"
    Start-Process -FilePath "msiexec.exe" -ArgumentList "/i $destination /passive" -Wait
    Remove-Item -Path $destination -force
} else {
    Write-Error "MSI asset not found in the latest release."
}
