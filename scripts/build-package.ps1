<#
.SYNOPSIS
    Builds ONE versioned release package on YOUR machine (Windows): API + EF Core migrations
    bundle + SPA build + server scripts + configuration, as a zip with a SHA-256 file next to it.

.DESCRIPTION
    Everything is driven by deploy.config.json (validated first).
      1. API: dotnet publish -c Release -r <api.runtimeIdentifier> --self-contained false.
         Files in api.excludeFromPackage are removed (default appsettings.Development.json).
         When the publish output has no appsettings.Production.json, the kit's template is added
         (log levels + Windows Event Log source; no secrets).
         web.config is patched: hostingModel=inprocess, stdout log off, request size limit,
         no Server / X-Powered-By headers, security headers + HSTS (templates/api).
      2. EF Core migrations bundle (migrations.enabled): dotnet ef migrations bundle
         -r <rid> --self-contained -> efbundle.exe (the server needs no .NET SDK). A local tool
         manifest (.config/dotnet-tools.json) is restored first when one is found.
      3. Web (frontend.enabled): installCommand + buildCommand in the frontend folder with
         <frontend.apiBaseUrlEnvVar>=https://<domains.api> in the environment. The output is
         verified (index.html, JavaScript, the API URL inside the bundle). web.config comes from
         the build output (e.g. Vite public/web.config) or from templates/spa/web.config; its
         placeholders are filled and the CSP connect-src must contain the API origin.
      4. scripts/: server scripts, deploy.config.json and the app.env template.
      5. manifest.json (app, version, kit version, git commit, SHA-256 of every file) + zip + .sha256.

    No secret goes into the package: secrets live only on the server in <root>\config\app.env.
    Everything is built in Release, so a running Debug instance of your API is not affected.

.PARAMETER Config
    Path to deploy.config.json. Default: .\deploy.config.json (current directory).

.PARAMETER Component
    All (default), Api or Web.

.PARAMETER OutputDirectory
    Where the zip is written. Default: <folder of deploy.config.json>\artifacts.

.PARAMETER SkipFrontendInstall
    Skip frontend.installCommand (node_modules already up to date).

.EXAMPLE
    .\scripts\build-package.ps1 -Config .\sample\deploy.config.json

.EXAMPLE
    .\deploy\iis\scripts\build-package.ps1 -Config .\deploy.config.json -Component Web
#>
[CmdletBinding()]
param(
    [string]$Config = '.\deploy.config.json',
    [ValidateSet('All', 'Api', 'Web')][string]$Component = 'All',
    [string]$OutputDirectory,
    [switch]$SkipFrontendInstall
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployKit.Common.psm1') -Force -DisableNameChecking
$kitRoot = Split-Path -Parent $PSScriptRoot
$templates = Join-Path $kitRoot 'templates'

$Config = (Resolve-Path -LiteralPath $Config).Path
Write-DeployKitStep "Configuration: $Config"
$cfg = Get-DeployKitSettings -ConfigPath $Config
$configDir = $cfg.ConfigDirectory
Write-DeployKitOk "Valid: app '$($cfg.AppName)', web $($cfg.WebHost), API $($cfg.ApiHost), kit $($cfg.KitVersion)."

function Resolve-ConfigPath([string]$Relative, [string]$What) {
    $full = [IO.Path]::GetFullPath((Join-Path $configDir $Relative))
    if (-not (Test-Path -LiteralPath $full)) { throw "$What not found: $full (paths are relative to $configDir)." }
    return $full
}

function Invoke-Step([string]$Description, [scriptblock]$Command) {
    Write-DeployKitStep $Description
    Invoke-DeployKitNative -Description $Description -Command $Command
}

# Runs a configured command line (e.g. "npm ci") through cmd.exe so npm.cmd/yarn.cmd/pnpm.cmd
# work and the exit code is reliable.
function Invoke-ShellCommand([string]$Description, [string]$CommandLine, [string]$WorkingDirectory) {
    Push-Location $WorkingDirectory
    try {
        Invoke-Step "$Description ($CommandLine)" { & cmd.exe /d /c $CommandLine }
    }
    finally { Pop-Location }
}

function Get-GitInfo([string]$Path) {
    Push-Location $Path
    try {
        $sha = & git rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $sha) { return [ordered]@{ commit = 'nogit'; dirty = $false } }
        $dirty = [bool](& git status --porcelain 2>$null)
        return [ordered]@{ commit = "$sha".Trim(); dirty = $dirty }
    }
    catch { return [ordered]@{ commit = 'nogit'; dirty = $false } }
    finally { Pop-Location }
}

