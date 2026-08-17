<#
.SYNOPSIS
    Clones, builds and configures Zigbee2MQTT, then registers it to run at boot.

.DESCRIPTION
    Performs the full Zigbee2MQTT deployment:
      - clones the repository (shallow)
      - installs dependencies with pnpm and pre-builds the TypeScript
      - seeds data\configuration.yaml from the repository template, wiring in
        the MQTT credentials created by 02-Setup-Mosquitto.ps1 and the COM port
        of the Zigbee coordinator
      - installs the ex-Xfinity external converters
      - registers a startup task so it survives reboots

    Seeding the configuration before first launch bypasses the web onboarding
    wizard that Zigbee2MQTT 2.x otherwise presents on port 8080.

.PARAMETER SerialPort
    COM port of the Zigbee coordinator, e.g. COM3. If omitted the script tries
    to detect it and refuses to guess when the result is ambiguous.

.PARAMETER Adapter
    Coordinator stack. One of: deconz, zstack, zigate, ezsp, ember, zboss, zoh.
    Omit unless autodetection fails or the coordinator misbehaves.

.PARAMETER Baudrate
    Serial baud rate. Omit to use the adapter default (usually 115200).

.PARAMETER Channel
    Zigbee channel. Use a ZLL channel: 11, 15, 20 or 25. Default 25.
    Changing this after devices are paired forces a full re-pair.

.PARAMETER InstallPath
    Install directory. Default C:\zigbee2mqtt

.NOTES
    Run as Administrator. Run 01 and 02 first.
#>
[CmdletBinding()]
param(
    [string]$SerialPort,
    [ValidateSet('deconz', 'zstack', 'zigate', 'ezsp', 'ember', 'zboss', 'zoh')]
    [string]$Adapter,
    [int]$Baudrate,
    [ValidateSet(11, 15, 20, 25)]
    [int]$Channel = 25,
    [string]$InstallPath = 'C:\zigbee2mqtt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot     = Split-Path $PSScriptRoot -Parent
$TemplatePath = Join-Path $RepoRoot 'config\zigbee2mqtt\configuration.yaml.template'
$ConvertersSrc= Join-Path $RepoRoot 'external_converters'
$CredPath     = 'C:\ProgramData\xfinity-home\credentials.json'
$TaskName     = 'Zigbee2MQTT'
$RepoUrl      = 'https://github.com/Koenkk/zigbee2mqtt.git'

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

function New-AuthToken {
    $bytes = [byte[]]::new(32)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

Assert-Administrator

Write-Host ''
Write-Host 'Zigbee2MQTT deployment' -ForegroundColor Cyan
Write-Host '----------------------' -ForegroundColor DarkGray

# --- Preconditions ---------------------------------------------------------
foreach ($tool in @('git', 'node')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is not on PATH. Run 01-Install-Prereqs.ps1 first, then open a new elevated shell."
    }
}
if (-not (Test-Path $CredPath)) {
    throw "MQTT credentials not found at $CredPath. Run 02-Setup-Mosquitto.ps1 first."
}
if (-not (Test-Path $TemplatePath)) {
    throw "Configuration template missing at $TemplatePath"
}

$creds = Get-Content $CredPath -Raw | ConvertFrom-Json
Write-Host "Using MQTT account '$($creds.mqtt_user)'." -ForegroundColor Green

# --- Resolve the serial port ----------------------------------------------
if (-not $SerialPort) {
    Write-Host 'No -SerialPort given; attempting detection ...' -ForegroundColor Cyan
    $finder = Join-Path $PSScriptRoot 'Find-Coordinators.ps1'
    $found  = @(& $finder -Json | ConvertFrom-Json) | Where-Object { $_.Radio -eq 'Zigbee' }

    if ($found.Count -eq 1) {
        $SerialPort = $found[0].Port
        if (-not $Adapter -and $found[0].Stack)     { $Adapter  = $found[0].Stack }
        if (-not $Baudrate -and $found[0].Baudrate) { $Baudrate = $found[0].Baudrate }
        Write-Host "Detected Zigbee coordinator on $SerialPort ($($found[0].Identified))." -ForegroundColor Green
    }
    else {
        throw @"
Could not unambiguously identify the Zigbee coordinator.

Run this to see what is attached:
    .\Find-Coordinators.ps1
    .\Find-Coordinators.ps1 -Watch     (definitive - identifies by unplugging)

Then re-run with the port, e.g.:
    .\03-Setup-Zigbee2MQTT.ps1 -SerialPort COM3
"@
    }
}

Write-Host "Zigbee coordinator : $SerialPort"
Write-Host "Adapter            : $(if ($Adapter) { $Adapter } else { 'autodetect' })"
Write-Host "Zigbee channel     : $Channel"

# --- Clone -----------------------------------------------------------------
if (Test-Path (Join-Path $InstallPath '.git')) {
    Write-Host "Existing checkout found at $InstallPath - leaving it in place." -ForegroundColor Green
}
elseif ((Test-Path $InstallPath) -and (Get-ChildItem $InstallPath -Force | Select-Object -First 1)) {
    throw "$InstallPath exists and is not empty, but is not a git checkout. Move it aside and re-run."
}
else {
    Write-Host "Cloning Zigbee2MQTT into $InstallPath ..." -ForegroundColor Cyan
    & git clone --depth 1 $RepoUrl $InstallPath
    if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
}

# --- Dependencies and build ------------------------------------------------
Push-Location $InstallPath
try {
    Write-Host 'Installing dependencies (this takes several minutes) ...' -ForegroundColor Cyan
    & corepack enable
    & pnpm install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'pnpm install failed.' }

    # Zigbee2MQTT self-builds on first start, but doing it now surfaces
    # compilation problems here rather than inside a background service.
    Write-Host 'Building ...' -ForegroundColor Cyan
    & pnpm run build
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
    Write-Host 'Build complete.' -ForegroundColor Green
}
finally {
    Pop-Location
}

