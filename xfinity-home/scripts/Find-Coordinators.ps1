<#
.SYNOPSIS
    Enumerates USB serial devices and identifies Zigbee / Z-Wave coordinators.

.DESCRIPTION
    Replaces hand-reading Device Manager. Lists every COM port with its
    USB VID/PID, annotates ports that match known coordinator hardware, and
    emits ready-to-paste configuration snippets for Zigbee2MQTT and Z-Wave JS UI.

    The VID/PID table is an *annotation* layer, not an oracle. Several vendors
    ship the same USB-serial bridge chip (notably Silicon Labs CP210x,
    VID_10C4&PID_EA60, which is used by both Zigbee and Z-Wave sticks), so a
    match narrows the field rather than proving identity. Use -Watch for a
    definitive answer.

.PARAMETER Watch
    Differential identification. Takes a snapshot, waits for you to unplug a
    single adapter, then reports exactly which COM port vanished. This is the
    only fully reliable way to map a physical stick to a port number.

.PARAMETER Json
    Emit machine-readable JSON instead of the formatted report.

.EXAMPLE
    .\Find-Coordinators.ps1
    Lists all serial ports with best-guess coordinator identification.

.EXAMPLE
    .\Find-Coordinators.ps1 -Watch
    Interactively identifies one adapter by unplug detection.

.NOTES
    Requires PowerShell 5.1+. Does not require Administrator.
