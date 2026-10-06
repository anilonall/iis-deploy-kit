# =============================================================================
# iis-deploy-kit - shared helpers for the server scripts and build-package.ps1.
#
# Imported by setup-server.ps1, install-release.ps1, set-config.ps1, backup.ps1,
# restore-db.ps1, startup-check.ps1, build-package.ps1 and test-config.ps1. On the server it
# lives in <root>\bin next to the scripts and next to deploy.config.json.
#
# Compatible with Windows PowerShell 5.1 (built into Windows Server 2025). No extra modules are
# installed; only WebAdministration (IIS) and built-in cmdlets are used.
#
# SECURITY: no function prints a password, key or connection string VALUE to the console, a log
# or a command line. Native tools that need a secret (psql, pg_dump, pg_restore, the migrations
# bundle) receive it only through that process's environment, which is restored afterwards.
#
# LOCALE: key/identifier checks use case-SENSITIVE operators (-cmatch, -cnotmatch, -ceq) or
# explicit [A-Za-z] classes. On Turkish-locale Windows a case-insensitive regex maps "I" to a
# dotless "i", so a key such as "Jwt__Issuer" was rejected by '^[A-Z_]...' with -match.
# =============================================================================

Set-StrictMode -Version 2.0

# Version of the kit's scripts. Written into every package manifest and into <root>\bin\kit-version.txt.
$script:DeployKitVersion = '1.0.0'

# Files that make up the server-side toolset (copied to <root>\bin).
$script:ManagedFiles = @(
    'DeployKit.Common.psm1', 'setup-server.ps1', 'install-release.ps1', 'set-config.ps1',
    'backup.ps1', 'restore-db.ps1', 'startup-check.ps1', 'app.env.example', 'deploy.config.json'
)

$script:SettingsCache = @{}

function Get-DeployKitVersion { return $script:DeployKitVersion }

function Get-DeployKitManagedFiles { return $script:ManagedFiles }

# --- Console output --------------------------------------------------------------
function Write-DeployKitStep {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-DeployKitOk {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "    $Message" -ForegroundColor Green
}

function Write-DeployKitInfo {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message)
    Write-Host "    $Message"
}

function Assert-DeployKitAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run ELEVATED: right-click PowerShell > "Run as administrator".'
    }
}

# --- Configuration -----------------------------------------------------------------
# Reads a nested property ('a.b.c') of a ConvertFrom-Json object; returns $Default when any part
# is missing or $null. Works with Windows PowerShell 5.1 PSCustomObjects.
function Get-DeployKitProperty {
    param($Object, [Parameter(Mandatory = $true)][string]$Path, $Default = $null)
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $Default }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }
    if ($null -eq $current) { return $Default }
    return $current
}

function Test-DeployKitVersionCompatible {
    param([string]$ConfigVersion)
    if ($ConfigVersion -cnotmatch '^\d+\.\d+\.\d+$') { return $false }
    return ([version]$ConfigVersion).Major -eq ([version]$script:DeployKitVersion).Major
}

