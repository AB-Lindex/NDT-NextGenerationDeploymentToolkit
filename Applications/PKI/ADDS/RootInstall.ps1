New-Item -ItemType directory -Path C:\CertEnroll
New-SmbShare -Name CertEnroll$ -Path C:\CertEnroll -FullAccess everyone

while (!(Test-Path -Path C:\CertEnroll\*root*.crt)) {
   "waiting"
   Start-Sleep 2
}

foreach ($cert in Get-ChildItem -Path C:\CertEnroll\*root*.crt) {
   Import-Certificate -FilePath $cert.FullName -CertStoreLocation  Cert:\LocalMachine\Root\
}
