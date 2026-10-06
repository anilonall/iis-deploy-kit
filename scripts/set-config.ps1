<#
.SYNOPSIS
    Validates <root>\config\app.env and copies its values into the environment variables of the
    API application pool, then restarts the pool and checks the health endpoint.

.DESCRIPTION
    Why app pool environment variables? ASP.NET Core reads configuration from environment
    variables (Jwt__SigningKey == Jwt:SigningKey). For an IIS application pool they are stored in
    the server's IIS configuration (applicationHost.config):
      * no secret ever lives in the site folder or in the web.config that every release replaces,
      * applicationHost.config is readable by Administrators + SYSTEM only; IIS generates a
        per-pool copy that only that pool's identity can read,
      * IIS configuration history (automatic backups) is redirected by setup-server.ps1 to the
        protected <root>\config\iis-history folder.

    Steps:
      1. Read app.env. Stop (IIS untouched) on a malformed line, an unfilled <...> / {{...}}
         value, a missing required key (api.connectionStringKey + api.requiredEnvKeys) or a value
         shorter than api.minLengthEnvKeys.
      2. REPLACE the pool's variables with the file's values (a line removed from the file is
         removed from IIS too) + ASPNETCORE_ENVIRONMENT=Production.
      3. Restart the pool (unless -NoRestart) and wait for the health endpoint.

    Values are NEVER written to the console, a log or a command line; only key names are listed.

.PARAMETER CheckOnly
    Validate only; IIS is not touched.

.PARAMETER NoRestart
    Do not restart the pool (used by install-release.ps1 while the pool is stopped).

.PARAMETER FillPlaceholders
    Before validating, replace known {{TOKEN}}s on active KEY=VALUE lines of app.env in place
    (e.g. after you uncommented "Jwt__SigningKey={{GENERATED_SECRET}}"). {{GENERATED_SECRET}}
    becomes a new random 64-character secret. {{GENERATED_DB_PASSWORD}} is never generated here
    (it must match the database role; setup-server.ps1 owns it).

.EXAMPLE
    C:\MyApp\bin\set-config.ps1

.EXAMPLE
    C:\MyApp\bin\set-config.ps1 -CheckOnly

.EXAMPLE
    C:\MyApp\bin\set-config.ps1 -FillPlaceholders
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$NoRestart,
    [switch]$FillPlaceholders
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeployKit.Common.psm1') -Force -DisableNameChecking
Assert-DeployKitAdministrator
$cfg = Get-DeployKitSettings -ConfigPath (Join-Path $PSScriptRoot 'deploy.config.json')

# Keys that are meaningless under IIS or managed by this script.
$ignored = @('ASPNETCORE_ENVIRONMENT', 'ASPNETCORE_URLS', 'ASPNETCORE_HTTP_PORTS', 'ASPNETCORE_HTTPS_PORTS', 'ASPNETCORE_HTTPS_PORT')

if ($FillPlaceholders) {
    Write-DeployKitStep "Filling {{...}} tokens on active lines: $($cfg.AppEnv)"
    if (-not (Test-Path -LiteralPath $cfg.AppEnv)) { throw "$($cfg.AppEnv) not found. Run setup-server.ps1 first." }
    $text = [IO.File]::ReadAllText($cfg.AppEnv, [Text.Encoding]::UTF8)
    $expanded = Expand-DeployKitEnvTemplate -Text $text -Tokens (Get-DeployKitEnvTokens -Settings $cfg)
    if ($expanded.ChangedLines -gt 0) {
        $backup = "$($cfg.AppEnv).{0}.bak" -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $cfg.AppEnv -Destination $backup
        [IO.File]::WriteAllText($cfg.AppEnv, $expanded.Text, (New-Object System.Text.UTF8Encoding($false)))
        Write-DeployKitOk "$($expanded.ChangedLines) line(s) filled (values not shown). Previous file: $backup"
    }
    else {
        Write-DeployKitOk 'Nothing to fill.'
    }
    foreach ($u in $expanded.Unresolved) { Write-Warning "Unknown or not generated here: $u" }
    Remove-Variable text, expanded
}

