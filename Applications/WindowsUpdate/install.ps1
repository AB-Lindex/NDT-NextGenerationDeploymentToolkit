if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
    Write-Host "PSWindowsUpdate is installed"
} else {
    Write-Host "PSWindowsUpdate is NOT installed"
   install-module pswindowsupdate -Scope CurrentUser  -Force
}

$WUCount = Get-WindowsUpdate -NotCategory "drivers" -AcceptAll -BrowseOnly
if ($WUCount.count -gt 0) {
   Get-WUInstall -NotCategory "drivers" -AcceptAll -Install -IgnoreReboot
}
if (Get-WURebootStatus -Silent) {
   shutdown.exe -r -t 5
}

