<#
.SYNOPSIS
    Deploys go2rtc for camera ingest, and probes cameras for their RTSP path.

.DESCRIPTION
    Two modes.

    Default: downloads go2rtc and FFmpeg, deploys the stream configuration and
    registers a startup task.

    -Probe: brute-forces the RTSP path of a single camera. The Sercomm XCam
    series does not document its RTSP endpoint and it varies by firmware, so
    this walks a candidate list with ffprobe and reports which paths return a
    decodable video stream.

.PARAMETER Probe
    Probe a camera for its RTSP path instead of deploying.

.PARAMETER CameraIp
    Camera IP address. Required with -Probe.

.PARAMETER CameraUser
    Camera username. Default: admin

.PARAMETER CameraPassword
    Camera password. Required with -Probe.

.PARAMETER InstallPath
    Install directory. Default C:\go2rtc

.EXAMPLE
    .\05-Setup-Cameras.ps1 -Probe -CameraIp 192.168.1.50 -CameraUser admin -CameraPassword hunter2

.EXAMPLE
    .\05-Setup-Cameras.ps1

.NOTES
    Run as Administrator for the deploy mode. -Probe does not need elevation
    once FFmpeg is installed.
#>
[CmdletBinding()]
param(
    [switch]$Probe,
    [string]$CameraIp,
    [string]$CameraUser = 'admin',
    [string]$CameraPassword,
    [string]$InstallPath = 'C:\go2rtc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DataRoot   = 'C:\ProgramData\xfinity-home'
$Go2rtcData = Join-Path $DataRoot 'go2rtc'
$ConfPath   = Join-Path $Go2rtcData 'go2rtc.yaml'
$RepoConf   = Join-Path (Split-Path $PSScriptRoot -Parent) 'config\go2rtc\go2rtc.yaml.template'
$TaskName   = 'go2rtc'
$ReleaseApi = 'https://api.github.com/repos/AlexxIT/go2rtc/releases/latest'

# Ordered by how often each has been observed on Sercomm firmware.
$CandidatePaths = @(
    '/img/media.sav',
    '/video.pro1',
    '/video.pro2',
    '/video.pro3',
    '/img/video.sav',
    '/live/ch0',
    '/live/ch00_0',
    '/h264',
    '/stream1',
    '/onvif1',
    '/media/video1',
    '/11',
    '/'
)

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

function Find-Ffprobe {
    $cmd = Get-Command 'ffprobe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @("$InstallPath\ffmpeg\bin\ffprobe.exe", 'C:\ffmpeg\bin\ffprobe.exe')) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
}

# ===========================================================================
# PROBE MODE
# ===========================================================================
if ($Probe) {
    if (-not $CameraIp)       { throw '-CameraIp is required with -Probe.' }
    if (-not $CameraPassword) { throw '-CameraPassword is required with -Probe.' }

    $ffprobe = Find-Ffprobe
    if (-not $ffprobe) {
        throw @'
ffprobe not found. Install FFmpeg first:
    winget install --id Gyan.FFmpeg --exact
Then open a new shell and retry.
'@
    }

    Write-Host ''
    Write-Host "Probing $CameraIp for a working RTSP path" -ForegroundColor Cyan
    Write-Host '-----------------------------------------' -ForegroundColor DarkGray

    # Reachability first, so a firewalled camera does not look like 13 path failures.
    Write-Host 'Checking RTSP port 554 ...' -ForegroundColor Cyan
    $tcp = Test-NetConnection -ComputerName $CameraIp -Port 554 -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        throw @"
Cannot reach $CameraIp on TCP 554.

The camera is either not on the network, on a different subnet, or has not had
its RTSP service enabled by the firmware unlock. Confirm it responds to ping
and that RTSP is actually exposed before probing paths.
"@
    }
    Write-Host 'Port 554 open.' -ForegroundColor Green
    Write-Host ''

    $hits = @()

    foreach ($path in $CandidatePaths) {
        $url     = "rtsp://${CameraUser}:${CameraPassword}@${CameraIp}:554${path}"
        $display = "rtsp://${CameraUser}:***@${CameraIp}:554${path}"

        Write-Host ("  {0,-20} " -f $path) -NoNewline

        # -rtsp_transport tcp: these cameras are unreliable over UDP.
        # -timeout is in microseconds for the rtsp demuxer.
        # Not named $args - that is a PowerShell automatic variable.
        $probeArgs = @(
            '-v', 'error',
            '-rtsp_transport', 'tcp',
            '-timeout', '5000000',
            '-select_streams', 'v:0',
            '-show_entries', 'stream=codec_name,width,height',
            '-of', 'default=noprint_wrappers=1:nokey=0',
            $url
        )

        $out = & $ffprobe @probeArgs 2>&1
        $ok  = ($LASTEXITCODE -eq 0) -and ($out -match 'codec_name')

        if ($ok) {
            $codec  = ($out | Select-String 'codec_name=(.+)').Matches.Groups[1].Value
            $width  = ($out | Select-String 'width=(.+)').Matches.Groups[1].Value
            $height = ($out | Select-String 'height=(.+)').Matches.Groups[1].Value
            Write-Host ("OK   {0} {1}x{2}" -f $codec, $width, $height) -ForegroundColor Green
            $hits += [pscustomobject]@{
                Path = $path; Url = $display; Codec = $codec
                Resolution = "${width}x${height}"
            }
        }
        else {
            $reason = if ($out -match '401|[Uu]nauthorized') { 'auth rejected' }
                      elseif ($out -match '404|[Nn]ot [Ff]ound') { 'no such path' }
                      elseif ($out -match 'timed out|[Tt]imeout') { 'timeout' }
                      else { 'no stream' }
            Write-Host $reason -ForegroundColor DarkGray
        }
    }

    Write-Host ''
    if ($hits.Count -eq 0) {
        Write-Host 'No candidate path returned a stream.' -ForegroundColor Red
        Write-Host ''
        Write-Host 'Things worth checking:' -ForegroundColor Yellow
        Write-Host '  - Credentials. An auth rejection on every path means the username or'
        Write-Host '    password is wrong, not that the paths are wrong.'
        Write-Host '  - Whether RTSP is actually enabled. Stock Xfinity firmware keeps the'
        Write-Host '    RTSP server closed; if the unlock did not enable it, no path exists.'
        Write-Host '  - The camera web UI, which sometimes exposes the stream URL directly.'
        Write-Host '  - ONVIF discovery, which will report the RTSP URI if the camera speaks it.'
        return
    }

    Write-Host ("Found {0} working path(s):" -f $hits.Count) -ForegroundColor Green
    $hits | Format-Table -AutoSize Path, Codec, Resolution

    $best = $hits[0]
    Write-Host 'Add to go2rtc.yaml under streams: (name it whatever the camera watches)' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  front_door: rtsp://${CameraUser}:PASSWORD@${CameraIp}:554$($best.Path)"
    Write-Host ''
    if ($hits.Count -gt 1) {
        Write-Host 'Multiple paths worked. The highest resolution is normally the main stream;'
        Write-Host 'a lower-resolution one is the substream, useful for dashboard tiles.'
    }
    return
}

