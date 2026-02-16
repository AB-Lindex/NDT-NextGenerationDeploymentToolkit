# Get MAC address from first IP-enabled adapter (WinPE compatible)
$adapter = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration | 
    Where-Object { $_.IPEnabled -eq $true } | 
    Select-Object -First 1

if (-not $adapter) {
    Write-Error "No IP-enabled network adapter found"
    exit 1
}

$macAddress = $adapter.MACAddress
Write-Host "Detected MAC Address: $macAddress" -ForegroundColor Yellow

# Return the MAC address
return $macAddress
