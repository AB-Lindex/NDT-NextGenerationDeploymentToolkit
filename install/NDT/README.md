# NDT - Next Deployment Toolkit

A lightweight PowerShell replacement for MDT. No GUI and no XML wizards - a new
Windows deployment share is provisioned, upgraded, and driven entirely from
PowerShell 5.1/7 and a small set of JSON control files. WDS/PXE handles network
boot; the deploy share is a standard Windows SMB share.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Administrator rights (share creation, IIS, WDS, and WinPE build all require it)
- Windows ADK + WinPE Add-on (only for `New-NDTPEImage`)

## Installation

```powershell
Install-Module NDT
```

Or import directly from the deployment share:

```powershell
Import-Module C:\Deploy2026\install\NDT\ndt.psd1
```

## Quick start

```powershell
# 1. Provision a new NDT deployment share (prompts for the deploy password)
Install-NDT

# 2. Build the WinPE boot image and register it in WDS
New-NDTPEImage

# 3. Import an operating system image
Add-NDTOs -Key WIN2025DCG -Path 'Operating Systems\ref-w2025dcg\w2025dcg.wim' -Index 1

# 4. Register a machine to deploy (keyed by MAC address)
Add-NDTServer -MAC '00:15:5D:02:56:05' -Computername srv05 -OS WIN2025DCG `
    -IPAddress '10.0.3.25/24' -DeploymentSteps 'General Settings','SMC'

# 5. Validate the configuration before booting
Test-NDTDeployment -MAC '00:15:5D:02:56:05'
```

## Commands

| Command | Purpose |
|---|---|
| `Install-NDT` | Bootstrap a new deployment share (download code, stamp credentials, create SMB share, install the monitor). |
| `Update-NDT` | In-place upgrade that refreshes code while preserving Control config, credentials, WIMs, certificates, and logs. |
| `Install-NDTMonitor` | Install the NDT Monitor IIS progress web service (idempotent). |
| `New-NDTPEImage` | Build the WinPE boot WIM (and optional ISO) and update the WDS boot image. |
| `Get-NDTServer` / `Add-NDTServer` / `Set-NDTServer` / `Remove-NDTServer` | Manage per-machine entries in `CustomSettings.json`. |
| `Get-NDTOs` / `Add-NDTOs` / `Set-NDTOs` / `Remove-NDTOs` | Manage the OS catalog in `OS.json`. |
| `Move-NDTReferenceImage` | Move captured reference WIMs from `Reference\` into `Operating Systems\`. |
| `Test-NDTDeployment` | Read-only dry-run validation of a machine's full deployment configuration. |

## Links

- Project: https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit
