"install wds role" 
Import-Module ServerManager
Install-WindowsFeature -Name WDS -IncludeManagementTools -Verbose
