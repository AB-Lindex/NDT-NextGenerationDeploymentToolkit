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
│   ├── Deployment.json            ← deployment groups and step/action definitions
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
│   └── Copy-Install.ps1           ← drops install2026.ps1 + settings.json to C:\temp
├── MDT-Scripts/                   ← legacy MDT helper scripts (reference only)
└── install/                       ← PowerShell module to bootstrap a new NDT server
    ├── ndt.psm1                   ← exports Install-NDT
    ├── ndt.psd1                   ← module manifest (requires PS 5.1)
    └── source/                    ← seed copies of the three control files
        ├── CustomSettings.json
        ├── Deployment.json
        └── OS.json
```

---

## Two-phase deployment flow

### Phase 1 — WinPE (`install.ps1`)

1. Check capture flag → if set, capture reference image instead.
2. Detect BIOS/UEFI and partition disk with diskpart.
3. Look up machine by MAC in `Control/CustomSettings.json`.
4. Resolve WIM path + index from `Control/OS.json` and apply with DISM.
5. Copy `install2026.ps1` and write `settings.json` (share credentials + admin password) to `C:\temp`.
6. Generate `unattend.xml` from template — replace `!PLACEHOLDER!` tokens with values from `CustomSettings.json`.
7. Apply `unattend.xml` to offline image and run BCDBoot.

### Phase 2 — First boot (`install2026.ps1`, PS 5)

1. Skip if `C:\temp\deploy-complete.flag` exists (prevents double-run).
2. Handle `C:\temp\reboot.flag` to distinguish re-logon from a completed reboot.
3. Re-register `RunOnce\Deploy2026` to survive intermediate reboots.
4. Map the deploy share using credentials from `C:\temp\settings.json`.
5. Install PS 7 if absent.
6. Launch `Install-NDT.ps1` via `pwsh.exe` (PS 7).

### Phase 2 continued — Step engine (`Install-NDT.ps1`, PS 7)

1. Read machine's `DeploymentSteps` from `CustomSettings.json` (matched by MAC).
2. Load ordered steps from `Deployment.json` for each group.
3. Track progress in `C:\temp\install-steps.json` — resumes after reboot at the next pending step.
4. Execute steps by type:
   - **Script** — run `.ps1`/`.cmd`/`.bat`; optional `Parameters` array names keys to pull from `CustomSettings.json`.
   - **Reboot** — save state, write AutoLogon to registry, `shutdown /r`, exit 3010.
   - **AutoLogon** — switch the AutoAdminLogon account mid-deployment (used for AD/SQL operations).
5. On completion: unmap share, remove RunOnce + AutoLogon, write `deploy-complete.flag`, delete sensitive files from `C:\temp`.

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

### Deployment.json

**Group block** — ordered steps referencing action entries:
```jsonc
"General Settings": {
  "Step1": { "Description": "Admin password never expires", "Reference": "Admin password never expires" },
  "Step2": { "Description": "Disable WAC popup",           "Reference": "DisableWACPopup" }
}
```

**Action entry** — what to run (three forms):
```jsonc
"Install App2026": { "Script": "\\Applications\\App2026\\install01.ps1", "Parameters": ["SQLServer", "AlwaysOn"] },
"Reboot":          { "Type": "Reboot",    "Description": "Restart the computer" },
"ADLogon":         { "Type": "AutoLogon", "Description": "Configure automatic logon" }
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
Import-Module C:\Deploy2026\install\ndt.psd1
Install-NDT              # all defaults match the corp.dev lab environment
```

Parameters (all optional):

| Parameter | Default |
|---|---|
| `LocalPath` | `C:\Deploy2026` |
| `ShareName` | `Deploy2026` |
| `ShareUNC` | `\\dc01.corp.dev\Deploy2026` |
| `DeployUsername` | `Corp\Deploy2026` |
| `DeployPassword` | `P@ssw0rd2026` |

Creates folder structure → copies seed JSON files from `install\source\` → creates SMB share → sets share permissions.

---

## Key conventions

- All paths inside JSON files use **backslash**, rooted at the deploy share root (e.g. `\Applications\App2026\install01.ps1`).
- MAC addresses in `CustomSettings.json` are **colon-separated, uppercase**.
- `install2026.ps1` runs as **PS 5** (RunOnce/FirstLogonCommands constraint); anything needing PS 7 runs inside `Install-NDT.ps1`.
- Step progress is persisted to `C:\temp\install-steps.json` — never delete this during a deployment.
- `C:\temp\settings.json` contains plaintext credentials and is deleted at the end of deployment.
- Exit code `3010` from `Install-NDT.ps1` means "reboot pending" — `install2026.ps1` checks for this.
