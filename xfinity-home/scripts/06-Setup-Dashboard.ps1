<#
.SYNOPSIS
    Deploys the mobile dashboard: dependencies, credentials, config, service.

.DESCRIPTION
    Installs the dashboard's single runtime dependency, provisions a login
    account and the separate lock PIN, writes the runtime config, and registers
    a startup task.

    The dashboard binds to loopback only. It is not reachable from your LAN and
    not reachable from the internet - exposure is 07-Setup-RemoteAccess.ps1's
    job, via `tailscale serve`, which also supplies TLS.

    Password and PIN hashing is delegated to Node (scrypt) rather than
    reimplemented here, so the stored format is by construction the same one
    server.js verifies against.

.PARAMETER Username
    Dashboard login name. Default: the current Windows username.

.PARAMETER Port
    Loopback port. Default 8099.

.PARAMETER SkipLock
    Configure the dashboard without lock control. Sensors and cameras only.

.PARAMETER Force
    Overwrite an existing dashboard.json.

.NOTES
    Run as Administrator. Run 01-04 first.
#>
[CmdletBinding()]
param(
    [string]$Username = $env:USERNAME,
    [int]$Port = 8099,
    [switch]$SkipLock,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot     = Split-Path $PSScriptRoot -Parent
$DashboardDir = Join-Path $RepoRoot 'dashboard'
$DataRoot     = 'C:\ProgramData\xfinity-home'
$CredPath     = Join-Path $DataRoot 'credentials.json'
$ConfigPath   = Join-Path $DataRoot 'dashboard.json'
$TaskName     = 'XfinityHomeDashboard'

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

function Read-Secret {
    param([string]$Prompt, [int]$MinLength = 1)
    while ($true) {
        $secure = Read-Host -Prompt $Prompt -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try   { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

        if ($plain.Length -lt $MinLength) {
            Write-Host "Must be at least $MinLength characters." -ForegroundColor Yellow
            continue
        }

        $secure2 = Read-Host -Prompt '  confirm' -AsSecureString
        $bstr2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
        try   { $plain2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr2) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr2) }

        if ($plain -ne $plain2) {
            Write-Host 'Did not match, try again.' -ForegroundColor Yellow
            continue
        }
        return $plain
    }
}

Assert-Administrator

Write-Host ''
Write-Host 'Dashboard deployment' -ForegroundColor Cyan
Write-Host '--------------------' -ForegroundColor DarkGray

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js is not on PATH. Run 01-Install-Prereqs.ps1 first.'
}
if (-not (Test-Path $CredPath)) {
    throw "MQTT credentials not found at $CredPath. Run 02-Setup-Mosquitto.ps1 first."
}
if (-not (Test-Path $DashboardDir)) {
    throw "Dashboard source not found at $DashboardDir"
}
if ((Test-Path $ConfigPath) -and -not $Force) {
    Write-Host "Config already exists at $ConfigPath" -ForegroundColor Yellow
    Write-Host 'Pass -Force to regenerate (this resets the password and PIN).' -ForegroundColor Yellow
    Write-Host 'Continuing with dependency install and task registration only.' -ForegroundColor DarkGray
    $skipConfig = $true
}
else {
    $skipConfig = $false
}

$creds = Get-Content $CredPath -Raw | ConvertFrom-Json

# --- Dependencies ----------------------------------------------------------
Write-Host 'Installing dashboard dependencies ...' -ForegroundColor Cyan
Push-Location $DashboardDir
try {
    & npm install --omit=dev --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw 'npm install failed.' }
}
finally { Pop-Location }
Write-Host 'Dependencies installed.' -ForegroundColor Green

