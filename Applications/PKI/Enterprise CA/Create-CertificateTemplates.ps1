$templateToClone = "WebServer"
$newTemplateName = "WebServer3Years"
$newDisplayName = "WebServer3Years"

# Bind to the AD container for certificate templates
$templatesContainer = [ADSI]"LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=ad01,DC=corp"

# Find the source template
#$sourceTemplate = $templatesContainer.Children | Where-Object { $_.Name -eq "CN=$templateToClone" }
$sourceTemplate = $templatesContainer.Children | Where-Object { $_.distinguishedName -match "CN=$templateToClone" }


# Duplicate the template
$newTemplate = $templatesContainer.Create("pKICertificateTemplate", "CN=$newTemplateName")

# Copy all properties from the source template
$sourceTemplate.Properties.PropertyNames | ForEach-Object {
    try {a
        $newTemplate.Properties[$_].Value = $sourceTemplate.Properties[$_].Value
    } catch {
        Write-Warning "Couldn't copy property $sourceTemplate.Properties[$_].Value"
    }
}

# Set the new display name and name
$newTemplate.Put("displayName", $newDisplayName)
$newTemplate.Put("name", $newTemplateName)

# Set to V2 template (Windows Server 2003)
$newTemplate.Put("revision", 100)
$newTemplate.Put("msPKI-TemplateSchemaVersion", 2)
$newTemplate.Put("msPKI-TemplateMajorRevision", 1)
$newTemplate.Put("msPKI-TemplateMinorRevision", 0)

# Commit the changes
$newTemplate.SetInfo()

