#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enables PowerShell remoting for PowerShell 7 (Enter-PSSession / Invoke-Command) and adds a WinRM HTTPS listener on TCP/5986.

.DESCRIPTION
    - Enables WinRM / PS remoting for Windows PowerShell 5.1 (endpoint Microsoft.PowerShell, stays the default).
    - Enables PS remoting from PowerShell 7, which registers the PowerShell.7 endpoint. Use it explicitly:
        Enter-PSSession -ComputerName <name> -ConfigurationName PowerShell.7
        Invoke-Command  -ComputerName <name> -ConfigurationName PowerShell.7 -ScriptBlock { $PSVersionTable.PSVersion }
    - Keeps the HTTP listener (TCP/5985) and adds an HTTPS listener (TCP/5986) with a self-signed
      certificate (CN = FQDN), plus a firewall rule. Add -UseSSL on the client. The certificate is
      self-signed, so the client must trust it or use
        New-PSSessionOption -SkipCACheck -SkipCNCheck
    - Safe to re-run: a valid certificate/listener/rule is reused.

    Place this step after the domain join (and any rename) so the certificate carries the final FQDN.
    PowerShell 7 must already be installed (Applications\PowerShell7\install.ps1).

.PARAMETER SkipHttps
    Switch. Skips the HTTPS listener on TCP/5986 (PS7 endpoint and TCP/5985 only). From a MAC block or
    section set "SkipHttps": true (a JSON boolean, not a string).
#>
param (
    [switch]$SkipHttps
)

$ErrorActionPreference = 'Stop'
$certValidityYears = 5

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

try {
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path $pwsh)) { throw "PowerShell 7 not found at $pwsh. Run the PowerShell 7 install step first." }

    $psRemoting = 'Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null'

    # Each host registers its own endpoint (Microsoft.PowerShell for 5.1, PowerShell.7 for 7)
    Write-Host 'Enabling PS remoting for Windows PowerShell 5.1...'
    Invoke-Native (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $psRemoting)

    Write-Host 'Enabling PS remoting for PowerShell 7...'
    Invoke-Native $pwsh @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $psRemoting)

    Set-Service -Name WinRM -StartupType Automatic
    if ((Get-Service -Name WinRM).Status -ne 'Running') { Start-Service -Name WinRM }

    $endpoints = & $pwsh -NoProfile -Command 'Get-PSSessionConfiguration | Select-Object -ExpandProperty Name'
    if ($endpoints -notcontains 'PowerShell.7') { throw "Endpoint 'PowerShell.7' was not registered. Registered: $($endpoints -join ', ')" }
    Write-Host "Registered endpoints: $($endpoints -join ', ')"

    if ($SkipHttps) {
        Write-Host '-SkipHttps: HTTPS listener (TCP/5986) not configured.'
        exit 0
    }

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $fqdn = if ($cs.PartOfDomain -and $cs.Domain) { "$($cs.DNSHostName).$($cs.Domain)".ToLower() } else { $cs.DNSHostName.ToLower() }
    $subject = "CN=$fqdn"

    # Reuse a valid certificate from an earlier run, otherwise create one
    $cert = Get-ChildItem -Path Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) -and $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1' } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($cert) {
        Write-Host "Reusing certificate $($cert.Thumbprint) ($subject, expires $($cert.NotAfter))."
    }
    else {
        $dnsNames = @($fqdn, $cs.DNSHostName.ToLower()) | Select-Object -Unique
        $cert = New-SelfSignedCertificate -DnsName $dnsNames -Subject $subject -CertStoreLocation Cert:\LocalMachine\My `
            -KeyExportPolicy NonExportable -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
            -NotAfter (Get-Date).AddYears($certValidityYears) -FriendlyName 'NDT WinRM HTTPS'
        Write-Host "Created self-signed certificate $($cert.Thumbprint) ($subject, expires $($cert.NotAfter))."
    }

    $listener = Get-WSManInstance -ResourceURI winrm/config/Listener -Enumerate | Where-Object { $_.Transport -eq 'HTTPS' }
    if ($listener -and $listener.CertificateThumbprint -eq $cert.Thumbprint -and $listener.Hostname -eq $fqdn) {
        Write-Host 'HTTPS listener already configured with this certificate.'
    }
    else {
        if ($listener) {
            Write-Host 'Replacing existing HTTPS listener.'
            Remove-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet @{ Address = '*'; Transport = 'HTTPS' }
        }
        New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet @{ Address = '*'; Transport = 'HTTPS' } `
            -ValueSet @{ Hostname = $fqdn; CertificateThumbprint = $cert.Thumbprint } | Out-Null
        Write-Host "Created HTTPS listener on TCP/5986 for $fqdn."
    }

    $ruleName = 'NDT WinRM HTTPS (TCP-In)'
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -Profile Any | Out-Null
        Write-Host "Created firewall rule '$ruleName'."
    }
    else {
        Enable-NetFirewallRule -DisplayName $ruleName
        Write-Host "Firewall rule '$ruleName' already exists (enabled)."
    }

    if (-not (Get-NetTCPConnection -LocalPort 5986 -State Listen -ErrorAction SilentlyContinue)) { throw 'Nothing is listening on TCP/5986 after configuration.' }
    Write-Host 'WinRM is listening on TCP/5985 and TCP/5986.'
}
catch {
    Write-Error "WinRM PS7 setup failed: $($_.Exception.Message)"
    exit 1
}
