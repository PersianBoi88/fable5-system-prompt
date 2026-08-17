<#
.SYNOPSIS
    Discovers the Z-Wave MQTT topic tree and identifies the lock's topics.

.DESCRIPTION
    Z-Wave JS UI's topic layout is not fixed - it depends on whether you chose
    named topics or ValueID topics, on the node's name and location, and on the
    gateway type. So the dashboard cannot hardcode the lock's topics; they have
    to be observed.

    This subscribes to the Z-Wave prefix for a window, collects every topic that
    reports, highlights the ones that look like door lock state and command
    points, and emits the JSON block to paste into dashboard.json.

.PARAMETER Seconds
    How long to listen. Default 20. Z-Wave nodes report on change, so operate
    the lock by hand during the capture to make its topics appear.

.PARAMETER Prefix
    MQTT topic prefix configured in Z-Wave JS UI. Default: zwave

.PARAMETER All
    Print every topic seen, not just the lock-related ones.

.EXAMPLE
    .\Get-ZWaveTopics.ps1 -Seconds 30
    Listens for 30s. Lock and unlock the door by hand during that window.

.NOTES
    Z-Wave JS UI must be running and connected to the broker.
#>
[CmdletBinding()]
param(
    [int]$Seconds = 20,
    [string]$Prefix = 'zwave',
    [switch]$All
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CredPath = 'C:\ProgramData\xfinity-home\credentials.json'

function Find-MosquittoSub {
    foreach ($c in @('C:\Program Files\mosquitto', 'C:\Program Files (x86)\mosquitto')) {
        $exe = Join-Path $c 'mosquitto_sub.exe'
        if (Test-Path $exe) { return $exe }
    }
    $cmd = Get-Command 'mosquitto_sub' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$sub = Find-MosquittoSub
if (-not $sub) { throw 'mosquitto_sub.exe not found. Run 02-Setup-Mosquitto.ps1 first.' }
if (-not (Test-Path $CredPath)) { throw "MQTT credentials not found at $CredPath." }

$creds = Get-Content $CredPath -Raw | ConvertFrom-Json

Write-Host ''
Write-Host "Listening on $Prefix/# for $Seconds seconds" -ForegroundColor Cyan
Write-Host '------------------------------------------' -ForegroundColor DarkGray
Write-Host 'Z-Wave nodes report on change, so the lock stays invisible until it moves.' -ForegroundColor Yellow
Write-Host 'LOCK AND UNLOCK THE DOOR BY HAND NOW, while this is running.' -ForegroundColor Yellow
Write-Host ''

# -v prints "topic payload" per line.
$lines = & $sub -h $creds.mqtt_host -p $creds.mqtt_port `
    -u $creds.mqtt_user -P $creds.mqtt_password `
    -t "$Prefix/#" -v -W $Seconds 2>$null

if (-not $lines) {
    throw @"
Nothing published on $Prefix/# during the capture window.

Check that:
  - Z-Wave JS UI is running and its MQTT settings point at 127.0.0.1:1883
  - the MQTT prefix in Z-Wave JS UI actually is '$Prefix'
  - the lock is included and responding
"@
}

# Collapse to latest value per topic.
$seen = [ordered]@{}
foreach ($line in $lines) {
    $idx = $line.IndexOf(' ')
    if ($idx -lt 1) { continue }
    $topic = $line.Substring(0, $idx)
    $value = $line.Substring($idx + 1)
    $seen[$topic] = $value
}

Write-Host ("Captured {0} distinct topic(s)." -f $seen.Count) -ForegroundColor Green
Write-Host ''

# --- Classify --------------------------------------------------------------
# Door Lock CC is 0x62 (98). Named-topic mode spells it out; ValueID mode uses
# the numeric class. Match both, plus the mode properties that carry state.
$lockPattern    = '(?i)(door_?lock|doorlock|/98/|currentMode|targetMode|boltStatus|latchStatus|locked)'
$statePattern   = '(?i)(currentMode|boltStatus|locked|latchStatus)'
$commandPattern = '(?i)(targetMode|/set$)'

$lockTopics = @($seen.Keys | Where-Object { $_ -match $lockPattern })

if ($lockTopics.Count -eq 0) {
    Write-Host 'No lock-like topics found.' -ForegroundColor Yellow
    Write-Host 'The lock may not have reported during the window. Re-run with a longer' -ForegroundColor Yellow
    Write-Host '-Seconds and operate the deadbolt by hand while it captures.' -ForegroundColor Yellow
    Write-Host ''
    $All = $true
}
else {
    Write-Host 'Lock-related topics:' -ForegroundColor Green
    foreach ($t in $lockTopics) {
        $kind = if ($t -match $commandPattern) { 'COMMAND?' }
                elseif ($t -match $statePattern) { 'STATE?  ' }
                else { '        ' }
        $colour = if ($kind.Trim()) { 'Cyan' } else { 'Gray' }
        Write-Host ("  {0}  {1}" -f $kind, $t) -ForegroundColor $colour
        Write-Host ("            = {0}" -f $seen[$t]) -ForegroundColor DarkGray
    }
    Write-Host ''
}

if ($All) {
    Write-Host 'All topics:' -ForegroundColor Cyan
    foreach ($t in $seen.Keys) {
        Write-Host ("  {0}" -f $t)
        Write-Host ("      = {0}" -f $seen[$t]) -ForegroundColor DarkGray
    }
    Write-Host ''
}

# --- Emit config block -----------------------------------------------------
$stateGuess   = @($lockTopics | Where-Object { $_ -match $statePattern -and $_ -notmatch '/set$' }) | Select-Object -First 1
$commandGuess = @($lockTopics | Where-Object { $_ -match 'targetMode' }) | Select-Object -First 1

if ($commandGuess -and $commandGuess -notmatch '/set$') {
    # Z-Wave JS UI accepts writes on <valueTopic>/set.
    $commandGuess = "$commandGuess/set"
}

Write-Host 'Paste into C:\ProgramData\xfinity-home\dashboard.json' -ForegroundColor Green
Write-Host ('-' * 60) -ForegroundColor DarkGray

$block = [ordered]@{
    name          = 'Front door'
    stateTopic    = if ($stateGuess)   { $stateGuess }   else { 'REPLACE - see STATE? lines above' }
    commandTopic  = if ($commandGuess) { $commandGuess } else { 'REPLACE - see COMMAND? lines above' }
    lockPayload   = '255'
    unlockPayload = '0'
}

Write-Host ('"lock": ' + (($block | ConvertTo-Json) -replace '^', '  ').Trim())

Write-Host ('-' * 60) -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Verify the payload values before trusting them.' -ForegroundColor Yellow
Write-Host 'Door Lock CC uses 255 for secured and 0 for unsecured, but Z-Wave JS UI'
Write-Host 'can be configured to publish booleans or label strings instead. Look at'
Write-Host 'what the STATE topic above actually printed when you turned the deadbolt:'
Write-Host '  255 / 0        -> keep lockPayload "255", unlockPayload "0"'
Write-Host '  true / false   -> use "true" / "false"'
Write-Host ''
Write-Host 'Then restart the dashboard and confirm the tile tracks the physical bolt' -ForegroundColor Cyan
Write-Host 'BEFORE relying on the remote unlock button.' -ForegroundColor Cyan
