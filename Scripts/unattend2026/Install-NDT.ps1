# NDT  - Next Deployment Tool for 2026 Unattended Deployment.
# This script is designed to run on the deployed machine after the initial Windows PE phase, and will execute deployment steps defined in Deployment.json based on the machine's MAC address.
# It supports executing scripts, configuring autologon, and handling reboots as part of the deployment process.


# Get MAC address
$macAddress = & "Z:\Scripts\unattend2026\Get-MACAddress.ps1"

# Load CustomSettings.json
$customSettingsPath = "Z:\Control\CustomSettings.json"
$customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json

# Load Deployment.json
$deploymentPath = "Z:\Control\Deployment.json"
$deployment = Get-Content -Path $deploymentPath -Raw | ConvertFrom-Json

# Get machine configuration by MAC address
$machineConfig = $customSettings.$macAddress
if (-not $machineConfig) {
    Write-Error "No configuration found for MAC address: $macAddress"
    exit 1
}

# Check if DeploymentSteps reference exists
if (-not $machineConfig.DeploymentSteps) {
    Write-Host "No deployment steps defined for this machine" -ForegroundColor Yellow
    exit 0
}

# Get the deployment group reference(s) - can be string or array
$deploymentGroupRefs = $machineConfig.DeploymentSteps
if ($deploymentGroupRefs -is [string]) {
    $deploymentGroupRefs = @($deploymentGroupRefs)
}

Write-Host "Deployment groups: $($deploymentGroupRefs -join ', ')" -ForegroundColor Cyan

# Load settings.json for autologon credentials
$settingsPath = "C:\temp\settings.json"
if (Test-Path $settingsPath) {
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
    $autoLogonSettings = $settings.AutoLogon
} else {
    Write-Warning "Settings file not found: $settingsPath"
    $autoLogonSettings = $null
}

# Load or create install progress tracker
$progressPath = "C:\temp\install.json"
if (Test-Path $progressPath) {
    $progress = Get-Content -Path $progressPath -Raw | ConvertFrom-Json
    $completedSteps = @($progress.CompletedSteps)
} else {
    $completedSteps = @()
}

Write-Host "`nExecuting Deployment Steps..." -ForegroundColor Green
Write-Host "=============================" -ForegroundColor Green

