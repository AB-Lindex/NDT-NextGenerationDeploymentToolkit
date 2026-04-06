do {
    Clear-DnsClientCache
    Start-Sleep -Seconds 2

    net use \\dc1.ad01.corp\CertEnroll$ /user:ad01\administrator Qantas-717 2>$null

} while ($LASTEXITCODE -ne 0)

while (!(Test-Path -Path \\dc1.ad01.corp\CertEnroll$\*root*.crt)) {
    "waiting"
    Start-Sleep 2
 }

net use \\dc1.ad01.corp\CertEnroll$ /d /y
$Password = ConvertTo-SecureString -AsPlainText -Force -String 'Qantas-717'
$cred = New-Object System.Management.Automation.PSCredential("administrator@ad01.corp", $Password)
add-computer -DomainName ad01.corp -Credential $cred
