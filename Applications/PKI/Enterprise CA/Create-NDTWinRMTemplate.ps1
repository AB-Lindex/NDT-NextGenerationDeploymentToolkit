#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates the NDT-WinRM certificate template and publishes it on this enterprise CA.

.DESCRIPTION
    Run on the enterprise CA as an Enterprise Admin (the template lives in the forest Configuration partition).

    Template settings (schema v2, modelled on the built-in Kerberos Authentication template):
    - Subject and DNS SAN are built from Active Directory (never supplied in the request), so a server can
      only obtain a certificate for its own name.
    - Server Authentication only, RSA 2048, key exchange, non-exportable private key.
    - No CA manager approval, no autoenrollment. Servers request it with Get-Certificate
      (Applications\WinRMPS7\install.ps1 -CertTemplate NDT-WinRM).
    - Read + Enroll for the enroll group only (default Domain Computers).

    Idempotent: an existing template is left as it is; publishing on the CA is (re)checked.

.PARAMETER TemplateName
    Template name (also the display name). Default NDT-WinRM.

.PARAMETER ValidityYears
    Certificate validity in years, 1-5. Default 2.

.PARAMETER EnrollGroup
    Group (sAMAccountName) that receives Read + Enroll. Default Domain Computers.
#>
param (
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$TemplateName = 'NDT-WinRM',
    [ValidateRange(1, 5)]
    [int]$ValidityYears = 2,
    [string]$EnrollGroup = 'Domain Computers'
)

$ErrorActionPreference = 'Stop'

try {
    $rootDse = [ADSI]'LDAP://RootDSE'
    $configNC = [string]$rootDse.Properties['configurationNamingContext'].Value
    $domainNC = [string]$rootDse.Properties['defaultNamingContext'].Value
    $pkiPath = "CN=Public Key Services,CN=Services,$configNC"
    $templatesPath = "CN=Certificate Templates,$pkiPath"
    $oidPath = "CN=OID,$pkiPath"

    $templatesEntry = [ADSI]"LDAP://$templatesPath"
    $oidEntry = [ADSI]"LDAP://$oidPath"

    $searcher = New-Object System.DirectoryServices.DirectorySearcher($templatesEntry, "(&(objectClass=pKICertificateTemplate)(cn=$TemplateName))")
    $exists = $null -ne $searcher.FindOne()

    if ($exists) {
        Write-Host "Template '$TemplateName' already exists - not changed."
    }
    else {
        # Group that may enroll
        $groupSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$domainNC", "(&(objectCategory=group)(sAMAccountName=$EnrollGroup))")
        $groupResult = $groupSearcher.FindOne()
        if (-not $groupResult) { throw "Group '$EnrollGroup' not found in $domainNC." }
        $groupSid = New-Object System.Security.Principal.SecurityIdentifier([byte[]]$groupResult.Properties['objectsid'][0], 0)

        # A template needs its own OID object in the forest OID container (same layout the Certificate Templates console creates)
        $forestOid = [string]$oidEntry.Properties['msPKI-Cert-Template-OID'].Value
        if (-not $forestOid) { throw "Forest OID base not found on $oidPath." }
        $oidSearcher = New-Object System.DirectoryServices.DirectorySearcher($oidEntry, '(objectClass=msPKI-Enterprise-Oid)', @('msPKI-Cert-Template-OID'))
        $usedOids = @($oidSearcher.FindAll() | ForEach-Object { [string]$_.Properties['mspki-cert-template-oid'][0] })
        do {
            $part1 = Get-Random -Minimum 1000000 -Maximum 9999999
            $part2 = Get-Random -Minimum 10000000 -Maximum 99999999
            $templateOid = "$forestOid.$part1.$part2"
        } while ($usedOids -contains $templateOid)

        $oidObject = $oidEntry.Create('msPKI-Enterprise-Oid', ('CN={0}.{1}' -f $part2, ([guid]::NewGuid().ToString('N').ToUpper())))
        $oidObject.Put('msPKI-Cert-Template-OID', $templateOid)
        $oidObject.Put('flags', 1)
        $oidObject.Put('displayName', $TemplateName)
        $oidObject.SetInfo()
        Write-Host "Created OID $templateOid."

        $expiration = [BitConverter]::GetBytes([int64](-($ValidityYears * 365 * 24 * 3600 * 10000000L)))
        $overlap = [BitConverter]::GetBytes([int64](-(42 * 24 * 3600 * 10000000L)))
        $serverAuth = '1.3.6.1.5.5.7.3.1'

        $template = $templatesEntry.Create('pKICertificateTemplate', "CN=$TemplateName")
        $template.Put('displayName', $TemplateName)
        $template.Put('flags', 65632)
        $template.Put('revision', 100)
        $template.Put('msPKI-Template-Schema-Version', 2)
        $template.Put('msPKI-Template-Minor-Revision', 0)
        $template.Put('msPKI-Cert-Template-OID', $templateOid)
        $template.Put('msPKI-Certificate-Name-Flag', 402653184)   # SAN DNS + DNS name as CN, both from AD
        $template.Put('msPKI-Enrollment-Flag', 0)
        $template.Put('msPKI-Private-Key-Flag', 0)                # non-exportable
        $template.Put('msPKI-Minimal-Key-Size', 2048)
        $template.Put('msPKI-RA-Signature', 0)
        $template.Put('pKIDefaultKeySpec', 1)
        $template.Put('pKIDefaultCSPs', '1,Microsoft RSA SChannel Cryptographic Provider')
        $template.Put('pKIKeyUsage', [byte[]](160, 0))            # digital signature + key encipherment
        $template.Put('pKIMaxIssuingDepth', 0)
        $template.Put('pKIExpirationPeriod', [byte[]]$expiration)
        $template.Put('pKIOverlapPeriod', [byte[]]$overlap)
        $template.Put('pKICriticalExtensions', '2.5.29.15')
        $template.Put('pKIExtendedKeyUsage', $serverAuth)
        $template.Put('msPKI-Certificate-Application-Policy', $serverAuth)
        $template.SetInfo()

        # Read + Enroll for the enroll group
        $template = [ADSI]"LDAP://CN=$TemplateName,$templatesPath"
        $enrollRight = [guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
        $security = $template.psbase.ObjectSecurity
        $security.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($groupSid, 'GenericRead', 'Allow')))
        $security.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($groupSid, 'ExtendedRight', 'Allow', $enrollRight)))
        $template.psbase.ObjectSecurity = $security
        $template.psbase.CommitChanges()
        Write-Host "Created template '$TemplateName' (valid $ValidityYears year(s), Read + Enroll for '$EnrollGroup')."
    }

    # Publish on this CA; a fresh template may need AD replication first, so retry a few times
    $published = $false
    for ($attempt = 1; $attempt -le 4 -and -not $published; $attempt++) {
        $current = (& certutil.exe -CATemplates 2>&1) -join "`n"
        if ($current -match "(?m)^$([regex]::Escape($TemplateName))\s*:") { $published = $true; break }
        & certutil.exe -SetCATemplates "+$TemplateName" | Out-Null
        if ($LASTEXITCODE -eq 0) { $published = $true; break }
        Write-Host "Publish attempt $attempt failed (exit $LASTEXITCODE); waiting for AD replication..."
        Start-Sleep -Seconds 15
    }
    if (-not $published) { throw "Could not publish '$TemplateName' on this CA. Run on the CA: certutil -SetCATemplates +$TemplateName" }
    Write-Host "Template '$TemplateName' is published on this CA."
}
catch {
    Write-Error "NDT-WinRM template setup failed: $($_.Exception.Message)"
    exit 1
}
