# NDT  - Next Deployment Tool for 2026 Unattended Deployment.
# This script runs in Windows PE after PXE boot (or ISO boot), and performs the following steps:
# 1. Maps the deployment share using credentials from settings file
# 2. Checks for capture mode (if DeployCapture.flag exists on any drive) and runs capture script if in capture mode
# 3. Partitions and formats the disk using diskpart script
# 4. Validates MAC address against CustomSettings.json and retrieves machine configuration
# 5. Applies the OS image to C: drive using Dism
# 6. Copies install2026.ps1 to C:\ and prepares unattend.xml based on machine configuration
# 7. Applies unattend.xml to the offline image
# Check if this is a capture operation (reference image creation)
# Must be checked BEFORE diskpart to avoid wiping the reference system

# ------------------------------------------------------------------
# Logging. C:\temp does not exist yet (the disk is not partitioned), so we start
# logging to the WinPE RAM drive (X:) and relocate the log onto C:\temp once the
# disk is partitioned (see "Log relocated" below). This mirrors the Write-Log used
# by install2026.ps1 / Install-NDT.ps1 so all three phases log the same way.
# ------------------------------------------------------------------
$script:LogPath = 'X:\install.log'
function Write-Log {
    param(
        [string]$Message,
        [string]$ForegroundColor = 'White',
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ($script:LogPath) {
        try { Add-Content -Path $script:LogPath -Value "$ts [$Level] $Message" -ErrorAction Stop } catch { }
    }
    switch ($Level) {
        'WARN'  { Write-Warning $Message }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message -ForegroundColor $ForegroundColor }
    }
}

try { $sysIP = (Get-NetIPAddress -AddressFamily IPv4 -Type Unicast | Where-Object { $_.InterfaceAlias -notmatch 'Loopback|Tunnel' } | Select-Object -First 1 -ExpandProperty IPAddress) } catch { $sysIP = 'unknown' }
Write-Log 'install.ps1 (WinPE) started' -ForegroundColor Cyan
Write-Log '-----------------------------------' -ForegroundColor Cyan
Write-Log "Hostname : $env:COMPUTERNAME"
Write-Log "User     : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "PS Ver   : $($PSVersionTable.PSVersion)"
Write-Log "IP       : $sysIP"
Write-Log "Log file : $script:LogPath (WinPE RAM drive - relocated to C:\temp after partitioning)"
Write-Log '-----------------------------------' -ForegroundColor Cyan

