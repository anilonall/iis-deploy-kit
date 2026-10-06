# Configuration reference (`deploy.config.json`)

One file drives the whole kit. It contains **no secrets**: it is packaged and copied to
`<root>\bin\deploy.config.json` on the server. Paths are relative to the folder that contains the
file. Add `"$schema": "<relative path>/deploy.config.schema.json"` for completion and validation
in VS Code / Visual Studio / Rider.

Validate it anywhere (no admin rights, no IIS):

```powershell
.\scripts\test-config.ps1 -Config .\deploy.config.json
```

The same rules run at the start of every script (Windows PowerShell 5.1 has no `Test-Json`, so the
module mirrors the schema and adds cross-field checks).

## Top level

| Key | Required | Description |
|---|---|---|
| `kitVersion` | yes | Kit version the file was written for (`x.y.z`). Its **major** version must match the scripts. |
| `appName` | yes | 2-40 letters/digits/hyphens, starting with a letter. Drives every derived name (below). |
| `domains` | yes | Host names. |
| `server` | no | Server layout and IIS tuning. |
| `database` | yes | PostgreSQL database, role, port and installer. |
| `downloads` | yes | Pinned installers (URL + hash). |
| `api` | yes | API project and runtime settings. |
| `migrations` | yes | EF Core migrations bundle. |
| `frontend` | yes | SPA build. |
| `backup` | no | Retention. |

### Names derived from `appName` (example `MyApp`)

| What | Value | Override |
|---|---|---|
| Server root | `C:\MyApp` | `server.root` |
| IIS sites | `MyApp API`, `MyApp Web` | `server.apiSiteName`, `server.webSiteName` |
| App pools | `MyAppApi`, `MyAppWeb` | `server.apiPoolName`, `server.webPoolName` |
| Event log source | `MyApp API` | `server.eventLogSource` |
| Scheduled tasks | `\MyApp\MyApp Daily Backup`, `\MyApp\MyApp Startup Check` | - |
| Firewall rules | `MyApp-HTTP-In`, `MyApp-HTTPS-In`, `MyApp-PostgreSQL-Block` | - |
| Package | `myapp-<yyyyMMdd-HHmmss>-<commit>.zip` | - |

### Server folders (`<root>` = `C:\MyApp`)

| Folder | Content | Access |
|---|---|---|
| `bin` | Management scripts, `deploy.config.json`, `kit-version.txt` | Administrators |
| `config` | `app.env`, DPAPI-protected PostgreSQL superuser password, IIS config history | Administrators + SYSTEM only |
| `config\api-readable` | Credential files the API must read (service-account JSON, ...) | API pool: read |
| `api\releases\<timestamp>` | API releases (IIS site path points to one) | API pool: read |
| `web\releases\<timestamp>` | SPA releases | Web pool: read |
| `storage` | Persistent app files (uploads), survives releases, archived weekly | API pool: modify |
| `backups` | `pg_dump` files and storage archives | Administrators |
| `logs\iis`, `logs\deploy`, `logs\setup`, `logs\backup`, `logs\stdout` | Logs | API pool: modify `stdout` only |
| `packages` | Uploaded packages (newest `keepReleases` kept) | Administrators |
| `tools\win-acme`, `tools\downloads` | win-acme, verified installers | Administrators |

## `domains`

| Key | Required | Description |
|---|---|---|
| `web` | yes | Canonical web host (`example.com`). The SPA `web.config` redirects every other host to it. |
| `webAliases` | no | Extra hosts bound to the web site and redirected (301) to `web`, e.g. `www.example.com`. |
| `api` | yes | API host (`api.example.com`). The SPA is built with `https://<api>` as API base URL. |

Host names are lower case, without scheme, port or path.

## `server`