#>
[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Known coordinator hardware.
#
# 'Stack' maps to the Zigbee2MQTT `serial.adapter` value where applicable:
#   ember   -> Silicon Labs EmberZNet (EFR32)
#   zstack  -> Texas Instruments Z-Stack (CC253x / CC26x2 / CC1352)
#   deconz  -> dresden elektronik ConBee / RaspBee
#   zboss   -> Nordic ZBOSS
# Z-Wave sticks have no adapter setting; Z-Wave JS just needs the port path.
# ---------------------------------------------------------------------------
$KnownDevices = @(
    [pscustomobject]@{
        Vid = '10C4'; Pid = '8A2A'
        Name        = 'Nortek / GoControl HUSBZB-1 (dual radio)'
        Radio       = 'Both'
        Stack       = 'ember'
        Baudrate    = 57600
        Note        = 'Presents TWO COM ports from one USB stick. The LOWER-numbered port is normally the Zigbee (EM357) radio, the HIGHER-numbered port the Z-Wave (500-series) radio. Verify before trusting this ordering.'
    }
    [pscustomobject]@{
        Vid = '1A86'; Pid = '55D4'
        Name        = 'Sonoff ZBDongle-E (EFR32MG21) or similar CH9102/CH343 device'
        Radio       = 'Zigbee'
        Stack       = 'ember'
        Baudrate    = 115200
        Note        = 'Requires the CH9102/CH343 driver on older Windows builds.'
    }
    [pscustomobject]@{
        Vid = '1CF1'; Pid = '0030'
        Name        = 'dresden elektronik ConBee II'
        Radio       = 'Zigbee'
        Stack       = 'deconz'
        Baudrate    = 38400
        Note        = ''
    }
    [pscustomobject]@{
        Vid = '0451'; Pid = '16A8'
        Name        = 'Texas Instruments CC2531 / CC2530'
        Radio       = 'Zigbee'
        Stack       = 'zstack'
        Baudrate    = 115200
        Note        = 'Legacy hardware. Underpowered for networks above ~20 devices; expect routing problems on a full sensor suite.'
    }
    [pscustomobject]@{
        Vid = '0658'; Pid = '0200'
        Name        = 'Sigma Designs Z-Wave (Aeotec Z-Stick Gen5 and relatives)'
        Radio       = 'Z-Wave'
        Stack       = $null
        Baudrate    = 115200
        Note        = 'Enumerates without a VID/PID-bearing USB-serial bridge on some firmware revisions.'
    }
    [pscustomobject]@{
        Vid = '10C4'; Pid = 'EA60'
        Name        = 'Silicon Labs CP210x bridge - AMBIGUOUS'
        Radio       = 'Unknown'
        Stack       = $null
        Baudrate    = $null
        Note        = 'This bridge chip is used by BOTH Zigbee and Z-Wave coordinators, including Sonoff ZBDongle-P (zstack, 115200), Zooz ZST10/ZST39 (Z-Wave), Aeotec Z-Stick 7 (Z-Wave), and several SMLIGHT boards. VID/PID alone CANNOT tell these apart - use -Watch, or check the label on the stick.'
    }
)

function Get-SerialPortInventory {
    $entities = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
        Where-Object { $_.Name -and $_.Name -match '\(COM\d+\)' }

    foreach ($e in $entities) {
        $port = if ($e.Name -match '\((COM\d+)\)') { $Matches[1] } else { $null }
        if (-not $port) { continue }

        $vid = $null; $pid = $null
        # PNPDeviceID uses '&' on USB\ devices and '+' on FTDIBUS\ devices.
        if ($e.PNPDeviceID -match 'VID[_]([0-9A-Fa-f]{4})') { $vid = $Matches[1].ToUpper() }
        if ($e.PNPDeviceID -match 'PID[_]([0-9A-Fa-f]{4})') { $pid = $Matches[1].ToUpper() }

        $match = $null
        if ($vid -and $pid) {
            $match = $KnownDevices | Where-Object { $_.Vid -eq $vid -and $_.Pid -eq $pid } | Select-Object -First 1
        }

        [pscustomobject]@{
            Port         = $port
            PortNumber   = [int]($port -replace '\D', '')
            Vid          = $vid
            Pid          = $pid
            HardwareId   = $e.PNPDeviceID
            Description  = $e.Name
            Manufacturer = $e.Manufacturer
            Status       = $e.Status
            Identified   = if ($match) { $match.Name }     else { 'Unrecognized' }
            Radio        = if ($match) { $match.Radio }    else { 'Unknown' }
            Stack        = if ($match) { $match.Stack }    else { $null }
            Baudrate     = if ($match) { $match.Baudrate } else { $null }
            Note         = if ($match) { $match.Note }     else { '' }
        }
    }
}

function Write-Header($text) {
    Write-Host ''
    Write-Host $text -ForegroundColor Cyan
    Write-Host ('-' * $text.Length) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# -Watch : differential identification by unplug
# ---------------------------------------------------------------------------
if ($Watch) {
    Write-Header 'Differential coordinator identification'
    $before = @(Get-SerialPortInventory)

    if ($before.Count -eq 0) {
        Write-Host 'No serial ports present. Plug in a coordinator and re-run.' -ForegroundColor Yellow
        return
    }

    Write-Host ("Currently present: {0}" -f (($before.Port | Sort-Object) -join ', '))
    Write-Host ''
    Write-Host 'Now UNPLUG the adapter you want to identify, wait ~3 seconds, then press Enter.' -ForegroundColor Yellow
    [void](Read-Host)

    $after   = @(Get-SerialPortInventory)
    $gonePorts = @(Compare-Object -ReferenceObject @($before.Port) -DifferenceObject @($after.Port) |
        Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object { $_.InputObject })

    if ($gonePorts.Count -eq 0) {
        Write-Host 'No port disappeared. Windows may not have processed the removal yet, or the adapter is still connected.' -ForegroundColor Red
        return
    }

    Write-Host ''
    Write-Host ("The adapter you unplugged is: {0}" -f ($gonePorts -join ' + ')) -ForegroundColor Green
    if ($gonePorts.Count -gt 1) {
        Write-Host 'Two ports vanished together, which means this is a DUAL-RADIO stick (e.g. HUSBZB-1).' -ForegroundColor Yellow
        Write-Host 'Assign the lower-numbered port to Zigbee and the higher-numbered port to Z-Wave, then confirm by starting one service at a time.' -ForegroundColor Yellow
    }
    foreach ($p in $gonePorts) {
        $d = $before | Where-Object { $_.Port -eq $p }
        Write-Host ("  {0}  VID_{1}&PID_{2}  {3}" -f $d.Port, $d.Vid, $d.Pid, $d.Description)
    }
    Write-Host ''
    Write-Host 'Plug the adapter back in before starting any services.' -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# Default: full inventory report
# ---------------------------------------------------------------------------
$ports = @(Get-SerialPortInventory | Sort-Object PortNumber)

if ($Json) {
    $ports | ConvertTo-Json -Depth 4
    return
}

Write-Header 'Serial port inventory'

if ($ports.Count -eq 0) {
    Write-Host 'No COM ports found.' -ForegroundColor Red
    Write-Host 'Check that the coordinators are plugged in and that their USB-serial drivers are installed.'
    Write-Host 'A stick that appears in Device Manager under "Other devices" with a warning icon is missing its driver.'
    return
}

$ports | Format-Table -AutoSize @(
    @{ Label = 'Port';  Expression = { $_.Port } }
    @{ Label = 'VID';   Expression = { if ($_.Vid) { $_.Vid } else { '-' } } }
    @{ Label = 'PID';   Expression = { if ($_.Pid) { $_.Pid } else { '-' } } }
    @{ Label = 'Radio'; Expression = { $_.Radio } }
    @{ Label = 'Identified'; Expression = { $_.Identified } }
)

foreach ($p in $ports | Where-Object { $_.Note }) {
    Write-Host ("[{0}] {1}" -f $p.Port, $p.Note) -ForegroundColor Yellow
    Write-Host ''
}

$unknown = @($ports | Where-Object { $_.Identified -eq 'Unrecognized' })
if ($unknown.Count -gt 0) {
    Write-Header 'Unrecognized ports'
    Write-Host 'These did not match the known-hardware table. That does not mean they are not coordinators -'
    Write-Host 'the table is deliberately small. Identify them with: .\Find-Coordinators.ps1 -Watch'
    Write-Host ''
    foreach ($u in $unknown) {
        Write-Host ("  {0}  {1}" -f $u.Port, $u.Description)
        Write-Host ("        {0}" -f $u.HardwareId) -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# Config snippet emission
# ---------------------------------------------------------------------------
$zigbee = @($ports | Where-Object { $_.Radio -eq 'Zigbee' })
$zwave  = @($ports | Where-Object { $_.Radio -eq 'Z-Wave' })
$both   = @($ports | Where-Object { $_.Radio -eq 'Both' })

Write-Header 'Configuration snippets'

if ($zigbee.Count -eq 1) {
    $z = $zigbee[0]
    Write-Host 'Zigbee2MQTT  ->  data\configuration.yaml' -ForegroundColor Green
    Write-Host ''
    Write-Host 'serial:'
    Write-Host ("  port: {0}" -f $z.Port)
    if ($z.Stack)    { Write-Host ("  adapter: {0}" -f $z.Stack) }
    if ($z.Baudrate) { Write-Host ("  baudrate: {0}" -f $z.Baudrate) }
    Write-Host ''
}
elseif ($both.Count -ge 1) {
    $sorted = @($ports | Where-Object { $_.Radio -eq 'Both' } | Sort-Object PortNumber)
    Write-Host 'Dual-radio stick detected. Suggested split (VERIFY before relying on it):' -ForegroundColor Yellow
    Write-Host ''
    Write-Host ("  Zigbee2MQTT  serial.port : {0}" -f $sorted[0].Port)
    if ($sorted.Count -gt 1) {
        Write-Host ("  Z-Wave JS    serial port: {0}" -f $sorted[-1].Port)
    }
    Write-Host ''
}
else {
    Write-Host 'Could not confidently identify a Zigbee coordinator. Run with -Watch to map it manually.' -ForegroundColor Yellow
    Write-Host ''
}

if ($zwave.Count -eq 1) {
    Write-Host 'Z-Wave JS UI  ->  Settings > Z-Wave > Serial Port' -ForegroundColor Green
    Write-Host ("  {0}" -f $zwave[0].Port)
    Write-Host ''
}

Write-Host 'Reminder: only one process may hold a serial port at a time. If Zigbee2MQTT and' -ForegroundColor DarkGray
Write-Host 'Z-Wave JS are pointed at the same COM port, the second one to start will fail to open it.' -ForegroundColor DarkGray
