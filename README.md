# iis-deploy-kit

Deploy an **ASP.NET Core (.NET 10) API + a single-page application (React/Vite or any static
build) + EF Core + PostgreSQL** to a single **Windows Server 2025** machine with **IIS**, as one
verified, versioned zip. No CI server, no SSH, no WinRM: build on your PC, copy over RDP, run one
script.

[Türkçe README](README.tr.md)

The kit was extracted from a real production deployment and generalized. Every rough edge that
showed up on the real server is fixed from day one; see [docs/lessons-learned.md](docs/lessons-learned.md).

- **One config file** (`deploy.config.json`, with a JSON schema) - no names, hosts or paths are
  hard-coded in the scripts.
- **One package** per release: API publish + EF Core migrations bundle + SPA build + server
  scripts, a `manifest.json` with the SHA-256 of every file, and a `.sha256` for the zip.
- **Idempotent server setup**: IIS, URL Rewrite, ASP.NET Core Hosting Bundle, PostgreSQL, database
  and role, app pools and sites, firewall, event log, win-acme, backups. Every download is pinned
  by hash and, where the vendor signs it, by Authenticode signature.
- **Safe installs**: pre-deploy backup, `app_offline.htm`, migrations, health check, automatic
  rollback; one-command rollback and status.
- **Secrets never leave the server**: one protected `app.env` -> IIS app pool environment variables.
  Nothing secret is in the package, the site folder or `web.config`, and nothing is ever printed.

## Use it in your own project

### 1. Get the kit

```powershell
git clone https://github.com/anilonall/iis-deploy-kit.git
```

or **Code → Download ZIP** on GitHub.

### 2. (Optional) Try the sample first

The kit ships with a tiny working app (`sample/`: .NET API + React). Build a package from it to see
what the kit produces before touching your own project:

```powershell
cd iis-deploy-kit
.\scripts\build-package.ps1 -Config .\sample\deploy.config.json
# -> sample\artifacts\<appname>-<version>.zip  (look inside: api\, web\, efbundle.exe, scripts\, manifest.json)
```

### 3. Copy the kit into your repository

Copy `scripts/` and `templates/` into a folder of your repository and create a
`deploy.config.json` next to them from `deploy.config.example.json`. Put the SPA `web.config`
into your frontend's `public/` folder so it ends up in the build output:

```
your-repo/
├── src/MyApp.Api/                <- your ASP.NET Core API (+ EF Core migrations)
├── frontend/
│   └── public/web.config         <- copied from templates/spa/web.config
└── deploy/iis/
    ├── deploy.config.json        <- copied from deploy.config.example.json, then edited
    ├── scripts/                  <- copied as-is
    └── templates/                <- copied as-is
```

Optionally copy `deploy.config.schema.json` too and point `"$schema"` at it for editor
autocompletion.

### 4. Check that your app fits

The scripts make a few assumptions about your application. Most ASP.NET Core + Vite projects
already meet them:

| Your app needs | Why | Config key |
|---|---|---|
| Reads its connection string from configuration (e.g. `ConnectionStrings:Default`) | The server passes settings as environment variables (`ConnectionStrings__Default`) | `api.connectionStringKey` |
| An anonymous health endpoint that returns 200 when the API and database are OK | Checked after every install, rollback, config change and reboot | `api.healthPath` |
| EF Core migrations (or none) | Packaged as `efbundle.exe` and applied before the switch | `migrations.*` (`enabled: false` to skip) |
| The SPA reads the API address from a build-time variable | The build sets it to `https://<domains.api>` | `frontend.apiBaseUrlEnvVar` (e.g. `VITE_API_BASE_URL`) |
| CORS allows the web origin, if web and API are on different hosts | Browser requests come from `https://<domains.web>` | add to `api.requiredEnvKeys` and `templates/app.env.example` |

No kit code ships inside your application; the kit only runs around it.

### 5. Fill in `deploy.config.json`

The essentials: `appName`, `domains` (`web`, `webAliases`, `api`), `api.project` (your `.csproj`),
`migrations.context`, `frontend.path` and `database.name`. Paths are relative to the config file
itself. Every key is described in [docs/configuration.md](docs/configuration.md). Validate it:

