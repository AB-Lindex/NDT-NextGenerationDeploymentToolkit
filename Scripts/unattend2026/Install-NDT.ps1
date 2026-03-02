# NDT  - Next Deployment Tool for 2026 Unattended Deployment.
# This script is designed to run on the deployed machine after the initial Windows PE phase, and will execute deployment steps defined in Deployment.json based on the machine's MAC address.
# It supports executing scripts, configuring autologon, and handling reboots as part of the deployment process.

$LogPath = 'C:\temp\install-NDT.log'

function Write-Log {
    param(
        [string]$Message,
        [string]$ForegroundColor = 'White',
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $LogPath -Value "$ts [$Level] $Message"
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message -ForegroundColor $ForegroundColor }
    }
}

try { $sysIP = (Get-NetIPAddress -AddressFamily IPv4 -Type Unicast | Where-Object { $_.InterfaceAlias -notmatch 'Loopback|Tunnel' } | Select-Object -First 1 -ExpandProperty IPAddress) } catch { $sysIP = 'unknown' }
Write-Log 'Install-NDT.ps1 started' -ForegroundColor Cyan
Write-Log '-----------------------------------' -ForegroundColor Cyan
Write-Log "Hostname : $env:COMPUTERNAME"
Write-Log "User     : $(whoami)"
Write-Log "Domain   : $env:USERDOMAIN"
Write-Log "PS Ver   : $($PSVersionTable.PSVersion)"
Write-Log "IP       : $sysIP"
Write-Log '-----------------------------------' -ForegroundColor Cyan

# Get MAC address
$macAddress = & "Z:\Scripts\unattend2026\Get-MACAddress.ps1"

# Load CustomSettings.json
$customSettingsPath = "Z:\Control\CustomSettings.json"
$customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json

# Load DeploymentGroups.json (groups → ordered steps with References)
$deploymentGroupsPath = "Z:\Control\DeploymentGroups.json"
$deploymentGroups = Get-Content -Path $deploymentGroupsPath -Raw | ConvertFrom-Json

# Load Deployment.json (actions → scripts / Reboot / AutoLogon entries)
$deploymentPath = "Z:\Control\Deployment.json"
$deployment = Get-Content -Path $deploymentPath -Raw | ConvertFrom-Json

# Get machine configuration by MAC address
$machineConfig = $customSettings.$macAddress
if (-not $machineConfig) {
    Write-Log "No configuration found for MAC address: $macAddress" -Level ERROR
    exit 1
}

# Check if DeploymentSteps reference exists
if (-not $machineConfig.DeploymentSteps) {
    Write-Log 'No deployment steps defined for this machine' -ForegroundColor Yellow
    exit 0
}

# Get the deployment group reference(s) - can be string or array
$deploymentGroupRefs = $machineConfig.DeploymentSteps
if ($deploymentGroupRefs -is [string]) {
    $deploymentGroupRefs = @($deploymentGroupRefs)
}

Write-Log "Deployment groups: $($deploymentGroupRefs -join ', ')" -ForegroundColor Cyan

# Load settings.json for autologon credentials
$settingsPath = "C:\temp\settings.json"
if (Test-Path $settingsPath) {
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
    $autoLogonSettings = $settings.AutoLogon
} else {
    Write-Log "Settings file not found: $settingsPath" -Level WARN
    $autoLogonSettings = $null
}

# Load or create install progress tracker
$progressPath = "C:\temp\install-steps.json"
if (Test-Path $progressPath) {
    $progress = Get-Content -Path $progressPath -Raw | ConvertFrom-Json
    $completedSteps = @($progress.CompletedSteps)
    $completedStepDetails = if ($progress.StepDetails) { @($progress.StepDetails) } else { @() }
} else {
    $completedSteps = @()
    $completedStepDetails = @()
}

Write-Log "`nExecuting Deployment Steps..." -ForegroundColor Green
Write-Log '=============================' -ForegroundColor Green

