#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Cleanup before Sysprep for Windows 11 and Windows Server 2025.
.DESCRIPTION
    Runs DISM image cleanup and CleanMgr to reduce image size before Sysprep.
    Removes the SoftwareDistribution cache and resets the component store baseline.
.NOTES
    Version : 3.0 - Feb 20 2026
    Authors : Mikael Nystrom & Johan Arwidmark (original VBScript)
              Converted to PowerShell for Windows 11 / Server 2025
    This script is provided "AS IS" with no warranties, confers no rights and
    is not supported by the authors.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region --- Logging -------------------------------------------------------

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARNING','ERROR')]
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "[$ts][$Level] $Message"
}

#endregion

#region --- Helpers -------------------------------------------------------

function Invoke-Executable {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $argString = $ArgumentList -join ' '
    Write-Log "Running: $FilePath $argString"
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
                       -Wait -PassThru -NoNewWindow
    Write-Log "Exit code: $($p.ExitCode)"
    return $p.ExitCode
}

function Test-ExitCode {
    param([int]$ExitCode, [string]$TaskName)
    if ($ExitCode -notin 0, 3010) {
        Write-Log "$TaskName failed (exit code $ExitCode)." 'WARNING'
    }
}

#endregion

#region --- Tasks ---------------------------------------------------------

function Set-CleanMgrRegistryValues {
    Write-Log 'Adding registry values for CleanMgr (StateFlags5432).'

    # Mark VM Guest OSD as done (used by some deployment toolkits)
    $vmGuestPath = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest'
    if (-not (Test-Path $vmGuestPath)) {
        New-Item -Path $vmGuestPath -Force | Out-Null
    }
    Set-ItemProperty -Path $vmGuestPath -Name 'OSD' -Value 'Done' -Type String

    $cacheRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'

    $caches = @(
        'Active Setup Temp Folders',
        'Content Indexer Cleaner',
        'Delivery Optimization Files',
        'Device Driver Packages',
        'Downloaded Program Files',
        'Internet Cache Files',
        'Memory Dump Files',
        'Offline Pages Files',
        'Old ChkDsk Files',
        'Previous Installations',
        'Recycle Bin',
        'RetailDemo Offline Content',
        'Service Pack Cleanup',
        'Setup Log Files',
        'System error memory dump files',
        'System error minidump files',
        'Temporary Files',
        'Temporary Setup Files',
        'Temporary Sync Files',
        'Thumbnail Cache',
        'Update Cleanup',
        'Upgrade Discarded Files',
        'Windows Defender',
        'Windows Error Reporting Archive Files',
        'Windows Error Reporting Queue Files',
        'Windows Error Reporting System Archive Files',
        'Windows Error Reporting System Queue Files',
        'Windows ESD installation files',
        'Windows Upgrade Log Files'
    )

    foreach ($cache in $caches) {
        $path = Join-Path $cacheRoot $cache
        if (Test-Path $path) {
            Set-ItemProperty -Path $path -Name 'StateFlags5432' -Value 2 `
                             -Type DWord -ErrorAction SilentlyContinue
        }
    }
    Write-Log 'CleanMgr registry values set.'
}

function Invoke-DismRestoreHealth {
    Write-Log 'Running DISM /online /Cleanup-Image /RestoreHealth.'
    $rc = Invoke-Executable -FilePath 'DISM.exe' `
            -ArgumentList '/online', '/Cleanup-Image', '/RestoreHealth'
    Test-ExitCode -ExitCode $rc -TaskName 'DISM RestoreHealth'
}

function Invoke-DismResetBase {
    Write-Log 'Running DISM /online /Cleanup-Image /StartComponentCleanup /ResetBase.'
    $rc = Invoke-Executable -FilePath 'DISM.exe' `
            -ArgumentList '/online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase'
    Test-ExitCode -ExitCode $rc -TaskName 'DISM ResetBase'
}

function Invoke-CleanMgr {
    Write-Log 'Running CleanMgr.exe /sagerun:5432.'
    $rc = Invoke-Executable -FilePath 'CleanMgr.exe' -ArgumentList '/sagerun:5432'
    Test-ExitCode -ExitCode $rc -TaskName 'CleanMgr'
}

function Remove-SoftwareDistribution {
    Write-Log 'Cleaning up the SoftwareDistribution folder.'

    Stop-Service  -Name 'wuauserv' -Force -ErrorAction SilentlyContinue
    Write-Log 'Windows Update service stopped.'

    $sdPath = 'C:\Windows\SoftwareDistribution'
    if (Test-Path $sdPath) {
        Remove-Item -Path $sdPath -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log 'SoftwareDistribution folder removed.'
    } else {
        Write-Log 'SoftwareDistribution folder not found, skipping.'
    }

    Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
    Write-Log 'Windows Update service started.'
}

#endregion

#region --- Main ----------------------------------------------------------

$ScriptName = 'Action-CleanupBeforeSysprep'
Write-Log "$ScriptName`: Starting."

$os          = Get-CimInstance -ClassName Win32_OperatingSystem
$buildNumber = [int]$os.BuildNumber
$productType = $os.ProductType   # 1 = Workstation, 2 = Domain Controller, 3 = Member Server
$isServer    = $productType -in 2, 3
$isClient    = $productType -eq 1

Write-Log "OS: $($os.Caption)  Build: $buildNumber  ProductType: $productType"

# Minimum supported builds
# Windows 11      : build 22000+
# Server 2019     : build 17763+
# Server 2022     : build 20348+
# Server 2025     : build 26100+
if ($isClient -and $buildNumber -lt 22000) {
    Write-Log "Unsupported client OS (build $buildNumber). This script requires Windows 11." 'ERROR'
    exit 1
}

if ($isServer -and $buildNumber -lt 17763) {
    Write-Log "Unsupported server OS (build $buildNumber). This script requires Windows Server 2019 or later (build 17763+)." 'ERROR'
    exit 1
}

if ($isClient) {
    Write-Log "$ScriptName`: Running on Windows 11."

    Set-CleanMgrRegistryValues
    Invoke-DismRestoreHealth
    Invoke-CleanMgr
    Remove-SoftwareDistribution
    Invoke-DismResetBase
}
elseif ($isServer) {
    Write-Log "$ScriptName`: Running on Windows Server 2019 / 2022 / 2025 (build $buildNumber)."

    Invoke-DismRestoreHealth
    Remove-SoftwareDistribution
    Invoke-DismResetBase
}
else {
    Write-Log "Unknown OS type (ProductType: $productType)." 'ERROR'
    exit 1
}

Write-Log "$ScriptName`: Finished."

#endregion
