# Install Roles and Features for Enterprise CA and OCSP service

Install-WindowsFeature -Name Web-Server

$Features = @('ADCS-Cert-Authority', 'ADCS-Online-Cert', 'RSAT-ADCS-Mgmt', 'RSAT-Online-Responder', `
'Web-Http-Redirect', 'Web-ISAPI-Ext', 'Web-Log-Libraries', `
'Web-Request-Monitor', 'Web-Http-Tracing', 'Web-Mgmt-Console', 'Web-Metabase')

Install-WindowsFeature -Name $Features