# Process each deployment group
foreach ($deploymentGroupName in $deploymentGroupRefs) {
    $deploymentGroup = $deployment.$deploymentGroupName

    if (-not $deploymentGroup) {
        Write-Warning "Deployment group '$deploymentGroupName' not found in Deployment.json"
        continue
    }
    
    Write-Host "`nProcessing group: $deploymentGroupName" -ForegroundColor Yellow

    # Execute each deployment step from the deployment group
    foreach ($stepProperty in $deploymentGroup.PSObject.Properties) {
    $stepName = $stepProperty.Name
    $stepInfo = $stepProperty.Value
    
    # Create unique step identifier including group name
    $uniqueStepId = "${deploymentGroupName}_${stepName}"
    
    $description = $stepInfo.Description
    $stepReference = $stepInfo.Reference
    
    # Check if step already completed
    if ($completedSteps -contains $uniqueStepId) {
        Write-Host "`n[$stepName] $description" -ForegroundColor Gray
        Write-Host "Already completed - skipping" -ForegroundColor Gray
        continue
    }
    
    Write-Host "`n[$stepName] $description" -ForegroundColor Cyan
    
    # Get the referenced section from Deployment.json
    $stepSection = $deployment.$stepReference
    if (-not $stepSection) {
        Write-Warning "Step reference '$stepReference' not found in Deployment.json"
        continue
    }
    
    # Check if this is a reboot action
    if ($stepSection.Type -eq "Reboot") {
        Write-Host "Rebooting system..." -ForegroundColor Yellow
        
        # Mark this step as completed before rebooting
        $completedSteps += $uniqueStepId
        $progressData = @{
            CompletedSteps = $completedSteps
            LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $progressData | ConvertTo-Json | Set-Content -Path $progressPath -Encoding UTF8

        # Write AutoLogon credentials directly to the Winlogon registry.
        # RunOnce\Deploy2026 was already registered by install2026.ps1 at startup.
        $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $winlogonPath -Name AutoAdminLogon -Value '1' -Type String -Force
        if ($autoLogonSettings -and $autoLogonSettings.Username) {
            Set-ItemProperty -Path $winlogonPath -Name DefaultUserName -Value $autoLogonSettings.Username -Type String -Force
            "$autoLogonDomain = $autoLogonSettings.Domain`n$autoLogonUser = $autoLogonSettings.Username" | Write-Host -ForegroundColor Gray
        }
        if ($autoLogonSettings -and $autoLogonSettings.Password) {
            Set-ItemProperty -Path $winlogonPath -Name DefaultPassword -Value $autoLogonSettings.Password -Type String -Force
            "Password set for AutoLogon user: $($autoLogonSettings.Password)" | Write-Host -ForegroundColor Gray
        }
        if ($autoLogonSettings -and $autoLogonSettings.Domain) {
            Set-ItemProperty -Path $winlogonPath -Name DefaultDomainName -Value $autoLogonSettings.Domain -Type String -Force
        } else {
            Remove-ItemProperty -Path $winlogonPath -Name DefaultDomainName -ErrorAction SilentlyContinue
        }
        Write-Host "AutoLogon set for user: $($autoLogonSettings.Username)" -ForegroundColor Green

        # Schedule reboot then exit 0.
        # exit 0 called inside a script invoked with & terminates the entire
        # powershell.exe host process immediately - this is intentional.
        # exit 3010 (standard "reboot required" code) signals install2026.ps1 to skip
        # end-of-deployment cleanup.  install2026.ps1 calls this script via pwsh.exe -File
        # so exit here terminates the child pwsh.exe process; $LASTEXITCODE in the
        # parent powershell.exe is set to 3010.
        Write-Host "System will restart in 5 seconds..." -ForegroundColor Red
        read-host "Press Enter to reboot..."
        shutdown.exe /r /t 10 /c "Deployment step requires restart"
        exit 3010
    }
    
    # Check if this is an AutoLogon configuration change
    if ($stepSection.Type -eq "AutoLogon") {
        Write-Host "Configuring new AutoLogon credentials..." -ForegroundColor Yellow

        # Look up credentials from CustomSettings.json using the step reference as the key
        $autoLogonConfig = $customSettings.$stepReference
        if (-not $autoLogonConfig) {
            Write-Warning "AutoLogon section '$stepReference' not found in CustomSettings.json - skipping"
            continue
        }

        # Parse Domain\Username or UPN format
        $fullUsername = $autoLogonConfig.Username
        $autoLogonPassword = $autoLogonConfig.Password

        if ($fullUsername -match '^(.+)\\(.+)$') {
            $autoLogonDomain = $Matches[1]
            $autoLogonUser   = $Matches[2]
        } elseif ($fullUsername -match '^(.+)@(.+)$') {
            $autoLogonUser   = $Matches[1]
            $autoLogonDomain = $Matches[2]
        } else {
            $autoLogonDomain = '.'
            $autoLogonUser   = $fullUsername
        }

        Write-Host "  Domain  : $autoLogonDomain" -ForegroundColor Gray
        Write-Host "  Username: $autoLogonUser"   -ForegroundColor Gray

        # Write directly to the Winlogon registry - this is the authoritative write.
        # The Reboot step that follows will call exit 0 (killing the process), so we
        # cannot rely on any in-memory state surviving. The registry IS the state.
        $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $winlogonPath -Name AutoAdminLogon    -Value '1'              -Type String -Force
        Set-ItemProperty -Path $winlogonPath -Name DefaultUserName   -Value $autoLogonUser   -Type String -Force
        Set-ItemProperty -Path $winlogonPath -Name DefaultPassword   -Value $autoLogonPassword -Type String -Force
        if ($autoLogonDomain -and $autoLogonDomain -ne '.') {
            Set-ItemProperty -Path $winlogonPath -Name DefaultDomainName -Value $autoLogonDomain -Type String -Force
        } else {
            Remove-ItemProperty -Path $winlogonPath -Name DefaultDomainName -ErrorAction SilentlyContinue
        }
        Write-Host "AutoLogon registry written: $autoLogonDomain\$autoLogonUser" -ForegroundColor Green

        # Also update settings.json and $autoLogonSettings so a subsequent Reboot step
        # in the same run uses the correct credentials (belt and braces).
        if (Test-Path $settingsPath) {
            $s = Get-Content $settingsPath -Raw | ConvertFrom-Json
            $s.AutoLogon.Domain   = $autoLogonDomain
            $s.AutoLogon.Username = $autoLogonUser
            $s.AutoLogon.Password = $autoLogonPassword
            $s | ConvertTo-Json -Depth 3 | Set-Content $settingsPath -Encoding UTF8
            $autoLogonSettings = $s.AutoLogon
        }

        # Mark step completed
        $completedSteps += $uniqueStepId
        @{ CompletedSteps = $completedSteps; LastUpdated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
            ConvertTo-Json | Set-Content -Path $progressPath -Encoding UTF8

        Write-Host "AutoLogon step completed" -ForegroundColor Green
        continue
    }
    
    $scriptPath = $stepSection.Script
    if (-not $scriptPath) {
        Write-Warning "No script path defined in section '$stepReference'"
        continue
    }
    
    # Get PowerShell version preference (default to pwsh/PowerShell 7 if not specified)
    $psVersion = $stepSection.PowerShell
    if (-not $psVersion) {
        $psVersion = "pwsh"
    }
    
    Write-Host "Script: $scriptPath" -ForegroundColor Gray
    Write-Host "PowerShell: $psVersion" -ForegroundColor Gray
    
    # Build script parameters if defined in Deployment.json
    $scriptParams = @{}
    if ($stepSection.Parameters) {
        Write-Host "Parameters:" -ForegroundColor Gray
        foreach ($paramName in $stepSection.Parameters) {
            if ($machineConfig.PSObject.Properties.Name -contains $paramName) {
                $paramValue = $machineConfig.$paramName
                $scriptParams[$paramName] = $paramValue
                Write-Host "  $paramName = $paramValue" -ForegroundColor Gray
            } else {
                Write-Warning "Parameter '$paramName' not found in machine configuration"
            }
        }
    }
    
    # Build full script path with Z: drive
    $fullScriptPath = "Z:$scriptPath"
    
    if (Test-Path $fullScriptPath) {
        try {
            Write-Host "Executing..." -ForegroundColor Yellow
            
            # Check file extension to determine execution method
            $fileExtension = [System.IO.Path]::GetExtension($fullScriptPath).ToLower()
            
            if ($fileExtension -eq ".cmd" -or $fileExtension -eq ".bat") {
                # Run with cmd.exe (no parameter support for batch files)
                cmd.exe /c $fullScriptPath
            } elseif ($psVersion -eq "powershell5") {
                # Run with Windows PowerShell 5.1
                if ($scriptParams.Count -gt 0) {
                    powershell.exe -ExecutionPolicy Bypass -File $fullScriptPath @scriptParams
                } else {
                    powershell.exe -ExecutionPolicy Bypass -File $fullScriptPath
                }
            } else {
                # Run with PowerShell 7 (default)
                if ($scriptParams.Count -gt 0) {
                    & $fullScriptPath @scriptParams
                } else {
                    & $fullScriptPath
                }
            }
            
            Write-Host "Completed successfully" -ForegroundColor Green
            
            # Add to completed steps (with group name for uniqueness)
            $completedSteps += $uniqueStepId
            $progressData = @{
                CompletedSteps = $completedSteps
                LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
            $progressData | ConvertTo-Json | Set-Content -Path $progressPath -Encoding UTF8
            
        } catch {
            Write-Error "Failed to execute: $_"
        }
    } else {
        Write-Warning "Script not found: $fullScriptPath"
    }
    }
}

Write-Host "`n=============================" -ForegroundColor Green
Write-Host "All deployment steps completed" -ForegroundColor Green

# Clean up AutoLogon and RunOnce registry entries
Write-Host "`nCleaning up deployment registry entries..." -ForegroundColor Cyan

try {
    $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    
    # Disable AutoLogon
    if (Get-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -ErrorAction SilentlyContinue) {
        Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -Value "0" -Type String
        Write-Host "- Disabled AutoAdminLogon" -ForegroundColor Gray
    }
    
    # Remove AutoLogonCount
    if (Get-ItemProperty -Path $winlogonPath -Name "AutoLogonCount" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $winlogonPath -Name "AutoLogonCount" -ErrorAction SilentlyContinue
        Write-Host "- Removed AutoLogonCount" -ForegroundColor Gray
    }
    
    # Remove DefaultPassword (if exists)
    if (Get-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
        Write-Host "- Removed DefaultPassword" -ForegroundColor Gray
    }
    
    # Remove DefaultDomainName (if exists)
    if (Get-ItemProperty -Path $winlogonPath -Name "DefaultDomainName" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $winlogonPath -Name "DefaultDomainName" -ErrorAction SilentlyContinue
        Write-Host "- Removed DefaultDomainName" -ForegroundColor Gray
    }
    
    Write-Host "Registry cleanup completed successfully" -ForegroundColor Green
} catch {
    Write-Warning "Error during registry cleanup: $_"
}

Write-Host "`n"
read-host "Installation complete. Press Enter to continue..."
