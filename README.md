# srvctl — CLI-Only Ultra-Güvenli Sunucu Yönetimi

> Sıfır GUI · Sıfır Docker · Sıfır Panel · Çok Katmanlı Güvenlik
> Ubuntu 22.04 / 24.04 LTS · PHP-FPM · Nginx · MariaDB · Redis

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
| 9 | Redis ACL | Domain yalnız kendi key/pub-sub prefix'ine erişir (scripting Redis sürümüne bağlı) |
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

## Desteklenen Platformlar

**Ubuntu 22.04 LTS (jammy)** ve **Ubuntu 24.04 LTS (noble)** birinci sınıf desteklenir — 24.04 bir "gelecek hedefi" değil, bugün üretimde çalışacak şekilde tasarlanmış ve gerçek VM'lerde doğrulanmıştır; 22.04 desteği düşürülmemiştir. `install.sh` her ikisini de **sessizce** kabul eder; başka bir Ubuntu sürümünde (ör. 20.04, 25.04) **uyarı + `evet` onayı** ister (kilitlemez), Ubuntu olmayan bir dağıtımda da aynı şekilde uyarır.

İki LTS arasındaki, srvctl'i doğrudan etkileyen davranış farkları:

| Bileşen | 22.04 (jammy) | 24.04 (noble) | Etkisi |
|---|---|---|---|
| Redis (apt varsayılan) | 6.0.16 | 7.0.15 | **22.04'te pub/sub kanal (channel) ACL izolasyonu YOK**: Redis 6.2 altında `resetchannels`/`&pattern` token'ları parser'da tanımlı değildir, bu yüzden bir domain diğer domain'lerin Redis kanallarını dinleyebilir/yayın yapabilir (srvctl'in değil, Redis 6.0'ın kendi sınırlaması). `srvctl init` bunu tespit edip **açıkça uyarır** (bkz. `_redis_channel_isolation_mode`, `lib/core.sh`). Kanal izolasyonu şart olan yoğun çok-domain'li (ör. e-ticaret) kurulumlarda **24.04 tercih edilmeli** ya da Redis 6.2+'a elle yükseltilmelidir. |
| PHP (apt varsayılan) | 8.1 | 8.3 — **8.2 varsayılan depoda YOK** | `srvctl domain add`/`init` eksik bir PHP sürümünü fail-open atlar (çökmez); 24.04'te PHP 8.1 veya 8.2 isteniyorsa Ondřej PPA (`ppa:ondrej/php`) gerekir. |
| AppArmor parser | 3.0.4 | 4.0.1 | Fark **gözlemlenmedi**: her iki şablon (`templates/apparmor/profile.tpl`, `profile-cli.tpl`) her iki sürümde de `apparmor_parser -Q` ile 0 kalıntı token'la temiz parse ediyor. |
| systemd | 249 | 255 | Detaylar için bkz. aşağıdaki geliştirici referansı. |

> Geliştirici referansı (yetenek-tespiti kuralları, tam sürüm-farkı tablosu, kod yazarken uyulacak kurallar): [`.claude/ubuntu-compat.md`](.claude/ubuntu-compat.md).

---

## Redis Scripting (Lua) Durumu

Domain'de `REDIS_SCRIPTING=enabled` belirtilirse:
- **Redis 7.0+:** Lua script'ler ACL-farkında (tüm komutlar denetlenir) — supportlu
- **Redis 6.x:** Lua script'ler denetim dışında kalır — **yapılandırılmamıştır**. 
  Laravel queue gibi script-kullanan kütüphaneler çalışmaz; `QUEUE_CONNECTION=database` 
  vb. alternatif kullanın

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

> **Bilinmeyen alt komut:** `srvctl <modül> <bilinmeyen>` kullanım metnini basar ve **çıkış kodu 1** döner
> (stderr'e "Bilinmeyen … alt komutu" yazılır). Yalnız açık yardım istekleri (alt komutsuz çağrı, `help`, `-h`,
> `--help`) 0 döner. Bu, eski kurulu srvctl'de bulunmayan bir alt komutu (ör. FM desteğinden önceki sürümde `domain fm-root`)
> çağıran betiğin sahte başarı görmemesi içindir. Kapsam: `domain`, `self-update`, `backup`, `changelog`,
> `cloudflare`, `cron`, `ip`, `notify`, `plugin`, `ssl`, `monitor`, `user`, `webhook`, `security`, `trusted`
> (`deploy`'un `*)` dalı bir domain deploy'udur; bilinmeyen üst komut zaten `exit 1` verir). **Eski bir srvctl'de bu
> kural YOKTUR** — kurulu sürümün yeni alt komutu bilip bilmediğini rc'den değil çıktıdan (`fm-auth --capabilities`
> / `domain help`) anlayın.

### Sunucu
```bash
sudo srvctl init        # Tek seferlik kurulum (12 + gelişmiş katman)
sudo srvctl status      # Durum özeti
sudo srvctl security audit                    # Güvenlik denetimi (skor/100)
sudo srvctl security harden-fs <domain>       # Dosya-sahiplik modelini ÖNİZLE (dry-run)
sudo srvctl security harden-fs <domain> --apply  # Uygula | --revert geri al | --all tümü
sudo srvctl security harden-fpm <domain>      # Per-domain FPM unit'ini ÖNİZLE (dry-run)
sudo srvctl security harden-fpm <domain> --apply --all  # Uygula | tüm domain'ler
```

> **Fail-closed audit (Faz 2/T7b) — ÖNEMLİ UYARISI:** `security audit` artık 
> AppArmor/seccomp/cgroups'u **gerçek enforce durumuyla** kontrol eder 
> (yalnız servis/profil-adı varlığıyla değil). Mevcut kurulumlar: varsayılan 
> `domain add` yolu paylaşılan FPM havuzunu kullandığından domain başına 3 
> FAIL (AppArmor/seccomp/cgroups attach) alacak ve skor düşecek. Bu beklenen; 
> çözüm per-domain FPM unit'i devreye almak: `srvctl security harden-fpm <domain> --apply`.
> ModSecurity /admin XSS koruması yalnız 941160 (zengin-metin yanlış-pozitifi) hariç aktiftir.

