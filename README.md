# srvctl — CLI-Only Ultra-Güvenli Sunucu Yönetimi

> Sıfır GUI · Sıfır Docker · Sıfır Panel · Çok Katmanlı Güvenlik
> Ubuntu 22.04 LTS · PHP-FPM · Nginx · MariaDB · Redis

---

## Nedir?

`srvctl` tamamen CLI tabanlı, güvenlik odaklı bir sunucu yönetim aracıdır. Her domain eklendiğinde güvenlik katmanları otomatik uygulanır; sunucu kurulumunda ise OS sertleştirme ve WAF dahil gelişmiş katmanlar devreye girer.

### Çekirdek güvenlik katmanları (her domain)

| # | Katman | Açıklama |
|---|--------|----------|
| 1 | Linux kullanıcı izolasyonu | Her domain ayrı sistem kullanıcısı (`web_domain`) |
| 2 | Dizin izinleri + ACL | `750` + `setfacl` ile sıkı erişim |
| 3 | chroot jail | PHP process domain dizininin dışına çıkamaz |
| 4 | PHP-FPM pool izolasyonu | Ayrı FPM pool, ayrı socket |
| 5 | AppArmor profili | Kernel seviyesinde erişim kısıtı (enforce) |
| 6 | open_basedir | PHP erişim dizinlerini kısıtlar |
| 7 | disable_functions | `exec`, `system`, `shell_exec` vb. kapalı |
| 8 | MariaDB GRANT izolasyonu | Domain yalnız kendi DB'sine erişir |
| 9 | Redis ACL | Domain yalnız kendi key prefix'ine erişir |
| 10 | Nginx güvenlik header'ları | HSTS, CSP, X-Frame-Options, rate limit |
| 11 | Fail2Ban | Brute-force engelleme |
| 12 | auditd | Dosya değişiklik denetimi |

### Gelişmiş katmanlar (sunucu geneli — `srvctl init`)

| Katman | Açıklama |
|--------|----------|
| ModSecurity WAF + OWASP CRS | Uygulama katmanı saldırı filtreleme |
| seccomp (SystemCallFilter) | PHP-FPM için tehlikeli syscall engelleme |
| cgroups v2 | Per-domain CPU/RAM/IO limiti |
| AIDE | Dosya bütünlük kontrolü (günlük) |
| ClamAV | Upload antivirüs taraması (günlük) |
| GeoIP | Ülke bazlı engelleme |

---

## Hızlı Kurulum

```bash
scp -r srvctl/ root@server:/tmp/srvctl/
ssh root@server
cd /tmp/srvctl && sudo bash install.sh
sudo nano /usr/local/srvctl/conf/srvctl.conf   # SSH portu, PHP sürümü...
sudo srvctl init                                # tek seferlik
sudo srvctl domain add example.com --php=8.3
```

---

## Komut Referansı

### Sunucu
```bash
sudo srvctl init        # Tek seferlik kurulum (12 + gelişmiş katman)
sudo srvctl status      # Durum özeti
sudo srvctl security audit            # Güvenlik denetimi (skor/100)
sudo srvctl security harden-fs <d>    # Dosya-sahiplik modelini ÖNİZLE (dry-run)
sudo srvctl security harden-fs <d> --apply   # uygula | --revert geri al | --all tümü
sudo srvctl security harden-fpm <d>   # FPM unit modelini ÖNİZLE | --apply | --all
```

> **Fail-closed audit (Faz 2/T7b):** `security audit` artık AppArmor/seccomp/cgroups'u
> **gerçek enforce durumuyla** kontrol eder (yalnız servis/profil-adı varlığıyla değil):
> bir domain'in FPM unit'i gerçekten enforce değilse ilgili kontrol **FAIL** verir.
> modsec /admin XSS koruması yalnız 941160 (zengin-metin yanlış-pozitifi) hariç aktiftir.

> **Per-domain FPM unit (Faz 2/T7a):** Her domain kendi `srvctl-fpm-<sname>.service`'inde
> çalışır; AppArmor profili (`AppArmorProfile=`) ve cgroups slice (`Slice=`) systemd üzerinden
> gerçekten uygulanır. Mevcut kurulumları taşımak:
> `srvctl security harden-fpm <domain> [--apply|--all]`

> **Dosya-sahiplik modeli (Faz 2/T1):** Her domain'in base dizini (`/var/www/<domain>/`)
> `root:root 751`'dir; web kullanıcısı yalnız yazması gereken alt dizinlere (public_html,
> private/writable, tmp, sessions, logs) sahiptir. Böylece `.credentials`/`.srvctl-meta`/
> `.deploy-repo` web kullanıcısı tarafından silinip-değiştirilemez (RC1 kapalı). Eski
> kurulumlardaki domain'leri yeni modele taşımak için `security harden-fs` kullanın
> (önce `dry-run` ile önizleyin).

