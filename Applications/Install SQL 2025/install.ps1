param (
    [Parameter()]
    [string]$SQLAONodes,
    [Parameter()]
    [string]$SQLAOgMSA,
    [Parameter()]
    [string]$SQLAOClusterIP,
    [Parameter()]
    [string]$SQLAOClusterName,
    [Parameter()]
    [string]$SQLAOClusterShare,
    [Parameter()]
    [string]$SQLAOListenerIP,
    [Parameter()]
    [string]$SQLAOListenerName,
    [Parameter()]
    [string]$AGName,
    [Parameter(Mandatory)]
    [string]$SQLPFXFile,
    [Parameter(Mandatory)]
    [string]$SAPWD,
    [Parameter(Mandatory)]
    [string]$PFXPwd
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

Set-Location $PSScriptRoot

$HostName = $env:ComputerName
$Domain = $env:USERDNSDOMAIN # corp.dev
$UserDomain = $env:USERDOMAIN # CORP
$INIFile = '.\SQL2025\ConfigurationFile.ini'
$Instance = 'MSSQLSERVER'

Write-Log -Value "Starting SQL 2025 Installation Script"
Write-Log -Value "HostName: $HostName"
Write-Log -Value "Domain: $Domain"
Write-Log -Value "UserDomain: $UserDomain"
Write-Log -Value "SQLAONodes: $SQLAONodes"
Write-Log -Value "SQLAOgMSA: $SQLAOgMSA"
Write-Log -Value "SQLAOClusterIP: $SQLAOClusterIP"
Write-Log -Value "SQLAOClusterName: $SQLAOClusterName"
Write-Log -Value "SQLAOClusterShare: $SQLAOClusterShare"
Write-Log -Value "SQLAOListenerIP: $SQLAOListenerIP"
Write-Log -Value "SQLAOListenerName: $SQLAOListenerName"
Write-Log -Value "AGName: $AGName"
Write-Log -Value "SQLPFXFile: $SQLPFXFile"
Write-Log -Value "INIFile: $INIFile"
Write-Log -Value "Instance: $Instance"
Write-Log -Value "SAPWD: $($SAPWD.substring(0,3))****"
write-log -Value "PFXPassword: $($PFXPwd.substring(0,3))****"

Write-Log -Value "Installing AD Module for PowerShell" # should be already installed from previous step
$Feature = 'RSAT-AD-PowerShell'
if ((get-windowsfeature -Name $Feature).Installstate -eq 'Installed') {
    Write-Log -Value "$Feature is already installed"
} else {
    Install-WindowsFeature -Name $Feature
    Write-Log -Value "$Feature is now installed"
}
Write-Log -Value "Done Installing AD Module for PowerShell"

[string[]]$Nodes
[bool]$FirstNode
if ($SQLAONodes) {
    $AO = $true
} else {
    $AO = $false
}

if ($AO) {
    Write-Log -Value "This will be an Always On SQL Installation"
    $Nodes = $SQLAONodes -split ','
    if ($Nodes[0] -eq $HostName) {
        $FirstNode = $true
    } else {
        $FirstNode = $false
    }
    Write-Log -Value "Installing Failover Cluster Features" # should be already installed from previous step
    $Features = @('Failover-Clustering', 'RSAT-Clustering-PowerShell', 'RSAT-AD-PowerShell', 'RSAT-DNS-Server')
    Install-WindowsFeature -Name $Features

    if (Test-Path "$env:windir\explorer.exe") {
        Install-WindowsFeature -Name 'RSAT-Clustering-Mgmt'
    }
    Write-Log -Value "Done Installing Failover Cluster Features"

    if ($FirstNode) {
        Write-Log -Value "Creating gMSA Account for Always On: $SQLAOgMSA"
        & .\MSA\New-MSAAccount.ps1 -SQLAOgMSA $SQLAOgMSA # Step 1: Create gMSA Account
        Set-Content -path c:\temp\gMSACreated.txt -Value "done" -Force
    } else {
        Write-Log -Value "Not the first node ($HostName). Skipping gMSA creation."
        Write-Log -Value "Waiting for gMSA Account $SQLAOgMSA to exists."
        while (-not (Get-ADServiceAccount -Filter "name -eq '$SQLAOgMSA'" -ErrorAction SilentlyContinue)) {
            Write-Log -Value "Still waiting for gMSA Account $SQLAOgMSA to exists."
            Start-Sleep -Seconds 4
        }
        while(-not (Test-Path "\\$($Nodes[0])\c$\temp\gMSACreated.txt")) {
            Write-Log -Value "Still waiting for gMSA Account $SQLAOgMSA to be confirmed with file semaphore on first node: $($Nodes[0])"
            Start-Sleep -Seconds 4
        }

        Write-Log -Value "Adding $hostname to PrincipalsAllowedToRetrieveManagedPassword for gMSA $SQLAOgMSA"
        $gMSA = Get-ADServiceAccount -Identity $SQLAOgMSA -Properties PrincipalsAllowedToRetrieveManagedPassword
        $computer = Get-ADComputer -Identity $HostName
        $principals = $gMSA.PrincipalsAllowedToRetrieveManagedPassword + $computer
        Set-ADServiceAccount -Identity $SQLAOgMSA `
            -PrincipalsAllowedToRetrieveManagedPassword $principals
    }

    Write-Log -Value "Installing gMSA Account: $SQLAOgMSA"
    Install-ADServiceAccount -Identity $SQLAOgMSA # Step 2: Install gMSA Account on each node
    $MSAResult = test-ADServiceAccount -Identity $SQLAOgMSA
    Write-Log -Value "gMSA Account Installation Result: $MSAResult"
    Write-Log -Value "Done Installing gMSA Account: $SQLAOgMSA"

    $ServiceAccountSQL = "$UserDomain\$SQLAOgMSA$"
} else {
    Write-Log -Value "This will be a Stand Alone SQL Installation"
    Write-Log -Value "Creating MSA Account for stand alone SQL: $HostName"

    & .\MSA\New-MSAAccount.ps1 # Step 1: Create MSA Account for stand alone SQL

    Write-Log -Value "Done Creating MSA Account for stand alone SQL: $HostName"
    $MSAComputerName = 'MSA' + $HostName

    Write-Log -Value "Installing MSA Account: $MSAComputerName"
    Install-ADServiceAccount -Identity $MSAComputerName # Step 2: Install MSA Account on the server
    $MSAResult = test-ADServiceAccount -Identity $MSAComputerName
    Write-Log -Value "MSA Account Installation Result: $MSAResult"
    Write-Log -Value "Done Installing MSA Account: $MSAComputerName"

    $ServiceAccountSQL = "$UserDomain\MSA" + $ENV:Computername +"$"
}

if (get-service | Where-Object {$_.name -eq $Instance} ) {
    Write-Log -Value "SQL Server is already installed"
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Instance'"
    Invoke-CimMethod -InputObject $service -MethodName Change -Arguments @{StartName = $ServiceAccountSQL}
    start-service -Name $Instance
    sc.exe config $Instance start= auto
    while ((get-service -Name $Instance).Status -ne 'Running') {
        Write-Log -Value "Waiting for SQL Service to start"
        Start-Sleep -Seconds 2
    }
    write-log -Value "SQL Service is running under account: $ServiceAccountSQL"
    $svc = sc.exe qc mssqlserver | Out-String
    write-log -Value "$svc"

    # Create the login and add to sysadmin role
    $loginName = "$UserDomain\administrator"
    $script = @"
USE [master]
GO
-- Create the login if it doesn't exist
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = '$loginName')
BEGIN
    CREATE LOGIN [$loginName] FROM WINDOWS WITH DEFAULT_DATABASE=[master]
END

-- Add to sysadmin role
ALTER SERVER ROLE [sysadmin] ADD MEMBER [$loginName]
GO
"@

    # Execute the script
    Invoke-Sqlcmd -Query $script -TrustServerCertificate:$true -Username 'sa' -Password $SAPWD
    Write-Log -Value "Successfully added $loginName to sysadmin role"

    $script = @"
EXEC sp_dropserver @@SERVERNAME;
EXEC sp_addserver @server = '$HostName', @local = 'local';
"@

    Invoke-Sqlcmd -Query $script -TrustServerCertificate -Username 'sa' -Password $SAPWD

    Write-Log -Value "Server name change queued. Restarting SQL Server..."
    Restart-Service -Name $Instance -Force

    while ((get-service -Name $Instance).Status -ne 'Running') {
        Write-Log -Value "Waiting for SQL Service to start"
        Start-Sleep -Seconds 2
    }

    $verify = Invoke-Sqlcmd -Query "SELECT @@SERVERNAME AS ServerName" -TrustServerCertificate -Username 'sa' -Password $SAPWD
    Write-Log -Value "New server name: $($verify.ServerName)"

} else {
    Write-Log -Value "SQL Server will be installed"
    Copy-item "$INIFile" -Destination c:\temp\ -Force
    $INIFile = "C:\temp\$(Split-Path $INIFile -Leaf)"
    $SetupExe = "\applications2026\SQL 2025\setup.exe"

    Write-Log -Value "Modifying INI File: $INIFile"
    Write-Log -Value "Setting Service Account to: $ServiceAccountSQL"

    (Get-Content $INIFile).replace('<ServiceAccount>', $ServiceAccountSQL) | Set-Content $INIFile # Step 3.1: Modify INI File to use the MSA/gMSA Account
    (Get-Content $INIFile).replace('<DomainAdmin>', "$UserDomain\administrator") | Set-Content $INIFile # Step 3.2: Modify INI File to use the Domain Admin Account
    (Get-Content $INIFile).replace('<SAPWD>', $SAPWD) | Set-Content $INIFile # Step 3.3: Modify INI File to use the SAPWD
    
    Write-Log -Value "done Modifying INI File: $INIFile"
    Write-Log -Value "Starting SQL 2025 Installation using INI File: $INIFile and SetupExe: $SetupExe"
    Start-Process -FilePath $SetupExe -ArgumentList "/ConfigurationFile=$INIFile /IAcceptSQLServerLicenseTerms" -Wait # Step 4: Install SQL using INI File

    Write-Log -Value "Finished SQL 2025 Installation"
}

Write-Log -Value "Setting SPNs for SQL Service Account: $ServiceAccountSQL"
$HostFQDN = "$HostName.$Domain"
$SPNfqdn = "MSSQLSvc/${HostFQDN}"
$SPN = "MSSQLSvc/${HostName}"

setspn -D $SPNfqdn $ServiceAccountSQL
setspn -D $SPN $ServiceAccountSQL

Start-Sleep -Seconds 2

setspn -A $SPNfqdn $ServiceAccountSQL
setspn -A $SPN $ServiceAccountSQL

setspn -L $ServiceAccountSQL | Out-File -FilePath "c:\temp\SPN_$HostName.txt" -Force
Write-Log -Value "Done Setting SPNs for SQL Service Account: $ServiceAccountSQL"

Write-Log -Value "Starting SQL Certificate Installation using PFX File: $SQLPFXFile"

$PFXPassword = ConvertTo-SecureString -String $PFXPwd -AsPlainText -Force
& '.\SQL Certificate\install-cert.ps1' -SQLPFXFile $SQLPFXFile -ServiceAccountSQL $ServiceAccountSQL -listenername $SQLAOListenerName -PFXPassword $PFXPassword # Step 5: Install SQL Certificate

Write-Log -Value "Done SQL Certificate Installation using PFX File: $SQLPFXFile"
Write-Log -Value "setting up firewall rules for SQL Server"

& '.\SQL Server Firewall Settings\install-firewall.ps1' # Step 6: Setup Firewall Rules for SQL Server

Write-Log -Value "Done setting up firewall rules for SQL Server"
Write-Log -Value "setting up SQL Server Powershell Modules"

& '.\SQL Server POSH Module\install.ps1' # Step 7: Setup SQL Server Powershell Modules

Write-Log -Value "Done setting up SQL Server Powershell Modules"
if ($AO) {
    write-log -Value "Starting setup of Cluster for: $SQLAOClusterName"
    if ($FirstNode) {
        write-log -Value "This is the first node: $HostName. Setting up cluster $SQLAOClusterName" # Step 8: Setup Cluster on first node
        & '.\SQL AO Cluster Setup\Setup-AOCluster.ps1' -Nodes $Nodes `
         -SQLAOClusterName $SQLAOClusterName `
         -SQLAOClusterIP $SQLAOClusterIP `
         -SQLAOClusterShare $SQLAOClusterShare `
         -SQLAOListenerName $SQLAOListenerName `
         -SQLAOgMSA $SQLAOgMSA `
         -Domain $Domain
        Write-Log -Value "Cluster $SQLAOClusterName setup completed on first node: $HostName"

        Write-Log -Value "Creating DNS Record for Listener $SQLAOListenerName with IP $SQLAOListenerIP"
        & '.\SQL AO DNS\setup-dns.ps1' -SQLAOListenerName $SQLAOListenerName -SQLAOListenerIP $SQLAOListenerIP -SQLAOClusterName $SQLAOClusterName -Domain $Domain # Step 9: Setup DNS Record for Listener
        Write-Log -Value "DNS setup completed for listener $SQLAOListenerName"

    } else {
        Set-Content -Path c:\temp\DeploymentFinished.txt -Value "done" -Force
        while ((get-service -Name 'ClusSvc').Status -ne 'Running') {
            Write-Log -Value "Waiting for Cluster Service to start"
            Start-Sleep -Seconds 5
        }
        while (!(Get-Cluster | Where-Object {$_.Name -eq $SQLAOClusterName})) {
            Write-Log -Value "Waiting for cluster $SQLAOClusterName to be finished on node $($Nodes[0])"
            Start-Sleep -Seconds 5
        }
        Write-Log -Value "Node: $($Nodes[0]) has now setup the cluster: $SQLAOClusterName"
    }

    Start-Sleep -Seconds 3

    [bool]$SQLAlwaysOnEnabled = $false
    while (!$SQLAlwaysOnEnabled) {
        try {
            Enable-SqlAlwaysOn -ServerInstance "$ENV:ComputerName" -Force
            $SQLAlwaysOnEnabled = $true
            write-log -Value "Successfully enabled Always On on $ENV:ComputerName"
        }
        catch {
            Write-Log -Value "Failed to enable Always On, retry"
            Start-Sleep -Seconds 3
        }
    }

    Start-Sleep -Seconds 2

    if ($FirstNode) {
        & '.\sql always on\SQL AO Database Setup.ps1' -Nodes $Nodes -AGName $AGName -SQLAOgMSA $SQLAOgMSA -SQLAOListenerName $SQLAOListenerName -SQLAOListenerIP $SQLAOListenerIP -Domain $Domain # Step 10: Setup Always On Availability Group Database
        write-log -Value "Done setting up Always On Availability Group: $AGName"
    }
    & '.\sql always on\Cluster-setup-owner.ps1' -SQLListener $SQLAOListenerName
 }

Write-Log -Value "SQL 2025 Installation Script Completed"
