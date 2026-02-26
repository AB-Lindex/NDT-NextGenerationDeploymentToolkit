# NDT — Next Deployment Tool

A lightweight PowerShell-based replacement for MDT (which is now EOL).  
The goal is to keep it simple: PowerShell 5 and 7, WDS/PXE for network boot, JSON files for all configuration, no GUI.

> **Status:** PGD — Pretty Good Deployment 🙂  
> No formal version numbers yet.

---

## How it works

Deployment flows through two phases.

### Phase 1 — Windows PE (PXE boot)

The machine PXE-boots from WDS and loads `Boot/boot2026.wim`.  
`Scripts/unattend2026/install.ps1` runs and performs:

1. Checks for a capture-mode flag — if present it runs reference image capture instead of a normal deployment.
2. Detects firmware type (BIOS/Gen1 or UEFI/Gen2) and partitions the disk with diskpart accordingly.
3. Looks up the machine by MAC address in `Control/CustomSettings.json`.
4. Resolves the OS image path and index from `Control/OS.json` and applies it with DISM.
5. Copies `install2026.ps1` and a `settings.json` (deploy share credentials + local admin password) to `C:\temp`.
6. Generates `unattend.xml` from the template, replacing placeholders with values from `CustomSettings.json`.
7. Applies `unattend.xml` to the offline image and runs BCDBoot.

### Phase 2 — First boot and post-deployment steps

`unattend.xml` bootstraps the deployment automatically on first logon via two mechanisms (both are needed to cover sysprepped and clean images):

- **specialize pass** — writes `RunOnce\Deploy2026` and enables AutoAdminLogon so the script fires even if OOBE is skipped.
- **oobeSystem FirstLogonCommands** — directly launches `install2026.ps1` for sysprepped images that run OOBE.

`install2026.ps1` runs under PowerShell 5 (via RunOnce/FirstLogonCommands) and:

1. Exits immediately if `C:\temp\deploy-complete.flag` exists (prevents double-run caused by both mechanisms firing on the same logon).
2. Handles the reboot-flag (`C:\temp\reboot.flag`) to distinguish a re-logon loop from a genuine completed reboot.
3. Re-registers `RunOnce\Deploy2026` so deployment survives any intermediate reboots.
4. Maps the deployment share from credentials in `C:\temp\settings.json`.
5. Installs PowerShell 7 if not already present.
6. Launches `Install-NDT.ps1` via `pwsh.exe` (PS7) as a child process.

`Install-NDT.ps1` runs under PowerShell 7 and drives all post-deployment work:

1. Reads the machine's deployment groups from `CustomSettings.json` (matched by MAC address).
2. Loads the ordered steps for each group from `Deployment.json`.
3. Tracks completed steps in `C:\temp\install-steps.json` so deployment can resume after a reboot exactly where it left off.
4. Supports three step types:
   - **Script** — runs a `.ps1`, `.cmd`, or `.bat` file from the Applications folder, with optional parameters from `CustomSettings.json`. Can target PowerShell 5, PowerShell 7, or cmd.exe.
   - **Reboot** — saves progress, writes AutoLogon credentials to the registry, calls `shutdown /r`, and exits with code `3010` so the parent script knows to write `reboot.flag` and skip cleanup.
   - **AutoLogon** — switches the AutoAdminLogon account (e.g. to a domain account) mid-deployment, useful for operations that must run as an AD user (gMSA creation, cluster setup, SQL Always On, etc.).

When all steps are done with no pending reboot, `install2026.ps1`:
- Unmounts the deployment share.
- Removes `RunOnce\Deploy2026` and disables AutoAdminLogon.
- Writes `C:\temp\deploy-complete.flag`.
- Removes `C:\temp\settings.json` and `C:\temp\install2026.ps1`.

---

## Folder structure

```
Deploy2026/
├── Boot/
│   └── boot2026.wim              # WinPE boot image served by WDS
├── Control/
│   ├── CustomSettings.json       # Per-machine config (keyed by MAC) + shared sections
│   ├── Deployment.json           # Deployment groups and step definitions
│   └── OS.json                   # OS image catalog (WIM path + index per OS key)
├── Operating Systems/            # WIM files for each OS
├── Applications/                 # General application installers
├── Applications2026/             # Product-specific installers
├── Scripts/
│   └── unattend2026/
│       ├── install.ps1           # WinPE phase: partition, apply image, prepare first-boot
│       ├── install2026.ps1       # First-boot orchestrator (PS5)
│       ├── Install-NDT.ps1       # Post-deployment step engine (PS7)
│       ├── unattend.xml          # Unattend template with !PLACEHOLDER! tokens
│       ├── Get-MACAddress.ps1    # Resolves the active NIC MAC address
│       ├── Get-OS.ps1            # Resolves WIM path/index from OS.json
│       ├── Get-Settings.ps1      # Generates unattend.xml from template + CustomSettings.json
│       └── Copy-Install.ps1      # Copies install2026.ps1 and creates settings.json on C:\temp
└── MDT-Scripts/                  # Retained MDT scripts (reference / legacy)
```

---

## Configuration

### CustomSettings.json

The central configuration file. Has two types of entries:

**Per-machine block** (keyed by MAC address):
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
  "DeploymentSteps": ["General Settings", "SMC"]
}
```

**Shared section blocks** (referenced by name from `Sections` or step `Reference`):
```json
"Sweden": { "InputLocale": "sv-SE", "UILanguage": "sv-SE", ... },
"ADJoinCorp": { "JoinDomain": "corp.dev", "Domain": "corp", ... },
"Deploy": { "Share": "\\\\server\\Deploy2026", "Username": "...", "Password": "..." }
```

### Deployment.json

Defines named deployment groups, each containing ordered steps that reference action entries:

```json
"SQL2025": {
  "Step1": { "Description": "ADLogon",         "Reference": "ADLogon" },
  "Step2": { "Description": "Reboot server",   "Reference": "Reboot" },
  "Step3": { "Description": "Install App2026", "Reference": "Install App2026" }
}
```

Action entries define what to run:
```json
"Install App2026": {
  "Script": "\\Applications\\App2026\\install01.ps1",
  "Parameters": ["SQLServer", "AlwaysOn"]
},
"Reboot": { "Type": "Reboot" },
"ADLogon": { "Type": "AutoLogon" }
```

### OS.json

Maps OS keys to WIM file paths and image indexes:
```json
"WIN2025DCG": { "Path": "Operating systems\\ref-w2025dcg\\w2025dcg.wim", "Index": 1 }
```

---

## In progress / planned

- Reference image creation
- Build script to set up the NDT server
- Review JSON structure — files are growing, may split them

