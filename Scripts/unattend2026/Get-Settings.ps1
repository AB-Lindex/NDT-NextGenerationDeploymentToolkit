# Read the JSON configuration
param(
    [Parameter(Mandatory=$true)]
    [string]$MACAddress
)

$jsonPath = "Z:\Control\CustomSettings.json"
$templatePath = "Z:\Scripts\unattend2026\unattend.xml"
$outputPath = "c:\temp\unattend.xml"

# Load JSON content
$config = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json

Write-Host "Using MAC Address: $MACAddress" -ForegroundColor Yellow

# Get machine configuration by MAC address
$machineConfig = $config.$MACAddress
if (-not $machineConfig) {
    Write-Error "No configuration found for MAC address: $MACAddress"
    exit 1
}

# Iterate through all sections and load their data
$sections = @{}
if ($machineConfig.Sections) {
    foreach ($sectionProperty in $machineConfig.Sections.PSObject.Properties) {
        $sectionName = $sectionProperty.Name
        $sectionReference = $sectionProperty.Value
        $sectionData = $config.$sectionReference
        
        if ($sectionData) {
            $sections[$sectionName] = $sectionData
            Write-Host "Loaded section: $sectionName -> $sectionReference" -ForegroundColor Cyan
        } else {
            Write-Warning "Section reference '$sectionReference' not found for $sectionName"
        }
    }
}

# Read the template
$unattendContent = Get-Content -Path $templatePath -Raw

# Replace placeholders from machine config
foreach ($property in $machineConfig.PSObject.Properties) {
    # Skip the Sections property
    if ($property.Name -eq 'Sections') {
        continue
    }
    
    $propertyName = $property.Name.ToUpper()
    $propertyValue = $property.Value
    $placeholder = "!$propertyName!"
    
    # Check if this placeholder exists in the template
    if ($unattendContent -match [regex]::Escape($placeholder)) {
        $unattendContent = $unattendContent -replace [regex]::Escape($placeholder), $propertyValue
        
        # Mask password in display output
        $displayValue = if ($property.Name -match 'Password') {
            $visibleChars = [Math]::Min(3, $propertyValue.Length)
            $propertyValue.Substring(0, $visibleChars) + ('*' * [Math]::Max(0, $propertyValue.Length - $visibleChars))
        } else {
            $propertyValue
        }
        
        Write-Host "Replaced $placeholder with $displayValue" -ForegroundColor Gray
    }
}

# Dynamically replace placeholders from all sections
foreach ($section in $sections.GetEnumerator()) {
    $sectionName = $section.Key
    $sectionData = $section.Value
    
    Write-Host "Processing section: $sectionName" -ForegroundColor Cyan
    
    foreach ($property in $sectionData.PSObject.Properties) {
        $propertyName = $property.Name.ToUpper()
        $propertyValue = $property.Value
        $placeholder = "!$propertyName!"
        
        # Check if this placeholder exists in the template
        if ($unattendContent -match [regex]::Escape($placeholder)) {
            $unattendContent = $unattendContent -replace [regex]::Escape($placeholder), $propertyValue
            
            # Mask password in display output
            $displayValue = if ($property.Name -match 'Password') {
                $visibleChars = [Math]::Min(3, $propertyValue.Length)
                $propertyValue.Substring(0, $visibleChars) + ('*' * [Math]::Max(0, $propertyValue.Length - $visibleChars))
            } else {
                $propertyValue
            }
            
            Write-Host "  Replaced $placeholder with $displayValue" -ForegroundColor Gray
        }
    }
}

# Ensure c:\temp exists
if (-not (Test-Path "c:\temp")) {
    New-Item -Path "c:\temp" -ItemType Directory -Force | Out-Null
}

# Save the modified unattend.xml
$unattendContent | Set-Content -Path $outputPath -Encoding UTF8

Write-Host "`nUnattend.xml created successfully at $outputPath" -ForegroundColor Green
Write-Host "`nApplied settings:" -ForegroundColor Cyan
Write-Host "  MAC Address: $MACAddress"

# Display machine config settings
Write-Host "`n  Machine Configuration:" -ForegroundColor Yellow
foreach ($property in $machineConfig.PSObject.Properties) {
    if ($property.Name -eq 'Sections') {
        continue
    }
    
    # Mask password in display output
    $displayValue = if ($property.Name -match 'Password') {
        $visibleChars = [Math]::Min(3, $property.Value.Length)
        $property.Value.Substring(0, $visibleChars) + ('*' * [Math]::Max(0, $property.Value.Length - $visibleChars))
    } else {
        $property.Value
    }
    
    Write-Host "    $($property.Name): $displayValue"
}

# Display settings from all sections dynamically
foreach ($section in $sections.GetEnumerator()) {
    Write-Host "`n  $($section.Key) Settings:" -ForegroundColor Yellow
    foreach ($property in $section.Value.PSObject.Properties) {
        # Mask password fields
        $displayValue = if ($property.Name -match 'Password') {
            $visibleChars = [Math]::Min(3, $property.Value.Length)
            $property.Value.Substring(0, $visibleChars) + ('*' * [Math]::Max(0, $property.Value.Length - $visibleChars))
        } else {
            $property.Value
        }
        Write-Host "    $($property.Name): $displayValue"
    }
}

# Display all loaded sections
Write-Host "`nLoaded sections:" -ForegroundColor Cyan
foreach ($section in $sections.GetEnumerator()) {
    # Create a copy of the section data to mask sensitive info
    $sectionData = $section.Value | ConvertTo-Json -Compress | ConvertFrom-Json
    
    # Mask password fields if they exist
    if ($sectionData.Password) {
        $visibleChars = [Math]::Min(3, $sectionData.Password.Length)
        $sectionData.Password = $sectionData.Password.Substring(0, $visibleChars) + ('*' * [Math]::Max(0, $sectionData.Password.Length - $visibleChars))
    }
    
    Write-Host "  $($section.Key): $($sectionData | ConvertTo-Json -Compress)"
}
