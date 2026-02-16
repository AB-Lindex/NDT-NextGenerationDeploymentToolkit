New-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\ServerManager -Name "DoNotPopWACConsoleAtSMLaunch" -Value 1 -PropertyType DWORD -Force
