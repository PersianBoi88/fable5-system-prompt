<#
.SYNOPSIS
    Exposes the dashboard to your phone over Tailscale, with TLS.

.DESCRIPTION
    Installs Tailscale, joins the machine to your tailnet, and publishes the
    loopback-bound dashboard to the tailnet over HTTPS using `tailscale serve`.

    Why this rather than a firewall rule: `tailscale serve` proxies from the
    tailnet to 127.0.0.1, so the dashboard stays bound to loopback. Nothing
    listens on your LAN and nothing is port-forwarded. The only route in is a
    device you have explicitly authorised onto the tailnet, and the connection
    carries a real TLS certificate for a *.ts.net name rather than a
    self-signed one your phone will nag about.

    This deliberately does NOT enable Tailscale Funnel. Funnel publishes a
    service to the public internet. For a dashboard that opens a front door,
    that is the wrong trade at any password strength.

.PARAMETER Port
    Loopback port the dashboard listens on. Default 8099.

.PARAMETER SkipInstall
    Skip installation; only configure serving.

.NOTES
    Run as Administrator. `tailscale up` opens a browser for authentication.
#>
[CmdletBinding()]
param(
    [int]$Port = 8099,
    [switch]$SkipInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
}

function Find-Tailscale {
    $cmd = Get-Command 'tailscale' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
    )) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

Assert-Administrator

Write-Host ''
Write-Host 'Remote access via Tailscale' -ForegroundColor Cyan
Write-Host '---------------------------' -ForegroundColor DarkGray

# --- Dashboard must actually be up ------------------------------------------
$listening = $null -ne (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
if (-not $listening) {
    Write-Warning "Nothing is listening on 127.0.0.1:$Port."
    Write-Warning 'Start the dashboard first, or `tailscale serve` will publish a dead endpoint:'
    Write-Warning '    Start-ScheduledTask -TaskName XfinityHomeDashboard'
    Write-Host ''
    $answer = Read-Host 'Continue anyway? (y/N)'
    if ($answer -ne 'y') { return }
}
else {
    Write-Host "Dashboard is listening on 127.0.0.1:$Port." -ForegroundColor Green
}

# --- Install ----------------------------------------------------------------
$ts = Find-Tailscale
if (-not $ts -and -not $SkipInstall) {
    Write-Host 'Installing Tailscale ...' -ForegroundColor Cyan
    & winget install --id 'Tailscale.Tailscale' --exact `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    $code = $LASTEXITCODE
    if ($code -ne 0 -and $code -ne -1978335189) {
        throw @"
Tailscale installation failed (winget exit code $code).

Install manually from https://tailscale.com/download/windows and re-run with
-SkipInstall.
"@
    }
    Update-SessionPath
    Start-Sleep -Seconds 3
    $ts = Find-Tailscale
}

if (-not $ts) { throw 'tailscale.exe not found. Install it and re-run with -SkipInstall.' }
Write-Host "Tailscale: $ts" -ForegroundColor Green

# --- Join the tailnet -------------------------------------------------------
$statusJson = & $ts status --json 2>$null | Out-String
$needsUp = $true
$selfName = $null

if ($statusJson) {
    try {
        $status = $statusJson | ConvertFrom-Json
        if ($status.BackendState -eq 'Running') {
            $needsUp = $false
            $selfName = $status.Self.DNSName
            Write-Host "Already connected to the tailnet as $selfName" -ForegroundColor Green
        }
    }
    catch { }
}

if ($needsUp) {
    Write-Host ''
    Write-Host 'Joining the tailnet. A browser will open for authentication.' -ForegroundColor Cyan
    Write-Host 'Sign in with the same account you will use on your phone.' -ForegroundColor Cyan
    Write-Host ''
    & $ts up
    if ($LASTEXITCODE -ne 0) { throw 'tailscale up failed.' }

    Start-Sleep -Seconds 2
    try {
        $status = (& $ts status --json | Out-String) | ConvertFrom-Json
        $selfName = $status.Self.DNSName
    }
    catch { }
}

$hostName = if ($selfName) { $selfName.TrimEnd('.') } else { '<your-machine>.ts.net' }

# --- Publish over HTTPS ------------------------------------------------------
Write-Host ''
Write-Host 'Publishing the dashboard to the tailnet ...' -ForegroundColor Cyan

# Serve syntax has shifted across Tailscale versions; try the current form and
# fall back rather than failing outright on an older client.
& $ts serve --bg "http://127.0.0.1:$Port" 2>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Retrying with the older serve syntax ...' -ForegroundColor Yellow
    & $ts serve https / "http://127.0.0.1:$Port" 2>&1 | Out-String | Write-Host
    if ($LASTEXITCODE -ne 0) {
        throw @"
`tailscale serve` failed.

The most common cause is that HTTPS certificates are not enabled for your
tailnet. Enable both MagicDNS and HTTPS in the admin console:
    https://login.tailscale.com/admin/dns
then re-run this script.
"@
    }
}

Write-Host ''
& $ts serve status 2>&1 | Out-String | Write-Host

# --- Confirm no Funnel -------------------------------------------------------
$funnel = & $ts funnel status 2>&1 | Out-String
if ($funnel -match 'https://' -and $funnel -notmatch 'No serve config|not.*enabled') {
    Write-Host ''
    Write-Warning 'FUNNEL APPEARS TO BE ENABLED - the dashboard may be reachable from the public internet.'
    Write-Warning 'Disable it with:  tailscale funnel off'
}

# --- Hand-off ----------------------------------------------------------------
Write-Host ''
Write-Host 'Remote access configured.' -ForegroundColor Green
Write-Host ''
Write-Host "  From your phone:  https://$hostName" -ForegroundColor Cyan
Write-Host ''
Write-Host 'On the phone:'
Write-Host '  1. Install the Tailscale app and sign in with the same account.'
Write-Host '  2. Make sure the VPN toggle is on.'
Write-Host "  3. Open https://$hostName"
Write-Host '  4. Add it to your home screen for an app-like launcher.'
Write-Host ''
Write-Host 'Notes worth keeping in mind:' -ForegroundColor Yellow
Write-Host '  - The dashboard is still bound to loopback. Nothing is exposed to your'
Write-Host '    LAN or the internet; the tailnet is the only path in.'
Write-Host '  - Being on the tailnet is NOT sufficient to open the door. The lock'
Write-Host '    requires its PIN on every operation, which is what protects you if'
Write-Host '    the phone itself is unlocked and in the wrong hands.'
Write-Host '  - Do NOT run `tailscale funnel`. That publishes to the public internet.'
Write-Host '  - Revoke a lost phone from https://login.tailscale.com/admin/machines'
Write-Host '    and change the dashboard password and lock PIN.'