# Validates the parsed deploy.config.json. Mirrors deploy.config.schema.json (Windows PowerShell
# 5.1 has no Test-Json) and adds cross-field checks. Returns a list of problems (empty = valid).
function Test-DeployKitConfig {
    param([Parameter(Mandatory = $true)]$Config)
    $problems = New-Object System.Collections.Generic.List[string]
    $hostPattern = '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
    $sqlPattern = '^[a-z_][a-z0-9_]{0,62}$'
    $iisPattern = '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$'
    $envKeyPattern = '^[A-Za-z_][A-Za-z0-9_]*$'
    $hex64 = '^[0-9A-Fa-f]{64}$'
    $hex128 = '^[0-9A-Fa-f]{128}$'

    function Need([string]$Path, [string]$Pattern, [string]$Hint) {
        $value = Get-DeployKitProperty $Config $Path
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { $problems.Add("$Path is required."); return }
        if ($Pattern -and ([string]$value) -cnotmatch $Pattern) { $problems.Add("$Path is invalid ('$value'). $Hint") }
    }
    function Optional([string]$Path, [string]$Pattern, [string]$Hint) {
        $value = Get-DeployKitProperty $Config $Path
        if ($null -ne $value -and ([string]$value) -cnotmatch $Pattern) { $problems.Add("$Path is invalid ('$value'). $Hint") }
    }

    Need 'kitVersion' '^\d+\.\d+\.\d+$' 'Expected x.y.z.'
    $kitVersion = [string](Get-DeployKitProperty $Config 'kitVersion' '')
    if ($kitVersion -cmatch '^\d+\.\d+\.\d+$' -and -not (Test-DeployKitVersionCompatible $kitVersion)) {
        $problems.Add("kitVersion $kitVersion is not compatible with these scripts ($script:DeployKitVersion): the major version must match.")
    }
    Need 'appName' '^[A-Za-z][A-Za-z0-9-]{1,39}$' 'Letters, digits and hyphens, 2-40 characters, starting with a letter.'
    Need 'domains.web' $hostPattern 'Lower-case host name, e.g. example.com.'
    Need 'domains.api' $hostPattern 'Lower-case host name, e.g. api.example.com.'
    $aliases = @(Get-DeployKitProperty $Config 'domains.webAliases' @())
    foreach ($alias in $aliases) {
        if (([string]$alias) -cnotmatch $hostPattern) { $problems.Add("domains.webAliases contains an invalid host '$alias'.") }
    }
    $allHosts = @([string](Get-DeployKitProperty $Config 'domains.web' '')) + @($aliases | ForEach-Object { [string]$_ }) + @([string](Get-DeployKitProperty $Config 'domains.api' ''))
    if (@($allHosts | Select-Object -Unique).Count -ne $allHosts.Count) { $problems.Add('domains: web, webAliases and api must all be different hosts.') }

    Optional 'server.root' '^[A-Za-z]:\\[^<>:"/|?*]+$' 'Absolute local path, e.g. C:\MyApp.'
    foreach ($name in 'apiSiteName', 'webSiteName', 'apiPoolName', 'webPoolName', 'eventLogSource') {
        Optional "server.$name" $iisPattern 'Letters, digits, space, dot, underscore, hyphen.'
    }
    Optional 'server.backupTime' '^([01]\d|2[0-3]):[0-5]\d$' 'Expected HH:mm.'
    foreach ($pair in @(@('server.keepReleases', 2, 50), @('server.maxRequestBodyMb', 1, 4000), @('database.port', 1024, 65535))) {
        $value = Get-DeployKitProperty $Config $pair[0]
        if ($null -ne $value -and (-not ($value -is [int] -or $value -is [long]) -or $value -lt $pair[1] -or $value -gt $pair[2])) {
            $problems.Add("$($pair[0]) must be an integer between $($pair[1]) and $($pair[2]).")
        }
    }

    Need 'database.name' $sqlPattern 'Lower-case PostgreSQL identifier.'
    Need 'database.role' $sqlPattern 'Lower-case PostgreSQL identifier.'
    $major = Get-DeployKitProperty $Config 'database.postgres.majorVersion'
    if (-not ($major -is [int] -or $major -is [long]) -or $major -lt 17) {
        $problems.Add('database.postgres.majorVersion must be an integer >= 17 (the database uses the builtin C.UTF-8 locale provider).')
    }
    Need 'database.postgres.installerVersion' '^\d+\.\d+-\d+$' 'EDB installer version, e.g. 18.6-2.'
    $installerVersion = [string](Get-DeployKitProperty $Config 'database.postgres.installerVersion' '')
    if ($null -ne $major -and $installerVersion -and -not $installerVersion.StartsWith("$major.")) {
        $problems.Add("database.postgres.installerVersion ($installerVersion) does not belong to majorVersion $major.")
    }
    Optional 'database.postgres.installerUrl' '^https://\S+$' 'HTTPS URL.'
    Optional 'database.postgres.installerSha256' $hex64 '64 hex characters.'

    Need 'downloads.hostingBundle.version' '^\d+\.\d+\.\d+$' 'e.g. 10.0.12.'
    Optional 'downloads.hostingBundle.url' '^https://\S+$' 'HTTPS URL.'
    Optional 'downloads.hostingBundle.sha512' $hex128 '128 hex characters.'
    $hbUrl = Get-DeployKitProperty $Config 'downloads.hostingBundle.url'
    $hbSha = Get-DeployKitProperty $Config 'downloads.hostingBundle.sha512'
    if (($null -eq $hbUrl) -ne ($null -eq $hbSha)) { $problems.Add('downloads.hostingBundle: give both url and sha512, or neither (then they are read from Microsoft release metadata).') }
    Need 'downloads.urlRewrite.url' '^https://\S+$' 'HTTPS URL.'
    Need 'downloads.urlRewrite.sha256' $hex64 '64 hex characters.'
    Need 'downloads.winAcme.version' '^\d+(\.\d+){1,3}$' 'e.g. 2.2.9.1701.'
    Need 'downloads.winAcme.url' '^https://\S+$' 'HTTPS URL.'
    Need 'downloads.winAcme.sha256' $hex64 '64 hex characters.'

    Need 'api.project' '\.csproj$' 'Path to the API .csproj (relative to deploy.config.json).'
    Optional 'api.healthPath' '^/[^\s?#]*$' 'Path starting with /.'
    Optional 'api.connectionStringKey' $envKeyPattern 'Letters, digits, underscores.'
    Optional 'api.runtimeIdentifier' '^win-(x64|arm64)$' 'win-x64 or win-arm64.'
    foreach ($key in @(Get-DeployKitProperty $Config 'api.requiredEnvKeys' @())) {
        if (([string]$key) -cnotmatch $envKeyPattern) { $problems.Add("api.requiredEnvKeys contains an invalid key '$key'.") }
    }
    $minLengths = Get-DeployKitProperty $Config 'api.minLengthEnvKeys'
    if ($null -ne $minLengths) {
        foreach ($p in $minLengths.PSObject.Properties) {
            if ($p.Name -cnotmatch $envKeyPattern -or -not ($p.Value -is [int] -or $p.Value -is [long]) -or $p.Value -lt 1) {
                $problems.Add("api.minLengthEnvKeys.$($p.Name) must be a positive integer with a valid key name.")
            }
        }
    }

    $migrationsEnabled = Get-DeployKitProperty $Config 'migrations.enabled'
    if ($migrationsEnabled -isnot [bool]) { $problems.Add('migrations.enabled must be true or false.') }
    elseif ($migrationsEnabled) {
        Need 'migrations.context' '^[A-Za-z_][A-Za-z0-9_.]*$' 'DbContext class name.'
        Optional 'migrations.connectionEnvVar' $envKeyPattern 'Letters, digits, underscores.'
    }

    $frontendEnabled = Get-DeployKitProperty $Config 'frontend.enabled'
    if ($frontendEnabled -isnot [bool]) { $problems.Add('frontend.enabled must be true or false.') }
    elseif ($frontendEnabled) {
        Need 'frontend.path' '.' 'Frontend folder relative to deploy.config.json.'
        Optional 'frontend.apiBaseUrlEnvVar' $envKeyPattern 'Letters, digits, underscores.'
        Optional 'frontend.spaCheckPath' '^/[^\s?#]*$' 'Path starting with /.'
    }

    foreach ($name in 'dailyRetentionDays', 'preDeployRetentionDays', 'manualRetentionDays', 'storageRetentionDays', 'iisLogRetentionDays', 'scriptLogRetentionDays') {
        $value = Get-DeployKitProperty $Config "backup.$name"
        if ($null -ne $value -and (-not ($value -is [int] -or $value -is [long]) -or $value -lt 1 -or $value -gt 3650)) {
            $problems.Add("backup.$name must be an integer between 1 and 3650.")
        }
    }
    Optional 'backup.storageArchiveDay' '^(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Never)$' 'A weekday name or Never.'

    return , $problems
}

