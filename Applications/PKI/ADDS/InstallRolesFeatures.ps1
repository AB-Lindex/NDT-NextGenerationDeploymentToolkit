$Features = @(
    'AD-Domain-Services',
    'DHCP',
    'DNS',
    'GPMC',
    'RSAT-AD-PowerShell',
    'RSAT-ADUC',
    'RSAT-ADDS-Tools',
    'RSAT-DHCP',
    'RSAT-DNS-Server'
)

Install-WindowsFeature -Name $Features -IncludeManagementTools
