param (
    [Parameter(Mandatory)]
    [string]$SQLAOListenerName,
    [Parameter(Mandatory)]
    [string]$SQLAOListenerIP,
    [Parameter(Mandatory)]
    [string]$SQLAOClusterName,
    [Parameter(Mandatory)]
    [string]$Domain
)
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )
    $LogFile = 'c:\temp\SQLsetup.log'
    $Timestamp = Get-Date -Format "HH:mm:ss"
    Add-Content -Path $LogFile -PassThru -Force -Value "$Timestamp $Value"
}

$Domain0 = $Domain.split('.')[0]
$Domain1 = $Domain.split('.')[1]

get-dnsServerResourceRecord -ZoneName $Domain -ComputerName $Domain | Where-Object {$_.HostName -eq $SQLAOListenerName} | `
Remove-DnsServerResourceRecord -ZoneName $Domain -ComputerName $Domain -Force
Add-DnsServerResourceRecordA -ComputerName $Domain -ZoneName $Domain -Name $SQLAOListenerName -IPv4Address $SQLAOListenerIP

$dnsRecordPath = "DC=$SQLAOListenerName,DC=$Domain,CN=MicrosoftDNS,DC=DomainDnsZones,DC=$Domain0,DC=$Domain1"
Write-Log -Value "DNS Record Path: $dnsRecordPath"
$acl = get-acl -Path "AD:$dnsRecordPath"
$computerSID = New-Object System.Security.Principal.NTAccount("$SQLAOClusterName$")
"$computerSID"
$accessRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $computerSID,
    "GenericAll",
    "Allow"
)

$acl.AddAccessRule($accessRule)

Set-Acl -Path "AD:$dnsRecordPath" -AclObject $acl
Write-Log -Value "Full Control permissions assigned to $computerSID on record $dnsRecordPath"
