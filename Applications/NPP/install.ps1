$msi = Join-Path $PSScriptRoot 'npp.8.9.2.Installer.x64.msi'

$process = Start-Process -FilePath 'msiexec.exe' `
    -ArgumentList '/i', "`"$msi`"", '/qn', '/norestart' `
    -Wait `
    -PassThru

if ($process.ExitCode -notin 0, 3010) {
    Write-Error "Notepad++ installation failed with exit code $($process.ExitCode)"
    exit $process.ExitCode
}

$src  = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Notepad++\Notepad++.lnk'
$dest = 'C:\Users\Public\Desktop\Notepad++.lnk'

if (Test-Path $src) {
    Copy-Item -Path $src -Destination $dest -Force
} else {
    Write-Warning "Notepad++ shortcut not found at: $src"
}

exit $process.ExitCode