function Read-DeployKitConfig {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Configuration file not found: $Path" }
    try {
        $config = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        throw "deploy.config.json is not valid JSON ($Path): $($_.Exception.Message)"
    }
    $problems = Test-DeployKitConfig -Config $config
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Host "    CONFIG ERROR: $p" -ForegroundColor Red }
        throw "deploy.config.json is invalid ($($problems.Count) problem(s)): $Path"
    }
    return $config
}

# Resolved settings: everything the scripts use, derived from deploy.config.json with defaults.
# Default config path: deploy.config.json next to this module (the scripts folder / <root>\bin).
function Get-DeployKitSettings {
    param([string]$ConfigPath)
    if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'deploy.config.json' }
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    if ($script:SettingsCache.ContainsKey($ConfigPath)) { return $script:SettingsCache[$ConfigPath] }

    $c = Read-DeployKitConfig -Path $ConfigPath
    $app = [string]$c.appName
    $root = [string](Get-DeployKitProperty $c 'server.root' "C:\$app")
    $major = [int](Get-DeployKitProperty $c 'database.postgres.majorVersion')
    $apiProject = [string](Get-DeployKitProperty $c 'api.project')
    $minLengths = @{}
    $minObject = Get-DeployKitProperty $c 'api.minLengthEnvKeys'
    if ($null -ne $minObject) { foreach ($p in $minObject.PSObject.Properties) { $minLengths[$p.Name] = [int]$p.Value } }
    $connectionKey = [string](Get-DeployKitProperty $c 'api.connectionStringKey' 'ConnectionStrings__Default')
    $required = New-Object System.Collections.Generic.List[string]
    $required.Add($connectionKey)
    foreach ($k in @(Get-DeployKitProperty $c 'api.requiredEnvKeys' @())) { if (-not $required.Contains([string]$k)) { $required.Add([string]$k) } }
    $webAliases = @(Get-DeployKitProperty $c 'domains.webAliases' @() | ForEach-Object { [string]$_ })

    $settings = [pscustomobject]@{
        KitVersion           = $script:DeployKitVersion
        ConfigPath           = $ConfigPath
        ConfigDirectory      = Split-Path -Parent $ConfigPath
        Raw                  = $c
        AppName              = $app
        PackagePrefix        = $app.ToLowerInvariant()

        Root                 = $root
        Bin                  = Join-Path $root 'bin'
        Config               = Join-Path $root 'config'
        AppEnv               = Join-Path $root 'config\app.env'
        ApiReadableDir       = Join-Path $root 'config\api-readable'
        PgSuperuserFile      = Join-Path $root 'config\postgres-superuser.dpapi'
        IisHistory           = Join-Path $root 'config\iis-history'
        Storage              = Join-Path $root 'storage'
        Backups              = Join-Path $root 'backups'
        Logs                 = Join-Path $root 'logs'
        IisLogs              = Join-Path $root 'logs\iis'
        StdoutLogs           = Join-Path $root 'logs\stdout'
        DeployLogs           = Join-Path $root 'logs\deploy'
        SetupLogs            = Join-Path $root 'logs\setup'
        BackupLogs           = Join-Path $root 'logs\backup'
        Tools                = Join-Path $root 'tools'
        Downloads            = Join-Path $root 'tools\downloads'
        WinAcme              = Join-Path $root 'tools\win-acme'
        Packages             = Join-Path $root 'packages'
        ApiRoot              = Join-Path $root 'api'
        ApiReleases          = Join-Path $root 'api\releases'
        ApiPreviousFile      = Join-Path $root 'api\previous.txt'
        WebRoot              = Join-Path $root 'web'
        WebReleases          = Join-Path $root 'web\releases'
        WebPreviousFile      = Join-Path $root 'web\previous.txt'

        ApiSite              = [string](Get-DeployKitProperty $c 'server.apiSiteName' "$app API")
        WebSite              = [string](Get-DeployKitProperty $c 'server.webSiteName' "$app Web")
        ApiPool              = [string](Get-DeployKitProperty $c 'server.apiPoolName' "${app}Api")
        WebPool              = [string](Get-DeployKitProperty $c 'server.webPoolName' "${app}Web")
        EventSource          = [string](Get-DeployKitProperty $c 'server.eventLogSource' "$app API")
        TaskPath             = "\$app\"
        KeepReleases         = [int](Get-DeployKitProperty $c 'server.keepReleases' 5)
        MaxRequestBodyMb     = [int](Get-DeployKitProperty $c 'server.maxRequestBodyMb' 20)
        BackupTime           = [string](Get-DeployKitProperty $c 'server.backupTime' '04:00')
        AlwaysRunning        = [bool](Get-DeployKitProperty $c 'server.alwaysRunning' $true)

        ApiHost              = [string]$c.domains.api
        WebHost              = [string]$c.domains.web
        WebAliases           = $webAliases
        WebHosts             = @([string]$c.domains.web) + $webAliases
        ApiOrigin            = "https://$($c.domains.api)"
        WebOrigin            = "https://$($c.domains.web)"

        PgMajor              = $major
        PgService            = "postgresql-x64-$major"
        PgPrefix             = "C:\Program Files\PostgreSQL\$major"
        PgBin                = "C:\Program Files\PostgreSQL\$major\bin"
        PgPort               = [int](Get-DeployKitProperty $c 'database.port' 5432)
        DbName               = [string]$c.database.name
        DbUser               = [string]$c.database.role

        ApiProject           = $apiProject
        ApiAssemblyName      = [string](Get-DeployKitProperty $c 'api.assemblyName' ([IO.Path]::GetFileNameWithoutExtension($apiProject)))
        RuntimeIdentifier    = [string](Get-DeployKitProperty $c 'api.runtimeIdentifier' 'win-x64')
        HealthPath           = [string](Get-DeployKitProperty $c 'api.healthPath' '/api/health')
        ConnectionStringKey  = $connectionKey
        RequiredEnvKeys      = @($required)
        MinLengthEnvKeys     = $minLengths
        ExcludeFromPackage   = @(Get-DeployKitProperty $c 'api.excludeFromPackage' @('appsettings.Development.json'))
        EnvTemplate          = [string](Get-DeployKitProperty $c 'api.envTemplate' '')

        MigrationsEnabled    = [bool]$c.migrations.enabled
        MigrationsProject    = [string](Get-DeployKitProperty $c 'migrations.project' $apiProject)
        MigrationsStartup    = [string](Get-DeployKitProperty $c 'migrations.startupProject' $apiProject)
        MigrationsContext    = [string](Get-DeployKitProperty $c 'migrations.context' '')
        MigrationsEnvVar     = [string](Get-DeployKitProperty $c 'migrations.connectionEnvVar' '')

        FrontendEnabled      = [bool]$c.frontend.enabled
        FrontendPath         = [string](Get-DeployKitProperty $c 'frontend.path' '')
        FrontendInstall      = [string](Get-DeployKitProperty $c 'frontend.installCommand' 'npm ci --no-audit --no-fund')
        FrontendBuild        = [string](Get-DeployKitProperty $c 'frontend.buildCommand' 'npm run build')
        FrontendOutput       = [string](Get-DeployKitProperty $c 'frontend.outputDir' 'dist')
        ApiBaseUrlEnvVar     = [string](Get-DeployKitProperty $c 'frontend.apiBaseUrlEnvVar' 'VITE_API_BASE_URL')
        VerifyApiUrlInBundle = [bool](Get-DeployKitProperty $c 'frontend.verifyApiUrlInBundle' $true)
        SpaCheckPath         = [string](Get-DeployKitProperty $c 'frontend.spaCheckPath' '/deploy-kit-spa-check')

        RetentionDays        = @{
            'daily'      = [int](Get-DeployKitProperty $c 'backup.dailyRetentionDays' 14)
            'pre-deploy' = [int](Get-DeployKitProperty $c 'backup.preDeployRetentionDays' 30)
            'manual'     = [int](Get-DeployKitProperty $c 'backup.manualRetentionDays' 30)
        }
        StorageRetentionDays = [int](Get-DeployKitProperty $c 'backup.storageRetentionDays' 28)
        IisLogRetentionDays  = [int](Get-DeployKitProperty $c 'backup.iisLogRetentionDays' 90)
        LogRetentionDays     = [int](Get-DeployKitProperty $c 'backup.scriptLogRetentionDays' 60)
        StorageArchiveDay    = [string](Get-DeployKitProperty $c 'backup.storageArchiveDay' 'Sunday')
    }
    $script:SettingsCache[$ConfigPath] = $settings
    return $settings
}

