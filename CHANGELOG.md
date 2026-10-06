# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/). The kit version lives in
`scripts/DeployKit.Common.psm1` (`$script:DeployKitVersion`); `kitVersion` in
`deploy.config.json` must have the same major version.

## [1.0.0] - 2026-10-07

### Added

- `deploy.config.json` as the single configuration file, with `deploy.config.schema.json`
  (editor validation) and the same rules enforced by the scripts on Windows PowerShell 5.1.
- `build-package.ps1`: one versioned zip (API publish, EF Core migrations bundle, SPA build,
  server scripts, configuration) with `manifest.json` (SHA-256 per file) and a `.sha256` file.
- `setup-server.ps1`: idempotent Windows Server 2025 setup (IIS features, URL Rewrite,
  ASP.NET Core Hosting Bundle, PostgreSQL via the EDB installer, database and role, protected
  `app.env`, app pools, sites, firewall, event log source, win-acme, scheduled tasks). All
  downloads are verified by pinned hash and, where available, Authenticode signature.
- `install-release.ps1`: verified install with pre-deploy backup, `app_offline.htm`, migrations,
  health check and automatic rollback; `-Rollback`, `-Status`, `-VerifyOnly`; HTTP-only mode for
  the SPA until its certificate exists; kit-version guard for the management scripts.
- `set-config.ps1`: `app.env` validation and transfer into the app pool's environment variables
  (`-CheckOnly`, `-FillPlaceholders`).
- `backup.ps1`, `restore-db.ps1` (`-TestOnly`), `startup-check.ps1`, `test-config.ps1`.
- Templates: SPA `web.config` (HTTPS + canonical host redirect, SPA fallback, cache and security
  headers, CSP), API `web.config` patch, `appsettings.Production.json`, `app.env.example`.
- Sample application: .NET 10 minimal API with EF Core + PostgreSQL and a Vite + React +
  TypeScript client.
- Lessons learned from a real production deployment, fixed from day one
  (see `docs/lessons-learned.md`).
