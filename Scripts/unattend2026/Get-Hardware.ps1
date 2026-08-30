# Get-Hardware.ps1
# Detect vendor / model and physical-vs-virtual (including the hypervisor name).
# PS 5.1-compatible on purpose: runs in the production PS5.1 WinPE, the PS7 POC WinPE,
# install2026.ps1 (PS5), and the PS7 step engine. Emits ONLY a PSCustomObject on the
# pipeline (no Write-Host) so callers can consume it for live queries and for embedding
# into settings.json. All detection is best-effort and never throws.

[CmdletBinding()]
param()

# --------------------------------------------------------------------------
# CPUID hypervisor-vendor fallback (leaf 0x40000000).
# Survives SMBIOS make/model spoofing. Needs Add-Type (csc), which may be absent
# in the production WinPE - returns $null there and detection falls back to WMI.
# x64 only (all NDT targets are AMD64); returns $null on x86.
# --------------------------------------------------------------------------
function Get-CpuIdHypervisorVendor {
    try {
        if (-not ('NdtCpuId' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class NdtCpuId {
    [DllImport("kernel32")] static extern IntPtr VirtualAlloc(IntPtr a, UIntPtr s, uint t, uint p);
    [DllImport("kernel32")] static extern bool  VirtualFree(IntPtr a, UIntPtr s, uint t);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void CpuIdDelegate(uint level, byte[] buf);
    // x64: RCX=level, RDX=buffer. Writes EAX,EBX,ECX,EDX (16 bytes) to buffer.
    static readonly byte[] code = new byte[] {
        0x53,                   // push rbx
        0x49,0x89,0xD0,         // mov  r8, rdx
        0x89,0xC8,              // mov  eax, ecx
        0x31,0xC9,              // xor  ecx, ecx
        0x0F,0xA2,              // cpuid
        0x41,0x89,0x00,         // mov  [r8],    eax
        0x41,0x89,0x58,0x04,    // mov  [r8+4],  ebx
        0x41,0x89,0x48,0x08,    // mov  [r8+8],  ecx
        0x41,0x89,0x50,0x0C,    // mov  [r8+12], edx
        0x5B,                   // pop  rbx
        0xC3                    // ret
    };
    public static string HypervisorVendor() {
        if (IntPtr.Size != 8) return null;
        IntPtr p = VirtualAlloc(IntPtr.Zero, (UIntPtr)code.Length, 0x1000 | 0x2000, 0x40);
        if (p == IntPtr.Zero) return null;
        try {
            Marshal.Copy(code, 0, p, code.Length);
            CpuIdDelegate f = (CpuIdDelegate)Marshal.GetDelegateForFunctionPointer(p, typeof(CpuIdDelegate));
            byte[] buf = new byte[16];
            f(0x40000000, buf);
            string s = Encoding.ASCII.GetString(buf, 4, 4)
                     + Encoding.ASCII.GetString(buf, 8, 4)
                     + Encoding.ASCII.GetString(buf, 12, 4);
            return s.Replace("\0", "").Trim();
        } finally {
            VirtualFree(p, UIntPtr.Zero, 0x8000);
        }
    }
}
'@
        }
        $vendor = [NdtCpuId]::HypervisorVendor()
        if ([string]::IsNullOrWhiteSpace($vendor)) { return $null }
        return $vendor
    } catch {
        # No compiler in this WinPE, or the call failed - WMI signatures still cover it.
        return $null
    }
}

# Map a raw CPUID leaf-0x40000000 vendor string to a friendly platform name.
function ConvertFrom-CpuIdVendor {
    param([string]$Vendor)
    if (-not $Vendor) { return $null }
    switch -Regex ($Vendor) {
        'Microsoft Hv'   { return 'Hyper-V' }
        'VMwareVMware'   { return 'VMware' }
        'KVMKVMKVM'      { return 'KVM/QEMU' }
        'TCGTCGTCGTCG'   { return 'KVM/QEMU' }   # QEMU (TCG, no KVM accel)
        'XenVMMXenVMM'   { return 'Xen' }
        'VBoxVBoxVBox'   { return 'VirtualBox' }
        'prl hyperv'     { return 'Parallels' }
        'bhyve bhyve'    { return 'bhyve' }
        'ACRNACRNACRN'   { return 'ACRN' }
        'QNXQVMBSQG'     { return 'QNX' }
        default          { return $Vendor }       # unknown but present -> still a hypervisor
    }
}

# --------------------------------------------------------------------------
# WMI / SMBIOS asset info (WinPE-compatible via Get-CimInstance).
# --------------------------------------------------------------------------
$cs    = Get-CimInstance -ClassName Win32_ComputerSystem        -ErrorAction SilentlyContinue | Select-Object -First 1
$bios  = Get-CimInstance -ClassName Win32_BIOS                  -ErrorAction SilentlyContinue | Select-Object -First 1
$board = Get-CimInstance -ClassName Win32_BaseBoard             -ErrorAction SilentlyContinue | Select-Object -First 1
$prod  = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction SilentlyContinue | Select-Object -First 1
$enc   = Get-CimInstance -ClassName Win32_SystemEnclosure       -ErrorAction SilentlyContinue | Select-Object -First 1

$make       = if ($cs.Manufacturer)   { $cs.Manufacturer.Trim() }   else { '' }
$model      = if ($cs.Model)          { $cs.Model.Trim() }          else { '' }
$serial     = if ($bios.SerialNumber) { $bios.SerialNumber.Trim() } else { '' }
$biosVer    = if ($bios.SMBIOSBIOSVersion) { $bios.SMBIOSBIOSVersion.Trim() } elseif ($bios.Version) { ($bios.Version -join ' ').Trim() } else { '' }
$biosVendor = if ($bios.Manufacturer) { $bios.Manufacturer.Trim() } else { '' }
$boardProd  = if ($board.Product)     { $board.Product.Trim() }     else { '' }
$uuid       = if ($prod.UUID)         { $prod.UUID.Trim() }         else { '' }
$assetTag   = if ($enc.SMBIOSAssetTag){ $enc.SMBIOSAssetTag.Trim() } else { '' }

# Chassis form-factor (same SMBIOS ChassisType codes MDT keys off).
$chassisType = $null
if ($enc -and $enc.ChassisTypes) { $chassisType = [int]$enc.ChassisTypes[0] }
$isLaptop  = $chassisType -in 8,9,10,11,12,14,18,21,30,31,32
$isDesktop = $chassisType -in 3,4,5,6,7,13,15,16,35,36
$isServer  = $chassisType -in 23,28

# --------------------------------------------------------------------------
# Platform detection: WMI signatures first, then CPUID as fallback/confirmation.
# --------------------------------------------------------------------------
$U = "$make $model $biosVendor $boardProd".ToUpper()
$platform = ''
$method   = ''

if ($model.ToUpper() -eq 'VIRTUAL MACHINE' -and $make.ToUpper() -like 'MICROSOFT*') {
    $platform = 'Hyper-V';    $method = 'WMI:Model'          # covers Azure (Hyper-V based)
} elseif ($U -like '*VMWARE*') {
    $platform = 'VMware';     $method = 'WMI:Manufacturer'
} elseif ($U -like '*VIRTUALBOX*' -or $U -like '*INNOTEK*') {
    $platform = 'VirtualBox'; $method = 'WMI:Model'
} elseif ($U -like '*PARALLELS*') {
    $platform = 'Parallels';  $method = 'WMI:Manufacturer'
} elseif ($U -like '*QEMU*' -or $U -like '*KVM*' -or $biosVendor.ToUpper() -like '*SEABIOS*') {
    $platform = 'KVM/QEMU';   $method = 'WMI:Manufacturer'   # Proxmox, oVirt/RHEV, OpenStack, libvirt
} elseif ($biosVendor.ToUpper() -like '*BOCHS*') {
    $platform = 'KVM/QEMU';   $method = 'WMI:BIOS'
} elseif ($U -like '*XEN*') {
    $platform = 'Xen';        $method = 'WMI:Manufacturer'
} elseif ($U -like '*AMAZON*' -or $U -like '*EC2*') {
    $platform = 'Amazon EC2'; $method = 'WMI:Manufacturer'
} elseif ($U -like '*GOOGLE*') {
    $platform = 'Google Compute Engine'; $method = 'WMI:Manufacturer'
} elseif ($U -like '*NUTANIX*') {
    $platform = 'Nutanix AHV'; $method = 'WMI:Manufacturer'  # AHV is KVM based
}

# CPUID fallback: catches spoofed SMBIOS and platforms WMI did not name.
$cpuidVendor   = Get-CpuIdHypervisorVendor
$cpuidPlatform = ConvertFrom-CpuIdVendor -Vendor $cpuidVendor
if (-not $platform -and $cpuidPlatform) {
    $platform = $cpuidPlatform
    $method   = 'CPUID'
}

$isVM = [bool]$platform
if (-not $isVM) {
    $platform = 'Physical'
    if (-not $method) { $method = 'None' }
}

[PSCustomObject]@{
    Make              = $make
    Model             = $model
    SerialNumber      = $serial
    BiosVersion       = $biosVer
    BiosVendor        = $biosVendor
    BaseBoardProduct  = $boardProd
    AssetTag          = $assetTag
    UUID              = $uuid
    IsVM              = $isVM
    Platform          = $platform
    DetectionMethod   = $method
    CpuidHypervisor   = $cpuidVendor
    HypervisorPresent = [bool]$cs.HypervisorPresent
    ChassisType       = $chassisType
    IsLaptop          = $isLaptop
    IsDesktop         = $isDesktop
    IsServer          = $isServer
}
