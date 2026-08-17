<#
.SYNOPSIS
    Dumps the ZCL fingerprint of devices joined to Zigbee2MQTT.

.DESCRIPTION
    Reads the retained `zigbee2mqtt/bridge/devices` topic and reports each
    device's modelID, manufacturer, power source and endpoint/cluster map.

    For devices Zigbee2MQTT does not recognise, it also emits a converter
    skeleton pre-filled with the real values, ready to drop into
    external_converters\.

    This is the information you need to write a custom converter, and it is
    tedious to extract by hand from the frontend.

.PARAMETER All
    Include devices that are already supported. By default only unsupported
    devices are reported, since supported ones need no converter work.

.PARAMETER Device
    Filter to a single device by friendly name or IEEE address.

.PARAMETER Raw
    Print the raw JSON payload for the matched devices instead of the report.

.EXAMPLE
    .\Get-DeviceFingerprint.ps1
    Reports every unsupported device and prints a converter skeleton for each.

.EXAMPLE
    .\Get-DeviceFingerprint.ps1 -All
    Reports every joined device.

.NOTES
    Zigbee2MQTT must be running and connected to the broker.
#>
[CmdletBinding()]
param(
    [switch]$All,
    [string]$Device,
    [switch]$Raw
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CredPath = 'C:\ProgramData\xfinity-home\credentials.json'

# Under Set-StrictMode, reading a property that does not exist on an object
# produced by ConvertFrom-Json throws. A device that is still interviewing can
# legitimately be missing model_id, manufacturer or power_source, so every
# read of the payload goes through here.
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

function Find-MosquittoSub {
    foreach ($c in @('C:\Program Files\mosquitto', 'C:\Program Files (x86)\mosquitto')) {
        $exe = Join-Path $c 'mosquitto_sub.exe'
        if (Test-Path $exe) { return $exe }
    }
    $cmd = Get-Command 'mosquitto_sub' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$subExe = Find-MosquittoSub
if (-not $subExe) { throw 'mosquitto_sub.exe not found. Run 02-Setup-Mosquitto.ps1 first.' }
if (-not (Test-Path $CredPath)) { throw "MQTT credentials not found at $CredPath." }

$creds = Get-Content $CredPath -Raw | ConvertFrom-Json

Write-Host 'Reading zigbee2mqtt/bridge/devices ...' -ForegroundColor Cyan

# bridge/devices is published retained, so a single read returns immediately
# when Zigbee2MQTT is up. -W bounds the wait when it is not.
$json = & $subExe -h $creds.mqtt_host -p $creds.mqtt_port `
    -u $creds.mqtt_user -P $creds.mqtt_password `
    -t 'zigbee2mqtt/bridge/devices' -C 1 -W 10 2>&1

if ($LASTEXITCODE -ne 0 -or -not $json) {
    throw @"
No retained payload on zigbee2mqtt/bridge/devices.

Usually means Zigbee2MQTT is not running or has not connected to the broker.
Check that it started cleanly, then retry.
"@
}

try {
    $devices = @($json -join '' | ConvertFrom-Json)
}
catch {
    throw "Could not parse the bridge/devices payload: $_"
}

# Drop the coordinator itself - it is not a device you write converters for.
$devices = @($devices | Where-Object { (Get-Prop $_ 'type') -ne 'Coordinator' })

if ($Device) {
    $devices = @($devices | Where-Object {
        (Get-Prop $_ 'friendly_name') -eq $Device -or (Get-Prop $_ 'ieee_address') -eq $Device
    })
    if ($devices.Count -eq 0) { throw "No device matched '$Device'." }
}

if (-not $All) {
    $unsupported = @($devices | Where-Object { -not (Get-Prop $_ 'supported' $false) })
    if ($unsupported.Count -eq 0) {
        Write-Host ''
        Write-Host "All $($devices.Count) joined device(s) are already supported. No converter work needed." -ForegroundColor Green
        Write-Host 'Use -All to inspect them anyway.' -ForegroundColor DarkGray
        return
    }
    $devices = $unsupported
}

if ($Raw) {
    $devices | ConvertTo-Json -Depth 10
    return
}

foreach ($d in $devices) {
    $supported = [bool](Get-Prop $d 'supported' $false)
    $modelId   = Get-Prop $d 'model_id'   ''
    $mfr       = Get-Prop $d 'manufacturer' ''
    $endpoints = Get-Prop $d 'endpoints'

    $status = if ($supported) { 'SUPPORTED' } else { 'UNSUPPORTED' }
    $colour = if ($supported) { 'Green' } else { 'Yellow' }

    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkGray
    Write-Host ("{0}   [{1}]" -f (Get-Prop $d 'friendly_name' '(unnamed)'), $status) -ForegroundColor $colour
    Write-Host ('=' * 70) -ForegroundColor DarkGray

    Write-Host ("  IEEE address   : {0}" -f (Get-Prop $d 'ieee_address' '(unknown)'))
    Write-Host ("  modelID        : {0}" -f $(if ($modelId) { $modelId } else { '(not reported - device may still be interviewing)' }))
    Write-Host ("  manufacturer   : {0}" -f $(if ($mfr) { $mfr } else { '(not reported)' }))
    Write-Host ("  power source   : {0}" -f (Get-Prop $d 'power_source' '(unknown)'))
    Write-Host ("  device type    : {0}" -f (Get-Prop $d 'type' '(unknown)'))

    $definition = Get-Prop $d 'definition'
    if ($supported -and $definition) {
        Write-Host ("  matched as     : {0} ({1})" -f (Get-Prop $definition 'model' '?'), (Get-Prop $definition 'vendor' '?')) -ForegroundColor Green
    }

    # Trailing whitespace in modelID is real on some of this hardware and will
    # silently break an otherwise correct zigbeeModel match.
    if ($modelId -and $modelId -ne $modelId.Trim()) {
        Write-Host '  NOTE: modelID has leading/trailing whitespace. It must be reproduced exactly in zigbeeModel.' -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '  Endpoints and clusters:'

    $endpointIds = @()
    if ($endpoints) {
        foreach ($prop in $endpoints.PSObject.Properties) {
            $endpointIds += $prop.Name
            $ep = $prop.Value
            Write-Host ("    endpoint {0}" -f $prop.Name) -ForegroundColor Cyan

            $clusters = Get-Prop $ep 'clusters'
            $inputs   = @(Get-Prop $clusters 'input'  @())
            $outputs  = @(Get-Prop $clusters 'output' @())

            Write-Host ("      input  : {0}" -f $(if ($inputs.Count)  { $inputs -join ', ' }  else { '(none)' }))
            Write-Host ("      output : {0}" -f $(if ($outputs.Count) { $outputs -join ', ' } else { '(none)' }))

            $bindings = @(Get-Prop $ep 'bindings' @())
            if ($bindings.Count -gt 0) {
                $b = @($bindings | ForEach-Object { Get-Prop $_ 'cluster' '?' })
                Write-Host ("      bound  : {0}" -f ($b -join ', ')) -ForegroundColor DarkGray
            }
            else {
                Write-Host '      bound  : (nothing) - configure has not run or it failed' -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host '    (no endpoint data - the device has not completed its interview)' -ForegroundColor Yellow
    }

    if ($supported) { continue }

    # --- Converter skeleton for unsupported devices -------------------------
    if (-not $modelId) {
        Write-Host ''
        Write-Host '  No modelID reported yet, so no skeleton can be generated.' -ForegroundColor Yellow
        Write-Host '  Wake the device and let the interview finish, then re-run.' -ForegroundColor Yellow
        continue
    }

    $firstEp = if ($endpointIds.Count) { $endpointIds[0] } else { '1' }
    $inputs  = @()
    if ($endpoints -and $endpoints.PSObject.Properties[$firstEp]) {
        $firstClusters = Get-Prop $endpoints.PSObject.Properties[$firstEp].Value 'clusters'
        $inputs = @(Get-Prop $firstClusters 'input' @())
    }

    $hasIas   = $inputs -contains 'ssIasZone'
    $hasPower = $inputs -contains 'genPowerCfg'
    $hasTemp  = $inputs -contains 'msTemperatureMeasurement'

    $fzList   = @()
    $exposes  = @()
    $bindList = @()

    if ($hasIas) {
        # Guess the alarm type from the device's own descriptor where possible.
        $fzList  += 'fz.ias_contact_alarm_1'
        $exposes += 'e.contact()', 'e.battery_low()', 'e.tamper()'
    }
    if ($hasTemp) {
        $fzList  += 'fz.temperature'
        $exposes += 'e.temperature()'
        $bindList += "'msTemperatureMeasurement'"
    }
    if ($hasPower) {
        $fzList  += 'fz.battery'
        $exposes += 'e.battery()'
        $bindList += "'genPowerCfg'"
    }

    $safeName = ($modelId -replace '[^A-Za-z0-9_-]', '-').ToLower()

    Write-Host ''
    Write-Host "  Converter skeleton  ->  external_converters\$safeName.mjs" -ForegroundColor Green
    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray

    $skeleton = @"
import * as fz from 'zigbee-herdsman-converters/converters/fromZigbee';
import * as exposes from 'zigbee-herdsman-converters/lib/exposes';
import * as reporting from 'zigbee-herdsman-converters/lib/reporting';

const e = exposes.presets;

export default {
    zigbeeModel: ['$modelId'],
    model: '$modelId',
    vendor: '$mfr',
    description: 'Ex-Xfinity device (generated skeleton - review before use)',
    fromZigbee: [$($fzList -join ', ')],
    toZigbee: [],
    meta: {battery: {voltageToPercentage: '3V_2100'}},
    configure: async (device, coordinatorEndpoint) => {
        const endpoint = device.getEndpoint($firstEp);
        await reporting.bind(endpoint, coordinatorEndpoint, [$($bindList -join ', ')]);$(if ($hasTemp) { "`n        await reporting.temperature(endpoint);" })$(if ($hasPower) { "`n        await reporting.batteryVoltage(endpoint);" })
    },
    exposes: [$($exposes -join ', ')],
};
"@

    Write-Host $skeleton

    Write-Host ('  ' + ('-' * 66)) -ForegroundColor DarkGray
    Write-Host '  Review before deploying:' -ForegroundColor Yellow
    if ($hasIas) {
        Write-Host '   - fz.ias_contact_alarm_1 was assumed. For a motion sensor use'
        Write-Host '     fz.ias_occupancy_alarm_1 and swap e.contact() for e.occupancy().'
        Write-Host '     For water use fz.ias_water_leak_alarm_1 / e.water_leak().'
    }
    if ($hasPower) {
        Write-Host '   - The 3V_2100 battery curve is a starting assumption. If the battery'
        Write-Host '     reads about half of reality, use {dontDividePercentage: true} instead.'
    }
    Write-Host '   - Drop any cluster from reporting.bind() that the device does not list'
    Write-Host '     above, or configure will fail as a whole.'
}

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkGray
Write-Host "Reported $($devices.Count) device(s)." -ForegroundColor Cyan
Write-Host 'After adding a converter: restart Zigbee2MQTT, then Reconfigure the device'
Write-Host 'from the frontend while it is awake.'
