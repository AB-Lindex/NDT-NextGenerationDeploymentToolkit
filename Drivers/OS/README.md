# OS drivers (injected into the deployed image)

These drivers are injected into the **deployed OS** (the offline Windows image applied
to `C:`), **not** into WinPE. Use them for storage/NIC drivers the applied image lacks
so the target can boot and reach the network on first start.

> WinPE (boot image) drivers are separate - they live in [`Drivers\PE`](../PE) and are
> injected by `New-NDTPEImage`. This folder (`Drivers\OS`) is injected by
> [`Scripts\unattend2026\install.ps1`](../../Scripts/unattend2026/install.ps1) Step 4a,
> right after `Dism /Apply-Image` and before `BCDBoot`.

## How folders are selected

`install.ps1` runs `Get-Hardware.ps1`, then injects every subfolder here whose **name**
appears in the detected hardware string (`Platform` + `Make` + `Model` + `BaseBoard`,
case-insensitive). Name the folder after the platform or vendor and NDT picks the right
one automatically:

| Folder name | Matches when the machine is... |
| --- | --- |
| `VMware`  | a VMware VM (`Platform = VMware`) |
| `Hyper-V` | a Hyper-V VM (`Platform = Hyper-V`) |
| `Dell`    | physical Dell (`Make` contains "Dell") |
| `HP`      | physical HP (`Make` contains "HP") |
| `Lenovo`  | physical Lenovo (`Make` contains "Lenovo") |

Multiple matches are all injected. No match (or an empty/missing folder) is skipped and
never blocks deployment.

## Layout

Drop the vendor's extracted driver package (`.inf` + `.sys` + `.cat`) anywhere under the
platform folder - injection is recursive:

```
Drivers\OS\
  VMware\        vmxnet3\ pvscsi\ ...   (any depth; all .inf found are added)
  Dell\          <model>\ ...
  HP\            <model>\ ...
```

## How injection works

For each matched folder:

```powershell
Dism.exe /Image:C:\ /Add-Driver /Driver:"<folder>" /Recurse /ForceUnsigned
```

`/Recurse` walks all subfolders and `/ForceUnsigned` lets boot-critical storage/NIC
drivers apply even if the offline image would otherwise reject them. Windows only binds
the drivers whose PnP IDs actually match the hardware, so it is safe to stage a whole
vendor package.

## Note on driver binaries

Vendor driver binaries (e.g. VMware/Broadcom `vmxnet3`/`pvscsi`, Dell/HP packs) are
proprietary and typically **not** committed to the repo. Stage them here yourself from
your licensed media. For VMware you can reuse the extractor in
[`Drivers\PE\VMware\Get-VMwarePEDrivers.ps1`](../PE/VMware/Get-VMwarePEDrivers.ps1) to
pull `vmxnet3`/`pvscsi` out of VMware Tools, then copy them under `Drivers\OS\VMware`.
