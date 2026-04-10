# NDT — Copilot Context

NDT (Next Deployment Tool) is a lightweight PowerShell-based replacement for MDT (EOL).
No GUI. No XML wizards. Everything is driven by PowerShell 5/7 and three JSON files.
WDS/PXE handles network boot. The deploy share is a standard Windows SMB share.

---

## Workspace layout

```
Deploy2026/                        ← root of the SMB share (\\dc01.corp.dev\Deploy2026)
├── Boot/boot2026.wim              ← WinPE image served by WDS
├── Control/
│   ├── CustomSettings.json        ← per-machine config keyed by MAC + shared sections
│   ├── DeploymentGroups.json      ← named groups: ordered steps referencing Deployment.json keys
│   ├── Deployment.json            ← action definitions: scripts, Reboot, AutoLogon
│   └── OS.json                    ← OS catalog: key → WIM path + index
├── Operating Systems/             ← WIM files
├── Applications/                  ← generic app installers (PS scripts)
├── Applications2026/              ← site-specific installers (not in git)
├── Scripts/unattend2026/
│   ├── install.ps1                ← WinPE phase script
│   ├── install2026.ps1            ← first-boot orchestrator (PS 5)
│   ├── Install-NDT.ps1            ← post-deploy step engine (PS 7)
│   ├── unattend.xml               ← unattend template with !PLACEHOLDER! tokens
│   ├── Get-MACAddress.ps1
│   ├── Get-OS.ps1
│   ├── Get-Settings.ps1           ← fills unattend.xml from CustomSettings.json
│   ├── Copy-Install.ps1           ← drops install2026.ps1 + settings.json to C:\temp
│   ├── test.ps1                   ← standalone test: runs Copy-Install + Get-Settings
│   ├── wds/
│   │   └── nuke-wds.ps1           ← WDS reset utility (stop, wipe RemoteInstall, reinit, add WIM)
│   └── WindowsPE/
│       ├── Unattend.xml           ← WinPE auto-run unattend (wpeinit → install.ps1)
│       └── Deploy/
│           └── install.ps1        ← WinPE launcher: maps Z: from X:\Deploy\settings.json, calls install.ps1
├── MDT-Scripts/                   ← legacy MDT helper scripts (reference only)
└── install/                       ← PowerShell module to bootstrap a new NDT server
    ├── NDT/
    │   ├── ndt.psm1               ← module script (exports all NDT-* commands)
    │   └── ndt.psd1               ← module manifest (requires PS 5.1)
    ├── ndt.nuspec                 ← NuGet package spec (reference; PSGallery uses psd1)
    └── Publish-NDT.ps1            ← publishes the module to PSGallery
```

---

## Two-phase deployment flow

### Phase 1 — WinPE (`install.ps1`)

