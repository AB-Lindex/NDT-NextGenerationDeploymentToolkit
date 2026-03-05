Set-Location $PSScriptRoot

Unblock-File -Path ".\adksetup.exe"
Unblock-File -Path ".\adkwinpesetup.exe"

Start-Process -FilePath ".\adksetup.exe" -ArgumentList "/quiet /norestart" -Wait
Start-Process -FilePath ".\adkwinpesetup.exe" -ArgumentList "/quiet /norestart" -Wait
