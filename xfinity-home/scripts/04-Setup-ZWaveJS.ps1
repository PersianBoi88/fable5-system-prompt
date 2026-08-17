<#
.SYNOPSIS
    Deploys Z-Wave JS UI and provisions Z-Wave security keys for the smart lock.

.DESCRIPTION
    Downloads the current Z-Wave JS UI Windows build, registers it to run at
    boot, and generates the four Z-Wave network security keys.

    THE SECURITY KEYS MATTER MORE THAN ANYTHING ELSE IN THIS SCRIPT.

    Z-Wave door locks refuse to operate over an unencrypted association. If the
    lock is included before the keys exist in Z-Wave JS, it joins the network
    unencrypted, reports itself as a lock, and then silently rejects every
    lock/unlock command. The fix is a full exclude and re-include - there is no
    way to add security to an existing insecure association. So the keys are
    generated and installed here, before the lock is ever paired.

.PARAMETER InstallPath
    Install directory. Default C:\zwave-js-ui

.PARAMETER Force
    Regenerate security keys even if they already exist.
    WARNING: this orphans every already-included secure device.

.NOTES
    Run as Administrator. Run 01 and 02 first.
#>
[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\zwave-js-ui',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DataRoot  = 'C:\ProgramData\xfinity-home'
$CredPath  = Join-Path $DataRoot 'credentials.json'
$KeyPath   = Join-Path $DataRoot 'zwave-keys.json'
$TaskName  = 'ZWaveJSUI'
$ReleaseApi= 'https://api.github.com/repos/zwave-js/zwave-js-ui/releases/latest'

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

function New-ZWaveKey {
    # A Z-Wave network key is 16 random bytes rendered as 32 hex characters.
    $bytes = [byte[]]::new(16)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    (-join ($bytes | ForEach-Object { $_.ToString('X2') }))
}

function Protect-File($path) {
    & icacls $path /inheritance:r /grant:r 'SYSTEM:(F)' 'BUILTIN\Administrators:(F)' | Out-Null
}

Assert-Administrator

Write-Host ''
Write-Host 'Z-Wave JS UI deployment' -ForegroundColor Cyan
Write-Host '-----------------------' -ForegroundColor DarkGray

if (-not (Test-Path $CredPath)) {
    throw "MQTT credentials not found at $CredPath. Run 02-Setup-Mosquitto.ps1 first."
}
$creds = Get-Content $CredPath -Raw | ConvertFrom-Json

# --- Security keys ---------------------------------------------------------
if ((Test-Path $KeyPath) -and -not $Force) {
    $keys = Get-Content $KeyPath -Raw | ConvertFrom-Json
    Write-Host 'Reusing existing Z-Wave security keys.' -ForegroundColor Green
}
else {
    if ((Test-Path $KeyPath) -and $Force) {
        Write-Warning 'Regenerating security keys. Every already-included secure device will need to be excluded and re-included.'
    }
    $keys = [pscustomobject]@{
        S0_Legacy           = New-ZWaveKey
        S2_Unauthenticated  = New-ZWaveKey
        S2_Authenticated    = New-ZWaveKey
        S2_AccessControl    = New-ZWaveKey
        generated_at        = (Get-Date).ToString('o')
    }
    $keys | ConvertTo-Json | Set-Content -Path $KeyPath -Encoding UTF8
    Protect-File $KeyPath
    Write-Host 'Generated four Z-Wave security keys.' -ForegroundColor Green
}

# --- Download --------------------------------------------------------------
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

$exePath = Join-Path $InstallPath 'zwave-js-ui.exe'

if (Test-Path $exePath) {
    Write-Host "Z-Wave JS UI already present at $exePath" -ForegroundColor Green
}
else {
    Write-Host 'Resolving the latest Z-Wave JS UI release ...' -ForegroundColor Cyan

    # TLS 1.2 is not the default on stock PowerShell 5.1 and GitHub requires it.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $release = Invoke-RestMethod -Uri $ReleaseApi -Headers @{ 'User-Agent' = 'xfinity-home-setup' }
    }
    catch {
        throw @"
Could not query the GitHub releases API: $_

Download the Windows build manually from
    https://github.com/zwave-js/zwave-js-ui/releases/latest
extract zwave-js-ui.exe to $InstallPath and re-run this script.
"@
    }

    # Asset naming has changed across releases; match rather than hardcode.
    $asset = $release.assets |
        Where-Object { $_.name -match 'win' -and $_.name -match '(x64|amd64)' } |
        Sort-Object { $_.name -match '\.zip$' } -Descending |
        Select-Object -First 1

    if (-not $asset) {
        $names = ($release.assets | ForEach-Object { $_.name }) -join "`n  "
        throw @"
No Windows x64 asset found in release $($release.tag_name).

Assets present:
  $names

Download the correct one manually to $InstallPath and re-run.
"@
    }

    Write-Host "Downloading $($asset.name) ($($release.tag_name)) ..." -ForegroundColor Cyan
    $tmp = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing

    if ($asset.name -match '\.zip$') {
        Expand-Archive -Path $tmp -DestinationPath $InstallPath -Force
        # The binary may land in a nested folder depending on how the archive
        # was built; normalise it to the install root.
        if (-not (Test-Path $exePath)) {
            $found = Get-ChildItem -Path $InstallPath -Filter 'zwave-js-ui*.exe' -Recurse |
                Select-Object -First 1
            if (-not $found) { throw 'Archive extracted but no zwave-js-ui executable was found inside it.' }
            Move-Item $found.FullName $exePath -Force
        }
    }
    else {
        Move-Item $tmp $exePath -Force
    }

    Remove-Item $tmp -ErrorAction SilentlyContinue
    Write-Host 'Downloaded.' -ForegroundColor Green
}