function Find-ToolManifestDirectory([string]$StartDirectory) {
    $dir = [IO.DirectoryInfo]$StartDirectory
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName '.config\dotnet-tools.json')) { return $dir.FullName }
        if (Test-Path -LiteralPath (Join-Path $dir.FullName 'dotnet-tools.json')) { return $dir.FullName }
        $dir = $dir.Parent
    }
    return $null
}

function Save-Xml([xml]$Document, [string]$Path) {
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try { $Document.Save($writer) } finally { $writer.Dispose() }
}

$doApi = @('All', 'Api') -contains $Component
$doWeb = (@('All', 'Web') -contains $Component) -and $cfg.FrontendEnabled
if ($Component -eq 'Web' -and -not $cfg.FrontendEnabled) { throw 'frontend.enabled is false in deploy.config.json.' }

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $configDir 'artifacts' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw "'dotnet' not found (.NET SDK required)." }

$git = Get-GitInfo $configDir
if ($git.dirty) { Write-Warning 'The working tree has uncommitted changes; the package includes them.' }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$version = "$stamp-$($git.commit)"
$staging = Join-Path $OutputDirectory "staging-$stamp"
New-Item -ItemType Directory -Force -Path $staging | Out-Null
$components = New-Object System.Collections.Generic.List[string]
$hasMigrations = $false
$frontendGit = $null
$zipPath = $null

