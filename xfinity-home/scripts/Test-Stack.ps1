<#
.SYNOPSIS
    End-to-end health check of the local smart home control plane.

.DESCRIPTION
    Answers "is this actually working" in one command, across all four
    services. Checks prerequisites, the broker and its authentication, serial
    port ownership, and each bridge's live state as reported over MQTT rather
    than merely whether its process is running - a Zigbee2MQTT task that is
    "Running" while its coordinator is unplugged is not a healthy stack.

    Exits non-zero if any check fails, so it can be used as a smoke test.

.PARAMETER Quick
    Skip the MQTT round-trip checks. Faster, but only confirms that processes
    exist rather than that they work.

.EXAMPLE
    .\Test-Stack.ps1

.NOTES
    Does not require Administrator, but a few checks report more detail when
    elevated.
#>
[CmdletBinding()]
param(
    [switch]$Quick
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$DataRoot = 'C:\ProgramData\xfinity-home'
$CredPath = Join-Path $DataRoot 'credentials.json'
$Z2MPath  = 'C:\zigbee2mqtt'

$script:Results = @()

function Add-Result {
    param(
        [string]$Component,
        [string]$Check,
        [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP')][string]$Status,
        [string]$Detail = ''
    )
    $script:Results += [pscustomobject]@{
        Component = $Component; Check = $Check; Status = $Status; Detail = $Detail
    }
}

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $Default
}

function Find-MosquittoTool([string]$name) {
    foreach ($c in @('C:\Program Files\mosquitto', 'C:\Program Files (x86)\mosquitto')) {
        $exe = Join-Path $c "$name.exe"
        if (Test-Path $exe) { return $exe }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-RetainedTopic {
    param([string]$Topic, $Creds, [int]$WaitSeconds = 5)
    $sub = Find-MosquittoTool 'mosquitto_sub'
    if (-not $sub) { return $null }
    $out = & $sub -h $Creds.mqtt_host -p $Creds.mqtt_port `
        -u $Creds.mqtt_user -P $Creds.mqtt_password `
        -t $Topic -C 1 -W $WaitSeconds 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    return ($out -join '')
}

function Test-TaskState([string]$TaskName) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return $null }
    return $t.State
}

Write-Host ''
Write-Host 'Smart home control plane - health check' -ForegroundColor Cyan
Write-Host '=======================================' -ForegroundColor DarkGray

# ===========================================================================
# Prerequisites
# ===========================================================================
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $v = (node --version) -replace '^v', ''
    $major = [int]($v -split '\.')[0]
    if (@(22, 24, 26) -contains $major) {
        Add-Result 'Prereq' 'Node.js version' 'PASS' "v$v"
    }
    else {
        Add-Result 'Prereq' 'Node.js version' 'FAIL' "v$v - Zigbee2MQTT needs major 22, 24 or 26"
    }
}
else {
    Add-Result 'Prereq' 'Node.js present' 'FAIL' 'not on PATH'
}

if (Get-Command git -ErrorAction SilentlyContinue) {
    Add-Result 'Prereq' 'Git present' 'PASS' ''
}
else {
    # Not fatal, but Zigbee2MQTT rebuilds on every start without it.
    Add-Result 'Prereq' 'Git present' 'WARN' 'absent - Zigbee2MQTT will rebuild its TypeScript on every start'
}

# ===========================================================================
# Credentials
# ===========================================================================
$creds = $null
if (Test-Path $CredPath) {
    try {
        $creds = Get-Content $CredPath -Raw | ConvertFrom-Json
        Add-Result 'Broker' 'Credential store' 'PASS' "user '$(Get-Prop $creds 'mqtt_user' '?')'"
    }
    catch {
        Add-Result 'Broker' 'Credential store' 'FAIL' "unreadable: $_"
    }
}
else {
    Add-Result 'Broker' 'Credential store' 'FAIL' "missing - run 02-Setup-Mosquitto.ps1"
}

# ===========================================================================
# Mosquitto
# ===========================================================================
$svc = Get-Service -Name 'mosquitto' -ErrorAction SilentlyContinue
if (-not $svc) {
    Add-Result 'Broker' 'Service registered' 'FAIL' 'mosquitto service not found'
}
elseif ($svc.Status -ne 'Running') {
    Add-Result 'Broker' 'Service running' 'FAIL' "state: $($svc.Status)"
}
else {
    Add-Result 'Broker' 'Service running' 'PASS' ''
}