# --- Configuration ---------------------------------------------------------
$dataDir = Join-Path $InstallPath 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

$configPath = Join-Path $dataDir 'configuration.yaml'

if (Test-Path $configPath) {
    $backup = "$configPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $configPath $backup
    Write-Host "Existing configuration.yaml backed up to $(Split-Path $backup -Leaf)" -ForegroundColor Yellow
    Write-Host 'Leaving the existing configuration in place. Delete it and re-run to regenerate.' -ForegroundColor Yellow
}
else {
    $token = New-AuthToken

    # Optional lines are emitted only when a value was supplied, so an unset
    # adapter means "let Zigbee2MQTT autodetect" rather than an empty YAML key.
    $adapterLine  = if ($Adapter)  { "  adapter: $Adapter" }   else { '' }
    $baudrateLine = if ($Baudrate) { "  baudrate: $Baudrate" } else { '' }

    $config = Get-Content $TemplatePath -Raw
    $config = $config.Replace('{{MQTT_USER}}',      $creds.mqtt_user)
    $config = $config.Replace('{{MQTT_PASSWORD}}',  $creds.mqtt_password)
    $config = $config.Replace('{{SERIAL_PORT}}',    $SerialPort)
    $config = $config.Replace('{{ADAPTER_LINE}}',   $adapterLine)
    $config = $config.Replace('{{BAUDRATE_LINE}}',  $baudrateLine)
    $config = $config.Replace('{{CHANNEL}}',        "$Channel")
    $config = $config.Replace('{{FRONTEND_TOKEN}}', $token)

    if ($config -match '\{\{[A-Z_]+\}\}') {
        throw "Template substitution incomplete - unreplaced token: $($Matches[0])"
    }

    # UTF-8 without BOM. A BOM at the head of configuration.yaml breaks the
    # YAML parser with an error that does not mention the BOM.
    [System.IO.File]::WriteAllText($configPath, $config, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Wrote $configPath" -ForegroundColor Green

    # Config carries the MQTT password in cleartext.
    & icacls $configPath /inheritance:r /grant:r 'SYSTEM:(F)' 'BUILTIN\Administrators:(F)' | Out-Null

    Write-Host ''
    Write-Host 'Frontend auth token (needed to open the web UI):' -ForegroundColor Yellow
    Write-Host "  $token"
    Write-Host "  http://127.0.0.1:8080"
    Write-Host ''
}

# --- External converters ---------------------------------------------------
# Must sit alongside configuration.yaml, i.e. in data\external_converters.
$convertersDst = Join-Path $dataDir 'external_converters'
if (-not (Test-Path $convertersDst)) { New-Item -ItemType Directory -Path $convertersDst -Force | Out-Null }

$mjs = @(Get-ChildItem -Path $ConvertersSrc -Filter '*.mjs' -ErrorAction SilentlyContinue)
if ($mjs.Count -gt 0) {
    Copy-Item -Path (Join-Path $ConvertersSrc '*.mjs') -Destination $convertersDst -Force
    Write-Host "Installed $($mjs.Count) external converter file(s)." -ForegroundColor Green
}
else {
    Write-Host 'No external converters to install yet.' -ForegroundColor DarkGray
}

# --- Startup task ----------------------------------------------------------
# A scheduled task avoids taking a dependency on NSSM or WinSW. Crash recovery
# is handled by Zigbee2MQTT's own watchdog (Z2M_WATCHDOG), which restarts the
# controller internally on backoff intervals of 1, 5, 15, 30 and 60 minutes.
Write-Host 'Registering startup task ...' -ForegroundColor Cyan

$nodeExe = (Get-Command node).Source

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $nodeExe -Argument 'index.js' -WorkingDirectory $InstallPath
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Zigbee2MQTT - local Zigbee to MQTT bridge' | Out-Null

# Enable the internal watchdog for the task's environment.
[Environment]::SetEnvironmentVariable('Z2M_WATCHDOG', 'default', 'Machine')

Write-Host "Registered scheduled task '$TaskName' (runs at startup as SYSTEM)." -ForegroundColor Green

Write-Host ''
Write-Host 'Zigbee2MQTT deployed.' -ForegroundColor Green
Write-Host ''
Write-Host 'Start it in the foreground for the first run so you can watch the coordinator come up:' -ForegroundColor Cyan
Write-Host "    cd $InstallPath"
Write-Host '    pnpm start'
Write-Host ''
Write-Host 'Look for "zigbee-herdsman started" and a "Coordinator firmware version" line.'
Write-Host 'If the port fails to open, confirm nothing else holds it (Z-Wave JS, a serial'
Write-Host 'terminal, or a previous instance still running).'
Write-Host ''
Write-Host 'Once it starts cleanly, run it as a service with:  Start-ScheduledTask -TaskName Zigbee2MQTT'
Write-Host ''
Write-Host 'Next: .\04-Setup-ZWaveJS.ps1' -ForegroundColor Cyan