try {
    # --- API -------------------------------------------------------------------------------
    if ($doApi) {
        $apiProject = Resolve-ConfigPath $cfg.ApiProject 'api.project'
        $apiDir = Join-Path $staging 'api'
        Invoke-Step "dotnet publish (Release, $($cfg.RuntimeIdentifier), framework-dependent)" {
            dotnet publish $apiProject -c Release -r $cfg.RuntimeIdentifier --self-contained false -o $apiDir -nologo
        }
        if (-not (Test-Path -LiteralPath (Join-Path $apiDir "$($cfg.ApiAssemblyName).dll"))) {
            throw "$($cfg.ApiAssemblyName).dll not found in the publish output. Set api.assemblyName in deploy.config.json."
        }

        # Development settings and development-only files never go to production.
        foreach ($exclude in $cfg.ExcludeFromPackage) {
            $target = Join-Path $apiDir $exclude
            if (Test-Path -LiteralPath $target) {
                Remove-Item -LiteralPath $target -Recurse -Force
                Write-DeployKitInfo "Excluded: $exclude"
            }
        }
        $prodSettings = Join-Path $apiDir 'appsettings.Production.json'
        if (Test-Path -LiteralPath $prodSettings) {
            Write-DeployKitInfo 'appsettings.Production.json comes from your project (template not applied).'
        }
        else {
            $json = [IO.File]::ReadAllText((Join-Path $templates 'api\appsettings.Production.json'), [Text.Encoding]::UTF8)
            $json = $json.Replace('__EVENT_LOG_SOURCE__', ($cfg.EventSource -replace '\\', '\\' -replace '"', '\"'))
            [IO.File]::WriteAllText($prodSettings, $json, (New-Object System.Text.UTF8Encoding($false)))
            Write-DeployKitInfo "appsettings.Production.json added from the template (Event Log source '$($cfg.EventSource)')."
        }

        Write-DeployKitStep 'Patching web.config (IIS / ASP.NET Core Module V2)'
        $webConfigPath = Join-Path $apiDir 'web.config'
        if (-not (Test-Path -LiteralPath $webConfigPath)) { throw 'The publish output has no web.config (is this an ASP.NET Core web project?).' }
        $doc = New-Object System.Xml.XmlDocument
        $doc.PreserveWhitespace = $false
        $doc.Load($webConfigPath)
        $webServer = $doc.SelectSingleNode('/configuration/location/system.webServer')
        if (-not $webServer) { $webServer = $doc.SelectSingleNode('/configuration/system.webServer') }
        if (-not $webServer) { throw 'web.config has no system.webServer element.' }
        $aspNetCore = $webServer.SelectSingleNode('aspNetCore')
        if (-not $aspNetCore) { throw 'web.config has no aspNetCore element.' }
        # In-process: the app runs inside w3wp.exe; no extra Kestrel port or proxy hop; the real
        # client IP and the https scheme arrive directly (no forwarded headers to trust).
        $aspNetCore.SetAttribute('hostingModel', 'inprocess')
        # The stdout log is never rotated and fills the disk: off. Enable temporarily on the server
        # to diagnose a 500.30; the folder exists and the API pool may write there.
        $aspNetCore.SetAttribute('stdoutLogEnabled', 'false')
        $aspNetCore.SetAttribute('stdoutLogFile', (Join-Path $cfg.StdoutLogs 'api'))
        # Graceful shutdown time for background services (app_offline.htm / pool stop), seconds.
        $aspNetCore.SetAttribute('shutdownTimeLimit', '30')

        foreach ($name in 'security', 'httpProtocol') {
            $existing = $webServer.SelectSingleNode($name)
            if ($existing) { [void]$webServer.RemoveChild($existing) }
        }
        $patchText = [IO.File]::ReadAllText((Join-Path $templates 'api\web.config.patch.xml'), [Text.Encoding]::UTF8)
        $patchText = $patchText.Replace('__MAX_REQUEST_BYTES__', [string]([long]$cfg.MaxRequestBodyMb * 1MB))
        $patch = New-Object System.Xml.XmlDocument
        $patch.LoadXml($patchText)
        foreach ($element in @($patch.DocumentElement.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
            [void]$webServer.AppendChild($doc.ImportNode($element, $true))
        }
        Save-Xml $doc $webConfigPath
        Write-DeployKitOk "hostingModel=inprocess, stdout off, $($cfg.MaxRequestBodyMb) MB request limit, security headers."
        $components.Add('api')

        if ($cfg.MigrationsEnabled) {
            $migrationsProject = Resolve-ConfigPath $cfg.MigrationsProject 'migrations.project'
            $startupProject = Resolve-ConfigPath $cfg.MigrationsStartup 'migrations.startupProject'
            $manifestDir = Find-ToolManifestDirectory (Split-Path -Parent $startupProject)
            $toolDir = if ($manifestDir) { $manifestDir } else { $configDir }
            Push-Location $toolDir
            try {
                if ($manifestDir) { Invoke-Step "dotnet tool restore ($manifestDir)" { dotnet tool restore } }
                Invoke-Step 'dotnet-ef tool check' { dotnet ef --version }
                $bundlePath = Join-Path $staging 'efbundle.exe'
                Invoke-Step "EF Core migrations bundle ($($cfg.MigrationsContext), $($cfg.RuntimeIdentifier), self-contained)" {
                    dotnet ef migrations bundle --project $migrationsProject --startup-project $startupProject `
                        --context $cfg.MigrationsContext -r $cfg.RuntimeIdentifier --self-contained --configuration Release `
                        -o $bundlePath --force
                }
            }
            finally { Pop-Location }
            $hasMigrations = $true
        }
    }

    # --- Web ---------------------------------------------------------------------------------
    if ($doWeb) {
        $frontendDir = Resolve-ConfigPath $cfg.FrontendPath 'frontend.path'
        $frontendGit = Get-GitInfo $frontendDir
        if ($frontendGit.commit -ne $git.commit -and $frontendGit.dirty) { Write-Warning 'The frontend working tree has uncommitted changes; the package includes them.' }

        $varName = $cfg.ApiBaseUrlEnvVar
        foreach ($envFileName in '.env.production.local', '.env.local', '.env.production', '.env') {
            $envFilePath = Join-Path $frontendDir $envFileName
            if (-not (Test-Path -LiteralPath $envFilePath)) { continue }
            $line = Select-String -LiteralPath $envFilePath -Pattern ("^\s*{0}\s*=\s*(.+?)\s*$" -f [regex]::Escape($varName)) -CaseSensitive | Select-Object -Last 1
            if ($line -and $line.Matches[0].Groups[1].Value.Trim('"').TrimEnd('/') -cne $cfg.ApiOrigin) {
                Write-Warning "$envFileName sets $varName to a different value; the build uses $($cfg.ApiOrigin) (process environment wins in Vite)."
            }
        }

        $distDir = Join-Path $frontendDir $cfg.FrontendOutput
        $previousValue = [Environment]::GetEnvironmentVariable($varName, 'Process')
        try {
            [Environment]::SetEnvironmentVariable($varName, $cfg.ApiOrigin, 'Process')
            if ($cfg.FrontendInstall -and -not $SkipFrontendInstall) {
                Invoke-ShellCommand 'Frontend dependencies' $cfg.FrontendInstall $frontendDir
            }
            Invoke-ShellCommand 'Frontend build' $cfg.FrontendBuild $frontendDir
        }
        finally {
            [Environment]::SetEnvironmentVariable($varName, $previousValue, 'Process')
        }

        Write-DeployKitStep 'Verifying the build output'
        if (-not (Test-Path -LiteralPath (Join-Path $distDir 'index.html'))) { throw "index.html not found in $distDir (frontend.outputDir)." }
        $jsFiles = @(Get-ChildItem -LiteralPath $distDir -Filter '*.js' -File -Recurse)
        if ($jsFiles.Count -eq 0) { throw "No JavaScript files in $distDir." }
        if ($cfg.VerifyApiUrlInBundle) {
            if (-not ($jsFiles | Select-String -SimpleMatch -Pattern $cfg.ApiOrigin -List | Select-Object -First 1)) {
                throw "The API URL ($($cfg.ApiOrigin)) was not found in the built JavaScript: $varName did not reach the build. (Set frontend.verifyApiUrlInBundle=false if your app gets the URL another way.)"
            }
        }

        $webDir = Join-Path $staging 'web'
        New-Item -ItemType Directory -Force -Path $webDir | Out-Null
        Copy-Item -Path (Join-Path $distDir '*') -Destination $webDir -Recurse -Force

        $spaConfig = Join-Path $webDir 'web.config'
        if (Test-Path -LiteralPath $spaConfig) {
            Write-DeployKitInfo "web.config comes from the build output ($($cfg.FrontendOutput)\web.config)."
        }
        else {
            Copy-Item -LiteralPath (Join-Path $templates 'spa\web.config') -Destination $spaConfig
            Write-DeployKitInfo 'web.config added from templates/spa/web.config.'
        }
        $spaText = [IO.File]::ReadAllText($spaConfig, [Text.Encoding]::UTF8)
        $spaText = $spaText.Replace('__WEB_HOST_REGEX__', [regex]::Escape($cfg.WebHost)).Replace('__WEB_HOST__', $cfg.WebHost).Replace('__API_ORIGIN__', $cfg.ApiOrigin)
        $leftover = [regex]::Matches($spaText, '__[A-Z][A-Z0-9_]*__') | ForEach-Object { $_.Value } | Select-Object -Unique
        if ($leftover) { throw "web.config still contains unknown placeholder(s): $($leftover -join ', ')" }
        [IO.File]::WriteAllText($spaConfig, $spaText, (New-Object System.Text.UTF8Encoding($false)))
        try { $spaXml = [xml]$spaText } catch { throw "web.config is not well-formed XML: $($_.Exception.Message)" }
        $csp = $spaXml.SelectSingleNode("/configuration/system.webServer/httpProtocol/customHeaders/add[@name='Content-Security-Policy']")
        if ($csp) {
            $connect = [regex]::Match($csp.GetAttribute('value'), 'connect-src([^;]*)')
            if (-not $connect.Success -or ($connect.Groups[1].Value -split '\s+') -notcontains $cfg.ApiOrigin) {
                throw "The SPA web.config CSP connect-src does not allow $($cfg.ApiOrigin); the browser would block every API call. Fix the CSP (or use the __API_ORIGIN__ placeholder)."
            }
        }
        else {
            Write-Warning 'The SPA web.config has no Content-Security-Policy header.'
        }
        if (-not $spaXml.SelectSingleNode("/configuration/system.webServer/rewrite/rules/rule[@name='canonical-host']")) {
            Write-Warning "The SPA web.config has no rule named 'canonical-host'; HTTP-only mode (before the certificate) cannot disable the HTTPS redirect."
        }
        Write-DeployKitOk "Build verified: index.html, web.config, $($jsFiles.Count) JavaScript file(s), API URL $($cfg.ApiOrigin)"
        $components.Add('web')
    }

    if ($components.Count -eq 0) { throw 'Nothing to package.' }

    # --- Server scripts, configuration, env template -----------------------------------------
    $scriptsDir = Join-Path $staging 'scripts'
    New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
    foreach ($name in (Get-DeployKitManagedFiles)) {
        if ($name -eq 'app.env.example' -or $name -eq 'deploy.config.json') { continue }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $scriptsDir -Force
    }
    Copy-Item -LiteralPath $Config -Destination (Join-Path $scriptsDir 'deploy.config.json') -Force
    $envTemplate = if ($cfg.EnvTemplate) { Resolve-ConfigPath $cfg.EnvTemplate 'api.envTemplate' } else { Join-Path $templates 'app.env.example' }
    Copy-Item -LiteralPath $envTemplate -Destination (Join-Path $scriptsDir 'app.env.example') -Force
    $templateText = [IO.File]::ReadAllText($envTemplate, [Text.Encoding]::UTF8)
    if ($templateText -cnotmatch ('(?m)^' + [regex]::Escape($cfg.ConnectionStringKey) + '=')) {
        Write-Warning "The app.env template has no active '$($cfg.ConnectionStringKey)=' line (api.connectionStringKey)."
    }

    # --- Manifest + zip + SHA-256 ------------------------------------------------------------
    Write-DeployKitStep 'manifest.json and zip'
    $files = @(Get-ChildItem -LiteralPath $staging -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($staging.Length + 1).Replace('\', '/')
            [ordered]@{ path = $relative; size = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        })
    $manifest = [ordered]@{
        appName      = $cfg.AppName
        version      = $version
        kitVersion   = $cfg.KitVersion
        createdUtc   = [DateTime]::UtcNow.ToString('o')
        components   = @($components)
        migrations   = $hasMigrations
        apiHost      = $cfg.ApiHost
        webHost      = $cfg.WebHost
        apiBaseUrl   = $cfg.ApiOrigin
        git          = $git
        frontendGit  = $frontendGit
        hostingModel = 'inprocess'
        runtime      = "$($cfg.RuntimeIdentifier) (framework-dependent)"
        files        = $files
    }
    [IO.File]::WriteAllText((Join-Path $staging 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

    $zipName = "$($cfg.PackagePrefix)-$version.zip"
    $zipPath = Join-Path $OutputDirectory $zipName
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    # Entry names use '/' (ZIP standard; Windows PowerShell 5.1's CreateFromDirectory writes '\').
    $zipStream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
    try {
        $archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in Get-ChildItem -LiteralPath $staging -Recurse -File) {
                $entryName = $file.FullName.Substring($staging.Length + 1).Replace('\', '/')
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, [IO.Compression.CompressionLevel]::Optimal)
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $zipStream.Dispose() }
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    [IO.File]::WriteAllText("$zipPath.sha256", "$hash  $zipName`n", (New-Object System.Text.UTF8Encoding($false)))
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$sizeMb = [Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
Write-Host ''
Write-Host "Package : $zipPath ($sizeMb MB)" -ForegroundColor Green
Write-Host "SHA-256 : $hash" -ForegroundColor Green
Write-Host "Contents: $($components -join ' + ')$(if ($hasMigrations) { ' + migrations' }) + scripts (kit $($cfg.KitVersion))"
Write-Host ''
Write-Host "Copy the zip AND the .sha256 file to $($cfg.Packages)\ on the server (RDP), then run there:"
Write-Host "  $($cfg.Bin)\install-release.ps1 -Package $($cfg.Packages)\$zipName"
Write-Host 'First time? Extract the zip and run scripts\setup-server.ps1 first (README > Quick start).'