# Runs a native program and stops on a non-zero exit code. Output goes to the HOST, never into
# the caller's return value. (PowerShell adds every uncaptured output line of a function to its
# return value; a native tool's output would otherwise turn "exit code 0" into an array.)
function Invoke-DeployKitNative {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [int[]]$AllowedExitCodes = @(0)
    )
    & $Command | Out-Host
    $exitCode = [int]$LASTEXITCODE
    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "$Description failed (exit code $exitCode)."
    }
}

# --- Random secrets -----------------------------------------------------------------
# Cryptographically random; letters and digits only (safe inside connection strings and SQL).
function New-DeployKitSecret {
    param([int]$Length = 48, [switch]$Hex)
    $alphabet = if ($Hex) { '0123456789abcdef' } else { 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789' }
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $chars = New-Object char[] $Length
        $buffer = New-Object byte[] 1
        $limit = 256 - (256 % $alphabet.Length)   # avoid modulo bias
        $i = 0
        while ($i -lt $Length) {
            $rng.GetBytes($buffer)
            if ($buffer[0] -lt $limit) {
                $chars[$i] = $alphabet[$buffer[0] % $alphabet.Length]
                $i++
            }
        }
        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

# --- DPAPI (local machine scope) -------------------------------------------------------
# The file lives in <root>\config (Administrators + SYSTEM only) and is additionally DPAPI
# encrypted: a copy taken to another machine cannot be decrypted.
function Protect-DeployKitText {
    param([Parameter(Mandatory = $true)][string]$PlainText, [Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.Security
    $bytes = [Text.Encoding]::UTF8.GetBytes($PlainText)
    $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllText($Path, [Convert]::ToBase64String($protected))
}

function Unprotect-DeployKitText {
    param([Parameter(Mandatory = $true)][string]$Path)
    Add-Type -AssemblyName System.Security
    $protected = [Convert]::FromBase64String(([IO.File]::ReadAllText($Path)).Trim())
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

# --- app.env --------------------------------------------------------------------------
# Format: KEY=VALUE (same as a systemd EnvironmentFile). Comments only at the start of a line.
# Surrounding double quotes are removed. Values are NEVER printed.
function Test-DeployKitEnvValueLine {
    param([string]$Line)
    $trimmed = $Line.Trim()
    if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { return $false }
    return ($trimmed.IndexOf('=') -ge 1)
}

function Read-DeployKitEnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Path not found. Run setup-server.ps1 first."
    }

    $values = [ordered]@{}
    $placeholders = New-Object System.Collections.Generic.List[string]
    $duplicates = New-Object System.Collections.Generic.List[string]
    $invalid = New-Object System.Collections.Generic.List[string]

    $lineNumber = 0
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }

        $eq = $trimmed.IndexOf('=')
        if ($eq -lt 1) { $invalid.Add("line $lineNumber"); continue }

        $key = $trimmed.Substring(0, $eq)
        $value = $trimmed.Substring($eq + 1)
        # Case-SENSITIVE match on purpose (Turkish-locale "I" problem, see the header).
        if ($key -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $invalid.Add("line $lineNumber (key '$key')"); continue }
        if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        # Not filled in: <...> (manual) or {{...}} (token).
        if ($value -cmatch '<[^<>]+>' -or $value -cmatch '\{\{[A-Za-z0-9_]+\}\}') { $placeholders.Add($key) }
        if ($values.Contains($key)) { $duplicates.Add($key) }
        $values[$key] = $value
    }

    [pscustomobject]@{
        Values       = $values
        Placeholders = $placeholders
        Duplicates   = $duplicates
        Invalid      = $invalid
    }
}

# Config-derived {{TOKEN}} values for the app.env template.
function Get-DeployKitEnvTokens {
    param([Parameter(Mandatory = $true)]$Settings)
    $tokens = @{
        'APP_NAME'         = $Settings.AppName
        'DB_NAME'          = $Settings.DbName
        'DB_USER'          = $Settings.DbUser
        'DB_PORT'          = [string]$Settings.PgPort
        'API_HOST'         = $Settings.ApiHost
        'WEB_HOST'         = $Settings.WebHost
        'API_ORIGIN'       = $Settings.ApiOrigin
        'WEB_ORIGIN'       = $Settings.WebOrigin
        'STORAGE_DIR'      = $Settings.Storage
        'API_READABLE_DIR' = $Settings.ApiReadableDir
    }
    for ($i = 0; $i -lt $Settings.WebAliases.Count; $i++) {
        $tokens["WEB_ALIAS_ORIGIN_$i"] = "https://$($Settings.WebAliases[$i])"
    }
    return $tokens
}

# Replaces {{TOKEN}}s ONLY on active KEY=VALUE lines, never in comment lines. (A real server once
# got its generated secrets written into the template's header comment, which documents the
# tokens; comments must stay as they are.)
#   * {{GENERATED_SECRET}}      -> a new random 64-character secret per occurrence
#   * {{GENERATED_DB_PASSWORD}} -> $DbPassword (only when given; otherwise left in place)
#   * other known tokens        -> from $Tokens
# Returns the new text and the list of tokens that are still unresolved on active lines.
function Expand-DeployKitEnvTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][hashtable]$Tokens,
        [string]$DbPassword
    )
    $separator = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $Text -split "`r?`n"
    $unresolved = New-Object System.Collections.Generic.List[string]
    $changed = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if (-not (Test-DeployKitEnvValueLine $line)) { continue }
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $name = $m.Groups[1].Value
            if ($name -ceq 'GENERATED_SECRET') { return (New-DeployKitSecret -Length 64) }
            if ($name -ceq 'GENERATED_DB_PASSWORD') {
                if ($DbPassword) { return $DbPassword }
                return $m.Value
            }
            if ($Tokens.ContainsKey($name)) { return [string]$Tokens[$name] }
            return $m.Value
        }
        $expandedLine = [regex]::Replace($line, '\{\{([A-Za-z0-9_]+)\}\}', $evaluator)
        if ($expandedLine -cne $line) { $changed++ }
        foreach ($m in [regex]::Matches($expandedLine, '\{\{([A-Za-z0-9_]+)\}\}')) { $unresolved.Add("line $($i + 1): $($m.Value)") }
        $lines[$i] = $expandedLine
    }
    [pscustomobject]@{
        Text         = ($lines -join $separator)
        ChangedLines = $changed
        Unresolved   = $unresolved
    }
}

