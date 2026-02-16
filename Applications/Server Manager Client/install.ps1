$Domain = (Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem).Domain

$Folder = 'foo'
$Server = 'bar'

switch ($Domain) {
    "lindex.local" {
        $Folder = 'smc'
        $Server = 'sentmdt03.lindex.local'
    }

    "ldxqa.local" {
        $Folder = 'smcqa'
        $Server = 'sentmdt03.lindex.local'
    }

    "corp.dev" {
        $Folder = 'smcdev'
        $Server = 'dc01.corp.dev'
    }
}
#  7z.dll 7z.exe ServerManagerClient.exe ServerManagerClient.json watchdog.exe watchdog.json Newtonsoft.Json.dll csroutines.dll 
robocopy "\\$Server\Deploy\Applications\Server Manager Client" "C:\Program files\$Folder" ServerManagerClient.json ServerManagerClient.exe Newtonsoft.Json.dll CSRoutines.dll /r:1 /w:1

New-Service -name 'smc' -BinaryPathName "C:\Program Files\$Folder\ServerManagerClient.exe" -DisplayName 'Server Manager Client' -StartupType Manual

exit 0
