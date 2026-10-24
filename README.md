# NDT — Next Deployment Tool

A lightweight PowerShell-based replacement for MDT (which is now EOL).  
The goal is to keep it simple: PowerShell 5 and 7, WDS/PXE for network boot, JSON files for all configuration, no GUI.

> **Status:** PGD — Pretty Good Deployment 🙂  
> No formal version numbers yet.
See my first video of a deployment here:
https://www.youtube.com/watch?v=8z-uKonbEoE

---

## Features

- **Unattended deployment** of Windows Server and Windows 11 Enterprise: WinPE applies a WIM with DISM, a per-machine `unattend.xml` is generated, and a step engine installs roles, applications and updates after first boot.
- **Configuration is JSON only** - five files in `Control\`, machines keyed by MAC address. No GUI, no database, no XML wizards.
- **Three ways to start**: PXE (WDS), a boot ISO (BIOS or UEFI VMs), or from inside a running Windows (`Start-Refresh.ps1`).
- **Resumable step engine**: reboots, pauses ("Continue Deployment" shortcut), AD/SQL logon switching and Windows Update loops survive restarts.
- **Reference images**: sysprep and capture from WinPE, then publish the WIM to the OS catalog.
- **Hardware detection** (physical/virtual, vendor, model) with automatic driver injection into both WinPE and the deployed OS.
- **NDT Monitor**: IIS dashboard with live progress per machine (the MDT monitoring replacement).
- **Safety guards**: `Install:NO` per machine, full pre-flight validation before the disk is touched, and a `Test-NDTDeployment` dry run.
- **Finish actions** (desktop, prompt, reboot, shutdown, logoff) just like MDT's `FinishAction`.
- **PowerShell module** (`NDT`, published to the PowerShell Gallery) to install, upgrade and administer the share.

---

## Requirements

| Where | Requirement |
|---|---|
| NDT server | Windows Server with Desktop Experience (WDS does not fully run on Server Core), SMB share, PowerShell 5.1 or 7, internet access to GitHub for `Install-NDT` / `Update-NDT`. IIS is installed automatically for the NDT Monitor. |
| Boot image build | Windows ADK **and** WinPE add-on, stable `10.1.26100.x` (the `10.1.28000.x` Arm64 preview kit does **not** work for x64 deployments). `Applications\ADK\install.ps1` installs a supported version. |
| Network boot | WDS role on the NDT server, with DHCP pointing PXE clients at it (not needed when you only use boot ISOs or `Start-Refresh.ps1`). |
| Targets | BIOS (MBR) or UEFI (GPT); Hyper-V Gen 1/Gen 2 (Secure Boot may stay on), VMware, or physical hardware. PowerShell 5.1 is in-box; PowerShell 7 is installed by the deployment. |
| Accounts | A dedicated deploy account with access to the share (default `Corp\Deploy2026`), stamped into the `Deploy` section by `Install-NDT`. |

---

## Quick start

```powershell
Install-Module NDT -Scope AllUsers

# 1. Provision a new NDT deployment share (prompts for the deploy password)
Install-NDT

# 2. Build the WinPE boot image, boot ISOs and register it in WDS
New-NDTPEImage

# 3. Register an operating system image
Add-NDTOs -Key WIN2025DCG -Path 'Operating Systems\ref-w2025dcg\w2025dcg.wim' -Index 1

# 4. Register a machine to deploy (keyed by MAC address)
Add-NDTComputer -MAC '00:15:5D:02:56:05' -Computername srv05 -OS WIN2025DCG `
    -IPAddress '10.0.3.25/24' -DeploymentGroups 'General Settings','SMC'

# 5. Validate the configuration before booting
Test-NDTDeployment -MAC '00:15:5D:02:56:05'

# 6. Boot the machine (PXE or ISO) and follow it live
Watch-NDTDeployment -Computername srv05
```

