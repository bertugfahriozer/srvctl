; TOKENS: SAFE_NAME DOMAIN WEB_USER WEB_ROOT PHP_VERSION PM_MODE
;         PM_MAX_CHILDREN PM_START_SERVERS PM_MIN_SPARE_SERVERS
;         PM_MAX_SPARE_SERVERS MEMORY_LIMIT DISABLE_FUNCTIONS
; Besleyen: lib/domain.sh — _domain_render_fpm_unit, _domain_repair ve
; domain add akışının pool render'ı (üç çağrı noktası). DISABLE_FUNCTIONS
; her üç çağrı noktasında da _domain_disable_functions_for(framework) ile
; üretilir (bkz. o fonksiyonun başlık yorumu — BUG 2 düzeltmesi: CI4
; domainlerinde 'putenv' listeden çıkar). GÖREV 2 sözleşmesi
; (ops-infra ↔ bash-developer, KESİNLEŞTİ — bkz. lib/domain.sh
; _domain_render_fpm_unit başlık yorumu): PM_MODE=RES_PM_MODE,
; PM_MAX_CHILDREN=RES_MAX_CHILDREN, MEMORY_LIMIT=RES_MEMORY_LIMIT_MB+'M',
; PM_START_SERVERS/PM_MIN_SPARE_SERVERS/PM_MAX_SPARE_SERVERS=RES_PM_*
; (max_children'dan formülle, resource_profile_load/core.sh içinde
; türetilir). pm.process_idle_timeout BİLİNÇLİ OLARAK token DEĞİL — sabit
; '10s' aşağıda gömülü (yalnız pm=ondemand'ta anlamlı, profile göre
; değişmiyor); resource_profile_load bunun için bir RES_* değişken
; ÜRETMEMELİDİR/BESLEMEMELİDİR.
[{{SAFE_NAME}}]
; ═══════════════════════════════════════════════
;  PHP-FPM Pool: {{DOMAIN}}
;  Güvenlik: chroot jail + izole kullanıcı
; ═══════════════════════════════════════════════

; ─── Kullanıcı İzolasyonu ───
user = {{WEB_USER}}
group = {{WEB_USER}}
listen = /run/php/php{{PHP_VERSION}}-fpm-{{SAFE_NAME}}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; ─── Process Yönetimi ───
; DALGA 5 (100-domain e-ticaret ölçeği): pm/max_children/memory_limit artık
; SABİT DEĞİL — conf/resource-profiles.conf'taki profilden TÜRETİLİR (bkz. o
; dosyanın başlık yorumu — micro/standard/ecommerce/heavy). 'dynamic' modu
; pm.start_servers/min_spare_servers/max_spare_servers'ı ZORUNLU kılar,
; 'ondemand' bunları YOK SAYAR (php-fpm hata VERMEZ); ondemand ise
; pm.process_idle_timeout kullanır, 'dynamic' bunu yok sayar. render_template
; koşullu blok ÜRETEMEZ ve çok satırlı token DEĞERİNİ zaten REDDEDER
; (CRLF/config-enjeksiyon koruması, core.sh) — bu yüzden EN BASİT VE GÜVENLİ
; çözüm: HER İKİ modun anahtarlarını HER ZAMAN, KOŞULSUZ basmak. Bu, Ubuntu
; 22.04/php8.1 VE 24.04/php8.3'te GERÇEK 'php-fpm -t' ile doğrulandı: pm=
; ondemand + dynamic-only anahtarlar birlikte VE pm=dynamic + ondemand-only
; process_idle_timeout birlikte, HER İKİSİ DE exit=0, uyarı YOK (Docker,
; bkz. rapor). start_servers/min_spare/max_spare BU DOSYADA SAKLANMAZ;
; besleyen fonksiyon max_children'dan TEK bir monoton formülle türetir
; (min ≤ start ≤ max ≤ max_children — php-fpm'in 'dynamic' doğrulaması TAM
; BUNU ister, sağlanmazsa 'status=78/CONFIG' ile başlangıçta ölür). GERÇEK
; KAYNAK lib/core.sh:resource_profile_load'dur (tamsayı bölme + clamp):
;   min_spare_servers = max(1, max_children / 8)
;   start_servers      = max(1, max_children / 4)
;   max_spare_servers  = clamp(max_children / 2, start_servers, max_children)
; ör. ecommerce (max_children=16) → min=2 start=4 max=8; heavy (32) →
; min=4 start=8 max=16.
pm = {{PM_MODE}}
pm.max_children = {{PM_MAX_CHILDREN}}
pm.start_servers = {{PM_START_SERVERS}}
pm.min_spare_servers = {{PM_MIN_SPARE_SERVERS}}
pm.max_spare_servers = {{PM_MAX_SPARE_SERVERS}}
pm.max_requests = 1000
; process_idle_timeout SABİT (token değil, lib/core.sh yorumuyla uyumlu) —
; yalnız pm=ondemand'ta anlamlı, 'dynamic'te yok sayılır (zararsız — gerçek
; 'php-fpm -t' ile Ubuntu 22.04/php8.1 VE 24.04/php8.3'te doğrulandı).
pm.process_idle_timeout = 10s

