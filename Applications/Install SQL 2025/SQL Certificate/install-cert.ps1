param (
    [Parameter(Mandatory)]
    [string]$listenername,
    [Parameter(Mandatory)]
    [string]$ServiceAccountSQL,
    [Parameter(Mandatory)]
    [string]$SQLPFXFile,
    [Parameter(Mandatory)]
    [SecureString]$PFXPassword
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

$SQLPFXFile = join-path -Path ".\SQL Certificate" -ChildPath $SQLPFXFile

write-log -Value "Starting SQL Certificate Installation using PFX File: $SQLPFXFile"

$Cert = Import-PfxCertificate -Password $PFXPassword -CertStoreLocation Cert:\LocalMachine\My\ -FilePath ".\$SQLPFXFile"
$Thumbprint = $cert.Thumbprint

Write-Log -Value "Setting up permissions on key for $ServiceAccountSQL"

$keyPath = [System.IO.Path]::Combine("$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys", $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName)
$acl = Get-Acl -Path $keyPath
$permission = $ServiceAccountSQL, "FullControl", "Allow"
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
$acl.SetAccessRule($accessRule)
$acl | Set-Acl -Path $keyPath

$instanceName = "MSSQLSERVER"
$sqlVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$instanceName
$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlVersion\MSSQLServer\SuperSocketNetLib"

Write-Log -Value "Setting registry values $Thumbprint $listenername"

Set-ItemProperty -Path $regPath -Name "Certificate" -Value $Thumbprint
Set-ItemProperty -Path $regPath -Name "HostNameInCertificate" -Value "$listenername"
Set-ItemProperty -Path $regPath -Name "ForceEncryption" -Value 1 -Type DWord

Restart-Service -Name $instanceName -Force
$ServiceResult = Get-Service -name $instanceName | Out-String

Write-Log -Value $ServiceResult
Write-Log -Value "Done SQL Certificate Installation using PFX File: $SQLPFXFile"