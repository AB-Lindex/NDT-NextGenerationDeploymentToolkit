<#
.SYNOPSIS
    Pauses the NDT deployment and places a shortcut on the Public Desktop
    so any logged-on user can continue when ready.
.DESCRIPTION
    Called as a deployment step.  Creates a .lnk on C:\Users\Public\Desktop
    that re-runs install2026.ps1 from the deployment folder ($env:NDT_DEPLOYDIR, set by the
    step engine) with -Resume, then prints a prominent message telling the operator what to do next.
#>

$shortcutPath  = 'C:\Users\Public\Desktop\Continue Deployment.lnk'
$installScript = Join-Path $env:NDT_DEPLOYDIR 'install2026.ps1'

# ------------------------------------------------------------------
# Create / overwrite the desktop shortcut
# ------------------------------------------------------------------
$shell   = New-Object -ComObject WScript.Shell
$lnk     = $shell.CreateShortcut($shortcutPath)
$lnk.TargetPath       = 'powershell.exe'
$lnk.Arguments        = "-executionpolicy bypass -File `"$installScript`" -Resume"
$lnk.WorkingDirectory = $env:NDT_DEPLOYDIR
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
Write-Host "    powershell.exe -executionpolicy bypass -File $installScript -Resume" -ForegroundColor Gray
Write-Host ''
Write-Host '========================================================' -ForegroundColor Yellow
