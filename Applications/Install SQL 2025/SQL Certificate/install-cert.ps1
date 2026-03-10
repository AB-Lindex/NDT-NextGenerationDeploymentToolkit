param (
    [Parameter(Mandatory)]
    [string]$listener,
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

$SQLPFXFile = Join-Path -Path $PSScriptRoot -ChildPath $SQLPFXFile

write-log -Value "Starting SQL Certificate Installation using PFX File: $SQLPFXFile"
$Cert = Import-PfxCertificate -Password $PFXPassword -CertStoreLocation Cert:\LocalMachine\My\ -FilePath $SQLPFXFile
$Thumbprint = $cert.Thumbprint

Write-Log -Value "Setting up permissions on key for $ServiceAccountSQL"

# Resolve private key path — handle both modern CNG and legacy CSP keys
$privateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
if ($privateKey -is [System.Security.Cryptography.RSACng]) {
    # CNG key (modern PFX)
    $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\Keys" $privateKey.Key.UniqueName
    Write-Log -Value "CNG private key path: $keyPath"
} else {
    # Legacy CSP key
    $keyPath = Join-Path "$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys" $cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
    Write-Log -Value "CSP private key path: $keyPath"
}

if (-not (Test-Path $keyPath)) {
    Write-Log -Value "ERROR: Private key file not found at: $keyPath"
    throw "Private key file not found. Cannot grant permissions."
}

$acl = Get-Acl -Path $keyPath
$permission = $ServiceAccountSQL, "Read", "Allow"
$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
$acl.SetAccessRule($accessRule)
$acl | Set-Acl -Path $keyPath
Write-Log -Value "Granted Read on private key to $ServiceAccountSQL"

$instanceName = "MSSQLSERVER"
$sqlVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').$instanceName
$regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$sqlVersion\MSSQLServer\SuperSocketNetLib"

Write-Log -Value "Setting registry values $Thumbprint $listener for SQL Server instance $instanceName"

Set-ItemProperty -Path $regPath -Name "Certificate" -Value $Thumbprint
Set-ItemProperty -Path $regPath -Name "HostNameInCertificate" -Value "$listener"
Set-ItemProperty -Path $regPath -Name "ForceEncryption" -Value 1 -Type DWord

Restart-Service -Name $instanceName -Force
$ServiceResult = Get-Service -name $instanceName | Out-String

Write-Log -Value $ServiceResult
Write-Log -Value "Done SQL Certificate Installation using PFX File: $SQLPFXFile"
read-host "Press Enter to continue..."
