Set-Location $PSScriptRoot

Start-Process -FilePath ".\adksetup.exe" -ArgumentList "/quiet /norestart" -Wait
Start-Process -FilePath ".\adkwinpesetup.exe" -ArgumentList "/quiet /norestart" -Wait
