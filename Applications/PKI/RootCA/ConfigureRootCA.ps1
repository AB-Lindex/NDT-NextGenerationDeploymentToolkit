Install-AdcsCertificationAuthority -CAType StandaloneRootCA -KeyLength 4096 -ValidityPeriod Years -ValidityPeriodUnits 15 -HashAlgorithmName sha256 -CADistinguishedNameSuffix "dc=fcdinfra,dc=com" -force

Get-CACrlDistributionPoint | Where-Object {$_.uri -notmatch "windows"} | Remove-CACrlDistributionPoint -force
Get-CAAuthorityInformationAccess | Where-Object {$_.uri -NotMatch "windows"} | Remove-CAAuthorityInformationAccess -force

Add-CAAuthorityInformationAccess -AddToCertificateAia -Uri "http://crl.pkilab.corp/CertEnroll/<ServerDNSName>_<CaName><CertificateName>.crt" -force
Add-CACrlDistributionPoint -Uri "http://crl.pkilab.corp/CertEnroll/<CAName><CRLNameSuffix><DeltaCRLAllowed>.crl" -AddToCertificateCdp -AddToFreshestCrl -force

certutil.exe -setreg CA\CRLPeriodUnits 400
certutil.exe -setreg CA\CRLPeriod "Days"

certutil.exe -setreg CA\ValidityPeriodUnits 8
certutil.exe -setreg CA\ValidityPeriod "Years"

restart-service -Name CertSvc

Start-Sleep -Seconds 5

certutil.exe -crl

# Root cert finns i c:\caconfig samt c:\windows\system32\certsrv\certenroll

while ((Get-ChildItem c:\windows\system32\certsrv\certenroll).count -lt 2) {
   Write-Output "too few!"
}

# Setup WinRm for a Workgroup server
New-NetFirewallRule -Name "WinRM_HTTP" -DisplayName "WinRM over HTTP" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 5985 -Profile Any

$listener = Get-WSManInstance -ResourceURI winrm/config/Listener -Enumerate | Where-Object { $_.Transport -eq "HTTP" }
if (-not $listener) {
   New-WSManInstance -ResourceURI winrm/config/Listener -SelectorSet @{Transport="HTTP"; Address="*"} -ValueSet @{Port="5985"; Enabled="true"}
} else {
   Write-Output "Listener for WinRM already in place"
}
New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" `
    -Name "LocalAccountTokenFilterPolicy" `
    -Value 1 `
    -PropertyType DWord `
    -Force
Enable-PSRemoting -Force
Set-Service -Name WinRM -StartupType Automatic -Status Running
