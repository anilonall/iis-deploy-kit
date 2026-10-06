<#
.SYNOPSIS
    Restores the application database from a backup (pg_dump -Fc), or test-restores a backup safely.

.DESCRIPTION
    -TestOnly (RECOMMENDED, production is not touched): the backup is restored into a temporary
    "<database>_restore_test" database, table and migration counts are reported and the temporary
    database is dropped. The PostgreSQL superuser password is read from the DPAPI file written by
    setup-server.ps1 (never printed).

    Real restore (CAREFUL: the current database content is REPLACED by the backup):
      1. A backup of the current state (backup.ps1 -Label manual).
      2. The API application pool is stopped (background workers included).
      3. pg_restore --clean --if-exists --single-transaction (as the application role; objects
         belong to that role).
      4. The pool is started and the health endpoint is checked.
    You are asked to type YES (not asked with -Force).

    The storage folder is not part of this script: README > Backups and restore.

.EXAMPLE
    C:\MyApp\bin\restore-db.ps1 -BackupFile C:\MyApp\backups\myapp-daily-20260101-030000.dump -TestOnly

.EXAMPLE
    C:\MyApp\bin\restore-db.ps1 -BackupFile C:\MyApp\backups\myapp-pre-deploy-20260101-120000.dump
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BackupFile,
    [switch]$TestOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployKit.Common.psm1') -Force -DisableNameChecking
Assert-DeployKitAdministrator
$cfg = Get-DeployKitSettings -ConfigPath (Join-Path $PSScriptRoot 'deploy.config.json')

if (-not (Test-Path -LiteralPath $BackupFile)) { throw "Backup file not found: $BackupFile" }
$BackupFile = (Resolve-Path -LiteralPath $BackupFile).Path
$pgRestore = Join-Path $cfg.PgBin 'pg_restore.exe'

Write-DeployKitStep 'Reading the backup (pg_restore --list)'
$null = & $pgRestore --list $BackupFile
if ($LASTEXITCODE -ne 0) { throw 'The backup file cannot be read; it may be corrupt.' }
Write-DeployKitOk 'Backup is readable.'

$db = Get-DeployKitDbConnection -Settings $cfg

if ($TestOnly) {
    $testDb = "$($cfg.DbName)_restore_test"
    $superPassword = Get-DeployKitPostgresSuperuserPassword -Settings $cfg
    Write-DeployKitStep "Test restore: $testDb"
    Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Sql "DROP DATABASE IF EXISTS $testDb; CREATE DATABASE $testDb WITH OWNER = $($db.User) ENCODING = 'UTF8' LOCALE_PROVIDER = 'builtin' BUILTIN_LOCALE = 'C.UTF-8' LC_COLLATE = 'C' LC_CTYPE = 'C' TEMPLATE = template0;" | Out-Null
    $previousPassword = $env:PGPASSWORD
    try {
        $env:PGPASSWORD = $db.Password
        & $pgRestore --no-owner --no-password --exit-on-error --host=$($db.Host) --port=$($db.Port) --username=$($db.User) --dbname=$testDb $BackupFile
        $restoreExit = $LASTEXITCODE
    }
    finally {
        $env:PGPASSWORD = $previousPassword
    }
    try {
        if ($restoreExit -ne 0) { throw "pg_restore failed (exit code $restoreExit)." }
        $tables = Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Database $testDb -Scalar `
            -Sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';"
        $hasHistory = Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Database $testDb -Scalar `
            -Sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__EFMigrationsHistory';"
        $migrations = if ($hasHistory -eq '1') {
            Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Database $testDb -Scalar -Sql 'SELECT count(*) FROM "__EFMigrationsHistory";'
        }
        else { '0' }
        Write-DeployKitOk "Test restore succeeded: $tables table(s), $migrations migration record(s)."
    }
    finally {
        Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Sql "DROP DATABASE IF EXISTS $testDb;" | Out-Null
        Write-DeployKitInfo "$testDb dropped."
    }
    return
}

Write-Host ''
Write-Host "WARNING: the content of database '$($db.Database)' will be REPLACED with this backup:" -ForegroundColor Red
Write-Host "  $BackupFile" -ForegroundColor Red
Write-Host '  The API is offline meanwhile. A backup of the current state is taken first.' -ForegroundColor Red
if (-not $Force) {
    $answer = Read-Host 'Type YES to continue'
    if ($answer -cne 'YES') { Write-Host 'Cancelled.'; return }
}

Write-DeployKitStep 'Backup of the current state'
& (Join-Path $PSScriptRoot 'backup.ps1') -Label manual

Write-DeployKitStep 'Stopping the API'
Stop-DeployKitAppPool -Name $cfg.ApiPool

Write-DeployKitStep 'Restoring (pg_restore --clean --if-exists --single-transaction)'
$previousPassword = $env:PGPASSWORD
try {
    $env:PGPASSWORD = $db.Password
    & $pgRestore --clean --if-exists --no-owner --no-password --single-transaction --exit-on-error `
        --host=$($db.Host) --port=$($db.Port) --username=$($db.User) --dbname=$($db.Database) $BackupFile
    $restoreExit = $LASTEXITCODE
}
finally {
    $env:PGPASSWORD = $previousPassword
}

Write-DeployKitStep 'Starting the API'
Start-DeployKitAppPool -Name $cfg.ApiPool
$healthy = Test-DeployKitApiHealth -Settings $cfg -Attempts 30 -DelaySeconds 2

if ($restoreExit -ne 0) {
    throw "pg_restore failed (exit code $restoreExit). Because of --single-transaction the database was NOT changed."
}
if (-not $healthy) {
    Show-DeployKitRecentApiEvents -Settings $cfg
    throw 'The restore completed but the API did not start healthy. If the backup has an older schema than this release, install the same package again (it applies the migrations).'
}
Write-DeployKitOk 'Restore complete.'
