<#
.SYNOPSIS
    Backs up the irreplaceable state of the smart home control plane.

.DESCRIPTION
    Captures the files that cannot be regenerated, and whose loss means
    physically re-pairing every device in the house:

      zwave-keys.json          the Z-Wave network security keys. Lose these and
                               every secure device - the lock included - must be
                               excluded and re-included.
      zigbee2mqtt\data\        the Zigbee network key, the device database and
                               the coordinator backup. Lose these and every
                               Zigbee sensor must be re-paired.
      zwave-js-ui\store\       Z-Wave node database and settings.
      credentials.json         MQTT account.
      mosquitto\               broker config and password file.
      go2rtc.yaml              camera stream definitions.

    Logs are excluded - they are large, they churn, and they are worthless in a
    restore.

    THE ARCHIVE CONTAINS SECRETS IN CLEARTEXT: network keys, the MQTT password
    and any camera passwords in go2rtc.yaml. Treat it accordingly. It is
    ACL-restricted on creation, but that protection does not survive a copy to
    a USB stick or a cloud folder.

.PARAMETER Destination
    Directory to write the archive into. Default: C:\ProgramData\xfinity-home\backups

.PARAMETER StopServices
    Stop the bridges before copying and restart them afterwards. Produces a
    guaranteed-consistent copy of the device databases at the cost of a brief
    outage. Without this the copy is taken hot, which is almost always fine but
    can catch a database mid-write.

.PARAMETER KeepLast
    Delete older archives, keeping this many. Default 10. Zero disables pruning.

.EXAMPLE
    .\Backup-Config.ps1

.EXAMPLE
    .\Backup-Config.ps1 -StopServices -Destination D:\backups

.NOTES
    Run as Administrator - the source files are ACL-restricted to SYSTEM and
    Administrators.
#>
[CmdletBinding()]
param(
    [string]$Destination = 'C:\ProgramData\xfinity-home\backups',
    [switch]$StopServices,
    [int]$KeepLast = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DataRoot   = 'C:\ProgramData\xfinity-home'
$Z2MPath    = 'C:\zigbee2mqtt'
$ZWavePath  = 'C:\zwave-js-ui'
$Tasks      = @('Zigbee2MQTT', 'ZWaveJSUI', 'go2rtc')

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session (Run as Administrator).'
    }
}

Assert-Administrator

Write-Host ''
Write-Host 'Control plane backup' -ForegroundColor Cyan
Write-Host '--------------------' -ForegroundColor DarkGray

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$staging = Join-Path $env:TEMP "xfinity-home-backup-$stamp"
$archive = Join-Path $Destination "xfinity-home-$stamp.zip"

