# PSGallery2026 — Copilot Context

Private PowerShell module repository built on **NuGet.Server** hosted on **IIS** (Windows Server 2025).
Managed by the NDT deployment system; installed via `Applications\PSGallery\install.ps1`.

---

## Architecture

| Component | Value |
|---|---|
| IIS site name | `PSGallery2026` |
| App pool | `PSGallery2026` (.NET v4.0, Integrated, ApplicationPoolIdentity) |
| Site root | `C:\inetpub\PSGallery2026` |
| Packages folder | `C:\inetpub\PSGallery2026\Packages` |
| Protocol | HTTPS/443 only (no HTTP binding) |
| TLS certificate | `*.corp.dev` wildcard from `Cert:\LocalMachine\My` |
| Hostname variable | Resolved at runtime via `[System.Net.Dns]::GetHostEntry('').HostName` |
| Feed URL | `https://<server-fqdn>/nuget` |
| NuGet API key | Any non-empty string (NuGet.Server default — no auth) |

---

## install.ps1 — section summary

### Section 1 — IIS Windows features
Installs the minimum required feature set (no `-IncludeAllSubFeature`):
- `Web-Server`, `Web-Default-Doc`, `Web-Static-Content`, `Web-Http-Errors`
- `Web-Net-Ext45`, `Web-Asp-Net45`, `Web-ISAPI-Ext`, `Web-ISAPI-Filter` — ASP.NET 4.x required by NuGet.Server
- `Web-Http-Logging`, `Web-Request-Monitor`, `Web-Filtering`
- `Web-Mgmt-Console`, `Web-Scripting-Tools`
- `NET-Framework-45-Core`, `NET-Framework-45-ASPNET`, `NET-WCF-HTTP-Activation45`

Exits `3010` if a restart is required (NDT reboot step).

### Section 2 — NuGet.Server web application
- Locates `nuget.exe` in `$PSScriptRoot` (pre-staged); downloads from dist.nuget.org if absent.
- Runs `nuget install NuGet.Server -ExcludeVersion -NonInteractive -NoHttpCache` into a temp folder.
- Copies `NuGet.Server\Content\*` to `C:\inetpub\PSGallery2026\`.
- **Critical**: collects all `lib\net4*\*.dll` from every installed dependency package into `bin\`.
  Without this step ASP.NET cannot load NuGet.Server and IIS returns 404 for all routes.

### Section 3 — File-system permissions
- Creates the app pool first (so the `IIS AppPool\PSGallery2026` virtual account exists in Windows).
- Uses `icacls /grant:r` (not `/grant`) to idempotently set Modify + full inheritance on site root and Packages folder.
  `/grant` without `:r` adds duplicate ACEs on re-run.

### Section 4 — IIS application pool and website
- Finds the `*.corp.dev` cert in `Cert:\LocalMachine\My` with a private key; picks the one with the furthest expiry.
- Configures app pool: .NET v4.0, Integrated pipeline, ApplicationPoolIdentity.
- Creates site with no default binding, then adds HTTPS/443 with `SslFlags=1` (SNI).
- Removes the existing SNI SSL store entry (`IIS:\SslBindings\!443!<hostname>`) before calling `AddSslCertificate`
  — otherwise `AddSslCertificate` throws "element already exists" on re-run.

### Section 5 — Firewall and PSRepository
- Firewall rule `PSGallery2026-HTTPS-443` (inbound TCP 443), guarded by existence check.
- Ensures the `NuGet` package provider is installed before calling `Register-PSRepository`
  (its absence causes a misleading "invalid Web Uri" error).
- Probes `https://<fqdn>/nuget` with `Invoke-WebRequest` before registering — a 404 or
  connection failure here means Section 2's DLL copy step failed or IIS is not running.
- Uses `-PackageManagementProvider NuGet` on `Register-PSRepository` to prevent provider auto-detection.

---

## Known gotchas

| Problem | Root cause | Fix in script |
|---|---|---|
| `Register-PSRepository` "invalid Web Uri" | NuGet package provider not installed | `Install-PackageProvider NuGet` before registration |
| `Register-PSRepository` "invalid Web Uri" (feed returns 404) | Dependency DLLs missing from `bin\` — ASP.NET app fails to load | Collect all `lib\net4*\*.dll` into `bin\` after `nuget install` |
| `AddSslCertificate` "element already exists" on re-run | `Remove-WebBinding` clears IIS binding but leaves `IIS:\SslBindings` entry | Remove `IIS:\SslBindings\!443!<hostname>` before calling `AddSslCertificate` |
| `icacls` "No mapping between account names and security IDs" | App pool doesn't exist yet when permissions are set | Create app pool in Section 3 before running `icacls` |
| `icacls /grant` adds duplicate ACEs on re-run | `/grant` appends; `/grant:r` replaces | Use `/grant:r` |
| `nuget -NoCache` deprecation warning | Renamed in newer nuget.exe | Use `-NoHttpCache` |

---

## Pre-staging for offline deployments

Place `nuget.exe` alongside `install.ps1` in the deploy share:
```
Applications\PSGallery\
    install.ps1
    nuget.exe          ← from https://dist.nuget.org/win-x86-commandline/latest/nuget.exe
```
The script always uses `nuget.exe` to install NuGet.Server (single `.nupkg` files were
tried and abandoned — they don't include dependency DLLs). Packages are fetched from
nuget.org unless a local NuGet feed is configured as the source.

---

## Post-install usage

```powershell
# On any machine that should consume the feed
Register-PSRepository -Name PSGallery2026 `
    -SourceLocation     https://psg01.corp.dev/nuget `
    -PublishLocation    https://psg01.corp.dev/nuget `
    -InstallationPolicy Trusted

# Publish a module
Publish-Module -Name MyModule -Repository PSGallery2026 -NuGetApiKey 'any'

# Install a module
Install-Module -Name MyModule -Repository PSGallery2026
```

---

## NDT integration

Add to `Deployment.json`:
```jsonc
"Install PSGallery": { "Script": "\\Applications\\PSGallery\\install.ps1" }
```

Add to a deployment group in `DeploymentGroups.json`:
```jsonc
"PSGallery Server": {
  "Step1": { "Description": "Install PSGallery", "Reference": "Install PSGallery" }
}
```

Assign the group to the target machine's `DeploymentSteps` in `CustomSettings.json`.
The script exits `3010` if a reboot is needed after IIS feature installation;
the NDT step engine will restart the machine and resume at this step automatically.