# ------------------------------------------------------------------
# WinPE progress reporting to the NDT Monitor (best-effort, never blocks).
# $script:MonitorUrl / PEMac / PEComputername are populated after the MAC is
# validated below. Until then these calls are no-ops.
# ------------------------------------------------------------------
$script:MonitorUrl     = $null
$script:PEMac          = $null
$script:PEComputername = $null
function Send-PEProgress {
    param(
        [string]$Description,
        [int]$Percent = 0
    )
    if (-not $script:MonitorUrl) { return }
    $body = @{
        Computername = $script:PEComputername
        MAC          = $script:PEMac
        Phase        = 'WinPE'
        Status       = 'WinPE'
        Description  = $Description
        Group        = 'WinPE'
        StepId       = ''
        Completed    = 0
        Total        = 0
        Percent      = $Percent
        Timestamp    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    } | ConvertTo-Json -Compress
    try {
        # Bypass TLS cert validation for the internal monitoring endpoint (best-effort, PS5.1).
        # The monitor uses an internal-CA cert that WinPE does not trust by default.
        if ($script:MonitorUrl -like 'https://*') {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        }
        Invoke-RestMethod -Uri "$script:MonitorUrl/progress" -Method Post -Body $body `
            -ContentType 'application/json' -TimeoutSec 5 -ErrorAction Stop | Out-Null
    } catch {
        # Non-critical - never block deployment on a monitor outage.
    }
}

Write-Log "Checking for capture mode..." -ForegroundColor Cyan
$captureMode = $false
$captureConfig = $null
$referenceDrive = $null

$volumes = Get-Volume | Where-Object {$_.DriveLetter -and $_.FileSystemLabel -ne "System Reserved"}
foreach ($vol in $volumes) {
    $flagFile = "$($vol.DriveLetter):\DeployCapture.flag"
    if (Test-Path $flagFile) {
        Write-Log "Capture mode detected on drive $($vol.DriveLetter):" -ForegroundColor Yellow
        $captureConfig = Get-Content $flagFile -Raw | ConvertFrom-Json
        $referenceDrive = $vol.DriveLetter
        $captureMode = $true
        break
    }
}

if ($captureMode) {
    Write-Log "Running in CAPTURE mode - creating reference image" -ForegroundColor Green
    Write-Log "Reference Drive: $referenceDrive" -ForegroundColor Cyan
    Write-Log "Image Name: $($captureConfig.ImageName)" -ForegroundColor Cyan
    Write-Log "Output Path: $($captureConfig.OutputPath)" -ForegroundColor Cyan
    Write-Log ""

    $captureScriptPath = "Z:\Applications\CreateReference\Capture-ReferenceImage.ps1"

    if (Test-Path $captureScriptPath) {
        # Remove the capture flag before capturing so it is not baked into the WIM.
        # If left in place, any future deployment using this image would incorrectly
        # enter capture mode again.
        Write-Log "Removing DeployCapture.flag from reference drive..." -ForegroundColor Yellow
        Remove-Item "${referenceDrive}:\DeployCapture.flag" -Force -ErrorAction SilentlyContinue

        # Clean C:\temp on the reference drive so deployment logs are not appended
        # when the WIM is applied to a new machine.
        $tempPath = "${referenceDrive}:\temp"
        if (Test-Path $tempPath) {
            Write-Log "Cleaning $tempPath before capture..." -ForegroundColor Yellow
            Remove-Item -Path "$tempPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Log "Executing capture script..." -ForegroundColor Green
        & $captureScriptPath -ImageName $captureConfig.ImageName -OutputPath $captureConfig.OutputPath -TargetDrive "${referenceDrive}:"
        Write-Log "Capture complete!" -ForegroundColor Green
    } else {
        Write-Log "ERROR: Capture script not found at: $captureScriptPath" -Level ERROR
    }
    exit 0
}

Write-Log "Running normal deployment..." -ForegroundColor Cyan
# read-host "Press Enter to start deployment..."

# Detect firmware type: 1 = BIOS (Gen 1), 2 = UEFI (Gen 2)
# Done early so we can report it, but disk is NOT touched until all validations pass.
$firmwareType = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "PEFirmwareType" -ErrorAction SilentlyContinue).PEFirmwareType
$isUEFI = ($firmwareType -eq 2)
Write-Log "Firmware type: $(if ($isUEFI) { 'UEFI (Gen 2)' } else { 'BIOS (Gen 1)' })" -ForegroundColor Cyan

# Detect hardware (physical/virtual, vendor, model) and show it alongside the other
# pre-flight info. Best-effort - never blocks deployment.
$hardware = & "Z:\Scripts\Unattend2026\Get-Hardware.ps1"
if ($hardware) {
    Write-Log "Hardware  : $(if ($hardware.IsVM) { "Virtual ($($hardware.Platform))" } else { 'Physical' })" -ForegroundColor Cyan
    Write-Log "  Vendor  : $($hardware.Make)" -ForegroundColor Gray
    Write-Log "  Model   : $($hardware.Model)" -ForegroundColor Gray
    Write-Log "  Serial  : $($hardware.SerialNumber)" -ForegroundColor Gray
    Write-Log "  BIOS    : $($hardware.BiosVersion)" -ForegroundColor Gray
    Write-Log "  Detected: $($hardware.DetectionMethod)$(if ($hardware.CpuidHypervisor) { " (CPUID: $($hardware.CpuidHypervisor))" })" -ForegroundColor Gray
}

# ------------------------------------------------------------------
# STEP 1 - Validate MAC address
# ------------------------------------------------------------------
$macAddress = & "Z:\Scripts\Unattend2026\Get-MACAddress.ps1"

$customSettingsPath = "Z:\Control\CustomSettings.json"
$customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json

while (-not $customSettings.$macAddress) {
    Write-Log "ERROR: MAC address '$macAddress' not found in CustomSettings.json" -Level ERROR
    Write-Log "Available MAC addresses in configuration:" -ForegroundColor Yellow
    $customSettings.PSObject.Properties | Where-Object { $_.Name -match '^[0-9A-F:]+$' } | ForEach-Object {
        Write-Log "  $($_.Name)" -ForegroundColor Gray
    }
    Read-Host "Press Enter to retry"
    $customSettings = Get-Content -Path $customSettingsPath -Raw | ConvertFrom-Json
}

$machineConfig = $customSettings.$macAddress

# ------------------------------------------------------------------
# SAFETY CHECK - Install:NO prevents accidental disk wipe
# ------------------------------------------------------------------
if ($machineConfig.Install -eq "NO") {
    Write-Log "Install is set to NO for MAC: $macAddress ($($machineConfig.Computername))" -ForegroundColor Yellow
    Write-Log "Deployment is disabled for this machine. Rebooting in 10 seconds..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
    wpeutil Reboot
    exit 0
}

# ------------------------------------------------------------------
# Resolve NDT Monitor URL for WinPE-phase progress reporting (best-effort).
# Uses the machine's deploy section (or default 'Deploy') from Sections.json.
# ------------------------------------------------------------------
$script:PEMac          = $macAddress
$script:PEComputername = $machineConfig.Computername
try {
    $peSections = Get-Content 'Z:\Control\Sections.json' -Raw | ConvertFrom-Json
    $peDeploySection = if ($machineConfig.Deploy -and $machineConfig.Deploy -notmatch '^(yes|no)$') { $machineConfig.Deploy } else { 'Deploy' }
    if ($peSections.$peDeploySection -and $peSections.$peDeploySection.MonitorUrl) {
        $script:MonitorUrl = $peSections.$peDeploySection.MonitorUrl.TrimEnd('/')
        Write-Log "NDT Monitor: $script:MonitorUrl" -ForegroundColor Gray
    }
} catch {
    # Sections.json missing MonitorUrl or unreadable - PE reporting stays disabled.
}

# ------------------------------------------------------------------
# STEP 2 - Resolve and validate OS / WIM
# ------------------------------------------------------------------
$osInfo = & "Z:\Scripts\Unattend2026\Get-OS.ps1" -MACAddress $macAddress

if (-not $osInfo -or -not $osInfo.Path -or -not $osInfo.Index) {
    Write-Log "ERROR: Could not resolve OS for MAC address: $macAddress" -Level ERROR
    Write-Log "Ensure an OS key is set in the MAC block or a referenced section, and exists in OS.json" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

$wimPath  = $osInfo.Path
$wimIndex = $osInfo.Index
$osKey    = $osInfo.OsKey

Write-Log "Configuration validated for MAC: $macAddress" -ForegroundColor Green
Write-Log "  OS          : $osKey" -ForegroundColor Cyan
Write-Log "  Computername: $($machineConfig.Computername)" -ForegroundColor Cyan

if (-not (Test-Path $wimPath)) {
    Write-Log "ERROR: WIM file not found at: $wimPath" -Level ERROR
    Write-Log "  OS key   : $osKey" -ForegroundColor Yellow
    Write-Log "  Path     : $wimPath" -ForegroundColor Yellow
    Write-Log "  Index    : $wimIndex" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Log "  WIM Path : $wimPath" -ForegroundColor Cyan
Write-Log "  WIM Index: $wimIndex" -ForegroundColor Cyan

Send-PEProgress -Description 'Configuration validated' -Percent 5

# ------------------------------------------------------------------
# STEP 3 - All validations passed - safe to wipe and partition disk
# ------------------------------------------------------------------
Write-Log "All pre-flight checks passed - partitioning disk 0..." -ForegroundColor Green
Send-PEProgress -Description 'Partitioning disk' -Percent 10

if ($isUEFI) {
    $diskpartScript = @"
select disk 0
clean
convert gpt
create partition efi size=100
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
format quick fs=ntfs label="Windows"
assign letter=C
exit
"@
} else {
    # Gen 1 / BIOS: MBR with single active primary partition
    $diskpartScript = @"
select disk 0
clean
convert mbr
create partition primary
format quick fs=ntfs label="Windows"
assign letter=C
active
exit
"@
}

$diskpartScript | diskpart

# Disk is now partitioned - C: exists. Relocate the WinPE log off the X: RAM drive
# onto C:\temp so it survives the reboot into Windows and lands on the deployed
# machine alongside install2026.log / install-NDT.log.
try {
    $null = New-Item -ItemType Directory -Path 'C:\temp' -Force
    $newLogPath = 'C:\temp\install.log'
    if (Test-Path $script:LogPath) {
        Copy-Item -Path $script:LogPath -Destination $newLogPath -Force -ErrorAction SilentlyContinue
    }
    $script:LogPath = $newLogPath
    Write-Log "Log relocated to $newLogPath (C: partition available)" -ForegroundColor Gray
} catch {
    Write-Log "Could not relocate log to C:\temp - continuing on $script:LogPath" -Level WARN
}

<# Storage-module equivalent - kept for reference only; we stay on diskpart (above).
   The cmdlets work in WinPE but are less forgiving than diskpart, so if you ever
   switch, mind these points learned the hard way:
     - Assign the drive letter directly on New-Partition (-DriveLetter S / C) instead
       of -AssignDriveLetter + Set-Partition. Reassigning to C: fails if C: is taken.
     - Format-Volume is the fragile step in WinPE (races the storage stack right after
       New-Partition). Add a short retry if it throws.
     - MBR/BIOS needs Set-Partition -IsActive $true to replace diskpart's "active".
     - Clear-Disk -RemoveOEM also wipes recovery/OEM partitions (diskpart "clean" does).

if ($isUEFI) {
    Clear-Disk -Number 0 -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    Initialize-Disk -Number 0 -PartitionStyle GPT

    $efi = New-Partition -DiskNumber 0 -Size 100MB -DriveLetter S -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false

    New-Partition -DiskNumber 0 -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null  # MSR - not formatted

    $win = New-Partition -DiskNumber 0 -UseMaximumSize -DriveLetter C
    Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
} else {
    # Gen 1 / BIOS: MBR with a single active primary partition
    Clear-Disk -Number 0 -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
    Initialize-Disk -Number 0 -PartitionStyle MBR

    $win = New-Partition -DiskNumber 0 -UseMaximumSize -DriveLetter C
    Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false
    Set-Partition -DriveLetter C -IsActive $true
}
#>

# ------------------------------------------------------------------
# STEP 4 - Apply OS image
# ------------------------------------------------------------------
Send-PEProgress -Description 'Applying OS image' -Percent 20
Dism.exe /Apply-Image /ImageFile:"$wimPath" /Index:$wimIndex /ApplyDir:C:\
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: DISM /Apply-Image failed with exit code $LASTEXITCODE" -Level ERROR
    Write-Log "  WIM Path : $wimPath" -ForegroundColor Yellow
    Write-Log "  WIM Index: $wimIndex" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit $LASTEXITCODE
}
Send-PEProgress -Description 'OS image applied' -Percent 45

# ------------------------------------------------------------------
# STEP 4b - Run optional PostPEScript (PS5) after image apply
# ------------------------------------------------------------------
if ($machineConfig.PostPEScript) {
    $postScript = "Z:$($machineConfig.PostPEScript)"
    if (Test-Path $postScript) {
        Write-Log "Running PostPEScript: $postScript" -ForegroundColor Cyan
        powershell.exe -ExecutionPolicy Bypass -File $postScript
        Write-Log "PostPEScript completed with exit code $LASTEXITCODE" -ForegroundColor Cyan
    } else {
        Write-Log "WARNING: PostPEScript not found: $postScript" -Level WARN
    }
}

# Copy and prepare install2026.ps1 with deployment share mapping
& "Z:\Scripts\Unattend2026\Copy-Install.ps1"

# Setup unattended.xml with settings from CustomSettings.json based on MAC address
& "Z:\Scripts\Unattend2026\Get-Settings.ps1" -MACAddress $macAddress

New-Item -ItemType Directory -Path "C:\Windows\Panther" -Force
Copy-Item "C:\temp\unattend.xml" "C:\Windows\Panther\unattend.xml"
Dism.exe /Image:C:\ /Apply-Unattend:"C:\Windows\Panther\unattend.xml"
remove-item "C:\temp\unattend.xml"

if ($isUEFI) {
    BCDBoot.exe C:\windows /l en-US /s S: /f UEFI
} else {
    # Gen 1 / BIOS: boot store goes on the Windows partition
    BCDBoot.exe C:\windows /l en-US /s C: /f BIOS
}
BCDEdit.exe /timeout 0

Write-Log "Rebooting..." -ForegroundColor Green
Send-PEProgress -Description 'Rebooting to Windows' -Percent 50
wpeutil Reboot