Write-DeployKitStep "Validating settings file: $($cfg.AppEnv)"
$envFile = Read-DeployKitEnvFile -Path $cfg.AppEnv
$problems = New-Object System.Collections.Generic.List[string]

if ($envFile.Invalid.Count -gt 0) { $problems.Add("Malformed lines: $($envFile.Invalid -join ', ') (expected KEY=VALUE).") }
if ($envFile.Placeholders.Count -gt 0) { $problems.Add("Values not filled in (<...> or {{...}}): $($envFile.Placeholders -join ', '). Fill them in, comment the line out, or run with -FillPlaceholders.") }
foreach ($key in $cfg.RequiredEnvKeys) {
    if (-not $envFile.Values.Contains($key) -or [string]::IsNullOrWhiteSpace($envFile.Values[$key])) { $problems.Add("Required key missing or empty: $key") }
}
foreach ($key in $cfg.MinLengthEnvKeys.Keys) {
    if ($envFile.Values.Contains($key) -and $envFile.Values[$key].Length -lt $cfg.MinLengthEnvKeys[$key]) {
        $problems.Add("$key must be at least $($cfg.MinLengthEnvKeys[$key]) characters long.")
    }
}
foreach ($key in $envFile.Duplicates) { Write-Warning "$key appears more than once; the LAST value wins." }
foreach ($key in $envFile.Values.Keys) {
    if ($ignored -contains $key) { Write-Warning "$key is ignored (managed by set-config.ps1 or meaningless under IIS)." }
}

if ($problems.Count -gt 0) {
    foreach ($p in $problems) { Write-Host "    ERROR: $p" -ForegroundColor Red }
    throw "app.env is invalid ($($problems.Count) problem(s)). The IIS configuration was NOT changed."
}

$keys = @($envFile.Values.Keys | Where-Object { $ignored -notcontains $_ })
Write-DeployKitOk "File is valid: $($keys.Count) setting(s)."

if ($CheckOnly) {
    Write-DeployKitInfo ('Keys: ' + ($keys -join ', '))
    return
}

Write-DeployKitStep "Updating application pool environment variables: $($cfg.ApiPool)"
Import-DeployKitIis
if (-not (Test-Path -LiteralPath "IIS:\AppPools\$($cfg.ApiPool)")) {
    throw "Application pool '$($cfg.ApiPool)' does not exist. Run setup-server.ps1 first."
}

$entries = [ordered]@{ 'ASPNETCORE_ENVIRONMENT' = 'Production' }
foreach ($key in $keys) {
    $entries[$key] = [string]$envFile.Values[$key]
}
# WebAdministration cmdlets, NOT Microsoft.Web.Administration.dll (DISP_E_TYPEMISMATCH on
# Windows Server 2025; see Set-DeployKitAppPoolEnvironment).
Set-DeployKitAppPoolEnvironment -PoolName $cfg.ApiPool -Variables $entries
Write-DeployKitOk "$($entries.Count) environment variable(s) written (including ASPNETCORE_ENVIRONMENT=Production). Values are not shown."

if ($NoRestart) { return }

Write-DeployKitStep 'Restarting the application pool'
$sitePath = Get-DeployKitSitePath -SiteName $cfg.ApiSite
if (-not (Test-Path -LiteralPath (Join-Path $sitePath 'web.config'))) {
    Write-DeployKitInfo 'No API release deployed yet; the pool will start with the first deployment.'
    return
}
$startedAt = (Get-Date).AddSeconds(-5)
Stop-DeployKitAppPool -Name $cfg.ApiPool
Start-DeployKitAppPool -Name $cfg.ApiPool
if (-not (Test-DeployKitApiHealth -Settings $cfg -Attempts 30 -DelaySeconds 2)) {
    Write-Host '    Recent events (Event Viewer > Windows Logs > Application):' -ForegroundColor Yellow
    Show-DeployKitRecentApiEvents -Settings $cfg -Since $startedAt
    throw 'The application did not start healthy with the new settings. Fix the setting and run this script again (README > Troubleshooting: 500.30).'
}
