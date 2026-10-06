# NDT TUI - Add-machine form (design)

Status: **design agreed, not implemented** (2026-10-06).
Location rationale: `.github/` is versioned in git, never published to PSGallery
(`install/NDT/` is published as-is - no `FileList`), and is stripped from a live
share by `Install-NDT`.

---

## 1. Goal and scope

A terminal UI (TUI) form for **adding** a new machine entry to
`Control\CustomSettings.json`.

| Decision | Value |
|---|---|
| Runtime | **PowerShell 7** required (TUI command only; rest of module stays 5.1) |
| Operations | **Add only** - no edit/remove (use `Set-NDTComputer` / `Remove-NDTComputer`) |
| Where it runs | On the NDT server **or** an admin workstation, against the share by **UNC** (`-LocalPath \\ndt01.corp.dev\Deploy2026`) |
| Action parameters | **Not prompted** - keys required by `DeploymentActions.json` `Parameters` are deployment-specific expert input, added by hand |

Future: the team may later want a **web GUI** on the existing NDT Monitor IIS
site. The TUI must be built so that GUI reuses everything except presentation
(see section 6).

---

## 2. How settings are resolved today (facts the design relies on)

- A MAC block's `Sections` is a map **label -> section name**, e.g.
  `"Locale": "Sweden"`. Only the **value** (section name) is used by
  `Install-NDT.ps1`, `Get-Settings.ps1`, `Get-OS.ps1`, `Test-NDTDeployment`.
  The label is cosmetic (log output only).
- Merge rule: **machine keys always win**; sections only fill keys the machine
  does not set. Between sections, **first in order wins**.
  - `Install-NDT.ps1` iterates `Sections` in JSON order.
  - `Get-Settings.ps1` now uses `[ordered]@{}` (changed 2026-10-06) so it
    matches. Previously a plain `@{}` made section-vs-section precedence
    non-deterministic. Behaviour-neutral for all current machines (no current
    section combination has overlapping keys).
- Sections in practice rarely overlap - each is purpose-specific. `Sections.json`
  exists to define shared values once (avoid redundancy across machines).
- **Deploy sections** (`Deploy`, `DeployDC01`) are *not* referenced via
  `Sections`. They are selected by the machine-level `Deploy` key
  (default `Deploy`; reserved values `yes`/`no` are ignored) and read by
  `Copy-Install.ps1` / `install.ps1` by named keys only.
- **AutoLogon credential sections** (`ADLogon`, `ADLogon-AD01`) are *not*
  merged. They are reached via a name chain:
  `DeploymentGroups.json` step `Reference` -> `DeploymentActions.json` key with
  `"Type": "AutoLogon"` -> `Sections.json` key with `Username`/`Password`.
  They only enter a machine's merged settings if someone lists them in that
  machine's `Sections` (which would collide on `Password` with `ADJoinCorp`).
- **OS can come from a section.** Example: SQL41 (`00:15:5D:02:40:1F`) has no
  `OS` key; it inherits `"OS": "WIN2025DCCSQL"` from the `SQLAO` section
  (supported by `Get-OS.ps1`). This nested lookup is **expert manipulation**
  of the files to avoid redundancy - NDT keeps supporting it, but the TUI does
  **not** model it. The TUI targets simple new-machine deployments.

---

## 3. Schema change: `"System": true`

Add `"System": true` to every deploy-share section in `Sections.json`:

```jsonc
"Deploy":     { "System": true, "Share": "\\\\ndt01.corp.dev\\Deploy2026", ... },
"DeployDC01": { "System": true, "Share": "\\\\dc01.corp.dev\\Deploy2026",  ... }
```

- Safe: all consumers read Deploy sections by named keys
  (`Share`, `Username`, `Password`, `MonitorUrl`, `MapTimeoutSec`, `FinishAction`).
- `Install-NDT` stamps the `Deploy` section property-by-property, so the
  marker survives.
- `DeployDC01` is kept as the example that alternative shares are supported;
  pointing a machine at it (machine-level `"Deploy": "DeployDC01"`) remains an
  **expert hand edit**, not a TUI feature.

---

## 4. Form

Single screen. Fields:

| Field | Input | Rules |
|---|---|---|
| MAC | text | Normalise to uppercase, colon-separated (`-` -> `:`); validate 6 octets; reject if already in `CustomSettings.json` |
| Computername | text | Required; NetBIOS-valid (<= 15 chars) |
| IPAddress | text | `DHCP` or `a.b.c.d/nn` |
| AdminPassword | masked text | Stored plaintext in `CustomSettings.json` (as today) |
| OS | single choice from `OS.json` keys | **Mandatory**, always written at machine level. If a checked section also supplies `OS`, the overlap warning shows the machine value wins |
| Sections | checkbox list, **all** sections | See rules below |
| DeploymentGroups | checkbox list from `DeploymentGroups.json` | Order of checking = order written |
| FinishAction | single choice | `(inherit)` default, `DESKTOP`, `PROMPT`, `REBOOT`, `SHUTDOWN`, `LOGOFF` |
| Install:NO | checkbox | Writes `"Install": "NO"` when checked |

