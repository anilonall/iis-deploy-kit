<#
.SYNOPSIS
    Installs a release package (output of build-package.ps1) ON THE SERVER, rolls back, verifies
    a package or shows the status. Run it over RDP in an ELEVATED PowerShell; no SSH/WinRM needed.

.DESCRIPTION
    Install (-Package):
      1. The package's SHA-256 is checked against the .sha256 file next to it, and every file
         against the hashes in manifest.json (catches truncated/corrupted copies). The package
         must belong to this application (same appName).
      2. API (-Component Api or All):
           a. app.env is validated (set-config.ps1 -CheckOnly); on any problem NOTHING changes.
           b. The release is copied to <root>\api\releases\<timestamp>.
           c. Database backup (backup.ps1 -Label pre-deploy).
           d. app_offline.htm is placed in the running release (ASP.NET Core Module shuts the app
              and its background workers down gracefully), then the pool is stopped.
           e. app.env -> pool environment variables (set-config.ps1 -NoRestart).
           f. EF Core migrations bundle. All app.env values (including the connection string) are
              passed ONLY as environment variables of this process - never on a command line, the
              console or a log. On failure the previous release is started again.
           g. The API site's physical path is switched to the new release, the pool is started and
              the health endpoint must return 200. Otherwise the PREVIOUS release is restored.
      3. Web (-Component Web or All): the release is copied to <root>\web\releases\<timestamp> and
         the site path is switched (no downtime). "/" and frontend.spaCheckPath must return the
         NEW index.html, otherwise the previous release is restored. While the web site has no
         HTTPS binding yet, web.config is switched to "HTTP-only" mode (no HTTPS redirect, no
         HSTS, no upgrade-insecure-requests); after the certificate, re-install the same package.
      4. server.keepReleases releases are kept (the active and the previous one always).
      5. Management scripts in <root>\bin are updated from the package - but never downgraded to
         an older kit version (see -Force).

    Rollback (-Rollback): switches the application files back to the previous release. Database
    migrations are NOT rolled back; restore the pre-deploy backup if needed (restore-db.ps1).

.PARAMETER Package
    Release package (<app>-<version>.zip). <app>-<version>.zip.sha256 must be next to it.

.PARAMETER Component
    All (default), Api or Web.

.PARAMETER VerifyOnly
    Verify the package (hashes, manifest, application, kit version) and exit without changes.

.PARAMETER Force
    Allow the package's (older) management scripts to replace newer ones in <root>\bin.

.EXAMPLE
    C:\MyApp\bin\install-release.ps1 -Package C:\MyApp\packages\myapp-20260101-120000-abc1234.zip

.EXAMPLE
    C:\MyApp\bin\install-release.ps1 -Package C:\MyApp\packages\myapp-20260101-120000-abc1234.zip -VerifyOnly

.EXAMPLE
    C:\MyApp\bin\install-release.ps1 -Rollback -Component Api

.EXAMPLE
    C:\MyApp\bin\install-release.ps1 -Status
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install', Mandatory = $true, Position = 0)][string]$Package,
    [Parameter(ParameterSetName = 'Install')][switch]$VerifyOnly,
    [Parameter(ParameterSetName = 'Install')][switch]$Force,
    [Parameter(ParameterSetName = 'Rollback', Mandatory = $true)][switch]$Rollback,
    [Parameter(ParameterSetName = 'Status', Mandatory = $true)][switch]$Status,
    [ValidateSet('All', 'Api', 'Web')][string]$Component = 'All'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'DeployKit.Common.psm1') -Force -DisableNameChecking
Assert-DeployKitAdministrator
$cfg = Get-DeployKitSettings -ConfigPath (Join-Path $PSScriptRoot 'deploy.config.json')
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$extract = $null

$appOfflineHtml = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Maintenance</title></head>
<body style="font-family:system-ui,'Segoe UI',sans-serif;display:grid;place-items:center;min-height:90vh;color:#1f2937">
<main style="text-align:center"><h1>Back in a moment</h1><p>We are installing an update. Please try again in a few minutes.</p></main>
</body></html>
'@

# --- Helpers --------------------------------------------------------------------------------
function Get-NormalizedPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\')
}