| Key | Default | Description |
|---|---|---|
| `root` | `C:\<appName>` | Server root folder. |
| `apiSiteName`, `webSiteName`, `apiPoolName`, `webPoolName`, `eventLogSource` | derived | See above. |
| `keepReleases` | `5` | Releases kept per component (active + previous always kept) and packages kept in `packages`. |
| `maxRequestBodyMb` | `20` | API request size limit in IIS (`requestLimits/maxAllowedContentLength`). Larger requests get 404.13. |
| `backupTime` | `04:00` | Daily backup time, server local time. |
| `alwaysRunning` | `true` | API pool tuned for background workers (AlwaysRunning, idle timeout 0, no periodic recycle, no overlapping recycle, preload). Set `false` for a request-only API that may idle. |

## `database`

| Key | Default | Description |
|---|---|---|
| `name` | - | Database name (lower-case identifier). |
| `role` | - | Login role that owns the database (`NOSUPERUSER NOCREATEDB NOCREATEROLE`). |
| `port` | `5432` | PostgreSQL port (listens on localhost only; blocked in the firewall). |
| `postgres.majorVersion` | - | `17` or later (the database uses the builtin `C.UTF-8` locale provider). |
| `postgres.installerVersion` | - | EDB Windows installer version, e.g. `18.6-2`. |
| `postgres.installerUrl` | EDB URL | `https://get.enterprisedb.com/postgresql/postgresql-<installerVersion>-windows-x64.exe` |
| `postgres.installerSha256` | - | Strongly recommended. Without it only the Authenticode signature is checked (with a warning). |
| `postgres.signer` | `EnterpriseDB Corporation` | Expected `O=` of the signing certificate. |

## `downloads`

Every installer is downloaded once into `<root>\tools\downloads`, then verified. A mismatch
deletes the file and stops the script.

| Key | Description |
|---|---|
| `hostingBundle.version` | ASP.NET Core Hosting Bundle version (e.g. `10.0.12`). Raising it and re-running `setup-server.ps1` updates .NET. |
| `hostingBundle.url` + `sha512` | Pinned URL and SHA-512. Omit **both** to read them from Microsoft's official `releases.json` for that version. |
| `hostingBundle.signer` | Default `Microsoft Corporation`. |
| `urlRewrite.url` + `sha256` (+ `signer`) | IIS URL Rewrite 2.1 MSI. |
| `winAcme.version` + `url` + `sha256` | win-acme x64 zip from GitHub releases (not Authenticode-signed: the hash is the check). |

How to pin a new version:

```powershell
Invoke-WebRequest <url> -OutFile installer.exe -UseBasicParsing
Get-FileHash installer.exe -Algorithm SHA256        # or SHA512 for the Hosting Bundle
Get-AuthenticodeSignature installer.exe | Format-List Status, SignerCertificate
```

Compare with the vendor's published hash where available (Microsoft publishes SHA-512 in
`releases.json`; win-acme publishes hashes on its release page).

## `api`

| Key | Default | Description |
|---|---|---|
| `project` | - | API `.csproj`. |
| `assemblyName` | project file name | Main assembly name (without `.dll`); checked in the publish output and the package. |
| `runtimeIdentifier` | `win-x64` | `win-x64` or `win-arm64`. Framework-dependent publish. |
| `healthPath` | `/api/health` | Anonymous endpoint returning 200 when the API (and its database) is healthy. Used after every deploy, rollback, config change and boot. |
| `connectionStringKey` | `ConnectionStrings__Default` | The `app.env` key with the Npgsql connection string (used by backups, restores and the migration step). Always required. |
| `requiredEnvKeys` | `[]` | Keys that must be present and non-empty in `app.env`. |
| `minLengthEnvKeys` | `{}` | Minimum lengths, e.g. `{ "Jwt__SigningKey": 32 }`. |
| `envTemplate` | kit template | Your own `app.env` template (recommended once your app has more settings). |
| `excludeFromPackage` | `["appsettings.Development.json"]` | Files/folders removed from the publish output. |

## `migrations`