### Sections list rules

- Every `Sections.json` key is listed, each row showing the name plus a short
  preview of its keys.
- Sections with `"System": true` are shown **checked and greyed out**
  (cannot be toggled) and are **never written** into the machine's `Sections`.
  They are informational: "this machine uses the default deploy share".
- AutoLogon sections (`ADLogon*`) **are shown** as normal checkboxes. Misuse is
  caught by the overlap warning (below).
- Written form: label = section name, e.g. `"Sweden": "Sweden"`. Valid under
  the existing schema; no consumer changes required.
- **Order of checking = precedence order** (first wins on overlap).

### Overlap warning

On every toggle, compute keys shared between checked sections (and between
checked sections and machine-level fields). Display e.g.:

```
! Password set by: ADJoinCorp (wins), ADLogon-AD01
```

Warning only - Save is still allowed.

### Save

1. Show the resulting JSON entry for confirmation.
2. Run the same checks as `Test-NDTDeployment` (OS key exists, sections
   exist, groups exist, actions/scripts resolve).
3. Call `Add-NDTComputer`.

---

## 5. Required changes to `Add-NDTComputer` before the TUI

Found while reviewing `install/NDT/ndt.psm1`:

1. ~~`-OS` is Mandatory~~ - **keep as-is.** OS is mandatory for TUI-created
   machines; section-provided OS stays an expert hand edit.
2. **`-Sections` is `[hashtable]`** -> unordered, loses the precedence order.
   Change to `[System.Collections.IDictionary]` and pass `[ordered]@{}`.
3. **MAC normalisation** is only `.ToUpper()` - no `-` -> `:` conversion or
   format validation.
4. No `-Install` parameter (workaround: `-Properties @{ Install = 'NO' }`).
5. No existence checks for OS / sections / groups (handled by the new
   validate layer, section 6).
6. No concurrency protection when CLI and TUI (and later GUI) write the same
   file - consider a read-hash check before write (optimistic concurrency).

---

## 6. Architecture (GUI-ready)

```
TUI (PS7, presentation only)        future Web GUI (IIS, hosted PS runspace)
            \                                   /
             +-- Get-NDTCatalog / Test-NDTComputerEntry (new, no UI) --+
             |       - OS keys, sections (+ key preview, System flag),
             |       - groups, overlap analysis, entry validation
             +-- Add-NDTComputer (sole write path)
```

- **No front end writes JSON directly.** All validation lives in the module,
  so TUI and GUI cannot drift.
- New non-UI cmdlets (names provisional):
  - `Get-NDTCatalog -LocalPath` - returns OS keys, sections (name, keys,
    `System`), groups.
  - `Test-NDTComputerEntry` - validates a proposed entry and returns overlaps
    (key, winner, losers) and errors.

### TUI technology

- **Terminal.Gui**, loaded from the `Microsoft.PowerShell.ConsoleGuiTools`
  module folder (it ships `Terminal.Gui.dll`) - no DLL of our own to bundle.
- **Pin the version** - Terminal.Gui v1 and v2 APIs differ.
- `Out-ConsoleGridView` rejected: multi-select works but only as separate
  screens, not one form.

### Web GUI (later) - security requirements to carry forward

The editor controls what runs on every deployed machine and holds domain-join
and admin passwords. Minimum:

- Separate `/admin` application; `/progress` must stay anonymous (WinPE posts to it).
- Windows Authentication (Kerberos, corp.dev), restricted to an AD group; anonymous disabled.
- HTTPS with a certificate from `eca01`.
- CSRF protection on all POSTs.
- Passwords write-only - never returned to the browser.
- Prefer impersonation of the signed-in user for writes to `Control\` (NTFS
  ACLs + per-user auditing) over granting the app-pool identity Modify.
- Audit trail (who changed what), reusing the `.jsonl` pattern.

---

## 7. Next steps

1. Add `"System": true` to `Deploy` and `DeployDC01` in `Sections.json`.
2. Fix `Add-NDTComputer` items 2-3 (section 5).
3. Implement `Get-NDTCatalog` + `Test-NDTComputerEntry`.
4. Implement the TUI command (e.g. `New-NDTComputerTui`), PS7-only.
5. Extend `Test-NDTDeployment` to warn when a machine's `Sections` references a
   `System` section.