### Domain — Temel
```bash
sudo srvctl domain add example.com --php=8.3
sudo srvctl domain list
sudo srvctl domain info example.com
sudo srvctl domain remove example.com        # öncesinde otomatik yedek
```

### Domain — Operasyonel (v2.0)
```bash
sudo srvctl domain clone kaynak.com hedef.com        # DB + dosya klonla
sudo srvctl domain suspend example.com               # bakım modu (503 + sayfa)
sudo srvctl domain unsuspend example.com
sudo srvctl domain php-switch example.com 8.2        # PHP sürümü değiştir
sudo srvctl domain resources example.com --memory=512M --cpu=50% --io=100
sudo srvctl domain resources example.com --show
sudo srvctl domain staging example.com               # staging.example.com klonu
sudo srvctl domain migrate example.com user@host [--auto]
```

### Deploy (zero-downtime)
```bash
sudo srvctl deploy example.com [branch]      # atomic switch + health check
sudo srvctl deploy example.com --dry-run     # canlıya geçirmeden dene
sudo srvctl deploy rollback example.com      # önceki sürüme dön
sudo srvctl rollback example.com             # (kısayol — aynısı)
sudo srvctl deploy health example.com        # sağlık kontrolü
sudo srvctl deploy list example.com          # release geçmişi
```
**Akış:** git clone → composer → `pre-deploy.sh` hook → shared bağla → izinler → atomic symlink switch → health check (başarısızsa **otomatik rollback**) → `post-deploy.sh` hook → eski release temizliği (son 5).
Hook'lar: `shared/hooks/pre-deploy.sh` ve `shared/hooks/post-deploy.sh` (varsa çalışır; `RELEASE_DIR`, `DOMAIN` env'leri verilir).

> **Güvenlik (Faz 2/T3):** Deploy hook'ları ve `composer install` per-domain web
> kullanıcısı olarak (`runuser`, root **değil**) çalışır — kötü niyetli composer
> lifecycle script'i ya da hook'u root'a ulaşamaz. `shared/.env`/`shared/writable`
> bir symlink ise reddedilir (`chown -R` ile jail dışına çıkış engellenir).

### Yedekleme
```bash
sudo srvctl backup run [domain]
sudo srvctl backup list
sudo srvctl backup restore 20250618_040000
```
Günlük otomatik yedek (04:00), 30 günden eski yedekler silinir.

> **Güvenlik notu (Faz 1):** Yedek paketleri `.credentials` ve `.srvctl-meta`
> dosyalarını **içermez** (parolaların world-readable yedeğe sızmaması için).
> Geri yüklemede DB/Redis parolaları yeniden üretilir veya `.credentials`
> güvenli (band-dışı) bir kopyadan elle yerleştirilir. Yedek şifrelemesi
> ileride eklenecektir.

### SSL
```bash
sudo srvctl ssl renew
sudo srvctl ssl status
```

Sonradan ssl eklemek isternirse:
```bash
sudo certbot --nginx -d example.com -d www.example.com
```

### İzleme & Alarm
```bash
sudo srvctl monitor live                # canlı sistem + per-domain kaynak
sudo srvctl monitor domains             # per-domain CPU/RAM/disk/conn
sudo srvctl monitor uptime [domain]     # HTTP + SSL süre kontrolü
sudo srvctl monitor check               # tam kontrol + alarm + oto-kurtarma
sudo srvctl monitor traffic example.com # GoAccess trafik analizi
```

### Bildirim (Telegram / Discord / Slack / Email)
```bash
sudo srvctl notify setup
sudo srvctl notify test
```

### IP & Ağ
```bash
sudo srvctl ip ban 1.2.3.4 [süre]
sudo srvctl ip unban 1.2.3.4
sudo srvctl ip whitelist add 1.2.3.4
sudo srvctl ip blacklist add 1.2.3.4
sudo srvctl ip geoblock add CN
sudo srvctl ip list
```

### Cloudflare
```bash
sudo srvctl cloudflare setup
sudo srvctl cloudflare dns list example.com
sudo srvctl cloudflare dns add example.com A www 1.2.3.4
sudo srvctl cloudflare purge example.com
sudo srvctl cloudflare waf enable example.com
sudo srvctl cloudflare ddos on example.com     # Under Attack modu
sudo srvctl cloudflare status example.com
```

