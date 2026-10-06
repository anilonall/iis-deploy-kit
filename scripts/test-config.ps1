<#
.SYNOPSIS
    Validates a deploy.config.json and prints the names and paths derived from it. Runs anywhere
    (no administrator rights, no IIS), e.g. on your machine before build-package.ps1.

.PARAMETER Config
    Path to deploy.config.json. Default: .\deploy.config.json (current directory).

.EXAMPLE
    .\scripts\test-config.ps1 -Config .\sample\deploy.config.json
#>
[CmdletBinding()]
param(
    [string]$Config = '.\deploy.config.json'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployKit.Common.psm1') -Force -DisableNameChecking

$Config = (Resolve-Path -LiteralPath $Config).Path
Write-DeployKitStep "Validating $Config (kit $(Get-DeployKitVersion))"
$cfg = Get-DeployKitSettings -ConfigPath $Config
Write-DeployKitOk 'Configuration is valid.'

Write-DeployKitStep 'Derived settings'
$rows = [ordered]@{
    'App name'             = $cfg.AppName
    'Server root'          = $cfg.Root
    'Settings file'        = $cfg.AppEnv
    'API site / pool'      = "$($cfg.ApiSite) / $($cfg.ApiPool)"
    'Web site / pool'      = "$($cfg.WebSite) / $($cfg.WebPool)"
    'API host'             = $cfg.ApiHost
    'Web hosts'            = ($cfg.WebHosts -join ', ')
    'Health check'         = "https://$($cfg.ApiHost)$($cfg.HealthPath)"
    'Event log source'     = $cfg.EventSource
    'PostgreSQL'           = "$($cfg.PgMajor) (service $($cfg.PgService), port $($cfg.PgPort))"
    'Database / role'      = "$($cfg.DbName) / $($cfg.DbUser)"
    'Required app.env keys' = ($cfg.RequiredEnvKeys -join ', ')
    'Always running pool'  = $cfg.AlwaysRunning
    'Migrations'           = $(if ($cfg.MigrationsEnabled) { "$($cfg.MigrationsContext) ($($cfg.MigrationsProject))" } else { 'disabled' })
    'Frontend'             = $(if ($cfg.FrontendEnabled) { "$($cfg.FrontendPath) -> $($cfg.FrontendOutput), $($cfg.ApiBaseUrlEnvVar)=$($cfg.ApiOrigin)" } else { 'disabled' })
    'Scheduled tasks'      = "$($cfg.TaskPath) (backup at $($cfg.BackupTime))"
    'Package name'         = "$($cfg.PackagePrefix)-<yyyyMMdd-HHmmss>-<commit>.zip"
}
foreach ($key in $rows.Keys) { Write-DeployKitInfo ('{0,-22}: {1}' -f $key, $rows[$key]) }

$missing = New-Object System.Collections.Generic.List[string]
foreach ($pair in @(@($cfg.ApiProject, 'api.project'), @($cfg.MigrationsProject, 'migrations.project'), @($cfg.MigrationsStartup, 'migrations.startupProject'))) {
    if ($pair[1] -ne 'api.project' -and -not $cfg.MigrationsEnabled) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $cfg.ConfigDirectory $pair[0]))) { $missing.Add("$($pair[1]): $($pair[0])") }
}
if ($cfg.FrontendEnabled -and -not (Test-Path -LiteralPath (Join-Path $cfg.ConfigDirectory $cfg.FrontendPath))) { $missing.Add("frontend.path: $($cfg.FrontendPath)") }
if ($cfg.EnvTemplate -and -not (Test-Path -LiteralPath (Join-Path $cfg.ConfigDirectory $cfg.EnvTemplate))) { $missing.Add("api.envTemplate: $($cfg.EnvTemplate)") }
foreach ($m in $missing) { Write-Warning "Path not found on this machine (relative to $($cfg.ConfigDirectory)): $m" }
