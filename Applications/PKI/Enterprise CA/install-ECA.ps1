Param(
    [parameter(Mandatory=$true)]
    [string]$CRLPath
)

Import-Certificate -FilePath $CRLPath\ROOTCA01_ROOTCA01-CA.crt -CertStoreLocation Cert:\LocalMachine\AuthRoot

Install-AdcsCertificationAuthority -CAType EnterpriseSubordinateCA -KeyLength 4096 -OutputCertRequestFile C:\$env:computername.req -force

Get-CACrlDistributionPoint | Where-Object {$_.uri -notmatch "windows"} | Remove-CACrlDistributionPoint -force
Get-CAAuthorityInformationAccess | Where-Object {$_.uri -NotMatch "windows"} | Remove-CAAuthorityInformationAccess -force

Add-CACrlDistributionPoint -Uri "file://$CRLPath\<CAName><CRLNameSuffix><DeltaCRLAllowed>.crl" -PublishToServer -PublishDeltaToServer -force
Add-CACrlDistributionPoint -Uri "http://crl.pkilab.corp/CertEnroll/<CAName><CRLNameSuffix><DeltaCRLAllowed>.crl" -AddToCertificateCdp -AddToFreshestCrl -force
Add-CAAuthorityInformationAccess -AddToCertificateAia -Uri "http://crl.pkilab.corp/CertEnroll/<ServerDNSName>_<CaName><CertificateName>.crt" -force

certutil -setreg ca\csp\CNGHashAlgorithm SHA256
certutil -setreg ca\ValidityPeriodUnits 5
Certutil -setreg ca\ValidityPeriod "Years"
Write-Output "CRLPath: $CRLPath"

$EncodedReq = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes((Get-Content -Path "C:\$ENV:ComputerName.req" -Encoding UTF8 -Raw)))

set-item wsman:\localhost\Client\TrustedHosts -value 10.0.1.101 -force:$TRUE
$Password = ConvertTo-SecureString -string "Qantas-707" -AsPlainText -force
$cred = New-Object System.Management.Automation.PSCredential ("rootca01\administrator", $Password)

$Certificate = Invoke-Command -ComputerName 10.0.1.101 -Credential $cred -ScriptBlock {
    param(
        [parameter(Mandatory=$true)]
        [string]$EncodedReq
    )
    Import-Module -Name PSPKI
    $ReqFile = "$ENV:temp\eca.req"
    $DecodeReq = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($EncodedReq))
    Set-Content -Value $DecodeReq -Path $reqFile -Encoding Ascii -Force
    $CA = Connect-CA -ComputerName $env:computername
    $Request = Submit-CertificateRequest -Path $ReqFile -CertificationAuthority $CA
    Get-pendingRequest -CertificationAuthority $CA -RequestID $Request.RequestID | Approve-CertificateRequest | Out-Null
    Get-IssuedRequest -CertificationAuthority $CA -RequestID $Request.RequestID | Receive-Certificate
} -ArgumentList $EncodedReq

$CertPath = "C:\Temp\IssuedCert.cer"
[System.IO.File]::WriteAllBytes($CertPath, $Certificate.RawData)
certutil -installcert $CertPath

xcopy C:\windows\System32\certsrv\CertEnroll\*.crt $CRLPath\ /y

start-service -name certsvc
while ((Get-Service -name certsvc).status -eq 'stopped') { 
    "waiting for service to start" 
    Start-Sleep -Seconds 2
}

