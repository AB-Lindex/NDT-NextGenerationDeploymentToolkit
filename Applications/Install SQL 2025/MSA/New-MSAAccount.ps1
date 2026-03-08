param (
    [Parameter()]
    [string]$SQLAOgMSA
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

Write-Log -Value "Installing AD Module for PowerShell"
$Feature = 'RSAT-AD-PowerShell'
if ((get-windowsfeature -Name $Feature).Installstate -eq 'Installed') {
    Write-Log -Value "$Feature is already installed"
} else {
    Install-WindowsFeature -Name $Feature
    Write-Log -Value "$Feature is now installed"
}
Write-Log -Value "Done Installing AD Module for PowerShell"

$ComputerName = $ENV:Computername
$ComputerNameAccount = $ComputerName + '$'
$Domain = (Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem).domain

if ($SQLAOgMSA) {
    Write-Log -Value "Creating gMSA Account for Always On: $SQLAOgMSA"
    $MSAComputerName = $SQLAOgMSA
} else {
    Write-Log -Value "Creating MSA Account for stand alone SQL: $ComputerName"
    $MSAComputerName = 'MSA' + $ComputerName
}

$MSAComputerNameFQDN = $MSAComputerName + "." + $Domain

Write-Log -Value "Creating MSA Account: $MSAComputerName"
Write-Log -Value "DNSHostname for MSA: $MSAComputerNameFQDN"
Write-Log -Value "ComputerNameAccount: $ComputerNameAccount"

Get-ADServiceAccount -Filter "name -eq '$MSAComputerName'" | Remove-ADServiceAccount -Confirm:$false
New-ADServiceAccount -name $MSAComputerName `
 -DNSHostName $MSAComputerNameFQDN `
  -PrincipalsAllowedToRetrieveManagedPassword $ComputerNameAccount `
  -KerberosEncryptionType AES128, AES256 `
  -enabled $true

Write-Log -Value "Done Creating Account: $MSAComputerName"
