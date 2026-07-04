<#
.SYNOPSIS
    Configure a Windows DHCP server to break the iPXE chainload loop by handing
    iPXE clients (and only iPXE clients) an HTTP boot-script URL.

    Run this on your DHCP server, or from any admin host with the DhcpServer
    RSAT module using -ComputerName. Requires Windows PowerShell 5.1.

.DESCRIPTION
    Firmware PXE boots snponly.efi / ipxe.pxe from WDS. Stock iPXE then re-runs
    DHCP; without a distinguisher it would be handed the SAME iPXE binary again
    -> infinite loop. iPXE identifies itself with DHCP user-class "iPXE", so this
    script:

      1. Defines a DHCP IPv4 User Class named "iPXE" (ASCII data "iPXE").
      2. Adds a policy that matches that user class.
      3. Sets option 067 (Bootfile Name) = the HTTP boot script URL for the policy.

    By default the policy is created at server level (applies to every scope).
    Pass -ScopeId to scope it to a single subnet instead.

    Idempotent - safe to re-run.

.EXAMPLE
    .\configure-dhcp-ipxe.ps1
    Uses the default boot URL against the local DHCP server.

.EXAMPLE
    .\configure-dhcp-ipxe.ps1 -ComputerName dhcp01.corp.dev -BootScriptUrl http://IPXE01.corp.dev/boot/boot.ipxe

.EXAMPLE
    .\configure-dhcp-ipxe.ps1 -ScopeId 10.0.3.0
    Applies the policy to a single scope only.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    # Full HTTP URL of the iPXE boot script (from the iPXE install.ps1 summary).
    [string]$BootScriptUrl = 'http://IPXE01.corp.dev:80/boot/boot.ipxe',

    # DHCP server to configure. Defaults to the local machine.
    [string]$ComputerName = $env:COMPUTERNAME,

    # Optional: restrict the policy to a single scope (e.g. 10.0.3.0).
    # Omit for a server-level policy that applies to all scopes.
    [string]$ScopeId,

    [string]$UserClassName = 'iPXE',
    [string]$PolicyName    = 'iPXE-HTTP'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Ok   { param($m) Write-Host "    [ok]   $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host "    [info] $m" -ForegroundColor DarkGray }

Import-Module DhcpServer -ErrorAction Stop

# Common -ComputerName splat (only when targeting a remote server).
$target = @{}
if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME) { $target['ComputerName'] = $ComputerName }

Write-Host "`n==> Configuring DHCP '$ComputerName' for iPXE chainloading" -ForegroundColor Cyan
Write-Info "Boot script URL : $BootScriptUrl"
Write-Info ("Scope           : {0}" -f ($(if ($ScopeId) { $ScopeId } else { 'server-level (all scopes)' })))

# 1. User class matching iPXE's DHCP option 77 value ("iPXE").
if (-not (Get-DhcpServerv4Class @target -Name $UserClassName -Type User -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Class @target -Name $UserClassName -Type User -Data $UserClassName `
        -Description 'iPXE clients (chainload loop break)'
    Write-Ok "Created user class '$UserClassName'."
} else {
    Write-Ok "User class '$UserClassName' already present."
}

# 2. Policy matching that user class.
$policyScope = @{}
if ($ScopeId) { $policyScope['ScopeId'] = $ScopeId }

if (-not (Get-DhcpServerv4Policy @target @policyScope -Name $PolicyName -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Policy @target @policyScope -Name $PolicyName -Condition OR -UserClass EQ, $UserClassName `
        -Description 'Serve HTTP iPXE boot script to iPXE clients'
    Write-Ok "Created policy '$PolicyName'."
} else {
    Write-Ok "Policy '$PolicyName' already present."
}

# 3. Option 067 (Bootfile Name) = the full HTTP URL; iPXE chainloads it directly.
Set-DhcpServerv4OptionValue @target @policyScope -PolicyName $PolicyName -OptionId 67 -Value $BootScriptUrl
Write-Ok "Policy option 067 -> $BootScriptUrl"

Write-Host "`n==> Done. iPXE clients on '$ComputerName' will now chainload:" -ForegroundColor Cyan
Write-Host "    $BootScriptUrl"
Write-Host "`n    Verify:" -ForegroundColor DarkGray
Write-Host "      Get-DhcpServerv4Policy $(if($ComputerName -ne $env:COMPUTERNAME){"-ComputerName $ComputerName "})-Name $PolicyName" -ForegroundColor DarkGray
Write-Host "      Get-DhcpServerv4OptionValue $(if($ComputerName -ne $env:COMPUTERNAME){"-ComputerName $ComputerName "})-PolicyName $PolicyName -OptionId 67" -ForegroundColor DarkGray