# Process each deployment group
foreach ($deploymentGroupName in $deploymentGroupRefs) {
    $deploymentGroup = $deploymentGroups.$deploymentGroupName

    if (-not $deploymentGroup) {
        Write-Log "Deployment group '$deploymentGroupName' not found in DeploymentGroups.json" -Level WARN
        continue
    }
    
    Write-Log "`nProcessing group: $deploymentGroupName" -ForegroundColor Yellow

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
        Write-Log "`n[$stepName] $description" -ForegroundColor Gray
        Write-Log 'Already completed - skipping' -ForegroundColor Gray
        continue
    }
    
    Write-Log "`n[$stepName] $description" -ForegroundColor Cyan
    
    # Get the referenced section from Deployment.json
    $stepSection = $deployment.$stepReference
    if (-not $stepSection) {
        Write-Log "Step reference '$stepReference' not found in Deployment.json" -Level WARN
        continue
    }
    
    # Check if this is a Pause action
    if ($stepSection.Type -eq 'Pause') {
        Write-Log 'Pausing deployment...' -ForegroundColor Yellow

        # Run Pause.ps1 to create the desktop shortcut
        $pauseScript = 'Z:\Applications\Pause\Pause.ps1'
        if (Test-Path $pauseScript) {
            & $pauseScript
        } else {
            Write-Log "Pause.ps1 not found at: $pauseScript" -Level WARN
        }

        # Mark this step as completed so resuming via the shortcut skips past it
        $completedSteps += $uniqueStepId
        $completedStepDetails += @{ StepId = $uniqueStepId; Application = $stepReference }
        @{ CompletedSteps = $completedSteps; StepDetails = $completedStepDetails; LastUpdated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
            ConvertTo-Json | Set-Content -Path $progressPath -Encoding UTF8

        # Exit 3011 — signals install2026.ps1 that deployment is paused (not a reboot).
        # install2026.ps1 will remove RunOnce\Deploy2026 so that rebooting while paused
        # does NOT auto-resume deployment.  The operator must double-click the desktop
        # shortcut to continue; that shortcut re-runs install2026.ps1 which re-registers
        # RunOnce and then continues from the next pending step.
        Write-Log 'Exiting with code 3011 (deployment paused - RunOnce will be removed)' -ForegroundColor Yellow
        exit 3011
    }

    # Check if this is a WindowsUpdate action
    # The WU script exits 3010 when a reboot is required, 0 when fully patched.
    # We deliberately do NOT mark the step complete on a 3010 exit so that the
    # engine re-runs Windows Update after the reboot, iterating until no more
    # patches require a restart.
    if ($stepSection.Type -eq 'WindowsUpdate') {
        $wuScript = "Z:$($stepSection.Script)"
        if (-not (Test-Path $wuScript)) {
            Write-Log "Windows Update script not found: $wuScript" -Level WARN
            continue
        }

        Write-Log 'Running Windows Update...' -ForegroundColor Yellow
        & $wuScript
        $wuExitCode = $LASTEXITCODE
        Write-Log "Windows Update script exited with code $wuExitCode"

        if ($wuExitCode -eq 3010) {
            # Reboot required — do NOT add to completedSteps so this step reruns after reboot.
            Write-Log 'Windows Update requires a reboot - initiating restart...' -ForegroundColor Yellow

            # Configure AutoLogon so deployment resumes automatically after the reboot.
            $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
            Set-ItemProperty -Path $winlogonPath -Name AutoAdminLogon -Value '1' -Type String -Force
            if ($autoLogonSettings -and $autoLogonSettings.Username) {
                Set-ItemProperty -Path $winlogonPath -Name DefaultUserName  -Value $autoLogonSettings.Username -Type String -Force
            }
            if ($autoLogonSettings -and $autoLogonSettings.Password) {
                Set-ItemProperty -Path $winlogonPath -Name DefaultPassword   -Value $autoLogonSettings.Password -Type String -Force
            }
            if ($autoLogonSettings -and $autoLogonSettings.Domain) {
                Set-ItemProperty -Path $winlogonPath -Name DefaultDomainName -Value $autoLogonSettings.Domain  -Type String -Force
            } else {
                Remove-ItemProperty -Path $winlogonPath -Name DefaultDomainName -ErrorAction SilentlyContinue
            }
            Write-Log "AutoLogon set for user: $($autoLogonSettings.Username)" -ForegroundColor Green

            Write-Log 'Shutdown initiated - system will restart in 10 seconds' -ForegroundColor Red
            shutdown.exe /r /t 10 /c "Windows Update requires restart"
            Write-Log 'Exiting with code 3010 (WU reboot pending)' -ForegroundColor Red
            exit 3010
        } else {
            # Exit 0 (or anything other than 3010): no reboot needed, patching complete.
            Write-Log 'Windows Update complete - no further reboots required' -ForegroundColor Green
            $completedSteps += $uniqueStepId
            $completedStepDetails += @{ StepId = $uniqueStepId; Application = $stepReference }
            @{ CompletedSteps = $completedSteps; StepDetails = $completedStepDetails; LastUpdated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
                ConvertTo-Json | Set-Content -Path $progressPath -Encoding UTF8
            continue
        }
    }

    # Check if this is a reboot action
    if ($stepSection.Type -eq "Reboot") {
        Write-Log 'Rebooting system...' -ForegroundColor Yellow
        
        # Mark this step as completed before rebooting
        $completedSteps += $uniqueStepId
        $completedStepDetails += @{ StepId = $uniqueStepId; Application = $stepReference }
        $progressData = @{
            CompletedSteps = $completedSteps
            StepDetails    = $completedStepDetails
            LastUpdated    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
        $progressData | ConvertTo-Json | Set-Content -Path $progressPath -Encoding UTF8

        # Write AutoLogon credentials directly to the Winlogon registry.
        # RunOnce\Deploy2026 was already registered by install2026.ps1 at startup.
        $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        Set-ItemProperty -Path $winlogonPath -Name AutoAdminLogon -Value '1' -Type String -Force
        if ($autoLogonSettings -and $autoLogonSettings.Username) {
            Set-ItemProperty -Path $winlogonPath -Name DefaultUserName -Value $autoLogonSettings.Username -Type String -Force
        }
        if ($autoLogonSettings -and $autoLogonSettings.Password) {
            Set-ItemProperty -Path $winlogonPath -Name DefaultPassword -Value $autoLogonSettings.Password -Type String -Force
        }
        if ($autoLogonSettings -and $autoLogonSettings.Domain) {
            Set-ItemProperty -Path $winlogonPath -Name DefaultDomainName -Value $autoLogonSettings.Domain -Type String -Force
        } else {
            Remove-ItemProperty -Path $winlogonPath -Name DefaultDomainName -ErrorAction SilentlyContinue
        }
        Write-Log "AutoLogon set for user: $($autoLogonSettings.Username)" -ForegroundColor Green

        # Schedule reboot then exit 0.
        # exit 0 called inside a script invoked with & terminates the entire
        # powershell.exe host process immediately - this is intentional.
        # exit 3010 (standard "reboot required" code) signals install2026.ps1 to skip
        # end-of-deployment cleanup.  install2026.ps1 calls this script via pwsh.exe -File
        # so exit here terminates the child pwsh.exe process; $LASTEXITCODE in the
        # parent powershell.exe is set to 3010.
        Write-Log 'Shutdown initiated - system will restart in 120 seconds' -ForegroundColor Red
        shutdown.exe /r /t 10 /c "Deployment step requires restart"
        Write-Log 'Exiting with code 3010 (reboot pending)' -ForegroundColor Red
        exit 3010
    }
    
    # Check if this is an AutoLogon configuration change
    if ($stepSection.Type -eq "AutoLogon") {
        Write-Log 'Configuring new AutoLogon credentials...' -ForegroundColor Yellow

        # Look up credentials from CustomSettings.json using the step reference as the key
        $autoLogonConfig = $customSettings.$stepReference
        if (-not $autoLogonConfig) {
            Write-Log "AutoLogon section '$stepReference' not found in CustomSettings.json - skipping" -Level WARN
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

        Write-Log "  Domain  : $autoLogonDomain" -ForegroundColor Gray
        Write-Log "  Username: $autoLogonUser" -ForegroundColor Gray

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
        Write-Log "AutoLogon registry written: $autoLogonDomain\$autoLogonUser" -ForegroundColor Green

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
        $completedStepDetails += @{ StepId = $uniqueStepId; Application = $stepReference }
        @{ CompletedSteps = $completedSteps; StepDetails = $completedStepDetails; LastUpdated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
            ConvertTo-Json | Set-Content -Path $progressPath -Encoding UTF8

        Write-Log 'AutoLogon step completed' -ForegroundColor Green
        continue
    }
    
    $scriptPath = $stepSection.Script
    if (-not $scriptPath) {
        Write-Log "No script path defined in section '$stepReference'" -Level WARN
        continue
    }
    
    # Get PowerShell version preference (default to pwsh/PowerShell 7 if not specified)
    $psVersion = $stepSection.PowerShell
    if (-not $psVersion) {
        $psVersion = "pwsh"
    }
    
    Write-Log "Script: $scriptPath" -ForegroundColor Gray
    Write-Log "PowerShell: $psVersion" -ForegroundColor Gray
    
    # Build script parameters if defined in Deployment.json
    $scriptParams = @{}
    if ($stepSection.Parameters) {
        Write-Log 'Parameters:' -ForegroundColor Gray
        foreach ($paramName in $stepSection.Parameters) {
            if ($machineConfig.PSObject.Properties.Name -contains $paramName) {
                $paramValue = $machineConfig.$paramName
                $scriptParams[$paramName] = $paramValue
                Write-Log "  $paramName = $paramValue" -ForegroundColor Gray
            } else {
                Write-Log "Parameter '$paramName' not found in machine configuration" -Level WARN
            }
        }
    }
    
    # Build full script path with Z: drive
    $fullScriptPath = "Z:$scriptPath"
    
    if (Test-Path $fullScriptPath) {
        try {
            Write-Log 'Executing...' -ForegroundColor Yellow
            
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
            
            Write-Log 'Completed successfully' -ForegroundColor Green
            
            # Add to completed steps (with group name for uniqueness)
            $completedSteps += $uniqueStepId
            $completedStepDetails += @{ StepId = $uniqueStepId; Application = $stepReference }
            $progressData = @{
                CompletedSteps = $completedSteps
                StepDetails    = $completedStepDetails
                LastUpdated    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
            $progressData | ConvertTo-Json | Set-Content -Path $progressPath -Encoding UTF8
            
        } catch {
            Write-Log "Failed to execute: $_" -Level ERROR
        }
    } else {
        Write-Log "Script not found: $fullScriptPath" -Level WARN
    }
    }
}

Write-Log "`n=============================" -ForegroundColor Green
Write-Log 'All deployment steps completed' -ForegroundColor Green

# Clean up AutoLogon and RunOnce registry entries
Write-Log "`nCleaning up deployment registry entries..." -ForegroundColor Cyan

try {
    $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    
    # Disable AutoLogon
    if (Get-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -ErrorAction SilentlyContinue) {
        Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -Value "0" -Type String
        Write-Log '- Disabled AutoAdminLogon' -ForegroundColor Gray
    }
    
    # Remove AutoLogonCount
    if (Get-ItemProperty -Path $winlogonPath -Name "AutoLogonCount" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $winlogonPath -Name "AutoLogonCount" -ErrorAction SilentlyContinue
        Write-Log '- Removed AutoLogonCount' -ForegroundColor Gray
    }
    
    # Remove DefaultPassword (if exists)
    if (Get-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
        Write-Log '- Removed DefaultPassword' -ForegroundColor Gray
    }
    
    # Remove DefaultDomainName (if exists)
    if (Get-ItemProperty -Path $winlogonPath -Name "DefaultDomainName" -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $winlogonPath -Name "DefaultDomainName" -ErrorAction SilentlyContinue
        Write-Log '- Removed DefaultDomainName' -ForegroundColor Gray
    }
    
    Write-Log 'Registry cleanup completed successfully' -ForegroundColor Green
} catch {
    Write-Log "Error during registry cleanup: $_" -Level WARN
}

Write-Log 'Installation complete' -ForegroundColor Green
# read-host "Installation complete. Press Enter to continue..."
