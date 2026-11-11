# NDT - Quick install guide

A short guide for a single Windows Server 2025 (Desktop Experience) with PowerShell 7.
It covers three things:

1. [Install the NDT share](#2-install-ndt-without-the-monitor-and-iis) without the monitor and IIS
2. [Install the NDT Monitor](#3-install-the-ndt-monitor) (IIS, HTTPS certificate)
3. [Build the WinPE boot image](#4-build-the-winpe-boot-image) with WDS (WIM registered) or without WDS (ISO only)

All commands run in an **elevated** PowerShell 7 prompt (Run as administrator).
For the full command reference see [install/NDT/README.md](install/NDT/README.md).

## 1. Prerequisites

| Needed for | What |
|---|---|
| Everything | Local administrator, internet access to GitHub and PSGallery |
| `Install-NDT` | A deploy account that clients use to map the share (e.g. `CORP\Deploy2026`) |
| `Install-NDTMonitor` | A **PFX certificate** for this server's FQDN (internal CA is fine) |
| `New-NDTPEImage` | Windows ADK + WinPE Add-on, stable `10.1.26100.x` (the `10.1.28000.x` preview kit does not work for x64) |
| WDS boot image only | The WDS role, installed and initialised by you (NDT does not do this) |

Install the NDT module from PSGallery:

```powershell
Install-Module NDT -Scope AllUsers
Import-Module NDT
```

The module is imported under PowerShell 7 here. `Install-NDTMonitor` needs Windows PowerShell 5.1
for IIS and relaunches itself under `powershell.exe` automatically - you do not need to switch shells.

## 2. Install NDT without the monitor and IIS

`-SkipMonitor` skips IIS and the NDT Monitor completely.

```powershell
Install-NDT -DeployUsername 'CORP\Deploy2026' -SkipMonitor
```

You are prompted for the deploy password (`-DeployPassword` is a SecureString and mandatory).
Optional parameters: `-LocalPath` (default `C:\Deploy2026`), `-ShareName` (default `Deploy2026`),
`-ShareUNC` (default `\\<this host FQDN>\Deploy2026`).

What it does:

- downloads the repository ZIP and extracts it into `LocalPath`
- stamps the `Deploy` section of `Control\Sections.json` (share, deploy user, password)
- creates the SMB share, gives the deploy account Full access and removes Everyone

Note: the `Deploy` section still gets a `MonitorUrl` (derived from the share host and `-MonitorPort`,
default 443) even with `-SkipMonitor`. Reporting is best-effort and silently ignored when nothing
answers, so deployments are not affected. Clear `MonitorUrl` in `Control\Sections.json` if you
want to remove it.

Check the result:

```powershell
Get-SmbShare Deploy2026
Get-Content C:\Deploy2026\version.json
```

## 3. Install the NDT Monitor

The monitor is an IIS web service that shows live deployment progress. It is **HTTPS only**:
a certificate is mandatory, no self-signed certificate is generated and there is no HTTP fallback.
If no certificate can be resolved, the command aborts.

Run it after `Install-NDT` (or later, on a share installed with `-SkipMonitor`):

```powershell
Install-NDTMonitor
```

It installs the IIS roles and ASP.NET 4.x, creates the application pool and the `NDTMonitor`
site (default port 443, default site removed), binds the certificate, grants the app pool write
access to `Logs\progress` and opens the firewall port. It is safe to re-run.

Alternatively, install it together with the share in one step. `Install-NDT` accepts the same
`-CertificatePath`, `-Thumbprint`, `-CertificatePassword` and `-MonitorPort` parameters:

```powershell
Install-NDT -DeployUsername 'CORP\Deploy2026' -CertificatePath 'D:\certs\ndt01.corp.dev.pfx'
```

### Certificate handling

The certificate is resolved in this order:

1. **`-CertificatePath`** - an explicit PFX file.
2. **`-Thumbprint`** - a certificate already in `LocalMachine\My` (no PFX needed), otherwise a PFX
   in `C:\Deploy2026\install\NDTMonitor` with that thumbprint.
3. **FQDN match (default)** - `<fqdn>.pfx` in `C:\Deploy2026\install\NDTMonitor`, otherwise any
   `*.pfx` there whose subject CN or SAN contains this server's FQDN.

PFX files are imported into `LocalMachine\My` (idempotent by thumbprint). The PFX password is
`-CertificatePassword` (SecureString); if you omit it, the NDT default PFX password is tried, so
pass your own password for your own PFX.

Examples for the three scenarios:

```powershell
# A) PFX named <fqdn>.pfx placed in the monitor folder (nothing else to specify)
Copy-Item .\ndt01.corp.dev.pfx C:\Deploy2026\install\NDTMonitor\
Install-NDTMonitor -CertificatePassword (Read-Host 'PFX password' -AsSecureString)

# B) Certificate already installed in the computer store (e.g. enrolled from the internal CA)
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Thumbprint, NotAfter
Install-NDTMonitor -Thumbprint 'AB12...'

# C) PFX anywhere on disk
Install-NDTMonitor -CertificatePath 'D:\certs\ndt01.corp.dev.pfx' `
                   -CertificatePassword (Read-Host 'PFX password' -AsSecureString)
```

Other options: `-Port` (default 443), `-SitePath`, `-SiteName`, `-AppPoolName`, `-LogRoot`.

Verify (browse from a client that trusts the issuing CA):

```powershell
Invoke-RestMethod https://ndt01.corp.dev/progress   # returns [] until a machine reports
```

Dashboard: `https://<server-fqdn>:<port>/`. The client name in `MonitorUrl` must match the certificate
name, and WinPE must trust the issuing CA (see `-RootCACertName` in the next section).

## 4. Build the WinPE boot image

Install the Windows ADK and the WinPE Add-on first (both, stable `10.1.26100.x`):
<https://learn.microsoft.com/windows-hardware/get-started/adk-install>

`New-NDTPEImage` always builds a fresh `Boot\boot2026.wim` from the ADK and reads the deploy
credentials from the `Deploy` section stamped by `Install-NDT`. The boot image contains the
deploy share path and credentials, so keep `Boot\` protected.

### With WDS (WIM registered in WDS, plus ISOs)

Install and initialise WDS once (NDT does not do this for you):

```powershell
Install-WindowsFeature WDS -IncludeManagementTools
wdsutil /Initialize-Server /RemInst:"C:\RemoteInstall"
```

Then build:

```powershell
New-NDTPEImage
```

Result in `C:\Deploy2026\Boot\`:

- `boot2026.wim` - also registered as the WDS boot image "NDT PE Boot 2026"
- `boot2026.iso` - hybrid BIOS/UEFI (Gen 1 VMs, reference-image capture, "press any key" prompt)
- `boot2026-uefi.iso` - UEFI only, boots unattended (Gen 2 VMs)

To refresh only the WDS registration of an existing WIM (no rebuild, no ISOs):

```powershell
New-NDTPEImage -RegisterOnly
```

### Without WDS (ISO only)

```powershell
New-NDTPEImage -SkipWDS
```

The same WIM and both ISOs are built, but WDS is neither checked nor touched. `boot2026.wim` stays in
`Boot\` because the ISOs are made from it; it is just not registered anywhere. Boot machines from
the ISO (attach it to the VM or write it to USB).

### Useful options

| Parameter | Purpose |
|---|---|
| `-DriverPath <folder[]>` | Inject extra NIC / storage drivers into the image (default `Drivers\PE`) |
| `-RootCACertName <subject>` | Export that root CA from this server and trust it inside WinPE, so the HTTPS monitor works from PE with an internal CA |
| `-DeploySection <name>` | Read share credentials from another section of `Sections.json` (default `Deploy`) |
| `-SkipISO` | Build the WIM (and WDS registration) only |
| `-WhatIf` / `-Verbose` | Preview or see detail |

Example with an internal CA and drivers, ISO only:

```powershell
New-NDTPEImage -SkipWDS -RootCACertName 'Corp Root CA' -DriverPath 'C:\Deploy2026\Drivers\PE'
```

Find the exact subject name with
`Get-ChildItem Cert:\LocalMachine\Root | Select-Object Subject, Thumbprint`.

Rebuild the image whenever the WinPE scripts, the deploy credentials or the trusted root CA change.

## 5. Next steps

```powershell
# Import an OS image (put the WIM under C:\Deploy2026\Operating Systems\ first)
Add-NDTOs -Key WIN2025DCG -Path 'Operating Systems\<folder>\install.wim' -Index 1
```

Then register machines by MAC address (`Add-NDTComputer`), check them with
`Test-NDTDeployment -MAC <MAC>`, boot from the ISO or PXE and follow progress on the monitor.
