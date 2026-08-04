# srvctl — `domain reload` + per-domain `.ini` / nginx `.conf` düzenleme — Tasarım

> **Tarih:** 2026-08-03
> **Kapsam:** Üç yeni alt-komut (`domain reload`, `domain ini`, `domain nginx`) ve bunları besleyen render/reload altyapısı.
> **Dışarıda (ayrı spec):** `srvctl` çalışırken terminalin yanında sürekli görünen canlı durum paneli. Bu bir görüntüleme katmanıdır, buradaki "düzenle → doğrula → reload" ailesiyle ortak kodu yoktur; kendi spec'ini alacaktır.
> **Çalışma modu:** Saf-bash karar mantığı (tarama, sözdizimi doğrulama, render filtreleme, rollback) macOS'ta unit-test edilir. `systemctl` / `php-fpm -t` / `nginx -t` içeren yollar gerçek Ubuntu host'ta doğrulanır (§9).
> **Önkoşul okuma (uygulayan ajan):** `superpowers:writing-plans` ile task-task plan üret; `superpowers:test-driven-development` ile macOS-test edilebilir kısımları önce testle yaz.

## 1. Amaç ve kök-neden

Bugün bir domain'in PHP veya nginx ayarını değiştirmenin desteklenen bir yolu yok. Operatörün elinde kalan üç seçenek de bozuk:

> **RC1 — Render edilen dosyayı elle düzenlemek sessizce geri alınır.** Per-domain PHP ayarları `/etc/srvctl/fpm/<sname>.conf` içinde `php_admin_value[...]` satırları olarak duruyor; bu dosyayı `_domain_render_fpm_unit` ([lib/domain.sh:1661](../../../lib/domain.sh)) şablondan **sıfırdan** üretiyor. `domain repair`, `domain php-switch` ve `security harden-fpm` bu render'ı yeniden çalıştırdığı için elle yapılmış her düzenleme kaybolur. Aynı şey nginx vhost'u için de geçerli (`_domain_write_vhost`). Kayıp sessizdir — operatör ayarın hâlâ yürürlükte olduğunu sanır.

> **RC2 — Doğru reload hedefini bilmek uzman bilgisi gerektiriyor.** `DOMAIN_ISOLATED_FPM=true` (varsayılan) olan bir kurulumda her domain'in kendi `srvctl-fpm-<sname>.service` unit'i vardır ve paylaşılan `php<ver>-fpm.service` havuzsuz kaldığı için **bilerek durdurulmuştur**. Refleks olarak çalıştırılan `systemctl reload php8.3-fpm` hiçbir şey yapmaz — ve hata da vermez. `lib/init.sh:723` `opcache.validate_timestamps = 0` set ettiğinden, fark edilmeyen bir reload başarısızlığı **süresiz eski bytecode servisi** demektir. Bu tuzak `_deploy_reload_fpm` ([lib/deploy.sh:1198](../../../lib/deploy.sh)) içinde bir host bulgusu olarak zaten belgelenmiş; ama o bilgi deploy yoluna hapsolmuş durumda, operatörün elinde bir komut yok.

> **RC3 — `.ini` fikrinin naif hali çalışmaz.** Pool config'i `memory_limit`, `max_execution_time`, `upload_max_filesize`, `post_max_size`, `max_input_vars` anahtarlarını `php_admin_value` olarak tanımlıyor ([templates/php-fpm/pool.conf.tpl:157-168](../../../templates/php-fpm/pool.conf.tpl)). PHP'de `php_admin_value` **her zaman** `php.ini` ve `conf.d/*.ini`'yi ezer. Yani `PHP_INI_SCAN_DIR` ile per-domain bir `.ini` yükletmek, operatörün en çok değiştirmek isteyeceği ayarların **hiçbirini** etkilemez — üstelik sessizce. Bu, RC1'in daha kötü bir versiyonu olurdu.

**Tasarım ilkesi:** Kullanıcı girdisinin **kaynağı** render'ın dışında, **uygulanması** render'ın içinde olur. Böylece pool'u/vhost'u yeniden üreten her yol (add, repair, php-switch, harden-fpm) override'ları otomatik olarak yeniden uygular; bu yolların override mekanizmasından haberdar olması gerekmez.

## 2. Kapsam