if (-not $Quick -and $creds -and $svc -and $svc.Status -eq 'Running') {
    $pub = Find-MosquittoTool 'mosquitto_pub'
    $sub = Find-MosquittoTool 'mosquitto_sub'

    if ($pub -and $sub) {
        $topic  = "xfinity-home/healthcheck/$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $expect = "ok-$(Get-Random)"

        $job = Start-Job -ScriptBlock {
            param($exe, $topic, $u, $p, $h, $port)
            & $exe -h $h -p $port -u $u -P $p -t $topic -C 1 -W 8
        } -ArgumentList $sub, $topic, $creds.mqtt_user, $creds.mqtt_password, $creds.mqtt_host, $creds.mqtt_port

        Start-Sleep -Seconds 2
        & $pub -h $creds.mqtt_host -p $creds.mqtt_port `
            -u $creds.mqtt_user -P $creds.mqtt_password -t $topic -m $expect 2>$null
        $got = (Receive-Job -Job $job -Wait -AutoRemoveJob) -join ''

        if ($got.Trim() -eq $expect) {
            Add-Result 'Broker' 'Authenticated round trip' 'PASS' ''
        }
        else {
            Add-Result 'Broker' 'Authenticated round trip' 'FAIL' 'publish/subscribe did not complete'
        }

        # Anonymous access must be refused. This is a security regression check,
        # not a connectivity check.
        & $pub -h $creds.mqtt_host -p $creds.mqtt_port -t $topic -m 'anon' 2>$null
        if ($LASTEXITCODE -eq 0) {
            Add-Result 'Broker' 'Anonymous refused' 'FAIL' 'SECURITY: broker accepted an unauthenticated publish'
        }
        else {
            Add-Result 'Broker' 'Anonymous refused' 'PASS' ''
        }
    }
    else {
        Add-Result 'Broker' 'Round trip' 'SKIP' 'mosquitto_pub/sub not found'
    }
}
elseif ($Quick) {
    Add-Result 'Broker' 'Round trip' 'SKIP' '-Quick'
}

# ===========================================================================
# Serial ports
# ===========================================================================
$configPort = $null
$z2mConfig = Join-Path $Z2MPath 'data\configuration.yaml'
if (Test-Path $z2mConfig) {
    $raw = Get-Content $z2mConfig -Raw
    # Match the port under the serial: block specifically.
    if ($raw -match '(?ms)^serial:\s*.*?^\s+port:\s*[''"]?(COM\d+)[''"]?') {
        $configPort = $Matches[1]
    }
}

$presentPorts = @()
try {
    $presentPorts = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
        Where-Object { $_.Name -and $_.Name -match '\(COM\d+\)' } |
        ForEach-Object { if ($_.Name -match '\((COM\d+)\)') { $Matches[1] } })
}
catch { }

if ($configPort) {
    if ($presentPorts -contains $configPort) {
        Add-Result 'Serial' 'Zigbee port present' 'PASS' "$configPort"
    }
    else {
        Add-Result 'Serial' 'Zigbee port present' 'FAIL' `
            "configuration.yaml points at $configPort, which is not attached. Present: $($presentPorts -join ', ')"
    }
}
else {
    Add-Result 'Serial' 'Zigbee port configured' 'WARN' 'could not read serial.port from configuration.yaml'
}

if ($presentPorts.Count -eq 0) {
    Add-Result 'Serial' 'Any coordinator attached' 'FAIL' 'no COM ports found at all'
}

# ===========================================================================
# Zigbee2MQTT
# ===========================================================================
$z2mState = Test-TaskState 'Zigbee2MQTT'
if ($null -eq $z2mState) {
    Add-Result 'Zigbee2MQTT' 'Startup task' 'WARN' 'not registered - will not survive a reboot'
}
else {
    Add-Result 'Zigbee2MQTT' 'Startup task' 'PASS' "state: $z2mState"
}

