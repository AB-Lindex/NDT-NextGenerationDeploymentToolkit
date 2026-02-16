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
        
        # Configure RunOnce registry entry to continue deployment after reboot
        Write-Host "Configuring post-reboot deployment continuation..." -ForegroundColor Cyan
        $runOncePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
        $runOnceCommand = "pwsh.exe -executionpolicy bypass -File c:\temp\install2026.ps1"
        Set-ItemProperty -Path $runOncePath -Name "ContinueDeployment" -Value $runOnceCommand -Type String
        
        # Ensure AutoLogon is still configured (in case it was cleared)
        $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
        Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -Value "1" -Type String
        Set-ItemProperty -Path $winlogonPath -Name "DefaultUserName" -Value "Administrator" -Type String
        
        # Optionally set a high LogonCount to ensure multiple reboots are handled
        if (-not (Get-ItemProperty -Path $winlogonPath -Name "AutoLogonCount" -ErrorAction SilentlyContinue)) {
            Set-ItemProperty -Path $winlogonPath -Name "AutoLogonCount" -Value 999 -Type DWord
        }
        
        Write-Host "Post-reboot continuation configured successfully" -ForegroundColor Green
        
        # Initiate reboot with a 10 second delay
        Write-Host "System will restart in 10 seconds..." -ForegroundColor Red
        Start-Sleep -Seconds 2
        shutdown.exe /r /t 10 /c "Deployment step requires restart"
        exit 0
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
    
    # Clean up RunOnce entries
    $runOncePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    if (Get-ItemProperty -Path $runOncePath -Name "ContinueDeployment" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $runOncePath -Name "ContinueDeployment" -ErrorAction SilentlyContinue
        Write-Host "- Removed RunOnce ContinueDeployment entry" -ForegroundColor Gray
    }
    
    Write-Host "Registry cleanup completed successfully" -ForegroundColor Green
} catch {
    Write-Warning "Error during registry cleanup: $_"
}

Write-Host "`n"
read-host "Installation complete. Press Enter to continue..."
