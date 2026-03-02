if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
    Write-Host "PSWindowsUpdate is installed"
} else {
    Write-Host "PSWindowsUpdate is NOT installed"
   install-module pswindowsupdate -Scope CurrentUser  -Force
}

Import-Module PSWindowsUpdate -Force

$WUCount = Get-WUList -NotCategory "drivers"
if ($WUCount.count -gt 0) {
   Get-WUInstall -NotCategory "drivers" -AcceptAll -Install -IgnoreReboot
   read-host "wait 1"
}
if (Get-WURebootStatus -Silent) {
   read-host "wait 2"
    # Signal the NDT step engine to reboot and re-run this step.
    # The orchestrator (Install-NDT.ps1) owns the actual shutdown call.
    exit 3010
}
   read-host "wait 3"

# No reboot required - all patches installed.
exit 0

