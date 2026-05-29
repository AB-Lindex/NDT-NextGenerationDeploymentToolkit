Install-WindowsFeature -Name Web-Server
start-sleep -Seconds 2

$Features = @('Web-Basic-Auth', 'Web-Digest-Auth', 'Web-Url-Auth', 'Web-Windows-Auth')
Install-WindowsFeature -Name $Features
start-sleep -Seconds 2

$Features = @('Web-Net-Ext45', 'Web-ASP', 'Web-Asp-Net45', 'Web-ISAPI-Ext', 'Web-ISAPI-Filter')
Install-WindowsFeature -Name $Features
start-sleep -Seconds 2

$Features = @('Web-Mgmt-Console', 'Web-Scripting-Tools', 'Web-Mgmt-Service')
Install-WindowsFeature -Name $Features
start-sleep -Seconds 2

$Features = @('NET-WCF-HTTP-Activation45', 'NET-WCF-Pipe-Activation45', 'NET-WCF-TCP-Activation45', 'NET-WCF-TCP-PortSharing45')
Install-WindowsFeature -Name $Features
