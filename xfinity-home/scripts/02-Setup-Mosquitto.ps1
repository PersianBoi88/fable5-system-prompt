<#
.SYNOPSIS
    Installs and configures the Mosquitto MQTT broker as a Windows service.

.DESCRIPTION
    Installs Mosquitto, deploys the repository's mosquitto.conf to a writable
    location outside Program Files, provisions authenticated broker accounts,
    repoints the Windows service at the deployed config, restricts inbound
    access to the local subnet, and verifies the broker with a real
    publish/subscribe round trip.

    Credentials are generated here and written to a protected file that the
    later setup scripts read, so the Zigbee and Z-Wave services are configured
    with matching passwords without you retyping anything.

.PARAMETER MqttUser
    Broker account name used by the service clients. Default: homeauto

.PARAMETER Password
    Broker password. Omit to generate a strong random one.

.PARAMETER Force
    Regenerate the password file and credential store even if they exist.

.NOTES
    Run as Administrator.
#>
[CmdletBinding()]
param(
    [string]$MqttUser = 'homeauto',
    [string]$Password,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DataRoot     = 'C:\ProgramData\xfinity-home'
$MosqDataDir  = Join-Path $DataRoot 'mosquitto'
$ConfPath     = Join-Path $MosqDataDir 'mosquitto.conf'
$PasswdPath   = Join-Path $MosqDataDir 'passwd'
$CredPath     = Join-Path $DataRoot 'credentials.json'
$RepoConf     = Join-Path $PSScriptRoot '..\config\mosquitto\mosquitto.conf'

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

function New-StrongPassword {
    # 24 chars from an unambiguous alphabet. Avoids characters that are painful
    # to quote in YAML/JSON or to read off a screen.
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes    = [byte[]]::new(24)
    $rng      = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try   { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function Protect-File($path) {
    # Strip inherited ACEs and grant only SYSTEM + Administrators.
    & icacls $path /inheritance:r /grant:r 'SYSTEM:(F)' 'BUILTIN\Administrators:(F)' | Out-Null
}

function Find-MosquittoDir {
    $candidates = @(
        'C:\Program Files\mosquitto',
        'C:\Program Files (x86)\mosquitto'
    )
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'mosquitto.exe')) { return $c }
    }
    return $null
}

Assert-Administrator

Write-Host ''
Write-Host 'Mosquitto broker setup' -ForegroundColor Cyan
Write-Host '----------------------' -ForegroundColor DarkGray

if (-not (Test-Path $RepoConf)) {
    throw "Could not find the repository mosquitto.conf at: $RepoConf"
}

# --- Install ---------------------------------------------------------------
$mosqDir = Find-MosquittoDir
if ($mosqDir) {
    Write-Host "Mosquitto already installed at $mosqDir" -ForegroundColor Green
}
else {
    Write-Host 'Installing Mosquitto ...' -ForegroundColor Cyan
    & winget install --id 'EclipseFoundation.Mosquitto' --exact `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    $code = $LASTEXITCODE
    if ($code -ne 0 -and $code -ne -1978335189) {
        throw @"
Mosquitto installation failed (winget exit code $code).

If the package ID has changed, find it with:
    winget search mosquitto

Or install manually from https://mosquitto.org/download/ and re-run this script;
it will detect the existing installation.
"@
    }
    $mosqDir = Find-MosquittoDir
    if (-not $mosqDir) {
        throw 'Mosquitto installed but mosquitto.exe was not found in the expected location. Install manually and re-run.'
    }
}

$MosqExe    = Join-Path $mosqDir 'mosquitto.exe'
$PasswdExe  = Join-Path $mosqDir 'mosquitto_passwd.exe'
$PubExe     = Join-Path $mosqDir 'mosquitto_pub.exe'
$SubExe     = Join-Path $mosqDir 'mosquitto_sub.exe'

# --- Data directory --------------------------------------------------------
foreach ($d in @($DataRoot, $MosqDataDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "Created $d"
    }
}

# --- Credentials -----------------------------------------------------------
$creds = $null
if ((Test-Path $CredPath) -and -not $Force) {
    $creds = Get-Content $CredPath -Raw | ConvertFrom-Json
    Write-Host "Reusing existing credentials for user '$($creds.mqtt_user)'." -ForegroundColor Green
    Write-Host 'Pass -Force to regenerate.' -ForegroundColor DarkGray
}
else {
    if (-not $Password) { $Password = New-StrongPassword }
    $creds = [pscustomobject]@{
        mqtt_user     = $MqttUser
        mqtt_password = $Password
        mqtt_host     = '127.0.0.1'
        mqtt_port     = 1883
        mqtt_ws_port  = 9001
        generated_at  = (Get-Date).ToString('o')
    }
    $creds | ConvertTo-Json | Set-Content -Path $CredPath -Encoding UTF8
    Protect-File $CredPath
    Write-Host "Generated credentials for user '$MqttUser'." -ForegroundColor Green
    Write-Host "Stored at $CredPath (readable only by SYSTEM and Administrators)." -ForegroundColor DarkGray
}

# --- Password file ---------------------------------------------------------
if ((-not (Test-Path $PasswdPath)) -or $Force) {
    # -c creates/overwrites, -b takes the password on the command line.
    & $PasswdExe -c -b $PasswdPath $creds.mqtt_user $creds.mqtt_password
    if ($LASTEXITCODE -ne 0) { throw 'mosquitto_passwd failed to create the password file.' }
    Protect-File $PasswdPath
    Write-Host 'Password file written.' -ForegroundColor Green
}
else {
    Write-Host 'Password file already present.' -ForegroundColor Green
}

# --- Config ----------------------------------------------------------------
Copy-Item -Path $RepoConf -Destination $ConfPath -Force
Write-Host "Deployed config to $ConfPath" -ForegroundColor Green

# Validate before touching the service, so a bad config does not take the
# broker down. Mosquitto has no dedicated --test-config flag; start it in the
# foreground briefly and see whether it stays up.
$proc = Start-Process -FilePath $MosqExe -ArgumentList @('-c', "`"$ConfPath`"", '-v') `
    -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $env:TEMP 'mosq-test.err')
