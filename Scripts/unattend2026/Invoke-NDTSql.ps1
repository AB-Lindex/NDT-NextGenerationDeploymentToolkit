<#
.SYNOPSIS
    Runs a parameterised T-SQL statement against SQL Server over TCP with SQL authentication.
.DESCRIPTION
    Connection settings come from a named section in Control\Sections.json (default 'NDTSql'):
      Server (required), Database (required), Username, Password (required),
      Port (default 1433), Encrypt (default true), TrustServerCertificate (default false).
    Uses System.Data.SqlClient, so it runs in the production WinPE (PS 5.1 + WinPE-NetFx),
    the PS7 POC WinPE, and a normal OS. Keep it PS 5.1 compatible and ASCII-only.
    -Mode Rows (default) returns one PSCustomObject per row, Scalar the first column of the
    first row, NonQuery the affected-row count.
.EXAMPLE
    & Z:\Scripts\unattend2026\Invoke-NDTSql.ps1 -Query 'SELECT @@VERSION AS Version'
.EXAMPLE
    & Z:\Scripts\unattend2026\Invoke-NDTSql.ps1 -Query 'SELECT * FROM Machines WHERE Mac = @mac' -Parameter @{ mac = '00:15:5D:02:56:01' }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Query,

    [hashtable]$Parameter = @{},

    [ValidateSet('Rows', 'Scalar', 'NonQuery')]
    [string]$Mode = 'Rows',

    [string]$Section = 'NDTSql',

    [string]$ShareRoot = 'Z:\',

    [int]$ConnectTimeoutSec = 15,

    [int]$CommandTimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

foreach ($asm in 'System.Data', 'System.Data.SqlClient') {
    if ('System.Data.SqlClient.SqlConnection' -as [type]) { break }
    try { Add-Type -AssemblyName $asm -ErrorAction Stop } catch { }
}
if (-not ('System.Data.SqlClient.SqlConnection' -as [type])) {
    throw 'System.Data.SqlClient is not available in this PowerShell session.'
}

function ConvertTo-Bool($Value, [bool]$Default) {
    if ($null -eq $Value -or "$Value" -eq '') { return $Default }
    return ("$Value" -match '^(1|true|yes)$')
}

$sectionsPath = Join-Path $ShareRoot 'Control\Sections.json'
$cfg = (Get-Content -Path $sectionsPath -Raw | ConvertFrom-Json).$Section
if (-not $cfg) { throw "Section '$Section' not found in $sectionsPath" }
foreach ($k in 'Server', 'Database', 'Username', 'Password') {
    if (-not $cfg.$k) { throw "Section '$Section' is missing '$k'" }
}

$port = if ($cfg.Port) { [int]$cfg.Port } else { 1433 }

$csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
# The tcp: prefix forces TCP (no named pipes / shared memory).
$csb['Data Source']             = "tcp:$($cfg.Server),$port"
$csb['Initial Catalog']         = $cfg.Database
$csb['User ID']                 = $cfg.Username
$csb['Password']                = $cfg.Password
$csb['Encrypt']                 = ConvertTo-Bool $cfg.Encrypt $true
$csb['TrustServerCertificate']  = ConvertTo-Bool $cfg.TrustServerCertificate $false
$csb['Connect Timeout']         = $ConnectTimeoutSec
$csb['Application Name']        = 'NDT'

$conn = New-Object System.Data.SqlClient.SqlConnection $csb.ConnectionString
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText    = $Query
    $cmd.CommandTimeout = $CommandTimeoutSec
    foreach ($key in $Parameter.Keys) {
        $name  = if ("$key".StartsWith('@')) { "$key" } else { "@$key" }
        $value = $Parameter[$key]
        if ($null -eq $value) { $value = [DBNull]::Value }
        [void]$cmd.Parameters.AddWithValue($name, $value)
    }

    switch ($Mode) {
        'Scalar' {
            $v = $cmd.ExecuteScalar()
            if ($v -is [DBNull]) { $null } else { $v }
        }
        'NonQuery' { $cmd.ExecuteNonQuery() }
        default {
            $reader = $cmd.ExecuteReader()
            try {
                $table = New-Object System.Data.DataTable
                $table.Load($reader)
            } finally {
                $reader.Dispose()
            }
            foreach ($row in $table.Rows) {
                $o = [ordered]@{}
                foreach ($col in $table.Columns) {
                    $v = $row[$col]
                    $o[$col.ColumnName] = if ($v -is [DBNull]) { $null } else { $v }
                }
                [pscustomobject]$o
            }
        }
    }
} catch {
    throw "SQL $Mode on $($csb['Data Source']) / $($cfg.Database) failed: $($_.Exception.Message)"
} finally {
    $conn.Dispose()
}
