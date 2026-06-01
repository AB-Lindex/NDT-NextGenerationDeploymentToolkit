param (
    [Parameter(Mandatory)]
    [string]$CertificateFileName,
    [Parameter(Mandatory)]
    [string]$CertificatePwd
)
import-pfxcertificate -FilePath "$PSScriptRoot\$CertificateFileName" `
 -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -AsPlainText -Force -String $CertificatePwd)