Files that are not in the repository (WIM files, certificates, licensed installers, `Applications2026\`) must be added to the share manually.

### Ways to start a deployment

| Method | When to use |
|---|---|
| **PXE / WDS** | Physical machines and VMs on a network with DHCP pointing at WDS. `New-NDTPEImage` registers the boot image. |
| **Boot ISO** | `Boot\boot2026.iso` (hybrid BIOS/EFI, Gen 1) or `Boot\boot2026-uefi.iso` (UEFI only, no keypress, Gen 2). See [Boot media](#boot-media). |
| **From inside Windows** | `Start-Refresh.ps1` re-images the running machine in place. See [Phase 1](#starting-phase-1-from-inside-windows-re-image-in-place). |

---

## How it works

Deployment flows through two phases.

### Phase 1 — Windows PE

The machine boots WinPE (via PXE/WDS, a boot ISO, or `Start-Refresh.ps1`) and loads `Boot/boot2026.wim`.  
`Scripts/unattend2026/install.ps1` runs and performs:

1. Checks for a capture-mode flag — if present it runs reference image capture instead of a normal deployment.
2. Detects firmware type (BIOS/Gen1 or UEFI/Gen2) and hardware (`Get-Hardware.ps1`: physical or virtual, hypervisor, vendor, model, serial) — disk is not touched until all validations pass.
3. Looks up the machine by MAC address in `Control/CustomSettings.json` and `Control/Projects/**/*.json` (merged, see [Projects](#projects-per-project-machine-files)); aborts (with a retry prompt, before the disk is touched) if not found, if the MAC is defined more than once, or if a JSON file is invalid. If the block has `"Install": "NO"` the machine reboots without touching the disk.
4. Resolves and validates the OS image path and index from `Control/OS.json`; aborts if the WIM file is not found.
5. All pre-flight checks passed — partitions disk 0 with diskpart (GPT/EFI for UEFI; MBR/active for BIOS).
6. Applies the OS image to `C:\` with DISM.
7. Injects OS drivers from `Drivers\OS\<Platform>` whose folder name matches the detected hardware (best-effort, see [Drivers](#drivers)).
8. Runs the optional `PostPEScript` from the machine's block (PowerShell 5, after the image is applied).
9. Copies `install2026.ps1` and a `settings.json` (deploy share credentials, local admin password, monitor URL, finish action, start time) to `C:\temp`.
10. Generates `unattend.xml` from the template, replacing placeholders with values from the machine's block (`CustomSettings.json` or `Control/Projects`). An OS can point at its own template via `Unattend` in `OS.json`.
11. Applies `unattend.xml` to the offline image, runs BCDBoot and reboots.

Throughout Phase 1 progress is reported to the [NDT Monitor](#ndt-monitor) (best-effort, never blocks deployment), and the log is written to `X:\install.log` and relocated to `C:\temp\install.log` once the disk is partitioned.

#### Starting Phase 1 from inside Windows (re-image in place)

An already-installed machine can enter Phase 1 without PXE. Run, elevated, from the deploy share:

```powershell
\\<server>\Deploy2026\Scripts\unattend2026\Start-Refresh.ps1
```

`Start-Refresh.ps1` checks the machine against the share (MAC block in `CustomSettings.json` or `Control/Projects`, `Install:NO` guard, OS key, WIM and `Boot/boot2026.iso` exist) and asks you to type the computer name (`-Force` skips this). It then stages `boot.wim` and `boot.sdi` from the ISO to `C:\NDT-PE`, adds a one-shot ramdisk BCD entry (`bcdedit /bootsequence`) and reboots. WinPE then runs the normal `install.ps1` flow above. The script wipes nothing itself; if WinPE aborts before partitioning, the next boot returns to the current Windows. There is no user-state backup/restore.

### Phase 2 — First boot and post-deployment steps

`unattend.xml` bootstraps the deployment automatically on first logon via two mechanisms (both are needed to cover sysprepped and clean images):

- **specialize pass** — writes `RunOnce\Deploy2026` and enables AutoAdminLogon so the script fires even if OOBE is skipped.
- **oobeSystem FirstLogonCommands** — directly launches `install2026.ps1` for sysprepped images that run OOBE.

`install2026.ps1` runs under PowerShell 5 (via RunOnce/FirstLogonCommands) and:

1. Exits immediately if `C:\Windows\Temp\DeploymentLogs\deploy-complete.flag` exists (prevents double-run caused by both mechanisms firing on the same logon), unless it is started with `-AdminPassword`/`-DeployPassword` to rerun a finished deployment (see below).
2. Handles the reboot-flag (`C:\temp\reboot.flag`) to distinguish a re-logon loop from a genuine completed reboot.
3. Re-registers `RunOnce\Deploy2026` so deployment survives any intermediate reboots.
4. Waits for a usable IPv4 address, then maps the deployment share from the credentials in `C:\temp\settings.json`, retrying until `Z:\Control\CustomSettings.json` is reachable (timeout `MapTimeoutSec` in the deploy section, default 120 s). This matters on physical NICs that are slow to get a link.
5. Installs PowerShell 7 if not already present.
6. Launches `Install-NDT.ps1` via `pwsh.exe` (PS7) as a child process.

`Install-NDT.ps1` runs under PowerShell 7 and drives all post-deployment work:

1. Reads the machine's deployment groups from its MAC block (`CustomSettings.json` or `Control/Projects`, matched by MAC address). A machine without `DeploymentGroups` is an OS-only deployment and is reported as done immediately.
2. Loads the ordered steps for each group from `DeploymentGroups.json`; resolves each step's action from `DeploymentActions.json`.
3. Tracks completed steps in `C:\temp\install-steps.json` so deployment can resume after a reboot exactly where it left off.
4. Supports five step types:
   - **Script** — runs a `.ps1`, `.cmd`, or `.bat` file from the Applications folder, with optional parameters from `CustomSettings.json`. Can target PowerShell 5, PowerShell 7, or cmd.exe. All script output (stdout, errors, warnings) is written to `C:\temp\install-NDT.log`. A non-zero exit code (other than `3010`/`1641`) or a terminating error is logged as `ERROR` and reported to the monitor as `Failed`. By default the deployment continues with the next step (the failed step is flagged in `install-steps.json` and not re-run); set `"ContinueOnError": false` on the action to stop the deployment instead (the engine exits with the script's exit code, so `install2026.ps1` takes the failure path).
   - **Reboot** — saves progress, writes AutoLogon credentials to the registry, calls `shutdown /r /t 10`, and exits with code `3010` so the parent script knows to write `reboot.flag` and skip cleanup.
   - **AutoLogon** — switches the AutoAdminLogon account mid-deployment, useful for operations that must run as an AD user (gMSA creation, cluster setup, SQL Always On, etc.). Credentials are resolved by looking up the step's `Reference` name as a key in `Sections.json` (`Username` + `Password`). Multiple named entries (e.g. `ADLogon-AD01`, `ADLogon-AD02`) allow logging on to different Active Directories without any code changes.
   - **WindowsUpdate** — runs the Windows Update script; if it exits `3010` the step is not marked complete and the engine exits `3010` (iterates until no reboot is needed); if it exits `0` the step is marked complete.
   - **Pause** — creates a "Continue Deployment" shortcut on `C:\Users\Public\Desktop`, marks the step complete, and exits `3011` so the parent script removes RunOnce (a reboot while paused does not auto-resume).

When all steps are done with no pending reboot, `install2026.ps1`:
- Unmounts the deployment share.
- Removes `RunOnce\Deploy2026` and disables AutoAdminLogon.
- Writes `C:\Windows\Temp\DeploymentLogs\deploy-complete.flag`.
- Moves the deployment files out of `C:\temp` into `C:\Windows\Temp\DeploymentLogs` (the folder MDT uses): `install.log`, `install2026.log`, `install-NDT.log`, `install-steps.json` and `settings.json`, with the Administrator and Deploy passwords blanked in the archived `settings.json`. `install2026.ps1` stays in `C:\temp`.
- Runs the **finish action**.

If `Install-NDT.ps1` exits with any other code, RunOnce and AutoLogon stay in place, the files stay in `C:\temp`, and the finish action runs with a failure status.

**Rerunning a finished deployment.** To re-run steps or run steps added since, start the script from `C:\temp` with the two passwords that were blanked:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\temp\install2026.ps1 -AdminPassword '<local admin password>' -DeployPassword '<deploy account password>'
```

Supplying either parameter starts the rerun when the archived `settings.json` exists in `DeploymentLogs` (the flag does not have to be present; do not delete it by hand). `-DeployPassword` is required to map the share; without `-AdminPassword` a Reboot step cannot sign in automatically. The files return to `C:\temp`, only steps not yet in `install-steps.json` run, logs are appended, and the files move back to `DeploymentLogs` when the rerun finishes. The parameters also override the stored passwords on a normal run.

### Finish action

`FinishAction` (set on a machine block, or site-wide on the deploy section; the machine wins) decides what happens when deployment ends, on success **and** on failure:

| Value | Behaviour |
|---|---|
| `DESKTOP` (default) | Leave the desktop as is. |
| `PROMPT` | System-modal popup with computer name, finish time, duration and, on failure, the reason. Works on Server Core too. |
| `REBOOT` / `SHUTDOWN` | `shutdown.exe /r` or `/s` after 10 s. `RESTART` is accepted as an alias for `REBOOT`. |
| `LOGOFF` | `shutdown.exe /l /f`. |

On failure `REBOOT`, `SHUTDOWN` and `LOGOFF` are downgraded to `PROMPT`, because RunOnce and AutoLogon are still in place and would otherwise loop the failed deployment. Unknown values fall back to `DESKTOP`.

---

## NDT Monitor

An IIS web service that gives centralised, live deployment progress (the MDT monitoring replacement). It is installed by `Install-NDT` (skip with `-SkipMonitor`, port with `-MonitorPort`, default `9999`) or on its own with `Install-NDTMonitor`, which is idempotent.

| Endpoint | Purpose |
|---|---|
| `GET /` | Live dashboard |
| `POST /progress` | Receive an update from a deploying machine |
| `GET /progress` | All machines as a JSON array |
| `GET /progress?name=<computername>` | One machine |

- Progress is reported from both phases: `Phase: WinPE` by `install.ps1` and `Phase: Windows` by `Install-NDT.ps1` (step-based percentage, plus `Rebooting`, `Paused`, `Failed`, `Done`).
- Data lives in `Logs\progress\`: `<Computername>.json` (latest state) and `audit-<date>.jsonl` (append-only daily history). Machines are keyed by computer name because a VM's MAC can change.
- Reporting is **best-effort**: it retries a few times, never blocks a deployment, and is silently disabled when `MonitorUrl` is absent from the deploy section. No credentials are stored in progress data.
- JSON only (no XML), so the service is not exposed to the XXE problem of the MDT monitor.
- Follow a machine from a console with `Watch-NDTDeployment`; clean up with `Remove-NDTProgress`.
- For an HTTPS monitor with an internal CA, build the boot image with `New-NDTPEImage -RootCACertName <subject>` so WinPE trusts the root certificate.

---

## Reference images

A reference image is a Windows installation that NDT builds, generalises and captures, so it can be deployed later like any other OS.

1. Register a reference machine in `CustomSettings.json` using the `RefSettings` section (DHCP, workgroup) and the `CreateReferenceImage` deployment group (install NuGet, Windows Update, `Cleanup Image`, then `ReferenceImage`).
2. The last step runs `Applications\CreateReference\Install.ps1`: it generalises with `sysprep /generalize /quit`, writes `DeployCapture.flag`, stages the boot ISO's WinPE on the local disk, adds a ramdisk BCD entry and reboots.
3. WinPE sees the capture flag, removes it, and runs `Capture-ReferenceImage.ps1`, which writes `Reference\<computername>.wim` to the share. The disk is **not** wiped in capture mode.
4. `Move-NDTReferenceImage` moves `Reference\ref-<name>.wim` to `Operating Systems\ref-<name>\<name>.wim` (always overwrites; use `-WhatIf` first).
5. Register it with `Add-NDTOs`, then reference the key from machine blocks.

Windows 11 reference images may need AppX clean-up before sysprep (a package installed for a user but not provisioned makes `/generalize` fail; check `C:\Windows\System32\Sysprep\Panther\setupact.log`).

---

## Drivers

| Folder | Injected into | When |
|---|---|---|
| `Drivers\PE\` | The WinPE boot image | `New-NDTPEImage` (`-DriverPath` overrides). Uses `DISM /Add-Driver /Recurse /ForceUnsigned`, which boot-critical storage drivers need. |
| `Drivers\OS\<Platform>\` | The deployed OS (offline image) | `install.ps1`, right after the image is applied. A subfolder is used when its name appears in the detected `Platform`/`Make`/`Model`/baseboard string, e.g. `VMware`, `Hyper-V`, `Dell`, `HP`, `Lenovo`. Several matches are all injected. |

A missing, empty or non-matching folder is skipped and never blocks deployment. Vendor driver binaries are proprietary and are **not** committed to the repository: see [Drivers/OS/README.md](Drivers/OS/README.md) and [Drivers/PE/VMware/README.md](Drivers/PE/VMware/README.md) (including `Get-VMwarePEDrivers.ps1`, which extracts the VMware NIC/storage drivers from your own VMware Tools installer).

VMware's NIC/storage INFs are gated by OS build, so the WinPE build must match the drivers you stage; on the supported `26100` ADK the Win11-flavour `vmxnet3` driver binds.

---

## Boot media

`New-NDTPEImage` writes two ISOs to `Boot\` (skip both with `-SkipISO`):

| ISO | Firmware | Use |
|---|---|---|
| `boot2026.iso` | Hybrid BIOS/EFI (`MakeWinPEMedia`) | Gen 1 VMs and reference-image capture. Keeps the "Press any key to boot from CD" prompt. |
| `boot2026-uefi.iso` | UEFI-only, no prompt (`oscdimg` + `efisys_noprompt.bin`) | Gen 2 VMs. Boots straight into WinPE, so unattended deployment is not blocked. Secure Boot may stay enabled. |

Both are built from the same staging tree; only the El Torito boot sector differs. The firmware boot order reverts to the disk automatically after the WinPE phase, so the DVD does not need to be ejected between phases.

```powershell
Set-VMDvdDrive -VMName '<vmname>' -Path 'C:\Deploy2026\Boot\boot2026-uefi.iso'   # Gen 2
```

`New-NDTPEImage -PS7` builds a separate, **experimental** image with PowerShell 7 inside WinPE (`boot2026-ps7.*`); it never overwrites the production image and is unsupported by Microsoft. The production image is PowerShell 5.1 only, so shared PE scripts must stay 5.1-compatible.

---

## Folder structure

```
Deploy2026/
├── Boot/
│   ├── boot2026.wim              # WinPE boot image served by WDS
│   ├── boot2026.iso              # Hybrid BIOS/EFI boot ISO (Gen 1, capture)
│   └── boot2026-uefi.iso         # UEFI-only, no-prompt boot ISO (Gen 2)
├── Control/
│   ├── CustomSettings.json       # Per-machine config (keyed by MAC address only)
│   ├── Projects/                 # Optional extra MAC files, any depth (empty in the public repo, never overwritten by Update-NDT)
│   ├── Sections.json             # Shared named sections (locale, network, AD, deploy creds)
│   ├── DeploymentGroups.json     # Named groups of ordered steps referencing DeploymentActions.json keys
│   ├── DeploymentActions.json    # Action definitions: scripts, Reboot, AutoLogon, etc.
│   └── OS.json                   # OS image catalog (WIM path + index per OS key)
├── Operating Systems/            # WIM files for each OS (not in git)
├── Reference/                    # Freshly captured reference WIMs (not in git)
├── Drivers/
│   ├── PE/                       # Drivers injected into the WinPE image
│   └── OS/<Platform>/            # Drivers injected into the deployed OS (VMware, Hyper-V, Dell, HP, Lenovo)
├── Applications/                 # General application installers (PowerShell scripts)
├── Applications2026/             # Company-specific installers (not checked in at Github)
├── Logs/progress/                # NDT Monitor data: <Computername>.json + audit-<date>.jsonl
├── Scripts/
│   └── unattend2026/
│       ├── install.ps1           # WinPE phase: validate, partition, apply image, prepare first-boot
│       ├── install2026.ps1       # First-boot orchestrator (PS5)
│       ├── Install-NDT.ps1       # Post-deployment step engine (PS7)
│       ├── unattend.xml          # Default unattend template with !PLACEHOLDER! tokens
│       ├── Get-MACAddress.ps1    # Resolves the active NIC MAC address
│       ├── Get-OS.ps1            # Resolves WIM path/index from OS.json (-ShareRoot, default Z:\)
│       ├── Get-Hardware.ps1      # Physical/virtual, hypervisor, vendor, model, serial
│       ├── Invoke-NDTSql.ps1     # Parameterised SQL query over TCP with SQL authentication (WinPE PS5/PS7 and OS)
│       ├── Get-Settings.ps1      # Generates unattend.xml from template + the machine's block
│       ├── Import-NDTModule.ps1  # Dot-sourced by the deploy scripts: imports the NDT module from the share (install\NDT)
│       ├── Copy-Install.ps1      # Copies install2026.ps1 and creates settings.json on C:\temp
│       ├── Start-Refresh.ps1     # Run from inside Windows: stages WinPE, one-shot BCD entry, reboots to re-image in place
│       ├── test.ps1              # Standalone test: runs Copy-Install + Get-Settings
│       ├── WindowsPE/            # Files baked into the boot image (Unattend.xml, Deploy\install.ps1 launcher)
│       └── wds/nuke-wds.ps1      # WDS reset utility
├── Scripts/MDT Scripts/          # Legacy MDT scripts, kept for reference only
└── install/
    ├── NDT/                      # The PowerShell module (published to the PowerShell Gallery; also imported by the deploy scripts from the share)
    ├── NDTMonitor/               # IIS progress web service content
    └── Publish-NDT.ps1           # Publishes the module (developer only, not kept on live shares)
```

---

## Configuration

### CustomSettings.json

The central configuration file. Contains one entry per machine, keyed by MAC address:
```json
"00:15:5D:02:56:01": {
  "OS": "WIN2025DCG",
  "Computername": "srv02",
  "IPAddress": "10.0.3.22/24",
  "AdminPassword": "...",
  "Sections": {
    "Locale": "Sweden",
    "NetworkSettings": "NicAuto",
    "ADSettings": "ADJoinCorp"
  },
  "DeploymentGroups": ["General Settings", "SMC"]
}
```

| Key | Meaning |
|---|---|
| `OS` | Key into `OS.json`. May instead come from a referenced section. |
| `Computername`, `IPAddress` | `IPAddress` is `a.b.c.d/nn`; omit or `DHCP` for DHCP. |
| `AdminPassword` | Local administrator password (also used for AutoLogon). |
| `Sections` | Label to section-name map into `Sections.json`. Only the value is used; the label is cosmetic. |
| `DeploymentGroups` | Ordered list of groups from `DeploymentGroups.json`. Omit for an OS-only deployment. |
| `Install` | `"NO"` disables deployment for this machine (reboot, no disk wipe). Any other value deploys. |
| `Deploy` | Name of the deploy section to use (default `Deploy`). |
| `FinishAction` | `DESKTOP` (default), `PROMPT`, `REBOOT`, `SHUTDOWN`, `LOGOFF`; overrides the deploy section. |
| `PostPEScript` | Share-relative PowerShell 5 script run in WinPE right after the image is applied. |
| any other key | Passed as a script parameter when a `DeploymentActions.json` entry lists it under `Parameters`. |

Merge rule: machine keys always win; sections only fill keys the machine does not set, and between sections the first one in order wins.

#### Projects (per-project machine files)

To keep groups of servers apart (per project, per customer, one file per server), put JSON files with MAC blocks under `Control/Projects/`. The format is identical to `CustomSettings.json`; one file may hold one or many MAC blocks, and folder and file names are free (any depth, `*.json` only).

```
Control/
├── CustomSettings.json          # still read, merged with Projects
└── Projects/
    ├── ProjectA/
    │   ├── web-tier.json        # many MAC blocks
    │   └── sql01.json           # one server
    └── Customer-X.json
```

- The effective machine set is `CustomSettings.json` plus every `Projects/**/*.json`. Only MAC-shaped keys count (case-insensitive, normalised to upper case); other keys (e.g. `"_Project": "..."`) are ignored. Empty files are skipped; a missing `Projects` folder adds nothing.
- **A MAC defined more than once (in the same or different files) aborts deployment**, as does an invalid JSON file. Both are reported in WinPE before the disk is touched, and `Test-NDTDeployment` flags them. Because uniqueness is checked across the whole set, one bad file blocks every deployment on the share until fixed.
- To park a machine, set `"Install": "NO"` in its block.
- `Control/Projects` is empty in the public repo (only a `.gitkeep`), and `Update-NDT` never removes or overwrites anything in it.
- `Get-NDTComputer` returns a `SourceFile` property (relative to `Control`); `Add-NDTComputer -File <name>` writes to `Control\Projects\<name>.json`; `Set-`/`Remove-NDTComputer` write back to whichever file holds the MAC (removing the last MAC leaves `{}`, the file is never deleted).
- `AdminPassword` lives in each MAC block, so it ends up in every project file - same share ACL, but more places to clean up.
- Only MAC blocks are split this way; `Sections.json`, `DeploymentGroups.json` and `DeploymentActions.json` stay single files.

### Sections.json

Shared named sections referenced from MAC blocks. Merged into a machine's effective settings at deploy time:
```json
"Sweden": { "InputLocale": "sv-SE", "UILanguage": "sv-SE", ... },
"ADJoinCorp": { "JoinDomain": "corp.dev", "Domain": "corp", ... },
"Deploy": { "Share": "\\\\server\\Deploy2026", "Username": "...", "Password": "..." }
```

The `Deploy` section (stamped by `Install-NDT`) holds the share, the deploy credentials and the optional `MonitorUrl`, `MapTimeoutSec` and `FinishAction`. Deploy sections are selected by the machine-level `Deploy` key, not through `Sections`. AutoLogon credential sections (e.g. `ADLogon-AD01`, with `Username` + `Password`) are reached by name from a step's `Reference` in `DeploymentGroups.json`, which points at a `DeploymentActions.json` entry of `"Type": "AutoLogon"`; the key names must match.

### DeploymentGroups.json

Named groups of ordered steps. Each step has a `Reference` key into `DeploymentActions.json`:
```json
"General Settings": {
  "Step1": { "Description": "Admin password never expires", "Reference": "Admin password never expires" },
  "Step2": { "Description": "Disable WAC popup",           "Reference": "DisableWACPopup" }
}
```

### DeploymentActions.json

Action definitions — what to run:
```json
"Install App2026": {
  "Script": "\\Applications\\App2026\\install01.ps1",
  "Parameters": ["SQLServer", "AlwaysOn"]
},
"Install Critical App": {
  "Script": "\\Applications\\Critical\\install.ps1",
  "ContinueOnError": false   // optional; false = stop deployment if the script fails (default: continue)
},
"Reboot":           { "Type": "Reboot" },
"ADLogon-AD01":     { "Type": "AutoLogon" },  // Reference name must match a key in Sections.json
"ADLogon-AD02":     { "Type": "AutoLogon" },
"WindowsUpdate": { "Type": "WindowsUpdate", "Script": "\\Applications\\WindowsUpdate\\install.ps1" },
"Pause":   { "Type": "Pause", "Description": "Pause deployment for manual intervention" }
```

### OS.json

Maps OS keys to WIM file paths and image indexes. An optional `Unattend` key (share-relative, e.g. `\Scripts\unattend2026\unattend-win11.xml`) selects an OS-specific answer file; absent or missing falls back to the default `unattend.xml`. Keep one default template and use a dedicated file only when an OS needs a structurally different answer file.
```json
"WIN2025DCG": { "Path": "Operating systems\\ref-w2025dcg\\w2025dcg.wim", "Index": 1 }
```

---

## SQL access

`Scripts\unattend2026\Invoke-NDTSql.ps1` runs a parameterised T-SQL statement against SQL Server over TCP (default port 1433) with a SQL login. It uses `System.Data.SqlClient`, so the same script works in the production WinPE (PowerShell 5.1 with `WinPE-NetFx`), in the experimental PowerShell 7 WinPE and in a normal OS. NDT does not use SQL for its own lookups yet; this is groundwork for broader lookups. There is no named-pipe, IPC$ or SQLShare mode.

Connection settings live in a section of `Sections.json` (default name `NDTSql`; mark it `"System": true` so it is not offered as a machine section). `Update-NDT` never changes an existing `Sections.json`, so add the section by hand:

```json
"NDTSql": {
  "System": true,
  "Server": "sql01.example.com",
  "Port": 1433,
  "Database": "NDT",
  "Username": "ndt_reader",
  "Password": "...",
  "Encrypt": true,
  "TrustServerCertificate": false
}
```

```powershell
& Z:\Scripts\unattend2026\Invoke-NDTSql.ps1 -Query 'SELECT * FROM Machines WHERE Mac = @mac' -Parameter @{ mac = $macAddress }
```

`-Mode Rows` (default) returns one object per row, `Scalar` the first value, `NonQuery` the affected-row count. Use a read-only login: the credentials are plaintext on the share, like the deploy credentials, and are read after the share is mapped (never baked into the WIM). With `Encrypt` on, WinPE must trust the server certificate; build the boot image with `New-NDTPEImage -RootCACertName <subject>` for an internal CA. Use the server FQDN and a fixed port (a named instance needs the SQL Browser service). The framework's `System.Data.SqlClient` does not support TDS 8.0 strict encryption.

---

## Applications

`Applications\` holds generic installers (PowerShell scripts) that deployment groups reference through `DeploymentActions.json`, for example ADK, PowerShell 7, PSGallery/NuGet, VMware Tools, NPP, WDS, IIS, Windows Update, SQL Server 2025 (including Always On), PKI (root CA, enterprise CA, PSPKI), ADDS, iPXE and the `Pause` step. Site-specific installers go in `Applications2026\`, which is not checked in.

A `Script` action runs `.ps1` with PowerShell 7 by default, `"PowerShell": "powershell5"` for PowerShell 5.1, or `.cmd`/`.bat` with cmd.exe. `Parameters` names keys to pull from the machine's effective settings.

---

## PowerShell module

The `NDT` module (`install\NDT`, published to the PowerShell Gallery) is used to provision, upgrade and administer the share. Use PowerShell 7 to import it; commands that need Windows PowerShell 5.1 (IIS, WDS) relaunch themselves under `powershell.exe`.

The module also lives on the share (`install\NDT`) and is imported by WinPE, the first-boot step engine and `Start-Refresh.ps1`, so the rules that decide which machine block, OS, deploy section and effective settings apply exist once and `Test-NDTDeployment` checks what deployment really does. The deploy scripts stop with an error if `install\NDT` is missing; run `Update-NDT` to restore it. The module is not part of the boot image.

| Command | Purpose |
|---|---|
| `Install-NDT` | Bootstrap a new share: download code, stamp the `Deploy` section, create the SMB share (deploy account Full, Everyone revoked), install the monitor. |
| `Update-NDT` | In-place upgrade of code; see [Updating NDT](#updating-ndt). |
| `Install-NDTMonitor` | Install the NDT Monitor IIS service (idempotent). |
| `New-NDTPEImage` | Build the WinPE WIM and both ISOs, inject drivers, update the WDS boot image (`-SkipISO`, `-SkipWDS`, `-RegisterOnly`, `-DriverPath`, `-RootCACertName`, `-PS7`). |
| `Get-/Add-/Set-/Remove-NDTComputer` | Manage machine blocks in `CustomSettings.json` and `Control\Projects\**\*.json` (`Add-NDTComputer -File` picks the Projects file; `SourceFile` on `Get-NDTComputer` output). |
| `Get-/Add-/Set-/Remove-NDTOs` | Manage the OS catalog in `OS.json` (`-Unattend` sets the per-OS template). |
| `Move-NDTReferenceImage` | Publish captured WIMs from `Reference\` to `Operating Systems\`. |
| `Test-NDTDeployment` | Read-only dry run for a MAC: machine block and its source file, duplicate/unreadable machine files, sections, OS key, WIM, groups, actions, script paths, finish action. Returns `$true`/`$false`. |
| `Watch-NDTDeployment` | Live progress bar for a machine until it reports Done. |
| `Remove-NDTProgress` | Delete a machine's monitor progress file. |
| `New-NDTComputerTui` | PowerShell 7 terminal form for adding a computer (needs `Microsoft.PowerShell.ConsoleGuiTools`). |
| `Get-NDTCatalog`, `Test-NDTComputerEntry` | Read-only helpers for front ends. |
| `Get-NDTMachine`, `Get-NDTEffectiveSetting`, `Resolve-NDTMachineOS`, `Resolve-NDTDeploySection`, `Test-NDTInstallDisabled` | Lookups the deploy scripts use at run time (merged machine set, effective settings, OS and deploy-section resolution, the `Install:NO` guard). |

See [install/NDT/README.md](install/NDT/README.md) for the module's own page.

---

## Updating NDT

- **Share content**: `Update-NDT` downloads the repository and copies the code over the share. It **preserves** `Control\*.json` and `Control\Projects\` (new control files are added, existing ones untouched), the stamped credentials, WIMs, certificates, `Applications2026\`, `Reference\` and `Logs\`. It does not re-create the SMB share or change permissions. A timestamped backup of `Control\` and `install\` is taken first (`-NoBackup` skips it). Before anything is copied, the new module is import-tested under Windows PowerShell 5.1 and PowerShell 7; if it fails, nothing on the share is changed. `install\NDT` is replaced through a temporary folder. After `Install-NDT`/`Update-NDT` the repo-only files (`.github`, `.vscode`, `.gitignore`, `README.md`) and `install\Publish-NDT.ps1` are removed from the live share; `install\NDT` stays because the deploy scripts import it.
- **The module itself**: update an AllUsers install with `Install-Module NDT -Force -Scope AllUsers`, and do this **before** running `Update-NDT` (an older module's `Update-NDT` still removes `install\NDT` from the share, which stops the deploy scripts). Do **not** use `Update-Module` on PowerShellGet 2.x; it installs to CurrentUser and the newer copy then shadows the AllUsers one.
- **Boot image**: rebuild with `New-NDTPEImage` after changing `install.ps1`, drivers or the WinPE launcher, since those are baked into the WIM.

---

## Notes and limitations

- **WDS needs Desktop Experience.** Server Core only offers the Transport Server role service, which has no image store. Boot ISOs and `Start-Refresh.ps1` work without WDS.
- **Secure Boot.** Hyper-V Gen 2 VMs boot the Microsoft-signed WDS/WinPE chain with Secure Boot on. The iPXE option in `Applications\iPXE` is unsigned and therefore only for lab, physical or Secure-Boot-off use.
- **WDS on Hyper-V.** If PXE transfers are flaky, disable the TFTP variable window (`wdsutil /Set-Server /Transport /EnableTFTPVariableWindowExtension:No`); `Applications\WDS\install.ps1` does this.
- **Start-Refresh.ps1** wipes disk 0 and has no user-state backup/restore (not an MDT Refresh with USMT).
- **Credentials.** `Control\*.json` and `C:\temp\settings.json` contain plaintext credentials. Restrict the share to the deploy account; when deployment completes `settings.json` is moved to `C:\Windows\Temp\DeploymentLogs` with the Administrator and Deploy passwords blanked.
- **PE build.** DISM unmount error `0xc1420117` means something (usually Defender) holds a handle in the mount folder; `New-NDTPEImage` adds Defender exclusions and retries the unmount.
- **Windows 11.** The shared `unattend.xml` skips machine/user OOBE and pins AutoLogon to the local account; without that, Win11 clears AutoLogon on domain-joined machines.

### Conventions for contributors

- `.ps1`/`.psm1` files must be **plain ASCII** (no em/en dashes, curly quotes or arrows, even in comments): Windows PowerShell 5.1 reads BOM-less files as Windows-1252 and fails to parse them.
- Scripts that run in WinPE, `install2026.ps1` or both must stay **PowerShell 5.1-compatible**.
- Paths inside the JSON files use backslashes rooted at the share root; MAC addresses are colon-separated and uppercase.
- `C:\temp\install-steps.json` tracks step progress; never delete it during a deployment (after completion it is in `C:\Windows\Temp\DeploymentLogs`).

---

## Links

- Project: https://github.com/AB-Lindex/NDT-NextGenerationDeploymentToolkit

---

## In progress / planned / done

- Reference image creation - Done
- Build script to set up the NDT server - Done
- Create Pause step, just like MDT - Done
- Create an F8 similar solution in PE - Done(ish)
- Core, gui and alse Windows 11 - Done
- Simple update of NDT deployment share - Done
- inject drivers into PE and OS - Done
- PE with PS7 support - Done
- Install OS from within OS - Done (Start-Refresh.ps1)
- Deployment monitoring (NDT Monitor, Watch-NDTDeployment) - Done
- Hardware detection - Done
- Terminal form for adding computers (New-NDTComputerTui) - Done
- User-state backup/restore for in-place refresh - Not planned yet
