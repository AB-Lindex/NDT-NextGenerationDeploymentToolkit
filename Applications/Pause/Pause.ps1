<#
.SYNOPSIS
    Pauses the NDT deployment and places a shortcut on the Public Desktop
    so any logged-on user can continue when ready.
.DESCRIPTION
    Called as a deployment step.  Creates a .lnk on C:\Users\Public\Desktop
    that re-runs install2026.ps1 (same command as RunOnce\Deploy2026), then
    prints a prominent message telling the operator what to do next.
#>

$shortcutPath = 'C:\Users\Public\Desktop\Continue Deployment.lnk'

# ------------------------------------------------------------------
# Create / overwrite the desktop shortcut
# ------------------------------------------------------------------
$shell   = New-Object -ComObject WScript.Shell
$lnk     = $shell.CreateShortcut($shortcutPath)
$lnk.TargetPath       = 'powershell.exe'
$lnk.Arguments        = '-executionpolicy bypass -File c:\temp\install2026.ps1 -Resume'
$lnk.WorkingDirectory = 'C:\temp'
$lnk.Description      = 'Continue NDT deployment'
$lnk.IconLocation     = 'powershell.exe,0'
$lnk.Save()

Write-Host ''
Write-Host '========================================================' -ForegroundColor Yellow
Write-Host '  DEPLOYMENT PAUSED' -ForegroundColor Yellow
Write-Host '========================================================' -ForegroundColor Yellow
Write-Host ''
Write-Host '  A shortcut has been placed on the Public Desktop:' -ForegroundColor Cyan
Write-Host "  $shortcutPath" -ForegroundColor White
Write-Host ''
Write-Host '  Complete any manual steps required, then double-click' -ForegroundColor Cyan
Write-Host '  "Continue Deployment" on the desktop to resume.' -ForegroundColor Cyan
Write-Host ''
Write-Host '  The shortcut runs:' -ForegroundColor Gray
Write-Host '    powershell.exe -executionpolicy bypass -File c:\temp\install2026.ps1' -ForegroundColor Gray
Write-Host ''
Write-Host '========================================================' -ForegroundColor Yellow
