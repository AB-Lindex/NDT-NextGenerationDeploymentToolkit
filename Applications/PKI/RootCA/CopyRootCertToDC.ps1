do {
    Clear-DnsClientCache
    Start-Sleep -Seconds 2

    net use \\dc1.ad01.corp\CertEnroll$ /user:ad01\administrator Qantas-717 2>$null

} while ($LASTEXITCODE -ne 0)

xcopy $ENV:windir\system32\CertSrv\CertEnroll\*.* \\dc1.ad01.corp\CertEnroll$\ /y

net use \\dc1.ad01.corp\CertEnroll$ /d /y
