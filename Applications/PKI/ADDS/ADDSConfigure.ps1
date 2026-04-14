param(
    [string]$DomainDNSName,
    [string]$DomainNetBiosName,
    [int]$DomainLevel,
    [int]$ForestLevel,
    [string]$SafeNodeAdminPwd
)

$SafeModePassword = ConvertTo-SecureString -String $SafeNodeAdminPwd -AsPlainText -Force

Install-ADDSForest `
    -DomainName                    $DomainDNSName `
    -DomainNetbiosName             $DomainNetBiosName `
    -DomainMode                    $DomainLevel `
    -ForestMode                    $ForestLevel `
    -SafeModeAdministratorPassword $SafeModePassword `
    -InstallDns `
    -NoRebootOnCompletion `
    -Force