# ===========================================================================
# DEPLOY MODE
# ===========================================================================
Assert-Administrator

Write-Host ''
Write-Host 'Camera layer deployment (go2rtc)' -ForegroundColor Cyan
Write-Host '--------------------------------' -ForegroundColor DarkGray

if (-not (Test-Path $RepoConf)) { throw "Config template missing at $RepoConf" }

foreach ($d in @($DataRoot, $Go2rtcData, $InstallPath)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# --- FFmpeg ----------------------------------------------------------------
$ffprobe = Find-Ffprobe
if (-not $ffprobe) {
    Write-Host 'Installing FFmpeg ...' -ForegroundColor Cyan
    & winget install --id 'Gyan.FFmpeg' --exact `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    $code = $LASTEXITCODE
    if ($code -ne 0 -and $code -ne -1978335189) {
        Write-Warning "FFmpeg install returned $code. go2rtc will still handle direct RTSP passthrough without it."
    }
    Update-SessionPath
    $ffprobe = Find-Ffprobe
}

$ffmpegPath = 'ffmpeg'
if ($ffprobe) {
    $candidate = Join-Path (Split-Path $ffprobe -Parent) 'ffmpeg.exe'
    if (Test-Path $candidate) { $ffmpegPath = $candidate }
    Write-Host "FFmpeg: $ffmpegPath" -ForegroundColor Green
}
else {
    Write-Warning 'FFmpeg not found. Direct RTSP passthrough works; transcoding will not.'
}

# --- go2rtc ----------------------------------------------------------------
$exePath = Join-Path $InstallPath 'go2rtc.exe'

if (Test-Path $exePath) {
    Write-Host "go2rtc already present at $exePath" -ForegroundColor Green
}
else {
    Write-Host 'Resolving the latest go2rtc release ...' -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $release = Invoke-RestMethod -Uri $ReleaseApi -Headers @{ 'User-Agent' = 'xfinity-home-setup' }
    }
    catch {
        throw @"
Could not query the GitHub releases API: $_

Download go2rtc_win64.zip manually from
    https://github.com/AlexxIT/go2rtc/releases/latest
extract go2rtc.exe to $InstallPath and re-run.
"@
    }

    $asset = $release.assets |
        Where-Object { $_.name -match 'win' -and $_.name -match '64' } |
        Select-Object -First 1
    if (-not $asset) {
        throw "No Windows 64-bit asset in release $($release.tag_name). Download manually to $InstallPath."
    }

    Write-Host "Downloading $($asset.name) ($($release.tag_name)) ..." -ForegroundColor Cyan
    $tmp = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing

    if ($asset.name -match '\.zip$') {
        Expand-Archive -Path $tmp -DestinationPath $InstallPath -Force
    }
    else {
        Move-Item $tmp $exePath -Force
    }
    Remove-Item $tmp -ErrorAction SilentlyContinue

    if (-not (Test-Path $exePath)) {
        $found = Get-ChildItem -Path $InstallPath -Filter 'go2rtc*.exe' -Recurse | Select-Object -First 1
        if (-not $found) { throw 'go2rtc executable not found after extraction.' }
        Move-Item $found.FullName $exePath -Force
    }
    Write-Host 'Downloaded.' -ForegroundColor Green
}

# --- Config ----------------------------------------------------------------
if (Test-Path $ConfPath) {
    Write-Host 'Existing go2rtc.yaml found - leaving it in place.' -ForegroundColor Yellow
    Write-Host 'Delete it and re-run to regenerate from the template.' -ForegroundColor DarkGray
}
else {
    $conf = Get-Content $RepoConf -Raw
    $conf = $conf.Replace('{{FFMPEG_PATH}}', ($ffmpegPath -replace '\\', '\\'))
    [System.IO.File]::WriteAllText($ConfPath, $conf, (New-Object System.Text.UTF8Encoding($false)))
    & icacls $ConfPath /inheritance:r /grant:r 'SYSTEM:(F)' 'BUILTIN\Administrators:(F)' | Out-Null
    Write-Host "Wrote $ConfPath" -ForegroundColor Green
}

# --- Startup task ----------------------------------------------------------
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $exePath -Argument "-config `"$ConfPath`"" -WorkingDirectory $InstallPath
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'go2rtc - camera stream ingest and restreaming' | Out-Null

Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green

Write-Host ''
Write-Host 'Camera layer deployed.' -ForegroundColor Green
Write-Host ''
Write-Host 'No streams are configured yet. For each camera:' -ForegroundColor Cyan
Write-Host '  1. Find its RTSP path:'
Write-Host '       .\05-Setup-Cameras.ps1 -Probe -CameraIp <ip> -CameraUser admin -CameraPassword <pw>'
Write-Host "  2. Add the stream under 'streams:' in $ConfPath"
Write-Host "  3. Start-ScheduledTask -TaskName $TaskName"
Write-Host '  4. Confirm at http://127.0.0.1:1984'
