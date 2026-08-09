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
sudo srvctl domain clone kaynak.com hedef.com        # DB + dosya klonla
sudo srvctl domain suspend example.com               # bakım modu (503 + sayfa)
sudo srvctl domain unsuspend example.com
sudo srvctl domain php-switch example.com 8.2        # PHP sürümü değiştir
sudo srvctl domain resources example.com --memory=512M --cpu=50% --io=100
sudo srvctl domain resources example.com --reset      # kaynak profiline döndür
sudo srvctl domain resources example.com --show
sudo srvctl domain staging example.com               # staging.example.com klonu
sudo srvctl domain migrate example.com user@host [--auto]
sudo srvctl domain worker <domain> <start|stop|status|enable|disable> [instance]
                         # Laravel queue / CI4 queue worker yönet
sudo srvctl domain scheduler <domain> <start|stop|status|enable|disable>
                         # Laravel schedule / Symfony messenger yönet
sudo srvctl domain rate-limit <domain> [profil]     # Rate-limit profilini değiştir/göster
sudo srvctl domain repair <domain>|--all             # Eksik chroot kütüphanelerini tamir et
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
sudo -E srvctl domain nginx example.com              # domaine özel nginx ayarları
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

Kaydettiğinizde srvctl önce sözdizimini (`php-fpm -t` / `nginx -t`), sonra
izolasyonu delen ayarları tarar. Bir sorun bulunursa değişiklik **uygulanmaz**;
`.ini` durumunda ondan türetilen pool da eski haline döndürülür ve reload
yapılmaz. `--force` ile bilerek geçebilirsiniz — o durumda olay `log_action`'a ve
bildirim kanalına düşer.

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
> satırı yoktur. `domain nginx` bunu fark edip durur ve `srvctl domain repair
> <domain>` önerir — sessizce etkisiz kalmasındansa açıkça durması tercih edildi.

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
