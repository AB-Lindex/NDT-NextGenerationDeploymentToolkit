<#
.SYNOPSIS
    Point UEFI x64 PXE firmware at the iPXE server (IPXE01) so it chainloads iPXE
    instead of the existing WDS deployment server (NDT01).

    Updates the existing "UEFI x64 bootfile" DHCP policy on the given scopes to
    hand UEFI x64 clients:
        option 066 (Boot Server) = the iPXE server IP
        option 067 (Bootfile)    = boot\x64\snponly.efi   (served via IPXE01 TFTP)

    After this, the flow is:
        firmware (UEFI x64) -> TFTP snponly.efi from IPXE01 -> iPXE runs
          -> re-DHCP as user-class "iPXE" -> iPXE-HTTP policy -> boot.ipxe -> WinPE

    Run on the DHCP server (DC01) under Windows PowerShell 5.1. Idempotent.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string[]]$ScopeId       = @('10.0.1.0', '10.0.3.0'),
    [string]  $IpxeServerIp  = '10.0.3.38',
    [string]  $BootFile      = 'boot\x64\snponly.efi',
    [string]  $PolicyName    = 'UEFI x64 bootfile',
    [string]  $ComputerName  = $env:COMPUTERNAME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module DhcpServer -ErrorAction Stop

$target = @{}
if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME) { $target['ComputerName'] = $ComputerName }

Write-Host "`n==> Redirecting UEFI x64 firmware to iPXE ($IpxeServerIp)" -ForegroundColor Cyan

foreach ($sc in $ScopeId) {
    $pol = Get-DhcpServerv4Policy @target -ScopeId $sc -Name $PolicyName -ErrorAction SilentlyContinue
    if (-not $pol) {
        Write-Warning "  Scope $sc : policy '$PolicyName' not found - skipped."
        continue
    }
    Set-DhcpServerv4OptionValue @target -ScopeId $sc -PolicyName $PolicyName -OptionId 66 -Value $IpxeServerIp
    Set-DhcpServerv4OptionValue @target -ScopeId $sc -PolicyName $PolicyName -OptionId 67 -Value $BootFile
    Write-Host ("    [ok] Scope {0}: 066={1}  067={2}" -f $sc, $IpxeServerIp, $BootFile) -ForegroundColor Green
}

Write-Host "`n==> Verify:" -ForegroundColor Cyan
foreach ($sc in $ScopeId) {
    $vals = Get-DhcpServerv4OptionValue @target -ScopeId $sc -PolicyName $PolicyName -ErrorAction SilentlyContinue |
        Where-Object OptionId -in 66, 67
    foreach ($v in $vals) {
        Write-Host ("    Scope {0}: {1,-4} {2,-22} {3}" -f $sc, $v.OptionId, $v.Name, ($v.Value -join ','))
    }
}
