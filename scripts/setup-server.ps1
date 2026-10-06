<#
.SYNOPSIS
    One-time (and idempotent) server setup: Windows Server 2025 + IIS + ASP.NET Core Hosting
    Bundle + PostgreSQL, driven by deploy.config.json. Run it in an ELEVATED PowerShell on the
    server, from the "scripts" folder of an extracted package. Re-running it is safe.

.DESCRIPTION
    What it does (details: README.md):
      1. Folders under <root> (default C:\<appName>) and NTFS permissions.
      2. IIS role and features: static content, default document, HTTP errors/redirect, static
         compression, request filtering, logging, Application Initialization, management console
         and scripting tools. (WebSockets is NOT installed; add Web-WebSockets if you need it.)
      3. IIS URL Rewrite 2.1 (official MSI; pinned SHA-256 + Authenticode signature).
      4. ASP.NET Core Hosting Bundle (pinned version + SHA-512 + signature), then
         "net stop was /y" + "net start w3svc".
      5. PostgreSQL (EDB unattended installer; SHA-256 + signature). The superuser password is
         random and stored ONLY DPAPI-encrypted in a file readable by Administrators + SYSTEM.
         Listens on localhost only; the port is blocked in the firewall.
      6. Database + login role (random password) and <root>\config\app.env (from the template,
         tokens filled on KEY=VALUE lines only).
      7. IIS server settings, application pools and sites (HTTP bindings only; win-acme adds
         HTTPS later), placeholder page. The API pool is tuned for background workers.
      8. Windows Event Log source, firewall (80/443 open, PostgreSQL closed), win-acme download,
         management scripts in <root>\bin, scheduled tasks (daily backup, startup check).
      9. Copies app.env values into the API application pool (set-config.ps1).

    It NEVER touches an existing database, existing passwords, an existing app.env, deployed
    releases or the HTTPS bindings added by win-acme. It does NOT request certificates (DNS must
    point to the server first) and does NOT deploy the application (install-release.ps1 does).

    Needs outbound internet access (official download URLs). Installers are kept in
    <root>\tools\downloads and are not downloaded again on re-runs.

.PARAMETER Force
    Allow replacing newer management scripts in <root>\bin with the (older) ones next to this
    script. Without it an older kit never overwrites a newer one.

.EXAMPLE
    # In the extracted package (e.g. C:\Deploy\myapp-20260101-120000-abc1234\scripts):
    powershell -ExecutionPolicy Bypass -File .\setup-server.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'DeployKit.Common.psm1') -Force -DisableNameChecking
Assert-DeployKitAdministrator
$cfg = Get-DeployKitSettings -ConfigPath (Join-Path $PSScriptRoot 'deploy.config.json')
$raw = $cfg.Raw
$apphost = 'MACHINE/WEBROOT/APPHOST'

New-Item -ItemType Directory -Force -Path $cfg.Root, $cfg.Logs, $cfg.SetupLogs | Out-Null
Start-Transcript -Path (Join-Path $cfg.SetupLogs ("setup-{0}.log" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))) | Out-Null

