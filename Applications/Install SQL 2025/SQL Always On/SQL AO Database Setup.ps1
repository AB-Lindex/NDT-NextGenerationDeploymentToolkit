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
    [string]$Domain
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
Invoke-Sqlcmd -ServerInstance $ENV:Computername -TrustServerCertificate:$true -InputFile (Join-Path $PSScriptRoot 'Database01 - 2025.sql')

write-log -Value "Backing up the database on $ENV:Computername"
Invoke-Sqlcmd -ServerInstance $ENV:Computername -TrustServerCertificate:$true -InputFile (Join-Path $PSScriptRoot 'DBBackup - 2025.sql')

for ($i = 1; $i -le $Nodes.Count; $i++) {
    $AGSQL = Get-Content -Path '.\SQL Always On\SetupAG01.sql' -raw


    $AGSQL = $AGSQL.Replace("<NODEX>", $($Nodes[$i-1]))
    $AGSQL = $AGSQL.Replace("<MSAUSER>","$UserDomain\$SQLAOgMSA`$")

    $AGSQL | Set-Content -Path "c:\temp\SetupAG01$i.sql" -Force
    write-log -Value "Connecting to node $($Nodes[$i-1]) and adding gMSA as an endpoint user"
    & 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -E -C -Q $AGSQL
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
& 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -E -C -Q $AGSQL



$AGSQL = Get-Content -Path '.\SQL Always On\SetupAG03.sql' -raw

$AGSQL = $AGSQL.Replace("<NODEX>", $($Nodes[0]))
$AGSQL = $AGSQL.Replace('<AGNAME>',$AGName)
$AGSQL = $AGSQL.Replace('<LISTENERNAME>',$SQLAOListenerName)
$AGSQL = $AGSQL.Replace('<LISTENERIP>',$SQLAOListenerIP)

$AGSQL | Set-Content -Path "c:\temp\SetupAG03.sql" -Force
& 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -E -C -Q $AGSQL


for ($i = 2; $i -le $Nodes.Count; $i++) { # for all nodes but the first
    $AGSQL = Get-Content -Path '.\SQL Always On\SetupAG04.sql' -raw

    $AGSQL = $AGSQL.Replace('<AGNAME>',$AGName)
    $AGSQL = $AGSQL.Replace("<NODEX>", $($Nodes[$i-1]))

    $AGSQL | Set-Content -Path "c:\temp\SetupAG04$i.sql" -Force
    & 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\SQLCMD.EXE' -S $ENV:Computername -E -C -Q $AGSQL
}
