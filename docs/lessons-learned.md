# Lessons learned

This kit was extracted from a deployment that runs in production on Windows Server 2025 + IIS.
Every item below caused a real problem on a real server at least once. The fix is built into
the kit; the comment next to the code points back here.

## 1. App pool environment variables: use the WebAdministration cmdlets

**Symptom.** Writing `environmentVariables` of an application pool through
`Microsoft.Web.Administration.dll` (`ServerManager`) from PowerShell failed on Windows Server 2025
with `DISP_E_TYPEMISMATCH`.

**Cause.** The `WebAdministration` module loads its own version of the assembly; mixing it with a
second `ServerManager` instance in the same PowerShell session conflicts.

**Fix.** `Set-DeployKitAppPoolEnvironment` (in `DeployKit.Common.psm1`) only uses the documented
cmdlets on `MACHINE/WEBROOT/APPHOST`:

```powershell
$filter = "system.applicationHost/applicationPools/add[@name='MyAppApi']/environmentVariables"
Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "$filter/add"
Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter -Name '.' -AtElement @{ name = 'Key' }
Add-WebConfigurationProperty    -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter -Name '.' -Value @{ name = 'Key'; value = '...' }
```

`appcmd.exe` is avoided as well: values would appear on a command line (process list, logs).

## 2. A native tool inside a PowerShell function pollutes the return value

**Symptom.** `install-release.ps1` reported "migrations failed" although the EF Core bundle had
exited with code 0.

**Cause.** PowerShell returns *every* uncaptured output of a function. `& $bundle; return
$LASTEXITCODE` therefore returned an array (the bundle's log lines followed by `0`), and
`$exit -ne 0` was true.

**Fix.** Send the tool's output to the host and return an explicit integer:

```powershell
& $Bundle | Out-Host
return [int]$LASTEXITCODE
```

The same pattern is used by `Invoke-DeployKitNative`.

## 3. win-acme needs `--installation iis`

**Symptom.** A certificate was issued, but the site had no HTTPS binding, and a later renewal did
not update IIS.

**Cause.** Without `--installation iis` win-acme only stores the certificate in the Windows
certificate store.

**Fix.** Always:

```powershell
wacs.exe --source iis --siteid <ID> --installation iis --validation selfhosting --emailaddress <you@example.com> --accepttos
```

`setup-server.ps1` prints these exact commands with the real site IDs.

## 4. Old packages re-install old scripts

**Symptom.** A script fix was deployed, then an *older* package was installed again (e.g. to roll
the application back). The old, broken scripts came back to `<root>\bin`.

**Cause.** `install-release.ps1` copies the management scripts that travel inside the package.

**Fix.**

- Every package's `manifest.json` records `kitVersion`; `<root>\bin\kit-version.txt` records the
  installed one.
- `Copy-DeployKitScripts` never replaces newer scripts with an older kit version unless `-Force`
  is given, and `install-release.ps1` prints both versions.
- For an application rollback use `install-release.ps1 -Rollback` (switches folders, does not touch
  scripts) instead of re-installing an old package.
- Rule of thumb: **always deploy the newest package.**

## 5. Generated secrets ended up in a comment

**Symptom.** After `setup-server.ps1`, the header comment of `app.env` (which documents the
placeholders) contained the generated database password and signing key.

**Cause.** The placeholders were replaced with a plain string replace over the whole file.

**Fix.** `Expand-DeployKitEnvTemplate` replaces `{{TOKEN}}`s only on active `KEY=VALUE` lines.
Comment lines are left byte-for-byte unchanged. A commented example that you enable later is
filled with `set-config.ps1 -FillPlaceholders`.

## 6. Background workers need an "always running" app pool

**Symptom.** Scheduled jobs and queue processors inside the API stopped at night.

**Cause.** IIS defaults: the worker process starts on the first request, shuts down after 20 idle
minutes and recycles every 29 hours. Overlapping recycling briefly runs two processes (two
schedulers).

**Fix (`server.alwaysRunning`, default `true`).** `startMode=AlwaysRunning`, `idleTimeout=0`,
periodic restarts (time, requests, memory, schedule) off, `disallowOverlappingRotation=true`,
`preloadEnabled=true` + the Application Initialization feature, and a scheduled
`startup-check.ps1` two minutes after boot: if PostgreSQL was not ready when the app started, the
pool is restarted once.

## 7. Turkish-locale Windows and case-insensitive regex

**Symptom.** `Jwt__Issuer=...` was reported as an invalid key on a server with a Turkish locale.

**Cause.** PowerShell's `-match` is case-insensitive and culture-sensitive. In Turkish, the
upper-case `I` does not fold to `i`, so `'^[A-Z_]...'` did not match.

**Fix.** Identifier checks use case-sensitive operators (`-cmatch`, `-cnotmatch`, `-ceq`) with
explicit `[A-Za-z]` classes. The module's tests run under `tr-TR`.

## 8. Secrets

- Never in the package, never in the site folder, never in `web.config`.
- One protected file: `<root>\config\app.env` (Administrators + SYSTEM; inheritance removed).
- `set-config.ps1` copies the values into the app pool's environment variables (stored in
  `applicationHost.config`, readable by administrators; IIS gives each pool its own copy).
- IIS configuration history (`configHistory`) is moved into the protected config folder, so its
  automatic backups of `applicationHost.config` do not leak the values.
- Values are never printed; scripts list key names only.
- `psql`, `pg_dump`, `pg_restore` and the migrations bundle receive secrets only through their own
  process environment (`PGPASSWORD`, `ConnectionStrings__...`), restored right afterwards.
- The PostgreSQL superuser password exists only DPAPI-encrypted (machine scope).
- IIS access logs omit the query string and Referer (one-time tokens in links).

## Smaller things worth knowing

- **Hosting Bundle before IIS.** If the ASP.NET Core Hosting Bundle was installed before IIS, the
  ASP.NET Core Module is not registered (500.19/500.21). `setup-server.ps1` detects this and runs
  the installer with `/repair`.
- **`net stop was /y` + `net start w3svc`** after installing the Hosting Bundle (Microsoft's
  documented step); `iisreset` alone is not enough for PATH changes.
- **Certificate first, then HTTPS redirects.** Until the web site has a certificate,
  `install-release.ps1` installs the SPA in "HTTP-only" mode (no redirect to https, no HSTS, no
  `upgrade-insecure-requests`). Re-install the same package after win-acme.
- **The first EF Core migration logs a "failed" query.** On an empty database EF probes
  `__EFMigrationsHistory` before creating it and logs the failed `SELECT`. The bundle still exits
  with code 0; the kit only looks at the exit code.
- **Default Web Site** catches `*:80` and must be stopped, otherwise it answers for unknown hosts.
- **icacls and localized Windows.** Built-in groups are granted by SID (`*S-1-5-32-544`,
  `*S-1-5-18`), never by display name.
- **ZIP entry names.** Windows PowerShell 5.1's `ZipFile.CreateFromDirectory` writes `\` in entry
  names; the kit writes `/` explicitly so the archive is portable.
