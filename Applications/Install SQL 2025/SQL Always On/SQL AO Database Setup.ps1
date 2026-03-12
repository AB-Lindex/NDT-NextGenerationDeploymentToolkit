param (
    [Parameter(Mandatory)]
    [string[]]$Nodes,
    [Parameter(Mandatory)]
    [string]$AGName,
    [Parameter(Mandatory)]
    [string]$SQLAOgMSA,
    [Parameter(Mandatory)]
    [string]$SQLAOListenerName,
    [Parameter(Mandatory)]
    [string]$SQLAOListenerIP,
    [Parameter(Mandatory)]
    [string]$Domain,
    [Parameter(Mandatory)]
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

write-log -Value "Creating the database on $ENV:Computername"
Invoke-Sqlcmd -ServerInstance $ENV:Computername -TrustServerCertificate:$true -Username 'sa' -Password $SAPWD -InputFile (Join-Path $PSScriptRoot 'Database01 - 2025.sql')

#$sqlOutput = & 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -U sa -P $SAPWD -i (Join-Path $PSScriptRoot 'Database01 - 2025.sql') -C 2>&1
#$sqlOutput | ForEach-Object { write-log -Value $_ }
#if ($LASTEXITCODE -ne 0) { throw "sqlcmd exited with code $LASTEXITCODE creating database" }

write-log -Value "Backing up the database on $ENV:Computername"
Invoke-Sqlcmd -ServerInstance $ENV:Computername -TrustServerCertificate:$true -Username 'sa' -Password $SAPWD -InputFile (Join-Path $PSScriptRoot 'DBBackup - 2025.sql')

read-host "press enter to continue now that DB is created and backed up"

#$sqlOutput = & 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -U sa -P $SAPWD -i (Join-Path $PSScriptRoot 'DBBackup - 2025.sql') -C 2>&1
#$sqlOutput | ForEach-Object { write-log -Value $_ }
#if ($LASTEXITCODE -ne 0) { throw "sqlcmd exited with code $LASTEXITCODE backing up database" }

for ($i = 1; $i -le $Nodes.Count; $i++) {
    $AGSQL = Get-Content -Path '.\SQL Always On\SetupAG01.sql' -raw


    $AGSQL = $AGSQL.Replace("<NODEX>", $($Nodes[$i-1]))
    $AGSQL = $AGSQL.Replace("<MSAUSER>","$UserDomain\$SQLAOgMSA`$")

    $AGSQL | Set-Content -Path "c:\temp\SetupAG01$i.sql" -Force
    write-log -Value "Connecting to node $($Nodes[$i-1]) and adding gMSA as an endpoint user"
    & 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -U sa -P $SAPWD -Q $AGSQL -C
}

$AGSQL = Get-Content -Path '.\SQL Always On\SetupAG02.sql' -raw

$AGSQL = $AGSQL.Replace("<NODEX>", $($Nodes[0]))
$AGSQL = $AGSQL.Replace('<AGNAME>',$AGName)

for ($i = 1; $i -le $Nodes.Count; $i++) {
    $AGSQL = $AGSQL + "    N'$($Nodes[$i-1])' WITH (ENDPOINT_URL = N'TCP://$($Nodes[$i-1]).$($Domain):5022', FAILOVER_MODE = AUTOMATIC, AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, BACKUP_PRIORITY = 50, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE(READ_ONLY_ROUTING_URL = NONE, ALLOW_CONNECTIONS = ALL))"
    if ($i -lt $Nodes.Count) {
        $AGSQL = $AGSQL + "," + [Environment]::NewLine
    } else {
        $AGSQL = $AGSQL + ";" + [Environment]::NewLine + "GO" + [Environment]::NewLine
    }
}
$AGSQL | Set-Content -Path "c:\temp\SetupAG02.sql" -Force

read-host "press enter #1"
& 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -U sa -P $SAPWD -Q $AGSQL -C
read-host "press enter #11"



$AGSQL = Get-Content -Path '.\SQL Always On\SetupAG03.sql' -raw

$AGSQL = $AGSQL.Replace("<NODEX>", $($Nodes[0]))
$AGSQL = $AGSQL.Replace('<AGNAME>',$AGName)
$AGSQL = $AGSQL.Replace('<LISTENERNAME>',$SQLAOListenerName)
$AGSQL = $AGSQL.Replace('<LISTENERIP>',$SQLAOListenerIP)

$AGSQL | Set-Content -Path "c:\temp\SetupAG03.sql" -Force
read-host "press enter #2"

& 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -U sa -P $SAPWD -Q $AGSQL -C
read-host "press enter #22"


for ($i = 2; $i -le $Nodes.Count; $i++) { # for all nodes but the first
    $AGSQL = Get-Content -Path '.\SQL Always On\SetupAG04.sql' -raw

    $AGSQL = $AGSQL.Replace('<AGNAME>',$AGName)
    $AGSQL = $AGSQL.Replace("<NODEX>", $($Nodes[$i-1]))

    $AGSQL | Set-Content -Path "c:\temp\SetupAG04$i.sql" -Force
read-host "press enter #3"
    & 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -U sa -P $SAPWD -Q $AGSQL -C
read-host "press enter #33"
}