> **🔴 KRİTİK GÜVENLİK DÜZELTMESİ — deploy kilit dizini (symlink ile ROOT'a yükselme):**
> Önceki sürümlerde `/run/srvctl/locks/<sname>` dizini `700 web_<sname>:web_<sname>`
> idi. Sahibi domain kullanıcısı olduğundan o kullanıcı kilit dosyasını **silip
> yerine keyfi bir hedefe sembolik bağ koyabiliyordu**; root olarak çalışan
> `srvctl deploy` bu bağı dereference edip hedefi `chown`/`chmod`/**truncate**
> ediyordu (`/etc/ld.so.preload` → tam root). Canlı bir Ubuntu 24.04 üretim
> sunucusunda sömürülebilirliği kanıtlandı.
> **Düzeltme:** dizin `710 root:web_<sname>` (domain kullanıcısında yazma yok,
> yalnız geçiş), kilit dosyası `660 root:web_<sname>` ve root tarafından
> ön-oluşturuluyor; `secure_file`/`secure_dir` sembolik bağda **fail-closed**
> (+ `chown -h`); `_deploy_lock` artık `exec 9>>` (truncate yok).
> **Mevcut kurulumlar:** bir sonraki `srvctl deploy` / `srvctl cron add`
> kilit ağacını yeniden uyguladığı için kendiliğinden onarılır; beklemeden
> kapatmak için `sudo srvctl domain repair --all` çalıştırın. `security audit`
> onarılmamış her domaini (ve yerleştirilmiş bir sembolik bağı) **FAIL** olarak
> raporlar.
>
> **Davranış değişikliği (`secure_file`/`secure_dir`):** hedef yolun kendisi bir
> sembolik bağsa artık hiçbir mod/sahiplik uygulanmaz — `warn` basılıp `1` dönülür.
> Bilinen tek gri alan: `BACKUP_DIR` bir mount noktasına **symlink** yapılmışsa
> `srvctl backup`/`init` uyarıp durur; `conf/srvctl.conf`'ta gerçek yolu yazın.

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
sudo srvctl domain add example.com [--php=8.3] [--framework=ci4|laravel|symfony]
                                   # Framework belirlerse `shared/` iskelesi,
                                   # `.env` şablonu, nginx denied yolları otomatik konfigüre edilir
sudo srvctl domain list
sudo srvctl domain info example.com [--show-secrets]  # Varsayılan parolalar gizli
sudo srvctl domain remove example.com        # öncesinde otomatik yedek
```

### Domain — Operasyonel (v2.0)
```bash
sudo srvctl domain clone kaynak.com hedef.com        # DB + dosya klonla (custom.d izin listesine uymuyorsa durur; --skip-custom-d)
sudo srvctl domain suspend example.com               # bakım modu (503 + sayfa)
sudo srvctl domain unsuspend example.com
sudo srvctl domain php-switch example.com 8.2        # PHP sürümü değiştir
sudo srvctl domain resources example.com --memory=512M --cpu=50% --io=100
sudo srvctl domain resources example.com --reset      # kaynak profiline döndür
sudo srvctl domain resources example.com --show
sudo srvctl domain staging example.com               # staging.example.com klonu (custom.d ihlalliyse DURUR)
sudo srvctl domain staging example.com --skip-custom-d  # custom.d'yi açıkça atlayarak
sudo srvctl domain migrate example.com user@host [--auto]
sudo srvctl domain worker <domain> <start|stop|status|enable|disable> [instance]
                         # Laravel queue / Symfony messenger / ci4ms (`spark ci4ms:worker`) yönet.
                         # ci4ms: komut release'te STATİK bulunursa (web kullanıcısıyla, kod çalıştırmadan);
                         # genel CI4'te worker yoktur
sudo srvctl domain scheduler <domain> <start|stop|status|enable|disable>
                         # Laravel `schedule:run` / CI4 `tasks:run` / ci4ms `cronjobs:run` yönet
                         # (Symfony'de yerleşik scheduler yok)
sudo srvctl domain rate-limit <domain> [profil]     # Rate-limit profilini değiştir/göster
sudo srvctl domain repair <domain>|--all             # GENİŞ onarım: chroot, FPM havuzu/unit + AppArmor,
                                                     # DB yetkisi + parola senkronu, Redis ACL, slice, FM dosyaları
sudo srvctl domain fm-root <domain>|--all [--apply]  # YALNIZ /_fm 403 kökü (kuru varsayılan; yazım gerekirse tek nginx -t + tek reload)
```

**Bellek eşikleri — `--memory` ne yapar:** verdiğiniz değer **tavan** (`MemoryMax`)
olarak kalır; `MemoryHigh` ve `MemorySwapMax` ondan türetilir (`High ≈ Max×8/9`,
`Swap = High/8`). Bu ayrım kritiktir: `MemoryHigh` kernel'in *yavaşlat ve geri
kazan* eşiği, `MemoryMax` ise *hard kill* eşiğidir. İkisi eşitlenirse throttle
aşaması tamamen atlanır ve süreç yavaşlamadan doğrudan OOM-kill yer. Daha önce
`--memory` ikisini eşitliyor, `MemorySwapMax`'ı ise dosyadaki eski değeriyle
(eski slice'larda `0`) bırakıyordu — ikisi de sessiz OOM kaynağıydı.

**`--reset` ne zaman gerekir:** `domain resources` mevcut slice dosyasını otorite
sayar (operatörün bilinçli ayarını korumak için). Bunun yan etkisi, eski bir
sürümden kalma **yanlış** bir değerin sonsuza kadar "korunmasıydı" — hiçbir komut
onu profile geri getiremiyordu. `--reset` bellek üçlüsünü ve `TasksMax`'ı kaynak
profiline döndürür; `CPUQuota` ile `IOWeight` **korunur** (ikisi
`conf/resource-profiles.conf` sözleşmesinde yoktur, dönülecek bir profil değerleri
yok). Aynı komutta verilen açık bayraklar reset'in üstüne yazar:
`--reset --cpu=200%` geçerlidir.

**`domain repair` artık cgroups slice'ı da denetler.** Daha önce
`_apply_cgroups_slice` yalnızca `domain add` yolundan çağrılıyordu; kaynak profili
sistemine geçildikten sonra mevcut domainlerin slice'ları hiç güncellenmiyordu.
Repair şimdi:

- slice dosyası **yoksa** profilden oluşturur (gerçek eksiklik → sessizce onarılır),
- slice **varsa** onu asla körlemesine ezmez — operatörün bilinçli ayarını geri
  almak, bu kod tabanında bir kez yaşanmış regresyon sınıfıdır.

"Profilden farklı olmak" tek başına bulgu sayılmaz (çoğu zaman operatör tercihidir
ve her repair'de gürültü üretirdi). Yalnızca **objektif olarak yanlış**, hiçbir
operatörün bilerek istemeyeceği üç durum raporlanır:

| Bulgu | Neden yanlış |
|---|---|
| `MemorySwapMax=0` | Eşzamanlı ağır isteklerde OOM-kill — `conf/resource-profiles.conf` bunu host'ta doğrulanmış olarak not ediyor |
| `MemoryHigh == MemoryMax` | Throttle/reclaim aşaması atlanır, doğrudan hard kill |
| `MemoryMax < max_children × memory_limit` | Havuz tam dolduğunda tavan matematiksel olarak yetmez |

Üçü de `srvctl domain resources <domain> --reset` ile tek komutta düzelir. Bulgu
raporlanması repair'i **başarısız saymaz**: repair'in çıkış kodu "site ayakta mı"
sorusunu yanıtlar, "limitler ideal mi" sorusunu değil.

### Per-domain yapılandırma ve reload
```bash
sudo srvctl domain reload example.com                # PHP-FPM + nginx reload
sudo srvctl domain reload example.com --fpm          # yalnız PHP-FPM
sudo srvctl domain reload --all                      # tüm domainler (nginx bir kez)

sudo -E srvctl domain ini example.com                # domaine özel PHP ayarları
sudo -E srvctl domain nginx example.com              # domaine özel nginx ayarları (izin listesi; --force YOK)
sudo srvctl domain nginx-audit example.com           # custom.d + /_fm 403 kökü denetimi (salt-okur; --all, --quarantine)
sudo srvctl domain ini example.com --show            # düzenlemeden içeriği gör
sudo srvctl domain ini example.com --file ayar.ini   # betikten uygula (editör açmaz)
```

**`domain reload` neden gerekli:** `DOMAIN_ISOLATED_FPM=true` (varsayılan) olan bir
kurulumda her domainin kendi `srvctl-fpm-<safe_name>.service` unit'i vardır ve
paylaşılan `php<ver>-fpm` servisi havuzsuz kaldığı için **bilerek durdurulmuştur**.
Refleks olarak çalıştırılan `systemctl reload php8.3-fpm` bu yüzden hiçbir şey
yapmaz — ve hata da vermez. `init` sırasında `opcache.validate_timestamps = 0`
ayarlandığından, fark edilmeyen bir reload başarısızlığı **süresiz eski bytecode
servisi** demektir. `domain reload` doğru unit'i kendi bulur, reload başarısız
olursa `restart` ile kurtarmayı dener ve sonunda `systemctl is-active` ile
gerçekten ayakta olduğunu teyit eder.

**Override dosyaları nerede:**

| | Yol | Nasıl uygulanır |
|---|---|---|
| PHP | `/etc/srvctl/php.d/<safe_name>.ini` | Pool config'ine `php_admin_value[...]` olarak enjekte edilir; aynı isimli şablon satırı düşürülür (her anahtar pool'da tek kez görünür) |
| nginx | `/etc/nginx/custom.d/<safe_name>/00-custom.conf` | vhost'un `server{}` bloğuna **en sonda** include edilir |

Her ikisi de render'ın **dışındadır**: `domain repair`, `domain php-switch` ve
`security harden-fpm` bunları **ezmez**, her seferinde yeniden uygular. Bu, elle
düzenlenen bir ayarın bir sonraki bakım komutunda sessizce kaybolması sorununu
kapatır.

Kaydettiğinizde srvctl önce **izin listesi** taramasını (`nginx -t`'den ÖNCE), sonra
sözdizimini (`php-fpm -t` / `nginx -t`) çalıştırır. Bir sorun bulunursa değişiklik
**uygulanmaz**; `.ini` durumunda ondan türetilen pool da eski haline döndürülür ve reload
yapılmaz. `.ini` için `--force` ile bilerek geçebilirsiniz (olay `log_action`'a ve bildirim
kanalına düşer). **`domain nginx`'te `--force` YOKTUR** (aşağıdaki izin listesi).

> **`sudo -E` notu:** `sudo` varsayılan olarak `env_reset` uygular ve `$EDITOR`'ü
> temizler. `sudo srvctl domain ini example.com` bu yüzden sizin editörünüzü değil
> `nano`'yu açar. Kendi editörünüz için `sudo -E srvctl domain ini example.com`
> çalıştırın.

> **nginx override'ının kısıtı:** Bir include dosyası mevcut direktifleri **ezemez**
> — nginx çoğu direktifte "is duplicate" hatası verir. Buraya *ekleme* yapılır,
> *override* değil. (`client_max_body_size` vhost'ta tanımlı olmadığı için serbestçe
> eklenebilir.) Ayrıca bir `location{}` bloğu içinde `add_header` kullanırsanız o
> location için üst bloğun **tüm** güvenlik başlıkları sessizce düşer; kullanacaksanız
> üsttekileri o blokta tekrarlayın.

> **Bu sürümden önce oluşturulmuş domainler:** vhost'larında `custom.d` include
> satırı yoktur. `domain nginx` (ve `fm-auth on`, `fm-root`) bunu fark edip durur —
> sessizce etkisiz kalmasındansa açıkça durması tercih edildi. **`domain repair` bunun çaresi DEĞİLDİR:**
> `repair` vhost'u yazmaz (vhost'u yalnız `domain add` ve `domain rate-limit` üretir). Çare:
> (1) önerilen — vhost'un `server { … }` bloğuna elle `include /etc/nginx/custom.d/<safe_name>/*.conf;`
> ekleyip `sudo nginx -t`, sonra `sudo srvctl domain reload <domain> --nginx`;
> (2) `sudo srvctl domain rate-limit <domain> <mevcut-profil>` vhost'u şablondan YENİDEN üretir
> (`--show` ile mevcut profili görün) — yan etkisi: vhost'taki tüm elle düzenlemeler kaybolur, nginx
> reload edilir ve profil meta'ya yazılır. İkisinde de `/_fm` 403 kökü ayrıca `fm-root <domain> --apply` ile kurulur.

### `custom.d` izin listesi (varsayılan RET) ve `domain nginx-audit`

`custom.d/<safe_name>/*.conf` dosyaları nginx'te **root yetkisiyle yüklenir**, ama içeriği
alan sahibinin elindedir; bu yüzden eski **yasak listesi** (kara liste: `fastcgi_pass`,
`*_pass`, kod/alt istek/yazma sınıfları, koşullu `proxy_pass`, B-biçimi korpus) yerine
**varsayılan-ret izin listesi** gelmiştir (`lib/nginx_allow.sh`; sözcük çözümleme
`lib/domconf.sh`'ın nginx `ngx_conf_read_token` birebir lexer'ıdır). Listede olmayan HER
direktif, değişken ve yapı reddedilir; çözümlenemeyen dosya (açık tırnak/blok, NUL bayt,
32 KiB üstü) da reddedilir.

Bağlam harfleri: **S** = dosya/server düzeyi, **L** = `location` içi, **I** = `location` içindeki
`if`, **J** = server düzeyindeki `if` (ayrı bağlam), **X** = `limit_except` gövdesi. Tablo
`lib/nginx_allow.sh` kuralının bire bir özetidir (kural değişirse tablo da değişir; direktif/bağlam/zone/tavan
eşitliğini `tests/test_readme_allowlist.sh` kilitler).

| İzinli direktif | Bağlam | Kısıt |
|---|---|---|
| `client_max_body_size` | S L | tek argüman `^[1-9][0-9]{0,5}[kKmMgG]?$` (`0` yasak) |
| `types` (blok) | S L | argümansız blok; içinde YALNIZ `<tür>/<alt-tür> <uzantı> [<uzantı> …];` satırları (tür RFC 6838 karakterleri, `$` yok; uzantı `[A-Za-z0-9]+`; yönerge/değişken/tırnak/`include`/iç blok yasak); boş `types {}` kabul |
| `default_type` | S L | tek MIME belirteci (`<tür>/<alt-tür>`; değişkenli/tırnaklı yasak) |
| `autoindex` | S L | YALNIZ `off` (`on` ve her varyantı, `autoindex_*` kesin ret) |
| `location` (blok) | S L | önek / `=` / `^~`: `^/[A-Za-z0-9._~/-]*$` (`..` yasak) ya da adlı `@[a-z][a-z0-9_]{0,31}`; `~` / `~*` regex (aşağıdaki regex kuralları) |
| `if` (blok) | S L | `($değişken)` ya da `($değişken OP değer)`; OP: `=` `!=` `~` `~*` `!~` `!~*`; sol işlenen tek değişken (dosya testi `-f`/`-d`… ve bileşik yasak); `=`/`!=` sağ işleneni değişkensiz sabit (≤200); blok içinde blok yasak |
| `set` | S L I J | `set $u_[a-z0-9_]{1,30} DEĞER`; değer çıkış kanalı sayılır (`$uri`, `$1..$9` ve yakalama kaynaklı `$u_*` yasak); okunan `$u_*` önce `set` ile tanımlanmış olmalı |
| `return` | S L I J | `KOD` (200-599) ya da `KOD METİN` ya da `http(s)://URL`; metin/URL çıkış kanalıdır |
| `rewrite` | S L I J | `REGEX YERİNE [last\|break\|redirect\|permanent]`; `last`/`break`/bayraksız YERİNE değişkensiz sabit yol, `redirect`/`permanent`/`http(s)://` YERİNE çıkış kanalı kuralları |
| `try_files` | S L | 2-8 argüman: `$uri`, `$uri/`, sabit yol (`?$args` / `?$query_string` ekli olabilir), `=KOD`, `@ad` |
| `add_header` | S L I | `AD DEĞER [always]`; `AD` = `^[A-Za-z][A-Za-z0-9-]{0,63}$`; DEĞER çıkış kanalı kuralları |
| `expires` | S L I | `off` \| `epoch` \| `max` \| `SÜRE` \| `modified SÜRE` (`^[+-]?[0-9]{1,9}(ms\|s\|m\|h\|d\|w\|M\|y)?$`) |
| `index` | S L | 1-8 düz dosya adı `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` (değişken/yol yasak) |
| `log_not_found` | S L | `on` \| `off` |
| `access_log` | S L I | yalnız `off` (yol alan günlük direktifi YOK: `nginx -t` yolu yaratır, `..` ile keyfi dosya) |
| `allow`, `deny` | S L X | tek argüman: `all`, IPv4, IPv6 ya da CIDR (`unix:` yasak) |
| `limit_req` | L | tam bir `zone=` + en çok bir `burst=N` (1-99999) + en çok bir `nodelay`; zone **kapalı küme**: `rl_strict rl_standard rl_relaxed rl_api login_strict login_standard login_relaxed general login api` |
| `limit_conn` | L | yalnız `limit_conn conn_per_ip N` (N 1-99999); `conn_per_ip` bir **bağlantı** bölgesidir, `limit_req` zone'u DEĞİLDİR |
| `limit_except` (blok) | L | yöntemler `GET HEAD POST PUT DELETE OPTIONS PATCH`; gövdede yalnız `allow`/`deny` |

Değişken kümesi (kapalı): `$request_uri $scheme $host $server_name $args $is_args $query_string
$request_method $remote_addr $http_host $http_user_agent $http_referer $arg_*` ve `set` ile
tanımlanmış `$u_*`; `if` sol işleneninde ayrıca `$uri`/`$1..$9` serbesttir. `${…}` biçimi yasak.
Regex kuralları (`location ~`, `if ~`, `rewrite`): ≤200 karakter; iç içe/alternasyonlu nicelik ve
>3 sınırsız nicelik (ReDoS sezgisi; grup niceliği `)+`/`)*` iki sayılır), `{n,m}` değerleri en çok 255 ve
n ≤ m, PCRE kod/fiil/geri başvuru/lookaround/bayrak, `_f` dizgisi ve
tek-karakterlik-sınıf ile gizleme yasak; desen ERE'ye çevrilip srvctl FM yolu örneklerine
(`/_fm/…`, `/__fm_auth`, …; 481 yol) karşı sınanır, eşleşen desen reddedilir. Sondada `X{n,m}`
`X{min(n,8),}` üst kümesine genişletilir (yalnız daha çok red; GNU grep'in `{0,m}` açılımı karesel
derlenir) ve dosyanın bütün desenleri TEK `grep` ile sınanır; red yolunda eşleşen desen ikiye
bölünerek (en çok 64 `grep`) satırıyla bulunur.
Genel tavanlar: dosya 32 KiB, dosya başına en çok 2048 ifade (blok başlığı dahil; aşan dosya
doğrulanamadı sayılır, RED), ifade başına en çok 16 argüman, blok derinliği 4, belirteç 1024
bayt, yalnız yazdırılabilir ASCII (CR/LF/NUL/BOM yasak), direktif adı küçük harf.

Kesin ret (örnek): her `*_pass` (**`proxy_pass` dahil**), `proxy_*`, `fastcgi_*`, `uwsgi_*`,
`scgi_*`, `grpc_*`, `include`, `root`/`alias`/`listen`/`server_name`, `modsecurity*`,
`auth_request*`, `auth_basic*`, `error_log`/`error_page`, `map`/`geo`/`upstream`, `mirror`, `ssi*`,
`sub_filter*`, `resolver`, `limit_*_zone` ve kod/alt istek/yazma modülleri. **Yasak dizgi (harf
duyarsız, HER argümanda):** `srvctl` (`@srvctl` dahil), `fm-auth`, `/_fm/`, `_fm`, `fm_`, `__fm_`, `@fm`, `$fm`,
`x-fm`, `x-accel`, `upstream_http`, `sent_http`, `http_authorization`, `$cookie`, `cookie_`, `$ssl_`.
Rezerve dosya adı: köken kaydında olmayan ve adı `*srvctl*` ya da `*fm*` içeren dosya (nginx `*.conf`
glob'una girse de) kullanıcı dosyasıdır ve reddedilir (aday/geçici dosyada hedefin mantıksal adı denetlenir).
Kalıntı risk: regex'ler için ReDoS sezgisi (uzunluk + iç içe nicelik) yalnız **derinlik**
savunmasıdır; işçi süreç üzerindeki etkisi `nginx` işçi sayısıyla sınırlıdır.

#### `proxy_pass` ilkesi (KULLANICI KARARI, 2026-10-25): kullanıcı dosyasında TAM YASAK

`proxy_pass` (ve `fastcgi_pass`/`uwsgi_pass`/`grpc_pass`/`scgi_pass`; loopback `127.0.0.1:PORT`,
unix soket, değişkenli hedef, koşullu kullanım dahil) `custom.d` **kullanıcı dosyasında hiçbir
biçimde kabul edilmez**, listeye de eklenmez. **Gerekçe:** `custom.d` dosyaları nginx'te **root
yetkisiyle** yüklenir ve içeriği alan sahibinin elindedir; ters vekil hedefi alan sahibine
sunucudaki başka bir dinleyiciye (başka kiracının loopback hizmeti, yönetim uçları, bulut
meta-veri adresi, unix soketler) kendi kimliğiyle olmayan bir yol açar, başlık sızdırma/SSRF ve
kiracı atlama sınıfının tamamını doğurur. Hedefi/başlığı doğrulayan bir "güvenli biçim" (B-biçimi
korpus, koşullu `proxy_pass`) denendi; her yeni biçim yeni bir baypas bulgusu üretti ve kaldırıldı.

**İlke: ters vekil ihtiyacı doğarsa çözüm kullanıcı dosyası değildir.** İhtiyaç kanıtlanırsa
srvctl'e **ayrı, şablonlu bir komut** eklenir (bugünkü `domain fm-auth` gibi: sabit hedef/bölge
tablosu, `assert_*` kapılı token'lar, köken kaydı, `nginx -t` ile geri alma). Kullanıcı
dosyasına `proxy_pass` yazdırmak için izin listesine istisna eklenmez ve elle `custom.d` düzenlemesi
bir çözüm olarak önerilmez. `proxy_pass` bugün yalnız srvctl'in ürettiği `20`/`21` şablonlarında
vardır (hedef: sabit pCloud ana makinesi).

Mevcut `proxy_pass` kullanan dosyalar **kırılmaz/silinmez** (`repair`/`reload` dokunmaz);
`srvctl domain nginx-audit [--all]` bunları `dosya:satır:proxy_pass:kesin-ret` olarak **raporlar**,
karar (kaldır / `--quarantine` / ayrı şablonlu komut talebi) kullanıcınındır. Yeni yazım
(`domain nginx --file`, `fm-auth on`, `domain clone`) bu dosyalarla **reddedilir**.

> **KIRICI DEĞİŞİKLİK (PR notu):** önceki sürümler `proxy_pass` (belgeli `http://127.0.0.1:PORT`
> kullanımı dahil) ve birçok direktifi izin veriyordu. Yeni sürüm bunları **yeni yazımlarda**
> reddeder. **Mevcut dosyalar kırılmaz/silinmez:** `repair`/`reload` bunlara dokunmaz, yalnız
> `nginx-audit` sayar; zorlama (karantina) kullanıcı kararıdır. Tek kanıtlı operatör kullanımı
> `client_max_body_size` idi; kanıtsız kalemler listeden çıkarıldı (geri eklemek kanıt + karar ister).
> `domain clone` kaynağın `00-custom.conf`'u uymuyorsa **durur**; `--skip-custom-d` ile açıkça atlanır.

```bash
sudo srvctl domain nginx-audit example.com            # SALT-OKUR denetim
sudo srvctl domain nginx-audit --all                  # tüm alanlar
sudo srvctl domain nginx-audit example.com --quarantine   # YALNIZ açık bayrakla: ihlalli dosyayı ayır
```

`nginx-audit` diske bakar (`custom.d/<safe_name>/*.conf`); **`nginx -t`/`-T`/reload çalıştırmaz,
hiçbir dosyayı değiştirmez**, `domain nginx --show` yolunu (iskelet yazar) kullanmaz.
Çıktı satırı `dosya:satır:direktif:gerekçe`; `.conf` olmayan adlar yalnız `BILGI` satırıdır.
Çıkış kodu: **0** temiz, **1** ihlal, **2** doğrulanamadı (2 öncelikli; ihlal satırları yine
basılır). `--json` yoktur. Kullanıcı dosyalarına ek olarak her alanın **`/_fm` 403 kökü** denetlenir;
kök sorunu en az **1** verir ve satırında çözüm yazar (`srvctl domain fm-root <alan> --apply`):
`KÖK-YOK` (kök kurulu değil — `/_fm` uygulamaya düşer; `custom.d/<safe_name>` dizini yoksa da),
`KÖK-KAYITSIZ` (FM adlı dosya köken kaydı olmadan diskte), `KÖK-SAĞLAM-DEĞİL` (kayıt var, `20` eksik/
kurcalanmış), `KÖK-DOĞRULANAMADI` (STATE-UNTRUSTED), `YARIM-İŞLEM` (kesintiye uğramış FM yazımının
yedeği; aşağıda). Yani "temiz" (0) yalnız kökü sağlam alanda mümkündür.

`--quarantine` (yalnız açık bayrakla): ihlalli (kod 1) **kullanıcı** dosyasını `<ad>.srvctl-rejected`e
taşır (`*.conf` glob'una girmez; ad doluysa `.srvctl-rejected.1`… — eski kanıtın üzerine yazılmaz).
**Asla taşınmayanlar:** srvctl/FM rezerve adları (`20`/`21`/`90` — kayıtlı, kurcalanmış ya da kayıtsız;
`/_fm` 403 kökü dahil) — "yeniden üret: `fm-root`" denir; doğrulanamayan (kod 2) dosyalar.
**Karantina YAPILMAYAN alanlar:** STATE-UNTRUSTED (köken doğrulanamazken taşınan dosya srvctl'in kendi
kökü olabilir) ve 403 kökü sağlam olmayan alanlar (taşınan bir kullanıcı dosyası `/_fm`'i uygulamaya
düşürebilir) — önce `srvctl domain fm-root <alan> --apply`. Taşımalar fm-auth kilidi altında,
hepsi-ya-hiçbiri yapılır (bir `mv` hatası önceki taşımaları geri alır; sarkan bağ ve satır sonu içeren
adlar da taşınır); sonra `nginx -t` ve kök yeniden doğrulanır → hata ya da kök bozulmuşsa **hepsi geri**,
reload yok. Ölçülen karantina yollarında (macOS PhpWebStudy nginx 1.28.0 laboratuvarı: nginx-audit
karantina hücreleri, `/_fm` sondaları FM200=0) `/_fm` uygulamaya düşmedi. **Kapsam sınırı:** nginx 1.18/1.24,
Linux (harf duyarlı önek eşleşmesi), bash 5 ve gerçek flock/AppArmor/ModSecurity ÖLÇÜLMEDİ — "hiçbir yol
düşürmez" kanıtlanmış bir iddia DEĞİLDİR; canlıda ölçülecektir.

#### Canlı yayılım adımları (izin listesi + FM şablonları)

1. **Denetim, kullanıcıya gösterilir:** yeni srvctl kurulmadan önce, yeni kodu bir kopyada
   (`/usr/local/srvctl` dışında) ya da yeni sürümü kurduktan hemen sonra `sudo srvctl domain
   nginx-audit --all` çalıştırılır; çıktı (ihlaller + `proxy_pass` kullanan alanlar) kullanıcıya
   **olduğu gibi** sunulur. Hiçbir dosya değişmez.
2. **Karar:** her ihlalli dosya için kullanıcı kararı: izin listesine uyacak şekilde düzenle,
   `--quarantine` ile ayır ya da (`proxy_pass` gibi bir ihtiyaç için) srvctl'e **ayrı şablonlu komut**
   talep et — `proxy_pass` kullanıcı dosyasına ASLA izin listesi istisnasıyla eklenmez ("`proxy_pass`
   ilkesi"). Karar verilmeden devam edilmez.
3. **Güncelle:** `sudo bash install.sh` (conf korunur). Mevcut `custom.d` dosyalarına ve `reload`'a
   dokunulmaz; çalışan yapılandırma kırılmaz. Eski alanlar **kökü olmadan** kalır (`status` ve
   `nginx-audit` bunları `YOK`/`KÖK-YOK` ile, çıkış 1 olarak listeler). **Kök için dar komut:**
   `sudo srvctl domain fm-root --all` (KURU: yapılacak işi listeler) → kullanıcıya gösterilir →
   `sudo srvctl domain fm-root --all --apply` (yalnız FM dosyaları; tek kilit; **yazılacak iş varsa** tek
   `nginx -t` — hata olursa **tüm** alanlar geri alınır —, tek reload; yazılacak iş yoksa `nginx -t` ve reload
   HİÇ çalışmaz; yalnız bir yarım işlem yedeği geri yüklendiyse o durumu yüklemek için ayrı bir `nginx -t` + reload
   koşar; mevcut kullanıcı dosyaları değişmez). Kök için
   `repair --all` **önerilmez**: `repair` geniş bir onarımdır — chroot kütüphaneleri, FPM havuzu/unit +
   AppArmor (paylaşılan FPM reload/restart), DB yetkisi + parola senkronu, Redis ACL, cgroups slice ve
   FM dosyaları; tek alanda bile servis yeniden yüklemeleri yapar.

   **`self-update` ile geçiş — FM destekli sürüme İLK güncellemede soruya HAYIR deyin.** Çalışan süreç, kendi
   (bellekteki) ESKİ `_selfupdate_run` gövdesini yürütür ve değiştirilemez: dosyalar kopyalandıktan sonra
   "Şimdi 'srvctl domain repair --all' çalıştırılsın mı?" diye sorar. **Bu soruya `evet` demeyin** (geniş
   eylem: FPM/AppArmor/DB/Redis). `evet` denirse yeni sürümün `lib/domain.sh`'ı çağrıyı yakalar:
   `_selfupdate_run` zincirindeki `repair` isteği geniş onarıma DÖNÜŞMEZ ("GEÇİŞ KORUMASI" uyarısı), yalnız
   kuru `fm-root --all` planı gösterilir ve ayrı bir onay istenir (`tests/test_selfupdate_first_update_transition.sh`);
   yine de doğru adım "hayır" deyip aşağıdaki sırayı elle izlemektir: `sudo srvctl domain fm-root --all`
   (kuru) → `sudo srvctl domain fm-root --all --apply`. Onaylı otomatik `fm-root` adımı (önce kuru plan,
   ikinci onay) FM destekli sürümden yapılan güncellemelerde çalışır — yeni `_selfupdate_run` onu kendisi çağırır.
4. **FM'i aç:** `sudo srvctl domain fm-auth <alan> on --script=/current/modules/FileManager/Auth/fm-auth.php [--region=eu|us]`
   — alanın kullanıcı dosyalarında ihlal varsa REDDEDİLİR (kullanıcı dosyası FM yolunu etkileyebilir).
   Sonra `status` AÇIK olmalıdır.
5. **Geri alma:** `sudo srvctl domain fm-auth <alan> off` (403 kökü kalır: `/_fm` tam eşleşme + `^~ /_fm/` + `/__fm_` ad alanı yakalayıcısı; yol CI4'e
   düşmez). Başarı YALNIZ `rc 0` + çalışan nginx'in KAPALI imzası ile söylenir; `rc≠0` ise "Acil kapatma" bölümündeki
   çıkış kodlarına bakın (`status` her zaman diski VE çalışan durumu gösterir). Tam geri dönüş için önceki srvctl sürümünü `install.sh` ile yeniden kurun; köken kaydı
   (`${SRVCTL_STATE_DIR}/_fm-auth/`) önceki sürümce okunmaz, zararsızdır. Karantinaya alınan dosyayı geri
   almak için adını `.conf`a döndürün ve `srvctl domain reload <alan>`.

   **Sürüm geri dönüşü ve KALINTI köken kaydı:** FM destekli sürümden eski sürüme dönüp orada bir alan
   `domain remove` edilirse, eski sürüm FM destekli sürümün bıraktıklarını (`_fm-auth/<safe_name>.manifest`,
   `custom.d/<safe_name>/20|21|90-srvctl-fm-*.conf`) BİLMEDİĞİ için silmez. FM destekli sürüm yeniden kurulunca aynı adla
   `srvctl domain add` **REDDEDİLİR** ("bu alan için KALINTI köken kaydı var … inceleyip kaldırın"; fail-closed,
   hiçbir kaynak yaratılmadan). Bu davranış BİLİNÇLİDİR ve değiştirilmedi: kalıntı kayıt "üretilmiş" muafiyeti
   taşıyabileceğinden sessizce yok sayılmaz ya da otomatik silinmez. Çıkış (silme YOK, kanıt korunur):
   (a) alanın gerçekten yok olduğunu doğrulayın (`/var/www/<alan>` ve vhost yok; alan yaşıyorsa bu yola GİRMEYİN —
   `fm-root <alan>` kaydı ve kökü onarır), (b) `sudo mv ${SRVCTL_STATE_DIR}/_fm-auth/<safe_name>.manifest
   ${SRVCTL_STATE_DIR}/_fm-auth/<safe_name>.manifest.kalinti` ve `custom.d/<safe_name>/` altında kalan
   `20`/`21`/`90` dosyalarını da aynı biçimde (`.kalinti`) kenara alın, (c) `add`'i yeniden deneyin. Aynı adım
   Deploy README §2 madde 5'te de yazılıdır. (FM destekli sürümde `domain remove` kaydı kendisi temizler.)

### `domain fm-auth` — FileManager nginx dosyaları (opt-in, şablondan üretim)

```bash
sudo srvctl domain fm-auth example.com status
sudo srvctl domain fm-auth example.com on --script=/current/modules/FileManager/Auth/fm-auth.php [--region=eu|us]
sudo srvctl domain fm-auth example.com off [--force]
sudo srvctl domain fm-auth example.com off --emergency        # ACİL kapatma (aşağıda; rc 0/3/4/5/6)
sudo srvctl domain fm-auth example.com on --script=… --dry   # doğrula, HİÇBİR dosya yazma
```

> **`fm-auth <alan> on` çıkış kodları:** `0` = açıldı VE sonda çalışan nginx'te AÇIK imzasını (411 + alan imzası) gördü; `1` = reddedildi/başarısız
> (kapılar, `nginx -t`, reload, kilit; geri alınan açılışlar dahil — alan KAPALI kalır ya da ileti gerçeği söyler); **`4` = AÇILDI ama canlıda DOĞRULANAMADI** (disk+kayıt `on`,
> reload başarılı, sonda ne AÇIK ne KAPALI imzası gördü: curl yok, 443'te başka vhost, bağlantı yok …). `4`, `status`un "doğrulanamadı" koduyla AYNI anlamdır (aşağıda); `on`un başka rc tablosu çakışması yoktur
> (`on` bugüne dek yalnız 0/1 veriyordu). Geri alma YAPILMAZ (sondası çalışmayan alan hiç açılamazdı); sessiz başarı da yoktur: ileti `AÇILDI, canlıda DOĞRULANAMADI (<neden>)` der,
> `srvctl domain fm-auth <alan> status` ile doğrulamayı ve gerekirse `off`u önerir. Otomasyon `4`ü "açık ama kanıtsız" okumalıdır ("başarısız" ya da "kapalı" değil). `--dry` her zaman 0/1'dir (sonda yok).

**Varsayılan KAPALI**; açılmadıkça yalnız `/_fm` 403 kökü (aşağıda) yazılır. `on`, `custom.d/<safe_name>/`
altına srvctl'in şablonlardan ürettiği **üç** dosyayı koyar (vhost şablonu değişmez; root:root 644;
yazımlar atomiktir; `custom.d`'de **hiç `include` yoktur**):

| Dosya | Şablon | İçerik |
|---|---|---|
| `90-srvctl-fm-auth.conf` | `templates/nginx/fm-auth.conf.tpl` | `location = /__fm_auth { internal; … }` — domainin **kendi** FPM soketine `fastcgi_pass`, `fastcgi_pass_request_body off`, `CONTENT_LENGTH ""`, sabit `SCRIPT_FILENAME`, `client_max_body_size 33m`, `fastcgi_hide_header X-Fm-Auth` |
| `21-srvctl-fm-download.conf` | `fm-download.conf.tpl` | `location = /__fm_dl { internal; … }` — `$arg_u` deseni (yalnız `https://*.pcloud.com/…`), `X-Accel-*` yok sayma, başlık izin listesi, `X-Fm-Ticket ""`, ayrı `crit` hata günlüğü |
| `20-srvctl-fm-upload.conf` | `fm-upload.conf.tpl` | `location ^~ /_fm/up/` (+ `location = /_fm { return 403; }` + `location ^~ /_fm/ { return 403; }` + adlı `@fm_deny` (auth hata eşlemesi) + adlı `@fm_up`): biçim kapısı, `limit_except PUT`, `auth_request`, **KAPI 2**, akıtma `proxy_pass` |

Sabit parametreler: pCloud ana makinesi **yalnız tablodan** (`--region=eu` → `eapi.pcloud.com`
(varsayılan), `us` → `api.pcloud.com`; başka değer reddedilir, host dosyadan/ortamdan okunmaz),
parça gövde sınırı `33m`, auth sınırı `33m`, betik yolu `--script` allowlist'i + gerçek yol denetimi.
Tüm şablon token'ları doğrulanır (`assert_safe_ident`/`assert_regex_safe`); beslenmeyen `{{…}}`
kalırsa render reddedilir.

**Konum önceliği:** yükleme location'ı `^~` önek eşleşmesidir; nginx `^~` önek kazanınca
regex location'lara BAKMAZ — vhost'un statik/PHP regex'leri ve kiracı dosyasındaki regex
location'lar bu yolda devre dışıdır; kalan her `/_fm/` yolu 403 alır. Biçim kapısı HAM istek
satırındadır (`$request_uri`): sorgu dizesi, `%` kodlaması, `..`, `//`, uzantı → 403 (auth ucuna
bile ulaşmaz). Not (nginx 1.28 ölçümü): içinden dönmeyen (`set` yapan) bir `if` eşleşince
`try_files` o if-bloğuna miras kalmaz (PUT → 405); bu yüzden `uploadid/offset` çıkarması
`proxy_pass`'in durduğu `@fm_up` içindedir. Eğik çizgisiz `/_fm` bu `^~` konumuna girmez; ayrı
`location = /_fm { return 403; }` (tam eşleşme) ile 403 alır (aşağıda).

**Fail-closed (iki kapı):** (1) `auth_request`; (2) **KAPI 2** — `@fm_up` içinde
`if ($fm_auth !~ "^Bearer [A-Za-z0-9._~+/=-]+$") { return 403; }`: auth ucu 2xx dönse bile boş/
biçimsiz belirteçle pCloud'a gidilmez (90 elle silinse bile). **`/__fm_` ad alanı:** `20-srvctl-fm-upload.conf`
`location ^~ /__fm_ { internal; return 403; }` yakalayıcısını taşır; 90 (`= /__fm_auth`) ve 21 (`= /__fm_dl`) tam eşleşmedir ve
bu önekten önce kazanır. 90 (ya da 21) yokken auth alt isteği / `X-Accel-Redirect` iç isteği uygulamaya (CI4) **düşmez**:
403 alır (uygulama kodu kullanıcı çerezleriyle çalışmaz); dışarıdan gelen `/__fm_…` isteği `internal` gereği 404 alır. **Aynı yakalayıcı KAPALI kökte de vardır**
(`fm-auth off` 403 kökü, şablon sürümü 4+): alan kapalıyken uygulama `X-Accel-Redirect: /__fm_dl…` ile (ya da bir auth alt isteği `/__fm_auth`'a) yönlendirirse istek CI4'e düşmez, 403 alır (gerçek nginx 1.28 ile ölçüldü: yakalayıcısız kökte istek uygulamaya düşüyordu).
"Auth ucu yalnız alt istek bağlamında yanıt verir" ayrımı nginx katmanında zorlanmaz; Aşama 3 auth betiği `SCRIPT_NAME`
(`/__fm_auth`) + `REQUEST_URI` ikilisini şart koşar. Auth alt isteği 2xx/401/403 dışında dönerse (auth betiği 5xx verir,
FPM soketi yok) nginx `auth_request`'i 500'e çevirir; `error_page 500 =403 @fm_deny` bunu **403**'e eşler (adlı location: iç yönlendirme gövde
sınırını yeniden uygulamaz; 32 MiB'lık parça 413 değil 403 alır; 33m sınırı üstü gövde sınır denetimiyle auth'tan ÖNCE 413 alır). pCloud'a istek 0. Yazım sırası
`on`: 90 → 21 → 20 (yol EN SON açılır); `off`: önce 20 üç konumlu 403 köküyle (`/_fm`, `^~ /_fm/`, `^~ /__fm_`) DEĞİŞTİRİLİR, sonra
90/21 silinir. Eğik çizgisiz `/_fm`: CI4'te `GET (:any)` catch-all vardır; bu yüzden hem açıkken
hem kapalıyken `location = /_fm { return 403; }` (TAM eşleşme) yazılır. `^~ /_fm` ÖNEKİ bilerek
kullanılmaz: `/_fmx`, `/_fm-x`, `/_fm_rapor`, `/_fm.php` gibi ilgisiz kiracı yollarını da yutardı
(nginx 1.28 ile ölçüldü).

**Her alanda `/_fm` 403 kökü (KULLANICI KARARI, 2026-10-25):** fm-auth hiç açılmamış alanda da
`/_fm` ve `/_fm/…` CI4'e DÜŞMEZ. `domain add` (vhost yazıldıktan sonra, `nginx -t`+reload'dan önce),
`domain fm-root` ve `domain repair` her alana `20-srvctl-fm-upload.conf` olarak **srvctl üretimi** iki
satırı yazar —
`location = /_fm { return 403; }` + `location ^~ /_fm/ { return 403; }` — ve köken kaydına
`state off` ile girer (kullanıcı dosyası olamaz). `fm-auth on` bu dosyanın yerini gerçek
yapılandırmayla alır, `off` yeniden 403 kökünü bırakır, `domain clone` hedefte kökle BAŞLAR (kaynağın
`on` durumu/dosyaları kopyalanmaz). Mevcut alanlar `srvctl domain fm-root <alan>|--all --apply` ile
alır (yukarıda); `nginx -t` başarısızsa dosya + kayıt geri alınır ve uyarı basılır.
**`domain add` FAIL-CLOSED'dır:** kök kurulamazsa add **durur** ve kısmi kaynaklar geri alınır
(SSL'den önce; köksüz alan canlıya çıkmaz). Öngörülebilir nedenler **hiçbir kaynak yaratılmadan** ön
koşul kapısında yakalanır: `flock` yok/kilit alınamıyor, köken kayıt dizini güvenilmez (sembolik bağ,
root sahipli değil, g/o-yazılabilir zincir, fiziksel yol farklı), bu ad için kalıntı köken kaydı ya da
yarım işlem yedeği, `custom.d/<safe_name>` sembolik bağ/dosya/yazılamaz, içinde kayıtsız `20`/`21`/`90`
(sarkan bağ dahil). `domain clone` ve `domain staging` aynı kapıdan geçer.
Kayıt YOKKEN diskte `20`/`21`/`90` adlı bir dosya varsa o **kullanıcı dosyasıdır**: açan/örtük eylemler
(`fm-auth on`, `domain add`, `repair`) onu **ezmez**, reddeder; kapatan eylemler (`fm-auth off`,
`fm-root --apply`) bilinçli olarak **devralır** (yol 403'e kapanır, eski içerik `<ad>.srvctl-tampered`).
Kayıt VARKEN dosyalar kayıtla doğrulanır (kayıt var/dosya yok "sessiz başarı" değildir): eksik/kurcalanmış/
bayat (STALE) dosyalar **kayıtlı parametrelerle** yeniden üretilir (açık alan açık kalır); KAPALI alanda eksik/kurcalanmış kök de yeniden üretilir.
AÇIK alanda ise `20`/`21`/`90`'dan biri eksik/kurcalanmış/kayıtla eşleşmiyorsa alan yeniden üretilmez, 403 köküne KAPANIR; üretilemezse çıkış 1.
`status`: yeni alan **KAPALI (403 kökü)**; kök henüz kurulmamış eski alan **YOK** (CI4'e düşer; çıkış 1;
`fm-root` ile kurulur). Kiracı yolları (`/_fmx`, `/_fm-x`,
`/_fm_rapor`, `/_fm.php`, `/_fm.css`) etkilenmez (nginx 1.28 ölçümü: `tests/test_domconf_nginx_real.sh` "3b").

**Köken kaydı (provenance):** `${SRVCTL_STATE_DIR}/_fm-auth/<safe_name>.manifest` (dizin root 0700,
dosya 0600, atomik yazım): `state`, `region`, `script`, `php_version`, `modsec`, `tpl_ver` ve her
dosya için `sha256`. Tarama muafiyeti **yalnız** buna bağlıdır: ad sabit kümede + normal dosya
(sembolik bağ/hardlink değil) + root sahipli + g/o yazma yok + özet kayıtla eşit ⇒ "üretilmiş".
İçerik kalıbıyla muafiyet YOKTUR. Kayıt dizini/dosyası sembolik bağ/yanlış sahip/mod/hardlink/
g-o-yazılabilir zincir ise **STATE-UNTRUSTED**: hiçbir dosya üretilmiş sayılmaz (hepsi kullanıcı
dosyası → izin listesi). Durumlar (`status`): **AÇIK**, **KAPALI (403 kökü)**, **YOK**, **STALE**
(özet kayıtla eşit ama şablon ya da PHP sürümü kaymış — **şablon kayması: `fm-root <alan> --apply`;
PHP havuz sürümü kayması: `repair <alan>`** (kayıtlı parametre PHP sürümünü yeniden okuyamaz; repair'in
geniş yan etkileri için yukarıya bakın); Deploy README §2 madde 4 ile aynı), **TAMPERED** (özet farklı: `repair`
yeniden üretir, eski içerik `<ad>.srvctl-tampered` olarak saklanır), **EKSİK**, **STATE-UNTRUSTED**,
**YARIM İŞLEM** (aşağıda). `status` ayrıca `nginx -t` çalıştırır: özetler sağlam dese de yapılandırma
yüklenemiyorsa (hata bu alanın dosyasındaysa ayrıca söylenir) çıkış 1'dir.
Yazımlar `flock` ile serileştirilir (`.lock`; `flock` yoksa fail-closed); yerinde yaz → `nginx -t` →
hata → dosyalar + kayıt **geri alınır**; kayıt iki aşamalıdır (yazımdan önce eski+yeni özet,
doğrulanınca yalnız yeni). **Kesinti (SIGKILL/OOM/güç) penceresi:** her FM yazımı önce
`${SRVCTL_STATE_DIR}/_fm-auth/.bk.<safe_name>.XXXXXX` yedeğini alır; yarıda kalan yazım bu yedeği bırakır.
`status`/`nginx-audit` bunu **YARIM İŞLEM** olarak raporlar (çıkış 1), `fm-root --apply` ve `repair`
yedeği kesinti ÖNCESİ (son `nginx -t`'den geçmiş) haline geri yükleyip normal akışı yeniden değerlendirir
(**birden çok yarım yedek (≥2) → otomatik kurtarma YAPILMAZ: alan 403 köküne KAPATILIR, iki yedek de dokunulmadan
korunur, rc 1 ve "elle inceleyin"** — ayrıntı ve bedeli: aşağıda "Kullanılabilirlik bedeli"; açık operatör komutu
`fm-auth <alan> off` ise yedekleri geri yüklemeden `.superseded.bk.*` olarak ayırır). Geri alma başarısızsa yedek **silinmez**. Eski biçim (adsız
`.bk.XXXXXX`) yedekler sahibi bilinemediği için yalnız raporlanır.

**KAPALI istisnası — "yedeği geri yükler" cümlesi köken kaydı `state off` iken GEÇMEZ.**
Kurtarma operatörün kapatmasını asla geri açmaz: kayıt KAPALI ise `fm-root --apply`, `repair` ve
`fm-auth off` yarım işlem yedeğini **geri yüklemez**, silmeden kenara ayırır:
`${SRVCTL_STATE_DIR}/_fm-auth/.superseded.bk.<safe_name>.XXXXXX` (aynı ad doluysa `.<pid>.<rastgele>`
soneki). Ne olduğu: kesinti anındaki ESKİ (çoğunlukla AÇIK) FM yapılandırmasının adli kopyasıdır —
içinde 90/21/20 dosyaları ve kayıt bulunabilir. Kod bu yedeği **hiçbir yolda okumaz ya da geri yüklemez**;
`status`/`nginx-audit`/`fm-root` planı onu "yarım işlem" saymaz (glob'lar `.superseded.*`'e eşleşmez) ve
ayrı bir satırda sayıp anar (alan başına 5'ten fazlaysa `UYARI`, değilse bilgi; çıkış kodunu DEĞİŞTİRMEZ). Yalnız `domain remove` siler; otomatik silme/tavan YOKTUR (adli kanıt yanlışlıkla silinmesin).
Ne zaman bakılır: bir kesinti/SIGKILL sonrası `status` "yarım işlem" dedikten sonra; yedek birikiyorsa
(aynı alanda birden çok) tekrarlayan kesinti vardır — nedenini arayın. Silmek güvenlidir (inceleme sonrası
`sudo rm -r -- "${SRVCTL_STATE_DIR}/_fm-auth/.superseded.bk.<safe_name>.XXXXXX"`); elle geri
yüklemek FM'i yeniden AÇABİLİR, bu yüzden önerilmez — açmak için normal yol `fm-auth <alan> on`'dur. `php-switch`/`repair` sed ile değil, **render + kayıt güncellemesi** ile
çalışır; `domain remove` kaydı siler; `domain clone` FM dosyalarını/kaydı **kopyalamaz** (klon 403
kökü ile başlar). `domain staging <alan>` aynı kapıdan geçer: kaynağın `00-custom.conf`'u izin
listesine uymuyorsa **DURUR**, `--skip-custom-d` ile açıkça atlanır (bayrak `clone`'a geçer).

- `off` (normal yol), `custom.d`'de başka bir dosya `/__fm_auth`, `__fm_dl` ya da `/_fm/` kullanıyorsa
  **reddeder** (`--force` ister). Çözümlenemeyen yüklenebilir dosya "kullanıyor" sayılır. Normal yolun
  reddi/başarısızlığı alanı AÇIK bırakmaz: aşağıdaki **acil kapatma yoluna** düşülür.

**Acil kapatma — `fm-auth <alan> off` hangi nedenle olursa olsun alanı KAPATIR ya da "FM HÂLÂ AÇIK" der.**
Önceki sürümde normal `off` yolu 15 lab hücresinin 8'inde reddedildi/geri alındı ve alan AÇIK kaldı (kayıt dizini
güvenilmez, kilit alınamadı, `flock` yok, `nginx -t` düştü, `custom.d` başvurusu `--force`suz, kayıtsız FM
dosyası …); reload başarısızken `status` diskteki "KAPALI"yı söyleyip çalışan nginx'in AÇIK olduğunu
gizliyordu. Çözüm, **monoton** (yalnız kapatma yönünde ilerleyen) bir yoldur:
- **Arayüz:** normal `off` başarısız olduğu HER durumda otomatik acil yola düşer (acil anda bayrak bilmek
  gerekmez); `sudo srvctl domain fm-auth <alan> off --emergency` normal yolu hiç denemeden doğrudan acil yola gider
  (`--dry` ile `DRY-OK`, yazım yok). **Normal `off` da artık çalışan durumu sınar**: reload `rc 0` dese
  bile nginx master'ı eski yapılandırmada kalmış olabilir (gerçek nginx 1.28 "still could not bind()" senaryosunda
  ölçüldü: reload başarılı, `PUT /_fm/up/1/0` hâlâ 411). Normal `off` başarıyı YALNIZ sonda KAPALI imzası
  verince söyler; sonda AÇIK görürse acil yolun "FM HÂLÂ AÇIK" iletisi ve rc 3; doğrulanamıyorsa bunu açıkça
  söyler ve rc 4 döner (sessizce "kapatıldı" demez).
- **Ne yapar:** köken kaydına, kilide, `custom.d` başvurularına (`--force`) ve `nginx -t` geri almasına BAĞLI OLMADAN
  (0) **acil işaretini diske dokunmadan ÖNCE yazar** (aşağıda "Acil işaretin yeri"), (1) `20-srvctl-fm-upload.conf`'u srvctl
  üretimi 403 köküne ATOMİK yazar (geçici dosya + `mv`; sembolik bağ/dizin olan eski girdi önce kenara alınır),
  (2) `90`/`21` dosyalarını devre dışı bırakır (silmez: `*.srvctl-emergency.*` adıyla kenara alır; `*.conf`
  glob'una uymaz — alınamazsa siler), (3) kayıt dizini güvenilirse bayat yarım işlem yedeklerini geri yüklemeden
  ayırır ve kaydı `off`a eşitler, (4) `nginx -t` dener; **geçerliyse** reload eder. `nginx -t` düşerse reload
  DENENMEZ (nginx geçersiz yapılandırmayı zaten almaz; çalışan nginx eski yapılandırmayla kalır ve sonda AÇIK
  görürse rc 3 "FM HÂLÂ AÇIK" olur), (5) ÇALIŞAN durumu sınar ve GERÇEĞİ söyler. Hiçbir hata yolunda eski
  (açık) içeriği geri koymaz. Kilit aşaması kilidi alana dek bekler ve kapanışı kilit altında YENİDEN doğrular
  (`SRVCTL_FM_EMERGENCY_LOCK_WAIT`, varsayılan **60 sn**, bekleme üst sınırıdır; disk
  ve nginx kilitten ÖNCE kapatılır AMA bekleme yalnız raporu geciktirmez: sürmekte olan bir yazıcı diski arada yeniden açmış
  olabilir ve kapanış kilit altında doğrulanana dek kesin değildir; normal `off`un kilit beklemesi ayrıdır: `SRVCTL_FM_OFF_LOCK_WAIT`, 10 sn).
  Süre dolarsa "ACİL KAPATILDI" DENMEZ — kapanış doğrulanamaz (eşzamanlı bir srvctl yazıcısı alanı arada açmış
  olabilir): "kapanış DOĞRULANAMAZ: eşzamanlı bir srvctl yazıcısı fm-auth kilidini N sn boyunca bırakmadı" iletisi ve rc 4. Başlangıç iletisi `ACİL KAPATMA:`, rc 0
  sonunda `fm-auth ACİL KAPATILDI:`; `domain remove` işareti ve alanın yedeklerini siler.
- **Çıkış kodları — acil yol (`off --emergency` ve otomatik düşüş).** rc 0 = disk KAPALI + reload tamam + sonda KAPALI imzası verdi
  (+ gerekli acil işaret yazıldı); başka hiçbir durum rc 0 değildir:
  | rc | anlam | ileti (başı) |
  |----|-------|--------------|
  | `0` | disk KAPALI, nginx yeniden yüklendi, sonda `srvctl-fm-closed <sig>` | `fm-auth ACİL KAPATILDI: <alan> — disk KAPALI, nginx yeniden yüklendi, çalışan durum KAPALI (sonda 403)` |
  | `3` | sonda AÇIK imzası (`srvctl-fm-open <sig>`): **FM HÂLÂ AÇIK** | `FM HÂLÂ AÇIK — çalışan nginx eski yapılandırmayla yüklemeye izin veriyor (…)` |
  | `4` | disk KAPALI ama çalışan durum **doğrulanamadı** (sonda ne KAPALI ne AÇIK imzası; reload başarısız/yapılmadı; ayrışık disk-çalışan durum), disk **KISMEN** kapatıldı, ya da **kilit bekleme süresi doldu** | `FM HÂLÂ AÇIK OLABİLİR …` / `ACİL KAPATMA KISMEN: …` / `kapanış DOĞRULANAMAZ: eşzamanlı bir srvctl yazıcısı …` |
  | `5` | disk **KAPATILAMADI** (elle kaldırma talimatı basılır) | `ACİL KAPATMA BAŞARISIZ: disk KAPATILAMADI (…)` |
  | `6` | disk KAPALI + çalışan KAPALI, AMA acil işaret hiçbir güvenilir yere **yazılamadı** (alan KAPALI kalır; repair/fm-root alanı hiçbir koşulda açmaz — yalnız açık 'fm-auth <alan> on' açar) | `disk KAPALI, çalışan durum KAPALI (sonda 403) AMA acil kapatma işareti YAZILAMADI …` |

  **Normal `off` (acil bayraksız):** `0` kapatıldı + sonda KAPALI imzası · `3` sonda AÇIK imzası verdi (disk+reload
  başarılı görünse de) → otomatik ACİL yola geçilir, sonucu o yol söyler · `4` kapatıldı ama çalışan durum
  **doğrulanamadı** (sonda KÖR olduğu alanlar, aşağıda "Sonda-kör alan" listesi; imzasız 403/411, 404/5xx/000 dahil;
  `fm-auth kapatıldı (disk KAPALI, nginx yeniden yüklendi) AMA çalışan durum DOĞRULANAMADI …` — "kapatıldı" DENMEZ).
  **SSL'siz alan rc 4 sebebi DEĞİLDİR**: https (443) sondası başka vhost'un yabancı imzasını alırsa sonda o
  şemada "doğrulanamadı" der ve `:80`'e geçer; orada KAPALI imzasını görürse sonuç KAPALI ve rc 0'dır.
  Normal yol başarısız olursa (herhangi bir rc) acil yola düşülür ve yukarıdaki tablo geçerlidir.
  `3`/`4`/`5`/`6`da iletide **çalışan durum** (sonda sonucu ve yapılacak adımlar) da yazılıdır: `nginx -t` hatasını giderip
  `systemctl reload nginx`, ardından `fm-auth <alan> status`.
  **Eşzamanlı açık `fm-auth on` yazıcısı ile yarış:** `off --emergency` kilit beklerken (`SRVCTL_FM_EMERGENCY_LOCK_WAIT`)
  eşzamanlı bir açık `fm-auth on` yazıcısı kilidi tutuyorsa ve bu süre içinde bırakmazsa, acil yol kapanışı kilit altında yeniden doğrulayamaz.
  Yazıcı bu arada diski açıp reload ettiyse sonda AÇIK imzası görülür: **rc 3 ve "FM HÂLÂ AÇIK OLABİLİR" MEŞRUDUR** (yanlış alarm değil — açık `on` tasarım gereği acil işaretini temizleyip alanı gerçekten açar;
  ölçümde rc 3 anında disk açık, kayıt `on`, çalışan nginx AÇIK idi). Yazıcının reload'u sondadan sonraysa rc 4 ("kapanış DOĞRULANAMAZ") çıkar. Sonuç yazıcının kilit tutma süresine bağlıdır (deterministik değil;
  varsayılan 60 sn bekleme ile ölçümde 9/9 rc 0). **Operatör adımı:** yazıcı (`fm-auth <alan> on`) bitince `sudo srvctl domain fm-auth <alan> off --emergency` komutunu TEKRAR çalıştırın
  (kapanışı kilit altında yeniden doğrular), ardından `sudo srvctl domain fm-auth <alan> status`. Bu dalın iletisi artık "kilit alınamadı … disk kilit altında DOĞRULANMADI" der ve yukarıdaki adımı önerir (eskiden yanlışlıkla "reload hatasını giderin" diyordu; rc değişmedi).
- **Sonda ve GÖVDE İMZASI:** `status`, normal `off` ve acil yol AYNI sondayı kullanır: tek istek, YALNIZ
  `127.0.0.1` (`curl --noproxy '*' --resolve <alan>:<port>:127.0.0.1`; dışarı istek yok), `PUT /_fm/up/1/0`
  gövdesiz/`Content-Length`sız; **durum kodu VE yanıt gövdesi** okunur. Her alan için srvctl üretimi şablonlar o alana
  ÖZGÜ bir imza taşır: `sig` = `sha256("srvctl-fm-sig:v" + tpl_ver + ":" + safe_name)`in ilk 12 hex'i (sır değil;
  elle: `printf 'srvctl-fm-sig:v%s:%s' <tpl_ver> <safe_name> | sha256sum | cut -c1-12`; `tpl_ver` köken kaydındaki
  `tpl_ver` = koddaki `_DOMCONF_FM_TPL_VER`). KAPALI kök (`location = /_fm` ve `location ^~ /_fm/`; acil yolun
  yazdığı kök dahil) `return 403 "srvctl-fm-closed <sig>";` döner; AÇIK yükleme konumu
  `if ($http_content_length = "") { return 411 "srvctl-fm-open <sig>"; }` döner. **YALNIZ** (403 + gövde TAM
  `srvctl-fm-closed <sig>`) = KAPALI, **YALNIZ** (411 + `srvctl-fm-open <sig>`) = AÇIK; **başka her şey =
  "doğrulanamadı"** ve HİÇBİR yerde KAPALI sayılmaz: imzasız 403/411 (sunucu düzeyi `return 403`, WAF, başka
  katman), başka alanın imzası (o şemada "doğrulanamadı"; sonda sıradaki şemaya, yani :80'e geçer), 404/5xx/000, köksüz alan (uygulama
  411/403 dönse bile imza yok). Eski sonda her 403'ü KAPALI sayıyordu; bu yanlış-KAPALI sınıfını kapatır.
  Yapılandırma-değişimi/reload karşılaştırması BİLEREK seçilmedi: reload'un başarılı görünüp worker'ların eski
  yapılandırmada kalmasını yakalamaz. Disk/kayıt KAPALI iken sonda AÇIK imzası verirse `status` "FM HÂLÂ AÇIK"
  der ve çıkış 1 döner; **köksüz** alanda (kök YOK) sonda imza göremeyeceğinden `status` ikinci bir "FM HÂLÂ
  AÇIK" uyarısı basmaz, çalışan durum "doğrulanamadı"dır. Önce https (`SRVCTL_FM_PROBE_HTTPS_PORT`, 443) sonra
  http (`SRVCTL_FM_PROBE_HTTP_PORT`, 80). Sınır: yalnız belirli bir IP'de dinleyen (127.0.0.1'e kapalı) vhost'ta
  sonuç "doğrulanamadı" olur. Ayarlar: `SRVCTL_FM_PROBE_HTTPS_PORT` (443) / `SRVCTL_FM_PROBE_HTTP_PORT` (80; `off` =
  o şemayı atla), `SRVCTL_FM_PROBE_RETRIES` (3) / `SRVCTL_FM_PROBE_RETRY_SLEEP` (1 sn; reload sonrası worker'lar
  yenilenene dek AÇIK görülürse yeniden dener), `SRVCTL_FM_OFF_LOCK_WAIT` (10 sn, normal `off` kilit beklemesi).
  **Hermetik test/lab ortamında** (curl sarmalayıcısı yalnız `<alan>:<lab portu>`na izin verir) sondanın
  443/80'e gitmemesi için `SRVCTL_FM_PROBE_HTTPS_PORT=<lab portu> SRVCTL_FM_PROBE_HTTP_PORT=off` verin.
  **Kapalılık kanıtı olarak `curl -I /_fm/x` KULLANILMAZ**: açık ve kapalı şablonun ikisinde de
  `location ^~ /_fm/ { return 403; }` vardır, ikisi de 403 verir. Doğru sınama: gövdesiz
  `curl -sS -X PUT --resolve <alan>:443:<origin> -o- -w '%{http_code}' https://<alan>/_fm/up/1/0` →
  `403` + `srvctl-fm-closed <sig>` (KAPALI) / `411` + `srvctl-fm-open <sig>` (AÇIK). Yol harf duyarlıdır
  (Linux): `PUT /_Fm/up/1/0` ayrıca sınanmalıdır. **Reload sonrası** eski worker'lar graceful kapanır; devam eden bir
  PUT eski yapılandırmayla tamamlanabilir (`worker_shutdown_timeout` tanımlı değildir) — kapanış anı ile sondanın
  KAPALI demesi arasında bu pencere vardır.
- **`status` çıkış kodu:** `rc 0` YALNIZ doğrulanmış durumda: sonda KAPALI imzasını gördü (disk KAPALI ile uyumlu)
  ya da sonda AÇIK imzasını gördü ve kayıt `on` ile uyumlu. Sonda KÖR ise (çalışan durum "doğrulanamadı") `rc 4`;
  "FM HÂLÂ AÇIK" (kayıt/disk KAPALI ama sonda AÇIK imzası) `rc 1` kalır. Normal `off`un rc 4'ü ile aynı sözleşme.
- **Sonda-kör alan ve karar kuralı:** sonda şu alanlarda imza GÖREMEZ, bu yüzden hem `status` hem normal `off`
  kalıcı olarak `rc 4` verir (bu bir arıza değil, "doğrulanamadı"dır): (a) `curl` kurulu değil; (b) hem 443'te hem 80'de
  bağlanılamıyor ya da yalnız yabancı imza geliyor; (c) sunucu düzeyi yanıt imzayı örtüyor: askıya alınmış alan
  (`domain suspend`, `.suspended` → sunucu düzeyi `return 503`), IP kısıtı, basic-auth, kullanıcı-aracısı kuralı, WAF;
  (d) v1 şablon (imza yok; `fm-root <alan> --apply` ile yenilenir). **Karar:** sonda-kör alanda `rc 4`ü "kapalı" okuma.
  Diskin KAPALI olduğunu `status` yazar (kayıt + `20` dosyası tanınan bir kapalı kök — aşağıdaki KAPALI KANITI kuralı —, `90/21` yok); çalışan durumu elle sına:
  gövdesiz `PUT` ile imzayı (aşağıda) kör noktayı atlayan bir yoldan (örn. askıyı kaldırıp ya da `--resolve` ile kısıtsız
  bir adresten) oku. Kör nedeni giderilemiyorsa alanı KAPALI tutmak için `off` yeterlidir (disk monoton KAPALI);
  "çalışan nginx de KAPALI" iddiası ancak imza görülünce yapılır.
- **Acil işaretin yeri:** işaret `<safe_name>.emergency` (içerik `srvctl-fm-emergency v1`, mod 0600) diske
  dokunulmadan ÖNCE yazılır. Kayıt dizini güvenilirse ve alanın kaydı varsa (`${SRVCTL_STATE_DIR}/_fm-auth/`, root 0700,
  sembolik bağ değil) orada; güvenilmezse (sembolik bağ, sahip/mod/yol yanlış) ya da oraya yazılamazsa kayıttan BAĞIMSIZ
  **ikinci konumda**: `${SRVCTL_FM_EMERGENCY_DIR:-/var/lib/srvctl/fm-emergency}/<safe_name>.emergency` (dizin root:root 0700,
  srvctl durum ağacının DIŞINDA). Sorgu her iki konuma bakar (varlık yönü yalnız sıkılaştırır). Kayıt dizini hiç yoksa ya da
  alanın kaydı yoksa işaret gerekmez (`on` diye okunacak kayıt yok). **İkinci konum dizini önceden hazırlanır:** `install.sh`, `srvctl init` ve `srvctl self-update` (sağlık kontrolünden sonra) `_domconf_fm_em_state_dir_prepare`'i çağırır (mkdir -p + 0700 + root:root doğrulaması, idempotent; sembolik bağ/yanlış sahip ONARILMAZ, reddedilir); başarısızlık kurulumu/güncellemeyi durdurmaz ama uyarı basar. Bu işlevi taşımayan ESKİ bir `self-update` ilk güncellemede adımı koşturamaz (çalışan kod eskidir): dizin ilk ihtiyaçta oluşur ya da `sudo bash install.sh` / `sudo srvctl init` ile hazırlanır. Hiçbir yer
  güvenilir değilse işaret YAZILAMAZ: acil kapanış YİNE yapılır (disk kapatma monotondur) ama rc 6 döner ve
  "acil kapatma işareti YAZILAMADI — repair / fm-root / php-switch alanı YENİDEN AÇABİLİR. Önce kayıt dizinini
  root:root 0700 yapıp 'srvctl domain fm-auth <alan> off' koşun" yazılır (kayıt dizini güvenilir hâle gelince `off` işareti
  yazar; ikinci konum zaten yazılabilirse işaret orada kalıcıdır). Güvenilmez dizinde root sembolik bağ İZLEYEREK hiçbir şey yazılmaz.
  **`status` TAMPERED'da `fm-root --apply` önermeden önce** diskin acil kapanmış olup olmadığına bakar: işaret
  yoksa bile "kayıt `on` ama 20 tanınan bir kapalı kök, 90/21 yok" durumu **KAPALI KANITI** sayılır (`status`: "fm-auth
  KAPALI KANITI: …"); `fm-root --apply`ın "TAMPERED, yeniden üretilecek" önerisi yerine öneri `fm-auth <alan> off`tur (`fm-root --apply` / `repair` / `php-switch` / kurtarma / toplu `repair` bu durumda
  `on` YAZMAZ).
- **Yetenek bildirimi:** `fm-auth --capabilities` çıktısı `f5-supersede=1 f6-emergency-off=1 f7-sig=1
  f7-emergency-marker=1 f8-stage-gate=1 f8-closed-evidence=1 f9e-on-rc4=1 f9e-state-untrusted=1` alanlarını da taşır
  (`f9e-on-rc4` = `fm-auth on` sonda doğrulanamayınca AÇILDI + **rc 4**, geri alma yok; `f9e-state-untrusted` = var olan yabancı
  sahipli / grup-herkes yazılabilir kayıt dizinini `on`/`fm-root`/provision REDDEDER, mod sessizce onarılmaz, `off` yine kapatır). Sayım: `srvctl-fm-caps v1` başlığı + `dry=1`
  (ayrı alan: `--dry`'ı gerçekten uyguladığının beyanı) + **13 sözleşme alanı** (`fm-root audit-root quarantine-safe modsec-probe
  add-fail-closed f5-supersede f6-emergency-off f7-sig f7-emergency-marker f8-stage-gate f8-closed-evidence f9e-on-rc4 f9e-state-untrusted`, bu sırayla) = satırda
  14 adet `=1`. "13" `dry` HARİÇ sayıdır; canlı betiğin `F4_CAPS_REQUIRED`ı da aynı 13 alandır (parite `tests/test_domconf_fm_f8_gaps.sh`ta).
  Canlı betikler (`live/fm-stage0-test.sh`) bu alanlardan biri eksik bir kurulu srvctl'e güvenmez; başlık yalnız TAM `v1` kabul edilir
  (`v10`/`v1x` kabul edilmez).
- **Ek mekanizmalar:**
  - **Stage kapısı** (`_domconf_fm_stage_gate`): `fm-auth <alan> on` DIŞINDaki her FM yazıcısı (repair, fm-root, php-switch, soket
    eşitleme, toplu repair, yarım işlem kurtarması) fm-auth kilidi altında işaretin iki konumunu **iki kez** okur — kapı A: yedekten ve
    herhangi bir yazımdan ÖNCE; kapı B: yedek kopyalama bittikten SONRA, işleme girdi eklenmeden. İşaret konmuşsa (kilit beklerken eşzamanlı
    bir acil kapatma koymuş olabilir) hiçbir şey yazılmaz, mevcut kapalı diske dokunulmaz, rc 4. Yalnız açık `fm-auth <alan> on --script=…`
    işareti kaldırır. İleti "alan KAPALI kalır" demesi için diskte KAPALI KANITI gerekir; yoksa "FM HÂLÂ AÇIK OLABİLİR" der.
  - **KAPALI KANITI (`_domconf_fm_closed_root_known`) sürümden bağımsız YAPISAL kuraldır, "srvctl'in o anki üretimiyle bayt bayt aynı" değil:**
    dosyada yalnız `location = /_fm { return 403 …; }` ve `location ^~ /_fm/ { return 403 …; }` satırları (boş/`#` satırlar dışında; şablon sürümü 4+ kökü ek olarak İMZALI kökte en çok bir kez `location ^~ /__fm_ { internal; return 403; }` taşır);
    iki satırda AYNI 12-hex `srvctl-fm-closed <imza>` (herhangi bir şablon sürümünün imzası kabul edilir) ya da imzasız eski biçim
    ise yalnız bilinen eski özet / köken kaydındaki özet. Ek direktif, include, `proxy_pass`, ek location, sembolik ya da sert bağ,
    root dışı sahip, grup/diğer yazma biti, NUL bayt → kanıt DEĞİL. Aynı yüklem acil işaret varken `status`/`nginx-audit`
    (STALE 20 + işaret), yedek geri yüklemede kapalı kökü koruma ve geri alma sonrası "disk yeniden KAPATILDI" hükmünde kullanılır.
- **"OTOMATİK YOLLAR ASLA AÇMAZ", ÜÇÜ DE TANINMALI (`_fmprov_open_artifact_recognized`, `_fmprov_load` sınıf 4):** `repair` (PHP kayması
  dahil), toplu `repair`, `fm-root`/`fm-root --all` (self-update geçişi de bu çağrıdır), `php-switch` soket güncellemesi, `domain add`/provision,
  yarım işlem kurtarması ve geri alma bir alanı **yalnız kapatma yönünde** değiştirir. Kayıt `on` iken diskteki `20-srvctl-fm-upload.conf`,
  `21-srvctl-fm-download.conf` ve `90-srvctl-fm-auth.conf` eserlerinin **üçü de tanınan srvctl AÇIK eseri** değilse (herhangi biri) — eksik, boş, sembolik bağ, yapısal sahte kök (ek direktif/`proxy_pass`/include/location), bozuk ya da
  yabancı imza, bilinmeyen içerik, kayıtta özeti olmayan, kurcalanmış açık şablon, root dışı sahip / g-o yazılabilir mod, nlink != 1, dizin, 90/21'li yarım kapalı kök — HİÇBİR otomatik yol
  açık yapılandırma üretmez: 403 kökü yazılır, 90/21 kaldırılır, kayıt `off`a eşitlenir (`_FMP_EMERGENCY=4`); `status` **TAMPERED (TANINMAYAN AÇIK
  ESER)** der, rc ≠ 0, `fm-root --apply` önermez, yalnız AÇIK `fm-auth <alan> on --script=…` (ya da kaydı eşitlemek için `off`) önerir.
  "Tanınan açık eser" yeni/gevşek bir tanıma DEĞİL, iki mevcut tanıyıcının bileşimidir: 20, 21 ve 90'ın HER BİRİ kayıtlı özetle eşleşen güvenli üretim
  (`_fmprov_file_matches_record`: normal dosya, nlink 1, root, g/o yazma yok, özet kayıtta) VE 20 ayrıca tanınan bir 403 kökü değil
  (`_domconf_fm_closed_root_known`). 21/90'ın tek başına eksik/kurcalanmış olması da alanı kapatır (önceki "20 tanınıyorsa 90/21 kayıtlı parametrelerle
  yeniden üretilir" davranışı KALDIRILDI; sınıf 4 iletisi "alan KAPATILDI" der, "yeniden üretildi" demez; kurcalanmış 90/21 `.srvctl-tampered` adli kopyasıyla
  saklanır). Üçü de tanınan açık eser üzerinde bakım (php-switch soket güncellemesi, STALE şablon yenilemesi) açık durumu KORUR, açmaz. Yarım işlem yedeği (`_fmprov_bk_restore_allowed`) yalnız ön durumu tanınan bir srvctl eseriyse geri
  yüklenir (yedeksiz-manifest ve 90/21'siz; `off` manifest + 90/21 yok + 20 yok/tanınan 403 kökü; `on` manifest + tanınan açık 20 VE yedeğin kendi kaydıyla eşleşen 90/21); aksi hâlde
  `.superseded.bk.*` olarak ayrılır, diskteki dosyalar kayda göre (yukarıdaki kuralla) yeniden değerlendirilir. Manifestsiz yedekte açık imzalı (`auth_request`/`srvctl-fm-open`/`proxy_pass`) ya da sembolik bağ/normal dosya olmayan `20` de geri yüklenmez (kayıt + 90/21 olmadan açık 20 koymak kayıtsız yarım-açık üretirdi). Yazıcı INT/TERM/HUP ile yarıda kesilirse ve yedeğin ön durumu tanınan eser değilse (kayıt `on` + tanınmayan 20), geri alma (`_domconf_fm_restore_entry`) açık/belirsiz sahte kökü diske geri KOYMAZ: `_domconf_fm_em_close_disk` ile 403 köküne kapatır, `_domconf_fm_tx_verify_list` alanı yumuşak doğrulamaya alır (nginx yeniden yüklenir + sonda; sonuç söylenir; kapatılamazsa "FM HÂLÂ AÇIK OLABİLİR"). Sınıf 4'te `status`/YARIM İŞLEM/`nginx -t` ipuçları `fm-root --apply` yerine kapatan `fm-auth <alan> off` ve açan açık `fm-auth <alan> on` önerir. Eski "yapısal sahte kök
  `fm-root --apply` ile yeniden üretilir ve alanı açar" davranışı **kaldırıldı**. Alanı AÇAN tek komut açık `fm-auth on`.
  Bilinen sınır (yüksek sesli): 90/21 (ve 20) yerinde DİZİN varsa aşama yedeği (`cp -pP`) dizini kopyalayamaz; kapatma yazımı reddedilir
  (rc ≠ 0, "sahneleme BAŞARISIZ"), önceki durum aynen kalır, alan yeniden AÇILMAZ / yeniden ÜRETİLMEZ. Artık bu durum sessiz değildir: kapatma yönünde
  "FM HÂLÂ AÇIK OLABİLİR — … kapatma YAPILAMADI: <yol> yerinde DİZİN (yabancı nesne) — srvctl dizini taşımaz, silmez, üzerine yazmaz" basılır (açma yönünde yalnız "yazım REDDEDİLDİ … yerinde DİZİN").
  Ayrıntı: aşağıda "Kullanılabilirlik bedeli".
  `php-switch` + yarım işlem yedeği: tek bir yarım işlem yedeği alanı AÇIK bırakmaz (sınıf 4 ve kayıt `on` + yedek dahil) — soket senkronu "REDDEDİLDİ" demez; yedek `fm-root`'un
  kurtarma yoluyla ele alınır (sınıf 4'te kayıt KAPALI sayılır → yedek geri YÜKLENMEZ, `.superseded.bk.*` olarak ayrılır), alan 403 köküne kapatılır ve çıkış 10 olur (php-switch nginx'i yeniden yükler). Kapatılamazsa çıkış ≠ 0 ve
  "FM HÂLÂ AÇIK OLABİLİR". ≥2 yarım işlem yedeği varsa otomatik kurtarma yapılmaz, ama alan artık AÇIK bırakılmaz: 403 köküne KAPATILIR, iki yedek dokunulmadan kalır,
  rc ≠ 0 ve "elle inceleyin" (kapatılamazsa "FM HÂLÂ AÇIK OLABİLİR"; `fm-auth <alan> off` yedekleri geri yüklemeden ayırır).
  **php-switch kapsamı:** `php-switch` soketi YAZACAĞI zaman (kayıt `on` + PHP sürüm kayması) ya da alanı KAPATMASI gerektiğinde bu yollara girer: sınıf 4 (kayıt `on` + 20/21/90'dan biri tanınmıyor) ve
  **kayıt `off` iken diskte açık iz** (90/21 var ya da 20 srvctl'in 403 kökü değil; ör. `off` kaydı diskten ÖNCE yazar, araya giren kesinti "kayıt off + disk açık" bırakabilir) — ikisinde de repair / fm-root / provision gibi alan 403 köküne
  KAPATILIR (yedek geri yüklenmez, `.superseded.`; çıkış 10, php-switch nginx'i yeniden yükler; ileti "fm-auth alanı KAPATILDI" der, "soket çekildi" DEMEZ). Kapatılamazsa rc ≠ 0 + "FM HÂLÂ AÇIK OLABİLİR".
  Kayıt `off` + disk kapalı, kayıtsız alan ya da aynı sürüm no-op'tur (rc 0); kayıtsız + diskte açık eser duran alan `php-switch` ile KAPATILMAZ (tanımlı sınır: `repair` / `fm-root --apply` / `fm-auth <alan> off`).
  **Kayıt `on` + tek yarım işlem yedeği** (`fm-auth on` yazdı, reload'dan önce kesildi; sınıf 4 değil): eskiden soket senkronu REDDEDİLİR ve yedek yerinde kalırdı, ama `php-switch` akışı arkasından koşulsuz `nginx -t && reload` yapar ve
  o yarım açılışı çalışan nginx'e YÜKLER (KAPALI → AÇIK); otomatik yol alanı açmış olurdu. Şimdi `php-switch` repair / fm-root gibi yedeği ÖNCE kurtarır (kesinti öncesi hâline geri yükler; ön durum kapalıysa alan kapalı kalır ve çıkış 10 + "fm-auth alanı KAPATILDI",
  ön durum açıksa o açık durum geri gelir ve soket güncellenir), ardından reload yüklenir. Kurtarma yapılamazsa rc ≠ 0 ve "FM HÂLÂ AÇIK OLABİLİR" basılır.

- **Kullanılabilirlik bedeli (KABUL EDİLDİ) — yarım kalan yazımdan sonra kurtarma alanı KAPATIR; açık kalmaz.** Güvenlik kullanılabilirliğin önündedir (üç eserin üçü tanınmıyorsa kayıt `off` sayılır):
  - **≥2 yarım işlem yedeği** (`.bk.<safe_name>.AAAAAA` + `.BBBBBB` …): `repair` (8.3/8.4, `--all`), `fm-root <alan> --apply`, `fm-root --all --apply`, `php-switch` (yukarıdaki koşulla) ve provision alanı **403 köküne KAPATIR**
    (kayıt `off`, 90/21 kaldırılır; yazılacak iş varsa tek `nginx -t` + tek reload; alan zaten KAPALI ise yazılacak iş yoktur, yazım ve reload yok), iki yedeğe **dokunmaz** (geri yüklemez, ayırmaz, silmez, yeniden adlandırmaz), rc 1 ve "elle inceleyin" basar. Alan zaten KAPALI ise yazım yapılmaz ("alan zaten KAPALI"). Kapatma başarısızsa
    (`nginx -t` / reload / geri alma düşerse ya da kayıt dizini güvenilmezse) rc ≠ 0 ve "FM HÂLÂ AÇIK OLABİLİR" basılır. `fm-root <alan>` kuru çıktısı "YAPILAMAZ: …" ve rc 1 olarak kalır; metin `--apply`ın alanı 403 köküne KAPATTIĞINI, yedeklere DOKUNMADIĞINI söyler.
    `status` rc 1 verir ve "YARIM İŞLEM (BİRDEN ÇOK YEDEK)" der (salt-okur).
  - **Operatör adımları (açma):** (1) yedekleri inceleyin (`${SRVCTL_STATE_DIR}/_fm-auth/.bk.<safe_name>.*`; içinde kesinti anındaki disk kopyası ve kayıt vardır); (2) neden kesildiğini bulun; (3) yedekleri elle kaldırın ya da kenara alın
    (silmek/taşımak operatörün işidir, kod yapmaz); (4) `sudo srvctl domain fm-auth <alan> on --script=/current/modules/FileManager/Auth/fm-auth.php [--region=eu|us]` ile yeniden açın; (5) `sudo srvctl domain fm-auth <alan> status`.
    **Sınır:** yedekler elle kaldırılana kadar `fm-auth <alan> on` REDDEDİLİR (yarım işlem yedeği kapısı) — yani alan, yedekler temizlenene dek KAPALI kalır; bu kabul edilmiş kullanılabilirlik bedelidir. Açık `fm-auth <alan> off` ise yedekleri `.superseded.bk.*` olarak ayırır (KAPALI istisnası) ve bundan sonra `on` mümkündür.
  - **21/90 (ya da 20) yerinde DİZİN (`isdir`):** yabancı nesne otomatik taşınmaz/silinmez (kanıt ve sahiplik). Otomatik yollar (`repair`, `--all`, `fm-root`, `fm-root --all`, provision, `php-switch`) rc ≠ 0 ve
    "FM HÂLÂ AÇIK OLABİLİR — … yerinde DİZİN" ile **yüksek sesle başarısız olur**; `status` TAMPERED ve rc ≠ 0 verir. Disk, kayıt, `custom.d` listesi ve 20 değişmez; yedek ya da `.srvctl-emergency.*` kalıntısı üretilmez.
    Bu, "üçü de tanınmalı" kuralının **tek gerekçeli istisnasıdır**: yapılandırma `nginx -t` ile zaten geçersizken (dizin `*.conf` glob'unda `pread() … (21: Is a directory)` verir) çalışan nginx'in durumu araçla değiştirilemez; çalışan nginx önceden açıksa açık kalabilir.
    Operatör adımı: dizini inceleyin, elle kaldırın/taşıyın, `nginx -t`, sonra `srvctl domain fm-auth <alan> off`, `srvctl domain fm-auth <alan> status`.
    **Dikkat — eski mekanizma:** açık operatör komutu `fm-auth <alan> off` (ve `--emergency`) bu dizini `*.srvctl-emergency.<pid>.<rastgele>` adıyla KENARA TAŞIR ve rc 0 verebilir (eski acil kapatma mekanizması; bu kural yalnız OTOMATİK yolları kapsar,
    yeni taşıma/silme mekanizması eklenmedi). Yani dizini otomatik yollar taşımaz, açık operatör kapatması taşır.
  - **`custom.d/<safe_name>` sembolik bağ ya da güvenilmez dizin İZLENMEZ:** FM yazıcıları (`on`, `repair`, toplu `repair`, provision, `php-switch`, `fm-root`, `fm-root --all`) `custom.d/<safe_name>` girdisi sembolik bağ ya da
    sembolik bağ olmayan ama root'a ait olmayan / grup-herkes tarafından yazılabilen bir dizinse (fiziksel yol zinciri dahil) HİÇBİR dosya yazmaz: hedefe (kiracının dizinine) yazım 0, rc ≠ 0, ileti `YAPILAMAZ — custom.d/<safe_name> …`
    (srvctl root olarak yazar; bağı izlemek kiracının dizinine root yazımı olurdu). **Kapatma yönü hedefe yazmadan yine kapatır:** `fm-auth <alan> off` ve `off --emergency` girdinin KENDİSİNİ (sembolik bağ ya da yabancı dizin; hedef/içerik
    taşınmaz, silinmez) yeni root sahipli dizinin içine `<safe_name>.srvctl-emergency.<pid>.<rastgele>` adıyla kenara alır, yerine root sahipli yeni dizin + 403 kökü kurar, sonra nginx `-t` + reload + sonda ile kapanışı doğrular
    (adli artık: `status`/`nginx-audit` sayar, srvctl okumaz/silmez). Kenara alma yapılamazsa (üst dizin yazılamaz vb.) disk kapatılmış sayılmaz: "FM HÂLÂ AÇIK OLABİLİR" + rc ≠ 0, hedefe yine yazılmaz. Otomatik yollar (repair, fm-root, php-switch …)
    kapatılmış alanı yeniden AÇMAZ (açma yalnız açık `fm-auth <alan> on`). Aynı kapı `_domconf_atomic_write` (hedef dizini sembolik bağsa ret) ve geri yükleme (`_domconf_fm_restore_entry`: işlem sürerken girdi bağa/yabancı dizine çevrilirse geri
    yükleme ona yazmaz, alan kapatılır) için de geçerlidir. `domain add` ön koşul kapısı aynı denetimi yapar.
    **Başarı bildirilmez:** güvenilmeyen `custom.d/<safe_name>` (sembolik bağ, root'a ait olmayan ya da grup-herkes yazılabilir dizin; inode'u kiracıya ait taklit dahil) için dosyalar kayıtla birebir eşleşse
    ve yazım gerekmese bile `repair` ve `provision` (kayma olmasa da, dolu durumdan da) rc 1 + `YAPILAMAZ … başarı bildirilmez` verir ve hiçbir şey yazmaz; `status` "fm-auth GÜVENİLMEZ" der (AÇIK/KAPALI/OK demez, rc 1);
    `nginx-audit` (tekil ve `--all`) "GÜVENİLMEZ" + "KÖK-DOĞRULANAMADI" der, "temiz" demez, rc ≥ 1 ve `--quarantine` taşımaz. Çıkış: girdiyi inceleyip root sahipli gerçek dizine çevirin ya da `fm-auth <alan> off`.
    **Kenara alma sinyal korumalıdır:** kenara alma (yeni dizin hazırla → 403 kökü → eski girdiyi içine al → yeni dizini yerine koy → doğrula) bir bütündür; bu pencerede gelen INT/TERM/HUP ertelenir, kenara alma
    TAMAMLANIR (alan KAPALI, yetim dizin yok) ve ancak sonra sinyalin çıkış koduyla çıkılır. Son `mv` düşerse eski girdi yerine geri konur (sembolik bağ/yabancı dizin olduğu gibi) ve "FM HÂLÂ AÇIK OLABİLİR" + rc ≠ 0 verilir.
    SIGKILL/elektrik kesintisi/geri koymanın da düşmesi gibi yakalanamayan kesintilerde geride `custom.d/<safe_name>.srvctl-new.<pid>.<rastgele>` (hazırlanan dizin; içinde 403 kökü ve kenara alınan girdi) ya da
    `<safe_name>.srvctl-emergency.<pid>.<rastgele>` kardeşi kalabilir; `status` (rc 1), `nginx-audit` (tekil ve `--all`, rc ≥ 1) ve `fm-root` kuru çıktısı bunları "YETİM kenara alma dizini" diye raporlar. srvctl bunları okumaz,
    geri yüklemez, SİLMEZ; nginx yüklemez (include yalnız `custom.d/<safe_name>/*.conf`). Böyle bir durumda `custom.d/<safe_name>` eksik olabilir: önce `srvctl domain fm-auth <alan> off` (kapatır, 403 kökünü kurar), sonra artıkları inceleyip elle silin.
    **Çökme sonrası yeniden yükleme (yalnız kapatma yönü):** normal `off` kaydı ve diski yazar, nginx'i EN SON yükler; `off` commit'i ile reload arasında ölüm olursa disk KAPALI (403 kökü, 90/21 yok) ama çalışan nginx hâlâ AÇIK
    kalır ve yazılacak bir şey olmadığından eskiden `repair` / `fm-root --apply` / provision reload etmez ve rc 0 verirdi. Şimdi bu yollar diskte KAPALI kanıtı olan alanda çalışan durumu da sınar (yerel sonda, `status` ile aynı): AÇIK imzası görürse
    `nginx -t` + reload yapar ve KAPALI imzasını doğrular (toplu `repair`: alan başına reload yok, sonda tek reload); `nginx -t` ya da reload başarısızsa ya da reload sonrası KAPALI doğrulanamazsa rc ≠ 0 ve "FM HÂLÂ AÇIK OLABİLİR".
    Çalışan durum KESİN KAPALI imzası (403 + alan imzası) veriyorsa dokunmaz. **Sonda kör (doğrulanamıyor: curl yok, iki portta başka/imzasız yanıt, sunucu düzeyi 403/503, `limit_req`) "kapalı" SAYILMAZ:** disk KAPALI kanıtı varsa yapılandırma
    yine KOŞULSUZ yeniden yüklenir (çalışan nginx diskten farklı olabilir); reload başarılıysa rc 0 ama ileti "çalışan durum KAPALI imzasıyla DOĞRULANAMADI" der (sessiz başarı yok), reload/`nginx -t` başarısızsa rc ≠ 0 ve "FM HÂLÂ AÇIK OLABİLİR".
    Bedeli: sondası kör bir alanda her `repair` / `fm-root --apply` / provision bir reload yapar (toplu `repair` alan başına reload etmez, döngü sonunda bir kez yükler). Alan başına bir yerel sonda isteği eklenir. Açık alanı etkilemez; hiçbir otomatik yol açmaz. Kurtarma kapatmayı diske yazıp reload düşerse
    (`repair`, `fm-root`, `fm-root --all`, provision) ileti de "FM HÂLÂ AÇIK OLABİLİR" der.
    **Bilinen sınır (kenara alma penceresi, ~6–10 ms):** kenara alma iki `mv` ile yapılır (eski girdi → yeni dizinin içine; yeni dizin → eski yol); iki adım arasında yaklaşık 6–10 ms (laboratuvarda 1. `mv` bitişinden 2. `mv` bitişine boşta 6,1–7,4 ms, yük altında 6,7–10,4 ms ölçüldü) `custom.d/<safe_name>` YOKTUR.
    Alan bu sürede AÇIK kalmaz (90/21 yoktur, açık yükleme yapılandırması yüklenmez); ancak o anda üçüncü bir tarafın nginx reload'u gelirse `/_fm` kökü görülmez ve `/_fm` yolu uygulamaya (CI4) düşer — gizlilik/bütünlük/erişilebilirlik
    etkisi yoktur (yükleme vekili yok, pCloud'a istek yok); kapanış sonrası doğrulama KAPALI imzasını arar. Pencere atomik değiş-tokuşla (`renameat2(RENAME_EXCHANGE)`; coreutils `mv --exchange`, coreutils 9.5'ten itibaren) kapatılabilirdi: hedef sistemdeki
    Ubuntu 24.04 coreutils 9.4 gönderir (`mv --exchange` yok; yardımcı araç `exch` varlığı/paketi doğrulanamadı) ve macOS laboratuvarında hiçbir karşılığı güvenle sınanamaz — sınanmamış bir yol "fail-closed" kanıtı olmadığından uygulanmadı;
    canlı sunucuda `mv --exchange` bulunur ve sınanırsa pencere kapatılabilir (kaynak: GNU coreutils bug-coreutils 2024-03 iletisi, mv(1) kılavuzu).
  - **Kayıt dizini güvenilmezken (STATE-UNTRUSTED) yazım yapılmaz ama sessiz kalınmaz:** köken kayıt dizini güvenilmez (sahip/mod/yol/sembolik bağ) ise `repair`, toplu `repair`, `fm-root <alan> --apply`,
    `fm-root --all --apply`, provision ve `php-switch` hiçbir şey yazmaz (değişmez kural: kayıt güvenilmezken disk, kayıt, yedek yok; `nginx -t` ve reload da çalışmaz) ve rc ≠ 0 verir. Eskiden ileti yalnız
    "kayıt dizinini root:root 0700 yapın" derdi (`php-switch` hiçbir şey demezdi) ve alanın hâlâ açık olabileceğini SÖYLEMEZDİ. Şimdi: diskte **KAPALI kanıtı yoksa** (90/21 duruyor ya da 20 srvctl'in tanınan 403 kökü değil) ileti
    **"FM HÂLÂ AÇIK OLABİLİR"** der ve iki çözüm gösterir: kayıt dizinini `root:root 0700` yapın, ya da kayıttan bağımsız `sudo srvctl domain fm-auth <alan> off --emergency` (işareti ikinci güvenilir konuma yazar). Diskte KAPALI kanıtı **varsa**
    ileti "AÇIK OLABİLİR" DEMEZ (yalnız "diskte KAPALI kanıtı var; çalışan nginx bu yoldan doğrulanmadı" der; rc yine ≠ 0). `fm-root <alan>` kuru çıktısının "YAPILAMAZ" nedeni ve `status` aynı kuralı izler (`status` zaten rc 1). Acil kapatma işareti
    varsa ve disk kapalıysa "alan KAPALI kalır" dalı değişmez. **Değişmeyenler:** `fm-auth <alan> off` ve `off --emergency` kayıttan bağımsız kapatmaya devam eder (rc 0, 403 kökü). **Açma yönü** (`fm-auth <alan> on`) kayıt güvenilmezken
    reddedilir (rc 1, yazım yok) ve alan açık olabiliyorsa (diskte KAPALI kanıtı yok) ÖTEKİ YOLLARLA AYNI ifadeyi söyler: **"FM HÂLÂ AÇIK OLABİLİR"** + düzeltme ipucu + `off --emergency`. Diskte KAPALI kanıtı varsa "AÇIK OLABİLİR" DENMEZ. Aynı ifade kayıt
    dizini sağlam ama kayıt DOSYASI güvenilmezse (kilit altı ret) de geçerlidir.
- **VAR OLAN kayıt dizininin modu/sahibi sessizce onarılmaz:** `fm-root <alan> --apply`, `fm-root --all --apply` ve provision (`domain add`/`repair` FM adımı) kayıt dizinini (`$SRVCTL_STATE_DIR/_fm-auth`)
    eskiden `secure_dir` ile **sessizce** `root:root 0700`'e çekip devam ederdi: dizin yabancı sahipli ya da grup/herkes tarafından yazılabilir (0777, 0770, 0775, 0707 …) iken bile. Mod düzeltmek içeriği doğrulamaz — yazabilen biri manifest, işaret ya da yedek koymuş olabilir.
    Şimdi (`_fmprov_prepare_dir`, tek kapı: kilit alan her FM yazıcısı buradan geçer): **var olan** dizin yabancı sahipli ya da `mod & 022` ise **hiçbir şey yazılmaz** (custom.d, 20/21/90, kayıt, yedek, reload, `nginx -t` aynı; mod DA 0700'e çekilmez), rc ≠ 0,
    ileti **"kayıt dizini güvenilmez: <yol> — <neden>"** + düzeltme ipucu (`chown root:root <yol> && chmod 700 <yol>`, önce içeriği inceleyin; alan açık olabiliyorsa `fm-auth <alan> off --emergency`) verir, ardından "FM HÂLÂ AÇIK OLABİLİR" kuralı işler: diskte KAPALI kanıtı yoksa
    **"FM HÂLÂ AÇIK OLABİLİR"**, varsa söylenmez. **Muaf:** dizinin HİÇ olmadığı ilk kurulum (oluşturulur, 0700) ve root sahipli, yazılamaz-gevşek modlar (0755, 0750 …: eskisi gibi 0700'e sıkılaştırılır). Aynı kapı `fm-auth <alan> on`u da reddeder
    (kapıdan önce dizin sessizce onarılıp alan açılırdı); `off`/`off --emergency` kayıttan bağımsız kapatmaya devam eder.
- **`fm-auth <alan> on` yarım kalmaz:** açan komut dosyaları+kaydı yazıp (commit) nginx'i yeniden yükler. Reload **başarısız** olursa eskiden disk AÇIK (90/21) + kayıt `on` kalırdı ("nginx reload başarısız" der, geri almazdı):
    sonraki herhangi bir reload (certbot kancası, başka srvctl komutu) ya da bir `repair`/`fm-root` o yarım açılışı "tamamlayıp" alanı AÇARDI. Şimdi açılış **geri alınır**: disk 403 köküne (90/21 kalkar, 20 = srvctl'in 403 kökü), kayıt `off`
    (kayıt-disk tutarlı), nginx bir kez daha yüklenmeye çalışılır (reload'u yeniden dene), rc ≠ 0 ve ileti gerçeği söyler ("AÇILMADI … açılış GERİ ALINDI"; çalışan durum sondadan eklenir). Reload **başarılı** ama çalışan nginx hâlâ KAPALI imzası
    (403 + alan imzası) veriyorsa (reload sessizce uygulanmadı) açılış çalışan yapılandırmaya yansımamıştır; aynı geri alma uygulanır. **Sonda kararı:** YALNIZ KESİN KAPALI imzası geri aldırır; sonda DOĞRULANAMADI (curl yok, 443'te başka vhost,
    bağlantı yok) geri ALDIRMAZ — aksi halde sondası çalışmayan her alan açılamaz olurdu (`on` önceden sonda yapmazdı; bu yeni, yalnız-kapatma-yönünde bir kontroldür).
    **Sonda DOĞRULANAMADI sessiz değildir:** geri alma yok, ama `on` "AÇILDI, canlıda DOĞRULANAMADI (<neden>)" der (yüksek sesle, `warn`) ve **rc 4** döner (yukarıdaki `on` rc notu; `status` rc 4 ile aynı anlam). Eskiden bu durumda "fm-auth AÇILDI" ve rc 0 denirdi. Sonrasında `repair`, toplu `repair`, `fm-root`, `fm-root --all`, provision
    ve `php-switch` alanı AÇMAZ (kayıt `off`, 20 = 403 kökü). **İleti dürüstlüğü:** önceki durum kapalı/yoksa yeni açılış nginx'e hiç yüklenmemiştir → "FM HÂLÂ AÇIK OLABİLİR" DENMEZ (çalışan durum doğrulanamıyorsa o söylenir);
    alan komuttan ÖNCE AÇIKTI ve başarısız bir yeniden `on` onu kapattıysa çalışan nginx eski AÇIK yapılandırmayı sunabilir → "FM HÂLÂ AÇIK OLABİLİR" + `systemctl status nginx`, `fm-auth <alan> off --emergency`. Geri alma de başarısız olursa
    (kayıt/`nginx -t`/yazım) "açılış GERİ ALINAMADI (geri alma rc=<n>) … FM HÂLÂ AÇIK OLABİLİR" + `off --emergency` denir **ve alan o anda kapatılır**: hata iletisinden ÖNCE acil kapatma işareti yazılır
    (geri almadan önce de konur, böylece geri almanın kendi yedeği açık eseri diske geri koyamaz) ve disk acil kapatma yoluyla 403 köküne alınır (iletide ikisinin sonucu yazılır; kayıt `on` kalmış olabilir ama işaret onu `off` sayar).
    Sonuç: sonraki `repair`, `php-switch`, `fm-root`, `fm-root --all` ve provision alanı AÇMAZ; yalnız açık `fm-auth <alan> on` açar ve işareti kaldırır. Çalışan nginx (reload başarısızsa) eski yapılandırmayı sunuyor olabilir: o yüzden "FM HÂLÂ AÇIK OLABİLİR"
    ve `off --emergency` + `status` önerisi sürer. Otomatik yol yalnız kapatma yönündedir: geri alma ASLA `on` yazmaz. Reload düzelince açık `fm-auth <alan> on` alanı yeniden açar (geri alma kalıcı kilit bırakmaz).
    **Geri alma sırasında köken kaydı okunamaz ya da güvenilmez olursa** (kayıt `on` yazıldıktan sonra silindi/bozuldu ya da kayıt dizini güvenilmez oldu): kayıt dizinine HİÇBİR ŞEY yazılmaz (kayıt güvenilmezken yazım yok), ama alan
    açık da bırakılmaz — disk, kayıttan ve kilitten bağımsız acil kapatma yoluyla (nginx `custom.d` dosyaları) 403 köküne alınır ve "açılış GERİ ALINAMADI (köken kaydı …) … FM HÂLÂ AÇIK OLABİLİR" + `off --emergency` denir. Acil işaret kayıt
    dizinine yazılmaz: kayıt güvenilmezse yalnız kayıt dizininin dışındaki ikinci konuma konur; kayıt hiç yoksa 'on' diye okunacak bir şey olmadığından işaret gerekmez.
    **Sinyal:** `on`un commit'i ile reload'u arasında gelen INT/TERM/HUP (ör. SSH kopması) süreci öldürmez: sinyal tuzağı commit'ten reload'un SONUNA kadar `:` olarak kalır (eskiden commit bitince kalkardı; bu pencerede ölen süreç disk AÇIK + kayıt `on`
    + çalışan nginx yüklenmemiş bırakırdı — başarısız açılışla aynı ara durum). Sinyal bu sürede yutulur, açılış kendi dalıyla (başarı / geri alma) sonuçlanır. Acil kapatma işareti kapıları ve "AÇILMADI" (eşzamanlı acil kapatma) dalı değişmez.
- **Acil işareti kapıyı atlatmaz, ek kapıdır:** işaret varken `on` kaydı KAPALI sayılır; sonraki `repair`,
  `fm-root`, `php-switch` ve yarım işlem kurtarması alanı yeniden AÇAMAZ — bu komutların işlem kaydı (`tx_commit`) işareti
  SİLMEZ ve kilit altında işareti yeniden okuyup `on` yazmaz (iletisi: "acil kapatma işareti var … 'on' kaydı YAZILMADI",
  işlem geri alınır, alan KAPALI kalır). İşareti yalnız açık `fm-auth <alan> on --script=…` (tüm kapılar: izin
  listesi taraması, vhost include, kayıt güveni …), açık `off` kaydı ve `domain remove` kaldırır.
- **`*.srvctl-emergency.<pid>.<rastgele>` kalıntıları:** her acil yolda kenara alınan 90/21 kopyaları
  nginx'e görünmez (`*.conf` glob'una uymaz) ama silinmez. `status`, `fm-root` planı ve `nginx-audit` bunları
  sayar: **10 dosyaya kadar bilgi, 11. dosyadan itibaren UYARI** ("SAYI EŞİĞİ (10) AŞILDI"; en çok 2 dosya/acil kapatma ≈ 5
  kapatma); rc'yi değiştirmez. Ad çakışmasında yeni ad denenir (üzerine `rm -f` ile yazılmaz, adli kopya kaybolmaz);
  yalnız taşıma gerçekten başarısız olursa son çare silinir (kapatma adli kopya uğruna ertelenmez). Silme yalnız
  elle ve incelemeden sonra, alanın `custom.d` dizininde (`/etc/nginx/custom.d/<safe_name>/`):
  `sudo rm -r -- /etc/nginx/custom.d/<safe_name>/*.srvctl-emergency.*` (`-r` şart: kenara alınan girdi bir DİZİN
  olabilir — güvenilmeyen/yabancı bir `custom.d/<safe_name>` dizini içeriğiyle birlikte buraya taşınır, düz `rm` onu
  silmez; sembolik bağ ise `-r` ile yalnız bağın kendisi silinir, hedef izlenmez. Önce `ls -la` ile içeriği inceleyin).

- `on` her `nginx -t`'den ÖNCE alanın kullanıcı dosyalarını izin listesinden geçirir; ihlal/
  doğrulanamayan varsa **reddeder** (kullanıcı dosyası FM yolunu etkileyebilir).
- ModSecurity tespiti **canlı yapılandırmaya hiçbir şey yazmadan** yapılır: köken kayıt
  dizini altında (root 0700; nginx'in hiçbir include glob'u buraya bakmaz) aday bir dizine bağımsız bir
  sonda yazılır ve `nginx -t -c <sonda>` çalıştırılır. Sonda yalnız ana yapılandırmanın **ana bağlam**
  `load_module` satırlarını (yalnız root sahipli, g/o-yazılamaz dosyalardan; kiracı dosyası okunmaz) ve
  `http { modsecurity off; }` içerir. Sonda geçerse `modsec 1`; sondada `unknown directive "modsecurity"`
  ise `modsec 0` (satırlar yazılmaz, uyarı basılır); **başka her sonda hatasında** hiçbir FM dosyası
  yazılmaz ve komut `rc≠0` ile durur. Ardından canlı yapılandırmada **tek** `nginx -t`; hata → dosyalar
  + kayıt geri. (Eski deneme-yanılma — önce `modsecurity off;` varyantını diske yazmak — arada bir
  kesintide host genelinde geçersiz yapılandırma bırakabiliyordu.) Ana yapılandırma yolu:
  `$SRVCTL_NGINX_CONF` | `nginx -V` `--conf-path` | `/etc/nginx/nginx.conf`; doğrulanamazsa sonda
  `load_module`'süz koşar (yanılma yönü güvenli: modül "yok" sayılırsa FM konumunda WAF açık kalır).
- `--dry` (`on`/`off`): tüm doğrulamaları yapar (allowlist, vhost include, PHP sürümü, betik gerçek yolu,
  şablon render, kullanıcı dosyası taraması), **tamamen salt-okurdur: hiçbir dosya/dizin yazmaz (köken
  kayıt dizini ve kilit dosyası dahil), nginx'i değiştirmez/reload etmez** (`flock` yoksa gerçek `on` da
  başarısız olacağından `--dry` de başarısız olur);
  başarıda `DRY-OK` basar. Betiğin srvctl modunu güvenli sorgulaması: çıktıyı değişkene alın, boruya
  vermeyin (`set -o pipefail` altında `srvctl domain help | grep -q` SIGPIPE yarışıdır).
- `srvctl domain fm-auth --capabilities` makinece okunur tek satır basar
  (`srvctl-fm-caps v1 dry=1 fm-root=1 …`). Bir betik kurulu srvctl'e `on --dry` göndermeden önce bu
  satırı doğrulamalıdır: bu satırı basmayan (eski) bir sürüm `--dry`'ı tanımayabilir.
- `fm-auth off` STATE-UNTRUSTED'da doğrudan reddedilir (`--force` bunu aşmaz; önce kayıt dizini düzeltilir).
- `--script` gerçek yol denetiminden geçer (betik varsa): betiğin kendisi sembolik bağ olamaz, dizin
  bağları çözülmüş gerçek yol alanın kendi ağacında kalmalıdır.
- Auth location'ı `fastcgi_param FM_AUTH_SUBREQ 1;` (sabit) gönderir: istemci başlıkları FPM'e yalnız
  `HTTP_` önekiyle ulaşır, bu adı istemci kuramaz. PHP tarafı kontrolü Aşama 3'tedir.

> **Not:** ModSecurity `SecRequestBodyAccess On` ile gövdeyi tamponlar; kurallar açılırsa
> `proxy_request_buffering off` akıtması bozulurdu. Bu yüzden yükleme location'ı için (hem `^~`
> location'ında hem `@fm_up`'ta) şablon düzeyinde WAF kapatılır.

### `open_basedir` — performans / savunma derinliği dengesi

```bash
sudo srvctl domain open-basedir --show                # tüm domainlerin durumu
sudo srvctl domain open-basedir example.com --show    # tek domain
sudo srvctl domain open-basedir example.com off       # kaldır (sınır chroot'a kalır)
sudo srvctl domain open-basedir example.com on        # şablon varsayılanına dön
sudo srvctl domain open-basedir --all off             # tüm domainlere uygula
```

**Varsayılan değişmedi.** Hiçbir domain bu komut açıkça çağrılmadan etkilenmez;
yeni domainler de `open_basedir` yürürlükteyken oluşur. Ayar
`/etc/srvctl/php.d/<safe_name>.ini` içinde saklandığı için `domain repair`,
`domain php-switch` ve `security harden-fpm` bunu **ezmez**.

**Neden bir seçenek:** `open_basedir` set edildiğinde PHP **realpath cache'ini
devre dışı bırakır** — `realpath_cache_size` ayarlı olsa bile kullanımı sıfır
kalır ve her dosya erişimi baştan tam yol çözümlemesi öder. Üretim ölçümü
(Ubuntu, PHP 8.3, chroot'lu izole pool, 50 modüllü CI4 uygulaması):

| Ölçüm | `open_basedir` açık | kapalı |
|---|---|---|
| 58 dosyalık `filemtime` döngüsü | 48.95 ms | **3.29 ms** |
| Dosya başına | 0.84 ms | **0.057 ms** |
| CI4 bootstrap (TTFB) | 1.28–1.60 s | **0.030–0.032 s** |
| realpath cache kullanımı | 0 KB | dolu |

Etki uygulamanın dosya sistemine ne kadar dokunduğuyla **çarpımsaldır**: çok
sayıda modül/paket tarayan (HMVC, `discoverInComposer`, cache'siz `development`
modu) uygulamalarda fark saniyelere çıkar; tek dosyalık bir PHP betiğinde
ölçülemez.

**Güvenlik ödünü nedir:** Pool zaten `chroot = WEB_ROOT/DOMAIN` ile çalışıyor ve
**chroot `open_basedir`'den daha güçlü bir sınırdır** — PHP süreci o dizinin
dışını göremez. Şablondaki `open_basedir` listesi
(`/public_html/ /private/ /tmp/ /sessions/ /releases/ /shared/`) chroot içindeki
dizinlerin neredeyse tamamını zaten kapsıyor; kaldırıldığında PHP'ye ek olarak
açılan tek şey chroot içindeki `/logs/` ve `/etc/`. Yani kaybedilen, ihlal
durumunda ikinci bir kat; kaybedilmeyen ise asıl sınır.

**Hangi domainde ne yapmalı:**

| Durum | Öneri |
|---|---|
| Geliştirme/staging, ölçülen TTFB > 300 ms | `off` — kazanç büyük, ortam zaten dış trafiğe kapalı |
| Üretim, ağır framework (çok modüllü CI4/Laravel), ölçülen fark belirgin | `off` — chroot sınırı korunur; kararı ölçüme dayandırın |
| Üretim, üçüncü taraf/müşteri kodu barındıran paylaşımlı kiracı | `on` bırakın — savunma derinliği burada ölçülen milisaniyelerden değerli |
| Ölçüm yapılmamış | Önce ölçün (aşağıdaki yöntem), sonra karar verin |

**Karar öncesi ölçüm** — `off` yapmadan önce ve sonra aynı isteği karşılaştırın:

```bash
D=example.com
curl -s -o /dev/null -H "Host: $D" -w "ONCE:  %{time_total}s\n" http://127.0.0.1/index.php
sudo srvctl domain open-basedir $D off
curl -s -o /dev/null -H "Host: $D" -w "SONRA: %{time_total}s\n" http://127.0.0.1/index.php
```

Aynı domainde bir statik dosya (`/robots.txt`) süresi **değişmemelidir** — değişirse
ölçtüğünüz şey bu ayar değildir. Cloudflare arkasındaki bir siteye sunucunun kendi
public hostname'inden `curl` atmak `000` döndürebilir; bu yüzden `Host:` başlığı +
`127.0.0.1` kullanın.

> **`none` veya boş değer YAZMAYIN.** `.ini` dosyasına elle `open_basedir = none`
> yazmak işe yaramaz, **zararlıdır**: PHP `none`'ı özel bir değer saymaz, `none`
> adlı göreli bir dizin olarak yorumlar ve domainin tüm dosya erişimini kırar.
> Boş değer de yazılamaz (`parse_php_ini_overrides` reddeder), `/` de kazanç
> vermez — boş olmayan **herhangi** bir değer PHP'ye ayarı "set edilmiş"
> saydırır ve realpath cache kapalı kalır. Ayarın kalkmasının tek doğru yolu
> pool'a o satırın hiç basılmamasıdır; `open-basedir off` tam olarak bunu yapar.
> `.ini`'ye elle yazmak isterseniz kabul edilen tek biçim `open_basedir = off`
> beyanıdır — bu, izolasyonu delen bir gevşetme sayılmadığı için `--force`
> istemez, ama başka her `open_basedir` değeri reddedilmeye devam eder.

**Geri alma:** `sudo srvctl domain open-basedir <domain> on` — beyan `.ini`'den
silinir, şablon satırı geri gelir ve FPM reload edilir.

> **`opcache.preload` neden yok:** aynı turda denendi ve gerçek sunucuda
> ölçüldü — pool'a `php_admin_value[opcache.preload]` yazıldığında `ini_get`
> değeri görüyor ama `opcache_get_status()` **`preload_statistics` üretmiyor**;
> yani preload hiç çalışmıyor. Üstelik tamamen sessiz: `php-fpm -t` temiz
> geçiyor, servis ayakta kalıyor, FPM günlüğünde tek uyarı yok. Nedeni
> zamanlama — preload **master süreç başlangıcında** çalışır, pool ayarları ise
> worker'a fork sonrası uygulanır. Eklenmesi için ayarın master'ın okuduğu
> php.ini seviyesine taşınması, chroot yol uyuşmazlığının çözülmesi ve deploy
> akışının `reload`'dan `restart`'a geçmesi gerekir (aksi halde "deploy ettim
> ama değişiklik yansımadı" sınıfı sessiz bir hata doğar). `open_basedir`
> kazancından sonra tipik katkısı 5-10 ms olduğu için bilinçli olarak
> eklenmedi; ayrıntı `templates/php-fpm/pool.conf.tpl` sonundaki notta.

### Deploy (zero-downtime)
```bash
sudo srvctl deploy example.com [branch]      # atomic switch + health check
sudo srvctl deploy example.com --dry-run     # canlıya geçirmeden dene
sudo srvctl deploy rollback example.com      # önceki sürüme dön
sudo srvctl rollback example.com             # (kısayol — aynısı)
sudo srvctl deploy health example.com        # sağlık kontrolü
sudo srvctl deploy list example.com          # release geçmişi
sudo srvctl deploy prune <domain>|--all [--keep=N] [--apply] [--include-bak]
                         # Eski release'leri temizle (varsayılan: dry-run, 5'ten eski siler)
```
**Akış:** git clone → composer → `pre-deploy.sh` hook → shared bağla → izinler → atomic symlink switch → health check (başarısızsa **otomatik rollback**) → `post-deploy.sh` hook → eski release temizliği (son 5).
Hook'lar: `shared/hooks/pre-deploy.sh` ve `shared/hooks/post-deploy.sh` (varsa çalışır; `RELEASE_DIR`, `DOMAIN` env'leri verilir).

> **Güvenlik (Faz 2/T3):** Deploy hook'ları, composer, framework build adımları
> (migrations, npm build vb.) per-domain web kullanıcısı olarak (`runuser`, 
> root **değil**) çalışır — kötü niyetli composer/npm lifecycle script'i ya da 
> hook'u root'a ulaşamaz. `shared/.env`/`shared/writable` bir symlink ise 
> reddedilir (`chown -R` ile jail dışına çıkış engellenir).

### Yedekleme
```bash
sudo srvctl backup run [domain]
sudo srvctl backup list
sudo srvctl backup restore <yedek_dizini> [domain] [--dry-run]
                           # Tek domain filtresi ve dry-run (önizleme) desteklenir
```
Günlük otomatik yedek (04:00), 30 günden eski yedekler silinir.

> **Güvenlik notu (Faz 1 → Faz 2/DALGA 6 güncellenmesi):** Dosya yedekleri
> `.credentials`, `.srvctl-meta`, `.deploy-repo` içermez. Konfigürasyon yedekleri
> (`configs.tar.gz`) ise iki moda ayırıldı:
> - **Varsayılan (güvenli):** `/etc/redis/users.acl` ve `conf/srvctl.conf` 
>   **hariç tutuluyor** (bare-metal restore sonrası Redis ACL parolaları ve
>   Cloudflare token'ı elle girilmelidir).
> - **Opt-in şifreli:** `BACKUP_GPG_RECIPIENT` yapılandırılıp `gpg` kuruluysa
>   sırlar dahil edilir ama doğrudan plaintext diske düşmeden GPG ile
>   şifrelenir (`configs.tar.gz.gpg`).

### SSL
```bash
sudo srvctl ssl renew
sudo srvctl ssl status
```

Sonradan ssl eklemek isternirse:
```bash
sudo certbot --nginx -d example.com -d www.example.com
```

### Self-Update (Pinned-Commit Modeli)
```bash
sudo srvctl self-update check          # Yeni sürüm hash'ini okuyup PİNLE (zorunlu)
sudo srvctl self-update run            # Pinlenmiş hash'i kur
sudo srvctl self-update rollback [ad]  # Son (veya belirtilen) yedeğe geri dön
```

> **Güvenlik modeli:** `run`, ÖNCE `check` çalıştırılmasını zorunlu kılar. Sistem
> klon her zaman `check` anında görülen tam commit hash'ine sabitlenir (HEAD değişse 
> bile çalıştırmıştır). Operatör kontrolü gözarı edilemez; tedarik zinciri saldırısı 
> karşı kalkan.
>
> **Neler taşınır:** `bin/`, `lib/`, `templates/`, `completions/` ve `conf/`
> altındaki **veri tabloları** (`rate-profiles.conf`, `resource-profiles.conf`).
> `conf/srvctl.conf` operatörün dosyasıdır — ayarlarınız ve sırlarınız asla
> kopyalanmaz, yedeklenmez, üzerine yazılmaz. Veri tabloları tek bir listeden
> (`_SELFUPDATE_DATA_CONFS`) yönetilir; yedekleme, kurulum ve geri yükleme
> yollarının üçü de o listeyi kullanır, böylece biri diğerlerinden geride
> kalamaz.
>
> `run`, pin dosyası yoksa (yani `check` hiç çalıştırılmamışsa) hiçbir dosyayı
> değiştirmeden durur ve size `sudo srvctl self-update check` çalıştırmanızı
> açıkça söyler — neden iki aşamalı olduğunu da (check ile run arasında içeriğin
> sessizce değişememesi için) açıklar. Pin `check`'ten sonra uzak repo ilerlediyse
> (yani "bayat" ise), `run` yine de PİNLENMİŞ commit'i kurar ve bunu bir uyarıyla
> bildirir — sessizce en güncel HEAD'e atlamaz (TOFU modelinin gereği).

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
sudo srvctl ip reapply          # Ban/whitelist/geoblock kurallarını yeniden uygula
```

> **Geoblock notu:** Ülke engelleme kuralları varsayılan uygulama yapılandırmasında 
> yer almaz; etkinleştirilmek için vhost template'ine elle ek yapılması gerekir.

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
# ─── Temel ───
DEFAULT_PHP_VERSION=8.3          # Varsayılan PHP sürümü
SSH_PORT=2222                    # SSH portu (srvctl denetleği değil, referans)
WEB_ROOT=/var/www                # Domain kökü
DEPLOYER_USER=deployer           # Deploy-çalıştırma kullanıcısı

# ─── Yedekleme ───
BACKUP_DIR=/backups              # Yedek kökü
BACKUP_RETENTION_DAYS=30         # Otomatik silme günü
BACKUP_MIN_FREE_MB=500           # Yedek sonrası disk serbest alanı (MB, uyarı)
BACKUP_GPG_RECIPIENT=            # (Opsiyonel) GPG anahtar ID → sırlarla şifreli yedek

# ─── Deploy ───
DEPLOY_KEEP_RELEASES=5           # Tutulacak release sayısı (taban 2)
DEPLOY_PRUNE_BAK_DAYS=7          # public_html.bak.* silinecek yaş (gün)
DEPLOY_RUN_MIGRATIONS=false      # DB migration otomatik çalıştır (per-domain override'ı var)
DEPLOY_NPM_BUILD=false           # npm ci && npm run build çalıştır
DEPLOY_HEALTH_RETRIES=5          # Deploy sonrası sağlık probe retry sayısı
DEPLOY_HEALTH_INTERVAL=2         # Probe interval (saniye)
DEPLOY_HEALTH_OK_CODES="200 301 302"  # Kabul edilen HTTP kodları

# ─── Güvenilir edge-IP senkronu ───
TRUSTED_SYNC_ENABLED=true        # Cloudflare/UptimeRobot IP senkronizasyonu
TRUSTED_SOURCES="cloudflare uptimerobot"  # Kaynaklar
TRUSTED_STATE_DIR=/etc/srvctl/trusted     # State dizini

# ─── Self-Update ───
SELFUPDATE_KEEP_BACKUPS=3        # Kaç son yedek tutulacak

# ─── Bildirim Entegrasyonu (setup tarafından doldurulur) ───
# REDIS_ADMIN_PASS=              (init doldurur)
# CF_API_TOKEN=                  (cloudflare setup doldurur)
# NOTIFY_TELEGRAM_TOKEN=         (notify setup doldurur)
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