# Npgsql connection string -> parts (lower-case keys without spaces). Values are not printed.
function Get-DeployKitConnectionParts {
    param([Parameter(Mandatory = $true)][string]$ConnectionString)
    $parts = @{}
    foreach ($segment in $ConnectionString.Split(';')) {
        $eq = $segment.IndexOf('=')
        if ($eq -lt 1) { continue }
        $name = ($segment.Substring(0, $eq) -replace '\s', '').ToLowerInvariant()
        $parts[$name] = $segment.Substring($eq + 1).Trim()
    }
    return $parts
}

function Get-DeployKitDbConnection {
    param([Parameter(Mandatory = $true)]$Settings)
    $key = $Settings.ConnectionStringKey
    $envFile = Read-DeployKitEnvFile -Path $Settings.AppEnv
    if (-not $envFile.Values.Contains($key)) { throw "$($Settings.AppEnv) has no $key (api.connectionStringKey)." }
    if ($envFile.Placeholders -contains $key) { throw "$($Settings.AppEnv): $key is not filled in (<...> or {{...}})." }
    $connection = $envFile.Values[$key]
    $parts = Get-DeployKitConnectionParts -ConnectionString $connection

    $hostName = if ($parts.ContainsKey('host')) { $parts['host'] } elseif ($parts.ContainsKey('server')) { $parts['server'] } else { '127.0.0.1' }
    $port = if ($parts.ContainsKey('port')) { $parts['port'] } else { [string]$Settings.PgPort }
    $database = if ($parts.ContainsKey('database')) { $parts['database'] } else { $Settings.DbName }
    $user = if ($parts.ContainsKey('username')) { $parts['username'] } elseif ($parts.ContainsKey('userid')) { $parts['userid'] } else { $Settings.DbUser }
    $password = if ($parts.ContainsKey('password')) { $parts['password'] } else { $null }

    [pscustomobject]@{
        ConnectionString = $connection
        Host             = $hostName
        Port             = $port
        Database         = $database
        User             = $user
        Password         = $password
    }
}

