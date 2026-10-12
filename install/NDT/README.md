# NDT - Next Deployment Toolkit

A lightweight PowerShell replacement for MDT. No GUI and no XML wizards - a new
Windows deployment share is provisioned, upgraded, and driven entirely from
PowerShell 5.1/7 and a small set of JSON control files. WDS/PXE handles network
boot; the deploy share is a standard Windows SMB share.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+ (PowerShell 7 recommended for importing; commands that need IIS or WDS relaunch under `powershell.exe` automatically)
- Administrator rights (share creation, IIS, WDS, and WinPE build all require it)
- Windows Server with Desktop Experience if you use WDS (Server Core has no WDS image store)
- Windows ADK + WinPE Add-on, stable `10.1.26100.x` (only for `New-NDTPEImage`; the `10.1.28000.x` preview kit does not work for x64)
- Internet access to GitHub for `Install-NDT` and `Update-NDT`
- `Microsoft.PowerShell.ConsoleGuiTools` (only for `New-NDTComputerTui`)

## Installation

```powershell
Install-Module NDT -Scope AllUsers
```

To update an AllUsers install, run `Install-Module NDT -Force -Scope AllUsers`. Do not use
`Update-Module` on PowerShellGet 2.x: it installs to CurrentUser and that newer copy then
shadows the AllUsers one.

From a clone of the repository:

```powershell
Import-Module .\install\NDT\ndt.psd1
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
Add-NDTComputer -MAC '00:15:5D:02:56:05' -Computername srv05 -OS WIN2025DCG `
    -IPAddress '10.0.3.25/24' -DeploymentGroups 'General Settings','SMC'

# 5. Validate the configuration before booting
Test-NDTDeployment -MAC '00:15:5D:02:56:05'

# 6. Boot the machine (PXE or boot ISO) and follow it live
Watch-NDTDeployment -Computername srv05
```

`Install-NDT` parameters: `-LocalPath` (default `C:\Deploy2026`), `-ShareName`, `-ShareUNC`,
`-DeployUsername` (default `Corp\Deploy2026`), `-DeployPassword` (mandatory, prompted),
`-RepoZipUrl`, `-MonitorPort` (default `9999`) and `-SkipMonitor`.

## Commands

| Command | Purpose |
|---|---|
| `Install-NDT` | Bootstrap a new deployment share (download code, stamp credentials, create SMB share, install the monitor). |
| `Update-NDT` | In-place upgrade that refreshes code while preserving Control config, credentials, WIMs, certificates, and logs. |
| `Install-NDTMonitor` | Install the NDT Monitor IIS progress web service (idempotent). |
| `New-NDTPEImage` | Build the WinPE boot WIM, two bootable ISOs (Gen 1 hybrid + Gen 2 UEFI no-prompt), inject drivers, and update the WDS boot image. Switches: `-SkipISO`, `-SkipWDS`, `-RegisterOnly`, `-DriverPath`, `-DeploySection`, `-RootCACertName`, `-PS7` (experimental). |
| `Get-NDTComputer` / `Add-NDTComputer` / `Set-NDTComputer` / `Remove-NDTComputer` | Manage per-machine entries in `CustomSettings.json`. |
| `Remove-NDTProgress` | Delete a computer's NDT Monitor progress file (called by `Add-`/`Remove-NDTComputer`). |
| `Get-NDTOs` / `Add-NDTOs` / `Set-NDTOs` / `Remove-NDTOs` | Manage the OS catalog in `OS.json`. |
| `Move-NDTReferenceImage` | Move captured reference WIMs from `Reference\` into `Operating Systems\`. |
| `Test-NDTDeployment` | Read-only dry-run validation of a machine's full deployment configuration (machine block, sections, OS key, WIM, groups, actions, script paths, finish action). Returns `$true`/`$false`. |
| `Watch-NDTDeployment` | Live progress bar for a machine (by `-Computername` or `-MAC`) until the NDT Monitor reports Done. `-TimeoutMinutes`, `-PollSeconds`, `-MonitorUrl`, `-SkipCertificateCheck`. |
| `New-NDTComputerTui` | PowerShell 7 terminal form for adding a computer (needs `Microsoft.PowerShell.ConsoleGuiTools`). Add only. |
| `Get-NDTCatalog` / `Test-NDTComputerEntry` | Read-only helpers for front ends: available OS/sections/groups, and validation + key-overlap check of a proposed entry. |

## Boot media

`New-NDTPEImage` writes two ISOs to `Boot\` (skip both with `-SkipISO`):

| ISO | Firmware | Use |
|---|---|---|
| `boot2026.iso` | Hybrid BIOS/EFI (`MakeWinPEMedia`) | Gen 1 VMs and reference-image capture. Keeps the "Press any key to boot from CD" prompt. |
| `boot2026-uefi.iso` | UEFI-only, no-prompt (`oscdimg` + `efisys_noprompt.bin`) | Gen 2 VMs. Boots straight into WinPE with no keypress, so unattended deployment is not blocked. |

Both ISOs are built from the same staging tree, so the WinPE contents are identical - only the El Torito boot sector differs.

```powershell
# Gen 1 VM
Set-VMDvdDrive -VMName '<vmname>' -Path 'C:\Deploy2026\Boot\boot2026.iso'

