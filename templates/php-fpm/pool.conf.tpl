; TOKENS: SAFE_NAME DOMAIN WEB_USER WEB_ROOT PHP_VERSION
; Besleyen: lib/domain.sh — _domain_render_fpm_unit (satır ~518),
; _domain_repair (satır ~190) ve domain add akışının pool render'ı
; (satır ~1227) — üçü de aynı 5 token'ı verir.
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
pm = ondemand
pm.max_children = 16
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
pm.max_requests = 1000
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
; NOT: bu liste lib/init.sh'daki global 99-srvctl-security.ini listesiyle
; BİREBİR SENKRON olmalı — php_admin_value[disable_functions] EKLEMEZ,
; php.ini'deki global değeri DEĞİŞTİRİR/EZER. 'putenv' burada eksikse
; global listede kapatılmış olsa da bu pool'da yeniden AÇILIR (klasik
; putenv("LD_PRELOAD=...")/mail() enjeksiyon bypass'ı geri döner).
; Symfony Dotenv'in opt-in usePutenv() modu bundan etkilenir (varsayılan
; KAPALI — Symfony 5.1+ varsayılanı $_ENV kullanır, putenv() çağırmaz);
; disable edilince usePutenv(true) çağıran uygulamalarda putenv() sessizce
; no-op olur (E_WARNING + false döner, fatal değil) — güvenlik kazancı bu
; dar/opt-in kullanım kaybından ağır basar.
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,proc_close,proc_get_status,proc_nice,proc_terminate,pcntl_alarm,pcntl_exec,pcntl_fork,pcntl_get_last_error,pcntl_getpriority,pcntl_setpriority,pcntl_signal,pcntl_signal_dispatch,pcntl_strerror,pcntl_wait,pcntl_waitpid,pcntl_wexitstatus,pcntl_wifexited,pcntl_wifsignaled,pcntl_wifstopped,pcntl_wstopsig,pcntl_wtermsig,dl,putenv,show_source,highlight_file

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
php_admin_value[memory_limit] = 256M
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
php_admin_value[mail.log] = /logs/php-mail.log
access.log = {{WEB_ROOT}}/{{DOMAIN}}/logs/php-access.log
access.format = "%R - %u %t \"%m %r\" %s %f %{mili}d %{kilo}M %C%%"

; ─── Slowlog (yavaş sorguları yakala) ───
slowlog = {{WEB_ROOT}}/{{DOMAIN}}/logs/php-slow.log
request_slowlog_timeout = 5s
