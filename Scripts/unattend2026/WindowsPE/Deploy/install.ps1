net use Z: \\dc01.corp.dev\deploy2026 /user:corp\Deploy2026 Boeing-747400

& "Z:\Scripts\Unattend2026\install.ps1"

read-host "press enter to reboot 1"

net use Z: /D /Y

read-host "press enter to reboot 2"
