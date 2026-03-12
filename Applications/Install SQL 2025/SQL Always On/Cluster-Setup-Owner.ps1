Param(
    [parameter(Mandatory = $true)]
    [string]$SQLListener
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

$Query1 = "SELECT e.name as EndpointName,sp.name AS EndpointOwner FROM sys.endpoints e INNER JOIN
           sys.server_principals sp ON e.principal_id = sp.principal_id  Where e.name = 'Hadr_endpoint'"

$Query2 = "SELECT ar.replica_server_name ,ag.name AS ag_name ,ar.owner_sid ,sp.name FROM
            sys.availability_replicas ar LEFT JOIN sys.server_principals sp ON sp.sid = ar.owner_sid INNER JOIN
            sys.availability_groups ag ON ag.group_id = ar.group_id WHERE ar.replica_server_name = SERVERPROPERTY('ServerName')"

$Query3 = "SELECT ag.name FROM sys.availability_groups ag
            INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
            WHERE ar.replica_server_name = SERVERPROPERTY('ServerName')"

# Wait until SQL is reachable via the listener
[bool]$SQLSuccess = $false
while (!$SQLSuccess) {
    try {
        $AGName = (Invoke-Sqlcmd -ServerInstance $SQLListener -Database master -TrustServerCertificate:$true -Query $Query3 -ErrorAction Stop).name
        $SQLSuccess = $true
    }
    catch {
        Write-Log -Value "Failed to connect to $SQLListener, retrying"
        Start-Sleep -Seconds 3
    }
}

$db_startname = (Get-CimInstance -ClassName Win32_Service -Filter "Name='MSSQLSERVER'").StartName
$db_endpointowner = (Invoke-Sqlcmd -ServerInstance $env:computername -Database master -TrustServerCertificate:$true -Query $Query1).EndpointOwner
$db_agowner = (Invoke-Sqlcmd -ServerInstance $env:computername -Database master -TrustServerCertificate:$true -Query $Query2).name

Write-Log -Value "Service Start Name: $db_startname"
Write-Log -Value "Endpoint Owner: $db_endpointowner"
Write-Log -Value "AG Owner: $db_agowner"

Write-Host "*********************************************************************" -ForegroundColor DarkYellow
Write-Host "Verifying: $env:computername" -ForegroundColor Yellow
Write-Host "*********************************************************************" -ForegroundColor DarkYellow

if ($db_agowner -ne $db_startname) {
    Write-Host "AG Owner needs to change from $db_agowner to $db_startname" -ForegroundColor Yellow
    Write-Log -Value "AG Owner needs to change from $db_agowner to $db_startname"

    $db_change_sql = "ALTER AUTHORIZATION ON AVAILABILITY GROUP::[$AGName] to [$db_startname]"
    Write-Log -Value "SQL: $db_change_sql"

    [bool]$SQLSuccess = $false
    while (!$SQLSuccess) {
        try {
            Invoke-Sqlcmd -ServerInstance $env:computername -Database master -TrustServerCertificate:$true -Query $db_change_sql -ErrorAction Stop
            $SQLSuccess = $true
        }
        catch {
            Write-Log -Value "Failed to execute AG owner change, retrying: $_"
            Start-Sleep -Seconds 3
        }
    }
}
else {
    Write-Log -Value "Owner is correctly set for AG"
}

if ($db_endpointowner -ne $db_startname) {
    Write-Host "Endpoint Owner needs to change from $db_endpointowner to $db_startname" -ForegroundColor Yellow
    Write-Log -Value "Endpoint Owner needs to change from $db_endpointowner to $db_startname"

    $db_change_sql = "ALTER AUTHORIZATION ON ENDPOINT::Hadr_endpoint TO [$db_startname]"
    Write-Log -Value "SQL: $db_change_sql"

    [bool]$SQLSuccess = $false
    while (!$SQLSuccess) {
        try {
            Invoke-Sqlcmd -ServerInstance $env:computername -Database master -TrustServerCertificate:$true -Query $db_change_sql -ErrorAction Stop
            $SQLSuccess = $true
        }
        catch {
            Write-Log -Value "Failed to execute endpoint owner change, retrying: $_"
            Start-Sleep -Seconds 3
        }
    }
}
else {
    Write-Log -Value "EndpointOwner is correctly set for AG"
}