; ─── CHROOT JAİL (EN KRİTİK GÜVENLİK KATMANI) ───
; PHP process bu dizinin DIŞINA ÇIKAMAZ
; Saldırgan bile olsa, dosya sistemi burada biter
chroot = {{WEB_ROOT}}/{{DOMAIN}}
chdir = /public_html

; ─── open_basedir (chroot içindeki göreceli yollar) ───
php_admin_value[open_basedir] = /public_html/:/private/:/tmp/:/sessions/:/releases/:/shared/
php_admin_value[upload_tmp_dir] = /tmp/
php_admin_value[session.save_path] = /sessions/
php_admin_value[sys_temp_dir] = /tmp/
php_admin_value[error_log] = /logs/php-error.log

; ─── Tehlikeli Fonksiyonları Devre Dışı Bırak ───
; NOT (BUG 2 düzeltmesi): bu liste lib/init.sh'daki global
; 99-srvctl-security.ini listesiyle BİREBİR SENKRON olmalı — TEK BİLİNÇLİ
; İSTİSNA: FRAMEWORK=ci4 domainlerde 'putenv' listeden ÇIKAR. Değer artık
; SABİT DEĞİL, {{DISABLE_FUNCTIONS}} token'ıyla render edilir; besleyen kod
; (lib/domain.sh:_domain_disable_functions_for) laravel/symfony/varsayılan
; domainlerde global ile BİREBİR AYNI (putenv DAHİL) listeyi üretir, yalnız
; ci4'te putenv'i çıkarır. php_admin_value[disable_functions] EKLEMEZ,
; php.ini'deki global değeri DEĞİŞTİRİR/EZER — bu yüzden 'putenv' üretilen
; değerde eksikse (ci4 dışı domainlerde ASLA olmamalı) global listede
; kapatılmış olsa da bu pool'da yeniden AÇILIR (klasik
; putenv("LD_PRELOAD=...") enjeksiyon bypass'ı geri döner).
;
; KÖK NEDEN (CI4 appstarter deploy → HTTP 500): CodeIgniter 4'ün DotEnv
; sınıfı (system/Config/DotEnv.php) .env yüklerken putenv() çağırır,
; alternatifi YOKTUR — kapalıyken framework 'Call to undefined function
; putenv()' ile HİÇ boot edemiyordu. Laravel/Symfony etkilenmiyor
; (vlucas/phpdotenv ve Symfony Dotenv putenv()'i opsiyonel/hiç kullanmaz;
; Symfony'nin opt-in usePutenv() modu zaten varsayılan KAPALI — Symfony
; 5.1+ varsayılanı $_ENV kullanır) — bu yüzden istisna DAR ve ci4'e ÖZGÜ
; tutuldu, global varsayılan sıkı kalıyor.
;
; TEHDİT MODELİ (ci4'te putenv'i açık bırakmak neden düşük risk): tek başına
; gerçek risk putenv("LD_PRELOAD=...") ile YENİ bir process spawn
; edildiğinde ortaya çıkar (env yalnız fork+exec'te İNHERİT edilir, çalışan
; process'i RETROAKTİF etkilemez). Process-spawn primitifleri (exec,
; shell_exec, system, passthru, proc_open, popen, pcntl_exec, pcntl_fork)
; FRAMEWORK FARK ETMEKSİZİN aşağıda HER ZAMAN kapalı — putenv tek başına bir
; sömürü zincirini TAMAMLAYAMAZ.
;
; GÜVENLİK DENETİMİ EKİ (2. TUR — HOST ÖLÇÜMÜYLE DÜZELTİLDİ): yukarıdaki
; "tek başına" iddiası bir istisnayı atlıyordu — mail() C seviyesinde
; popen(sendmail_path) çağırır ve bu iç popen() üstteki 'popen' girişinden
; bağımsızdır. putenv ile LD_PRELOAD ayarlanmış bir domainde mail()
; çağrılırsa yeni spawn edilen süreç onu miras alabilirdi. AYRICA mail() TEK
; BAŞINA yeterli değildi: mbstring'in mb_send_mail()'i ve imap eklentisinin
; imap_mail()'i AYNI dahili popen yolunu kullanır ve disable_functions'taki
; 'mail' girişinden ETKİLENMEZ — HOST'ta (Ubuntu 22.04, PHP 8.3) doğrulandı:
; 'mail' kapalıyken bile mb_send_mail() GERÇEKTEN spawn etti. Bu yüzden
; 'mail'/'mb_send_mail'/'imap_mail' üçü de — putenv'in aksine framework
; istisnası OLMADAN, HER framework için — aşağıya eklendi (lib/domain.sh
; besleyen fonksiyonun 'base'i üzerinden).
;
; BU LİSTE BEST-EFFORT'TUR, TEK/YETERLİ KATMAN DEĞİL: "chroot'ta sendmail/sh
; yok, o yüzden zaten kırık" savunması TEK BAŞINA güvenilmezdir — HOST
; mutasyon testi, chroot'a elle bir /bin/sh + sendmail yerleştirilse BİLE
; zinciri fiilen kesenin AppArmor'ın exec deny'i olduğunu gösterdi (tam kanıt
; ve error_log'un neden disable_functions'a EKLENMEDİĞİ:
; lib/domain.sh:_domain_disable_functions_for başlık yorumu). Yani bu satır
; yalnız BİLİNEN mail-ailesi PHP fonksiyonlarını kapatır; error_log gibi
; kapatılamayan bir yol için gerçek/tek savunma yine AppArmor'dur.
php_admin_value[disable_functions] = {{DISABLE_FUNCTIONS}}

