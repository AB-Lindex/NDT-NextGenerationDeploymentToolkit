# VMware PE drivers (VMXNET3 + PVSCSI)

WinPE has **no** driver for the VMware VMXNET3 NIC (and usually not for the PVSCSI
storage controller). Without them, a WinPE deployment on VMware gets **no network**
(and can't see PVSCSI disks). `New-NDTPEImage` Step 4c injects any drivers found under
`Drivers\PE` into the boot image, so staging them here fixes both.

## Why the driver files are not in this repo

The VMXNET3 / PVSCSI drivers are **VMware/Broadcom proprietary binaries**, shipped under
the VMware Tools license. That license permits *use*, not *redistribution*, so the actual
`.inf/.sys/.cat/.dll` files are **git-ignored** and never committed. You already have a
license to these drivers via VMware Tools - stage them yourself from that media.

## Stage the drivers (one command)

Use the helper in this folder against your VMware Tools installer. The most reliable
source is `setup.exe` extracted with 7-Zip (it contains `VMXNet3.cab` and `PVSCSI.cab`):

```powershell
# 1. 7-Zip-extract VMware Tools setup.exe to a folder (or point -Source at setup.exe
#    directly if 7z.exe is on PATH), then:
.\Get-VMwarePEDrivers.ps1 -Source C:\temp\vmtools-extracted
```

Defaults stage the **Win11** VMXNET3 flavor (gate build >= 26100, correct for the
Windows Server 2025 / build-26100 ADK) and the **Win10** PVSCSI flavor. Override with
`-VmxnetFlavor` / `-PvscsiFlavor` (`Win7`/`Win8`/`Win10`/`Win11`) if you build PE on an
older ADK.

Resulting layout (what Step 4c injects):

```
Drivers\PE\VMware\
  pvscsi\               pvscsi.inf/.sys/.cat/txtsetup.oem
  vmxnet3\Win11\        vmxnet3.inf/.sys/.cat/vmxnet3ver.dll
```

## Choosing the VMXNET3 flavor

VMware's INF `[Manufacturer]` section is gated to a **minimum OS build**:

| Flavor | Gate | Matches WinPE build |
| --- | --- | --- |
| Win11 | `10.0...26100` | 26100+ (Server 2025 / 24H2 ADK) |
| Win10 | `10.0...20124` | 20124+ (Win11 22H2/23H2 = 22621/22631, and 26100) |

Stage the flavor whose gate is **<=** your PE build. If the driver is injected but the
NIC still doesn't bind (`pnputil /enum-devices /class net` is empty), the flavor gate is
higher than your PE build - use the lower one.

> Build the PE with the **stable** ADK that matches your OS (Windows Server 2025 =
> **ADK 10.1.26100.2454**). A preview/Insider ADK (e.g. 10.1.28000.1, 26H1 Arm64) builds
> a WinPE where injected NIC drivers do not bind at all.
