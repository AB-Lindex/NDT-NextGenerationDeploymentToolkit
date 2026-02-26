@echo off
rem StartDeploy.cmd - called by Unattend.xml RunSynchronous after wpeinit
rem wpeinit has already initialised DHCP/PnP; WaitForNetwork ensures a lease is held
wpeutil WaitForNetwork
powershell.exe -NoLogo -ExecutionPolicy Bypass -File X:\Deploy\install.ps1
