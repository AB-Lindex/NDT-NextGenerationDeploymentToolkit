install-module -Name ndt -Force -Scope AllUsers
Install-NDT -DeployPassword (ConvertTo-SecureString -AsPlainText -Force -String 'P@ssw0rd2026')

Build-NDTPEImage
