<#
.SYNOPSIS
    Installs Node.js, Git and pnpm (via corepack) for the local smart home stack.

.DESCRIPTION
    Zigbee2MQTT is built from source and requires a Node.js runtime inside the
    range declared by its package.json `engines` field, plus pnpm supplied
    through corepack, plus Git (Zigbee2MQTT shells out to `git rev-parse` on
    startup to decide whether its TypeScript needs rebuilding - a clone without
    Git on PATH will rebuild on every launch).

.PARAMETER NodeVersion
    Major Node version to install. Defaults to 22 to match the project brief.
    Zigbee2MQTT accepts 22, 24 and 26.

.PARAMETER SkipNode
    Skip Node installation (use an existing runtime already on PATH).

.NOTES
    Run as Administrator.
#>
[CmdletBinding()]
param(
    [ValidateSet('22', '24', '26')]
    [string]$NodeVersion = '22',
    [switch]$SkipNode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Zigbee2MQTT package.json: "engines": { "node": "^22.2.0 || ^24 || ^26" }
$SupportedNodeMajors = @(22, 24, 26)

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

function Update-SessionPath {
    # winget-installed tools land on the machine PATH, which the current process
    # does not see until it is refreshed.
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
}

function Test-Command($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Version,
        [string]$Friendly = $Id
    )

    Write-Host "Installing $Friendly ..." -ForegroundColor Cyan

    # Not named $args - that is a PowerShell automatic variable.
    $wingetArgs = @(
        'install', '--id', $Id,
        '--exact',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )
    if ($Version) { $wingetArgs += @('--version', $Version) }

    & winget @wingetArgs
    $code = $LASTEXITCODE

    # winget exit codes: 0 = installed, -1978335189 (0x8A15002B) = no applicable
    # upgrade / already installed. Both are success for our purposes.
    if ($code -ne 0 -and $code -ne -1978335189) {
        Write-Warning "winget returned exit code $code for $Friendly."
        Write-Warning "If the package ID has changed, search for it with: winget search $Id"
        throw "Failed to install $Friendly."
    }

    Update-SessionPath
}

Assert-Administrator

Write-Host ''
Write-Host 'Prerequisite installation' -ForegroundColor Cyan
Write-Host '-------------------------' -ForegroundColor DarkGray

if (-not (Test-Command 'winget')) {
    throw @'
winget (Windows Package Manager) is not available.

Install "App Installer" from the Microsoft Store, or install the prerequisites
manually:
  Node.js  https://nodejs.org/en/download
  Git      https://git-scm.com/download/win
Then re-run this script with -SkipNode, or skip straight to 02-Setup-Mosquitto.ps1.
'@
}

# --- Git -------------------------------------------------------------------
if (Test-Command 'git') {
    Write-Host "Git already present: $((git --version) -join '')" -ForegroundColor Green
}
else {
    Install-WingetPackage -Id 'Git.Git' -Friendly 'Git'
}

# --- Node ------------------------------------------------------------------
if (-not $SkipNode) {
    $needsInstall = $true

    if (Test-Command 'node') {
        $current = (node --version) -replace '^v', ''
        $major   = [int]($current -split '\.')[0]
        if ($SupportedNodeMajors -contains $major) {
            Write-Host "Node.js already present and supported: v$current" -ForegroundColor Green
            $needsInstall = $false
        }
        else {
            Write-Warning "Node.js v$current is installed but Zigbee2MQTT requires major version 22, 24 or 26."
            Write-Warning "Installing Node $NodeVersion alongside / over it."
        }
    }

    if ($needsInstall) {
        # OpenJS.NodeJS.LTS tracks whichever line is currently LTS, which drifts
        # over time, so pin the major explicitly.
        Install-WingetPackage -Id "OpenJS.NodeJS.LTS" -Friendly "Node.js $NodeVersion LTS"
    }
}

Update-SessionPath

if (-not (Test-Command 'node')) {
    throw 'Node.js is still not on PATH. Close and reopen the elevated PowerShell session, then re-run.'
}

$nodeVer   = (node --version) -replace '^v', ''
$nodeMajor = [int]($nodeVer -split '\.')[0]
if ($SupportedNodeMajors -notcontains $nodeMajor) {
    throw "Node.js v$nodeVer is not supported by Zigbee2MQTT (needs major 22, 24 or 26)."
}
Write-Host "Node.js v$nodeVer" -ForegroundColor Green

# --- corepack / pnpm -------------------------------------------------------
Write-Host 'Enabling corepack and preparing pnpm ...' -ForegroundColor Cyan

# Node 25+ removed the bundled corepack shim; install it standalone if absent.
if (-not (Test-Command 'corepack')) {
    Write-Host 'corepack not bundled with this Node build; installing globally.' -ForegroundColor Yellow
    & npm install --global corepack
    Update-SessionPath
}

& corepack enable
if ($LASTEXITCODE -ne 0) {
    throw 'corepack enable failed. On some systems this needs an elevated shell - confirm you are running as Administrator.'
}

Update-SessionPath

if (Test-Command 'pnpm') {
    Write-Host "pnpm $((pnpm --version) -join '')" -ForegroundColor Green
}
else {
    Write-Warning 'pnpm shim not yet on PATH. It will be activated by corepack when Zigbee2MQTT is first built.'
}

Write-Host ''
Write-Host 'Prerequisites complete.' -ForegroundColor Green
Write-Host 'Next: .\02-Setup-Mosquitto.ps1' -ForegroundColor Cyan
