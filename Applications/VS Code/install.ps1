$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# System installer (per-machine, C:\Program Files\Microsoft VS Code), not the user installer.
$url  = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64'
$temp = if (Test-Path 'C:\temp') { 'C:\temp' } else { $env:TEMP }
$exe  = Join-Path $temp 'VSCodeSetup-x64.exe'

Write-Host "Downloading latest VS Code from $url"
$oldProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'   # PS 5 progress bar slows Invoke-WebRequest drastically
try {
    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
} finally {
    $ProgressPreference = $oldProgress
}

$sig = Get-AuthenticodeSignature -FilePath $exe
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
    Remove-Item $exe -Force -ErrorAction SilentlyContinue
    Write-Error "VS Code installer signature check failed: $($sig.Status) / $($sig.SignerCertificate.Subject)"
    exit 1
}

Write-Host 'Installing VS Code for all users'
$process = Start-Process -FilePath $exe `
    -ArgumentList '/VERYSILENT', '/NORESTART', '/SUPPRESSMSGBOXES', '/MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,addtopath' `
    -Wait `
    -PassThru

Remove-Item $exe -Force -ErrorAction SilentlyContinue

if ($process.ExitCode -ne 0) {
    Write-Error "VS Code installation failed with exit code $($process.ExitCode)"
    exit $process.ExitCode
}

$codeExe = Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'
if (-not (Test-Path $codeExe)) {
    Write-Error "VS Code not found at expected path: $codeExe"
    exit 1
}

Write-Host "VS Code installed: $codeExe"

$shell    = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut('C:\Users\Public\Desktop\Visual Studio Code.lnk')
$shortcut.TargetPath       = $codeExe
$shortcut.WorkingDirectory = Split-Path $codeExe
$shortcut.Save()
Write-Host 'Created shortcut on the public desktop'

exit 0
