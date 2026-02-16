# Disable for Administrators
$adminPath = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
if (-not (Test-Path $adminPath)) {
    Write-Host "Creating registry key for Administrators..." -ForegroundColor Yellow
    New-Item -Path $adminPath -Force | Out-Null
}
Set-ItemProperty -Path $adminPath -Name "IsInstalled" -Value 0
Write-Host "Disabled IE ESC for Administrators" -ForegroundColor Green

# Disable for Users
$userPath = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
if (-not (Test-Path $userPath)) {
    Write-Host "Creating registry key for Users..." -ForegroundColor Yellow
    New-Item -Path $userPath -Force | Out-Null
}
Set-ItemProperty -Path $userPath -Name "IsInstalled" -Value 0
Write-Host "Disabled IE ESC for Users" -ForegroundColor Green

Write-Host "`nIE Enhanced Security Configuration has been disabled." -ForegroundColor Green
