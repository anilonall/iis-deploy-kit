# iis-deploy-kit

**ASP.NET Core (.NET 10) API + tek sayfalık uygulama (React/Vite veya herhangi bir statik derleme)
+ EF Core + PostgreSQL** yığınını tek bir **Windows Server 2025 + IIS** sunucusuna, doğrulanmış ve
sürümlü **tek bir zip** olarak yayınlamak için hazır şablon. CI sunucusu, SSH veya WinRM gerekmez:
bilgisayarınızda derleyin, RDP ile kopyalayın, tek betik çalıştırın.

[English README](README.md)

Kit, gerçek bir canlı (production) kurulumdan çıkarılıp genelleştirildi. Gerçek sunucuda karşılaşılan
her sorun ilk günden düzeltilmiş olarak gelir: [docs/lessons-learned.md](docs/lessons-learned.md)
(İngilizce).

- **Tek ayar dosyası** (`deploy.config.json`, JSON şemasıyla): betiklerde sabit ad, alan adı veya
  yol yoktur.
- **Her sürüm için tek paket**: API publish + EF Core migration bundle + SPA derlemesi + sunucu
  betikleri; her dosyanın SHA-256 özetini içeren `manifest.json` ve zip için `.sha256`.
- **Tekrar çalıştırılabilir (idempotent) sunucu kurulumu**: IIS, URL Rewrite, ASP.NET Core Hosting
  Bundle, PostgreSQL, veritabanı ve rol, uygulama havuzları ve siteler, güvenlik duvarı, olay
  günlüğü, win-acme, yedekler. Her indirme sabitlenmiş özetle (hash) ve yayıncı imzalıyorsa
  Authenticode imzasıyla doğrulanır.
- **Güvenli kurulum**: dağıtım öncesi yedek, `app_offline.htm`, migration, sağlık kontrolü, otomatik
  geri dönüş; tek komutla geri alma ve durum.
- **Sırlar sunucudan çıkmaz**: korumalı tek bir `app.env` → IIS uygulama havuzu ortam değişkenleri.
  Pakette, site klasöründe veya `web.config`'te sır yoktur ve hiçbir değer ekrana yazılmaz.

## İçindekiler