try {
    # --- 0. Pre-flight -------------------------------------------------------------------
    Write-DeployKitStep "Pre-flight ($($cfg.AppName), kit $($cfg.KitVersion))"
    $os = Get-CimInstance Win32_OperatingSystem
    Write-DeployKitInfo "Operating system: $($os.Caption) (build $($os.BuildNumber))"
    if ($os.ProductType -eq 1) { throw 'This script is for Windows SERVER (a client edition was detected).' }
    if ([int]$os.BuildNumber -lt 26100) {
        Write-Warning 'Tested on Windows Server 2025 (build 26100+). This version is untested; continuing.'
    }
    foreach ($file in (Get-DeployKitManagedFiles)) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) { throw "$file not found next to this script. Use the complete 'scripts' folder of the package." }
    }

    # --- 1. Folders (pool permissions follow in step 8) -------------------------------------
    Write-DeployKitStep 'Folders'
    $dirs = @($cfg.Bin, $cfg.Config, $cfg.ApiReadableDir, $cfg.IisHistory, $cfg.Storage, $cfg.Backups, $cfg.IisLogs,
        $cfg.StdoutLogs, $cfg.DeployLogs, $cfg.BackupLogs, $cfg.Tools, $cfg.Downloads, $cfg.Packages, $cfg.ApiReleases, $cfg.WebReleases)
    foreach ($dir in $dirs) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Root: Administrators + SYSTEM only (inheritance removed; pool rights are added below).
    Set-DeployKitPrivateAcl -Path $cfg.Root
    Write-DeployKitOk "$($cfg.Root) ready (Administrators + SYSTEM only)."

    # --- 2. IIS role and features ---------------------------------------------------------
    Write-DeployKitStep 'IIS role and features'
    $features = @(
        'Web-Server', 'Web-WebServer', 'Web-Common-Http', 'Web-Default-Doc', 'Web-Static-Content',
        'Web-Http-Errors', 'Web-Http-Redirect', 'Web-Stat-Compression', 'Web-Filtering',
        'Web-Http-Logging', 'Web-AppInit', 'Web-Mgmt-Console', 'Web-Scripting-Tools'
    )
    $missing = @($features | Where-Object { -not (Get-WindowsFeature -Name $_).Installed })
    if ($missing.Count -gt 0) {
        Write-DeployKitInfo ('Installing: ' + ($missing -join ', '))
        $result = Install-WindowsFeature -Name $missing
        if (-not $result.Success) { throw 'IIS features could not be installed.' }
        if ($result.RestartNeeded -eq 'Yes') { Write-Warning 'Windows requests a restart. Restart the server when this script finishes and run it again.' }
    }
    Write-DeployKitOk 'IIS features installed.'
    Import-DeployKitIis

    # --- 3. URL Rewrite 2.1 --------------------------------------------------------------
    Write-DeployKitStep 'IIS URL Rewrite 2.1'
    if (Test-Path -LiteralPath (Join-Path $env:windir 'System32\inetsrv\rewrite.dll')) {
        Write-DeployKitOk 'Already installed.'
    }
    else {
        $rw = $raw.downloads.urlRewrite
        $msi = Get-DeployKitVerifiedDownload -Url $rw.url -Destination (Join-Path $cfg.Downloads (Split-Path $rw.url -Leaf)) `
            -Sha256 $rw.sha256 -Signer (Get-DeployKitProperty $rw 'signer' 'Microsoft Corporation')
        $msiLog = Join-Path $cfg.SetupLogs 'urlrewrite-install.log'
        $process = Start-Process -FilePath msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart', '/l*v', "`"$msiLog`"") -Wait -PassThru
        if (@(0, 3010) -notcontains $process.ExitCode) { throw "URL Rewrite installation failed (msiexec $($process.ExitCode)). Log: $msiLog" }
        Write-DeployKitOk 'Installed.'
    }

    # --- 4. ASP.NET Core Hosting Bundle (ASP.NET Core Module V2 + runtime) -----------------
    $hb = $raw.downloads.hostingBundle
    $hbVersion = [string]$hb.version
    Write-DeployKitStep "ASP.NET Core Hosting Bundle $hbVersion"
    $ancm = Join-Path $env:ProgramFiles 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
    $runtimeDir = Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.AspNetCore.App'
    $hbMajor = ([version]$hbVersion).Major
    $installedRuntimes = @()
    if (Test-Path -LiteralPath $runtimeDir) {
        $installedRuntimes = @(Get-ChildItem -LiteralPath $runtimeDir -Directory | Where-Object { $_.Name -like "$hbMajor.*" } |
            ForEach-Object { $v = $null; if ([version]::TryParse($_.Name, [ref]$v)) { $v } })
    }
    # Skipped when this version (or newer, same major) is installed. To update .NET: raise
    # downloads.hostingBundle.version in deploy.config.json and run this script again.
    $upToDate = @($installedRuntimes | Where-Object { $_ -ge [version]$hbVersion }).Count -gt 0
    if ((Test-Path -LiteralPath $ancm) -and $upToDate) {
        Write-DeployKitOk "ASP.NET Core Module V2 and runtime installed ($(($installedRuntimes | Sort-Object | ForEach-Object { $_.ToString() }) -join ', '))."
    }
    else {
        $hbUrl = Get-DeployKitProperty $hb 'url'
        $hbSha512 = Get-DeployKitProperty $hb 'sha512'
        if (-not $hbUrl) {
            # Official release metadata: URL and SHA-512 come from Microsoft.
            $channel = '{0}.{1}' -f ([version]$hbVersion).Major, ([version]$hbVersion).Minor
            $meta = Invoke-RestMethod -Uri "https://builds.dotnet.microsoft.com/dotnet/release-metadata/$channel/releases.json" -UseBasicParsing
            $release = $meta.releases | Where-Object { $_.'aspnetcore-runtime'.version -eq $hbVersion } | Select-Object -First 1
            if (-not $release) { throw "Hosting Bundle $hbVersion is not in the official release list." }
            $file = $release.'aspnetcore-runtime'.files | Where-Object { $_.name -eq 'dotnet-hosting-win.exe' } | Select-Object -First 1
            $hbUrl = $file.url
            $hbSha512 = $file.hash
        }
        $installer = Get-DeployKitVerifiedDownload -Url $hbUrl -Destination (Join-Path $cfg.Downloads "dotnet-hosting-$hbVersion-win.exe") `
            -Sha512 $hbSha512 -Signer (Get-DeployKitProperty $hb 'signer' 'Microsoft Corporation')
        $hbLog = Join-Path $cfg.SetupLogs 'hosting-bundle-install.log'
        # Same version installed but ANCM missing (bundle installed BEFORE IIS): /repair registers it.
        $sameVersion = @($installedRuntimes | Where-Object { $_ -eq [version]$hbVersion }).Count -gt 0
        $mode = if ($sameVersion -and -not (Test-Path -LiteralPath $ancm)) { '/repair' } else { '/install' }
        # OPT_NO_X86=1: no 32-bit runtime (the pools are 64-bit).
        $process = Start-Process -FilePath $installer -ArgumentList @($mode, '/quiet', '/norestart', 'OPT_NO_X86=1', '/log', "`"$hbLog`"") -Wait -PassThru
        if (@(0, 3010) -notcontains $process.ExitCode) { throw "Hosting Bundle installation failed (exit $($process.ExitCode)). Log: $hbLog" }
        # Let IIS pick up the new module and PATH (Microsoft's documented step).
        & net.exe stop was /y | Out-Null
        & net.exe start w3svc | Out-Null
        if (-not (Test-Path -LiteralPath $ancm)) { throw 'Hosting Bundle installed, but ASP.NET Core Module V2 was not found.' }
        Write-DeployKitOk 'Installed; IIS restarted (net stop was /y; net start w3svc).'
    }

    # --- 5. PostgreSQL ----------------------------------------------------------------------
    $pg = $raw.database.postgres
    $pgVersion = [string]$pg.installerVersion
    Write-DeployKitStep "PostgreSQL $($cfg.PgMajor)"
    $pgService = Get-Service -Name $cfg.PgService -ErrorAction SilentlyContinue
    if (-not $pgService) {
        if (Test-Path -LiteralPath $cfg.PgSuperuserFile) {
            throw "Service $($cfg.PgService) does not exist but $($cfg.PgSuperuserFile) does. A previous installation may have been interrupted: README > Troubleshooting."
        }
        $pgUrl = Get-DeployKitProperty $pg 'installerUrl' "https://get.enterprisedb.com/postgresql/postgresql-$pgVersion-windows-x64.exe"
        $pgInstaller = Get-DeployKitVerifiedDownload -Url $pgUrl -Destination (Join-Path $cfg.Downloads "postgresql-$pgVersion-windows-x64.exe") `
            -Sha256 (Get-DeployKitProperty $pg 'installerSha256' '') -Signer (Get-DeployKitProperty $pg 'signer' 'EnterpriseDB Corporation')

        # Superuser password: written to the DPAPI file FIRST (not lost if the installer fails).
        $superPassword = New-DeployKitSecret -Length 40
        Protect-DeployKitText -PlainText $superPassword -Path $cfg.PgSuperuserFile

        # Options go through a protected option file, not the command line (process list).
        $optionFile = Join-Path $cfg.Config 'pg-install-options.txt'
        $options = @(
            "superpassword=$superPassword",
            'superaccount=postgres',
            "serverport=$($cfg.PgPort)",
            "servicename=$($cfg.PgService)",
            "prefix=$($cfg.PgPrefix)",
            "datadir=$($cfg.PgPrefix)\data",
            'disable-components=pgAdmin,stackbuilder',
            'install_runtimes=1',
            'create_shortcuts=0'
        )
        [IO.File]::WriteAllLines($optionFile, $options)
        try {
            Write-DeployKitInfo 'Unattended installation started (this can take a few minutes)...'
            $process = Start-Process -FilePath $pgInstaller -ArgumentList @('--mode', 'unattended', '--unattendedmodeui', 'none', '--optionfile', "`"$optionFile`"") -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "PostgreSQL installation failed (exit $($process.ExitCode)). Log: $env:TEMP\install-postgresql.log" }
        }
        finally {
            # The option file contains the password: overwrite, then delete.
            if (Test-Path -LiteralPath $optionFile) {
                [IO.File]::WriteAllText($optionFile, ('x' * 256))
                Remove-Item -LiteralPath $optionFile -Force
            }
        }
        $pgService = Get-Service -Name $cfg.PgService -ErrorAction Stop
        Write-DeployKitOk "Installed: service $($cfg.PgService) (account NT AUTHORITY\NetworkService)."
    }
    else {
        Write-DeployKitOk "Already installed: $($cfg.PgService)."
    }
    Set-Service -Name $cfg.PgService -StartupType Automatic
    if ($pgService.Status -ne 'Running') { Start-Service -Name $cfg.PgService }
    $superPassword = Get-DeployKitPostgresSuperuserPassword -Settings $cfg

    # Settings via ALTER SYSTEM (postgresql.auto.conf; the main file is not edited).
    $ramGb = [Math]::Max(1, [Math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB))
    $sharedBuffersMb = [int][Math]::Min(1024, [Math]::Max(128, $ramGb * 1024 / 8))   # ~12% of RAM on Windows, max 1 GB
    $effectiveCacheMb = [int]($ramGb * 1024 / 2)
    $before = Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Scalar `
        -Sql "SELECT current_setting('listen_addresses') || '|' || (SELECT setting FROM pg_settings WHERE name = 'shared_buffers');"
    $desiredSharedBuffersPages = [string]($sharedBuffersMb * 128)   # 8 kB pages
    $pgSql = @"
ALTER SYSTEM SET listen_addresses = 'localhost';
ALTER SYSTEM SET shared_buffers = '${sharedBuffersMb}MB';
ALTER SYSTEM SET effective_cache_size = '${effectiveCacheMb}MB';
ALTER SYSTEM SET maintenance_work_mem = '256MB';
ALTER SYSTEM SET work_mem = '16MB';
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET wal_compression = on;
ALTER SYSTEM SET timezone = 'UTC';
ALTER SYSTEM SET log_timezone = 'UTC';
ALTER SYSTEM SET log_parameter_max_length = 0;
ALTER SYSTEM SET log_parameter_max_length_on_error = 0;
SELECT pg_reload_conf();
"@
    Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Sql $pgSql | Out-Null
    if ($before -ne "localhost|$desiredSharedBuffersPages") {
        Write-DeployKitInfo 'A setting that needs a restart changed (listen_addresses / shared_buffers); restarting the service.'
        Restart-Service -Name $cfg.PgService -Force
        Start-Sleep -Seconds 3
    }
    Write-DeployKitOk "Settings: localhost only, shared_buffers ${sharedBuffersMb}MB, UTC, query parameters never logged."

    # --- 6. Database, role and app.env -------------------------------------------------------
    Write-DeployKitStep 'Database, role and app.env'
    $roleExists = (Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Scalar -Sql "SELECT count(*) FROM pg_roles WHERE rolname = '$($cfg.DbUser)';") -eq '1'
    $dbExists = (Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Scalar -Sql "SELECT count(*) FROM pg_database WHERE datname = '$($cfg.DbName)';") -eq '1'

    if (Test-Path -LiteralPath $cfg.AppEnv) {
        Write-DeployKitOk "$($cfg.AppEnv) already exists; left untouched (passwords and keys are kept)."
        if (-not $roleExists) { throw "$($cfg.AppEnv) exists but role '$($cfg.DbUser)' does not. Back the file up, delete it and run this script again." }
    }
    else {
        # Hex only: no escaping issues in the connection string or in SQL.
        $dbPassword = New-DeployKitSecret -Length 48 -Hex
        if ($roleExists) {
            Write-DeployKitInfo "Role '$($cfg.DbUser)' exists but app.env does not: resetting the role's password."
            Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Sql "ALTER ROLE $($cfg.DbUser) WITH LOGIN PASSWORD '$dbPassword';" | Out-Null
        }
        else {
            Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Sql "CREATE ROLE $($cfg.DbUser) WITH LOGIN PASSWORD '$dbPassword' NOSUPERUSER NOCREATEDB NOCREATEROLE;" | Out-Null
        }
        $template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'app.env.example'), [Text.Encoding]::UTF8)
        # Tokens are replaced on KEY=VALUE lines only, never inside comments.
        $expanded = Expand-DeployKitEnvTemplate -Text $template -Tokens (Get-DeployKitEnvTokens -Settings $cfg) -DbPassword $dbPassword
        # <root>\config: Administrators + SYSTEM only (inherited from the root).
        [IO.File]::WriteAllText($cfg.AppEnv, $expanded.Text, (New-Object System.Text.UTF8Encoding($false)))
        Remove-Variable dbPassword, template, expanded
        Write-DeployKitOk "$($cfg.AppEnv) created (database password and generated secrets are random; values are not shown)."
    }

    if (-not $dbExists) {
        # Windows has no "C.UTF-8" OS locale; PostgreSQL 17+ builtin provider gives the same
        # behavior independent of the OS (identical to a Linux installation).
        Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Sql @"
CREATE DATABASE $($cfg.DbName) WITH OWNER = $($cfg.DbUser) ENCODING = 'UTF8' LOCALE_PROVIDER = 'builtin' BUILTIN_LOCALE = 'C.UTF-8' LC_COLLATE = 'C' LC_CTYPE = 'C' TEMPLATE = template0;
"@ | Out-Null
        Write-DeployKitOk "Database '$($cfg.DbName)' created."
    }
    Invoke-DeployKitPsql -Settings $cfg -User 'postgres' -Password $superPassword -Database $cfg.DbName -Sql @"
ALTER SCHEMA public OWNER TO $($cfg.DbUser);
REVOKE ALL ON DATABASE $($cfg.DbName) FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE $($cfg.DbName) TO $($cfg.DbUser);
"@ | Out-Null
    Remove-Variable superPassword

    # --- 7. IIS: server settings, pools, sites -------------------------------------------
    Write-DeployKitStep 'IIS server settings'
    # IIS configuration history (automatic backups of applicationHost.config) goes to a protected
    # folder: pool environment variables (= secrets) stay readable by administrators only.
    Set-WebConfigurationProperty -PSPath $apphost -Filter 'system.applicationHost/configHistory' -Name 'path' -Value $cfg.IisHistory
    # Remove X-Powered-By; never send the Server header.
    if (Get-WebConfigurationProperty -PSPath $apphost -Filter "system.webServer/httpProtocol/customHeaders/add[@name='X-Powered-By']" -Name 'name' -ErrorAction SilentlyContinue) {
        Remove-WebConfigurationProperty -PSPath $apphost -Filter 'system.webServer/httpProtocol/customHeaders' -Name '.' -AtElement @{ name = 'X-Powered-By' }
    }
    Set-WebConfigurationProperty -PSPath $apphost -Filter 'system.webServer/security/requestFiltering' -Name 'removeServerHeader' -Value $true
    # Static compression from the first request and for the types an SPA uses. The list order
    # matters ("*/*" disabled at the end), so new types are inserted at the top.
    Set-WebConfigurationProperty -PSPath $apphost -Filter 'system.webServer/serverRuntime' -Name 'frequentHitThreshold' -Value 1
    foreach ($mime in 'application/json', 'application/manifest+json', 'image/svg+xml', 'application/xml', 'text/xml') {
        $exists = Get-WebConfigurationProperty -PSPath $apphost -Filter "system.webServer/httpCompression/staticTypes/add[@mimeType='$mime']" -Name 'mimeType' -ErrorAction SilentlyContinue
        if (-not $exists) {
            Add-WebConfigurationProperty -PSPath $apphost -Filter 'system.webServer/httpCompression/staticTypes' -Name '.' -AtIndex 0 -Value @{ mimeType = $mime; enabled = 'True' }
        }
    }
    # The default site (*:80 catches every host name) is stopped, not deleted.
    $default = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    if ($default) {
        Set-ItemProperty -LiteralPath 'IIS:\Sites\Default Web Site' -Name serverAutoStart -Value $false
        if ($default.State -ne 'Stopped') { Stop-Website -Name 'Default Web Site' }
        Write-DeployKitOk "'Default Web Site' stopped (no auto start)."
    }

    Write-DeployKitStep 'IIS application pools'
    foreach ($poolName in $cfg.ApiPool, $cfg.WebPool) {
        if (-not (Test-Path -LiteralPath "IIS:\AppPools\$poolName")) { New-WebAppPool -Name $poolName | Out-Null }
        $poolPath = "IIS:\AppPools\$poolName"
        # "No Managed Code": the .NET Framework CLR is not loaded (ASP.NET Core brings its own runtime).
        Set-ItemProperty -LiteralPath $poolPath -Name managedRuntimeVersion -Value ''
        Set-ItemProperty -LiteralPath $poolPath -Name managedPipelineMode -Value 'Integrated'
        Set-ItemProperty -LiteralPath $poolPath -Name enable32BitAppOnWin64 -Value $false
        Set-ItemProperty -LiteralPath $poolPath -Name processModel.identityType -Value 'ApplicationPoolIdentity'
        Set-ItemProperty -LiteralPath $poolPath -Name processModel.loadUserProfile -Value $true
        Set-ItemProperty -LiteralPath $poolPath -Name autoStart -Value $true
    }
    $apiPoolPath = "IIS:\AppPools\$($cfg.ApiPool)"
    if ($cfg.AlwaysRunning) {
        # API pool for an app with BACKGROUND WORKERS (hosted services, schedulers, queues). IIS
        # defaults (shut down after 20 idle minutes, recycle every 29 hours, start on first
        # request) would silently stop those workers at night. Therefore:
        #   * startMode=AlwaysRunning          - the worker process starts with IIS/WAS,
        #   * idleTimeout=0                    - never shut down for being idle,
        #   * periodicRestart time/requests/memory/schedule = off,
        #   * disallowOverlappingRotation=true - on a recycle the old process stops BEFORE the new
        #     one starts: never two schedulers at once (cost: a few seconds of 503 on a recycle),
        #   * preloadEnabled=true on the site (below) - Application Initialization starts the app
        #     without waiting for a request,
        #   * a scheduled startup check after boot (startup-check.ps1) restarts the pool once if
        #     the app failed to start because PostgreSQL was not up yet.
        Set-ItemProperty -LiteralPath $apiPoolPath -Name startMode -Value 'AlwaysRunning'
        Set-ItemProperty -LiteralPath $apiPoolPath -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
        Set-ItemProperty -LiteralPath $apiPoolPath -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
        Set-ItemProperty -LiteralPath $apiPoolPath -Name recycling.periodicRestart.requests -Value 0
        Set-ItemProperty -LiteralPath $apiPoolPath -Name recycling.periodicRestart.memory -Value 0
        Set-ItemProperty -LiteralPath $apiPoolPath -Name recycling.periodicRestart.privateMemory -Value 0
        Clear-WebConfiguration -PSPath $apphost -Filter "system.applicationHost/applicationPools/add[@name='$($cfg.ApiPool)']/recycling/periodicRestart/schedule" -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath $apiPoolPath -Name recycling.disallowOverlappingRotation -Value $true
        Write-DeployKitOk "$($cfg.ApiPool): No Managed Code, AlwaysRunning, no idle shutdown, no periodic recycling, no overlapping recycle."
    }
    else {
        Write-DeployKitOk "$($cfg.ApiPool): No Managed Code (server.alwaysRunning=false: IIS default idle/recycle behavior)."
    }
    Set-ItemProperty -LiteralPath $apiPoolPath -Name recycling.logEventOnRecycle -Value 'Time,Requests,Schedule,Memory,IsapiUnhealthy,OnDemand,ConfigChange,PrivateMemory'
    Write-DeployKitOk "$($cfg.WebPool): No Managed Code (static site)."

    Write-DeployKitStep 'IIS sites (HTTP only; win-acme adds the HTTPS bindings)'
    $placeholderApi = Join-Path $cfg.ApiReleases '00000000-000000-empty'
    $placeholderWeb = Join-Path $cfg.WebReleases '00000000-000000-placeholder'
    New-Item -ItemType Directory -Force -Path $placeholderApi, $placeholderWeb | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $placeholderWeb 'index.html'))) {
        $title = [Net.WebUtility]::HtmlEncode($cfg.AppName)
        $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>$title</title>
<style>
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
         font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
         background: #f4f7fb; color: #1f2937; }
  main { text-align: center; padding: 24px; }
  h1 { margin: 0 0 8px; font-size: 28px; }
  p { margin: 0; color: #4b5563; }
</style>
</head>
<body>
<main>
  <h1>$title</h1>
  <p>Coming soon.</p>
</main>
</body>
</html>
"@
        [IO.File]::WriteAllText((Join-Path $placeholderWeb 'index.html'), $html, (New-Object System.Text.UTF8Encoding($false)))
    }

    $sites = @(
        @{ Name = $cfg.ApiSite; Pool = $cfg.ApiPool; Path = $placeholderApi; Hosts = @($cfg.ApiHost) },
        @{ Name = $cfg.WebSite; Pool = $cfg.WebPool; Path = $placeholderWeb; Hosts = @($cfg.WebHosts) }
    )
    foreach ($site in $sites) {
        if (-not (Get-Website -Name $site.Name -ErrorAction SilentlyContinue)) {
            New-Website -Name $site.Name -PhysicalPath $site.Path -ApplicationPool $site.Pool -HostHeader $site.Hosts[0] -Port 80 -IPAddress '*' | Out-Null
            Write-DeployKitOk "Site created: $($site.Name) -> $($site.Path)"
        }
        else {
            Set-ItemProperty -LiteralPath "IIS:\Sites\$($site.Name)" -Name applicationPool -Value $site.Pool
            Write-DeployKitOk "Site exists (deployed release untouched): $($site.Name)"
        }
        foreach ($h in $site.Hosts) {
            if (-not (Get-WebBinding -Name $site.Name -Protocol http -Port 80 -HostHeader $h)) {
                New-WebBinding -Name $site.Name -Protocol http -Port 80 -IPAddress '*' -HostHeader $h
            }
        }
        $sitePath = "IIS:\Sites\$($site.Name)"
        Set-ItemProperty -LiteralPath $sitePath -Name serverAutoStart -Value $true
        # Anonymous requests read files as the pool identity (not IUSR): one identity to grant.
        Set-WebConfigurationProperty -PSPath $apphost -Location $site.Name -Filter 'system.webServer/security/authentication/anonymousAuthentication' -Name 'userName' -Value ''
        # IIS access log in <root>\logs\iis WITHOUT query string and Referer (one-time tokens in
        # links, e.g. password reset, must not end up in log files).
        Set-ItemProperty -LiteralPath $sitePath -Name logFile.directory -Value $cfg.IisLogs
        Set-ItemProperty -LiteralPath $sitePath -Name logFile.logExtFileFlags -Value 'Date,Time,ClientIP,ServerIP,Method,UriStem,HttpStatus,HttpSubStatus,Win32Status,TimeTaken,ServerPort,UserAgent,Host'
        Set-ItemProperty -LiteralPath $sitePath -Name logFile.localTimeRollover -Value $false
    }
    # API: preload with Application Initialization (no waiting for the first request).
    Set-ItemProperty -LiteralPath "IIS:\Sites\$($cfg.ApiSite)" -Name applicationDefaults.preloadEnabled -Value $cfg.AlwaysRunning
    Set-WebConfigurationProperty -PSPath $apphost -Filter "system.applicationHost/sites/site[@name='$($cfg.ApiSite)']/application[@path='/']" -Name 'preloadEnabled' -Value $cfg.AlwaysRunning
    foreach ($site in $sites) {
        if ((Get-Website -Name $site.Name).State -ne 'Started') { Start-Website -Name $site.Name -ErrorAction SilentlyContinue }
    }

    # --- 8. NTFS permissions (pool identities exist now) -----------------------------------
    Write-DeployKitStep 'NTFS permissions'
    $apiIdentity = "IIS AppPool\$($cfg.ApiPool)"
    $webIdentity = "IIS AppPool\$($cfg.WebPool)"
    # Root and parents: list "this folder" only (not inherited by children).
    Invoke-DeployKitIcacls -Arguments @($cfg.Root, '/grant', "${apiIdentity}:(RX)", "${webIdentity}:(RX)")
    Invoke-DeployKitIcacls -Arguments @($cfg.ApiRoot, '/grant', "${apiIdentity}:(RX)")
    Invoke-DeployKitIcacls -Arguments @($cfg.WebRoot, '/grant', "${webIdentity}:(RX)")
    # Application files: read + execute (no write).
    Invoke-DeployKitIcacls -Arguments @($cfg.ApiReleases, '/grant', "${apiIdentity}:(OI)(CI)RX")
    Invoke-DeployKitIcacls -Arguments @($cfg.WebReleases, '/grant', "${webIdentity}:(OI)(CI)RX")
    # Storage and (temporary diagnosis) ANCM stdout log: modify.
    Invoke-DeployKitIcacls -Arguments @($cfg.Storage, '/grant', "${apiIdentity}:(OI)(CI)M")
    Invoke-DeployKitIcacls -Arguments @($cfg.Logs, '/grant', "${apiIdentity}:(RX)")
    Invoke-DeployKitIcacls -Arguments @($cfg.StdoutLogs, '/grant', "${apiIdentity}:(OI)(CI)M")
    # Credential files the API must read (never app.env itself): read only.
    Invoke-DeployKitIcacls -Arguments @($cfg.ApiReadableDir, '/grant', "${apiIdentity}:(OI)(CI)RX")
    Write-DeployKitOk 'releases: pools read; storage + logs\stdout: API writes; config\api-readable: API reads; app.env and backups: administrators only.'

    # --- 9. Windows Event Log source ---------------------------------------------------------
    Write-DeployKitStep 'Event log source'
    if (-not [Diagnostics.EventLog]::SourceExists($cfg.EventSource)) {
        New-EventLog -LogName Application -Source $cfg.EventSource
    }
    # At least 64 MB so older entries are not overwritten too quickly.
    $appLog = Get-WinEvent -ListLog Application
    if ($appLog.MaximumSizeInBytes -lt 64MB) { Limit-EventLog -LogName Application -MaximumSize 64MB }
    Write-DeployKitOk "Source '$($cfg.EventSource)' (Application log). The app writes warnings and errors here."

    # --- 10. Firewall ------------------------------------------------------------------------
    Write-DeployKitStep 'Windows Firewall'
    $rules = @(
        @{ Name = "$($cfg.AppName)-HTTP-In"; Display = "$($cfg.AppName) - HTTP (80)"; Port = 80 },
        @{ Name = "$($cfg.AppName)-HTTPS-In"; Display = "$($cfg.AppName) - HTTPS (443)"; Port = 443 }
    )
    foreach ($rule in $rules) {
        if (-not (Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name $rule.Name -DisplayName $rule.Display -Direction Inbound -Protocol TCP -LocalPort $rule.Port -Action Allow -Profile Any | Out-Null
        }
    }
    # PostgreSQL closed from outside: allow rules created by the installer are disabled and an
    # explicit block rule is added (block wins over allow on Windows). It listens on localhost anyway.
    Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq "$($cfg.PgPort)" } |
        Get-NetFirewallRule | Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.Enabled -eq 'True' } |
        ForEach-Object { Disable-NetFirewallRule -Name $_.Name; Write-DeployKitInfo "Disabled: $($_.DisplayName)" }
    $blockName = "$($cfg.AppName)-PostgreSQL-Block"
    if (-not (Get-NetFirewallRule -Name $blockName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $blockName -DisplayName "$($cfg.AppName) - PostgreSQL $($cfg.PgPort) BLOCK" -Direction Inbound -Protocol TCP -LocalPort $cfg.PgPort -Action Block -Profile Any | Out-Null
    }
    $disabledProfiles = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
    if ($disabledProfiles.Count -gt 0) {
        Write-Warning ("Firewall profile(s) DISABLED: {0}. Not enabled automatically to avoid locking out RDP; enable them after verifying the RDP rule." -f ($disabledProfiles -join ', '))
    }
    Write-DeployKitOk "80/443 open, $($cfg.PgPort) blocked. RDP rules untouched."

    # --- 11. win-acme (Let's Encrypt client) ------------------------------------------------
    $wa = $raw.downloads.winAcme
    Write-DeployKitStep "win-acme $($wa.version)"
    $wacs = Join-Path $cfg.WinAcme 'wacs.exe'
    $versionFile = Join-Path $cfg.WinAcme 'version.txt'
    $installedVersion = if (Test-Path -LiteralPath $versionFile) { ([IO.File]::ReadAllText($versionFile)) } else { '' }
    if ((Test-Path -LiteralPath $wacs) -and $installedVersion -like "*$($wa.version)*") {
        Write-DeployKitOk 'Already installed.'
    }
    else {
        # wacs.exe is NOT Authenticode-signed (self-signed): the pinned SHA-256 is the check.
        $zip = Get-DeployKitVerifiedDownload -Url $wa.url -Destination (Join-Path $cfg.Downloads (Split-Path $wa.url -Leaf)) -Sha256 $wa.sha256
        New-Item -ItemType Directory -Force -Path $cfg.WinAcme | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $cfg.WinAcme -Force
        Write-DeployKitOk "Extracted: $($cfg.WinAcme)"
    }

    # --- 12. Management scripts and app.env -> pool ---------------------------------------
    Write-DeployKitStep "Management scripts: $($cfg.Bin)"
    $null = Copy-DeployKitScripts -Source $PSScriptRoot -Destination $cfg.Bin -SourceVersion $cfg.KitVersion -Force:$Force
    try {
        & (Join-Path $cfg.Bin 'set-config.ps1') -NoRestart
    }
    catch {
        # Typical on a first run with a custom template: values marked <...> must be filled in by hand.
        Write-Warning "app.env was not applied to the application pool yet: $($_.Exception.Message)"
        Write-Warning "Fill in $($cfg.AppEnv), then run $($cfg.Bin)\set-config.ps1"
    }

    # --- 13. Scheduled tasks ------------------------------------------------------------------
    Write-DeployKitStep 'Scheduled tasks'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $powershell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

    $backupAction = New-ScheduledTaskAction -Execute $powershell -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"{0}`" -Label daily" -f (Join-Path $cfg.Bin 'backup.ps1'))
    $backupTrigger = New-ScheduledTaskTrigger -Daily -At $cfg.BackupTime
    $backupSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $cfg.TaskPath -TaskName "$($cfg.AppName) Daily Backup" -Action $backupAction -Trigger $backupTrigger `
        -Principal $principal -Settings $backupSettings -Description "$($cfg.AppName): pg_dump + weekly storage archive + retention (backup.ps1)." -Force | Out-Null

    $checkAction = New-ScheduledTaskAction -Execute $powershell -Argument ("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"{0}`"" -f (Join-Path $cfg.Bin 'startup-check.ps1'))
    $checkTrigger = New-ScheduledTaskTrigger -AtStartup
    $checkTrigger.Delay = 'PT2M'
    $checkSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath $cfg.TaskPath -TaskName "$($cfg.AppName) Startup Check" -Action $checkAction -Trigger $checkTrigger `
        -Principal $principal -Settings $checkSettings -Description "$($cfg.AppName): 2 minutes after boot, checks PostgreSQL + API health and restarts the pool once if needed." -Force | Out-Null
    Write-DeployKitOk "Daily backup at $($cfg.BackupTime) (server local time), startup check (boot + 2 min). Task Scheduler > $($cfg.AppName)."

    # --- Done ---------------------------------------------------------------------------------
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' } |
        Select-Object -First 1).IPAddress
    if (-not $ip) { $ip = '<SERVER-PUBLIC-IP>' }
    $apiId = (Get-Website -Name $cfg.ApiSite).Id
    $webId = (Get-Website -Name $cfg.WebSite).Id

    Write-Host ''
    Write-Host '=============================================================================' -ForegroundColor Green
    Write-Host ' Setup complete. Next steps (details: README.md):' -ForegroundColor Green
    Write-Host ''
    Write-Host ' 1. DNS at your DNS provider. Lower the TTL a day before switching existing names:'
    foreach ($h in @($cfg.ApiHost) + @($cfg.WebHosts)) {
        Write-Host ("      {0,-34} A  {1}" -f $h, $ip)
    }
    Write-Host '    Do NOT touch MX / SPF / DKIM / DMARC / autodiscover records.'
    Write-Host ''
    Write-Host ' 2. Certificates (win-acme) once the names resolve to this server and port 80 is'
    Write-Host '    reachable from the internet. --installation iis is REQUIRED: without it the'
    Write-Host '    certificate is only stored, no https binding is created and renewals do not update IIS.'
    Write-Host "      & '$wacs' --source iis --siteid $apiId --installation iis --validation selfhosting --emailaddress <your-email> --accepttos"
    Write-Host "      Restart-WebAppPool '$($cfg.ApiPool)'     # the app learns its HTTPS port"
    Write-Host "      & '$wacs' --source iis --siteid $webId --installation iis --validation selfhosting --emailaddress <your-email> --accepttos"
    Write-Host "      & '$wacs' --setuptaskscheduler     # automatic renewal task (once, if missing)"
    Write-Host ''
    Write-Host " 3. Review the settings: notepad $($cfg.AppEnv)"
    Write-Host "    then: $($cfg.Bin)\set-config.ps1"
    Write-Host ''
    Write-Host ' 4. Deploy the package (built with build-package.ps1 on your machine):'
    Write-Host "      $($cfg.Bin)\install-release.ps1 -Package $($cfg.Packages)\$($cfg.PackagePrefix)-<version>.zip"
    Write-Host '=============================================================================' -ForegroundColor Green
}
finally {
    Stop-Transcript | Out-Null
}
