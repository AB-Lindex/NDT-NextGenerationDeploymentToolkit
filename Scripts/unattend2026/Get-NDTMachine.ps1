# Shared machine lookup: merges the MAC blocks of Control\CustomSettings.json with every
# Control\Projects\**\*.json into one PSCustomObject keyed by upper-case MAC address.
#
# Dot-source this file, then call Get-NDTMachine. It is a drop-in replacement for
#   Get-Content Z:\Control\CustomSettings.json -Raw | ConvertFrom-Json
# so `$customSettings.$macAddress` keeps working unchanged. PS 5.1 and PS 7 compatible
# (runs in WinPE PS 5.1, first-boot PS 5.1 and the PS 7 step engine).
#
#   . 'Z:\Scripts\unattend2026\Get-NDTMachine.ps1'
#   $src = @{}
#   $customSettings = Get-NDTMachine -SourceMap $src     # $src[<MAC>] = 'Projects\A\web.json'
#
# Rules: only MAC-shaped keys count (case-insensitive, normalised to upper case); a duplicate
# MAC anywhere (same or different file) or an unreadable/invalid JSON file is a terminating
# error; empty files are skipped; a missing Projects folder simply adds no machines.

function Get-NDTMachine {
    [CmdletBinding()]
    param(
        [string]$ControlPath = 'Z:\Control',

        # Optional hashtable filled with MAC -> source file (relative to the Control folder).
        [hashtable]$SourceMap
    )

    $macPattern = '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'
    $controlFull = [System.IO.Path]::GetFullPath($ControlPath).TrimEnd('\')

    $files = New-Object System.Collections.Generic.List[string]
    $csFile = Join-Path $controlFull 'CustomSettings.json'
    if (Test-Path -LiteralPath $csFile -PathType Leaf) { $files.Add($csFile) }

    $projectsDir = Join-Path $controlFull 'Projects'
    if (Test-Path -LiteralPath $projectsDir -PathType Container) {
        # -Filter *.json can also match longer extensions (e.g. .json1) - keep exact .json only.
        Get-ChildItem -LiteralPath $projectsDir -Filter '*.json' -File -Recurse |
            Where-Object { $_.Extension -eq '.json' } |
            Sort-Object FullName |
            ForEach-Object { $files.Add($_.FullName) }
    }

    $merged  = [ordered]@{}
    $owners  = @{}
    $dupes   = New-Object System.Collections.Generic.List[string]

    foreach ($file in $files) {
        $rel = $file.Substring($controlFull.Length).TrimStart('\')

        $raw = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        try {
            $json = $raw | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "Invalid JSON in Control\$rel : $($_.Exception.Message)"
        }
        if ($null -eq $json -or $json -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Control\$rel must contain a JSON object keyed by MAC address."
        }

        foreach ($prop in $json.PSObject.Properties) {
            $mac = $prop.Name.ToUpper()
            if ($mac -notmatch $macPattern) { continue }

            if ($owners.ContainsKey($mac)) {
                $dupes.Add("  $mac in Control\$($owners[$mac]) and Control\$rel")
                continue
            }
            $owners[$mac] = $rel
            $merged[$mac] = $prop.Value
        }
    }

    if ($dupes.Count -gt 0) {
        throw "Duplicate MAC address(es) in the machine configuration - each MAC may appear only once:`n$($dupes -join "`n")"
    }

    if ($SourceMap) {
        foreach ($mac in $owners.Keys) { $SourceMap[$mac] = $owners[$mac] }
    }

    [PSCustomObject]$merged
}
