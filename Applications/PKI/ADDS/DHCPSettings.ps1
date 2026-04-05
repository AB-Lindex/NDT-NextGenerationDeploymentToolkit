param (
    [parameter(Mandatory = $true)]
    [string]$Computername,
    [parameter(Mandatory = $true)]
    [string]$DomainDNSName,
    [parameter(Mandatory = $true)]
    [string]$DHCPServerIP,
    [parameter(Mandatory = $true)]
    [string]$BootServerIp,
    [parameter(Mandatory = $true)]
    [string]$DHCPScopes0Name,
    [parameter(Mandatory = $true)]
    [string]$DHCPScopes0StartIP,
    [parameter(Mandatory = $true)]
    [string]$DHCPScopes0EndIP,
    [parameter(Mandatory = $true)]
    [string]$DHCPScopes0SubnetMask,
    [parameter(Mandatory = $true)]
    [string]$DHCPScopes0IP,
    [parameter(Mandatory = $true)]
    [string]$DHCPScopes0OptionDNSDomainName,
    [parameter(Mandatory = $true)]
    [string]$DHCPScopes0OptionDNSServer,
    [parameter(Mandatory = $true)]
    [int]$DHCPScopes0OptionLease,
    [parameter(Mandatory = $true)]
    [string]$DHCPScopes0OptionRouter
)

Add-DhcpServerInDC -Dnsname "$Computername.$DomainDNSName" -IpAddress $DHCPServerIP
Add-DhcpServerSecurityGroup
Set-ItemProperty �Path registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\ServerManager\Roles\12 �Name ConfigurationState �Value 2

Add-DhcpServerv4OptionDefinition -Name PXECLient -OptionId 60 -Type String

Set-DhcpServerv4OptionValue -OptionId 66 -value "$BootServerIp"
Set-DhcpServerv4OptionValue -OptionId 67 -value "boot\x86\wdsnbp.com"
Set-DhcpServerv4OptionValue -OptionId 60 -value "PXEClient"

Add-DhcpServerv4Scope -Name $DHCPScopes0Name `
    -StartRange $DHCPScopes0StartIP `
    -EndRange $DHCPScopes0EndIP `
    -SubnetMask $DHCPScopes0SubnetMask

Set-DhcpServerv4Scope -ScopeId $DHCPScopes0IP `
    -LeaseDuration (New-TimeSpan -Seconds $DHCPScopes0OptionLease)

Set-DhcpServerv4OptionValue -ScopeId $DHCPScopes0IP `
    -DnsDomain $DHCPScopes0OptionDNSDomainName `
    -DnsServer $DHCPScopes0OptionDNSServer `
    -Router $DHCPScopes0OptionRouter