if (-not (Test-Path $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$stopped = @()

try {
    # --- Optionally quiesce ------------------------------------------------
    if ($StopServices) {
        Write-Host 'Stopping bridges for a consistent copy ...' -ForegroundColor Cyan
        foreach ($t in $Tasks) {
            $task = Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
            if ($task -and $task.State -eq 'Running') {
                Stop-ScheduledTask -TaskName $t
                $stopped += $t
                Write-Host "  stopped $t"
            }
        }
        # Give the databases a moment to flush and release their handles.
        if ($stopped.Count -gt 0) { Start-Sleep -Seconds 5 }
    }

    $captured = @()
    $missing  = @()

    function Copy-Item-Tracked {
        param([string]$Source, [string]$RelativeTarget, [string[]]$ExcludeDirs = @())

        if (-not (Test-Path $Source)) {
            $script:missing += $RelativeTarget
            return
        }

        $target = Join-Path $staging $RelativeTarget

        if (Test-Path $Source -PathType Container) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null

            $items = Get-ChildItem -Path $Source -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $rel = $_.FullName.Substring($Source.Length).TrimStart('\')
                    $keep = $true
                    foreach ($ex in $ExcludeDirs) {
                        if ($rel -like "$ex\*" -or $rel -like "*\$ex\*") { $keep = $false; break }
                    }
                    $keep
                }

            foreach ($f in $items) {
                $rel = $f.FullName.Substring($Source.Length).TrimStart('\')
                $dst = Join-Path $target $rel
                $dir = Split-Path $dst -Parent
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                try { Copy-Item $f.FullName $dst -Force }
                catch { Write-Warning "Could not copy $($f.FullName): $_" }
            }

            $count = @($items).Count
            $script:captured += "$RelativeTarget ($count files)"
        }
        else {
            $dir = Split-Path $target -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Copy-Item $Source $target -Force
            $script:captured += $RelativeTarget
        }
    }

    Write-Host 'Collecting ...' -ForegroundColor Cyan

    Copy-Item-Tracked (Join-Path $DataRoot 'zwave-keys.json')    'zwave-keys.json'
    Copy-Item-Tracked (Join-Path $DataRoot 'credentials.json')   'credentials.json'
    Copy-Item-Tracked (Join-Path $DataRoot 'mosquitto\mosquitto.conf') 'mosquitto\mosquitto.conf'
    Copy-Item-Tracked (Join-Path $DataRoot 'mosquitto\passwd')   'mosquitto\passwd'
    Copy-Item-Tracked (Join-Path $DataRoot 'go2rtc\go2rtc.yaml') 'go2rtc\go2rtc.yaml'

    # Zigbee2MQTT data, minus logs.
    Copy-Item-Tracked (Join-Path $Z2MPath 'data') 'zigbee2mqtt-data' -ExcludeDirs @('log')

    # Z-Wave JS UI store. Location varies by build; try both.
    $zwStore = Join-Path $ZWavePath 'store'
    if (-not (Test-Path $zwStore)) { $zwStore = Join-Path $ZWavePath 'data' }
    Copy-Item-Tracked $zwStore 'zwave-js-ui-store'

    # --- Manifest ----------------------------------------------------------
    $manifest = [pscustomobject]@{
        created_at   = (Get-Date).ToString('o')
        host         = $env:COMPUTERNAME
        consistent   = [bool]$StopServices
        captured     = $captured
        missing      = $missing
        restore_note = 'Restore by stopping all bridges, copying each directory back to its original location, then starting them. Restoring zigbee2mqtt-data onto a DIFFERENT coordinator also requires restoring the coordinator backup via the Zigbee2MQTT frontend.'
    }
    $manifest | ConvertTo-Json -Depth 4 |
        Set-Content -Path (Join-Path $staging 'MANIFEST.json') -Encoding UTF8

    foreach ($c in $captured) { Write-Host "  + $c" -ForegroundColor Green }
    foreach ($m in $missing)  { Write-Host "  - $m (not present)" -ForegroundColor DarkGray }

    if ($captured.Count -eq 0) {
        throw 'Nothing was captured. Has any of the stack been deployed yet?'
    }

    # --- Archive -----------------------------------------------------------
    Write-Host 'Compressing ...' -ForegroundColor Cyan
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $archive -Force

    & icacls $archive /inheritance:r /grant:r 'SYSTEM:(F)' 'BUILTIN\Administrators:(F)' | Out-Null

    $sizeKb = [math]::Round((Get-Item $archive).Length / 1KB, 1)
    Write-Host ''
    Write-Host "Wrote $archive ($sizeKb KB)" -ForegroundColor Green
}
finally {
    # Always restart whatever we stopped, even if the backup failed partway.
    if ($stopped.Count -gt 0) {
        Write-Host 'Restarting bridges ...' -ForegroundColor Cyan
        foreach ($t in $stopped) {
            try { Start-ScheduledTask -TaskName $t; Write-Host "  started $t" }
            catch { Write-Warning "Could not restart $t - start it manually." }
        }
    }
    if (Test-Path $staging) {
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Prune -----------------------------------------------------------------
if ($KeepLast -gt 0) {
    $old = @(Get-ChildItem -Path $Destination -Filter 'xfinity-home-*.zip' |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepLast)
    foreach ($o in $old) {
        Remove-Item $o.FullName -Force
        Write-Host "Pruned $($o.Name)" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'THIS ARCHIVE CONTAINS SECRETS IN CLEARTEXT.' -ForegroundColor Yellow
Write-Host 'Z-Wave network keys, the MQTT password, and any camera passwords.' -ForegroundColor Yellow
Write-Host 'Anyone holding it can join your Z-Wave network and operate the lock.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Copy it somewhere off this machine - a coordinator failure and a disk' -ForegroundColor Cyan
Write-Host 'failure are the two cases this protects against, and a backup that only' -ForegroundColor Cyan
Write-Host 'exists on the failed disk protects against neither.' -ForegroundColor Cyan