function Get-PreviousRelease([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    return Get-NormalizedPath (([IO.File]::ReadAllText($File)).Trim())
}

function Set-PreviousRelease([string]$File, [string]$Path) {
    [IO.File]::WriteAllText($File, $Path)
}

function Remove-OldReleases([string]$Directory, [string]$SiteName, [string]$PreviousFile) {
    $keepCurrent = Get-NormalizedPath (Get-DeployKitSitePath -SiteName $SiteName)
    $keepPrevious = Get-PreviousRelease $PreviousFile
    # Release names are timestamps (yyyyMMdd-HHmmss): sorting by name = sorting by time.
    Get-ChildItem -LiteralPath $Directory -Directory | Sort-Object Name -Descending | Select-Object -Skip $cfg.KeepReleases |
        Where-Object { $_.FullName.TrimEnd('\') -ne $keepCurrent -and $_.FullName.TrimEnd('\') -ne $keepPrevious } |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-DeployKitInfo "Old release removed: $($_.Name)"
        }
}

function Copy-Release([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -Path (Join-Path $Source '*') -Destination $Destination -Recurse -Force
}

# Web site without a certificate yet (HTTP binding only): disable the HTTPS redirect and the
# HTTPS-only headers, otherwise visitors would be sent to a non-working https:// address.
function Set-WebConfigHttpOnly([string]$Path) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($Path)
    $rule = $doc.SelectSingleNode("/configuration/system.webServer/rewrite/rules/rule[@name='canonical-host']")
    if ($rule) { $rule.SetAttribute('enabled', 'false') }
    $hsts = $doc.SelectSingleNode("/configuration/system.webServer/httpProtocol/customHeaders/add[@name='Strict-Transport-Security']")
    if ($hsts) { [void]$hsts.ParentNode.RemoveChild($hsts) }
    $csp = $doc.SelectSingleNode("/configuration/system.webServer/httpProtocol/customHeaders/add[@name='Content-Security-Policy']")
    if ($csp) { $csp.SetAttribute('value', ($csp.GetAttribute('value') -replace ';\s*upgrade-insecure-requests', '')) }
    $doc.Save($Path)
}

function Get-IndexAssetReference([string]$IndexPath) {
    $html = [IO.File]::ReadAllText($IndexPath)
    $m = [regex]::Match($html, 'src="(/[^"]+\.js)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Web check from the server itself: "/" and the SPA check route must return 200 and contain the
# new index.html's script reference.
function Test-WebRelease([string]$ExpectedAsset) {
    $https = Test-DeployKitSiteHttps -SiteName $cfg.WebSite
    $scheme = if ($https) { 'https' } else { 'http' }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        foreach ($path in '/', $cfg.SpaCheckPath) {
            $ok = $false
            $code = 0
            for ($i = 0; $i -lt 10 -and -not $ok; $i++) {
                $code = Invoke-DeployKitProbe -HostName $cfg.WebHost -Path $path -Https:$https -OutFile $tmp
                $body = if (Test-Path -LiteralPath $tmp) { [IO.File]::ReadAllText($tmp) } else { '' }
                $ok = ($code -eq 200) -and ((-not $ExpectedAsset) -or $body.Contains($ExpectedAsset))
                if (-not $ok) { Start-Sleep -Seconds 1 }
            }
            if (-not $ok) { Write-Warning "${scheme}://$($cfg.WebHost)$path -> $code (expected 200 with the new index.html)"; return $false }
            Write-DeployKitOk "${scheme}://$($cfg.WebHost)$path -> 200 (new release)"
        }
        return $true
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Runs the EF Core migrations bundle with the app's configuration in PROCESS environment
# variables only (restored afterwards). The working directory is the new release, so the bundle
# also sees the release's appsettings*.json - the same configuration the app gets. Returns the
# exit code.
#
# The bundle's output is piped to Out-Host ON PURPOSE: PowerShell adds every uncaptured output
# line of a function to its return value. Without Out-Host the "return code" became an array of
# log lines + 0, and a SUCCESSFUL migration was treated as a failure.
function Invoke-Migrations([string]$Bundle, [string]$WorkingDirectory) {
    $envFile = Read-DeployKitEnvFile -Path $cfg.AppEnv
    $db = Get-DeployKitDbConnection -Settings $cfg
    $variables = [ordered]@{}
    foreach ($key in $envFile.Values.Keys) { $variables[$key] = [string]$envFile.Values[$key] }
    $variables['ASPNETCORE_ENVIRONMENT'] = 'Production'
    $variables['DOTNET_ENVIRONMENT'] = 'Production'
    if ($cfg.MigrationsEnvVar) { $variables[$cfg.MigrationsEnvVar] = $db.ConnectionString }

    $previous = @{}
    foreach ($key in $variables.Keys) { $previous[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
    try {
        foreach ($key in $variables.Keys) { [Environment]::SetEnvironmentVariable($key, $variables[$key], 'Process') }
        Push-Location -LiteralPath $WorkingDirectory
        try {
            & $Bundle | Out-Host
            return [int]$LASTEXITCODE
        }
        finally { Pop-Location }
    }
    finally {
        foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key], 'Process') }
    }
}

# --- API ---------------------------------------------------------------------------------------
function Install-Api([string]$Extract, [string]$Version, [bool]$HasMigrations) {
    Write-DeployKitStep "API installation ($Version)"
    $source = Join-Path $Extract 'api'
    $bundle = Join-Path $Extract 'efbundle.exe'
    $requiredFiles = @((Join-Path $source 'web.config'), (Join-Path $source "$($cfg.ApiAssemblyName).dll"))
    if ($HasMigrations) { $requiredFiles += $bundle }
    foreach ($required in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Missing in package: $required" }
    }

    & (Join-Path $PSScriptRoot 'set-config.ps1') -CheckOnly

    $release = Join-Path $cfg.ApiReleases $stamp
    Copy-Release -Source $source -Destination $release
    Write-DeployKitOk "Release copied: $release"

    $current = Get-NormalizedPath (Get-DeployKitSitePath -SiteName $cfg.ApiSite)
    $hasCurrentApp = Test-Path -LiteralPath (Join-Path $current 'web.config')

    Write-DeployKitStep 'Pre-deploy database backup'
    & (Join-Path $PSScriptRoot 'backup.ps1') -Label pre-deploy

    Write-DeployKitStep 'Stopping the API (app_offline.htm + application pool)'
    $offline = Join-Path $current 'app_offline.htm'
    if ($hasCurrentApp) {
        [IO.File]::WriteAllText($offline, $appOfflineHtml, (New-Object System.Text.UTF8Encoding($false)))
        Start-Sleep -Seconds 5
    }
    Stop-DeployKitAppPool -Name $cfg.ApiPool
    & (Join-Path $PSScriptRoot 'set-config.ps1') -NoRestart

    if ($HasMigrations) {
        Write-DeployKitStep 'Database migrations (EF Core bundle)'
        $exit = Invoke-Migrations -Bundle $bundle -WorkingDirectory $release
        if ($exit -ne 0) {
            Write-Warning "Migrations FAILED (exit code $exit). Starting the previous release again."
            Remove-Item -LiteralPath $offline -Force -ErrorAction SilentlyContinue
            if ($hasCurrentApp) { Start-DeployKitAppPool -Name $cfg.ApiPool; $null = Test-DeployKitApiHealth -Settings $cfg }
            Write-DeployKitHistory -Settings $cfg -Component 'api' -Action 'install' -Release $stamp -Version $Version -Result "FAILED migrations ($exit)"
            throw "Migration error. Pre-deploy backup: $($cfg.Backups) (newest $($cfg.DbName)-pre-deploy-*.dump). README > Backups and restore."
        }
        Write-DeployKitOk 'Migrations applied.'
    }
    else {
        Write-DeployKitInfo 'Package has no migrations bundle (migrations.enabled=false); skipped.'
    }

    Write-DeployKitStep 'Switching to the new release'
    Set-DeployKitSitePath -SiteName $cfg.ApiSite -Path $release
    if ($hasCurrentApp -and $current -ne $release) { Set-PreviousRelease -File $cfg.ApiPreviousFile -Path $current }
    Remove-Item -LiteralPath $offline -Force -ErrorAction SilentlyContinue
    $startedAt = Get-Date
    Start-DeployKitAppPool -Name $cfg.ApiPool

    if (-not (Test-DeployKitApiHealth -Settings $cfg -Attempts 45 -DelaySeconds 2)) {
        Write-Host '    The new release did not start healthy. Recent events:' -ForegroundColor Yellow
        Show-DeployKitRecentApiEvents -Settings $cfg -Since $startedAt.AddSeconds(-10)
        if ($hasCurrentApp) {
            Write-Warning 'Rolling back to the previous release automatically.'
            Stop-DeployKitAppPool -Name $cfg.ApiPool
            Set-DeployKitSitePath -SiteName $cfg.ApiSite -Path $current
            Set-PreviousRelease -File $cfg.ApiPreviousFile -Path $release
            Start-DeployKitAppPool -Name $cfg.ApiPool
            $null = Test-DeployKitApiHealth -Settings $cfg
        }
        Write-DeployKitHistory -Settings $cfg -Component 'api' -Action 'install' -Release $stamp -Version $Version -Result 'FAILED health (rolled back)'
        throw 'Deployment failed (migrations, if any, remain applied). README > Troubleshooting.'
    }

    Remove-OldReleases -Directory $cfg.ApiReleases -SiteName $cfg.ApiSite -PreviousFile $cfg.ApiPreviousFile
    Write-DeployKitHistory -Settings $cfg -Component 'api' -Action 'install' -Release $stamp -Version $Version -Result 'OK'
    Write-DeployKitOk "API release active: $stamp"
}

# --- Web ---------------------------------------------------------------------------------------
function Install-Web([string]$Extract, [string]$Version) {
    Write-DeployKitStep "Web installation ($Version)"
    $source = Join-Path $Extract 'web'
    foreach ($required in (Join-Path $source 'index.html'), (Join-Path $source 'web.config')) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Missing in package: $required" }
    }

    $release = Join-Path $cfg.WebReleases $stamp
    Copy-Release -Source $source -Destination $release
    if (-not (Test-DeployKitSiteHttps -SiteName $cfg.WebSite)) {
        Set-WebConfigHttpOnly -Path (Join-Path $release 'web.config')
        Write-Warning 'The web site has no HTTPS binding (certificate) yet: installed in HTTP-only mode. After win-acme has issued the web certificate, install the SAME package again (-Component Web).'
    }
    $asset = Get-IndexAssetReference -IndexPath (Join-Path $release 'index.html')

    $current = Get-NormalizedPath (Get-DeployKitSitePath -SiteName $cfg.WebSite)
    Set-DeployKitSitePath -SiteName $cfg.WebSite -Path $release
    if ($current -and $current -ne $release) { Set-PreviousRelease -File $cfg.WebPreviousFile -Path $current }

    if (-not (Test-WebRelease -ExpectedAsset $asset)) {
        Write-Warning 'The new web release could not be verified; switching back to the previous release.'
        Set-DeployKitSitePath -SiteName $cfg.WebSite -Path $current
        Set-PreviousRelease -File $cfg.WebPreviousFile -Path $release
        Write-DeployKitHistory -Settings $cfg -Component 'web' -Action 'install' -Release $stamp -Version $Version -Result 'FAILED check (rolled back)'
        throw 'Web deployment failed. Is IIS URL Rewrite installed? A web.config error returns 500.19 (README > Troubleshooting).'
    }

    Remove-OldReleases -Directory $cfg.WebReleases -SiteName $cfg.WebSite -PreviousFile $cfg.WebPreviousFile
    Write-DeployKitHistory -Settings $cfg -Component 'web' -Action 'install' -Release $stamp -Version $Version -Result 'OK'
    Write-DeployKitOk "Web release active: $stamp"
}

# --- Rollback ----------------------------------------------------------------------------------
function Invoke-ApiRollback {
    Write-DeployKitStep 'API: switching back to the previous release'
    $previous = Get-PreviousRelease $cfg.ApiPreviousFile
    if (-not $previous -or -not (Test-Path -LiteralPath (Join-Path $previous 'web.config'))) { throw 'There is no previous API release to roll back to.' }
    $current = Get-NormalizedPath (Get-DeployKitSitePath -SiteName $cfg.ApiSite)
    $startedAt = Get-Date
    Stop-DeployKitAppPool -Name $cfg.ApiPool
    Set-DeployKitSitePath -SiteName $cfg.ApiSite -Path $previous
    Set-PreviousRelease -File $cfg.ApiPreviousFile -Path $current
    Start-DeployKitAppPool -Name $cfg.ApiPool
    if (-not (Test-DeployKitApiHealth -Settings $cfg -Attempts 45 -DelaySeconds 2)) {
        Show-DeployKitRecentApiEvents -Settings $cfg -Since $startedAt
        Write-DeployKitHistory -Settings $cfg -Component 'api' -Action 'rollback' -Release (Split-Path $previous -Leaf) -Version '-' -Result 'FAILED health'
        throw 'The rolled-back release did not start healthy either. Check the event log; if the schema is incompatible use restore-db.ps1 (README > Rollback).'
    }
    Write-DeployKitHistory -Settings $cfg -Component 'api' -Action 'rollback' -Release (Split-Path $previous -Leaf) -Version '-' -Result 'OK'
    Write-DeployKitOk "API rolled back: $(Split-Path $previous -Leaf). Note: migrations were NOT rolled back."
}

function Invoke-WebRollback {
    Write-DeployKitStep 'Web: switching back to the previous release'
    $previous = Get-PreviousRelease $cfg.WebPreviousFile
    if (-not $previous -or -not (Test-Path -LiteralPath (Join-Path $previous 'index.html'))) { throw 'There is no previous web release to roll back to.' }
    $current = Get-NormalizedPath (Get-DeployKitSitePath -SiteName $cfg.WebSite)
    Set-DeployKitSitePath -SiteName $cfg.WebSite -Path $previous
    Set-PreviousRelease -File $cfg.WebPreviousFile -Path $current
    $null = Test-WebRelease -ExpectedAsset (Get-IndexAssetReference -IndexPath (Join-Path $previous 'index.html'))
    Write-DeployKitHistory -Settings $cfg -Component 'web' -Action 'rollback' -Release (Split-Path $previous -Leaf) -Version '-' -Result 'OK'
    Write-DeployKitOk "Web rolled back: $(Split-Path $previous -Leaf)"
}

# --- Status ------------------------------------------------------------------------------------
function Show-Status {
    Write-DeployKitStep "$($cfg.AppName) - management scripts"
    Write-DeployKitInfo "kit      : $(Get-DeployKitInstalledVersion -BinPath $cfg.Bin) ($($cfg.Bin))"
    foreach ($item in @(
            @{ Name = 'API'; Site = $cfg.ApiSite; Pool = $cfg.ApiPool; Previous = $cfg.ApiPreviousFile },
            @{ Name = 'Web'; Site = $cfg.WebSite; Pool = $cfg.WebPool; Previous = $cfg.WebPreviousFile })) {
        Write-DeployKitStep $item.Name
        Write-DeployKitInfo "active   : $(Get-DeployKitSitePath -SiteName $item.Site)"
        Write-DeployKitInfo "previous : $(Get-PreviousRelease $item.Previous)"
        Write-DeployKitInfo "pool     : $($item.Pool) = $((Get-WebAppPoolState -Name $item.Pool).Value)"
        $httpsText = if (Test-DeployKitSiteHttps -SiteName $item.Site) { 'yes' } else { 'NO (no certificate yet)' }
        Write-DeployKitInfo "HTTPS    : $httpsText"
    }
    Write-DeployKitStep 'API health'
    $null = Test-DeployKitApiHealth -Settings $cfg -Attempts 1 -DelaySeconds 0
    $history = Join-Path $cfg.DeployLogs 'history.log'
    if (Test-Path -LiteralPath $history) {
        Write-DeployKitStep 'Recent deployments (UTC)'
        Get-Content -LiteralPath $history -Tail 10 -Encoding UTF8 | ForEach-Object { Write-DeployKitInfo $_ }
    }
}

# --- Package verification -------------------------------------------------------------------
function Test-Package([string]$Path, [string]$Destination) {
    Write-DeployKitStep 'Verifying the package'
    if (-not (Test-Path -LiteralPath $Path)) { throw "Package not found: $Path" }
    $hashFile = "$Path.sha256"
    if (-not (Test-Path -LiteralPath $hashFile)) { throw "$hashFile not found. Copy the .sha256 file together with the zip." }
    $expected = (([IO.File]::ReadAllText($hashFile)).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actual -ine $expected) { throw "Package hash MISMATCH (expected $expected, found $actual). The zip is incomplete or corrupt; copy it again." }
    Write-DeployKitOk "SHA-256: $actual"

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($Path, $Destination)
    $manifestPath = Join-Path $Destination 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'manifest.json is missing: not a package built by build-package.ps1.' }
    $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $bad = 0
    foreach ($file in $manifest.files) {
        $filePath = Join-Path $Destination ($file.path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $filePath) -or (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash -ine $file.sha256) {
            Write-Warning "File could not be verified: $($file.path)"
            $bad++
        }
    }
    if ($bad -gt 0) { throw "$bad file(s) do not match the manifest." }
    if ([string]$manifest.appName -cne $cfg.AppName) {
        throw "This package is for '$($manifest.appName)', but this server is set up for '$($cfg.AppName)'."
    }
    Write-DeployKitOk "Version $($manifest.version): $(@($manifest.files).Count) file(s) verified (API URL in web build: $($manifest.apiBaseUrl))."

    $installedKit = Get-DeployKitInstalledVersion -BinPath $cfg.Bin
    $packageKit = [version]$manifest.kitVersion
    Write-DeployKitInfo "Kit version: package $packageKit, installed $installedKit"
    if ($installedKit -and $packageKit -lt $installedKit) {
        Write-Warning "The package was built with an OLDER kit ($packageKit) than the installed scripts ($installedKit). Its scripts will NOT replace the installed ones (unless -Force). Prefer rebuilding the package with the current kit."
    }
    $packageConfig = Join-Path $Destination 'scripts\deploy.config.json'
    if ((Test-Path -LiteralPath $packageConfig) -and (Test-Path -LiteralPath $cfg.ConfigPath) -and
        (Get-FileHash -LiteralPath $packageConfig).Hash -ne (Get-FileHash -LiteralPath $cfg.ConfigPath).Hash) {
        Write-Warning 'deploy.config.json in the package differs from the installed one. This run uses the INSTALLED configuration; the new one is copied to bin at the end and applies from the next run (re-run setup-server.ps1 if hosts, names or downloads changed).'
    }
    return $manifest
}

# =============================================================================================
New-Item -ItemType Directory -Force -Path $cfg.DeployLogs | Out-Null
$doApi = @('All', 'Api') -contains $Component
$doWeb = @('All', 'Web') -contains $Component

if ($Status) { Import-DeployKitIis; Show-Status; return }

if ($VerifyOnly) {
    $Package = (Resolve-Path -LiteralPath $Package).Path
    $extract = Join-Path $cfg.Packages "verify-$stamp"
    try {
        $manifest = Test-Package -Path $Package -Destination $extract
        Write-DeployKitOk "Package is valid. Components: $(@($manifest.components) -join ', '). Nothing was changed."
    }
    finally {
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
    return
}

Import-DeployKitIis
Start-Transcript -Path (Join-Path $cfg.DeployLogs ("install-{0}.log" -f $stamp)) | Out-Null
try {
    if ($Rollback) {
        if ($doApi) { Invoke-ApiRollback }
        if ($doWeb) { Invoke-WebRollback }
        return
    }

    $Package = (Resolve-Path -LiteralPath $Package).Path
    $extract = Join-Path $cfg.Packages "extract-$stamp"
    $manifest = Test-Package -Path $Package -Destination $extract

    $components = @($manifest.components)
    if ($doApi -and $components -notcontains 'api') {
        if ($Component -eq 'Api') { throw 'The package contains no API.' }
        $doApi = $false
    }
    if ($doWeb -and $components -notcontains 'web') {
        if ($Component -eq 'Web') { throw 'The package contains no web build.' }
        $doWeb = $false
    }

    if ($doApi) { Install-Api -Extract $extract -Version $manifest.version -HasMigrations ([bool]$manifest.migrations) }
    if ($doWeb) { Install-Web -Extract $extract -Version $manifest.version }

    # Management scripts from the package (the running script is already in memory; overwriting
    # it is safe). Never downgraded to an older kit unless -Force.
    $scripts = Join-Path $extract 'scripts'
    if (Test-Path -LiteralPath $scripts) {
        Write-DeployKitStep 'Management scripts'
        $null = Copy-DeployKitScripts -Source $scripts -Destination $cfg.Bin -SourceVersion ([string]$manifest.kitVersion) -Force:$Force
    }

    Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    # Keep the newest server.keepReleases packages in the packages folder.
    if ((Split-Path $Package -Parent).TrimEnd('\') -ieq $cfg.Packages.TrimEnd('\')) {
        Get-ChildItem -LiteralPath $cfg.Packages -Filter "$($cfg.PackagePrefix)-*.zip" -File | Sort-Object Name -Descending | Select-Object -Skip $cfg.KeepReleases |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName, "$($_.FullName).sha256" -Force -ErrorAction SilentlyContinue }
    }

    Write-Host ''
    Write-Host "Installation complete: $($manifest.version) ($stamp)." -ForegroundColor Green
}
catch {
    if ($extract -and (Test-Path -LiteralPath $extract)) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
    throw
}
finally {
    Stop-Transcript | Out-Null
}
