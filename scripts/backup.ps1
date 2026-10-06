<#
.SYNOPSIS
    Database backup (pg_dump, custom format) + weekly storage archive + retention.

.DESCRIPTION
    * pg_dump -Fc (compressed) of the application database. Written to a .partial file first,
      verified with "pg_restore --list", then renamed: a broken dump never looks successful.
    * On backup.storageArchiveDay (default Sunday; daily runs only) the <root>\storage folder is
      zipped.
    * Retention (deploy.config.json "backup"): daily 14 days, pre-deploy and manual 30 days,
      storage archives 28 days; IIS access logs 90 days, script logs 60 days.

    The connection comes from api.connectionStringKey in <root>\config\app.env. The password
    is given to pg_dump only through this process's PGPASSWORD variable (never on the command
    line). Only Administrators + SYSTEM can access the backup folder.

    The scheduled task "\<appName>\<appName> Daily Backup" runs this as SYSTEM every night.

    IMPORTANT: a backup on the server does NOT protect against losing the server. Copy backups
    off the server regularly (README > Backups and restore).

.PARAMETER Label
    daily (scheduled task), pre-deploy (install-release.ps1) or manual.

.EXAMPLE
    C:\MyApp\bin\backup.ps1 -Label manual
#>
[CmdletBinding()]
param(
    [ValidateSet('daily', 'pre-deploy', 'manual')]
    [string]$Label = 'daily'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployKit.Common.psm1') -Force -DisableNameChecking
Assert-DeployKitAdministrator
$cfg = Get-DeployKitSettings -ConfigPath (Join-Path $PSScriptRoot 'deploy.config.json')

New-Item -ItemType Directory -Force -Path $cfg.Backups, $cfg.BackupLogs | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$logFile = Join-Path $cfg.BackupLogs ("backup-{0}.log" -f [DateTime]::UtcNow.ToString('yyyyMMdd'))

function Write-BackupLog([string]$Message) {
    $line = '{0:u} [{1}] {2}' -f [DateTime]::UtcNow, $Label, $Message
    Write-Host "[backup] $Message"
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

$pgDump = Join-Path $cfg.PgBin 'pg_dump.exe'
$pgRestore = Join-Path $cfg.PgBin 'pg_restore.exe'
foreach ($tool in $pgDump, $pgRestore) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "$tool not found (is PostgreSQL $($cfg.PgMajor) installed?)." }
}

$db = Get-DeployKitDbConnection -Settings $cfg
if (-not $db.Password) { throw 'The connection string has no password; pg_dump cannot authenticate.' }

$target = Join-Path $cfg.Backups ("{0}-{1}-{2}.dump" -f $db.Database, $Label, $stamp)
$partial = "$target.partial"

Write-BackupLog "Creating database backup: $(Split-Path $target -Leaf)"
$previousPassword = $env:PGPASSWORD
try {
    $env:PGPASSWORD = $db.Password
    & $pgDump --format=custom --compress=6 --no-owner --no-password `
        --host=$($db.Host) --port=$($db.Port) --username=$($db.User) --dbname=$($db.Database) --file=$partial
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        Write-BackupLog "ERROR: pg_dump failed (exit code $LASTEXITCODE)."
        throw 'pg_dump failed.'
    }
}
finally {
    $env:PGPASSWORD = $previousPassword
}

# A truncated/corrupt dump must not look successful: its table of contents must be readable.
$null = & $pgRestore --list $partial
if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Write-BackupLog 'ERROR: the backup file is not readable (pg_restore --list).'
    throw 'Backup verification failed.'
}
Move-Item -LiteralPath $partial -Destination $target -Force
$sizeMb = [Math]::Round((Get-Item -LiteralPath $target).Length / 1MB, 2)
Write-BackupLog "OK: $target ($sizeMb MB)"

# Weekly storage archive (daily runs only).
$archiveToday = $cfg.StorageArchiveDay -ne 'Never' -and [DateTime]::Now.DayOfWeek.ToString() -eq $cfg.StorageArchiveDay
if ($Label -eq 'daily' -and $archiveToday -and (Test-Path -LiteralPath $cfg.Storage) -and
    @(Get-ChildItem -LiteralPath $cfg.Storage -Force | Select-Object -First 1).Count -gt 0) {
    $zip = Join-Path $cfg.Backups ("storage-{0}.zip" -f $stamp)
    Write-BackupLog "Archiving storage: $(Split-Path $zip -Leaf)"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # ZipFile: faster than Compress-Archive on large folders and no 2 GB limit.
    [IO.Compression.ZipFile]::CreateFromDirectory($cfg.Storage, "$zip.partial", [IO.Compression.CompressionLevel]::Optimal, $true)
    Move-Item -LiteralPath "$zip.partial" -Destination $zip -Force
    Write-BackupLog "OK: $zip ($([Math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 2)) MB)"
}

# --- Retention (only names produced by this script) ------------------------------------------
$now = Get-Date
function Remove-Older([string]$Directory, [string]$Filter, [int]$Days) {
    if (-not (Test-Path -LiteralPath $Directory)) { return }
    Get-ChildItem -LiteralPath $Directory -Filter $Filter -File |
        Where-Object { $_.LastWriteTime -lt $now.AddDays(-$Days) } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force
            Write-BackupLog "Retention expired, deleted: $($_.Name)"
        }
}
foreach ($kind in $cfg.RetentionDays.Keys) {
    Remove-Older -Directory $cfg.Backups -Filter ("{0}-{1}-*.dump" -f $db.Database, $kind) -Days $cfg.RetentionDays[$kind]
}
Remove-Older -Directory $cfg.Backups -Filter 'storage-*.zip' -Days $cfg.StorageRetentionDays
Get-ChildItem -LiteralPath $cfg.Backups -Filter '*.partial' -File |
    Where-Object { $_.LastWriteTime -lt $now.AddHours(-2) } | Remove-Item -Force

# IIS access logs (IIS never deletes them) and script logs.
if (Test-Path -LiteralPath $cfg.IisLogs) {
    Get-ChildItem -LiteralPath $cfg.IisLogs -Filter '*.log' -File -Recurse |
        Where-Object { $_.LastWriteTime -lt $now.AddDays(-$cfg.IisLogRetentionDays) } | Remove-Item -Force
}
foreach ($dir in $cfg.BackupLogs, $cfg.DeployLogs, $cfg.SetupLogs) {
    if (Test-Path -LiteralPath $dir) {
        Get-ChildItem -LiteralPath $dir -Filter '*.log' -File |
            Where-Object { $_.Name -ne 'history.log' -and $_.LastWriteTime -lt $now.AddDays(-$cfg.LogRetentionDays) } | Remove-Item -Force
    }
}

Write-BackupLog 'Done.'