# Gen 2 VM (Secure Boot can stay enabled - the ISO boots fine with it on)
Set-VMDvdDrive -VMName '<vmname>' -Path 'C:\Deploy2026\Boot\boot2026-uefi.iso'
```

On Gen 2, WDS/UEFI moves the DVD ahead of the disk for the first boot and the
firmware boot order reverts to the disk automatically after the WinPE phase, so
the DVD does not need to be ejected between phases.

Other `New-NDTPEImage` inputs:

- **Drivers**: everything under `Drivers\PE` (or `-DriverPath`) is injected with `DISM /Add-Driver /Recurse /ForceUnsigned`, so WinPE can see NICs and storage it lacks (e.g. VMware `vmxnet3`/`pvscsi`). Drivers for the deployed OS live in `Drivers\OS\<Platform>` and are injected by `install.ps1`, not by this command.
- **Internal HTTPS**: `-RootCACertName <subject>` exports that root certificate from this host and imports it into WinPE at boot, so the NDT Monitor can use an internal-CA HTTPS endpoint.
- **`-PS7`**: experimental image with PowerShell 7 inside WinPE, written to separate `boot2026-ps7.*` files so the production image is never overwritten. Unsupported by Microsoft.

## NDT Monitor

`Install-NDT` installs the NDT Monitor (IIS, default port `9999`) unless `-SkipMonitor` is given; `Install-NDTMonitor` installs it on its own and is idempotent. Deploying machines report progress to it from WinPE and from Windows. Data is stored per computer name in `Logs\progress`, with a daily audit log. Use `Watch-NDTDeployment` to follow a machine and `Remove-NDTProgress` to clear its entry.

## Updating a share

`Update-NDT` refreshes the code of an existing share and preserves `Control\*.json`, credentials, WIMs, certificates, `Applications2026\`, `Reference\` and `Logs\`. A timestamped backup of `Control\` and `install\` is taken first (`-NoBackup` skips it). Rebuild the boot image with `New-NDTPEImage` afterwards if `install.ps1`, drivers or the WinPE launcher changed.

## SQL access

The share contains `Scripts\unattend2026\Invoke-NDTSql.ps1`, a parameterised T-SQL helper that
connects over TCP (default 1433) with a SQL login using `System.Data.SqlClient`. It works in the
production WinPE (PowerShell 5.1), the experimental PowerShell 7 WinPE and a normal OS. Settings
come from an `NDTSql` section in `Control\Sections.json` (`Server`, `Database`, `Username`,
`Password`, optional `Port`, `Encrypt`, `TrustServerCertificate`); add it by hand, since
`Update-NDT` does not change an existing `Sections.json`. Use a read-only login. NDT does not use
it for its own lookups yet. See the repository README.

## Starting a deployment from inside Windows

Not a module command: run `Scripts\unattend2026\Start-Refresh.ps1` elevated from the share. It validates the machine, stages the boot ISO's WinPE locally, adds a one-shot ramdisk boot entry and reboots into the normal WinPE deployment. See the repository README.

## Links

- Project: https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit
