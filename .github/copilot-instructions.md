# NDT — Copilot Context

NDT (Next Deployment Tool) is a lightweight PowerShell-based replacement for MDT (EOL).
No GUI. No XML wizards. Everything is driven by PowerShell 5/7 and four JSON files.
WDS/PXE handles network boot. The deploy share is a standard Windows SMB share.

---

## Environment / infrastructure (corp.dev)

| Host | IP | Role |
|---|---|---|
| `dc01.corp.dev`    | `10.0.3.11` | DNS, DHCP, ADDS; also hosts VS Code + the repos |
| `ndt01.corp.dev`   | `10.0.3.16` | `Deploy2026` share for the NDT solution |
| `ipxe01.corp.dev`  | `10.0.3.38` | iPXE server (WDS chainload + IIS boot files); ADK installed |
| `eca01.corp.dev`   | `10.0.3.14` | Enterprise/intermediate CA (ADCS) |
| `rootca01`         | *(offline)* | Standalone offline Root CA |

The `corp.dev` Active Directory runs its own two-tier PKI: an offline standalone
Root CA (`rootca01`) and an online enterprise/intermediate CA (`eca01`). Certificates
for internal HTTPS chain to this internal CA — not a public CA — which is why stock
iPXE binaries (public CA bundle only) cannot do HTTPS to internal endpoints without
being rebuilt with the internal CA embedded (`TRUST=`).

---

## Workspace layout

```
Deploy2026/                        ← root of the SMB share (\\dc01.corp.dev\Deploy2026)
├── Boot/boot2026.wim              ← WinPE image served by WDS
├── Control/
│   ├── CustomSettings.json        ← per-machine config keyed by MAC address only
│   ├── Sections.json              ← shared named sections (locale, network, AD, deploy credentials)
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
├── Logs/progress/                 ← NDT Monitor data: <MAC>.json (latest state) + audit-<date>.jsonl (history)
├── MDT-Scripts/                   ← legacy MDT helper scripts (reference only)
└── install/                       ← PowerShell module to bootstrap a new NDT server
    ├── NDT/
    │   ├── ndt.psm1               ← module script (exports all NDT-* commands)
    │   └── ndt.psd1               ← module manifest (requires PS 5.1)
    ├── NDTMonitor/                ← IIS progress web service (deployed by Install-NDTMonitor)
    │   ├── web.config             ← maps /progress to the handler; LogRoot appSetting
    │   ├── App_Code/ProgressHandler.cs ← ASP.NET handler (auto-compiled by IIS)
    │   └── Default.htm            ← live dashboard (MDT-style monitoring view)
    ├── ndt.nuspec                 ← NuGet package spec (reference; PSGallery uses psd1)
    └── Publish-NDT.ps1            ← publishes the module to PSGallery
```

---

## Two-phase deployment flow

### Phase 1 — WinPE (`install.ps1`)

1. Check capture flag (`DeployCapture.flag` on any drive) → if set, remove flag, clean `C:\temp`, call `Capture-ReferenceImage.ps1`, exit.
2. Detect BIOS/UEFI firmware type — recorded early but **disk is not touched** until all validations pass.
3. Validate MAC address against `Control/CustomSettings.json`; abort with error if not found.
   - **`Install:NO` guard** — if the MAC block has `"Install": "NO"` (case-insensitive), skip deployment entirely: reboot without touching the disk. Prevents accidental re-imaging. Any other value (or absent) deploys normally.
4. Resolve and validate WIM path + index from `Control/OS.json`; abort if WIM file not found.
5. All pre-flight checks passed → partition disk 0 with diskpart (GPT/EFI for UEFI; MBR/active for BIOS).
6. Apply OS image to `C:\` with DISM.
7. Run `Copy-Install.ps1` → copies `install2026.ps1` and writes `settings.json` (share credentials + admin password + optional `MonitorUrl`) to `C:\temp`.
8. Run `Get-Settings.ps1` → generates `unattend.xml` from template (replaces `!PLACEHOLDER!` tokens); apply to offline image with DISM.
9. Run BCDBoot (UEFI: `/f UEFI /s S:` ; BIOS: `/f BIOS /s C:`), set BCD timeout 0, then `wpeutil Reboot`.

Throughout Phase 1, `install.ps1` reports progress to the NDT Monitor (best-effort) — `Phase: WinPE` updates at config-validated, partitioning, applying image, image applied, and rebooting. `MonitorUrl` is resolved from the machine's deploy section in `Sections.json`; if absent, reporting is silently disabled and never blocks deployment.

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
   - Resolves `MonitorUrl` early from `C:\temp\settings.json`; if the machine has **no** `DeploymentSteps`, posts a `Done` (100%) to the monitor and exits 0 (OS-only deploy).
2. Load ordered steps from `DeploymentGroups.json` for each group; resolve each step's action from `Deployment.json`.
3. Track progress in `C:\temp\install-steps.json` — resumes after reboot at the next pending step.
4. Execute steps by type:
   - **Script** — run `.ps1` (default: pwsh/PS 7), `.ps1` with `"PowerShell": "powershell5"` (PS 5.1), or `.cmd`/`.bat` (cmd.exe). Optional `Parameters` array names keys to pull from `CustomSettings.json`.
   - **Reboot** — mark step complete, write AutoLogon to registry, `shutdown /r /t 10`, exit 3010.
   - **AutoLogon** — switch the AutoAdminLogon account mid-deployment (used for AD/SQL operations); also updates `settings.json` so subsequent Reboot steps use the new credentials. Credentials are resolved by looking up the step's `Reference` name as a key in `Sections.json` (`Username` + `Password`). Multiple named entries (e.g. `ADLogon-AD01`, `ADLogon-AD02`) allow logging on to different Active Directories from the same step engine.
   - **WindowsUpdate** — runs the WU script; if it exits 3010 the step is **not** marked complete and the engine exits 3010 (iterates until no reboot is needed); if it exits 0 the step is marked complete.
   - **Pause** — creates a "Continue Deployment" shortcut on `C:\Users\Public\Desktop`, marks step complete, exits 3011.
5. On completion: engine exits 0. `install2026.ps1` then unmaps share, removes RunOnce + AutoLogon, writes `deploy-complete.flag`.

Throughout Phase 2, `Install-NDT.ps1` reports `Phase: Windows` progress to the NDT Monitor via `Send-NDTProgress` (best-effort): `Starting`, `Running`/`Completed` per step, `Rebooting`, `Paused`, `Failed`, and `Done`. Percent is step-based (completed / total). Requires `MonitorUrl` in `settings.json` (carried from the deploy section by `Copy-Install.ps1`); absent = silently disabled.

---

## Control file schemas

### CustomSettings.json

MAC address blocks only — one per machine:
```jsonc
"00:15:5D:02:56:01": {
  "OS": "WIN2025DCG",          // key into OS.json
  "Computername": "srv02",
  "IPAddress": "10.0.3.22/24", // omit or "DHCP" for DHCP
  "AdminPassword": "...",
  "SQLServer": "SQL2025",       // arbitrary extra keys passed as script parameters
  "AlwaysOn": "AO2025",
  "Sections": {
    "Locale": "Sweden",         // reference keys into Sections.json
    "NetworkSettings": "NicAuto",
    "ADSettings": "ADJoinCorp"
  },
  "DeploymentSteps": ["General Settings", "SMC"]
}
```

### Sections.json

Shared named sections, referenced by name from MAC blocks. Merged into effective settings at deploy time:
```jsonc
"Sweden":      { "InputLocale": "sv-SE", "SystemLocale": "sv-SE", "UILanguage": "sv-SE", "UserLocale": "sv-SE", "TimeZone": "W. Europe Standard Time" },
"NicAuto":     { "DefaultGateway": "10.0.3.1", "DNSServers": "10.0.3.11" },
"ADJoinCorp":  { "JoinDomain": "corp.dev", "Domain": "corp", "OU": "ou=Servers,dc=corp,dc=dev", "User": "ADJoin2026", "Password": "..." },
"RefSettings": { "Sysprep": "Generalize", "Shutdown": "Shutdown", "IPAddress": "DHCP", "JoinDomain": "WORKGROUP", ... },
"Deploy":       { "Share": "\\\\dc01.corp.dev\\Deploy2026", "Username": "Corp\\Deploy2026", "Password": "...", "MonitorUrl": "http://ndt01.corp.dev:9999" },
"ADLogon-AD01": { "Username": "Corp\\ADLogon",   "Password": "..." },
"ADLogon-AD02": { "Username": "Dev\\ADLogon",    "Password": "..." }
// The key name must match the "Reference" value used in DeploymentGroups.json.
// MonitorUrl (on the deploy section) is optional — enables NDT Monitor progress reporting; stamped by Install-NDT.
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
"ADLogon-AD01":     { "Type": "AutoLogon",       "Description": "Log on as Corp AD account" },
"ADLogon-AD02":     { "Type": "AutoLogon",       "Description": "Log on as Dev AD account" },
// Reference name must match a key in Sections.json — that entry supplies Username + Password.
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
| `MonitorPort` | optional | `9999` (NDT Monitor site port) |
| `SkipMonitor` | optional | *(switch — skip NDT Monitor install)* |