; ─── Güvenlik Ayarları ───
php_admin_value[allow_url_fopen] = Off
php_admin_value[allow_url_include] = Off
php_admin_value[cgi.fix_pathinfo] = 0
php_admin_value[expose_php] = Off
php_admin_value[display_errors] = Off
php_admin_value[display_startup_errors] = Off
php_admin_value[log_errors] = On
php_admin_value[error_reporting] = E_ALL & ~E_DEPRECATED & ~E_STRICT

; ─── Session Güvenliği ───
php_admin_value[session.cookie_httponly] = 1
php_admin_value[session.cookie_secure] = 1
php_admin_value[session.use_strict_mode] = 1
php_admin_value[session.cookie_samesite] = Strict
php_admin_value[session.use_only_cookies] = 1
php_admin_value[session.name] = __Secure_SID
php_admin_value[session.gc_maxlifetime] = 3600

; ─── Kaynak Limitleri ───
; memory_limit artık profil-türetilmiş (bkz. yukarı 'Process Yönetimi').
; max_execution_time/max_input_time/upload limitleri BİLİNÇLİ OLARAK sabit
; kaldı — "uzun istekler" ekseni bu turda kapsam dışı (bkz. rapor: mevcut
; conf/resource-profiles.conf sözleşmesi yalnız pm_mode/max_children/
; memory_limit_mb/tasks_max alanlarını kapsıyor, genişletmedik).
php_admin_value[memory_limit] = {{MEMORY_LIMIT}}
; ↑ TOKEN ADI 'MEMORY_LIMIT' (PM_ önekSİZ, çünkü php_admin_value[memory_limit]
; bir 'pm.*' pool-manager ayarı değil, doğrudan php.ini ayarıdır). NOT: bu
; isim lib/domain.sh tarafında bu oturumda BİRDEN ÇOK KEZ 'MEMORY_LIMIT' ↔
; 'PM_MEMORY_LIMIT' arasında salındı (canlı eşzamanlı geliştirme yarışı —
; bkz. rapor). Bu şablondaki GÜNCEL/NİHAİ ad budur: besleyen kod bununla
; BİREBİR eşleşmeli, aksi halde render 'beslenmeyen token' hatasıyla durur.
php_admin_value[max_execution_time] = 60
php_admin_value[max_input_time] = 60
php_admin_value[max_input_vars] = 5000
php_admin_value[upload_max_filesize] = 50M
php_admin_value[post_max_size] = 55M

; ─── OS Kaynak Limitleri ───
rlimit_files = 4096
rlimit_core = 0

; ─── Ortam Değişkenlerini Temizle ───
clear_env = yes

; ─── Loglama ───
; NOT: access.log ve slowlog POOL direktifleridir; php-fpm MASTER (chroot DIŞI)
; tarafından açılır → GERÇEK yol olmalı (chroot-relative /logs master'da bulunamaz).
; mail.log php_admin_value'dur (worker/chroot içi) → chroot-relative kalır.
; GÜVENLİK DENETİMİ EKİ (DÜZELTME — bu satırı "artık etkisiz" sanma):
; yukarıdaki disable_functions mail()/mb_send_mail()/imap_mail()'i kapatır
; AMA error_log($msg, 1, $to) (message_type=1) BUNLARDAN BAĞIMSIZ, AYNI
; dahili sendmail yolunu kullanarak mail.log'a YAZABİLİR — HOST'ta doğrulandı
; (bkz. lib/domain.sh:_domain_disable_functions_for başlık yorumu, "error_log
; KASITLI OLARAK EKLENMEDİ" bölümü: error_log Laravel/CI4/Monolog'un temel
; loglamasına gömülü olduğundan disable_functions'a EKLENEMEZ). Yani bu satır
; HÂLÂ AKTİF bir yazma yolu olabilir; kaldırılması AYRI bir karardır ve bu
; turda yapılmadı.
php_admin_value[mail.log] = /logs/php-mail.log
access.log = {{WEB_ROOT}}/{{DOMAIN}}/logs/php-access.log
access.format = "%R - %u %t \"%m %r\" %s %f %{mili}d %{kilo}M %C%%"

; ─── Slowlog (yavaş sorguları yakala) ───
slowlog = {{WEB_ROOT}}/{{DOMAIN}}/logs/php-slow.log
request_slowlog_timeout = 5s
