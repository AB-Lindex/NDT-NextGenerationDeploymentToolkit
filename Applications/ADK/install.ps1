Set-Location $PSScriptRoot

$LocalPath = 'C:\temp\ADK'
New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
Copy-Item -Path "$PSScriptRoot\*" -Destination $LocalPath -Force

Start-Process -FilePath "$LocalPath\adksetup.exe" -ArgumentList "/quiet /norestart" -Wait
Start-Process -FilePath "$LocalPath\adkwinpesetup.exe" -ArgumentList "/quiet /norestart" -Wait

Remove-Item -Path $LocalPath -Recurse -Force