# --- PostgreSQL ------------------------------------------------------------------------
# The password is placed in PGPASSWORD for this process only (never on the command line); SQL is
# passed on standard input. The previous value is restored afterwards.
function Invoke-DeployKitPsql {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$Sql,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Database = 'postgres',
        [string]$HostName = '127.0.0.1',
        [string]$Port,
        [switch]$Scalar
    )
    if (-not $Port) { $Port = [string]$Settings.PgPort }
    $psql = Join-Path $Settings.PgBin 'psql.exe'
    if (-not (Test-Path -LiteralPath $psql)) { throw "psql not found: $psql" }

    $previousPassword = $env:PGPASSWORD
    $previousEncoding = $OutputEncoding
    try {
        $env:PGPASSWORD = $Password
        $global:OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $arguments = @('-X', '-w', '-q', '-v', 'ON_ERROR_STOP=1', '-h', $HostName, '-p', $Port, '-U', $User, '-d', $Database)
        if ($Scalar) { $arguments += @('-t', '-A') }
        $output = $Sql | & $psql @arguments
        if ($LASTEXITCODE -ne 0) { throw "psql failed (exit code $LASTEXITCODE)." }
        if ($Scalar) { return (($output | Out-String).Trim()) }
        return $output
    }
    finally {
        $env:PGPASSWORD = $previousPassword
        $global:OutputEncoding = $previousEncoding
    }
}

function Get-DeployKitPostgresSuperuserPassword {
    param([Parameter(Mandatory = $true)]$Settings)
    if (-not (Test-Path -LiteralPath $Settings.PgSuperuserFile)) {
        throw "$($Settings.PgSuperuserFile) not found. PostgreSQL was probably not installed by setup-server.ps1 (README > Troubleshooting)."
    }
    return Unprotect-DeployKitText -Path $Settings.PgSuperuserFile
}

# --- Verified downloads ----------------------------------------------------------------
# Downloads from the official URL; verifies the SHA-256/SHA-512 hash and (when given) the
# Authenticode signature. A file that fails verification is deleted and the script stops.
function Test-DeployKitFileHash {
    param([string]$Path, [string]$Sha256, [string]$Sha512, [switch]$Quiet)
    if (-not $Sha256 -and -not $Sha512) {
        if (-not $Quiet) { Write-Warning "No pinned hash: $Path is verified by its signature only." }
        return $true
    }
    $algorithm = if ($Sha512) { 'SHA512' } else { 'SHA256' }
    $expected = if ($Sha512) { $Sha512 } else { $Sha256 }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm $algorithm).Hash
    $ok = $actual -ieq $expected.Trim()
    if ($ok -and -not $Quiet) { Write-DeployKitOk "$algorithm verified: $(Split-Path $Path -Leaf)" }
    return $ok
}

function Get-DeployKitVerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string]$Sha256,
        [string]$Sha512,
        [string]$Signer
    )

    $needsDownload = $true
    if (Test-Path -LiteralPath $Destination) {
        $needsDownload = -not (Test-DeployKitFileHash -Path $Destination -Sha256 $Sha256 -Sha512 $Sha512 -Quiet)
    }

    if ($needsDownload) {
        Write-DeployKitInfo "Downloading: $Url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $previousProgress = $global:ProgressPreference
        $global:ProgressPreference = 'SilentlyContinue'
        try {
            $partial = "$Destination.partial"
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
            Move-Item -LiteralPath $partial -Destination $Destination -Force
        }
        finally {
            $global:ProgressPreference = $previousProgress
        }
    }

    if (-not (Test-DeployKitFileHash -Path $Destination -Sha256 $Sha256 -Sha512 $Sha512)) {
        Remove-Item -LiteralPath $Destination -Force
        throw "Hash mismatch: $Destination was deleted. The file changed upstream or the download is corrupt."
    }

    if ($Signer) {
        $signature = Get-AuthenticodeSignature -FilePath $Destination
        $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
        if ($signature.Status -ne 'Valid' -or $subject -notlike "*O=$Signer*") {
            Remove-Item -LiteralPath $Destination -Force
            throw "Authenticode signature invalid or not from '$Signer': status=$($signature.Status), signer='$subject'."
        }
        Write-DeployKitOk "Signature verified: $Signer"
    }
    return $Destination
}