- [Mimari](#mimari)
- [Ön koşullar](#ön-koşullar)
- [Depo yapısı](#depo-yapısı)
- [Hızlı başlangıç](#hızlı-başlangıç)
- [Güncelleme](#güncelleme)
- [Geri alma](#geri-alma)
- [Durum ve günlükler](#durum-ve-günlükler)
- [Yedekleme ve geri yükleme](#yedekleme-ve-geri-yükleme)
- [Ayarlar ve sırlar](#ayarlar-ve-sırlar)
- [Sorun giderme](#sorun-giderme)
- [Güvenlik notları](#güvenlik-notları)
- [SSS](#sss)
- [Sınırlamalar](#sınırlamalar)

## Mimari

```
                       DNS (sağlayıcınız)
                       ├── example.com      A → sunucu IP
                       ├── www.example.com  A → sunucu IP   (takma ad, 301 → example.com)
                       └── api.example.com  A → sunucu IP

 Tarayıcı ──HTTPS──► Windows Server 2025 · IIS 10 :443 (Let's Encrypt / win-acme, SNI, 2 sertifika)
                     │
                     ├── site "<App> Web"  example.com, www.example.com
                     │     C:\<App>\web\releases\<zaman>        statik SPA + web.config
                     │     URL Rewrite: http → https, www → kök, SPA geri dönüşü, önbellek + güvenlik başlıkları
                     │
                     └── site "<App> API"  api.example.com
                           ASP.NET Core Module V2, IN-PROCESS (.NET 10, w3wp.exe içinde)
                           C:\<App>\api\releases\<zaman>
                           havuz: AlwaysRunning, boşta kapanma yok, periyodik geri dönüşüm yok
                           ayarlar: havuz ortam değişkenleri ← C:\<App>\config\app.env
                               │
                               └──► PostgreSQL (Windows servisi, yalnızca localhost, port kapalı)

 HTTP :80 → web: https'e 301 (URL Rewrite) · api: uygulama yönlendirir (UseHttpsRedirection)
 RDP: yalnızca yönetim. Dağıtım = RDP ile kopyalanan tek zip + install-release.ps1.
```

```
 Bilgisayarınız                                  Sunucu (RDP, yönetici PowerShell)
 ──────────────                                  ─────────────────────────────────
 build-package.ps1 -Config deploy.config.json
   ├─ dotnet publish (Release, win-x64)
   ├─ dotnet ef migrations bundle → efbundle.exe
   ├─ npm ci && npm run build (VITE_API_BASE_URL)
   └─ myapp-<sürüm>.zip + .sha256 ──── kopyala ──►  C:\<App>\packages\
                                                     install-release.ps1 -Package ...
                                                       doğrula → yedek → app_offline → migration
                                                       → sürüm değişimi → sağlık kontrolü
                                                       (başarısız mı? → önceki sürüme dönülür)
```

## Ön koşullar

**Bilgisayarınız (Windows 10/11):** .NET 10 SDK, Node.js 20.19+ (Vite 8 için), Git, Windows
PowerShell 5.1 (yerleşik). `dotnet-ef` araç bildiriminiz (tool manifest) varsa oradan geri yüklenir;
yoksa bir kez: `dotnet tool install --global dotnet-ef`.

**Sunucu:** Windows Server 2025 (denendi; 2022 muhtemelen çalışır ama denenmedi), RDP ile yönetici
erişimi, dışarıya internet erişimi (resmi indirme adresleri, Let's Encrypt), içeriye **80 ve 443**
açık (sağlayıcının güvenlik duvarında da). Öneri: 2+ vCPU, 4+ GB RAM, 60+ GB disk.

**Uygulamanız:**

- ayarlarını ortam değişkenlerinden okumalı (ASP.NET Core varsayılanı; `ConnectionStrings__Default`
  → `ConnectionStrings:Default`),
- anonim bir sağlık ucu sunmalı (varsayılan `/api/health`; yalnızca veritabanına ulaşılabiliyorsa 200),
- açılışta migration **çalıştırmamalı** (kit EF Core bundle'ı dağıtımın açık bir adımı olarak çalıştırır),
- Windows'ta `Logging:EventLog` bölümünü bağlamalı (örnek: `sample/backend/TodoApi/Program.cs`).

## Depo yapısı

```
iis-deploy-kit/
├── deploy.config.schema.json        ayar dosyasının JSON şeması
├── deploy.config.example.json       tipik bir uygulama için örnek
├── scripts/
│   ├── DeployKit.Common.psm1        ortak yardımcılar (ayar, env dosyası, IIS, PostgreSQL, indirme)
│   ├── build-package.ps1            BİLGİSAYARINIZ: sürüm zip'ini üretir
│   ├── test-config.ps1              BİLGİSAYARINIZ: deploy.config.json'u doğrular, türetilen adları yazar
│   ├── setup-server.ps1             SUNUCU: ilk kurulum (tekrar çalıştırılabilir)
│   ├── install-release.ps1          SUNUCU: kurulum / geri alma / durum / doğrulama
│   ├── set-config.ps1               SUNUCU: app.env → havuz ortam değişkenleri
│   ├── backup.ps1                   SUNUCU: pg_dump + dosya deposu arşivi + saklama
│   ├── restore-db.ps1               SUNUCU: yedekten geri yükleme / deneme geri yükleme
│   └── startup-check.ps1            SUNUCU: açılış sonrası sağlık kontrolü (zamanlanmış görev)
├── templates/                       app.env şablonu, SPA ve API web.config, appsettings.Production.json
├── sample/                          küçük çalışan örnek (.NET 10 API + Vite/React/TS)
├── tests/DeployKit.Tests.ps1        bağımlılıksız testler (tr-TR kültüründe çalışır)
└── docs/                            ayar başvurusu, çıkarılan dersler (İngilizce)
```

Kendi projenizde: `scripts/` ve `templates/` klasörlerini deponuza kopyalayın (ör. `deploy/iis/`),
yanına `deploy.config.example.json`'dan bir `deploy.config.json` oluşturun, `templates/spa/web.config`
dosyasını frontend'inizin `public/` klasörüne koyun. `deploy.config.json` içindeki yollar dosyanın
kendi klasörüne göredir. Tüm anahtarlar: [docs/configuration.md](docs/configuration.md).

## Hızlı başlangıç

`sample/` örneği `example.com` kullanır; gerçek dağıtımdan önce kendi alan adınızla değiştirin.

### 1. Ayar ve doğrulama (bilgisayarınız)

```powershell
copy deploy.config.example.json deploy.config.json      # appName, domains, yolları düzenleyin
.\scripts\test-config.ps1 -Config .\deploy.config.json
```

### 2. Paketi üretme (bilgisayarınız)

```powershell
# PowerShell betikleri engellerse bir kez:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\scripts\build-package.ps1 -Config .\deploy.config.json
# → artifacts\myapp-20260101-120000-abc1234.zip  +  .zip.sha256
```

Örnekle denemek için: `.\scripts\build-package.ps1 -Config .\sample\deploy.config.json`.

### 3. Sunucuya kopyalama (RDP)

Uzak Masaüstü (`mstsc`) → **Yerel Kaynaklar → Sürücüler** açık olsun; zip'i **ve** `.sha256`
dosyasını ör. `C:\Deploy\` klasörüne kopyalayıp orada açın (sağ tık → Tümünü Ayıkla).

### 4. Sunucu kurulumu (bir kez; tekrar çalıştırmak güvenli)

Sunucuda yönetici PowerShell:

```powershell
cd C:\Deploy\myapp-20260101-120000-abc1234\scripts
powershell -ExecutionPolicy Bypass -File .\setup-server.ps1
```

5-15 dakika sürer; sonunda sunucunuza özel DNS kayıtlarını ve win-acme komutlarını yazdırır. IIS
kurulumundan sonra Windows yeniden başlatma isterse yeniden başlatıp betiği tekrar çalıştırın.

### 5. DNS

DNS sağlayıcınızda API adı, web adı ve her takma ad için sunucunun genel IP'sini gösteren `A`
kayıtları oluşturun. Var olan bir siteyi taşıyorsanız bir gün önce TTL'i düşürün (ör. 300 sn).
**MX/SPF/DKIM/DMARC/autodiscover kayıtlarına dokunmayın** - `A` kaydını değiştirmek e-postayı
etkilemez. Yayılmayı kontrol:

```powershell
Resolve-DnsName api.example.com -Server 8.8.8.8 -Type A
```

### 6. Sertifikalar (win-acme)

Adlar sunucuyu gösterdiğinde ve 80 portu internetten erişilebilir olduğunda:

```powershell
cd C:\MyApp\tools\win-acme
.\wacs.exe --source iis --siteid <API-SITE-ID> --installation iis --validation selfhosting --emailaddress siz@example.com --accepttos
Restart-WebAppPool MyAppApi            # uygulama HTTPS portunu öğrenir (http → https yönlendirmesi)
.\wacs.exe --source iis --siteid <WEB-SITE-ID> --installation iis --validation selfhosting --emailaddress siz@example.com --accepttos
.\wacs.exe --setuptaskscheduler        # yenileme görevi (yoksa)
```

`--installation iis` **zorunludur**: olmadan sertifika yalnızca depoya konur, HTTPS bağlaması
oluşmaz ve yenilemeler IIS'i güncellemez. Site numaraları: `Get-Website | Select-Object Name, Id`.

### 7. Ayarları gözden geçirme

```powershell
notepad C:\MyApp\config\app.env      # veritabanı parolası ve üretilen sırlar zaten dolu
C:\MyApp\bin\set-config.ps1
```

### 8. Sürümü kurma

```powershell
copy C:\Deploy\myapp-*.zip* C:\MyApp\packages\
C:\MyApp\bin\install-release.ps1 -Package C:\MyApp\packages\myapp-20260101-120000-abc1234.zip
```

Web sertifikası henüz yoksa SPA **"yalnızca HTTP" kipinde** kurulur (https yönlendirmesi/HSTS yok).
Web sitesi için 6. adımdan sonra **aynı** paketi `-Component Web` ile yeniden kurun.

`https://api.example.com/api/health` ve `https://example.com` adreslerini açın.

## Güncelleme

```powershell
# bilgisayarınız
.\scripts\build-package.ps1 -Config .\deploy.config.json             # veya -Component Api / Web
# sunucu (zip + .sha256 C:\MyApp\packages'a kopyalandıktan sonra)
C:\MyApp\bin\install-release.ps1 -Package C:\MyApp\packages\myapp-<sürüm>.zip
C:\MyApp\bin\install-release.ps1 -Package C:\MyApp\packages\myapp-<sürüm>.zip -VerifyOnly   # yalnızca doğrula
```

API için akış: özetleri doğrula → `app.env`'i doğrula → sürümü kopyala → `pg_dump` yedeği →
`app_offline.htm` (düzgün kapanma) → havuzu durdur → `app.env`'i uygula → migration bundle → site
yolunu değiştir → başlat → sağlık kontrolü → başarısızsa önceki sürüme otomatik dönüş. Web kısmı
site yolunu değiştirir (kesintisiz) ve `/` ile bir istemci rotasının yeni `index.html`'i döndürdüğünü
doğrular.

Paket yönetim betiklerini de taşır; `C:\MyApp\bin`'e kopyalanırlar ama **daha yeni bir kit
sürümünün üzerine asla eski sürüm yazılmaz** (`-Force` yalnızca bilerek). Her zaman en yeni paketi
kurun. .NET güncellemesi: `downloads.hostingBundle.version`'ı yükseltin, paket üretin ve paketteki
`setup-server.ps1`'i yeniden çalıştırın.

## Geri alma

```powershell
C:\MyApp\bin\install-release.ps1 -Rollback                 # API ve web
C:\MyApp\bin\install-release.ps1 -Rollback -Component Api  # yalnızca API
```

Geri alma uygulama dosyalarını saniyeler içinde önceki sürüme döndürür. **Migration'lar geri
alınmaz.** Migration'ları ekleyici (expand/contract) tutun ki önceki sürüm yeni şemayla çalışsın;
çalışmıyorsa dağıtım öncesi yedekten dönün ([aşağıda](#yedekleme-ve-geri-yükleme)).

## Durum ve günlükler

```powershell
C:\MyApp\bin\install-release.ps1 -Status    # etkin/önceki sürüm, havuzlar, HTTPS, sağlık, geçmiş
```

| Ne | Nerede |
|---|---|
| Uygulama uyarı/hataları, açılış/kapanış | Olay Görüntüleyicisi → Windows Günlükleri → Uygulama, kaynak **`<App> API`** |
| Açılış hataları (500.30 vb.) | Aynı yer, kaynak **IIS AspNetCore Module V2** |
| Havuz durması / geri dönüşüm | Windows Günlükleri → Sistem, kaynak **WAS** |
| IIS erişim günlükleri (sorgu dizesi yok) | `C:\MyApp\logs\iis\W3SVC<id>\` |
| Dağıtım / kurulum / yedek günlükleri, geçmiş | `C:\MyApp\logs\deploy` (`history.log`), `logs\setup`, `logs\backup`, `logs\startup-check.log` |

**ANCM stdout günlüğü** (yalnızca olay günlüğü açılış hatasını açıklamıyorsa, geçici): etkin
sürümün `web.config`'inde `stdoutLogEnabled="true"` → hatayı tekrarlayın → `C:\MyApp\logs\stdout\api_*.log`
→ `false` yapıp dosyaları silin (bu günlük döndürülmez, diski doldurur).

## Yedekleme ve geri yükleme

- **Otomatik:** her gece (`<db>-daily-*.dump`, 14 gün), her API dağıtımından önce
  (`<db>-pre-deploy-*`, 30 gün), haftalık dosya deposu arşivi (`storage-*.zip`, 28 gün). Görev
  Zamanlayıcı → `<App>` → `<App> Daily Backup` (son sonuç `0x0` olmalı).
- **Elle:** `C:\MyApp\bin\backup.ps1 -Label manual`
- **Sunucu dışına kopyalamak sizin işiniz.** Sunucudaki yedek sunucunun kaybına karşı korumaz.
  `C:\MyApp\backups`'ı düzenli olarak (şifreli; kişisel veri içerir) dışarı kopyalayın ve
  sağlayıcınızın anlık görüntü (snapshot) hizmetini açın.

Geri yükleme - **önce deneyin** (canlıya dokunmaz):

```powershell
C:\MyApp\bin\restore-db.ps1 -BackupFile C:\MyApp\backups\<dosya>.dump -TestOnly
```

Gerçek geri yükleme (önce mevcut durum yedeklenir, API durur, `pg_restore --clean --if-exists
--single-transaction`, API başlar; `YES` yazmanız istenir):

```powershell
C:\MyApp\bin\restore-db.ps1 -BackupFile C:\MyApp\backups\<dosya>.dump
```

Dosya deposu:

```powershell
Stop-WebAppPool MyAppApi
Rename-Item C:\MyApp\storage storage-old-$(Get-Date -Format yyyyMMdd)
Expand-Archive C:\MyApp\backups\storage-<zaman>.zip -DestinationPath C:\MyApp
icacls C:\MyApp\storage /grant "IIS AppPool\MyAppApi:(OI)(CI)M"
Start-WebAppPool MyAppApi
```

## Ayarlar ve sırlar

- **`deploy.config.json`** (deponuzda, pakete girer, sır yok): adlar, alan adları, sürümler, yollar.
- **`C:\MyApp\config\app.env`** (yalnızca sunucuda; Administrators + SYSTEM): `ANAHTAR=DEĞER`
  satırları. `setup-server.ps1` şablondan bir kez üretir; veritabanı parolası ve her
  `{{GENERATED_SECRET}}` rastgeledir. Yer tutucular **yalnızca değer satırlarında** doldurulur,
  yorum satırlarına dokunulmaz. Düzenledikten sonra `set-config.ps1`: dosyayı doğrular (biçim,
  doldurulmamış `<...>`/`{{...}}`, zorunlu anahtarlar, en kısa uzunluk) ve ancak o zaman API
  havuzunun ortam değişkenlerini değiştirip havuzu yeniden başlatır.
- Kendi şablonunuzu [templates/app.env.example](templates/app.env.example)'dan başlatıp
  `api.envTemplate` ile gösterin.

## Sorun giderme

| Belirti | Olası neden | Çözüm |
|---|---|---|
| **HTTP 500.19** (Config Error, `0x8007000d`) | IIS `web.config`'teki bir bölümü tanımıyor: URL Rewrite yok (web), ASP.NET Core Module yok (API) veya yinelenen MIME/başlık | `setup-server.ps1`'i yeniden çalıştırın. `Test-Path C:\Windows\System32\inetsrv\rewrite.dll`, `Test-Path "C:\Program Files\IIS\Asp.Net Core Module\V2\aspnetcorev2.dll"`. Hata sayfasındaki "Config Source" sorunlu satırı gösterir |
| **HTTP 500.30** (uygulama açılmadı) | Açılışta hata: eksik/yanlış ayar, veritabanı kapalı, parola yanlış | Olay Görüntüleyicisi (IIS AspNetCore Module V2 + `<App> API`), `set-config.ps1 -CheckOnly`, `Get-Service postgresql-x64-*`, geçici stdout günlüğü |
| **HTTP 500.31 / 500.32** | ASP.NET Core runtime yok veya 32 bit havuz | `setup-server.ps1`; "32 bit uygulamaları etkinleştir" False olmalı |
| **HTTP 502.5** | Yalnızca out-of-process'te olur: `hostingModel` elle değiştirilmiş | Kit hep `inprocess` paketler; son paketi yeniden kurun |
| **HTTP 503** | Havuz durmuş (art arda çökme → Rapid-Fail Protection) veya dağıtım sürüyor | `Get-WebAppPoolState MyAppApi`; neden Sistem günlüğünde (WAS). Düzeltip `startup-check.ps1` veya `Start-WebAppPool` |
| Yeni kurulumdan hemen sonra 500.19/500.21 | Hosting Bundle IIS'ten **önce** kurulmuş | `setup-server.ps1` bunu algılayıp `/repair` yapar; elle: Hosting Bundle'ı onar + `net stop was /y; net start w3svc` |
| `set-config.ps1`: **DISP_E_TYPEMISMATCH** | Aynı oturumda WebAdministration modülüyle birlikte `Microsoft.Web.Administration.dll` kullanan özel kod | Kitin `Set-DeployKitAppPoolEnvironment` fonksiyonunu (WebAdministration cmdlet'leri) kullanın; yeni PowerShell penceresi açın |
| Sertifika alındı ama **https bağlaması yok** / yenileme IIS'i güncellemiyor | win-acme `--installation iis` olmadan çalıştırılmış | `--source iis --siteid <id> --installation iis` ile yeniden çalıştırın |
| win-acme: `Authorization failed`, `Connection refused` | DNS yayılmadı veya sağlayıcıda 80 kapalı | `Resolve-DnsName <ad> -Server 8.8.8.8`; dışarıdan `Test-NetConnection <ip> -Port 80`; sağlayıcıdan 80/443'ü açmasını isteyin |
| Site hâlâ eski sunucuyu/içeriği gösteriyor | DNS önbelleği, uzun TTL, eski `AAAA` kaydı | TTL kadar bekleyin, `ipconfig /flushdns`, eski `AAAA` kayıtlarını silin |
| Web'de sertifika uyarısı / `http` yönlendirmiyor | Web sertifikası yok veya web hâlâ "yalnızca HTTP" kipinde | Web için 6. adım, sonra aynı paketi `-Component Web` ile yeniden kurun |
| Tarayıcı konsolunda **CORS** hatası | Web origin'i API'nin izinli listesinde yok (`www`/kök farkı, sonda `/`) | Tam adresi (`https://example.com`, sonda `/` yok) `app.env`'e ekleyin, `set-config.ps1` |
| Tarayıcı API çağrılarını **CSP** hatasıyla engelliyor | `connect-src` API adresini içermiyor | SPA `web.config`'inde `__API_ORIGIN__` kullanın (eksikse derleme durur) |
| Yenileyince oturum düşüyor / **cookie** gitmiyor | Cookie `Secure`/`SameSite` uyumsuz, API HTTPS değil, web "yalnızca HTTP" kipinde | Web ve API ikisi de HTTPS olmalı; kardeş alt alan adları (`example.com` + `api.example.com`) *aynı site*dir, `SameSite=Lax` + `credentials: 'include'` çalışır |
| İstemci rotası yenilenince 404 | URL Rewrite yok veya sürümde `web.config` yok | `Test-Path C:\Windows\System32\inetsrv\rewrite.dll`; `install-release.ps1 -Status` |
| Yüklemede **404.13** | İstek `server.maxRequestBodyMb`'den büyük | `deploy.config.json`'da artırın, yeniden paketleyip kurun |
| Yüklemede "Access to the path is denied" | Havuz kimliğinin `storage` izni yok (klasör taşındı/geri yüklendi) | `icacls C:\MyApp\storage /grant "IIS AppPool\MyAppApi:(OI)(CI)M"` veya `setup-server.ps1` |
| Migration adımı başarısız | Şema/veri çakışması | Önceki sürüm otomatik yeniden başlar; çıktıyı inceleyin, gerekirse `pre-deploy` yedeğinden dönün |
| İlk dağıtımda migration çıktısında `fail: ... __EFMigrationsHistory` | EF Core geçmiş tablosunu oluşturmadan önce yoklar | Zararsız; kit yalnızca bundle'ın çıkış koduna bakar |
| "Package hash MISMATCH" | Zip kopyalamada bozulmuş | Zip ve `.sha256`'yı yeniden kopyalayın |
| "Management scripts NOT updated" uyarısı | Paket, kurulu betiklerden eski bir kitle üretilmiş | Güncel kitle yeni paket üretin (veya bilerek `-Force`) |
| "running scripts is disabled on this system" | Yürütme ilkesi | `powershell -ExecutionPolicy Bypass -File <betik>` veya `Unblock-File` |
| PostgreSQL kurulumu yarıda kaldı | Kurucu hata verdi | `%TEMP%\install-postgresql.log`. Servis yok ama `C:\MyApp\config\postgres-superuser.dpapi` varsa: PostgreSQL'i kaldırın, klasörünü ve DPAPI dosyasını silin, kurulumu yeniden çalıştırın |

## Güvenlik notları

- **Sırlar** yalnızca `C:\<App>\config\app.env`'de (Administrators + SYSTEM) ve IIS
  yapılandırmasında (havuz ortam değişkenleri; IIS yapılandırma geçmişi korumalı klasöre
  yönlendirilir) durur. `app.env`'i asla commit etmeyin; sohbete, kayıt sistemine veya ekran
  görüntüsüne koymayın. Betikler yalnızca anahtar adlarını yazar.
- **Bir sır sızdıysa** değiştirin: `app.env`'deki değeri değiştirin (veya `{{GENERATED_SECRET}}`
  yazıp `set-config.ps1 -FillPlaceholders`), `set-config.ps1` çalıştırın. Veritabanı parolası için
  `postgres` ile `ALTER ROLE <rol> PASSWORD '...'`, sonra `app.env`. İmza anahtarını değiştirmek
  herkesin oturumunu kapatır.
- **RDP**, Windows sunucularında en çok saldırılan servistir. Sağlayıcının güvenlik duvarında kendi
  IP'nizle sınırlayın (veya VPN), uzun ve benzersiz parola kullanın, Windows'u güncel tutun. Kit RDP
  kurallarına dokunmaz ve kapalı güvenlik duvarı profillerini kendiliğinden açmaz.
- **PostgreSQL** yalnızca localhost'u dinler; portu ayrıca engellenir.
- **İndirmeler** SHA-256/SHA-512 ile sabitlenir ve beklenen Authenticode yayıncısı denetlenir;
  uyuşmazlıkta dosya silinir ve betik durur.
- **Başlıklar:** `Server`/`X-Powered-By` yok; HSTS `includeSubDomains` olmadan (e-posta gibi diğer alt
  alan adları HTTPS'e zorlanmaz); CSP, `X-Frame-Options`, `nosniff`, `Referrer-Policy`.

## SSS

**Yayın çıktısını sunucuya elle kopyalamak yerine neden paket?**

| | `publish/` + `dist/` elle kopyalama | Sürümlü paket |
|---|---|---|
| Bütünlük | Yarım/bozuk kopya fark edilmez | Hiçbir şey değişmeden önce zip'in ve her dosyanın SHA-256'sı doğrulanır |
| İzlenebilirlik | "Hangi derleme çalışıyor?" | `manifest.json`: sürüm, git commit, kit sürümü, SPA'ya gömülen API adresi |
| Migration | Sunucuda .NET SDK veya elle SQL gerekir | Kendi kendine yeten `efbundle.exe`, yedek ile geçiş arasında otomatik |
| Kesinti | Çalışan uygulamanın altında dosya ezilir (kilitli DLL, karışık sürüm) | Her sürüm yeni klasör, site yolu tek adımda değişir |
| Geri alma | Eski dosyaları bir yerden bulup kopyalamak | `-Rollback` saniyeler içinde döner; eski sürümler saklanır |
| Sırlar | `appsettings.Development.json` veya `.env` kolayca kopyalanır | Geliştirme ayarları çıkarılır; pakette sır olmaz |
| Tutarlılık | API ve SPA farklı derlemelerden gelebilir | İkisi için tek sürüm (veya bilerek `-Component`) |
| Betikler | Sunucudaki betikler zamanla farklılaşır | Betikler paketle gelir; sürüm korumalı |

**Neden IIS in-process, IIS arkasında Kestrel (out-of-process) değil?** Tek süreç, vekil atlaması
yok, ek port yok; gerçek istemci IP'si ve `https` şeması doğrudan gelir, forwarded header'a güvenmek
gerekmez.

**Neden `appsettings.Production.json` veya `web.config` yerine havuz ortam değişkenleri?** O dosyalar
sürüm klasöründe durur ve her dağıtımda değişir; sırlar paketlere ve sürüm klasörlerine düşerdi.
Havuz yapılandırması sunucuya özeldir, sürümlerden etkilenmez ve yalnızca yöneticilerce okunur.

**PostgreSQL yerine SQL Server / MySQL?** Değişiklik gerekir: kurulum, yedek ve geri yükleme
PostgreSQL'e özeldir. IIS, paketleme ve sır yönetimi kısımları veritabanından bağımsızdır.

**Yalnızca API (SPA'sız)?** Evet: `"frontend": { "enabled": false }`.

**Angular, Vue, Svelte, düz HTML?** Evet; `index.html` içeren statik çıktı üreten her derleme.
`buildCommand`, `outputDir`, `apiBaseUrlEnvVar` ve CSP'yi uyarlayın.

## Sınırlamalar

- Tek sunucu: web, API ve veritabanı aynı makinede (tek arıza noktası - sunucu dışı yedek ve anlık
  görüntü şart).
- CI/CD ile dağıtım yok: paket yerelde üretilip RDP ile kopyalanır (GitHub Actions iş akışı yalnızca
  derler ve denetler).
- Windows Server 2025, PostgreSQL 18 ve .NET 10 ile denendi. PostgreSQL 17+ gerekir.
- Ayar başına bir API + bir SPA; tek veritabanı.
- Migration'lar yalnızca ileri yönlüdür.
- SPA şablonu, içerik özetli derleme dosyalarının `/assets/` altında olduğunu varsayar (Vite varsayılanı).
- SPA, API adresini derleme sırasında alır (ortam başına bir derleme).

## Lisans

[MIT](LICENSE)