```powershell
.\deploy\iis\scripts\test-config.ps1 -Config .\deploy\iis\deploy.config.json
```

### 6. Build your first package and deploy

```powershell
.\deploy\iis\scripts\build-package.ps1 -Config .\deploy\iis\deploy.config.json
```

Then continue with [Quick start](#quick-start) from step 3 (copy to the server). For later
releases you only repeat **build the package -> copy -> `install-release.ps1`**
([Updates](#updates)).

## Contents

- [Use it in your own project](#use-it-in-your-own-project)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Repository layout](#repository-layout)
- [Quick start](#quick-start)
- [Updates](#updates)
- [Rollback](#rollback)
- [Status and logs](#status-and-logs)
- [Backups and restore](#backups-and-restore)
- [Configuration and secrets](#configuration-and-secrets)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [FAQ](#faq)
- [Limitations](#limitations)
- [Development of the kit](#development-of-the-kit)

## Architecture

```
                       DNS (your provider)
                       ├── example.com      A → server IP
                       ├── www.example.com  A → server IP   (alias, 301 → example.com)
                       └── api.example.com  A → server IP

 Browser ──HTTPS──► Windows Server 2025 · IIS 10 :443 (Let's Encrypt via win-acme, SNI, 2 certificates)
                    │
                    ├── site "<App> Web"  example.com, www.example.com
                    │     C:\<App>\web\releases\<timestamp>      static SPA + web.config
                    │     URL Rewrite: http → https, www → apex, SPA fallback, cache + security headers
                    │
                    └── site "<App> API"  api.example.com
                          ASP.NET Core Module V2, IN-PROCESS (.NET 10 inside w3wp.exe)
                          C:\<App>\api\releases\<timestamp>
                          app pool: AlwaysRunning, no idle shutdown, no periodic recycle
                          configuration: app pool environment variables ← C:\<App>\config\app.env
                              │
                              └──► PostgreSQL (Windows service, localhost only, port blocked)

 HTTP :80 → web: 301 to https (URL Rewrite) · api: redirect by the app (UseHttpsRedirection)
 RDP: administration only. Deployment = one zip copied over RDP + install-release.ps1.
```

Deployment flow:

```
 Your PC                                         Server (RDP, elevated PowerShell)
 ───────                                         ─────────────────────────────────
 build-package.ps1 -Config deploy.config.json
   ├─ dotnet publish (Release, win-x64)
   ├─ dotnet ef migrations bundle → efbundle.exe
   ├─ npm ci && npm run build (VITE_API_BASE_URL)
   └─ myapp-<version>.zip + .sha256 ──── copy ───►  C:\<App>\packages\
                                                     install-release.ps1 -Package ...
                                                       verify → backup → app_offline → migrate
                                                       → switch release → health check
                                                       (fails? → previous release restored)
```

## Prerequisites

**Your machine (Windows 10/11):** .NET 10 SDK, Node.js 20.19+ (for Vite 8), Git, Windows
PowerShell 5.1 (built in). `dotnet-ef` is restored from your tool manifest if you have one,
otherwise install it once: `dotnet tool install --global dotnet-ef`.

**Server:** Windows Server 2025 (tested; 2022 should work but is untested), administrator access
over RDP, outbound internet (official download URLs, Let's Encrypt), inbound **80 and 443** open
(also in your hosting provider's firewall). Recommended 2+ vCPU, 4+ GB RAM, 60+ GB disk.

**Your application** should:

- read its configuration from environment variables (the ASP.NET Core default; `ConnectionStrings__Default`
  becomes `ConnectionStrings:Default`),
- expose an anonymous health endpoint (default `/api/health`) that returns 200 only when the
  database is reachable,
- *not* run migrations at startup (the kit runs the EF Core bundle as an explicit deploy step),
- on Windows, bind `Logging:EventLog` so logs use your event source (see the sample's `Program.cs`).

## Repository layout

```
iis-deploy-kit/
├── deploy.config.schema.json        JSON schema of the configuration
├── deploy.config.example.json       annotated example for a typical app
├── scripts/
│   ├── DeployKit.Common.psm1        shared helpers (config, env file, IIS, PostgreSQL, downloads)
│   ├── build-package.ps1            YOUR PC: builds the release zip
│   ├── test-config.ps1              YOUR PC: validates deploy.config.json, prints derived names
│   ├── setup-server.ps1             SERVER: one-time, idempotent setup
│   ├── install-release.ps1          SERVER: install / rollback / status / verify
│   ├── set-config.ps1               SERVER: app.env → app pool environment variables
│   ├── backup.ps1                   SERVER: pg_dump + storage archive + retention
│   ├── restore-db.ps1               SERVER: restore or test-restore a backup
│   └── startup-check.ps1            SERVER: post-boot health check (scheduled task)
├── templates/
│   ├── app.env.example              server settings template (no real values)
│   ├── spa/web.config               IIS config for the SPA (copy into your public/ folder)
│   └── api/                         web.config patch + appsettings.Production.json
├── sample/                          tiny working example (.NET 10 API + Vite/React/TS)
├── tests/DeployKit.Tests.ps1        dependency-free tests (run under tr-TR culture)
└── docs/                            configuration reference, lessons learned
```

Using it in your own project: see [Use it in your own project](#use-it-in-your-own-project).

## Quick start

The sample in `sample/` uses `example.com`. Replace it with your own domain in
`sample/deploy.config.json` (or your own config) before deploying for real.

### 1. Configure and validate (your PC)

```powershell
copy deploy.config.example.json deploy.config.json      # then edit appName, domains, paths
.\scripts\test-config.ps1 -Config .\deploy.config.json
```

See [docs/configuration.md](docs/configuration.md) for every key.

### 2. Build the package (your PC)

```powershell
# If PowerShell blocks scripts, once:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\scripts\build-package.ps1 -Config .\deploy.config.json
# → artifacts\myapp-20260101-120000-abc1234.zip  +  .zip.sha256
```

Try it with the sample: `.\scripts\build-package.ps1 -Config .\sample\deploy.config.json`.

### 3. Copy to the server (RDP)

Connect with Remote Desktop (`mstsc`), enable **Local Resources → Drives** so your PC's disk
appears on the server, and copy the zip **and** the `.sha256` file to e.g. `C:\Deploy\`. Extract
the zip there (right click → Extract All).

### 4. Set up the server (once; safe to re-run)

Elevated PowerShell on the server:

```powershell
cd C:\Deploy\myapp-20260101-120000-abc1234\scripts
powershell -ExecutionPolicy Bypass -File .\setup-server.ps1
```

It takes 5-15 minutes and ends with the exact DNS records and win-acme commands for your server.
If Windows asks for a restart after installing IIS, restart and run it again.

### 5. DNS

At your DNS provider, create `A` records for the API host, the web host and every alias, pointing
to the server's public IP. When moving an existing site, lower the TTL (e.g. 300 s) a day before.
**Do not touch MX/SPF/DKIM/DMARC/autodiscover records** - changing an `A` record does not affect
e-mail. Check propagation:

```powershell
Resolve-DnsName api.example.com -Server 8.8.8.8 -Type A
```

### 6. Certificates (win-acme)

Once the names resolve to the server and port 80 is reachable from the internet:

```powershell
cd C:\MyApp\tools\win-acme
.\wacs.exe --source iis --siteid <API-SITE-ID> --installation iis --validation selfhosting --emailaddress you@example.com --accepttos
Restart-WebAppPool MyAppApi            # the app learns its HTTPS port (http → https redirect)
.\wacs.exe --source iis --siteid <WEB-SITE-ID> --installation iis --validation selfhosting --emailaddress you@example.com --accepttos
.\wacs.exe --setuptaskscheduler        # renewal task, if it is not there yet
```

`--installation iis` is **required**: without it the certificate is only stored, no HTTPS binding
is created and renewals do not update IIS. Site IDs: `Get-Website | Select-Object Name, Id`.

### 7. Review the settings

```powershell
notepad C:\MyApp\config\app.env      # database password and generated secrets are already filled
C:\MyApp\bin\set-config.ps1
```

### 8. Install the release

```powershell
copy C:\Deploy\myapp-*.zip* C:\MyApp\packages\
C:\MyApp\bin\install-release.ps1 -Package C:\MyApp\packages\myapp-20260101-120000-abc1234.zip
```

If the web certificate did not exist yet, the SPA was installed in **HTTP-only mode** (no https
redirect/HSTS). After step 6 for the web site, install the **same** package again with
`-Component Web`.

Open `https://api.example.com/api/health` and `https://example.com`.

## Updates

```powershell
# your PC
.\scripts\build-package.ps1 -Config .\deploy.config.json             # or -Component Api / Web
# server (after copying zip + .sha256 to C:\MyApp\packages)
C:\MyApp\bin\install-release.ps1 -Package C:\MyApp\packages\myapp-<version>.zip
C:\MyApp\bin\install-release.ps1 -Package C:\MyApp\packages\myapp-<version>.zip -VerifyOnly   # check only
```

What happens for the API: verify hashes → validate `app.env` → copy release → `pg_dump` backup →
`app_offline.htm` (graceful shutdown) → stop pool → apply `app.env` → migrations bundle → switch
the site path → start → health check → on failure, automatic switch back to the previous
release. The web part switches the site path (no downtime) and verifies `/` and a client-side
route return the new `index.html`.

The package also carries the management scripts; they are copied to `C:\MyApp\bin`, **but never
replace a newer kit version with an older one** (use `-Force` only on purpose). Always deploy the
newest package. To update .NET, raise `downloads.hostingBundle.version`, build a package and re-run
`setup-server.ps1` from it.

## Rollback

```powershell
C:\MyApp\bin\install-release.ps1 -Rollback                 # API and web
C:\MyApp\bin\install-release.ps1 -Rollback -Component Api  # API only
```

Rollback switches the application files to the previous release (seconds). **Database migrations
are not rolled back.** Keep migrations additive (expand/contract) so the previous release still
works with the new schema; if not, restore the pre-deploy backup ([below](#backups-and-restore)).

## Status and logs

```powershell
C:\MyApp\bin\install-release.ps1 -Status    # active/previous release, pools, HTTPS, health, history
```

| What | Where |
|---|---|
| App warnings/errors, startup/shutdown | Event Viewer → Windows Logs → Application, source **`<App> API`** |
| Startup failures (500.30 etc.) | Same log, source **IIS AspNetCore Module V2** |
| Pool stopped / recycled | Windows Logs → System, source **WAS** |
| IIS access logs (no query strings) | `C:\MyApp\logs\iis\W3SVC<id>\` |
| Deploy / setup / backup logs, history | `C:\MyApp\logs\deploy` (`history.log`), `logs\setup`, `logs\backup`, `logs\startup-check.log` |
| PostgreSQL | `C:\Program Files\PostgreSQL\<major>\data\log` |

```powershell
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'MyApp API', 'IIS AspNetCore Module V2' } -MaxEvents 30 |
    Format-List TimeCreated, ProviderName, LevelDisplayName, Message
```

**ANCM stdout log** (only when a startup error is not explained by the event log, temporarily):
set `stdoutLogEnabled="true"` in the active release's `web.config` → reproduce → read
`C:\MyApp\logs\stdout\api_*.log` → set it back to `false` and delete the files (they are never
rotated). The next deployment resets it anyway.

## Backups and restore

- **Automatic:** every night (`<db>-daily-*.dump`, 14 days), before every API deployment
  (`<db>-pre-deploy-*`, 30 days), weekly storage archive (`storage-*.zip`, 28 days). Task Scheduler
  → `<App>` → `<App> Daily Backup` (last result should be `0x0`).
- **Manual:** `C:\MyApp\bin\backup.ps1 -Label manual`
- **Off-server copies are your job.** A backup on the server does not survive the loss of the
  server. Copy `C:\MyApp\backups` regularly (encrypted, they contain personal data) and enable your
  provider's snapshots.

Restore - **test first** (production is not touched):

```powershell
C:\MyApp\bin\restore-db.ps1 -BackupFile C:\MyApp\backups\<file>.dump -TestOnly
```

Real restore (current state is backed up first, API stopped, `pg_restore --clean --if-exists
--single-transaction`, API started, asks you to type `YES`):

```powershell
C:\MyApp\bin\restore-db.ps1 -BackupFile C:\MyApp\backups\<file>.dump
```

Storage folder:

```powershell
Stop-WebAppPool MyAppApi
Rename-Item C:\MyApp\storage storage-old-$(Get-Date -Format yyyyMMdd)
Expand-Archive C:\MyApp\backups\storage-<stamp>.zip -DestinationPath C:\MyApp
icacls C:\MyApp\storage /grant "IIS AppPool\MyAppApi:(OI)(CI)M"
Start-WebAppPool MyAppApi
```

## Configuration and secrets

- **`deploy.config.json`** (in your repo, packaged, no secrets): names, hosts, versions, paths.
  Reference: [docs/configuration.md](docs/configuration.md).
- **`C:\MyApp\config\app.env`** (server only, Administrators + SYSTEM): `KEY=VALUE` lines.
  Created once by `setup-server.ps1` from your template; the database password and every
  `{{GENERATED_SECRET}}` are random. After editing, run `set-config.ps1`: it validates the file
  (format, unfilled `<...>`/`{{...}}`, required keys, minimum lengths) and only then replaces the
  API pool's environment variables and restarts it.
- Start your own template from [templates/app.env.example](templates/app.env.example) and set
  `api.envTemplate`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| **HTTP 500.19** (Config Error, `0x8007000d`) | IIS does not know a `web.config` section: URL Rewrite missing (web), ASP.NET Core Module missing (API), or a duplicate MIME/header entry | Re-run `setup-server.ps1`. Check `Test-Path C:\Windows\System32\inetsrv\rewrite.dll` and `Test-Path "C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"`. The error page's "Config Source" shows the offending line |
| **HTTP 500.30** (app failed to start) | Exception at startup: missing/invalid setting, database down, wrong password | Event Viewer (IIS AspNetCore Module V2 + `<App> API`), `set-config.ps1 -CheckOnly`, `Get-Service postgresql-x64-*`, temporary stdout log ([above](#status-and-logs)) |
| **HTTP 500.31 / 500.32** | ASP.NET Core runtime missing, or a 32-bit pool | Re-run `setup-server.ps1`; "Enable 32-bit applications" must be False |
| **HTTP 502.5** (process failure) | Only out-of-process hosting produces it: `hostingModel` was changed by hand | The kit always packages `inprocess`; re-install the latest package |
| **HTTP 503** | Pool stopped (Rapid-Fail Protection after repeated crashes) or deployment in progress | `Get-WebAppPoolState MyAppApi`; reason in System log (WAS). Fix, then `startup-check.ps1` or `Start-WebAppPool` |
| 500.19/500.21 right after a fresh setup | Hosting Bundle installed **before** IIS | `setup-server.ps1` detects this and runs `/repair`; manually: repair the Hosting Bundle + `net stop was /y; net start w3svc` |
| `set-config.ps1`: **DISP_E_TYPEMISMATCH** | Custom code using `Microsoft.Web.Administration.dll` in the same session as the WebAdministration module | Use the kit's `Set-DeployKitAppPoolEnvironment` (WebAdministration cmdlets). Open a new PowerShell window |
| Certificate issued but **no https binding** / renewals don't update IIS | win-acme ran without `--installation iis` | Run it again with `--source iis --siteid <id> --installation iis` |
| win-acme: `Authorization failed`, `Connection refused` | DNS not propagated, or port 80 closed at the provider | `Resolve-DnsName <host> -Server 8.8.8.8`; from outside `Test-NetConnection <ip> -Port 80`; ask the provider to allow 80/443 |
| Site shows the old server / old content | DNS cache or a long TTL, a stale `AAAA` record | Wait for the TTL, `ipconfig /flushdns`, remove old `AAAA` records |
| `https://` works but `http://` does not redirect, or certificate warning on the web | Web certificate missing or web still in HTTP-only mode | Step 6 for the web site, then re-install the same package with `-Component Web` |
| Browser console: **CORS** error | Web origin not in the API's allowed origins (`www` vs apex, trailing `/`) | Add the exact origin (`https://example.com`, no trailing slash) to `app.env`, `set-config.ps1` |
| Browser blocks API calls with a **CSP** error | `connect-src` does not include the API origin | Use `__API_ORIGIN__` in your SPA `web.config` (build fails if it is missing) |
| Login lost on refresh / **cookies** not sent | Cookie not `Secure`/`SameSite` compatible, API not on HTTPS, web in HTTP-only mode | Web and API must both be HTTPS; sibling subdomains (`example.com` + `api.example.com`) are *same-site*, so `SameSite=Lax` works with `credentials: 'include'` |
| Client-side route refresh returns 404 | URL Rewrite missing or no `web.config` in the release | `Test-Path C:\Windows\System32\inetsrv\rewrite.dll`; `install-release.ps1 -Status` |
| Blank page after a deployment | Browser kept an old `index.html`, or a build error | Ctrl+F5, browser console; `-Rollback -Component Web` |
| **404.13** on upload | Request bigger than `server.maxRequestBodyMb` | Raise it in `deploy.config.json`, rebuild, re-install |
| Upload fails with "Access to the path is denied" | Pool identity lost its rights on `storage` (folder moved/restored) | `icacls C:\MyApp\storage /grant "IIS AppPool\MyAppApi:(OI)(CI)M"` or re-run `setup-server.ps1` |
| Migration step fails | Schema/data conflict | The previous release is restarted automatically; read the output; if needed restore the `pre-deploy` backup |
| Migration output shows `fail: ... __EFMigrationsHistory` on the first deploy | EF Core probes the history table before creating it | Harmless; the kit checks only the bundle's exit code |
| `install-release.ps1`: "Package hash MISMATCH" | Zip truncated during copy | Copy the zip and `.sha256` again |
| "Management scripts NOT updated" warning | Package built with an older kit than the installed scripts | Build a new package with the current kit (or `-Force` on purpose) |
| ".NET Runtime: Unable to log .NET application events" | Event source not registered / app not binding `Logging:EventLog` | Re-run `setup-server.ps1`; bind `EventLogSettings` as in the sample |
| "running scripts is disabled on this system" | Execution policy | `powershell -ExecutionPolicy Bypass -File <script>` or `Unblock-File` |
| PostgreSQL installation interrupted | Installer failed | `%TEMP%\install-postgresql.log`. If the service is missing but `C:\MyApp\config\postgres-superuser.dpapi` exists: uninstall PostgreSQL, delete its folder and the DPAPI file, re-run setup |

## Security notes

- **Secrets** live only in `C:\<App>\config\app.env` (Administrators + SYSTEM) and in IIS's
  configuration (app pool environment variables; IIS config history is redirected into the
  protected folder). Never commit `app.env`, never paste it into chats, tickets or screenshots.
  The scripts print key names only.
- **Leaked a secret?** Rotate it: change the value in `app.env` (or set it to
  `{{GENERATED_SECRET}}` and run `set-config.ps1 -FillPlaceholders`), run `set-config.ps1`. For the
  database password: `ALTER ROLE <role> PASSWORD '...'` as `postgres`, then update `app.env`.
  Rotating a token signing key signs everybody out.
- **RDP** is the most attacked service on a Windows server. Restrict it to your IP at the provider's
  firewall (or use a VPN/bastion), use a long unique password, keep Windows updated. The kit never
  touches RDP firewall rules and refuses to enable disabled firewall profiles automatically.
- **PostgreSQL** listens on localhost only and its port is explicitly blocked.
- **Downloads** are pinned by SHA-256/SHA-512 and checked for the expected Authenticode publisher;
  a mismatch deletes the file and stops.
- **Headers:** no `Server`/`X-Powered-By`; HSTS without `includeSubDomains` (so other subdomains such
  as mail are not forced to HTTPS); CSP, `X-Frame-Options`, `nosniff`, `Referrer-Policy`.
- **Logs:** IIS access logs omit query strings and referrers; PostgreSQL never logs query
  parameters.

## FAQ

**Why a package instead of copying the publish output to the server?**

| | Copying `publish/` + `dist/` by hand | Versioned package |
|---|---|---|
| Integrity | A truncated or partial copy goes unnoticed | SHA-256 of the zip and of every file is verified before anything changes |
| Reproducibility | "Which build is running?" | `manifest.json`: version, git commit, kit version, API URL baked into the SPA |
| Migrations | Need the .NET SDK or a manual SQL step on the server | Self-contained `efbundle.exe`, run automatically between backup and switch |
| Downtime | Files overwritten under a running app (locked DLLs, mixed versions) | New folder per release, atomic switch of the site path |
| Rollback | Re-copy old files from somewhere | `-Rollback` switches back in seconds; old releases are kept |
| Secrets | Easy to copy `appsettings.Development.json` or a `.env` along | Development settings excluded; secrets never in the package |
| Consistency | API and SPA may come from different builds | One version for both (or `-Component` on purpose) |
| Scripts | Server scripts drift | Scripts travel with the package; version-guarded |

**Why IIS in-process and not Kestrel behind IIS (out-of-process)?** One process, no proxy hop, no
extra port, the real client IP and the `https` scheme arrive directly, so no forwarded headers have
to be trusted. Out-of-process only helps if you need process isolation.

**Why environment variables on the app pool instead of `appsettings.Production.json` or
`web.config`?** Those files live in the release folder and are replaced by every deployment, so
secrets would end up in packages and release folders. The app pool configuration is per server,
survives releases and is readable by administrators only.

**Can I use SQL Server / MySQL instead of PostgreSQL?** Not without changes: setup, backup and
restore are PostgreSQL-specific. The IIS, packaging and secret-handling parts are database-agnostic.

**Can I deploy only the API (no SPA)?** Yes: `"frontend": { "enabled": false }`.

**Does it work with Angular, Vue, Svelte, plain HTML?** Yes - any build that produces static files
with an `index.html`. Adjust `buildCommand`, `outputDir`, `apiBaseUrlEnvVar` and the CSP.

**Can I automate the copy step?** Enable the built-in OpenSSH Server (key-only, port 22 restricted to
your IP) and `scp` the zip + `ssh ... install-release.ps1`. The kit does not assume it.

**Where are the scripts on the server?** `C:\<App>\bin`. Always run them from there after setup.

## Limitations

- Single server: web, API and database on one machine (a single point of failure - keep off-server
  backups and snapshots).
- No CI/CD deployment: packages are built locally and copied over RDP (the included GitHub Actions
  workflow only builds and checks).
- Tested on Windows Server 2025 with PostgreSQL 18 and .NET 10. PostgreSQL 17+ is required.
- One API + one SPA per configuration; one database.
- Database migrations are forward-only (no automatic down-migrations).
- The SPA template assumes hashed build assets under `/assets/` (Vite's default).
- The SPA must get its API URL at build time (one build per environment).

## Development of the kit

```powershell
powershell -NoProfile -File .\tests\DeployKit.Tests.ps1     # kit tests (Turkish culture)
.\scripts\test-config.ps1 -Config .\sample\deploy.config.json
.\scripts\build-package.ps1 -Config .\sample\deploy.config.json
```

- Scripts target **Windows PowerShell 5.1** and are saved as UTF-8 with BOM, CRLF
  (`.gitattributes`). No ternaries, `??` or `&&`.
- Console messages are English. Identifiers are validated with case-sensitive operators.
- `PSScriptAnalyzerSettings.psd1` documents every excluded rule; CI runs the parse check,
  PSScriptAnalyzer, the tests, schema validation, the sample builds and `build-package.ps1`.
- Bump `$script:DeployKitVersion` in `DeployKit.Common.psm1` and `kitVersion` in the example configs
  together, and add a `CHANGELOG.md` entry.

Sample app: `sample/backend` (`dotnet run --project sample/backend/TodoApi`, needs a local
PostgreSQL matching `appsettings.Development.json`) and `sample/frontend` (`npm install`,
`npm run dev`; `/api` is proxied to `http://localhost:5080`).

## License

[MIT](LICENSE)