| İçeride | Dışarıda |
|---|---|
| `srvctl domain reload <domain>\|--all [--fpm\|--nginx]` | Canlı durum paneli (ayrı spec) |
| `srvctl domain ini <domain> [--show] [--file F] [--force]` | Global (tüm domainler için ortak) taban `.ini`/`.conf` katmanı |
| `srvctl domain nginx <domain> [--show] [--file F] [--force]` | `php.ini`/`conf.d` global ayarlarının srvctl üzerinden yönetimi |
| Reddedilen direktif taraması + `--force` kaçış kapısı | ModSecurity kural yönetimi (mevcut `security` modülünde) |
| `reload_domain_fpm` / `domain_fpm_unit` helper'larının core.sh'a çıkarılması | `_deploy_reload_fpm`'in davranış değişikliği (yalnız DRY refactor) |
| `domain add` iskelet üretimi, `remove` temizliği, `clone` kopyalaması | |

## 3. Mimari

### 3.1 Modül yerleşimi

Yeni modül **`lib/domconf.sh`**. `lib/domain.sh` şu an 4300+ satır; üç komutu daha oraya yığmak dosyayı okunamaz hale getirir. Yükleme, projenin mevcut cross-module deseniyle (`_security_load_domain_lib`) yapılır:

```bash
# lib/domain.sh
_domain_load_conf_lib() {
    declare -F _domconf_edit_ini >/dev/null 2>&1 && return 0
    source "${SRVCTL_ROOT}/lib/domconf.sh" || return 1
}
```

`cmd_domain`'in case bloğunda:

```bash
reload) _domain_load_conf_lib || error "domconf modülü yüklenemedi"; _domconf_reload "${@:2}" ;;
ini)    _domain_load_conf_lib || error "domconf modülü yüklenemedi"; _domconf_edit_ini "${@:2}" ;;
nginx)  _domain_load_conf_lib || error "domconf modülü yüklenemedi"; _domconf_edit_nginx "${@:2}" ;;
```

`tests/test_no_undefined_functions.sh` modül sınırlarını statik olarak denetlediği için, bu yeni kenar (`domain.sh → domconf.sh`) o testin bildiği bağımlılık haritasına eklenmelidir.

### 3.2 Sorumluluk sınırı

| Katman | Sahiplendiği |
|---|---|
| `lib/domconf.sh` | Kullanıcı arayüzü: editör açma, tarama, sözdizimi doğrulama, atomik yerleştirme, rollback, reload tetikleme |
| `lib/domain.sh` | Render zinciri: `_domain_render_php_overrides` — `.ini` içeriğini pool config'ine basmak |
| `lib/core.sh` | `domain_fpm_unit`, `reload_domain_fpm` — servis katmanı helper'ları |
| `lib/deploy.sh` | `_deploy_reload_fpm` core.sh helper'larını çağıracak şekilde sadeleşir (davranış aynı) |

Enjeksiyonun `domain.sh`'ta kalması bilinçli: pool render'ının parçası olduğu için `repair` / `php-switch` / `harden-fpm` onu bedavaya kazanır.

### 3.3 core.sh'a çıkarılan helper'lar

```bash
# Domain'in GERÇEKTEN kullandığı FPM unit adını döndürür.
# İzole unit varsa o, yoksa paylaşılan php<ver>-fpm.
domain_fpm_unit() { … }

# reload → başarısızsa restart → is-active teyidi.
# PREDİKAT: 0=ayakta, 1=değil. Çağıran fail-closed davranmalı.
reload_domain_fpm() { … }
```

`_deploy_reload_fpm`'in mevcut host-bulgusu yorumları (izole domainde paylaşılan servisin bilerek durdurulmuş olması, opcache sonucu) helper'larla birlikte core.sh'a taşınır — bilgi kaybolmaz, yalnız tek yere iner.

## 4. `srvctl domain reload`

```
srvctl domain reload <domain> [--fpm|--nginx]
srvctl domain reload --all      [--fpm|--nginx]
```

Varsayılan **ikisi de**: domain'in FPM unit'i reload edilir, ardından `nginx_test` geçerse `systemctl reload nginx`.

nginx tek bir master process olduğu için domain başına nginx reload diye bir şey yoktur. `--all` çalıştırıldığında nginx **bir kez** reload edilir, domain başına değil.

**Akış (tek domain):**

1. `domain_exists` kapısı
2. `--nginx` verilmediyse: `reload_domain_fpm <domain>` → başarısızsa `error` (exit)
3. `--fpm` verilmediyse: `nginx_test` → başarısızsa `error`, geçerse `systemctl reload nginx`
4. `log_action "DOMAIN RELOAD: <domain> (fpm=… nginx=…)"`

