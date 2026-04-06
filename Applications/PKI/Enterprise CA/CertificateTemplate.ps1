Import-Module -Name PSPKI -Global

$CA = Get-CertificationAuthority -ComputerName "$ENV:ComputerName.$ENV:USERDNSDOMAIN"

$TemplateName = 'OCSPResponseSigning'

Get-CertificateTemplate -name $TemplateName | `
get-CertificateTemplateAcl | Add-CertificateTemplateAcl -Identity "$ENV:ComputerName$@$ENV:USERDNSDOMAIN" `
 -AccessType Allow -AccessMask read, enroll, autoenroll | Set-CertificateTemplateAcl

$Template = Get-CertificateTemplate -Name $TemplateName
Get-CATemplate -CertificationAuthority $CA | Add-CATemplate -Template $Template | Set-CATemplate

$TemplateName = 'CodeSigning'

Get-CertificateTemplate -name $TemplateName | `
get-CertificateTemplateAcl | Add-CertificateTemplateAcl -Identity "$ENV:ComputerName$@$ENV:USERDNSDOMAIN" `
 -AccessType Allow -AccessMask read, enroll, autoenroll | Set-CertificateTemplateAcl

$Template = Get-CertificateTemplate -Name $TemplateName
Get-CATemplate -CertificationAuthority $CA | Add-CATemplate -Template $Template | Set-CATemplate

