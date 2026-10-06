<#
.SYNOPSIS
    Dependency-free tests for DeployKit.Common.psm1 and the pure helpers of install-release.ps1.
    Runs on any Windows machine with Windows PowerShell 5.1 (no IIS, no PostgreSQL, no admin).
    Runs under the Turkish culture on purpose (lesson 7).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\DeployKit.Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
[Threading.Thread]::CurrentThread.CurrentCulture = 'tr-TR'
[Threading.Thread]::CurrentThread.CurrentUICulture = 'tr-TR'
Import-Module (Join-Path $repo 'scripts\DeployKit.Common.psm1') -Force -DisableNameChecking

$script:failures = 0
$script:passed = 0
function Assert([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:passed++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:failures++; Write-Host "  FAIL  $Name" -ForegroundColor Red }
}

# Loads a function defined in a script file (without running the script).
function Import-ScriptFunction([string]$Path, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1
    if (-not $fn) { throw "Function $Name not found in $Path" }
    return [scriptblock]::Create($fn.Extent.Text)
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('deploykit-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null

try {
    Write-Host 'Configuration'
    foreach ($file in 'deploy.config.example.json', 'sample\deploy.config.json') {
        $cfg = Get-DeployKitSettings -ConfigPath (Join-Path $repo $file)
        Assert ($null -ne $cfg -and $cfg.AppName.Length -gt 0) "$file is valid"
    }
    $cfg = Get-DeployKitSettings -ConfigPath (Join-Path $repo 'sample\deploy.config.json')
    Assert ($cfg.ApiPool -ceq 'TodoSampleApi' -and $cfg.Root -ceq 'C:\TodoSample' -and $cfg.PgService -ceq 'postgresql-x64-18') 'derived names'
    Assert (($cfg.WebHosts -join ',') -ceq 'example.com,www.example.com') 'web hosts = canonical + aliases'
    Assert ($cfg.RequiredEnvKeys[0] -ceq 'ConnectionStrings__Default') 'connection string key is always required'

    $bad = [IO.File]::ReadAllText((Join-Path $repo 'sample\deploy.config.json')) | ConvertFrom-Json
    $bad.appName = '1 bad'
    $bad.domains.api = 'API.example.com'
    $bad.database.name = 'Bad-Name'
    $bad.database.postgres.majorVersion = 16
    $bad.kitVersion = '99.0.0'
    $bad.domains.webAliases = @('example.com')
    $problems = Test-DeployKitConfig -Config $bad
    foreach ($fragment in 'kitVersion', 'appName', 'domains.api', 'database.name', 'majorVersion', 'must all be different') {
        Assert (@($problems | Where-Object { $_.Contains($fragment) }).Count -gt 0) "invalid config reports '$fragment'"
    }

    Write-Host 'app.env template (lesson 5: tokens only on KEY=VALUE lines)'
    $template = [IO.File]::ReadAllText((Join-Path $repo 'templates\app.env.example'))
    $template += "`r`nJwt__Issuer={{API_ORIGIN}}`r`nJwt__SigningKey={{GENERATED_SECRET}}`r`nOther__Secret={{GENERATED_SECRET}}`r`nUnknown__Key={{NOT_A_TOKEN}}`r`n"
    $result = Expand-DeployKitEnvTemplate -Text $template -Tokens (Get-DeployKitEnvTokens -Settings $cfg) -DbPassword 'db-password-for-test'
    $before = @($template -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('#') }) -join "`n"
    $after = @($result.Text -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('#') }) -join "`n"
    Assert ($before -ceq $after) 'comment lines are unchanged'
    Assert ($after.Contains('{{GENERATED_SECRET}}') -and -not $after.Contains('db-password-for-test')) 'no generated value inside comments'
    $lines = $result.Text -split "`r?`n"
    $connection = $lines | Where-Object { $_.StartsWith('ConnectionStrings__Default=') }
    Assert ($connection -ceq 'ConnectionStrings__Default=Host=127.0.0.1;Port=5432;Database=todosample;Username=todosample;Password=db-password-for-test;Maximum Pool Size=50') 'connection string filled'
    Assert (($lines -contains 'Jwt__Issuer=https://api.example.com') -and ($lines -contains 'Cors__AllowedOrigins__0=https://example.com')) 'config tokens filled'
    $secret1 = ($lines | Where-Object { $_.StartsWith('Jwt__SigningKey=') }).Substring(16)
    $secret2 = ($lines | Where-Object { $_.StartsWith('Other__Secret=') }).Substring(14)
    Assert ($secret1.Length -eq 64 -and $secret2.Length -eq 64 -and $secret1 -cne $secret2) 'one new 64-character secret per occurrence'
    Assert ($result.Unresolved.Count -eq 1 -and $result.Unresolved[0].Contains('{{NOT_A_TOKEN}}')) 'unknown token reported'
    $noDb = Expand-DeployKitEnvTemplate -Text 'A=Password={{GENERATED_DB_PASSWORD}}' -Tokens @{}
    Assert ($noDb.Text -ceq 'A=Password={{GENERATED_DB_PASSWORD}}') 'DB password token kept when no password is given'

    Write-Host 'app.env parsing (lesson 7: Turkish culture)'
    $envPath = Join-Path $temp 'app.env'
    [IO.File]::WriteAllText($envPath, "# comment`r`nJwt__Issuer=https://api.example.com`r`nISSUER_ID=1`r`nQuoted=`"a b`"`r`nBad Key=1`r`nTodo=<fill-me>`r`nTok={{API_HOST}}`r`nDup=1`r`nDup=2`r`n")
    $parsed = Read-DeployKitEnvFile -Path $envPath
    Assert ($parsed.Values.Contains('Jwt__Issuer') -and $parsed.Values.Contains('ISSUER_ID')) 'keys with I are valid under tr-TR'
    Assert ($parsed.Values['Quoted'] -ceq 'a b') 'surrounding quotes removed'
    Assert ($parsed.Invalid.Count -eq 1) 'invalid key detected'
    Assert ((@($parsed.Placeholders) -join ',') -ceq 'Todo,Tok') '<...> and {{...}} detected as unfilled'
    Assert ((@($parsed.Duplicates) -join ',') -ceq 'Dup' -and $parsed.Values['Dup'] -ceq '2') 'duplicates: last wins'

    Write-Host 'Native tools inside functions (lesson 2)'
    $fakeBundle = Join-Path $temp 'fake-bundle.cmd'
    [IO.File]::WriteAllText($fakeBundle, "@echo off`r`necho Applying migration 'Initial'.`r`necho Done.`r`nif `"%ConnectionStrings__Default%`"==`"`" exit /b 7`r`nexit /b %FAKE_EXIT%`r`n")
    [IO.File]::WriteAllText($envPath, "ConnectionStrings__Default=Host=127.0.0.1;Database=x;Username=x;Password=y`r`nFAKE_EXIT=0`r`n")
    $cfg.AppEnv = $envPath
    . (Import-ScriptFunction (Join-Path $repo 'scripts\install-release.ps1') 'Invoke-Migrations')
    $exit = Invoke-Migrations -Bundle $fakeBundle -WorkingDirectory $temp
    Assert ($exit -is [int] -and $exit -eq 0) 'Invoke-Migrations returns [int] 0 despite tool output'
    Assert ($null -eq $env:ConnectionStrings__Default -and $null -eq $env:FAKE_EXIT) 'process environment restored'
    [IO.File]::WriteAllText($envPath, "ConnectionStrings__Default=Host=127.0.0.1;Database=x;Username=x;Password=y`r`nFAKE_EXIT=3`r`n")
    $exit = Invoke-Migrations -Bundle $fakeBundle -WorkingDirectory $temp
    Assert ($exit -is [int] -and $exit -eq 3) 'Invoke-Migrations returns the failing exit code'
    $nativeThrew = $false
    try { Invoke-DeployKitNative -Description 'exit 5' -Command { cmd.exe /d /c 'echo output & exit /b 5' } } catch { $nativeThrew = $_.Exception.Message.Contains('exit code 5') }
    Assert $nativeThrew 'Invoke-DeployKitNative throws on a non-zero exit code'
    $returned = @(Invoke-DeployKitNative -Description 'echo' -Command { cmd.exe /d /c 'echo output' })
    Assert ($returned.Count -eq 0) 'Invoke-DeployKitNative does not leak tool output into the pipeline'

    Write-Host 'SPA web.config'
    $spa = [IO.File]::ReadAllText((Join-Path $repo 'templates\spa\web.config'))
    $placeholders = @([regex]::Matches($spa, '__[A-Z][A-Z0-9_]*__') | ForEach-Object { $_.Value } | Select-Object -Unique | Sort-Object)
    Assert (($placeholders -join ',') -ceq '__API_ORIGIN__,__WEB_HOST__,__WEB_HOST_REGEX__') 'template uses only known placeholders'
    $samplePublic = [IO.File]::ReadAllText((Join-Path $repo 'sample\frontend\public\web.config'))
    Assert ($samplePublic -ceq $spa) 'sample public/web.config equals the template'
    $copy = Join-Path $temp 'web.config'
    [IO.File]::WriteAllText($copy, $spa.Replace('__WEB_HOST_REGEX__', 'example\.com').Replace('__WEB_HOST__', 'example.com').Replace('__API_ORIGIN__', 'https://api.example.com'))
    . (Import-ScriptFunction (Join-Path $repo 'scripts\install-release.ps1') 'Set-WebConfigHttpOnly')
    Set-WebConfigHttpOnly -Path $copy
    $xml = [xml][IO.File]::ReadAllText($copy)
    Assert ($xml.SelectSingleNode("//rule[@name='canonical-host']").GetAttribute('enabled') -ceq 'false') 'HTTP-only: redirect rule disabled'
    Assert ($null -eq $xml.SelectSingleNode("//customHeaders/add[@name='Strict-Transport-Security']")) 'HTTP-only: HSTS removed'
    Assert (-not $xml.SelectSingleNode("//customHeaders/add[@name='Content-Security-Policy']").GetAttribute('value').Contains('upgrade-insecure-requests')) 'HTTP-only: upgrade-insecure-requests removed'
    $patch = [xml][IO.File]::ReadAllText((Join-Path $repo 'templates\api\web.config.patch.xml'))
    Assert ($null -ne $patch.SelectSingleNode('/root/security/requestFiltering/requestLimits')) 'API web.config patch is well-formed'

    Write-Host 'Kit version guard (lesson 4)'
    $source = Join-Path $temp 'pkg-scripts'
    $bin = Join-Path $temp 'bin'
    New-Item -ItemType Directory -Path $source, $bin | Out-Null
    [IO.File]::WriteAllText((Join-Path $source 'backup.ps1'), 'new')
    [IO.File]::WriteAllText((Join-Path $bin 'backup.ps1'), 'installed')
    [IO.File]::WriteAllText((Join-Path $bin 'kit-version.txt'), '1.2.0')
    $copied = Copy-DeployKitScripts -Source $source -Destination $bin -SourceVersion '1.1.0' 3>$null
    Assert (-not $copied -and [IO.File]::ReadAllText((Join-Path $bin 'backup.ps1')) -ceq 'installed') 'older kit does not overwrite newer scripts'
    $copied = Copy-DeployKitScripts -Source $source -Destination $bin -SourceVersion '1.3.0'
    Assert ($copied -and [IO.File]::ReadAllText((Join-Path $bin 'backup.ps1')) -ceq 'new' -and (Get-DeployKitInstalledVersion -BinPath $bin) -eq [version]'1.3.0') 'newer kit updates scripts and kit-version.txt'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "$script:passed passed, $script:failures failed."
if ($script:failures -gt 0) { exit 1 }
