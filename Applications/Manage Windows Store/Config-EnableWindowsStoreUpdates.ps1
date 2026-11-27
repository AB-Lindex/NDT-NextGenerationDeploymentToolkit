# Enables Microsoft Store auto-updates and consumer experiences in the OFFLINE image (run from WinPE after the image is applied).
# PS 5.1 compatible. Port of Config-EnableWindowsStoreUpdates.wsf.
param(
    [string]$SystemDrive = 'C:'
)

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'ERROR')][string]$Level = 'INFO')
    $color = if ($Level -eq 'ERROR') { 'Red' } else { 'Gray' }
    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

function Update-OfflineRegistry {
    param([string]$SystemDrive)

    Write-Log 'Load the offline registry file'

    $found = $false
    foreach ($dir in Get-ChildItem -Path "$SystemDrive\" -Directory -Force -ErrorAction SilentlyContinue) {
        $hive = Join-Path $dir.FullName 'system32\config\software'
        if (Test-Path -LiteralPath $hive -PathType Leaf) {
            Write-Log "Trying to load registry file $hive"
            & reg.exe load 'HKLM\NewOS' $hive | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $found = $true
                break
            }
        }
    }
    if (-not $found) {
        Write-Log 'Unable to find the new OS registry file; Windows Store settings cannot be updated.' -Level ERROR
        return
    }

    try {
        Write-Log 'Enable Windows Store Updates'
        # 2 = always off, 4 = always on
        & reg.exe add 'HKLM\NewOS\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate' /v AutoDownload /t REG_DWORD /d 4 /f | Out-Null

        Write-Log 'Enable Consumer Experience'
        # 1 = Off (disabled), 0 = On (enabled)
        & reg.exe add 'HKLM\NewOS\Policies\Microsoft\Windows\CloudContent' /v DisableWindowsConsumerFeatures /t REG_DWORD /d 0 /f | Out-Null
    }
    finally {
        Write-Log 'Unload the offline registry file'
        Start-Sleep -Seconds 3
        & reg.exe unload 'HKLM\NewOS' | Out-Null
    }
}

Write-Log "Current OS drive letter is $SystemDrive"
Write-Log 'About to configure offline registry settings'
Update-OfflineRegistry -SystemDrive $SystemDrive
exit 0
