import-pfxcertificate -FilePath "$PSScriptRoot\psgallery.corp.dev.pfx" -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -AsPlainText -Force -String '1q2w3e4r')
