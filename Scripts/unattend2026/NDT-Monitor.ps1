# NDT Monitor — HTTP listener for centralised deployment progress tracking
# Mirrors MDT's monitoring service: receives percent + step name from each deploying machine.
#
# Usage (run as Administrator on the NDT server):
#   pwsh.exe -File NDT-Monitor.ps1
#   pwsh.exe -File NDT-Monitor.ps1 -Port 9999 -LogRoot C:\Deploy2026\Logs\progress
#
# Endpoints:
#   POST /progress          — receive a progress update (JSON body)
#   GET  /progress          — return all current machine states as a JSON array
#   GET  /progress/<mac>    — return a single machine's latest state (MAC with dashes or colons)
#
# Each deploying machine POSTs:
#   { Computername, MAC, Status, Description, Group, StepId, Completed, Total, Percent, Timestamp }
#
# Data is stored in <LogRoot>\<MAC>.json  (latest state per machine)
# and appended to    <LogRoot>\audit.jsonl (full audit trail, one JSON object per line)

param(
    [int]$Port      = 9999,
    [string]$LogRoot = 'C:\Deploy2026\Logs\progress'
)

New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$Port/")

try {
    $listener.Start()
} catch {
    Write-Host "Failed to start HTTP listener on port $Port. Run as Administrator." -ForegroundColor Red
    Write-Host $_ -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'NDT Monitor started' -ForegroundColor Green
Write-Host "  Port    : $Port"     -ForegroundColor Gray
Write-Host "  Log root: $LogRoot"  -ForegroundColor Gray
Write-Host '  Endpoints:' -ForegroundColor Gray
Write-Host '    POST /progress          receive progress update' -ForegroundColor Gray
Write-Host '    GET  /progress          all machine states (JSON array)' -ForegroundColor Gray
Write-Host '    GET  /progress/<mac>    single machine state' -ForegroundColor Gray
Write-Host ''
Write-Host 'Press Ctrl+C to stop.' -ForegroundColor Gray
Write-Host ''

function Write-MonitorLog {
    param([string]$Message, [string]$Color = 'White')
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $req     = $context.Request
        $res     = $context.Response
        $method  = $req.HttpMethod
        $path    = $req.Url.AbsolutePath.TrimEnd('/')

        $responseBody    = ''
        $res.ContentType = 'application/json; charset=utf-8'

        try {
            # ---------------------------------------------------------------
            # POST /progress — receive a progress update from a deploying machine
            # ---------------------------------------------------------------
            if ($method -eq 'POST' -and $path -eq '/progress') {
                $raw  = [System.IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8).ReadToEnd()
                $data = $raw | ConvertFrom-Json

                # Normalise MAC: uppercase, colons replaced by dashes (safe filename)
                $macNorm = ($data.MAC -replace ':', '-').ToUpper()
                $stateFile = Join-Path $LogRoot "$macNorm.json"

                # Overwrite latest state for this machine
                $raw | Set-Content -Path $stateFile -Encoding UTF8

                # Append to audit log (one JSON object per line)
                Add-Content -Path (Join-Path $LogRoot 'audit.jsonl') -Value $raw.TrimEnd()

                $pct = if ($null -ne $data.Percent) { "$($data.Percent)%" } else { '?' }
                Write-MonitorLog "$($data.Computername) [$($data.MAC)]  $($data.Status.PadRight(10))  $($data.Description)  ($pct  $($data.Completed)/$($data.Total))" -Color Cyan

                $res.StatusCode = 200
                $responseBody   = '{"ok":true}'
            }

            # ---------------------------------------------------------------
            # GET /progress — return all current machine states as JSON array
            # ---------------------------------------------------------------
            elseif ($method -eq 'GET' -and $path -eq '/progress') {
                $machines = @(
                    Get-ChildItem -Path $LogRoot -Filter '*.json' -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                        if ($content) { $content | ConvertFrom-Json }
                    }
                )
                $responseBody   = if ($machines.Count -gt 0) { $machines | ConvertTo-Json -Depth 5 } else { '[]' }
                $res.StatusCode = 200
            }

            # ---------------------------------------------------------------
            # GET /progress/<mac> — return a single machine's latest state
            # ---------------------------------------------------------------
            elseif ($method -eq 'GET' -and $path -match '^/progress/(.+)$') {
                $macNorm   = ($Matches[1] -replace ':', '-').ToUpper()
                $stateFile = Join-Path $LogRoot "$macNorm.json"
                if (Test-Path $stateFile) {
                    $responseBody   = Get-Content $stateFile -Raw
                    $res.StatusCode = 200
                } else {
                    $responseBody   = '{"error":"not found"}'
                    $res.StatusCode = 404
                }
            }

            else {
                $responseBody   = '{"error":"not found"}'
                $res.StatusCode = 404
            }

        } catch {
            $msg            = ($_ -replace '"', "'")
            $responseBody   = "{`"error`":`"$msg`"}"
            $res.StatusCode = 500
            Write-MonitorLog "Error handling request: $_" -Color Red
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($responseBody)
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.Close()
    }
} finally {
    $listener.Stop()
    Write-Host ''
    Write-Host 'NDT Monitor stopped.' -ForegroundColor Yellow
}