**Akış (`--all`):** Bir domain başarısız olursa **durulmaz** — kalan domainler işlenir, sonda başarısızların listesi basılır ve komut non-zero exit eder. Gerekçe: 100 domainli bir sunucuda tek bozuk domain, 99 sağlıklı domain'i reload edilmemiş bırakmamalı. `nginx_test` başarısızsa nginx reload hiç denenmez (FPM reload'ları yine yapılır).

**Fail-closed teyit:** `reload_domain_fpm` `systemctl is-active` ile biter. `opcache.validate_timestamps=0` yüzünden sessiz başarısızlık = süresiz eski kod servisi; "reload komutu hata vermedi" yeterli kanıt değildir.

## 5. `srvctl domain ini`

```
srvctl domain ini <domain> [--show] [--file <path>] [--force]
```

**Dosya:** `${SRVCTL_PHP_INI_DIR:-/etc/srvctl/php.d}/<sname>.ini`, `root:root 0644` (sır içermez). Dizin `root:root 0755`.

### 5.1 Akış

1. Dosya yoksa iskelet (§5.4) oluşturulur
2. `--show` → içeriği bas, çık
3. Aday içerik elde edilir: `--file <path>` verilmişse o dosya, verilmemişse `mktemp` kopyası `$EDITOR` ile açılır
4. Aday içerik canlı dosyayla aynıysa → "değişiklik yok", çık (reload da yok)
5. **Sözdizimi doğrulama** (§5.2) → başarısızsa hangi satır olduğu gösterilir, hiçbir şey uygulanmaz
6. **Reddedilen anahtar taraması** (§5.3) → bulgu varsa ve `--force` yoksa reddedilir, hiçbir şey uygulanmaz
7. Canlı `.ini` `mktemp` yedeğine alınır, aday atomik olarak yerine konur
8. `_domain_render_fpm_unit <domain> <php_ver>` → pool yeniden üretilir
9. `php-fpm<ver> --fpm-config <pool> -t` → **başarısızsa rollback** (§8), reload yapılmaz
10. `reload_domain_fpm <domain>` → başarısızsa `error`
11. `log_action`; `--force` kullanıldıysa ek olarak `send_notification` ile "izolasyon override edildi" kaydı

### 5.2 Sözdizimi kuralları

Kabul edilen satır biçimleri yalnızca: boş satır, `;` veya `#` ile başlayan yorum, ve `anahtar = değer`.

| Kural | Gerekçe |
|---|---|
| Anahtar `^[A-Za-z_][A-Za-z0-9_.]*$` kalıbına uymalı | `php_admin_value[<anahtar>]` içine basılacak; köşeli parantez kapatma kaçışını engeller |
| Değerde **CR veya LF olamaz** | **Güvenlik kritik:** değer doğrudan pool config'ine basılıyor. Satır sonu kaçışı `user = root` gibi keyfi bir FPM direktifi enjekte ettirirdi |
| Değerde `{{` olamaz | `_domain_assert_no_leftover_tokens` yanlış pozitif verir |
| `[section]` başlıkları **reddedilir** | Pool'a çevrilemez; sessizce yok sayılmaları RC3'ün aynısını üretirdi |
| Aynı anahtar iki kez tanımlanamaz | Belirsizlik yerine açık hata |

### 5.3 Reddedilen anahtarlar

