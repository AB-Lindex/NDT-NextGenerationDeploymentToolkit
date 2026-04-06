Import-Module WebAdministration

New-Item -ItemType directory -Path C:\CertEnroll
New-SmbShare -Name CertEnroll$ -Path C:\CertEnroll -FullAccess everyone

Copy-Item -Path \\dc1\certenroll$\*.* -Destination C:\CertEnroll\

New-Item 'IIS:\Sites\Default Web Site\CertEnroll' -type VirtualDirectory -physicalPath C:\CertEnroll

# Config for allowDoubleEscaping is Needed because Web-Filtering is installed
Set-WebConfigurationProperty -Filter "/system.webServer/security/requestFiltering" -Name "allowDoubleEscaping" -Value $true -PSPath "IIS:\"