# --- Startup task ----------------------------------------------------------
Write-Host 'Registering startup task ...' -ForegroundColor Cyan

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $exePath -WorkingDirectory $InstallPath
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Z-Wave JS UI - local Z-Wave to MQTT bridge' | Out-Null

Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green

# --- Firewall --------------------------------------------------------------
Remove-NetFirewallRule -DisplayName 'Xfinity Home - Z-Wave JS UI (8091)' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'Xfinity Home - Z-Wave JS UI (8091)' `
    -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort 8091 -RemoteAddress LocalSubnet -Profile Private,Domain | Out-Null

# --- Hand-off --------------------------------------------------------------
$zwavePort = 'COM?'
try {
    $finder = Join-Path $PSScriptRoot 'Find-Coordinators.ps1'
    $found  = @(& $finder -Json | ConvertFrom-Json) | Where-Object { $_.Radio -eq 'Z-Wave' }
    if ($found.Count -eq 1) { $zwavePort = $found[0].Port }
}
catch { }

Write-Host ''
Write-Host 'Z-Wave JS UI deployed.' -ForegroundColor Green
Write-Host ''
Write-Host 'Start it:' -ForegroundColor Cyan
Write-Host "    Start-ScheduledTask -TaskName $TaskName"
Write-Host '    then open http://127.0.0.1:8091'
Write-Host ''
Write-Host 'CONFIGURE THESE BEFORE INCLUDING THE LOCK' -ForegroundColor Yellow
Write-Host '=========================================' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Settings > Z-Wave' -ForegroundColor Cyan
Write-Host "  Serial Port : $zwavePort"
if ($zwavePort -eq 'COM?') {
    Write-Host '                (not autodetected - run .\Find-Coordinators.ps1 -Watch)' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  Security Keys - paste each of these into the matching field:' -ForegroundColor Cyan
Write-Host ("    S0 Legacy          : {0}" -f $keys.S0_Legacy)
Write-Host ("    S2 Unauthenticated : {0}" -f $keys.S2_Unauthenticated)
Write-Host ("    S2 Authenticated   : {0}" -f $keys.S2_Authenticated)
Write-Host ("    S2 Access Control  : {0}" -f $keys.S2_AccessControl)
Write-Host ''
Write-Host "  (also saved to $KeyPath)" -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Settings > MQTT' -ForegroundColor Cyan
Write-Host "  Host     : mqtt://127.0.0.1"
Write-Host "  Port     : 1883"
Write-Host "  Username : $($creds.mqtt_user)"
Write-Host "  Password : $($creds.mqtt_password)"
Write-Host "  Prefix   : zwave"
Write-Host ''
Write-Host 'The Kwikset Convert 914C is a door lock and MUST be included securely.' -ForegroundColor Yellow
Write-Host 'Save the security keys and restart Z-Wave JS UI BEFORE running inclusion.' -ForegroundColor Yellow
Write-Host 'A lock included without keys will pair, appear healthy, and then ignore' -ForegroundColor Yellow
Write-Host 'every lock/unlock command - recoverable only by excluding and re-including.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Next: .\05-Setup-Cameras.ps1' -ForegroundColor Cyan