# --- Credentials and config ------------------------------------------------
if (-not $skipConfig) {
    Write-Host ''
    Write-Host "Dashboard login account (username: $Username)" -ForegroundColor Cyan
    $password = Read-Secret -Prompt 'Password (min 12 chars)' -MinLength 12

    $pin = $null
    if (-not $SkipLock) {
        Write-Host ''
        Write-Host 'Lock PIN' -ForegroundColor Cyan
        Write-Host 'Required every time the door is locked or unlocked from the phone.' -ForegroundColor DarkGray
        Write-Host 'Make it DIFFERENT from your password - the whole point is that an' -ForegroundColor DarkGray
        Write-Host 'unlocked phone with a live session still cannot open your door.' -ForegroundColor DarkGray
        $pin = Read-Secret -Prompt 'Lock PIN (min 4 chars)' -MinLength 4
    }

    Write-Host ''
    Write-Host 'Hashing credentials ...' -ForegroundColor Cyan

    # Secrets go to Node over stdin, never as command-line arguments - argv is
    # visible to any process that can enumerate the process list.
    $stdinPayload = @{
        password = $password
        pin      = $pin
        username = $Username
        port     = $Port
        mqtt     = @{
            host     = $creds.mqtt_host
            port     = $creds.mqtt_port
            user     = $creds.mqtt_user
            password = $creds.mqtt_password
        }
    } | ConvertTo-Json -Compress

    $hashScript = @'
const {scryptSync, randomBytes} = require("node:crypto");
let raw = "";
process.stdin.on("data", d => raw += d);
process.stdin.on("end", () => {
  const inp = JSON.parse(raw);
  const mk = (secret) => {
    const salt = randomBytes(16).toString("hex");
    return {salt, hash: scryptSync(secret, Buffer.from(salt, "hex"), 64).toString("hex")};
  };
  const user = mk(inp.password);
  const cfg = {
    port: inp.port,
    bindHost: "127.0.0.1",
    sessionSecret: randomBytes(32).toString("hex"),
    users: [{username: inp.username, salt: user.salt, hash: user.hash}],
    mqtt: inp.mqtt,
    zwavePrefix: "zwave",
    cameras: []
  };
  if (inp.pin) {
    const p = mk(inp.pin);
    cfg.lockPin = {salt: p.salt, hash: p.hash};
    cfg.lock = {
      name: "Front door",
      stateTopic: "",
      commandTopic: "",
      lockPayload: "255",
      unlockPayload: "0"
    };
  }
  process.stdout.write(JSON.stringify(cfg, null, 2));
});
'@

    $tmpScript = Join-Path $env:TEMP "hash-$([guid]::NewGuid().ToString('N')).cjs"
    Set-Content -Path $tmpScript -Value $hashScript -Encoding UTF8
    try {
        $configJson = $stdinPayload | & node $tmpScript
        if ($LASTEXITCODE -ne 0 -or -not $configJson) { throw 'Credential hashing failed.' }
    }
    finally {
        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
        # Drop the plaintext from this session's memory as soon as possible.
        $password = $null; $pin = $null; $stdinPayload = $null
        [GC]::Collect()
    }

    if (-not (Test-Path $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
    [System.IO.File]::WriteAllText($ConfigPath, $configJson, (New-Object System.Text.UTF8Encoding($false)))
    & icacls $ConfigPath /inheritance:r /grant:r 'SYSTEM:(F)' 'BUILTIN\Administrators:(F)' | Out-Null

    Write-Host "Wrote $ConfigPath" -ForegroundColor Green
}

# --- Startup task ----------------------------------------------------------
Write-Host 'Registering startup task ...' -ForegroundColor Cyan

$nodeExe = (Get-Command node).Source
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $nodeExe -Argument 'server.js' -WorkingDirectory $DashboardDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Local smart home dashboard' | Out-Null

Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green

# --- Hand-off --------------------------------------------------------------
Write-Host ''
Write-Host 'Dashboard deployed.' -ForegroundColor Green
Write-Host ''
Write-Host "  Start    Start-ScheduledTask -TaskName $TaskName"
Write-Host "  Local    http://127.0.0.1:$Port"
Write-Host "  Config   $ConfigPath"
Write-Host "  Audit    $DataRoot\dashboard-audit.log"
Write-Host ''

if (-not $SkipLock) {
    Write-Host 'THE LOCK TOPICS ARE NOT SET YET.' -ForegroundColor Yellow
    Write-Host 'Z-Wave JS UI topic layout depends on your node names and topic mode, so' -ForegroundColor Yellow
    Write-Host 'they have to be observed rather than assumed. Discover them with:' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '    .\Get-ZWaveTopics.ps1 -Seconds 30' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "Paste the emitted block into the 'lock' section of dashboard.json, then"
    Write-Host 'restart the dashboard task.'
    Write-Host ''
    Write-Host 'Confirm the tile tracks the physical deadbolt BEFORE trusting the remote' -ForegroundColor Yellow
    Write-Host 'unlock button. A state topic that reads backwards is worse than none.' -ForegroundColor Yellow
    Write-Host ''
}

Write-Host 'Next: .\07-Setup-RemoteAccess.ps1  (phone access over Tailscale)' -ForegroundColor Cyan