# --- NTFS permissions -------------------------------------------------------------------
# Built-in accounts by SID so icacls works on every Windows display language:
#   *S-1-5-32-544 = Administrators, *S-1-5-18 = SYSTEM.
function Invoke-DeployKitIcacls {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $null = & icacls.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "icacls failed ($($Arguments -join ' '))." }
}

# Folder accessible to Administrators + SYSTEM only (inheritance removed).
function Set-DeployKitPrivateAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    Invoke-DeployKitIcacls -Arguments @($Path, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F')
}

# --- IIS -----------------------------------------------------------------------------
function Import-DeployKitIis {
    if (-not (Get-Module -Name WebAdministration)) {
        Import-Module WebAdministration -ErrorAction Stop
    }
}

function Test-DeployKitSiteHttps {
    param([Parameter(Mandatory = $true)][string]$SiteName)
    Import-DeployKitIis
    $binding = Get-WebBinding -Name $SiteName -Protocol https -ErrorAction SilentlyContinue
    return [bool]$binding
}

function Get-DeployKitSitePath {
    param([Parameter(Mandatory = $true)][string]$SiteName)
    Import-DeployKitIis
    return (Get-ItemProperty -LiteralPath "IIS:\Sites\$SiteName" -Name physicalPath)
}

function Set-DeployKitSitePath {
    param([Parameter(Mandatory = $true)][string]$SiteName, [Parameter(Mandatory = $true)][string]$Path)
    Import-DeployKitIis
    Set-ItemProperty -LiteralPath "IIS:\Sites\$SiteName" -Name physicalPath -Value $Path
}

function Wait-DeployKitAppPoolState {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$State, [int]$TimeoutSeconds = 60)
    Import-DeployKitIis
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-WebAppPoolState -Name $Name).Value -eq $State) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Stop-DeployKitAppPool {
    param([Parameter(Mandatory = $true)][string]$Name)
    Import-DeployKitIis
    if ((Get-WebAppPoolState -Name $Name).Value -ne 'Stopped') {
        Stop-WebAppPool -Name $Name
    }
    if (-not (Wait-DeployKitAppPoolState -Name $Name -State 'Stopped' -TimeoutSeconds 120)) {
        throw "Application pool '$Name' did not stop within 120 seconds."
    }
}

function Start-DeployKitAppPool {
    param([Parameter(Mandatory = $true)][string]$Name)
    Import-DeployKitIis
    if ((Get-WebAppPoolState -Name $Name).Value -ne 'Started') {
        Start-WebAppPool -Name $Name
    }
    $null = Wait-DeployKitAppPoolState -Name $Name -State 'Started' -TimeoutSeconds 60
}

