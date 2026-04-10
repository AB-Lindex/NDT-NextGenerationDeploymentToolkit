# NDT — Next Deployment Tool

A lightweight PowerShell-based replacement for MDT (which is now EOL).  
The goal is to keep it simple: PowerShell 5 and 7, WDS/PXE for network boot, JSON files for all configuration, no GUI.

> **Status:** PGD — Pretty Good Deployment 🙂  
> No formal version numbers yet.
See my first video of a deployment here:
https://www.youtube.com/watch?v=8z-uKonbEoE
---

## How it works

Deployment flows through two phases.

### Phase 1 — Windows PE (PXE boot)

The machine PXE-boots from WDS and loads `Boot/boot2026.wim`.  
`Scripts/unattend2026/install.ps1` runs and performs:

1. Checks for a capture-mode flag — if present it runs reference image capture instead of a normal deployment.
2. Detects firmware type (BIOS/Gen1 or UEFI/Gen2) — recorded early but disk is not touched until all validations pass.
3. Looks up the machine by MAC address in `Control/CustomSettings.json`; aborts if not found.
4. Resolves and validates the OS image path and index from `Control/OS.json`; aborts if WIM file not found.
5. All pre-flight checks passed — partitions disk 0 with diskpart (GPT/EFI for UEFI; MBR/active for BIOS).
6. Applies the OS image to `C:\` with DISM.
7. Copies `install2026.ps1` and a `settings.json` (deploy share credentials + local admin password) to `C:\temp`.
8. Generates `unattend.xml` from the template, replacing placeholders with values from `CustomSettings.json`.
9. Applies `unattend.xml` to the offline image and runs BCDBoot.

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
2. Loads the ordered steps for each group from `DeploymentGroups.json`; resolves each step's action from `Deployment.json`.
3. Tracks completed steps in `C:\temp\install-steps.json` so deployment can resume after a reboot exactly where it left off.
4. Supports five step types:
   - **Script** — runs a `.ps1`, `.cmd`, or `.bat` file from the Applications folder, with optional parameters from `CustomSettings.json`. Can target PowerShell 5, PowerShell 7, or cmd.exe.
   - **Reboot** — saves progress, writes AutoLogon credentials to the registry, calls `shutdown /r /t 10`, and exits with code `3010` so the parent script knows to write `reboot.flag` and skip cleanup.
   - **AutoLogon** — switches the AutoAdminLogon account (e.g. to a domain account) mid-deployment, useful for operations that must run as an AD user (gMSA creation, cluster setup, SQL Always On, etc.).
   - **WindowsUpdate** — runs the Windows Update script; if it exits `3010` the step is not marked complete and the engine exits `3010` (iterates until no reboot is needed); if it exits `0` the step is marked complete.
   - **Pause** — creates a "Continue Deployment" shortcut on `C:\Users\Public\Desktop`, marks the step complete, and exits `3011` so the parent script removes RunOnce (a reboot while paused does not auto-resume).

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
│   ├── CustomSettings.json       # Per-machine config (keyed by MAC address only)
│   ├── Sections.json             # Shared named sections (locale, network, AD, deploy creds)
│   ├── DeploymentGroups.json     # Named groups of ordered steps referencing Deployment.json keys
│   ├── Deployment.json           # Action definitions: scripts, Reboot, AutoLogon, etc.
│   └── OS.json                   # OS image catalog (WIM path + index per OS key)
├── Operating Systems/            # WIM files for each OS
├── Applications/                 # General application installers
├── Applications2026/             # Company-specific installers (not checked in at Github)
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
  "DeploymentSteps": ["General Settings", "SMC"]
}
```

### Sections.json

Shared named sections referenced from MAC blocks. Merged into a machine's effective settings at deploy time:
```json
"Sweden": { "InputLocale": "sv-SE", "UILanguage": "sv-SE", ... },
"ADJoinCorp": { "JoinDomain": "corp.dev", "Domain": "corp", ... },
"Deploy": { "Share": "\\\\server\\Deploy2026", "Username": "...", "Password": "..." }
```

### DeploymentGroups.json

Named groups of ordered steps. Each step has a `Reference` key into `Deployment.json`:
```json
"General Settings": {
  "Step1": { "Description": "Admin password never expires", "Reference": "Admin password never expires" },
  "Step2": { "Description": "Disable WAC popup",           "Reference": "DisableWACPopup" }
}
```

### Deployment.json

Action definitions — what to run:
```json
"Install App2026": {
  "Script": "\\Applications\\App2026\\install01.ps1",
  "Parameters": ["SQLServer", "AlwaysOn"]
},
"Reboot":  { "Type": "Reboot" },
"ADLogon": { "Type": "AutoLogon" },
"WindowsUpdate": { "Type": "WindowsUpdate", "Script": "\\Applications\\WindowsUpdate\\install.ps1" },
"Pause":   { "Type": "Pause", "Description": "Pause deployment for manual intervention" }
```

### OS.json

Maps OS keys to WIM file paths and image indexes:
```json
"WIN2025DCG": { "Path": "Operating systems\\ref-w2025dcg\\w2025dcg.wim", "Index": 1 }
```

---

## In progress / planned

- Reference image creation - Done
- Build script to set up the NDT server - Done
- Create Pause step, just like MDT - Done
- Review JSON structure — files are growing, may split them - Done
- Create an F8 similar solution in PE - Done

- more verbose and helpful in Pause step
- "double"check that everything works in both core and Gui situations, they differ some!