### Güvenilir edge-IP senkronu (`srvctl trusted`)

Cloudflare ve UptimeRobot'un yayınladığı IP'leri otomatik allowlist'e ekler:
fail2ban `ignoreip` (bu IP'ler asla banlanmaz) + Cloudflare için nginx real-IP
restorasyonu (`set_real_ip_from` + `CF-Connecting-IP`). `srvctl init` günlük
cron kurar (`30 2 * * *`, default açık). Fetch başarısızsa son-iyi liste korunur.

| Komut | Açıklama |
|-------|----------|
| `srvctl trusted sync` | IP'leri şimdi çek + uygula |
| `srvctl trusted list` | Yönetilen IP'leri ve son senkronu göster |

Yapılandırma (conf/srvctl.conf, varsayılanlar load_config'te):
`TRUSTED_SYNC_ENABLED`, `TRUSTED_SOURCES`, `CLOUDFLARE_IPS_V4_URL`,
`CLOUDFLARE_IPS_V6_URL`, `UPTIMEROBOT_IPS_URL`.

### Kullanıcı Yönetimi (RBAC + 2FA)
```bash
sudo srvctl user add ali --role=developer      # admin | developer | viewer
sudo srvctl user grant ali example.com
sudo srvctl user revoke ali example.com
sudo srvctl user key add ali ~/.ssh/id_ed25519.pub
sudo srvctl user 2fa setup ali                 # TOTP
sudo srvctl user audit [ali]
sudo srvctl user list
```

### Plugin & Webhook & Changelog
```bash
sudo srvctl plugin create myplugin
sudo srvctl plugin install <git_url>
sudo srvctl plugin list

sudo srvctl webhook setup example.com          # GitHub/GitLab push → auto-deploy
sudo srvctl webhook start

sudo srvctl changelog show 20
sudo srvctl changelog search DEPLOY
```

---

## Dizin Yapısı

### srvctl kurulum dizini
```
/usr/local/srvctl/
├── bin/srvctl
├── lib/            core, init, domain, deploy, backup, ssl, security, status,
│                   monitor, notify, cloudflare, ip, user, plugin, webhook, changelog
├── templates/      nginx, php-fpm, apparmor, logrotate, cgroups, seccomp
├── completions/    srvctl.bash, srvctl.zsh
├── plugins/        (kurulan plugin'ler)
├── conf/srvctl.conf
└── logs/           srvctl.log, changelog.log, webhook.log, aide.log, clamav.log
```

### Her domain
```
/var/www/example.com/
├── public_html/    Nginx root (deploy'da release/public'e symlink)
├── private/        Uygulama kodu (app, system, vendor, writable...)
├── shared/         Deploy'lar arası paylaşılan (.env, writable, hooks/)
├── releases/       Deploy geçmişi (son 5)
├── logs/  tmp/  sessions/
├── dev/  etc/      chroot ortamı
├── .credentials    DB/Redis kimlik bilgileri (root:600)
└── .suspended      (varsa) bakım modu bayrağı
```

---

## Yapılandırma — `/usr/local/srvctl/conf/srvctl.conf`
```bash
DEFAULT_PHP_VERSION=8.3
SSH_PORT=2222
WEB_ROOT=/var/www
BACKUP_DIR=/backups
BACKUP_RETENTION_DAYS=30
DEPLOYER_USER=deployer
# REDIS_ADMIN_PASS=        (init doldurur)
# CF_API_TOKEN=            (cloudflare setup doldurur)
# NOTIFY_TELEGRAM_TOKEN=   (notify setup doldurur)
```

---

## Güvenlik Doğrulama Testleri
```bash
# Dosya izolasyonu
sudo -u web_domain_a cat /var/www/domain_b/public_html/index.php   # Permission denied

# DB izolasyonu
mysql -u usr_domain_a -p -e "USE db_domain_b"                      # Access denied

# WAF (ModSecurity)
curl "https://example.com/?id=1' OR 1=1--"                        # 403

# AppArmor
sudo aa-status | grep srvctl                                       # enforce

# Tam denetim
sudo srvctl security audit                                         # skor ≥ 90/100
```

---

## Otomatik İşlemler (Cron)

| Zamanlama | İşlem |
|-----------|-------|
| `0 3,15 * * *` | SSL yenileme |
| `0 4 * * *`    | Günlük yedekleme |
| `30 2 * * *`   | Güvenilir edge-IP senkronu |
| `30 5 * * *`   | AIDE bütünlük kontrolü |
| `0 6 * * *`    | ClamAV upload taraması |

---

## Lisans
Özel kullanım için geliştirilmiştir.