Downloads the repository ZIP from GitHub → extracts into `LocalPath` → removes repo-only artefacts (`.github`, `.vscode`, `.gitignore`, `README.md`) that must not exist on a live deployment share → stamps the `Deploy` section of `Control\Sections.json` with the supplied parameters (including `MonitorUrl`, derived from the share host + `-MonitorPort`) → creates SMB share → grants deploy account Full Access → revokes Everyone access → installs the NDT Monitor via `Install-NDTMonitor` (unless `-SkipMonitor`).

Also exported by the module (see `ndt.psd1`):
- `Install-NDTMonitor` — installs the NDT Monitor IIS progress web service (idempotent). Installs IIS roles/features (ASP.NET 4.x), deploys `install/NDTMonitor` content, creates the app pool + site on the port (default 9999), grants the app-pool identity write access to `Logs\progress`, and opens the firewall. **Must run under Windows PowerShell 5.1** — it self-relaunches under `powershell.exe` if called from PS 7 (the IIS: provider is unreliable in PS 7). Called automatically by `Install-NDT` (skip with `-SkipMonitor`, port via `-MonitorPort`).
- `New-NDTPEImage` (alias `Build-NDTPEImage`) — builds the WinPE WIM + optional ISO; updates WDS boot image.
- `Get-NDTServer` / `Add-NDTServer` / `Set-NDTServer` / `Remove-NDTServer`
- `Get-NDTOs` / `Add-NDTOs` / `Set-NDTOs` / `Remove-NDTOs`
- `Move-NDTReferenceImage` — moves captured WIM files from `\Reference\` into `\Operating Systems\`. For each `ref-<name>.wim` the destination is `Operating Systems\ref-<name>\<name>.wim` (folder = full stem, file = stem without the `ref-` prefix). Always overwrites; use `-WhatIf` for a dry run.
- `Test-NDTDeployment` — dry-run validation for a given MAC address: checks CustomSettings.json entry, referenced sections in Sections.json, OS.json key, WIM file existence, DeploymentGroups.json groups, Deployment.json references, and script file paths. Returns `$true` / `$false`.

---

## Key conventions

- All paths inside JSON files use **backslash**, rooted at the deploy share root (e.g. `\Applications\App2026\install01.ps1`).
- MAC addresses in `CustomSettings.json` are **colon-separated, uppercase**.
- Named sections (locale, network, AD join, deploy credentials) live in `Sections.json`. `CustomSettings.json` contains MAC address blocks only.
- `install2026.ps1` runs as **PS 5** (RunOnce/FirstLogonCommands constraint); anything needing PS 7 runs inside `Install-NDT.ps1`.
- Step progress is persisted to `C:\temp\install-steps.json` — never delete this during a deployment.
- `C:\temp\settings.json` contains plaintext credentials and is deleted at the end of deployment.
- Exit code `3010` from `Install-NDT.ps1` means "reboot pending" — `install2026.ps1` writes `reboot.flag` and exits cleanly (RunOnce remains).
- Exit code `3011` from `Install-NDT.ps1` means "deployment paused" — `install2026.ps1` writes `pause.flag` and **removes** RunOnce so a reboot while paused does not auto-resume.
- **NDT Monitor** — IIS web service (`install/NDTMonitor`) providing centralized deployment progress (MDT-monitoring replacement). Endpoints: `POST /progress` (receive update), `GET /progress` (all machines as JSON array), `GET /progress?mac=..` (single machine), `GET /` (dashboard). Data lives in `Logs\progress\`: `<MAC>.json` (latest state) and `audit-<date>.jsonl` (daily-rolling append-only history, retry-on-lock, retained indefinitely). Reporting is best-effort and never blocks deployment; no credentials are stored in progress data. Uses JSON only (`JavaScriptSerializer`) — **not** XML — so it is not exposed to the MDT-monitor XXE vulnerability.
- **`Install:NO`** in a MAC block disables deployment for that machine (reboot, no disk wipe). This is distinct from `Deploy` (a section-name reference); the reserved values `yes`/`no` are never treated as section names by `Copy-Install.ps1`.