1. Check capture flag (`DeployCapture.flag` on any drive) → if set, remove flag, clean `C:\temp`, call `Capture-ReferenceImage.ps1`, exit.
2. Detect BIOS/UEFI firmware type — recorded early but **disk is not touched** until all validations pass.
3. Validate MAC address against `Control/CustomSettings.json`; abort with error if not found.
4. Resolve and validate WIM path + index from `Control/OS.json`; abort if WIM file not found.
5. All pre-flight checks passed → partition disk 0 with diskpart (GPT/EFI for UEFI; MBR/active for BIOS).
6. Apply OS image to `C:\` with DISM.
7. Run `Copy-Install.ps1` → copies `install2026.ps1` and writes `settings.json` (share credentials + admin password) to `C:\temp`.
8. Run `Get-Settings.ps1` → generates `unattend.xml` from template (replaces `!PLACEHOLDER!` tokens); apply to offline image with DISM.
9. Run BCDBoot (UEFI: `/f UEFI /s S:` ; BIOS: `/f BIOS /s C:`), set BCD timeout 0, then `wpeutil Reboot`.

### Phase 2 — First boot (`install2026.ps1`, PS 5)

Accepts an optional `-Resume` switch (used by the "Continue Deployment" desktop shortcut after a Pause step).

1. Skip if `C:\temp\deploy-complete.flag` exists (prevents double-run).
2. Check `C:\temp\pause.flag` — if present and `-Resume` not passed, exit immediately (deployment is paused); if `-Resume`, delete the flag and continue.
3. Handle `C:\temp\reboot.flag` — compare flag timestamp to last-boot time to distinguish re-logon from completed reboot. If flag is newer than boot time, exit (reboot still pending); otherwise delete flag and continue.
4. Re-register `RunOnce\Deploy2026` to survive intermediate reboots.
5. Remove "Continue Deployment" desktop shortcut from `C:\Users\Public\Desktop` if present.
6. Map the deploy share using credentials from `C:\temp\settings.json`.
7. Install PS 7 if absent (probes `%ProgramFiles%\PowerShell\7\pwsh.exe` directly — not `Get-Command`, since PS 5 `$PATH` is frozen at launch).
8. Launch `Install-NDT.ps1` via `pwsh.exe` (PS 7) as a **child process**; inspect `$LASTEXITCODE`:
   - `0` → all steps done; unmap share, remove RunOnce + AutoLogon, write `deploy-complete.flag`.
   - `3010` → reboot step; write `reboot.flag`, unmap share, exit 0 (RunOnce remains, resumes after reboot).
   - `3011` → pause step; write `pause.flag`, **remove** RunOnce (so reboot while paused does NOT auto-resume), unmap share.

### Phase 2 continued — Step engine (`Install-NDT.ps1`, PS 7)

1. Read machine's `DeploymentSteps` from `CustomSettings.json` (matched by MAC).
2. Load ordered steps from `DeploymentGroups.json` for each group; resolve each step's action from `Deployment.json`.
3. Track progress in `C:\temp\install-steps.json` — resumes after reboot at the next pending step.
4. Execute steps by type:
   - **Script** — run `.ps1` (default: pwsh/PS 7), `.ps1` with `"PowerShell": "powershell5"` (PS 5.1), or `.cmd`/`.bat` (cmd.exe). Optional `Parameters` array names keys to pull from `CustomSettings.json`.
   - **Reboot** — mark step complete, write AutoLogon to registry, `shutdown /r /t 10`, exit 3010.
   - **AutoLogon** — switch the AutoAdminLogon account mid-deployment (used for AD/SQL operations); also updates `settings.json` so subsequent Reboot steps use the new credentials.
   - **WindowsUpdate** — runs the WU script; if it exits 3010 the step is **not** marked complete and the engine exits 3010 (iterates until no reboot is needed); if it exits 0 the step is marked complete.
   - **Pause** — creates a "Continue Deployment" shortcut on `C:\Users\Public\Desktop`, marks step complete, exits 3011.
5. On completion: engine exits 0. `install2026.ps1` then unmaps share, removes RunOnce + AutoLogon, writes `deploy-complete.flag`.

---

## Control file schemas

### CustomSettings.json

Two kinds of top-level keys:

**MAC address block** — one per machine:
```jsonc
"00:15:5D:02:56:01": {
  "OS": "WIN2025DCG",          // key into OS.json
  "Computername": "srv02",
  "IPAddress": "10.0.3.22/24", // omit or "DHCP" for DHCP
  "AdminPassword": "...",
  "SQLServer": "SQL2025",       // arbitrary extra keys passed as script parameters
  "AlwaysOn": "AO2025",
  "Sections": {
    "Locale": "Sweden",         // merged into the machine's effective settings
    "NetworkSettings": "NicAuto",
    "ADSettings": "ADJoinCorp"
  },
  "DeploymentSteps": ["General Settings", "SMC"]
}
```

**Named section block** — shared, referenced by name:
```jsonc
"Sweden":      { "InputLocale": "sv-SE", "SystemLocale": "sv-SE", "UILanguage": "sv-SE", "UserLocale": "sv-SE", "TimeZone": "W. Europe Standard Time" },
"NicAuto":     { "DefaultGateway": "10.0.3.1", "DNSServers": "10.0.3.11" },
"ADJoinCorp":  { "JoinDomain": "corp.dev", "Domain": "corp", "OU": "ou=Servers,dc=corp,dc=dev", "User": "ADJoin2026", "Password": "..." },
"RefSettings": { "Sysprep": "Generalize", "Shutdown": "Shutdown", "IPAddress": "DHCP", "JoinDomain": "WORKGROUP", ... },
"Deploy":      { "Share": "\\\\dc01.corp.dev\\Deploy2026", "Username": "Corp\\Deploy2026", "Password": "..." },
"ADLogon":     { "Username": "Corp\\ADLogon", "Password": "..." }
```

### DeploymentGroups.json

Named groups of ordered steps. Each step has a `Reference` key into `Deployment.json`:
```jsonc
"General Settings": {
  "Step1": { "Description": "Admin password never expires", "Reference": "Admin password never expires" },
  "Step2": { "Description": "Disable WAC popup",           "Reference": "DisableWACPopup" }
}
```

### Deployment.json

Action definitions only — what to run (three forms):
```jsonc
"Install App2026": { "Script": "\\Applications\\App2026\\install01.ps1", "Parameters": ["SQLServer", "AlwaysOn"] },
"Install App PS5":  { "Script": "\\Applications\\App2026\\install01.ps1", "PowerShell": "powershell5" },
"Reboot":           { "Type": "Reboot",         "Description": "Restart the computer" },
"ADLogon":          { "Type": "AutoLogon",       "Description": "Configure automatic logon" },
"WindowsUpdate":    { "Type": "WindowsUpdate",   "Script": "\\Applications\\WindowsUpdate\\install.ps1" },
"Pause":            { "Type": "Pause",           "Description": "Pause deployment for manual intervention" }
```

### OS.json

```jsonc
"WIN2025DC":  { "Path": "Operating Systems\\VL Server 2025 2509\\sources\\install.wim", "Index": 3 },
"WIN2025DCG": { "Path": "Operating systems\\ref-w2025dcg\\w2025dcg.wim",               "Index": 1 }
```

---

## install/ module (`Install-NDT`)

Used **once** to provision a new NDT server. Import with:

```powershell
Import-Module C:\Deploy2026\install\NDT\ndt.psd1
Install-NDT   # DeployPassword is mandatory — you will be prompted
```

Parameters:

| Parameter | Required | Default |
|---|---|---|
| `LocalPath` | optional | `C:\Deploy2026` |
| `ShareName` | optional | `Deploy2026` |
| `ShareUNC` | optional | `\\<hostname>\Deploy2026` |
| `DeployUsername` | optional | `Corp\Deploy2026` |
| `DeployPassword` | **mandatory** | *(SecureString — prompted if omitted)* |
| `RepoZipUrl` | optional | GitHub main-branch ZIP of this repo |

Downloads the repository ZIP from GitHub → extracts into `LocalPath` → removes repo-only artefacts (`.github`, `.vscode`, `.gitignore`, `README.md`) that must not exist on a live deployment share → stamps the `Deploy` section of `Control\CustomSettings.json` with the supplied parameters → creates SMB share → grants deploy account Full Access → revokes Everyone access.

Also exported by the module (see `ndt.psd1`):
- `Build-NDTPEImage` — builds the WinPE WIM + optional ISO; updates WDS boot image.
- `Get-NDTServer` / `Add-NDTServer` / `Set-NDTServer` / `Remove-NDTServer`
- `Get-NDTOs` / `Add-NDTOs` / `Set-NDTOs` / `Remove-NDTOs`
- `Move-NDTReferenceImage` — moves captured WIM files from `\Reference\` into `\Operating Systems\`. For each `ref-<name>.wim` the destination is `Operating Systems\ref-<name>\<name>.wim` (folder = full stem, file = stem without the `ref-` prefix). Always overwrites; use `-WhatIf` for a dry run.
- `Test-NDTDeployment` — dry-run validation for a given MAC address: checks CustomSettings.json entry, referenced sections, OS.json key, WIM file existence, DeploymentGroups.json groups, Deployment.json references, and script file paths. Returns `$true` / `$false`.

---

## Key conventions

- All paths inside JSON files use **backslash**, rooted at the deploy share root (e.g. `\Applications\App2026\install01.ps1`).
- MAC addresses in `CustomSettings.json` are **colon-separated, uppercase**.
- `install2026.ps1` runs as **PS 5** (RunOnce/FirstLogonCommands constraint); anything needing PS 7 runs inside `Install-NDT.ps1`.
- Step progress is persisted to `C:\temp\install-steps.json` — never delete this during a deployment.
- `C:\temp\settings.json` contains plaintext credentials and is deleted at the end of deployment.
- Exit code `3010` from `Install-NDT.ps1` means "reboot pending" — `install2026.ps1` writes `reboot.flag` and exits cleanly (RunOnce remains).
- Exit code `3011` from `Install-NDT.ps1` means "deployment paused" — `install2026.ps1` writes `pause.flag` and **removes** RunOnce so a reboot while paused does not auto-resume.