Start-Sleep -Seconds 2
if ($proc.HasExited) {
    $err = Get-Content (Join-Path $env:TEMP 'mosq-test.err') -Raw -ErrorAction SilentlyContinue
    throw "Mosquitto rejected the configuration file:`n$err"
}
$proc | Stop-Process -Force
Start-Sleep -Seconds 1
Write-Host 'Configuration validated.' -ForegroundColor Green

# --- Service ---------------------------------------------------------------
$svc = Get-Service -Name 'mosquitto' -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host 'Registering the Mosquitto service ...' -ForegroundColor Cyan
    & $MosqExe install
    Start-Sleep -Seconds 2
    $svc = Get-Service -Name 'mosquitto' -ErrorAction SilentlyContinue
    if (-not $svc) { throw 'Failed to register the mosquitto service.' }
}

if ($svc.Status -eq 'Running') {
    Stop-Service -Name 'mosquitto' -Force
    Write-Host 'Stopped running service for reconfiguration.'
}

# Repoint the service at our config. The stock install runs mosquitto.exe with
# the config in Program Files, which is not writable by the service account and
# would be clobbered by an upgrade.
& sc.exe config mosquitto binPath= "`"$MosqExe`" run -c `"$ConfPath`"" | Out-Null
& sc.exe config mosquitto start= auto | Out-Null
# Restart automatically on crash: 5s, 10s, then every 30s; reset counter daily.
& sc.exe failure mosquitto reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

Start-Service -Name 'mosquitto'
Start-Sleep -Seconds 2
$svc = Get-Service -Name 'mosquitto'
if ($svc.Status -ne 'Running') {
    throw "The mosquitto service did not start. Check $MosqDataDir\mosquitto.log"
}
Write-Host 'Service running and set to start automatically.' -ForegroundColor Green

# --- Firewall --------------------------------------------------------------
# Scope to the local subnet. This broker controls door locks; it has no
# business accepting connections from arbitrary hosts.
foreach ($rule in @(
    @{ Name = 'Xfinity Home - MQTT (1883)';      Port = 1883 },
    @{ Name = 'Xfinity Home - MQTT WS (9001)';   Port = 9001 }
)) {
    Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $rule.Name `
        -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $rule.Port -RemoteAddress LocalSubnet `
        -Profile Private,Domain | Out-Null
    Write-Host "Firewall: allowed TCP $($rule.Port) from the local subnet only." -ForegroundColor Green
}

# --- Verify ----------------------------------------------------------------
Write-Host ''
Write-Host 'Verifying broker with a publish/subscribe round trip ...' -ForegroundColor Cyan

$topic  = "xfinity-home/selftest/$([guid]::NewGuid().ToString('N').Substring(0,8))"
$expect = "ok-$(Get-Random)"

$subJob = Start-Job -ScriptBlock {
    param($exe, $topic, $u, $p)
    & $exe -h 127.0.0.1 -p 1883 -u $u -P $p -t $topic -C 1 -W 10
} -ArgumentList $SubExe, $topic, $creds.mqtt_user, $creds.mqtt_password

Start-Sleep -Seconds 2
& $PubExe -h 127.0.0.1 -p 1883 -u $creds.mqtt_user -P $creds.mqtt_password -t $topic -m $expect
if ($LASTEXITCODE -ne 0) {
    Remove-Job $subJob -Force -ErrorAction SilentlyContinue
    throw 'Publish failed. The broker is running but rejected the credentials.'
}

$received = (Receive-Job -Job $subJob -Wait -AutoRemoveJob) -join ''
if ($received.Trim() -ne $expect) {
    throw "Round trip failed. Expected '$expect', received '$received'."
}

Write-Host 'Broker verified: authenticated publish and subscribe both working.' -ForegroundColor Green

# --- Anonymous access must be refused --------------------------------------
& $PubExe -h 127.0.0.1 -p 1883 -t $topic -m 'anon' 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Warning 'SECURITY: the broker accepted an UNAUTHENTICATED publish. Check allow_anonymous in mosquitto.conf.'
}
else {
    Write-Host 'Anonymous access correctly refused.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Mosquitto is ready.' -ForegroundColor Green
Write-Host "  Broker    mqtt://127.0.0.1:1883"
Write-Host "  User      $($creds.mqtt_user)"
Write-Host "  Log       $MosqDataDir\mosquitto.log"
Write-Host ''
Write-Host 'Next: .\03-Setup-Zigbee2MQTT.ps1' -ForegroundColor Cyan