# Replaces ALL environment variables of an application pool (a key removed from app.env must
# disappear from IIS too).
#
# Uses the WebAdministration cmdlets on MACHINE/WEBROOT/APPHOST. Do NOT switch to
# Microsoft.Web.Administration.dll (ServerManager) from PowerShell: on Windows Server 2025 it
# conflicts with the assembly version loaded by the WebAdministration module and fails with
# DISP_E_TYPEMISMATCH. appcmd is not used either, because values would appear on a command line.
function Set-DeployKitAppPoolEnvironment {
    param(
        [Parameter(Mandatory = $true)][string]$PoolName,
        [Parameter(Mandatory = $true)][System.Collections.Specialized.OrderedDictionary]$Variables
    )
    Import-DeployKitIis
    $psPath = 'MACHINE/WEBROOT/APPHOST'
    $filter = "system.applicationHost/applicationPools/add[@name='$PoolName']/environmentVariables"

    $existing = @(Get-WebConfiguration -PSPath $psPath -Filter "$filter/add" -ErrorAction SilentlyContinue)
    foreach ($item in $existing) {
        $existingName = [string]$item.name
        if ($existingName) {
            Remove-WebConfigurationProperty -PSPath $psPath -Filter $filter -Name '.' -AtElement @{ name = $existingName } -ErrorAction Stop
        }
    }
    foreach ($name in $Variables.Keys) {
        Add-WebConfigurationProperty -PSPath $psPath -Filter $filter -Name '.' `
            -Value @{ name = [string]$name; value = [string]$Variables[$name] } -ErrorAction Stop
    }
}

# --- HTTP probes (curl.exe is built into Windows Server 2025) ---------------------------
# The request goes to this server (127.0.0.1) but with the REAL host name (SNI + Host header):
# IIS bindings, the certificate and the app's AllowedHosts are exercised exactly like in production.
function Invoke-DeployKitProbe {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Https,
        [string]$OutFile
    )
    $scheme = if ($Https) { 'https' } else { 'http' }
    $port = if ($Https) { 443 } else { 80 }
    $target = if ($OutFile) { $OutFile } else { 'NUL' }
    $url = "${scheme}://$HostName$Path"
    $code = & curl.exe -s --max-time 15 --ssl-no-revoke -o $target -w '%{http_code}' --resolve "${HostName}:${port}:127.0.0.1" $url
    $value = 0
    if (-not [int]::TryParse((($code | Out-String).Trim()), [ref]$value)) { $value = 0 }
    return $value
}

# API health endpoint: HTTPS when the site has an https binding, otherwise HTTP. Waits for 200.
function Test-DeployKitApiHealth {
    param([Parameter(Mandatory = $true)]$Settings, [int]$Attempts = 30, [int]$DelaySeconds = 2)
    $https = Test-DeployKitSiteHttps -SiteName $Settings.ApiSite
    $scheme = if ($https) { 'https' } else { 'http' }
    $status = 0
    for ($i = 1; $i -le $Attempts; $i++) {
        $status = Invoke-DeployKitProbe -HostName $Settings.ApiHost -Path $Settings.HealthPath -Https:$https
        if ($status -eq 200) {
            Write-DeployKitOk "Health check passed: ${scheme}://$($Settings.ApiHost)$($Settings.HealthPath) -> 200"
            return $true
        }
        if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
    }
    Write-Warning "Health check did not return 200 after $Attempts attempt(s) (last status: $status)."
    return $false
}

# Recent ASP.NET Core Module, application and WAS events (startup failure diagnosis).
function Show-DeployKitRecentApiEvents {
    param([Parameter(Mandatory = $true)]$Settings, [datetime]$Since = (Get-Date).AddMinutes(-10))
    $providers = @('IIS AspNetCore Module V2', $Settings.EventSource, '.NET Runtime', 'WAS')
    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $Since } -ErrorAction Stop |
            Where-Object { $providers -contains $_.ProviderName } |
            Select-Object -First 15
        $system = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WAS'; StartTime = $Since } -ErrorAction SilentlyContinue |
            Select-Object -First 5
        $all = @($events) + @($system) | Where-Object { $_ }
        if (@($all).Count -eq 0) { Write-Host '    (No related event log entries.)'; return }
        foreach ($e in $all) {
            $text = ($e.Message -split "`r?`n" | Select-Object -First 12) -join "`n      "
            Write-Host "    [$($e.TimeCreated.ToString('HH:mm:ss'))] $($e.ProviderName) ($($e.LevelDisplayName)):`n      $text" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host '    (Event log could not be read or has no entries.)'
    }
}

function Write-DeployKitHistory {
    param([Parameter(Mandatory = $true)]$Settings, [string]$Component, [string]$Action, [string]$Release, [string]$Version, [string]$Result)
    if (-not (Test-Path -LiteralPath $Settings.DeployLogs)) { New-Item -ItemType Directory -Force -Path $Settings.DeployLogs | Out-Null }
    $line = '{0:u} | {1} | {2} | {3} | {4} | {5}' -f [DateTime]::UtcNow, $Component, $Action, $Release, $Version, $Result
    Add-Content -LiteralPath (Join-Path $Settings.DeployLogs 'history.log') -Value $line -Encoding UTF8
}

# --- Management scripts in <root>\bin ------------------------------------------------------
function Get-DeployKitInstalledVersion {
    param([Parameter(Mandatory = $true)][string]$BinPath)
    $file = Join-Path $BinPath 'kit-version.txt'
    if (Test-Path -LiteralPath $file) {
        $text = ([IO.File]::ReadAllText($file)).Trim()
        if ($text -cmatch '^\d+\.\d+\.\d+$') { return [version]$text }
    }
    $module = Join-Path $BinPath 'DeployKit.Common.psm1'
    if (Test-Path -LiteralPath $module) {
        $m = [regex]::Match([IO.File]::ReadAllText($module), "DeployKitVersion\s*=\s*'(\d+\.\d+\.\d+)'")
        if ($m.Success) { return [version]$m.Groups[1].Value }
    }
    return $null
}

# Copies the managed scripts (+ deploy.config.json, app.env.example) into <root>\bin.
#
# GUARD: install-release.ps1 copies the scripts that came INSIDE the package. A package built
# before a script fix would silently re-install the old, broken scripts. Therefore an older kit
# version never overwrites a newer one unless -Force is given. Always deploy the newest package.
function Copy-DeployKitScripts {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$SourceVersion,
        [switch]$Force
    )
    $sourceFull = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $destinationFull = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    if ($sourceFull -ieq $destinationFull) {
        Write-DeployKitInfo "Scripts already run from $Destination (kit $SourceVersion)."
        return $false
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $installed = Get-DeployKitInstalledVersion -BinPath $Destination
    $incoming = [version]$SourceVersion
    if ($installed -and $incoming -lt $installed) {
        if (-not $Force) {
            Write-Warning "Management scripts NOT updated: the package carries kit $incoming but $Destination has the newer kit $installed. Build a package with the current kit (or pass -Force to downgrade on purpose)."
            return $false
        }
        Write-Warning "Downgrading management scripts from kit $installed to $incoming (-Force)."
    }
    foreach ($name in $script:ManagedFiles) {
        $src = Join-Path $Source $name
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Destination $name) -Force }
    }
    [IO.File]::WriteAllText((Join-Path $Destination 'kit-version.txt'), $SourceVersion)
    Get-ChildItem -LiteralPath $Destination -File | Unblock-File
    $from = if ($installed) { "$installed -> " } else { '' }
    Write-DeployKitOk "Management scripts in ${Destination}: kit $from$incoming."
    return $true
}

Export-ModuleMember -Function *-DeployKit*
