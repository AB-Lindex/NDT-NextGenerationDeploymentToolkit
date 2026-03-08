param (
    [Parameter(Mandatory)]
    [string[]]$Nodes,
    [Parameter(Mandatory)]
    [string]$SQLAOClusterName,
    [Parameter(Mandatory)]
    [string]$SQLAOClusterIP,
    [Parameter(Mandatory)]
    [string]$SQLAOClusterShare,
    [Parameter(Mandatory)]
    [string]$SQLAOListenerName,
    [Parameter(Mandatory)]
    [string]$SQLAOgMSA,
    [Parameter(Mandatory)]
    [string]$Domain
)
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )
    $LogFile = 'c:\temp\SQLsetup.log'
    $Timestamp = Get-Date -Format "HH:mm:ss"
    Add-Content -Path $LogFile -PassThru -Force -Value "$Timestamp $Value"
}

write-log -Value "Setting up SQL Always On $SQLAOClusterName with nodes: $($Nodes -join ', ')"
foreach ($Node in $Nodes[1..($Nodes.Count-1)]) {
    while (!(Test-Path "\\$Node\c$\temp\DeploymentFinished.txt")) {
        Write-Log -Value "Waiting for deployment of $Node to be finished."
        Start-Sleep -Seconds 5
    }
    Write-Log -Value "Server $Node is ready to be joined to cluster."
}

Get-ADComputer -Filter 'name -eq $SQLAOClusterName' | Remove-ADComputer -Confirm:$false
$FQDNNodes = $Nodes | ForEach-Object { "$_`.$Domain" }
New-Cluster -Name $SQLAOClusterName -Node $FQDNNodes -StaticAddress $SQLAOClusterIP
Set-ClusterQuorum -FileShareWitness $SQLAOClusterShare
Write-Log -Value "Cluster $SQLAOClusterName created with nodes: $($FQDNNodes -join ', ')"

Write-Log -Value "Creating AD Computer Object for Listener: $SQLAOListenerName"
$description = "SQL Always On Listener for Availability Group"
Get-ADComputer -Filter "name -eq '$SQLAOListenerName'" | Remove-ADComputer -Confirm:$false
New-ADComputer -Name $SQLAOListenerName `
            -Description $description `
            -Enabled $true

foreach ($Account in ("$SQLAOgMSA$", "$Domain\$SQLAOClusterName$")) {
    $listenerObject = Get-ADComputer -Identity $SQLAOListenerName

    $acl = Get-ACL -Path "AD:\$($listenerObject.DistinguishedName)"
    $identity = New-Object System.Security.Principal.NTAccount($Account)
    $accessRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($identity, "GenericAll", "Allow")
    $acl.AddAccessRule($accessRule)

    Set-ACL -Path "AD:\$($listenerObject.DistinguishedName)" -AclObject $acl
    Write-Log -Value "Full Control permissions assigned to $Account on $SQLAOListenerName."
}
