Param(
    [parameter(Mandatory = $true)]
    [string]$SQLListener,
    [parameter(Mandatory = $true)]
    [string]$SAPWD
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

if (get-module -Name SqlServer) {
    remove-module SqlServer -Force
}
import-module dbatools -ArgumentList @{SkipAzure = $true}

Set-DbatoolsConfig -Name Import.EncryptionMessageCheck -Value $false -PassThru | Register-DbatoolsConfig
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true -Register 
Set-DbatoolsConfig -FullName sql.connection.encrypt -Value $false -Register

$SqlCredential = New-Object System.Management.Automation.PSCredential('sa', (ConvertTo-SecureString $SAPWD -AsPlainText -Force))

[bool]$SQLSuccess = $false
while (!$SQLSuccess) {
    try {
        $AG = Get-DbaAgReplica -SqlInstance $SQLListener -SqlCredential $SqlCredential -WarningAction SilentlyContinue
        $AGName = $AG.availabilitygroup[0]
        $SQLSuccess = $true
    }
    catch {
        Write-Log -Value "Failed to connect to database $SQLListener, retrying"
        Start-Sleep -Seconds 3
    }
}

$Query1 = "SELECT e.name as EndpointName,sp.name AS EndpointOwner FROM sys.endpoints e INNER JOIN `
           sys.server_principals sp ON e.principal_id = sp.principal_id  Where e.name = 'Hadr_endpoint' "

$Query2 = "SELECT ar.replica_server_name ,ag.name AS ag_name ,ar.owner_sid ,sp.name FROM `
            sys.availability_replicas ar LEFT JOIN sys.server_principals sp ON sp.sid = ar.owner_sid INNER JOIN `
            sys.availability_groups ag ON ag.group_id = ar.group_id WHERE ar.replica_server_name = SERVERPROPERTY('ServerName') "

$db_startname = (Get-DbaService | Where-Object servicetype -eq 'Engine').StartName
$db_endpointowner = (Invoke-DbaQuery -SqlInstance $env:computername -SqlCredential $SqlCredential -Database master -Query $Query1).EndpointOwner
$db_agowner = (Invoke-DbaQuery -SqlInstance $env:computername -SqlCredential $SqlCredential -Database master -Query $Query2).Name

Write-Log -Value "Service Start Name: $db_startname"
Write-Log -Value "Endpoint Owner: $db_endpointowner"
Write-Log -Value "AG Owner: $db_agowner"

Write-Host "*********************************************************************" -ForegroundColor DarkYellow
Write-Host "Verifying: $env:computername" -ForegroundColor Yellow
Write-Host "*********************************************************************" -ForegroundColor DarkYellow

if ($db_agowner -ne $db_startname) {
    Write-Host "AG Owner needs to change from $db_agowner to $db_startname" -ForegroundColor Yellow
    Write-Log -Value "AG Owner needs to change from $db_agowner to $db_startname"

    $db_change_sql = "ALTER AUTHORIZATION ON AVAILABILITY GROUP::[$AGName] to [$db_startname] "
    Write-Log -Value "SQL: $db_change_sql"

    [bool]$SQLSuccess = $false
    while (!$SQLSuccess) {
        try {
            Invoke-DbaQuery -SqlInstance $env:computername -SqlCredential $SqlCredential -Database master -Query $db_change_sql
            $SQLSuccess = $true
        }
        catch {
            Write-Log -Value "Failed to connect to database $SQLListener, retrying"
            Start-Sleep -Seconds 3
        }
    }
}
else { 
    Write-Log -Value "Owner is correctly set for AG"
}

if ($db_endpointowner -ne $db_startname ) {
    Write-Host "Endpoint Owner needs to change from $db_endpointowner to $db_startname" -ForegroundColor Yellow
    Write-Log -Value "Endpoint Owner needs to change from $db_endpointowner to $db_startname"

    $db_change_sql = "ALTER AUTHORIZATION ON ENDPOINT::Hadr_endpoint TO [$db_startname] "
    Write-Log -Value "SQL: $db_change_sql"

    [bool]$SQLSuccess = $false
    while (!$SQLSuccess) {
        try {
            Invoke-DbaQuery -SqlInstance $env:computername -SqlCredential $SqlCredential -Database master -Query $db_change_sql
            $SQLSuccess = $true
        }
        catch {
            Write-Log -Value "Failed to connect to database $SQLListener, retrying"
            Start-Sleep -Seconds 3
        }
    }
}
else { 
    Write-Log -Value "EndpointOwner is correctly set for AG"
}