| Key | Default | Description |
|---|---|---|
| `enabled` | - | Build `efbundle.exe` and run it during `install-release.ps1`. |
| `project` | `api.project` | Project with the migrations. |
| `startupProject` | `api.project` | Startup project for design-time services. |
| `context` | - | `DbContext` class name (required when enabled). |
| `connectionEnvVar` | - | Extra environment variable that receives the connection string while the bundle runs (for an `IDesignTimeDbContextFactory` that reads its own variable). |

How the bundle gets its configuration: **every** `app.env` value is set as an environment variable
of the PowerShell process (plus `ASPNETCORE_ENVIRONMENT=Production` and
`DOTNET_ENVIRONMENT=Production`), the working directory is the new release folder (its
`appsettings*.json` are visible), the bundle runs, and the previous environment is restored. The
connection string never appears on a command line.

If a local tool manifest (`.config/dotnet-tools.json`) is found above the startup project,
`build-package.ps1` runs `dotnet tool restore` first, so the pinned `dotnet-ef` version is used.

## `frontend`

| Key | Default | Description |
|---|---|---|
| `enabled` | - | Build and package the SPA. `false` = API-only packages. |
| `path` | - | Frontend folder (with `package.json`). May be outside the repo, e.g. `../my-frontend`. |
| `installCommand` | `npm ci --no-audit --no-fund` | Run through `cmd.exe` in `path`. Empty string = never install. `-SkipFrontendInstall` skips it once. |
| `buildCommand` | `npm run build` | Run through `cmd.exe` in `path`. |
| `outputDir` | `dist` | Build output relative to `path`. |
| `apiBaseUrlEnvVar` | `VITE_API_BASE_URL` | Receives `https://<domains.api>` during the build (`REACT_APP_...`, `NEXT_PUBLIC_...` work the same way). |
| `verifyApiUrlInBundle` | `true` | Fail when the API URL is not found in the built JavaScript. |
| `spaCheckPath` | `/deploy-kit-spa-check` | A client-side route that is not a file. After install it must return the new `index.html` (proves the SPA fallback works). |

`web.config` for the SPA: taken from the build output when present (put a copy of
`templates/spa/web.config` in Vite's `public/`), otherwise the template is used. Placeholders
`__WEB_HOST__`, `__WEB_HOST_REGEX__`, `__API_ORIGIN__` are filled; the CSP `connect-src` must contain
the API origin or the build fails. The template expects hashed assets under `/assets/` (Vite's
default) for the one-year immutable cache rule.

## `backup`

| Key | Default |
|---|---|
| `dailyRetentionDays` | 14 |
| `preDeployRetentionDays` | 30 |
| `manualRetentionDays` | 30 |
| `storageRetentionDays` | 28 |
| `iisLogRetentionDays` | 90 |
| `scriptLogRetentionDays` | 60 |
| `storageArchiveDay` | `Sunday` (`Never` disables the storage archive) |

## `app.env` tokens

`setup-server.ps1` creates `<root>\config\app.env` from the template once and fills these tokens
**on `KEY=VALUE` lines only** (never inside comments):

| Token | Value |
|---|---|
| `{{DB_NAME}}`, `{{DB_USER}}`, `{{DB_PORT}}` | `database.*` |
| `{{API_HOST}}`, `{{WEB_HOST}}` | `domains.api`, `domains.web` |
| `{{API_ORIGIN}}`, `{{WEB_ORIGIN}}` | `https://<api>`, `https://<web>` |
| `{{WEB_ALIAS_ORIGIN_0}}`, `_1`, ... | `https://<webAliases[n]>` |
| `{{STORAGE_DIR}}`, `{{API_READABLE_DIR}}` | `<root>\storage`, `<root>\config\api-readable` |
| `{{APP_NAME}}` | `appName` |
| `{{GENERATED_DB_PASSWORD}}` | the generated password of the database role |
| `{{GENERATED_SECRET}}` | a new random 64-character secret per occurrence |

Anything still containing `<...>` or `{{...}}` on an active line blocks `set-config.ps1`.
`set-config.ps1 -FillPlaceholders` fills tokens on lines you enabled later.
