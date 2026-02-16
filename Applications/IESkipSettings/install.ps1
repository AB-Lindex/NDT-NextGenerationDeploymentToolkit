# Disable Edge first-run experience
$registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"

# Create the registry path if it doesn't exist
if (!(Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

# Set the policies to skip first-run experience
Set-ItemProperty -Path $registryPath -Name "HideFirstRunExperience" -Value 1 -Type DWord
Set-ItemProperty -Path $registryPath -Name "FirstRunExperienceEnabled" -Value 0 -Type DWord

Write-Host "Edge first-run experience has been disabled." -ForegroundColor Green

# Disable the welcome page
Set-ItemProperty -Path $registryPath -Name "PromptOnMultipleMatchingCertificates" -Value 0 -Type DWord -ErrorAction SilentlyContinue

# Disable browser sign-in
Set-ItemProperty -Path $registryPath -Name "BrowserSignin" -Value 0 -Type DWord

# Disable sync
Set-ItemProperty -Path $registryPath -Name "SyncDisabled" -Value 1 -Type DWord

Write-Host "Additional Edge prompts have been disabled." -ForegroundColor Green

# Set Edge to open with about:blank
$registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"

# Create the registry path if it doesn't exist
if (!(Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

# Configure startup settings
Set-ItemProperty -Path $registryPath -Name "RestoreOnStartup" -Value 4 -Type DWord

# Create the RestoreOnStartupURLs subkey
$startupUrlsPath = "$registryPath\RestoreOnStartupURLs"
if (!(Test-Path $startupUrlsPath)) {
    New-Item -Path $startupUrlsPath -Force | Out-Null
}

# Set about:blank as the startup page
Set-ItemProperty -Path $startupUrlsPath -Name "1" -Value "about:blank" -Type String

Write-Host "Edge start page has been set to about:blank" -ForegroundColor Green
