<#
.SYNOPSIS
    A few minutes after boot, verifies that the API is up; otherwise restarts its application
    pool once.

.DESCRIPTION
    Why? IIS and PostgreSQL start in parallel when Windows boots. The API pool is AlwaysRunning +
    preload, so the app starts immediately; if its startup needs the database and PostgreSQL is
    not ready yet, the app fails (500.30) and may stay failed until the next recycle - which never
    comes, because periodic recycling is disabled for background workers. IIS Rapid-Fail
    Protection can also stop a pool after repeated failures. This script:
      1. makes sure the PostgreSQL service runs (waits up to 3 minutes, starts it if needed),
      2. starts the API pool if it is stopped,
      3. if the health endpoint is not 200, restarts the pool once and checks again.
    Results go to <root>\logs\startup-check.log.

    The scheduled task "\<appName>\<appName> Startup Check" (created by setup-server.ps1) runs it
    as SYSTEM 2 minutes after boot. It can also be run by hand.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployKit.Common.psm1') -Force -DisableNameChecking
$cfg = Get-DeployKitSettings -ConfigPath (Join-Path $PSScriptRoot 'deploy.config.json')
$logFile = Join-Path $cfg.Logs 'startup-check.log'

function Write-CheckLog([string]$Message) {
    Write-Host "[startup-check] $Message"
    Add-Content -LiteralPath $logFile -Value ('{0:u} {1}' -f [DateTime]::UtcNow, $Message) -Encoding UTF8
}

try {
    $service = Get-Service -Name $cfg.PgService -ErrorAction SilentlyContinue
    if ($service) {
        $deadline = (Get-Date).AddMinutes(3)
        while ($service.Status -ne 'Running' -and (Get-Date) -lt $deadline) {
            if ($service.Status -eq 'Stopped') { Start-Service -Name $cfg.PgService -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 5
            $service.Refresh()
        }
        Write-CheckLog "PostgreSQL service: $($service.Status)"
    }
    else {
        Write-CheckLog "WARNING: service $($cfg.PgService) not found."
    }

    $sitePath = Get-DeployKitSitePath -SiteName $cfg.ApiSite
    if (-not (Test-Path -LiteralPath (Join-Path $sitePath 'web.config'))) {
        Write-CheckLog 'No API release deployed yet; check skipped.'
        return
    }

    Start-DeployKitAppPool -Name $cfg.ApiPool
    if (Test-DeployKitApiHealth -Settings $cfg -Attempts 15 -DelaySeconds 4) {
        Write-CheckLog 'API healthy.'
        return
    }

    Write-CheckLog 'API unhealthy; restarting the application pool.'
    Stop-DeployKitAppPool -Name $cfg.ApiPool
    Start-DeployKitAppPool -Name $cfg.ApiPool
    if (Test-DeployKitApiHealth -Settings $cfg -Attempts 30 -DelaySeconds 4) {
        Write-CheckLog 'API healthy after the restart.'
    }
    else {
        Write-CheckLog 'ERROR: API still unhealthy after the restart. See Event Viewer > Windows Logs > Application (README > Troubleshooting).'
        exit 1
    }
}
catch {
    Write-CheckLog "ERROR: $($_.Exception.Message)"
    exit 1
}
