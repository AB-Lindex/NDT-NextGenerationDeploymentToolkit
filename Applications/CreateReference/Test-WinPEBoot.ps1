<#
.SYNOPSIS
    Sets up the BCD for WinPE ramdisk boot and reboots — WITHOUT running sysprep.
.DESCRIPTION
    Use this to isolate whether the BCD/WIM configuration itself works independently
    of sysprep.  If WinPE boots successfully from this test, sysprep is resetting the
    BCD entries (known MDT behaviour on Vista+).  If it still fails with 0xED, the
    problem is in the boot files, not sysprep.
    
    After the test reboot, WinPE will boot (or fail).  Either way, the VM will
    eventually land back at the Windows boot menu (30 s timeout) or back in Windows.
    Run  bcdedit /enum all  afterwards to check whether the entry survived the reboot.
#>

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error "Must run as Administrator"; exit 1 }

$bootDrive = $env:SystemDrive   # C:
$wimDest   = "$bootDrive\sources\boot.wim"
$sdiDest   = "$bootDrive\Boot\boot.sdi"
$guidFile  = "$bootDrive\WinPE-BCD-GUID.txt"
$isoPath   = "Z:\Boot\boot2026.iso"

# ---- Extract WinPE files from ISO -------------------------------------------
Write-Output "Mounting $isoPath ..."
$mount    = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
$isoDrive = ($mount | Get-Volume).DriveLetter + ":"

try {
    foreach ($f in @("$isoDrive\Boot\boot.sdi", "$isoDrive\sources\boot.wim")) {
        if (-not (Test-Path $f)) { throw "Not found in ISO: $f" }
    }
    New-Item -ItemType Directory -Force -Path "$bootDrive\Boot"    | Out-Null
    New-Item -ItemType Directory -Force -Path "$bootDrive\sources" | Out-Null
    Copy-Item "$isoDrive\Boot\boot.sdi"       $sdiDest  -Force
    Copy-Item "$isoDrive\sources\boot.wim"    $wimDest  -Force
    Write-Output "  [OK] boot.sdi  -> $sdiDest"
    Write-Output "  [OK] boot.wim  -> $wimDest  ($([math]::Round((Get-Item $wimDest).Length/1MB)) MB)"
} finally {
    Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue | Out-Null
}

# ---- Configure BCD ----------------------------------------------------------
Write-Output "Configuring BCD..."
& bcdedit /delete "{ramdiskoptions}" 2>&1 | Out-Null
& bcdedit /create "{ramdiskoptions}" /d "Ramdisk Options" | Out-Null
& bcdedit /set "{ramdiskoptions}" ramdisksdidevice "partition=$bootDrive" | Out-Null
& bcdedit /set "{ramdiskoptions}" ramdisksdipath   \Boot\boot.sdi         | Out-Null

$createOut = & bcdedit /create /d "WinPE TEST" /application OSLOADER 2>&1
$guid      = [regex]::Match($createOut, '\{[0-9a-fA-F-]{36}\}').Value
if (-not $guid) { Write-Error "bcdedit /create failed: $createOut"; exit 1 }

& bcdedit /set $guid device     "ramdisk=[$bootDrive]\sources\boot.wim,{ramdiskoptions}" | Out-Null
& bcdedit /set $guid path       \Windows\System32\winload.exe | Out-Null
& bcdedit /set $guid osdevice   "ramdisk=[$bootDrive]\sources\boot.wim,{ramdiskoptions}" | Out-Null
& bcdedit /set $guid systemroot \Windows  | Out-Null
& bcdedit /set $guid detecthal  Yes       | Out-Null
& bcdedit /set $guid winpe      Yes       | Out-Null
& bcdedit /set $guid nx         OptIn     | Out-Null

& bcdedit /displayorder $guid /addfirst | Out-Null
& bcdedit /default      $guid           | Out-Null
& bcdedit /timeout      30              | Out-Null

Set-Content -Path $guidFile -Value $guid -Force

Write-Output ""
Write-Output "BCD entry created: $guid"
Write-Output ""
& bcdedit /enum all
Write-Output ""
Write-Output "========================================"
Write-Output "IF WinPE boots OK  → sysprep is resetting the BCD (known issue)"
Write-Output "IF 0xED still      → the WIM/SDI files or bootmgr are the problem"
Write-Output "========================================"
Write-Output ""
Write-Output "The VM will reboot in 15 seconds into WinPE."
Write-Output "30-second BCD timeout will fall back to Windows if WinPE fails."
Write-Output ""
Read-Host "Press Enter to reboot now (or Ctrl+C to abort)"

shutdown /r /t 5 /c "WinPE boot test"
