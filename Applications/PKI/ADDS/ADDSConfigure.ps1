param(
    [string]$DomainDNSName,
    [string]$DomainNetBiosName,
    [int]$DomainLevel,
    [int]$ForestLevel,
    [string]$AdminPassword
)

$SafeModePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force

Install-ADDSForest `
    -DomainName                    $DomainDNSName `
    -DomainNetbiosName             $DomainNetBiosName `
    -DomainMode                    $DomainLevel `
    -ForestMode                    $ForestLevel `
    -SafeModeAdministratorPassword $SafeModePassword `
    -InstallDns `
    -NoRebootOnCompletion `
    -Force
