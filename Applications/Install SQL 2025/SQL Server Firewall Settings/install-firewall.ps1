$FWProfile = "Domain,Private,Public"

$port = 1433
$ruleName = "SQL Server (TCP 1433)"
Get-NetFirewallRule | Where-Object { $_.DisplayName -eq $ruleName } | Remove-NetFirewallRule -Confirm:$false
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort $port `
    -Action Allow `
    -Profile $FWProfile

$port = 1434
$ruleName = "SQL Browser (UDP 1434)"
Get-NetFirewallRule | Where-Object { $_.DisplayName -eq $ruleName } | Remove-NetFirewallRule -Confirm:$false
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound `
    -Protocol UDP `
    -LocalPort $port `
    -Action Allow `
    -Profile $FWProfile

$port = 5022
$ruleName = "SQL Always On (TCP 5022)"
Get-NetFirewallRule | Where-Object { $_.DisplayName -eq $ruleName } | Remove-NetFirewallRule -Confirm:$false
New-NetFirewallRule -DisplayName $ruleName `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort $port `
    -Action Allow `
    -Profile $FWProfile