| Anahtar | Gerekçe |
|---|---|
| `extension`, `zend_extension` | FPM master **root** olarak başlar; keyfi `.so` yükleme = root kod çalıştırma |
| `open_basedir` | chroot içi dosya erişim sınırının gevşetilmesi |
| `disable_functions`, `disable_classes` | hardening gevşetme (bkz. pool.conf.tpl'deki BUG 2 notu) |
| `sendmail_path` | `mail()` üzerinden komut çalıştırma; pool bu anahtarı **set etmiyor**, yani gerçekten açık bir kapı |
| `allow_url_fopen`, `allow_url_include` | RFI / SSRF |
| `cgi.fix_pathinfo` | klasik PHP-FPM arbitrary-exec vektörü |

`display_errors`, `error_reporting`, `opcache.*`, `session.*`, `memory_limit` ve benzerleri serbesttir — bunlar "ayağına sıkma" kategorisi, izolasyon delme değil.

### 5.4 İskelet

`domain add` sırasında üretilir. İçeriği yorumlu ve öğretici olmalı: izin verilen tipik ayarlar yorum satırı olarak hazır bulunur, reddedilen anahtarlar gerekçesiyle listelenir, değişiklik sonrası `srvctl domain reload <domain>` hatırlatması yer alır.

### 5.5 Pool'a enjeksiyon — `_domain_render_php_overrides`

`_domain_render_fpm_unit` içindeki `{ … } > "$fpm_conf"` bloğunun sonuna eklenir.

**Kritik tasarım kararı — filtreleme, çift tanım değil.** `.ini` içindeki bir anahtar pool şablonunda da tanımlıysa (`memory_limit` gibi), şablondan gelen `php_admin_value[<anahtar>]` satırı **çıktıdan düşürülür** ve yalnız override basılır. Alternatif (ikisini de basıp "sonuncusu kazanır"a güvenmek) php-fpm'in belgelenmemiş bir davranışına bağımlılık yaratırdı; filtreleme bu bağımlılığı tamamen ortadan kaldırır ve sonuç, PHP sürümünden bağımsız olarak deterministiktir. Ayrıca üretilen pool dosyası okunduğunda hangi değerin yürürlükte olduğu tek bakışta görülür.

Üretilen blok kendini tanıtan bir başlık taşır:

```
; ─── per-domain override (/etc/srvctl/php.d/<sname>.ini) ───
php_admin_value[memory_limit] = 512M
```

Tüm override'lar `php_admin_value` olarak basılır, `php_value` olarak değil — `ini_set()` ile uygulama içinden değiştirilebilir olmaları istenmiyor.

`.ini` dosyası yoksa veya yalnız yorum içeriyorsa hiçbir şey basılmaz ve pool çıktısı bugünkünün birebir aynısı olur.

## 6. `srvctl domain nginx`

```
srvctl domain nginx <domain> [--show] [--file <path>] [--force]
```

**Dosya:** `${SRVCTL_NGINX_CUSTOM_DIR:-/etc/nginx/custom.d}/<sname>/00-custom.conf` — mevcut `webhook.d/<sname>/*.conf` yerleşimiyle birebir aynı desen.

**Include noktası:** `templates/nginx/vhost.conf.tpl` **ve** `vhost-ssl.conf.tpl`'de, server bloğunun sonunda, webhook include'unun yanında:

```nginx
include /etc/nginx/custom.d/{{SAFE_NAME}}/*.conf;
```

Glob include sıfır eşleşmeyi hatasız kabul eder, bu yüzden dizin yokken de vhost geçerlidir (aynı gerekçe webhook.d için zaten belgelenmiş).

**Konum neden sonda:** nginx'te regex `location`'lar tanım sırasına göre değerlendirilir. Include'un sonda olması, şablondaki `deny` kurallarının (`/\.`, `\.(env|git|…)$`, `spark`, `composer.json`) her zaman **önce** eşleşmesini garanti eder — operatörün eklediği bir regex bunları bypass edemez. Prefix location'lar en-uzun-eşleşme ile çalıştığı için `location /api/` gibi meşru kullanım bundan etkilenmez.

**Ön koşul kapısı (fail-closed):** Komut, domain'in vhost dosyasında include satırının bulunduğunu doğrular. Bulamazsa `error` ile durur ve `srvctl domain repair <domain>` önerir. Gerekçe: bu spec'ten önce oluşturulmuş domainlerin vhost'unda include satırı yoktur; kontrol olmasaydı operatör dosyayı düzenler, `nginx -t` temiz geçer, reload başarılı görünür ve **hiçbir şey değişmez** — RC3'ün nginx versiyonu.

### 6.1 Reddedilen direktifler

| Direktif | Gerekçe |
|---|---|
| `fastcgi_pass` | başka bir domain'in FPM socket'ine yönlenme — domainler arası izolasyon ihlali |
| `root`, `alias` | docroot/chroot dışı dosya servisi |
| `server_name` | başka bir domain'i kapma |
| `listen` | vhost/port çakışması |
| `disable_symlinks` | symlink koruması kapatma (`disable_symlinks if_not_owner` vhost'ta set) |
| `modsecurity`, `modsecurity_rules_file`, `modsecurity_rules` | WAF bypass |
| `fastcgi_param` satırında `PHP_VALUE` veya `PHP_ADMIN_VALUE` | nginx üzerinden PHP ayarı enjeksiyonu — buradan `open_basedir` boşaltılabilir; ne `nginx -t` ne `php-fpm -t` buna itiraz eder |

**`proxy_pass` bilinçli olarak serbesttir.** Tehdit modeli burada "saldırgan" değil "operatörün ayağına sıkması" — dosyayı yalnız root düzenler. Bir Node/websocket servisine proxy meşru ve yaygın bir ihtiyaçtır; reddetmek operatörü srvctl'i baypas edip vhost'u elle düzenlemeye iter, ki o değişiklik ilk `repair`de sessizce kaybolur (RC1).

**`add_header` taranmıyor, iskelette uyarılıyor.** nginx'te bir `location` bloğu içinde `add_header` kullanmak, o location için üst bloğun **tüm** güvenlik başlıklarını (HSTS, X-Frame-Options, Referrer-Policy…) sessizce düşürür. Bunu güvenilir biçimde yakalamak blok-farkında bir parser gerektirir; satır bazlı bir tarama ya yanlış pozitif üretir ya da kaçırır. İskelet dosyasının yorumlarında bu tuzağı açıkça anlatmak dürüst ve etkili çözümdür.

### 6.2 Tarama yöntemi ve sınırları

Tarama satır bazlıdır: `#` yorumları çıkarılır, baştaki boşluk kırpılır, satırın ilk kelimesi direktif adı olarak alınır. Bu, string literali içinde geçen bir direktif adında yanlış pozitif üretebilir. Bu bilinçli bir ödünleşim — yanlış pozitifin maliyeti `--force`, yanlış negatifin maliyeti sessiz izolasyon ihlali.

## 7. Yaşam döngüsü entegrasyonu

| Olay | Davranış |
|---|---|
| `domain add` | İki iskelet dosyası oluşturulur (`.ini` ve `00-custom.conf`); vhost include satırını zaten içerir |
| `domain remove` | `_domain_purge_resources` her ikisini de siler (`custom.d/<sname>/` dizini dahil) |
| `domain clone` | Her ikisi de hedefe kopyalanır — klonun amacı kaynağın davranışını taşımaktır |
| `domain repair` / `php-switch` / `security harden-fpm` | Pool render'ı `.ini`'yi otomatik yeniden uygular; vhost render'ı include satırını yeniden yazar. **Ek kod gerekmez** |
| `domain suspend` / `unsuspend` | Etkilenmez |

## 8. Hata yönetimi ve rollback

**Rollback bütünlüğü ilkesi:** Bir doğrulama başarısız olduğunda yalnız kullanıcının dosyası değil, ondan **türetilmiş çıktı da** eski haline döner. Aksi halde bozuk bir pool/vhost diskte kalır ve bir sonraki `repair` veya reload onu canlıya alır — yani hata, kendisini tetikleyen komuttan çok sonra patlar.

| Aşama | Başarısızlıkta |
|---|---|
| Sözdizimi / tarama | Hiçbir şey yazılmamıştır; satır numarası + gerekçe basılır, exit ≠ 0 |
| `php-fpm -t` | `.ini` yedekten geri konur, **pool eski `.ini` ile yeniden render edilir**, `php-fpm`'in kendi stderr çıktısı girintili gösterilir, reload yapılmaz |
| `nginx -t` | `00-custom.conf` yedekten geri konur, `nginx -t` çıktısı gösterilir, reload yapılmaz |
| `reload_domain_fpm` | `error` — dosyalar yeni haliyle kalır (config geçerli, sorun servis katmanında). Mesaj `systemctl status` / `journalctl` yönlendirmesi içerir |

`php-fpm -t` ve `nginx -t` çıktıları **yutulmaz**. `_domain_activate_fpm_unit`'te bunun tam tersi bir regresyon yaşandı ve gerçek hata mesajı (`chdir path … does not exist`) operatörden gizlenmişti; aynı hatayı tekrarlamıyoruz.

## 9. Test stratejisi

### 9.1 macOS'ta unit-test edilebilir (tests/)

| Test | Kapsam |
|---|---|
| `test_domconf_scan_ini.sh` | Her reddedilen anahtar yakalanıyor; yorum satırındaki `extension=` yakalanmıyor; `--force` geçiriyor |
| `test_domconf_scan_nginx.sh` | Her reddedilen direktif yakalanıyor; `fastcgi_param … PHP_ADMIN_VALUE` tespit ediliyor; `proxy_pass` geçiyor |
| `test_domconf_ini_syntax.sh` | CR/LF enjeksiyonu reddediliyor; `[section]` reddediliyor; çift anahtar reddediliyor; geçerli satır kabul ediliyor |
| `test_domain_php_overrides_render.sh` | `.ini`'deki `memory_limit` pool'da **tek kez** görünüyor (şablon satırı düşürülmüş); `.ini` yokken pool çıktısı değişmiyor; token kalıntısı yok |
| `test_domconf_rollback.sh` | Geçersiz içerik sonrası hem `.ini` hem pool eski halinde |
| `test_domain_fpm_unit_resolve.sh` | `domain_fpm_unit` izole unit varken onu, yokken paylaşılanı döndürüyor |
| `test_no_undefined_functions.sh` (mevcut) | Yeni `domain.sh → domconf.sh` kenarı tanımlı |

Test edilebilirlik için gereken env seam'leri: `SRVCTL_PHP_INI_DIR`, `SRVCTL_NGINX_CUSTOM_DIR` (mevcut `SRVCTL_FPM_DIR` / `SITES_AVAILABLE` deseniyle aynı).

`--file <path>` bayrağı yalnız otomasyon için değil, **test edilebilirlik için de** gereklidir: editörü mocklamadan tüm doğrulama/rollback zinciri sürülebilir.

### 9.2 HOST doğrulama (Ubuntu 22.04 ve 24.04)

1. İzole FPM'li bir domain'de `domain reload` → unit gerçekten reload oluyor, `is-active` teyidi geçiyor
2. `DOMAIN_ISOLATED_FPM=false` kurulumda aynı komut paylaşılan servisi hedefliyor
3. `domain ini` ile `memory_limit = 512M` → `php -i` / `phpinfo()` üzerinden değerin **gerçekten** değiştiği doğrulanıyor (RC3'ün sessiz başarısızlığının gerçekleşmediğinin kanıtı)
4. Aynı domain'e `domain repair` → override korunuyor
5. `domain nginx` ile `client_max_body_size 100M;` → `nginx -t` geçiyor, büyük dosya yüklemesi çalışıyor
6. Bu spec'ten önce oluşturulmuş bir domain'de `domain nginx` → include eksikliği fail-closed yakalanıyor; `repair` sonrası çalışıyor
7. `--force` ile reddedilen bir ayar → uygulanıyor, `log_action` ve bildirim kaydı düşüyor
8. Bozuk `.ini` → rollback sonrası pool dosyası eski haliyle diskte, servis kesintisi yok
9. `sudo srvctl domain ini` (env_reset yüzünden `$EDITOR` boş) → nano açılıyor; `sudo -E` ile operatörün editörü geliyor

## 10. Belgelenmesi gereken operatör tuzağı

`sudo` varsayılan olarak `env_reset` uygular ve `$EDITOR`'ü temizler. `sudo srvctl domain ini example.com` bu yüzden operatörün seçtiği editörü değil `nano`'yu açar; `sudo -E` gerekir. Bu, komutun help metninde ve README'de açıkça yer almalıdır — aksi halde "srvctl editörümü yok sayıyor" şeklinde yanlış bir hata raporuna dönüşür.

## 11. Değişecek dosyalar

| Dosya | Değişiklik |
|---|---|
| `lib/domconf.sh` | **YENİ** — `_domconf_reload`, `_domconf_edit_ini`, `_domconf_edit_nginx`, `_domconf_scan_ini`, `_domconf_scan_nginx`, `_domconf_validate_ini_syntax` |
| `lib/core.sh` | **YENİ** `domain_fpm_unit`, `reload_domain_fpm` |
| `lib/domain.sh` | `cmd_domain` case + help; `_domain_load_conf_lib`; `_domain_render_php_overrides`; `_domain_render_fpm_unit` filtreleme; `_domain_add` iskelet üretimi; `_domain_purge_resources` temizlik; `_domain_clone` kopyalama |
| `lib/deploy.sh` | `_deploy_reload_fpm` core.sh helper'larını çağıracak şekilde sadeleşir (davranış aynı) |
| `templates/nginx/vhost.conf.tpl` | `custom.d` include satırı + TOKENS yorumu |
| `templates/nginx/vhost-ssl.conf.tpl` | aynı |
| `bin/srvctl` | help metnine üç yeni alt-komut |
| `completions/srvctl.bash`, `completions/srvctl.zsh` | `reload`, `ini`, `nginx` alt-komutları ve bayrakları |
| `README.md` | Komut referansı + `sudo -E` notu |
| `tests/` | §9.1'deki altı yeni test |

## 12. Açık nokta

Yok. §5.5'teki filtreleme kararı, tasarım sırasında tespit edilen tek doğrulama borcunu (php-fpm'in çift `php_admin_value` tanımında hangi değeri seçtiği) ortadan kaldırdı; davranış artık php-fpm'in belgelenmemiş bir ayrıntısına bağlı değil.