if (-not $Quick -and $creds) {
    $stateRaw = Get-RetainedTopic 'zigbee2mqtt/bridge/state' $creds
    if (-not $stateRaw) {
        Add-Result 'Zigbee2MQTT' 'Bridge online' 'FAIL' 'no retained bridge/state - not running or not connected to the broker'
    }
    else {
        # 2.x publishes {"state":"online"}; 1.x published a bare "online".
        $onlineState = $stateRaw.Trim()
        try {
            $parsed = $stateRaw | ConvertFrom-Json
            $onlineState = Get-Prop $parsed 'state' $onlineState
        }
        catch { }

        if ($onlineState -eq 'online') {
            Add-Result 'Zigbee2MQTT' 'Bridge online' 'PASS' ''
        }
        else {
            Add-Result 'Zigbee2MQTT' 'Bridge online' 'FAIL' "state: $onlineState"
        }
    }

    $infoRaw = Get-RetainedTopic 'zigbee2mqtt/bridge/info' $creds
    if ($infoRaw) {
        try {
            $info = $infoRaw | ConvertFrom-Json
            $ver  = Get-Prop $info 'version' '?'
            Add-Result 'Zigbee2MQTT' 'Version' 'PASS' "$ver"

            $coord = Get-Prop $info 'coordinator'
            if ($coord) {
                $ct = Get-Prop $coord 'type' '?'
                Add-Result 'Zigbee2MQTT' 'Coordinator' 'PASS' "$ct"
            }
            else {
                Add-Result 'Zigbee2MQTT' 'Coordinator' 'FAIL' 'no coordinator reported - the radio did not come up'
            }

            $permit = Get-Prop $info 'permit_join' $false
            if ($permit) {
                Add-Result 'Zigbee2MQTT' 'Permit join closed' 'WARN' 'permit_join is OPEN - close it once pairing is done'
            }
            else {
                Add-Result 'Zigbee2MQTT' 'Permit join closed' 'PASS' ''
            }
        }
        catch {
            Add-Result 'Zigbee2MQTT' 'Bridge info' 'WARN' 'unparseable payload'
        }
    }

    $devRaw = Get-RetainedTopic 'zigbee2mqtt/bridge/devices' $creds
    if ($devRaw) {
        try {
            $devs = @($devRaw | ConvertFrom-Json | Where-Object { (Get-Prop $_ 'type') -ne 'Coordinator' })
            $unsupported = @($devs | Where-Object { -not (Get-Prop $_ 'supported' $false) })

            Add-Result 'Zigbee2MQTT' 'Devices joined' 'PASS' "$($devs.Count)"

            if ($unsupported.Count -gt 0) {
                $names = ($unsupported | ForEach-Object { Get-Prop $_ 'model_id' '(no modelID)' }) -join ', '
                Add-Result 'Zigbee2MQTT' 'All devices supported' 'WARN' `
                    "$($unsupported.Count) unsupported: $names - run Get-DeviceFingerprint.ps1"
            }
            elseif ($devs.Count -gt 0) {
                Add-Result 'Zigbee2MQTT' 'All devices supported' 'PASS' ''
            }
        }
        catch {
            Add-Result 'Zigbee2MQTT' 'Device list' 'WARN' 'unparseable payload'
        }
    }
}

# ===========================================================================
# Z-Wave JS UI
# ===========================================================================
$zwState = Test-TaskState 'ZWaveJSUI'
if ($null -eq $zwState) {
    Add-Result 'Z-Wave JS' 'Startup task' 'WARN' 'not registered'
}
else {
    Add-Result 'Z-Wave JS' 'Startup task' 'PASS' "state: $zwState"
}

$zwListening = $null -ne (Get-NetTCPConnection -State Listen -LocalPort 8091 -ErrorAction SilentlyContinue)
if ($zwListening) {
    Add-Result 'Z-Wave JS' 'UI listening (8091)' 'PASS' ''
}
else {
    Add-Result 'Z-Wave JS' 'UI listening (8091)' 'WARN' 'nothing listening on 8091'
}

if (Test-Path (Join-Path $DataRoot 'zwave-keys.json')) {
    Add-Result 'Z-Wave JS' 'Security keys generated' 'PASS' 'back this file up off-machine'
}
else {
    Add-Result 'Z-Wave JS' 'Security keys generated' 'WARN' 'no key file - do not include the lock until keys exist'
}

# ===========================================================================
# go2rtc
# ===========================================================================
$g2State = Test-TaskState 'go2rtc'
if ($null -eq $g2State) {
    Add-Result 'go2rtc' 'Startup task' 'WARN' 'not registered'
}
else {
    Add-Result 'go2rtc' 'Startup task' 'PASS' "state: $g2State"
}

try {
    $streams = Invoke-RestMethod -Uri 'http://127.0.0.1:1984/api/streams' -TimeoutSec 5 -ErrorAction Stop
    $names = @($streams.PSObject.Properties.Name)
    if ($names.Count -eq 0) {
        Add-Result 'go2rtc' 'Streams configured' 'WARN' 'API up, but no streams defined yet'
    }
    else {
        Add-Result 'go2rtc' 'Streams configured' 'PASS' "$($names.Count): $($names -join ', ')"
    }
}
catch {
    Add-Result 'go2rtc' 'API responding' 'WARN' 'not reachable on 127.0.0.1:1984'
}

# ===========================================================================
# Report
# ===========================================================================
Write-Host ''
foreach ($group in ($script:Results | Group-Object Component)) {
    Write-Host $group.Name -ForegroundColor Cyan
    foreach ($r in $group.Group) {
        $colour = switch ($r.Status) {
            'PASS' { 'Green' }; 'FAIL' { 'Red' }; 'WARN' { 'Yellow' }; default { 'DarkGray' }
        }
        $line = "  [{0}] {1}" -f $r.Status, $r.Check
        if ($r.Detail) { $line += "  -  $($r.Detail)" }
        Write-Host $line -ForegroundColor $colour
    }
    Write-Host ''
}

$fails = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
$warns = @($script:Results | Where-Object { $_.Status -eq 'WARN' })

Write-Host ('=' * 55) -ForegroundColor DarkGray
Write-Host ("{0} passed, {1} failed, {2} warnings" -f `
    @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count, $fails.Count, $warns.Count)

if ($fails.Count -gt 0) {
    Write-Host ''
    Write-Host 'Failures:' -ForegroundColor Red
    foreach ($f in $fails) { Write-Host ("  {0} / {1}: {2}" -f $f.Component, $f.Check, $f.Detail) }
    Write-Host ''
    Write-Host 'See docs\troubleshooting.md' -ForegroundColor Cyan
    exit 1
}

Write-Host 'Stack healthy.' -ForegroundColor Green
exit 0
